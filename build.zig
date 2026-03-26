const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app_version = b.option([]const u8, "app_version", "Application version string") orelse "0.0.0-dev";
    const git_commit = detectGitCommit(b);

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", app_version);
    build_options.addOption([]const u8, "git_commit", git_commit);

    const gen_unicode_exe = b.addExecutable(.{
        .name = "gen-grapheme-tables",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_grapheme_tables.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const gen_unicode_run = b.addRunArtifact(gen_unicode_exe);
    const gen_unicode_step = b.step("gen-unicode", "Regenerate grapheme tables from upstream Unicode data");
    gen_unicode_step.dependOn(&gen_unicode_run.step);

    const gen_cacert_exe = b.addExecutable(.{
        .name = "gen-cacert",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_cacert.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const gen_cacert_run = b.addRunArtifact(gen_cacert_exe);
    const gen_cacert_step = b.step("gen-cacert", "Download Mozilla CA certificates from curl.se and generate embedded bundle");
    gen_cacert_step.dependOn(&gen_cacert_run.step);

    const mod = b.addModule("neoclaw", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });

    const clap = b.dependency("clap", .{});

    const exe = b.addExecutable(.{
        .name = "neoclaw",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "neoclaw", .module = mod },
                .{ .name = "clap", .module = clap.module("clap") },
            },
        }),
    });
    exe.build_id = .fast;

    b.installArtifact(exe);

    const codex_test_exe = b.addExecutable(.{
        .name = "codex-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/codex_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "neoclaw", .module = mod },
            },
        }),
    });

    b.installArtifact(codex_test_exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_codex_test_step = b.step("run-codex-test", "Run the Codex test client");
    const run_codex_test_cmd = b.addRunArtifact(codex_test_exe);
    run_codex_test_step.dependOn(&run_codex_test_cmd.step);
    run_codex_test_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_codex_test_cmd.addArgs(args);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_cancel.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "neoclaw", .module = mod },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("integration-test", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);
}

fn detectGitCommit(b: *std.Build) []const u8 {
    var code: u8 = 0;
    const stdout = b.runAllowFail(&.{ "git", "rev-parse", "--short=12", "HEAD" }, &code, .ignore) catch return "unknown";
    defer b.allocator.free(stdout);

    const trimmed = std.mem.trimEnd(u8, stdout, "\r\n");
    if (trimmed.len == 0) return "unknown";
    return b.allocator.dupe(u8, trimmed) catch "unknown";
}
