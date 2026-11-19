const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gopf = b.addModule("gopf", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "gopf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gopf", .module = gopf },
            },
        }),
    });
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .filters = if (b.option([]const u8, "test-filter", "Run only tests matching this filter")) |filter|
            &.{filter}
        else
            &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gopf", .module = gopf },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const unit_tests = b.addTest(.{
        .root_module = gopf,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_unit_tests.step);

    const run_step = b.step("run", "Run the load balancer");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);
}
