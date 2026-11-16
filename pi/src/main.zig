//! gopf: a tiny TCP layer-4 load balancer.
//!
//!   gopf [-listen host:port] config.json
//!
//! SIGHUP reloads the config (old config kept on failure), SIGUSR1 prints
//! status, SIGTERM/SIGINT exit.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const sys = @import("sys.zig");
const config_mod = @import("config.zig");
const proxy_mod = @import("proxy.zig");
const log = @import("log.zig").logf;

const Proxy = proxy_mod.Proxy;

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

    // Never let a dead peer kill us with SIGPIPE (writes use MSG_NOSIGNAL
    // too, this is just a belt-and-suspenders default like Go's).
    const ign: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.PIPE, &ign, null);

    // Block the handled signals in every thread (all threads inherit this
    // mask) and receive them through a signalfd instead.
    var sigs = posix.sigemptyset();
    posix.sigaddset(&sigs, .HUP);
    posix.sigaddset(&sigs, .USR1);
    posix.sigaddset(&sigs, .TERM);
    posix.sigaddset(&sigs, .INT);
    posix.sigprocmask(posix.SIG.BLOCK, &sigs, null);
    const sig_fd = posix.signalfd(-1, &sigs, linux.SFD.CLOEXEC) catch |e| {
        log("signalfd failed: {s}", .{@errorName(e)});
        return 1;
    };

    // Listen socket.
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

    // Initial config load is fatal on failure, like the Go original.
    proxy.loadConfigFile(path) catch {
        log("failed to load initial configuration from '{s}'; exiting", .{path});
        return 1;
    };

    const st = std.Thread.spawn(.{}, signalThread, .{ proxy, sig_fd, path }) catch |e| {
        log("failed to spawn signal thread: {s}", .{@errorName(e)});
        return 1;
    };
    st.detach();

    log("load balancer started, listening on {s}", .{listen_text});
    proxy.run(); // never returns
    return 0;
}

test {
    // Pull in tests from all imported modules.
    _ = @import("sys.zig");
    _ = @import("config.zig");
    _ = @import("proxy.zig");
}

fn signalThread(proxy: *Proxy, sig_fd: sys.fd_t, config_path: []const u8) void {
    while (true) {
        var info: linux.signalfd_siginfo = undefined;
        const n = posix.read(sig_fd, std.mem.asBytes(&info)) catch continue;
        if (n < @sizeOf(linux.signalfd_siginfo)) continue;
        const sig = info.signo;
        if (sig == @intFromEnum(linux.SIG.HUP)) {
            log("SIGHUP received: reloading configuration", .{});
            if (proxy.loadConfigFile(config_path)) {
                log("configuration reloaded successfully", .{});
            } else |_| {
                // loadConfigFile already logged the reason; old config kept.
            }
        } else if (sig == @intFromEnum(linux.SIG.USR1)) {
            proxy.printStatus();
        } else if (sig == @intFromEnum(linux.SIG.TERM) or sig == @intFromEnum(linux.SIG.INT)) {
            log("received signal {d}, shutting down", .{sig});
            std.process.exit(0);
        }
    }
}
