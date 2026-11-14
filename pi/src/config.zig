//! Backend configuration: JSON parsing, validation, and weighted random
//! host selection. A Config owns all of its memory in a private arena and is
//! reference counted (refs are guarded by the owner's lock) so a reload can
//! swap it out while in-flight connections still use the old one.

const std = @import("std");
const sys = @import("sys.zig");

pub const Host = struct {
    /// Original "host:port" text from the config file.
    addr: []const u8,
    weight: i64,
    /// Pre-resolved address for IP literals / localhost. Null for names we
    /// cannot resolve without libc DNS; dialing them fails at connect time
    /// (same moment where Go's dial would fail).
    sockaddr: ?sys.SockAddr,
};

pub const Config = struct {
    hosts: []Host,
    weight_sum: i64,
    /// Guarded by the owning Proxy's config lock. The "current config"
    /// pointer itself holds one reference.
    refs: usize,
    arena: std.heap.ArenaAllocator,

    /// Free all memory. Only call when refs == 0.
    pub fn destroy(self: *Config) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{
    InvalidJson,
    InvalidStructure,
    MissingAddr,
    InvalidAddr,
    InvalidWeight,
    NegativeWeight,
    WeightOverflow,
    OutOfMemory,
};

fn objGet(obj: *const std.json.ObjectMap, key: []const u8) ?std.json.Value {
    // Go's encoding/json matches struct field names case-insensitively.
    var it = obj.iterator();
    while (it.next()) |e| {
        if (std.ascii.eqlIgnoreCase(e.key_ptr.*, key)) return e.value_ptr.*;
    }
    return null;
}

/// Parse and validate a JSON config document:
///   {"hosts":[{"addr":"host:port","weight":100}]}
/// Keys are matched case-insensitively (Go encoding/json semantics).
/// Returns a heap-owned Config with refs == 1.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) ParseError!*Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const root = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch
        return error.InvalidJson;
    if (root != .object) return error.InvalidStructure;

    var hosts = std.array_list.Managed(Host).init(a);
    var weight_sum: i64 = 0;

    if (objGet(&root.object, "hosts")) |hosts_value| {
        if (hosts_value != .array) return error.InvalidStructure;
        for (hosts_value.array.items) |hv| {
            if (hv != .object) return error.InvalidStructure;

            const addr_value = objGet(&hv.object, "addr") orelse return error.MissingAddr;
            if (addr_value != .string) return error.InvalidAddr;
            const addr = addr_value.string;

            // Every addr must split into host:port, even on weight-0 hosts;
            // any illegal entry fails the whole load, like the Go original.
            const hp = sys.splitHostPort(addr) catch return error.InvalidAddr;
            const sockaddr: ?sys.SockAddr = sys.resolveDial(hp.host, hp.port) catch null;

            const weight_value = objGet(&hv.object, "weight") orelse {
                // Go: missing int field decodes as 0 (host disabled).
                try hosts.append(.{ .addr = addr, .weight = 0, .sockaddr = sockaddr });
                continue;
            };
            if (weight_value != .integer) return error.InvalidWeight;
            const weight = weight_value.integer;
            if (weight < 0) return error.NegativeWeight;
            weight_sum = std.math.add(i64, weight_sum, weight) catch return error.WeightOverflow;
            try hosts.append(.{ .addr = addr, .weight = weight, .sockaddr = sockaddr });
        }
    }

    // Validation of every addr happens even for weight-0 hosts: any illegal
    // entry fails the whole load, like the Go original.
    const cfg = try a.create(Config);
    cfg.* = .{
        .hosts = try hosts.toOwnedSlice(),
        .weight_sum = weight_sum,
        .refs = 1,
        .arena = arena,
    };
    return cfg;
}

/// Weighted random selection: draw uniform r in [0, weight_sum), then walk
/// cumulative weights. Returns null when no backend is usable
/// (weight_sum <= 0). Weight-0 hosts are never selected.
pub fn chooseHost(hosts: []const Host, weight_sum: i64, random: std.Random) ?usize {
    if (weight_sum <= 0) return null;
    const target = random.uintLessThan(u64, @intCast(weight_sum));
    var cumulative: u64 = 0;
    for (hosts, 0..) |h, i| {
        if (h.weight <= 0) continue;
        cumulative += @intCast(h.weight);
        if (target < cumulative) return i;
    }
    // Unreachable in theory; mirrors the Go fallback.
    return if (hosts.len > 0) hosts.len - 1 else null;
}

// ============================== tests ==============================

const testing = std.testing;

test "parse valid config" {
    const cfg = try parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:8001","weight":100},{"addr":"10.0.0.2:80","weight":50}]}
    );
    defer cfg.destroy();
    try testing.expectEqual(@as(usize, 2), cfg.hosts.len);
    try testing.expectEqualStrings("127.0.0.1:8001", cfg.hosts[0].addr);
    try testing.expectEqual(@as(i64, 100), cfg.hosts[0].weight);
    try testing.expectEqual(@as(i64, 150), cfg.weight_sum);
    try testing.expect(cfg.hosts[0].sockaddr != null);
    try testing.expectEqual(@as(u16, 8001), cfg.hosts[0].sockaddr.?.port());
}

test "parse accepts Go-style capitalized keys" {
    // The reference settings.conf uses "Hosts"/"Addr"/"Weight".
    const cfg = try parse(testing.allocator,
        \\{"Hosts":[{"Addr":"127.0.0.1:80","Weight":100}]}
    );
    defer cfg.destroy();
    try testing.expectEqual(@as(usize, 1), cfg.hosts.len);
    try testing.expectEqual(@as(i64, 100), cfg.weight_sum);
}

test "invalid addresses fail the whole load" {
    const cases = [_][]const u8{
        \\{"hosts":[{"addr":"no-colon-here","weight":1}]}
    ,
        \\{"hosts":[{"addr":"127.0.0.1:99999","weight":1}]}
    ,
        \\{"hosts":[{"addr":"127.0.0.1:abc","weight":1}]}
    ,
        \\{"hosts":[{"addr":"127.0.0.1:","weight":1}]}
    ,
        \\{"hosts":[{"addr":"::1:80","weight":1}]}
    , // unbracketed IPv6
        \\{"hosts":[{"addr":"[::1:80","weight":1}]}
    , // missing ']'
        \\{"hosts":[{"weight":1}]}
    , // missing addr
    };
    for (cases) |c| {
        if (parse(testing.allocator, c)) |cfg| {
            cfg.destroy();
            return error.TestUnexpectedResult; // should have failed
        } else |_| {}
    }
}

test "negative weight fails the whole load" {
    const r = parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:80","weight":-5}]}
    );
    try testing.expectError(error.NegativeWeight, r);
}

test "empty hosts loads with weight_sum 0 and no selection" {
    const cfg = try parse(testing.allocator,
        \\{"hosts":[]}
    );
    defer cfg.destroy();
    try testing.expectEqual(@as(i64, 0), cfg.weight_sum);
    var prng = std.Random.DefaultPrng.init(42);
    try testing.expectEqual(@as(?usize, null), chooseHost(cfg.hosts, cfg.weight_sum, prng.random()));
}

test "all-zero weights load but select nothing" {
    const cfg = try parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:1","weight":0},{"addr":"127.0.0.1:2","weight":0}]}
    );
    defer cfg.destroy();
    try testing.expectEqual(@as(i64, 0), cfg.weight_sum);
    var prng = std.Random.DefaultPrng.init(7);
    for (0..1000) |_| {
        try testing.expectEqual(@as(?usize, null), chooseHost(cfg.hosts, cfg.weight_sum, prng.random()));
    }
}

test "non-integer weight is rejected" {
    const r = parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:80","weight":1.5}]}
    );
    try testing.expectError(error.InvalidWeight, r);
}

test "weighted choice hits 1:2 ratio over 100k draws" {
    const hosts = [_]Host{
        .{ .addr = "a:1", .weight = 1, .sockaddr = null },
        .{ .addr = "b:2", .weight = 2, .sockaddr = null },
    };
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    var counts = [_]u64{ 0, 0 };
    const n = 100_000;
    for (0..n) |_| {
        const i = chooseHost(&hosts, 3, prng.random()).?;
        counts[i] += 1;
    }
    // Expected 1/3 and 2/3; allow generous but meaningful slack.
    try testing.expect(counts[0] > 31_000 and counts[0] < 35_667);
    try testing.expect(counts[1] > 64_333 and counts[1] < 69_000);
    try testing.expectEqual(@as(u64, n), counts[0] + counts[1]);
}

test "weight-0 host is never selected" {
    const hosts = [_]Host{
        .{ .addr = "a:1", .weight = 1, .sockaddr = null },
        .{ .addr = "dead:0", .weight = 0, .sockaddr = null },
        .{ .addr = "c:3", .weight = 2, .sockaddr = null },
    };
    var prng = std.Random.DefaultPrng.init(0xBEEF);
    for (0..100_000) |_| {
        const i = chooseHost(&hosts, 3, prng.random()).?;
        try testing.expect(i != 1);
    }
}

test "single host is always selected" {
    const hosts = [_]Host{.{ .addr = "only:1", .weight = 7, .sockaddr = null }};
    var prng = std.Random.DefaultPrng.init(1);
    for (0..1000) |_| {
        try testing.expectEqual(@as(?usize, 0), chooseHost(&hosts, 7, prng.random()));
    }
}

test "splitHostPort" {
    const hp1 = try sys.splitHostPort("127.0.0.1:80");
    try testing.expectEqualStrings("127.0.0.1", hp1.host);
    try testing.expectEqual(@as(u16, 80), hp1.port);

    const hp2 = try sys.splitHostPort(":1248");
    try testing.expectEqualStrings("", hp2.host);
    try testing.expectEqual(@as(u16, 1248), hp2.port);

    const hp3 = try sys.splitHostPort("[::1]:8080");
    try testing.expectEqualStrings("::1", hp3.host);
    try testing.expectEqual(@as(u16, 8080), hp3.port);

    try testing.expectError(error.MissingPort, sys.splitHostPort("host"));
    try testing.expectError(error.TooManyColons, sys.splitHostPort("a:b:c"));
    try testing.expectError(error.MissingBracket, sys.splitHostPort("[::1"));
    try testing.expectError(error.EmptyPort, sys.splitHostPort("host:"));
    try testing.expectError(error.InvalidPort, sys.splitHostPort("host:99999"));
    try testing.expectError(error.InvalidPort, sys.splitHostPort("host:http"));
}

test "ip literal parsers" {
    try testing.expectEqual([4]u8{ 127, 0, 0, 1 }, sys.parseIp4("127.0.0.1").?);
    try testing.expectEqual(@as(?[4]u8, null), sys.parseIp4("256.0.0.1"));
    try testing.expectEqual(@as(?[4]u8, null), sys.parseIp4("1.2.3"));
    try testing.expectEqual(@as(?[4]u8, null), sys.parseIp4("01.2.3.4"));

    const loop6 = sys.parseIp6("::1").?;
    try testing.expectEqual([16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, loop6);
    const mapped = sys.parseIp6("::ffff:127.0.0.1").?;
    try testing.expectEqual([16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1 }, mapped);
    _ = sys.parseIp6("fe80::a:b:c:d:e").?;
    try testing.expectEqual(@as(?[16]u8, null), sys.parseIp6("1::2::3"));
    try testing.expectEqual(@as(?[16]u8, null), sys.parseIp6("1:2:3:4:5:6:7")); // too short
    try testing.expectEqual(@as(?[16]u8, null), sys.parseIp6("1:2:3:4:5:6:7:8:9")); // too long
}
