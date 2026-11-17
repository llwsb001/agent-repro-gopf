const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xev_dep = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "xev", .module = xev_dep.module("xev") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "gopf",
        .root_module = root,
    });
    b.installArtifact(exe);
}
