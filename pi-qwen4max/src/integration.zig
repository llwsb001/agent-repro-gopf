//! End-to-end integration tests over real TCP sockets on 127.0.0.1.
//! Each test spins up an in-process backend (echo or fixed-reply server)
//! and a proxy accept loop on ephemeral ports, then exercises the proxy
//! with a real client socket.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const sys = @import("sys.zig");
const config = @import("config.zig");
const proxy = @import("proxy.zig");

const alloc = std.testing.allocator;

fn ignoreSigpipe() void {
    posix.sigaction(posix.SIG.PIPE, &.{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    }, null);
}

fn connectPort(port: u16) !sys.fd_t {
    var buf: [32]u8 = undefined;
    const addr = try std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{port});
    return sys.dial(addr, 3000);
}

fn expectEof(fd: sys.fd_t) !void {
    var buf: [64]u8 = undefined;
    const n = try posix.read(fd, &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

// ---------------------------------------------------------------------------
// in-process backend: echo server or fixed-reply server
// ---------------------------------------------------------------------------

const TestServer = struct {
    fd: sys.fd_t,
    port: u16,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: std.Thread = undefined,

    fn start(reply: ?[]const u8) !*TestServer {
        ignoreSigpipe();
        const self = try alloc.create(TestServer);
        errdefer alloc.destroy(self);
        self.* = .{ .fd = try sys.listen("127.0.0.1:0"), .port = 0 };
        self.port = try sys.localPort(self.fd);
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{ self, reply });
        return self;
    }

    fn acceptLoop(self: *TestServer, reply: ?[]const u8) void {
        while (!self.stop.load(.monotonic)) {
            var pfds = [1]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 }};
            _ = posix.poll(&pfds, 50) catch continue;
            if (pfds[0].revents & posix.POLL.IN == 0) continue;
            const c = sys.accept(self.fd) catch continue;
            const t = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, connLoop, .{ c, reply }) catch {
                sys.close(c);
                continue;
            };
            t.detach();
        }
    }

    fn connLoop(c: sys.fd_t, reply: ?[]const u8) void {
        defer sys.close(c);
        var buf: [16384]u8 = undefined;
        if (reply) |r| {
            // Read whatever the client sent, answer immediately, half-close.
            _ = posix.read(c, &buf) catch return;
            sys.writeAll(c, r) catch return;
            sys.shutdownWrite(c);
            while (true) {
                const n = posix.read(c, &buf) catch return;
                if (n == 0) return;
            }
        } else {
            // Echo until EOF, then half-close so the client sees EOF too.
            while (true) {
                const n = posix.read(c, &buf) catch return;
                if (n == 0) {
                    sys.shutdownWrite(c);
                    return;
                }
                sys.writeAll(c, buf[0..n]) catch return;
            }
        }
    }

    fn deinit(self: *TestServer) void {
        self.stop.store(true, .monotonic);
        self.thread.join();
        sys.close(self.fd);
        alloc.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// in-process proxy (same handleConn/pump code as the real binary)
// ---------------------------------------------------------------------------

const TestProxy = struct {
    store: config.Store,
    stats: proxy.Stats = .{},
    p: proxy.Proxy,
    fd: sys.fd_t,
    port: u16,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: std.Thread = undefined,

    fn start(cfg_text: []const u8) !*TestProxy {
        ignoreSigpipe();
        const self = try alloc.create(TestProxy);
        errdefer alloc.destroy(self);
        const cfg = try config.parse(alloc, cfg_text);
        self.* = .{
            .store = config.Store.init(cfg),
            .p = undefined,
            .fd = try sys.listen("127.0.0.1:0"),
            .port = 0,
        };
        self.p = proxy.Proxy.init(&self.store, &self.stats, 0xC0FFEE);
        self.port = try sys.localPort(self.fd);
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    fn acceptLoop(self: *TestProxy) void {
        while (!self.stop.load(.monotonic)) {
            var pfds = [1]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 }};
            _ = posix.poll(&pfds, 50) catch continue;
            if (pfds[0].revents & posix.POLL.IN == 0) continue;
            const c = sys.accept(self.fd) catch continue;
            const t = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, proxy.Proxy.handleConn, .{ &self.p, c }) catch {
                sys.close(c);
                continue;
            };
            t.detach();
        }
    }

    fn deinit(self: *TestProxy) void {
        self.stop.store(true, .monotonic);
        self.thread.join();
        sys.close(self.fd);
        // Let detached connection threads finish before freeing the store.
        var tries: usize = 0;
        while (self.stats.active.load(.monotonic) != 0 and tries < 500) : (tries += 1) {
            sys.sleepMs(10);
        }
        self.store.deinit(alloc);
        alloc.destroy(self);
    }
};

fn backendCfg(port: u16, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"hosts\":[{{\"addr\":\"127.0.0.1:{d}\",\"weight\":100}}]}}", .{port}) catch unreachable;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "forward: small request/response without half-close" {
    const echo = try TestServer.start(null);
    defer echo.deinit();
    var cfgbuf: [128]u8 = undefined;
    const px = try TestProxy.start(backendCfg(echo.port, &cfgbuf));
    defer px.deinit();

    const c = try connectPort(px.port);
    defer sys.close(c);
    // Client keeps its write side open the whole time (HTTP-like pattern):
    // the request must reach the backend immediately and the response must
    // come back without any shutdown().
    const req = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    try sys.writeAll(c, req);
    var resp: [req.len]u8 = undefined;
    try sys.readFull(c, &resp);
    try std.testing.expectEqualStrings(req, &resp);

    // A second request on the same connection also works.
    try sys.writeAll(c, "ping-2");
    var resp2: [6]u8 = undefined;
    try sys.readFull(c, &resp2);
    try std.testing.expectEqualStrings("ping-2", &resp2);
}

test "forward: half-close still delivers remaining data" {
    const echo = try TestServer.start(null);
    defer echo.deinit();
    var cfgbuf: [128]u8 = undefined;
    const px = try TestProxy.start(backendCfg(echo.port, &cfgbuf));
    defer px.deinit();

    const c = try connectPort(px.port);
    defer sys.close(c);
    const payload = "0123456789abcdef";
    try sys.writeAll(c, payload);
    sys.shutdownWrite(c); // client EOF -> proxy must shutdown(WR) on backend

    var got: [payload.len]u8 = undefined;
    try sys.readFull(c, &got); // echoed data must still arrive after half-close
    try std.testing.expectEqualStrings(payload, &got);
    try expectEof(c); // backend EOF propagated back as full close
}

test "forward: 1 MiB+ transfer is byte-identical" {
    const echo = try TestServer.start(null);
    defer echo.deinit();
    var cfgbuf: [128]u8 = undefined;
    const px = try TestProxy.start(backendCfg(echo.port, &cfgbuf));
    defer px.deinit();

    const size = (1 << 20) + 777; // > 1 MiB, not a multiple of buffer sizes
    const data = try alloc.alloc(u8, size);
    defer alloc.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);

    const c = try connectPort(px.port);
    defer sys.close(c);

    const Writer = struct {
        fn run(fd: sys.fd_t, bytes: []const u8) void {
            sys.writeAll(fd, bytes) catch {};
            sys.shutdownWrite(fd);
        }
    };
    const writer = try std.Thread.spawn(.{}, Writer.run, .{ c, data });

    const got = try alloc.alloc(u8, size);
    defer alloc.free(got);
    try sys.readFull(c, got);
    writer.join();
    try std.testing.expectEqualSlices(u8, data, got);
    try expectEof(c);
}

test "no available backend (zero weight) closes the connection" {
    const px = try TestProxy.start("{\"hosts\":[{\"addr\":\"127.0.0.1:1\",\"weight\":0}]}");
    defer px.deinit();

    const c = try connectPort(px.port);
    defer sys.close(c);
    try expectEof(c);
}

test "dial failure closes the client connection" {
    // Grab an ephemeral port and close it so nothing listens there.
    const dead = try sys.listen("127.0.0.1:0");
    const dead_port = try sys.localPort(dead);
    sys.close(dead);

    var cfgbuf: [128]u8 = undefined;
    const px = try TestProxy.start(backendCfg(dead_port, &cfgbuf));
    defer px.deinit();

    const c = try connectPort(px.port);
    defer sys.close(c);
    try expectEof(c);
}

test "reload changes routing end-to-end" {
    const srv_a = try TestServer.start("AAA");
    defer srv_a.deinit();
    const srv_b = try TestServer.start("BBB");
    defer srv_b.deinit();

    var pathbuf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&pathbuf, "/tmp/gopf-itest-{d}.json", .{linux.getpid()});
    defer sys.deleteFile(path);

    var cfgbuf: [128]u8 = undefined;
    try sys.writeFile(path, backendCfg(srv_a.port, &cfgbuf));
    const initial = try sys.readFile(alloc, path, 1 << 20);
    defer alloc.free(initial);
    const px = try TestProxy.start(initial);
    defer px.deinit();

    const ask = struct {
        fn call(port: u16) ![3]u8 {
            const c = try connectPort(port);
            defer sys.close(c);
            try sys.writeAll(c, "x");
            var r: [3]u8 = undefined;
            try sys.readFull(c, &r);
            return r;
        }
    }.call;

    try std.testing.expectEqualStrings("AAA", &(try ask(px.port)));

    // Rewrite config to backend B and reload (what SIGHUP does).
    try sys.writeFile(path, backendCfg(srv_b.port, &cfgbuf));
    try px.store.reload(alloc, path);
    try std.testing.expectEqualStrings("BBB", &(try ask(px.port)));

    // Broken reload keeps routing to B.
    try sys.writeFile(path, "{\"hosts\":[{\"addr\":\"bad\",\"weight\":1}]}");
    try std.testing.expectError(error.InvalidAddress, px.store.reload(alloc, path));
    try std.testing.expectEqualStrings("BBB", &(try ask(px.port)));
}
