const std = @import("std");
const Io = std.Io;

const neoclaw = @import("neoclaw");
const LineEditor = @import("line_editor.zig").LineEditor;

const SystemPromptFile = "NEOCLAW.md";

const ToolRegistry = neoclaw.schema.Registry(.{
    neoclaw.tools.code_run,
    neoclaw.tools.file_read,
    neoclaw.tools.file_write,
    neoclaw.tools.ask_user,
});

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var editor = LineEditor.init(arena);
    defer editor.deinit();

    const api_key = try getEnvOwned(arena, init.environ_map, "OPENAI_API_KEY", null);
    const api_base = try getEnvOwned(arena, init.environ_map, "OPENAI_API_BASE", "https://api.openai.com");
    const model = try getEnvOwned(arena, init.environ_map, "OPENAI_MODEL", "gpt-4o-mini");
    const system_prompt = try loadSystemPrompt(arena, io);

    var client = neoclaw.openai.Client.init(arena, .{
        .io = io,
        .api_base = api_base,
        .api_key = api_key,
        .model = model,
    });
    defer client.deinit();

    var tool_ctx = neoclaw.schema.ToolContext{ .io = io };
    var registry = ToolRegistry.init(&tool_ctx);
    const tools_json = try registry.toolsJsonOwned(arena);

    var history: std.ArrayList(neoclaw.openai.Message) = .empty;
    defer deinitHistory(arena, &history);
    try resetHistory(arena, &history, system_prompt);

    try stdout.writeAll("neoclaw interactive chat\n");
    try stdout.writeAll("commands: /exit /quit /clear\n\n");

    while (true) {
        try stdout.flush();

        const line_opt = try editor.readLine("you> ");
        if (line_opt == null) break;
        const line = line_opt.?;
        defer arena.free(line);

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        if (std.mem.eql(u8, trimmed, "/exit") or std.mem.eql(u8, trimmed, "/quit")) {
            break;
        }

        if (std.mem.eql(u8, trimmed, "/clear")) {
            try resetHistory(arena, &history, system_prompt);
            try stdout.writeAll("[history cleared]\n\n");
            continue;
        }

        try editor.addHistory(trimmed);
        try history.append(arena, .{ .role = .user, .content = try arena.dupe(u8, trimmed) });

        var runner = try neoclaw.loop.runEvents(
            arena,
            &client,
            registry.handler(),
            &history,
            tools_json,
            40,
        );
        defer runner.deinit();

        var assistant_prefix_printed = false;
        while (try runner.next()) |event| {
            switch (event) {
                .turn_started => {},
                .assistant_delta => |ev| {
                    _ = ev.turn;
                    if (!assistant_prefix_printed) {
                        assistant_prefix_printed = true;
                        try stdout.writeAll("assistant> ");
                    }
                    try stdout.writeAll(ev.text);
                    try stdout.flush();
                },
                .tool_call => |ev| {
                    if (assistant_prefix_printed) {
                        try stdout.writeAll("\n");
                        assistant_prefix_printed = false;
                    }
                    try stdout.print("[tool][turn {d}][{d}] id={s} {s} args={s}\n", .{ ev.turn, ev.index, ev.tool_call_id, ev.name, ev.arguments_json });
                    try stdout.flush();
                },
                .tool_result => |ev| {
                    if (assistant_prefix_printed) {
                        try stdout.writeAll("\n");
                        assistant_prefix_printed = false;
                    }
                    const status = switch (ev.status) {
                        .ok => "ok",
                        .interrupted => "interrupted",
                        .failed => "failed",
                    };
                    try stdout.print("[tool-result][turn {d}][{d}] id={s} status={s} output={s}\n", .{ ev.turn, ev.index, ev.tool_call_id, status, ev.output });
                    try stdout.flush();
                },
                .run_finished => |ev| {
                    switch (ev.reason) {
                        .completed => {
                            if (!assistant_prefix_printed and ev.final_text.len > 0) {
                                try stdout.print("assistant> {s}", .{ev.final_text});
                            }
                        },
                        .interrupted => {
                            if (assistant_prefix_printed) {
                                try stdout.writeAll("\n");
                                assistant_prefix_printed = false;
                            }
                            try stdout.print("assistant> [INTERRUPTED] {s}\n", .{ev.final_text});
                        },
                        .max_turns_exceeded => {
                            if (assistant_prefix_printed) {
                                try stdout.writeAll("\n");
                                assistant_prefix_printed = false;
                            }
                            try stdout.writeAll("assistant> [MAX_TURNS_EXCEEDED]\n");
                        },
                    }

                    assistant_prefix_printed = false;
                    try stdout.writeAll("\n");
                },
            }
        }
    }

    try stdout.writeAll("bye\n");
    try stdout.flush();
}

fn resetHistory(allocator: std.mem.Allocator, history: *std.ArrayList(neoclaw.openai.Message), system_prompt: []const u8) !void {
    deinitHistory(allocator, history);
    history.* = .empty;
    try history.append(allocator, .{ .role = .system, .content = try allocator.dupe(u8, system_prompt) });
}

/// Returns owned system prompt read from `NEOCLAW.md` in current working directory.
fn loadSystemPrompt(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, SystemPromptFile, allocator, .limited(256 * 1024));
}

fn deinitHistory(allocator: std.mem.Allocator, history: *std.ArrayList(neoclaw.openai.Message)) void {
    for (history.items) |msg| {
        if (msg.content) |content| allocator.free(content);
        if (msg.tool_call_id) |id| allocator.free(id);
        if (msg.tool_calls) |tool_calls| neoclaw.openai.freeToolCalls(allocator, tool_calls);
    }
    history.deinit(allocator);
}

/// Returns owned value copied from environment or default.
fn getEnvOwned(
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    name: []const u8,
    default_value: ?[]const u8,
) ![]const u8 {
    if (environ_map.get(name)) |value| {
        return allocator.dupe(u8, value);
    }
    if (default_value) |v| return allocator.dupe(u8, v);
    return error.MissingEnvironmentVariable;
}
