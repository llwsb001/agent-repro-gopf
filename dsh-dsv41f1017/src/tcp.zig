//! Small blocking TCP layer built directly on Linux syscalls.
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Io = std.Io;

pub const Error = error{
    InvalidAddress,
    UnknownHost,
    AddressFamilyNotSupported,
    ProtocolNotSupported,
    PermissionDenied,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ConnectionRefused,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    NetworkUnreachable,
    HostUnreachable,
    AddressNotAvailable,
    AlreadyConnected,
    WouldBlock,
    BrokenPipe,
    SocketUnconnected,
    Unexpected,
};

pub const SockAddr = union(enum) {
    in: posix.sockaddr.in,
    in6: posix.sockaddr.in6,

    pub fn ptr(self: *const SockAddr) *const posix.sockaddr {
        return @ptrCast(self);
    }

    pub fn len(self: *const SockAddr) posix.socklen_t {
        return switch (self.*) {
            .in => @sizeOf(posix.sockaddr.in),
            .in6 => @sizeOf(posix.sockaddr.in6),
        };
    }
};

pub fn sockAddr(ip: Io.net.IpAddress) SockAddr {
    return switch (ip) {
        .ip4 => |a| .{ .in = .{
            .port = std.mem.nativeToBig(u16, a.port),
            .addr = @bitCast(a.bytes),
        } },
        .ip6 => |a| .{ .in6 = .{
            .port = std.mem.nativeToBig(u16, a.port),
            .addr = a.bytes,
            .flowinfo = 0,
            .scope_id = 0,
        } },
    };
}

fn createSocket(domain: u32, ty: u32) Error!posix.fd_t {
    while (true) {
        const rc = linux.socket(domain, ty, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .PROTONOSUPPORT => return error.ProtocolNotSupported,
            .ACCES, .PERM => return error.PermissionDenied,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
}

fn errnoToConnectError(e: posix.E) Error {
    return switch (e) {
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .TIMEDOUT => error.ConnectionTimedOut,
        .NETUNREACH => error.NetworkUnreachable,
        .HOSTUNREACH => error.HostUnreachable,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .AFNOSUPPORT => error.AddressFamilyNotSupported,
        .ACCES, .PERM => error.PermissionDenied,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => error.SystemResources,
        .ISCONN => error.AlreadyConnected,
        .AGAIN, .INPROGRESS => error.WouldBlock,
        else => error.Unexpected,
    };
}

pub fn nowMs() u64 {
    var ts: posix.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    if (ts.sec < 0) return 0;
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(@max(ts.nsec, 0));
    return sec * 1000 + nsec / std.time.ns_per_ms;
}

pub fn sleepMs(ms: u64) void {
    var req: posix.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    while (true) {
        const rc = linux.nanosleep(&req, &req);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return,
        }
    }
}

/// Resolve a host string used by a config file. Numeric addresses and
/// localhost are handled directly; /etc/hosts supplies the remaining simple
/// name lookups (no recursive DNS resolver is needed for the proxy's use case).
pub fn resolveHost(host: []const u8) Error!Io.net.IpAddress {
    const name = if (host.len == 0) "127.0.0.1" else host;
    if (Io.net.IpAddress.parse(name, 0)) |ip| return ip else |_| {}
    if (std.ascii.eqlIgnoreCase(name, "localhost")) {
        return .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    }
    return resolveHostsFile(name) catch error.UnknownHost;
}

fn resolveHostsFile(name: []const u8) !Io.net.IpAddress {
    const data = try @import("config.zig").readFileAlloc(std.heap.page_allocator, "/etc/hosts", 1024 * 1024);
    defer std.heap.page_allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const clean = std.mem.trim(u8, line, " \t\r");
        if (clean.len == 0 or clean[0] == '#') continue;
        var it = std.mem.tokenizeAny(u8, clean, " \t");
        const ip_text = it.next() orelse continue;
        var matched = false;
        while (it.next()) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate, name)) {
                matched = true;
                break;
            }
        }
        if (!matched) continue;
        const ip = Io.net.IpAddress.parse(ip_text, 0) catch continue;
        return ip;
    }
    return error.UnknownHost;
}

pub fn parseListenAddress(s: []const u8) Error!SockAddr {
    var host: []const u8 = undefined;
    var port: u16 = undefined;
    if (s.len > 0 and s[0] == '[') {
        const hp = @import("config.zig").splitHostPort(s) catch return error.InvalidAddress;
        host = hp.host;
        port = hp.port;
    } else if (s.len > 0 and s[0] == ':') {
        host = "";
        port = std.fmt.parseInt(u16, s[1..], 10) catch return error.InvalidAddress;
    } else {
        const hp = @import("config.zig").splitHostPort(s) catch return error.InvalidAddress;
        host = hp.host;
        port = hp.port;
    }

    if (host.len == 0 or std.mem.eql(u8, host, "*")) {
        return .{ .in = .{ .port = std.mem.nativeToBig(u16, port), .addr = 0 } };
    }
    const ip = resolveHost(host) catch return error.InvalidAddress;
    var sa = sockAddr(ip);
    switch (sa) {
        inline else => |*a| a.port = std.mem.nativeToBig(u16, port),
    }
    return sa;
}

pub const ConnectStart = struct {
    socket: Socket,
    pending: bool,
};

pub const Socket = struct {
    fd: posix.fd_t,

    pub fn listen(address: []const u8) Error!Socket {
        const sa = try parseListenAddress(address);
        const domain: u32 = switch (sa) {
            .in => posix.AF.INET,
            .in6 => posix.AF.INET6,
        };
        const fd = try createSocket(domain, posix.SOCK.STREAM | posix.SOCK.CLOEXEC);
        errdefer _ = linux.close(fd);

        var one: c_int = 1;
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&one)) catch {};
        const rc = linux.bind(fd, sa.ptr(), sa.len());
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .ADDRINUSE => return error.AddressNotAvailable,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .ACCES, .PERM => return error.PermissionDenied,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .INVAL => return error.InvalidAddress,
            else => return error.Unexpected,
        }
        const lrc = linux.listen(fd, 1024);
        switch (posix.errno(lrc)) {
            .SUCCESS => {},
            .ADDRINUSE => return error.AddressNotAvailable,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
        return .{ .fd = fd };
    }

    pub fn beginConnect(host: []const u8, port: u16) Error!ConnectStart {
        const ip = try resolveHost(host);
        var sa = sockAddr(ip);
        switch (sa) {
            inline else => |*a| a.port = std.mem.nativeToBig(u16, port),
        }
        const domain: u32 = switch (sa) {
            .in => posix.AF.INET,
            .in6 => posix.AF.INET6,
        };
        const fd = try createSocket(domain, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK);
        errdefer _ = linux.close(fd);

        const rc = linux.connect(fd, sa.ptr(), sa.len());
        return switch (posix.errno(rc)) {
            .SUCCESS => .{ .socket = .{ .fd = fd }, .pending = false },
            .INPROGRESS, .AGAIN => .{ .socket = .{ .fd = fd }, .pending = true },
            else => |e| errnoToConnectError(e),
        };
    }

    pub fn finishConnect(self: Socket) Error!void {
        var err_code: c_int = 0;
        var elen: posix.socklen_t = @sizeOf(c_int);
        const grc = linux.getsockopt(self.fd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&err_code), &elen);
        if (posix.errno(grc) != .SUCCESS) return error.Unexpected;
        if (err_code != 0) return errnoToConnectError(@enumFromInt(err_code));
    }

    pub fn setBlocking(self: Socket) void {
        const flags = linux.fcntl(self.fd, linux.F.GETFL, 0);
        if (posix.errno(flags) == .SUCCESS) {
            const nonblock_bit: u32 = 1 << @bitOffsetOf(linux.O, "NONBLOCK");
            _ = linux.fcntl(self.fd, linux.F.SETFL, @as(u32, @intCast(flags)) & ~nonblock_bit);
        }
    }

    pub fn setNonBlocking(self: Socket) void {
        const flags = linux.fcntl(self.fd, linux.F.GETFL, 0);
        if (posix.errno(flags) == .SUCCESS) {
            const nonblock_bit: u32 = 1 << @bitOffsetOf(linux.O, "NONBLOCK");
            _ = linux.fcntl(self.fd, linux.F.SETFL, @as(u32, @intCast(flags)) | nonblock_bit);
        }
    }

    pub fn connect(host: []const u8, port: u16, timeout_ms: u64) Error!Socket {
        const started = try beginConnect(host, port);
        if (!started.pending) {
            started.socket.setBlocking();
            return started.socket;
        }

        const deadline = nowMs() + timeout_ms;
        while (true) {
            const remaining = deadline -| nowMs();
            if (remaining == 0) {
                started.socket.close();
                return error.ConnectionTimedOut;
            }
            var pfd = [1]posix.pollfd{.{ .fd = started.socket.fd, .events = posix.POLL.OUT }};
            const prc = posix.poll(&pfd, @intCast(@min(remaining, std.math.maxInt(i32)))) catch {
                started.socket.close();
                return error.Unexpected;
            };
            if (prc == 0) continue;
            break;
        }
        started.socket.finishConnect() catch |err| {
            started.socket.close();
            return err;
        };
        started.socket.setBlocking();
        return started.socket;
    }

    pub fn accept(self: *const Socket) Error!Socket {
        while (true) {
            const rc = linux.accept4(self.fd, null, null, posix.SOCK.CLOEXEC);
            switch (posix.errno(rc)) {
                .SUCCESS => return .{ .fd = @intCast(rc) },
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS, .NOMEM => return error.SystemResources,
                .CONNABORTED => return error.ConnectionResetByPeer,
                else => return error.Unexpected,
            }
        }
    }

    pub fn acceptNonBlocking(self: *const Socket) Error!Socket {
        while (true) {
            const rc = linux.accept4(self.fd, null, null, posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK);
            switch (posix.errno(rc)) {
                .SUCCESS => return .{ .fd = @intCast(rc) },
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS, .NOMEM => return error.SystemResources,
                .CONNABORTED => return error.ConnectionResetByPeer,
                else => return error.Unexpected,
            }
        }
    }

    pub fn close(self: Socket) void {
        _ = linux.close(self.fd);
    }

    pub fn shutdownWrite(self: Socket) void {
        _ = linux.shutdown(self.fd, posix.SHUT.WR);
    }

    pub fn read(self: Socket, buf: []u8) !usize {
        return posix.read(self.fd, buf);
    }

    pub fn writeSome(self: Socket, data: []const u8) Error!usize {
        if (data.len == 0) return 0;
        while (true) {
            const rc = linux.sendto(self.fd, data.ptr, data.len, posix.MSG.NOSIGNAL, null, 0);
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .PIPE => return error.BrokenPipe,
                .CONNRESET => return error.ConnectionResetByPeer,
                .NOTCONN => return error.SocketUnconnected,
                .NOBUFS, .NOMEM => return error.SystemResources,
                else => return error.Unexpected,
            }
        }
    }

    pub fn writeAll(self: Socket, data: []const u8) !void {
        var off: usize = 0;
        while (off < data.len) {
            off += try self.writeSome(data[off..]);
        }
    }

    pub fn setNoDelay(self: Socket) void {
        var one: c_int = 1;
        posix.setsockopt(self.fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&one)) catch {};
    }

    pub fn setKeepAlive(self: Socket, idle_s: u32) void {
        var one: c_int = 1;
        posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, std.mem.asBytes(&one)) catch {};
        var idle: c_int = @intCast(idle_s);
        posix.setsockopt(self.fd, posix.IPPROTO.TCP, posix.TCP.KEEPIDLE, std.mem.asBytes(&idle)) catch {};
        var intvl: c_int = 10;
        posix.setsockopt(self.fd, posix.IPPROTO.TCP, posix.TCP.KEEPINTVL, std.mem.asBytes(&intvl)) catch {};
        var cnt: c_int = 3;
        posix.setsockopt(self.fd, posix.IPPROTO.TCP, posix.TCP.KEEPCNT, std.mem.asBytes(&cnt)) catch {};
    }

    pub fn localPort(self: Socket) u16 {
        var sa: posix.sockaddr.in = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        const rc = linux.getsockname(self.fd, @ptrCast(&sa), &len);
        if (posix.errno(rc) != .SUCCESS) return 0;
        return std.mem.bigToNative(u16, sa.port);
    }
};
