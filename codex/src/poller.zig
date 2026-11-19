const std = @import("std");
const os = @import("builtin").target.os.tag;
const c = std.c;
const posix = std.posix;
const linux = std.os.linux;

pub const Interest = struct {
    read: bool = false,
    write: bool = false,
};

pub const Event = struct {
    token: u64,
    readable: bool,
    writable: bool,
};

const max_batch = 128;

pub const Poller = struct {
    fd: posix.fd_t,

    pub fn init() !Poller {
        const fd = switch (os) {
            .linux => c.epoll_create1(linux.EPOLL.CLOEXEC),
            .macos => c.kqueue(),
            else => @compileError("gopf supports Linux and macOS"),
        };
        if (c.errno(fd) != .SUCCESS) return error.PollerCreateFailed;
        errdefer _ = c.close(fd);

        if (os == .macos) {
            const result = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
            if (c.errno(result) != .SUCCESS) return error.PollerCreateFailed;
        }
        return .{ .fd = fd };
    }

    pub fn deinit(self: *Poller) void {
        _ = c.close(self.fd);
    }

    /// The token stays fixed while the descriptor is registered. On error,
    /// close the descriptor, since kqueue may have applied some of the changes.
    pub fn update(self: *Poller, fd: posix.fd_t, token: u64, previous: Interest, next: Interest) !void {
        if (previous.read == next.read and previous.write == next.write) return;

        const result = switch (os) {
            .linux => self.updateEpoll(fd, token, previous, next),
            .macos => self.updateKqueue(fd, token, previous, next),
            else => unreachable,
        };
        if (c.errno(result) != .SUCCESS) return error.PollerUpdateFailed;
    }

    fn updateEpoll(self: *Poller, fd: posix.fd_t, token: u64, previous: Interest, next: Interest) c_int {
        const epoll = linux.EPOLL;
        if (!next.read and !next.write) return c.epoll_ctl(self.fd, epoll.CTL_DEL, fd, null);
        const operation: c_uint = if (previous.read or previous.write) epoll.CTL_MOD else epoll.CTL_ADD;
        var event = c.epoll_event{ .events = 0, .data = .{ .u64 = token } };
        if (next.read) event.events |= epoll.IN | epoll.RDHUP;
        if (next.write) event.events |= epoll.OUT;
        return c.epoll_ctl(self.fd, operation, fd, &event);
    }

    fn updateKqueue(self: *Poller, fd: posix.fd_t, token: u64, previous: Interest, next: Interest) c_int {
        var changes: [2]c.kevent64_s = undefined;
        var count: usize = 0;
        if (previous.read != next.read) {
            changes[count] = kqueueChange(fd, token, c.EVFILT.READ, next.read);
            count += 1;
        }
        if (previous.write != next.write) {
            changes[count] = kqueueChange(fd, token, c.EVFILT.WRITE, next.write);
            count += 1;
        }

        var receipts: [0]c.kevent64_s = .{};
        return c.kevent64(self.fd, &changes, @intCast(count), &receipts, 0, .{}, null);
    }

    /// Wait for at least one event, retrying interrupted waits. kqueue may
    /// report read and write as separate events with the same token.
    pub fn wait(self: *Poller, events: []Event) !usize {
        std.debug.assert(events.len != 0);
        const batch = events[0..@min(events.len, max_batch)];
        return switch (os) {
            .linux => self.waitEpoll(batch),
            .macos => self.waitKqueue(batch),
            else => unreachable,
        };
    }

    fn waitEpoll(self: *Poller, events: []Event) !usize {
        const epoll = linux.EPOLL;
        var raw: [max_batch]c.epoll_event = undefined;
        while (true) {
            const count = c.epoll_wait(self.fd, &raw, @intCast(events.len), -1);
            switch (c.errno(count)) {
                .SUCCESS => {
                    for (events[0..@intCast(count)], raw[0..@intCast(count)]) |*out, event| {
                        // HUP and ERR arrive without an explicit subscription.
                        // Let the caller attempt I/O for whichever end is active.
                        const terminal = event.events & (epoll.HUP | epoll.ERR) != 0;
                        out.* = .{
                            .token = event.data.u64,
                            .readable = terminal or event.events & (epoll.IN | epoll.RDHUP) != 0,
                            .writable = terminal or event.events & epoll.OUT != 0,
                        };
                    }
                    return @intCast(count);
                },
                .INTR => continue,
                else => return error.PollerWaitFailed,
            }
        }
    }

    fn waitKqueue(self: *Poller, events: []Event) !usize {
        var raw: [max_batch]c.kevent64_s = undefined;
        while (true) {
            const count = c.kevent64(self.fd, &.{}, 0, &raw, @intCast(events.len), .{}, null);
            switch (c.errno(count)) {
                .SUCCESS => {
                    for (events[0..@intCast(count)], raw[0..@intCast(count)]) |*out, event| {
                        // EV_EOF is delivered on the relevant filter, including
                        // when the socket has unread bytes left.
                        out.* = .{
                            .token = event.udata,
                            .readable = event.filter == c.EVFILT.READ,
                            .writable = event.filter == c.EVFILT.WRITE,
                        };
                    }
                    return @intCast(count);
                },
                .INTR => continue,
                else => return error.PollerWaitFailed,
            }
        }
    }
};

fn kqueueChange(fd: posix.fd_t, token: u64, filter: i16, enabled: bool) c.kevent64_s {
    return .{
        .ident = @intCast(fd),
        .filter = filter,
        .flags = if (enabled) c.EV.ADD else c.EV.DELETE,
        .fflags = 0,
        .data = 0,
        .udata = token,
        .ext = .{ 0, 0 },
    };
}
