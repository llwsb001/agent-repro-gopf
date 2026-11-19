const std = @import("std");
const gopf = @import("gopf");

const EchoServer = struct {
    listener: gopf.net.Listener,
    thread: std.Thread,
    io: std.Io,

    fn start(io: std.Io) !EchoServer {
        const listener = try gopf.net.listen(io, "127.0.0.1:0");
        const thread = try std.Thread.spawn(.{}, run, .{listener.fd});
        return .{ .listener = listener, .thread = thread, .io = io };
    }

    fn stop(self: *EchoServer) void {
        gopf.net.shutdown(self.listener.fd, .RDWR);
        self.thread.join();
        gopf.net.close(self.listener.fd);
    }

    fn run(listener_fd: gopf.net.fd_t) void {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = listener_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        while (true) {
            const ready = std.posix.poll(&poll_fds, -1) catch return;
            if (ready != 0) break;
        }
        const client_fd = gopf.net.accept(listener_fd) catch return;
        defer gopf.net.close(client_fd);

        var buffer: [16 * 1024]u8 = undefined;
        while (true) {
            const count = gopf.net.read(client_fd, &buffer) catch return;
            if (count == 0) return;
            gopf.net.writeAll(client_fd, buffer[0..count]) catch return;
        }
    }
};

test "reload changes the effective selection set and failed reload preserves it" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var proxy = try gopf.proxy.Proxy.initText(
        allocator,
        io,
        "{\"hosts\":[{\"addr\":\"127.0.0.1:1111\",\"weight\":1}]}",
    );
    defer proxy.deinit();

    try std.testing.expectEqualStrings("127.0.0.1:1111", proxy.snapshot().hosts[0].addr);

    try proxy.reloadText("{\"hosts\":[{\"addr\":\"127.0.0.1:2222\",\"weight\":1}]}");
    try std.testing.expectEqualStrings("127.0.0.1:2222", proxy.snapshot().hosts[0].addr);

    try std.testing.expectError(
        error.InvalidAddr,
        proxy.reloadText("{\"hosts\":[{\"addr\":\"bad\",\"weight\":1}]}"),
    );
    try std.testing.expectEqualStrings("127.0.0.1:2222", proxy.snapshot().hosts[0].addr);
}

test "tcp proxy forwards small payload and flushes data before half-close" {
    try runEchoScenario("hello, gopf", true);
}

test "tcp proxy preserves a one MiB payload byte-for-byte" {
    const allocator = std.testing.allocator;
    const size = 1024 * 1024 + 17;
    const payload = try allocator.alloc(u8, size);
    defer allocator.free(payload);
    for (payload, 0..) |*byte, i| byte.* = @truncate((i *% 131) +% 17);

    try runEchoScenario(payload, true);
}

fn runEchoScenario(payload: []const u8, half_close: bool) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var echo = try EchoServer.start(io);
    defer echo.stop();

    var config_buffer: [256]u8 = undefined;
    const config_text = try std.mem.print(
        &config_buffer,
        "{{\"hosts\":[{{\"addr\":\"127.0.0.1:{d}\",\"weight\":100}}]}}",
        .{echo.listener.port},
    );

    var proxy = try gopf.proxy.Proxy.initText(allocator, io, config_text);
    defer proxy.deinit();

    const proxy_listener = try gopf.net.listen(io, "127.0.0.1:0");
    defer gopf.net.close(proxy_listener.fd);

    const proxy_thread = try std.Thread.spawn(.{}, gopf.proxy.Proxy.run, .{ &proxy, proxy_listener.fd });

    var proxy_addr_buffer: [64]u8 = undefined;
    const proxy_addr = try std.mem.print(&proxy_addr_buffer, "127.0.0.1:{d}", .{proxy_listener.port});
    const client = try gopf.net.connect(io, proxy_addr, 2000);
    defer gopf.net.close(client);

    try gopf.net.writeAll(client, payload);
    if (half_close) gopf.net.shutdown(client, .WR);

    const response = try allocator.alloc(u8, payload.len);
    defer allocator.free(response);
    var received: usize = 0;
    while (received < response.len) {
        const count = try gopf.net.read(client, response[received..]);
        if (count == 0) break;
        received += count;
    }
    try std.testing.expectEqual(payload.len, received);
    try std.testing.expectEqualSlices(u8, payload, response[0..received]);

    try proxy.waitIdle(io, 3000);
    proxy.stop();
    gopf.net.shutdown(proxy_listener.fd, .RDWR);
    proxy_thread.join();
}
