//! gopf: a tiny TCP layer-4 load balancer.
//!
//!   gopf [-listen host:port] config.json
//!
//! SIGHUP reloads the config (old config kept on failure), SIGUSR1 prints
//! status, SIGTERM/SIGINT exit.

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");
const proxy_mod = @import("proxy.zig");
const log = @import("log.zig").logf;

const Proxy = proxy_mod.Proxy;

var sig_reload: std.atomic.Value(bool) = .init(false);
var sig_status: std.atomic.Value(bool) = .init(false);
var sig_quit: std.atomic.Value(bool) = .init(false);

fn onSignal(sig: posix.SIG) callconv(.c) void {
    switch (sig) {
        .HUP => sig_reload.store(true, .release),
        .USR1 => sig_status.store(true, .release),
        .TERM, .INT => sig_quit.store(true, .release),
        else => {},
    }
}

fn usage() noreturn {
    log("usage: gopf [-listen host:port] config_file  (default listen :1248)", .{});
    std.process.exit(1);
}

pub fn main(init: std.process.Init) u8 {
    const argv = init.minimal.args.vector;
    const gpa = init.gpa;

    var listen_text: []const u8 = ":1248";
    var config_path: ?[]const u8 = null;

    // Go flag-package semantics: flag parsing stops at the first positional.
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
        } else if (std.mem.startsWith(u8, arg, "--listen=")) {
            listen_text = arg["--listen=".len..];
        } else if (arg.len > 1 and arg[0] == '-') {
            log("unknown flag: {s}", .{arg});
            usage();
        } else {
            config_path = arg;
        }
    }
    const path = config_path orelse {
        log("configuration file path is required as the first argument", .{});
        usage();
    };

    // Ignore SIGPIPE; writes also use MSG_NOSIGNAL / SO_NOSIGPIPE where available.
    const ign: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.PIPE, &ign, null);

    // Async-signal-safe handlers only flip atomics; a watcher thread does the work.
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.HUP, &act, null);
    posix.sigaction(.USR1, &act, null);
    posix.sigaction(.TERM, &act, null);
    posix.sigaction(.INT, &act, null);

    const hp = sys.splitHostPort(listen_text) catch |e| {
        log("invalid listen address '{s}': {s}", .{ listen_text, @errorName(e) });
        return 1;
    };
    const listen_addr = sys.resolveListen(hp.host, hp.port) catch |e| {
        log("invalid listen address '{s}': {s}", .{ listen_text, @errorName(e) });
        return 1;
    };
    const proxy = Proxy.create(gpa, &listen_addr) catch |e| {
        log("failed to listen on '{s}': {s}", .{ listen_text, @errorName(e) });
        return 1;
    };

    proxy.loadConfigFile(path) catch {
        log("failed to load initial configuration from '{s}'; exiting", .{path});
        return 1;
    };

    const st = std.Thread.spawn(.{}, signalThread, .{ proxy, path }) catch |e| {
        log("failed to spawn signal thread: {s}", .{@errorName(e)});
        return 1;
    };
    st.detach();

    log("load balancer started, listening on {s}", .{listen_text});
    proxy.run(); // never returns
    return 0;
}

test {
    _ = @import("sys.zig");
    _ = @import("config.zig");
    _ = @import("proxy.zig");
}

fn signalThread(proxy: *Proxy, config_path: []const u8) void {
    while (true) {
        if (sig_quit.swap(false, .acq_rel)) {
            log("received terminate signal, shutting down", .{});
            std.process.exit(0);
        }
        if (sig_reload.swap(false, .acq_rel)) {
            log("SIGHUP received: reloading configuration", .{});
            if (proxy.loadConfigFile(config_path)) {
                log("configuration reloaded successfully", .{});
            } else |_| {}
        }
        if (sig_status.swap(false, .acq_rel)) {
            proxy.printStatus();
        }
        sys.sleepMs(10);
    }
}
