const std = @import("std");

pub const Host = struct {
    addr: []const u8,
    weight: u32,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    hosts: []Host,
    weight_sum: u64,

    pub fn deinit(self: *Config) void {
        for (self.hosts) |host| self.allocator.free(host.addr);
        self.allocator.free(self.hosts);
        self.* = undefined;
    }
};

pub const HostPort = struct {
    host: []const u8,
    port: u16,
};

pub const ParseError = error{
    InvalidRoot,
    InvalidHosts,
    InvalidHost,
    MissingAddr,
    InvalidAddr,
    InvalidWeight,
    NegativeWeight,
    WeightOverflow,
    OutOfMemory,
} || std.json.ParseError(std.json.Scanner) || std.mem.Allocator.Error;

pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!Config {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    return parseValue(allocator, parsed.value);
}

pub fn parseValue(allocator: std.mem.Allocator, root: std.json.Value) ParseError!Config {
    if (root != .object) return error.InvalidRoot;

    const hosts_value = objectField(root.object, "hosts") orelse {
        return .{ .allocator = allocator, .hosts = try allocator.alloc(Host, 0), .weight_sum = 0 };
    };
    if (hosts_value != .array) return error.InvalidHosts;

    var hosts: std.ArrayList(Host) = .empty;
    errdefer {
        for (hosts.items) |host| allocator.free(host.addr);
        hosts.deinit(allocator);
    }

    var weight_sum: u64 = 0;
    for (hosts_value.array.items) |host_value| {
        if (host_value != .object) return error.InvalidHost;

        const addr_value = objectField(host_value.object, "addr") orelse return error.MissingAddr;
        if (addr_value != .string or addr_value.string.len == 0) return error.InvalidAddr;
        _ = try splitHostPort(addr_value.string);

        var weight: u32 = 0;
        if (objectField(host_value.object, "weight")) |weight_value| {
            if (weight_value != .integer) return error.InvalidWeight;
            if (weight_value.integer < 0) return error.NegativeWeight;
            weight = std.math.cast(u32, weight_value.integer) orelse return error.InvalidWeight;
        }

        weight_sum = std.math.add(u64, weight_sum, weight) catch return error.WeightOverflow;
        const addr = try allocator.dupe(u8, addr_value.string);
        errdefer allocator.free(addr);
        try hosts.append(allocator, .{ .addr = addr, .weight = weight });
    }

    return .{
        .allocator = allocator,
        .hosts = try hosts.toOwnedSlice(allocator),
        .weight_sum = weight_sum,
    };
}

pub fn loadFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !Config {
    const text = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(text);
    return parse(allocator, text);
}

pub fn splitHostPort(addr: []const u8) !HostPort {
    if (addr.len == 0) return error.InvalidAddr;

    var host: []const u8 = undefined;
    var port_text: []const u8 = undefined;

    if (addr[0] == '[') {
        const close = std.mem.findScalar(u8, addr, ']') orelse return error.InvalidAddr;
        if (close <= 1 or close + 1 >= addr.len or addr[close + 1] != ':') {
            return error.InvalidAddr;
        }
        host = addr[1..close];
        port_text = addr[close + 2 ..];
    } else {
        const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse return error.InvalidAddr;
        if (std.mem.findScalar(u8, addr[0..colon], ':')) |_| return error.InvalidAddr;
        host = addr[0..colon];
        port_text = addr[colon + 1 ..];
    }

    if (port_text.len == 0) return error.InvalidAddr;
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidAddr;
    return .{ .host = host, .port = port };
}

pub fn chooseIndex(config: *const Config, random: std.Random) ?usize {
    if (config.weight_sum == 0) return null;
    const pick = random.uintLessThan(u64, config.weight_sum);

    var cumulative: u64 = 0;
    for (config.hosts, 0..) |host, index| {
        cumulative += host.weight;
        if (pick < cumulative) return index;
    }
    return if (config.hosts.len == 0) null else config.hosts.len - 1;
}

fn objectField(object: std.json.ObjectMap, name: []const u8) ?std.json.Value {
    var it = object.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return entry.value_ptr.*;
    }
    return null;
}

test "valid config, empty hosts, and all-zero weights" {
    const allocator = std.testing.allocator;

    var config = try parse(allocator,
        \\{"hosts":[{"addr":"127.0.0.1:9001","weight":3},{"addr":"[::1]:9002","weight":0}]}
    );
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 2), config.hosts.len);
    try std.testing.expectEqual(@as(u64, 3), config.weight_sum);
    try std.testing.expectEqual(@as(u16, 9002), (try splitHostPort(config.hosts[1].addr)).port);

    var empty = try parse(allocator, "{\"hosts\":[]}");
    defer empty.deinit();
    try std.testing.expectEqual(@as(u64, 0), empty.weight_sum);
    var empty_prng = std.Random.DefaultPrng.init(1);
    try std.testing.expect(chooseIndex(&empty, empty_prng.random()) == null);

    var zero = try parse(allocator,
        \\{"hosts":[{"addr":"127.0.0.1:9001","weight":0}]}
    );
    defer zero.deinit();
    try std.testing.expectEqual(@as(u64, 0), zero.weight_sum);
    var zero_prng = std.Random.DefaultPrng.init(2);
    try std.testing.expect(chooseIndex(&zero, zero_prng.random()) == null);
}

test "invalid addresses and negative weights fail the whole load" {
    const allocator = std.testing.allocator;
    const invalid_addresses = [_][]const u8{
        \\{"hosts":[{"addr":"127.0.0.1","weight":1}]}
        ,
        \\{"hosts":[{"addr":"127.0.0.1:notaport","weight":1}]}
        ,
        \\{"hosts":[{"addr":"127.0.0.1:70000","weight":1}]}
        ,
        \\{"hosts":[{"addr":"::1:9000","weight":1}]}
        ,
    };
    for (invalid_addresses) |text| {
        try std.testing.expectError(error.InvalidAddr, parse(allocator, text));
    }

    try std.testing.expectError(
        error.NegativeWeight,
        parse(allocator, "{\"hosts\":[{\"addr\":\"127.0.0.1:1\",\"weight\":-1}]}"),
    );
}

test "weighted selection is random with the requested proportions" {
    const allocator = std.testing.allocator;
    var config = try parse(allocator,
        \\{"hosts":[{"addr":"127.0.0.1:1","weight":1},{"addr":"127.0.0.1:2","weight":2},{"addr":"127.0.0.1:3","weight":0}]}
    );
    defer config.deinit();

    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    var counts = [_]usize{ 0, 0, 0 };
    for (0..100_000) |_| {
        const selected = chooseIndex(&config, random).?;
        counts[selected] += 1;
    }

    try std.testing.expectEqual(@as(usize, 0), counts[2]);
    try std.testing.expect(counts[0] > 25_000 and counts[0] < 42_000);
    try std.testing.expect(counts[1] > 58_000 and counts[1] < 75_000);
}
