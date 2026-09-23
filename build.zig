const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const assemble = b.addSystemCommand(&.{
        "64tass",
        "--nostart",
        "-o",
    });
    const prog = assemble.addOutputFileArg("prog.bin");
    assemble.addFileArg(b.path("src/test.asm"));
    assemble.addFileInput(b.path("src/test.asm"));

    const prog_install = b.addInstallFile(prog, "prog.bin");
    b.getInstallStep().dependOn(&prog_install.step);

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
    run.setCwd(.{ .cwd_relative = b.install_prefix });
    run.step.dependOn(&install.step);
    run.step.dependOn(&prog_install.step);
    run_step.dependOn(&run.step);
}
