const std = @import("std");
const Io = std.Io;

const neoclaw = @import("neoclaw");
const dotenv = @import("dotenv.zig");
const cacert = @import("generated/cacert.zig");
const LineEditor = @import("line_editor/editor.zig").LineEditor;

const SystemPromptFile = "NEOCLAW.md";
const MaxTurns: u32 = 40;

const ToolRegistry = neoclaw.schema.Registry(.{
    neoclaw.tools.code_run,
    neoclaw.tools.file_read,
    neoclaw.tools.file_write,
    neoclaw.tools.ask_user,
});

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var editor = LineEditor.init(allocator);
    defer editor.deinit();

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

    var sub = runtime.event_log.subscribe(.tail);
    var current_agent_id: ?neoclaw.loop.AgentId = null;

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
        const receipt = try runtime.submitQuery(current_agent_id, trimmed, .interactive);
        current_agent_id = receipt.agent_id;

        try consumeUntilFinished(allocator, &editor, stdout, &runtime, &sub, current_agent_id.?, receipt.request_id);
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
    request_id: ?neoclaw.loop.RequestId,
) !void {
    var saw_delta = false;

    while (try runtime.event_log.recv(sub)) |record_const| {
        var record = record_const;
        defer record.deinit(allocator);
        switch (record.event) {
            .accepted => {},
            .started => |ev| {
                if (ev.agent_id == agent_id and ev.request_id == request_id) {
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

                const reply_opt = try editor.readLine("reply> ");
                if (reply_opt == null) return;
                const reply = reply_opt.?;
                defer allocator.free(reply);

                const reply_trimmed = std.mem.trim(u8, reply, " \t\r\n");
                _ = try runtime.submitReply(agent_id, ev.syscall_id, reply_trimmed);
            },
            .finished => |ev| {
                if (ev.agent_id != agent_id) continue;
                if (ev.request_id != request_id) continue;
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
