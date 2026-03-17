const std = @import("std");
const llm = @import("mod.zig");

const Allocator = std.mem.Allocator;

pub const ToolCall = llm.ToolCall;
pub const MessageView = llm.MessageView;

pub const ChatResponse = struct {
    /// Owned buffer.
    content: []const u8,
    finish_reason: llm.FinishReason,
    /// Owned array + owned nested string buffers.
    tool_calls: []ToolCall,

    /// Releases all owned fields in this response.
    pub fn deinit(self: *ChatResponse, allocator: Allocator) void {
        allocator.free(self.content);
        ToolCall.freeSlice(allocator, self.tool_calls);
        self.* = undefined;
    }
};

pub const ChatDeltaEvent = union(enum) {
    /// Borrowed view, valid until next `ChatStream.next` call.
    content_delta: []const u8,
    finished,
};

pub const Client = struct {
    allocator: Allocator,
    http_client: std.http.Client,
    /// Borrowed view. Must outlive `Client`.
    api_base: []const u8,
    /// Borrowed view. Must outlive `Client`.
    api_key: []const u8,
    /// Borrowed view. Must outlive `Client`.
    model: []const u8,

    pub const Options = struct {
        io: std.Io,
        api_base: []const u8,
        api_key: []const u8,
        model: []const u8,
    };

    pub const Error = error{
        HttpStatusNotOk,
        EmptyChoices,
        StreamNotFinished,
        StreamAlreadyTaken,
    };

    pub fn init(allocator: Allocator, options: Options) Client {
        return .{
            .allocator = allocator,
            .http_client = .{
                .allocator = allocator,
                .io = options.io,
            },
            .api_base = options.api_base,
            .api_key = options.api_key,
            .model = options.model,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
    }

    /// Returns owned `ChatResponse`. Caller must call `ChatResponse.deinit`.
    pub fn chat(self: *Client, messages: []const MessageView, tools_json: ?[]const u8) !ChatResponse {
        const endpoint = try self.chatCompletionsEndpoint();
        defer self.allocator.free(endpoint);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        var request_body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer request_body_writer.deinit();
        try self.writeChatRequestBody(&request_body_writer.writer, messages, tools_json, false);

        const headers = [_]std.http.Header{
            .{ .name = "authorization", .value = auth_header },
            .{ .name = "content-type", .value = "application/json" },
        };

        var response_body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_body_writer.deinit();

        const result = try self.http_client.fetch(.{
            .location = .{ .url = endpoint },
            .method = .POST,
            .payload = request_body_writer.written(),
            .extra_headers = &headers,
            .response_writer = &response_body_writer.writer,
        });

        if (result.status != .ok) return Error.HttpStatusNotOk;
        return parseChatResponse(self.allocator, response_body_writer.written());
    }

    /// Returns an owned stream object. Caller must call `ChatStream.deinit`.
    pub fn chatStream(self: *Client, messages: []const MessageView, tools_json: ?[]const u8) !ChatStream {
        const endpoint = try self.chatCompletionsEndpoint();
        defer self.allocator.free(endpoint);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        var request_body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer request_body_writer.deinit();
        try self.writeChatRequestBody(&request_body_writer.writer, messages, tools_json, true);

        const headers = [_]std.http.Header{
            .{ .name = "authorization", .value = auth_header },
            .{ .name = "content-type", .value = "application/json" },
        };

        const uri = try std.Uri.parse(endpoint);
        var req = try self.http_client.request(.POST, uri, .{ .extra_headers = &headers });
        errdefer {
            // FIXME: Workaround for the case that sometimes the connection is cancelled during receiving head, and closing=false still holds,
            // thus the connection is allowed for reusing in conn pool, which makes a subsequent request get response to the previous request.
            if (req.connection) |conn| conn.closing = true;
            req.deinit();
        }

        const payload = request_body_writer.written();
        req.transfer_encoding = .{ .content_length = payload.len };
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(payload);
        try body.end();
        try req.connection.?.flush();

        var response = try req.receiveHead(&.{});
        if (response.head.status != .ok) return Error.HttpStatusNotOk;

        return .{
            .allocator = self.allocator,
            .request = req,
            .response = response,
        };
    }

    fn writeChatRequestBody(self: *Client, writer: *std.Io.Writer, messages: []const MessageView, tools_json: ?[]const u8, stream: bool) !void {
        try writer.writeAll("{");
        try writer.print("\"model\":{f}", .{std.json.fmt(self.model, .{})});
        try writer.writeAll(",\"messages\":[");
        for (messages, 0..) |msg, i| {
            if (i != 0) try writer.writeAll(",");
            try writeMessage(writer, msg);
        }
        try writer.writeAll("]");
        if (tools_json) |t| {
            if (t.len > 0 and !std.mem.eql(u8, t, "[]")) {
                try writer.print(",\"tools\":{s},\"tool_choice\":\"auto\"", .{t});
            }
        }
        if (stream) try writer.writeAll(",\"stream\":true");
        try writer.writeAll("}");
    }

    /// Returns owned endpoint string.
    fn chatCompletionsEndpoint(self: *Client) ![]const u8 {
        if (std.mem.endsWith(u8, self.api_base, "/chat/completions")) return self.allocator.dupe(u8, self.api_base);
        if (std.mem.endsWith(u8, self.api_base, "/v1")) return std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.api_base});
        return std.fmt.allocPrint(self.allocator, "{s}/v1/chat/completions", .{self.api_base});
    }
};

pub const ChatStream = struct {
    allocator: Allocator,
    request: std.http.Client.Request,
    response: std.http.Client.Response,
    reader: ?*std.Io.Reader = null,
    transfer_buffer: [8192]u8 = undefined,

    content_builder: std.ArrayList(u8) = .empty,
    finish_reason_builder: std.ArrayList(u8) = .empty,
    tool_builders: std.ArrayList(ToolCallBuilder) = .empty,

    delta_buffer: std.ArrayList(u8) = .empty,
    state: State = .streaming,
    json_scratch: [65536]u8 = undefined,

    const State = enum {
        streaming,
        /// Stream ended; next() has returned .finished. Ready for takeResponseOwned().
        finished,
        /// takeResponseOwned() has been called; no further operations are valid.
        taken,
    };

    const ToolCallBuilder = struct {
        id: std.ArrayList(u8) = .empty,
        name: std.ArrayList(u8) = .empty,
        arguments_json: std.ArrayList(u8) = .empty,

        fn deinit(self: *ToolCallBuilder, allocator: Allocator) void {
            self.id.deinit(allocator);
            self.name.deinit(allocator);
            self.arguments_json.deinit(allocator);
            self.* = undefined;
        }
    };

    pub fn deinit(self: *ChatStream) void {
        self.delta_buffer.deinit(self.allocator);
        self.content_builder.deinit(self.allocator);
        self.finish_reason_builder.deinit(self.allocator);
        for (self.tool_builders.items) |*tb| tb.deinit(self.allocator);
        self.tool_builders.deinit(self.allocator);
        self.request.deinit();
        self.* = undefined;
    }

    /// Returns the content accumulated so far from stream chunks.
    /// Borrowed view, valid until the next stream read or deinit.
    pub fn contentSoFar(self: *const ChatStream) []const u8 {
        return self.content_builder.items;
    }

    fn getReader(self: *ChatStream) *std.Io.Reader {
        return self.reader orelse {
            self.reader = self.response.reader(&self.transfer_buffer);
            return self.reader.?;
        };
    }

    /// Returns borrowed event data valid until next `next` call.
    pub fn next(self: *ChatStream) !?ChatDeltaEvent {
        if (self.state != .streaming) return null;

        while (true) {
            const line_opt = try self.getReader().takeDelimiter('\n');
            if (line_opt == null) {
                self.state = .finished;
                return .finished;
            }

            const line = std.mem.trimEnd(u8, line_opt.?, "\r");
            if (line.len == 0) continue;
            if (!std.mem.startsWith(u8, line, "data:")) continue;

            const payload = std.mem.trimStart(u8, line[5..], " ");
            if (std.mem.eql(u8, payload, "[DONE]")) {
                self.state = .finished;
                return .finished;
            }

            if (try self.consumeChunk(payload)) |delta| return .{ .content_delta = delta };
        }
    }

    /// Returns owned response assembled from stream chunks.
    pub fn takeResponseOwned(self: *ChatStream) !ChatResponse {
        switch (self.state) {
            .streaming => return Client.Error.StreamNotFinished,
            .taken => return Client.Error.StreamAlreadyTaken,
            .finished => {},
        }

        const content = try self.content_builder.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(content);

        const finish_reason = llm.FinishReason.fromString(self.finish_reason_builder.items);
        const tool_calls = try self.allocator.alloc(ToolCall, self.tool_builders.items.len);
        errdefer self.allocator.free(tool_calls);

        var filled: usize = 0;
        errdefer for (tool_calls[0..filled]) |*tc| tc.deinit(self.allocator);

        for (self.tool_builders.items, 0..) |*tb, i| {
            const id = try tb.id.toOwnedSlice(self.allocator);
            errdefer self.allocator.free(id);
            const name = try tb.name.toOwnedSlice(self.allocator);
            errdefer self.allocator.free(name);
            const arguments_json = try tb.arguments_json.toOwnedSlice(self.allocator);
            tool_calls[i] = .{ .id = id, .name = name, .arguments_json = arguments_json };
            filled = i + 1;
        }

        self.state = .taken;
        return .{ .content = content, .finish_reason = finish_reason, .tool_calls = tool_calls };
    }

    /// Returns borrowed content delta valid until next stream read, if present.
    fn consumeChunk(self: *ChatStream, payload: []const u8) !?[]const u8 {
        const RawChunk = struct {
            choices: []const Choice,

            const Choice = struct {
                delta: Delta = .{},
                finish_reason: ?[]const u8 = null,

                const Delta = struct {
                    content: ?[]const u8 = null,
                    tool_calls: ?[]const ToolCallDelta = null,

                    const ToolCallDelta = struct {
                        index: usize,
                        id: ?[]const u8 = null,
                        function: ?FunctionDelta = null,

                        const FunctionDelta = struct {
                            name: ?[]const u8 = null,
                            arguments: ?[]const u8 = null,
                        };
                    };
                };
            };
        };

        var fba = std.heap.FixedBufferAllocator.init(&self.json_scratch);
        const parsed = try std.json.parseFromSlice(RawChunk, fba.allocator(), payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        self.delta_buffer.clearRetainingCapacity();

        for (parsed.value.choices) |choice| {
            if (choice.delta.content) |delta| {
                try self.delta_buffer.appendSlice(self.allocator, delta);
                try self.content_builder.appendSlice(self.allocator, delta);
            }

            if (choice.delta.tool_calls) |tool_calls| {
                for (tool_calls) |delta_tool| {
                    try self.ensureToolBuilder(delta_tool.index);
                    const tb = &self.tool_builders.items[delta_tool.index];

                    if (delta_tool.id) |id| try tb.id.appendSlice(self.allocator, id);

                    if (delta_tool.function) |fn_delta| {
                        if (fn_delta.name) |name| try tb.name.appendSlice(self.allocator, name);
                        if (fn_delta.arguments) |arguments| try tb.arguments_json.appendSlice(self.allocator, arguments);
                    }
                }
            }

            if (choice.finish_reason) |finish_reason| {
                self.finish_reason_builder.clearRetainingCapacity();
                try self.finish_reason_builder.appendSlice(self.allocator, finish_reason);
            }
        }

        if (self.delta_buffer.items.len == 0) return null;
        return self.delta_buffer.items;
    }

    fn ensureToolBuilder(self: *ChatStream, index: usize) !void {
        while (self.tool_builders.items.len <= index) {
            try self.tool_builders.append(self.allocator, .{});
        }
    }
};

fn writeMessage(writer: *std.Io.Writer, msg: MessageView) !void {
    try writer.writeAll("{");
    try writer.print("\"role\":{f}", .{std.json.fmt(@tagName(msg.role), .{})});

    if (msg.content) |content| {
        try writer.print(",\"content\":{f}", .{std.json.fmt(content, .{})});
    } else {
        try writer.writeAll(",\"content\":null");
    }

    if (msg.tool_call_id) |tool_call_id| {
        try writer.print(",\"tool_call_id\":{f}", .{std.json.fmt(tool_call_id, .{})});
    }

    if (msg.tool_calls) |tool_calls| {
        try writer.writeAll(",\"tool_calls\":[");
        for (tool_calls, 0..) |tc, i| {
            if (i != 0) try writer.writeAll(",");
            try writer.writeAll("{");
            try writer.print("\"id\":{f},\"type\":\"function\",\"function\":{{\"name\":{f},\"arguments\":{f}}}", .{
                std.json.fmt(tc.id, .{}),
                std.json.fmt(tc.name, .{}),
                std.json.fmt(tc.arguments_json, .{}),
            });
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
    }

    try writer.writeAll("}");
}

/// Returns owned `ChatResponse`. Caller must call `ChatResponse.deinit`.
fn parseChatResponse(allocator: Allocator, body: []const u8) !ChatResponse {
    const RawResponse = struct {
        choices: []const Choice,

        const Choice = struct {
            message: struct {
                content: ?[]const u8 = null,
                tool_calls: ?[]const RawToolCall = null,
            },
            finish_reason: ?[]const u8 = null,
        };

        const RawToolCall = struct {
            id: []const u8,
            function: struct {
                name: []const u8,
                arguments: []const u8,
            },
        };
    };

    const parsed = try std.json.parseFromSlice(RawResponse, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value.choices.len == 0) return Client.Error.EmptyChoices;

    const first = parsed.value.choices[0];
    const content = try allocator.dupe(u8, first.message.content orelse "");
    errdefer allocator.free(content);

    const finish_reason = llm.FinishReason.fromString(first.finish_reason orelse "");
    const raw_tool_calls = first.message.tool_calls orelse &.{};
    const tool_calls = try allocator.alloc(ToolCall, raw_tool_calls.len);
    errdefer allocator.free(tool_calls);

    var filled: usize = 0;
    errdefer for (tool_calls[0..filled]) |*tc| tc.deinit(allocator);

    for (raw_tool_calls, 0..) |raw_tc, i| {
        const id = try allocator.dupe(u8, raw_tc.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, raw_tc.function.name);
        errdefer allocator.free(name);
        const arguments_json = try allocator.dupe(u8, raw_tc.function.arguments);
        tool_calls[i] = .{ .id = id, .name = name, .arguments_json = arguments_json };
        filled = i + 1;
    }

    return .{ .content = content, .finish_reason = finish_reason, .tool_calls = tool_calls };
}
