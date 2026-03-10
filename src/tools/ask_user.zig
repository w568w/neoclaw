const std = @import("std");
const schema = @import("../schema.zig");
const loop = @import("../loop.zig");

pub const name = "ask_user";
pub const description = "Ask user for clarification and pause current loop.";

pub const Params = struct {
    question: []const u8,
};

/// Returns owned `StepOutcome.data`.
pub fn run(_: *schema.ToolContext, params: Params, allocator: std.mem.Allocator) !loop.StepOutcome {
    const payload = try std.fmt.allocPrint(allocator, "[ASK_USER] {s}", .{params.question});
    return .{ .data = payload, .should_exit = true };
}
