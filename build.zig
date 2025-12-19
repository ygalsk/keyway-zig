const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "keystone",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add dependencies
    const libxev_dep = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("xev", libxev_dep.module("xev"));

    const luajit_dep = b.dependency("luajit", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("luajit", luajit_dep.module("luajit"));

    // Add picohttpparser (vendored C library)
    exe.addCSourceFile(.{
        .file = b.path("vendor/picohttpparser.c"),
        .flags = &.{"-std=c99"},
    });
    exe.addIncludePath(b.path("vendor"));
    exe.linkLibC();

    // Export all symbols so LuaRocks C modules can find Lua API functions
    // This is required for dynamically loaded .so modules to resolve symbols like lua_getmetatable
    exe.rdynamic = true;

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
