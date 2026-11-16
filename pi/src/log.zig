//! Minimal thread-safe logger: one write(2) syscall per line, guarded by a
//! spinlock so lines from different threads never interleave. Cheap enough to
//! call once per accepted connection without measurably hurting throughput.

const std = @import("std");
const linux = std.os.linux;

var lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn millisNow() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Log a line to stderr: "[<epoch_ms>] gopf: <msg>".
pub fn logf(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[{d}] gopf: " ++ fmt ++ "\n", .{millisNow()} ++ args) catch blk: {
        // Message did not fit; emit truncated.
        break :blk buf[0 .. buf.len - 1];
    };
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
    defer lock.store(false, .release);
    _ = linux.write(2, line.ptr, line.len);
}
