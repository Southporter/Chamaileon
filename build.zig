const std = @import("std");
const dvui = @import("dvui");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const known_folders = b.dependency("known_folders", .{}).module("known-folders");
    lib_mod.addImport("known-folders", known_folders);
    const zeit = b.dependency("zeit", .{
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("zeit", zeit.module("zeit"));

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("mailbox", lib_mod);

    const exe = b.addExecutable(.{
        .name = "mailbox",
        .root_module = exe_mod,
    });

    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    });
    exe_mod.addImport("dvui", dvui_dep.module("dvui_sdl3"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const check_exe = b.addExecutable(.{
        .name = "mailbox",
        .root_module = exe_mod,
    });

    const check_step = b.step("check", "Run the compiler's code checks");
    check_step.dependOn(&check_exe.step);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
