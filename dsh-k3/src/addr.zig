//! IPv4 地址与 host:port 解析。
//!
//! 语义对齐 Go 参考实现里用到的 net.SplitHostPort / net.ResolveTCPAddr 的
//! 子集：后端与监听地址必须是 `host:port` 形式；host 支持 IPv4 字面量或
//! "localhost"；监听地址允许空 host（表示 0.0.0.0）。端口必须是非空的
//! 十进制数字且在 0..65535 之内。

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{InvalidAddress};

pub const Ip4 = struct {
    octets: [4]u8,
    port: u16,

    pub const any = Ip4{ .octets = .{ 0, 0, 0, 0 }, .port = 0 };
    pub const loopback = Ip4{ .octets = .{ 127, 0, 0, 1 }, .port = 0 };

    /// 转为内核使用的 sockaddr_in（网络字节序）。
    pub fn sockaddrIn(self: Ip4) linux.sockaddr.in {
        return .{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, self.port),
            .addr = @bitCast(self.octets),
            .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        };
    }

    pub fn fromSockaddrIn(sa: linux.sockaddr.in) Ip4 {
        return .{
            .octets = @bitCast(sa.addr),
            .port = std.mem.bigToNative(u16, sa.port),
        };
    }

    pub fn formatBuf(self: Ip4, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}:{d}", .{
            self.octets[0], self.octets[1], self.octets[2], self.octets[3], self.port,
        }) catch unreachable;
    }

    pub fn eql(a: Ip4, b: Ip4) bool {
        return a.port == b.port and std.mem.eql(u8, &a.octets, &b.octets);
    }
};

/// 解析 "a.b.c.d" 形式的 IPv4 字面量，非法返回 null。
pub fn parseIp4(text: []const u8) ?[4]u8 {
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, text, '.');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= 4) return null;
        if (part.len == 0 or part.len > 3) return null;
        var v: u16 = 0;
        for (part) |c| {
            if (c < '0' or c > '9') return null;
            v = v * 10 + (c - '0');
        }
        if (v > 255) return null;
        octets[i] = @intCast(v);
        i += 1;
    }
    if (i != 4) return null;
    return octets;
}

pub const HostPort = struct { host: []const u8, port: u16 };

/// 把 "host:port" 拆成主机与端口。host 里再出现 ':' 视为非法
/// （不支持 IPv6 字面量，与后端都是 IPv4 的场景一致）。
pub fn splitHostPort(text: []const u8, allow_empty_host: bool) Error!HostPort {
    const idx = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.InvalidAddress;
    const host = text[0..idx];
    const port_text = text[idx + 1 ..];
    if (std.mem.indexOfScalar(u8, host, ':') != null) return error.InvalidAddress;
    if (port_text.len == 0 or port_text.len > 5) return error.InvalidAddress;
    if (!allow_empty_host and host.len == 0) return error.InvalidAddress;
    var port: u32 = 0;
    for (port_text) |c| {
        if (c < '0' or c > '9') return error.InvalidAddress;
        port = port * 10 + (c - '0');
    }
    if (port > 65535) return error.InvalidAddress;
    return .{ .host = host, .port = @intCast(port) };
}

fn resolveHost(host: []const u8) Error![4]u8 {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return .{ 127, 0, 0, 1 };
    return parseIp4(host) orelse error.InvalidAddress;
}

/// 解析后端地址：host 必须非空且可解析（IPv4 字面量或 localhost）。
pub fn parseBackend(text: []const u8) Error!Ip4 {
    const hp = try splitHostPort(text, false);
    return .{ .octets = try resolveHost(hp.host), .port = hp.port };
}

/// 解析监听地址：允许 ":port"（空 host → 0.0.0.0）。
pub fn parseListen(text: []const u8) Error!Ip4 {
    const hp = try splitHostPort(text, true);
    if (hp.host.len == 0) return .{ .octets = .{ 0, 0, 0, 0 }, .port = hp.port };
    return .{ .octets = try resolveHost(hp.host), .port = hp.port };
}

// ---------------------------------------------------------------------------
// 单元测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseIp4 valid and invalid" {
    try testing.expectEqual([4]u8{ 127, 0, 0, 1 }, parseIp4("127.0.0.1").?);
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, parseIp4("0.0.0.0").?);
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, parseIp4("255.255.255.255").?);
    try testing.expect(parseIp4("256.0.0.1") == null);
    try testing.expect(parseIp4("1.2.3") == null);
    try testing.expect(parseIp4("1.2.3.4.5") == null);
    try testing.expect(parseIp4("1.2.3.a") == null);
    try testing.expect(parseIp4("") == null);
    try testing.expect(parseIp4("1.2.3.") == null);
}

test "splitHostPort" {
    const hp = try splitHostPort("127.0.0.1:8080", false);
    try testing.expectEqualStrings("127.0.0.1", hp.host);
    try testing.expectEqual(@as(u16, 8080), hp.port);

    // 空 host 仅在允许时合法
    try testing.expectError(error.InvalidAddress, splitHostPort(":80", false));
    const hp2 = try splitHostPort(":80", true);
    try testing.expectEqualStrings("", hp2.host);
    try testing.expectEqual(@as(u16, 80), hp2.port);

    // 非法形式
    try testing.expectError(error.InvalidAddress, splitHostPort("nocolon", false));
    try testing.expectError(error.InvalidAddress, splitHostPort("host:", false));
    try testing.expectError(error.InvalidAddress, splitHostPort("host:abc", false));
    try testing.expectError(error.InvalidAddress, splitHostPort("host:65536", false));
    try testing.expectError(error.InvalidAddress, splitHostPort("a:b:80", false));
}

test "parseBackend / parseListen" {
    const a = try parseBackend("127.0.0.1:18091");
    try testing.expect(a.eql(.{ .octets = .{ 127, 0, 0, 1 }, .port = 18091 }));
    const b = try parseBackend("localhost:80");
    try testing.expect(b.eql(.{ .octets = .{ 127, 0, 0, 1 }, .port = 80 }));
    try testing.expectError(error.InvalidAddress, parseBackend(":80"));
    try testing.expectError(error.InvalidAddress, parseBackend("example.com:80"));

    const l = try parseListen(":1248");
    try testing.expect(l.eql(.{ .octets = .{ 0, 0, 0, 0 }, .port = 1248 }));
    const l2 = try parseListen("127.0.0.1:12481");
    try testing.expect(l2.eql(.{ .octets = .{ 127, 0, 0, 1 }, .port = 12481 }));
}

test "sockaddrIn round trip" {
    const a = Ip4{ .octets = .{ 10, 1, 2, 3 }, .port = 8080 };
    const sa = a.sockaddrIn();
    try testing.expectEqual(linux.AF.INET, sa.family);
    const b = Ip4.fromSockaddrIn(sa);
    try testing.expect(a.eql(b));
}
