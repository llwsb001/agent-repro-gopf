//! Backend configuration: JSON parsing, validation, and a thread-safe store
//! that supports hot reload (SIGHUP swaps the active Config).

const std = @import("std");
const Allocator = std.mem.Allocator;
const dial = @import("dial.zig");

pub const Host = struct {
    addr: []const u8,
    weight: i64,
};

pub const Config = struct {
    hosts: []Host,
    weight_sum: i64,

    pub fn deinit(self: *Config, gpa: Allocator) void {
        for (self.hosts) |h| gpa.free(h.addr);
        gpa.free(self.hosts);
        self.* = undefined;
    }
};

pub const ParseError = error{
    InvalidJson,
    InvalidConfig,
    InvalidAddress,
    NegativeWeight,
    OutOfMemory,
};

/// Parse and validate JSON. Any invalid host aborts the whole load.
/// The `hosts` key may be absent; that is treated as an empty backend set.
/// Matching of keys is case-insensitive, like Go's encoding/json.
pub fn parse(gpa: Allocator, text: []const u8) ParseError!Config {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidJson,
    };

    var hosts_value: ?std.json.Value = null;
    var it = root.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "hosts")) {
            hosts_value = entry.value_ptr.*;
            break;
        }
    }
    if (hosts_value == null) return .{ .hosts = &.{}, .weight_sum = 0 };

    const arr = switch (hosts_value.?) {
        .array => |a| a,
        else => return error.InvalidConfig,
    };
    const list = try gpa.alloc(Host, arr.items.len);
    errdefer gpa.free(list);
    var owned: usize = 0;
    errdefer for (list[0..owned]) |h| gpa.free(h.addr);

    var weight_sum: i64 = 0;
    for (arr.items, 0..) |item, i| {
        const obj = switch (item) {
            .object => |o| o,
            else => return error.InvalidConfig,
        };
        var addr: ?[]const u8 = null;
        var weight: i64 = 0;
        var oit = obj.iterator();
        while (oit.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "addr")) {
                addr = switch (entry.value_ptr.*) {
                    .string => |s| s,
                    else => return error.InvalidConfig,
                };
            } else if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "weight")) {
                weight = switch (entry.value_ptr.*) {
                    .integer => |w| w,
                    .number_string => |s| std.fmt.parseInt(i64, s, 10) catch
                        return error.InvalidConfig,
                    else => return error.InvalidConfig,
                };
            }
        }
        const a = addr orelse return error.InvalidAddress;
        _ = dial.splitHostPort(a) catch return error.InvalidAddress;
        if (weight < 0) return error.NegativeWeight;
        weight_sum += weight;
        list[i] = .{ .addr = try gpa.dupe(u8, a), .weight = weight };
        owned += 1;
    }
    return .{ .hosts = list, .weight_sum = weight_sum };
}

pub fn loadFromFile(gpa: Allocator, io: std.Io, path: []const u8) !Config {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited64(16 * 1024 * 1024));
    defer gpa.free(text);
    return parse(gpa, text);
}

/// Thread-safe holder for the active config. The lock only protects the
/// pointer swap; per-connection selection copies the chosen address while
/// holding the lock, so an old config can be freed immediately after swap.
pub const Store = struct {
    lock: std.Io.Mutex = .init,
    current: ?*Config = null,

    pub fn init() Store {
        return .{};
    }

    pub fn swap(self: *Store, gpa: Allocator, io: std.Io, new_cfg: *Config) void {
        self.lock.lockUncancelable(io);
        const old = self.current;
        self.current = new_cfg;
        self.lock.unlock(io);
        if (old) |o| {
            o.deinit(gpa);
            gpa.destroy(o);
        }
    }

    pub fn clear(self: *Store, gpa: Allocator, io: std.Io) void {
        self.lock.lockUncancelable(io);
        const old = self.current;
        self.current = null;
        self.lock.unlock(io);
        if (old) |o| {
            o.deinit(gpa);
            gpa.destroy(o);
        }
    }

    pub const Snapshot = struct {
        hosts: []Host,
        buf: []u8,
        weight_sum: i64,

        pub fn deinit(self: *Snapshot, gpa: Allocator) void {
            gpa.free(self.hosts);
            gpa.free(self.buf);
        }
    };

    pub fn snapshot(self: *Store, gpa: Allocator, io: std.Io) !?Snapshot {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        const cfg = self.current orelse return null;
        const hosts = try gpa.alloc(Host, cfg.hosts.len);
        errdefer gpa.free(hosts);
        var total: usize = 0;
        for (cfg.hosts) |h| total += h.addr.len;
        const buf = try gpa.alloc(u8, total);
        var off: usize = 0;
        for (cfg.hosts, 0..) |h, i| {
            @memcpy(buf[off..][0..h.addr.len], h.addr);
            hosts[i] = .{ .addr = buf[off..][0..h.addr.len], .weight = h.weight };
            off += h.addr.len;
        }
        return .{ .hosts = hosts, .buf = buf, .weight_sum = cfg.weight_sum };
    }
};