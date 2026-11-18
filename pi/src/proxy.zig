//! Proxy core: accept loop, weighted backend selection, bidirectional
//! forwarding with half-close propagation, and hot config reload.
//!
//! Threading model: a pool of pre-spawned worker threads. The accept loop
//! hands each connection to a worker through a bounded ring queue with
//! futex/ulock wakeups; a worker runs the whole connection lifetime,
//! duplexing both directions in a single poll(2) loop.
//!
//! Forwarding buffers live on thread stacks; the hot path performs no heap
//! allocations.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const sys = @import("sys.zig");
const log = @import("log.zig").logf;
const config_mod = @import("config.zig");
const Config = config_mod.Config;

pub const dial_timeout_ms: u32 = 5000;
const copy_buf_size = 64 * 1024;
const worker_stack_size = 1 << 20;
const queue_cap = 4096;
const max_workers = 4096;
const worker_idle_poll_ms = 100;

const SpinLock = struct {
    flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *SpinLock) void {
        while (self.flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

fn futexWake(ptr: *std.atomic.Value(u32)) void {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            _ = linux.futex(&ptr.raw, .{ .cmd = .WAKE, .private = true }, 1, .{ .val2 = 0 }, null, 0);
        },
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst => {
            const c = std.c;
            const flags: c.UL = .{ .op = .COMPARE_AND_WAIT, .NO_ERRNO = true };
            while (true) {
                const status = c.__ulock_wake(flags, &ptr.raw, 0);
                if (status >= 0) return;
                switch (@as(c.E, @fromBackingInt(@intCast(@as(u16, @intCast(-status)))))) {
                    .INTR => continue,
                    .NOENT => return,
                    else => return,
                }
            }
        },
        else => @compileError("unsupported OS for CountSem"),
    }
}

fn futexWait(ptr: *std.atomic.Value(u32), expected: u32, timeout_ns: ?u64) void {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            if (timeout_ns) |ns| {
                var ts: linux.timespec = .{
                    .sec = @intCast(ns / 1_000_000_000),
                    .nsec = @intCast(ns % 1_000_000_000),
                };
                _ = linux.futex(&ptr.raw, .{ .cmd = .WAIT, .private = true }, expected, .{ .timeout = &ts }, null, 0);
            } else {
                _ = linux.futex(&ptr.raw, .{ .cmd = .WAIT, .private = true }, expected, .{ .val2 = 0 }, null, 0);
            }
        },
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst => {
            const c = std.c;
            const flags: c.UL = .{ .op = .COMPARE_AND_WAIT, .NO_ERRNO = true };
            const ns = timeout_ns orelse 0; // 0 = wait forever for __ulock_wait2
            _ = c.__ulock_wait2(flags, &ptr.raw, expected, ns, 0);
        },
        else => @compileError("unsupported OS for CountSem"),
    }
}

/// Counting semaphore via Linux futex / Darwin ulock.
const CountSem = struct {
    count: std.atomic.Value(u32),

    fn init(v: u32) CountSem {
        return .{ .count = std.atomic.Value(u32).init(v) };
    }

    fn post(self: *CountSem) void {
        _ = self.count.fetchAdd(1, .release);
        futexWake(&self.count);
    }

    fn wait(self: *CountSem) void {
        while (true) {
            var c = self.count.load(.acquire);
            while (c > 0) {
                if (self.count.cmpxchgWeak(c, c - 1, .acquire, .monotonic) == null) return;
                c = self.count.load(.acquire);
            }
            futexWait(&self.count, 0, null);
        }
    }

    /// Returns false on timeout (used so workers can notice shutdown).
    fn waitTimeout(self: *CountSem, ms: u32) bool {
        const deadline = sys.nanosNow() + @as(u64, ms) * 1_000_000;
        while (true) {
            var c = self.count.load(.acquire);
            while (c > 0) {
                if (self.count.cmpxchgWeak(c, c - 1, .acquire, .monotonic) == null) return true;
                c = self.count.load(.acquire);
            }
            const left_ns = deadline -| sys.nanosNow();
            if (left_ns == 0) return false;
            futexWait(&self.count, 0, left_ns);
        }
    }
};

const Job = struct { fd: sys.fd_t, peer: sys.SockAddr };

/// Bounded multi-consumer ring queue. Producers block when full, which
/// pushes backpressure onto the kernel accept queue.
const JobQueue = struct {
    ring: [queue_cap]Job = undefined,
    head: usize = 0,
    tail: usize = 0,
    lock: SpinLock = .{},
    items: CountSem = CountSem.init(0),
    space: CountSem = CountSem.init(queue_cap),

    fn push(q: *JobQueue, job: Job) void {
        q.space.wait();
        q.lock.lock();
        q.ring[q.tail & (queue_cap - 1)] = job;
        q.tail += 1;
        q.lock.unlock();
        q.items.post();
    }

    fn pop(q: *JobQueue) Job {
        // Caller has already consumed one `items` token.
        q.lock.lock();
        const job = q.ring[q.head & (queue_cap - 1)];
        q.head += 1;
        q.lock.unlock();
        q.space.post();
        return job;
    }
};

pub const Proxy = struct {
    gpa: std.mem.Allocator,
    listen_fd: sys.fd_t,

    cfg_lock: SpinLock = .{},
    cfg: ?*Config = null,

    active: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    dial_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rng_state: std.atomic.Value(u64),

    queue: JobQueue = .{},
    n_workers: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    idle_workers: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    base_workers: u32,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Create a proxy listening on addr and spawn the base worker pool.
    /// The proxy owns the listen fd.
    pub fn create(gpa: std.mem.Allocator, addr: *const sys.SockAddr) sys.SockError!*Proxy {
        const fd = try sys.listenTcp(addr, 1024);
        errdefer sys.closeFd(fd);
        const self = gpa.create(Proxy) catch return error.SystemResources;
        const cpus = std.Thread.getCpuCount() catch 4;
        self.* = .{
            .gpa = gpa,
            .listen_fd = fd,
            .base_workers = @intCast(@max(32, cpus * 4)),
            .rng_state = std.atomic.Value(u64).init(0x9E3779B97F4A7C15 ^ sys.nanosNow()),
        };
        var i: u32 = 0;
        while (i < self.base_workers) : (i += 1) {
            self.spawnWorker() catch |e| {
                log("failed to spawn worker: {s}", .{@errorName(e)});
                break;
            };
        }
        return self;
    }

    /// Close listener, stop and join all workers, drop the config.
    /// Callers must have stopped the accept loop first (or accept the accept
    /// thread stays parked in accept4(2) forever — it never touches self
    /// while blocked).
    pub fn destroy(self: *Proxy) void {
        self.stopping.store(true, .monotonic);
        sys.closeFd(self.listen_fd);
        var waited_ms: u64 = 0;
        while (self.n_workers.load(.acquire) != 0 and waited_ms < 10_000) : (waited_ms += 1) {
            sys.sleepMs(1);
        }
        self.cfg_lock.lock();
        const old = self.cfg;
        self.cfg = null;
        var dead: ?*Config = null;
        if (old) |o| {
            o.refs -= 1;
            if (o.refs == 0) dead = o;
        }
        self.cfg_lock.unlock();
        if (dead) |d| d.destroy();
        self.gpa.destroy(self);
    }

    pub fn localAddress(self: *Proxy) sys.SockError!sys.SockAddr {
        return sys.getSockName(self.listen_fd);
    }

    /// Swap in a new config (takes over its reference). The old config is
    /// destroyed once no in-flight connection references it.
    pub fn setConfig(self: *Proxy, cfg: *Config) void {
        self.cfg_lock.lock();
        const old = self.cfg;
        self.cfg = cfg;
        var dead: ?*Config = null;
        if (old) |o| {
            o.refs -= 1; // drop the "current pointer" reference
            if (o.refs == 0) dead = o;
        }
        self.cfg_lock.unlock();
        if (dead) |d| d.destroy();
    }

    /// Reload configuration from a JSON file. On any failure the old config
    /// is kept (this is the SIGHUP path).
    pub fn loadConfigFile(self: *Proxy, path: []const u8) !void {
        const text = sys.readFileAlloc(self.gpa, path, 8 << 20) catch |e| {
            log("config reload failed: cannot read '{s}': {s}", .{ path, @errorName(e) });
            return e;
        };
        defer self.gpa.free(text);
        const cfg = config_mod.parse(self.gpa, text) catch |e| {
            log("config reload failed: invalid config in '{s}': {s}", .{ path, @errorName(e) });
            return e;
        };
        self.setConfig(cfg);
        log("loaded new config from '{s}': {d} host(s), weight_sum={d}", .{
            path, cfg.hosts.len, cfg.weight_sum,
        });
    }

    fn acquireConfig(self: *Proxy) ?*Config {
        self.cfg_lock.lock();
        defer self.cfg_lock.unlock();
        const cfg = self.cfg orelse return null;
        cfg.refs += 1;
        return cfg;
    }

    fn releaseConfig(self: *Proxy, cfg: *Config) void {
        self.cfg_lock.lock();
        cfg.refs -= 1;
        const dead = cfg.refs == 0;
        self.cfg_lock.unlock();
        if (dead) cfg.destroy();
    }

    fn spawnWorker(self: *Proxy) !void {
        _ = self.n_workers.fetchAdd(1, .acq_rel);
        const t = std.Thread.spawn(.{ .stack_size = worker_stack_size }, workerMain, .{self}) catch |e| {
            _ = self.n_workers.fetchSub(1, .acq_rel);
            return e;
        };
        t.detach();
    }

    /// Grow the pool when work is queuing up faster than idle workers drain
    /// it; extra workers retire themselves once the burst is over.
    fn maybeGrowPool(self: *Proxy) void {
        const pending: i64 = self.queue.items.count.load(.monotonic);
        const idle = self.idle_workers.load(.monotonic);
        if (pending <= idle) return;
        const n = self.n_workers.load(.monotonic);
        if (n >= max_workers) return;
        if (self.n_workers.cmpxchgStrong(n, n + 1, .acq_rel, .monotonic) == null) {
            const t = std.Thread.spawn(.{ .stack_size = worker_stack_size }, workerMain, .{self}) catch {
                _ = self.n_workers.fetchSub(1, .acq_rel);
                return;
            };
            t.detach();
        }
    }

    /// Blocking accept loop; returns after destroy() closes the listener.
    pub fn run(self: *Proxy) void {
        while (true) {
            var peer: sys.SockAddr = .{};
            const fd = sys.acceptTcp(self.listen_fd, &peer) catch |e| {
                if (self.stopping.load(.monotonic)) return;
                log("accept error: {s}; retrying", .{@errorName(e)});
                sys.sleepMs(10);
                continue;
            };
            if (self.stopping.load(.monotonic)) {
                sys.closeFd(fd);
                return;
            }
            _ = self.total.fetchAdd(1, .monotonic);
            sys.setTcpOpts(fd);
            self.queue.push(.{ .fd = fd, .peer = peer });
            self.maybeGrowPool();
        }
    }

    /// SIGUSR1 handler payload: connection counters + config summary.
    pub fn printStatus(self: *Proxy) void {
        log("status: active_connections={d} total_connections={d} dial_errors={d} workers={d}", .{
            self.active.load(.monotonic),
            self.total.load(.monotonic),
            self.dial_errors.load(.monotonic),
            self.n_workers.load(.monotonic),
        });
        self.cfg_lock.lock();
        defer self.cfg_lock.unlock();
        if (self.cfg) |cfg| {
            log("status: config hosts={d} weight_sum={d}", .{ cfg.hosts.len, cfg.weight_sum });
            for (cfg.hosts) |h| {
                log("status:   host {s} weight={d}", .{ h.addr, h.weight });
            }
        } else {
            log("status: no config loaded", .{});
        }
    }

    fn workerMain(self: *Proxy) void {
        while (true) {
            _ = self.idle_workers.fetchAdd(1, .monotonic);
            const got = self.queue.items.waitTimeout(worker_idle_poll_ms);
            _ = self.idle_workers.fetchSub(1, .monotonic);
            if (self.stopping.load(.monotonic)) {
                _ = self.n_workers.fetchSub(1, .acq_rel);
                return;
            }
            if (!got) continue;

            const job = self.queue.pop();
            self.handleConn(job);

            // Retire extra workers once the queue has drained. The decision
            // and the count decrement must be one atomic claim, otherwise
            // concurrent retirements can drain the pool below base_workers.
            var n = self.n_workers.load(.monotonic);
            while (n > self.base_workers and self.queue.items.count.load(.monotonic) == 0) {
                if (self.n_workers.cmpxchgWeak(n, n - 1, .acq_rel, .monotonic)) |actual| {
                    n = actual;
                } else {
                    return; // retired; count already decremented
                }
            }
        }
    }

    fn handleConn(self: *Proxy, job: Job) void {
        const client_fd = job.fd;
        defer sys.closeFd(client_fd);
        _ = self.active.fetchAdd(1, .monotonic);
        defer _ = self.active.fetchSub(1, .monotonic);

        const cfg = self.acquireConfig() orelse {
            log("no configuration loaded; closing connection", .{});
            return;
        };
        defer self.releaseConfig(cfg);

        const seed = self.rng_state.fetchAdd(0x9E3779B97F4A7C15, .monotonic);
        var prng = std.Random.DefaultPrng.init(seed);
        const idx = config_mod.chooseHost(cfg.hosts, cfg.weight_sum, prng.random()) orelse {
            log("no available backend hosts to forward connection; closing", .{});
            return;
        };
        const host = &cfg.hosts[idx];

        const target = host.sockaddr orelse {
            _ = self.dial_errors.fetchAdd(1, .monotonic);
            log("failed to connect to backend '{s}': cannot resolve host name", .{host.addr});
            return;
        };
        const backend_fd = sys.connectTimeout(&target, dial_timeout_ms) catch |e| {
            _ = self.dial_errors.fetchAdd(1, .monotonic);
            log("failed to connect to backend '{s}': {s}", .{ host.addr, @errorName(e) });
            return;
        };
        defer sys.closeFd(backend_fd);
        sys.setTcpOpts(backend_fd);

        forward(client_fd, backend_fd);
    }
};

const Direction = struct {
    buffer: [copy_buf_size]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    open: bool = true,

    fn hasPending(self: *const Direction) bool {
        return self.start < self.end;
    }

    fn finish(self: *Direction, dst: sys.fd_t) void {
        self.open = false;
        self.start = self.end;
        sys.shutdownWr(dst);
    }

    fn flush(self: *Direction, dst: sys.fd_t) void {
        const sent = sys.writeNonblocking(dst, self.buffer[self.start..self.end]) catch return self.finish(dst);
        const n = sent orelse return;
        if (n == 0) return self.finish(dst);
        self.start += n;
    }

    fn read(self: *Direction, src: sys.fd_t, dst: sys.fd_t) void {
        const received = sys.readNonblocking(src, &self.buffer) catch return self.finish(dst);
        const n = received orelse return;
        if (n == 0) return self.finish(dst);
        self.start = 0;
        self.end = n;
        self.flush(dst);
    }
};

/// Each direction stops reading while it has pending output. The opposite
/// direction stays eligible, and EOF is forwarded only after pending data.
fn forward(client_fd: sys.fd_t, backend_fd: sys.fd_t) void {
    const sockets = [2]sys.fd_t{ client_fd, backend_fd };
    for (sockets) |fd| sys.setNonblocking(fd, true) catch |err| {
        log("failed to set forwarding socket nonblocking: {s}", .{@errorName(err)});
        return;
    };

    // Direction i reads sockets[i] and writes the other socket.
    var directions = [2]Direction{ .{}, .{} };
    const terminal_events = posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL;

    while (directions[0].open or directions[1].open) {
        var fds: [2]posix.pollfd = undefined;
        for (&fds, 0..) |*fd, i| {
            const outgoing = &directions[i];
            var events: i16 = 0;
            if (outgoing.open and !outgoing.hasPending()) events |= posix.POLL.IN;
            if (directions[1 - i].hasPending()) events |= posix.POLL.OUT;
            fd.* = .{ .fd = if (events != 0) sockets[i] else -1, .events = events, .revents = 0 };
        }
        _ = posix.poll(&fds, -1) catch return;

        for (&directions, 0..) |*direction, src| {
            if (!direction.open) continue;
            const dst = 1 - src;
            if (direction.hasPending()) {
                if (fds[dst].revents & (posix.POLL.OUT | terminal_events) != 0) {
                    direction.flush(sockets[dst]);
                }
            } else if (fds[src].revents & (posix.POLL.IN | terminal_events) != 0) {
                direction.read(sockets[src], sockets[dst]);
            }
        }
    }
}

// ============================== tests ==============================

const testing = std.testing;

fn echoConnWorker(fd: sys.fd_t) void {
    defer sys.closeFd(fd);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = sys.readSome(fd, &buf) catch return;
        if (n == 0) return; // close() sends FIN after all written data
        sys.writeAll(fd, buf[0..n]) catch return;
    }
}

fn echoAcceptLoop(listen_fd: sys.fd_t) void {
    while (true) {
        var peer: sys.SockAddr = .{};
        const fd = sys.acceptTcp(listen_fd, &peer) catch return;
        const t = std.Thread.spawn(.{ .stack_size = 1 << 20 }, echoConnWorker, .{fd}) catch {
            sys.closeFd(fd);
            continue;
        };
        t.detach();
    }
}

fn startEchoServer() !sys.SockAddr {
    const any = sys.sockaddrIp4(.{ 127, 0, 0, 1 }, 0);
    const fd = try sys.listenTcp(&any, 128);
    const t = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, echoAcceptLoop, .{fd});
    t.detach();
    return sys.getSockName(fd);
}

fn startProxyWithBackends(gpa: std.mem.Allocator, backends: []const sys.SockAddr) !*Proxy {
    const any = sys.sockaddrIp4(.{ 127, 0, 0, 1 }, 0);
    const proxy = try Proxy.create(gpa, &any);

    var json = std.array_list.Managed(u8).init(gpa);
    defer json.deinit();
    try json.appendSlice("{\"hosts\":[");
    for (backends, 0..) |b, i| {
        var addr_buf: [64]u8 = undefined;
        const addr_text = sys.formatSockAddr(&addr_buf, &b);
        if (i > 0) try json.appendSlice(",");
        try json.print("{{\"addr\":\"{s}\",\"weight\":100}}", .{addr_text});
    }
    try json.appendSlice("]}");

    const cfg = try config_mod.parse(gpa, json.items);
    proxy.setConfig(cfg);
    const t = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, Proxy.run, .{proxy});
    t.detach();
    return proxy;
}

fn connectOrFail(addr: *const sys.SockAddr) sys.fd_t {
    return sys.connectTimeout(addr, 5000) catch |e| {
        std.debug.panic("test connect failed: {s}", .{@errorName(e)});
    };
}

test "forward small echo packet" {
    const echo = try startEchoServer();
    const proxy = try startProxyWithBackends(testing.allocator, &.{echo});
    defer proxy.destroy();
    const proxy_addr = try proxy.localAddress();

    const c = connectOrFail(&proxy_addr);
    defer sys.closeFd(c);

    const msg = "hello gopf";
    try sys.writeAll(c, msg);
    var buf: [64]u8 = undefined;
    var got: usize = 0;
    while (got < msg.len) {
        const n = try sys.readSome(c, buf[got..]);
        if (n == 0) break;
        got += n;
    }
    try testing.expectEqualStrings(msg, buf[0..got]);
}

test "forward reverse traffic while the other direction is backpressured" {
    const client, const backend = pairs: {
        var client: [2]sys.fd_t = undefined;
        try testing.expectEqual(@as(c_int, 0), std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &client));
        errdefer for (client) |fd| sys.closeFd(fd);
        var backend: [2]sys.fd_t = undefined;
        try testing.expectEqual(@as(c_int, 0), std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &backend));
        break :pairs .{ client, backend };
    };
    var worker: ?std.Thread = null;
    defer {
        sys.closeFd(client[0]);
        sys.closeFd(backend[0]);
        if (worker) |thread| thread.join();
        sys.closeFd(client[1]);
        sys.closeFd(backend[1]);
    }
    try sys.setNonblocking(client[0], true);
    try sys.setNonblocking(backend[0], true);

    // Fill the proxy's send buffer toward the client, which has not read yet.
    const send_buffer: c_int = 4096;
    try posix.setsockopt(client[1], posix.SOL.SOCKET, posix.SO.SNDBUF, std.mem.asBytes(&send_buffer));
    try sys.setNonblocking(client[1], true);
    const filler: [4096]u8 = @splat('x');
    var filled: usize = 0;
    while (try sys.writeNonblocking(client[1], &filler)) |n| {
        try testing.expect(n > 0);
        filled += n;
    }
    while (try sys.writeNonblocking(client[1], "x")) |n| {
        try testing.expectEqual(@as(usize, 1), n);
        filled += n;
    }
    try sys.setNonblocking(client[1], false);
    try sys.writeAll(backend[0], "b");

    if (@hasDecl(posix.SO, "NOSIGPIPE")) {
        const enabled: c_int = 1;
        try posix.setsockopt(client[1], posix.SOL.SOCKET, posix.SO.NOSIGPIPE, std.mem.asBytes(&enabled));
        try posix.setsockopt(backend[1], posix.SOL.SOCKET, posix.SO.NOSIGPIPE, std.mem.asBytes(&enabled));
    }
    worker = try std.Thread.spawn(.{}, forward, .{ client[1], backend[1] });

    // Wait until the proxy has read "b" and must contend with the full buffer.
    var readable = [1]posix.pollfd{.{ .fd = backend[1], .events = posix.POLL.IN, .revents = 0 }};
    const deadline = sys.nanosNow() + 2 * std.time.ns_per_s;
    while (try posix.poll(&readable, 0) != 0) {
        if (sys.nanosNow() >= deadline) return error.Timeout;
        sys.sleepMs(1);
    }

    try sys.writeAll(client[0], "c");
    readable[0].fd = backend[0];
    try testing.expectEqual(@as(usize, 1), try posix.poll(&readable, 2000));
    var byte: [1]u8 = undefined;
    try testing.expectEqual(@as(?usize, 1), try sys.readNonblocking(backend[0], &byte));
    try testing.expectEqualStrings("c", &byte);

    // Let the pending byte drain. The backend's FIN must follow that byte.
    sys.shutdownWr(backend[0]);
    sys.shutdownWr(client[0]);
    readable[0].fd = client[0];
    const drain_deadline = sys.nanosNow() + 2 * std.time.ns_per_s;
    var received: usize = 0;
    var chunk: [filler.len]u8 = undefined;
    while (true) {
        const left_ns = drain_deadline -| sys.nanosNow();
        if (left_ns == 0) return error.Timeout;
        const left_ms = (left_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
        try testing.expectEqual(@as(usize, 1), try posix.poll(&readable, @intCast(left_ms)));
        const n = (try sys.readNonblocking(client[0], &chunk)) orelse continue;
        if (n == 0) break;
        const filler_bytes = @min(n, filled -| received);
        try testing.expectEqualSlices(u8, filler[0..filler_bytes], chunk[0..filler_bytes]);
        if (filler_bytes < n) try testing.expectEqualStrings("b", chunk[filler_bytes..n]);
        received += n;
    }
    try testing.expectEqual(filled + 1, received);
}

test "half-close: remaining data still delivered after client FIN" {
    const echo = try startEchoServer();
    const proxy = try startProxyWithBackends(testing.allocator, &.{echo});
    defer proxy.destroy();
    const proxy_addr = try proxy.localAddress();

    const c = connectOrFail(&proxy_addr);
    defer sys.closeFd(c);

    var payload: [4096]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);

    try sys.writeAll(c, &payload);
    sys.shutdownWr(c); // client half-closes: FIN to proxy

    var received = std.array_list.Managed(u8).init(testing.allocator);
    defer received.deinit();
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = try sys.readSome(c, &chunk);
        if (n == 0) break; // must reach EOF only after all bytes arrive
        try received.appendSlice(chunk[0..n]);
    }
    try testing.expectEqualSlices(u8, &payload, received.items);
}

fn bulkWriter(fd: sys.fd_t, data: []const u8) void {
    sys.writeAll(fd, data) catch {};
    sys.shutdownWr(fd);
}

test "forward 1 MiB payload byte-identical" {
    const echo = try startEchoServer();
    const proxy = try startProxyWithBackends(testing.allocator, &.{echo});
    defer proxy.destroy();
    const proxy_addr = try proxy.localAddress();

    const c = connectOrFail(&proxy_addr);
    defer sys.closeFd(c);

    const read_timeout: posix.timeval = .{ .sec = 5, .usec = 0 };
    try posix.setsockopt(c, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&read_timeout));

    const size = 1 << 20;
    const payload = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(payload);
    var prng = std.Random.DefaultPrng.init(0);
    prng.random().bytes(payload);

    const wt = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, bulkWriter, .{ c, payload });
    defer {
        _ = std.c.shutdown(c, posix.SHUT.RDWR);
        wt.join();
    }

    var received = std.array_list.Managed(u8).init(testing.allocator);
    defer received.deinit();
    var chunk: [16384]u8 = undefined;
    while (true) {
        const n = try sys.readSome(c, &chunk);
        if (n == 0) break;
        try received.appendSlice(chunk[0..n]);
    }
    try testing.expectEqual(size, received.items.len);
    try testing.expectEqualSlices(u8, payload, received.items);
}

test "reload changes the selection set" {
    const proxy_addr_any = sys.sockaddrIp4(.{ 127, 0, 0, 1 }, 0);
    const proxy = try Proxy.create(testing.allocator, &proxy_addr_any);
    defer proxy.destroy();

    const cfg_a = try config_mod.parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:11111","weight":100}]}
    );
    proxy.setConfig(cfg_a);

    const cfg_b = try config_mod.parse(testing.allocator,
        \\{"hosts":[{"addr":"127.0.0.1:22222","weight":100}]}
    );
    proxy.setConfig(cfg_b);

    var prng = std.Random.DefaultPrng.init(99);
    const cfg = proxy.acquireConfig().?;
    defer proxy.releaseConfig(cfg);
    for (0..1000) |_| {
        const i = config_mod.chooseHost(cfg.hosts, cfg.weight_sum, prng.random()).?;
        try testing.expectEqualStrings("127.0.0.1:22222", cfg.hosts[i].addr);
    }
}

test "reload from file keeps old config on failure" {
    var tmp_path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&tmp_path_buf, "/tmp/gopf-test-{d}.json", .{sys.getPid()}) catch unreachable;

    // Write a good config file.
    writeTestFile(path, "{\"hosts\":[{\"addr\":\"127.0.0.1:33333\",\"weight\":5}]}");
    defer deleteTestFile(path);

    const any = sys.sockaddrIp4(.{ 127, 0, 0, 1 }, 0);
    const proxy = try Proxy.create(testing.allocator, &any);
    defer proxy.destroy();

    try proxy.loadConfigFile(path);
    {
        const cfg = proxy.acquireConfig().?;
        defer proxy.releaseConfig(cfg);
        try testing.expectEqualStrings("127.0.0.1:33333", cfg.hosts[0].addr);
    }

    // Corrupt the file: reload must fail and the old config must survive.
    writeTestFile(path, "this is not json");
    try testing.expectError(error.InvalidJson, proxy.loadConfigFile(path));
    {
        const cfg = proxy.acquireConfig().?;
        defer proxy.releaseConfig(cfg);
        try testing.expectEqualStrings("127.0.0.1:33333", cfg.hosts[0].addr);
    }

    // A valid reload replaces it.
    writeTestFile(path, "{\"hosts\":[{\"addr\":\"127.0.0.1:44444\",\"weight\":1}]}");
    try proxy.loadConfigFile(path);
    {
        const cfg = proxy.acquireConfig().?;
        defer proxy.releaseConfig(cfg);
        try testing.expectEqualStrings("127.0.0.1:44444", cfg.hosts[0].addr);
    }
}

fn writeTestFile(path: []const u8, content: []const u8) void {
    sys.writeFile(path, content);
}

fn deleteTestFile(path: []const u8) void {
    sys.unlinkPath(path);
}
