const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add module for zig dependencies
    _ = b.addModule("anyline", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create C library + header files
    const anyline_c_mod = b.createModule(.{
        .root_source_file = b.path("src/c_bindings.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const anyline_c_lib = b.addLibrary(.{
        .name = "anyline",
        .root_module = anyline_c_mod,
    });
    anyline_c_lib.bundle_compiler_rt = switch (optimize) {
        .ReleaseFast, .ReleaseSmall => false,
        .Debug => target.result.os.tag == .freebsd,
        .ReleaseSafe => target.result.os.tag == .linux or target.result.os.tag == .freebsd,
    };
    b.installArtifact(anyline_c_lib);
    const header_install_step = b.addInstallFile(b.path("include/anyline.h"), "include/anyline.h");
    b.getInstallStep().dependOn(&header_install_step.step);

    // Build-On-Save
    const exe = b.addExecutable(.{
        .name = "anyline-exe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const tests = b.addTest(.{
        .name = "anyline-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const check = b.step("check", "Check if anyline compiles");
    check.dependOn(&exe.step);
    if (target.result.os.tag != .windows) {
        check.dependOn(&tests.step);
    }
}
