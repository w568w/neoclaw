const std = @import("std");
const llm = @import("llm/mod.zig");
const openai = @import("llm/openai.zig");

const Allocator = std.mem.Allocator;

const loop_debug_enabled = false;

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (!loop_debug_enabled) return;
    std.debug.print("[loop] " ++ fmt ++ "\n", args);
}

// 1. Shared ids and public API types.

pub const EventSeq = u64;
pub const AgentId = u64;
pub const RequestId = u64;
pub const SyscallId = u64;

pub const Priority = enum {
    interactive,
    background,
};

pub const SubscribeFrom = union(enum) {
    beginning,
    tail,
    seq: EventSeq,
};

pub const ToolJob = struct {
    ptr: *anyopaque,
    /// Runs synchronously and returns an owned output buffer.
    runFn: *const fn (ptr: *anyopaque, allocator: Allocator) anyerror![]const u8,
    /// Releases the job payload.
    deinitFn: *const fn (ptr: *anyopaque, allocator: Allocator) void,

    pub fn run(self: ToolJob, allocator: Allocator) ![]const u8 {
        return self.runFn(self.ptr, allocator);
    }

    pub fn deinit(self: ToolJob, allocator: Allocator) void {
        self.deinitFn(self.ptr, allocator);
    }
};

pub const UserWait = struct {
    /// Owned question buffer.
    question: []const u8,
};

pub const WaitSpec = union(enum) {
    worker: ToolJob,
    user: UserWait,
};

pub const DetachSpec = struct {
    /// Owned acknowledgement buffer.
    ack: []const u8,
    job: ToolJob,
};

pub const ToolStartResult = union(enum) {
    /// Owned immediate tool result.
    ready: []const u8,
    wait: WaitSpec,
    detach: DetachSpec,

    pub fn deinit(self: *ToolStartResult, allocator: Allocator) void {
        switch (self.*) {
            .ready => |buf| allocator.free(buf),
            .wait => |wait| switch (wait) {
                .worker => |job| job.deinit(allocator),
                .user => |user| allocator.free(user.question),
            },
            .detach => |det| {
                allocator.free(det.ack);
                det.job.deinit(allocator);
            },
        }
        self.* = undefined;
    }
};

pub const ToolKernel = struct {
    ctx: *anyopaque,
    /// Returns a syscall start result whose owned payload transfers to runtime.
    startFn: *const fn (ctx: *anyopaque, tool_name: []const u8, args_json: []const u8, allocator: Allocator) anyerror!ToolStartResult,

    pub fn start(self: ToolKernel, tool_name: []const u8, args_json: []const u8, allocator: Allocator) !ToolStartResult {
        return self.startFn(self.ctx, tool_name, args_json, allocator);
    }
};

// 2. Event log model. Event owns any heap payload referenced by a stored record.

pub const Event = union(enum) {
    accepted: struct {
        agent_id: AgentId,
        request_id: ?RequestId,
    },
    started: struct {
        agent_id: AgentId,
        request_id: ?RequestId,
    },
    assistant_delta: struct {
        agent_id: AgentId,
        text: []const u8,
    },
    tool_started: struct {
        agent_id: AgentId,
        syscall_id: SyscallId,
        name: []const u8,
    },
    tool_waiting: struct {
        agent_id: AgentId,
        syscall_id: SyscallId,
    },
    tool_detached: struct {
        agent_id: AgentId,
        syscall_id: SyscallId,
        ack: []const u8,
    },
    tool_completed: struct {
        agent_id: AgentId,
        syscall_id: SyscallId,
        output: []const u8,
        ok: bool,
    },
    waiting_user: struct {
        agent_id: AgentId,
        syscall_id: SyscallId,
        question: []const u8,
    },
    finished: struct {
        agent_id: AgentId,
        request_id: ?RequestId,
        final_text: []const u8,
    },
    fault: struct {
        agent_id: ?AgentId,
        message: []const u8,
    },

    fn cloneOwned(event: Event, allocator: Allocator) !Event {
        return switch (event) {
            .accepted => |ev| .{ .accepted = ev },
            .started => |ev| .{ .started = ev },
            .assistant_delta => |ev| .{ .assistant_delta = .{ .agent_id = ev.agent_id, .text = try allocator.dupe(u8, ev.text) } },
            .tool_started => |ev| .{ .tool_started = .{ .agent_id = ev.agent_id, .syscall_id = ev.syscall_id, .name = try allocator.dupe(u8, ev.name) } },
            .tool_waiting => |ev| .{ .tool_waiting = ev },
            .tool_detached => |ev| .{ .tool_detached = .{ .agent_id = ev.agent_id, .syscall_id = ev.syscall_id, .ack = try allocator.dupe(u8, ev.ack) } },
            .tool_completed => |ev| .{ .tool_completed = .{ .agent_id = ev.agent_id, .syscall_id = ev.syscall_id, .output = try allocator.dupe(u8, ev.output), .ok = ev.ok } },
            .waiting_user => |ev| .{ .waiting_user = .{ .agent_id = ev.agent_id, .syscall_id = ev.syscall_id, .question = try allocator.dupe(u8, ev.question) } },
            .finished => |ev| .{ .finished = .{ .agent_id = ev.agent_id, .request_id = ev.request_id, .final_text = try allocator.dupe(u8, ev.final_text) } },
            .fault => |ev| .{ .fault = .{ .agent_id = ev.agent_id, .message = try allocator.dupe(u8, ev.message) } },
        };
    }

    fn deinit(self: *Event, allocator: Allocator) void {
        switch (self.*) {
            .accepted => {},
            .started => {},
            .assistant_delta => |ev| allocator.free(ev.text),
            .tool_started => |ev| allocator.free(ev.name),
            .tool_waiting => {},
            .tool_detached => |ev| allocator.free(ev.ack),
            .tool_completed => |ev| allocator.free(ev.output),
            .waiting_user => |ev| allocator.free(ev.question),
            .finished => |ev| allocator.free(ev.final_text),
            .fault => |ev| allocator.free(ev.message),
        }
        self.* = undefined;
    }
};

pub const EventRecord = struct {
    seq: EventSeq,
    /// Owned by the event log.
    event: Event,

    fn clone(allocator: Allocator, event: Event, seq: EventSeq) !EventRecord {
        return .{ .seq = seq, .event = try event.cloneOwned(allocator) };
    }

    pub fn deinit(self: *EventRecord, allocator: Allocator) void {
        self.event.deinit(allocator);
        self.* = undefined;
    }
};

pub const Subscription = struct {
    next_seq: EventSeq,
};

pub const SubmitReceipt = struct {
    accepted_seq: EventSeq,
    agent_id: AgentId,
    request_id: ?RequestId,
};

const CancelReceipt = struct {
    accepted_seq: EventSeq,
    agent_id: AgentId,
};

const SubmitError = error{
    RuntimeShutdown,
    UnknownAgent,
    AgentNotWaitingUser,
    OutOfMemory,
};

const CancelError = error{
    RuntimeShutdown,
    UnknownAgent,
    OutOfMemory,
};

// 3. Userspace: Agent (= process).
//
// Each Agent runs in its own concurrent context (like a process with its own
// execution thread). It owns its working memory (message history), calls LLM
// directly, and issues syscalls to the kernel when it needs tools. The kernel
// communicates back via signals.

const Request = struct {
    id: RequestId,
    /// Owned buffer. Set to null after ownership transfer.
    text: ?[]const u8,
    priority: Priority,

    fn deinit(self: *Request, allocator: Allocator) void {
        if (self.text) |t| allocator.free(t);
        self.* = undefined;
    }
};

const Signal = union(enum) {
    request: Request,
    tool_done: struct {
        syscall_id: SyscallId,
        output: []const u8,
        ok: bool,
        detached: bool,
    },
    cancel,

    fn deinit(self: *Signal, allocator: Allocator) void {
        switch (self.*) {
            .request => |*req| req.deinit(allocator),
            .tool_done => |td| allocator.free(td.output),
            .cancel => {},
        }
        self.* = undefined;
    }
};

const Agent = struct {
    id: AgentId,
    runtime: *Runtime,
    allocator: Allocator,

    /// Working memory (= process virtual memory).
    history: std.ArrayList(llm.MessageOwned) = .empty,
    next_request_id: RequestId = 1,
    next_syscall_id: SyscallId = 1,

    /// Signal queue. Kernel delivers signals here; the agent consumes them.
    signals: std.ArrayList(Signal) = .empty,
    /// Protects `signals`. Acquired after `Runtime.mutex` when both are needed.
    signal_mutex: std.Io.Mutex = .init,
    /// Signaled when a new signal is enqueued.
    signal_cond: std.Io.Condition = .init,

    fn deinit(self: *Agent, allocator: Allocator) void {
        llm.freeMessagesOwned(allocator, &self.history);
        for (self.signals.items) |*sig| sig.deinit(allocator);
        self.signals.deinit(allocator);
        self.* = undefined;
    }

    /// Waits until at least one signal is present, then returns all signals
    /// by swapping the queue into a local copy. Caller owns the returned list
    /// and must deinit each signal.
    fn waitSignals(self: *Agent) std.ArrayList(Signal) {
        const io = self.runtime.io;
        self.signal_mutex.lockUncancelable(io);
        while (self.signals.items.len == 0) {
            self.signal_cond.waitUncancelable(io, &self.signal_mutex);
        }
        const batch = self.signals;
        self.signals = .empty;
        self.signal_mutex.unlock(io);
        return batch;
    }

    /// Non-blocking: drain any pending signals.
    fn drainSignals(self: *Agent) std.ArrayList(Signal) {
        const io = self.runtime.io;
        self.signal_mutex.lockUncancelable(io);
        const batch = self.signals;
        self.signals = .empty;
        self.signal_mutex.unlock(io);
        return batch;
    }

    fn nextSyscallId(self: *Agent) SyscallId {
        const id = self.next_syscall_id;
        self.next_syscall_id += 1;
        return id;
    }
};

// 4. Kernel: Runtime (= OS kernel loop) and communication primitives.
//
// Runtime only does three things: dispatch interrupts (external from users,
// internal from tool workers) as signals to agents, maintain the agent list,
// and maintain tool workers.

const InboxItem = struct {
    node: std.DoublyLinkedList.Node = .{},
    msg: Msg,
    /// Protects `done` and `result`. The runtime thread writes the result and
    /// sets `done = true`; the submitting thread waits for `done` to become true.
    mutex: std.Io.Mutex = .init,
    /// Signaled when `done` is set to true.
    cond: std.Io.Condition = .init,
    done: bool = false,
    result: Result = .pending,

    const Msg = union(enum) {
        // External interrupts (from user).
        submit_query: struct {
            agent_id: ?AgentId,
            /// Owned buffer. Set to null after ownership transfer.
            text: ?[]const u8,
            priority: Priority,
        },
        submit_reply: struct {
            agent_id: AgentId,
            syscall_id: SyscallId,
            /// Owned buffer. Set to null after ownership transfer.
            text: ?[]const u8,
        },
        cancel_agent: struct {
            agent_id: AgentId,
        },
        // Internal interrupt (from tool worker).
        tool_done: struct {
            agent_id: AgentId,
            syscall_id: SyscallId,
            /// Owned buffer. Set to null after ownership transfer.
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
        ok: SubmitReceipt,
        cancel_ok: CancelReceipt,
        err: SubmitError,
        cancel_err: CancelError,
    };

    fn deinit(self: *InboxItem, allocator: Allocator) void {
        self.msg.deinit(allocator);
        self.* = undefined;
    }
};

pub const RuntimeConfig = struct {
    system_prompt: []const u8,
    tools_json: ?[]const u8,
    max_turns: u32,
};

pub const EventLog = struct {
    allocator: Allocator,
    io: std.Io,
    /// Protects `events`, `next_seq`, and `shutdown`.
    mutex: std.Io.Mutex = .init,
    /// Signaled when a new event is appended or shutdown is set.
    cond: std.Io.Condition = .init,
    events: std.ArrayList(EventRecord) = .empty,
    next_seq: EventSeq = 1,
    shutdown: bool = false,

    pub fn append(self: *EventLog, event: Event) !EventSeq {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const seq = self.next_seq;
        self.next_seq += 1;
        try self.events.append(self.allocator, try EventRecord.clone(self.allocator, event, seq));
        self.cond.broadcast(self.io);
        return seq;
    }

    pub fn subscribe(self: *EventLog, from: SubscribeFrom) Subscription {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .next_seq = switch (from) {
            .beginning => 1,
            .tail => self.next_seq,
            .seq => |seq| seq,
        } };
    }

    /// Returns an owned clone of the next event record, blocking until
    /// available. Returns null on shutdown.
    pub fn recv(self: *EventLog, sub: *Subscription) !?EventRecord {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (sub.next_seq >= self.next_seq and !self.shutdown) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }

        if (sub.next_seq >= self.next_seq and self.shutdown) return null;

        if (sub.next_seq < self.next_seq) {
            const idx: usize = @intCast(sub.next_seq - 1);
            const record = self.events.items[idx];
            sub.next_seq = record.seq + 1;
            return try EventRecord.clone(self.allocator, record.event, record.seq);
        }
        return null;
    }

    pub fn peekNextSeq(self: *EventLog) EventSeq {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.next_seq;
    }

    pub fn signalShutdown(self: *EventLog) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown = true;
        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    pub fn deinit(self: *EventLog) void {
        for (self.events.items) |*record| record.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const Runtime = struct {
    allocator: Allocator,
    io: std.Io,
    client: *openai.Client,
    kernel: ToolKernel,
    config: RuntimeConfig,

    /// Protects `inbox`, `agents`, `shutdown`, and `next_agent_id`.
    /// Lock ordering: Runtime.mutex -> Agent.signal_mutex -> InboxItem.mutex.
    mutex: std.Io.Mutex = .init,
    /// Signaled when a new item is enqueued to `inbox` or `shutdown` is set.
    inbox_cond: std.Io.Condition = .init,
    runtime_thread: ?std.Thread = null,
    shutdown: bool = false,
    worker_group: std.Io.Group = .init,

    agents: std.AutoArrayHashMapUnmanaged(AgentId, *Agent) = .empty,
    event_log: EventLog,
    inbox: std.DoublyLinkedList = .{},
    next_agent_id: AgentId = 1,

    pub fn init(allocator: Allocator, io: std.Io, client: *openai.Client, kernel: ToolKernel, config: RuntimeConfig) Runtime {
        return .{
            .allocator = allocator,
            .io = io,
            .client = client,
            .kernel = kernel,
            .config = config,
            .event_log = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown = true;
        self.inbox_cond.broadcast(self.io);
        self.mutex.unlock(self.io);
        self.event_log.signalShutdown();

        // Send cancel signal to all agents so they exit their main loops.
        for (self.agents.values()) |agent| _ = self.deliverSignal(agent, .cancel);

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

    pub fn submitQuery(self: *Runtime, agent_id: ?AgentId, text: []const u8, priority: Priority) !SubmitReceipt {
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

    pub fn submitReply(self: *Runtime, agent_id: AgentId, syscall_id: SyscallId, text: []const u8) !SubmitReceipt {
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

    pub fn cancelAgent(self: *Runtime, agent_id: AgentId) !CancelReceipt {
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

    /// Kernel main loop: wait for interrupts and dispatch them as signals.
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

    /// Dispatch a single inbox item: either handle an external interrupt
    /// (with synchronous reply) or forward an internal interrupt as a signal.
    fn dispatchItem(self: *Runtime, item: *InboxItem) void {
        switch (item.msg) {
            .tool_done => |*msg| {
                if (self.dispatchToolDone(msg.*)) {
                    // Ownership of output transferred to agent signal queue.
                    msg.output = null;
                }
                item.deinit(self.allocator);
                self.allocator.destroy(item);
                return;
            },
            else => {},
        }

        const result: InboxItem.Result = switch (item.msg) {
            .submit_query => |*msg| blk: {
                const r = self.handleSubmitQuery(msg) catch |err|
                    break :blk .{ .err = mapSubmitError(err) };
                break :blk r;
            },
            .submit_reply => |*msg| blk: {
                const r = self.handleSubmitReply(msg) catch |err|
                    break :blk .{ .err = mapSubmitError(err) };
                break :blk r;
            },
            .cancel_agent => |msg| self.handleCancelAgent(msg) catch |err|
                .{ .cancel_err = mapCancelError(err) },
            .tool_done => unreachable,
        };
        item.mutex.lockUncancelable(self.io);
        item.result = result;
        item.done = true;
        item.cond.signal(self.io);
        item.mutex.unlock(self.io);
    }

    fn handleSubmitQuery(self: *Runtime, msg: *@FieldType(InboxItem.Msg, "submit_query")) !InboxItem.Result {
        const agent = if (msg.agent_id) |id|
            self.getAgent(id) orelse return error.UnknownAgent
        else
            try self.createAgent();

        const request_id = agent.next_request_id;
        agent.next_request_id += 1;
        const accepted_seq = try self.event_log.append(.{ .accepted = .{ .agent_id = agent.id, .request_id = request_id } });
        debugLog("submit_query agent={d} request={d}", .{ agent.id, request_id });

        // Ownership of text transfers to signal (or freed on delivery failure).
        _ = self.deliverSignal(agent, .{ .request = .{
            .id = request_id,
            .text = msg.text.?,
            .priority = msg.priority,
        } });
        msg.text = null;

        return .{ .ok = .{ .accepted_seq = accepted_seq, .agent_id = agent.id, .request_id = request_id } };
    }

    fn handleSubmitReply(self: *Runtime, msg: *@FieldType(InboxItem.Msg, "submit_reply")) !InboxItem.Result {
        const agent = self.getAgent(msg.agent_id) orelse return error.UnknownAgent;
        const accepted_seq = try self.event_log.append(.{ .accepted = .{ .agent_id = msg.agent_id, .request_id = null } });
        debugLog("submit_reply agent={d} syscall={d}", .{ msg.agent_id, msg.syscall_id });

        // Ownership of text transfers to signal (or freed on delivery failure).
        _ = self.deliverSignal(agent, .{ .tool_done = .{
            .syscall_id = msg.syscall_id,
            .output = msg.text.?,
            .ok = true,
            .detached = false,
        } });
        msg.text = null;

        return .{ .ok = .{ .accepted_seq = accepted_seq, .agent_id = msg.agent_id, .request_id = null } };
    }

    fn handleCancelAgent(self: *Runtime, msg: @FieldType(InboxItem.Msg, "cancel_agent")) !InboxItem.Result {
        const agent = self.getAgent(msg.agent_id) orelse return error.UnknownAgent;
        debugLog("cancel agent={d}", .{msg.agent_id});

        _ = self.deliverSignal(agent, .cancel);

        return .{ .cancel_ok = .{ .accepted_seq = self.event_log.peekNextSeq(), .agent_id = msg.agent_id } };
    }

    /// Returns true if ownership of msg.output was transferred to the agent.
    fn dispatchToolDone(self: *Runtime, msg: @FieldType(InboxItem.Msg, "tool_done")) bool {
        const agent = self.getAgent(msg.agent_id) orelse return false;
        return self.deliverSignal(agent, .{ .tool_done = .{
            .syscall_id = msg.syscall_id,
            .output = msg.output.?,
            .ok = msg.ok,
            .detached = msg.detached,
        } });
    }

    /// Returns true if signal was delivered (ownership transferred).
    /// On failure, owned payload is freed.
    fn deliverSignal(self: *Runtime, agent: *Agent, signal: Signal) bool {
        agent.signal_mutex.lockUncancelable(self.io);
        agent.signals.append(self.allocator, signal) catch {
            agent.signal_mutex.unlock(self.io);
            var sig = signal;
            sig.deinit(self.allocator);
            return false;
        };
        agent.signal_cond.signal(self.io);
        agent.signal_mutex.unlock(self.io);
        return true;
    }

    fn createAgent(self: *Runtime) !*Agent {
        const agent = try self.allocator.create(Agent);
        errdefer self.allocator.destroy(agent);
        agent.* = .{
            .id = self.next_agent_id,
            .runtime = self,
            .allocator = self.allocator,
        };
        errdefer agent.deinit(self.allocator);
        self.next_agent_id += 1;
        {
            const system_prompt = try self.allocator.dupe(u8, self.config.system_prompt);
            errdefer self.allocator.free(system_prompt);
            try agent.history.append(self.allocator, .{ .role = .system, .content = system_prompt });
        }
        try self.agents.put(self.allocator, agent.id, agent);

        // Spawn the agent's process.
        self.worker_group.concurrent(self.io, agentMain, .{agent}) catch |err| {
            _ = self.agents.fetchSwapRemove(agent.id);
            return err;
        };
        return agent;
    }

    fn getAgent(self: *Runtime, agent_id: AgentId) ?*Agent {
        return self.agents.get(agent_id);
    }

    fn spawnToolWorker(self: *Runtime, agent_id: AgentId, syscall_id: SyscallId, job: ToolJob, detached: bool) void {
        debugLog("spawn_tool_worker agent={d} syscall={d} detached={}", .{ agent_id, syscall_id, detached });
        const ctx = self.allocator.create(ToolWorkerCtx) catch {
            job.deinit(self.allocator);
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
            return;
        };
    }

};

// 5. Agent process main loop (= userspace execution).
//
// Each agent runs in its own concurrent context. It waits for request signals,
// then processes them by calling LLM and issuing syscalls for tools.

fn agentMain(agent: *Agent) std.Io.Cancelable!void {
    const runtime = agent.runtime;
    const allocator = agent.allocator;

    while (!runtime.shutdown) {
        // Wait for a request signal.
        var batch = agent.waitSignals();
        defer {
            for (batch.items) |*sig| sig.deinit(allocator);
            batch.deinit(allocator);
        }

        // Find the highest-priority request (interactive before background).
        var request: ?Request = null;
        var hi_requests: std.ArrayList(Request) = .empty;
        var lo_requests: std.ArrayList(Request) = .empty;
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
                        _ = runtime.event_log.append(.{ .tool_completed = .{
                            .agent_id = agent.id,
                            .syscall_id = td.syscall_id,
                            .output = td.output,
                            .ok = td.ok,
                        } }) catch {};
                        queueDetachedInterrupt(agent, td);
                    }
                },
                else => {},
            }
        }

        // Pick first interactive, then first background.
        if (hi_requests.items.len > 0) {
            request = hi_requests.orderedRemove(0);
        } else if (lo_requests.items.len > 0) {
            request = lo_requests.orderedRemove(0);
        }

        if (request == null) {
            if (runtime.shutdown) break;
            continue;
        }

        // Put remaining requests back into signal queue for later (ownership transfer).
        for (hi_requests.items) |*req| {
            _ = runtime.deliverSignal(agent, .{ .request = .{
                .id = req.id,
                .text = req.text,
                .priority = req.priority,
            } });
            req.text = null;
        }
        for (lo_requests.items) |*req| {
            _ = runtime.deliverSignal(agent, .{ .request = .{
                .id = req.id,
                .text = req.text,
                .priority = req.priority,
            } });
            req.text = null;
        }

        var req = request.?;
        defer req.deinit(allocator);
        processRequest(agent, &req) catch |err| {
            _ = runtime.event_log.append(.{ .fault = .{ .agent_id = agent.id, .message = @errorName(err) } }) catch {};
            _ = runtime.event_log.append(.{ .finished = .{ .agent_id = agent.id, .request_id = req.id, .final_text = @errorName(err) } }) catch {};
        };
    }
}

/// Process a single request: call LLM in a loop, handle tool calls via syscalls.
fn processRequest(agent: *Agent, request: *const Request) !void {
    const runtime = agent.runtime;
    const allocator = agent.allocator;

    try agent.history.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, request.text.?) });
    _ = try runtime.event_log.append(.{ .started = .{ .agent_id = agent.id, .request_id = request.id } });
    debugLog("start_request agent={d} request={d}", .{ agent.id, request.id });

    var turn: u32 = 0;
    while (turn < runtime.config.max_turns) : (turn += 1) {
        // Check for cancel before LLM call.
        if (checkCancel(agent)) {
            return finishRequest(agent, request.id, "[CANCELED]");
        }

        // Call LLM (synchronous in this agent's concurrent context).
        const response = callLlm(agent) catch |err| {
            return finishRequest(agent, request.id, @errorName(err));
        };
        defer {
            var resp = response;
            resp.deinit(allocator);
        }

        // No tool calls → finished.
        if (response.tool_calls.len == 0) {
            const content = try allocator.dupe(u8, response.content);
            errdefer allocator.free(content);
            try agent.history.append(allocator, .{ .role = .assistant, .content = content });
            _ = try runtime.event_log.append(.{ .finished = .{ .agent_id = agent.id, .request_id = request.id, .final_text = response.content } });
            debugLog("finished agent={d} request={d}", .{ agent.id, request.id });
            return;
        }

        // Record assistant message with tool calls in history.
        const assistant_calls = try llm.cloneToolCallsOwnedSlice(allocator, response.tool_calls);
        errdefer llm.freeToolCallsOwned(allocator, assistant_calls);
        try agent.history.append(allocator, .{ .role = .assistant, .content = null, .tool_calls = assistant_calls });

        // Execute each tool call (syscall).
        for (response.tool_calls) |tc| {
            if (checkCancel(agent)) {
                return finishRequest(agent, request.id, "[CANCELED]");
            }
            try executeSyscall(agent, request.id, tc);
        }
    }

    // Max turns exceeded.
    try finishRequest(agent, request.id, "[MAX_TURNS_EXCEEDED]");
}

fn recordToolResult(agent: *Agent, syscall_id: SyscallId, tc_id: []const u8, output: []const u8, ok: bool) !void {
    const allocator = agent.allocator;
    try agent.history.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, output),
        .tool_call_id = try allocator.dupe(u8, tc_id),
    });
    _ = try agent.runtime.event_log.append(.{ .tool_completed = .{
        .agent_id = agent.id,
        .syscall_id = syscall_id,
        .output = output,
        .ok = ok,
    } });
}

/// Issue a syscall for a single tool call and wait for the result.
fn executeSyscall(agent: *Agent, request_id: RequestId, tc: openai.ToolCallOwned) !void {
    const runtime = agent.runtime;
    const allocator = agent.allocator;
    const syscall_id = agent.nextSyscallId();

    _ = try runtime.event_log.append(.{ .tool_started = .{ .agent_id = agent.id, .syscall_id = syscall_id, .name = tc.name } });

    var start_result = runtime.kernel.start(tc.name, tc.arguments_json, allocator) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "tool `{s}` failed to start: {s}", .{ tc.name, @errorName(err) });
        defer allocator.free(msg);
        try recordToolResult(agent, syscall_id, tc.id, msg, false);
        return;
    };

    switch (start_result) {
        .ready => |output| {
            defer allocator.free(output);
            try recordToolResult(agent, syscall_id, tc.id, output, true);
            start_result = undefined;
        },
        .wait => |wait| {
            switch (wait) {
                .worker => |job| {
                    _ = try runtime.event_log.append(.{ .tool_waiting = .{ .agent_id = agent.id, .syscall_id = syscall_id } });
                    runtime.spawnToolWorker(agent.id, syscall_id, job, false);
                },
                .user => |user_wait| {
                    _ = try runtime.event_log.append(.{ .waiting_user = .{ .agent_id = agent.id, .syscall_id = syscall_id, .question = user_wait.question } });
                    allocator.free(user_wait.question);
                    start_result = undefined;
                },
            }
            const result = waitToolDone(agent, syscall_id, request_id);
            defer allocator.free(result.output);
            try recordToolResult(agent, syscall_id, tc.id, result.output, result.ok);
        },
        .detach => |det| {
            _ = try runtime.event_log.append(.{ .tool_detached = .{ .agent_id = agent.id, .syscall_id = syscall_id, .ack = det.ack } });
            defer allocator.free(det.ack);
            try recordToolResult(agent, syscall_id, tc.id, det.ack, true);
            runtime.spawnToolWorker(agent.id, syscall_id, det.job, true);
            start_result = undefined;
        },
    }
}

/// Wait for a tool_done signal matching the given syscall_id.
/// Detached completions for other syscalls are queued as pending interrupts.
fn waitToolDone(agent: *Agent, target_syscall_id: SyscallId, request_id: RequestId) struct { output: []u8, ok: bool } {
    const runtime = agent.runtime;
    const allocator = agent.allocator;
    _ = request_id;

    while (true) {
        var batch = agent.waitSignals();
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
                    // Detached completion for another syscall: emit event + re-queue as request.
                    if (td.detached) {
                        _ = runtime.event_log.append(.{ .tool_completed = .{ .agent_id = agent.id, .syscall_id = td.syscall_id, .output = td.output, .ok = td.ok } }) catch {};
                        queueDetachedInterrupt(agent, td);
                    }
                },
                .cancel => {
                    const output = allocator.dupe(u8, "[CANCELED]") catch
                        return .{ .output = &.{}, .ok = false };
                    return .{ .output = output, .ok = false };
                },
                .request => |*req| {
                    // Re-queue requests that arrive while waiting (ownership transfer).
                    _ = runtime.deliverSignal(agent, .{ .request = .{
                        .id = req.id,
                        .text = req.text,
                        .priority = req.priority,
                    } });
                    req.text = null;
                },
            }
        }
    }
}

fn queueDetachedInterrupt(agent: *Agent, td: @FieldType(Signal, "tool_done")) void {
    const allocator = agent.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    out.writer.print("[DETACHED INTERRUPT] syscall {d} [{s}]\n{s}", .{
        td.syscall_id,
        if (td.ok) "ok" else "failed",
        td.output,
    }) catch return;

    const text = out.toOwnedSlice() catch return;
    const request_id = agent.next_request_id;
    agent.next_request_id += 1;
    _ = agent.runtime.deliverSignal(agent, .{ .request = .{
        .id = request_id,
        .text = text,
        .priority = .interactive,
    } });
}

/// Check for cancel signals without blocking.
fn checkCancel(agent: *Agent) bool {
    var batch = agent.drainSignals();
    defer {
        for (batch.items) |*sig| sig.deinit(agent.allocator);
        batch.deinit(agent.allocator);
    }

    var cancelled = false;
    for (batch.items) |*sig| {
        switch (sig.*) {
            .cancel => {
                cancelled = true;
            },
            .request => |*req| {
                _ = agent.runtime.deliverSignal(agent, .{ .request = .{
                    .id = req.id,
                    .text = req.text,
                    .priority = req.priority,
                } });
                req.text = null;
            },
            else => {},
        }
    }
    return cancelled;
}

fn finishRequest(agent: *Agent, request_id: RequestId, reason: []const u8) !void {
    _ = try agent.runtime.event_log.append(.{ .fault = .{ .agent_id = agent.id, .message = reason } });
    _ = try agent.runtime.event_log.append(.{ .finished = .{ .agent_id = agent.id, .request_id = request_id, .final_text = reason } });
}

/// Call LLM synchronously, streaming deltas as events.
fn callLlm(agent: *Agent) !openai.ChatResponse {
    const runtime = agent.runtime;
    const allocator = agent.allocator;

    var message_views: std.ArrayList(llm.MessageView) = .empty;
    defer message_views.deinit(allocator);
    try message_views.ensureUnusedCapacity(allocator, agent.history.items.len);
    for (agent.history.items) |*msg| message_views.appendAssumeCapacity(msg.asView());

    var stream = try runtime.client.chatStream(message_views.items, runtime.config.tools_json);
    defer stream.deinit();
    debugLog("llm_call agent={d}", .{agent.id});

    while (true) {
        const event_opt = try stream.next();
        if (event_opt) |event| switch (event) {
            .content_delta => |delta| {
                _ = runtime.event_log.append(.{ .assistant_delta = .{ .agent_id = agent.id, .text = delta } }) catch {};
            },
            .finished => {},
        } else break;
    }

    return try stream.takeResponseOwned();
}

// 6. Tool worker (= kernel thread for executing syscalls).

const ToolWorkerCtx = struct {
    runtime: *Runtime,
    allocator: Allocator,
    agent_id: AgentId,
    syscall_id: SyscallId,
    job: ToolJob,
    detached: bool,

    fn deinit(self: *ToolWorkerCtx) void {
        self.job.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

fn toolWorkerMain(ctx: *ToolWorkerCtx) std.Io.Cancelable!void {
    defer ctx.deinit();

    var ok = true;
    debugLog("tool_worker_main agent={d} syscall={d}", .{ ctx.agent_id, ctx.syscall_id });
    const output = ctx.job.run(ctx.allocator) catch |err| blk: {
        ok = false;
        break :blk std.fmt.allocPrint(ctx.allocator, "tool worker failed: {s}", .{@errorName(err)}) catch return;
    };

    enqueueToolDone(ctx.runtime, ctx.allocator, .{
        .agent_id = ctx.agent_id,
        .syscall_id = ctx.syscall_id,
        .output = output,
        .ok = ok,
        .detached = ctx.detached,
    });
}

fn enqueueToolDone(runtime: *Runtime, allocator: Allocator, msg: @FieldType(InboxItem.Msg, "tool_done")) void {
    const item = allocator.create(InboxItem) catch {
        if (msg.output) |o| allocator.free(o);
        return;
    };
    item.* = .{ .msg = .{ .tool_done = msg } };

    runtime.mutex.lockUncancelable(runtime.io);
    if (runtime.shutdown) {
        runtime.mutex.unlock(runtime.io);
        item.deinit(allocator);
        allocator.destroy(item);
        return;
    }
    runtime.inbox.append(&item.node);
    runtime.inbox_cond.signal(runtime.io);
    runtime.mutex.unlock(runtime.io);
}

fn mapSubmitError(err: anyerror) SubmitError {
    return switch (err) {
        error.RuntimeShutdown => error.RuntimeShutdown,
        error.UnknownAgent => error.UnknownAgent,
        error.AgentNotWaitingUser => error.AgentNotWaitingUser,
        else => error.OutOfMemory,
    };
}

fn mapCancelError(err: anyerror) CancelError {
    return switch (err) {
        error.RuntimeShutdown => error.RuntimeShutdown,
        error.UnknownAgent => error.UnknownAgent,
        else => error.OutOfMemory,
    };
}
