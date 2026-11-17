const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zio_dep = b.dependency("zio", .{ .target = target, .optimize = optimize });
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zio", .module = zio_dep.module("zio") },
        },
    });
    const exe = b.addExecutable(.{ .name = "gopf", .root_module = root });
    b.installArtifact(exe);
}
