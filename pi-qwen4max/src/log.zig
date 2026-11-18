//! Timestamped logging to stderr, mimicking Go's `log` package default
//! format ("2006-01-02 15:04:05 message"). std.debug.print locks stderr,
//! so lines from concurrent connection threads never interleave.

const std = @import("std");
const sys = @import("sys.zig");

fn timestamp(buf: *[20]u8) []const u8 {
    const secs: u64 = @intCast(@max(sys.nowSecs(), 0));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay();
    const ds = es.getDaySeconds();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch "0000-00-00 00:00:00";
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var tsbuf: [20]u8 = undefined;
    const ts = timestamp(&tsbuf);
    std.debug.print("{s} " ++ fmt ++ "\n", .{ts} ++ args);
}
