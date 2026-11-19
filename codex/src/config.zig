const std = @import("std");
const sys = @import("sys.zig");

const Allocator = std.mem.Allocator;

const Host = struct {
    addresses: []const sys.Address,
    weight: i64,
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    hosts: []const Host,
    total_weight: i64,

    pub fn load(allocator: Allocator, io: std.Io, path: []const u8) !Config {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(text);
        return parse(allocator, text);
    }

    pub fn parse(allocator: Allocator, text: []const u8) !Config {
        const json = try std.json.parseFromSlice(std.json.Value, allocator, text, .{
            .duplicate_field_behavior = .use_last,
        });
        defer json.deinit();
        const root = switch (json.value) {
            .object => |object| object,
            else => return error.InvalidConfig,
        };

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const memory = arena.allocator();
        const values: []const std.json.Value = switch (field(root, "hosts")) {
            .array => |array| array.items,
            .null => &.{},
            else => return error.InvalidHosts,
        };
        const hosts = try memory.alloc(Host, values.len);
        var total_weight: i64 = 0;
        for (hosts, values) |*host, value| {
            const object = switch (value) {
                .object => |object| object,
                else => return error.InvalidHost,
            };
            const address = switch (field(object, "addr")) {
                .string => |address| address,
                else => return error.InvalidHost,
            };
            const weight = switch (field(object, "weight")) {
                .integer => |integer| integer,
                .null => 0,
                else => return error.InvalidWeight,
            };
            if (weight < 0) return error.InvalidWeight;
            total_weight = std.math.add(i64, total_weight, weight) catch return error.WeightOverflow;
            const addresses: []const sys.Address = if (weight == 0) disabled: {
                _ = try sys.splitAddress(address, false);
                break :disabled &.{};
            } else try sys.resolve(memory, address, false);
            host.* = .{ .addresses = addresses, .weight = weight };
        }
        return .{ .arena = arena, .hosts = hosts, .total_weight = total_weight };
    }

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }

    pub fn choose(self: *const Config, random: std.Random) ?[]const sys.Address {
        if (self.total_weight == 0) return null;
        var pick = random.intRangeLessThan(i64, 0, self.total_weight);
        for (self.hosts) |host| {
            if (pick < host.weight) return host.addresses;
            pick -= host.weight;
        }
        unreachable;
    }
};

fn field(object: std.json.ObjectMap, name: []const u8) std.json.Value {
    var result: std.json.Value = .null;
    for (object.keys(), object.values()) |key, value| {
        if (std.ascii.eqlIgnoreCase(key, name)) result = value;
    }
    return result;
}

test "configuration accepts case-insensitive keys and excludes zero weight from selection" {
    const testing = std.testing;
    var cfg = try Config.parse(testing.allocator,
        \\{"HOSTS":[{"Addr":"127.0.0.1:9001","Weight":1},
        \\          {"addr":"127.0.0.1:9002","weight":2},
        \\          {"addr":"127.0.0.1:9003","weight":0}]}
    );
    defer cfg.deinit();

    var prng = std.Random.DefaultPrng.init(42);
    const samples = 100_000;
    var first: usize = 0;
    for (0..samples) |_| {
        const selected = cfg.choose(prng.random()).?;
        if (selected.ptr == cfg.hosts[0].addresses.ptr) {
            first += 1;
        } else {
            try testing.expect(selected.ptr == cfg.hosts[1].addresses.ptr);
        }
    }
    try testing.expect(first > 32_000 and first < 35_000);
}

test "empty and zero-weight configurations return no backend" {
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(42);
    for ([_][]const u8{
        "{}",
        "{\"hosts\":[]}",
        "{\"hosts\":[{\"addr\":\"disabled.invalid:9001\",\"weight\":0}]}",
    }) |text| {
        var cfg = try Config.parse(testing.allocator, text);
        defer cfg.deinit();
        try testing.expect(cfg.choose(prng.random()) == null);
    }
}

test "configuration rejects invalid hosts, negative weights, and overflow" {
    const testing = std.testing;
    try testing.expectError(error.InvalidHost, Config.parse(testing.allocator,
        \\{"hosts":[{"addr":1,"weight":1}]}
    ));
    try testing.expectError(error.InvalidAddress, Config.parse(testing.allocator,
        \\{"hosts":[{"addr":"no-port","weight":1}]}
    ));
    try testing.expectError(error.InvalidWeight, Config.parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:9001","weight":-1}]}
    ));
    try testing.expectError(error.InvalidAddress, Config.parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1","weight":1}]}
    ));
    try testing.expectError(error.WeightOverflow, Config.parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:9001","weight":9223372036854775807},
        \\          {"addr":"127.0.0.1:9002","weight":1}]}
    ));
}
