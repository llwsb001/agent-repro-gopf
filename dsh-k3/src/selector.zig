//! 加权随机后端选择。
//!
//! 语义与 Go 参考实现一致：rand(0, weightSum) 后按累计权重落点；
//! weightSum <= 0（没有可用后端）返回 null。

const std = @import("std");
const configz = @import("config.zig");

/// 在 cfg.hosts 中按权重随机选择一个后端，返回下标；无可用后端返回 null。
pub fn choose(cfg: *const configz.Config, rng: std.Random) ?usize {
    if (cfg.weight_sum == 0 or cfg.hosts.len == 0) return null;

    const r = rng.uintLessThan(u64, cfg.weight_sum);
    var cumulative: u64 = 0;
    for (cfg.hosts, 0..) |h, i| {
        cumulative += h.weight;
        if (r < cumulative) return i;
    }
    // 理论上来不到这里；与 Go 版一样兜底为最后一个后端。
    return cfg.hosts.len - 1;
}

// ---------------------------------------------------------------------------
// 单元测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testCfg(hosts: []configz.Host) configz.Config {
    var sum: u64 = 0;
    for (hosts) |h| sum += h.weight;
    return .{ .arena = undefined, .hosts = hosts, .weight_sum = sum };
}

fn mkHost(text: []const u8, weight: u64) configz.Host {
    return .{ .text = @constCast(text), .addr = undefined, .weight = weight };
}

test "weighted selection distributes 1:2 over 100k picks" {
    var hosts = [_]configz.Host{ mkHost("a", 1), mkHost("b", 2) };
    const cfg = testCfg(&hosts);

    var rng = std.Random.DefaultPrng.init(0xdeadbeef);
    var counts = [_]u64{ 0, 0 };
    const n = 100_000;
    for (0..n) |_| {
        const idx = choose(&cfg, rng.random()).?;
        counts[idx] += 1;
    }
    const p0 = @as(f64, @floatFromInt(counts[0])) / n;
    const p1 = @as(f64, @floatFromInt(counts[1])) / n;
    // 期望 1/3 与 2/3，留足统计裕量（±1.5%）。
    try testing.expect(p0 > 1.0 / 3.0 - 0.015 and p0 < 1.0 / 3.0 + 0.015);
    try testing.expect(p1 > 2.0 / 3.0 - 0.015 and p1 < 2.0 / 3.0 + 0.015);
}

test "weight-zero host is never selected" {
    var hosts = [_]configz.Host{ mkHost("a", 0), mkHost("b", 1), mkHost("c", 0) };
    const cfg = testCfg(&hosts);

    var rng = std.Random.DefaultPrng.init(12345);
    for (0..100_000) |_| {
        const idx = choose(&cfg, rng.random()).?;
        try testing.expectEqual(@as(usize, 1), idx);
    }
}

test "zero weight sum or empty hosts yields null" {
    var hosts = [_]configz.Host{ mkHost("a", 0), mkHost("b", 0) };
    const cfg0 = testCfg(&hosts);
    var rng = std.Random.DefaultPrng.init(7);
    try testing.expect(choose(&cfg0, rng.random()) == null);

    var empty = [_]configz.Host{};
    const cfg_empty = testCfg(&empty);
    try testing.expect(choose(&cfg_empty, rng.random()) == null);
}
