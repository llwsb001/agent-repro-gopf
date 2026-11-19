//! TCP proxy built around a single epoll event loop.
//!
//! All sockets are non-blocking. Connection setup (weighted selection and a
//! 5 second connect timeout) and both forwarding directions are state machines
//! driven by one thread, so neither a thread nor a poll fd is needed per
//! connection. Half-close is explicit: EOF on one direction calls
//! shutdown(SHUT_WR) on the peer and only closes the pair after both
//! directions have finished.
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const tcp = @import("tcp.zig");
const store_mod = @import("store.zig");
const config = @import("config.zig");

const log = std.log.scoped(.gopf);

pub var pending_reload: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var pending_status: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var pending_shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn onSignal(sig: posix.SIG) callconv(.c) void {
    switch (sig) {
        .HUP => pending_reload.store(true, .release),
        .USR1 => pending_status.store(true, .release),
        .TERM, .INT => pending_shutdown.store(true, .release),
        else => {},
    }
}

pub fn installSignalHandlers() void {
    var act = posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.HUP, &act, null);
    posix.sigaction(.USR1, &act, null);
    posix.sigaction(.TERM, &act, null);
    posix.sigaction(.INT, &act, null);

    const ignore = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.PIPE, &ignore, null);
}

pub const Stats = struct {
    active: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    bytes_forwarded: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

const max_conns = 1024;
const pump_buffer_size = 32 * 1024;
const epoll_batch = 512;

const kind_listener: u64 = 0;
const kind_wake: u64 = 1;
const kind_client: u64 = 2;
const kind_backend: u64 = 3;

fn makeToken(index: u32, kind: u64) u64 {
    return (@as(u64, index) << 3) | kind;
}

const Dir = struct {
    len: usize = 0,
    off: usize = 0,
    eof: bool = false,
    done: bool = false,

    fn pending(self: *const Dir) bool {
        return self.len > self.off;
    }

    fn needsRead(self: *const Dir) bool {
        return !self.done and !self.eof and !self.pending();
    }

    fn needsWrite(self: *const Dir) bool {
        return !self.done and self.pending();
    }
};

const Conn = struct {
    owner: *Proxy,
    index: u32,
    in_use: bool = false,
    connecting: bool = false,
    client: tcp.Socket = undefined,
    backend: tcp.Socket = .{ .fd = -1 },
    c2b: Dir = .{},
    b2c: Dir = .{},
    buf_c2b: [pump_buffer_size]u8 = undefined,
    buf_b2c: [pump_buffer_size]u8 = undefined,
    client_interest: u32 = 0,
    backend_interest: u32 = 0,
    deadline_ms: u64 = 0,
    next_connecting: ?*Conn = null,
};

pub const Proxy = struct {
    allocator: std.mem.Allocator,
    listener: tcp.Socket,
    store: store_mod.Store,
    config_path: ?[]const u8,
    listen_addr: []const u8,
    stats: Stats = .{},
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stopped: bool = false,
    thread: ?std.Thread = null,

    epoll_fd: posix.fd_t,
    wake_fd: posix.fd_t,
    conns: []Conn,
    free_list: []u32,
    free_count: usize,
    connecting_head: ?*Conn = null,

    pub fn init(allocator: std.mem.Allocator, listen_addr: []const u8, cfg: config.Config, config_path: ?[]const u8) !Proxy {
        const listener = try tcp.Socket.listen(listen_addr);
        errdefer listener.close();
        listener.setNonBlocking();

        const ep_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (posix.errno(ep_rc) != .SUCCESS) return error.SystemResources;
        const epoll_fd: posix.fd_t = @intCast(ep_rc);
        errdefer _ = linux.close(epoll_fd);

        const wake_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (posix.errno(wake_rc) != .SUCCESS) return error.SystemResources;
        const wake_fd: posix.fd_t = @intCast(wake_rc);
        errdefer _ = linux.close(wake_fd);

        const conns = try allocator.alloc(Conn, max_conns);
        errdefer allocator.free(conns);
        const free_list = try allocator.alloc(u32, max_conns);
        errdefer allocator.free(free_list);
        for (conns, 0..) |*c, i| {
            c.* = undefined;
            c.index = @intCast(i);
            c.in_use = false;
        }
        for (free_list, 0..) |*slot, i| slot.* = @intCast(i);

        var self = Proxy{
            .allocator = allocator,
            .listener = listener,
            .store = store_mod.Store.init(allocator, cfg),
            .config_path = config_path,
            .listen_addr = listen_addr,
            .epoll_fd = epoll_fd,
            .wake_fd = wake_fd,
            .conns = conns,
            .free_list = free_list,
            .free_count = max_conns,
            .connecting_head = null,
        };
        self.epollAdd(listener.fd, kind_listener, linux.EPOLL.IN) catch {};
        self.epollAdd(wake_fd, kind_wake, linux.EPOLL.IN) catch {};
        return self;
    }

    pub fn initFromPath(allocator: std.mem.Allocator, listen_addr: []const u8, path: []const u8) !Proxy {
        const cfg = try config.Config.load(allocator, path);
        return init(allocator, listen_addr, cfg, path);
    }

    pub fn deinit(self: *Proxy) void {
        self.stop();
        _ = linux.close(self.epoll_fd);
        _ = linux.close(self.wake_fd);
        self.allocator.free(self.conns);
        self.allocator.free(self.free_list);
        self.listener.close();
        self.store.deinit();
    }

    pub fn port(self: *Proxy) u16 {
        return self.listener.localPort();
    }

    pub fn start(self: *Proxy) !void {
        if (self.running.load(.acquire)) return;
        self.stopped = false;
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, runThread, .{self}) catch |err| {
            self.running.store(false, .release);
            return err;
        };
    }

    fn runThread(self: *Proxy) void {
        self.run();
    }

    pub fn wait(self: *Proxy) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn stop(self: *Proxy) void {
        if (self.stopped) return;
        self.stopped = true;
        self.running.store(false, .release);
        self.wake();
        self.wait();
    }

    fn wake(self: *Proxy) void {
        var value: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&value), @sizeOf(u64));
    }

    fn drainWake(self: *Proxy) void {
        var value: u64 = 0;
        while (true) {
            const rc = linux.read(self.wake_fd, std.mem.asBytes(&value).ptr, @sizeOf(u64));
            switch (posix.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                .AGAIN => return,
                else => return,
            }
        }
    }

    fn epollAdd(self: *Proxy, fd: posix.fd_t, token: u64, events: u32) !void {
        var ev = linux.epoll_event{ .events = events, .data = .{ .u64 = token } };
        const rc = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, fd, &ev);
        if (posix.errno(rc) != .SUCCESS) return error.EpollFailed;
    }

    fn epollMod(self: *Proxy, fd: posix.fd_t, token: u64, events: u32) void {
        var ev = linux.epoll_event{ .events = events, .data = .{ .u64 = token } };
        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, fd, &ev);
    }

    fn epollDel(self: *Proxy, fd: posix.fd_t) void {
        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
    }

    fn pathOf(self: *Proxy, conn: *Conn, kind: u64) tcp.Socket {
        _ = self;
        return switch (kind) {
            kind_client => conn.client,
            else => conn.backend,
        };
    }

    fn allocConn(self: *Proxy) ?*Conn {
        if (self.free_count == 0) return null;
        self.free_count -= 1;
        const index = self.free_list[self.free_count];
        const conn = &self.conns[index];
        conn.* = .{
            .owner = self,
            .index = index,
            .in_use = true,
        };
        return conn;
    }

    fn freeConn(self: *Proxy, conn: *Conn) void {
        conn.in_use = false;
        self.free_list[self.free_count] = conn.index;
        self.free_count += 1;
    }

    fn closeConn(self: *Proxy, conn: *Conn) void {
        if (!conn.in_use) return;
        if (conn.connecting) self.unlinkConnecting(conn);
        self.epollDel(conn.client.fd);
        if (conn.backend.fd >= 0) self.epollDel(conn.backend.fd);
        conn.client.close();
        if (conn.backend.fd >= 0) conn.backend.close();
        conn.backend.fd = -1;
        conn.in_use = false;
        _ = self.stats.active.fetchSub(1, .monotonic);
        self.freeConn(conn);
    }

    fn unlinkConnecting(self: *Proxy, target: *Conn) void {
        var prev: ?*Conn = null;
        var cur = self.connecting_head;
        while (cur) |conn| {
            if (conn == target) {
                if (prev) |p| p.next_connecting = conn.next_connecting else self.connecting_head = conn.next_connecting;
                conn.next_connecting = null;
                conn.connecting = false;
                return;
            }
            prev = conn;
            cur = conn.next_connecting;
        }
    }

    fn relayInterest(self: *Proxy, conn: *Conn, client_side: bool) u32 {
        _ = self;
        var events: u32 = linux.EPOLL.RDHUP;
        if (client_side) {
            if (conn.c2b.needsRead()) events |= linux.EPOLL.IN;
            if (conn.b2c.needsWrite()) events |= linux.EPOLL.OUT;
        } else {
            if (conn.b2c.needsRead()) events |= linux.EPOLL.IN;
            if (conn.c2b.needsWrite()) events |= linux.EPOLL.OUT;
        }
        return events;
    }

    fn refreshInterests(self: *Proxy, conn: *Conn) void {
        const ci = self.relayInterest(conn, true);
        const bi = self.relayInterest(conn, false);
        if (ci != conn.client_interest) {
            conn.client_interest = ci;
            self.epollMod(conn.client.fd, makeToken(conn.index, kind_client), ci);
        }
        if (bi != conn.backend_interest) {
            conn.backend_interest = bi;
            self.epollMod(conn.backend.fd, makeToken(conn.index, kind_backend), bi);
        }
    }

    fn relayRead(self: *Proxy, conn: *Conn, client_side: bool) void {
        const src = self.pathOf(conn, if (client_side) kind_client else kind_backend);
        const dst = self.pathOf(conn, if (client_side) kind_backend else kind_client);
        const dir = if (client_side) &conn.c2b else &conn.b2c;
        const buf = if (client_side) &conn.buf_c2b else &conn.buf_b2c;

        const n = src.read(buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => {
                dir.done = true;
                dst.shutdownWrite();
                return;
            },
        };
        if (n == 0) {
            dir.eof = true;
            dir.done = true;
            dst.shutdownWrite();
            return;
        }
        dir.off = 0;
        dir.len = n;
        self.relayWrite(conn, client_side);
    }

    fn relayWrite(self: *Proxy, conn: *Conn, client_side: bool) void {
        const dst = self.pathOf(conn, if (client_side) kind_backend else kind_client);
        const dir = if (client_side) &conn.c2b else &conn.b2c;
        const buf = if (client_side) &conn.buf_c2b else &conn.buf_b2c;

        while (dir.off < dir.len) {
            const n = dst.writeSome(buf[dir.off..dir.len]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    dir.done = true;
                    dst.shutdownWrite();
                    dir.len = 0;
                    dir.off = 0;
                    return;
                },
            };
            if (n == 0) {
                dir.done = true;
                dst.shutdownWrite();
                dir.len = 0;
                dir.off = 0;
                return;
            }
            dir.off += n;
            _ = self.stats.bytes_forwarded.fetchAdd(n, .monotonic);
        }
        dir.len = 0;
        dir.off = 0;
    }

    fn finishEvent(self: *Proxy, conn: *Conn) void {
        if (!conn.in_use) return;
        if (conn.c2b.done and conn.b2c.done) {
            self.closeConn(conn);
            return;
        }
        self.refreshInterests(conn);
    }

    fn handleAccept(self: *Proxy) void {
        while (self.running.load(.acquire)) {
            const client = self.listener.acceptNonBlocking() catch |err| {
                if (err != error.WouldBlock) log.err("accept failed: {s}", .{@errorName(err)});
                return;
            };
            _ = self.stats.total.fetchAdd(1, .monotonic);
            _ = self.stats.active.fetchAdd(1, .monotonic);
            log.info("accepted connection fd={d}", .{client.fd});

            const conn = self.allocConn() orelse {
                log.err("connection limit reached; rejecting connection", .{});
                _ = self.stats.active.fetchSub(1, .monotonic);
                client.close();
                continue;
            };
            conn.* = .{
                .owner = self,
                .index = conn.index,
                .in_use = true,
                .client = client,
                .backend = .{ .fd = -1 },
            };

            const total = self.stats.total.load(.monotonic);
            const seed = tcp.nowMs() ^ (total *% 0x9E3779B97F4A7C15) ^ @as(u64, @intCast(@intFromPtr(self)));
            var prng = std.Random.DefaultPrng.init(seed);
            const selected = self.store.choose(prng.random()) orelse {
                log.warn("no available backend hosts (weight_sum<=0); closing connection", .{});
                self.closeConn(conn);
                continue;
            };
            const hp = config.splitHostPort(selected.addr()) catch {
                log.err("selected backend address became invalid: '{s}'", .{selected.addr()});
                self.closeConn(conn);
                continue;
            };

            const started = tcp.Socket.beginConnect(hp.host, hp.port) catch |err| {
                log.warn("failed to connect to backend '{s}': {s}", .{ selected.addr(), @errorName(err) });
                self.closeConn(conn);
                continue;
            };
            conn.backend = started.socket;
            client.setKeepAlive(60);
            conn.backend.setKeepAlive(60);
            client.setNoDelay();
            conn.backend.setNoDelay();

            conn.client_interest = self.relayInterest(conn, true);
            conn.backend_interest = self.relayInterest(conn, false);
            if (started.pending) {
                conn.connecting = true;
                conn.deadline_ms = tcp.nowMs() + 5000;
                self.epollAdd(conn.backend.fd, makeToken(conn.index, kind_backend), linux.EPOLL.OUT) catch {
                    self.closeConn(conn);
                    continue;
                };
                conn.next_connecting = self.connecting_head;
                self.connecting_head = conn;
            } else {
                conn.connecting = false;
                self.epollAdd(conn.client.fd, makeToken(conn.index, kind_client), conn.client_interest) catch {
                    self.closeConn(conn);
                    continue;
                };
                self.epollAdd(conn.backend.fd, makeToken(conn.index, kind_backend), conn.backend_interest) catch {
                    self.closeConn(conn);
                    continue;
                };
            }
        }
    }

    fn handleConnectFinished(self: *Proxy, conn: *Conn, events: u32) void {
        if ((events & (linux.EPOLL.OUT | linux.EPOLL.ERR | linux.EPOLL.HUP)) == 0) return;
        self.unlinkConnecting(conn);
        conn.connecting = false;
        conn.backend.finishConnect() catch |err| {
            log.warn("backend connect failed: {s}", .{@errorName(err)});
            self.closeConn(conn);
            return;
        };
        conn.client_interest = self.relayInterest(conn, true);
        conn.backend_interest = self.relayInterest(conn, false);
        self.epollAdd(conn.client.fd, makeToken(conn.index, kind_client), conn.client_interest) catch {
            self.closeConn(conn);
            return;
        };
        self.epollMod(conn.backend.fd, makeToken(conn.index, kind_backend), conn.backend_interest);
    }

    fn handleClientEvent(self: *Proxy, conn: *Conn, events: u32) void {
        if (conn.connecting) return;
        if ((events & (linux.EPOLL.IN | linux.EPOLL.RDHUP | linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0 and conn.c2b.needsRead()) {
            self.relayRead(conn, true);
        }
        if ((events & (linux.EPOLL.OUT | linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0 and conn.b2c.needsWrite()) {
            self.relayWrite(conn, false);
        }
        self.finishEvent(conn);
    }

    fn handleBackendEvent(self: *Proxy, conn: *Conn, events: u32) void {
        if (conn.connecting) {
            self.handleConnectFinished(conn, events);
            return;
        }
        if ((events & (linux.EPOLL.IN | linux.EPOLL.RDHUP | linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0 and conn.b2c.needsRead()) {
            self.relayRead(conn, false);
        }
        if ((events & (linux.EPOLL.OUT | linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0 and conn.c2b.needsWrite()) {
            self.relayWrite(conn, true);
        }
        self.finishEvent(conn);
    }

    fn connAt(self: *Proxy, index: u32) ?*Conn {
        if (index >= self.conns.len) return null;
        const conn = &self.conns[index];
        if (!conn.in_use) return null;
        return conn;
    }

    fn checkConnectTimeouts(self: *Proxy) void {
        var cur = self.connecting_head;
        const now = tcp.nowMs();
        while (cur) |conn| {
            const next = conn.next_connecting;
            if (now >= conn.deadline_ms) {
                log.err("backend connect timed out for fd={d}", .{conn.backend.fd});
                self.closeConn(conn);
            }
            cur = next;
        }
    }

    fn handleEvent(self: *Proxy, event: *const linux.epoll_event) void {
        const token = event.data.u64;
        const kind = token & 7;
        const index: u32 = @intCast(token >> 3);
        switch (kind) {
            kind_listener => self.handleAccept(),
            kind_wake => self.drainWake(),
            kind_client => if (self.connAt(index)) |conn| self.handleClientEvent(conn, event.events),
            kind_backend => if (self.connAt(index)) |conn| self.handleBackendEvent(conn, event.events),
            else => {},
        }
    }

    pub fn reload(self: *Proxy) void {
        const path = self.config_path orelse {
            log.warn("reload requested but no config path is set", .{});
            return;
        };
        log.info("reloading configuration from '{s}'", .{path});
        self.store.reloadFromPath(path) catch |err| {
            log.err("reload failed ({s}); keeping previous configuration", .{@errorName(err)});
            return;
        };
        log.info("configuration reloaded successfully", .{});
        self.store.logSummary();
    }

    pub fn reloadFromBytes(self: *Proxy, bytes: []const u8) !void {
        try self.store.reloadFromBytes(bytes);
    }

    pub fn logStatus(self: *Proxy) void {
        log.info("status: active_connections={d} total_connections={d} bytes_forwarded={d}", .{
            self.stats.active.load(.acquire),
            self.stats.total.load(.acquire),
            self.stats.bytes_forwarded.load(.acquire),
        });
        self.store.logSummary();
    }

    pub fn run(self: *Proxy) void {
        self.running.store(true, .release);
        log.info("load balancer listening on {s} (port {d})", .{ self.listen_addr, self.port() });
        self.store.logSummary();

        var events: [epoll_batch]linux.epoll_event = undefined;
        while (self.running.load(.acquire)) {
            if (pending_shutdown.swap(false, .acquire)) {
                log.info("shutdown signal received", .{});
                break;
            }
            if (pending_reload.swap(false, .acquire)) self.reload();
            if (pending_status.swap(false, .acquire)) self.logStatus();

            const rc = linux.epoll_wait(self.epoll_fd, &events, epoll_batch, 50);
            switch (posix.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => break,
            }
            const n: usize = @intCast(rc);
            for (events[0..n]) |*event| self.handleEvent(event);
            if (self.connecting_head != null) self.checkConnectTimeouts();
        }

        // Close every live connection before the owning thread exits.
        for (self.conns) |*conn| {
            if (conn.in_use) self.closeConn(conn);
        }
        self.connecting_head = null;
        self.running.store(false, .release);
    }
};
