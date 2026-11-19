const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const gopf = @import("gopf");

var signal_pipe_write: posix.fd_t = -1;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var listen_addr: []const u8 = ":1248";
    var config_path: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-listen") or std.mem.eql(u8, arg, "--listen")) {
            index += 1;
            if (index >= args.len) return usage();
            listen_addr = args[index];
        } else if (std.mem.startsWith(u8, arg, "-listen=")) {
            listen_addr = arg["-listen=".len..];
        } else if (std.mem.startsWith(u8, arg, "--listen=")) {
            listen_addr = arg["--listen=".len..];
        } else if (config_path == null and !std.mem.startsWith(u8, arg, "-")) {
            config_path = arg;
        } else {
            return usage();
        }
    }
    const path = config_path orelse return usage();

    var proxy = try gopf.proxy.Proxy.initFile(allocator, init.io, path);
    std.debug.print("loaded config from {s}: {d} host(s), weight_sum={d}\n", .{
        path,
        proxy.snapshot().hosts.len,
        proxy.snapshot().weight_sum,
    });

    const listener = try gopf.net.listen(init.io, listen_addr);
    defer gopf.net.close(listener.fd);
    std.debug.print("listening on {s} (port {d})\n", .{ listen_addr, listener.port });

    var pipe_fds: [2]posix.fd_t = undefined;
    if (linux.pipe2(&pipe_fds, .{ .NONBLOCK = true, .CLOEXEC = true }) != 0) {
        return error.PipeFailed;
    }
    defer gopf.net.close(pipe_fds[0]);
    defer gopf.net.close(pipe_fds[1]);
    signal_pipe_write = pipe_fds[1];

    var action: posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.HUP, &action, null);
    posix.sigaction(posix.SIG.USR1, &action, null);
    posix.sigaction(posix.SIG.TERM, &action, null);
    posix.sigaction(posix.SIG.INT, &action, null);

    var poll_fds = [_]posix.pollfd{
        .{ .fd = listener.fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = pipe_fds[0], .events = posix.POLL.IN, .revents = 0 },
    };

    while (!proxy.stopping.load(.acquire)) {
        _ = posix.poll(&poll_fds, -1) catch |err| {
            std.debug.print("poll failed: {s}\n", .{@errorName(err)});
            break;
        };

        if (poll_fds[1].revents & posix.POLL.IN != 0) {
            drainSignals(&proxy, path, pipe_fds[0]);
        }
        if (!proxy.stopping.load(.acquire) and
            poll_fds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0)
        {
            _ = proxy.acceptAvailable(listener.fd);
        }
    }

    std.debug.print("shutting down\n", .{});
}

fn drainSignals(proxy: *gopf.proxy.Proxy, config_path: []const u8, read_fd: posix.fd_t) void {
    var bytes: [64]u8 = undefined;
    while (true) {
        const rc = linux.read(read_fd, &bytes, bytes.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return;
                for (bytes[0..rc]) |byte| {
                    const sig: posix.SIG = @fromBackingInt(byte);
                    switch (sig) {
                        posix.SIG.HUP => {
                            std.debug.print("reloading config {s}\n", .{config_path});
                            proxy.reloadFile(config_path) catch |err| {
                                std.debug.print("configuration reload failed: {s}\n", .{@errorName(err)});
                                continue;
                            };
                            std.debug.print("configuration reloaded successfully\n", .{});
                        },
                        posix.SIG.USR1 => proxy.status(),
                        posix.SIG.TERM, posix.SIG.INT => {
                            std.debug.print("termination signal received\n", .{});
                            proxy.stop();
                        },
                        else => {},
                    }
                }
            },
            .AGAIN => return,
            .INTR => continue,
            else => return,
        }
    }
}

fn handleSignal(sig: posix.SIG) callconv(.c) void {
    const byte: [1]u8 = .{@intCast(@backingInt(sig))};
    _ = linux.write(signal_pipe_write, &byte, 1);
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: gopf [-listen addr] config.json\n", .{});
    return error.InvalidArguments;
}
