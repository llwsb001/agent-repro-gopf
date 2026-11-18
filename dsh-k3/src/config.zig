//! 配置解析与校验。
//!
//! 配置文件是 JSON：`{"hosts":[{"addr":"host:port","weight":100}]}`。
//! 与 Go 版 encoding/json 一样，键名大小写不敏感，未知字段忽略。
//! 校验规则（任何一项非法都导致整次加载失败）：
//!   - addr 必须能拆成 host:port 且 host 可解析为 IPv4（或 localhost）；
//!   - weight 不得为负；
//!   - hosts 缺失或为空、所有 weight 为 0 都合法（表示无可用后端）。

const std = @import("std");
const linux = std.os.linux;
const json = std.json;
const addrz = @import("addr.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidConfig,
    InvalidAddress,
    NegativeWeight,
    NameTooLong,
    OpenFailed,
    ReadFailed,
    OutOfMemory,
};

pub const Host = struct {
    /// 规范化后的 "a.b.c.d:port"，用于日志与状态输出。
    text: []u8,
    addr: addrz.Ip4,
    weight: u64,
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    hosts: []Host,
    weight_sum: u64,

    pub fn deinit(self: *Config) void {
        _ = self.arena.deinit();
    }
};

/// 大小写不敏感地取对象字段（对齐 Go encoding/json 的行为）。
fn objGetCI(obj: json.ObjectMap, key: []const u8) ?json.Value {
    var it = obj.iterator();
    while (it.next()) |e| {
        if (std.ascii.eqlIgnoreCase(e.key_ptr.*, key)) return e.value_ptr.*;
    }
    return null;
}

/// 从 JSON 文本解析并校验配置。返回的 Config 自持一块 arena，
/// 调用方用 `cfg.deinit()` 释放。
pub fn parse(child_alloc: Allocator, bytes: []const u8) Error!Config {
    var arena = std.heap.ArenaAllocator.init(child_alloc);
    errdefer _ = arena.deinit();
    const a = arena.allocator();

    const root = json.parseFromSliceLeaky(json.Value, a, bytes, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidConfig,
    };
    if (root != .object) return error.InvalidConfig;

    var hosts: std.ArrayList(Host) = .empty;
    var weight_sum: u64 = 0;

    if (objGetCI(root.object, "hosts")) |hosts_val| {
        if (hosts_val != .array) return error.InvalidConfig;
        for (hosts_val.array.items) |item| {
            if (item != .object) return error.InvalidConfig;
            const addr_val = objGetCI(item.object, "addr") orelse return error.InvalidConfig;
            if (addr_val != .string) return error.InvalidConfig;
            var weight: u64 = 0;
            if (objGetCI(item.object, "weight")) |wval| {
                if (wval != .integer) return error.InvalidConfig;
                if (wval.integer < 0) return error.NegativeWeight;
                weight = @intCast(wval.integer);
            }
            const ip4 = addrz.parseBackend(addr_val.string) catch return error.InvalidAddress;
            const text = std.fmt.allocPrint(a, "{d}.{d}.{d}.{d}:{d}", .{
                ip4.octets[0], ip4.octets[1], ip4.octets[2], ip4.octets[3], ip4.port,
            }) catch return error.OutOfMemory;
            hosts.append(a, .{ .text = text, .addr = ip4, .weight = weight }) catch return error.OutOfMemory;
            weight_sum += weight;
        }
    }

    return .{
        .arena = arena,
        .hosts = hosts.toOwnedSlice(a) catch return error.OutOfMemory,
        .weight_sum = weight_sum,
    };
}

/// 读取文件内容（上限 max 字节），调用方负责 free。
fn readFileAlloc(alloc: Allocator, path: []const u8, max: usize) Error![]u8 {
    var pbuf: [4096]u8 = undefined;
    if (path.len == 0 or path.len >= pbuf.len) return error.NameTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;

    const fd_rc = linux.openat(linux.AT.FDCWD, pbuf[0..path.len :0].ptr, .{}, 0);
    const fd: i32 = switch (linux.errno(fd_rc)) {
        .SUCCESS => @intCast(fd_rc),
        else => return error.OpenFailed,
    };
    defer _ = linux.close(fd);

    const buf = alloc.alloc(u8, max) catch return error.OutOfMemory;
    errdefer alloc.free(buf);
    var n: usize = 0;
    while (n < max) {
        const rc = linux.read(fd, buf.ptr + n, max - n);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) break;
                n += rc;
            },
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
    return alloc.realloc(buf, n) catch return error.OutOfMemory;
}

/// 从文件加载并校验配置（上限 1 MiB）。
pub fn loadFile(alloc: Allocator, path: []const u8) Error!Config {
    const bytes = try readFileAlloc(alloc, path, 1 << 20);
    defer alloc.free(bytes);
    return parse(alloc, bytes);
}

// ---------------------------------------------------------------------------
// 单元测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parse valid config" {
    var cfg = try parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:18091","weight":100},{"addr":"10.0.0.2:80","weight":1}]}
    );
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 2), cfg.hosts.len);
    try testing.expectEqual(@as(u64, 101), cfg.weight_sum);
    try testing.expectEqual(@as(u64, 100), cfg.hosts[0].weight);
    try testing.expect(cfg.hosts[0].addr.eql(.{ .octets = .{ 127, 0, 0, 1 }, .port = 18091 }));
    try testing.expectEqualStrings("127.0.0.1:18091", cfg.hosts[0].text);
}

test "parse is case-insensitive like Go encoding/json" {
    var cfg = try parse(testing.allocator,
        \\{"Hosts":[{"Addr":"127.0.0.1:80","Weight":5}],"Traffic_Url":"x"}
    );
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 1), cfg.hosts.len);
    try testing.expectEqual(@as(u64, 5), cfg.weight_sum);
}

test "invalid address fails whole load" {
    try testing.expectError(error.InvalidAddress, parse(testing.allocator,
        \\{"hosts":[{"addr":"nocolon","weight":1}]}
    ));
    try testing.expectError(error.InvalidAddress, parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:99999","weight":1}]}
    ));
    try testing.expectError(error.InvalidAddress, parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:","weight":1}]}
    ));
    // 第二个非法同样整次失败
    try testing.expectError(error.InvalidAddress, parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:80","weight":1},{"addr":"bad","weight":1}]}
    ));
}

test "negative weight fails whole load" {
    try testing.expectError(error.NegativeWeight, parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:80","weight":-1}]}
    ));
}

test "empty hosts is valid with zero weight sum" {
    var cfg = try parse(testing.allocator,
        \\{"hosts":[]}
    );
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 0), cfg.hosts.len);
    try testing.expectEqual(@as(u64, 0), cfg.weight_sum);
}

test "missing hosts is valid with zero weight sum" {
    var cfg = try parse(testing.allocator,
        \\{}
    );
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 0), cfg.hosts.len);
    try testing.expectEqual(@as(u64, 0), cfg.weight_sum);
}

test "all zero weights is valid with zero weight sum" {
    var cfg = try parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:1","weight":0},{"addr":"127.0.0.1:2","weight":0}]}
    );
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 2), cfg.hosts.len);
    try testing.expectEqual(@as(u64, 0), cfg.weight_sum);
}

test "malformed json fails" {
    try testing.expectError(error.InvalidConfig, parse(testing.allocator, "not json"));
    try testing.expectError(error.InvalidConfig, parse(testing.allocator,
        \\{"hosts": "oops"}
    ));
    try testing.expectError(error.InvalidConfig, parse(testing.allocator,
        \\{"hosts":[{"weight":1}]}
    ));
    try testing.expectError(error.InvalidConfig, parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:80","weight":"heavy"}]}
    ));
}

test "loadFile reads from disk" {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/tmp/gopf-cfgtest-{d}.conf", .{linux.getpid()}) catch unreachable;
    try writeTestFile(path, "{\"hosts\":[{\"addr\":\"127.0.0.1:18091\",\"weight\":7}]}");
    defer {
        var pbuf: [4096]u8 = undefined;
        @memcpy(pbuf[0..path.len], path);
        pbuf[path.len] = 0;
        _ = linux.unlinkat(linux.AT.FDCWD, pbuf[0..path.len :0].ptr, 0);
    }

    var cfg = try loadFile(testing.allocator, path);
    defer cfg.deinit();
    try testing.expectEqual(@as(u64, 7), cfg.weight_sum);

    try testing.expectError(error.OpenFailed, loadFile(testing.allocator, "/tmp/gopf-no-such-file.conf"));
}

pub fn writeTestFile(path: []const u8, content: []const u8) !void {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return error.NameTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd_rc = linux.openat(linux.AT.FDCWD, pbuf[0..path.len :0].ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(fd_rc) != .SUCCESS) return error.OpenFailed;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < content.len) {
        const rc = linux.write(fd, content.ptr + off, content.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}
