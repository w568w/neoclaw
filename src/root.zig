//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub const llm = @import("llm/mod.zig");
pub const openai = @import("llm/openai.zig");
pub const loop = @import("loop.zig");
pub const schema = @import("schema.zig");
pub const tools = struct {
    pub const code_run = @import("tools/code_run.zig");
    pub const file_read = @import("tools/file_read.zig");
    pub const file_write = @import("tools/file_write.zig");
    pub const ask_user = @import("tools/ask_user.zig");
};

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
