//! Typed JSON config parse + weighted random selection (lowercase keys only).

const std = @import("std");
const zio = @import("zio");

pub const Host = struct {
    addr: []const u8,
    weight: i64,
    /// Parsed at load; dial uses this (IP literals / bracketed IPv6 only).
    endpoint: zio.net.IpAddress,
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
        const endpoint = zio.net.IpAddress.parseIpAndPort(h.addr) catch return error.InvalidAddr;
        if (h.weight < 0) return error.NegativeWeight;
        weight_sum = std.math.add(i64, weight_sum, h.weight) catch return error.WeightOverflow;
        try hosts.append(.{ .addr = h.addr, .weight = h.weight, .endpoint = endpoint });
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
