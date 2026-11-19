const std = @import("std");
const config = @import("config.zig");
const proxy = @import("proxy.zig");

const usage =
    \\Usage: gopf [options] config_file
    \\
    \\Options:
    \\  -listen <addr>   listen address (default: :1248)
    \\  -h, --help       show this help
    \\
    \\Config file format:
    \\  {"hosts":[{"addr":"127.0.0.1:8080","weight":100}]}
    \\
;

const log = std.log.scoped(.gopf);

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args = std.process.Args.Iterator.init(init.minimal.args);

    var listen_addr: []const u8 = ":1248";
    var config_path: ?[]const u8 = null;

    _ = args.next(); // argv[0]
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try std.Io.File.stderr().writeStreamingAll(init.io, usage);
            return;
        } else if (std.mem.eql(u8, arg, "-listen")) {
            listen_addr = args.next() orelse {
                try std.Io.File.stderr().writeStreamingAll(init.io, "error: -listen requires a value\n");
                return error.InvalidArguments;
            };
        } else if (std.mem.startsWith(u8, arg, "-listen=")) {
            listen_addr = arg["-listen=".len..];
        } else if (arg.len > 0 and arg[0] == '-') {
            try std.Io.File.stderr().writeStreamingAll(init.io, "error: unknown option\n");
            try std.Io.File.stderr().writeStreamingAll(init.io, usage);
            return error.InvalidArguments;
        } else if (config_path == null) {
            config_path = arg;
        } else {
            try std.Io.File.stderr().writeStreamingAll(init.io, "error: unexpected extra argument\n");
            return error.InvalidArguments;
        }
    }

    const path = config_path orelse {
        try std.Io.File.stderr().writeStreamingAll(init.io, "error: configuration file is required\n");
        try std.Io.File.stderr().writeStreamingAll(init.io, usage);
        return error.InvalidArguments;
    };

    proxy.installSignalHandlers();

    var server = proxy.Proxy.initFromPath(allocator, listen_addr, path) catch |err| {
        log.err("failed to start on '{s}' with config '{s}': {s}", .{ listen_addr, path, @errorName(err) });
        return err;
    };
    defer server.deinit();

    log.info("gopf (Zig) starting; config={s} listen={s}", .{ path, listen_addr });
    try server.start();
    server.wait();
    log.info("shutdown complete", .{});
}
