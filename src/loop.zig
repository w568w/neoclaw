const std = @import("std");

const Allocator = std.mem.Allocator;

const loop_debug_enabled = false;

pub fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (!loop_debug_enabled) return;
    std.debug.print("[loop] " ++ fmt ++ "\n", args);
}

// 1. Shared IDs and public API types.

pub const EventSeq = u64;
pub const AgentId = u64;
pub const TriggerId = u64;
pub const SyscallId = u64;

/// A monotonically increasing ID allocator. IDs start at 1; 0 is never issued.
pub fn IdPool(Id: type) type {
    return struct {
        next: Id = 1,

        pub fn allocate(self: *@This()) Id {
            const id = self.next;
            self.next += 1;
            return id;
        }
    };
}

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
    /// The `io` parameter enables cancelable I/O within the tool.
    runFn: *const fn (ptr: *anyopaque, allocator: Allocator, io: std.Io) anyerror![]const u8,
    /// Releases the job payload.
    deinitFn: *const fn (ptr: *anyopaque, allocator: Allocator) void,

    pub fn run(self: ToolJob, allocator: Allocator, io: std.Io) ![]const u8 {
        return self.runFn(self.ptr, allocator, io);
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

// 2. Event log model.

pub const Event = union(enum) {
    accepted: struct {
        agent_id: AgentId,
        trigger_id: ?TriggerId,
    },
    started: struct {
        agent_id: AgentId,
        trigger_id: ?TriggerId,
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
    message_incomplete: struct {
        agent_id: AgentId,
        trigger_id: ?TriggerId,
        partial_content: []const u8,
    },
    tool_cancelled: struct {
        agent_id: AgentId,
        syscall_id: SyscallId,
    },
    finished: struct {
        agent_id: AgentId,
        trigger_id: ?TriggerId,
        final_text: []const u8,
    },
    fault: struct {
        agent_id: ?AgentId,
        message: []const u8,
    },

    pub fn cloneOwned(event: Event, allocator: Allocator) !Event {
        return switch (event) {
            .accepted => |ev| .{ .accepted = ev },
            .started => |ev| .{ .started = ev },
            .assistant_delta => |ev| .{ .assistant_delta = .{ .agent_id = ev.agent_id, .text = try allocator.dupe(u8, ev.text) } },
            .tool_started => |ev| .{ .tool_started = .{ .agent_id = ev.agent_id, .syscall_id = ev.syscall_id, .name = try allocator.dupe(u8, ev.name) } },
            .tool_waiting => |ev| .{ .tool_waiting = ev },
            .tool_detached => |ev| .{ .tool_detached = .{ .agent_id = ev.agent_id, .syscall_id = ev.syscall_id, .ack = try allocator.dupe(u8, ev.ack) } },
            .tool_completed => |ev| .{ .tool_completed = .{ .agent_id = ev.agent_id, .syscall_id = ev.syscall_id, .output = try allocator.dupe(u8, ev.output), .ok = ev.ok } },
            .waiting_user => |ev| .{ .waiting_user = .{ .agent_id = ev.agent_id, .syscall_id = ev.syscall_id, .question = try allocator.dupe(u8, ev.question) } },
            .message_incomplete => |ev| .{ .message_incomplete = .{ .agent_id = ev.agent_id, .trigger_id = ev.trigger_id, .partial_content = try allocator.dupe(u8, ev.partial_content) } },
            .tool_cancelled => |ev| .{ .tool_cancelled = ev },
            .finished => |ev| .{ .finished = .{ .agent_id = ev.agent_id, .trigger_id = ev.trigger_id, .final_text = try allocator.dupe(u8, ev.final_text) } },
            .fault => |ev| .{ .fault = .{ .agent_id = ev.agent_id, .message = try allocator.dupe(u8, ev.message) } },
        };
    }

    pub fn deinit(self: *Event, allocator: Allocator) void {
        switch (self.*) {
            .accepted => {},
            .started => {},
            .assistant_delta => |ev| allocator.free(ev.text),
            .tool_started => |ev| allocator.free(ev.name),
            .tool_waiting => {},
            .tool_detached => |ev| allocator.free(ev.ack),
            .tool_completed => |ev| allocator.free(ev.output),
            .waiting_user => |ev| allocator.free(ev.question),
            .message_incomplete => |ev| allocator.free(ev.partial_content),
            .tool_cancelled => {},
            .finished => |ev| allocator.free(ev.final_text),
            .fault => |ev| allocator.free(ev.message),
        }
        self.* = undefined;
    }
};

pub const EventRecord = struct {
    seq: EventSeq,
    event: Event,

    pub fn clone(allocator: Allocator, event: Event, seq: EventSeq) !EventRecord {
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
    trigger_id: ?TriggerId,
};

pub const CancelReceipt = struct {
    accepted_seq: EventSeq,
    agent_id: AgentId,
};

pub const SubmitError = error{
    RuntimeShutdown,
    UnknownAgent,
    AgentNotWaitingUser,
    OutOfMemory,
};

pub const CancelError = error{
    RuntimeShutdown,
    UnknownAgent,
    OutOfMemory,
};

// 3. Mail protocol (kernel -> userspace communication).

pub const Request = struct {
    id: TriggerId,
    text: ?[]const u8,
    priority: Priority,

    /// Takes ownership of the text field, returning it and clearing the field.
    pub fn takeText(self: *Request) ?[]const u8 {
        const t = self.text;
        self.text = null;
        return t;
    }

    pub fn deinit(self: *Request, allocator: Allocator) void {
        if (self.text) |t| allocator.free(t);
        self.* = undefined;
    }
};

pub const Mail = union(enum) {
    request: Request,
    tool_done: struct {
        syscall_id: SyscallId,
        output: []const u8,
        ok: bool,
        detached: bool,
    },

    pub fn deinit(self: *Mail, allocator: Allocator) void {
        switch (self.*) {
            .request => |*req| req.deinit(allocator),
            .tool_done => |td| allocator.free(td.output),
        }
        self.* = undefined;
    }
};

// 4. Kernel services interface (userspace -> kernel syscall boundary).

pub const KernelServices = struct {
    ctx: *anyopaque,
    io: std.Io,

    emitEventFn: *const fn (ctx: *anyopaque, event: Event) anyerror!EventSeq,
    startToolFn: *const fn (ctx: *anyopaque, tool_name: []const u8, args_json: []const u8, allocator: Allocator) anyerror!ToolStartResult,
    spawnToolWorkerFn: *const fn (ctx: *anyopaque, agent_id: AgentId, syscall_id: SyscallId, job: ToolJob, detached: bool) void,
    cancelToolFn: *const fn (ctx: *anyopaque, syscall_id: SyscallId) void,
    isShutdownFn: *const fn (ctx: *anyopaque) bool,

    // Emits an event to the kernel.
    // The `event` is cloned and owned by the kernel, so the caller can safely free any buffers after this call returns.
    pub fn emitEvent(self: KernelServices, event: Event) !EventSeq {
        return self.emitEventFn(self.ctx, event);
    }

    pub fn startTool(self: KernelServices, tool_name: []const u8, args_json: []const u8, allocator: Allocator) !ToolStartResult {
        return self.startToolFn(self.ctx, tool_name, args_json, allocator);
    }

    pub fn spawnToolWorker(self: KernelServices, agent_id: AgentId, syscall_id: SyscallId, job: ToolJob, detached: bool) void {
        self.spawnToolWorkerFn(self.ctx, agent_id, syscall_id, job, detached);
    }

    pub fn cancelTool(self: KernelServices, syscall_id: SyscallId) void {
        self.cancelToolFn(self.ctx, syscall_id);
    }

    pub fn isShutdown(self: KernelServices) bool {
        return self.isShutdownFn(self.ctx);
    }
};

// 5. Event log.

pub const RuntimeConfig = struct {
    system_prompt: []const u8,
    tools_json: ?[]const u8,
    max_turns: u32,
};

pub const EventLog = struct {
    allocator: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    events: std.ArrayList(EventRecord) = .empty,
    seqs: IdPool(EventSeq) = .{},
    shutdown: bool = false,

    pub fn append(self: *EventLog, event: Event) !EventSeq {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const seq = self.seqs.allocate();
        try self.events.append(self.allocator, try EventRecord.clone(self.allocator, event, seq));
        self.cond.broadcast(self.io);
        return seq;
    }

    pub fn subscribe(self: *EventLog, from: SubscribeFrom) Subscription {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .next_seq = switch (from) {
            .beginning => 1,
            .tail => self.seqs.next,
            .seq => |seq| seq,
        } };
    }

    /// Receives the next event for a subscription, blocking until an event is available.
    /// This method is cancelable.
    pub fn recv(self: *EventLog, sub: *Subscription) !?EventRecord {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (sub.next_seq >= self.seqs.next and !self.shutdown) {
            try self.cond.wait(self.io, &self.mutex);
        }

        if (sub.next_seq >= self.seqs.next and self.shutdown) return null;

        if (sub.next_seq < self.seqs.next) {
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
        return self.seqs.next;
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

// 6. Re-exports: userspace and kernel.

pub const Mailbox = @import("loop/mailbox.zig").Mailbox;
pub const Agent = @import("loop/agent.zig").Agent;
pub const Runtime = @import("loop/runtime.zig").Runtime;
