//! Connection handling: backend selection, dial-with-timeout, keepalive,
//! and a full-duplex copy loop with TCP half-close semantics.
//!
//! Threading model: one OS thread per accepted connection (like Go's
//! goroutine-per-conn, but cheaper here because a single thread pumps both
//! directions with poll(2) instead of two goroutines + channels).

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");
const config = @import("config.zig");
const log = @import("log.zig");

pub const Stats = struct {
    active: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    total: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
};

pub const dial_timeout_ms: i32 = 5000;
pub const keepalive_period_secs: c_int = 60;
const copy_buf_size = 32 * 1024; // same order as Go's io.Copy 32 KiB buffer

pub const Proxy = struct {
    store: *config.Store,
    stats: *Stats,
    rng_mutex: sys.Mutex = .{},
    prng: std.Random.DefaultPrng,

    pub fn init(store: *config.Store, stats: *Stats, seed: u64) Proxy {
        return .{ .store = store, .stats = stats, .prng = std.Random.DefaultPrng.init(seed) };
    }

    fn chooseAddr(self: *Proxy, buf: []u8) ?[]const u8 {
        self.rng_mutex.lock();
        defer self.rng_mutex.unlock();
        return self.store.chooseCopy(self.prng.random(), buf);
    }

    /// Full lifecycle of one client connection. Runs on its own thread.
    pub fn handleConn(self: *Proxy, client: sys.fd_t) void {
        defer sys.close(client);
        _ = self.stats.active.fetchAdd(1, .monotonic);
        defer _ = self.stats.active.fetchSub(1, .monotonic);
        _ = self.stats.total.fetchAdd(1, .monotonic);

        var addrbuf: [300]u8 = undefined;
        const addr = self.chooseAddr(&addrbuf) orelse {
            log.print("No available backend hosts to forward connection.", .{});
            return;
        };

        const backend = sys.dial(addr, dial_timeout_ms) catch |err| {
            log.print("Failed to connect to backend '{s}': {s}", .{ addr, @errorName(err) });
            return;
        };
        defer sys.close(backend);

        sys.enableKeepalive(client, keepalive_period_secs) catch {};
        sys.enableKeepalive(backend, keepalive_period_secs) catch {};
        sys.setNodelay(client) catch {};
        sys.setNodelay(backend) catch {};

        pump(client, backend);
    }
};

/// Bidirectional copy. When one side reaches EOF (or a read error), the
/// write half of the *other* side is shut down so in-flight data can still
/// drain; the connection is fully closed only when both directions end.
fn pump(a: sys.fd_t, b: sys.fd_t) void {
    var buf_ab: [copy_buf_size]u8 = undefined;
    var buf_ba: [copy_buf_size]u8 = undefined;
    var open_ab = true; // a -> b direction still reading from a
    var open_ba = true; // b -> a direction still reading from b
    var fds: [2]posix.pollfd = undefined;

    while (open_ab or open_ba) {
        var n: usize = 0;
        if (open_ab) {
            fds[n] = .{ .fd = a, .events = posix.POLL.IN, .revents = 0 };
            n += 1;
        }
        if (open_ba) {
            fds[n] = .{ .fd = b, .events = posix.POLL.IN, .revents = 0 };
            n += 1;
        }
        _ = posix.poll(fds[0..n], -1) catch break;

        for (fds[0..n]) |*p| {
            if (p.revents == 0) continue;
            if (p.revents & posix.POLL.NVAL != 0) return;
            if (p.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) == 0) continue;

            const is_a = p.fd == a;
            const dst = if (is_a) b else a;
            const buf: []u8 = if (is_a) &buf_ab else &buf_ba;

            const nr = posix.read(p.fd, buf) catch |err| {
                if (err != error.EndOfStream) {
                    log.print("Forwarding error ({s}): {s}", .{ if (is_a) "conn1->conn2" else "conn2->conn1", @errorName(err) });
                }
                sys.shutdownWrite(dst);
                if (is_a) open_ab = false else open_ba = false;
                continue;
            };
            if (nr == 0) {
                // EOF: half-close the peer, keep the other direction alive.
                sys.shutdownWrite(dst);
                if (is_a) open_ab = false else open_ba = false;
                continue;
            }
            sys.writeAll(dst, buf[0..nr]) catch |err| {
                log.print("Forwarding write error ({s}): {s}", .{ if (is_a) "conn1->conn2" else "conn2->conn1", @errorName(err) });
                return; // fatal: both fds closed by caller's defers
            };
        }
    }
}
