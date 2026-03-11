const std = @import("std");
const schema = @import("../schema.zig");
const loop = @import("../loop.zig");

pub const name = "ask_user";
pub const description = "Ask user for clarification and pause current loop.";

pub const Params = struct {
    question: []const u8,
};

pub fn start(_: *schema.ToolContext, params: Params, allocator: std.mem.Allocator) !loop.ToolStartResult {
    return .{ .wait = .{ .user = .{ .question = try allocator.dupe(u8, params.question) } } };
}
