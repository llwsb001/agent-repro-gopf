const std = @import("std");
const testing = std.testing;
const config = @import("config.zig");

// Pull in tests defined next to the code they exercise.
test {
    _ = @import("dial.zig");
    _ = @import("selector.zig");
    _ = @import("proxy.zig");
}

test "valid config with comments-free reference style keys" {
    const text =
        \\{"traffic_url":"ignored","Hosts":[{"Addr":"127.0.0.1:8080","Weight":100},{"addr":"[::1]:9090","weight":50}]}
    ;
    var cfg = try config.parse(testing.allocator, text);
    defer cfg.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), cfg.hosts.len);
    try testing.expectEqualStrings("127.0.0.1:8080", cfg.hosts[0].addr);
    try testing.expectEqual(@as(i64, 150), cfg.weight_sum);
}

test "empty hosts is valid and has no usable backend" {
    var cfg = try config.parse(testing.allocator, "{\"hosts\":[]}");
    defer cfg.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), cfg.hosts.len);
    try testing.expectEqual(@as(i64, 0), cfg.weight_sum);
}

test "all-zero weights is valid but sums to zero" {
    var cfg = try config.parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:1","weight":0},{"addr":"127.0.0.1:2","weight":0}]}
    );
    defer cfg.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 0), cfg.weight_sum);
}

test "invalid address rejects the whole config" {
    const cases = [_][]const u8{
        \\{"hosts":[{"addr":"127.0.0.1","weight":1}]}
        ,
        \\{"hosts":[{"addr":"a:b:c","weight":1}]}
        ,
        \\{"hosts":[{"addr":"127.0.0.1:99999","weight":1}]}
        ,
        \\{"hosts":[{"addr":"127.0.0.1:","weight":1}]}
        ,
        \\{"hosts":[{"weight":1}]}
        ,
    };
    for (cases) |text| {
        if (config.parse(testing.allocator, text)) |cfg_value| {
            var cfg = cfg_value;
            cfg.deinit(testing.allocator);
            return error.TestExpectedError;
        } else |_| {}
    }
}

test "negative weight rejects the whole config" {
    try testing.expectError(error.NegativeWeight, config.parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:1","weight":5},{"addr":"127.0.0.1:2","weight":-1}]}
    ));
}

test "malformed json and wrong shapes are rejected" {
    try testing.expectError(error.InvalidJson, config.parse(testing.allocator, "{not json"));
    try testing.expectError(error.InvalidConfig, config.parse(testing.allocator, "{\"hosts\":{}}"));
    try testing.expectError(error.InvalidConfig, config.parse(testing.allocator, "{\"hosts\":[1]}"));
}

test "status snapshot copies config safely" {
    var store = config.Store.init();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    defer store.clear(testing.allocator, io);

    const cfg = try testing.allocator.create(config.Config);
    cfg.* = try config.parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:1","weight":1},{"addr":"127.0.0.1:2","weight":2}]}
    );
    store.swap(testing.allocator, io, cfg);

    var snap = (try store.snapshot(testing.allocator, io)).?;
    defer snap.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), snap.hosts.len);
    try testing.expectEqual(@as(i64, 3), snap.weight_sum);
    try testing.expectEqualStrings("127.0.0.1:2", snap.hosts[1].addr);
}