const std = @import("std");
const openai = @import("../llm/openai.zig");
const loop = @import("../loop.zig");
const Agent = loop.Agent;

const Allocator = std.mem.Allocator;
const Io = std.Io;

const InboxItem = struct {
    node: std.DoublyLinkedList.Node = .{},
    msg: Msg,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    done: bool = false,
    result: Result = .pending,

    const Msg = union(enum) {
        // External interrupts (from user).
        submit_query: struct {
            agent_id: ?loop.AgentId,
            client_query_id: u64,
            text: ?[]const u8,
            priority: loop.Priority,
        },
        submit_reply: struct {
            agent_id: loop.AgentId,
            syscall_id: loop.SyscallId,
            text: ?[]const u8,
        },
        cancel_agent: struct {
            agent_id: loop.AgentId,
        },
        // Internal interrupt (from tool worker).
        tool_done: struct {
            agent_id: loop.AgentId,
            syscall_id: loop.SyscallId,
            output: ?[]const u8,
            ok: bool,
            detached: bool,
        },

        fn deinit(self: *Msg, allocator: Allocator) void {
            switch (self.*) {
                .submit_query => |msg| if (msg.text) |t| allocator.free(t),
                .submit_reply => |msg| if (msg.text) |t| allocator.free(t),
                .cancel_agent => {},
                .tool_done => |msg| if (msg.output) |o| allocator.free(o),
            }
            self.* = undefined;
        }
    };

    const Result = union(enum) {
        pending,
        ok: loop.SubmitReceipt,
        cancel_ok: loop.CancelReceipt,
        err: loop.SubmitError,
        cancel_err: loop.CancelError,
    };

    fn deinit(self: *InboxItem, allocator: Allocator) void {
        self.msg.deinit(allocator);
        self.* = undefined;
    }
};

pub const Runtime = struct {
    // -- Dependencies (injected, not owned) --
    allocator: Allocator,
    io: Io,
    client: *openai.Client,
    tool_kernel: loop.ToolKernel,
    config: loop.RuntimeConfig,

    // -- Kernel synchronization --
    // Protects `inbox`, `agents`, `shutdown`, and `agent_ids`.
    // Lock ordering: Runtime.mutex -> Agent.mailbox.mutex -> InboxItem.mutex.
    mutex: Io.Mutex = .init,
    inbox_cond: Io.Condition = .init,
    runtime_thread: ?std.Thread = null,
    shutdown: bool = false,
    agent_group: Io.Group = .init,

    // -- Agent registry and event log --
    agents: std.AutoArrayHashMapUnmanaged(loop.AgentId, *Agent) = .empty,
    event_log: loop.EventLog,
    inbox: std.DoublyLinkedList = .{},
    agent_ids: loop.IdPool(loop.AgentId) = .{},

    // -- Tool future tracking --
    // Each tool worker gets an individual Future so it can be cancelled independently.
    // Guarded by its own mutex to avoid holding `mutex` during potentially
    // blocking future.cancel() calls in cancelToolWorker.
    tool_futures: std.AutoArrayHashMapUnmanaged(loop.SyscallId, *ToolFutureEntry) = .empty,
    tool_futures_mutex: Io.Mutex = .init,

    const ToolFutureEntry = struct {
        future: Io.Future(void),
        agent_id: loop.AgentId,
    };

    pub fn init(allocator: Allocator, io: Io, client: *openai.Client, tool_kernel: loop.ToolKernel, config: loop.RuntimeConfig) Runtime {
        return .{
            .allocator = allocator,
            .io = io,
            .client = client,
            .tool_kernel = tool_kernel,
            .config = config,
            .event_log = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown = true;
        self.inbox_cond.broadcast(self.io);
        // Wake up all agent signal receiver threads so they can exit.
        for (self.agents.values()) |agent| agent.cancel_event.set(self.io);
        self.mutex.unlock(self.io);
        self.event_log.signalShutdown();

        if (self.runtime_thread) |thread| thread.join();

        // Wait for all agent threads to finish.
        self.agent_group.await(self.io) catch {};

        // Cancel all remaining tool futures.
        self.tool_futures_mutex.lockUncancelable(self.io);
        for (self.tool_futures.values()) |entry| {
            _ = entry.future.cancel(self.io);
            self.allocator.destroy(entry);
        }
        self.tool_futures.deinit(self.allocator);
        self.tool_futures_mutex.unlock(self.io);

        while (self.inbox.popFirst()) |node| {
            const item: *InboxItem = @fieldParentPtr("node", node);
            item.deinit(self.allocator);
            self.allocator.destroy(item);
        }
        self.event_log.deinit();
        for (self.agents.values()) |agent| {
            agent.deinit();
            self.allocator.destroy(agent);
        }
        self.agents.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn start(self: *Runtime) !void {
        self.runtime_thread = try std.Thread.spawn(.{}, runtimeMain, .{self});
    }

    // -- Public API: external interrupt entry points --

    pub fn submitQuery(self: *Runtime, agent_id: ?loop.AgentId, client_query_id: u64, text: []const u8, priority: loop.Priority) !loop.SubmitReceipt {
        const item = try self.allocator.create(InboxItem);
        errdefer self.allocator.destroy(item);
        item.* = .{
            .msg = .{ .submit_query = .{
                .agent_id = agent_id,
                .client_query_id = client_query_id,
                .text = try self.allocator.dupe(u8, text),
                .priority = priority,
            } },
        };
        return switch (try self.enqueueItemAndWait(item)) {
            .ok => |receipt| receipt,
            .err => |err| err,
            else => unreachable,
        };
    }

    pub fn submitReply(self: *Runtime, agent_id: loop.AgentId, syscall_id: loop.SyscallId, text: []const u8) !loop.SubmitReceipt {
        const item = try self.allocator.create(InboxItem);
        errdefer self.allocator.destroy(item);
        item.* = .{
            .msg = .{ .submit_reply = .{
                .agent_id = agent_id,
                .syscall_id = syscall_id,
                .text = try self.allocator.dupe(u8, text),
            } },
        };
        return switch (try self.enqueueItemAndWait(item)) {
            .ok => |receipt| receipt,
            .err => |err| err,
            else => unreachable,
        };
    }

    pub fn cancelAgent(self: *Runtime, agent_id: loop.AgentId) !loop.CancelReceipt {
        const item = try self.allocator.create(InboxItem);
        errdefer self.allocator.destroy(item);
        item.* = .{
            .msg = .{ .cancel_agent = .{ .agent_id = agent_id } },
        };
        return switch (try self.enqueueItemAndWait(item)) {
            .cancel_ok => |receipt| receipt,
            .cancel_err => |err| err,
            else => unreachable,
        };
    }

    // -- Kernel internals --

    fn enqueueItemAndWait(self: *Runtime, item: *InboxItem) error{ RuntimeShutdown, OutOfMemory }!InboxItem.Result {
        self.mutex.lockUncancelable(self.io);
        if (self.shutdown) {
            self.mutex.unlock(self.io);
            item.deinit(self.allocator);
            self.allocator.destroy(item);
            return error.RuntimeShutdown;
        }
        self.inbox.append(&item.node);
        self.inbox_cond.signal(self.io);
        self.mutex.unlock(self.io);

        item.mutex.lockUncancelable(self.io);
        while (!item.done) item.cond.waitUncancelable(self.io, &item.mutex);
        const result = item.result;
        item.mutex.unlock(self.io);
        defer {
            item.deinit(self.allocator);
            self.allocator.destroy(item);
        }
        return result;
    }

    fn runtimeMain(self: *Runtime) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.inbox.first == null and !self.shutdown) {
                self.inbox_cond.waitUncancelable(self.io, &self.mutex);
            }
            if (self.shutdown and self.inbox.first == null) {
                self.mutex.unlock(self.io);
                break;
            }
            const node = self.inbox.popFirst().?;
            self.mutex.unlock(self.io);

            self.dispatchItem(@fieldParentPtr("node", node));
        }

        // Drain remaining inbox items on shutdown.
        self.mutex.lockUncancelable(self.io);
        while (self.inbox.popFirst()) |node| {
            const item: *InboxItem = @fieldParentPtr("node", node);
            item.deinit(self.allocator);
            self.allocator.destroy(item);
        }
        self.mutex.unlock(self.io);
    }

    fn dispatchItem(self: *Runtime, item: *InboxItem) void {
        switch (item.msg) {
            .tool_done => |*msg| {
                if (self.dispatchToolDone(msg.*)) {
                    msg.output = null;
                }
                item.deinit(self.allocator);
                self.allocator.destroy(item);
                return;
            },
            else => {},
        }

        const result: InboxItem.Result = switch (item.msg) {
            .submit_query => |*msg| self.handleSubmitQuery(msg),
            .submit_reply => |*msg| self.handleSubmitReply(msg),
            .cancel_agent => |msg| self.handleCancelAgent(msg),
            .tool_done => unreachable,
        };
        item.mutex.lockUncancelable(self.io);
        item.result = result;
        item.done = true;
        item.cond.signal(self.io);
        item.mutex.unlock(self.io);
    }

    fn handleSubmitQuery(self: *Runtime, msg: *@FieldType(InboxItem.Msg, "submit_query")) InboxItem.Result {
        const agent = if (msg.agent_id) |id|
            self.getAgent(id) orelse return .{ .err = error.UnknownAgent }
        else
            self.createAgent() catch return .{ .err = error.OutOfMemory };

        const trigger_id = agent.trigger_ids.allocate();
        const accepted_seq = self.event_log.append(.{ .accepted = .{ .agent_id = agent.id, .trigger_id = trigger_id, .client_query_id = msg.client_query_id } }) catch
            return .{ .err = error.OutOfMemory };
        loop.debugLog("submit_query agent={d} trigger={d}", .{ agent.id, trigger_id });

        agent.enqueueMail(self.allocator, .{ .request = .{
            .id = trigger_id,
            .client_query_id = msg.client_query_id,
            .text = msg.text.?,
            .priority = msg.priority,
        } }) catch {
            msg.text = null;
            return .{ .err = error.OutOfMemory };
        };
        msg.text = null;

        return .{ .ok = .{ .accepted_seq = accepted_seq, .agent_id = agent.id, .trigger_id = trigger_id } };
    }

    fn handleSubmitReply(self: *Runtime, msg: *@FieldType(InboxItem.Msg, "submit_reply")) InboxItem.Result {
        const agent = self.getAgent(msg.agent_id) orelse return .{ .err = error.UnknownAgent };
        const accepted_seq = self.event_log.append(.{ .accepted = .{ .agent_id = msg.agent_id, .trigger_id = null, .client_query_id = null } }) catch
            return .{ .err = error.OutOfMemory };
        loop.debugLog("submit_reply agent={d} syscall={d}", .{ msg.agent_id, msg.syscall_id });

        agent.enqueueMail(self.allocator, .{ .tool_done = .{
            .syscall_id = msg.syscall_id,
            .output = msg.text.?,
            .ok = true,
            .detached = false,
        } }) catch {
            msg.text = null;
            return .{ .err = error.OutOfMemory };
        };
        msg.text = null;

        return .{ .ok = .{ .accepted_seq = accepted_seq, .agent_id = msg.agent_id, .trigger_id = null } };
    }

    fn handleCancelAgent(self: *Runtime, msg: @FieldType(InboxItem.Msg, "cancel_agent")) InboxItem.Result {
        const agent = self.getAgent(msg.agent_id) orelse return .{ .cancel_err = error.UnknownAgent };
        loop.debugLog("cancel agent={d}", .{msg.agent_id});

        // Signal the agent's signal receiver thread to cancel the event loop.
        agent.cancel_event.set(self.io);

        return .{ .cancel_ok = .{ .accepted_seq = self.event_log.peekNextSeq(), .agent_id = msg.agent_id } };
    }

    fn dispatchToolDone(self: *Runtime, msg: @FieldType(InboxItem.Msg, "tool_done")) bool {
        const agent = self.getAgent(msg.agent_id) orelse return false;
        agent.enqueueMail(self.allocator, .{ .tool_done = .{
            .syscall_id = msg.syscall_id,
            .output = msg.output.?,
            .ok = msg.ok,
            .detached = msg.detached,
        } }) catch return false;
        return true;
    }

    fn createAgent(self: *Runtime) !*Agent {
        const agent = try self.allocator.create(Agent);
        errdefer self.allocator.destroy(agent);
        agent.* = .{
            .id = self.agent_ids.allocate(),
            .allocator = self.allocator,
            .client = self.client,
            .max_turns = self.config.max_turns,
            .tools_json = self.config.tools_json,
            .kernel = self.kernelServices(),
        };
        errdefer agent.deinit();
        try agent.appendSystemPrompt(self.config.system_prompt);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.agents.put(self.allocator, agent.id, agent);

        self.agent_group.concurrent(self.io, Agent.main, .{agent}) catch |err| {
            _ = self.agents.fetchSwapRemove(agent.id);
            return err;
        };
        return agent;
    }

    fn getAgent(self: *Runtime, agent_id: loop.AgentId) ?*Agent {
        return self.agents.get(agent_id);
    }

    // -- KernelServices vtable implementation --

    fn kernelServices(self: *Runtime) loop.KernelServices {
        return .{
            .ctx = @ptrCast(self),
            .io = self.io,
            .emitEventFn = emitEventThunk,
            .startToolFn = startToolThunk,
            .spawnToolWorkerFn = spawnToolWorkerThunk,
            .cancelToolFn = cancelToolThunk,
            .isShutdownFn = isShutdownThunk,
        };
    }

    fn emitEventThunk(ctx: *anyopaque, event: loop.Event) anyerror!loop.EventSeq {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        return self.event_log.append(event);
    }

    fn startToolThunk(ctx: *anyopaque, tool_name: []const u8, args_json: []const u8, allocator: Allocator) anyerror!loop.ToolStartResult {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        return self.tool_kernel.start(tool_name, args_json, allocator);
    }

    fn spawnToolWorkerThunk(ctx: *anyopaque, agent_id: loop.AgentId, syscall_id: loop.SyscallId, job: loop.ToolJob, detached: bool) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        self.spawnToolWorker(agent_id, syscall_id, job, detached) catch {
            self.sendToolFailure(agent_id, syscall_id, detached);
        };
    }

    fn cancelToolThunk(ctx: *anyopaque, syscall_id: loop.SyscallId) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        self.cancelToolWorker(syscall_id);
    }

    fn isShutdownThunk(ctx: *anyopaque) bool {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        return self.shutdown;
    }

    // -- Tool workers (= kernel threads for executing syscalls) --

    const ToolWorkerCtx = struct {
        runtime: *Runtime,
        allocator: Allocator,
        agent_id: loop.AgentId,
        syscall_id: loop.SyscallId,
        job: loop.ToolJob,
        detached: bool,

        fn deinit(self: *ToolWorkerCtx) void {
            self.job.deinit(self.allocator);
            self.allocator.destroy(self);
        }
    };

    fn spawnToolWorker(self: *Runtime, agent_id: loop.AgentId, syscall_id: loop.SyscallId, job: loop.ToolJob, detached: bool) !void {
        loop.debugLog("spawn_tool_worker agent={d} syscall={d} detached={}", .{ agent_id, syscall_id, detached });

        const ctx = self.allocator.create(ToolWorkerCtx) catch |err| {
            job.deinit(self.allocator);
            return err;
        };
        // job has been moved into ctx, so we must ensure ctx is deinitialized on any error path from this point on.
        errdefer ctx.deinit();

        ctx.* = .{
            .runtime = self,
            .allocator = self.allocator,
            .agent_id = agent_id,
            .syscall_id = syscall_id,
            .job = job,
            .detached = detached,
        };

        // Spawn tool on its own Future for individual cancellation.
        const entry = try self.allocator.create(ToolFutureEntry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .future = try self.io.concurrent(toolWorkerMain, .{ctx}),
            .agent_id = agent_id,
        };

        // Past this point, ctx ownership has been transferred to the worker thread
        // (toolWorkerMain defers ctx.deinit()). No `try` below, so the errdefers above
        // will not fire on the normal return path.

        self.tool_futures_mutex.lockUncancelable(self.io);
        defer self.tool_futures_mutex.unlock(self.io);
        self.tool_futures.put(self.allocator, syscall_id, entry) catch |err| {
            // Future is already spawned; we just can't track it for cancellation.
            // The tool will still run and deliver results.
            // FIXME: or should it? Without being able to track the Future, we won't be able to cancel it on shutdown,
            // which could lead to memory leaks if the tool allocates memory and never finishes. Maybe we should kill the process in this case?
            loop.debugLog("spawn_tool_worker syscall={d} failed to track future: {s}", .{ syscall_id, @errorName(err) });
            self.allocator.destroy(entry);
        };
    }

    fn toolWorkerMain(ctx: *ToolWorkerCtx) void {
        defer ctx.deinit();

        var ok = true;
        loop.debugLog("tool_worker_main agent={d} syscall={d}", .{ ctx.agent_id, ctx.syscall_id });
        const output = ctx.job.run(ctx.allocator, ctx.runtime.io) catch |err| blk: {
            ok = false;
            loop.debugLog("tool_worker_main agent={d} syscall={d} failed: {s}", .{ ctx.agent_id, ctx.syscall_id, @errorName(err) });
            break :blk std.fmt.allocPrint(ctx.allocator, "tool worker failed: {s}", .{@errorName(err)}) catch return;
        };
        loop.debugLog("tool_worker_main agent={d} syscall={d} done ok={}", .{ ctx.agent_id, ctx.syscall_id, ok });

        ctx.runtime.enqueueToolDone(.{
            .agent_id = ctx.agent_id,
            .syscall_id = ctx.syscall_id,
            .output = output,
            .ok = ok,
            .detached = ctx.detached,
        });
    }

    fn cancelToolWorker(self: *Runtime, syscall_id: loop.SyscallId) void {
        loop.debugLog("cancelToolWorker syscall={d} looking up future", .{syscall_id});
        self.tool_futures_mutex.lockUncancelable(self.io);
        const entry_kv = self.tool_futures.fetchSwapRemove(syscall_id);
        self.tool_futures_mutex.unlock(self.io);

        if (entry_kv) |kv| {
            const entry = kv.value;
            loop.debugLog("cancelToolWorker syscall={d} cancelling future", .{syscall_id});
            // future.cancel blocks until the tool worker finishes.
            _ = entry.future.cancel(self.io);
            loop.debugLog("cancelToolWorker syscall={d} future cancelled", .{syscall_id});

            // Emit tool_cancelled event.
            _ = self.event_log.append(.{ .tool_cancelled = .{
                .agent_id = entry.agent_id,
                .syscall_id = syscall_id,
            } }) catch {};

            self.allocator.destroy(entry);
        } else {
            loop.debugLog("cancelToolWorker syscall={d} no future found (already finished?)", .{syscall_id});
        }
    }

    fn enqueueToolDone(self: *Runtime, msg: @FieldType(InboxItem.Msg, "tool_done")) void {
        const item = self.allocator.create(InboxItem) catch {
            if (msg.output) |o| self.allocator.free(o);
            return;
        };
        item.* = .{ .msg = .{ .tool_done = msg } };

        self.mutex.lockUncancelable(self.io);
        if (self.shutdown) {
            self.mutex.unlock(self.io);
            item.deinit(self.allocator);
            self.allocator.destroy(item);
            return;
        }
        self.inbox.append(&item.node);
        self.inbox_cond.signal(self.io);
        self.mutex.unlock(self.io);
    }

    fn sendToolFailure(self: *Runtime, agent_id: loop.AgentId, syscall_id: loop.SyscallId, detached: bool) void {
        const agent = self.getAgent(agent_id) orelse return;
        const output = self.allocator.dupe(u8, "[tool worker failed to spawn]") catch {
            agent.enqueueMail(self.allocator, .{ .tool_done = .{
                .syscall_id = syscall_id,
                .output = &.{},
                .ok = false,
                .detached = detached,
            } }) catch {};
            return;
        };
        agent.enqueueMail(self.allocator, .{ .tool_done = .{
            .syscall_id = syscall_id,
            .output = output,
            .ok = false,
            .detached = detached,
        } }) catch {};
    }
};
