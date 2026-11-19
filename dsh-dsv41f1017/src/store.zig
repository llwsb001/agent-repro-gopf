//! Thread-safe configuration store with atomic replacement on reload.
const std = @import("std");
const config = @import("config.zig");
const balancer = @import("balancer.zig");

pub const SpinLock = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn lock(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            spins += 1;
            if (spins > 200) {
                std.Thread.yield() catch {};
                spins = 0;
            } else {
                std.atomic.spinLoopHint();
            }
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};

pub const Selection = struct {
    buf: [config.max_addr_len]u8 = undefined,
    len: usize = 0,
    weight: i64 = 0,

    pub fn addr(self: *const Selection) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    lock: SpinLock = .{},
    config: config.Config,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) Store {
        return .{ .allocator = allocator, .config = cfg };
    }

    pub fn deinit(self: *Store) void {
        self.config.deinit();
    }

    /// Replace the current configuration. The old configuration is freed only
    /// after the write lock is acquired, so no reader can still be inspecting it.
    pub fn replace(self: *Store, cfg: config.Config) void {
        self.lock.lock();
        const old = self.config;
        self.config = cfg;
        self.lock.unlock();
        var old_mut = old;
        old_mut.deinit();
    }

    pub fn reloadFromBytes(self: *Store, bytes: []const u8) !void {
        var fresh = try config.Config.parse(self.allocator, bytes);
        errdefer fresh.deinit();
        self.replace(fresh);
    }

    pub fn reloadFromPath(self: *Store, path: []const u8) !void {
        const bytes = try config.readFileAlloc(self.allocator, path, 16 * 1024 * 1024);
        defer self.allocator.free(bytes);
        try self.reloadFromBytes(bytes);
    }

    pub fn choose(self: *Store, random: std.Random) ?Selection {
        self.lock.lock();
        defer self.lock.unlock();

        const idx = balancer.choose(self.config.hosts, self.config.weight_sum, random) orelse return null;
        const host = self.config.hosts[idx];
        var result = Selection{ .len = host.addr.len, .weight = host.weight };
        @memcpy(result.buf[0..host.addr.len], host.addr);
        return result;
    }

    pub fn hostCount(self: *Store) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.config.hosts.len;
    }

    pub fn weightSum(self: *Store) i64 {
        self.lock.lock();
        defer self.lock.unlock();
        return self.config.weight_sum;
    }

    pub fn logSummary(self: *Store) void {
        self.lock.lock();
        defer self.lock.unlock();
        const log = std.log.scoped(.gopf);
        log.info("config: {d} host(s), weight_sum={d}", .{ self.config.hosts.len, self.config.weight_sum });
        for (self.config.hosts) |h| {
            log.info("  backend {s} weight={d}", .{ h.addr, h.weight });
        }
    }
};
