const std = @import("std");
const sys = @import("sys.zig");
const events = @import("poller.zig");
const Allocator = std.mem.Allocator;

const wake_token = 0;
const endpoint_token_bits = @bitSizeOf(u16);
const queue_size = 256;
const jobs_per_batch = 64;
const chunk_size = 16 * 1024;
const buffer_budget_per_slot = 8 * 1024;

pub const Job = struct {
    client: sys.Fd,
    address: sys.Address,
    // A nonempty slice is owned by the current holder of the job.
    fallbacks: []const sys.Address = &.{},
};

const Endpoint = struct {
    fd: sys.Fd,
    interest: events.Interest = .{},
};

const Direction = struct {
    pending: ?[]u8 = null,
    offset: usize = 0,
    eof: bool = false,

    fn canRead(self: Direction) bool {
        return !self.eof and self.pending == null;
    }
};

const Connection = struct {
    client: Endpoint,
    backend: ?Endpoint = null,
    connecting: bool = true,
    fallbacks: []const sys.Address,
    tried_fallbacks: usize = 0,
    to_backend: Direction = .{},
    to_client: Direction = .{},

    fn backendToken(self: *const Connection, id: u48) u64 {
        // A retry can close and reopen the same fd within a batch of events.
        return clientToken(id) + 1 + self.tried_fallbacks;
    }
};

fn clientToken(id: u48) u64 {
    return @as(u64, id) << endpoint_token_bits;
}

pub const Worker = struct {
    allocator: Allocator,
    io: std.Io,
    capacity: usize,
    poller: events.Poller,
    wake_pipe: sys.WakePipe,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    active: std.atomic.Value(usize) = .init(0),

    queue_lock: std.Io.Mutex = .init,
    jobs: [queue_size]Job = undefined,
    job_head: usize = 0,
    job_count: usize = 0,

    // The event loop owns the connections and their buffers.
    connections: std.AutoHashMap(u48, Connection),
    next_id: u48 = 1,
    pending_bytes: usize = 0,
    buffer_budget: usize,

    pub fn init(allocator: Allocator, io: std.Io, capacity: usize) !Worker {
        var poller = try events.Poller.init();
        errdefer poller.deinit();
        var wake_pipe = try sys.WakePipe.init();
        errdefer wake_pipe.deinit();
        try poller.update(wake_pipe.read_fd, wake_token, .{}, .{ .read = true });
        return .{
            .allocator = allocator,
            .io = io,
            .capacity = capacity,
            .poller = poller,
            .wake_pipe = wake_pipe,
            .connections = .init(allocator),
            .buffer_budget = @max(2 * chunk_size, capacity * buffer_budget_per_slot),
        };
    }

    pub fn start(self: *Worker) !void {
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *Worker) void {
        self.stopping.store(true, .release);
        self.wake_pipe.wake();
    }

    pub fn deinit(self: *Worker) void {
        self.stop();
        if (self.thread) |thread| thread.join();
        self.discardJobs();
        self.connections.deinit();
        self.wake_pipe.deinit();
        self.poller.deinit();
    }

    pub fn activeCount(self: *const Worker) usize {
        return self.active.load(.monotonic);
    }

    /// Transfers the client and fallback addresses only if queued.
    pub fn submit(self: *Worker, job: Job) bool {
        self.queue_lock.lockUncancelable(self.io);
        if (self.stopping.load(.acquire) or self.job_count == queue_size or
            self.activeCount() >= self.capacity)
        {
            self.queue_lock.unlock(self.io);
            return false;
        }
        const was_empty = self.job_count == 0;
        self.jobs[(self.job_head + self.job_count) % queue_size] = job;
        self.job_count += 1;
        _ = self.active.fetchAdd(1, .monotonic);
        self.queue_lock.unlock(self.io);
        if (was_empty) self.wake_pipe.wake();
        return true;
    }

    fn popJob(self: *Worker) ?Job {
        self.queue_lock.lockUncancelable(self.io);
        defer self.queue_lock.unlock(self.io);
        if (self.job_count == 0) return null;
        const job = self.jobs[self.job_head];
        self.job_head = (self.job_head + 1) % queue_size;
        self.job_count -= 1;
        return job;
    }

    fn discardJobs(self: *Worker) void {
        while (self.popJob()) |job| {
            sys.close(job.client);
            if (job.fallbacks.len != 0) self.allocator.free(job.fallbacks);
            _ = self.active.fetchSub(1, .monotonic);
        }
    }

    fn run(self: *Worker) void {
        defer {
            self.stopping.store(true, .release);
            var values = self.connections.valueIterator();
            while (values.next()) |conn| self.destroyConnection(conn);
            self.connections.clearRetainingCapacity();
            self.discardJobs();
        }

        var batch: [128]events.Event = undefined;
        var scratch: [chunk_size]u8 = undefined;
        while (!self.stopping.load(.acquire)) {
            const count = self.poller.wait(&batch) catch |err| {
                std.log.err("worker event wait failed: {s}", .{@errorName(err)});
                return;
            };
            for (batch[0..count]) |event| {
                if (self.stopping.load(.acquire)) return;
                if (event.token == wake_token) {
                    self.wake_pipe.drain();
                    self.processJobs();
                } else {
                    self.processEvent(event, &scratch);
                }
            }
        }
    }

    fn processJobs(self: *Worker) void {
        for (0..jobs_per_batch) |_| {
            if (self.stopping.load(.acquire)) return;
            self.addConnection(self.popJob() orelse return);
        }
        // Bound accept work per wake so active connections get time in this loop.
        self.wake_pipe.wake();
    }

    fn addConnection(self: *Worker, job: Job) void {
        const id = self.next_id;
        self.next_id += 1;
        var conn: Connection = .{
            .client = .{ .fd = job.client },
            .fallbacks = job.fallbacks,
        };
        self.openBackend(&conn, job.address) catch |err| {
            std.log.warn("backend dial failed: {s}", .{@errorName(err)});
            self.destroyConnection(&conn);
            return;
        };
        self.refreshInterests(id, &conn) catch |err| {
            std.log.err("registering connection events failed: {s}", .{@errorName(err)});
            self.destroyConnection(&conn);
            return;
        };
        self.connections.put(id, conn) catch {
            self.destroyConnection(&conn);
            std.log.err("allocating connection state failed", .{});
        };
    }

    fn openBackend(self: *Worker, conn: *Connection, first: sys.Address) !void {
        // TODO: apply a common 5-second deadline across all addresses of a dial.
        var address = first;
        while (true) {
            const result = sys.connect(address) catch |err| {
                address = nextAddress(conn) orelse return err;
                continue;
            };
            conn.backend = .{ .fd = result.fd };
            conn.connecting = !result.connected;
            if (result.connected) self.freeFallbacks(conn);
            return;
        }
    }

    fn nextAddress(conn: *Connection) ?sys.Address {
        if (conn.tried_fallbacks == conn.fallbacks.len or
            conn.tried_fallbacks == std.math.maxInt(u16) - 1) return null;
        const address = conn.fallbacks[conn.tried_fallbacks];
        conn.tried_fallbacks += 1;
        return address;
    }

    fn finishDial(self: *Worker, conn: *Connection) !void {
        sys.finishConnect(conn.backend.?.fd) catch |err| {
            sys.close(conn.backend.?.fd);
            conn.backend = null;
            const next = nextAddress(conn) orelse return err;
            return self.openBackend(conn, next);
        };
        conn.connecting = false;
        self.freeFallbacks(conn);
    }

    fn freeFallbacks(self: *Worker, conn: *Connection) void {
        if (conn.fallbacks.len != 0) {
            self.allocator.free(conn.fallbacks);
            conn.fallbacks = &.{};
        }
    }

    fn processEvent(self: *Worker, event: events.Event, scratch: []u8) void {
        const id: u48 = @intCast(event.token >> endpoint_token_bits);
        const conn = self.connections.getPtr(id) orelse return;
        const is_client = event.token == clientToken(id);
        if (!is_client and event.token != conn.backendToken(id)) return;

        if (conn.connecting) {
            std.debug.assert(!is_client);
            self.finishDial(conn) catch |err| {
                std.log.warn("backend dial failed: {s}", .{@errorName(err)});
                self.removeConnection(id, conn);
                return;
            };
        } else {
            self.forwardReady(conn, is_client, event, scratch) catch |err| {
                if (err == error.BufferBudgetExceeded) {
                    std.log.warn("worker buffer budget exhausted, closing connection", .{});
                } else {
                    std.log.debug("connection I/O ended: {s}", .{@errorName(err)});
                }
                self.removeConnection(id, conn);
                return;
            };
            if (conn.to_client.eof and conn.to_backend.eof) {
                self.removeConnection(id, conn);
                return;
            }
        }

        self.refreshInterests(id, conn) catch |err| {
            std.log.err("updating connection events failed: {s}", .{@errorName(err)});
            self.removeConnection(id, conn);
        };
    }

    fn forwardReady(self: *Worker, conn: *Connection, is_client: bool, event: events.Event, scratch: []u8) !void {
        const ready_fd = if (is_client) conn.client.fd else conn.backend.?.fd;
        const peer_fd = if (is_client) conn.backend.?.fd else conn.client.fd;
        const outgoing = if (is_client) &conn.to_backend else &conn.to_client;
        const incoming = if (is_client) &conn.to_client else &conn.to_backend;

        if (event.writable) {
            if (incoming.pending) |data| {
                incoming.offset += try writeSome(ready_fd, data[incoming.offset..]);
                if (incoming.offset == data.len) self.freePending(incoming);
            }
        }
        if (!event.readable or !outgoing.canRead()) return;
        const len = (try sys.read(ready_fd, scratch)) orelse return;
        if (len == 0) {
            // Reads pause while data is pending, so all preceding bytes are sent.
            outgoing.eof = true;
            sys.shutdownWrite(peer_fd);
            return;
        }
        const written = try writeSome(peer_fd, scratch[0..len]);
        if (written == len) return;
        const unsent = scratch[written..len];
        if (unsent.len > self.buffer_budget - self.pending_bytes)
            return error.BufferBudgetExceeded;
        outgoing.pending = try self.allocator.dupe(u8, unsent);
        self.pending_bytes += unsent.len;
    }

    fn writeSome(fd: sys.Fd, data: []const u8) !usize {
        const n = (try sys.write(fd, data)) orelse return 0;
        if (n == 0) return error.NoWriteProgress;
        return n;
    }

    fn refreshInterests(self: *Worker, id: u48, conn: *Connection) !void {
        if (conn.connecting) {
            try self.setInterest(&conn.backend.?, conn.backendToken(id), .{ .write = true });
            return;
        }
        try self.setInterest(&conn.client, clientToken(id), .{
            .read = conn.to_backend.canRead(),
            .write = conn.to_client.pending != null,
        });
        try self.setInterest(&conn.backend.?, conn.backendToken(id), .{
            .read = conn.to_client.canRead(),
            .write = conn.to_backend.pending != null,
        });
    }

    fn setInterest(self: *Worker, endpoint: *Endpoint, token: u64, interest: events.Interest) !void {
        try self.poller.update(endpoint.fd, token, endpoint.interest, interest);
        endpoint.interest = interest;
    }

    fn freePending(self: *Worker, direction: *Direction) void {
        if (direction.pending) |pending| {
            self.pending_bytes -= pending.len;
            self.allocator.free(pending);
            direction.pending = null;
            direction.offset = 0;
        }
    }

    fn destroyConnection(self: *Worker, conn: *Connection) void {
        sys.close(conn.client.fd);
        if (conn.backend) |backend| sys.close(backend.fd);
        self.freePending(&conn.to_backend);
        self.freePending(&conn.to_client);
        self.freeFallbacks(conn);
        _ = self.active.fetchSub(1, .monotonic);
    }

    fn removeConnection(self: *Worker, id: u48, conn: *Connection) void {
        self.destroyConnection(conn);
        _ = self.connections.remove(id);
    }
};
