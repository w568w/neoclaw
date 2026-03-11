const std = @import("std");
const llm = @import("../llm/mod.zig");
const openai = @import("../llm/openai.zig");
const loop = @import("../loop.zig");

const Allocator = std.mem.Allocator;

pub const Agent = struct {
    id: loop.AgentId,
    allocator: Allocator,

    // Userspace dependencies (owned by the agent process).
    client: *openai.Client,
    max_turns: u32,
    tools_json: ?[]const u8,

    // Kernel services interface (syscall boundary).
    kernel: loop.KernelServices,

    // Working memory (= process virtual memory).
    history: std.ArrayList(llm.MessageOwned) = .empty,
    next_request_id: loop.RequestId = 1,
    next_syscall_id: loop.SyscallId = 1,

    // Signal queue. Kernel delivers signals here; the agent consumes them.
    signals: std.ArrayList(loop.Signal) = .empty,
    signal_mutex: std.Io.Mutex = .init,
    signal_cond: std.Io.Condition = .init,

    // -- Public interface for kernel --

    pub fn deinit(self: *Agent, allocator: Allocator) void {
        llm.MessageOwned.freeList(allocator, &self.history);
        for (self.signals.items) |*sig| sig.deinit(allocator);
        self.signals.deinit(allocator);
        self.* = undefined;
    }

    pub fn appendSystemPrompt(self: *Agent, system_prompt: []const u8) !void {
        const content = try self.allocator.dupe(u8, system_prompt);
        errdefer self.allocator.free(content);
        try self.history.append(self.allocator, .{ .role = .system, .content = content });
    }

    pub fn allocateRequestId(self: *Agent) loop.RequestId {
        const id = self.next_request_id;
        self.next_request_id += 1;
        return id;
    }

    /// Enqueues a signal into the agent's signal queue. Called by the kernel
    /// to deliver signals. On failure, owned payload within the signal is
    /// freed before returning error.
    pub fn enqueueSignal(self: *Agent, allocator: Allocator, signal: loop.Signal) Allocator.Error!void {
        const io = self.kernel.io;
        self.signal_mutex.lockUncancelable(io);
        self.signals.append(allocator, signal) catch {
            self.signal_mutex.unlock(io);
            var sig = signal;
            sig.deinit(allocator);
            return error.OutOfMemory;
        };
        self.signal_cond.signal(io);
        self.signal_mutex.unlock(io);
    }

    // -- Agent process main loop (= userspace execution) --

    pub fn main(self: *Agent) std.Io.Cancelable!void {
        const allocator = self.allocator;

        while (true) {
            var batch = self.waitSignals() orelse break;
            defer {
                for (batch.items) |*sig| sig.deinit(allocator);
                batch.deinit(allocator);
            }

            var request: ?loop.Request = null;
            var hi_requests: std.ArrayList(loop.Request) = .empty;
            var lo_requests: std.ArrayList(loop.Request) = .empty;
            defer {
                for (hi_requests.items) |*r| r.deinit(allocator);
                hi_requests.deinit(allocator);
                for (lo_requests.items) |*r| r.deinit(allocator);
                lo_requests.deinit(allocator);
            }
            for (batch.items) |*sig| {
                switch (sig.*) {
                    .request => |req| {
                        switch (req.priority) {
                            .interactive => hi_requests.append(allocator, req) catch continue,
                            .background => lo_requests.append(allocator, req) catch continue,
                        }
                        sig.* = .cancel; // Prevent double-free in batch defer.
                    },
                    .tool_done => |td| {
                        if (td.detached) {
                            _ = self.kernel.emitEvent(.{ .tool_completed = .{
                                .agent_id = self.id,
                                .syscall_id = td.syscall_id,
                                .output = td.output,
                                .ok = td.ok,
                            } }) catch {};
                            self.queueDetachedInterrupt(td);
                        }
                    },
                    else => {},
                }
            }

            if (hi_requests.items.len > 0) {
                request = hi_requests.orderedRemove(0);
            } else if (lo_requests.items.len > 0) {
                request = lo_requests.orderedRemove(0);
            }

            if (request == null) continue;

            // Put remaining requests back into signal queue (ownership transfer).
            for (hi_requests.items) |*req| {
                self.enqueueSignal(allocator, .{ .request = .{
                    .id = req.id,
                    .text = req.text,
                    .priority = req.priority,
                } }) catch {};
                req.text = null;
            }
            for (lo_requests.items) |*req| {
                self.enqueueSignal(allocator, .{ .request = .{
                    .id = req.id,
                    .text = req.text,
                    .priority = req.priority,
                } }) catch {};
                req.text = null;
            }

            var req = request.?;
            defer req.deinit(allocator);
            self.processRequest(&req) catch |err| {
                _ = self.kernel.emitEvent(.{ .fault = .{ .agent_id = self.id, .message = @errorName(err) } }) catch {};
                _ = self.kernel.emitEvent(.{ .finished = .{ .agent_id = self.id, .request_id = req.id, .final_text = @errorName(err) } }) catch {};
            };
        }
    }

    // -- Private methods --

    fn waitSignals(self: *Agent) ?std.ArrayList(loop.Signal) {
        const io = self.kernel.io;
        self.signal_mutex.lockUncancelable(io);
        while (self.signals.items.len == 0 and !self.kernel.isShutdown()) {
            self.signal_cond.waitUncancelable(io, &self.signal_mutex);
        }
        if (self.signals.items.len == 0) {
            self.signal_mutex.unlock(io);
            return null;
        }
        const batch = self.signals;
        self.signals = .empty;
        self.signal_mutex.unlock(io);
        return batch;
    }

    fn drainSignals(self: *Agent) std.ArrayList(loop.Signal) {
        const io = self.kernel.io;
        self.signal_mutex.lockUncancelable(io);
        const batch = self.signals;
        self.signals = .empty;
        self.signal_mutex.unlock(io);
        return batch;
    }

    fn nextSyscallId(self: *Agent) loop.SyscallId {
        const id = self.next_syscall_id;
        self.next_syscall_id += 1;
        return id;
    }

    fn processRequest(self: *Agent, request: *const loop.Request) !void {
        const allocator = self.allocator;

        try self.history.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, request.text.?) });
        _ = try self.kernel.emitEvent(.{ .started = .{ .agent_id = self.id, .request_id = request.id } });
        loop.debugLog("start_request agent={d} request={d}", .{ self.id, request.id });

        var turn: u32 = 0;
        while (turn < self.max_turns) : (turn += 1) {
            if (self.checkCancel()) {
                return self.finishRequest(request.id, "[CANCELED]");
            }

            const response = self.callLlm() catch |err| {
                return self.finishRequest(request.id, @errorName(err));
            };
            defer {
                var resp = response;
                resp.deinit(allocator);
            }

            if (response.tool_calls.len == 0) {
                const content = try allocator.dupe(u8, response.content);
                errdefer allocator.free(content);
                try self.history.append(allocator, .{ .role = .assistant, .content = content });
                _ = try self.kernel.emitEvent(.{ .finished = .{ .agent_id = self.id, .request_id = request.id, .final_text = response.content } });
                loop.debugLog("finished agent={d} request={d}", .{ self.id, request.id });
                return;
            }

            const assistant_calls = try llm.ToolCall.cloneSlice(allocator, response.tool_calls);
            errdefer llm.ToolCall.freeSlice(allocator, assistant_calls);
            try self.history.append(allocator, .{ .role = .assistant, .content = null, .tool_calls = assistant_calls });

            for (response.tool_calls) |tc| {
                if (self.checkCancel()) {
                    return self.finishRequest(request.id, "[CANCELED]");
                }
                try self.executeSyscall(tc);
            }
        }

        try self.finishRequest(request.id, "[MAX_TURNS_EXCEEDED]");
    }

    fn recordToolResult(self: *Agent, syscall_id: loop.SyscallId, tc_id: []const u8, output: []const u8, ok: bool) !void {
        const allocator = self.allocator;
        try self.history.append(allocator, .{
            .role = .tool,
            .content = try allocator.dupe(u8, output),
            .tool_call_id = try allocator.dupe(u8, tc_id),
        });
        _ = try self.kernel.emitEvent(.{ .tool_completed = .{
            .agent_id = self.id,
            .syscall_id = syscall_id,
            .output = output,
            .ok = ok,
        } });
    }

    fn executeSyscall(self: *Agent, tc: openai.ToolCall) !void {
        const allocator = self.allocator;
        const syscall_id = self.nextSyscallId();

        _ = try self.kernel.emitEvent(.{ .tool_started = .{ .agent_id = self.id, .syscall_id = syscall_id, .name = tc.name } });

        var start_result = self.kernel.startTool(tc.name, tc.arguments_json, allocator) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "tool `{s}` failed to start: {s}", .{ tc.name, @errorName(err) });
            defer allocator.free(msg);
            try self.recordToolResult(syscall_id, tc.id, msg, false);
            return;
        };

        switch (start_result) {
            .ready => |output| {
                defer allocator.free(output);
                try self.recordToolResult(syscall_id, tc.id, output, true);
                start_result = undefined;
            },
            .wait => |wait| {
                switch (wait) {
                    .worker => |job| {
                        _ = try self.kernel.emitEvent(.{ .tool_waiting = .{ .agent_id = self.id, .syscall_id = syscall_id } });
                        self.kernel.spawnToolWorker(self.id, syscall_id, job, false);
                        start_result = undefined;
                    },
                    .user => |user_wait| {
                        _ = try self.kernel.emitEvent(.{ .waiting_user = .{ .agent_id = self.id, .syscall_id = syscall_id, .question = user_wait.question } });
                        allocator.free(user_wait.question);
                        start_result = undefined;
                    },
                }
                const result = self.waitToolDone(syscall_id);
                defer allocator.free(result.output);
                try self.recordToolResult(syscall_id, tc.id, result.output, result.ok);
            },
            .detach => |det| {
                _ = try self.kernel.emitEvent(.{ .tool_detached = .{ .agent_id = self.id, .syscall_id = syscall_id, .ack = det.ack } });
                defer allocator.free(det.ack);
                try self.recordToolResult(syscall_id, tc.id, det.ack, true);
                self.kernel.spawnToolWorker(self.id, syscall_id, det.job, true);
                start_result = undefined;
            },
        }
    }

    fn waitToolDone(self: *Agent, target_syscall_id: loop.SyscallId) struct { output: []const u8, ok: bool } {
        const allocator = self.allocator;

        while (true) {
            var batch = self.waitSignals() orelse
                return .{ .output = &.{}, .ok = false };
            defer {
                for (batch.items) |*sig| sig.deinit(allocator);
                batch.deinit(allocator);
            }

            for (batch.items) |*sig| {
                switch (sig.*) {
                    .tool_done => |td| {
                        if (td.syscall_id == target_syscall_id and !td.detached) {
                            const output = allocator.dupe(u8, td.output) catch
                                return .{ .output = &.{}, .ok = false };
                            return .{ .output = output, .ok = td.ok };
                        }
                        if (td.detached) {
                            _ = self.kernel.emitEvent(.{ .tool_completed = .{ .agent_id = self.id, .syscall_id = td.syscall_id, .output = td.output, .ok = td.ok } }) catch {};
                            self.queueDetachedInterrupt(td);
                        }
                    },
                    .cancel => {
                        const output = allocator.dupe(u8, "[CANCELED]") catch
                            return .{ .output = &.{}, .ok = false };
                        return .{ .output = output, .ok = false };
                    },
                    .request => |*req| {
                        self.enqueueSignal(allocator, .{ .request = .{
                            .id = req.id,
                            .text = req.text,
                            .priority = req.priority,
                        } }) catch {};
                        req.text = null;
                    },
                }
            }
        }
    }

    fn queueDetachedInterrupt(self: *Agent, td: @FieldType(loop.Signal, "tool_done")) void {
        const allocator = self.allocator;
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        out.writer.print("[DETACHED INTERRUPT] syscall {d} [{s}]\n{s}", .{
            td.syscall_id,
            if (td.ok) "ok" else "failed",
            td.output,
        }) catch return;

        const text = out.toOwnedSlice() catch return;
        const request_id = self.next_request_id;
        self.next_request_id += 1;
        self.enqueueSignal(allocator, .{ .request = .{
            .id = request_id,
            .text = text,
            .priority = .interactive,
        } }) catch {};
    }

    fn checkCancel(self: *Agent) bool {
        var batch = self.drainSignals();
        defer {
            for (batch.items) |*sig| sig.deinit(self.allocator);
            batch.deinit(self.allocator);
        }

        var cancelled = false;
        for (batch.items) |*sig| {
            switch (sig.*) {
                .cancel => {
                    cancelled = true;
                },
                .request => |*req| {
                    self.enqueueSignal(self.allocator, .{ .request = .{
                        .id = req.id,
                        .text = req.text,
                        .priority = req.priority,
                    } }) catch {};
                    req.text = null;
                },
                .tool_done => |*td| {
                    self.enqueueSignal(self.allocator, .{ .tool_done = .{
                        .syscall_id = td.syscall_id,
                        .output = td.output,
                        .ok = td.ok,
                        .detached = td.detached,
                    } }) catch {};
                    td.output = &.{};
                },
            }
        }
        return cancelled;
    }

    fn finishRequest(self: *Agent, request_id: loop.RequestId, reason: []const u8) !void {
        _ = try self.kernel.emitEvent(.{ .fault = .{ .agent_id = self.id, .message = reason } });
        _ = try self.kernel.emitEvent(.{ .finished = .{ .agent_id = self.id, .request_id = request_id, .final_text = reason } });
    }

    fn callLlm(self: *Agent) !openai.ChatResponse {
        const allocator = self.allocator;

        var message_views: std.ArrayList(llm.MessageView) = .empty;
        defer message_views.deinit(allocator);
        try message_views.ensureUnusedCapacity(allocator, self.history.items.len);
        for (self.history.items) |*msg| message_views.appendAssumeCapacity(msg.asView());

        var stream = try self.client.chatStream(message_views.items, self.tools_json);
        defer stream.deinit();
        loop.debugLog("llm_call agent={d}", .{self.id});

        while (true) {
            const event_opt = try stream.next();
            if (event_opt) |event| switch (event) {
                .content_delta => |delta| {
                    _ = self.kernel.emitEvent(.{ .assistant_delta = .{ .agent_id = self.id, .text = delta } }) catch {};
                },
                .finished => {},
            } else break;
        }

        return try stream.takeResponseOwned();
    }
};
