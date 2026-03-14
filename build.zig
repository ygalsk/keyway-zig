const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Fetch dependencies once, share across targets
    const libxev_dep = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });
    const luajit_dep = b.dependency("luajit", .{
        .target = target,
        .optimize = optimize,
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "keyway",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addSharedDeps(b, exe, libxev_dep, luajit_dep);

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
    addSharedDeps(b, exe_unit_tests, libxev_dep, luajit_dep);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

/// Configure dependencies shared by both the main executable and test targets:
/// libxev, luajit, picohttpparser (vendored C), libc, and linker workarounds.
fn addSharedDeps(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    libxev_dep: *std.Build.Dependency,
    luajit_dep: *std.Build.Dependency,
) void {
    compile.root_module.addImport("xev", libxev_dep.module("xev"));
    compile.root_module.addImport("luajit", luajit_dep.module("luajit"));
    // Lua stdlib: scripts/keyway/stdlib.zig uses @embedFile for sibling .lua files
    compile.root_module.addImport("stdlib", b.createModule(.{
        .root_source_file = b.path("scripts/keyway/stdlib.zig"),
    }));
    compile.addCSourceFile(.{
        .file = b.path("vendor/picohttpparser.c"),
        .flags = &.{"-std=c99"},
    });
    compile.addIncludePath(b.path("vendor"));
    compile.linkLibC();
    compile.linkSystemLibrary("ssl");
    compile.linkSystemLibrary("crypto");

    // GCC 15's crt1.o has .sframe sections with R_X86_64_PC64 relocations that
    // Zig's bundled lld can't handle. --gc-sections discards unreferenced .sframe.
    compile.link_gc_sections = true;
}
