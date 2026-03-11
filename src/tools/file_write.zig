const std = @import("std");
const schema = @import("../schema.zig");
const loop = @import("../loop.zig");

pub const name = "file_write";
pub const description = "Write or append content to a file path.";

pub const Params = struct {
    path: []const u8,
    content: []const u8,
    mode: enum { overwrite, append } = .overwrite,
};

pub fn start(ctx: *schema.ToolContext, params: Params, allocator: std.mem.Allocator) !loop.ToolStartResult {
    switch (params.mode) {
        .overwrite => {
            try std.Io.Dir.cwd().writeFile(ctx.io, .{
                .sub_path = params.path,
                .data = params.content,
                .flags = .{ .truncate = true },
            });
        },
        .append => {
            const existing = std.Io.Dir.cwd().readFileAlloc(ctx.io, params.path, allocator, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
                error.FileNotFound => try allocator.dupe(u8, ""),
                else => return err,
            };
            defer allocator.free(existing);

            const merged = try std.mem.concat(allocator, u8, &.{ existing, params.content });
            defer allocator.free(merged);

            try std.Io.Dir.cwd().writeFile(ctx.io, .{
                .sub_path = params.path,
                .data = merged,
                .flags = .{ .truncate = true },
            });
        },
    }

    return .{ .ready = try std.fmt.allocPrint(allocator, "wrote {d} bytes to {s}", .{ params.content.len, params.path }) };
}
