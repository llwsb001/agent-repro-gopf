//! Weighted-random backend selection.
const std = @import("std");
const config = @import("config.zig");

/// Pick an index using a uniform random value in [0, weight_sum).
/// A zero-weight host is never selected. Returns null when no host has weight.
pub fn choose(hosts: []const config.Host, weight_sum: i64, random: std.Random) ?usize {
    if (hosts.len == 0 or weight_sum <= 0) return null;
    const r = random.intRangeLessThan(i64, 0, weight_sum);
    var cumulative: i64 = 0;
    for (hosts, 0..) |h, i| {
        cumulative += h.weight;
        if (r < cumulative) return i;
    }
    return hosts.len - 1;
}
