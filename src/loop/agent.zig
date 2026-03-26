const std = @import("std");
const llm = @import("../llm/mod.zig");
const openai = @import("../llm/openai.zig");
const loop = @import("../loop.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

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
    trigger_ids: loop.IdPool(loop.TriggerId) = .{},
    syscall_ids: loop.IdPool(loop.SyscallId) = .{},

    // Mailbox. Runtime delivers mails here; Agent's event loop consumes them.
    mailbox: loop.Mailbox(loop.Mail) = .{},

    // Cancel event. Runtime sets this to request cancellation.
    cancel_event: Io.Event = .unset,

    // In-flight tool tracking. Persists across requests (detach tools
    // may outlive a single request).
    // Value is the owned tool_call_id for detached tools (needed to write tool-role history on completion),
    // or null for blocking tools (tool_call_id stays on the stack).
    active_tool_ids: std.AutoArrayHashMapUnmanaged(loop.SyscallId, ?[]const u8) = .empty,

    // -- Public interface for kernel --

    pub fn deinit(self: *Agent) void {
        llm.MessageOwned.freeList(self.allocator, &self.history);
        self.mailbox.deinit(self.kernel.io, self.allocator, loop.Mail.deinit);

        self.drainActiveToolIds();
        self.active_tool_ids.deinit(self.allocator);

        self.* = undefined;
    }

    pub fn appendSystemPrompt(self: *Agent, system_prompt: []const u8) !void {
        const content = try self.allocator.dupe(u8, system_prompt);
        errdefer self.allocator.free(content);
        try self.history.append(self.allocator, .{ .role = .system, .content = content });
    }

    /// Enqueues a mail into the agent's mailbox. Called by the kernel.
    /// User requests are prepended (high priority); everything else
    /// is appended to the tail.
    /// On failure, owned payload within the mail is freed before returning error.
    pub fn enqueueMail(self: *Agent, allocator: Allocator, mail: loop.Mail) Allocator.Error!void {
        const front = switch (mail) {
            .request => |req| req.priority == .interactive,
            .tool_done => false,
        };
        (if (front) self.mailbox.putFront(self.kernel.io, allocator, mail) else self.mailbox.put(self.kernel.io, allocator, mail)) catch {
            var m = mail;
            m.deinit(allocator);
            return error.OutOfMemory;
        };
    }

    // -- Signal receiver thread (= Agent process entry point) --

    /// Entry point for the agent thread. Acts as a signal receiver that
    /// manages the event loop lifecycle and handles cancellation.
    pub fn main(self: *Agent) void {
        loop.debugLog("agent_main agent={d} starting", .{self.id});
        while (!self.kernel.isShutdown()) {
            self.cancel_event.reset();

            loop.debugLog("agent_main agent={d} spawning eventLoop", .{self.id});
            var future = self.kernel.io.concurrent(eventLoop, .{self}) catch {
                // TODO: emit fatal event?
                return;
            };

            // Block until cancel is requested.
            self.cancel_event.waitUncancelable(self.kernel.io);
            loop.debugLog("agent_main agent={d} cancel_event fired, cancelling eventLoop", .{self.id});

            // Cancel the event loop and wait for it to finish cleanup.
            _ = future.cancel(self.kernel.io);
            loop.debugLog("agent_main agent={d} eventLoop cancelled, looping", .{self.id});
        }
        loop.debugLog("agent_main agent={d} exiting (shutdown)", .{self.id});
    }

    // -- Event loop --

    fn eventLoop(self: *Agent) void {
        const allocator = self.allocator;

        loop.debugLog("eventLoop agent={d} started", .{self.id});
        while (true) {
            loop.debugLog("eventLoop agent={d} waiting for mail", .{self.id});
            var mail = self.mailbox.take(self.kernel.io, allocator) catch {
                // error.Canceled: interrupted while idle. No request in progress,
                // but detach tools may be running.
                loop.debugLog("eventLoop agent={d} canceled while idle, cleaning up", .{self.id});
                self.cancelAllActiveTools();
                self.drainMailbox();
                return;
            };

            var trigger_id: ?loop.TriggerId = null;
            var client_query_id: ?u64 = null;
            var has_update = false;

            switch (mail) {
                .request => |*req| {
                    trigger_id = req.id;
                    client_query_id = req.client_query_id;

                    // Append user message to history.
                    if (req.takeText()) |text| {
                        const content = allocator.dupe(u8, text) catch |e| {
                            allocator.free(text);
                            self.emitErrorAndFinish(req.id, req.client_query_id, @errorName(e));
                            continue;
                        };
                        allocator.free(text);
                        self.history.append(allocator, .{ .role = .user, .content = content }) catch |e| {
                            allocator.free(content);
                            self.emitErrorAndFinish(req.id, req.client_query_id, @errorName(e));
                            continue;
                        };
                        has_update = true;
                    }
                },
                .tool_done => |td| {
                    defer allocator.free(td.output);
                    const kv = self.active_tool_ids.fetchSwapRemove(td.syscall_id) orelse continue; // Skip stale tool_done events.
                    if (!td.detached) continue; // what? It cannot happen. Ignore just in case.

                    // Detached tool completed: emit event to user and append result to history.
                    _ = self.kernel.emitEvent(.{ .tool_completed = .{
                        .agent_id = self.id,
                        .syscall_id = td.syscall_id,
                        .output = td.output,
                        .ok = td.ok,
                    } }) catch {};
                    if (kv.value) |tool_call_id| { // again, sanity check; should always be present for detached tools.
                        const content = allocator.dupe(u8, td.output) catch |e| {
                            allocator.free(tool_call_id);
                            _ = self.kernel.emitEvent(.{ .fault = .{ .agent_id = self.id, .message = @errorName(e) } }) catch {};
                            continue;
                        };
                        self.history.append(allocator, .{
                            .role = .tool,
                            .content = content,
                            .tool_call_id = tool_call_id,
                        }) catch |e| {
                            allocator.free(content);
                            allocator.free(tool_call_id);
                            _ = self.kernel.emitEvent(.{ .fault = .{ .agent_id = self.id, .message = @errorName(e) } }) catch {};
                            continue;
                        };
                        has_update = true;
                    }
                },
            }

            if (!has_update) continue;

            const tid = trigger_id orelse self.trigger_ids.allocate();
            self.processUpdate(tid, client_query_id) catch |err| switch (err) {
                error.Canceled => {
                    self.cancelAllActiveTools();
                    self.drainMailbox();
                    return;
                },
                else => self.emitErrorAndFinish(tid, client_query_id, @errorName(err)),
            };
        }
    }

    // -- Private methods --

    // Drains the mailbox, freeing all mails. Make the mailbox empty.
    // Used during cancellation to clean up pending events.
    fn drainMailbox(self: *Agent) void {
        self.mailbox.removeAll(self.kernel.io, self.allocator, loop.Mail.deinit);
    }

    // Frees all active tool IDs and clears the tracking map, so that they will be ignored if their tool_done events arrive later.
    // Used during cancellation to clean up in-flight tools.
    fn drainActiveToolIds(self: *Agent) void {
        for (self.active_tool_ids.values()) |maybe_tc_id| {
            if (maybe_tc_id) |tc_id| self.allocator.free(tc_id);
        }
        self.active_tool_ids.clearRetainingCapacity();
    }

    // -- Cancel handling --

    fn cancelAllActiveTools(self: *Agent) void {
        loop.debugLog("cancelAllActiveTools agent={d} count={d}", .{ self.id, self.active_tool_ids.count() });
        for (self.active_tool_ids.keys()) |syscall_id| {
            loop.debugLog("cancelAllActiveTools agent={d} cancelling syscall={d}", .{ self.id, syscall_id });
            self.kernel.cancelTool(syscall_id);
        }
        self.drainActiveToolIds();
    }

    // -- Update processing (LLM dialogue loop) --

    fn processUpdate(self: *Agent, trigger_id: loop.TriggerId, client_query_id: ?u64) !void {
        const allocator = self.allocator;

        _ = try self.kernel.emitEvent(.{ .started = .{ .agent_id = self.id, .trigger_id = trigger_id, .client_query_id = client_query_id } });
        loop.debugLog("processUpdate agent={d} trigger={d}", .{ self.id, trigger_id });

        var turn: u32 = 0;
        while (turn < self.max_turns) : (turn += 1) {
            loop.debugLog("processUpdate agent={d} trigger={d} turn={d}", .{ self.id, trigger_id, turn });

            // 1. call LLM
            var partial_content: ?[]const u8 = null;
            var response = self.callLlm(trigger_id, &partial_content) catch |err| switch (err) {
                error.Canceled => {
                    loop.debugLog("processUpdate agent={d} callLlm canceled", .{self.id});
                    defer if (partial_content) |pc| allocator.free(pc);
                    const final_text = partial_content orelse "[CANCELED]";
                    const content = allocator.dupe(u8, final_text) catch null;
                    if (content) |c| {
                        self.history.append(allocator, .{ .role = .assistant, .content = c }) catch {
                            allocator.free(c);
                        };
                    }
                    _ = self.kernel.emitEvent(.{ .finished = .{
                        .agent_id = self.id,
                        .trigger_id = trigger_id,
                        .client_query_id = client_query_id,
                        .final_text = final_text,
                    } }) catch {};
                    return err;
                },
                else => {
                    loop.debugLog("processUpdate agent={d} callLlm error={s}", .{ self.id, @errorName(err) });
                    self.emitErrorAndFinish(trigger_id, client_query_id, @errorName(err));
                    return;
                },
            };
            defer response.deinit(allocator);

            // 2.1. If no tool calls, append assistant message to history and finish.
            if (response.tool_calls.len == 0) {
                loop.debugLog("processUpdate agent={d} LLM done, no tool calls, content=\"{s}\"", .{ self.id, response.content });
                const content = try allocator.dupe(u8, response.content);
                errdefer allocator.free(content);
                try self.history.append(allocator, .{ .role = .assistant, .content = content });
                _ = try self.kernel.emitEvent(.{ .finished = .{ .agent_id = self.id, .trigger_id = trigger_id, .client_query_id = client_query_id, .final_text = response.content } });
                loop.debugLog("finished agent={d} trigger={d}", .{ self.id, trigger_id });
                return;
            }

            // 2.2. Or if there are tool calls, append assistant message with tool_calls and execute them sequentially.
            loop.debugLog("processUpdate agent={d} LLM returned {d} tool call(s)", .{ self.id, response.tool_calls.len });
            {
            const assistant_calls = try llm.ToolCall.cloneSlice(allocator, response.tool_calls);
            errdefer llm.ToolCall.freeSlice(allocator, assistant_calls);
            // FIXME: could it have non-null content and tool_calls at the same time?
            try self.history.append(allocator, .{ .role = .assistant, .content = null, .tool_calls = assistant_calls });
            }

            for (response.tool_calls, 0..) |tc, i| {
                loop.debugLog("processUpdate agent={d} executeSyscall[{d}] tool=\"{s}\"", .{ self.id, i, tc.name });
                self.executeSyscall(tc) catch |err| switch (err) {
                    error.Canceled => {
                        loop.debugLog("processUpdate agent={d} tool[{d}] canceled", .{ self.id, i });
                        // Patch history: add [CANCELED] result for each unfinished tool call.
                        for (response.tool_calls[i..]) |canceled_tc| {
                            const cancel_content = allocator.dupe(u8, "[CANCELED]") catch {
                                loop.debugLog("processUpdate agent={d} cancel: failed to dupe cancel_content for tc={s}", .{ self.id, canceled_tc.id });
                                continue;
                            };
                            const tc_id = allocator.dupe(u8, canceled_tc.id) catch {
                                allocator.free(cancel_content);
                                loop.debugLog("processUpdate agent={d} cancel: failed to dupe tc_id={s}", .{ self.id, canceled_tc.id });
                                continue;
                            };
                            self.history.append(allocator, .{
                                .role = .tool,
                                .content = cancel_content,
                                .tool_call_id = tc_id,
                            }) catch {
                                allocator.free(cancel_content);
                                allocator.free(tc_id);
                                loop.debugLog("processUpdate agent={d} cancel: failed to append history for tc={s}", .{ self.id, canceled_tc.id });
                            };
                        }
                        _ = self.kernel.emitEvent(.{ .finished = .{
                            .agent_id = self.id,
                            .trigger_id = trigger_id,
                            .client_query_id = client_query_id,
                            .final_text = "[CANCELED]",
                        } }) catch {};
                        return err;
                    },
                    else => return err,
                };
            }
        }

        self.emitErrorAndFinish(trigger_id, client_query_id, "[MAX_TURNS_EXCEEDED]");
    }

    fn emitErrorAndFinish(self: *Agent, trigger_id: loop.TriggerId, client_query_id: ?u64, reason: []const u8) void {
        _ = self.kernel.emitEvent(.{ .fault = .{ .agent_id = self.id, .message = reason } }) catch {};
        _ = self.kernel.emitEvent(.{ .finished = .{ .agent_id = self.id, .trigger_id = trigger_id, .client_query_id = client_query_id, .final_text = reason } }) catch {};
    }

    fn recordToolResult(self: *Agent, syscall_id: loop.SyscallId, tc_id: []const u8, output: []const u8, ok: bool) !void {
        const allocator = self.allocator;

        const content = try allocator.dupe(u8, output);
        errdefer allocator.free(content);

        try self.history.append(allocator, .{
            .role = .tool,
            .content = content,
            .tool_call_id = try allocator.dupe(u8, tc_id),
        });

        _ = try self.kernel.emitEvent(.{ .tool_completed = .{
            .agent_id = self.id,
            .syscall_id = syscall_id,
            .output = output,
            .ok = ok,
        } });
    }

    // Executes a tool call. Blocks until the tool call is completed (either ready or detached).
    // On cancellation, returns error.Canceled.
    fn executeSyscall(self: *Agent, tc: openai.ToolCall) !void {
        const allocator = self.allocator;
        const syscall_id = self.syscall_ids.allocate();

        _ = try self.kernel.emitEvent(.{ .tool_started = .{
            .agent_id = self.id,
            .syscall_id = syscall_id,
            .name = tc.name,
            .args_json = tc.arguments_json,
        } });

        const start_result = self.kernel.startTool(tc.name, tc.arguments_json, allocator) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "tool `{s}` failed to start: {s}", .{ tc.name, @errorName(err) });
            defer allocator.free(msg);
            try self.recordToolResult(syscall_id, tc.id, msg, false);
            return;
        };

        switch (start_result) {
            .ready => |output| {
                defer allocator.free(output);
                try self.recordToolResult(syscall_id, tc.id, output, true);
            },
            .wait => |wait| {
                switch (wait) {
                    .worker => |job| {
                        _ = try self.kernel.emitEvent(.{ .tool_waiting = .{ .agent_id = self.id, .syscall_id = syscall_id } });
                        self.kernel.spawnToolWorker(self.id, syscall_id, job, false);
                    },
                    .user => |user_wait| {
                        _ = try self.kernel.emitEvent(.{ .waiting_user = .{ .agent_id = self.id, .syscall_id = syscall_id, .question = user_wait.question } });
                        allocator.free(user_wait.question);
                    },
                }
                self.active_tool_ids.put(allocator, syscall_id, null) catch {
                    loop.debugLog("executeSyscall agent={d} failed to track active tool syscall={d}", .{ self.id, syscall_id });
                };
                const result = try self.waitToolDone(syscall_id);
                defer allocator.free(result.output);
                try self.recordToolResult(syscall_id, tc.id, result.output, result.ok);
            },
            .detach => |det| {
                _ = try self.kernel.emitEvent(.{ .tool_detached = .{ .agent_id = self.id, .syscall_id = syscall_id, .ack = det.ack } });
                defer allocator.free(det.ack);
                try self.recordToolResult(syscall_id, tc.id, det.ack, true);
                const owned_tc_id = try allocator.dupe(u8, tc.id);
                self.kernel.spawnToolWorker(self.id, syscall_id, det.job, true);
                self.active_tool_ids.put(allocator, syscall_id, owned_tc_id) catch {
                    loop.debugLog("executeSyscall agent={d} failed to track active detached tool syscall={d}", .{ self.id, syscall_id });
                    allocator.free(owned_tc_id);
                };
            },
        }
    }

    const ToolResult = struct { output: []const u8, ok: bool };

    // Blockedly waits for the tool call with the given syscall_id to complete, and returns its result.
    // It's a small event loop that clones the main event loop but only cares about tool_done events for the target syscall_id, while buffering other user requests and re-enqueuing them after the target tool is done.
    fn waitToolDone(self: *Agent, target_syscall_id: loop.SyscallId) Io.Cancelable!ToolResult {
        const allocator = self.allocator;
        // Temporary buffer for user requests that arrive while waiting for the tool to complete.
        // They will be re-enqueued after the target tool_done is received.
        // Reason 1: we want to reorder tool_done events before pending user requests;
        // Reason 2: prevent busy loop of taking and re-enqueuing requests while waiting for the tool to complete.
        var pending_requests: std.ArrayList(loop.Mail) = .empty;
        errdefer {
            for (pending_requests.items) |*m| m.deinit(allocator);
            pending_requests.deinit(allocator);
        }

        while (true) {
            const mail = try self.mailbox.take(self.kernel.io, allocator); // <- cancellation point

            switch (mail) {
                .tool_done => |td| {
                    defer allocator.free(td.output);

                    // 1. If this is the target syscall, return the result and re-enqueue pending user requests.
                    if (td.syscall_id == target_syscall_id and !td.detached) {
                        const output = allocator.dupe(u8, td.output) catch
                            return .{ .output = &.{}, .ok = false };
                        _ = self.active_tool_ids.fetchSwapRemove(td.syscall_id);
                        for (pending_requests.items) |*m| {
                            self.enqueueMail(allocator, m.*) catch {
                                loop.debugLog("waitToolDone agent={d} failed to re-enqueue pending request", .{self.id});
                            };
                            m.* = undefined;
                        }
                        pending_requests.deinit(allocator);
                        return .{ .output = output, .ok = td.ok };
                    }
                    // 2. If this is other detached tool, emit event and append to history normally as in event loop.
                    const kv = self.active_tool_ids.fetchSwapRemove(td.syscall_id) orelse continue;
                    if (!td.detached) continue; // It cannot happen.

                    _ = self.kernel.emitEvent(.{ .tool_completed = .{ .agent_id = self.id, .syscall_id = td.syscall_id, .output = td.output, .ok = td.ok } }) catch {};
                    if (kv.value) |tool_call_id| {
                        const content = allocator.dupe(u8, td.output) catch {
                            allocator.free(tool_call_id);
                            continue;
                        };
                        self.history.append(allocator, .{
                            .role = .tool,
                            .content = content,
                            .tool_call_id = tool_call_id,
                        }) catch {
                            allocator.free(content);
                            allocator.free(tool_call_id);
                        };
                    }
                },
                .request => |req| {
                    // 3. Save user requests to buffer temporarily.
                    pending_requests.append(allocator, .{ .request = req }) catch {};
                },
            }
        }
    }

    /// Calls the LLM with streaming. On cancel, handles cleanup
    /// (including emitting message_incomplete) and returns error.Canceled.
    /// If cancelled mid-stream, `partial_content.*` is set to an owned copy
    /// of the text received so far (caller must free). It stays null when
    /// cancellation happens before any content arrives.
    fn callLlm(self: *Agent, trigger_id: loop.TriggerId, partial_content: *?[]const u8) !openai.ChatResponse {
        const allocator = self.allocator;

        var message_views: std.ArrayList(llm.MessageView) = .empty;
        defer message_views.deinit(allocator);
        try message_views.ensureUnusedCapacity(allocator, self.history.items.len);
        for (self.history.items) |*msg| message_views.appendAssumeCapacity(msg.asView());

        loop.debugLog("callLlm agent={d} connecting to LLM", .{self.id});
        var stream = self.client.chatStream(message_views.items, self.tools_json) catch |err| {
            // FIXME: due to https://codeberg.org/ziglang/zig/issues/30910,
            // the writer/reader maps all I/O errors (including Canceled) to WriteFailed/ReadFailed. One has to check r.err for the real error code,
            // which is not viable in our case. So just check the cancel event as a workaround.
            if (err == Io.Cancelable.Canceled or self.cancel_event.isSet()) {
                loop.debugLog("callLlm agent={d} connect canceled", .{self.id});
                return error.Canceled;
            }
            loop.debugLog("callLlm agent={d} connect error={s}", .{ self.id, @errorName(err) });
            return err;
        };
        defer stream.deinit();
        loop.debugLog("callLlm agent={d} streaming started", .{self.id});

        while (true) {
            const event_opt = stream.next() catch |err| {
                // FIXME: ditto, should use proper cancellation mechanism if Zig fixes the issue.
                if (err == Io.Cancelable.Canceled or self.cancel_event.isSet()) {
                    loop.debugLog("callLlm agent={d} stream.next canceled (underlying err={s})", .{ self.id, @errorName(err) });
                    // We are in the middle of streaming when cancellation happens.
                    // Emit message_incomplete with the content so far for better UX, and then return Canceled.
                    const pc = stream.contentSoFar();
                    if (pc.len > 0) {
                        _ = self.kernel.emitEvent(.{ .message_incomplete = .{
                            .agent_id = self.id,
                            .trigger_id = trigger_id,
                            .partial_content = pc,
                        } }) catch {};
                        partial_content.* = allocator.dupe(u8, pc) catch null;
                    }
                    return error.Canceled;
                }
                loop.debugLog("callLlm agent={d} stream.next error={s}", .{ self.id, @errorName(err) });
                return err;
            };
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
