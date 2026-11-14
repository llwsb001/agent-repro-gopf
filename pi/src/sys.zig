//! Thin wrappers over raw Linux syscalls (no libc) for TCP networking.
//! Every socket gopf creates is blocking; the connect timeout is implemented
//! with SO_SNDTIMEO which Linux honors for blocking connect(2).

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

pub const fd_t = linux.fd_t;
pub const socklen_t = linux.socklen_t;

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

/// Owned socket address (IPv4 or IPv6), value type.
pub const SockAddr = struct {
    storage: linux.sockaddr.storage = .{ .family = 0, .padding = undefined },
    len: socklen_t = 0,

    pub fn family(self: *const SockAddr) u16 {
        return self.storage.family;
    }

    pub fn ptr(self: *const SockAddr) *const linux.sockaddr {
        return @ptrCast(&self.storage);
    }

    pub fn ptrMut(self: *SockAddr) *linux.sockaddr {
        return @ptrCast(&self.storage);
    }

    pub fn port(self: *const SockAddr) u16 {
        return switch (self.family()) {
            linux.AF.INET => std.mem.bigToNative(u16, self.inConst().port),
            linux.AF.INET6 => std.mem.bigToNative(u16, self.in6Const().port),
            else => 0,
        };
    }

    pub fn inConst(self: *const SockAddr) *const linux.sockaddr.in {
        return @ptrCast(&self.storage);
    }

    pub fn in6Const(self: *const SockAddr) *const linux.sockaddr.in6 {
        return @ptrCast(&self.storage);
    }
};

pub fn sockaddrIp4(octets: [4]u8, port: u16) SockAddr {
    var sa: SockAddr = .{};
    const in: *linux.sockaddr.in = @ptrCast(&sa.storage);
    in.* = .{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0,
        .zero = @splat(0),
    };
    @memcpy(@as(*[4]u8, @ptrCast(&in.addr)), &octets);
    sa.len = @sizeOf(linux.sockaddr.in);
    return sa;
}

pub fn sockaddrIp6(bytes: [16]u8, port: u16) SockAddr {
    var sa: SockAddr = .{};
    const in6: *linux.sockaddr.in6 = @ptrCast(&sa.storage);
    in6.* = .{
        .family = linux.AF.INET6,
        .port = std.mem.nativeToBig(u16, port),
        .flowinfo = 0,
        .addr = bytes,
        .scope_id = 0,
    };
    sa.len = @sizeOf(linux.sockaddr.in6);
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
        for (part) |c| {
            if (c < '0' or c > '9') return null;
            v = v * 10 + (c - '0');
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
    for (s) |c| {
        const d: u16 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        v = v * 16 + d;
    }
    return v;
}

/// Parse a ':'-separated run of hextets (optionally ending in an IPv4 tail)
/// into up to 8 groups. Returns group count.
fn parseIp6Groups(text: []const u8, groups: *[8]u16, allow_v4: bool) ?usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, ':');
    while (it.next()) |g| {
        if (g.len == 0) return null; // empty group: caller handles "::"
        if (allow_v4 and std.mem.indexOfScalar(u8, g, '.') != null) {
            if (it.peek() != null) return null; // v4 tail must be last
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

/// Parse an IPv6 literal, supporting "::" compression and embedded IPv4
/// ("::ffff:1.2.3.4"). Zone identifiers ("fe80::1%eth0") are not supported.
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
        if (nh + nt > 7) return null; // "::" must stand for at least one group
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

/// Split "host:port" with Go net.SplitHostPort-compatible bracket handling.
/// Additionally requires a numeric port (we cannot resolve service names
/// without libc/DNS). Host may be empty (":1248").
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
        if (colons > 1) return error.TooManyColons; // unbracketed IPv6
        const idx = std.mem.indexOfScalar(u8, addr, ':').?;
        host = addr[0..idx];
        port_text = addr[idx + 1 ..];
    }
    if (port_text.len == 0) return error.EmptyPort;
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidPort;
    return .{ .host = host, .port = port };
}

/// Resolve a backend dial target. Empty host means loopback (like Go's dial
/// of ":80"). "localhost" maps to 127.0.0.1. Arbitrary DNS names are not
/// resolvable without libc; they fail here with error.UnknownHost.
pub fn resolveDial(host: []const u8, port: u16) SockError!SockAddr {
    if (host.len == 0 or std.ascii.eqlIgnoreCase(host, "localhost")) {
        return sockaddrIp4(.{ 127, 0, 0, 1 }, port);
    }
    if (parseIp4(host)) |octets| return sockaddrIp4(octets, port);
    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        if (parseIp6(host)) |bytes| return sockaddrIp6(bytes, port);
    }
    return error.UnknownHost;
}

/// Resolve a listen address. Empty host means the wildcard address.
pub fn resolveListen(host: []const u8, port: u16) SockError!SockAddr {
    if (host.len == 0) return sockaddrIp4(.{ 0, 0, 0, 0 }, port);
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return sockaddrIp4(.{ 127, 0, 0, 1 }, port);
    if (parseIp4(host)) |octets| return sockaddrIp4(octets, port);
    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        if (parseIp6(host)) |bytes| return sockaddrIp6(bytes, port);
    }
    return error.UnknownHost;
}

/// Write "a.b.c.d:port" or "[v6]:port" into buf.
pub fn formatSockAddr(buf: []u8, sa: *const SockAddr) []const u8 {
    switch (sa.family()) {
        linux.AF.INET => {
            const in = sa.inConst();
            const b: *const [4]u8 = @ptrCast(&in.addr);
            return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}:{d}", .{
                b[0], b[1], b[2], b[3], sa.port(),
            }) catch buf[0..0];
        },
        linux.AF.INET6 => {
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

fn mapCommonErr(e: linux.E) SockError {
    return switch (e) {
        .CONNREFUSED => error.Refused,
        .TIMEDOUT, .TIME => error.Timeout,
        .NETUNREACH, .HOSTUNREACH, .NETDOWN => error.Unreachable,
        .ADDRINUSE => error.AddrInUse,
        .ADDRNOTAVAIL => error.AddrNotAvail,
        .MFILE, .NFILE => error.FdQuota,
        .NOBUFS, .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

pub fn errnoTag(rc: usize) []const u8 {
    return @tagName(linux.errno(rc));
}

pub fn socket(family: u16) SockError!fd_t {
    const rc = linux.socket(family, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |e| mapCommonErr(e),
    };
}

pub fn closeFd(fd: fd_t) void {
    _ = linux.close(fd);
}

pub fn shutdownWr(fd: fd_t) void {
    _ = linux.shutdown(fd, linux.SHUT.WR);
}

fn setsockoptInt(fd: fd_t, level: i32, optname: u32, value: c_int) void {
    posix.setsockopt(fd, level, optname, std.mem.asBytes(&value)) catch {};
}

/// Go's net package defaults: TCP_NODELAY on, SO_KEEPALIVE on with a 60s
/// idle/interval period (SetKeepAlivePeriod(60s) sets both).
pub fn setTcpOpts(fd: fd_t) void {
    setsockoptInt(fd, linux.SOL.SOCKET, linux.SO.KEEPALIVE, 1);
    setsockoptInt(fd, linux.IPPROTO.TCP, linux.TCP.KEEPIDLE, 60);
    setsockoptInt(fd, linux.IPPROTO.TCP, linux.TCP.KEEPINTVL, 60);
    setsockoptInt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, 1);
}

/// Create, bind and listen a TCP socket. SO_REUSEADDR like Go's net.Listen.
pub fn listenTcp(addr: *const SockAddr, backlog: u32) SockError!fd_t {
    const fd = try socket(addr.family());
    errdefer closeFd(fd);
    setsockoptInt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1);
    switch (linux.errno(linux.bind(fd, addr.ptr(), addr.len))) {
        .SUCCESS => {},
        else => |e| return mapCommonErr(e),
    }
    switch (linux.errno(linux.listen(fd, backlog))) {
        .SUCCESS => {},
        else => |e| return mapCommonErr(e),
    }
    return fd;
}

pub fn acceptTcp(listen_fd: fd_t, peer: *SockAddr) SockError!fd_t {
    while (true) {
        peer.len = @sizeOf(linux.sockaddr.storage);
        const rc = linux.accept4(listen_fd, peer.ptrMut(), &peer.len, linux.SOCK.CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .CONNABORTED => continue, // peer already gone; keep accepting
            .MFILE, .NFILE => return error.FdQuota,
            .NOBUFS, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
}

/// Blocking connect(2) with a timeout via SO_SNDTIMEO (Linux honors the send
/// timeout for connection establishment). The timeout is reset to infinite
/// after the connection is up so later sends block like Go's.
pub fn connectTimeout(addr: *const SockAddr, timeout_ms: u32) SockError!fd_t {
    const fd = try socket(addr.family());
    errdefer closeFd(fd);

    const tv: linux.timeval = .{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    posix.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};

    switch (linux.errno(linux.connect(fd, addr.ptr(), addr.len))) {
        .SUCCESS => {},
        .INTR => return error.Timeout, // interrupted blocking connect: treat as failure
        .AGAIN => return error.Timeout,
        else => |e| return mapCommonErr(e),
    }

    // Back to infinite send timeout for the forwarding phase.
    const zero: linux.timeval = .{ .sec = 0, .usec = 0 };
    posix.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&zero)) catch {};
    return fd;
}

/// Send the whole buffer, retrying short writes and EINTR. MSG_NOSIGNAL so a
/// dead peer never raises SIGPIPE (we also ignore SIGPIPE in main).
pub fn writeAll(fd: fd_t, bytes: []const u8) SockError!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.sendto(fd, bytes.ptr + off, bytes.len - off, linux.MSG.NOSIGNAL, null, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => continue,
            .PIPE, .CONNRESET => return error.Refused,
            else => |e| return mapCommonErr(e),
        }
    }
}

/// Read once; 0 means EOF. Retries EINTR.
pub fn readSome(fd: fd_t, buf: []u8) SockError!usize {
    while (true) {
        const rc = linux.read(fd, buf.ptr, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            .CONNRESET => return error.Refused,
            else => |e| return mapCommonErr(e),
        }
    }
}

pub fn getSockName(fd: fd_t) SockError!SockAddr {
    var sa: SockAddr = .{};
    sa.len = @sizeOf(linux.sockaddr.storage);
    return switch (linux.errno(linux.getsockname(fd, sa.ptrMut(), &sa.len))) {
        .SUCCESS => sa,
        else => |e| mapCommonErr(e),
    };
}

pub fn sleepMs(ms: u64) void {
    var ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = linux.nanosleep(&ts, null);
}

/// Read an entire (small) file into memory.
pub fn readFileAlloc(gpa: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const fd = posix.openat(linux.AT.FDCWD, path, .{}, 0) catch return error.FileOpen;
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
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @intCast(ts.sec * 1_000_000_000 + ts.nsec);
}
