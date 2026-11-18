//! Configuration: JSON parsing, validation, weighted-random host selection,
//! and an atomically-swappable config store (SIGHUP reload semantics).

const std = @import("std");
const sys = @import("sys.zig");
const log = @import("log.zig");
const Allocator = std.mem.Allocator;

pub const Host = struct {
    addr: []const u8,
    weight: i64,
};

pub const Config = struct {
    hosts: []const Host,
    weight_sum: i64,

    pub fn deinit(self: *const Config, alloc: Allocator) void {
        for (self.hosts) |h| alloc.free(h.addr);
        alloc.free(self.hosts);
    }
};

pub const ParseError = error{
    InvalidJson,
    InvalidConfig,
    InvalidAddress,
    NegativeWeight,
    OutOfMemory,
};

/// Mirror of Go's net.SplitHostPort: split "host:port", allowing empty host
/// and empty port, bracketed IPv6 literals, and rejecting malformed input.
pub fn splitHostPort(hostport: []const u8) error{InvalidAddress}!struct { host: []const u8, port: []const u8 } {
    const bad = error.InvalidAddress;
    const i = std.mem.lastIndexOfScalar(u8, hostport, ':') orelse return bad; // missing port
    var host: []const u8 = undefined;
    var j: usize = 0;
    var k: usize = 0;
    if (hostport.len > 0 and hostport[0] == '[') {
        const end = std.mem.indexOfScalar(u8, hostport, ']') orelse return bad; // missing ']'
        if (end + 1 == hostport.len) return bad; // missing port after ']'
        if (end + 1 != i) {
            // ']' not followed by the last ':'
            return bad;
        }
        host = hostport[1..end];
        j = 1;
        k = end + 1;
    } else {
        host = hostport[0..i];
        if (std.mem.indexOfScalar(u8, host, ':') != null) return bad; // too many colons
    }
    if (std.mem.indexOfScalar(u8, hostport[j..], '[') != null) return bad;
    if (std.mem.indexOfScalar(u8, hostport[k..], ']') != null) return bad;
    return .{ .host = host, .port = hostport[i + 1 ..] };
}

fn fieldIs(key: []const u8, name: []const u8) bool {
    // Go's encoding/json matches struct field names case-insensitively.
    return std.ascii.eqlIgnoreCase(key, name);
}

/// Parse and validate a config document. Any invalid entry fails the whole
/// load (like the Go original). Missing "hosts" is legal (empty backend set).
pub fn parse(alloc: Allocator, text: []const u8) ParseError!Config {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{
        .duplicate_field_behavior = .use_last,
    }) catch return error.InvalidJson;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidConfig;
    const root = parsed.value.object;

    var hosts_val: ?std.json.Value = null;
    for (root.keys(), root.values()) |key, val| {
        if (fieldIs(key, "hosts")) hosts_val = val;
    }

    var hosts = std.array_list.Managed(Host).init(alloc);
    errdefer {
        for (hosts.items) |h| alloc.free(h.addr);
        hosts.deinit();
    }

    var weight_sum: i64 = 0;
    if (hosts_val) |hv| {
        if (hv != .array) return error.InvalidConfig;
        for (hv.array.items) |item| {
            if (item != .object) return error.InvalidConfig;
            var addr: ?[]const u8 = null;
            var weight: i64 = 0; // Go zero value when the field is absent/null
            for (item.object.keys(), item.object.values()) |key, val| {
                if (fieldIs(key, "addr")) {
                    if (val != .string) return error.InvalidConfig;
                    addr = val.string;
                } else if (fieldIs(key, "weight")) {
                    switch (val) {
                        .integer => |n| weight = n,
                        .null => {},
                        else => return error.InvalidConfig,
                    }
                }
            }
            const a = addr orelse return error.InvalidAddress; // "" fails SplitHostPort in Go
            _ = splitHostPort(a) catch return error.InvalidAddress;
            if (weight < 0) return error.NegativeWeight;
            const dup = alloc.dupe(u8, a) catch return error.OutOfMemory;
            hosts.append(.{ .addr = dup, .weight = weight }) catch return error.OutOfMemory;
            weight_sum += weight;
        }
    }

    return .{
        .hosts = hosts.toOwnedSlice() catch return error.OutOfMemory,
        .weight_sum = weight_sum,
    };
}

/// Weighted random selection: draw uniformly in [0, weight_sum) and walk the
/// cumulative weights. Returns null when there is no usable backend.
pub fn chooseHost(cfg: *const Config, r: std.Random) ?*const Host {
    if (cfg.weight_sum <= 0) return null;
    const v = r.uintLessThan(u64, @intCast(cfg.weight_sum));
    var cum: i64 = 0;
    for (cfg.hosts) |*h| {
        cum += h.weight;
        if (v < cum) return h;
    }
    // Theoretically unreachable; mirror Go's fallback to the last host.
    if (cfg.hosts.len > 0) return &cfg.hosts[cfg.hosts.len - 1];
    return null;
}

/// Holds the current config behind a mutex; reload swaps it atomically.
/// On reload failure the old config is kept intact.
pub const Store = struct {
    mutex: sys.Mutex = .{},
    cfg: Config,

    pub fn init(cfg: Config) Store {
        return .{ .cfg = cfg };
    }

    pub fn deinit(self: *Store, alloc: Allocator) void {
        self.cfg.deinit(alloc);
    }

    /// Pick a host and copy its address into `buf` while holding the lock,
    /// so connection threads never reference freed config memory.
    pub fn chooseCopy(self: *Store, r: std.Random, buf: []u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const h = chooseHost(&self.cfg, r) orelse return null;
        if (h.addr.len > buf.len) return null;
        @memcpy(buf[0..h.addr.len], h.addr);
        return buf[0..h.addr.len];
    }

    /// Load `path`, validate, and swap in the new config. Errors leave the
    /// current config untouched.
    pub fn reload(self: *Store, alloc: Allocator, path: []const u8) !void {
        const text = try sys.readFile(alloc, path, 16 << 20);
        defer alloc.free(text);
        var new_cfg = try parse(alloc, text);
        errdefer new_cfg.deinit(alloc);

        self.mutex.lock();
        const old = self.cfg;
        self.cfg = new_cfg;
        self.mutex.unlock();

        old.deinit(alloc);
        log.print("Loaded new config: {d} hosts, weight_sum={d}", .{ new_cfg.hosts.len, new_cfg.weight_sum });
    }

    /// Log a summary of the current config (SIGUSR1 status output).
    pub fn logSummary(self: *Store) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        log.print("Config: {d} hosts, weight_sum={d}", .{ self.cfg.hosts.len, self.cfg.weight_sum });
        for (self.cfg.hosts) |h| {
            log.print("  host {s} weight={d}", .{ h.addr, h.weight });
        }
    }
};

// ---------------------------------------------------------------------------
// unit tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "splitHostPort valid forms" {
    const a = try splitHostPort("127.0.0.1:8080");
    try testing.expectEqualStrings("127.0.0.1", a.host);
    try testing.expectEqualStrings("8080", a.port);

    const b = try splitHostPort(":1248");
    try testing.expectEqualStrings("", b.host);
    try testing.expectEqualStrings("1248", b.port);

    const c = try splitHostPort("example.com:");
    try testing.expectEqualStrings("example.com", c.host);
    try testing.expectEqualStrings("", c.port);

    const d = try splitHostPort("[::1]:80");
    try testing.expectEqualStrings("::1", d.host);
    try testing.expectEqualStrings("80", d.port);

    const e = try splitHostPort("[2001:db8::1]:443");
    try testing.expectEqualStrings("2001:db8::1", e.host);
    try testing.expectEqualStrings("443", e.port);
}

test "splitHostPort invalid forms" {
    try testing.expectError(error.InvalidAddress, splitHostPort("no-port"));
    try testing.expectError(error.InvalidAddress, splitHostPort(""));
    try testing.expectError(error.InvalidAddress, splitHostPort("a:b:c"));
    try testing.expectError(error.InvalidAddress, splitHostPort("::1"));
    try testing.expectError(error.InvalidAddress, splitHostPort("[::1"));
    try testing.expectError(error.InvalidAddress, splitHostPort("[::1]"));
    try testing.expectError(error.InvalidAddress, splitHostPort("[::1]:80:90"));
    try testing.expectError(error.InvalidAddress, splitHostPort("host[0]:80"));
}

test "parse valid config (lowercase and Go-style capitalized keys)" {
    const cfg = try parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:8080","weight":100},{"addr":"127.0.0.1:8081","weight":50}]}
    );
    defer cfg.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), cfg.hosts.len);
    try testing.expectEqual(@as(i64, 150), cfg.weight_sum);
    try testing.expectEqualStrings("127.0.0.1:8080", cfg.hosts[0].addr);

    const cfg2 = try parse(testing.allocator,
        \\{"Hosts":[{"Addr":"127.0.0.1:80","Weight":100}],"traffic_url":"unused"}
    );
    defer cfg2.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 100), cfg2.weight_sum);
}

test "parse rejects invalid address" {
    try testing.expectError(error.InvalidAddress, parse(testing.allocator,
        \\{"hosts":[{"addr":"missing-port","weight":1}]}
    ));
    try testing.expectError(error.InvalidAddress, parse(testing.allocator,
        \\{"hosts":[{"addr":"a:b:c","weight":1}]}
    ));
    // Missing addr behaves like Go's "" -> SplitHostPort error.
    try testing.expectError(error.InvalidAddress, parse(testing.allocator,
        \\{"hosts":[{"weight":1}]}
    ));
    // One bad entry fails the whole load.
    try testing.expectError(error.InvalidAddress, parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:80","weight":1},{"addr":"bad","weight":1}]}
    ));
}

test "parse rejects negative weight" {
    try testing.expectError(error.NegativeWeight, parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:80","weight":-5}]}
    ));
}

test "parse rejects malformed json and wrong types" {
    try testing.expectError(error.InvalidJson, parse(testing.allocator, "{not json"));
    try testing.expectError(error.InvalidConfig, parse(testing.allocator, "[]"));
    try testing.expectError(error.InvalidConfig, parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:80","weight":"heavy"}]}
    ));
    try testing.expectError(error.InvalidConfig, parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:80","weight":1.5}]}
    ));
}

test "empty hosts and all-zero weights are valid but select nothing" {
    const empty = try parse(testing.allocator, "{\"hosts\":[]}");
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 0), empty.weight_sum);

    const missing = try parse(testing.allocator, "{}");
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 0), missing.weight_sum);

    const zero = try parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:80","weight":0},{"addr":"127.0.0.1:81","weight":0}]}
    );
    defer zero.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 0), zero.weight_sum);

    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    try testing.expect(chooseHost(&empty, r) == null);
    try testing.expect(chooseHost(&missing, r) == null);
    try testing.expect(chooseHost(&zero, r) == null);
}

test "weighted selection 1:2 distribution over 100k draws (fixed seed)" {
    const cfg = try parse(testing.allocator,
        \\{"hosts":[{"addr":"a:1","weight":1},{"addr":"b:2","weight":2}]}
    );
    defer cfg.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(0x1234_5678);
    const r = prng.random();
    const n = 100_000;
    var count_a: usize = 0;
    var count_b: usize = 0;
    for (0..n) |_| {
        const h = chooseHost(&cfg, r).?;
        if (std.mem.eql(u8, h.addr, "a:1")) count_a += 1 else count_b += 1;
    }
    try testing.expectEqual(n, count_a + count_b);
    // Expected shares: 1/3 and 2/3. Allow generous statistical slack.
    const fa = @as(f64, @floatFromInt(count_a)) / @as(f64, @floatFromInt(n));
    const fb = @as(f64, @floatFromInt(count_b)) / @as(f64, @floatFromInt(n));
    try testing.expect(fa > 0.30 and fa < 0.37);
    try testing.expect(fb > 0.63 and fb < 0.70);
    // Both shares lie inside the 1/3..2/3 band required by the task.
    try testing.expect(fb >= 1.0 / 3.0 and fb <= 2.0 / 3.0);
    // Ratio b:a close to 2:1.
    const ratio = @as(f64, @floatFromInt(count_b)) / @as(f64, @floatFromInt(count_a));
    try testing.expect(ratio > 1.8 and ratio < 2.2);
}

test "zero-weight host is never selected" {
    const cfg = try parse(testing.allocator,
        \\{"hosts":[{"addr":"a:1","weight":1},{"addr":"zero:0","weight":0},{"addr":"c:2","weight":2}]}
    );
    defer cfg.deinit(testing.allocator);
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    for (0..100_000) |_| {
        const h = chooseHost(&cfg, r).?;
        try testing.expect(!std.mem.eql(u8, h.addr, "zero:0"));
    }
}

test "reload swaps the selection set; failed reload keeps old config" {
    const alloc = testing.allocator;
    var pathbuf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&pathbuf, "/tmp/gopf-reload-test-{d}.json", .{std.os.linux.getpid()});
    defer sys.deleteFile(path);

    try sys.writeFile(path, "{\"hosts\":[{\"addr\":\"10.0.0.1:1111\",\"weight\":5}]}");
    const initial_text = try sys.readFile(alloc, path, 1 << 20);
    defer alloc.free(initial_text);
    const cfg = try parse(alloc, initial_text);
    var store = Store.init(cfg);
    defer store.deinit(alloc);

    var prng = std.Random.DefaultPrng.init(1);
    var buf: [256]u8 = undefined;
    // Before reload: only the old host can be chosen.
    for (0..1000) |_| {
        const a = store.chooseCopy(prng.random(), &buf).?;
        try testing.expectEqualStrings("10.0.0.1:1111", a);
    }

    // Successful reload changes the selection set.
    try sys.writeFile(path, "{\"hosts\":[{\"addr\":\"10.0.0.2:2222\",\"weight\":3},{\"addr\":\"10.0.0.3:3333\",\"weight\":1}]}");
    try store.reload(alloc, path);
    var seen2 = false;
    var seen3 = false;
    for (0..1000) |_| {
        const a = store.chooseCopy(prng.random(), &buf).?;
        try testing.expect(!std.mem.eql(u8, a, "10.0.0.1:1111"));
        if (std.mem.eql(u8, a, "10.0.0.2:2222")) seen2 = true;
        if (std.mem.eql(u8, a, "10.0.0.3:3333")) seen3 = true;
    }
    try testing.expect(seen2 and seen3);

    // Failed reload (invalid JSON) keeps the current config.
    try sys.writeFile(path, "{broken");
    try testing.expectError(error.InvalidJson, store.reload(alloc, path));
    const a = store.chooseCopy(prng.random(), &buf).?;
    try testing.expect(std.mem.eql(u8, a, "10.0.0.2:2222") or std.mem.eql(u8, a, "10.0.0.3:3333"));

    // Failed reload (negative weight) also keeps the current config.
    try sys.writeFile(path, "{\"hosts\":[{\"addr\":\"10.0.0.9:9999\",\"weight\":-1}]}");
    try testing.expectError(error.NegativeWeight, store.reload(alloc, path));
    try testing.expectEqual(@as(i64, 4), store.cfg.weight_sum);

    // Missing file keeps the current config too.
    try testing.expectError(error.FileNotFound, store.reload(alloc, "/tmp/gopf-does-not-exist-xyz.json"));
    try testing.expectEqual(@as(i64, 4), store.cfg.weight_sum);
}
