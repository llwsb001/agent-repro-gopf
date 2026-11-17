//! gopf on libxev: callback / completion-based event loop.

const std = @import("std");
const xev = @import("xev");
const config_mod = @import("config.zig");
const Config = config_mod.Config;

const copy_buf_size = 64 * 1024;

const SpinLock = struct {
    flag: std.atomic.Value(bool) = .init(false),
    fn lock(self: *SpinLock) void {
        while (self.flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    fn unlock(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

const Proxy = struct {
    gpa: std.mem.Allocator,
    loop: *xev.Loop,
    listen: xev.TCP = undefined,
    c_accept: xev.Completion = undefined,
    cfg_lock: SpinLock = .{},
    cfg: ?*Config = null,
    active: std.atomic.Value(i64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),
    dial_errors: std.atomic.Value(u64) = .init(0),
    rng_state: std.atomic.Value(u64) = .init(0x9E3779B97F4A7C15),
    conn_pool: std.heap.MemoryPool(Conn) = .empty,

    fn setConfig(self: *Proxy, cfg: *Config) void {
        self.cfg_lock.lock();
        const old = self.cfg;
        self.cfg = cfg;
        var dead: ?*Config = null;
        if (old) |o| {
            o.refs -= 1;
            if (o.refs == 0) dead = o;
        }
        self.cfg_lock.unlock();
        if (dead) |d| d.destroy();
    }

    fn loadConfigFile(self: *Proxy, path: []const u8) !void {
        const text = try readFileAlloc(self.gpa, path);
        defer self.gpa.free(text);
        const cfg = try config_mod.parse(self.gpa, text);
        self.setConfig(cfg);
        std.log.info("loaded config from '{s}': {d} host(s), weight_sum={d}", .{
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

    fn nextRandom(self: *Proxy) std.Random {
        const s = self.rng_state.fetchAdd(0x9E3779B97F4A7C15, .monotonic);
        var prng = std.Random.DefaultPrng.init(s);
        return prng.random();
    }

    fn startAccept(self: *Proxy) void {
        self.listen.accept(self.loop, &self.c_accept, Proxy, self, acceptCb);
    }
};

fn acceptCb(
    self_: ?*Proxy,
    loop: *xev.Loop,
    c: *xev.Completion,
    r: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    _ = c;
    const self = self_.?;
    const client = r catch |e| {
        std.log.err("accept error: {s}", .{@errorName(e)});
        return .rearm;
    };

    _ = self.total.fetchAdd(1, .monotonic);

    const conn = self.conn_pool.create(self.gpa) catch {
        // Never steal the accept completion; close the fd synchronously.
        _ = std.c.close(client.fd);
        return .rearm;
    };

    var backend_ip: ?std.Io.net.IpAddress = null;
    if (self.acquireConfig()) |cfg| {
        defer self.releaseConfig(cfg);
        if (config_mod.chooseHost(cfg.hosts, cfg.weight_sum, self.nextRandom())) |idx| {
            backend_ip = cfg.hosts[idx].endpoint;
        }
    }

    conn.* = .{
        .proxy = self,
        .client = client,
        .backend = undefined,
        .state = .connecting,
    };
    _ = self.active.fetchAdd(1, .monotonic);

    const ip = backend_ip orelse {
        failConn(conn, loop);
        return .rearm;
    };

    conn.backend = xev.TCP.init(ip) catch {
        failConn(conn, loop);
        return .rearm;
    };
    conn.backend.connect(loop, &conn.c_connect, ip, Conn, conn, connectCb);
    return .rearm;
}

const Conn = struct {
    proxy: *Proxy,
    client: xev.TCP,
    backend: xev.TCP,
    state: enum { connecting, active, closing },

    c_connect: xev.Completion = undefined,
    c_cr: xev.Completion = undefined,
    c_br: xev.Completion = undefined,
    c_cw: xev.Completion = undefined,
    c_bw: xev.Completion = undefined,
    c_misc: xev.Completion = undefined,

    buf_c: [copy_buf_size]u8 = undefined,
    buf_b: [copy_buf_size]u8 = undefined,

    client_rd: bool = true,
    backend_rd: bool = true,
    client_wr: bool = true,
    backend_wr: bool = true,
    writing_c: bool = false,
    writing_b: bool = false,
};

fn connectCb(
    conn_: ?*Conn,
    loop: *xev.Loop,
    c: *xev.Completion,
    socket: xev.TCP,
    r: xev.ConnectError!void,
) xev.CallbackAction {
    _ = c;
    const conn = conn_.?;
    r catch {
        _ = conn.proxy.dial_errors.fetchAdd(1, .monotonic);
        failConn(conn, loop);
        return .disarm;
    };
    conn.state = .active;
    conn.backend = socket;
    // Start both directions.
    conn.client.read(loop, &conn.c_cr, .{ .slice = &conn.buf_c }, Conn, conn, clientReadCb);
    conn.backend.read(loop, &conn.c_br, .{ .slice = &conn.buf_b }, Conn, conn, backendReadCb);
    return .disarm;
}

fn clientReadCb(
    conn_: ?*Conn,
    loop: *xev.Loop,
    c: *xev.Completion,
    socket: xev.TCP,
    buf: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    _ = socket;
    const conn = conn_.?;
    if (conn.state == .closing) return .disarm;

    const n = r catch |err| switch (err) {
        error.EOF => {
            conn.client_rd = false;
            if (conn.backend_wr and !conn.writing_b) {
                conn.backend_wr = false;
                conn.backend.shutdown(loop, &conn.c_misc, Conn, conn, shutdownBackendCb);
            } else {
                maybeFinish(conn, loop);
            }
            return .disarm;
        },
        else => {
            failConn(conn, loop);
            return .disarm;
        },
    };

    _ = c;
    conn.writing_b = true;
    conn.backend.write(loop, &conn.c_bw, .{ .slice = buf.slice[0..n] }, Conn, conn, backendWriteCb);
    // Don't rearm read until write finishes (single buffer).
    return .disarm;
}

fn backendWriteCb(
    conn_: ?*Conn,
    loop: *xev.Loop,
    c: *xev.Completion,
    socket: xev.TCP,
    buf: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    _ = c;
    _ = socket;
    _ = buf;
    const conn = conn_.?;
    conn.writing_b = false;
    _ = r catch {
        failConn(conn, loop);
        return .disarm;
    };
    if (!conn.client_rd) {
        maybeFinish(conn, loop);
        return .disarm;
    }
    conn.client.read(loop, &conn.c_cr, .{ .slice = &conn.buf_c }, Conn, conn, clientReadCb);
    return .disarm;
}

fn backendReadCb(
    conn_: ?*Conn,
    loop: *xev.Loop,
    c: *xev.Completion,
    socket: xev.TCP,
    buf: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    _ = socket;
    const conn = conn_.?;
    if (conn.state == .closing) return .disarm;

    const n = r catch |err| switch (err) {
        error.EOF => {
            conn.backend_rd = false;
            if (conn.client_wr and !conn.writing_c) {
                conn.client_wr = false;
                conn.client.shutdown(loop, &conn.c_misc, Conn, conn, shutdownClientCb);
            } else {
                maybeFinish(conn, loop);
            }
            return .disarm;
        },
        else => {
            failConn(conn, loop);
            return .disarm;
        },
    };

    _ = c;
    conn.writing_c = true;
    conn.client.write(loop, &conn.c_cw, .{ .slice = buf.slice[0..n] }, Conn, conn, clientWriteCb);
    return .disarm;
}

fn clientWriteCb(
    conn_: ?*Conn,
    loop: *xev.Loop,
    c: *xev.Completion,
    socket: xev.TCP,
    buf: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    _ = c;
    _ = socket;
    _ = buf;
    const conn = conn_.?;
    conn.writing_c = false;
    _ = r catch {
        failConn(conn, loop);
        return .disarm;
    };
    if (!conn.backend_rd) {
        maybeFinish(conn, loop);
        return .disarm;
    }
    conn.backend.read(loop, &conn.c_br, .{ .slice = &conn.buf_b }, Conn, conn, backendReadCb);
    return .disarm;
}

fn shutdownBackendCb(
    conn_: ?*Conn,
    loop: *xev.Loop,
    c: *xev.Completion,
    s: xev.TCP,
    r: xev.ShutdownError!void,
) xev.CallbackAction {
    _ = c;
    _ = s;
    _ = r catch {};
    maybeFinish(conn_.?, loop);
    return .disarm;
}

fn shutdownClientCb(
    conn_: ?*Conn,
    loop: *xev.Loop,
    c: *xev.Completion,
    s: xev.TCP,
    r: xev.ShutdownError!void,
) xev.CallbackAction {
    _ = c;
    _ = s;
    _ = r catch {};
    maybeFinish(conn_.?, loop);
    return .disarm;
}

fn maybeFinish(conn: *Conn, loop: *xev.Loop) void {
    if (conn.state == .closing) return;
    // Done when both reads ended and no writes in flight.
    if (conn.client_rd or conn.backend_rd or conn.writing_c or conn.writing_b) return;
    conn.state = .closing;
    conn.client.close(loop, &conn.c_misc, Conn, conn, closeClientCb);
}

fn closeClientCb(
    conn_: ?*Conn,
    loop: *xev.Loop,
    c: *xev.Completion,
    s: xev.TCP,
    r: xev.CloseError!void,
) xev.CallbackAction {
    _ = c;
    _ = s;
    _ = r catch {};
    const conn = conn_.?;
    conn.backend.close(loop, &conn.c_connect, Conn, conn, closeBackendCb);
    return .disarm;
}

fn closeBackendCb(
    conn_: ?*Conn,
    loop: *xev.Loop,
    c: *xev.Completion,
    s: xev.TCP,
    r: xev.CloseError!void,
) xev.CallbackAction {
    _ = loop;
    _ = c;
    _ = s;
    _ = r catch {};
    const conn = conn_.?;
    const proxy = conn.proxy;
    _ = proxy.active.fetchSub(1, .monotonic);
    proxy.conn_pool.destroy(conn);
    return .disarm;
}

fn failConn(conn: *Conn, loop: *xev.Loop) void {
    if (conn.state == .closing) return;
    conn.state = .closing;
    conn.client_rd = false;
    conn.backend_rd = false;
    conn.client.close(loop, &conn.c_misc, Conn, conn, closeClientCb);
}

fn parseHostPort(text: []const u8) !std.Io.net.IpAddress {
    const idx = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.InvalidAddr;
    const host = text[0..idx];
    const port = try std.fmt.parseInt(u16, text[idx + 1 ..], 10);
    return std.Io.net.IpAddress.parse(host, port);
}

fn parseListen(text: []const u8) !std.Io.net.IpAddress {
    if (text.len > 0 and text[0] == ':') {
        const port = try std.fmt.parseInt(u16, text[1..], 10);
        return std.Io.net.IpAddress.parse("0.0.0.0", port);
    }
    return parseHostPort(text);
}

fn readFileAlloc(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{}, 0);
    defer _ = std.c.close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) {
            switch (std.posix.errno(n)) {
                .INTR => continue,
                else => return error.FileRead,
            }
        }
        if (n == 0) break;
        try list.appendSlice(gpa, buf[0..@intCast(n)]);
        if (list.items.len > 8 << 20) return error.FileTooBig;
    }
    return try list.toOwnedSlice(gpa);
}

fn usage() noreturn {
    std.log.err("usage: gopf [-listen host:port] config_file", .{});
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const argv = init.minimal.args.vector;
    const gpa = init.gpa;

    var listen_text: []const u8 = ":1248";
    var config_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = std.mem.sliceTo(argv[i], 0);
        if (config_path != null) break;
        if (std.mem.eql(u8, arg, "-listen") or std.mem.eql(u8, arg, "--listen")) {
            i += 1;
            if (i >= argv.len) usage();
            listen_text = std.mem.sliceTo(argv[i], 0);
        } else if (std.mem.startsWith(u8, arg, "-listen=")) {
            listen_text = arg["-listen=".len..];
        } else if (arg.len > 1 and arg[0] == '-') {
            usage();
        } else {
            config_path = arg;
        }
    }
    const path = config_path orelse usage();

    var thread_pool = xev.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    var loop = try xev.Loop.init(.{ .thread_pool = &thread_pool });
    defer loop.deinit();

    var proxy = Proxy{
        .gpa = gpa,
        .loop = &loop,
    };
    defer {
        proxy.cfg_lock.lock();
        if (proxy.cfg) |cfg| {
            cfg.refs -= 1;
            if (cfg.refs == 0) cfg.destroy();
        }
        proxy.cfg_lock.unlock();
        proxy.conn_pool.deinit(gpa);
    }

    try proxy.loadConfigFile(path);

    const addr = try parseListen(listen_text);
    proxy.listen = try xev.TCP.init(addr);
    try proxy.listen.bind(addr);
    try proxy.listen.listen(1024);
    proxy.startAccept();

    std.log.info("gopf-xev listening on {s}", .{listen_text});
    try loop.run(.until_done);
}
