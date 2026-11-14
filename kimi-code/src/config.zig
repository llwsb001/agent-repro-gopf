//! Backend configuration: JSON parsing, validation, and a thread-safe
//! holder that supports hot reload (the SIGHUP path swaps configs).
//!
//! Config JSON looks like the Go reference implementation:
//!   {"hosts":[{"addr":"host:port","weight":100}]}
//! Keys are matched case-insensitively, mirroring Go's encoding/json, so the
//! reference "Hosts"/"Addr"/"Weight" style works too. Unknown keys are
//! ignored (e.g. the reference's "traffic_url").

const std = @import("std");
const Allocator = std.mem.Allocator;
const dial = @import("dial.zig");

pub const Host = struct {
    /// Owned by the Config; valid while the Config is alive.
    addr: []const u8,
    weight: i64,
};

pub const Config = struct {
    hosts: []Host,
    weight_sum: i64,

    pub fn deinit(self: *Config, gpa: Allocator) void {
        for (self.hosts) |h| gpa.free(h.addr);
        gpa.free(self.hosts);
    }

    pub fn hostCount(self: *const Config) usize {
        return self.hosts.len;
    }
};

pub const ParseError = error{
    InvalidJson,
    InvalidConfig,
    InvalidAddress,
    NegativeWeight,
    OutOfMemory,
};

/// Parse and validate config JSON text. The returned Config owns its host
/// addr strings (duped from the parse tree, whose lifetime is internal).
/// Any invalid entry fails the whole parse, mirroring the Go version.
pub fn parse(gpa: Allocator, text: []const u8) ParseError!Config {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidJson,
    };

    var hosts_value: ?std.json.Value = null;
    var it = root.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "hosts")) {
            hosts_value = entry.value_ptr.*;
        }
    }

    if (hosts_value == null) {
        // No "hosts" key: valid JSON but no backends, like an empty list in Go.
        return .{ .hosts = &.{}, .weight_sum = 0 };
    }

    const arr = switch (hosts_value.?) {
        .array => |a| a,
        else => return error.InvalidConfig,
    };
    const list = try gpa.alloc(Host, arr.items.len);
    errdefer gpa.free(list);
    var duped: usize = 0;
    errdefer for (list[0..duped]) |h| gpa.free(h.addr);

    var weight_sum: i64 = 0;
    for (arr.items, 0..) |item, i| {
        const obj = switch (item) {
            .object => |o| o,
            else => return error.InvalidConfig,
        };
        var addr: ?[]const u8 = null;
        var weight: i64 = 0;
        var oit = obj.iterator();
        while (oit.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "addr")) {
                addr = switch (entry.value_ptr.*) {
                    .string => |s| s,
                    else => return error.InvalidConfig,
                };
            } else if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "weight")) {
                weight = switch (entry.value_ptr.*) {
                    .integer => |w| w,
                    .number_string => |s| std.fmt.parseInt(i64, s, 10) catch
                        return error.InvalidConfig,
                    else => return error.InvalidConfig,
                };
            }
        }
        const a = addr orelse return error.InvalidAddress;
        // The address must split into host:port.
        _ = dial.splitHostPort(a) catch return error.InvalidAddress;
        if (weight < 0) return error.NegativeWeight;
        weight_sum += weight;
        list[i] = .{ .addr = try gpa.dupe(u8, a), .weight = weight };
        duped += 1;
    }
    return .{ .hosts = list, .weight_sum = weight_sum };
}

/// Load and validate the config file at `path`. Fully self-contained: does
/// not touch the shared store, so it is safe to call from any thread.
pub fn loadFromFile(gpa: Allocator, io: std.Io, path: []const u8) !Config {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited64(64 * 1024 * 1024)) catch |err| {
        return err;
    };
    defer gpa.free(text);
    return parse(gpa, text);
}

/// Thread-safe holder for the active configuration. The lock is held only
/// long enough to copy what a caller needs, so a reload may free the old
/// config immediately after the swap. (A plain mutex rather than an RwLock:
/// critical sections here are a few nanoseconds.)
pub const Store = struct {
    lock: std.Io.Mutex = .init,
    current: ?*Config = null,

    pub fn init() Store {
        return .{};
    }

    /// Swap in a new config, freeing the old one. Takes ownership of `new_cfg`.
    pub fn swap(self: *Store, gpa: Allocator, io: std.Io, new_cfg: *Config) void {
        self.lock.lockUncancelable(io);
        const old = self.current;
        self.current = new_cfg;
        self.lock.unlock(io);
        if (old) |o| {
            o.deinit(gpa);
            gpa.destroy(o);
        }
    }

    /// Drop the current config, if any, freeing its memory.
    pub fn clear(self: *Store, gpa: Allocator, io: std.Io) void {
        self.lock.lockUncancelable(io);
        const old = self.current;
        self.current = null;
        self.lock.unlock(io);
        if (old) |o| {
            o.deinit(gpa);
            gpa.destroy(o);
        }
    }

    /// Copy the active config out (addr strings are copied into one buffer).
    /// Used by status printing and tests.
    pub fn snapshot(self: *Store, gpa: Allocator, io: std.Io) error{OutOfMemory}!?Snapshot {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        const cfg = self.current orelse return null;
        const hosts = try gpa.alloc(Host, cfg.hosts.len);
        errdefer gpa.free(hosts);
        var raw_len: usize = 0;
        for (cfg.hosts) |h| raw_len += h.addr.len;
        const buf = try gpa.alloc(u8, raw_len);
        var off: usize = 0;
        for (cfg.hosts, 0..) |h, i| {
            @memcpy(buf[off..][0..h.addr.len], h.addr);
            hosts[i] = .{ .addr = buf[off..][0..h.addr.len], .weight = h.weight };
            off += h.addr.len;
        }
        return .{ .hosts = hosts, .buf = buf, .weight_sum = cfg.weight_sum };
    }

    pub const Snapshot = struct {
        hosts: []Host,
        buf: []u8,
        weight_sum: i64,

        pub fn deinit(self: *Snapshot, gpa: Allocator) void {
            gpa.free(self.hosts);
            gpa.free(self.buf);
        }
    };
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parse valid config" {
    const text =
        \\{"hosts":[{"addr":"127.0.0.1:8080","weight":100},{"addr":"[::1]:9090","weight":50}]}
    ;
    var cfg = try parse(testing.allocator, text);
    defer cfg.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), cfg.hosts.len);
    try testing.expectEqualStrings("127.0.0.1:8080", cfg.hosts[0].addr);
    try testing.expectEqual(@as(i64, 100), cfg.hosts[0].weight);
    try testing.expectEqual(@as(i64, 150), cfg.weight_sum);
}

test "parse reference-style capitalized keys and traffic_url" {
    const text =
        \\{"traffic_url":"ignored","Hosts":[{"Addr":"example.com:80","Weight":100}]}
    ;
    var cfg = try parse(testing.allocator, text);
    defer cfg.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), cfg.hosts.len);
    try testing.expectEqualStrings("example.com:80", cfg.hosts[0].addr);
    try testing.expectEqual(@as(i64, 100), cfg.weight_sum);
}

test "empty hosts is valid but has no backends" {
    var cfg = try parse(testing.allocator, "{\"hosts\":[]}");
    defer cfg.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), cfg.hosts.len);
    try testing.expectEqual(@as(i64, 0), cfg.weight_sum);
}

test "all-zero weights parse fine but sum to zero" {
    var cfg = try parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:1","weight":0},{"addr":"127.0.0.1:2","weight":0}]}
    );
    defer cfg.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), cfg.hosts.len);
    try testing.expectEqual(@as(i64, 0), cfg.weight_sum);
}

test "invalid addresses fail the whole load" {
    const cases = [_][]const u8{
        // missing port
        \\{"hosts":[{"addr":"127.0.0.1","weight":1}]}
        ,
        // too many colons without brackets
        \\{"hosts":[{"addr":"a:b:c","weight":1}]}
        ,
        // port out of range
        \\{"hosts":[{"addr":"127.0.0.1:99999","weight":1}]}
        ,
        // empty port
        \\{"hosts":[{"addr":"127.0.0.1:","weight":1}]}
        ,
        // missing addr entirely
        \\{"hosts":[{"weight":1}]}
    };
    for (cases) |text| {
        if (parse(testing.allocator, text)) |*cfg| {
            var c = cfg.*;
            c.deinit(testing.allocator);
            return error.TestExpectedError;
        } else |_| {}
    }
}

test "negative weight fails the whole load" {
    const text =
        \\{"hosts":[{"addr":"127.0.0.1:80","weight":-5}]}
    ;
    try testing.expectError(error.NegativeWeight, parse(testing.allocator, text));
}

test "non-json input fails" {
    try testing.expectError(error.InvalidJson, parse(testing.allocator, "not json"));
    try testing.expectError(error.InvalidJson, parse(testing.allocator, "[1,2]"));
}

test "store swap replaces config and frees old" {
    var store = Store.init();
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const c1 = try gpa.create(Config);
    c1.* = try parse(gpa, "{\"hosts\":[{\"addr\":\"127.0.0.1:1\",\"weight\":1}]}");
    store.swap(gpa, io, c1);

    {
        var snap = (try store.snapshot(gpa, io)).?;
        defer snap.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), snap.hosts.len);
    }

    const c2 = try gpa.create(Config);
    c2.* = try parse(gpa, "{\"hosts\":[{\"addr\":\"127.0.0.1:2\",\"weight\":2}]}");
    store.swap(gpa, io, c2);

    var snap = (try store.snapshot(gpa, io)).?;
    defer snap.deinit(gpa);
    try testing.expectEqualStrings("127.0.0.1:2", snap.hosts[0].addr);
    try testing.expectEqual(@as(i64, 2), snap.weight_sum);

    store.clear(gpa, io);
}
