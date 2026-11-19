const std = @import("std");
const sys = @import("sys.zig");
const Config = @import("config.zig").Config;
const Worker = @import("worker.zig").Worker;

const posix = std.posix;
const Allocator = std.mem.Allocator;
const connection_budget = 16_384;
const accept_batch = 64;
const usage = "usage: gopf [-listen ADDR] [-workers N] CONFIG\n";

const signal_reload = 1 << 0;
const signal_status = 1 << 1;
const signal_stop = 1 << 2;
var pending_signals = std.atomic.Value(u32).init(0);
var signal_fd = std.atomic.Value(sys.Fd).init(-1);

pub fn main(init: std.process.Init) !void {
    const options = Options.parse(init.minimal.args) catch |err| {
        std.debug.print("{s}{s}\n", .{ usage, @errorName(err) });
        std.process.exit(2);
    } orelse {
        std.debug.print("{s}", .{usage});
        return;
    };

    const allocator = std.heap.smp_allocator;
    var config = Config.load(allocator, init.io, options.config_path) catch |err| {
        std.debug.print("configuration {s}: {s}\n", .{ options.config_path, @errorName(err) });
        std.process.exit(1);
    };
    defer config.deinit();
    const listener = try openListener(allocator, options.listen);
    defer sys.close(listener);
    const port = try sys.boundPort(listener);

    var wake_pipe = try sys.WakePipe.init();
    defer wake_pipe.deinit();
    signal_fd.store(wake_pipe.write_fd, .release);
    defer signal_fd.store(-1, .release);
    installSignalHandlers();

    const workers = try allocator.alloc(Worker, options.workers);
    defer allocator.free(workers);
    var initialized: usize = 0;
    defer {
        for (workers[0..initialized]) |*worker| worker.stop();
        for (workers[0..initialized]) |*worker| worker.deinit();
    }
    const capacity = (connection_budget - 1) / workers.len + 1;
    for (workers) |*worker| {
        worker.* = try Worker.init(allocator, init.io, capacity);
        initialized += 1;
        try worker.start();
    }

    var seed: u64 = undefined;
    init.io.random(std.mem.asBytes(&seed));
    var acceptor: Acceptor = .{
        .allocator = allocator,
        .io = init.io,
        .config = &config,
        .config_path = options.config_path,
        .workers = workers,
        .listener = listener,
        .wake_pipe = wake_pipe,
        .prng = std.Random.DefaultPrng.init(seed),
    };
    std.debug.print("listening on port {d} with {d} workers\n", .{ port, workers.len });
    try acceptor.run();
}

const Options = struct {
    listen: []const u8 = ":1248",
    workers: usize,
    config_path: []const u8,

    fn parse(args: std.process.Args) !?Options {
        var iterator = std.process.Args.Iterator.init(args);
        _ = iterator.next();
        var options: Options = .{
            .workers = @min(std.Thread.getCpuCount() catch 1, 16),
            .config_path = undefined,
        };
        var path: ?[]const u8 = null;
        var positional_only = false;
        while (iterator.next()) |arg| {
            if (!positional_only and arg.len > 1 and arg[0] == '-') {
                if (std.mem.eql(u8, arg, "--")) {
                    positional_only = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return null;
                const separator = std.mem.indexOfScalar(u8, arg, '=') orelse arg.len;
                const flag = arg[0..separator];
                const value = if (separator < arg.len) arg[separator + 1 ..] else iterator.next() orelse return error.MissingOptionValue;
                if (std.mem.eql(u8, flag, "-listen")) {
                    options.listen = value;
                } else if (std.mem.eql(u8, flag, "-workers")) {
                    options.workers = std.fmt.parseInt(usize, value, 10) catch return error.InvalidWorkerCount;
                    if (options.workers == 0) return error.InvalidWorkerCount;
                } else {
                    return error.UnknownOption;
                }
                continue;
            }
            if (path != null) return error.TooManyArguments;
            path = arg;
        }
        options.config_path = path orelse return error.MissingConfigPath;
        return options;
    }
};

const Acceptor = struct {
    allocator: Allocator,
    io: std.Io,
    config: *Config,
    config_path: []const u8,
    workers: []Worker,
    listener: sys.Fd,
    wake_pipe: sys.WakePipe,
    prng: std.Random.DefaultPrng,
    next_worker: usize = 0,
    total: u64 = 0,
    dropped: u64 = 0,

    fn run(self: *Acceptor) !void {
        var events = [_]posix.pollfd{
            .{ .fd = self.wake_pipe.read_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.listener, .events = posix.POLL.IN, .revents = 0 },
        };
        while (true) {
            _ = try posix.poll(&events, -1);
            if (events[0].revents & posix.POLL.IN != 0) {
                self.wake_pipe.drain();
                const signals = pending_signals.swap(0, .acq_rel);
                if (signals & signal_stop != 0) return;
                if (signals & signal_reload != 0) self.reload();
                if (signals & signal_status != 0) self.reportStatus();
            }
            if (events[1].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
                return error.ListenerFailed;
            }
            if (events[1].revents & posix.POLL.IN != 0) {
                self.acceptBatch() catch |err| {
                    std.debug.print("accept failed: {s}\n", .{@errorName(err)});
                    // Avoid spinning while the listener remains ready and resources recover.
                    _ = try posix.poll(events[0..1], 50);
                };
            }
        }
    }

    fn acceptBatch(self: *Acceptor) !void {
        for (0..accept_batch) |_| {
            const client = try sys.accept(self.listener) orelse return;
            self.total +|= 1;
            std.debug.print("accepted fd {d}\n", .{client});
            if (!self.dispatch(client)) {
                self.dropped +|= 1;
                sys.close(client);
            }
        }
    }

    fn dispatch(self: *Acceptor, client: sys.Fd) bool {
        const addresses = self.config.choose(self.prng.random()) orelse return false;
        const fallbacks: []const sys.Address = if (addresses.len > 1)
            self.allocator.dupe(sys.Address, addresses[1..]) catch return false
        else
            &.{};
        for (0..self.workers.len) |_| {
            const worker = &self.workers[self.next_worker];
            self.next_worker = (self.next_worker + 1) % self.workers.len;
            if (worker.submit(.{ .client = client, .address = addresses[0], .fallbacks = fallbacks })) return true;
        }
        self.allocator.free(fallbacks);
        return false;
    }

    fn reload(self: *Acceptor) void {
        const replacement = Config.load(self.allocator, self.io, self.config_path) catch |err| {
            std.debug.print("reload failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.config.deinit();
        self.config.* = replacement;
        std.debug.print("reloaded configuration: hosts={d} total_weight={d}\n", .{
            self.config.hosts.len, self.config.total_weight,
        });
    }

    fn reportStatus(self: *Acceptor) void {
        var active: usize = 0;
        for (self.workers) |*worker| active += worker.activeCount();
        std.debug.print("status: active={d} total={d} dropped={d} workers={d} hosts={d} total_weight={d}\n", .{
            active, self.total, self.dropped, self.workers.len, self.config.hosts.len, self.config.total_weight,
        });
    }
};

fn openListener(allocator: Allocator, text: []const u8) !sys.Fd {
    const addresses = try sys.resolve(allocator, text, true);
    defer allocator.free(addresses);
    var last_error: anyerror = error.ListenerFailed;
    for (addresses) |address| {
        if (sys.listen(address)) |fd| {
            return fd;
        } else |err| {
            last_error = err;
        }
    }
    return last_error;
}

fn installSignalHandlers() void {
    const action: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    for ([_]posix.SIG{ .HUP, .USR1, .TERM, .INT }) |sig| {
        posix.sigaction(sig, &action, null);
    }
}

fn onSignal(sig: posix.SIG) callconv(.c) void {
    const flag: u32 = switch (sig) {
        .HUP => signal_reload,
        .USR1 => signal_status,
        .TERM, .INT => signal_stop,
        else => unreachable,
    };
    _ = pending_signals.fetchOr(flag, .release);
    const fd = signal_fd.load(.acquire);
    if (fd >= 0) sys.wakePipeFd(fd);
}
