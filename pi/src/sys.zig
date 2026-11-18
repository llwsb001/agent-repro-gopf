//! Portable TCP helpers over libc/posix (Linux + macOS).
//! Connect uses SO_SNDTIMEO; forwarding switches connected sockets to nonblocking mode.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;

pub const fd_t = posix.fd_t;
pub const socklen_t = posix.socklen_t;

pub const SockError = error{
    Timeout,
    Refused,
    Unreachable,
    AddrInUse,
    AddrNotAvail,
    FdQuota,
    SystemResources,
    UnknownHost,
    Unexpected,
};

const is_darwin = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst => true,
    else => false,
};

/// Owned socket address (IPv4 or IPv6), value type.
pub const SockAddr = struct {
    storage: posix.sockaddr.storage = std.mem.zeroes(posix.sockaddr.storage),
    len: socklen_t = 0,

    pub fn family(self: *const SockAddr) posix.sa_family_t {
        return self.storage.family;
    }

    pub fn ptr(self: *const SockAddr) *const posix.sockaddr {
        return @ptrCast(&self.storage);
    }

    pub fn ptrMut(self: *SockAddr) *posix.sockaddr {
        return @ptrCast(&self.storage);
    }

    pub fn port(self: *const SockAddr) u16 {
        return switch (self.family()) {
            posix.AF.INET => std.mem.bigToNative(u16, self.inConst().port),
            posix.AF.INET6 => std.mem.bigToNative(u16, self.in6Const().port),
            else => 0,
        };
    }

    pub fn inConst(self: *const SockAddr) *const posix.sockaddr.in {
        return @ptrCast(&self.storage);
    }

    pub fn in6Const(self: *const SockAddr) *const posix.sockaddr.in6 {
        return @ptrCast(&self.storage);
    }
};

pub fn sockaddrIp4(octets: [4]u8, port_num: u16) SockAddr {
    var sa: SockAddr = .{};
    const in: *posix.sockaddr.in = @ptrCast(@alignCast(&sa.storage));
    in.* = .{
        .port = std.mem.nativeToBig(u16, port_num),
        .addr = 0,
    };
    @memcpy(@as(*[4]u8, @ptrCast(&in.addr)), &octets);
    sa.len = @sizeOf(posix.sockaddr.in);
    return sa;
}

pub fn sockaddrIp6(bytes: [16]u8, port_num: u16) SockAddr {
    var sa: SockAddr = .{};
    const in6: *posix.sockaddr.in6 = @ptrCast(@alignCast(&sa.storage));
    in6.* = .{
        .port = std.mem.nativeToBig(u16, port_num),
        .flowinfo = 0,
        .addr = bytes,
        .scope_id = 0,
    };
    sa.len = @sizeOf(posix.sockaddr.in6);
    return sa;
}

/// Parse a dotted-quad IPv4 literal. Leading zeros rejected (like Go).
pub fn parseIp4(text: []const u8) ?[4]u8 {
    var parts: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, text, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return null;
        if (part.len == 0 or part.len > 3) return null;
        if (part.len > 1 and part[0] == '0') return null;
        var v: u16 = 0;
        for (part) |ch| {
            if (ch < '0' or ch > '9') return null;
            v = v * 10 + (ch - '0');
        }
        if (v > 255) return null;
        parts[i] = @intCast(v);
    }
    if (i != 4) return null;
    return parts;
}

fn parseHextet(s: []const u8) ?u16 {
    if (s.len == 0 or s.len > 4) return null;
    var v: u16 = 0;
    for (s) |ch| {
        const d: u16 = switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => return null,
        };
        v = v * 16 + d;
    }
    return v;
}

fn parseIp6Groups(text: []const u8, groups: *[8]u16, allow_v4: bool) ?usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, ':');
    while (it.next()) |g| {
        if (g.len == 0) return null;
        if (allow_v4 and std.mem.indexOfScalar(u8, g, '.') != null) {
            if (it.peek() != null) return null;
            const v4 = parseIp4(g) orelse return null;
            if (n + 2 > 8) return null;
            groups[n] = (@as(u16, v4[0]) << 8) | v4[1];
            groups[n + 1] = (@as(u16, v4[2]) << 8) | v4[3];
            return n + 2;
        }
        if (n >= 8) return null;
        groups[n] = parseHextet(g) orelse return null;
        n += 1;
    }
    return n;
}

fn groupsToBytes(groups: *const [8]u16) [16]u8 {
    var bytes: [16]u8 = undefined;
    for (groups, 0..) |g, i| {
        bytes[2 * i] = @intCast(g >> 8);
        bytes[2 * i + 1] = @intCast(g & 0xff);
    }
    return bytes;
}

pub fn parseIp6(text: []const u8) ?[16]u8 {
    var groups: [8]u16 = @splat(0);
    if (std.mem.indexOf(u8, text, "::")) |idx| {
        if (std.mem.indexOf(u8, text[idx + 2 ..], "::") != null) return null;
        var head_g: [8]u16 = undefined;
        var tail_g: [8]u16 = undefined;
        const head_txt = text[0..idx];
        const tail_txt = text[idx + 2 ..];
        const nh = if (head_txt.len == 0) 0 else (parseIp6Groups(head_txt, &head_g, false) orelse return null);
        const nt = if (tail_txt.len == 0) 0 else (parseIp6Groups(tail_txt, &tail_g, true) orelse return null);
        if (nh + nt > 7) return null;
        @memcpy(groups[0..nh], head_g[0..nh]);
        @memcpy(groups[8 - nt .. 8], tail_g[0..nt]);
    } else {
        const n = parseIp6Groups(text, &groups, true) orelse return null;
        if (n != 8) return null;
    }
    return groupsToBytes(&groups);
}

pub const HostPort = struct { host: []const u8, port: u16 };

pub const SplitError = error{
    MissingPort,
    TooManyColons,
    MissingBracket,
    EmptyPort,
    InvalidPort,
};

pub fn splitHostPort(addr: []const u8) SplitError!HostPort {
    var host: []const u8 = undefined;
    var port_text: []const u8 = undefined;
    if (addr.len > 0 and addr[0] == '[') {
        const close = std.mem.indexOfScalar(u8, addr, ']') orelse return error.MissingBracket;
        host = addr[1..close];
        if (close + 1 >= addr.len or addr[close + 1] != ':') return error.MissingPort;
        port_text = addr[close + 2 ..];
    } else {
        const colons = std.mem.count(u8, addr, ":");
        if (colons == 0) return error.MissingPort;
        if (colons > 1) return error.TooManyColons;
        const idx = std.mem.indexOfScalar(u8, addr, ':').?;
        host = addr[0..idx];
        port_text = addr[idx + 1 ..];
    }
    if (port_text.len == 0) return error.EmptyPort;
    const port_num = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidPort;
    return .{ .host = host, .port = port_num };
}

pub fn resolveDial(host: []const u8, port_num: u16) SockError!SockAddr {
    if (host.len == 0 or std.ascii.eqlIgnoreCase(host, "localhost")) {
        return sockaddrIp4(.{ 127, 0, 0, 1 }, port_num);
    }
    if (parseIp4(host)) |octets| return sockaddrIp4(octets, port_num);
    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        if (parseIp6(host)) |bytes| return sockaddrIp6(bytes, port_num);
    }
    return error.UnknownHost;
}

pub fn resolveListen(host: []const u8, port_num: u16) SockError!SockAddr {
    if (host.len == 0) return sockaddrIp4(.{ 0, 0, 0, 0 }, port_num);
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return sockaddrIp4(.{ 127, 0, 0, 1 }, port_num);
    if (parseIp4(host)) |octets| return sockaddrIp4(octets, port_num);
    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        if (parseIp6(host)) |bytes| return sockaddrIp6(bytes, port_num);
    }
    return error.UnknownHost;
}

pub fn formatSockAddr(buf: []u8, sa: *const SockAddr) []const u8 {
    switch (sa.family()) {
        posix.AF.INET => {
            const in = sa.inConst();
            const b: *const [4]u8 = @ptrCast(&in.addr);
            return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}:{d}", .{
                b[0], b[1], b[2], b[3], sa.port(),
            }) catch buf[0..0];
        },
        posix.AF.INET6 => {
            const b = &sa.in6Const().addr;
            var g: [8]u16 = undefined;
            for (0..8) |i| g[i] = (@as(u16, b[2 * i]) << 8) | b[2 * i + 1];
            return std.fmt.bufPrint(buf, "[{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}]:{d}", .{
                g[0], g[1], g[2], g[3], g[4], g[5], g[6], g[7], sa.port(),
            }) catch buf[0..0];
        },
        else => return std.fmt.bufPrint(buf, "af={d}", .{sa.family()}) catch buf[0..0],
    }
}

fn mapCommonErr(e: posix.E) SockError {
    return switch (e) {
        .CONNREFUSED => error.Refused,
        .TIMEDOUT => error.Timeout,
        .NETUNREACH, .HOSTUNREACH, .NETDOWN => error.Unreachable,
        .ADDRINUSE => error.AddrInUse,
        .ADDRNOTAVAIL => error.AddrNotAvail,
        .MFILE, .NFILE => error.FdQuota,
        .NOBUFS, .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

fn setCloexec(fd: fd_t) void {
    _ = c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
}

pub fn socket(family: posix.sa_family_t) SockError!fd_t {
    const rc = c.socket(family, posix.SOCK.STREAM, 0);
    if (rc < 0) return mapCommonErr(posix.errno(rc));
    setCloexec(rc);
    return rc;
}

pub fn closeFd(fd: fd_t) void {
    _ = c.close(fd);
}

pub fn setNonblocking(fd: fd_t, enabled: bool) SockError!void {
    const flags = c.fcntl(fd, posix.F.GETFL);
    if (flags < 0) return mapCommonErr(posix.errno(flags));
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    const updated = if (enabled) flags | nonblocking else flags & ~nonblocking;
    if (c.fcntl(fd, posix.F.SETFL, updated) < 0) return mapCommonErr(posix.errno(-1));
}

pub fn shutdownWr(fd: fd_t) void {
    _ = c.shutdown(fd, posix.SHUT.WR);
}

fn setsockoptInt(fd: fd_t, level: i32, optname: u32, value: c_int) void {
    posix.setsockopt(fd, level, optname, std.mem.asBytes(&value)) catch {};
}

/// Go net defaults: TCP_NODELAY + keepalive ~60s idle/interval.
pub fn setTcpOpts(fd: fd_t) void {
    setsockoptInt(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, 1);
    setsockoptInt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, 1);
    if (builtin.os.tag == .linux) {
        setsockoptInt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPIDLE, 60);
        setsockoptInt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPINTVL, 60);
    } else {
        // Darwin: TCP.KEEPALIVE is idle seconds when SO_KEEPALIVE is on.
        setsockoptInt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPALIVE, 60);
        if (@hasDecl(posix.TCP, "KEEPINTVL")) {
            setsockoptInt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPINTVL, 60);
        }
    }
    if (is_darwin and @hasDecl(posix.SO, "NOSIGPIPE")) {
        setsockoptInt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, 1);
    }
}

pub fn listenTcp(addr: *const SockAddr, backlog: u32) SockError!fd_t {
    const fd = try socket(addr.family());
    errdefer closeFd(fd);
    setsockoptInt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, 1);
    if (c.bind(fd, addr.ptr(), addr.len) < 0) return mapCommonErr(posix.errno(-1));
    if (c.listen(fd, backlog) < 0) return mapCommonErr(posix.errno(-1));
    return fd;
}

pub fn acceptTcp(listen_fd: fd_t, peer: *SockAddr) SockError!fd_t {
    while (true) {
        peer.len = @sizeOf(posix.sockaddr.storage);
        const rc = c.accept(listen_fd, peer.ptrMut(), &peer.len);
        if (rc >= 0) {
            setCloexec(rc);
            return rc;
        }
        switch (posix.errno(rc)) {
            .INTR => continue,
            .CONNABORTED => continue,
            .MFILE, .NFILE => return error.FdQuota,
            .NOBUFS, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
}

pub fn connectTimeout(addr: *const SockAddr, timeout_ms: u32) SockError!fd_t {
    const fd = try socket(addr.family());
    errdefer closeFd(fd);

    const tv: posix.timeval = .{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};

    if (c.connect(fd, addr.ptr(), addr.len) < 0) {
        switch (posix.errno(-1)) {
            .INTR => return error.Timeout,
            .AGAIN => return error.Timeout,
            else => |e| return mapCommonErr(e),
        }
    }

    const zero: posix.timeval = .{ .sec = 0, .usec = 0 };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&zero)) catch {};
    return fd;
}

fn sendFlags() u32 {
    if (@hasDecl(posix.MSG, "NOSIGNAL")) return posix.MSG.NOSIGNAL;
    return 0;
}

fn sendSome(fd: fd_t, bytes: []const u8) SockError!?usize {
    while (true) {
        const n = c.send(fd, bytes.ptr, bytes.len, sendFlags());
        if (n >= 0) return @as(usize, @intCast(n));
        switch (posix.errno(n)) {
            .INTR => continue,
            .AGAIN => return null,
            .PIPE, .CONNRESET => return error.Refused,
            else => |e| return mapCommonErr(e),
        }
    }
}

pub fn writeAll(fd: fd_t, bytes: []const u8) SockError!void {
    var off: usize = 0;
    while (off < bytes.len) off += (try sendSome(fd, bytes[off..])) orelse return error.Unexpected;
}

/// Write to a nonblocking socket. Returns null if it would block.
pub fn writeNonblocking(fd: fd_t, bytes: []const u8) SockError!?usize {
    return sendSome(fd, bytes);
}

fn receiveSome(fd: fd_t, buf: []u8) SockError!?usize {
    while (true) {
        const n = c.read(fd, buf.ptr, buf.len);
        if (n >= 0) return @as(usize, @intCast(n));
        switch (posix.errno(n)) {
            .INTR => continue,
            .AGAIN => return null,
            .CONNRESET => return error.Refused,
            else => |e| return mapCommonErr(e),
        }
    }
}

pub fn readSome(fd: fd_t, buf: []u8) SockError!usize {
    return (try receiveSome(fd, buf)) orelse error.Unexpected;
}

/// Read from a nonblocking socket. Returns null for would-block and 0 for EOF.
pub fn readNonblocking(fd: fd_t, buf: []u8) SockError!?usize {
    return receiveSome(fd, buf);
}

pub fn getSockName(fd: fd_t) SockError!SockAddr {
    var sa: SockAddr = .{};
    sa.len = @sizeOf(posix.sockaddr.storage);
    if (c.getsockname(fd, sa.ptrMut(), &sa.len) < 0) return mapCommonErr(posix.errno(-1));
    return sa;
}

pub fn sleepMs(ms: u64) void {
    var ts: posix.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = c.nanosleep(&ts, null);
}

pub fn readFileAlloc(gpa: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const fd = posix.openat(posix.AT.FDCWD, path, .{}, 0) catch return error.FileOpen;
    defer closeFd(fd);
    var buf = std.array_list.Managed(u8).init(gpa);
    errdefer buf.deinit();
    var chunk: [16384]u8 = undefined;
    while (true) {
        const n = readSome(fd, &chunk) catch return error.FileRead;
        if (n == 0) break;
        try buf.appendSlice(chunk[0..n]);
        if (buf.items.len > max_bytes) return error.FileTooBig;
    }
    return buf.toOwnedSlice();
}

pub fn nanosNow() u64 {
    var ts: posix.timespec = undefined;
    _ = c.clock_gettime(posix.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn getPid() i32 {
    return c.getpid();
}

pub fn unlinkPath(path: []const u8) void {
    var buf: [256]u8 = undefined;
    const zpath = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return;
    _ = c.unlink(zpath);
}

pub fn writeFile(path: []const u8, content: []const u8) void {
    const fd = posix.openat(posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644) catch @panic("openat");
    defer closeFd(fd);
    var off: usize = 0;
    while (off < content.len) {
        const n = c.write(fd, content.ptr + off, content.len - off);
        if (n < 0) @panic("write");
        off += @intCast(n);
    }
}
