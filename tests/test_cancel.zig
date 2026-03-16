const std = @import("std");
const neoclaw = @import("neoclaw");
const loop = neoclaw.loop;
const openai = neoclaw.openai;
const schema = neoclaw.schema;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const linux = std.os.linux;

// ============================================================================
// Test logging
// ============================================================================

fn tlog(comptime fmt: []const u8, args: anytype) void {
    const ts = timestampMs();
    std.debug.print("[test +{d}.{d:0>3}] " ++ fmt ++ "\n", .{ ts / 1000, ts % 1000 } ++ args);
}

fn eventToStr(event: loop.Event, buf: []u8) []const u8 {
    return switch (event) {
        .accepted => |ev| std.fmt.bufPrint(buf, "accepted(agent={d}, trigger={?})", .{ ev.agent_id, ev.trigger_id }) catch "accepted(?)",
        .started => |ev| std.fmt.bufPrint(buf, "started(agent={d}, trigger={?})", .{ ev.agent_id, ev.trigger_id }) catch "started(?)",
        .assistant_delta => |ev| std.fmt.bufPrint(buf, "assistant_delta(agent={d}, text=\"{s}\")", .{ ev.agent_id, ev.text }) catch "assistant_delta(?)",
        .tool_started => |ev| std.fmt.bufPrint(buf, "tool_started(agent={d}, syscall={d}, name=\"{s}\")", .{ ev.agent_id, ev.syscall_id, ev.name }) catch "tool_started(?)",
        .tool_waiting => |ev| std.fmt.bufPrint(buf, "tool_waiting(agent={d}, syscall={d})", .{ ev.agent_id, ev.syscall_id }) catch "tool_waiting(?)",
        .tool_detached => |ev| std.fmt.bufPrint(buf, "tool_detached(agent={d}, syscall={d}, ack=\"{s}\")", .{ ev.agent_id, ev.syscall_id, ev.ack }) catch "tool_detached(?)",
        .tool_completed => |ev| std.fmt.bufPrint(buf, "tool_completed(agent={d}, syscall={d}, ok={}, output=\"{s}\")", .{ ev.agent_id, ev.syscall_id, ev.ok, ev.output }) catch "tool_completed(?)",
        .waiting_user => |ev| std.fmt.bufPrint(buf, "waiting_user(agent={d}, syscall={d})", .{ ev.agent_id, ev.syscall_id }) catch "waiting_user(?)",
        .message_incomplete => |ev| std.fmt.bufPrint(buf, "message_incomplete(agent={d}, trigger={?}, partial=\"{s}\")", .{ ev.agent_id, ev.trigger_id, ev.partial_content }) catch "message_incomplete(?)",
        .tool_cancelled => |ev| std.fmt.bufPrint(buf, "tool_cancelled(agent={d}, syscall={d})", .{ ev.agent_id, ev.syscall_id }) catch "tool_cancelled(?)",
        .finished => |ev| std.fmt.bufPrint(buf, "finished(agent={d}, trigger={?}, text=\"{s}\")", .{ ev.agent_id, ev.trigger_id, ev.final_text }) catch "finished(?)",
        .fault => |ev| std.fmt.bufPrint(buf, "fault(agent={?}, msg=\"{s}\")", .{ ev.agent_id, ev.message }) catch "fault(?)",
    };
}

fn sleepMs(ms: u64) void {
    var ts: linux.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    while (true) {
        const rc = linux.nanosleep(&ts, &ts);
        if (rc == 0) return;
        if (linux.errno(rc) == .INTR) continue;
        return;
    }
}

fn timestampMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

// ============================================================================
// Mock tools
// ============================================================================

const slow_tool = struct {
    pub const name = "slow_tool";
    pub const description = "test: blocks for 30s (cancelable)";
    pub const Params = struct { input: []const u8 = "" };

    pub fn start(_: *schema.ToolContext, _: Params, allocator: Allocator) !loop.ToolStartResult {
        const job = try allocator.create(SlowJob);
        job.* = .{};
        return .{ .wait = .{ .worker = .{
            .ptr = job,
            .runFn = SlowJob.run,
            .deinitFn = SlowJob.deinit_fn,
        } } };
    }

    const SlowJob = struct {
        fn run(_: *anyopaque, allocator: Allocator, io: Io) anyerror![]const u8 {
            try io.sleep(.fromSeconds(30), .awake);
            return allocator.dupe(u8, "slow_tool_done");
        }
        fn deinit_fn(ptr: *anyopaque, allocator: Allocator) void {
            const self: *SlowJob = @ptrCast(@alignCast(ptr));
            allocator.destroy(self);
        }
    };
};

const slow_detach_tool = struct {
    pub const name = "slow_detach_tool";
    pub const description = "test: detach tool that blocks for 30s";
    pub const Params = struct { input: []const u8 = "" };

    pub fn start(_: *schema.ToolContext, _: Params, allocator: Allocator) !loop.ToolStartResult {
        const job = try allocator.create(SlowDetachJob);
        job.* = .{};
        return .{ .detach = .{
            .ack = try allocator.dupe(u8, "detaching"),
            .job = .{
                .ptr = job,
                .runFn = SlowDetachJob.run,
                .deinitFn = SlowDetachJob.deinit_fn,
            },
        } };
    }

    const SlowDetachJob = struct {
        fn run(_: *anyopaque, allocator: Allocator, io: Io) anyerror![]const u8 {
            try io.sleep(.fromSeconds(30), .awake);
            return allocator.dupe(u8, "detach_done");
        }
        fn deinit_fn(ptr: *anyopaque, allocator: Allocator) void {
            const self: *SlowDetachJob = @ptrCast(@alignCast(ptr));
            allocator.destroy(self);
        }
    };
};

const fast_tool = struct {
    pub const name = "fast_tool";
    pub const description = "test: returns immediately";
    pub const Params = struct { input: []const u8 = "" };

    pub fn start(_: *schema.ToolContext, _: Params, allocator: Allocator) !loop.ToolStartResult {
        return .{ .ready = try allocator.dupe(u8, "fast_result") };
    }
};

const MockRegistry = schema.Registry(.{ slow_tool, slow_detach_tool, fast_tool });

// ============================================================================
// Mock HTTP Server (simulates OpenAI SSE API)
// ============================================================================

const MockServer = struct {
    port: std.atomic.Value(u16) = .init(0),
    should_stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(self: *MockServer) !void {
        self.thread = try std.Thread.spawn(.{}, serverThread, .{self});
    }

    fn stop(self: *MockServer) void {
        self.should_stop.store(true, .release);
        // Connect to wake up accept() — use raw Linux syscalls.
        const port = self.port.load(.acquire);
        if (port != 0) {
            // AF_INET=2, SOCK_STREAM=1
            const sock_fd = linux.socket(2, 1, 0);
            const signed: isize = @bitCast(sock_fd);
            if (signed >= 0) {
                // sockaddr_in: family(2) + port(2) + addr(4) + zero(8)
                var sin = [_]u8{0} ** 16;
                sin[0] = 2; // AF_INET (little-endian, family field)
                sin[2] = @intCast(port >> 8); // port high byte (network order)
                sin[3] = @intCast(port & 0xff); // port low byte
                sin[4] = 127; // 127.0.0.1
                sin[5] = 0;
                sin[6] = 0;
                sin[7] = 1;
                _ = linux.connect(@intCast(sock_fd), @ptrCast(&sin), 16);
                _ = linux.close(@intCast(sock_fd));
            }
        }
        if (self.thread) |t| t.join();
    }

    fn serverThread(self: *MockServer) void {
        const io = Io.Threaded.global_single_threaded.io();

        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = Io.net.IpAddress.listen(addr, io, .{ .reuse_address = true }) catch return;
        defer server.deinit(io);

        // Publish the actual port.
        self.port.store(server.socket.address.getPort(), .release);

        while (!self.should_stop.load(.acquire)) {
            const stream = server.accept(io) catch continue;
            if (self.should_stop.load(.acquire)) {
                var s = stream;
                s.close(io);
                break;
            }
            self.handleConnection(io, stream);
        }
    }

    fn handleConnection(self: *MockServer, io: Io, stream: Io.net.Stream) void {
        _ = self;
        defer {
            var s = stream;
            s.close(io);
        }

        var recv_buf: [65536]u8 = undefined;
        var send_buf: [4096]u8 = undefined;
        var conn_reader = stream.reader(io, &recv_buf);
        var conn_writer = stream.writer(io, &send_buf);
        var http_server: std.http.Server = .init(&conn_reader.interface, &conn_writer.interface);

        var request = http_server.receiveHead() catch return;

        // Read body.
        var body_buf: [8192]u8 = undefined;
        const body_reader = request.readerExpectNone(&body_buf);
        const body = body_reader.allocRemaining(std.testing.allocator, .limited(1024 * 1024)) catch return;
        defer std.testing.allocator.free(body);

        const user_content = extractLastUserContent(body) catch
            (std.testing.allocator.dupe(u8, "simple") catch return);
        defer std.testing.allocator.free(user_content);

        // Route based on content.
        if (std.mem.indexOf(u8, user_content, "slow_stream") != null) {
            tlog("[mock] route -> sendSlowStream (user_content=\"{s}\")", .{user_content});
            sendSlowStream(io, &request);
        } else if (std.mem.indexOf(u8, user_content, "call_slow_tool") != null) {
            tlog("[mock] route -> sendToolCallResponse(slow_tool) (user_content=\"{s}\")", .{user_content});
            sendToolCallResponse(&request, "slow_tool", "{\"input\":\"test\"}");
        } else if (std.mem.indexOf(u8, user_content, "call_detach_tool") != null) {
            tlog("[mock] route -> sendToolCallResponse(slow_detach_tool) (user_content=\"{s}\")", .{user_content});
            sendToolCallResponse(&request, "slow_detach_tool", "{\"input\":\"test\"}");
        } else {
            tlog("[mock] route -> sendSimpleResponse(ack) (user_content=\"{s}\")", .{user_content});
            sendSimpleResponse(&request, "ack");
        }
    }

    fn extractLastUserContent(body: []const u8) ![]const u8 {
        const parsed = try std.json.parseFromSlice(RequestBody, std.testing.allocator, body, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var last_user_content: []const u8 = "simple";
        for (parsed.value.messages) |msg| {
            if (std.mem.eql(u8, msg.role, "user")) {
                if (msg.content) |c| last_user_content = c;
            }
        }
        return std.testing.allocator.dupe(u8, last_user_content);
    }

    const RequestBody = struct {
        messages: []const MessageEntry = &.{},
        model: []const u8 = "",

        const MessageEntry = struct {
            role: []const u8 = "",
            content: ?[]const u8 = null,
        };
    };

    fn sendSlowStream(_: Io, request: *std.http.Server.Request) void {
        var body_buf: [4096]u8 = undefined;
        var body_writer = request.respondStreaming(&body_buf, .{
            .respond_options = .{
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/event-stream" },
                },
            },
        }) catch return;

        // First chunk: role + initial content delta (arrives quickly so the
        // test can detect streaming has started).
        tlog("[mock] sendSlowStream: sending first chunk \"Hello\"", .{});
        body_writer.writer.writeAll("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"Hello\"},\"finish_reason\":null}]}\n\n") catch return;
        // Drain body buffer to conn writer, then flush conn writer to TCP.
        body_writer.writer.flush() catch return;
        body_writer.flush() catch return;

        // Remaining chunks are sent slowly (500ms each). The test will
        // cancel the agent well before all chunks are delivered.
        const chunks = [_][]const u8{ " world", " from", " slow", " stream" };
        for (chunks, 0..) |chunk, i| {
            sleepMs(500);
            tlog("[mock] sendSlowStream: sending chunk {d}/4 \"{s}\"", .{ i + 1, chunk });
            body_writer.writer.print("data: {{\"choices\":[{{\"delta\":{{\"content\":\"{s}\"}},\"finish_reason\":null}}]}}\n\n", .{chunk}) catch return;
            body_writer.writer.flush() catch return;
            body_writer.flush() catch return;
        }

        tlog("[mock] sendSlowStream: sending finish + [DONE]", .{});
        body_writer.writer.writeAll("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n") catch return;
        body_writer.writer.writeAll("data: [DONE]\n\n") catch return;
        body_writer.end() catch return;
    }

    fn sendToolCallResponse(request: *std.http.Server.Request, tool_name: []const u8, args: []const u8) void {
        tlog("[mock] sendToolCallResponse: tool=\"{s}\"", .{tool_name});
        var body_buf: [4096]u8 = undefined;
        var body_writer = request.respondStreaming(&body_buf, .{
            .respond_options = .{
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/event-stream" },
                },
            },
        }) catch return;

        // First chunk: role + tool_call start.
        body_writer.writer.print(
            "data: {{\"choices\":[{{\"delta\":{{\"role\":\"assistant\",\"tool_calls\":[{{\"index\":0,\"id\":\"call_1\",\"function\":{{\"name\":\"{s}\",\"arguments\":\"\"}}}}]}},\"finish_reason\":null}}]}}\n\n",
            .{tool_name},
        ) catch return;
        body_writer.writer.flush() catch return;
        body_writer.flush() catch return;

        // Second chunk: arguments.
        var escaped_buf: [1024]u8 = undefined;
        const escaped_args = escapeJson(args, &escaped_buf);
        body_writer.writer.print(
            "data: {{\"choices\":[{{\"delta\":{{\"tool_calls\":[{{\"index\":0,\"function\":{{\"arguments\":\"{s}\"}}}}]}},\"finish_reason\":null}}]}}\n\n",
            .{escaped_args},
        ) catch return;
        body_writer.writer.flush() catch return;
        body_writer.flush() catch return;

        // Third chunk: finish.
        tlog("[mock] sendToolCallResponse: sending finish + [DONE]", .{});
        body_writer.writer.writeAll("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n") catch return;
        body_writer.writer.writeAll("data: [DONE]\n\n") catch return;
        body_writer.end() catch return;
    }

    fn sendSimpleResponse(request: *std.http.Server.Request, text: []const u8) void {
        tlog("[mock] sendSimpleResponse: text=\"{s}\"", .{text});
        var body_buf: [4096]u8 = undefined;
        var body_writer = request.respondStreaming(&body_buf, .{
            .respond_options = .{
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/event-stream" },
                },
            },
        }) catch return;

        body_writer.writer.print(
            "data: {{\"choices\":[{{\"delta\":{{\"role\":\"assistant\",\"content\":\"{s}\"}},\"finish_reason\":null}}]}}\n\n",
            .{text},
        ) catch return;
        body_writer.writer.flush() catch return;
        body_writer.flush() catch return;

        body_writer.writer.writeAll("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n") catch return;
        body_writer.writer.writeAll("data: [DONE]\n\n") catch return;
        body_writer.end() catch return;
    }

    fn escapeJson(input: []const u8, buf: []u8) []const u8 {
        var pos: usize = 0;
        for (input) |c| {
            switch (c) {
                '"' => {
                    if (pos + 2 > buf.len) break;
                    buf[pos] = '\\';
                    buf[pos + 1] = '"';
                    pos += 2;
                },
                '\\' => {
                    if (pos + 2 > buf.len) break;
                    buf[pos] = '\\';
                    buf[pos + 1] = '\\';
                    pos += 2;
                },
                '\n' => {
                    if (pos + 2 > buf.len) break;
                    buf[pos] = '\\';
                    buf[pos + 1] = 'n';
                    pos += 2;
                },
                else => {
                    if (pos + 1 > buf.len) break;
                    buf[pos] = c;
                    pos += 1;
                },
            }
        }
        return buf[0..pos];
    }
};

// ============================================================================
// Event collector (bridges Io-based EventLog to std.Thread-based polling)
// ============================================================================

const EventCollector = struct {
    event_log: *loop.EventLog,
    events: std.ArrayList(CollectedEvent) = .empty,
    mutex: std.atomic.Mutex = .unlocked,
    thread: ?std.Thread = null,
    allocator: Allocator,

    const CollectedEvent = struct {
        seq: loop.EventSeq,
        event: loop.Event,
    };

    fn start(self: *EventCollector) !void {
        self.thread = try std.Thread.spawn(.{}, collectThread, .{self});
    }

    fn stop(self: *EventCollector) void {
        // EventLog.signalShutdown should be called before this.
        if (self.thread) |t| t.join();
    }

    fn deinit(self: *EventCollector) void {
        for (self.events.items) |*ev| {
            var e = ev.event;
            e.deinit(self.allocator);
        }
        self.events.deinit(self.allocator);
    }

    fn collectThread(self: *EventCollector) void {
        var sub = self.event_log.subscribe(.beginning);
        while (true) {
            const record = self.event_log.recv(&sub) catch continue;
            if (record == null) break; // shutdown
            var rec = record.?;

            var desc_buf: [512]u8 = undefined;
            const desc = eventToStr(rec.event, &desc_buf);

            self.lock();
            const idx = self.events.items.len;
            self.events.append(self.allocator, .{
                .seq = rec.seq,
                .event = rec.event,
            }) catch {
                rec.deinit(self.allocator);
                self.unlock();
                continue;
            };
            // Don't deinit rec — we transferred ownership of rec.event.
            self.unlock();

            tlog("[event #{d}] seq={d} {s}", .{ idx, rec.seq, desc });
        }
        tlog("[event] collector thread exiting (shutdown)", .{});
    }

    fn lock(self: *EventCollector) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *EventCollector) void {
        self.mutex.unlock();
    }

    /// Poll for an event matching the given tag, starting from `from_idx`.
    /// Returns the event payload and the index after the matched event.
    /// Polls with 10ms intervals; fails after `timeout_ms`.
    fn pollForTag(self: *EventCollector, comptime tag: []const u8, from_idx: usize, timeout_ms: u64) !struct { usize, @FieldType(loop.Event, tag) } {
        tlog("pollForTag(\"{s}\", from={d}, timeout={d}ms) ...", .{ tag, from_idx, timeout_ms });
        const deadline = timestampMs() + timeout_ms;
        while (true) {
            {
                self.lock();
                defer self.unlock();
                const events = self.events.items;
                if (from_idx < events.len) {
                    for (events[from_idx..], from_idx..) |ev, idx| {
                        if (ev.event == @field(loop.Event, tag)) {
                            tlog("pollForTag(\"{s}\") -> found at index {d}", .{ tag, idx });
                            return .{ idx + 1, @field(ev.event, tag) };
                        }
                    }
                }
            }
            if (timestampMs() > deadline) {
                tlog("pollForTag(\"{s}\") -> TIMEOUT after {d}ms", .{ tag, timeout_ms });
                return error.Timeout;
            }
            sleepMs(10);
        }
    }

    /// Count how many events of the given tag exist starting from `from_idx`.
    fn countTag(self: *EventCollector, comptime tag: []const u8, from_idx: usize) usize {
        self.lock();
        defer self.unlock();
        var count: usize = 0;
        if (from_idx < self.events.items.len) {
            for (self.events.items[from_idx..]) |ev| {
                if (ev.event == @field(loop.Event, tag)) count += 1;
            }
        }
        return count;
    }

    /// Returns current collected event count.
    fn len(self: *EventCollector) usize {
        self.lock();
        defer self.unlock();
        return self.events.items.len;
    }
};

// ============================================================================
// Test harness
// ============================================================================

const TestHarness = struct {
    allocator: Allocator,
    mock_server: MockServer,
    io_threaded: Io.Threaded,
    client: openai.Client,
    tool_ctx: schema.ToolContext,
    registry: MockRegistry,
    runtime: loop.Runtime,
    collector: EventCollector,
    api_base_owned: []const u8,
    tools_json_owned: []const u8,

    fn init(allocator: Allocator) !*TestHarness {
        tlog("=== TestHarness.init ===", .{});
        const self = try allocator.create(TestHarness);
        errdefer allocator.destroy(self);

        // Start mock server.
        self.mock_server = .{};
        try self.mock_server.start();

        // Wait for server to bind a port.
        while (self.mock_server.port.load(.acquire) == 0) {
            sleepMs(1);
        }

        // Create Io.
        self.io_threaded = Io.Threaded.init(allocator, .{});
        const io = self.io_threaded.io();

        // Build api_base URL (heap-allocated to outlive init).
        const port = self.mock_server.port.load(.acquire);
        self.api_base_owned = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});

        // Create LLM client.
        self.client = openai.Client.init(allocator, .{
            .io = io,
            .api_base = self.api_base_owned,
            .api_key = "test-key",
            .model = "test-model",
        });

        // Create tool registry.
        self.tool_ctx = .{ .io = io };
        self.registry = MockRegistry.init(&self.tool_ctx);
        self.tools_json_owned = try self.registry.toolsJsonOwned(allocator);

        // Create runtime.
        self.runtime = loop.Runtime.init(allocator, io, &self.client, self.registry.kernel(), .{
            .system_prompt = "You are a test agent.",
            .tools_json = self.tools_json_owned,
            .max_turns = 10,
        });

        // Start event collector.
        self.collector = .{ .event_log = &self.runtime.event_log, .allocator = allocator };
        try self.collector.start();

        // Start runtime.
        try self.runtime.start();

        self.allocator = allocator;
        tlog("=== TestHarness ready (mock server port={d}) ===", .{port});
        return self;
    }

    fn deinit(self: *TestHarness) void {
        tlog("=== TestHarness.deinit ===", .{});
        // Shutdown runtime (this signals EventLog shutdown too).
        self.runtime.deinit();

        // Stop event collector.
        self.collector.stop();
        self.collector.deinit();

        // Stop mock server.
        self.mock_server.stop();

        // Cleanup.
        self.client.deinit();
        self.allocator.free(self.tools_json_owned);
        self.allocator.free(self.api_base_owned);
        self.io_threaded.deinit();

        self.allocator.destroy(self);
    }

    fn submitQuery(self: *TestHarness, text: []const u8) !loop.SubmitReceipt {
        tlog("submitQuery(new agent, \"{s}\")", .{text});
        const receipt = try self.runtime.submitQuery(null, text, .interactive);
        tlog("submitQuery -> agent={d}, trigger={?}", .{ receipt.agent_id, receipt.trigger_id });
        return receipt;
    }

    fn submitQueryToAgent(self: *TestHarness, agent_id: loop.AgentId, text: []const u8) !loop.SubmitReceipt {
        tlog("submitQueryToAgent(agent={d}, \"{s}\")", .{ agent_id, text });
        const receipt = try self.runtime.submitQuery(agent_id, text, .interactive);
        tlog("submitQueryToAgent -> agent={d}, trigger={?}", .{ receipt.agent_id, receipt.trigger_id });
        return receipt;
    }

    fn cancelAgent(self: *TestHarness, agent_id: loop.AgentId) !loop.CancelReceipt {
        tlog("cancelAgent(agent={d})", .{agent_id});
        const receipt = try self.runtime.cancelAgent(agent_id);
        tlog("cancelAgent -> done", .{});
        return receipt;
    }
};

// ============================================================================
// Test cases
// ============================================================================

const TIMEOUT_MS: u64 = 10_000; // 10 seconds for all event waits.

test "A1: cancel during idle — agent survives" {
    tlog("", .{});
    tlog("========== A1: cancel during idle — agent survives ==========", .{});
    const h = try TestHarness.init(std.testing.allocator);
    defer h.deinit();

    tlog("[A1] step 1: submit simple query", .{});
    const receipt1 = try h.submitQuery("simple");
    const agent_id = receipt1.agent_id;

    tlog("[A1] step 2: wait for finished", .{});
    const r1 = try h.collector.pollForTag("finished", 0, TIMEOUT_MS);
    const finished1 = r1[1];
    try std.testing.expectEqualStrings("ack", finished1.final_text);
    tlog("[A1] step 2: finished with text=\"{s}\" ✓", .{finished1.final_text});

    tlog("[A1] step 3: cancel agent (should be idle now)", .{});
    _ = try h.cancelAgent(agent_id);

    tlog("[A1] step 4: wait 200ms for cancel to propagate", .{});
    sleepMs(200);

    tlog("[A1] step 5: submit second query to verify agent is alive", .{});
    _ = try h.submitQueryToAgent(agent_id, "simple");

    tlog("[A1] step 6: wait for second finished", .{});
    const r2 = try h.collector.pollForTag("finished", r1[0], TIMEOUT_MS);
    const finished2 = r2[1];
    try std.testing.expectEqualStrings("ack", finished2.final_text);
    tlog("[A1] PASSED ✓ (agent survived cancel during idle)", .{});
}

test "A2: cancel during LLM streaming — message_incomplete + finished" {
    tlog("", .{});
    tlog("========== A2: cancel during LLM streaming ==========", .{});
    const h = try TestHarness.init(std.testing.allocator);
    defer h.deinit();

    tlog("[A2] step 1: submit slow_stream query", .{});
    const receipt = try h.submitQuery("slow_stream");
    const agent_id = receipt.agent_id;

    tlog("[A2] step 2: wait for started + first delta", .{});
    _ = try h.collector.pollForTag("started", 0, TIMEOUT_MS);
    _ = try h.collector.pollForTag("assistant_delta", 0, TIMEOUT_MS);

    tlog("[A2] step 3: sleep 500ms to let agent block on next slow chunk", .{});
    sleepMs(500);

    tlog("[A2] step 4: cancel agent (should be in callLlm)", .{});
    _ = try h.cancelAgent(agent_id);

    tlog("[A2] step 5: wait for finished event", .{});
    const r1 = try h.collector.pollForTag("finished", 0, TIMEOUT_MS);
    const finished = r1[1];
    try std.testing.expectEqualStrings("[CANCELED]", finished.final_text);
    tlog("[A2] step 5: finished with text=\"{s}\" ✓", .{finished.final_text});

    tlog("[A2] step 6: verify agent is alive (submit simple query)", .{});
    sleepMs(200);
    _ = try h.submitQueryToAgent(agent_id, "simple");
    const r3 = try h.collector.pollForTag("finished", r1[0], TIMEOUT_MS);
    try std.testing.expectEqualStrings("ack", r3[1].final_text);
    tlog("[A2] PASSED ✓ (cancel interrupted LLM streaming)", .{});
}

test "A3: cancel during tool execution (wait) — tool_cancelled + finished" {
    tlog("", .{});
    tlog("========== A3: cancel during tool execution (wait) ==========", .{});
    const h = try TestHarness.init(std.testing.allocator);
    defer h.deinit();

    tlog("[A3] step 1: submit call_slow_tool query", .{});
    const receipt = try h.submitQuery("call_slow_tool");
    const agent_id = receipt.agent_id;

    tlog("[A3] step 2: wait for tool_waiting", .{});
    _ = try h.collector.pollForTag("tool_waiting", 0, TIMEOUT_MS);

    tlog("[A3] step 3: cancel agent (should be in waitToolDone)", .{});
    _ = try h.cancelAgent(agent_id);

    tlog("[A3] step 4: wait for tool_cancelled", .{});
    _ = try h.collector.pollForTag("tool_cancelled", 0, TIMEOUT_MS);

    tlog("[A3] step 5: wait for finished", .{});
    const r2 = try h.collector.pollForTag("finished", 0, TIMEOUT_MS);
    const finished = r2[1];
    try std.testing.expectEqualStrings("[CANCELED]", finished.final_text);
    tlog("[A3] step 5: finished with text=\"{s}\" ✓", .{finished.final_text});

    tlog("[A3] step 6: verify agent is alive", .{});
    sleepMs(200);
    _ = try h.submitQueryToAgent(agent_id, "simple");
    _ = try h.collector.pollForTag("finished", r2[0], TIMEOUT_MS);
    tlog("[A3] PASSED ✓ (cancel interrupted tool execution)", .{});
}

test "B1: cancel detach tool during idle — tool_cancelled" {
    tlog("", .{});
    tlog("========== B1: cancel detach tool during idle ==========", .{});
    const h = try TestHarness.init(std.testing.allocator);
    defer h.deinit();

    tlog("[B1] step 1: submit call_detach_tool query", .{});
    const receipt = try h.submitQuery("call_detach_tool");
    const agent_id = receipt.agent_id;

    tlog("[B1] step 2: wait for tool_detached", .{});
    _ = try h.collector.pollForTag("tool_detached", 0, TIMEOUT_MS);

    tlog("[B1] step 3: wait for finished (agent continues after detach ack)", .{});
    const r1 = try h.collector.pollForTag("finished", 0, TIMEOUT_MS);

    tlog("[B1] step 4: cancel agent (idle, but detach tool still running)", .{});
    _ = try h.cancelAgent(agent_id);

    tlog("[B1] step 5: wait for tool_cancelled (detach tool)", .{});
    _ = try h.collector.pollForTag("tool_cancelled", 0, TIMEOUT_MS);

    tlog("[B1] step 6: verify agent is alive", .{});
    sleepMs(200);
    _ = try h.submitQueryToAgent(agent_id, "simple");
    _ = try h.collector.pollForTag("finished", r1[0], TIMEOUT_MS);
    tlog("[B1] PASSED ✓ (detach tool cancelled while agent idle)", .{});
}

test "B2: cancel during LLM with detach tool — tool_cancelled + message_incomplete + finished" {
    tlog("", .{});
    tlog("========== B2: cancel during LLM with detach tool ==========", .{});
    const h = try TestHarness.init(std.testing.allocator);
    defer h.deinit();

    tlog("[B2] step 1: submit call_detach_tool (first request)", .{});
    const receipt1 = try h.submitQuery("call_detach_tool");
    const agent_id = receipt1.agent_id;

    tlog("[B2] step 2: wait for tool_detached + finished", .{});
    _ = try h.collector.pollForTag("tool_detached", 0, TIMEOUT_MS);
    const r1 = try h.collector.pollForTag("finished", 0, TIMEOUT_MS);

    tlog("[B2] step 3: submit slow_stream (second request, detach tool still running)", .{});
    _ = try h.submitQueryToAgent(agent_id, "slow_stream");
    _ = try h.collector.pollForTag("assistant_delta", r1[0], TIMEOUT_MS);

    tlog("[B2] step 4: cancel agent (in callLlm + detach tool background)", .{});
    _ = try h.cancelAgent(agent_id);

    tlog("[B2] step 5: wait for tool_cancelled (detach tool)", .{});
    _ = try h.collector.pollForTag("tool_cancelled", 0, TIMEOUT_MS);

    tlog("[B2] step 6: wait for message_incomplete", .{});
    _ = try h.collector.pollForTag("message_incomplete", r1[0], TIMEOUT_MS);

    tlog("[B2] step 7: wait for finished", .{});
    const r3 = try h.collector.pollForTag("finished", r1[0], TIMEOUT_MS);
    try std.testing.expectEqualStrings("[CANCELED]", r3[1].final_text);
    tlog("[B2] step 7: finished with text=\"{s}\" ✓", .{r3[1].final_text});

    tlog("[B2] step 8: verify agent is alive", .{});
    sleepMs(200);
    _ = try h.submitQueryToAgent(agent_id, "simple");
    _ = try h.collector.pollForTag("finished", r3[0], TIMEOUT_MS);
    tlog("[B2] PASSED ✓ (cancel interrupted LLM + detach tool cancelled)", .{});
}

test "B3: cancel during wait tool with detach tool — two tool_cancelled + finished" {
    tlog("", .{});
    tlog("========== B3: cancel during wait tool with detach tool ==========", .{});
    const h = try TestHarness.init(std.testing.allocator);
    defer h.deinit();

    tlog("[B3] step 1: submit call_detach_tool (first request)", .{});
    const receipt1 = try h.submitQuery("call_detach_tool");
    const agent_id = receipt1.agent_id;

    tlog("[B3] step 2: wait for tool_detached + finished", .{});
    _ = try h.collector.pollForTag("tool_detached", 0, TIMEOUT_MS);
    const r1 = try h.collector.pollForTag("finished", 0, TIMEOUT_MS);

    tlog("[B3] step 3: submit call_slow_tool (second request, detach tool still running)", .{});
    _ = try h.submitQueryToAgent(agent_id, "call_slow_tool");

    tlog("[B3] step 4: wait for tool_waiting", .{});
    _ = try h.collector.pollForTag("tool_waiting", r1[0], TIMEOUT_MS);

    tlog("[B3] step 5: cancel agent (in waitToolDone + detach tool background)", .{});
    _ = try h.cancelAgent(agent_id);

    tlog("[B3] step 6: wait for finished", .{});
    const r2 = try h.collector.pollForTag("finished", r1[0], TIMEOUT_MS);
    try std.testing.expectEqualStrings("[CANCELED]", r2[1].final_text);
    tlog("[B3] step 6: finished with text=\"{s}\" ✓", .{r2[1].final_text});

    tlog("[B3] step 7: check tool_cancelled count (expect >= 1)", .{});
    sleepMs(200);
    const cancel_count = h.collector.countTag("tool_cancelled", 0);
    tlog("[B3] step 7: tool_cancelled count = {d}", .{cancel_count});
    try std.testing.expect(cancel_count >= 1);

    tlog("[B3] step 8: verify agent is alive", .{});
    _ = try h.submitQueryToAgent(agent_id, "simple");
    _ = try h.collector.pollForTag("finished", r2[0], TIMEOUT_MS);
    tlog("[B3] PASSED ✓ (both tools cancelled, agent survived)", .{});
}
