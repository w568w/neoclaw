const std = @import("std");
const llm = @import("mod.zig");
const openai = @import("openai.zig");

const Allocator = std.mem.Allocator;

pub const ToolCall = llm.ToolCall;
pub const MessageView = llm.MessageView;
pub const ChatResponse = openai.ChatResponse;
pub const ChatDeltaEvent = openai.ChatDeltaEvent;

pub const Auth = struct {
    allocator: Allocator,
    io: std.Io,
    http_client: *std.http.Client,

    auth_base: []const u8,
    client_id: []const u8,
    user_agent: []const u8,
    auth_file_path: []const u8,

    access_token: ?[]u8 = null,
    refresh_token: ?[]u8 = null,
    account_id: ?[]u8 = null,
    expires_at_ms: ?i64 = null,

    pub const Error = error{
        HttpStatusNotOk,
        MissingRefreshToken,
        MissingAccessToken,
        InvalidAuthState,
        DeviceAuthorizationFailed,
        DeviceAuthorizationDenied,
    };

    pub fn deinit(self: *Auth) void {
        if (self.access_token) |value| self.allocator.free(value);
        if (self.refresh_token) |value| self.allocator.free(value);
        if (self.account_id) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn ensureLogin(self: *Auth) !void {
        try self.loadState();
        try self.ensureAccessToken();
    }

    pub fn loginHeadless(self: *Auth, status_writer: ?*std.Io.Writer) !void {
        var device = try self.startDeviceAuth();
        defer device.deinit(self.allocator);

        if (status_writer) |writer| {
            try writer.print("Open this URL in your browser:\n{s}\n\n", .{"https://auth.openai.com/codex/device"});
            try writer.print("Then enter this code:\n{s}\n\n", .{device.user_code});
            try writer.flush();
        }

        var poll = try self.pollDeviceAuthToken(device.device_auth_id, device.user_code, device.interval_seconds);
        defer poll.deinit(self.allocator);

        var token = try self.exchangeAuthorizationCode(poll.authorization_code, poll.code_verifier);
        defer token.deinit(self.allocator);
        try self.applyTokenResponse(&token);
        try self.saveState();
    }

    pub fn bearerHeader(self: *Auth) ![]u8 {
        const access_token = self.access_token orelse return Error.MissingAccessToken;
        return std.fmt.allocPrint(self.allocator, "Bearer {s}", .{access_token});
    }

    pub fn loadState(self: *Auth) !void {
        if (self.refresh_token != null or self.access_token != null) return;

        const data = std.Io.Dir.cwd().readFileAlloc(self.io, self.auth_file_path, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(data);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return Error.InvalidAuthState;
        const obj = parsed.value.object;

        if (obj.get("access_token")) |value| {
            if (value != .string) return Error.InvalidAuthState;
            self.access_token = try self.allocator.dupe(u8, value.string);
        }
        if (obj.get("refresh_token")) |value| {
            if (value != .string) return Error.InvalidAuthState;
            self.refresh_token = try self.allocator.dupe(u8, value.string);
        }
        if (obj.get("account_id")) |value| {
            if (value == .null) {
                self.account_id = null;
            } else {
                if (value != .string) return Error.InvalidAuthState;
                self.account_id = try self.allocator.dupe(u8, value.string);
            }
        }
        if (obj.get("expires_at_ms")) |value| {
            self.expires_at_ms = switch (value) {
                .integer => |number| number,
                .null => null,
                else => return Error.InvalidAuthState,
            };
        }
    }

    pub fn saveState(self: *Auth) !void {
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();
        try writer.writer.writeAll("{");
        try writer.writer.print("\"access_token\":{f}", .{std.json.fmt(self.access_token orelse "", .{})});
        try writer.writer.print(",\"refresh_token\":{f}", .{std.json.fmt(self.refresh_token orelse "", .{})});
        if (self.account_id) |aid| {
            try writer.writer.print(",\"account_id\":{f}", .{std.json.fmt(aid, .{})});
        } else {
            try writer.writer.writeAll(",\"account_id\":null");
        }
        if (self.expires_at_ms) |expires| {
            try writer.writer.print(",\"expires_at_ms\":{d}", .{expires});
        } else {
            try writer.writer.writeAll(",\"expires_at_ms\":null");
        }
        try writer.writer.writeAll("}\n");

        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = self.auth_file_path,
            .data = writer.written(),
            .flags = .{ .truncate = true },
        });
    }

    fn ensureAccessToken(self: *Auth) !void {
        const now_ms = self.nowMillis();
        if (self.access_token) |_| {
            if (self.expires_at_ms) |expires_at_ms| {
                if (expires_at_ms > now_ms + 60_000) return;
            } else {
                return;
            }
        }

        if (self.refresh_token) |_| {
            var token = try self.refreshToken();
            defer token.deinit(self.allocator);
            try self.applyTokenResponse(&token);
            try self.saveState();
            return;
        }

        try self.loginHeadless(null);
    }

    fn applyTokenResponse(self: *Auth, token: *TokenResponse) !void {
        try replaceOptionalOwned(self.allocator, &self.access_token, token.access_token);
        try replaceOptionalOwned(self.allocator, &self.refresh_token, token.refresh_token);
        self.expires_at_ms = if (token.expires_in) |seconds| self.nowMillis() + @as(i64, @intCast(seconds)) * 1000 else null;

        if (token.id_token) |id_token| {
            if (try extractAccountId(self.allocator, id_token)) |aid| {
                if (self.account_id) |old| self.allocator.free(old);
                self.account_id = aid;
                return;
            }
        }
        if (try extractAccountId(self.allocator, token.access_token)) |aid| {
            if (self.account_id) |old| self.allocator.free(old);
            self.account_id = aid;
        }
    }

    fn startDeviceAuth(self: *Auth) !DeviceAuthStartResponse {
        var request_body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer request_body_writer.deinit();
        try request_body_writer.writer.print("{{\"client_id\":{f}}}", .{std.json.fmt(self.client_id, .{})});

        const url = try joinUrl(self.allocator, self.auth_base, "/api/accounts/deviceauth/usercode");
        defer self.allocator.free(url);
        const response = try self.jsonRequest(.POST, url, request_body_writer.written(), null);
        defer self.allocator.free(response.body);
        if (response.status != .ok) return Error.HttpStatusNotOk;

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return Error.InvalidAuthState;
        const obj = parsed.value.object;
        const device_auth_id = try dupJsonString(self.allocator, obj.get("device_auth_id") orelse return Error.InvalidAuthState);
        errdefer self.allocator.free(device_auth_id);
        const user_code = try dupJsonString(self.allocator, obj.get("user_code") orelse return Error.InvalidAuthState);
        errdefer self.allocator.free(user_code);
        const interval_seconds = try parseJsonIntToU64(obj.get("interval") orelse return Error.InvalidAuthState);

        return .{
            .device_auth_id = device_auth_id,
            .user_code = user_code,
            .interval_seconds = interval_seconds,
        };
    }

    fn pollDeviceAuthToken(self: *Auth, device_auth_id: []const u8, user_code: []const u8, interval_seconds: u64) !DeviceAuthPollResponse {
        while (true) {
            var writer: std.Io.Writer.Allocating = .init(self.allocator);
            defer writer.deinit();
            try writer.writer.writeAll("{");
            try writer.writer.print("\"device_auth_id\":{f}", .{std.json.fmt(device_auth_id, .{})});
            try writer.writer.print(",\"user_code\":{f}", .{std.json.fmt(user_code, .{})});
            try writer.writer.writeAll("}");

            const poll_url = try joinUrl(self.allocator, self.auth_base, "/api/accounts/deviceauth/token");
            defer self.allocator.free(poll_url);
            const response = try self.jsonRequest(.POST, poll_url, writer.written(), null);
            defer self.allocator.free(response.body);

            switch (response.status) {
                .ok => {
                    const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
                    defer parsed.deinit();
                    if (parsed.value != .object) return Error.InvalidAuthState;
                    const obj = parsed.value.object;
                    const authorization_code = try dupJsonString(self.allocator, obj.get("authorization_code") orelse return Error.InvalidAuthState);
                    errdefer self.allocator.free(authorization_code);
                    const code_verifier = try dupJsonString(self.allocator, obj.get("code_verifier") orelse return Error.InvalidAuthState);
                    return .{ .authorization_code = authorization_code, .code_verifier = code_verifier };
                },
                .forbidden, .not_found => {
                    try std.Io.sleep(self.io, .fromSeconds(@intCast(interval_seconds + 3)), .boot);
                    continue;
                },
                .unauthorized => return Error.DeviceAuthorizationDenied,
                else => return Error.DeviceAuthorizationFailed,
            }
        }
    }

    fn exchangeAuthorizationCode(self: *Auth, authorization_code: []const u8, code_verifier: []const u8) !TokenResponse {
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();
        try appendFormField(&writer.writer, true, "grant_type", "authorization_code");
        try appendFormField(&writer.writer, false, "code", authorization_code);
        try appendFormField(&writer.writer, false, "redirect_uri", "https://auth.openai.com/deviceauth/callback");
        try appendFormField(&writer.writer, false, "client_id", self.client_id);
        try appendFormField(&writer.writer, false, "code_verifier", code_verifier);

        const exchange_url = try joinUrl(self.allocator, self.auth_base, "/oauth/token");
        defer self.allocator.free(exchange_url);
        const response = try self.formRequest(exchange_url, writer.written());
        defer self.allocator.free(response.body);
        if (response.status != .ok) return Error.HttpStatusNotOk;
        return try parseTokenResponse(self.allocator, response.body);
    }

    fn refreshToken(self: *Auth) !TokenResponse {
        const rt = self.refresh_token orelse return Error.MissingRefreshToken;
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();
        try appendFormField(&writer.writer, true, "grant_type", "refresh_token");
        try appendFormField(&writer.writer, false, "refresh_token", rt);
        try appendFormField(&writer.writer, false, "client_id", self.client_id);

        const refresh_url = try joinUrl(self.allocator, self.auth_base, "/oauth/token");
        defer self.allocator.free(refresh_url);
        const response = try self.formRequest(refresh_url, writer.written());
        defer self.allocator.free(response.body);
        if (response.status != .ok) return Error.HttpStatusNotOk;
        return try parseTokenResponse(self.allocator, response.body);
    }

    fn jsonRequest(self: *Auth, method: std.http.Method, url: []const u8, body: []const u8, auth_header: ?[]const u8) !SimpleHttpResponse {
        var headers_list: std.ArrayList(std.http.Header) = .empty;
        defer headers_list.deinit(self.allocator);
        try headers_list.appendSlice(self.allocator, &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "user-agent", .value = self.user_agent },
        });
        if (auth_header) |value| try headers_list.append(self.allocator, .{ .name = "authorization", .value = value });

        var response_body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer response_body_writer.deinit();

        const result = try self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = body,
            .extra_headers = headers_list.items,
            .response_writer = &response_body_writer.writer,
        });

        return .{
            .status = result.status,
            .body = try self.allocator.dupe(u8, response_body_writer.written()),
        };
    }

    fn formRequest(self: *Auth, url: []const u8, body: []const u8) !SimpleHttpResponse {
        const headers = [_]std.http.Header{
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "user-agent", .value = self.user_agent },
        };

        var response_body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer response_body_writer.deinit();

        const result = try self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = &headers,
            .response_writer = &response_body_writer.writer,
        });

        return .{
            .status = result.status,
            .body = try self.allocator.dupe(u8, response_body_writer.written()),
        };
    }

    fn nowMillis(self: *Auth) i64 {
        return std.Io.Clock.real.now(self.io).toMilliseconds();
    }
};

pub const Client = struct {
    allocator: Allocator,
    http_client: std.http.Client,
    auth: Auth,
    api_base: []const u8,
    model: []const u8,
    instructions: ?[]const u8,
    originator: []const u8,

    pub const Options = struct {
        io: std.Io,
        model: []const u8,
        api_base: []const u8 = "https://chatgpt.com/backend-api/codex/responses",
        auth_base: []const u8 = "https://auth.openai.com",
        client_id: []const u8 = "app_EMoamEEZ73f0CkXaXp7hrann",
        instructions: ?[]const u8 = null,
        auth_file_path: []const u8 = ".codex-auth.json",
        user_agent: []const u8 = "neoclaw/0.1",
        originator: []const u8 = "opencode",
        access_token: ?[]const u8 = null,
        refresh_token: ?[]const u8 = null,
        account_id: ?[]const u8 = null,
        expires_at_ms: ?i64 = null,
    };

    pub const Error = error{
        HttpStatusNotOk,
        EmptyChoices,
        StreamNotFinished,
        StreamAlreadyTaken,
        CodexApiError,
    };

    pub fn init(allocator: Allocator, options: Options) !Client {
        var client = Client{
            .allocator = allocator,
            .http_client = .{
                .allocator = allocator,
                .io = options.io,
            },
            .auth = .{
                .allocator = allocator,
                .io = options.io,
                .http_client = undefined, // Fixed up by ensureAuthClient() once self is pinned.
                .auth_base = options.auth_base,
                .client_id = options.client_id,
                .user_agent = options.user_agent,
                .auth_file_path = options.auth_file_path,
            },
            .api_base = options.api_base,
            .model = options.model,
            .instructions = options.instructions,
            .originator = options.originator,
        };
        errdefer client.deinit();

        if (options.access_token) |value| client.auth.access_token = try allocator.dupe(u8, value);
        if (options.refresh_token) |value| client.auth.refresh_token = try allocator.dupe(u8, value);
        if (options.account_id) |value| client.auth.account_id = try allocator.dupe(u8, value);
        client.auth.expires_at_ms = options.expires_at_ms;
        return client;
    }

    /// Must be called through a stable `*Client` pointer (not during `init`
    /// where the struct may still be moved) to bind auth's http_client.
    /// Called automatically by `chatStream`, but must be called manually
    /// if using `auth` directly before the first `chatStream` call.
    pub fn ensureAuthClient(self: *Client) void {
        self.auth.http_client = &self.http_client;
    }

    pub fn deinit(self: *Client) void {
        self.auth.deinit();
        self.http_client.deinit();
    }

    pub fn chat(self: *Client, messages: []const MessageView, tools_json: ?[]const u8) !ChatResponse {
        var stream = try self.chatStream(messages, tools_json);
        defer stream.deinit();

        while (try stream.next()) |_| {}
        return try stream.takeResponseOwned();
    }

    pub fn chatStream(self: *Client, messages: []const MessageView, tools_json: ?[]const u8) !ChatStream {
        self.ensureAuthClient();
        try self.auth.ensureLogin();

        const auth_header = try self.auth.bearerHeader();
        defer self.allocator.free(auth_header);

        const tools_payload = if (tools_json) |value| try convertToolsJsonToResponses(self.allocator, value) else null;
        defer if (tools_payload) |value| self.allocator.free(value);

        var request_body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer request_body_writer.deinit();
        try self.writeResponsesRequestBody(&request_body_writer.writer, messages, tools_payload, true);

        var headers_list: std.ArrayList(std.http.Header) = .empty;
        defer headers_list.deinit(self.allocator);
        try headers_list.appendSlice(self.allocator, &.{
            .{ .name = "authorization", .value = auth_header },
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "user-agent", .value = self.auth.user_agent },
            .{ .name = "originator", .value = self.originator },
        });
        if (self.auth.account_id) |aid| {
            try headers_list.append(self.allocator, .{ .name = "chatgpt-account-id", .value = aid });
        }

        const uri = try std.Uri.parse(self.api_base);
        var req = try self.http_client.request(.POST, uri, .{ .extra_headers = headers_list.items });
        errdefer {
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
        if (response.head.status != .ok) {
            var transfer_buffer: [4096]u8 = undefined;
            var reader = response.reader(&transfer_buffer);
            var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
            defer body_writer.deinit();
            _ = reader.streamRemaining(&body_writer.writer) catch {};
            std.log.err("codex request failed status={s} body={s}", .{ @tagName(response.head.status), body_writer.written() });
            return Error.HttpStatusNotOk;
        }

        return .{
            .allocator = self.allocator,
            .request = req,
            .response = response,
        };
    }

    fn writeResponsesRequestBody(self: *Client, writer: *std.Io.Writer, messages: []const MessageView, tools_json: ?[]const u8, stream: bool) !void {
        try writer.writeAll("{");
        try writer.print("\"model\":{f}", .{std.json.fmt(self.model, .{})});
        if (try self.buildInstructions(messages, self.instructions)) |instructions| {
            defer self.allocator.free(instructions);
            try writer.print(",\"instructions\":{f}", .{std.json.fmt(instructions, .{})});
        }
        try writer.writeAll(",\"store\":false");
        if (isReasoningModel(self.model)) {
            try writer.writeAll(",\"reasoning\":{\"effort\":\"medium\",\"summary\":\"auto\"}");
        }
        try writer.writeAll(",\"input\":[");
        var first = true;
        for (messages) |msg| {
            switch (msg.role) {
                .system => continue,
                .user => {
                    if (!first) try writer.writeAll(",");
                    first = false;
                    try writer.writeAll("{");
                    try writer.writeAll("\"role\":\"user\",\"content\":[");
                    try writer.print("{{\"type\":\"input_text\",\"text\":{f}}}", .{std.json.fmt(msg.content orelse "", .{})});
                    try writer.writeAll("]}");
                },
                .assistant => {
                    if (msg.content) |content| {
                        if (!first) try writer.writeAll(",");
                        first = false;
                        try writer.writeAll("{");
                        try writer.writeAll("\"role\":\"assistant\",\"content\":[");
                        try writer.print("{{\"type\":\"output_text\",\"text\":{f}}}", .{std.json.fmt(content, .{})});
                        try writer.writeAll("]}");
                    }
                    if (msg.tool_calls) |tool_calls| {
                        for (tool_calls) |tc| {
                            if (!first) try writer.writeAll(",");
                            first = false;
                            try writer.writeAll("{");
                            try writer.writeAll("\"type\":\"function_call\",");
                            try writer.print("\"call_id\":{f},\"name\":{f},\"arguments\":{f}", .{
                                std.json.fmt(tc.id, .{}),
                                std.json.fmt(tc.name, .{}),
                                std.json.fmt(tc.arguments_json, .{}),
                            });
                            try writer.writeAll("}");
                        }
                    }
                },
                .tool => {
                    if (!first) try writer.writeAll(",");
                    first = false;
                    try writer.writeAll("{");
                    try writer.writeAll("\"type\":\"function_call_output\",");
                    try writer.print("\"call_id\":{f},\"output\":{f}", .{
                        std.json.fmt(msg.tool_call_id orelse "", .{}),
                        std.json.fmt(msg.content orelse "", .{}),
                    });
                    try writer.writeAll("}");
                },
            }
        }
        try writer.writeAll("]");
        if (tools_json) |value| {
            if (value.len > 0 and !std.mem.eql(u8, value, "[]")) {
                try writer.print(",\"tools\":{s},\"tool_choice\":\"auto\"", .{value});
            }
        }
        if (stream) try writer.writeAll(",\"stream\":true");
        try writer.writeAll("}");
    }

    fn buildInstructions(self: *Client, messages: []const MessageView, default_instructions: ?[]const u8) !?[]u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(self.allocator);

        if (default_instructions) |instructions| try parts.append(self.allocator, instructions);
        for (messages) |msg| {
            if (msg.role == .system) {
                if (msg.content) |content| try parts.append(self.allocator, content);
            }
        }
        if (parts.items.len == 0) return null;

        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        for (parts.items, 0..) |part, i| {
            if (i != 0) try writer.writer.writeAll("\n\n");
            try writer.writer.writeAll(part);
        }
        return try writer.toOwnedSlice();
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
    tool_index_map: std.StringArrayHashMapUnmanaged(usize) = .empty,

    delta_buffer: std.ArrayList(u8) = .empty,
    state: State = .streaming,
    json_scratch: [65536]u8 = undefined,

    const State = enum {
        streaming,
        finished,
        taken,
    };

    const ToolCallBuilder = struct {
        item_id: std.ArrayList(u8) = .empty,
        call_id: std.ArrayList(u8) = .empty,
        name: std.ArrayList(u8) = .empty,
        arguments_json: std.ArrayList(u8) = .empty,

        fn deinit(self: *ToolCallBuilder, allocator: Allocator) void {
            self.item_id.deinit(allocator);
            self.call_id.deinit(allocator);
            self.name.deinit(allocator);
            self.arguments_json.deinit(allocator);
            self.* = undefined;
        }
    };

    pub fn deinit(self: *ChatStream) void {
        self.delta_buffer.deinit(self.allocator);
        self.content_builder.deinit(self.allocator);
        self.finish_reason_builder.deinit(self.allocator);
        // Keys in tool_index_map point into ToolCallBuilder.item_id slices,
        // so they are freed when the builders are deinited below.
        self.tool_index_map.deinit(self.allocator);
        for (self.tool_builders.items) |*tb| tb.deinit(self.allocator);
        self.tool_builders.deinit(self.allocator);
        self.request.deinit();
        self.* = undefined;
    }

    pub fn contentSoFar(self: *const ChatStream) []const u8 {
        return self.content_builder.items;
    }

    fn getReader(self: *ChatStream) *std.Io.Reader {
        return self.reader orelse {
            self.reader = self.response.reader(&self.transfer_buffer);
            return self.reader.?;
        };
    }

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
            if (self.state == .finished) return .finished;
        }
    }

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
            const id = try tb.call_id.toOwnedSlice(self.allocator);
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

    const RawEvent = struct {
        type: []const u8,
        delta: ?[]const u8 = null,
        item_id: ?[]const u8 = null,
        output_index: ?usize = null,
        arguments: ?[]const u8 = null,
        item: ?OutputItem = null,
        response: ?ResponsePayload = null,
        incomplete_details: ?IncompleteDetails = null,

        const OutputItem = struct {
            id: ?[]const u8 = null,
            call_id: ?[]const u8 = null,
            type: []const u8,
            name: ?[]const u8 = null,
            arguments: ?[]const u8 = null,
            role: ?[]const u8 = null,
            content: ?[]const ContentPart = null,

            const ContentPart = struct {
                type: []const u8,
                text: ?[]const u8 = null,
            };
        };

        const ResponsePayload = struct {
            output: ?[]const OutputItem = null,
        };

        const IncompleteDetails = struct {
            reason: ?[]const u8 = null,
        };
    };

    const EventKind = enum {
        output_text_delta,
        output_item_added,
        output_item_done,
        function_call_arguments_delta,
        completed,
        incomplete,
        @"error",
    };

    const event_kind_map = std.StaticStringMap(EventKind).initComptime(.{
        .{ "response.output_text.delta", .output_text_delta },
        .{ "response.output_item.added", .output_item_added },
        .{ "response.output_item.done", .output_item_done },
        .{ "response.function_call_arguments.delta", .function_call_arguments_delta },
        .{ "response.completed", .completed },
        .{ "response.incomplete", .incomplete },
        .{ "error", .@"error" },
    });

    fn consumeChunk(self: *ChatStream, payload: []const u8) !?[]const u8 {
        var fba = std.heap.FixedBufferAllocator.init(&self.json_scratch);
        const parsed = try std.json.parseFromSlice(RawEvent, fba.allocator(), payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        self.delta_buffer.clearRetainingCapacity();
        const event = parsed.value;

        const kind = event_kind_map.get(event.type) orelse return null;
        switch (kind) {
            .output_text_delta => {
                if (event.delta) |delta| {
                    try self.delta_buffer.appendSlice(self.allocator, delta);
                    try self.content_builder.appendSlice(self.allocator, delta);
                }
            },
            .output_item_added, .output_item_done => {
                if (event.item) |item| try self.consumeOutputItem(item, event.output_index);
            },
            .function_call_arguments_delta => {
                const id = event.item_id orelse return null;
                const index = try self.ensureToolBuilderByItemId(id, event.output_index);
                const tb = &self.tool_builders.items[index];
                if (event.delta) |delta| try tb.arguments_json.appendSlice(self.allocator, delta);
            },
            .completed => {
                if (event.response) |response| {
                    if (response.output) |output| {
                        for (output) |item| try self.consumeOutputItem(item, null);
                    }
                }
                try self.setFinishReason(if (self.tool_builders.items.len > 0) "tool_calls" else "stop");
                self.state = .finished;
            },
            .incomplete => {
                const reason = if (event.incomplete_details) |d| d.reason else null;
                if (reason) |r| {
                    try self.setFinishReason(if (std.mem.eql(u8, r, "max_output_tokens")) "length" else r);
                } else {
                    try self.setFinishReason("unknown");
                }
                self.state = .finished;
            },
            .@"error" => return Client.Error.CodexApiError,
        }

        if (self.delta_buffer.items.len == 0) return null;
        return self.delta_buffer.items;
    }

    fn setFinishReason(self: *ChatStream, reason: []const u8) !void {
        self.finish_reason_builder.clearRetainingCapacity();
        try self.finish_reason_builder.appendSlice(self.allocator, reason);
    }

    fn consumeOutputItem(self: *ChatStream, item: RawEvent.OutputItem, output_index: ?usize) !void {
        if (std.mem.eql(u8, item.type, "function_call")) {
            const item_id = item.id orelse item.call_id orelse return;
            const index = try self.ensureToolBuilderByItemId(item_id, output_index);
            const tb = &self.tool_builders.items[index];
            if (item.call_id) |call_id| if (tb.call_id.items.len == 0) try tb.call_id.appendSlice(self.allocator, call_id);
            if (item.name) |name| if (tb.name.items.len == 0) try tb.name.appendSlice(self.allocator, name);
            if (item.arguments) |arguments| if (tb.arguments_json.items.len == 0) try tb.arguments_json.appendSlice(self.allocator, arguments);
            return;
        }

        if (std.mem.eql(u8, item.type, "message")) {
            if (item.role) |role| {
                if (!std.mem.eql(u8, role, "assistant")) return;
            }
            if (item.content) |content| {
                for (content) |part| {
                    if (std.mem.eql(u8, part.type, "output_text")) {
                        if (part.text) |text| try self.content_builder.appendSlice(self.allocator, text);
                    }
                }
            }
        }
    }

    fn ensureToolBuilderByItemId(self: *ChatStream, item_id: []const u8, output_index: ?usize) !usize {
        if (self.tool_index_map.get(item_id)) |index| return index;
        const index = if (output_index) |value| value else self.tool_builders.items.len;
        while (self.tool_builders.items.len <= index) {
            try self.tool_builders.append(self.allocator, .{});
        }
        const tb = &self.tool_builders.items[index];
        if (tb.item_id.items.len == 0) {
            try tb.item_id.appendSlice(self.allocator, item_id);
        }
        try self.tool_index_map.put(self.allocator, tb.item_id.items, index);
        return index;
    }
};

const DeviceAuthStartResponse = struct {
    device_auth_id: []u8,
    user_code: []u8,
    interval_seconds: u64,

    fn deinit(self: *DeviceAuthStartResponse, allocator: Allocator) void {
        allocator.free(self.device_auth_id);
        allocator.free(self.user_code);
        self.* = undefined;
    }
};

const DeviceAuthPollResponse = struct {
    authorization_code: []u8,
    code_verifier: []u8,

    fn deinit(self: *DeviceAuthPollResponse, allocator: Allocator) void {
        allocator.free(self.authorization_code);
        allocator.free(self.code_verifier);
        self.* = undefined;
    }
};

const TokenResponse = struct {
    id_token: ?[]u8 = null,
    access_token: []u8,
    refresh_token: []u8,
    expires_in: ?u64 = null,

    fn deinit(self: *TokenResponse, allocator: Allocator) void {
        if (self.id_token) |value| allocator.free(value);
        allocator.free(self.access_token);
        allocator.free(self.refresh_token);
        self.* = undefined;
    }
};

const SimpleHttpResponse = struct {
    status: std.http.Status,
    body: []u8,
};

fn parseTokenResponse(allocator: Allocator, body: []const u8) !TokenResponse {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return Auth.Error.InvalidAuthState;
    const obj = parsed.value.object;

    const access_token = try dupJsonString(allocator, obj.get("access_token") orelse return Auth.Error.InvalidAuthState);
    errdefer allocator.free(access_token);
    const refresh_token = try dupJsonString(allocator, obj.get("refresh_token") orelse return Auth.Error.InvalidAuthState);
    errdefer allocator.free(refresh_token);
    const id_token = if (obj.get("id_token")) |value|
        if (value == .null) null else try dupJsonString(allocator, value)
    else
        null;
    errdefer if (id_token) |value| allocator.free(value);
    const expires_in = if (obj.get("expires_in")) |value| try parseJsonIntToU64(value) else null;

    return .{
        .id_token = id_token,
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_in = expires_in,
    };
}

fn joinUrl(allocator: Allocator, base: []const u8, suffix: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, base, "/")) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ base[0 .. base.len - 1], suffix });
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, suffix });
}

fn dupJsonString(allocator: Allocator, value: std.json.Value) ![]u8 {
    if (value != .string) return Auth.Error.InvalidAuthState;
    return allocator.dupe(u8, value.string);
}

fn parseJsonIntToU64(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else Auth.Error.InvalidAuthState,
        .string => |text| std.fmt.parseInt(u64, text, 10),
        else => Auth.Error.InvalidAuthState,
    };
}

fn replaceOptionalOwned(allocator: Allocator, target: *?[]u8, src: []const u8) !void {
    const duped = try allocator.dupe(u8, src);
    if (target.*) |old| allocator.free(old);
    target.* = duped;
}

fn extractAccountId(allocator: Allocator, token: []const u8) !?[]u8 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return null;
    const payload_b64 = parts.next() orelse return null;
    _ = parts.next() orelse return null;

    const payload = try decodeBase64UrlAlloc(allocator, payload_b64);
    defer allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    if (obj.get("chatgpt_account_id")) |value| {
        if (value == .string) return try allocator.dupe(u8, value.string);
    }
    if (obj.get("https://api.openai.com/auth")) |value| {
        if (value == .object) {
            if (value.object.get("chatgpt_account_id")) |account| {
                if (account == .string) return try allocator.dupe(u8, account.string);
            }
        }
    }
    if (obj.get("organizations")) |value| {
        if (value == .array and value.array.items.len > 0) {
            const first = value.array.items[0];
            if (first == .object) {
                if (first.object.get("id")) |id_value| {
                    if (id_value == .string) return try allocator.dupe(u8, id_value.string);
                }
            }
        }
    }
    return null;
}

fn decodeBase64UrlAlloc(allocator: Allocator, encoded: []const u8) ![]u8 {
    const Decoder = std.base64.url_safe_no_pad;
    const size = try Decoder.Decoder.calcSizeForSlice(encoded);
    const output = try allocator.alloc(u8, size);
    errdefer allocator.free(output);
    try Decoder.Decoder.decode(output, encoded);
    return output;
}

fn appendFormField(writer: *std.Io.Writer, first: bool, key: []const u8, value: []const u8) !void {
    if (!first) try writer.writeAll("&");
    try writeFormEncoded(writer, key);
    try writer.writeAll("=");
    try writeFormEncoded(writer, value);
}

fn writeFormEncoded(writer: *std.Io.Writer, input: []const u8) !void {
    for (input) |c| {
        if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~') {
            try writer.writeByte(c);
        } else if (c == ' ') {
            try writer.writeByte('+');
        } else {
            try writer.print("%{X:0>2}", .{c});
        }
    }
}

fn convertToolsJsonToResponses(allocator: Allocator, tools_json: []const u8) ![]u8 {
    if (tools_json.len == 0) return allocator.dupe(u8, tools_json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, tools_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return allocator.dupe(u8, tools_json);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("[");
    for (parsed.value.array.items, 0..) |item, i| {
        if (i != 0) try writer.writer.writeAll(",");
        if (item == .object) {
            const obj = item.object;
            if (obj.get("type")) |type_value| {
                if (type_value == .string and std.mem.eql(u8, type_value.string, "function")) {
                    if (obj.get("function")) |function_value| {
                        if (function_value == .object) {
                            try writer.writer.writeAll("{");
                            try writer.writer.writeAll("\"type\":\"function\"");
                            if (function_value.object.get("name")) |name| {
                                if (name == .string) try writer.writer.print(",\"name\":{f}", .{std.json.fmt(name.string, .{})});
                            }
                            if (function_value.object.get("description")) |description| {
                                if (description == .string) try writer.writer.print(",\"description\":{f}", .{std.json.fmt(description.string, .{})});
                            }
                            if (function_value.object.get("parameters")) |parameters| {
                                try writer.writer.print(",\"parameters\":{f}", .{std.json.fmt(parameters, .{})});
                            }
                            try writer.writer.writeAll("}");
                            continue;
                        }
                    }
                }
            }
        }
        try writer.writer.print("{f}", .{std.json.fmt(item, .{})});
    }
    try writer.writer.writeAll("]");
    return writer.toOwnedSlice();
}

fn isReasoningModel(model: []const u8) bool {
    if (std.mem.startsWith(u8, model, "gpt-5") or std.mem.startsWith(u8, model, "codex-")) return true;
    // Match o1, o3, o4-mini, etc. but not arbitrary "o..." strings.
    if (model.len >= 2 and model[0] == 'o' and model[1] >= '0' and model[1] <= '9') return true;
    return false;
}
