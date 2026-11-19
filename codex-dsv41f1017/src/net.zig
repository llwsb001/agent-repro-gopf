const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const config = @import("config.zig");

pub const fd_t = posix.socket_t;

pub const Address = union(enum) {
    ip4: posix.sockaddr.in,
    ip6: posix.sockaddr.in6,

    fn ptr(self: *const Address) *const posix.sockaddr {
        return switch (self.*) {
            .ip4 => |*addr| @ptrCast(addr),
            .ip6 => |*addr| @ptrCast(addr),
        };
    }

    fn len(self: *const Address) posix.socklen_t {
        return switch (self.*) {
            .ip4 => @sizeOf(posix.sockaddr.in),
            .ip6 => @sizeOf(posix.sockaddr.in6),
        };
    }
};

pub const Listener = struct {
    fd: fd_t,
    port: u16,
};

pub const ShutdownHow = enum(i32) {
    RD = 0,
    WR = 1,
    RDWR = 2,
};

pub fn listen(io: std.Io, text: []const u8) !Listener {
    const hp = try config.splitHostPort(text);
    const address = try resolve(io, hp.host, hp.port, true);
    const fd = try openSocket(&address);
    errdefer close(fd);

    var one: c_int = 1;
    try setsockoptBytes(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&one));

    const bind_rc = linux.bind(fd, address.ptr(), address.len());
    if (posix.errno(bind_rc) != .SUCCESS) return socketError(posix.errno(bind_rc));
    const listen_rc = linux.listen(fd, 256);
    if (posix.errno(listen_rc) != .SUCCESS) return socketError(posix.errno(listen_rc));
    try setNonBlocking(fd, true);

    var storage: posix.sockaddr.storage = undefined;
    var storage_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    const name_rc = linux.getsockname(fd, @ptrCast(&storage), &storage_len);
    if (posix.errno(name_rc) != .SUCCESS) return socketError(posix.errno(name_rc));
    const bound = addressFromStorage(&storage);
    return .{ .fd = fd, .port = switch (bound) {
        .ip4 => |addr| std.mem.bigToNative(u16, addr.port),
        .ip6 => |addr| std.mem.bigToNative(u16, addr.port),
    } };
}

pub fn connect(io: std.Io, text: []const u8, timeout_ms: i32) !fd_t {
    const hp = try config.splitHostPort(text);
    const address = try resolve(io, hp.host, hp.port, false);
    const fd = try openSocket(&address);
    errdefer close(fd);
    try setNonBlocking(fd, true);

    const rc = linux.connect(fd, address.ptr(), address.len());
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        .INPROGRESS, .AGAIN => {
            var poll_fds = [_]posix.pollfd{.{
                .fd = fd,
                .events = posix.POLL.OUT,
                .revents = 0,
            }};
            const ready = try posix.poll(&poll_fds, timeout_ms);
            if (ready == 0) return error.Timeout;

            var socket_error: i32 = 0;
            var len: posix.socklen_t = @sizeOf(i32);
            const option_rc = linux.getsockopt(
                fd,
                posix.SOL.SOCKET,
                posix.SO.ERROR,
                @ptrCast(&socket_error),
                &len,
            );
            if (posix.errno(option_rc) != .SUCCESS) return socketError(posix.errno(option_rc));
            switch (@as(posix.E, @fromBackingInt(@intCast(socket_error)))) {
                .SUCCESS => {},
                .CONNREFUSED => return error.ConnectionRefused,
                .TIMEDOUT => return error.Timeout,
                .NETUNREACH => return error.NetworkUnreachable,
                .HOSTUNREACH => return error.HostUnreachable,
                else => return error.ConnectionFailed,
            }
        },
        .CONNREFUSED => return error.ConnectionRefused,
        .TIMEDOUT => return error.Timeout,
        .NETUNREACH => return error.NetworkUnreachable,
        .HOSTUNREACH => return error.HostUnreachable,
        else => |err| return socketError(err),
    }

    try setNonBlocking(fd, false);
    return fd;
}

pub fn accept(fd: fd_t) !fd_t {
    var storage: posix.sockaddr.storage = undefined;
    var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    const rc = linux.accept(fd, @ptrCast(&storage), &len);
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .AGAIN => error.WouldBlock,
        .INTR => error.Interrupted,
        .MFILE, .NFILE => error.ProcessFdQuotaExceeded,
        .NOBUFS, .NOMEM => error.SystemResources,
        .CONNABORTED => error.ConnectionAborted,
        .INVAL => error.ListenerStopped,
        .BADF => error.ListenerStopped,
        else => |err| socketError(err),
    };
}

pub fn read(fd: fd_t, buffer: []u8) !usize {
    return posix.read(fd, buffer) catch |err| switch (err) {
        error.WouldBlock => error.WouldBlock,
        error.ConnectionResetByPeer => error.ConnectionResetByPeer,
        error.SocketUnconnected => error.SocketUnconnected,
        else => err,
    };
}

pub fn writeAll(fd: fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = linux.sendto(fd, bytes.ptr + written, bytes.len - written, posix.MSG.NOSIGNAL, null, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.WriteZero;
                written += rc;
            },
            .INTR => continue,
            .PIPE, .CONNRESET => return error.BrokenPipe,
            .AGAIN => return error.WouldBlock,
            else => return error.WriteFailed,
        }
    }
}

pub fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

pub fn shutdown(fd: fd_t, how: ShutdownHow) void {
    _ = linux.shutdown(fd, @backingInt(how));
}

pub fn setKeepAlive(fd: fd_t) void {
    var one: c_int = 1;
    setsockoptBytes(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, std.mem.asBytes(&one)) catch {};

    const sol_tcp: i32 = 6;
    var sixty: c_int = 60;
    if (@hasDecl(posix.TCP, "KEEPIDLE"))
        setsockoptBytes(fd, sol_tcp, posix.TCP.KEEPIDLE, std.mem.asBytes(&sixty)) catch {};
    if (@hasDecl(posix.TCP, "KEEPINTVL"))
        setsockoptBytes(fd, sol_tcp, posix.TCP.KEEPINTVL, std.mem.asBytes(&sixty)) catch {};
}

pub fn setNonBlocking(fd: fd_t, enabled: bool) !void {
    const rc = linux.fcntl(fd, linux.F.GETFL, 0);
    if (posix.errno(rc) != .SUCCESS) return socketError(posix.errno(rc));
    var flags: linux.O = @bitCast(@as(u32, @intCast(rc)));
    flags.NONBLOCK = enabled;
    const set_rc = linux.fcntl(fd, linux.F.SETFL, @as(u32, @bitCast(flags)));
    if (posix.errno(set_rc) != .SUCCESS) return socketError(posix.errno(set_rc));
}

fn openSocket(address: *const Address) !fd_t {
    const domain: u32 = switch (address.*) {
        .ip4 => @intCast(posix.AF.INET),
        .ip6 => @intCast(posix.AF.INET6),
    };
    const rc = linux.socket(
        domain,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        0,
    );
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .MFILE, .NFILE => error.ProcessFdQuotaExceeded,
        .NOBUFS, .NOMEM => error.SystemResources,
        else => |err| socketError(err),
    };
}

fn setsockoptBytes(fd: fd_t, level: i32, option: u32, bytes: []const u8) !void {
    const rc = linux.setsockopt(fd, level, option, bytes.ptr, @intCast(bytes.len));
    const err = posix.errno(rc);
    if (err != .SUCCESS) return socketError(err);
}

fn resolve(io: std.Io, host: []const u8, port: u16, wildcard: bool) !Address {
    if (host.len == 0) {
        if (wildcard) return fromIp(std.Io.net.IpAddress{ .ip4 = .unspecified(port) });
        return fromIp(std.Io.net.IpAddress{ .ip4 = .loopback(port) });
    }

    if (std.Io.net.IpAddress.parse(host, port)) |ip| {
        return fromIp(ip);
    } else |_| {}

    const host_name = std.Io.net.HostName.init(host) catch return error.InvalidHost;
    var lookup_buffer: [32]std.Io.net.HostName.LookupResult = undefined;
    var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buffer);
    try host_name.lookup(io, &queue, .{ .port = port });

    while (true) {
        const item = queue.getOne(io) catch |err| switch (err) {
            error.Closed => break,
            else => return err,
        };
        switch (item) {
            .address => |ip| return fromIp(ip),
            .canonical_name => {},
        }
    }
    return error.UnknownHost;
}

fn fromIp(ip: std.Io.net.IpAddress) Address {
    return switch (ip) {
        .ip4 => |addr| .{ .ip4 = .{
            .port = std.mem.nativeToBig(u16, addr.port),
            .addr = @bitCast(addr.bytes),
        } },
        .ip6 => |addr| .{ .ip6 = .{
            .port = std.mem.nativeToBig(u16, addr.port),
            .flowinfo = 0,
            .addr = addr.bytes,
            .scope_id = 0,
        } },
    };
}

fn addressFromStorage(storage: *const posix.sockaddr.storage) Address {
    return switch (storage.family) {
        posix.AF.INET => .{ .ip4 = @as(*const posix.sockaddr.in, @ptrCast(storage)).* },
        posix.AF.INET6 => .{ .ip6 = @as(*const posix.sockaddr.in6, @ptrCast(storage)).* },
        else => unreachable,
    };
}

fn socketError(err: posix.E) anyerror {
    return switch (err) {
        .ACCES, .PERM => error.PermissionDenied,
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .CONNREFUSED => error.ConnectionRefused,
        .TIMEDOUT => error.Timeout,
        else => posix.unexpectedErrno(err),
    };
}
