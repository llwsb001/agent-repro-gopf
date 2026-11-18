//! gopf-zig: a Layer-4 (TCP) load balancer, Zig port of the Go original.
//!
//! Usage: gopf [-listen addr] config.json
//! Signals: SIGHUP reload config, SIGUSR1 status, SIGTERM/SIGINT exit.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const sys = @import("sys.zig");
const config = @import("config.zig");
const proxy = @import("proxy.zig");
const log = @import("log.zig");

var signal_pipe_wr: std.atomic.Value(posix.fd_t) = std.atomic.Value(posix.fd_t).init(-1);

fn onSignal(sig: posix.SIG) callconv(.c) void {
    const fd = signal_pipe_wr.load(.monotonic);
    if (fd < 0) return;
    const byte: [1]u8 = .{@intCast(@intFromEnum(sig))};
    // write(2) is async-signal-safe; pipe is non-blocking so we never block.
    _ = linux.write(fd, &byte, 1);
}

fn installSignalHandler(sig: posix.SIG) void {
    const act = posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    posix.sigaction(sig, &act, null);
}

fn usage(prog: []const u8) noreturn {
    std.debug.print(
        "Usage: {s} [options] config_file\n" ++
            "  -listen addr\tLocal address to listen on (default \":1248\")\n",
        .{prog},
    );
    std.process.exit(1);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;

    // Parse args: -listen / --listen / -listen=... plus first positional arg.
    // Zig 0.17 passes argv via the main() parameter (no argsAlloc anymore).
    const argv = init.args.vector;
    const prog: []const u8 = if (argv.len > 0) std.mem.span(argv[0]) else "gopf";
    var listen_addr: []const u8 = ":1248";
    var config_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg: []const u8 = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "-listen") or std.mem.eql(u8, arg, "--listen")) {
            i += 1;
            if (i >= argv.len) usage(prog);
            listen_addr = std.mem.span(argv[i]);
        } else if (std.mem.startsWith(u8, arg, "-listen=")) {
            listen_addr = arg["-listen=".len..];
        } else if (std.mem.startsWith(u8, arg, "--listen=")) {
            listen_addr = arg["--listen=".len..];
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            usage(prog);
        } else if (arg.len > 0 and arg[0] == '-') {
            std.debug.print("unknown flag: {s}\n", .{arg});
            usage(prog);
        } else if (config_path == null) {
            config_path = arg;
        }
    }
    const cfg_path = config_path orelse {
        log.print("Error: Configuration file path is required as the first argument.", .{});
        usage(prog);
    };

    // Go ignores SIGPIPE implicitly; writes to dead sockets must return
    // EPIPE instead of killing the process.
    posix.sigaction(posix.SIG.PIPE, &.{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    }, null);

    // Initial config load (fatal on failure, like log.Fatalf).
    const text = sys.readFile(alloc, cfg_path, 16 << 20) catch |err| {
        log.print("Failed to load initial configuration from '{s}': {s}", .{ cfg_path, @errorName(err) });
        std.process.exit(1);
    };
    defer alloc.free(text);
    const cfg = config.parse(alloc, text) catch |err| {
        log.print("Failed to load initial configuration from '{s}': {s}", .{ cfg_path, @errorName(err) });
        std.process.exit(1);
    };
    log.print("Loaded new config: {d} hosts, weight_sum={d}", .{ cfg.hosts.len, cfg.weight_sum });

    var store = config.Store.init(cfg);
    var stats = proxy.Stats{};
    const seed: u64 = @truncate(@as(u128, @bitCast(sys.nowNs())));
    var p = proxy.Proxy.init(&store, &stats, seed ^ @as(u64, @intCast(linux.getpid())));

    const listener = sys.listen(listen_addr) catch |err| {
        log.print("Failed to create listener on '{s}': {s}", .{ listen_addr, @errorName(err) });
        std.process.exit(1);
    };
    defer sys.close(listener);
    log.print("Load balancer started, listening on {s}", .{listen_addr});

    // Self-pipe for signal delivery into the poll-based accept loop.
    var pipefds: [2]posix.fd_t = undefined;
    if (linux.errno(linux.pipe2(&pipefds, .{ .NONBLOCK = true, .CLOEXEC = true })) != .SUCCESS) {
        log.print("Failed to create signal pipe", .{});
        std.process.exit(1);
    }
    signal_pipe_wr.store(pipefds[1], .monotonic);
    installSignalHandler(posix.SIG.HUP);
    installSignalHandler(posix.SIG.USR1);
    installSignalHandler(posix.SIG.TERM);
    installSignalHandler(posix.SIG.INT);

    while (true) {
        var pfds = [2]posix.pollfd{
            .{ .fd = listener, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = pipefds[0], .events = posix.POLL.IN, .revents = 0 },
        };
        _ = posix.poll(&pfds, -1) catch continue;

        if (pfds[1].revents & posix.POLL.IN != 0) {
            var sigbuf: [64]u8 = undefined;
            const n = posix.read(pipefds[0], &sigbuf) catch 0;
            for (sigbuf[0..n]) |byte| {
                const sig: posix.SIG = @enumFromInt(byte);
                switch (sig) {
                    .HUP => {
                        log.print("Reloading configuration...", .{});
                        store.reload(alloc, cfg_path) catch |err| {
                            log.print("Configuration reload failed: {s}", .{@errorName(err)});
                            continue;
                        };
                        log.print("Configuration reloaded successfully.", .{});
                    },
                    .USR1 => {
                        log.print("Status: active_connections={d} total_connections={d}", .{
                            stats.active.load(.monotonic),
                            stats.total.load(.monotonic),
                        });
                        store.logSummary();
                    },
                    .TERM, .INT => {
                        log.print("Received signal {s}, shutting down...", .{@tagName(sig)});
                        std.process.exit(0);
                    },
                    else => {},
                }
            }
        }

        if (pfds[0].revents & posix.POLL.IN != 0) {
            const client = sys.accept(listener) catch |err| {
                log.print("Accept error: {s}", .{@errorName(err)});
                continue;
            };
            var namebuf: [128]u8 = undefined;
            log.print("Accepted connection from {s}", .{sys.peerName(client, &namebuf)});
            const thread = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, proxy.Proxy.handleConn, .{ &p, client }) catch |err| {
                log.print("Failed to spawn connection thread: {s}", .{@errorName(err)});
                sys.close(client);
                continue;
            };
            thread.detach();
        }
    }
}
