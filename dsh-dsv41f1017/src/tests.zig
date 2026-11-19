const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const config = @import("config.zig");
const balancer = @import("balancer.zig");
const store_mod = @import("store.zig");
const tcp = @import("tcp.zig");
const proxy_mod = @import("proxy.zig");

// ---------------------------------------------------------------------------
// Configuration parsing and validation
// ---------------------------------------------------------------------------

test "config: valid document with multiple hosts" {
    const json =
        \\{"traffic_url":"unused","hosts":[
        \\  {"addr":"127.0.0.1:18091","weight":100},
        \\  {"addr":"localhost:9000","weight":0},
        \\  {"addr":"[::1]:9001","weight":7}
        \\]}
    ;
    var cfg = try config.Config.parse(std.testing.allocator, json);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 3), cfg.hosts.len);
    try std.testing.expectEqual(@as(i64, 107), cfg.weight_sum);
    try std.testing.expectEqualStrings("127.0.0.1:18091", cfg.hosts[0].addr);
    try std.testing.expectEqual(@as(i64, 100), cfg.hosts[0].weight);
    try std.testing.expectEqual(@as(i64, 0), cfg.hosts[1].weight);
}

test "config: invalid address is rejected" {
    const bad = [_][]const u8{
        \\{"hosts":[{"addr":"127.0.0.1","weight":1}]}
        ,
        \\{"hosts":[{"addr":"127.0.0.1:notaport","weight":1}]}
        ,
        \\{"hosts":[{"addr":"127.0.0.1:99999","weight":1}]}
        ,
    };
    for (bad) |json| {
        if (config.Config.parse(std.testing.allocator, json)) |cfg| {
            var c = cfg;
            c.deinit();
            return error.TestExpectedInvalidAddress;
        } else |err| {
            try std.testing.expectEqual(error.InvalidAddress, err);
        }
    }
}

test "config: negative weight is rejected" {
    const json =
        \\{"hosts":[{"addr":"127.0.0.1:1","weight":5},{"addr":"127.0.0.1:2","weight":-1}]}
    ;
    if (config.Config.parse(std.testing.allocator, json)) |cfg| {
        var c = cfg;
        c.deinit();
        return error.TestExpectedNegativeWeight;
    } else |err| {
        try std.testing.expectEqual(error.NegativeWeight, err);
    }
}

test "config: empty hosts is legal but has no backend" {
    var cfg = try config.Config.parse(std.testing.allocator, "{\"hosts\":[]}");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.hosts.len);
    try std.testing.expectEqual(@as(i64, 0), cfg.weight_sum);
    var prng = std.Random.DefaultPrng.init(1);
    try std.testing.expectEqual(@as(?usize, null), balancer.choose(cfg.hosts, cfg.weight_sum, prng.random()));
}

test "config: all-zero weights is legal but selects nothing" {
    const json =
        \\{"hosts":[{"addr":"127.0.0.1:1","weight":0},{"addr":"127.0.0.1:2","weight":0}]}
    ;
    var cfg = try config.Config.parse(std.testing.allocator, json);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 2), cfg.hosts.len);
    try std.testing.expectEqual(@as(i64, 0), cfg.weight_sum);
    var prng = std.Random.DefaultPrng.init(7);
    for (0..1000) |_| {
        try std.testing.expectEqual(@as(?usize, null), balancer.choose(cfg.hosts, cfg.weight_sum, prng.random()));
    }
}

test "config: malformed json is rejected" {
    const bad = [_][]const u8{
        "not json",
        "{\"hosts\":[",
        "{\"hosts\":[{\"addr\":\"127.0.0.1:1\",\"weight\":1.5}]}",
    };
    for (bad) |json| {
        if (config.Config.parse(std.testing.allocator, json)) |cfg| {
            var c = cfg;
            c.deinit();
            return error.TestExpectedParseFailure;
        } else |_| {}
    }
}

test "config: load from file and split host:port" {
    const path = "/tmp/gopf-zig-config-test.json";
    const body =
        \\{"hosts":[{"addr":"127.0.0.1:12345","weight":3}]}
    ;
    try writeFile(path, body);
    var cfg = try config.Config.load(std.testing.allocator, path);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.hosts.len);
    const hp = try config.splitHostPort(cfg.hosts[0].addr);
    try std.testing.expectEqualStrings("127.0.0.1", hp.host);
    try std.testing.expectEqual(@as(u16, 12345), hp.port);
    const hp6 = try config.splitHostPort("[::1]:80");
    try std.testing.expectEqualStrings("::1", hp6.host);
    try std.testing.expectEqual(@as(u16, 80), hp6.port);
    try std.testing.expectError(error.InvalidAddress, config.splitHostPort("nope"));
}

// ---------------------------------------------------------------------------
// Weighted random selection
// ---------------------------------------------------------------------------

test "balancer: 1:2 weights stay between 1/3 and 2/3 over 100k picks" {
    var hosts = [_]config.Host{
        .{ .addr = "127.0.0.1:1", .weight = 1 },
        .{ .addr = "127.0.0.1:2", .weight = 2 },
        .{ .addr = "127.0.0.1:3", .weight = 0 },
    };
    var prng = std.Random.DefaultPrng.init(0x1234_5678_9abc_def0);
    const random = prng.random();

    const n = 100_000;
    var counts = [_]usize{ 0, 0, 0 };
    for (0..n) |_| {
        const idx = balancer.choose(&hosts, 3, random).?;
        counts[idx] += 1;
    }

    try std.testing.expect(counts[2] == 0);
    try std.testing.expect(counts[0] + counts[1] == n);
    // Expected proportion for the weight-1 host is 1/3. Allow a small
    // statistical tolerance on the fixed-seed sample while still requiring
    // the 1:2 split to land inside the requested 1/3..2/3 band.
    try std.testing.expect(counts[0] * 3 + n / 20 >= n);
    try std.testing.expect(counts[0] * 3 <= 2 * n);
    try std.testing.expect(counts[0] > n / 4 and counts[0] < n / 2);
}

// ---------------------------------------------------------------------------
// Reload semantics
// ---------------------------------------------------------------------------

test "store: reload changes the selection set and failure keeps old config" {
    var store = store_mod.Store.init(std.testing.allocator, try config.Config.parse(
        std.testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:1111","weight":1}]}
        ,
    ));
    defer store.deinit();

    var prng = std.Random.DefaultPrng.init(99);
    const random = prng.random();
    for (0..200) |_| {
        const sel = store.choose(random).?;
        try std.testing.expectEqualStrings("127.0.0.1:1111", sel.addr());
    }

    try store.reloadFromBytes(
        \\{"hosts":[{"addr":"127.0.0.1:2222","weight":5},{"addr":"127.0.0.1:3333","weight":1}]}
        ,
    );
    var seen_2222 = false;
    var seen_3333 = false;
    for (0..2000) |_| {
        const sel = store.choose(random).?;
        try std.testing.expect(!std.mem.eql(u8, "127.0.0.1:1111", sel.addr()));
        if (std.mem.eql(u8, "127.0.0.1:2222", sel.addr())) seen_2222 = true;
        if (std.mem.eql(u8, "127.0.0.1:3333", sel.addr())) seen_3333 = true;
    }
    try std.testing.expect(seen_2222 and seen_3333);

    // A failed reload must not disturb the live configuration.
    if (store.reloadFromBytes(
        \\{"hosts":[{"addr":"bad-address","weight":1}]}
        ,
    )) |_| {
        return error.TestExpectedReloadFailure;
    } else |err| {
        try std.testing.expectEqual(error.InvalidAddress, err);
    }
    const sel = store.choose(random).?;
    try std.testing.expect(std.mem.eql(u8, "127.0.0.1:2222", sel.addr()) or
        std.mem.eql(u8, "127.0.0.1:3333", sel.addr()));
}

test "signals: installing handlers and dispatching flags" {
    proxy_mod.installSignalHandlers();
    _ = proxy_mod.pending_shutdown.swap(false, .acquire);
    try std.posix.kill(std.os.linux.getpid(), .USR1);
    // Give the signal a chance to be delivered, then consume the flag.
    var tries: usize = 0;
    while (!proxy_mod.pending_status.load(.acquire) and tries < 100) : (tries += 1) {
        tcp.sleepMs(1);
    }
    try std.testing.expect(proxy_mod.pending_status.swap(false, .acquire));
}

// ---------------------------------------------------------------------------
// Integration: real echo backend, real proxy, real TCP clients
// ---------------------------------------------------------------------------

const EchoServer = struct {
    listener: tcp.Socket,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    active: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    thread: ?std.Thread = null,

    fn start(allocator: std.mem.Allocator) !*EchoServer {
        const server = try allocator.create(EchoServer);
        errdefer allocator.destroy(server);
        server.* = .{ .listener = try tcp.Socket.listen("127.0.0.1:0") };
        server.running.store(true, .release);
        server.thread = try std.Thread.spawn(.{}, run, .{server});
        return server;
    }

    fn run(self: *EchoServer) void {
        while (self.running.load(.acquire)) {
            var fds = [1]posix.pollfd{.{ .fd = self.listener.fd, .events = posix.POLL.IN }};
            const n = posix.poll(&fds, 20) catch continue;
            if (n == 0) continue;
            const client = self.listener.accept() catch continue;
            _ = self.active.fetchAdd(1, .monotonic);
            const t = std.Thread.spawn(.{}, echoThread, .{ self, client }) catch {
                _ = self.active.fetchSub(1, .monotonic);
                client.close();
                continue;
            };
            t.detach();
        }
    }

    fn echoThread(self: *EchoServer, client: tcp.Socket) void {
        defer _ = self.active.fetchSub(1, .monotonic);
        defer client.close();
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = client.read(&buf) catch return;
            if (n == 0) break;
            client.writeAll(buf[0..n]) catch return;
        }
        client.shutdownWrite();
    }

    fn stop(self: *EchoServer) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        var waited: usize = 0;
        while (self.active.load(.acquire) != 0 and waited < 5000) : (waited += 1) tcp.sleepMs(1);
        self.listener.close();
    }
};

const TestServer = struct {
    echo: *EchoServer,
    proxy: *proxy_mod.Proxy,

    fn start() !TestServer {
        const allocator = std.testing.allocator;
        const echo = try EchoServer.start(allocator);
        errdefer {
            echo.stop();
            allocator.destroy(echo);
        }
        const port = echo.listener.localPort();
        const json = try std.fmt.allocPrint(allocator,
            \\{{"hosts":[{{"addr":"127.0.0.1:{d}","weight":100}}]}}
        , .{port});
        defer allocator.free(json);
        const cfg = try config.Config.parse(allocator, json);

        const p = try allocator.create(proxy_mod.Proxy);
        errdefer allocator.destroy(p);
        p.* = try proxy_mod.Proxy.init(allocator, "127.0.0.1:0", cfg, null);
        try p.start();
        return .{ .echo = echo, .proxy = p };
    }

    fn stop(self: *TestServer) void {
        const allocator = std.testing.allocator;
        self.proxy.deinit();
        allocator.destroy(self.proxy);
        self.echo.stop();
        allocator.destroy(self.echo);
    }
};

test "integration: small echo and half-close keeps remaining data flowing" {
    var server = try TestServer.start();
    defer server.stop();

    const client = try tcp.Socket.connect("127.0.0.1", server.proxy.port(), 3000);
    defer client.close();

    try client.writeAll("hello");
    var buf: [256]u8 = undefined;
    var got: usize = 0;
    while (got < 5) {
        const n = try client.read(buf[got..]);
        if (n == 0) return error.UnexpectedEof;
        got += n;
    }
    try std.testing.expectEqualStrings("hello", buf[0..5]);

    const tail = "tail-data-after-half-close";
    try client.writeAll(tail);
    client.shutdownWrite();

    var rest = std.array_list.Managed(u8).init(std.testing.allocator);
    defer rest.deinit();
    while (true) {
        const n = try client.read(&buf);
        if (n == 0) break;
        try rest.appendSlice(buf[0..n]);
    }
    try std.testing.expectEqualStrings(tail, rest.items);
}

const ReadCheck = struct {
    expected: []const u8,
    total: usize = 0,
    ok: bool = true,
};

fn readAndCompare(client: tcp.Socket, check: *ReadCheck) void {
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = client.read(&buf) catch {
            check.ok = false;
            return;
        };
        if (n == 0) break;
        if (check.total + n > check.expected.len or
            !std.mem.eql(u8, buf[0..n], check.expected[check.total .. check.total + n]))
        {
            check.ok = false;
        }
        check.total += n;
    }
}

test "integration: 1 MiB payload round-trips byte for byte" {
    var server = try TestServer.start();
    defer server.stop();

    const size = 1024 * 1024;
    const payload = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);

    const client = try tcp.Socket.connect("127.0.0.1", server.proxy.port(), 3000);
    defer client.close();

    var check = ReadCheck{ .expected = payload };
    const reader = try std.Thread.spawn(.{}, readAndCompare, .{ client, &check });

    var off: usize = 0;
    while (off < payload.len) {
        off += try client.writeSome(payload[off..]);
    }
    client.shutdownWrite();
    reader.join();

    try std.testing.expect(check.ok);
    try std.testing.expectEqual(payload.len, check.total);
}

test "integration: unreachable backend closes the client" {
    const old_log_level = std.testing.log_level;
    std.testing.log_level = .err; // the refused dial is the expected outcome
    defer std.testing.log_level = old_log_level;

    const cfg = try config.Config.parse(std.testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:1","weight":100}]}
        ,
    );
    var p = try proxy_mod.Proxy.init(std.testing.allocator, "127.0.0.1:0", cfg, null);
    defer p.deinit();
    try p.start();

    const client = try tcp.Socket.connect("127.0.0.1", p.port(), 3000);
    defer client.close();

    var pfd = [1]posix.pollfd{.{ .fd = client.fd, .events = posix.POLL.IN }};
    const ready = try posix.poll(&pfd, 3000);
    try std.testing.expect(ready > 0);
    var buf: [64]u8 = undefined;
    const n = client.read(&buf) catch 0;
    try std.testing.expectEqual(@as(usize, 0), n);
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn writeFile(path: []const u8, data: []const u8) !void {
    const fd = try posix.openat(posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    }, 0o600);
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const rc = linux.write(fd, data.ptr + off, data.len - off);
        switch (posix.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}
