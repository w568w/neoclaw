const std = @import("std");
const Io = std.Io;

const neoclaw = @import("neoclaw");
const dotenv = @import("dotenv.zig");
const cacert = @import("generated/cacert.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const io = init.io;

    try dotenv.loadInto(allocator, init.environ_map, init.io);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const model = try getEnvOwned(allocator, init.environ_map, "CODEX_MODEL", "gpt-5.3-codex");
    defer allocator.free(model);
    const auth_file_path = try getEnvOwned(allocator, init.environ_map, "CODEX_AUTH_FILE", ".codex-auth.json");
    defer allocator.free(auth_file_path);
    const prompt = try getPrompt(allocator, init.minimal.args);
    defer allocator.free(prompt);

    var client = try neoclaw.codex.Client.init(allocator, .{
        .io = io,
        .model = model,
        .auth_file_path = auth_file_path,
    });
    defer client.deinit();
    client.ensureAuthClient();

    try initCaBundle(&client.http_client, allocator, io);

    try stdout.print("Using auth file: {s}\n", .{auth_file_path});
    try stdout.flush();

    client.auth.loadState() catch |err| {
        try stderr.print("failed to load auth state: {s}\n", .{@errorName(err)});
        try stderr.flush();
        return err;
    };

    if (client.auth.refresh_token == null and client.auth.access_token == null) {
        try stdout.writeAll("No saved token found. Starting headless login...\n\n");
        try stdout.flush();
        try client.auth.loginHeadless(stdout);
    } else {
        try client.auth.ensureLogin();
    }

    try stdout.writeAll("Login ready. Sending test prompt...\n\nassistant> ");
    try stdout.flush();

    const messages = [_]neoclaw.llm.MessageView{
        .{ .role = .system, .content = "You are a concise coding assistant." },
        .{ .role = .user, .content = prompt },
    };

    var stream = try client.chatStream(&messages, null);
    defer stream.deinit();

    while (try stream.next()) |event| {
        switch (event) {
            .content_delta => |delta| {
                try stdout.writeAll(delta);
                try stdout.flush();
            },
            .finished => {},
        }
    }

    var response = try stream.takeResponseOwned();
    defer response.deinit(allocator);

    try stdout.print("\n\nfinish_reason={s} tool_calls={d}\n", .{ @tagName(response.finish_reason), response.tool_calls.len });
    if (client.auth.account_id) |account_id| {
        try stdout.print("account_id={s}\n", .{account_id});
    }
    try stdout.flush();
}

fn getPrompt(allocator: std.mem.Allocator, args: std.process.Args) ![]const u8 {
    var iter = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer iter.deinit();
    _ = iter.next();
    if (iter.next()) |first_z| {
        const first: []const u8 = first_z;
        var writer: std.Io.Writer.Allocating = .init(allocator);
        errdefer writer.deinit();
        try writer.writer.writeAll(first);
        while (iter.next()) |arg_z| {
            const arg: []const u8 = arg_z;
            try writer.writer.writeByte(' ');
            try writer.writer.writeAll(arg);
        }
        return writer.toOwnedSlice();
    }
    return allocator.dupe(u8, "Reply with a short sentence confirming the Codex API call works.");
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
    if (default_value) |value| return allocator.dupe(u8, value);
    return error.MissingEnvironmentVariable;
}
