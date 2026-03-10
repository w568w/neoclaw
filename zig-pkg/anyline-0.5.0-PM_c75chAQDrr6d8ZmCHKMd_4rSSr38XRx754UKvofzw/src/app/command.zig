const std = @import("std");
const control_code = std.ascii.control_code;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const ansi_term = @import("../vendored/ansi_term.zig");
const clearFromCursorToLineEnd = ansi_term.clearFromCursorToLineEnd;
const setCursorColumn = ansi_term.setCursorColumn;
const globals = @import("globals.zig");
const supported_os = @import("supported_os.zig");

const FindError = error{
    FirstByteUnhandled,
    SecondByteUnhandled,
    ThirdByteUnhandled,
    FourthByteUnhandled,
    ProcessExit,
};
pub const LogError = std.Io.Writer.Error || Allocator.Error;
pub const ParseInputError =
    std.process.GetEnvVarOwnedError ||
    std.fs.File.OpenError ||
    error{ ReadFailed, StreamTooLong } ||
    std.mem.Allocator.Error;
pub const CommandError =
    error{ DeleteEmptyLineBuffer, NewLine, ProcessExit } ||
    Allocator.Error ||
    std.fs.File.ReadError ||
    std.Io.Writer.Error;

const CommandFn = *const fn (*State) CommandError!void;
pub const CommandFnPair = struct { CommandFn, CommandFn };

pub const State = struct {
    outlive: Allocator,
    temp: Allocator,
    prompt: []const u8,
    out: *std.Io.Writer,
    in: std.fs.File,
    col_offset: usize,
    line_buffer: std.ArrayListUnmanaged(u8),
    edit_stack: std.ArrayListUnmanaged([]const u8),
    is_yankable: bool,
    history_index: usize,
    bytes_read: usize,
    in_buffer: [8]u8,
    map: std.StringHashMapUnmanaged(CommandFnPair),
};

pub fn log(
    state: *const State,
    comptime fmt: []const u8,
    args: anytype,
    prev_col: usize,
) LogError!void {
    if (builtin.mode != .Debug or builtin.is_test) return;

    const max_col = max_col: {
        try ansi_term.setCursorColumn(state.out, 999);
        try ansi_term.queryCursorPosition(state.out);
        try state.out.flush();

        var buffer: [32]u8 = undefined;
        var reader = state.in.readerStreaming(&buffer);
        const input = reader.interface.takeDelimiterExclusive('R') catch @panic("Failed to log!");

        const semicolon_index = std.mem.indexOf(u8, input, ";").?;
        const position_slice = input[semicolon_index + 1 ..];
        break :max_col std.fmt.parseUnsigned(usize, position_slice, 10) catch unreachable;
    };

    const msg = try std.fmt.allocPrint(state.temp, fmt, args);
    try ansi_term.setCursorColumn(state.out, max_col - msg.len);
    try state.out.writeAll(msg);
    try ansi_term.setCursorColumn(state.out, prev_col);
}

pub const CTRL_A = 0x01;
pub const CTRL_B = 0x02;
pub const CTRL_C = 0x03;
pub const CTRL_D = 0x04;
pub const CTRL_E = 0x05;
pub const CTRL_F = 0x06;
pub const CTRL_K = 0x0b;
pub const CTRL_L = 0x0c;
pub const CTRL_N = 0x0e;
pub const CTRL_P = 0x10;
pub const CTRL_W = 0x17;
pub const CTRL_Y = 0x19;
pub const CTRL_UNDERSCORE = 0x1F;

pub const DEL = 0x33;
pub const UP_ARROW = 0x41;
pub const DOWN_ARROW = 0x42;
pub const RIGHT_ARROW = 0x43;
pub const LEFT_ARROW = 0x44;
pub const HOME = 0x48;
pub const BACKSPACE = control_code.del;

pub const META_DASH = '-';
pub const META_LT = '<';
pub const META_GT = '>';
pub const META_0 = '0';
pub const META_9 = '9';
pub const META_B = 'b';
pub const META_D = 'd';
pub const META_F = 'f';
pub const META_Y = 'y';
pub const META_BACKSPACE = 0x7F;

pub fn findCommandFnPair(state: *State) FindError!CommandFnPair {
    if (state.map.get(state.in_buffer[0..state.bytes_read])) |pair| {
        return pair;
    }

    return switch (state.in_buffer[0]) {
        ' '...'~' => .{ printChar, doNothing },
        CTRL_A => .{ moveBeginningLine, moveEndLine },
        CTRL_B => .{ moveBackOneChar, moveForwardOneChar },
        CTRL_C => error.ProcessExit,
        CTRL_D => .{ deleteAfter, deleteBefore },
        CTRL_E => .{ moveEndLine, moveBeginningLine },
        CTRL_F => .{ moveForwardOneChar, moveBackOneChar },
        control_code.lf, control_code.cr => .{ acceptLine, acceptLine },
        CTRL_K => .{ killToEnd, killFromStart },
        CTRL_L => .{ clearScreen, doNothing },
        CTRL_N => .{ historyForward, historyBack },
        CTRL_P => .{ historyBack, historyForward },
        CTRL_W => .{ killToWhitespace, killToWhitespace },
        CTRL_Y => .{ yankText, doNothing },
        CTRL_UNDERSCORE => .{ undo, doNothing },
        BACKSPACE => .{ deleteBefore, deleteAfter },
        control_code.esc => {
            if (state.bytes_read == 1) {
                return .{ doNothing, doNothing };
            }

            return switch (state.in_buffer[1]) {
                '[' => {
                    return switch (state.in_buffer[2]) {
                        DEL => {
                            return switch (state.in_buffer[3]) {
                                '~' => .{ deleteAfter, deleteBefore },
                                else => error.FourthByteUnhandled,
                            };
                        },
                        HOME => .{ moveBeginningLine, moveEndLine },
                        UP_ARROW => .{ historyBack, historyForward },
                        DOWN_ARROW => .{ historyForward, historyBack },
                        RIGHT_ARROW => .{ moveForwardOneChar, moveBackOneChar },
                        LEFT_ARROW => .{ moveBackOneChar, moveForwardOneChar },
                        else => error.ThirdByteUnhandled,
                    };
                },
                META_DASH, META_0...META_9 => .{ handleArguments, doNothing },
                META_LT => .{ historyBeginning, historyEnd },
                META_GT => .{ historyEnd, historyBeginning },
                META_B => .{ moveBackOneWord, moveForwardOneWord },
                META_D => .{ killCurrentWordEnd, killCurrentWordStart },
                META_F => .{ moveForwardOneWord, moveBackOneWord },
                META_Y => .{ yankRotate, doNothing },
                META_BACKSPACE => .{ killCurrentWordStart, killCurrentWordEnd },
                else => error.SecondByteUnhandled,
            };
        },
        else => error.FirstByteUnhandled,
    };
}

fn handleArguments(state: *State) !void {
    var list = std.ArrayListUnmanaged(u8).empty;
    try list.append(state.temp, state.in_buffer[1]);

    try setCursorColumn(state.out, 0);
    try clearFromCursorToLineEnd(state.out);
    if (state.in_buffer[1] == '-') {
        try state.out.print("(arg: -1) {s}", .{state.line_buffer.items});
        try setCursorColumn(state.out, 10 + state.col_offset);
    } else {
        try state.out.print("(arg: {c}) {s}", .{ list.items[0], state.line_buffer.items });
        try setCursorColumn(state.out, 9 + state.col_offset);
    }
    try state.out.flush();

    while (true) : (try state.out.flush()) {
        state.bytes_read = try state.in.read(&state.in_buffer);
        std.debug.assert(state.bytes_read > 0);

        if (std.ascii.isDigit(state.in_buffer[0]) or state.in_buffer[0] == '-') {
            try list.append(state.temp, state.in_buffer[0]);

            try setCursorColumn(state.out, 0);
            try state.out.print("(arg: {s}) {s}", .{ list.items, state.line_buffer.items });
            try setCursorColumn(state.out, 8 + list.items.len + state.col_offset);
            continue;
        } else if (state.bytes_read > 1 and state.in_buffer[0] == control_code.esc) {
            if (std.ascii.isDigit(state.in_buffer[1])) {
                try list.append(state.temp, state.in_buffer[1]);

                try setCursorColumn(state.out, 0);
                try state.out.print("(arg: {s}) {s}", .{ list.items, state.line_buffer.items });
                try setCursorColumn(state.out, 8 + list.items.len + state.col_offset);
                continue;
            } else if (state.in_buffer[1] == '-') {
                state.bytes_read = 1;
                state.in_buffer[0] = '-';
            }
        }

        try setCursorColumn(state.out, 0);
        try clearFromCursorToLineEnd(state.out);
        try state.out.print("{s}{s}", .{ state.prompt, state.line_buffer.items });
        try setCursorColumn(state.out, state.prompt.len + state.col_offset);

        const i = std.fmt.parseInt(isize, list.items, 10) catch -1;

        const positive, const negative = findCommandFnPair(state) catch |err| {
            const prev_col = state.prompt.len + state.col_offset;
            switch (err) {
                error.FirstByteUnhandled => {
                    const fmt = "Unhandled first byte: 0x{x}";
                    try log(state, fmt, .{state.in_buffer[0]}, prev_col);
                },
                error.SecondByteUnhandled => {
                    const fmt = "Unhandled second byte: 0x{x}";
                    try log(state, fmt, .{state.in_buffer[1]}, prev_col);
                },
                error.ThirdByteUnhandled => {
                    const fmt = "Unhandled third byte: 0x{x}";
                    try log(state, fmt, .{state.in_buffer[2]}, prev_col);
                },
                error.FourthByteUnhandled => {
                    const fmt = "Unhandled third byte: 0x{x}";
                    try log(state, fmt, .{state.in_buffer[2]}, prev_col);
                },
                error.ProcessExit => return error.ProcessExit,
            }
            return;
        };

        for (0..@abs(i)) |_| {
            if (i > 0) try positive(state) else try negative(state);
        }
        return;
    }
}

pub fn parseInputFile(
    alloc: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(CommandFnPair),
    inputrc: std.fs.File,
) ParseInputError!void {
    var buf: [1024]u8 = undefined;
    var reader = inputrc.readerStreaming(&buf);

    while (try reader.interface.takeDelimiter('\n')) |line| {
        var iter = std.mem.tokenizeScalar(u8, line, ':');
        const keyname = std.mem.trim(u8, iter.next().?, " ");
        const function_name = std.mem.trim(u8, iter.next().?, " ");

        const len = if (std.mem.startsWith(u8, keyname, "Control"))
            "Control".len
        else if (std.mem.startsWith(u8, keyname, "Meta"))
            "Meta".len
        else
            @panic("Bad input");

        std.debug.assert(keyname.len >= len + 2);
        std.debug.assert(keyname[len] == '-');
        std.debug.assert('a' <= keyname[len + 1] and keyname[len + 1] <= 'z');

        const letter = keyname[len + 1];
        const key = if (std.mem.startsWith(u8, keyname, "Control"))
            try alloc.dupe(u8, &.{letter - 96})
        else if (std.mem.startsWith(u8, keyname, "Meta"))
            try alloc.dupe(u8, &.{ control_code.esc, letter })
        else
            @panic("Bad input");

        const value = function_table.get(function_name).?;
        if (try map.fetchPut(alloc, key, value)) |_| {
            std.debug.print("\"{s}\" clobbered something!\n", .{function_name});
        }
    }
}

const function_table = std.StaticStringMap(CommandFnPair).initComptime(.{
    // Commands For Moving
    .{ "beginning-of-line", .{ moveBeginningLine, moveEndLine } },
    .{ "end-of-line", .{ moveEndLine, moveBeginningLine } },
    .{ "forward-char", .{ moveForwardOneChar, moveBackOneChar } },
    .{ "backward-char", .{ moveBackOneChar, moveForwardOneChar } },
    .{ "forward-word", .{ moveForwardOneWord, moveBackOneWord } },
    .{ "backward-word", .{ moveBackOneWord, moveForwardOneWord } },
    // TODO previous-screen-line
    // TODO next-screen-line
    // TODO clear-display
    .{ "clear-screen", .{ clearScreen, doNothing } },
    // TODO redraw-current-line

    // Commands For Manipulating The History
    .{ "accept-line", .{ acceptLine, acceptLine } },
    .{ "previous-history", .{ historyBack, historyForward } },
    .{ "next-history", .{ historyForward, historyBack } },
    .{ "beginning-of-history", .{ historyBeginning, historyEnd } },
    .{ "end-of-history", .{ historyEnd, historyBeginning } },
    // TODO reverse-search-history
    // TODO forward-search-history
    // TODO non-incremental-reverse-search-history
    // TODO non-incremental-forward-search-history
    // TODO history-search-backward
    // TODO history-search-forward
    // TODO history-substring-search-backward
    // TODO history-substring-search-forward
    // TODO yank-nth-arg
    // TODO yank-last-arg
    // TODO operate-and-get-next
    // TODO fetch-history

    // Commands For Changing Text
    // TODO end-of-file
    .{ "delete-char", .{ deleteAfter, deleteBefore } },
    .{ "backward-delete-char", .{ deleteBefore, deleteAfter } },
    // TODO forward-backward-delete-char
    // TODO quoted-insert
    // TODO tab-insert
    .{ "self-insert", .{ printChar, doNothing } },
    // TODO bracketed-paste-begin
    // TODO transpose-chars
    // TODO transpose-words
    // TODO upcase-word
    // TODO downcase-word
    // TODO capitalize-word
    // TODO overwrite-mode

    // Killing And Yanking
    .{ "kill-line", .{ killToEnd, killFromStart } },
    .{ "backward-kill-line", .{ killFromStart, killToEnd } },
    .{ "unix-line-discard", .{ killFromStart, killToEnd } },
    // TODO kill-whole-line
    .{ "kill-word", .{ killCurrentWordEnd, killCurrentWordStart } },
    .{ "backward-kill-word", .{ killCurrentWordStart, killCurrentWordEnd } },
    .{ "unix-word-rubout", .{ killToWhitespace, killToWhitespace } },
    // TODO unix-filename-rubout
    // TODO delete-horizontal-space
    // TODO kill-region
    // TODO copy-region-as-kill
    // TODO copy-backward-word
    // TODO copy-forward-word
    .{ "yank", .{ yankText, doNothing } },
    .{ "yank-pop", .{ yankRotate, doNothing } },

    // Specifying Numeric Arguments
    // TODO digit-argument (handled by handleArguments)
    // TODO universal-argument

    // Letting Readline Type For You
    // TODO complete
    // TODO possible-completions
    // TODO insert-completions
    // TODO menu-complete
    // TODO menu-complete-backward
    // TODO export-completions
    // TODO delete-char-or-list

    // Keyboard Macros
    // TODO start-kbd-macro
    // TODO end-kbd-macro
    // TODO call-last-kbd-macro
    // TODO print-last-kbd-macro

    // Some Miscellaneous Commands
    // TODO re-read-init-file
    // TODO abort
    // TODO do-lowercase-version
    // TODO prefix-meta
    .{ "undo", .{ undo, doNothing } },
    // TODO revert-line
    // TODO tilde-expand
    // TODO set-mark
    // TODO exchange-point-and-mark
    // TODO character-search
    // TODO character-search-backward
    // TODO skip-csi-sequence
    // TODO insert-comment
    // TODO dump-functions
    // TODO dump-variables
    // TODO dump-macros
    // TODO execute-named-command
    // TODO emacs-editing-mode
    // TODO vi-editing-mode
});

//Functions

fn moveBackOneChar(state: *State) !void {
    state.col_offset -|= 1;
    try setCursorColumn(state.out, state.prompt.len + state.col_offset);
}

fn moveForwardOneChar(state: *State) !void {
    state.col_offset = @min(state.col_offset + 1, state.line_buffer.items.len);
    try setCursorColumn(state.out, state.prompt.len + state.col_offset);
}

fn moveBackOneWord(state: *State) !void {
    if (state.col_offset == 0) return;
    std.debug.assert(state.line_buffer.items.len > 0);

    const isAN = std.ascii.isAlphabetic;
    if (!isAN(state.line_buffer.items[state.col_offset - 1])) {
        while (state.col_offset > 0 and
            !isAN(state.line_buffer.items[state.col_offset - 1]))
        {
            state.col_offset -= 1;
        }
    }
    while (state.col_offset > 0 and isAN(state.line_buffer.items[state.col_offset - 1])) {
        state.col_offset -= 1;
    }

    try setCursorColumn(state.out, state.prompt.len + state.col_offset);
}

fn moveForwardOneWord(state: *State) !void {
    const len = state.line_buffer.items.len;
    if (state.col_offset == len) return;

    const isAN = std.ascii.isAlphanumeric;
    if (!isAN(state.line_buffer.items[state.col_offset])) {
        while (state.col_offset < len and !isAN(state.line_buffer.items[state.col_offset])) {
            state.col_offset += 1;
        }
    }
    while (state.col_offset < len and isAN(state.line_buffer.items[state.col_offset])) {
        state.col_offset += 1;
    }

    try setCursorColumn(state.out, state.prompt.len + state.col_offset);
}

fn moveBeginningLine(state: *State) !void {
    state.col_offset = 0;
    try setCursorColumn(state.out, state.prompt.len + state.col_offset);
}

fn moveEndLine(state: *State) !void {
    state.col_offset = state.line_buffer.items.len;
    try setCursorColumn(state.out, state.prompt.len + state.col_offset);
}

fn deleteBefore(state: *State) !void {
    if (state.col_offset == 0) return;

    const copied_line = try state.temp.dupe(u8, state.line_buffer.items);
    try state.edit_stack.append(state.temp, copied_line);

    state.col_offset -= 1;
    _ = state.line_buffer.orderedRemove(state.col_offset);

    try setCursorColumn(state.out, state.prompt.len + state.col_offset);
    try state.out.writeAll(state.line_buffer.items[state.col_offset..]);
    try state.out.writeByte(' ');
    try setCursorColumn(state.out, state.prompt.len + state.col_offset);
}

fn deleteAfter(state: *State) !void {
    if (state.line_buffer.items.len == 0) return error.DeleteEmptyLineBuffer;

    if (state.line_buffer.items.len == state.col_offset) {
        return;
    }
    const edited_line = try state.temp.dupe(u8, state.line_buffer.items);
    try state.edit_stack.append(state.temp, edited_line);

    _ = state.line_buffer.orderedRemove(state.col_offset);

    try state.out.writeAll(state.line_buffer.items[state.col_offset..]);
    try state.out.writeByte(' ');
    try setCursorColumn(state.out, state.prompt.len + state.col_offset);
}

fn clearScreen(state: *State) !void {
    try ansi_term.clearEntireScreen(state.out);
    try ansi_term.setCursor(state.out, 0, 0);

    try state.out.writeAll(state.prompt);
    try state.out.writeAll(state.line_buffer.items);

    try setCursorColumn(state.out, state.prompt.len + state.col_offset);
}

fn killToEnd(state: *State) !void {
    const duped_buffer = try state.outlive.dupe(u8, state.line_buffer.items[state.col_offset..]);
    try globals.kill_ring.pushFront(state.outlive, duped_buffer);

    state.line_buffer.shrinkRetainingCapacity(state.col_offset);

    try clearFromCursorToLineEnd(state.out);
}

fn killFromStart(state: *State) !void {
    const duped_buffer = try state.outlive.dupe(u8, state.line_buffer.items[0..state.col_offset]);
    try globals.kill_ring.pushFront(state.outlive, duped_buffer);

    var i: usize = 0;
    while (i < state.col_offset and
        (i + state.col_offset) < state.line_buffer.items.len) : (i += 1)
    {
        state.line_buffer.items[i] = state.line_buffer.items[i + state.col_offset];
    }
    state.line_buffer.shrinkRetainingCapacity(state.line_buffer.items.len - state.col_offset);
    state.col_offset = 0;

    try setCursorColumn(state.out, 0);
    try clearFromCursorToLineEnd(state.out);
    try state.out.print("{s}{s}", .{ state.prompt, state.line_buffer.items });
    try setCursorColumn(state.out, state.prompt.len + state.col_offset);
}

fn killCurrentWordEnd(state: *State) !void {
    var word_offset = state.col_offset;
    const len = state.line_buffer.items.len;
    if (state.col_offset == len) return;

    const isAN = std.ascii.isAlphanumeric;
    if (!isAN(state.line_buffer.items[word_offset])) {
        while (word_offset < len and !isAN(state.line_buffer.items[word_offset]))
            word_offset += 1;
    }
    while (word_offset < len and isAN(state.line_buffer.items[word_offset])) {
        word_offset += 1;
    }

    const killed_text = try state.outlive.dupe(
        u8,
        state.line_buffer.items[state.col_offset..word_offset],
    );
    try globals.kill_ring.pushFront(state.outlive, killed_text);

    for (state.col_offset..word_offset) |i| {
        state.line_buffer.items[i] = state.line_buffer.items[i + killed_text.len];
    }

    const new_len = state.line_buffer.items.len - (word_offset - state.col_offset);
    state.line_buffer.shrinkRetainingCapacity(new_len);

    try clearFromCursorToLineEnd(state.out);
    try state.out.writeAll(state.line_buffer.items[state.col_offset..]);
    try setCursorColumn(state.out, state.prompt.len + state.col_offset);
}

fn killCurrentWordStart(state: *State) !void {
    const prev_col_offset = @min(state.col_offset, state.line_buffer.items.len);
    if (prev_col_offset == 0) return;
    std.debug.assert(state.line_buffer.items.len > 0);

    const isAN = std.ascii.isAlphanumeric;
    if (!isAN(state.line_buffer.items[state.col_offset - 1])) {
        while (state.col_offset > 0 and !isAN(state.line_buffer.items[state.col_offset - 1]))
            state.col_offset -= 1;
    }
    while (state.col_offset > 0 and isAN(state.line_buffer.items[state.col_offset - 1])) {
        state.col_offset -= 1;
    }

    const copy = state.line_buffer.items[state.col_offset..prev_col_offset];
    const duped_buffer = try state.outlive.dupe(u8, copy);
    try globals.kill_ring.pushFront(state.outlive, duped_buffer);

    try state.line_buffer.replaceRange(
        state.outlive,
        state.col_offset,
        state.line_buffer.items.len - prev_col_offset,
        state.line_buffer.items[prev_col_offset..],
    );

    const new_len = state.line_buffer.items.len - (prev_col_offset - state.col_offset);
    state.line_buffer.shrinkRetainingCapacity(new_len);

    try setCursorColumn(state.out, state.prompt.len + state.col_offset);
    try clearFromCursorToLineEnd(state.out);
    try state.out.writeAll(state.line_buffer.items[state.col_offset..]);
    try setCursorColumn(state.out, state.prompt.len + state.col_offset);
}

fn killToWhitespace(state: *State) !void {
    if (state.col_offset == 0) return;
    std.debug.assert(state.line_buffer.items.len > 0);

    const prev_col_offset = state.col_offset;

    if (std.ascii.isWhitespace(state.line_buffer.items[state.col_offset - 1])) {
        while (state.col_offset > 0 and
            std.ascii.isWhitespace(state.line_buffer.items[state.col_offset - 1]))
            state.col_offset -= 1;
    }
    while (state.col_offset > 0 and
        !std.ascii.isWhitespace(state.line_buffer.items[state.col_offset - 1]))
        state.col_offset -= 1;

    const duped_buffer = try state.outlive.dupe(
        u8,
        state.line_buffer.items[state.col_offset..prev_col_offset],
    );
    try globals.kill_ring.pushFront(state.outlive, duped_buffer);

    try state.line_buffer.replaceRange(
        state.temp,
        state.col_offset,
        state.line_buffer.items.len - prev_col_offset,
        state.line_buffer.items[prev_col_offset..],
    );

    const new_len = state.line_buffer.items.len - (prev_col_offset - state.col_offset);
    state.line_buffer.shrinkRetainingCapacity(new_len);

    try setCursorColumn(state.out, state.prompt.len + state.col_offset);
    try clearFromCursorToLineEnd(state.out);
    try state.out.writeAll(state.line_buffer.items[state.col_offset..]);
    try setCursorColumn(state.out, state.prompt.len + state.col_offset);
}

fn yankText(state: *State) !void {
    if (globals.kill_ring.len == 0) {
        try state.out.writeByte(control_code.bel);
        state.bytes_read = 0;
        return;
    }

    const copy = globals.kill_ring.front().?;
    try state.line_buffer.insertSlice(state.temp, state.col_offset, copy);
    try state.out.writeAll(state.line_buffer.items[state.col_offset..]);

    state.col_offset += copy.len;
    try setCursorColumn(state.out, state.prompt.len + state.col_offset);
}

fn yankRotate(state: *State) !void {
    if (!state.is_yankable) {
        try state.out.writeByte(control_code.bel);
        state.bytes_read = 0;
        return;
    }
    const prev = globals.kill_ring.popFront().?;
    try globals.kill_ring.pushBack(state.outlive, prev);

    const next = globals.kill_ring.front().?;

    state.col_offset -= prev.len;
    for (0..prev.len) |_| {
        _ = state.line_buffer.orderedRemove(state.col_offset);
    }

    try state.line_buffer.insertSlice(state.temp, state.col_offset, next);
    state.col_offset += next.len;

    try setCursorColumn(state.out, state.prompt.len);
    try clearFromCursorToLineEnd(state.out);
    try state.out.writeAll(state.line_buffer.items);
    try setCursorColumn(state.out, state.prompt.len + state.col_offset);
}

fn undo(state: *State) !void {
    if (state.edit_stack.items.len == 0) return;

    state.line_buffer.clearRetainingCapacity();
    try state.line_buffer.appendSlice(state.temp, state.edit_stack.pop().?);

    state.col_offset = @min(state.col_offset, state.line_buffer.items.len);

    try setCursorColumn(state.out, state.prompt.len);
    try clearFromCursorToLineEnd(state.out);
    try state.out.writeAll(state.line_buffer.items);
    try setCursorColumn(state.out, state.prompt.len + state.col_offset);
}

fn printChar(state: *State) !void {
    // If you are editing a line that was populated from history,
    // then you need to include a backstop for undo's
    const is_last_entry = state.history_index + 1 == globals.history_entries.items.len;
    if (!is_last_entry and state.edit_stack.items.len == 0) {
        const duped_finished_line = try state.temp.dupe(u8, state.line_buffer.items);
        try state.edit_stack.append(state.temp, duped_finished_line);
    }

    try state.line_buffer.insert(state.temp, state.col_offset, state.in_buffer[0]);
    try state.out.writeAll(state.line_buffer.items[state.col_offset..]);

    state.col_offset += 1;
    try setCursorColumn(state.out, state.prompt.len + state.col_offset);
}

fn doNothing(_: *State) !void {}

fn historyBack(state: *State) !void {
    if (!globals.is_using_history or state.history_index == 0) {
        return;
    }

    if (state.history_index + 1 == globals.history_entries.items.len) {
        globals.history_entries.items[state.history_index] =
            try state.temp.dupe(u8, state.line_buffer.items);
    }
    state.edit_stack.clearRetainingCapacity();

    state.history_index -= 1;

    state.line_buffer.clearRetainingCapacity();
    try state.line_buffer.appendSlice(
        state.temp,
        globals.history_entries.items[state.history_index],
    );

    try setCursorColumn(state.out, state.prompt.len);
    try clearFromCursorToLineEnd(state.out);
    try state.out.writeAll(state.line_buffer.items);
    state.col_offset = state.line_buffer.items.len;
}

fn historyForward(state: *State) !void {
    const is_last_entry = state.history_index + 1 == globals.history_entries.items.len;
    if (!globals.is_using_history or is_last_entry) {
        return;
    }

    state.edit_stack.clearRetainingCapacity();
    state.history_index += 1;

    state.line_buffer.clearRetainingCapacity();
    try state.line_buffer.appendSlice(
        state.temp,
        globals.history_entries.items[state.history_index],
    );

    try setCursorColumn(state.out, state.prompt.len);
    try clearFromCursorToLineEnd(state.out);
    try state.out.writeAll(state.line_buffer.items);
    state.col_offset = state.line_buffer.items.len;
}

fn historyBeginning(state: *State) !void {
    if (!globals.is_using_history or globals.history_entries.items.len < 2) return;

    state.edit_stack.clearRetainingCapacity();
    state.history_index = 0;

    state.line_buffer.clearRetainingCapacity();
    try state.line_buffer.appendSlice(state.temp, globals.history_entries.items[0]);

    try setCursorColumn(state.out, state.prompt.len);
    try clearFromCursorToLineEnd(state.out);
    try state.out.writeAll(state.line_buffer.items);
    state.col_offset = state.line_buffer.items.len;
}

fn historyEnd(state: *State) !void {
    if (!globals.is_using_history or globals.history_entries.items.len < 2) return;

    state.edit_stack.clearRetainingCapacity();
    state.history_index = globals.history_entries.items.len - 2;

    state.line_buffer.clearRetainingCapacity();
    try state.line_buffer.appendSlice(state.temp, globals.history_entries.items[state.history_index]);

    try setCursorColumn(state.out, state.prompt.len);
    try clearFromCursorToLineEnd(state.out);
    try state.out.writeAll(state.line_buffer.items);
    state.col_offset = state.line_buffer.items.len;
}

fn acceptLine(_: *State) !void {
    return error.NewLine;
}

test "Parse Input File" {
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    var actual = std.StringHashMapUnmanaged(CommandFnPair).empty;
    const flags = std.fs.File.CreateFlags{ .read = true, .truncate = false };
    const inputrc = try std.fs.cwd().createFile(".inputrc", flags);
    try parseInputFile(arena_alloc.allocator(), &actual, inputrc);

    const ctrl_u_positive, const ctrl_u_negative = actual.get(&.{0x15}) orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqual(moveBeginningLine, ctrl_u_positive);
    try std.testing.expectEqual(moveEndLine, ctrl_u_negative);

    const meta_o_positive, const meta_o_negative = actual.get(&.{ control_code.esc, 'o' }).?;

    try std.testing.expectEqual(moveForwardOneWord, meta_o_positive);
    try std.testing.expectEqual(moveBackOneWord, meta_o_negative);
}
