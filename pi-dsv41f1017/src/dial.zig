//! Networking helpers: host:port parsing, name resolution, timeout dial,
//! keepalive, and the libc-free socket syscalls used by the proxy.
//!
//! Zig 0.17's std.Io listen/accept path is used for the listener; dialing is
//! implemented with raw Linux syscalls because the Io connect timeout path is
//! not implemented in this standard-library revision.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const net = std.Io.net;

pub const SplitError = error{
    MissingPort,
    TooManyColons,
    InvalidPort,
    InvalidAddress,
};

pub const HostPort = struct {
    host: []const u8,
    port: u16,
};

/// Split "host:port" or "[v6addr]:port". The empty host (":1248") is allowed.
pub fn splitHostPort(addr: []const u8) SplitError!HostPort {
    if (addr.len == 0) return error.MissingPort;
    var host: []const u8 = undefined;
    var port_str: []const u8 = undefined;

    if (addr[0] == '[') {
        const close = std.mem.findScalar(u8, addr, ']') orelse return error.InvalidAddress;
        host = addr[1..close];
        if (close == addr.len - 1) return error.MissingPort;
        if (addr[close + 1] != ':') return error.InvalidAddress;
        port_str = addr[close + 2 ..];
    } else {
        const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse return error.MissingPort;
        if (std.mem.indexOfScalar(u8, addr, ':')) |first| {
            if (first != colon) return error.TooManyColons;
        }
        host = addr[0..colon];
        port_str = addr[colon + 1 ..];
    }

    if (port_str.len == 0) return error.InvalidPort;
    const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPort;
    return .{ .host = host, .port = port };
}

/// Resolve a host:port string to an IP address. Numeric literals avoid I/O;
/// names are resolved through Zig's std.Io name resolver (/etc/hosts + DNS).
pub fn resolve(io: std.Io, addr_text: []const u8) !net.IpAddress {
    const hp = splitHostPort(addr_text) catch return error.InvalidAddress;
    const host = if (hp.host.len == 0) "127.0.0.1" else hp.host;

    if (net.IpAddress.parse(host, hp.port)) |ip| {
        return ip;
    } else |_| {}

    const hn = net.HostName.init(host) catch return error.UnknownHostName;
    var results: [16]net.HostName.LookupResult = undefined;
    var queue = std.Io.Queue(net.HostName.LookupResult).init(&results);
    try net.HostName.lookup(hn, io, &queue, .{ .port = hp.port });

    var out: [1]net.HostName.LookupResult = undefined;
    while (true) {
        const n = queue.getUncancelable(io, &out, 1) catch |err| switch (err) {
            error.Closed => return error.UnknownHostName,
        };
        if (n == 0) return error.UnknownHostName;
        switch (out[0]) {
            .address => |a| return a,
            .canonical_name => continue,
        }
    }
}

fn addressToPosix(a: net.IpAddress, storage: *posix.sockaddr.storage) posix.socklen_t {
    return switch (a) {
        .ip4 => |ip4| {
            const sa: *posix.sockaddr.in = @ptrCast(@alignCast(storage));
            const raw: *align(1) const u32 = @ptrCast(&ip4.bytes);
            sa.* = .{
                .family = posix.AF.INET,
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = raw.*,
            };
            return @sizeOf(posix.sockaddr.in);
        },
        .ip6 => |ip6| {
            const sa: *posix.sockaddr.in6 = @ptrCast(@alignCast(storage));
            sa.* = .{
                .family = posix.AF.INET6,
                .port = std.mem.nativeToBig(u16, ip6.port),
                .flowinfo = ip6.flow,
                .addr = ip6.bytes,
                .scope_id = ip6.interface.index,
            };
            return @sizeOf(posix.sockaddr.in6);
        },
    };
}

pub const DialError = error{
    ConnectionRefused,
    Timeout,
    Unreachable,
    SystemResources,
    Unexpected,
    InvalidAddress,
    UnknownHostName,
    OutOfMemory,
    Canceled,
};

/// Connect with a timeout. The returned descriptor is in blocking mode.
pub fn dialTimeout(io: std.Io, addr_text: []const u8, timeout_ms: i32) !posix.fd_t {
    const addr = try resolve(io, addr_text);
    return dialIpTimeout(addr, timeout_ms);
}

pub fn dialIpTimeout(addr: net.IpAddress, timeout_ms: i32) DialError!posix.fd_t {
    var storage: posix.sockaddr.storage = undefined;
    const addr_len = addressToPosix(addr, &storage);
    const family: u32 = switch (addr) {
        .ip4 => posix.AF.INET,
        .ip6 => posix.AF.INET6,
    };

    const rc = linux.socket(family, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    const fd: posix.fd_t = switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .MFILE, .NFILE => return error.SystemResources,
        .NOBUFS, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    };
    errdefer std.Io.Threaded.closeFd(fd);

    while (true) {
        const crc = linux.connect(fd, @ptrCast(&storage), addr_len);
        switch (posix.errno(crc)) {
            .SUCCESS => break,
            .INTR => continue,
            .INPROGRESS => {
                var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
                const n = posix.poll(&pfd, timeout_ms) catch return error.Unexpected;
                if (n == 0) return error.Timeout;
                var so_err: i32 = 0;
                var optlen: posix.socklen_t = @sizeOf(i32);
                switch (posix.errno(linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&so_err), &optlen))) {
                    .SUCCESS => {},
                    else => return error.Unexpected,
                }
                if (so_err != 0) return mapConnectErrno(@enumFromInt(so_err));
                break;
            },
            .CONNREFUSED => return error.ConnectionRefused,
            .TIMEDOUT => return error.Timeout,
            .HOSTUNREACH, .NETUNREACH => return error.Unreachable,
            .ACCES, .PERM => return error.Unreachable,
            .NFILE, .MFILE, .NOBUFS, .NOMEM => return error.SystemResources,
            .AGAIN => return error.SystemResources,
            else => return error.Unexpected,
        }
    }

    // connect() needs nonblocking mode; the copy loop wants blocking mode.
    const flags_rc = linux.fcntl(fd, linux.F.GETFL, 0);
    switch (posix.errno(flags_rc)) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
    const nonblock: usize = @as(usize, 1) << @bitOffsetOf(linux.O, "NONBLOCK");
    const set_rc = linux.fcntl(fd, linux.F.SETFL, @as(usize, @intCast(flags_rc)) & ~nonblock);
    switch (posix.errno(set_rc)) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
    return fd;
}

fn mapConnectErrno(e: linux.E) DialError {
    return switch (e) {
        .CONNREFUSED => error.ConnectionRefused,
        .TIMEDOUT => error.Timeout,
        .HOSTUNREACH, .NETUNREACH => error.Unreachable,
        .ACCES, .PERM => error.Unreachable,
        else => error.Unexpected,
    };
}

/// Keepalive matching Go's SetKeepAlive(true) + SetKeepAlivePeriod(60s).
pub fn setKeepAlive(fd: posix.fd_t) !void {
    const one = std.mem.toBytes(@as(c_int, 1));
    const sixty = std.mem.toBytes(@as(c_int, 60));
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, &one);
    try posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPIDLE, &sixty);
    try posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPINTVL, &sixty);
}

pub fn ignoreSigPipe() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.PIPE, &act, null);
}

test "split host:port" {
    const hp = try splitHostPort("127.0.0.1:8080");
    try std.testing.expectEqualStrings("127.0.0.1", hp.host);
    try std.testing.expectEqual(@as(u16, 8080), hp.port);

    const name = try splitHostPort("example.com:80");
    try std.testing.expectEqualStrings("example.com", name.host);

    const empty = try splitHostPort(":1248");
    try std.testing.expectEqualStrings("", empty.host);
    try std.testing.expectEqual(@as(u16, 1248), empty.port);

    const v6 = try splitHostPort("[::1]:9090");
    try std.testing.expectEqualStrings("::1", v6.host);
}

test "split rejects bad addresses" {
    try std.testing.expectError(error.MissingPort, splitHostPort("127.0.0.1"));
    try std.testing.expectError(error.MissingPort, splitHostPort("[::1]"));
    try std.testing.expectError(error.TooManyColons, splitHostPort("a:b:c"));
    try std.testing.expectError(error.TooManyColons, splitHostPort("::1"));
    try std.testing.expectError(error.InvalidPort, splitHostPort("host:"));
    try std.testing.expectError(error.InvalidPort, splitHostPort("host:abc"));
    try std.testing.expectError(error.InvalidPort, splitHostPort("host:65536"));
    try std.testing.expectError(error.InvalidAddress, splitHostPort("[::1]x:80"));
}