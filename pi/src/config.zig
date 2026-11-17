//! Backend configuration: typed JSON parse, validation, weighted random selection.
//! Config owns memory in a private arena and is reference-counted for hot reload.

const std = @import("std");
const sys = @import("sys.zig");

pub const Host = struct {
    addr: []const u8,
    weight: i64,
    /// Pre-resolved for IP literals / localhost; null if dial-time resolve needed.
    sockaddr: ?sys.SockAddr,
};

pub const Config = struct {
    hosts: []Host,
    weight_sum: i64,
    refs: usize,
    arena: std.heap.ArenaAllocator,

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

const FileHost = struct {
    addr: []const u8,
    weight: i64 = 0,
};

const FileRoot = struct {
    hosts: []FileHost = &.{},
};

fn mapJsonErr(err: anyerror) ParseError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.MissingField => error.MissingAddr,
        error.UnexpectedToken, error.InvalidNumber, error.Overflow => error.InvalidWeight,
        error.UnknownField, error.DuplicateField, error.LengthMismatch => error.InvalidStructure,
        else => error.InvalidJson,
    };
}

/// Parse `{"hosts":[{"addr":"host:port","weight":100}]}` (lowercase keys only).
/// Missing `weight` defaults to 0. Returns a heap-owned Config with refs == 1.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) ParseError!*Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const draft = std.json.parseFromSliceLeaky(FileRoot, a, text, .{
        .allocate = .alloc_always,
    }) catch |e| return mapJsonErr(e);

    var hosts = std.array_list.Managed(Host).init(a);
    var weight_sum: i64 = 0;

    for (draft.hosts) |h| {
        const hp = sys.splitHostPort(h.addr) catch return error.InvalidAddr;
        const sockaddr: ?sys.SockAddr = sys.resolveDial(hp.host, hp.port) catch null;
        if (h.weight < 0) return error.NegativeWeight;
        weight_sum = std.math.add(i64, weight_sum, h.weight) catch return error.WeightOverflow;
        try hosts.append(.{
            .addr = h.addr,
            .weight = h.weight,
            .sockaddr = sockaddr,
        });
    }

    const cfg = try a.create(Config);
    cfg.* = .{
        .hosts = try hosts.toOwnedSlice(),
        .weight_sum = weight_sum,
        .refs = 1,
        .arena = arena,
    };
    return cfg;
}

/// Weighted random selection in `[0, weight_sum)`. Null when `weight_sum <= 0`.
pub fn chooseHost(hosts: []const Host, weight_sum: i64, random: std.Random) ?usize {
    if (weight_sum <= 0) return null;
    const target = random.uintLessThan(u64, @intCast(weight_sum));
    var cumulative: u64 = 0;
    for (hosts, 0..) |h, i| {
        if (h.weight <= 0) continue;
        cumulative += @intCast(h.weight);
        if (target < cumulative) return i;
    }
    return if (hosts.len > 0) hosts.len - 1 else null;
}

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

test "parse rejects capitalized keys" {
    try testing.expectError(error.InvalidStructure, parse(testing.allocator,
        \\{"Hosts":[{"Addr":"127.0.0.1:80","Weight":100}]}
    ));
}

test "missing weight defaults to zero" {
    const cfg = try parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:80"}]}
    );
    defer cfg.destroy();
    try testing.expectEqual(@as(i64, 0), cfg.hosts[0].weight);
    try testing.expectEqual(@as(i64, 0), cfg.weight_sum);
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
        ,
        \\{"hosts":[{"addr":"[::1:80","weight":1}]}
        ,
        \\{"hosts":[{"weight":1}]}
        ,
    };
    for (cases) |c| {
        if (parse(testing.allocator, c)) |cfg| {
            cfg.destroy();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "negative weight fails the whole load" {
    try testing.expectError(error.NegativeWeight, parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:80","weight":-5}]}
    ));
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
    try testing.expectError(error.InvalidWeight, parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:80","weight":1.5}]}
    ));
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
    try testing.expectEqual(@as(?[16]u8, null), sys.parseIp6("1:2:3:4:5:6:7"));
    try testing.expectEqual(@as(?[16]u8, null), sys.parseIp6("1:2:3:4:5:6:7:8:9"));
}
