const std = @import("std");
const loop = @import("loop.zig");

const Allocator = std.mem.Allocator;

pub const ToolContext = struct {
    io: std.Io,
};

pub fn Registry(comptime tools: anytype) type {
    return struct {
        const Self = @This();

        ctx: *ToolContext,

        pub fn init(ctx: *ToolContext) Self {
            return .{ .ctx = ctx };
        }

        pub fn handler(self: *Self) loop.ToolHandler {
            return .{
                .ctx = self,
                .dispatchFn = dispatchThunk,
            };
        }

        /// Returns owned JSON string for OpenAI `tools` field.
        pub fn toolsJsonOwned(_: *Self, allocator: Allocator) ![]const u8 {
            var out: std.Io.Writer.Allocating = .init(allocator);
            defer out.deinit();

            try out.writer.writeAll("[");
            inline for (tools, 0..) |tool, i| {
                if (i != 0) try out.writer.writeAll(",");
                try writeToolSchema(&out.writer, tool);
            }
            try out.writer.writeAll("]");

            return out.toOwnedSlice();
        }

        fn dispatchThunk(ptr: *anyopaque, tool_name: []const u8, args_json: []const u8, allocator: Allocator) !loop.StepOutcome {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.dispatch(tool_name, args_json, allocator);
        }

        fn dispatch(self: *Self, tool_name: []const u8, args_json: []const u8, allocator: Allocator) !loop.StepOutcome {
            inline for (tools) |tool| {
                if (std.mem.eql(u8, tool_name, tool.name)) {
                    const parsed = try std.json.parseFromSlice(tool.Params, allocator, args_json, .{ .ignore_unknown_fields = true });
                    defer parsed.deinit();
                    return tool.run(self.ctx, parsed.value, allocator);
                }
            }
            const msg = try std.fmt.allocPrint(allocator, "unknown tool: {s}", .{tool_name});
            return .{ .data = msg, .should_exit = false };
        }
    };
}

fn writeToolSchema(writer: *std.Io.Writer, comptime tool: type) !void {
    try writer.writeAll("{\"type\":\"function\",\"function\":{");
    try writer.print("\"name\":{f}", .{std.json.fmt(tool.name, .{})});
    try writer.print(",\"description\":{f}", .{std.json.fmt(tool.description, .{})});
    try writer.writeAll(",\"parameters\":{");
    try writeParamsSchema(writer, tool.Params);
    try writer.writeAll("}}}");
}

fn writeParamsSchema(writer: *std.Io.Writer, comptime Params: type) !void {
    const ti = @typeInfo(Params);
    if (ti != .@"struct") @compileError("tool Params must be struct");

    try writer.writeAll("\"type\":\"object\",\"properties\":{");

    const fields = ti.@"struct".fields;
    inline for (fields, 0..) |f, i| {
        if (i != 0) try writer.writeAll(",");
        try writer.print("{f}:", .{std.json.fmt(f.name, .{})});
        try writeTypeSchema(writer, f.type);
    }

    try writer.writeAll("}");

    var required_count: usize = 0;
    inline for (fields) |f| {
        if (!isOptionalType(f.type) and f.default_value_ptr == null) {
            required_count += 1;
        }
    }

    if (required_count > 0) {
        try writer.writeAll(",\"required\":[");
        var emitted: usize = 0;
        inline for (fields) |f| {
            if (!isOptionalType(f.type) and f.default_value_ptr == null) {
                if (emitted != 0) try writer.writeAll(",");
                emitted += 1;
                try writer.print("{f}", .{std.json.fmt(f.name, .{})});
            }
        }
        try writer.writeAll("]");
    }
}

fn writeTypeSchema(writer: *std.Io.Writer, comptime T: type) !void {
    const base = unwrapOptional(T);
    switch (@typeInfo(base)) {
        .bool => try writer.writeAll("{\"type\":\"boolean\"}"),
        .int => try writer.writeAll("{\"type\":\"integer\"}"),
        .float => try writer.writeAll("{\"type\":\"number\"}"),
        .@"enum" => |e| {
            try writer.writeAll("{\"type\":\"string\",\"enum\":[");
            inline for (e.fields, 0..) |f, i| {
                if (i != 0) try writer.writeAll(",");
                try writer.print("{f}", .{std.json.fmt(f.name, .{})});
            }
            try writer.writeAll("]}");
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                try writer.writeAll("{\"type\":\"string\"}");
            } else {
                @compileError("unsupported pointer type in tool params");
            }
        },
        else => @compileError("unsupported param field type in schema"),
    }
}

fn isOptionalType(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn unwrapOptional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}
