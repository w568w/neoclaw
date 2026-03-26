const std = @import("std");
const loop = @import("../loop.zig");
const Allocator = std.mem.Allocator;

// -- JSON serialization for Event → WebSocket messages --

pub fn serializeEvent(allocator: Allocator, record: loop.EventRecord) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{},
    };

    try jw.beginObject();
    try jw.objectField("seq");
    try jw.write(record.seq);
    try jw.objectField("type");
    try jw.write(@tagName(record.event));
    try writeEventPayload(&jw, record.event);
    try jw.endObject();
    return out.toOwnedSlice();
}

/// Writes all fields of the active union payload as flat JSON object fields.
fn writeEventPayload(jw: *std.json.Stringify, event: loop.Event) !void {
    // inline switch gives us comptime access to the payload type per variant.
    switch (event) {
        inline else => |payload| {
            const T = @TypeOf(payload);
            inline for (@typeInfo(T).@"struct".fields) |field| {
                try jw.objectField(field.name);
                try jw.write(@field(payload, field.name));
            }
        },
    }
}

// -- Command parsing (Client → Server JSON messages) --

pub const Command = union(enum) {
    query: struct {
        agent_id: ?loop.AgentId,
        client_query_id: u64,
        text: []u8,
    },
    reply: struct {
        agent_id: loop.AgentId,
        syscall_id: loop.SyscallId,
        text: []u8,
    },
    cancel: struct {
        agent_id: loop.AgentId,
    },

    pub fn deinit(self: *Command, allocator: Allocator) void {
        switch (self.*) {
            .query => |q| allocator.free(q.text),
            .reply => |r| allocator.free(r.text),
            .cancel => {},
        }
    }
};

pub const ParseError = error{
    InvalidJson,
    UnknownCommand,
    MissingField,
    OutOfMemory,
};

pub fn parseCommand(allocator: Allocator, data: []const u8) ParseError!Command {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidJson;
    const obj = root.object;

    const cmd_val = obj.get("cmd") orelse return error.MissingField;
    if (cmd_val != .string) return error.InvalidJson;
    const cmd = cmd_val.string;

    if (std.mem.eql(u8, cmd, "query")) {
        const text_val = obj.get("text") orelse return error.MissingField;
        if (text_val != .string) return error.InvalidJson;
        const agent_id = parseOptionalU64(obj.get("agent_id"));
        const client_query_id = parseOptionalU64(obj.get("client_query_id")) orelse return error.MissingField;
        const text = allocator.dupe(u8, text_val.string) catch return error.OutOfMemory;
        return .{ .query = .{ .agent_id = agent_id, .client_query_id = client_query_id, .text = text } };
    }

    if (std.mem.eql(u8, cmd, "reply")) {
        const text_val = obj.get("text") orelse return error.MissingField;
        if (text_val != .string) return error.InvalidJson;
        const agent_id = parseOptionalU64(obj.get("agent_id")) orelse return error.MissingField;
        const syscall_id = parseOptionalU64(obj.get("syscall_id")) orelse return error.MissingField;
        const text = allocator.dupe(u8, text_val.string) catch return error.OutOfMemory;
        return .{ .reply = .{ .agent_id = agent_id, .syscall_id = syscall_id, .text = text } };
    }

    if (std.mem.eql(u8, cmd, "cancel")) {
        const agent_id = parseOptionalU64(obj.get("agent_id")) orelse return error.MissingField;
        return .{ .cancel = .{ .agent_id = agent_id } };
    }

    return error.UnknownCommand;
}

fn parseOptionalU64(val: ?std.json.Value) ?u64 {
    const v = val orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .null => null,
        else => null,
    };
}
