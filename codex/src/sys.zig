const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const is_linux = builtin.os.tag == .linux;

pub const Fd = std.posix.fd_t;

pub const Address = struct {
    storage: c.sockaddr.storage,
    len: c.socklen_t,

    fn ptr(self: *const Address) *const c.sockaddr {
        return @ptrCast(&self.storage);
    }
};

pub const HostPort = struct {
    host: []const u8,
    port: u16,
};

pub fn splitAddress(text: []const u8, passive: bool) !HostPort {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidAddress;

    const host, const service = if (std.mem.startsWith(u8, text, "[")) parts: {
        const bracket = std.mem.indexOfScalar(u8, text, ']') orelse return error.InvalidAddress;
        if (bracket == 1 or bracket + 1 >= text.len or text[bracket + 1] != ':') {
            return error.InvalidAddress;
        }
        break :parts .{ text[1..bracket], text[bracket + 2 ..] };
    } else parts: {
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidAddress;
        break :parts .{ text[0..colon], text[colon + 1 ..] };
    };
    if (std.mem.indexOfAny(u8, host, "[]") != null or service.len == 0) return error.InvalidAddress;
    for (service) |digit| {
        if (!std.ascii.isDigit(digit)) return error.InvalidAddress;
    }
    const port = std.fmt.parseInt(u16, service, 10) catch return error.InvalidAddress;
    if (port == 0 and !passive) return error.InvalidAddress;
    return .{ .host = host, .port = port };
}

/// Copies the TCP addresses out of libc's result list, in resolver order.
pub fn resolve(allocator: std.mem.Allocator, text: []const u8, passive: bool) ![]Address {
    const parts = try splitAddress(text, passive);
    const host = if (parts.host.len != 0) try allocator.dupeSentinel(u8, parts.host, 0) else null;
    defer if (host) |name| allocator.free(name);
    var service_buffer: [6]u8 = undefined;
    const service = std.fmt.bufPrintSentinel(&service_buffer, "{d}", .{parts.port}, 0) catch unreachable;

    var hints = std.mem.zeroes(c.addrinfo);
    hints.flags = .{ .PASSIVE = passive, .NUMERICSERV = true };
    hints.family = c.AF.UNSPEC;
    hints.socktype = c.SOCK.STREAM;
    hints.protocol = c.IPPROTO.TCP;

    var result: ?*c.addrinfo = null;
    const rc = c.getaddrinfo(if (host) |name| name.ptr else null, service.ptr, &hints, &result);
    if (@backingInt(rc) != 0) return switch (rc) {
        .MEMORY => error.OutOfMemory,
        .AGAIN => error.AddressResolutionTemporaryFailure,
        .NONAME, .NODATA => error.UnknownHost,
        else => error.AddressResolutionFailed,
    };
    const first = result orelse return error.UnknownHost;
    defer c.freeaddrinfo(first);

    var addresses: std.ArrayList(Address) = .empty;
    errdefer addresses.deinit(allocator);
    var next: ?*c.addrinfo = first;
    while (next) |entry| : (next = entry.next) {
        if (entry.family != c.AF.INET and entry.family != c.AF.INET6) continue;
        const address = entry.addr orelse continue;
        var storage = std.mem.zeroes(c.sockaddr.storage);
        const source: [*]const u8 = @ptrCast(address);
        @memcpy(std.mem.asBytes(&storage)[0..entry.addrlen], source[0..entry.addrlen]);
        try addresses.append(allocator, .{ .storage = storage, .len = entry.addrlen });
    }
    if (addresses.items.len == 0) return error.UnknownHost;
    return addresses.toOwnedSlice(allocator);
}

pub fn listen(address: Address) !Fd {
    const fd = try openSocket(address.storage.family);
    errdefer close(fd);
    try setSocketInt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, 1);
    try check(c.bind(fd, address.ptr(), address.len));
    try check(c.listen(fd, 1024));
    return fd;
}

pub fn boundPort(fd: Fd) !u16 {
    var storage: c.sockaddr.storage = undefined;
    var len: c.socklen_t = @sizeOf(c.sockaddr.storage);
    try check(c.getsockname(fd, @ptrCast(&storage), &len));
    const network_port = switch (storage.family) {
        c.AF.INET => @as(*const c.sockaddr.in, @ptrCast(&storage)).port,
        c.AF.INET6 => @as(*const c.sockaddr.in6, @ptrCast(&storage)).port,
        else => return error.AddressFamilyUnsupported,
    };
    return std.mem.bigToNative(u16, network_port);
}

pub fn accept(fd: Fd) !?Fd {
    while (true) {
        const accepted = if (is_linux)
            c.accept4(fd, null, null, c.SOCK.NONBLOCK | c.SOCK.CLOEXEC)
        else
            c.accept(fd, null, null);
        switch (c.errno(accepted)) {
            .SUCCESS => {
                errdefer close(accepted);
                if (!is_linux) try setDescriptorFlags(accepted);
                try configurePeer(accepted);
                return accepted;
            },
            .INTR => continue,
            .AGAIN => return null,
            else => |err| return socketError(err),
        }
    }
}

pub const ConnectResult = struct {
    fd: Fd,
    connected: bool,
};

pub fn connect(address: Address) !ConnectResult {
    const fd = try openSocket(address.storage.family);
    errdefer close(fd);
    try configurePeer(fd);
    const connected = switch (c.errno(c.connect(fd, address.ptr(), address.len))) {
        .SUCCESS, .ISCONN => true,
        .INPROGRESS, .ALREADY, .INTR => false,
        else => |err| return socketError(err),
    };
    return .{ .fd = fd, .connected = connected };
}

pub fn finishConnect(fd: Fd) !void {
    var socket_error: c_int = undefined;
    var len: c.socklen_t = @sizeOf(c_int);
    try check(c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, &socket_error, &len));
    if (socket_error != 0) return socketError(@fromBackingInt(@intCast(socket_error)));
}

/// A zero count from a nonempty buffer is EOF. Null means try again on readiness.
pub fn read(fd: Fd, bytes: []u8) !?usize {
    while (true) {
        const count = c.read(fd, bytes.ptr, bytes.len);
        switch (c.errno(count)) {
            .SUCCESS => return @intCast(count),
            .INTR => continue,
            .AGAIN => return null,
            else => |err| return socketError(err),
        }
    }
}

pub fn write(fd: Fd, bytes: []const u8) !?usize {
    const flags = if (is_linux) c.MSG.NOSIGNAL else 0;
    while (true) {
        const count = c.send(fd, bytes.ptr, bytes.len, flags);
        switch (c.errno(count)) {
            .SUCCESS => return @intCast(count),
            .INTR => continue,
            .AGAIN => return null,
            else => |err| return socketError(err),
        }
    }
}

pub fn shutdownWrite(fd: Fd) void {
    while (c.errno(c.shutdown(fd, c.SHUT.WR)) == .INTR) {}
}

pub fn close(fd: Fd) void {
    _ = c.close(fd);
}

pub fn wakePipeFd(fd: Fd) void {
    // Signal handlers also use this. A full pipe already represents a wakeup.
    const errno = c._errno();
    const previous = errno.*;
    defer errno.* = previous;
    const byte = [_]u8{1};
    while (c.errno(c.write(fd, &byte, byte.len)) == .INTR) {}
}

pub const WakePipe = struct {
    read_fd: Fd,
    write_fd: Fd,

    pub fn init() !WakePipe {
        var fds: [2]Fd = undefined;
        if (is_linux) {
            try check(c.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true }));
        } else {
            try check(c.pipe(&fds));
            errdefer for (fds) |fd| close(fd);
            for (fds) |fd| try setDescriptorFlags(fd);
        }
        return .{ .read_fd = fds[0], .write_fd = fds[1] };
    }

    pub fn deinit(self: *WakePipe) void {
        close(self.write_fd);
        close(self.read_fd);
        self.* = undefined;
    }

    pub fn wake(self: WakePipe) void {
        wakePipeFd(self.write_fd);
    }

    pub fn drain(self: WakePipe) void {
        var buffer: [256]u8 = undefined;
        while (true) {
            const count = c.read(self.read_fd, &buffer, buffer.len);
            switch (c.errno(count)) {
                .SUCCESS => if (count == 0) return,
                .INTR => continue,
                else => return,
            }
        }
    }
};

fn openSocket(family: c.sa_family_t) !Fd {
    const flags = c.SOCK.STREAM | if (is_linux) c.SOCK.NONBLOCK | c.SOCK.CLOEXEC else 0;
    const fd = c.socket(family, flags, c.IPPROTO.TCP);
    try check(fd);
    errdefer close(fd);
    if (!is_linux) try setDescriptorFlags(fd);
    return fd;
}

fn setDescriptorFlags(fd: Fd) !void {
    const status_flags = c.fcntl(fd, c.F.GETFL);
    try check(status_flags);
    const nonblocking: c_int = @bitCast(c.O{ .NONBLOCK = true });
    try check(c.fcntl(fd, c.F.SETFL, status_flags | nonblocking));
    try check(c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)));
}

fn configurePeer(fd: Fd) !void {
    if (!is_linux) try setSocketInt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, 1);
    try setSocketInt(fd, c.SOL.SOCKET, c.SO.KEEPALIVE, 1);
    const keep_idle = if (is_linux) c.TCP.KEEPIDLE else c.TCP.KEEPALIVE;
    try setSocketInt(fd, c.IPPROTO.TCP, keep_idle, 60);
    try setSocketInt(fd, c.IPPROTO.TCP, c.TCP.KEEPINTVL, 60);
}

fn setSocketInt(fd: Fd, level: c_int, option: u32, value: c_int) !void {
    try check(c.setsockopt(fd, level, option, &value, @sizeOf(c_int)));
}

fn check(rc: c_int) !void {
    const err = c.errno(rc);
    if (err != .SUCCESS) return socketError(err);
}

fn socketError(err: c.E) anyerror {
    return switch (err) {
        .ACCES, .PERM => error.AccessDenied,
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .CONNABORTED => error.ConnectionAborted,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .HOSTUNREACH => error.HostUnreachable,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NETDOWN => error.NetworkDown,
        .NETUNREACH => error.NetworkUnreachable,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => error.SystemResources,
        .NOTCONN => error.SocketUnconnected,
        .PIPE => error.BrokenPipe,
        .TIMEDOUT => error.Timeout,
        else => error.UnexpectedSocketError,
    };
}
