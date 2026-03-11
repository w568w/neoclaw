const std = @import("std");
const openai = @import("../llm/openai.zig");
const loop = @import("../loop.zig");
const Agent = loop.Agent;

const Allocator = std.mem.Allocator;

const InboxItem = struct {
    node: std.DoublyLinkedList.Node = .{},
    msg: Msg,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    done: bool = false,
    result: Result = .pending,

    const Msg = union(enum) {
        // External interrupts (from user).
        submit_query: struct {
            agent_id: ?loop.AgentId,
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
    io: std.Io,
    client: *openai.Client,
    tool_kernel: loop.ToolKernel,
    config: loop.RuntimeConfig,

    // -- Kernel synchronization --
    // Protects `inbox`, `agents`, `shutdown`, and `next_agent_id`.
    // Lock ordering: Runtime.mutex -> Agent.signal_mutex -> InboxItem.mutex.
    mutex: std.Io.Mutex = .init,
    inbox_cond: std.Io.Condition = .init,
    runtime_thread: ?std.Thread = null,
    shutdown: bool = false,
    worker_group: std.Io.Group = .init,

    // -- Agent registry and event log --
    agents: std.AutoArrayHashMapUnmanaged(loop.AgentId, *Agent) = .empty,
    event_log: loop.EventLog,
    inbox: std.DoublyLinkedList = .{},
    next_agent_id: loop.AgentId = 1,

    pub fn init(allocator: Allocator, io: std.Io, client: *openai.Client, tool_kernel: loop.ToolKernel, config: loop.RuntimeConfig) Runtime {
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
        for (self.agents.values()) |agent| agent.enqueueSignal(self.allocator, .cancel) catch {};
        self.mutex.unlock(self.io);
        self.event_log.signalShutdown();

        if (self.runtime_thread) |thread| thread.join();
        self.worker_group.await(self.io) catch {};

        while (self.inbox.popFirst()) |node| {
            const item: *InboxItem = @fieldParentPtr("node", node);
            item.deinit(self.allocator);
            self.allocator.destroy(item);
        }
        self.event_log.deinit();
        for (self.agents.values()) |agent| {
            agent.deinit(self.allocator);
            self.allocator.destroy(agent);
        }
        self.agents.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn start(self: *Runtime) !void {
        self.runtime_thread = try std.Thread.spawn(.{}, runtimeMain, .{self});
    }

    // -- Public API: external interrupt entry points --

    pub fn submitQuery(self: *Runtime, agent_id: ?loop.AgentId, text: []const u8, priority: loop.Priority) !loop.SubmitReceipt {
        const item = try self.allocator.create(InboxItem);
        errdefer self.allocator.destroy(item);
        item.* = .{
            .msg = .{ .submit_query = .{
                .agent_id = agent_id,
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

        const request_id = agent.allocateRequestId();
        const accepted_seq = self.event_log.append(.{ .accepted = .{ .agent_id = agent.id, .request_id = request_id } }) catch
            return .{ .err = error.OutOfMemory };
        loop.debugLog("submit_query agent={d} request={d}", .{ agent.id, request_id });

        agent.enqueueSignal(self.allocator, .{ .request = .{
            .id = request_id,
            .text = msg.text.?,
            .priority = msg.priority,
        } }) catch {
            msg.text = null;
            return .{ .err = error.OutOfMemory };
        };
        msg.text = null;

        return .{ .ok = .{ .accepted_seq = accepted_seq, .agent_id = agent.id, .request_id = request_id } };
    }

    fn handleSubmitReply(self: *Runtime, msg: *@FieldType(InboxItem.Msg, "submit_reply")) InboxItem.Result {
        const agent = self.getAgent(msg.agent_id) orelse return .{ .err = error.UnknownAgent };
        const accepted_seq = self.event_log.append(.{ .accepted = .{ .agent_id = msg.agent_id, .request_id = null } }) catch
            return .{ .err = error.OutOfMemory };
        loop.debugLog("submit_reply agent={d} syscall={d}", .{ msg.agent_id, msg.syscall_id });

        agent.enqueueSignal(self.allocator, .{ .tool_done = .{
            .syscall_id = msg.syscall_id,
            .output = msg.text.?,
            .ok = true,
            .detached = false,
        } }) catch {
            msg.text = null;
            return .{ .err = error.OutOfMemory };
        };
        msg.text = null;

        return .{ .ok = .{ .accepted_seq = accepted_seq, .agent_id = msg.agent_id, .request_id = null } };
    }

    fn handleCancelAgent(self: *Runtime, msg: @FieldType(InboxItem.Msg, "cancel_agent")) InboxItem.Result {
        const agent = self.getAgent(msg.agent_id) orelse return .{ .cancel_err = error.UnknownAgent };
        loop.debugLog("cancel agent={d}", .{msg.agent_id});

        agent.enqueueSignal(self.allocator, .cancel) catch {};

        return .{ .cancel_ok = .{ .accepted_seq = self.event_log.peekNextSeq(), .agent_id = msg.agent_id } };
    }

    fn dispatchToolDone(self: *Runtime, msg: @FieldType(InboxItem.Msg, "tool_done")) bool {
        const agent = self.getAgent(msg.agent_id) orelse return false;
        agent.enqueueSignal(self.allocator, .{ .tool_done = .{
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
            .id = self.next_agent_id,
            .allocator = self.allocator,
            .client = self.client,
            .max_turns = self.config.max_turns,
            .tools_json = self.config.tools_json,
            .kernel = self.kernelServices(),
        };
        errdefer agent.deinit(self.allocator);
        self.next_agent_id += 1;
        try agent.appendSystemPrompt(self.config.system_prompt);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.agents.put(self.allocator, agent.id, agent);

        self.worker_group.concurrent(self.io, Agent.main, .{agent}) catch |err| {
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
        self.spawnToolWorker(agent_id, syscall_id, job, detached);
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

    fn spawnToolWorker(self: *Runtime, agent_id: loop.AgentId, syscall_id: loop.SyscallId, job: loop.ToolJob, detached: bool) void {
        loop.debugLog("spawn_tool_worker agent={d} syscall={d} detached={}", .{ agent_id, syscall_id, detached });
        const ctx = self.allocator.create(ToolWorkerCtx) catch {
            job.deinit(self.allocator);
            self.sendToolFailure(agent_id, syscall_id, detached);
            return;
        };
        ctx.* = .{
            .runtime = self,
            .allocator = self.allocator,
            .agent_id = agent_id,
            .syscall_id = syscall_id,
            .job = job,
            .detached = detached,
        };
        self.worker_group.concurrent(self.io, toolWorkerMain, .{ctx}) catch {
            ctx.deinit();
            self.sendToolFailure(agent_id, syscall_id, detached);
            return;
        };
    }

    fn toolWorkerMain(ctx: *ToolWorkerCtx) std.Io.Cancelable!void {
        defer ctx.deinit();

        var ok = true;
        loop.debugLog("tool_worker_main agent={d} syscall={d}", .{ ctx.agent_id, ctx.syscall_id });
        const output = ctx.job.run(ctx.allocator) catch |err| blk: {
            ok = false;
            break :blk std.fmt.allocPrint(ctx.allocator, "tool worker failed: {s}", .{@errorName(err)}) catch return;
        };

        ctx.runtime.enqueueToolDone(.{
            .agent_id = ctx.agent_id,
            .syscall_id = ctx.syscall_id,
            .output = output,
            .ok = ok,
            .detached = ctx.detached,
        });
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
            agent.enqueueSignal(self.allocator, .{ .tool_done = .{
                .syscall_id = syscall_id,
                .output = &.{},
                .ok = false,
                .detached = detached,
            } }) catch {};
            return;
        };
        agent.enqueueSignal(self.allocator, .{ .tool_done = .{
            .syscall_id = syscall_id,
            .output = output,
            .ok = false,
            .detached = detached,
        } }) catch {};
    }
};
