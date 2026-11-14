//! Weighted random backend selection, mirroring the Go reference:
//! draw r = rand in [0, weightSum), then walk cumulative weights until
//! r < cumulative. weightSum <= 0 means no usable backend.

const std = @import("std");
const config = @import("config.zig");

/// Pick a backend index by weight. Returns null when no backend is usable
/// (empty host list or non-positive total weight).
pub fn chooseHost(rand: std.Random, hosts: []const config.Host, weight_sum: i64) ?usize {
    if (weight_sum <= 0) return null;

    const r = rand.intRangeLessThan(i64, 0, weight_sum);

    var cumulative: i64 = 0;
    for (hosts, 0..) |host, i| {
        cumulative += host.weight;
        if (r < cumulative) return i;
    }
    // Fallback: cannot happen if weight_sum matches the hosts, but keep the
    // Go behavior of returning the last host rather than crashing.
    if (hosts.len > 0) return hosts.len - 1;
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn mkHosts(weights: []const i64, addrs: []const []const u8, hosts: []config.Host) void {
    for (weights, 0..) |w, i| hosts[i] = .{ .addr = addrs[i], .weight = w };
}

test "weightSum <= 0 yields no backend" {
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    var hosts_buf: [1]config.Host = undefined;
    mkHosts(&.{0}, &.{"127.0.0.1:1"}, &hosts_buf);

    try testing.expectEqual(@as(?usize, null), chooseHost(rand, hosts_buf[0..0], 0));
    try testing.expectEqual(@as(?usize, null), chooseHost(rand, &hosts_buf, 0));
    try testing.expectEqual(@as(?usize, null), chooseHost(rand, &hosts_buf, -3));
}

test "single positive-weight host is always chosen" {
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    var hosts_buf: [1]config.Host = undefined;
    mkHosts(&.{5}, &.{"127.0.0.1:1"}, &hosts_buf);
    for (0..1000) |_| {
        try testing.expectEqual(@as(?usize, 0), chooseHost(rand, &hosts_buf, 5));
    }
}

test "weighted ratio 1:2 over 100k draws lands in the expected band" {
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rand = prng.random();

    var hosts_buf: [2]config.Host = undefined;
    mkHosts(&.{ 1, 2 }, &.{ "127.0.0.1:1", "127.0.0.1:2" }, &hosts_buf);
    const sum: i64 = 3;

    const n = 100_000;
    var counts = [_]usize{ 0, 0 };
    for (0..n) |_| {
        const i = chooseHost(rand, &hosts_buf, sum).?;
        counts[i] += 1;
    }
    try testing.expectEqual(n, counts[0] + counts[1]);

    // Expected shares: 1/3 and 2/3. The binomial standard deviation for
    // 100k draws is ~149; the bands below are far wider (>10 sigma), so a
    // correct weighted implementation passes deterministically regardless of
    // seed, while round-robin-free bugs (e.g. uniform choice at 1/2) fail.
    const share0 = @as(f64, @floatFromInt(counts[0])) / n;
    const share1 = @as(f64, @floatFromInt(counts[1])) / n;
    try testing.expect(share0 > 1.0 / 3.0 - 0.01 and share0 < 1.0 / 3.0 + 0.01);
    try testing.expect(share1 > 2.0 / 3.0 - 0.01 and share1 < 2.0 / 3.0 + 0.01);
}

test "zero-weight backend is never selected" {
    var prng = std.Random.DefaultPrng.init(1234);
    const rand = prng.random();

    var hosts_buf: [3]config.Host = undefined;
    mkHosts(&.{ 0, 5, 0 }, &.{ "a:1", "b:2", "c:3" }, &hosts_buf);
    const sum: i64 = 5;

    for (0..100_000) |_| {
        try testing.expectEqual(@as(?usize, 1), chooseHost(rand, &hosts_buf, sum));
    }
}

test "zero-weight host between weighted hosts splits correctly" {
    var prng = std.Random.DefaultPrng.init(99);
    const rand = prng.random();

    var hosts_buf: [3]config.Host = undefined;
    mkHosts(&.{ 1, 0, 1 }, &.{ "a:1", "b:2", "c:3" }, &hosts_buf);
    const sum: i64 = 2;

    var counts = [_]usize{ 0, 0, 0 };
    for (0..10_000) |_| {
        counts[chooseHost(rand, &hosts_buf, sum).?] += 1;
    }
    try testing.expectEqual(@as(usize, 0), counts[1]);
    try testing.expect(counts[0] > 4500 and counts[0] < 5500);
    try testing.expect(counts[2] > 4500 and counts[2] < 5500);
}
