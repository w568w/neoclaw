const std = @import("std");
const openai = @import("llm/openai.zig");

const Allocator = std.mem.Allocator;

pub const StepOutcome = struct {
    /// Owned buffer. `Runner` always consumes and frees it.
    data: []const u8,
    should_exit: bool = false,
};

pub const ExitReason = enum {
    completed,
    interrupted,
    max_turns_exceeded,
};

pub const ToolResultStatus = enum {
    ok,
    interrupted,
    failed,
};

pub const ToolCallEvent = struct {
    turn: u32,
    index: u32,
    /// Borrowed view, valid until next `Runner.next` call.
    tool_call_id: []const u8,
    /// Borrowed view, valid until next `Runner.next` call.
    name: []const u8,
    /// Borrowed view, valid until next `Runner.next` call.
    arguments_json: []const u8,
};

pub const ToolResultEvent = struct {
    turn: u32,
    index: u32,
    /// Borrowed view, valid until next `Runner.next` call.
    tool_call_id: []const u8,
    status: ToolResultStatus,
    /// Borrowed view, valid until next `Runner.next` call.
    output: []const u8,
};

pub const RunFinishedEvent = struct {
    reason: ExitReason,
    /// Borrowed view, valid until next `Runner.next` call.
    final_text: []const u8,
};

pub const LoopEvent = union(enum) {
    turn_started: struct {
        turn: u32,
    },
    assistant_delta: struct {
        turn: u32,
        /// Borrowed view, valid until next `Runner.next` call.
        text: []const u8,
    },
    tool_call: ToolCallEvent,
    tool_result: ToolResultEvent,
    run_finished: RunFinishedEvent,
};

pub const ToolHandler = struct {
    ctx: *anyopaque,
    /// Must return `StepOutcome` where `data` is owned by caller.
    dispatchFn: *const fn (ctx: *anyopaque, tool_name: []const u8, args_json: []const u8, allocator: Allocator) anyerror!StepOutcome,

    pub fn dispatch(self: ToolHandler, tool_name: []const u8, args_json: []const u8, allocator: Allocator) !StepOutcome {
        return self.dispatchFn(self.ctx, tool_name, args_json, allocator);
    }
};

pub const Runner = struct {
    allocator: Allocator,
    client: *openai.Client,
    handler: ToolHandler,
    history: *std.ArrayList(openai.Message),
    tools_json: ?[]const u8,
    max_turns: u32,

    turn: u32 = 0,
    phase: Phase = .start_turn,
    stream: ?openai.ChatStream = null,
    stream_response: ?openai.ChatResponse = null,
    tool_index: usize = 0,
    pending_outcome: ?StepOutcome = null,
    pending_tool_status: ToolResultStatus = .ok,

    exit_reason: ?ExitReason = null,
    exit_text: []const u8 = "",

    const Phase = enum {
        start_turn,
        emit_turn_started,
        stream,
        emit_tool_call,
        run_tool,
        emit_tool_result,
        advance_after_tool_result,
        emit_run_finished,
        finish_cleanup,
        done,
    };

    pub fn deinit(self: *Runner) void {
        if (self.pending_outcome) |outcome| self.allocator.free(outcome.data);
        if (self.stream_response) |*resp| resp.deinit(self.allocator);
        if (self.stream) |*s| s.deinit();
        self.* = undefined;
    }

    /// Returns next event in the loop. `null` means stream finished.
    pub fn next(self: *Runner) !?LoopEvent {
        while (true) {
            switch (self.phase) {
                .start_turn => {
                    if (self.turn >= self.max_turns) {
                        self.exit_reason = .max_turns_exceeded;
                        self.exit_text = "";
                        self.phase = .emit_run_finished;
                        continue;
                    }

                    self.stream = try self.client.chatStream(self.history.items, self.tools_json);
                    self.phase = .emit_turn_started;
                    continue;
                },
                .emit_turn_started => {
                    self.phase = .stream;
                    return .{ .turn_started = .{ .turn = self.turn + 1 } };
                },
                .stream => {
                    const event_opt = try self.stream.?.next();
                    if (event_opt) |event| {
                        switch (event) {
                            .content_delta => |delta| {
                                return .{ .assistant_delta = .{ .turn = self.turn + 1, .text = delta } };
                            },
                            .finished => continue,
                        }
                    }

                    var stream = self.stream.?;
                    self.stream = null;
                    defer stream.deinit();

                    self.stream_response = try stream.takeResponseOwned();
                    if (self.stream_response.?.tool_calls.len == 0) {
                        const assistant_content = try self.allocator.dupe(u8, self.stream_response.?.content);
                        errdefer self.allocator.free(assistant_content);
                        try self.history.append(self.allocator, .{ .role = .assistant, .content = assistant_content });

                        self.exit_reason = .completed;
                        self.exit_text = self.stream_response.?.content;
                        self.phase = .emit_run_finished;
                        continue;
                    }

                    const assistant_calls = try openai.duplicateToolCalls(self.allocator, self.stream_response.?.tool_calls);
                    errdefer openai.freeToolCalls(self.allocator, assistant_calls);
                    try self.history.append(self.allocator, .{
                        .role = .assistant,
                        .content = null,
                        .tool_calls = assistant_calls,
                    });

                    self.tool_index = 0;
                    self.phase = .emit_tool_call;
                    continue;
                },
                .emit_tool_call => {
                    if (self.tool_index >= self.stream_response.?.tool_calls.len) {
                        self.stream_response.?.deinit(self.allocator);
                        self.stream_response = null;
                        self.turn += 1;
                        self.phase = .start_turn;
                        continue;
                    }

                    const tc = self.stream_response.?.tool_calls[self.tool_index];
                    self.phase = .run_tool;
                    return .{ .tool_call = .{
                        .turn = self.turn + 1,
                        .index = @intCast(self.tool_index + 1),
                        .tool_call_id = tc.id,
                        .name = tc.name,
                        .arguments_json = tc.arguments_json,
                    } };
                },
                .run_tool => {
                    const tc = self.stream_response.?.tool_calls[self.tool_index];

                    self.pending_outcome = self.handler.dispatch(tc.name, tc.arguments_json, self.allocator) catch |err| blk: {
                        const msg = if (err == error.Timeout)
                            try std.fmt.allocPrint(self.allocator, "tool `{s}` failed: timeout", .{tc.name})
                        else
                            try std.fmt.allocPrint(self.allocator, "tool `{s}` failed: {s}", .{ tc.name, @errorName(err) });
                        self.pending_tool_status = .failed;
                        break :blk StepOutcome{ .data = msg, .should_exit = false };
                    };

                    if (self.pending_tool_status != .failed) {
                        self.pending_tool_status = if (self.pending_outcome.?.should_exit) .interrupted else .ok;
                    }

                    try self.history.append(self.allocator, .{
                        .role = .tool,
                        .content = try self.allocator.dupe(u8, self.pending_outcome.?.data),
                        .tool_call_id = try self.allocator.dupe(u8, tc.id),
                    });

                    self.phase = .emit_tool_result;
                    continue;
                },
                .emit_tool_result => {
                    const tc = self.stream_response.?.tool_calls[self.tool_index];
                    const outcome = self.pending_outcome.?;
                    self.phase = .advance_after_tool_result;
                    return .{ .tool_result = .{
                        .turn = self.turn + 1,
                        .index = @intCast(self.tool_index + 1),
                        .tool_call_id = tc.id,
                        .status = self.pending_tool_status,
                        .output = outcome.data,
                    } };
                },
                .advance_after_tool_result => {
                    if (self.pending_tool_status == .interrupted) {
                        self.exit_reason = .interrupted;
                        self.exit_text = self.pending_outcome.?.data;
                        self.phase = .emit_run_finished;
                        continue;
                    }

                    self.allocator.free(self.pending_outcome.?.data);
                    self.pending_outcome = null;
                    self.pending_tool_status = .ok;
                    self.tool_index += 1;
                    self.phase = .emit_tool_call;
                    continue;
                },
                .emit_run_finished => {
                    self.phase = .finish_cleanup;
                    return .{ .run_finished = .{
                        .reason = self.exit_reason.?,
                        .final_text = self.exit_text,
                    } };
                },
                .finish_cleanup => {
                    if (self.pending_outcome) |outcome| {
                        self.allocator.free(outcome.data);
                        self.pending_outcome = null;
                    }
                    self.pending_tool_status = .ok;

                    if (self.stream_response) |*resp| {
                        resp.deinit(self.allocator);
                        self.stream_response = null;
                    }

                    self.phase = .done;
                    return null;
                },
                .done => return null,
            }
        }
    }
};

/// Returns an event runner over the current conversation history.
pub fn runEvents(
    allocator: Allocator,
    client: *openai.Client,
    handler: ToolHandler,
    history: *std.ArrayList(openai.Message),
    tools_json: ?[]const u8,
    max_turns: u32,
) !Runner {
    return .{
        .allocator = allocator,
        .client = client,
        .handler = handler,
        .history = history,
        .tools_json = tools_json,
        .max_turns = max_turns,
    };
}
