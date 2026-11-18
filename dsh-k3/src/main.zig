//! gopf：四层 TCP 负载均衡器（Go 版 gopf 的 Zig 复现）。
//!
//! 用法：gopf [-listen host:port] config_file
//!   -listen   监听地址，默认 ":1248"
//!   config_file  JSON 配置：{"hosts":[{"addr":"host:port","weight":100}]}

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const addrz = @import("addr.zig");
const configz = @import("config.zig");
const proxy = @import("proxy.zig");

fn usage() noreturn {
    proxy.logf("Usage: gopf [-listen host:port] config_file", .{});
    proxy.logf("  -listen  local address to listen on (default \":1248\")", .{});
    std.process.exit(1);
}

pub fn main(init: std.process.Init.Minimal) !u8 {
    // 先把信号屏蔽掉，全部改走 signalfd（要在创建任何线程之前做）。
    var mask = posix.sigemptyset();
    posix.sigaddset(&mask, .HUP);
    posix.sigaddset(&mask, .USR1);
    posix.sigaddset(&mask, .TERM);
    posix.sigaddset(&mask, .INT);
    posix.sigprocmask(linux.SIG.BLOCK, &mask, null);

    var listen_text: []const u8 = ":1248";
    var cfg_path: ?[]const u8 = null;

    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next(); // argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-listen")) {
            listen_text = it.next() orelse usage();
        } else if (std.mem.startsWith(u8, arg, "-listen=")) {
            listen_text = arg["-listen=".len..];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            usage();
        } else if (cfg_path == null) {
            cfg_path = arg;
        } else {
            usage();
        }
    }
    const path = cfg_path orelse {
        proxy.logf("error: configuration file path is required as the first argument", .{});
        usage();
    };

    const listen_addr = addrz.parseListen(listen_text) catch {
        proxy.logf("invalid listen address '{s}'", .{listen_text});
        return 1;
    };

    const alloc = std.heap.page_allocator;
    const cfg = alloc.create(configz.Config) catch return 1;
    cfg.* = configz.loadFile(alloc, path) catch |e| {
        proxy.logf("failed to load initial configuration from '{s}': {s}", .{ path, @errorName(e) });
        return 1;
    };

    var p = proxy.Proxy.init(alloc, listen_addr, cfg, path) catch |e| {
        proxy.logf("failed to start: {s}", .{@errorName(e)});
        cfg.deinit();
        alloc.destroy(cfg);
        return 1;
    };
    defer p.deinit();

    var lbuf: [64]u8 = undefined;
    proxy.logf("load balancer started, listening on {s}", .{p.bound.formatBuf(&lbuf)});
    proxy.logf("loaded config: {d} backend(s), weight_sum={d}", .{ p.cfg.hosts.len, p.cfg.weight_sum });

    p.run(); // 直到 SIGTERM/SIGINT 或 stop()
    proxy.logf("bye", .{});
    return 0;
}
