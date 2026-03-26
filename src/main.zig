const std = @import("std");
const builtin = @import("builtin");
const clap = @import("clap");
const Io = std.Io;

const neoclaw = @import("neoclaw");
const dotenv = @import("dotenv.zig");
const cacert = @import("generated/cacert.zig");
const LineEditor = @import("line_editor/editor.zig").LineEditor;
const Terminal = @import("line_editor/terminal.zig").Terminal;
const WebServer = neoclaw.webui.WebServer;

const SystemPromptFile = "NEOCLAW.md";
const MaxTurns: u32 = 40;
const DefaultWebUIPort: u16 = 3120;

const ToolRegistry = neoclaw.schema.Registry(.{
    neoclaw.tools.code_run,
    neoclaw.tools.file_read,
    neoclaw.tools.file_write,
    neoclaw.tools.ask_user,
});

const RunMode = enum { cli, webui };

const CliOptions = struct {
    mode: RunMode = .cli,
    port: u16 = DefaultWebUIPort,
};

const cli_params = clap.parseParamsComptime(
    \\-h, --help       Display this help and exit.
    \\-p, --port <u16> WebUI port (default: 3120).
    \\    --webui      Run in WebUI mode instead of CLI.
    \\
);

fn parseArgs(args: std.process.Args, io: Io) CliOptions {
    var diag: clap.Diagnostic = .{};
    var res = clap.parse(clap.Help, &cli_params, clap.parsers.default, args, .{
        .diagnostic = &diag,
        .allocator = std.heap.smp_allocator,
    }) catch |err| {
        diag.reportToFile(io, .stderr(), err) catch {};
        std.process.exit(1);
    };
    defer res.deinit();

    if (res.args.help != 0) {
        clap.helpToFile(io, .stdout(), clap.Help, &cli_params, .{}) catch {};
        std.process.exit(0);
    }

    return .{
        .mode = if (res.args.webui != 0) .webui else .cli,
        .port = res.args.port orelse DefaultWebUIPort,
    };
}

pub fn main(init: std.process.Init) !void {
    // Ctrl-C is handled via raw mode stdin (byte 0x03), not SIGINT.
    // Ignore SIGINT to prevent unclean termination during shutdown.
    ignoreSigint();

    const allocator = std.heap.smp_allocator;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const opts = parseArgs(init.minimal.args, io);

    try dotenv.loadInto(allocator, init.environ_map, init.io);

    const api_key = try getEnvOwned(allocator, init.environ_map, "OPENAI_API_KEY", null);
    defer allocator.free(api_key);
    const api_base = try getEnvOwned(allocator, init.environ_map, "OPENAI_API_BASE", "https://api.openai.com");
    defer allocator.free(api_base);
    const model = try getEnvOwned(allocator, init.environ_map, "OPENAI_MODEL", "gpt-4o-mini");
    defer allocator.free(model);
    const system_prompt = try loadSystemPrompt(allocator, io);
    defer allocator.free(system_prompt);

    var client = neoclaw.openai.Client.init(allocator, .{
        .io = io,
        .api_base = api_base,
        .api_key = api_key,
        .model = model,
    });
    defer client.deinit();

    try initCaBundle(&client.http_client, allocator, io);

    var tool_ctx = neoclaw.schema.ToolContext{ .io = io };
    var registry = ToolRegistry.init(&tool_ctx);
    const tools_json = try registry.toolsJsonOwned(allocator);
    defer allocator.free(tools_json);

    var runtime = neoclaw.loop.Runtime.init(allocator, io, &client, registry.kernel(), .{
        .system_prompt = system_prompt,
        .tools_json = tools_json,
        .max_turns = MaxTurns,
    });
    try runtime.start();
    defer runtime.deinit();

    switch (opts.mode) {
        .webui => try runWebUI(allocator, io, stdout, &runtime, opts.port),
        .cli => try runCli(allocator, stdout, &runtime),
    }
}

fn runWebUI(allocator: std.mem.Allocator, io: Io, stdout: *Io.Writer, runtime: *neoclaw.loop.Runtime, port: u16) !void {
    var web_server = WebServer.init(allocator, io, runtime, port);
    defer web_server.deinit();
    try web_server.start();

    try stdout.print("neoclaw webui running on http://localhost:{d}\n", .{port});
    try stdout.print("press Ctrl-C to stop\n", .{});
    try stdout.flush();

    // Main task blocks on stdin in raw mode, waiting for Ctrl-C.
    waitForCtrlC(io);
}

fn waitForCtrlC(io: Io) void {
    var terminal: Terminal = .{};
    const raw_ok = terminal.enableRawMode() catch false;
    if (!raw_ok) {
        // stdin is not a terminal (e.g. pipe, background process).
        // Sleep forever so the WebUI keeps serving without consuming the Io runtime.
        const sleep_timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(3600), .clock = .awake } };
        while (true) sleep_timeout.sleep(io) catch {};
    }
    defer terminal.disableRawMode();

    var buf: [16]u8 = undefined;
    var stdin_reader: Io.File.Reader = .initStreaming(.stdin(), io, &buf);
    const reader = &stdin_reader.interface;
    while (true) {
        const byte_ptr = reader.takeArray(1) catch return;
        if (byte_ptr[0] == 3) return; // Ctrl-C
    }
}

fn runCli(allocator: std.mem.Allocator, stdout: *Io.Writer, runtime: *neoclaw.loop.Runtime) !void {
    var editor = LineEditor.init(allocator);
    defer editor.deinit();

    var sub = runtime.event_log.subscribe(.tail);
    var current_agent_id: ?neoclaw.loop.AgentId = null;
    var client_query_ids: neoclaw.loop.IdPool(u64) = .{};

    try stdout.writeAll("neoclaw interactive chat\n");
    try stdout.writeAll("commands: /exit /quit /clear\n\n");

    while (true) {
        try stdout.flush();
        const line_opt = try editor.readLine("you> ");
        if (line_opt == null) break;
        const line = line_opt.?;
        defer allocator.free(line);

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "/exit") or std.mem.eql(u8, trimmed, "/quit")) break;

        if (std.mem.eql(u8, trimmed, "/clear")) {
            if (current_agent_id) |aid| _ = runtime.cancelAgent(aid) catch {};
            current_agent_id = null;
            sub = runtime.event_log.subscribe(.tail);
            try stdout.writeAll("[history cleared]\n\n");
            continue;
        }

        try editor.addHistory(trimmed);
        const client_query_id = client_query_ids.allocate();
        const receipt = try runtime.submitQuery(current_agent_id, client_query_id, trimmed, .interactive);
        current_agent_id = receipt.agent_id;

        try consumeUntilFinished(allocator, &editor, stdout, runtime, &sub, current_agent_id.?, receipt.trigger_id);
    }

    try stdout.writeAll("bye\n");
    try stdout.flush();
}

fn consumeUntilFinished(
    allocator: std.mem.Allocator,
    editor: *LineEditor,
    stdout: *std.Io.Writer,
    runtime: *neoclaw.loop.Runtime,
    sub: *neoclaw.loop.Subscription,
    agent_id: neoclaw.loop.AgentId,
    trigger_id: ?neoclaw.loop.TriggerId,
) !void {
    const io = runtime.io;
    var signal_future = startSignalListener(io, runtime, agent_id);
    defer stopSignalListener(io, &signal_future);

    var saw_delta = false;

    while (try runtime.event_log.recv(sub)) |record_const| {
        var record = record_const;
        defer record.deinit(allocator);
        switch (record.event) {
            .accepted => {},
            .started => |ev| {
                if (ev.agent_id == agent_id and ev.trigger_id == trigger_id) {
                    try stdout.print("[started][agent {d}]\n", .{ev.agent_id});
                    try stdout.flush();
                }
            },
            .assistant_delta => |ev| {
                if (ev.agent_id != agent_id) continue;
                if (!saw_delta) {
                    saw_delta = true;
                    try stdout.writeAll("assistant> ");
                }
                try stdout.writeAll(ev.text);
                try stdout.flush();
            },
            .tool_started => |ev| {
                if (ev.agent_id != agent_id) continue;
                if (saw_delta) {
                    try stdout.writeAll("\n");
                    saw_delta = false;
                }
                try stdout.print("[tool][syscall {d}] {s}\n", .{ ev.syscall_id, ev.name });
                try stdout.flush();
            },
            .tool_waiting => |ev| {
                if (ev.agent_id != agent_id) continue;
                try stdout.print("[tool-waiting][syscall {d}]\n", .{ev.syscall_id});
                try stdout.flush();
            },
            .tool_detached => |ev| {
                if (ev.agent_id != agent_id) continue;
                try stdout.print("[tool-detached][syscall {d}] {s}\n", .{ ev.syscall_id, ev.ack });
                try stdout.flush();
            },
            .tool_completed => |ev| {
                if (ev.agent_id != agent_id) continue;
                try stdout.print("[tool-completed][syscall {d}][{s}]\n{s}\n", .{ ev.syscall_id, if (ev.ok) "ok" else "failed", ev.output });
                try stdout.flush();
            },
            .waiting_user => |ev| {
                if (ev.agent_id != agent_id) continue;
                if (saw_delta) {
                    try stdout.writeAll("\n");
                    saw_delta = false;
                }
                try stdout.print("assistant> [ASK] {s}\n", .{ev.question});
                try stdout.flush();

                stopSignalListener(io, &signal_future);
                defer signal_future = startSignalListener(io, runtime, agent_id);

                const reply_opt = try editor.readLine("reply> ");
                if (reply_opt == null) return;
                const reply = reply_opt.?;
                defer allocator.free(reply);

                const reply_trimmed = std.mem.trim(u8, reply, " \t\r\n");
                _ = try runtime.submitReply(agent_id, ev.syscall_id, reply_trimmed);
            },
            .message_incomplete => |ev| {
                if (ev.agent_id != agent_id) continue;
                if (saw_delta) {
                    try stdout.writeAll("\n");
                    saw_delta = false;
                }
                try stdout.print("[incomplete] {s}\n", .{ev.partial_content});
                try stdout.flush();
            },
            .tool_cancelled => |ev| {
                if (ev.agent_id != agent_id) continue;
                try stdout.print("[tool-cancelled][syscall {d}]\n", .{ev.syscall_id});
                try stdout.flush();
            },
            .finished => |ev| {
                if (ev.agent_id != agent_id) continue;
                if (ev.trigger_id != trigger_id) continue;
                if (!saw_delta and ev.final_text.len > 0) {
                    try stdout.print("assistant> {s}", .{ev.final_text});
                }
                try stdout.writeAll("\n\n");
                try stdout.flush();
                return;
            },
            .fault => |ev| {
                if (ev.agent_id != null and ev.agent_id.? != agent_id) continue;
                if (saw_delta) {
                    try stdout.writeAll("\n");
                    saw_delta = false;
                }
                try stdout.print("[fault] {s}\n", .{ev.message});
                try stdout.flush();
            },
        }
    }
}

const SignalFuture = Io.Future(void);

fn signalListener(runtime: *neoclaw.loop.Runtime, agent_id: neoclaw.loop.AgentId) void {
    const io = runtime.io;
    var terminal: Terminal = .{};
    const raw_ok = terminal.enableRawMode() catch return;
    if (!raw_ok) return;
    defer terminal.disableRawMode();

    var buf: [16]u8 = undefined;
    var stdin_reader: Io.File.Reader = .initStreaming(.stdin(), io, &buf);
    const reader = &stdin_reader.interface;

    while (true) {
        const byte_ptr = reader.takeArray(1) catch return;
        if (byte_ptr[0] == 3) {
            _ = runtime.cancelAgent(agent_id) catch {};
            return;
        }
    }
}

fn startSignalListener(io: Io, runtime: *neoclaw.loop.Runtime, agent_id: neoclaw.loop.AgentId) ?SignalFuture {
    return io.concurrent(signalListener, .{ runtime, agent_id }) catch null;
}

fn stopSignalListener(io: Io, future: *?SignalFuture) void {
    if (future.*) |*f| {
        _ = f.cancel(io);
        future.* = null;
    }
}

fn loadSystemPrompt(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, SystemPromptFile, allocator, .limited(256 * 1024));
}

fn initCaBundle(http_client: *std.http.Client, allocator: std.mem.Allocator, io: Io) !void {
    const now = Io.Clock.real.now(io);
    http_client.now = now;
    http_client.ca_bundle.rescan(allocator, io, now) catch {};
    if (http_client.ca_bundle.map.count() == 0) {
        try cacert.addToBundle(&http_client.ca_bundle, allocator, now.toSeconds());
    }
}

fn getEnvOwned(
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    name: []const u8,
    default_value: ?[]const u8,
) ![]const u8 {
    if (environ_map.get(name)) |value| return allocator.dupe(u8, value);
    if (default_value) |v| return allocator.dupe(u8, v);
    return error.MissingEnvironmentVariable;
}

fn ignoreSigint() void {
    if (comptime builtin.os.tag == .linux) {
        const posix = std.posix;
        const act: std.os.linux.Sigaction = .{
            .handler = .{ .handler = posix.SIG.IGN },
            .mask = std.os.linux.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.INT, &act, null);
    }
}
