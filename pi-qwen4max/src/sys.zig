//! Thin wrappers around Linux syscalls / libc used by the proxy.
//!
//! Zig 0.17 removed the old `std.net` high-level socket API and the new
//! `std.Io` networking is not fully implemented (e.g. connect-with-timeout
//! panics), so we talk to the kernel directly via `std.os.linux` and use
//! libc only for `getaddrinfo` (DNS / service resolution).

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const config = @import("config.zig");

pub const fd_t = posix.fd_t;

// ---------------------------------------------------------------------------
// basic syscall helpers
// ---------------------------------------------------------------------------

fn ok(rc: usize) !fd_t {
    const e = linux.errno(rc);
    switch (e) {
        .SUCCESS => return @intCast(rc),
        .NOENT => return error.FileNotFound,
        .ACCES => return error.AccessDenied,
        .ISDIR => return error.IsDir,
        .NAMETOOLONG => return error.NameTooLong,
        else => return posix.unexpectedErrno(e),
    }
}

/// Copy `s` into `buf` NUL-terminated (std.fmt.bufPrintZ was removed in 0.17).
fn copyZ(buf: []u8, s: []const u8) ![*:0]const u8 {
    if (s.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf.ptr);
}

pub fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

/// CLOCK_REALTIME via raw syscall (std.time.timestamp was removed in 0.17).
pub fn nowSecs() i64 {
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.REALTIME, &ts)) != .SUCCESS) return 0;
    return ts.sec;
}

pub fn nowNs() i128 {
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.REALTIME, &ts)) != .SUCCESS) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub fn sleepMs(ms: u64) void {
    var req = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    while (true) {
        switch (linux.errno(linux.nanosleep(&req, &req))) {
            .SUCCESS, .FAULT => return,
            .INTR => continue,
            else => return,
        }
    }
}

pub fn tcpSocket(family: u32, nonblock: bool) !fd_t {
    var typ: u32 = linux.SOCK.STREAM | linux.SOCK.CLOEXEC;
    if (nonblock) typ |= linux.SOCK.NONBLOCK;
    return ok(linux.socket(family, typ, linux.IPPROTO.TCP));
}

pub fn setBlocking(fd: fd_t, blocking: bool) !void {
    const rc = linux.fcntl(fd, linux.F.GETFL, 0);
    const flags = try ok(rc);
    const nonblock: u32 = @bitCast(linux.O{ .NONBLOCK = true });
    var f: u32 = @intCast(flags);
    if (blocking) {
        f &= ~nonblock;
    } else {
        f |= nonblock;
    }
    _ = try ok(linux.fcntl(fd, linux.F.SETFL, f));
}

pub fn setIntOpt(fd: fd_t, level: i32, opt: u32, value: c_int) !void {
    try posix.setsockopt(fd, level, opt, std.mem.asBytes(&value));
}

pub fn enableKeepalive(fd: fd_t, period_secs: c_int) !void {
    try setIntOpt(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, 1);
    // Go's SetKeepAlivePeriod sets both the idle time and the probe interval.
    try setIntOpt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPIDLE, period_secs);
    try setIntOpt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPINTVL, period_secs);
}

pub fn setNodelay(fd: fd_t) !void {
    // Go's net package enables TCP_NODELAY by default on TCP connections.
    try setIntOpt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, 1);
}

pub fn shutdownWrite(fd: fd_t) void {
    _ = linux.shutdown(fd, posix.SHUT.WR);
}

/// write(2) with EINTR retry (std.posix.write was removed in 0.17).
pub fn write(fd: fd_t, data: []const u8) !usize {
    while (true) {
        const rc = linux.write(fd, data.ptr, data.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

pub fn writeAll(fd: fd_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = try write(fd, data[off..]);
        if (n == 0) return error.BrokenPipe;
        off += n;
    }
}

/// Read exactly `buf.len` bytes; returns error.EndOfStream on premature EOF.
pub fn readFull(fd: fd_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try posix.read(fd, buf[off..]);
        if (n == 0) return error.EndOfStream;
        off += n;
    }
}

// ---------------------------------------------------------------------------
// address helpers
// ---------------------------------------------------------------------------

pub fn localPort(fd: fd_t) !u16 {
    var ss: posix.sockaddr.storage = undefined;
    var len: posix.socklen_t = @sizeOf(@TypeOf(ss));
    _ = try ok(linux.getsockname(fd, @ptrCast(&ss), &len));
    const sa: *const posix.sockaddr = @ptrCast(&ss);
    return switch (sa.family) {
        posix.AF.INET => std.mem.bigToNative(u16, @as(*const posix.sockaddr.in, @ptrCast(@alignCast(sa))).port),
        posix.AF.INET6 => std.mem.bigToNative(u16, @as(*const posix.sockaddr.in6, @ptrCast(@alignCast(sa))).port),
        else => error.UnsupportedAddressFamily,
    };
}

/// Format a sockaddr as "ip:port" into `buf`, returning the used slice.
pub fn formatAddr(sa: *const posix.sockaddr, buf: []u8) []const u8 {
    switch (sa.family) {
        posix.AF.INET => {
            const in: *const posix.sockaddr.in = @ptrCast(@alignCast(sa));
            const b: *const [4]u8 = @ptrCast(&in.addr);
            const port = std.mem.bigToNative(u16, in.port);
            return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}:{d}", .{ b[0], b[1], b[2], b[3], port }) catch buf[0..0];
        },
        posix.AF.INET6 => {
            const in6: *const posix.sockaddr.in6 = @ptrCast(@alignCast(sa));
            const port = std.mem.bigToNative(u16, in6.port);
            var w: usize = 0;
            w += (std.fmt.bufPrint(buf[w..], "[", .{}) catch return buf[0..0]).len;
            for (0..8) |i| {
                const word = std.mem.readInt(u16, in6.addr[i * 2 ..][0..2], .big);
                w += (std.fmt.bufPrint(buf[w..], "{x}", .{word}) catch return buf[0..0]).len;
                if (i < 7) w += (std.fmt.bufPrint(buf[w..], ":", .{}) catch return buf[0..0]).len;
            }
            w += (std.fmt.bufPrint(buf[w..], "]:{d}", .{port}) catch return buf[0..0]).len;
            return buf[0..w];
        },
        else => return std.fmt.bufPrint(buf, "<unknown-af:{d}>", .{sa.family}) catch buf[0..0],
    }
}

pub fn peerName(fd: fd_t, buf: []u8) []const u8 {
    var ss: posix.sockaddr.storage = undefined;
    var len: posix.socklen_t = @sizeOf(@TypeOf(ss));
    const rc = linux.getpeername(fd, @ptrCast(&ss), &len);
    if (linux.errno(rc) != .SUCCESS) return "<unknown>";
    return formatAddr(@ptrCast(&ss), buf);
}

// ---------------------------------------------------------------------------
// resolution (libc getaddrinfo)
// ---------------------------------------------------------------------------

const AddrList = struct {
    res: *std.c.addrinfo,
    fn deinit(self: AddrList) void {
        std.c.freeaddrinfo(self.res);
    }
};

fn resolve(host: ?[]const u8, port: []const u8, passive: bool) !AddrList {
    var hostbuf: [256]u8 = undefined;
    var portbuf: [32]u8 = undefined;
    if (port.len == 0 or port.len >= portbuf.len) return error.InvalidPort;
    const port_z = try copyZ(&portbuf, port);
    var host_z: ?[*:0]const u8 = null;
    if (host) |h| {
        if (h.len == 0 or h.len >= hostbuf.len) return error.InvalidHost;
        host_z = try copyZ(&hostbuf, h);
    }
    var hints: std.c.addrinfo = std.mem.zeroes(std.c.addrinfo);
    hints.family = posix.AF.UNSPEC;
    hints.socktype = linux.SOCK.STREAM;
    hints.protocol = linux.IPPROTO.TCP;
    hints.flags = .{ .PASSIVE = passive };
    var res: ?*std.c.addrinfo = null;
    const rc = std.c.getaddrinfo(host_z, port_z, &hints, &res);
    if (@intFromEnum(rc) != 0 or res == null) return error.ResolutionFailed;
    return .{ .res = res.? };
}

// ---------------------------------------------------------------------------
// dial with timeout (non-blocking connect + poll, like Go's DialTimeout)
// ---------------------------------------------------------------------------

pub fn dial(addr: []const u8, timeout_ms: i32) !fd_t {
    const hp = try config.splitHostPort(addr);
    // Go treats an empty dial host as localhost.
    const host: ?[]const u8 = if (hp.host.len == 0) "localhost" else hp.host;
    const list = try resolve(host, hp.port, false);
    defer list.deinit();

    var it: ?*std.c.addrinfo = list.res;
    var last_err: anyerror = error.ConnectionFailed;
    while (it) |ai| : (it = ai.next) {
        const fd = tcpSocket(@intCast(ai.family), true) catch |e| {
            last_err = e;
            continue;
        };
        const rc = linux.connect(fd, @ptrCast(ai.addr.?), ai.addrlen);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                try setBlocking(fd, true);
                return fd;
            },
            .INPROGRESS => {
                var pfds = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
                const n = posix.poll(&pfds, timeout_ms) catch {
                    close(fd);
                    last_err = error.Timeout;
                    continue;
                };
                if (n == 0) {
                    close(fd);
                    last_err = error.Timeout;
                    continue;
                }
                var soerr: c_int = 0;
                var slen: posix.socklen_t = @sizeOf(c_int);
                const grc = linux.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&soerr), &slen);
                if (linux.errno(grc) != .SUCCESS or soerr != 0) {
                    close(fd);
                    last_err = error.ConnectionFailed;
                    continue;
                }
                try setBlocking(fd, true);
                return fd;
            },
            else => |e| {
                close(fd);
                last_err = switch (e) {
                    .CONNREFUSED => error.ConnectionRefused,
                    .TIMEDOUT => error.Timeout,
                    .HOSTUNREACH => error.HostUnreachable,
                    .NETUNREACH => error.NetworkUnreachable,
                    else => posix.unexpectedErrno(e),
                };
                continue;
            },
        }
    }
    return last_err;
}

// ---------------------------------------------------------------------------
// listen
// ---------------------------------------------------------------------------

pub fn listen(addr: []const u8) !fd_t {
    const hp = try config.splitHostPort(addr);
    const host: ?[]const u8 = if (hp.host.len == 0) null else hp.host;
    const list = try resolve(host, hp.port, true);
    defer list.deinit();

    var it: ?*std.c.addrinfo = list.res;
    var last_err: anyerror = error.BindFailed;
    while (it) |ai| : (it = ai.next) {
        const fd = tcpSocket(@intCast(ai.family), false) catch |e| {
            last_err = e;
            continue;
        };
        setIntOpt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, 1) catch {};
        if (ai.family == posix.AF.INET6) {
            // Dual-stack listener, like Go's net.Listen("tcp", ...).
            setIntOpt(fd, posix.IPPROTO.IPV6, posix.IPV6.V6ONLY, 0) catch {};
        }
        if (linux.errno(linux.bind(fd, ai.addr.?, ai.addrlen)) != .SUCCESS) {
            close(fd);
            last_err = error.BindFailed;
            continue;
        }
        if (linux.errno(linux.listen(fd, 1024)) != .SUCCESS) {
            close(fd);
            last_err = error.ListenFailed;
            continue;
        }
        return fd;
    }
    return last_err;
}

pub fn accept(listener: fd_t) !fd_t {
    var ss: posix.sockaddr.storage = undefined;
    var len: posix.socklen_t = @sizeOf(@TypeOf(ss));
    return ok(linux.accept4(listener, @ptrCast(&ss), &len, linux.SOCK.CLOEXEC));
}

// ---------------------------------------------------------------------------
// files (raw syscalls; std.fs in 0.17 requires the unfinished Io interface)
// ---------------------------------------------------------------------------

pub fn readFile(alloc: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    var pathbuf: [4096]u8 = undefined;
    if (path.len >= pathbuf.len) return error.NameTooLong;
    const path_z = try copyZ(&pathbuf, path);
    const fd = try ok(linux.openat(linux.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0));
    defer close(fd);
    var list = std.array_list.Managed(u8).init(alloc);
    errdefer list.deinit();
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = try posix.read(fd, &chunk);
        if (n == 0) break;
        if (list.items.len + n > limit) return error.FileTooBig;
        try list.appendSlice(chunk[0..n]);
    }
    return list.toOwnedSlice();
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    var pathbuf: [4096]u8 = undefined;
    if (path.len >= pathbuf.len) return error.NameTooLong;
    const path_z = try copyZ(&pathbuf, path);
    const fd = try ok(linux.openat(linux.AT.FDCWD, path_z, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    }, 0o644));
    defer close(fd);
    try writeAll(fd, data);
}

pub fn deleteFile(path: []const u8) void {
    var pathbuf: [4096]u8 = undefined;
    if (path.len >= pathbuf.len) return;
    const path_z = copyZ(&pathbuf, path) catch return;
    _ = linux.unlinkat(linux.AT.FDCWD, path_z, 0);
}

/// Simple blocking mutex (std.Thread.Mutex was removed in 0.17; the remaining
/// std.atomic.Mutex is try-lock only). Critical sections here are tiny.
pub const Mutex = struct {
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    pub fn lock(m: *Mutex) void {
        while (m.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    pub fn unlock(m: *Mutex) void {
        m.state.store(0, .release);
    }
};
