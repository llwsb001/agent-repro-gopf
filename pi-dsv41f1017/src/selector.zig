//! Weighted random selection. Mirrors the Go reference: draw
//! r in [0, weightSum), then walk cumulative weights until r < cumulative.
//! Zero-weight hosts are naturally never selected.

const std = @import("std");
const config = @import("config.zig");

pub fn choose(rand: std.Random, hosts: []const config.Host, weight_sum: i64) ?usize {
    if (weight_sum <= 0) return null;
    const r = rand.intRangeLessThan(i64, 0, weight_sum);
    var cumulative: i64 = 0;
    for (hosts, 0..) |h, i| {
        cumulative += h.weight;
        if (r < cumulative) return i;
    }
    if (hosts.len > 0) return hosts.len - 1;
    return null;
}

const TestCtx = struct {
    hosts: [3]config.Host = undefined,
    sum: i64 = 0,
};

test "weight sum <= 0 selects nothing" {
    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();
    const hosts = [_]config.Host{
        .{ .addr = "127.0.0.1:1", .weight = 0 },
    };
    try std.testing.expectEqual(@as(?usize, null), choose(rand, &hosts, 0));
    try std.testing.expectEqual(@as(?usize, null), choose(rand, &hosts, -1));
    try std.testing.expectEqual(@as(?usize, null), choose(rand, &.{}, 0));
}

test "1:2 weights stay in the expected band over 100k draws" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    const hosts = [_]config.Host{
        .{ .addr = "127.0.0.1:1", .weight = 1 },
        .{ .addr = "127.0.0.1:2", .weight = 2 },
    };
    var counts = [_]usize{ 0, 0 };
    const n = 100_000;
    for (0..n) |_| counts[choose(rand, &hosts, 3).?] += 1;
    try std.testing.expectEqual(n, counts[0] + counts[1]);
    const share0 = @as(f64, @floatFromInt(counts[0])) / @as(f64, n);
    const share1 = @as(f64, @floatFromInt(counts[1])) / @as(f64, n);
    // Expected 1/3 and 2/3; bands are deliberately wide, and 1:2 is
    // statistically impossible to confuse with uniform 1:1.
    try std.testing.expect(share0 > 1.0 / 3.0 - 0.01 and share0 < 1.0 / 3.0 + 0.01);
    try std.testing.expect(share1 > 2.0 / 3.0 - 0.01 and share1 < 2.0 / 3.0 + 0.01);
}

test "zero-weight hosts are never selected" {
    var prng = std.Random.DefaultPrng.init(9);
    const rand = prng.random();
    const hosts = [_]config.Host{
        .{ .addr = "a:1", .weight = 0 },
        .{ .addr = "b:2", .weight = 4 },
        .{ .addr = "c:3", .weight = 0 },
    };
    for (0..100_000) |_| {
        try std.testing.expectEqual(@as(?usize, 1), choose(rand, &hosts, 4));
    }
}

test "zero weight between two positive hosts" {
    var prng = std.Random.DefaultPrng.init(11);
    const rand = prng.random();
    const hosts = [_]config.Host{
        .{ .addr = "a:1", .weight = 3 },
        .{ .addr = "b:2", .weight = 0 },
        .{ .addr = "c:3", .weight = 3 },
    };
    var counts = [_]usize{ 0, 0, 0 };
    for (0..20_000) |_| counts[choose(rand, &hosts, 6).?] += 1;
    try std.testing.expectEqual(@as(usize, 0), counts[1]);
    try std.testing.expect(counts[0] > 9000 and counts[0] < 11000);
    try std.testing.expect(counts[2] > 9000 and counts[2] < 11000);
}