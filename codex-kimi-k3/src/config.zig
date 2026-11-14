const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Host = struct {
    /// Address of the backend server (e.g., "127.0.0.1:8080"). Owned by the
    /// enclosing Backend (arena allocated).
    addr: []const u8,
    /// Weight for load balancing (higher weight means more traffic).
    weight: i64,
};

pub const Backend = struct {
    /// Not used by the proxy, kept for config file compatibility.
    traffic_url: []const u8 = "",
    hosts: []Host = &.{},
    /// Pre-calculated sum of all host weights for efficient selection.
    weight_sum: i64 = 0,
};

pub const LoadError = error{
    InvalidAddress,
    NegativeWeight,
    WeightOverflow,
    OpenFailed,
    ReadFailed,
    ParseFailed,
    StreamTooLong,
    OutOfMemory,
};

pub const empty_backend: Backend = .{};

/// Maximum config file size accepted (1 MiB), mirrors what a sane
/// settings.conf would ever need.
const max_config_bytes = 1 << 20;

/// Reads, parses and validates the JSON config file at `path`.
///
/// All memory backing the returned Backend is allocated from `arena`; callers
/// typically hand it a per-config `std.heap.ArenaAllocator` that is freed when
/// the config is swapped out.
pub fn load(io: std.Io, gpa: Allocator, arena: Allocator, path: []const u8) LoadError!Backend {
    const raw = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        gpa,
        .limited(max_config_bytes),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.StreamTooLong,
        else => return error.OpenFailed,
    };
    defer gpa.free(raw);

    var backend = parse(arena, raw) catch |err| return err;
    backend.weight_sum = validateAndSumWeights(backend.hosts) catch |err| return err;
    return backend;
}

/// Parses JSON config text with Go encoding/json semantics: object keys match
/// struct fields case-insensitively, unknown keys are ignored, missing fields
/// take zero values.
pub fn parse(arena: Allocator, raw: []const u8) LoadError!Backend {
    const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{
        .ignore_unknown_fields = true,
    }) catch return error.ParseFailed;
    if (doc != .object) return error.ParseFailed;

    var backend: Backend = .{};

    if (findCaseInsensitive(&doc.object, "traffic_url")) |value| {
        switch (value) {
            .string => |s| backend.traffic_url = s,
            // Go's encoding/json unmarshals null into any field as a no-op.
            .null => {},
            // Numbers/bools/objects/arrays for a string field are errors.
            else => return error.ParseFailed,
        }
    }

    if (findCaseInsensitive(&doc.object, "hosts")) |value| {
        switch (value) {
            // "hosts": null unmarshals as a nil slice in Go.
            .null => {},
            .array => {
                const items = value.array.items;
                const hosts = arena.alloc(Host, items.len) catch return error.OutOfMemory;
                for (items, 0..) |item, i| {
                    if (item != .object) return error.ParseFailed;
                    hosts[i] = try parseHost(&item.object);
                }
                backend.hosts = hosts;
            },
            else => return error.ParseFailed,
        }
    }

    return backend;
}

fn parseHost(obj: *const std.json.ObjectMap) LoadError!Host {
    var host: Host = .{ .addr = "", .weight = 0 };
    if (findCaseInsensitive(obj, "addr")) |value| {
        switch (value) {
            .string => |s| host.addr = s,
            // Go: unmarshaling null into a string field is a no-op.
            .null => {},
            else => return error.ParseFailed,
        }
    }
    if (findCaseInsensitive(obj, "weight")) |value| {
        host.weight = try parseInteger(value);
    }
    return host;
}

fn parseInteger(value: std.json.Value) LoadError!i64 {
    return switch (value) {
        .integer => |i| i,
        // Go: unmarshaling null into an int field is a no-op (stays 0).
        .null => 0,
        // Go's encoding/json rejects non-integer JSON numbers for int fields,
        // and std.json's default parse_numbers mode already maps fractional
        // values to .float, so anything but .integer is a type error.
        else => error.ParseFailed,
    };
}

fn findCaseInsensitive(obj: *const std.json.ObjectMap, key: []const u8) ?std.json.Value {
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, key)) return entry.value_ptr.*;
    }
    return null;
}

/// Validates every host and returns the total weight.
pub fn validateAndSumWeights(hosts: []const Host) LoadError!i64 {
    var sum: i64 = 0;
    for (hosts) |host| {
        _ = try splitHostPort(host.addr);
        if (host.weight < 0) return error.NegativeWeight;
        // Checked: a hostile config with huge weights must be rejected, not
        // wrap (UB in ReleaseFast) or panic (Debug).
        sum = std.math.add(i64, sum, host.weight) catch return error.WeightOverflow;
    }
    return sum;
}

pub const HostPort = struct {
    host: []const u8,
    port: u16,
};

/// Splits "host:port" / "[v6]:port" like Go's net.SplitHostPort, requiring a
/// numeric port in range 0..65535. Empty host is allowed.
pub fn splitHostPort(addr: []const u8) LoadError!HostPort {
    if (addr.len == 0) return error.InvalidAddress;

    var host: []const u8 = undefined;
    var port_text: []const u8 = undefined;

    if (addr[0] == '[') {
        // Bracketed IPv6 literal: "[::1]:8080" or "[::1]".
        const close = std.mem.indexOfScalar(u8, addr, ']') orelse return error.InvalidAddress;
        host = addr[1..close];
        if (close + 1 == addr.len) {
            // Go's SplitHostPort accepts "[::1]" (missing port) as an error
            // for our purposes; require a port.
            return error.InvalidAddress;
        }
        if (addr[close + 1] != ':') return error.InvalidAddress;
        port_text = addr[close + 2 ..];
    } else {
        const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse return error.InvalidAddress;
        host = addr[0..colon];
        port_text = addr[colon + 1 ..];
        // "a:b:c" is IPv6 without brackets; SplitHostPort rejects it.
        if (std.mem.indexOfScalar(u8, host, ':') != null) return error.InvalidAddress;
    }

    const port = parsePort(port_text) orelse return error.InvalidAddress;
    return .{ .host = host, .port = port };
}

/// Go accepts decimal ports with no sign, digits only, range 0..65535.
fn parsePort(text: []const u8) ?u16 {
    if (text.len == 0) return null;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return std.fmt.parseInt(u16, text, 10) catch null;
}

/// Selects a backend host with probability proportional to its weight.
/// `random_value` must be uniform in `[0, backend.weight_sum)`.
pub fn chooseHost(backend: *const Backend, random_value: i64) ?Host {
    if (backend.weight_sum <= 0) return null;
    var cumulative: i64 = 0;
    for (backend.hosts) |host| {
        cumulative += host.weight;
        if (random_value < cumulative) return host;
    }
    if (backend.hosts.len > 0) return backend.hosts[backend.hosts.len - 1];
    return null;
}

test "parse accepts capitalized and lowercase keys" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const upper = try parse(arena,
        \\{"Hosts":[{"Addr":"127.0.0.1:8080","Weight":100}],"Traffic_Url":"x"}
    );
    try std.testing.expectEqual(@as(usize, 1), upper.hosts.len);
    try std.testing.expectEqualStrings("127.0.0.1:8080", upper.hosts[0].addr);
    try std.testing.expectEqual(@as(i64, 100), upper.hosts[0].weight);
    try std.testing.expectEqualStrings("x", upper.traffic_url);

    const lower = try parse(arena,
        \\{"hosts":[{"addr":"10.0.0.1:80","weight":0}],"traffic_url":"y"}
    );
    try std.testing.expectEqual(@as(usize, 1), lower.hosts.len);
    try std.testing.expectEqual(@as(i64, 0), lower.hosts[0].weight);
    try std.testing.expectEqualStrings("y", lower.traffic_url);

    // Unknown keys ignored; missing keys take defaults.
    const sparse = try parse(arena, "{\"HOSTS\":[{\"ADDR\":\":9999\"}], \"other\": 42}");
    try std.testing.expectEqual(@as(usize, 1), sparse.hosts.len);
    try std.testing.expectEqualStrings(":9999", sparse.hosts[0].addr);
    try std.testing.expectEqual(@as(i64, 0), sparse.hosts[0].weight);
}

test "parse rejects malformed documents" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.ParseFailed, parse(arena, "{"));
    try std.testing.expectError(error.ParseFailed, parse(arena, "[]"));
    try std.testing.expectError(error.ParseFailed, parse(arena,
        \\{"hosts":[{"addr":123}]}
    ));
}

test "parse treats JSON null as field-absent (Go compatibility)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // "Hosts": null -> nil slice in Go.
    const null_hosts = try parse(arena, "{\"Hosts\":null}");
    try std.testing.expectEqual(@as(usize, 0), null_hosts.hosts.len);

    // null addr/weight -> zero values.
    const null_fields = try parse(arena, "{\"hosts\":[{\"addr\":null,\"weight\":null}]}");
    try std.testing.expectEqual(@as(usize, 1), null_fields.hosts.len);
    try std.testing.expectEqualStrings("", null_fields.hosts[0].addr);
    try std.testing.expectEqual(@as(i64, 0), null_fields.hosts[0].weight);

    // null traffic_url -> empty string.
    const null_url = try parse(arena, "{\"traffic_url\":null,\"hosts\":[]}");
    try std.testing.expectEqualStrings("", null_url.traffic_url);

    // Wrong types are still errors.
    try std.testing.expectError(error.ParseFailed, parse(arena, "{\"hosts\":[{\"addr\":123}]}"));
    try std.testing.expectError(error.ParseFailed, parse(arena, "{\"hosts\":[{\"weight\":\"x\"}]}"));
    try std.testing.expectError(error.ParseFailed, parse(arena, "{\"hosts\":123}"));
    try std.testing.expectError(error.ParseFailed, parse(arena, "{\"traffic_url\":false}"));
}

test "validateAndSumWeights rejects weight overflow" {
    const max = std.math.maxInt(i64);
    try std.testing.expectError(error.WeightOverflow, validateAndSumWeights(&.{
        .{ .addr = "127.0.0.1:80", .weight = max },
        .{ .addr = "127.0.0.1:81", .weight = max },
    }));
    try std.testing.expectError(error.WeightOverflow, validateAndSumWeights(&.{
        .{ .addr = "127.0.0.1:80", .weight = max },
        .{ .addr = "127.0.0.1:81", .weight = 1 },
    }));
    // Largest legal sum still works.
    const sum = try validateAndSumWeights(&.{
        .{ .addr = "127.0.0.1:80", .weight = max },
        .{ .addr = "127.0.0.1:81", .weight = 0 },
    });
    try std.testing.expectEqual(max, sum);
}

test "splitHostPort matches net.SplitHostPort essentials" {
    const hp = try splitHostPort("127.0.0.1:8080");
    try std.testing.expectEqualStrings("127.0.0.1", hp.host);
    try std.testing.expectEqual(@as(u16, 8080), hp.port);

    const empty_host = try splitHostPort(":1248");
    try std.testing.expectEqualStrings("", empty_host.host);
    try std.testing.expectEqual(@as(u16, 1248), empty_host.port);

    const v6 = try splitHostPort("[::1]:9090");
    try std.testing.expectEqualStrings("::1", v6.host);
    try std.testing.expectEqual(@as(u16, 9090), v6.port);

    try std.testing.expectError(error.InvalidAddress, splitHostPort("noport"));
    try std.testing.expectError(error.InvalidAddress, splitHostPort("host:"));
    try std.testing.expectError(error.InvalidAddress, splitHostPort("host:abc"));
    try std.testing.expectError(error.InvalidAddress, splitHostPort("host:65536"));
    try std.testing.expectError(error.InvalidAddress, splitHostPort("host:-1"));
    try std.testing.expectError(error.InvalidAddress, splitHostPort("a:b:c"));
    try std.testing.expectError(error.InvalidAddress, splitHostPort("[::1]9090"));
    try std.testing.expectError(error.InvalidAddress, splitHostPort(""));
    // Port 0 is valid per Go (LookupPort accepts 0).
    const zero = try splitHostPort("host:0");
    try std.testing.expectEqual(@as(u16, 0), zero.port);
}

test "validateAndSumWeights rejects bad configs" {
    try std.testing.expectError(error.NegativeWeight, validateAndSumWeights(&.{
        .{ .addr = "127.0.0.1:80", .weight = -5 },
    }));
    try std.testing.expectError(error.InvalidAddress, validateAndSumWeights(&.{
        .{ .addr = "not-an-address", .weight = 1 },
    }));
    const sum = try validateAndSumWeights(&.{
        .{ .addr = "127.0.0.1:80", .weight = 30 },
        .{ .addr = ":81", .weight = 20 },
    });
    try std.testing.expectEqual(@as(i64, 50), sum);
}

test "chooseHost honors weights" {
    const backend: Backend = .{
        .hosts = @constCast(&[_]Host{
            .{ .addr = "a:1", .weight = 100 },
            .{ .addr = "b:2", .weight = 0 },
            .{ .addr = "c:3", .weight = 100 },
        }),
        .weight_sum = 200,
    };
    try std.testing.expectEqualStrings("a:1", chooseHost(&backend, 0).?.addr);
    try std.testing.expectEqualStrings("a:1", chooseHost(&backend, 99).?.addr);
    try std.testing.expectEqualStrings("c:3", chooseHost(&backend, 100).?.addr);
    try std.testing.expectEqualStrings("c:3", chooseHost(&backend, 199).?.addr);

    const zero: Backend = .{ .hosts = &.{}, .weight_sum = 0 };
    try std.testing.expect(chooseHost(&zero, 0) == null);

    // All weights zero => weight_sum 0 => no host.
    const all_zero: Backend = .{
        .hosts = @constCast(&[_]Host{.{ .addr = "a:1", .weight = 0 }}),
        .weight_sum = 0,
    };
    try std.testing.expect(chooseHost(&all_zero, 0) == null);
}
