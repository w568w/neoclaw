const std = @import("std");
const schema = @import("../schema.zig");
const loop = @import("../loop.zig");

pub const name = "file_read";
pub const description = "Read file content by line window.";

pub const Params = struct {
    path: []const u8,
    start: usize = 1,
    count: usize = 200,
};

/// Returns owned `StepOutcome.data`.
pub fn run(ctx: *schema.ToolContext, params: Params, allocator: std.mem.Allocator) !loop.StepOutcome {
    const safe_start = if (params.start == 0) @as(usize, 1) else params.start;
    const safe_count = if (params.count == 0) @as(usize, 1) else params.count;

    const content = try std.Io.Dir.cwd().readFileAlloc(ctx.io, params.path, allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(content);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var line_no: usize = 1;
    var idx: usize = 0;
    var emitted: usize = 0;

    while (idx < content.len and emitted < safe_count) {
        const line_start = idx;
        while (idx < content.len and content[idx] != '\n') : (idx += 1) {}
        const line_end = idx;
        if (idx < content.len and content[idx] == '\n') idx += 1;

        if (line_no >= safe_start) {
            try out.writer.print("{d}: {s}\n", .{ line_no, content[line_start..line_end] });
            emitted += 1;
        }
        line_no += 1;
    }

    if (emitted == 0) {
        try out.writer.writeAll("(no content in requested range)\n");
    }

    return .{ .data = try out.toOwnedSlice(), .should_exit = false };
}
