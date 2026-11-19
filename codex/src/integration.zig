const std = @import("std");
const sys = @import("sys.zig");
const Worker = @import("worker.zig").Worker;

const testing = std.testing;
const posix = std.posix;
const timeout_ms = 5000;
const restricted_buffer = 4 * 1024;

test "client FIN reaches backend before the backend replies" {
    var worker = try Worker.init(testing.allocator, testing.io, 4);
    defer worker.deinit();
    try worker.start();
    const peers = try Peers.open(&worker, false);
    defer peers.close();

    try writeAll(peers.client, "request");
    sys.shutdownWrite(peers.client);
    try expectData(peers.backend, "request");
    try expectEof(peers.backend);

    try writeAll(peers.backend, "response after client FIN");
    sys.shutdownWrite(peers.backend);
    try expectData(peers.client, "response after client FIN");
    try expectEof(peers.client);
}

test "backend FIN reaches client before the client replies" {
    var worker = try Worker.init(testing.allocator, testing.io, 4);
    defer worker.deinit();
    try worker.start();
    const peers = try Peers.open(&worker, false);
    defer peers.close();

    try writeAll(peers.backend, "banner");
    sys.shutdownWrite(peers.backend);
    try expectData(peers.client, "banner");
    try expectEof(peers.client);

    try writeAll(peers.client, "response after backend FIN");
    sys.shutdownWrite(peers.client);
    try expectData(peers.backend, "response after backend FIN");
    try expectEof(peers.backend);
}

test "backpressure in either TCP direction leaves the opposite direction running" {
    var worker = try Worker.init(testing.allocator, testing.io, 4);
    defer worker.deinit();
    try worker.start();

    const payload = try testing.allocator.alloc(u8, 8 * 1024 * 1024);
    defer testing.allocator.free(payload);
    var prng = std.Random.DefaultPrng.init(0);
    prng.random().bytes(payload);

    for ([_]bool{ false, true }) |client_sends| {
        const peers = try Peers.open(&worker, true);
        defer peers.close();
        const sender = if (client_sends) peers.client else peers.backend;
        const receiver = if (client_sends) peers.backend else peers.client;
        const sent = try fillUntilBackpressured(sender, payload);
        try testing.expect(sent > 0);

        try writeAll(receiver, "reverse traffic");
        try expectData(sender, "reverse traffic");

        // The small receive window has served its purpose. Restore room for
        // the drain so TCP window updates don't dominate its deadline.
        try setBufferSize(receiver, posix.SO.RCVBUF, 256 * 1024);
        sys.shutdownWrite(sender);
        try expectData(receiver, payload[0..sent]);
        try expectEof(receiver);
        sys.shutdownWrite(receiver);
        try expectEof(sender);
    }
}

test "forward 1 MiB payload byte for byte" {
    var worker = try Worker.init(testing.allocator, testing.io, 4);
    defer worker.deinit();
    try worker.start();
    const peers = try Peers.open(&worker, false);
    defer peers.close();

    const payload = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(payload);
    var prng = std.Random.DefaultPrng.init(1);
    prng.random().bytes(payload);

    const Sender = struct {
        fd: sys.Fd,
        data: []const u8,
        result: anyerror!void = undefined,

        fn run(self: *@This()) void {
            defer sys.shutdownWrite(self.fd);
            self.result = writeAll(self.fd, self.data);
        }
    };
    var sender: Sender = .{ .fd = peers.client, .data = payload };
    const thread = try std.Thread.spawn(.{}, Sender.run, .{&sender});
    const receive_result = expectData(peers.backend, payload);
    thread.join();
    try sender.result;
    try receive_result;
    try expectEof(peers.backend);
}

const Peers = struct {
    client: sys.Fd,
    backend: sys.Fd,

    fn open(worker: *Worker, limit_buffers: bool) !Peers {
        const loopback = try loopbackAddress(0);
        const frontend_listener = try sys.listen(loopback);
        defer sys.close(frontend_listener);
        const backend_listener = try sys.listen(loopback);
        defer sys.close(backend_listener);

        const client_addr = try loopbackAddress(try sys.boundPort(frontend_listener));
        const client_conn = try sys.connect(client_addr);
        errdefer sys.close(client_conn.fd);
        if (!client_conn.connected) {
            try waitReady(client_conn.fd, posix.POLL.OUT, deadlineAfter(timeout_ms));
            try sys.finishConnect(client_conn.fd);
        }
        const accepted_client = try accept(frontend_listener);
        var submitted = false;
        errdefer if (!submitted) sys.close(accepted_client);

        if (limit_buffers) {
            try setBufferSize(client_conn.fd, posix.SO.RCVBUF, restricted_buffer);
            try setBufferSize(client_conn.fd, posix.SO.SNDBUF, restricted_buffer);
            try setBufferSize(accepted_client, posix.SO.SNDBUF, restricted_buffer);
            try setBufferSize(accepted_client, posix.SO.RCVBUF, restricted_buffer);
        }
        const backend_addr = try loopbackAddress(try sys.boundPort(backend_listener));
        if (!worker.submit(.{ .client = accepted_client, .address = backend_addr })) {
            return error.WorkerRejectedClient;
        }
        submitted = true;

        const backend = try accept(backend_listener);
        errdefer sys.close(backend);
        if (limit_buffers) {
            try setBufferSize(backend, posix.SO.SNDBUF, restricted_buffer);
            try setBufferSize(backend, posix.SO.RCVBUF, restricted_buffer);
        }
        return .{ .client = client_conn.fd, .backend = backend };
    }

    fn close(peers: Peers) void {
        sys.close(peers.client);
        sys.close(peers.backend);
    }
};

fn loopbackAddress(port: u16) !sys.Address {
    var text: [32]u8 = undefined;
    const address = try std.fmt.bufPrint(&text, "127.0.0.1:{d}", .{port});
    const resolved = try sys.resolve(testing.allocator, address, port == 0);
    defer testing.allocator.free(resolved);
    return resolved[0];
}

fn setBufferSize(fd: sys.Fd, option: u32, size: c_int) !void {
    try posix.setsockopt(fd, posix.SOL.SOCKET, option, std.mem.asBytes(&size));
}

fn accept(listener: sys.Fd) !sys.Fd {
    const deadline = deadlineAfter(timeout_ms);
    while (true) {
        if (try sys.accept(listener)) |fd| return fd;
        try waitReady(listener, posix.POLL.IN, deadline);
    }
}

fn writeAll(fd: sys.Fd, data: []const u8) !void {
    const deadline = deadlineAfter(timeout_ms);
    var offset: usize = 0;
    while (offset < data.len) {
        if (try sys.write(fd, data[offset..])) |n| {
            if (n == 0) return error.WriteZero;
            offset += n;
        } else {
            try waitReady(fd, posix.POLL.OUT, deadline);
        }
    }
}

fn fillUntilBackpressured(fd: sys.Fd, data: []const u8) !usize {
    const deadline = deadlineAfter(timeout_ms);
    var offset: usize = 0;
    while (offset < data.len) {
        if (try sys.write(fd, data[offset..])) |n| {
            if (n == 0) return error.WriteZero;
            offset += n;
        } else if (try readyBy(fd, posix.POLL.OUT, @min(deadline, deadlineAfter(250)))) {
            continue;
        } else {
            if (monotonicNow() >= deadline) return error.Timeout;
            return offset;
        }
    }
    return error.ExpectedBackpressure;
}

fn expectData(fd: sys.Fd, expected: []const u8) !void {
    const deadline = deadlineAfter(timeout_ms);
    var remaining = expected;
    var buffer: [8192]u8 = undefined;
    while (remaining.len > 0) {
        const n = try readWhenReady(fd, buffer[0..@min(remaining.len, buffer.len)], deadline);
        if (n == 0) return error.UnexpectedEof;
        try testing.expectEqualSlices(u8, remaining[0..n], buffer[0..n]);
        remaining = remaining[n..];
    }
}

fn expectEof(fd: sys.Fd) !void {
    var extra: [1]u8 = undefined;
    const n = try readWhenReady(fd, &extra, deadlineAfter(timeout_ms));
    try testing.expectEqual(@as(usize, 0), n);
}

fn readWhenReady(fd: sys.Fd, buffer: []u8, deadline: i96) !usize {
    while (true) {
        if (try sys.read(fd, buffer)) |n| return n;
        try waitReady(fd, posix.POLL.IN, deadline);
    }
}

fn monotonicNow() i96 {
    return std.Io.Clock.awake.now(testing.io).nanoseconds;
}

fn deadlineAfter(ms: i96) i96 {
    return monotonicNow() + ms * std.time.ns_per_ms;
}

fn waitReady(fd: sys.Fd, events: i16, deadline: i96) !void {
    if (!try readyBy(fd, events, deadline)) return error.Timeout;
}

fn readyBy(fd: sys.Fd, events: i16, deadline: i96) !bool {
    const left_ns = deadline - monotonicNow();
    if (left_ns <= 0) return false;
    const left_ms = @divTrunc(left_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    return try posix.poll(&fds, @intCast(left_ms)) != 0;
}
