const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Role = enum {
    system,
    user,
    assistant,
    tool,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,

    pub fn deinit(self: *ToolCall, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments_json);
        self.* = undefined;
    }
};

pub const MessageView = struct {
    role: Role,
    /// Borrowed view. `MessageView` never frees this.
    content: ?[]const u8 = null,
    /// Borrowed view. `MessageView` never frees this.
    tool_call_id: ?[]const u8 = null,
    /// Borrowed view. `MessageView` never frees this.
    tool_calls: ?[]const ToolCall = null,
};

pub const MessageOwned = struct {
    role: Role,
    /// Owned buffer.
    content: ?[]const u8 = null,
    /// Owned buffer.
    tool_call_id: ?[]const u8 = null,
    /// Owned array with owned nested strings.
    tool_calls: ?[]ToolCall = null,

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
        return .{
            .role = self.role,
            .content = self.content,
            .tool_call_id = self.tool_call_id,
            .tool_calls = self.tool_calls,
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

pub fn cloneToolCall(allocator: Allocator, src: ToolCall) !ToolCall {
    const id = try allocator.dupe(u8, src.id);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, src.name);
    errdefer allocator.free(name);
    const arguments_json = try allocator.dupe(u8, src.arguments_json);
    return .{ .id = id, .name = name, .arguments_json = arguments_json };
}

pub fn cloneToolCalls(allocator: Allocator, src: []const ToolCall) ![]ToolCall {
    const dst = try allocator.alloc(ToolCall, src.len);
    errdefer allocator.free(dst);

    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) dst[i].deinit(allocator);
    }

    for (src, 0..) |item, i| {
        dst[i] = try cloneToolCall(allocator, item);
        filled = i + 1;
    }
    return dst;
}

pub fn freeToolCalls(allocator: Allocator, tool_calls: []ToolCall) void {
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
        const content = if (msg.content) |c| try allocator.dupe(u8, c) else null;
        errdefer if (content) |c| allocator.free(c);
        const tool_call_id = if (msg.tool_call_id) |id| try allocator.dupe(u8, id) else null;
        errdefer if (tool_call_id) |id| allocator.free(id);
        const tool_calls = if (msg.tool_calls) |tc| try cloneToolCalls(allocator, tc) else null;
        dst[i] = .{ .role = msg.role, .content = content, .tool_call_id = tool_call_id, .tool_calls = tool_calls };
        filled = i + 1;
    }
    return dst;
}
