//! Low-level networking helpers: host:port splitting (Go `net.SplitHostPort`
//! semantics plus numeric-port validation), name resolution, and a TCP dial
//! with a real timeout.
//!
//! The timeout-capable dial is implemented with raw Linux syscalls because
//! Zig 0.17's `std.Io.Threaded` panics on `netConnectIp` with a timeout
//! ("TODO implement netConnectIpPosix with timeout"), so we cannot go through
//! the Io interface for that.

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

/// Split "host:port" or "[v6addr]:port". Unlike Go we additionally require
/// the port to be a valid number, since this proxy can only dial numeric
/// ports anyway. Empty host is allowed (":8080" — Go treats it as localhost
/// when dialing and wildcard when listening).
pub fn splitHostPort(addr: []const u8) SplitError!HostPort {
    if (addr.len == 0) return error.MissingPort;

    var host: []const u8 = undefined;
    var port_str: []const u8 = undefined;

    if (addr[0] == '[') {
        // Bracketed (IPv6) form: [host]:port or [host]
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

pub const ResolveError = error{
    UnknownHostName,
    InvalidAddress,
    OutOfMemory,
} || net.HostName.LookupError || std.Io.Cancelable;

/// Resolve a host:port string to an IP address. Tries IP literals first
/// (cheap, no IO), then falls back to real name resolution.
pub fn resolve(io: std.Io, addr_text: []const u8) ResolveError!net.IpAddress {
    const hp = splitHostPort(addr_text) catch return error.InvalidAddress;
    const host = if (hp.host.len == 0) "127.0.0.1" else hp.host;

    if (net.IpAddress.parse(host, hp.port)) |ip| {
        return ip;
    } else |_| {}

    // Hostname resolution (reads /etc/hosts, DNS; "localhost" is
    // special-cased to loopback by the Io implementation).
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

/// Convert an IpAddress to a posix sockaddr. Returns the sockaddr length.
fn addressToPosix(a: net.IpAddress, storage: *posix.sockaddr.storage) posix.socklen_t {
    return switch (a) {
        .ip4 => |ip4| {
            const sa: *posix.sockaddr.in = @ptrCast(@alignCast(storage));
            const addr_raw: *align(1) const u32 = @ptrCast(&ip4.bytes);
            sa.* = .{
                .family = posix.AF.INET,
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = addr_raw.*,
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
} || ResolveError;

/// Connect to "host:port" with a timeout. Returns a blocking-mode fd.
pub fn dialTimeout(io: std.Io, addr_text: []const u8, timeout_ms: i32) DialError!posix.fd_t {
    const addr = try resolve(io, addr_text);
    return dialIpTimeout(addr, timeout_ms);
}

/// Connect to an already-resolved address with a timeout. Returns a
/// blocking-mode fd.
pub fn dialIpTimeout(addr: net.IpAddress, timeout_ms: i32) DialError!posix.fd_t {
    var storage: posix.sockaddr.storage = undefined;
    const addr_len = addressToPosix(addr, &storage);
    const family: u32 = switch (addr) {
        .ip4 => posix.AF.INET,
        .ip6 => posix.AF.INET6,
    };

    const fd_rc = linux.socket(family, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    const fd: posix.fd_t = switch (posix.errno(fd_rc)) {
        .SUCCESS => @intCast(fd_rc),
        .MFILE, .NFILE => return error.SystemResources,
        .NOBUFS, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    };
    errdefer std.Io.Threaded.closeFd(fd);

    while (true) {
        const rc = linux.connect(fd, @ptrCast(&storage), addr_len);
        switch (posix.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            .INPROGRESS => {
                var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
                const n = posix.poll(&pfd, timeout_ms) catch return error.Unexpected;
                if (n == 0) return error.Timeout;
                var so_err: i32 = 0;
                var optlen: posix.socklen_t = @sizeOf(i32);
                const grc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&so_err), &optlen);
                switch (posix.errno(grc)) {
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

    // Restore blocking mode: clear O_NONBLOCK.
    const flags_rc = linux.fcntl(fd, linux.F.GETFL, 0);
    switch (posix.errno(flags_rc)) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
    const nonblock_bit: usize = @as(usize, 1) << @bitOffsetOf(linux.O, "NONBLOCK");
    const set_rc = linux.fcntl(fd, linux.F.SETFL, @as(usize, @intCast(flags_rc)) & ~nonblock_bit);
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

/// Enable TCP keepalive with a 60-second idle/interval, matching the Go
/// reference's SetKeepAlive(true) + SetKeepAlivePeriod(60s).
pub fn setKeepAlive(fd: posix.fd_t) !void {
    const one = std.mem.toBytes(@as(c_int, 1));
    const sixty = std.mem.toBytes(@as(c_int, 60));
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, &one);
    try posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPIDLE, &sixty);
    try posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPINTVL, &sixty);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "splitHostPort ipv4" {
    const hp = try splitHostPort("127.0.0.1:8080");
    try testing.expectEqualStrings("127.0.0.1", hp.host);
    try testing.expectEqual(@as(u16, 8080), hp.port);
}

test "splitHostPort hostname" {
    const hp = try splitHostPort("example.com:80");
    try testing.expectEqualStrings("example.com", hp.host);
    try testing.expectEqual(@as(u16, 80), hp.port);
}

test "splitHostPort empty host" {
    const hp = try splitHostPort(":1248");
    try testing.expectEqualStrings("", hp.host);
    try testing.expectEqual(@as(u16, 1248), hp.port);
}

test "splitHostPort bracketed ipv6" {
    const hp = try splitHostPort("[::1]:9090");
    try testing.expectEqualStrings("::1", hp.host);
    try testing.expectEqual(@as(u16, 9090), hp.port);
}

test "splitHostPort rejects bad addresses" {
    try testing.expectError(error.MissingPort, splitHostPort("127.0.0.1"));
    try testing.expectError(error.MissingPort, splitHostPort("[::1]"));
    try testing.expectError(error.TooManyColons, splitHostPort("a:b:c"));
    try testing.expectError(error.TooManyColons, splitHostPort("::1"));
    try testing.expectError(error.InvalidPort, splitHostPort("host:"));
    try testing.expectError(error.InvalidPort, splitHostPort("host:abc"));
    try testing.expectError(error.InvalidPort, splitHostPort("host:65536"));
    try testing.expectError(error.InvalidAddress, splitHostPort("[::1]x:80"));
}
