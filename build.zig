const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "6502-jit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    const run_step = b.step("run", "");
    const run = b.addRunArtifact(exe);
    run.step.dependOn(&exe.step);
    run_step.dependOn(&run.step);
}
