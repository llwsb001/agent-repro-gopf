//! JSON configuration loading and validation.
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const max_addr_len = 255;

pub const Host = struct {
    addr: []const u8,
    weight: i64,
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    hosts: []const Host,
    weight_sum: i64,

    const RawHost = struct {
        addr: []const u8,
        weight: i64 = 0,
    };

    const RawConfig = struct {
        hosts: []const RawHost = &.{},
    };

    /// Parse and validate a configuration document. The returned Config owns all
    /// of its strings through an internal arena; call deinit when done.
    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Config {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const raw = try std.json.parseFromSliceLeaky(RawConfig, a, bytes, .{
            .ignore_unknown_fields = true,
            // Always copy strings into our arena: callers are allowed to free
            // the JSON input as soon as parse returns.
            .allocate = .alloc_always,
        });

        const hosts = try a.alloc(Host, raw.hosts.len);
        var sum: i64 = 0;
        for (raw.hosts, 0..) |rh, i| {
            if (rh.weight < 0) return error.NegativeWeight;
            if (rh.addr.len > max_addr_len) return error.AddressTooLong;
            _ = try splitHostPort(rh.addr);
            sum = std.math.add(i64, sum, rh.weight) catch return error.WeightOverflow;
            hosts[i] = .{ .addr = rh.addr, .weight = rh.weight };
        }

        return .{ .arena = arena, .hosts = hosts, .weight_sum = sum };
    }

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
        const bytes = try readFileAlloc(allocator, path, 16 * 1024 * 1024);
        defer allocator.free(bytes);
        return parse(allocator, bytes);
    }

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const HostPort = struct {
    host: []const u8,
    port: u16,
};

/// Splits "host:port" or "[ipv6]:port". The host may be empty (":80"), which
/// means the unspecified address for listeners / loopback for dialing.
pub fn splitHostPort(s: []const u8) error{InvalidAddress}!HostPort {
    if (s.len == 0) return error.InvalidAddress;
    if (s[0] == '[') {
        const end = std.mem.indexOfScalar(u8, s, ']') orelse return error.InvalidAddress;
        if (end + 1 >= s.len or s[end + 1] != ':') return error.InvalidAddress;
        const host = s[1..end];
        if (host.len == 0) return error.InvalidAddress;
        const port = parsePort(s[end + 2 ..]) orelse return error.InvalidAddress;
        return .{ .host = host, .port = port };
    }
    const idx = std.mem.lastIndexOfScalar(u8, s, ':') orelse return error.InvalidAddress;
    const port = parsePort(s[idx + 1 ..]) orelse return error.InvalidAddress;
    return .{ .host = s[0..idx], .port = port };
}

fn parsePort(s: []const u8) ?u16 {
    if (s.len == 0) return null;
    return std.fmt.parseInt(u16, s, 10) catch null;
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_len: usize) ![]u8 {
    const fd = try posix.openat(posix.AT.FDCWD, path, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
    }, 0);
    defer _ = linux.close(fd);

    var list = std.array_list.Managed(u8).init(allocator);
    errdefer list.deinit();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try posix.read(fd, &buf);
        if (n == 0) break;
        if (list.items.len + n > max_len) return error.ConfigTooLarge;
        try list.appendSlice(buf[0..n]);
    }
    return list.toOwnedSlice();
}
