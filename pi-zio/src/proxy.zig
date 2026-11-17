//! zio-backed proxy: accept → weighted pick → dial → bidirectional copy (Go-like).

const std = @import("std");
const zio = @import("zio");
const config_mod = @import("config.zig");
const Config = config_mod.Config;

pub const dial_timeout = zio.Timeout.fromMilliseconds(5000);
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

pub const Proxy = struct {
    gpa: std.mem.Allocator,
    cfg_lock: SpinLock = .{},
    cfg: ?*Config = null,
    active: std.atomic.Value(i64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),
    dial_errors: std.atomic.Value(u64) = .init(0),
    rng_state: std.atomic.Value(u64),

    pub fn init(gpa: std.mem.Allocator) Proxy {
        return .{
            .gpa = gpa,
            .rng_state = .init(0x9E3779B97F4A7C15),
        };
    }

    pub fn deinit(self: *Proxy) void {
        self.cfg_lock.lock();
        defer self.cfg_lock.unlock();
        if (self.cfg) |c| {
            c.refs -= 1;
            if (c.refs == 0) c.destroy();
            self.cfg = null;
        }
    }

    pub fn setConfig(self: *Proxy, cfg: *Config) void {
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

    pub fn loadConfigFile(self: *Proxy, path: []const u8) !void {
        const text = readFileAlloc(self.gpa, path) catch |e| {
            std.log.err("config reload failed: cannot read '{s}': {s}", .{ path, @errorName(e) });
            return e;
        };
        defer self.gpa.free(text);
        const cfg = config_mod.parse(self.gpa, text) catch |e| {
            std.log.err("config reload failed: invalid config in '{s}': {s}", .{ path, @errorName(e) });
            return e;
        };
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

    pub fn printStatus(self: *Proxy) void {
        std.log.info("status: active={d} total={d} dial_errors={d}", .{
            self.active.load(.monotonic),
            self.total.load(.monotonic),
            self.dial_errors.load(.monotonic),
        });
        self.cfg_lock.lock();
        defer self.cfg_lock.unlock();
        if (self.cfg) |cfg| {
            std.log.info("status: hosts={d} weight_sum={d}", .{ cfg.hosts.len, cfg.weight_sum });
            for (cfg.hosts) |h| {
                std.log.info("status:   {s} weight={d}", .{ h.addr, h.weight });
            }
        }
    }

    pub fn handleConn(self: *Proxy, client: zio.net.Stream) void {
        defer client.close();
        _ = self.active.fetchAdd(1, .monotonic);
        defer _ = self.active.fetchSub(1, .monotonic);
        _ = self.total.fetchAdd(1, .monotonic);

        client.socket.setKeepAlive(true) catch {};

        const cfg = self.acquireConfig() orelse {
            std.log.warn("no configuration loaded; closing", .{});
            return;
        };
        defer self.releaseConfig(cfg);

        const idx = config_mod.chooseHost(cfg.hosts, cfg.weight_sum, self.nextRandom()) orelse {
            std.log.warn("no available backend; closing", .{});
            return;
        };
        const host = cfg.hosts[idx];

        const backend = host.endpoint.connect(.{ .timeout = dial_timeout }) catch |e| {
            _ = self.dial_errors.fetchAdd(1, .monotonic);
            std.log.err("dial '{s}' failed: {s}", .{ host.addr, @errorName(e) });
            return;
        };
        defer backend.close();
        backend.socket.setKeepAlive(true) catch {};

        forward(client, backend);
    }
};

fn readFileAlloc(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try zio.Dir.cwd().openFile(path, .{});
    defer file.close();
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [16384]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.read(&buf, offset);
        if (n == 0) break;
        try list.appendSlice(gpa, buf[0..n]);
        offset += n;
        if (list.items.len > 8 << 20) return error.FileTooBig;
    }
    return try list.toOwnedSlice(gpa);
}

fn copyOneWay(src: zio.net.Stream, dst: zio.net.Stream) void {
    var buf: [copy_buf_size]u8 = undefined;
    while (true) {
        const n = src.read(&buf, .none) catch break;
        if (n == 0) break;
        dst.writeAll(buf[0..n], .none) catch break;
    }
    dst.shutdown(.send) catch {};
}

fn forward(client: zio.net.Stream, backend: zio.net.Stream) void {
    var group: zio.Group = .init;
    defer group.cancel();
    group.spawn(copyOneWay, .{ backend, client }) catch {
        copyOneWay(client, backend);
        return;
    };
    copyOneWay(client, backend);
    group.wait() catch {};
}
