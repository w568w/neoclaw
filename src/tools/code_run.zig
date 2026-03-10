const std = @import("std");
const schema = @import("../schema.zig");
const loop = @import("../loop.zig");

pub const name = "code_run";
pub const description = "Run Python or Bash code snippet.";

pub const Params = struct {
    type: enum { python, bash } = .python,
    code: []const u8,
    timeout: u32 = 10,
    cwd: ?[]const u8 = null,
};

/// Returns owned `StepOutcome.data`.
pub fn run(ctx: *schema.ToolContext, params: Params, allocator: std.mem.Allocator) !loop.StepOutcome {
    const temp_path = switch (params.type) {
        .python => ".neoclaw_tmp.py",
        .bash => ".neoclaw_tmp.sh",
    };

    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = temp_path, .data = params.code, .flags = .{ .truncate = true } });
    defer std.Io.Dir.cwd().deleteFile(ctx.io, temp_path) catch {};

    const argv = switch (params.type) {
        .python => [_][]const u8{ "python3", temp_path },
        .bash => [_][]const u8{ "bash", temp_path },
    };

    const timeout = (std.Io.Timeout{ .duration = .{
        .raw = std.Io.Duration.fromSeconds(@intCast(params.timeout)),
        .clock = .awake,
    } }).toDeadline(ctx.io);

    const result = try std.process.run(allocator, ctx.io, .{
        .argv = &argv,
        .cwd = if (params.cwd) |p| .{ .path = p } else .inherit,
        .timeout = timeout,
        .stdout_limit = .limited(512 * 1024),
        .stderr_limit = .limited(512 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.print("exit={f}\n", .{std.json.fmt(result.term, .{})});
    if (result.stdout.len > 0) {
        try out.writer.writeAll("[stdout]\n");
        try out.writer.writeAll(result.stdout);
        if (result.stdout[result.stdout.len - 1] != '\n') try out.writer.writeAll("\n");
    }
    if (result.stderr.len > 0) {
        try out.writer.writeAll("[stderr]\n");
        try out.writer.writeAll(result.stderr);
        if (result.stderr[result.stderr.len - 1] != '\n') try out.writer.writeAll("\n");
    }

    return .{ .data = try out.toOwnedSlice(), .should_exit = false };
}
