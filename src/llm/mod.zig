const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Role = enum {
    system,
    user,
    assistant,
    tool,
};

pub const ToolCallView = struct {
    /// Borrowed view.
    id: []const u8,
    /// Borrowed view.
    name: []const u8,
    /// Borrowed view.
    arguments_json: []const u8,
};

pub const ToolCallOwned = struct {
    /// Owned buffer.
    id: []const u8,
    /// Owned buffer.
    name: []const u8,
    /// Owned buffer.
    arguments_json: []const u8,

    pub fn deinit(self: *ToolCallOwned, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments_json);
        self.* = undefined;
    }

    pub fn asView(self: *const ToolCallOwned) ToolCallView {
        return .{
            .id = self.id,
            .name = self.name,
            .arguments_json = self.arguments_json,
        };
    }
};

pub const MessageView = struct {
    role: Role,
    /// Borrowed view. `MessageView` never frees this.
    content: ?[]const u8 = null,
    /// Borrowed view. `MessageView` never frees this.
    tool_call_id: ?[]const u8 = null,
    /// Borrowed view. `MessageView` never frees this.
    tool_calls: ?[]const ToolCallView = null,
};

pub const MessageOwned = struct {
    role: Role,
    /// Owned buffer.
    content: ?[]const u8 = null,
    /// Owned buffer.
    tool_call_id: ?[]const u8 = null,
    /// Owned array with owned nested strings.
    tool_calls: ?[]ToolCallOwned = null,

    pub fn deinit(self: *MessageOwned, allocator: Allocator) void {
        if (self.content) |content| allocator.free(content);
        if (self.tool_call_id) |tool_call_id| allocator.free(tool_call_id);
        if (self.tool_calls) |tool_calls| {
            for (tool_calls) |*tool_call| tool_call.deinit(allocator);
            allocator.free(tool_calls);
        }
        self.* = undefined;
    }

    pub fn asView(self: *const MessageOwned) MessageView {
        const tool_calls: ?[]const ToolCallView = if (self.tool_calls) |owned|
            @as([*]const ToolCallView, @ptrCast(owned.ptr))[0..owned.len]
        else
            null;
        return .{
            .role = self.role,
            .content = self.content,
            .tool_call_id = self.tool_call_id,
            .tool_calls = tool_calls,
        };
    }
};

pub const FinishReason = enum {
    stop,
    tool_calls,
    length,
    unknown,
};

pub fn finishReasonFromString(s: []const u8) FinishReason {
    if (std.mem.eql(u8, s, "stop")) return .stop;
    if (std.mem.eql(u8, s, "tool_calls")) return .tool_calls;
    if (std.mem.eql(u8, s, "length")) return .length;
    return .unknown;
}

pub fn cloneToolCallOwned(allocator: Allocator, src: ToolCallView) !ToolCallOwned {
    return .{
        .id = try allocator.dupe(u8, src.id),
        .name = try allocator.dupe(u8, src.name),
        .arguments_json = try allocator.dupe(u8, src.arguments_json),
    };
}

/// Returns owned array and owned nested strings.
pub fn cloneToolCallsOwned(allocator: Allocator, src: []const ToolCallView) ![]ToolCallOwned {
    const dst = try allocator.alloc(ToolCallOwned, src.len);
    errdefer allocator.free(dst);

    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) dst[i].deinit(allocator);
    }

    for (src, 0..) |item, i| {
        dst[i] = try cloneToolCallOwned(allocator, item);
        filled = i + 1;
    }
    return dst;
}

pub fn cloneToolCallsOwnedSlice(allocator: Allocator, src: []const ToolCallOwned) ![]ToolCallOwned {
    const dst = try allocator.alloc(ToolCallOwned, src.len);
    errdefer allocator.free(dst);

    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) dst[i].deinit(allocator);
    }

    for (src, 0..) |*item, i| {
        dst[i] = try cloneToolCallOwned(allocator, item.asView());
        filled = i + 1;
    }
    return dst;
}

/// Frees an array previously returned by `cloneToolCallsOwned` or equivalent owned array.
pub fn freeToolCallsOwned(allocator: Allocator, tool_calls: []ToolCallOwned) void {
    for (tool_calls) |*tc| tc.deinit(allocator);
    allocator.free(tool_calls);
}

pub fn freeMessagesOwned(allocator: Allocator, history: *std.ArrayList(MessageOwned)) void {
    for (history.items) |*msg| msg.deinit(allocator);
    history.deinit(allocator);
    history.* = .empty;
}

pub fn cloneMessagesOwnedSlice(allocator: Allocator, src: []const MessageOwned) ![]MessageOwned {
    const dst = try allocator.alloc(MessageOwned, src.len);
    errdefer allocator.free(dst);

    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) dst[i].deinit(allocator);
    }

    for (src, 0..) |msg, i| {
        dst[i] = .{
            .role = msg.role,
            .content = if (msg.content) |content| try allocator.dupe(u8, content) else null,
            .tool_call_id = if (msg.tool_call_id) |id| try allocator.dupe(u8, id) else null,
            .tool_calls = if (msg.tool_calls) |tool_calls| try cloneToolCallsOwnedSlice(allocator, tool_calls) else null,
        };
        filled = i + 1;
    }
    return dst;
}
