//! The proxy core: accept loop, per-connection handling, and bidirectional
//! forwarding with half-close semantics.
//!
//! Threading model (mirrors the Go reference's goroutine-per-connection):
//! one OS thread per accepted connection plus one extra thread per active
//! connection for the second copy direction. Both directions run a plain
//! read/write loop; when a direction's read side reaches EOF (or errors) it
//! half-closes the *other* socket's write side with shutdown(SHUT_WR). Only
//! after both directions have finished are the sockets closed.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const net = std.Io.net;
const Allocator = std.mem.Allocator;

const config = @import("config.zig");
const chooser = @import("chooser.zig");
const dial = @import("dial.zig");

const log = std.debug.print;

var rng_seed_counter = std.atomic.Value(u64).init(0x2545f4914f6cdd1d);

const copy_buf_size = 32 * 1024;
const copy_stack_size = 256 * 1024;

pub const dial_timeout_ms: i32 = 5000;

/// Writing to a closed socket raises SIGPIPE, whose default disposition kills
/// the process. The Go runtime ignores it; we do the same so writes simply
/// fail with EPIPE.
pub fn ignoreSigPipe() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.PIPE, &act, null);
}

fn writeAll(fd: posix.fd_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        while (true) {
            const rc = linux.write(fd, data.ptr + off, data.len - off);
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    off += @intCast(rc);
                    break;
                },
                .INTR => continue,
                .PIPE => return error.BrokenPipe,
                .CONNRESET => return error.ConnectionResetByPeer,
                .AGAIN => return error.WouldBlock,
                else => return error.WriteFailed,
            }
        }
    }
}

fn shutdownWrite(fd: posix.fd_t) void {
    switch (posix.errno(linux.shutdown(fd, linux.SHUT.WR))) {
        .SUCCESS => {},
        // Already closed by peer / not connected: nothing to do.
        .NOTCONN => {},
        else => {},
    }
}

/// Copy src -> dst until EOF or error, then half-close dst's write side.
fn copyAndCloseWrite(src: posix.fd_t, dst: posix.fd_t) void {
    var buf: [copy_buf_size]u8 = undefined;
    while (true) {
        const n = posix.read(src, &buf) catch break;
        if (n == 0) break;
        writeAll(dst, buf[0..n]) catch break;
    }
    shutdownWrite(dst);
}

/// Bidirectional forward; returns when both directions are done.
pub fn forward(client_fd: posix.fd_t, backend_fd: posix.fd_t) void {
    const t = std.Thread.spawn(
        .{ .stack_size = copy_stack_size },
        copyAndCloseWrite,
        .{ backend_fd, client_fd },
    ) catch {
        // Could not spawn the second direction; give up on this connection.
        // The caller's defers close both fds, which unblocks nothing here but
        // at least frees the resources.
        return;
    };
    copyAndCloseWrite(client_fd, backend_fd);
    t.join();
}

/// Pick a backend address, copying it into `buf` while holding the config
/// lock so a concurrent reload cannot free the string under us.
pub fn pickBackend(store: *config.Store, io: std.Io, rand: std.Random, buf: []u8) ?[]const u8 {
    store.lock.lockUncancelable(io);
    defer store.lock.unlock(io);
    const cfg = store.current orelse return null;
    const idx = chooser.chooseHost(rand, cfg.hosts, cfg.weight_sum) orelse return null;
    const addr = cfg.hosts[idx].addr;
    if (addr.len > buf.len) return null;
    @memcpy(buf[0..addr.len], addr);
    return buf[0..addr.len];
}

pub const Proxy = struct {
    io: std.Io,
    gpa: Allocator,
    store: *config.Store,
    server: net.Server,

    active_conns: std.atomic.Value(i64) = .init(0),
    total_conns: std.atomic.Value(u64) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    accept_thread: ?std.Thread = null,

    pub fn listen(io: std.Io, gpa: Allocator, store: *config.Store, addr: net.IpAddress) !Proxy {
        ignoreSigPipe();
        const server = try addr.listen(io, .{
            .reuse_address = true,
            .kernel_backlog = 512,
        });
        return .{ .io = io, .gpa = gpa, .store = store, .server = server };
    }

    pub fn port(self: *const Proxy) u16 {
        return self.server.socket.address.getPort();
    }

    /// Run the accept loop in a background thread.
    pub fn start(self: *Proxy) !void {
        self.accept_thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Accept loop: blocks until `stop` is called. May be run on the caller's
    /// thread directly (the main function does this).
    pub fn run(self: *Proxy) void {
        while (true) {
            const stream = self.server.accept(self.io) catch |err| {
                if (self.stopping.load(.acquire)) return;
                switch (err) {
                    // Transient resource exhaustion: keep accepting.
                    error.ProcessFdQuotaExceeded,
                    error.SystemFdQuotaExceeded,
                    error.SystemResources,
                    error.ConnectionAborted,
                    => {
                        log("accept error (continuing): {s}\n", .{@errorName(err)});
                        continue;
                    },
                    else => {
                        log("accept error (stopping): {s}\n", .{@errorName(err)});
                        return;
                    },
                }
            };
            if (self.stopping.load(.acquire)) {
                // Woken by stop()'s dummy connection.
                std.Io.Threaded.closeFd(stream.socket.handle);
                return;
            }
            self.total_conns.store(self.total_conns.load(.monotonic) + 1, .monotonic);
            const t = std.Thread.spawn(.{ .stack_size = copy_stack_size }, handleConn, .{ self, stream }) catch |err| {
                log("failed to spawn connection thread: {s}\n", .{@errorName(err)});
                std.Io.Threaded.closeFd(stream.socket.handle);
                continue;
            };
            t.detach();
        }
    }

    /// Stop accepting and release the listener. Safe to call from another
    /// thread while `run` is blocked in accept.
    pub fn stop(self: *Proxy) void {
        self.stopping.store(true, .release);
        // shutdown() does not wake a blocked accept() on Linux, and closing
        // the listen fd out from under accept() would panic in the std lib's
        // debug builds (EBADF is treated as a bug). Instead, wake accept()
        // with a dummy connection; run() notices `stopping` and exits.
        if (dial.dialIpTimeout(self.server.socket.address, 500)) |fd| {
            std.Io.Threaded.closeFd(fd);
        } else |_| {}
        if (self.accept_thread) |t| {
            t.join();
            self.accept_thread = null;
        }
        self.server.deinit(self.io);
        // Wait for in-flight connection threads to finish so callers can
        // safely tear down the Io instance (connection threads use it).
        // Capped at ~2s; stop() is only used in tests and on shutdown paths.
        const tick: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(5), .clock = .awake };
        var waited_ms: u64 = 0;
        while (self.active_conns.load(.monotonic) != 0 and waited_ms < 2000) : (waited_ms += 5) {
            tick.sleep(self.io) catch break;
        }
    }
};

fn handleConn(px: *Proxy, client: net.Stream) void {
    const client_fd = client.socket.handle;
    defer std.Io.Threaded.closeFd(client_fd);

    _ = px.active_conns.fetchAdd(1, .monotonic);
    defer _ = px.active_conns.fetchSub(1, .monotonic);

    if (comptime !builtin.is_test) {
        log("accepted connection from {f}\n", .{client.socket.address});
    }

    const seed: u64 = rng_seed_counter.fetchAdd(0x9e3779b97f4a7c15, .monotonic);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var addr_buf: [512]u8 = undefined;
    const addr_text = pickBackend(px.store, px.io, rand, &addr_buf) orelse {
        if (comptime !builtin.is_test) {
            log("no available backend hosts to forward connection\n", .{});
        }
        return;
    };

    const backend_fd = dial.dialTimeout(px.io, addr_text, dial_timeout_ms) catch |err| {
        if (comptime !builtin.is_test) {
            log("failed to connect to backend '{s}': {s}\n", .{ addr_text, @errorName(err) });
        }
        return;
    };
    defer std.Io.Threaded.closeFd(backend_fd);

    dial.setKeepAlive(client_fd) catch {};
    dial.setKeepAlive(backend_fd) catch {};

    forward(client_fd, backend_fd);
}

// ---------------------------------------------------------------------------
// Integration tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A minimal TCP server used by the tests: optionally writes a banner on
/// connect, then echoes everything until the peer goes away, then closes.
const EchoServer = struct {
    io: std.Io,
    server: net.Server,
    banner: []const u8,
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    /// Caller provides stable storage: the accept thread dereferences `self`.
    fn start(self: *EchoServer, io: std.Io, banner: []const u8) !void {
        ignoreSigPipe();
        const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
        self.* = .{
            .io = io,
            .server = try addr.listen(io, .{ .reuse_address = true }),
            .banner = banner,
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(es: *EchoServer) void {
        while (true) {
            const stream = es.server.accept(es.io) catch {
                return;
            };
            if (es.stopping.load(.acquire)) {
                std.Io.Threaded.closeFd(stream.socket.handle);
                return;
            }
            const t = std.Thread.spawn(.{}, echoConn, .{ es.io, stream.socket.handle, es.banner }) catch {
                std.Io.Threaded.closeFd(stream.socket.handle);
                continue;
            };
            t.detach();
        }
    }

    fn echoConn(io: std.Io, fd: posix.fd_t, banner: []const u8) void {
        _ = io;
        defer std.Io.Threaded.closeFd(fd);
        if (banner.len > 0) writeAll(fd, banner) catch return;
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = posix.read(fd, &buf) catch return;
            if (n == 0) return;
            writeAll(fd, buf[0..n]) catch return;
        }
    }

    fn port(es: *const EchoServer) u16 {
        return es.server.socket.address.getPort();
    }

    fn stop(es: *EchoServer) void {
        es.stopping.store(true, .release);
        // Wake the blocked accept() with a dummy connection (see Proxy.stop).
        if (dial.dialIpTimeout(es.server.socket.address, 500)) |fd| {
            std.Io.Threaded.closeFd(fd);
        } else |_| {}
        if (es.thread) |t| {
            t.join();
            es.thread = null;
        }
        es.server.deinit(es.io);
    }
};

const TestCtx = struct {
    // Threaded is heap-allocated: it contains self-referential state and the
    // Io handle points back at it, so it must never be moved after init.
    threaded: *std.Io.Threaded,
    io: std.Io,
    store: config.Store,

    fn init() !TestCtx {
        const t = try testing.allocator.create(std.Io.Threaded);
        t.* = .init(testing.allocator, .{});
        return .{
            .threaded = t,
            .io = t.io(),
            .store = config.Store.init(),
        };
    }

    fn setConfig(ctx: *TestCtx, text: []const u8) !void {
        const cfg = try testing.allocator.create(config.Config);
        cfg.* = try config.parse(testing.allocator, text);
        ctx.store.swap(testing.allocator, ctx.io, cfg);
    }

    fn deinit(ctx: *TestCtx) void {
        ctx.store.clear(testing.allocator, ctx.io);
        ctx.threaded.deinit();
        testing.allocator.destroy(ctx.threaded);
    }
};

/// Connect to the proxy, send `request`, half-close the write side, then read
/// until EOF and return the received bytes.
fn roundTrip(proxy_port: u16, request: []const u8) ![]u8 {
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(proxy_port) };
    const fd = try dial.dialIpTimeout(addr, 5000);
    defer std.Io.Threaded.closeFd(fd);

    try writeAll(fd, request);
    // Half-close: we are done sending, but still expect the echo back.
    switch (posix.errno(linux.shutdown(fd, linux.SHUT.WR))) {
        .SUCCESS => {},
        else => return error.ShutdownFailed,
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(testing.allocator, buf[0..n]);
    }
    return out.toOwnedSlice(testing.allocator);
}


/// Give detached connection threads a moment to finish logging before the
/// test binary exits (avoids racing the test runner's result protocol).
fn settle(io: std.Io) void {
    const d: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(50), .clock = .awake };
    d.sleep(io) catch {};
}

test "small packet echo through proxy with half-close" {
    var ctx = try TestCtx.init();
    defer ctx.deinit();

    var echo: EchoServer = undefined;
    try echo.start(ctx.io, "");
    defer echo.stop();

    var text_buf: [128]u8 = undefined;
    const cfg_text = try std.fmt.bufPrint(&text_buf,
        \\{{"hosts":[{{"addr":"127.0.0.1:{d}","weight":100}}]}}
    , .{echo.port()});
    try ctx.setConfig(cfg_text);

    var px = try Proxy.listen(ctx.io, testing.allocator, &ctx.store, .{ .ip4 = net.Ip4Address.loopback(0) });
    try px.start();
    defer px.stop();

    const got = try roundTrip(px.port(), "hello, gopf");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello, gopf", got);
    settle(ctx.io);
}

test "large payload (2 MiB) echoes byte-identical" {
    var ctx = try TestCtx.init();
    defer ctx.deinit();

    var echo: EchoServer = undefined;
    try echo.start(ctx.io, "");
    defer echo.stop();

    var text_buf: [128]u8 = undefined;
    const cfg_text = try std.fmt.bufPrint(&text_buf,
        \\{{"hosts":[{{"addr":"127.0.0.1:{d}","weight":100}}]}}
    , .{echo.port()});
    try ctx.setConfig(cfg_text);

    var px = try Proxy.listen(ctx.io, testing.allocator, &ctx.store, .{ .ip4 = net.Ip4Address.loopback(0) });
    try px.start();
    defer px.stop();

    // Deterministic 2 MiB pattern (not compressible, exercises many copies).
    const size = 2 * 1024 * 1024;
    const payload = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(payload);
    var prng = std.Random.DefaultPrng.init(12345);
    prng.random().bytes(payload);

    const got = try roundTrip(px.port(), payload);
    defer testing.allocator.free(got);
    try testing.expectEqual(size, got.len);
    try testing.expect(std.mem.eql(u8, payload, got));
    settle(ctx.io);
}

test "reload changes the backend selection set" {
    var ctx = try TestCtx.init();
    defer ctx.deinit();

    var echo_a: EchoServer = undefined;
    try echo_a.start(ctx.io, "A>");
    defer echo_a.stop();
    var echo_b: EchoServer = undefined;
    try echo_b.start(ctx.io, "B>");
    defer echo_b.stop();

    var text_buf: [128]u8 = undefined;
    const cfg_a = try std.fmt.bufPrint(&text_buf,
        \\{{"hosts":[{{"addr":"127.0.0.1:{d}","weight":1}}]}}
    , .{echo_a.port()});
    try ctx.setConfig(cfg_a);

    var px = try Proxy.listen(ctx.io, testing.allocator, &ctx.store, .{ .ip4 = net.Ip4Address.loopback(0) });
    try px.start();
    defer px.stop();

    const got_a = try roundTrip(px.port(), "x");
    defer testing.allocator.free(got_a);
    try testing.expectEqualStrings("A>x", got_a);

    // Simulate what the SIGHUP handler does: parse new config, swap it in.
    const cfg_b_text = try std.fmt.bufPrint(&text_buf,
        \\{{"hosts":[{{"addr":"127.0.0.1:{d}","weight":1}}]}}
    , .{echo_b.port()});
    try ctx.setConfig(cfg_b_text);

    const got_b = try roundTrip(px.port(), "y");
    defer testing.allocator.free(got_b);
    try testing.expectEqualStrings("B>y", got_b);
    settle(ctx.io);
}

test "no usable backends closes the connection" {
    var ctx = try TestCtx.init();
    defer ctx.deinit();

    // All-zero weights: weight_sum == 0, so no backend can be chosen.
    try ctx.setConfig(
        \\{"hosts":[{"addr":"127.0.0.1:9","weight":0}]}
    );

    var px = try Proxy.listen(ctx.io, testing.allocator, &ctx.store, .{ .ip4 = net.Ip4Address.loopback(0) });
    try px.start();
    defer px.stop();

    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(px.port()) };
    const fd = try dial.dialIpTimeout(addr, 5000);
    defer std.Io.Threaded.closeFd(fd);
    // The proxy must close the connection promptly: read returns EOF.
    var buf: [16]u8 = undefined;
    const n = try posix.read(fd, &buf);
    try testing.expectEqual(@as(usize, 0), n);
    settle(ctx.io);
}
