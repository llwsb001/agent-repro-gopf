//! gopf on zio: Go-style coroutine networking.

const std = @import("std");
const zio = @import("zio");
const proxy_mod = @import("proxy.zig");
const Proxy = proxy_mod.Proxy;

pub const std_options_debug_io = zio.debug_io;

fn usage() noreturn {
    std.log.err("usage: gopf [-listen host:port] config_file", .{});
    std.process.exit(1);
}

fn parseListen(text: []const u8) !zio.net.IpAddress {
    if (text.len > 0 and text[0] == ':') {
        const port = try std.fmt.parseInt(u16, text[1..], 10);
        return zio.net.IpAddress.initIp4(.{ 0, 0, 0, 0 }, port);
    }
    return zio.net.IpAddress.parseIpAndPort(text);
}

fn handleSignals(px: *Proxy, path: []const u8, server: zio.net.Server, stopping: *std.atomic.Value(bool)) !void {
    var sighup = try zio.Signal.init(.hangup);
    defer sighup.deinit();
    var sigusr1 = try zio.Signal.init(.user1);
    defer sigusr1.deinit();
    var sigint = try zio.Signal.init(.interrupt);
    defer sigint.deinit();
    var sigterm = try zio.Signal.init(.terminate);
    defer sigterm.deinit();

    while (!stopping.load(.acquire)) {
        const which = try zio.select(.{
            .hup = &sighup,
            .usr1 = &sigusr1,
            .int = &sigint,
            .term = &sigterm,
        });
        switch (which) {
            .hup => {
                if (stopping.load(.acquire)) return;
                std.log.info("SIGHUP: reloading configuration", .{});
                if (px.loadConfigFile(path)) |_| {
                    std.log.info("configuration reloaded", .{});
                } else |_| {}
            },
            .usr1 => {
                if (stopping.load(.acquire)) return;
                px.printStatus();
            },
            .int, .term => {
                std.log.info("terminate signal, exiting", .{});
                stopping.store(true, .release);
                server.shutdown(.both) catch {};
                return;
            },
        }
    }
}

fn acceptLoop(px: *Proxy, server: zio.net.Server, stopping: *std.atomic.Value(bool)) !void {
    var group: zio.Group = .init;
    defer group.cancel();
    while (!stopping.load(.acquire)) {
        const stream = server.accept(.{}) catch |e| {
            if (stopping.load(.acquire)) return;
            std.log.err("accept error: {s}", .{@errorName(e)});
            try zio.sleep(.fromMilliseconds(10));
            continue;
        };
        if (stopping.load(.acquire)) {
            stream.close();
            return;
        }
        group.spawn(Proxy.handleConn, .{ px, stream }) catch {
            stream.close();
        };
    }
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

    var rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();

    var px = Proxy.init(gpa);
    defer px.deinit();
    try px.loadConfigFile(path);

    const listen_addr = parseListen(listen_text) catch {
        std.log.err("invalid listen address '{s}'", .{listen_text});
        return error.InvalidListen;
    };
    const server = try listen_addr.listen(.{});
    defer server.close();

    var stopping = std.atomic.Value(bool).init(false);
    var group: zio.Group = .init;
    defer group.cancel();

    try group.spawn(handleSignals, .{ &px, path, server, &stopping });
    try group.spawn(acceptLoop, .{ &px, server, &stopping });

    std.log.info("gopf-zio listening on {s}", .{listen_text});
    try group.wait();
}
