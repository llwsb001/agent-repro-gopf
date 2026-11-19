//! Proxy core: accept loop, per-connection backend selection/dial, and
//! bidirectional forwarding with half-close semantics.
//!
//! Threading model: one OS thread per accepted connection. Inside that thread
//! a single poll() loop drives both directions, so a connection costs one
//! thread rather than the two copy goroutines a direct translation would use.
//! When one side reaches EOF its buffered bytes are flushed, then the peer's
//! write side is shut down. Both directions must finish before both fds close.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const net = std.Io.net;
const Allocator = std.mem.Allocator;

const config = @import("config.zig");
const selector = @import("selector.zig");
const dial = @import("dial.zig");

const log = std.debug.print;

var rng_counter = std.atomic.Value(u64).init(0x9e3779b97f4a7c15);

pub const dial_timeout_ms: i32 = 5000;
const copy_buf_size = 64 * 1024;
const conn_stack_size = 512 * 1024;
const worker_count = 128;
const queue_capacity = 8192;

/// Bounded MPSC queue of accepted sockets. The accept thread pushes, a fixed
/// worker pool pops. Bounding the queue provides backpressure instead of
/// letting an unbounded backlog eat memory/file descriptors.
const StreamQueue = struct {
    mutex: std.Io.Mutex = .init,
    not_empty: std.Io.Condition = .init,
    not_full: std.Io.Condition = .init,
    items: [queue_capacity]net.Stream = undefined,
    head: usize = 0,
    tail: usize = 0,
    len: usize = 0,
    closed: bool = false,

    fn push(q: *StreamQueue, io: std.Io, stream: net.Stream) bool {
        q.mutex.lockUncancelable(io);
        while (q.len == q.items.len and !q.closed) {
            q.not_full.waitUncancelable(io, &q.mutex);
        }
        if (q.closed) {
            q.mutex.unlock(io);
            return false;
        }
        q.items[q.tail] = stream;
        q.tail = (q.tail + 1) % q.items.len;
        q.len += 1;
        q.not_empty.signal(io);
        q.mutex.unlock(io);
        return true;
    }

    fn pop(q: *StreamQueue, io: std.Io) ?net.Stream {
        q.mutex.lockUncancelable(io);
        while (q.len == 0) {
            if (q.closed) {
                q.mutex.unlock(io);
                return null;
            }
            q.not_empty.waitUncancelable(io, &q.mutex);
        }
        const stream = q.items[q.head];
        q.head = (q.head + 1) % q.items.len;
        q.len -= 1;
        q.not_full.signal(io);
        q.mutex.unlock(io);
        return stream;
    }

    fn close(q: *StreamQueue, io: std.Io) void {
        q.mutex.lockUncancelable(io);
        q.closed = true;
        q.not_empty.broadcast(io);
        q.not_full.broadcast(io);
        q.mutex.unlock(io);
    }
};

pub fn writeAllFd(fd: posix.fd_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = writeSome(fd, data[off..]) catch |err| return err;
        if (n == 0) return error.WriteFailed;
        off += n;
    }
}

fn writeSome(fd: posix.fd_t, data: []const u8) !usize {
    while (true) {
        const rc = linux.write(fd, data.ptr, data.len);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .AGAIN => return error.WouldBlock,
            else => return error.WriteFailed,
        }
    }
}

fn shutdownWrite(fd: posix.fd_t) void {
    _ = linux.shutdown(fd, linux.SHUT.WR);
}

const Direction = struct {
    src: posix.fd_t,
    dst: posix.fd_t,
    buf: [copy_buf_size]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    src_open: bool = true,
    done: bool = false,

    fn pending(d: *const Direction) bool {
        return d.start < d.end;
    }

    fn finishIfReady(d: *Direction) void {
        if (!d.done and !d.src_open and !d.pending()) {
            shutdownWrite(d.dst);
            d.done = true;
        }
    }

    fn abort(d: *Direction) void {
        d.start = 0;
        d.end = 0;
        d.src_open = false;
        d.done = true;
    }
};

/// Forward until both directions are complete. The caller owns and closes
/// the descriptors after this returns.
pub fn forward(client_fd: posix.fd_t, backend_fd: posix.fd_t) void {
    var dirs = [_]Direction{
        .{ .src = client_fd, .dst = backend_fd },
        .{ .src = backend_fd, .dst = client_fd },
    };

    while (true) {
        for (&dirs) |*d| d.finishIfReady();
        if (dirs[0].done and dirs[1].done) break;

        var pfds: [2]posix.pollfd = undefined;
        for (&dirs, 0..) |*d, i| {
            if (d.done) {
                pfds[i] = .{ .fd = -1, .events = 0, .revents = 0 };
            } else if (d.pending()) {
                pfds[i] = .{ .fd = d.dst, .events = posix.POLL.OUT, .revents = 0 };
            } else {
                pfds[i] = .{ .fd = d.src, .events = posix.POLL.IN, .revents = 0 };
            }
        }

        _ = posix.poll(&pfds, -1) catch break;

        for (&dirs, 0..) |*d, i| {
            if (d.done) continue;
            const rev = pfds[i].revents;
            if (rev == 0) continue;

            if (d.pending()) {
                if (rev & (posix.POLL.OUT | posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
                    const n = writeSome(d.dst, d.buf[d.start..d.end]) catch {
                        d.abort();
                        continue;
                    };
                    d.start += n;
                    if (d.start == d.end) {
                        d.start = 0;
                        d.end = 0;
                    }
                }
            } else if (d.src_open) {
                if (rev & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
                    const n = posix.read(d.src, &d.buf) catch {
                        d.src_open = false;
                        continue;
                    };
                    if (n == 0) {
                        d.src_open = false;
                    } else {
                        d.start = 0;
                        d.end = n;
                    }
                }
            }
        }
    }
}

pub fn pickBackend(store: *config.Store, io: std.Io, rand: std.Random, buf: []u8) ?[]const u8 {
    store.lock.lockUncancelable(io);
    defer store.lock.unlock(io);
    const cfg = store.current orelse return null;
    const idx = selector.choose(rand, cfg.hosts, cfg.weight_sum) orelse return null;
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
    queue: StreamQueue = .{},
    workers: []std.Thread = &.{},

    pub fn listen(io: std.Io, gpa: Allocator, store: *config.Store, addr: net.IpAddress) !Proxy {
        dial.ignoreSigPipe();
        const server = try addr.listen(io, .{
            .reuse_address = true,
            .kernel_backlog = 1024,
        });
        return .{ .io = io, .gpa = gpa, .store = store, .server = server };
    }

    pub fn port(self: *const Proxy) u16 {
        return self.server.socket.address.getPort();
    }

    pub fn start(self: *Proxy) !void {
        self.accept_thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn startWorkers(self: *Proxy) !void {
        if (self.workers.len != 0) return;
        const threads = try self.gpa.alloc(std.Thread, worker_count);
        errdefer self.gpa.free(threads);
        var started: usize = 0;
        errdefer for (threads[0..started]) |t| t.join();
        while (started < threads.len) : (started += 1) {
            threads[started] = try std.Thread.spawn(
                .{ .stack_size = conn_stack_size },
                workerMain,
                .{self},
            );
        }
        self.workers = threads;
    }

    pub fn run(self: *Proxy) void {
        self.startWorkers() catch |err| {
            if (!builtin.is_test) log("failed to start worker pool: {s}\n", .{@errorName(err)});
            return;
        };
        while (true) {
            const stream = self.server.accept(self.io) catch |err| {
                if (self.stopping.load(.acquire)) return;
                switch (err) {
                    error.ProcessFdQuotaExceeded,
                    error.SystemFdQuotaExceeded,
                    error.SystemResources,
                    error.ConnectionAborted,
                    => {
                        if (!builtin.is_test) log("accept error (continuing): {s}\n", .{@errorName(err)});
                        continue;
                    },
                    else => {
                        if (!builtin.is_test) log("accept error (stopping): {s}\n", .{@errorName(err)});
                        return;
                    },
                }
            };
            if (self.stopping.load(.acquire)) {
                std.Io.Threaded.closeFd(stream.socket.handle);
                return;
            }
            _ = self.total_conns.fetchAdd(1, .monotonic);
            if (!self.queue.push(self.io, stream)) {
                std.Io.Threaded.closeFd(stream.socket.handle);
                return;
            }
        }
    }

    pub fn stop(self: *Proxy) void {
        self.stopping.store(true, .release);
        self.queue.close(self.io);
        // A dummy connection wakes the blocking accept(). shutdown() on the
        // listening fd does not reliably wake Linux accept().
        if (dial.dialIpTimeout(self.server.socket.address, 500)) |fd| {
            std.Io.Threaded.closeFd(fd);
        } else |_| {}
        if (self.accept_thread) |t| {
            t.join();
            self.accept_thread = null;
        }
        self.server.deinit(self.io);
        for (self.workers) |t| t.join();
        if (self.workers.len != 0) {
            self.gpa.free(self.workers);
            self.workers = &.{};
        }
    }
};

fn workerMain(px: *Proxy) void {
    while (px.queue.pop(px.io)) |stream| handleConn(px, stream);
}

fn handleConn(px: *Proxy, client: net.Stream) void {
    const client_fd = client.socket.handle;
    defer std.Io.Threaded.closeFd(client_fd);
    _ = px.active_conns.fetchAdd(1, .monotonic);
    defer _ = px.active_conns.fetchSub(1, .monotonic);

    if (!builtin.is_test) log("accepted connection from {f}\n", .{client.socket.address});

    const seed = rng_counter.fetchAdd(0x9e3779b97f4a7c15, .monotonic);
    var prng = std.Random.DefaultPrng.init(seed);
    var addr_buf: [512]u8 = undefined;
    const addr_text = pickBackend(px.store, px.io, prng.random(), &addr_buf) orelse {
        if (!builtin.is_test) log("no available backend hosts to forward connection\n", .{});
        return;
    };

    const backend_fd = dial.dialTimeout(px.io, addr_text, dial_timeout_ms) catch |err| {
        if (!builtin.is_test) log("failed to connect to backend '{s}': {s}\n", .{ addr_text, @errorName(err) });
        return;
    };
    defer std.Io.Threaded.closeFd(backend_fd);

    dial.setKeepAlive(client_fd) catch {};
    dial.setKeepAlive(backend_fd) catch {};

    forward(client_fd, backend_fd);
}

// ---------------------------------------------------------------------------
// Integration test support
// ---------------------------------------------------------------------------

const testing = std.testing;

const EchoServer = struct {
    io: std.Io,
    server: net.Server,
    banner: []const u8,
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(self: *EchoServer, io: std.Io, banner: []const u8) !void {
        dial.ignoreSigPipe();
        const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
        self.* = .{
            .io = io,
            .server = try addr.listen(io, .{ .reuse_address = true }),
            .banner = banner,
        };
        self.thread = try std.Thread.spawn(.{}, echoRun, .{self});
    }

    fn echoRun(es: *EchoServer) void {
        while (true) {
            const stream = es.server.accept(es.io) catch return;
            if (es.stopping.load(.acquire)) {
                std.Io.Threaded.closeFd(stream.socket.handle);
                return;
            }
            const t = std.Thread.spawn(.{}, echoConn, .{ stream.socket.handle, es.banner }) catch {
                std.Io.Threaded.closeFd(stream.socket.handle);
                continue;
            };
            t.detach();
        }
    }

    fn echoConn(fd: posix.fd_t, banner: []const u8) void {
        defer std.Io.Threaded.closeFd(fd);
        if (banner.len > 0) writeAllFd(fd, banner) catch return;
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = posix.read(fd, &buf) catch return;
            if (n == 0) return;
            writeAllFd(fd, buf[0..n]) catch return;
        }
    }

    fn port(es: *const EchoServer) u16 {
        return es.server.socket.address.getPort();
    }

    fn stop(es: *EchoServer) void {
        es.stopping.store(true, .release);
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
    threaded: *std.Io.Threaded,
    io: std.Io,
    store: config.Store,

    fn init() !TestCtx {
        const t = try testing.allocator.create(std.Io.Threaded);
        t.* = .init(testing.allocator, .{});
        return .{ .threaded = t, .io = t.io(), .store = config.Store.init() };
    }

    fn deinit(ctx: *TestCtx) void {
        ctx.store.clear(testing.allocator, ctx.io);
        ctx.threaded.deinit();
        testing.allocator.destroy(ctx.threaded);
    }

    fn setConfig(ctx: *TestCtx, text: []const u8) !void {
        const cfg = try testing.allocator.create(config.Config);
        errdefer testing.allocator.destroy(cfg);
        cfg.* = try config.parse(testing.allocator, text);
        ctx.store.swap(testing.allocator, ctx.io, cfg);
    }
};

fn roundTrip(proxy_port: u16, request: []const u8) ![]u8 {
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(proxy_port) };
    const fd = try dial.dialIpTimeout(addr, 5000);
    defer std.Io.Threaded.closeFd(fd);

    try writeAllFd(fd, request);
    _ = linux.shutdown(fd, linux.SHUT.WR);

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

fn settle(io: std.Io) void {
    const d: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(30), .clock = .awake };
    d.sleep(io) catch {};
}

test "config reload changes backend selection" {
    var ctx = try TestCtx.init();
    defer ctx.deinit();
    var echo_a: EchoServer = undefined;
    try echo_a.start(ctx.io, "A>");
    defer echo_a.stop();
    var echo_b: EchoServer = undefined;
    try echo_b.start(ctx.io, "B>");
    defer echo_b.stop();

    var text_buf: [160]u8 = undefined;
    try ctx.setConfig(try std.fmt.bufPrint(&text_buf,
        \\{{"hosts":[{{"addr":"127.0.0.1:{d}","weight":1}}]}}
    , .{echo_a.port()}));

    var px = try Proxy.listen(ctx.io, testing.allocator, &ctx.store, .{ .ip4 = net.Ip4Address.loopback(0) });
    try px.start();
    defer px.stop();

    const got_a = try roundTrip(px.port(), "x");
    defer testing.allocator.free(got_a);
    try testing.expectEqualStrings("A>x", got_a);

    try ctx.setConfig(try std.fmt.bufPrint(&text_buf,
        \\{{"hosts":[{{"addr":"127.0.0.1:{d}","weight":1}}]}}
    , .{echo_b.port()}));

    const got_b = try roundTrip(px.port(), "y");
    defer testing.allocator.free(got_b);
    try testing.expectEqualStrings("B>y", got_b);
    settle(ctx.io);
}

test "all-zero weights closes without choosing a backend" {
    var ctx = try TestCtx.init();
    defer ctx.deinit();
    try ctx.setConfig(
        \\{"hosts":[{"addr":"127.0.0.1:9","weight":0}]}
    );
    var px = try Proxy.listen(ctx.io, testing.allocator, &ctx.store, .{ .ip4 = net.Ip4Address.loopback(0) });
    try px.start();
    defer px.stop();

    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(px.port()) };
    const fd = try dial.dialIpTimeout(addr, 5000);
    defer std.Io.Threaded.closeFd(fd);
    var buf: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try posix.read(fd, &buf));
    settle(ctx.io);
}
test "small packet echoes correctly after half-close" {
    var ctx = try TestCtx.init();
    defer ctx.deinit();
    var echo: EchoServer = undefined;
    try echo.start(ctx.io, "");
    defer echo.stop();

    var text_buf: [160]u8 = undefined;
    try ctx.setConfig(try std.fmt.bufPrint(&text_buf,
        \\{{"hosts":[{{"addr":"127.0.0.1:{d}","weight":100}}]}}
    , .{echo.port()}));

    var px = try Proxy.listen(ctx.io, testing.allocator, &ctx.store, .{ .ip4 = net.Ip4Address.loopback(0) });
    try px.start();
    defer px.stop();

    // roundTrip half-closes the write side immediately after sending; the
    // echo still has to come all the way back.
    const got = try roundTrip(px.port(), "hello, gopf");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello, gopf", got);
    settle(ctx.io);
}

test "large payload (2 MiB) is byte-identical" {
    var ctx = try TestCtx.init();
    defer ctx.deinit();
    var echo: EchoServer = undefined;
    try echo.start(ctx.io, "");
    defer echo.stop();

    var text_buf: [160]u8 = undefined;
    try ctx.setConfig(try std.fmt.bufPrint(&text_buf,
        \\{{"hosts":[{{"addr":"127.0.0.1:{d}","weight":100}}]}}
    , .{echo.port()}));

    var px = try Proxy.listen(ctx.io, testing.allocator, &ctx.store, .{ .ip4 = net.Ip4Address.loopback(0) });
    try px.start();
    defer px.stop();

    const size = 2 * 1024 * 1024;
    const payload = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(payload);
    var prng = std.Random.DefaultPrng.init(0x1234_5678);
    prng.random().bytes(payload);

    const got = try roundTrip(px.port(), payload);
    defer testing.allocator.free(got);
    try testing.expectEqual(size, got.len);
    try testing.expect(std.mem.eql(u8, payload, got));
    settle(ctx.io);
}
