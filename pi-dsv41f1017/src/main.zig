//! gopf: a small four-layer TCP load balancer reimplemented in Zig.
//!
//!   gopf [-listen addr] config.json
//!
//! * listens on addr (default :1248)
//! * picks a backend by weighted random selection
//! * SIGHUP reloads, SIGUSR1 prints status, SIGTERM/SIGINT exit

const std = @import("std");
const posix = std.posix;
const net = std.Io.net;

const config = @import("config.zig");
const dial = @import("dial.zig");
const proxy = @import("proxy.zig");

const log = std.debug.print;

const usage_text =
    \\Usage: gopf [options] config_file
    \\  -listen addr   Local address to listen on (default ":1248")
    \\
;

var sig_reload = std.atomic.Value(bool).init(false);
var sig_status = std.atomic.Value(bool).init(false);
var sig_quit = std.atomic.Value(bool).init(false);

fn onSignal(sig: posix.SIG) callconv(.c) void {
    switch (sig) {
        .HUP => sig_reload.store(true, .release),
        .USR1 => sig_status.store(true, .release),
        .TERM, .INT => sig_quit.store(true, .release),
        else => {},
    }
}

fn installSignalHandlers() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.HUP, &act, null);
    posix.sigaction(.USR1, &act, null);
    posix.sigaction(.TERM, &act, null);
    posix.sigaction(.INT, &act, null);
}

const WatcherCtx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    config_path: []const u8,
    store: *config.Store,
    px: *proxy.Proxy,
};

fn reloadConfig(ctx: *const WatcherCtx) void {
    log("reloading configuration from '{s}'...\n", .{ctx.config_path});
    var new_cfg = config.loadFromFile(ctx.gpa, ctx.io, ctx.config_path) catch |err| {
        log("configuration reload failed: {s} (keeping previous config)\n", .{@errorName(err)});
        return;
    };
    const heap_cfg = ctx.gpa.create(config.Config) catch {
        new_cfg.deinit(ctx.gpa);
        log("configuration reload failed: OutOfMemory (keeping previous config)\n", .{});
        return;
    };
    heap_cfg.* = new_cfg;
    ctx.store.swap(ctx.gpa, ctx.io, heap_cfg);
    log("configuration reloaded successfully: hosts={d} weight_sum={d}\n", .{ new_cfg.hosts.len, new_cfg.weight_sum });
}

fn printStatus(ctx: *const WatcherCtx) void {
    log("status: active_connections={d} total_connections={d}\n", .{
        ctx.px.active_conns.load(.monotonic),
        ctx.px.total_conns.load(.monotonic),
    });
    var maybe_snap = ctx.store.snapshot(ctx.gpa, ctx.io) catch {
        log("status: failed to snapshot config\n", .{});
        return;
    };
    if (maybe_snap) |*snap| {
        defer snap.deinit(ctx.gpa);
        log("status: backends (weight_sum={d}):\n", .{snap.weight_sum});
        for (snap.hosts) |h| log("  - {s} weight={d}\n", .{ h.addr, h.weight });
    } else {
        log("status: no config loaded\n", .{});
    }
}

fn signalWatcher(ctx: *const WatcherCtx) void {
    while (true) {
        const tick: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(10), .clock = .awake };
        tick.sleep(ctx.io) catch {};
        if (sig_quit.swap(false, .acq_rel)) {
            log("received termination signal, shutting down...\n", .{});
            std.process.exit(0);
        }
        if (sig_reload.swap(false, .acq_rel)) reloadConfig(ctx);
        if (sig_status.swap(false, .acq_rel)) printStatus(ctx);
    }
}

fn parseListenAddr(io: std.Io, text: []const u8) !net.IpAddress {
    const hp = try dial.splitHostPort(text);
    if (hp.host.len == 0) {
        return .{ .ip4 = net.Ip4Address.unspecified(hp.port) };
    }
    return dial.resolve(io, text);
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var listen_text: []const u8 = ":1248";
    var config_path: ?[]const u8 = null;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-listen")) {
            listen_text = args.next() orelse {
                log("error: -listen requires a value\n{s}", .{usage_text});
                return 1;
            };
        } else if (std.mem.startsWith(u8, arg, "-listen=")) {
            listen_text = arg["-listen=".len..];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            log("error: unknown flag '{s}'\n{s}", .{ arg, usage_text });
            return 1;
        } else if (config_path == null) {
            config_path = arg;
        } else {
            log("error: unexpected extra argument '{s}'\n{s}", .{ arg, usage_text });
            return 1;
        }
    }

    const cfg_path = config_path orelse {
        log("error: configuration file path is required\n{s}", .{usage_text});
        return 1;
    };

    var store = config.Store.init();
    {
        const cfg = config.loadFromFile(gpa, io, cfg_path) catch |err| {
            log("failed to load initial configuration from '{s}': {s}\n", .{ cfg_path, @errorName(err) });
            return 1;
        };
        const heap_cfg = try gpa.create(config.Config);
        heap_cfg.* = cfg;
        store.swap(gpa, io, heap_cfg);
        log("loaded config: hosts={d} weight_sum={d}\n", .{ cfg.hosts.len, cfg.weight_sum });
    }

    const listen_addr = parseListenAddr(io, listen_text) catch |err| {
        log("invalid listen address '{s}': {s}\n", .{ listen_text, @errorName(err) });
        return 1;
    };

    var px = proxy.Proxy.listen(io, gpa, &store, listen_addr) catch |err| {
        log("failed to create listener on '{s}': {s}\n", .{ listen_text, @errorName(err) });
        return 1;
    };
    log("load balancer started, listening on {f}\n", .{listen_addr});

    installSignalHandlers();

    const watcher_ctx: WatcherCtx = .{
        .io = io,
        .gpa = gpa,
        .config_path = cfg_path,
        .store = &store,
        .px = &px,
    };
    const watcher = try std.Thread.spawn(.{}, signalWatcher, .{&watcher_ctx});
    watcher.detach();

    px.run();
    return 0;
}