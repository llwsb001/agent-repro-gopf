const std = @import("std");

/// Global logger state. Installed by `install` in main() before any
/// concurrent task is spawned.
var state: ?State = null;

const State = struct {
    io: std.Io,
    w: *std.Io.Writer,
};

pub fn install(io: std.Io, w: *std.Io.Writer) void {
    state = .{ .io = io, .w = w };
}

/// Appends a log line ("YYYY/MM/DD HH:MM:SS <text>") to the installed stderr
/// writer's buffer without flushing. Callers must hold the log mutex and are
/// responsible for flushing.
pub fn logf(comptime fmt: []const u8, args: anytype) void {
    const s = state orelse return;
    const w = s.w;
    writeTimestamp(s.io, w);
    w.writeByte(' ') catch {};
    w.print(fmt, args) catch {};
    w.writeByte('\n') catch {};
}

pub fn flush() void {
    if (state) |s| s.w.flush() catch {};
}

fn writeTimestamp(io: std.Io, w: *std.Io.Writer) void {
    const now = std.Io.Clock.real.now(io);
    const secs = now.toSeconds();
    if (secs < 0) {
        w.writeAll("0000/00/00 00:00:00") catch {};
        return;
    }
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_secs.getDaySeconds();
    w.print("{d:0>4}/{d:0>2}/{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch {};
}
