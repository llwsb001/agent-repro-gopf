//! Minimal thread-safe logger: one write per line, guarded by a spinlock.

const std = @import("std");
const posix = std.posix;
const c = std.c;

var lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn millisNow() i64 {
    var ts: posix.timespec = undefined;
    _ = c.clock_gettime(posix.CLOCK.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// Log a line to stderr: "[<epoch_ms>] gopf: <msg>".
pub fn logf(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[{d}] gopf: " ++ fmt ++ "\n", .{millisNow()} ++ args) catch blk: {
        break :blk buf[0 .. buf.len - 1];
    };
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
    defer lock.store(false, .release);
    _ = c.write(2, line.ptr, line.len);
}
