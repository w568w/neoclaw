const std = @import("std");
const Allocator = std.mem.Allocator;
const control_code = std.ascii.control_code;

const ansi_term = @import("../vendored/ansi_term.zig");
const command = @import("command.zig");
const globals = @import("globals.zig");
const history = @import("history.zig");
const supported_os = @import("supported_os.zig");
const Unix = @import("../os/Unix.zig");
const Windows = @import("../os/Windows.zig");

const unistd = @cImport(@cInclude("unistd.h"));

pub const ReadlineError =
Allocator.Error ||
    std.fs.File.ReadError ||
    std.Io.Writer.Error ||
    command.ParseInputError ||
    command.CommandError ||
    command.LogError ||
    switch (supported_os.SUPPORTED_OS) {
        .linux, .macos, .freebsd => Unix.Error,
        .windows => Windows.Error,
    };

pub fn readLine(outlive: Allocator, prompt: []const u8) ReadlineError![]u8 {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);

    const stdin_file = std.fs.File.stdin();

    // const inputrc_maybe = findInputrc(outlive) catch null;

    return helper(outlive, prompt, &stdout_writer.interface, stdin_file, null);
}

fn findInputrc(alloc: Allocator) !std.fs.File {
    const flags = std.fs.File.OpenFlags{};
    // Step 1: check INPUTRC env
    const inputrc_path_maybe = std.process.getEnvVarOwned(alloc, "INPUTRC");
    if (inputrc_path_maybe) |inputrc_path| {
        defer alloc.free(inputrc_path);
        return try std.fs.openFileAbsolute(inputrc_path, flags);
    } else |inputrc_path_err| switch (inputrc_path_err) {
    // Step 2: check ENV_HOME_PATH env
        error.EnvironmentVariableNotFound => {
        const home_path = try std.process.getEnvVarOwned(alloc, supported_os.ENV_HOME_PATH);
        defer alloc.free(home_path);

        var home_dir = try std.fs.openDirAbsolute(home_path, std.fs.Dir.OpenOptions{});
        defer home_dir.close();

        if (home_dir.openFile(".inputrc", flags)) |home_file| return home_file
            // Step 3: check /etc (on Unix only?)
            else |err| switch (err) {
            error.FileNotFound => return try std.fs.openFileAbsolute("/etc/inputrc", flags),
            else => |remaining_err| return remaining_err,
        }
    },
        else => |remaining_err| return remaining_err,
    }
}

fn helper(
    outlive: Allocator,
    prompt: []const u8,
    out: *std.Io.Writer,
    in: std.fs.File,
    inputrc_maybe: ?std.fs.File,
) ![]u8 {
    var arena_allocator = std.heap.ArenaAllocator.init(outlive);
    defer arena_allocator.deinit();
    const temp = arena_allocator.allocator();

    try globals.history_entries.append(outlive, undefined);
    defer _ = globals.history_entries.pop();

    var state = command.State{
        .prompt = prompt,
        .out = out,
        .in = in,
        .col_offset = 0,
        .line_buffer = std.ArrayListUnmanaged(u8).empty,
        .edit_stack = std.ArrayListUnmanaged([]const u8).empty,
        .is_yankable = false,
        .temp = temp,
        .outlive = outlive,
        .bytes_read = undefined,
        .history_index = globals.history_entries.items.len - 1,
        .in_buffer = undefined,
        .map = std.StringHashMapUnmanaged(command.CommandFnPair).empty,
    };

    if (inputrc_maybe) |inputrc| {
        try command.parseInputFile(temp, &state.map, inputrc);
    }

    const old = switch (supported_os.SUPPORTED_OS) {
        .linux, .macos, .freebsd => try Unix.init(),
        .windows => try Windows.init(),
    };
    defer old.deinit();

    if (supported_os.SUPPORTED_OS == .windows) {
        try ansi_term.setCursorColumn(out, 0);
        try ansi_term.clearFromCursorToLineEnd(out);
    }
    try out.writeAll(prompt);
    try out.flush();

    while (true) : ({
        try out.flush();
        const was_yank = state.bytes_read > 0 and state.in_buffer[0] == command.CTRL_Y;
        const was_rotate = state.bytes_read > 1 and
            state.in_buffer[0] == std.ascii.control_code.esc and
            state.in_buffer[1] == 'y';
        state.is_yankable = was_yank or was_rotate;
    }) {
        state.bytes_read = try in.read(&state.in_buffer);

        const positive, _ = command.findCommandFnPair(&state) catch |err| {
            const prev_col = state.prompt.len + state.col_offset;
            switch (err) {
                error.FirstByteUnhandled => {
                    const fmt = "Unhandled first byte: 0x{x}";
                    try command.log(&state, fmt, .{state.in_buffer[0]}, prev_col);
                },
                error.SecondByteUnhandled => {
                    const fmt = "Unhandled second byte: 0x{x}";
                    try command.log(&state, fmt, .{state.in_buffer[1]}, prev_col);
                },
                error.ThirdByteUnhandled => {
                    const fmt = "Unhandled third byte: 0x{x}";
                    try command.log(&state, fmt, .{state.in_buffer[2]}, prev_col);
                },
                error.FourthByteUnhandled => {
                    const fmt = "Unhandled fourth byte: 0x{x}";
                    try command.log(&state, fmt, .{state.in_buffer[3]}, prev_col);
                },
                error.ProcessExit => return error.ProcessExit,
            }
            continue;
        };

        positive(&state) catch |command_error| switch (command_error) {
            error.DeleteEmptyLineBuffer, error.NewLine => break,
            else => |readline_error| return readline_error,
        };
    }

    try out.writeAll(supported_os.NEW_LINE);
    try out.flush();
    return try outlive.dupe(u8, state.line_buffer.items);
}

// Testing

test "Print characters" {
    try testInputs(&.{ "a", "s", "d", "f" }, "asdf");
}

test "Move forward and backward" {
    try testInputs(&.{
        "a",
        "s",
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        "d",
        "f",
        &.{command.CTRL_F},
        &.{command.CTRL_F},
        "g",
        "h",
    }, "dfasgh");
}

test "Delete before" {
    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        &.{command.BACKSPACE},
        &.{command.BACKSPACE},
    }, "as");

    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        &.{ control_code.esc, command.META_DASH },
        "2",
        &.{command.CTRL_D},
    }, "as");

    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        &.{ control_code.esc, command.META_DASH },
        "2",
        &.{ control_code.esc, '[', command.DEL, '~' },
    }, "as");
}

test "Delete after" {
    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_D},
        &.{command.CTRL_D},
    }, "df");

    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{ control_code.esc, command.META_DASH },
        "2",
        &.{command.BACKSPACE},
    }, "df");

    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{ control_code.esc, '[', command.DEL, '~' },
        &.{ control_code.esc, '[', command.DEL, '~' },
    }, "df");
}

test "Undo" {
    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_D},
        &.{command.CTRL_UNDERSCORE},
    }, "asdf");
}

test "Move to start of line" {
    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        &.{command.CTRL_A},
        "g",
        "h",
        "j",
        "k",
    }, "ghjkasdf");

    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        &.{ control_code.esc, command.META_DASH },
        &.{command.CTRL_E},
        "g",
        "h",
        "j",
        "k",
    }, "ghjkasdf");

    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        &.{ control_code.esc, '[', command.HOME },
        "g",
        "h",
        "j",
        "k",
    }, "ghjkasdf");
}

test "Move to end of line" {
    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_E},
        "g",
        "h",
        "j",
        "k",
    }, "asdfghjk");

    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{ control_code.esc, command.META_DASH },
        &.{command.CTRL_A},
        "g",
        "h",
        "j",
        "k",
    }, "asdfghjk");

    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{ control_code.esc, command.META_DASH },
        "2",
        &.{ control_code.esc, '[', command.HOME },
        "g",
        "h",
        "j",
        "k",
    }, "asdfghjk");
}

test "Move forward a word" {
    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{ control_code.esc, 'f' },
        "g",
        "h",
        "j",
        "k",
    }, "asdfghjk");

    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{ control_code.esc, command.META_DASH },
        &.{ control_code.esc, 'b' },
        "g",
        "h",
        "j",
        "k",
    }, "asdfghjk");
}

test "Move forward to non-alphanumeric" {
    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        ";",
        "l",
        "k",
        "j",
        &.{command.CTRL_A},
        &.{ control_code.esc, command.META_F },
        "q",
        "w",
        "e",
        "r",
    }, "asdfqwer;lkj");
}

test "Move backward a word" {
    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        &.{ control_code.esc, command.META_B },
        "g",
        "h",
        "j",
        "k",
    }, "ghjkasdf");

    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        &.{ control_code.esc, command.META_DASH },
        &.{ control_code.esc, command.META_F },
        "g",
        "h",
        "j",
        "k",
    }, "ghjkasdf");
}

test "Move backward to non-alphanumeric" {
    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        ";",
        "l",
        "k",
        "j",
        &.{ control_code.esc, command.META_B },
        "q",
        "w",
        "e",
        "r",
    }, "asdf;qwerlkj");
}

test "Clear screen" {
    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        &.{command.CTRL_L},
    }, "asdf");
}

test "Kill text from cursor to end" {
    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        ";",
        "l",
        "k",
        "j",
        &.{command.CTRL_A},
        &.{command.CTRL_K},
    }, "");
    defer globals.freeKillRing(std.testing.allocator);

    try std.testing.expectEqualStrings(globals.kill_ring.at(0), "asdf;lkj");
}

test "Kill text from start to cursor" {
    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        ";",
        "l",
        "k",
        "j",
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{ control_code.esc, command.META_DASH },
        &.{command.CTRL_K},
    }, ";lkj");
    defer globals.freeKillRing(std.testing.allocator);

    try std.testing.expectEqualStrings(globals.kill_ring.at(0), "asdf");
}

test "Kill text to end of word" {
    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        ";",
        "l",
        "k",
        "j",
        &.{command.CTRL_A},
        &.{ control_code.esc, command.META_D },
    }, ";lkj");
    defer globals.freeKillRing(std.testing.allocator);

    try std.testing.expectEqualStrings(globals.kill_ring.at(0), "asdf");
}

test "Kill text to end of word while surrounded" {
    try testInputs(&.{
        ".",
        ".",
        "1",
        ".",
        ".",
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{ control_code.esc, command.META_D },
    }, "....");
    defer globals.freeKillRing(std.testing.allocator);

    try std.testing.expectEqualStrings(globals.kill_ring.at(0), "1");
}

test "Kill text to start of word" {
    {
        try testInputs(&.{
            "a",
            "s",
            "d",
            "f",
            ";",
            "l",
            "k",
            "j",
            &.{ control_code.esc, command.META_BACKSPACE },
        }, "asdf;");
        defer globals.freeKillRing(std.testing.allocator);
        try std.testing.expectEqualStrings(globals.kill_ring.at(0), "lkj");
    }
    {
        try testInputs(&.{
            "a",
            "s",
            "d",
            "f",
            ";",
            "l",
            "k",
            "j",
            &.{ control_code.esc, command.META_DASH },
            &.{ control_code.esc, command.META_D },
        }, "asdf;");
        defer globals.freeKillRing(std.testing.allocator);
        try std.testing.expectEqualStrings(globals.kill_ring.at(0), "lkj");
    }
}

test "Kill text from cursor to start of previous word" {
    try testInputs(&.{
        ".",
        ".",
        ".",
        "1",
        "2",
        "3",
        ".",
        ".",
        ".",
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{ control_code.esc, command.META_BACKSPACE },
    }, "......");
    defer globals.freeKillRing(std.testing.allocator);

    try std.testing.expectEqualStrings(globals.kill_ring.at(0), "123");
}

test "Kill text from end to previous whitespace" {
    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        " ",
        "l",
        "k",
        "j",
        &.{command.CTRL_W},
    }, "asdf ");
    defer globals.freeKillRing(std.testing.allocator);

    try std.testing.expectEqualStrings(globals.kill_ring.at(0), "lkj");
}

test "Kill text from mid-word to whitespace" {
    try testInputs(&.{
        "1",
        "2",
        "3",
        &.{command.CTRL_B},
        &.{command.CTRL_W},
    }, "3");
    defer globals.freeKillRing(std.testing.allocator);

    try std.testing.expectEqualStrings(globals.kill_ring.at(0), "12");
}

test "Yank text" {
    try testInputs(&.{
        "a",
        "s",
        "d",
        "f",
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_K},
        &.{command.CTRL_B},
        &.{command.CTRL_B},
        &.{command.CTRL_Y},
    }, "dfas");
    defer globals.freeKillRing(std.testing.allocator);

    try std.testing.expectEqual(1, globals.kill_ring.len);
}

test "Rotate kill-ring and yank text" {
    try testInputs(&.{
        "a",
        "b",
        "c",
        &.{command.CTRL_B},
        &.{command.CTRL_K},
        &.{command.CTRL_B},
        &.{command.CTRL_K},
        &.{command.CTRL_B},
        &.{command.CTRL_K},
        &.{command.CTRL_Y},
        &.{ control_code.esc, command.META_Y },
        &.{command.CTRL_Y},
    }, "bb");
    defer globals.freeKillRing(std.testing.allocator);

    try std.testing.expectEqual(3, globals.kill_ring.len);
}

test "Positive Arguments Movement" {
    try testInputs(&.{
        "a",
        "b",
        "c",
        &.{ control_code.esc, '3' },
        &.{command.CTRL_B},
        "d",
    }, "dabc");
}

test "Negative Arguments Movement" {
    try testInputs(&.{
        "a",
        "b",
        "c",
        &.{ control_code.esc, command.META_DASH },
        "3",
        &.{command.CTRL_F},
        "d",
    }, "dabc");
}

test "Argument print char" {
    try testInputs(&.{
        &.{ control_code.esc, '1' },
        "0",
        "a",
    }, "aaaaaaaaaa");
}

test "Positive Argument meta dash" {
    try testInputs(&.{
        &.{ control_code.esc, '6' },
        &.{ control_code.esc, command.META_DASH },
    }, "------");
}

test "Negative Argument meta dash" {
    try testInputs(&.{
        &.{ control_code.esc, command.META_DASH },
        &.{ control_code.esc, command.META_DASH },
    }, "");
}

test "History Back" {
    const expected = "asdf";
    history.usingHistory();

    try history.addHistory(std.testing.allocator, expected);
    try testInputs(&.{&.{command.CTRL_P}}, expected);

    try history.addHistory(std.testing.allocator, expected);
    try testInputs(&.{&.{ control_code.esc, '[', command.UP_ARROW }}, expected);
}

test "History Forward" {
    const expected = "jkl;";
    history.usingHistory();

    try history.addHistory(std.testing.allocator, "asdf");
    try history.addHistory(std.testing.allocator, expected);
    try testInputs(&.{
        &.{ control_code.esc, '[', command.UP_ARROW },
        &.{ control_code.esc, '[', command.UP_ARROW },
        &.{ control_code.esc, '[', command.DOWN_ARROW },
    }, expected);

    try history.addHistory(std.testing.allocator, "asdf");
    try history.addHistory(std.testing.allocator, expected);
    try testInputs(&.{
        &.{command.CTRL_P},
        &.{command.CTRL_P},
        &.{command.CTRL_N},
    }, expected);
}

test "History Beginning" {
    history.usingHistory();

    try history.addHistory(std.testing.allocator, "1");
    try history.addHistory(std.testing.allocator, "2");
    try history.addHistory(std.testing.allocator, "3");
    try history.addHistory(std.testing.allocator, "4");
    try testInputs(&.{
        &.{ control_code.esc, command.META_LT },
    }, "1");

    try history.addHistory(std.testing.allocator, "1");
    try history.addHistory(std.testing.allocator, "2");
    try history.addHistory(std.testing.allocator, "3");
    try history.addHistory(std.testing.allocator, "4");
    try testInputs(&.{
        &.{ control_code.esc, command.META_DASH },
        &.{ control_code.esc, command.META_GT },
    }, "1");
}

test "History End" {
    history.usingHistory();

    try history.addHistory(std.testing.allocator, "1");
    try history.addHistory(std.testing.allocator, "2");
    try history.addHistory(std.testing.allocator, "3");
    try history.addHistory(std.testing.allocator, "4");
    try testInputs(&.{
        &.{command.CTRL_P},
        &.{command.CTRL_P},
        &.{ control_code.esc, command.META_GT },
    }, "4");

    try history.addHistory(std.testing.allocator, "1");
    try history.addHistory(std.testing.allocator, "2");
    try history.addHistory(std.testing.allocator, "3");
    try history.addHistory(std.testing.allocator, "4");
    try testInputs(&.{
        &.{command.CTRL_P},
        &.{command.CTRL_P},
        &.{ control_code.esc, command.META_DASH },
        &.{ control_code.esc, command.META_LT },
    }, "4");
}

fn testInputs(inputs: []const []const u8, expected: []const u8) !void {
    const outlive = std.testing.allocator;

    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&out_buf);

    var pipe_fds: [2]c_int = undefined;
    try std.testing.expect(-1 != unistd.pipe(&pipe_fds));
    defer _ = unistd.close(pipe_fds[0]);
    const fd = pipe_fds[1];

    for (inputs) |input| {
        try inputStdin(fd, input);
    }
    try inputStdin(fd, "\n");

    try std.testing.expect(-1 != unistd.close(fd));

    const in = std.fs.File{ .handle = pipe_fds[0] };
    const line = try helper(outlive, "", &out.writer, in, null);
    defer {
        outlive.free(line);
        globals.freeHistory(outlive);
    }

    try std.testing.expectEqualStrings(expected, line);
}

fn inputStdin(fd: c_int, input: []const u8) !void {
    var buffer: [8]u8 = undefined;
    @memmove(buffer[0..input.len], input);
    try std.testing.expect(-1 != unistd.write(fd, &buffer, 8));
}
