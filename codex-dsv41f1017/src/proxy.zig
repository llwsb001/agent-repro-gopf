const std = @import("std");
const posix = std.posix;
const config = @import("config.zig");
const net = @import("net.zig");

pub const Proxy = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    current: std.atomic.Value(*config.Config),
    retired: std.ArrayList(*config.Config) = .empty,
    config_lock: std.atomic.Mutex = .unlocked,
    active_connections: std.atomic.Value(u64) = .init(0),
    total_connections: std.atomic.Value(u64) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn initText(allocator: std.mem.Allocator, io: std.Io, text: []const u8) !Proxy {
        const loaded = try allocator.create(config.Config);
        errdefer allocator.destroy(loaded);
        loaded.* = try config.parse(allocator, text);
        return .{
            .allocator = allocator,
            .io = io,
            .current = std.atomic.Value(*config.Config).init(loaded),
        };
    }

    pub fn initFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Proxy {
        const loaded = try allocator.create(config.Config);
        errdefer allocator.destroy(loaded);
        loaded.* = try config.loadFile(allocator, io, path);
        return .{
            .allocator = allocator,
            .io = io,
            .current = std.atomic.Value(*config.Config).init(loaded),
        };
    }

    pub fn deinit(self: *Proxy) void {
        self.current.load(.acquire).deinit();
        self.allocator.destroy(self.current.load(.acquire));
        for (self.retired.items) |old| {
            old.deinit();
            self.allocator.destroy(old);
        }
        self.retired.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn snapshot(self: *const Proxy) *const config.Config {
        return self.current.load(.acquire);
    }

    pub fn reloadText(self: *Proxy, text: []const u8) !void {
        const replacement = try self.allocator.create(config.Config);
        replacement.* = config.parse(self.allocator, text) catch |err| {
            self.allocator.destroy(replacement);
            return err;
        };
        var installed = false;
        errdefer if (!installed) {
            replacement.deinit();
            self.allocator.destroy(replacement);
        };

        while (!self.config_lock.tryLock()) std.atomic.spinLoopHint();
        try self.installConfig(replacement);
        installed = true;
    }

    fn installConfig(self: *Proxy, replacement: *config.Config) !void {
        defer self.config_lock.unlock();
        const old = self.current.load(.monotonic);
        try self.retired.append(self.allocator, old);
        self.current.store(replacement, .release);
    }

    pub fn reloadFile(self: *Proxy, path: []const u8) !void {
        const text = try std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.allocator,
            .limited(1024 * 1024),
        );
        defer self.allocator.free(text);
        try self.reloadText(text);
    }

    pub fn status(self: *const Proxy) void {
        const cfg = self.snapshot();
        std.debug.print(
            "status: active_connections={d} total_connections={d} hosts={d} weight_sum={d}\n",
            .{
                self.active_connections.load(.acquire),
                self.total_connections.load(.monotonic),
                cfg.hosts.len,
                cfg.weight_sum,
            },
        );
        for (cfg.hosts) |host| {
            std.debug.print("  backend {s} weight={d}\n", .{ host.addr, host.weight });
        }
    }

    pub fn activeConnections(self: *const Proxy) u64 {
        return self.active_connections.load(.acquire);
    }

    pub fn waitIdle(self: *const Proxy, io: std.Io, timeout_ms: u64) !void {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        while (self.activeConnections() != 0) {
            const elapsed = start.untilNow(io);
            if (elapsed.raw.toMilliseconds() >= @as(i64, @intCast(timeout_ms))) return error.Timeout;
            try std.Io.sleep(io, .fromMilliseconds(2), .awake);
        }
    }

    pub fn stop(self: *Proxy) void {
        self.stopping.store(true, .release);
    }

    pub fn acceptAvailable(self: *Proxy, listener_fd: net.fd_t) usize {
        var accepted: usize = 0;
        while (!self.stopping.load(.acquire)) {
            const client_fd = net.accept(listener_fd) catch |err| switch (err) {
                error.WouldBlock, error.Interrupted => break,
                error.ListenerStopped => {
                    self.stop();
                    break;
                },
                else => {
                    std.debug.print("accept error: {s}\n", .{@errorName(err)});
                    break;
                },
            };
            accepted += 1;
            _ = self.active_connections.fetchAdd(1, .acq_rel);
            _ = self.total_connections.fetchAdd(1, .monotonic);
            std.debug.print("accepted connection fd={d}\n", .{client_fd});

            const thread = std.Thread.spawn(
                .{ .stack_size = 256 * 1024 },
                handleClientThread,
                .{ self, client_fd },
            ) catch |err| {
                std.debug.print("failed to spawn connection thread: {s}\n", .{@errorName(err)});
                _ = self.active_connections.fetchSub(1, .acq_rel);
                net.close(client_fd);
                continue;
            };
            thread.detach();
        }
        return accepted;
    }

    pub fn run(self: *Proxy, listener_fd: net.fd_t) void {
        var poll_fds = [_]posix.pollfd{.{
            .fd = listener_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        while (!self.stopping.load(.acquire)) {
            _ = posix.poll(&poll_fds, 100) catch break;
            if (poll_fds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
                _ = self.acceptAvailable(listener_fd);
            }
        }
    }
};

fn handleClientThread(proxy: *Proxy, client_fd: net.fd_t) void {
    defer {
        _ = proxy.active_connections.fetchSub(1, .acq_rel);
    }
    handleClient(proxy, client_fd);
}

fn handleClient(proxy: *Proxy, client_fd: net.fd_t) void {
    defer net.close(client_fd);

    const cfg = proxy.snapshot();
    var seed_bytes: [8]u8 = undefined;
    proxy.io.random(&seed_bytes);
    var prng = std.Random.DefaultPrng.init(@as(u64, @bitCast(seed_bytes)));
    const index = config.chooseIndex(cfg, prng.random()) orelse {
        std.debug.print("no available backend hosts; closing connection\n", .{});
        return;
    };
    const backend_addr = cfg.hosts[index].addr;

    const backend_fd = net.connect(proxy.io, backend_addr, 5000) catch |err| {
        std.debug.print("dial backend {s} failed: {s}\n", .{ backend_addr, @errorName(err) });
        return;
    };
    defer net.close(backend_fd);

    net.setKeepAlive(client_fd);
    net.setKeepAlive(backend_fd);

    var client_buffer: [16 * 1024]u8 = undefined;
    var backend_context = CopyContext{
        .source = backend_fd,
        .destination = client_fd,
        .buffer = &client_buffer,
    };
    const thread = std.Thread.spawn(
        .{ .stack_size = 64 * 1024 },
        copyWorker,
        .{&backend_context},
    ) catch {
        return;
    };

    var backend_to_client_buffer: [16 * 1024]u8 = undefined;
    copyLoop(client_fd, backend_fd, &backend_to_client_buffer);
    thread.join();
}

const CopyContext = struct {
    source: net.fd_t,
    destination: net.fd_t,
    buffer: *[16 * 1024]u8,
};

fn copyWorker(context: *CopyContext) void {
    copyLoop(context.source, context.destination, context.buffer);
}

fn copyLoop(source: net.fd_t, destination: net.fd_t, buffer: *[16 * 1024]u8) void {
    copy: {
        while (true) {
            const count = net.read(source, buffer) catch break :copy;
            if (count == 0) break :copy;
            net.writeAll(destination, buffer[0..count]) catch break :copy;
        }
    }
    net.shutdown(destination, .WR);
}
