const std = @import("std");
const wc = @import("wcwidth.zig");
const grapheme = @import("grapheme.zig");
const Terminal = @import("terminal.zig").Terminal;

const Allocator = std.mem.Allocator;

pub const LineEditor = struct {
    allocator: Allocator,
    buf: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    history_entries: std.ArrayList([]const u8) = .empty,
    history_index: usize = 0,
    saved_line: std.ArrayList(u8) = .empty,
    terminal: Terminal = .{},

    pub fn init(allocator: Allocator) LineEditor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LineEditor) void {
        self.buf.deinit(self.allocator);
        self.saved_line.deinit(self.allocator);
        for (self.history_entries.items) |entry| self.allocator.free(entry);
        self.history_entries.deinit(self.allocator);
    }

    /// Reads a line with editing support. Returns owned slice, or null on EOF/Ctrl-D.
    pub fn readLine(self: *LineEditor, prompt: []const u8) !?[]const u8 {
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        self.history_index = self.history_entries.items.len;
        self.saved_line.clearRetainingCapacity();

        const raw_enabled = self.terminal.enableRawMode() catch |err| {
            if (err == error.NotATerminal) return self.readLineCooked(prompt);
            return err;
        };
        if (!raw_enabled) return self.readLineCooked(prompt);
        defer self.terminal.disableRawMode();

        self.terminal.writeAll(prompt);

        while (true) {
            const b = self.terminal.readByte() catch return null;

            if (b == '\r' or b == '\n') {
                self.terminal.writeAll("\r\n");
                return try self.allocator.dupe(u8, self.buf.items);
            }

            if (b == 4) { // Ctrl-D
                if (self.buf.items.len == 0) {
                    self.terminal.writeAll("\r\n");
                    return null;
                }
                continue;
            }

            if (b == 3) { // Ctrl-C
                self.buf.clearRetainingCapacity();
                self.cursor = 0;
                self.terminal.writeAll("^C\r\n");
                self.terminal.writeAll(prompt);
                continue;
            }

            if (b == 127 or b == 8) { // Backspace / Ctrl-H
                if (self.cursor > 0) {
                    const prev_len = grapheme.prevLen(self.buf.items, self.cursor);
                    const from = self.cursor - prev_len;
                    std.mem.copyForwards(u8, self.buf.items[from..], self.buf.items[self.cursor..]);
                    self.buf.items.len -= prev_len;
                    self.cursor -= prev_len;
                    self.refreshLine(prompt);
                }
                continue;
            }

            if (b == 27) { // ESC
                const b2 = self.terminal.readByte() catch continue;
                if (b2 == '[') {
                    const b3 = self.terminal.readByte() catch continue;
                    const csi = self.parseCsi(b3) orelse continue;
                    switch (csi.final) {
                        'A' => { // Up
                            try self.historyPrev(prompt);
                            continue;
                        },
                        'B' => { // Down
                            try self.historyNext(prompt);
                            continue;
                        },
                        'C' => { // Right
                            if (csi.ctrl) {
                                const next = moveWordRight(self.buf.items, self.cursor);
                                if (next != self.cursor) {
                                    self.cursor = next;
                                    self.refreshLine(prompt);
                                }
                            } else if (self.cursor < self.buf.items.len) {
                                self.cursor += grapheme.nextLen(self.buf.items, self.cursor);
                                self.refreshLine(prompt);
                            }
                            continue;
                        },
                        'D' => { // Left
                            if (csi.ctrl) {
                                const prev = moveWordLeft(self.buf.items, self.cursor);
                                if (prev != self.cursor) {
                                    self.cursor = prev;
                                    self.refreshLine(prompt);
                                }
                            } else if (self.cursor > 0) {
                                self.cursor -= grapheme.prevLen(self.buf.items, self.cursor);
                                self.refreshLine(prompt);
                            }
                            continue;
                        },
                        'H' => { // Home
                            self.cursor = 0;
                            self.refreshLine(prompt);
                            continue;
                        },
                        'F' => { // End
                            self.cursor = self.buf.items.len;
                            self.refreshLine(prompt);
                            continue;
                        },
                        '~' => {
                            if (csi.p1 == 3) { // Delete key (ESC [ 3 ~)
                                if (self.cursor < self.buf.items.len) {
                                    const next_len = grapheme.nextLen(self.buf.items, self.cursor);
                                    std.mem.copyForwards(u8, self.buf.items[self.cursor..], self.buf.items[self.cursor + next_len ..]);
                                    self.buf.items.len -= next_len;
                                    self.refreshLine(prompt);
                                }
                            }
                            continue;
                        },
                        else => continue,
                    }
                }
                continue;
            }

            if (b == 1) { // Ctrl-A (Home)
                self.cursor = 0;
                self.refreshLine(prompt);
                continue;
            }

            if (b == 5) { // Ctrl-E (End)
                self.cursor = self.buf.items.len;
                self.refreshLine(prompt);
                continue;
            }

            if (b == 11) { // Ctrl-K (kill to end)
                self.buf.items.len = self.cursor;
                self.refreshLine(prompt);
                continue;
            }

            if (b == 21) { // Ctrl-U (kill to start)
                std.mem.copyForwards(u8, self.buf.items[0..], self.buf.items[self.cursor..]);
                self.buf.items.len -= self.cursor;
                self.cursor = 0;
                self.refreshLine(prompt);
                continue;
            }

            if (b == 12) { // Ctrl-L (clear screen)
                self.terminal.writeAll("\x1b[2J\x1b[H");
                self.refreshLine(prompt);
                continue;
            }

            // Regular character (printable or UTF-8 leading byte)
            if (b >= 32) {
                const char_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
                var char_buf: [4]u8 = undefined;
                char_buf[0] = b;
                var i: usize = 1;
                while (i < char_len) : (i += 1) {
                    char_buf[i] = self.terminal.readByte() catch break;
                }
                if (i == char_len) {
                    const insert_pos = self.cursor;
                    try self.buf.insertSlice(self.allocator, insert_pos, char_buf[0..char_len]);
                    self.cursor += char_len;
                    self.refreshLine(prompt);
                }
                continue;
            }
        }
    }

    fn readLineCooked(self: *LineEditor, prompt: []const u8) !?[]const u8 {
        self.terminal.writeAll(prompt);
        while (true) {
            const b = self.terminal.readByte() catch |err| switch (err) {
                error.EndOfStream => {
                    if (self.buf.items.len == 0) return null;
                    return try self.allocator.dupe(u8, self.buf.items);
                },
                else => return err,
            };

            if (b == '\n') {
                return try self.allocator.dupe(u8, self.buf.items);
            }
            if (b == '\r') continue;
            try self.buf.append(self.allocator, b);
        }
    }

    pub fn addHistory(self: *LineEditor, line: []const u8) !void {
        if (line.len == 0) return;
        if (self.history_entries.items.len > 0) {
            const last = self.history_entries.items[self.history_entries.items.len - 1];
            if (std.mem.eql(u8, last, line)) return;
        }
        try self.history_entries.append(self.allocator, try self.allocator.dupe(u8, line));
    }

    fn historyPrev(self: *LineEditor, prompt: []const u8) !void {
        if (self.history_entries.items.len == 0) return;
        if (self.history_index == 0) return;

        if (self.history_index == self.history_entries.items.len) {
            self.saved_line.clearRetainingCapacity();
            try self.saved_line.appendSlice(self.allocator, self.buf.items);
        }

        self.history_index -= 1;
        const entry = self.history_entries.items[self.history_index];
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(self.allocator, entry);
        self.cursor = self.buf.items.len;
        self.refreshLine(prompt);
    }

    fn historyNext(self: *LineEditor, prompt: []const u8) !void {
        if (self.history_index >= self.history_entries.items.len) return;

        self.history_index += 1;

        if (self.history_index == self.history_entries.items.len) {
            self.buf.clearRetainingCapacity();
            try self.buf.appendSlice(self.allocator, self.saved_line.items);
            self.cursor = self.buf.items.len;
        } else {
            const entry = self.history_entries.items[self.history_index];
            self.buf.clearRetainingCapacity();
            try self.buf.appendSlice(self.allocator, entry);
            self.cursor = self.buf.items.len;
        }
        self.refreshLine(prompt);
    }

    fn refreshLine(self: *LineEditor, prompt: []const u8) void {
        var out_buf: [8192]u8 = undefined;
        var pos: usize = 0;

        // \r: move to column 0
        out_buf[pos] = '\r';
        pos += 1;

        // write prompt
        @memcpy(out_buf[pos..][0..prompt.len], prompt);
        pos += prompt.len;

        // write buffer content
        const buf_len = self.buf.items.len;
        if (pos + buf_len + 16 > out_buf.len) {
            // fallback: just write what fits
            const avail = out_buf.len - pos - 16;
            @memcpy(out_buf[pos..][0..avail], self.buf.items[0..avail]);
            pos += avail;
        } else {
            @memcpy(out_buf[pos..][0..buf_len], self.buf.items);
            pos += buf_len;
        }

        // \x1b[K: clear to end of line
        @memcpy(out_buf[pos..][0..3], "\x1b[K");
        pos += 3;

        // move cursor to correct column
        const display_cursor = wc.utf8Width(prompt) + wc.utf8Width(self.buf.items[0..self.cursor]);
        const cursor_cmd = std.fmt.bufPrint(out_buf[pos..], "\r\x1b[{d}C", .{display_cursor}) catch return;
        pos += cursor_cmd.len;

        self.terminal.writeAll(out_buf[0..pos]);
    }

    const Csi = struct {
        final: u8,
        p1: usize = 0,
        p2: usize = 0,
        ctrl: bool = false,
    };

    fn parseCsi(self: *LineEditor, first: u8) ?Csi {
        var csi: Csi = .{ .final = first };
        var buf: [16]u8 = undefined;
        var len: usize = 0;
        var b = first;

        while (true) {
            if ((b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or b == '~') {
                csi.final = b;
                break;
            }
            if (len >= buf.len) return null;
            buf[len] = b;
            len += 1;
            b = self.terminal.readByte() catch return null;
        }

        if (len == 0) return csi;

        var it = std.mem.splitScalar(u8, buf[0..len], ';');
        if (it.next()) |p1s| {
            csi.p1 = std.fmt.parseInt(usize, p1s, 10) catch 0;
        }
        if (it.next()) |p2s| {
            csi.p2 = std.fmt.parseInt(usize, p2s, 10) catch 0;
        }
        csi.ctrl = csi.p2 == 5;
        return csi;
    }
};

fn firstCodepointAt(buf: []const u8, pos: usize) u21 {
    const step = grapheme.nextLen(buf, pos);
    if (step == 0) return 0;
    const s = buf[pos .. pos + step];
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
    return switch (n) {
        1 => s[0],
        2 => std.unicode.utf8Decode2(s[0..2].*) catch s[0],
        3 => std.unicode.utf8Decode3AllowSurrogateHalf(s[0..3].*) catch s[0],
        4 => std.unicode.utf8Decode4(s[0..4].*) catch s[0],
        else => s[0],
    };
}

fn isSpaceCp(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r';
}

fn isWordCp(cp: u21) bool {
    if (cp >= 0x80) return true;
    return std.ascii.isAlphanumeric(@as(u8, @truncate(cp))) or cp == '_';
}

fn moveWordRight(buf: []const u8, cursor: usize) usize {
    var i = cursor;
    while (i < buf.len) {
        const cp = firstCodepointAt(buf, i);
        if (!isSpaceCp(cp)) break;
        i += grapheme.nextLen(buf, i);
    }
    if (i >= buf.len) return i;

    const start_cp = firstCodepointAt(buf, i);
    if (isWordCp(start_cp)) {
        while (i < buf.len) {
            const cp = firstCodepointAt(buf, i);
            if (!isWordCp(cp)) break;
            i += grapheme.nextLen(buf, i);
        }
        return i;
    }

    while (i < buf.len) {
        const cp = firstCodepointAt(buf, i);
        if (isSpaceCp(cp) or isWordCp(cp)) break;
        i += grapheme.nextLen(buf, i);
    }
    return i;
}

fn moveWordLeft(buf: []const u8, cursor: usize) usize {
    var i = cursor;
    while (i > 0) {
        const prev = i - grapheme.prevLen(buf, i);
        const cp = firstCodepointAt(buf, prev);
        if (!isSpaceCp(cp)) break;
        i = prev;
    }
    if (i == 0) return 0;

    var prev = i - grapheme.prevLen(buf, i);
    const start_cp = firstCodepointAt(buf, prev);

    if (isWordCp(start_cp)) {
        while (true) {
            const cp = firstCodepointAt(buf, prev);
            if (!isWordCp(cp)) break;
            i = prev;
            if (i == 0) break;
            prev = i - grapheme.prevLen(buf, i);
        }
        return i;
    }

    while (true) {
        const cp = firstCodepointAt(buf, prev);
        if (isSpaceCp(cp) or isWordCp(cp)) break;
        i = prev;
        if (i == 0) break;
        prev = i - grapheme.prevLen(buf, i);
    }
    return i;
}

test "grapheme navigation with combining mark" {
    const s = "e\u{0301}x";
    try std.testing.expectEqual(@as(usize, 3), grapheme.nextLen(s, 0));
    try std.testing.expectEqual(@as(usize, 3), grapheme.prevLen(s, 3));
    try std.testing.expectEqual(@as(usize, 1), grapheme.nextLen(s, 3));
}

test "grapheme navigation with zwj emoji" {
    const s = "👨\u{200D}👩\u{200D}👧!";
    const first = grapheme.nextLen(s, 0);
    try std.testing.expect(first > 4);
    try std.testing.expectEqual(@as(usize, 1), grapheme.nextLen(s, first));
}

test "history dedupe consecutive" {
    var editor = LineEditor.init(std.testing.allocator);
    defer editor.deinit();

    try editor.addHistory("hello");
    try editor.addHistory("hello");
    try editor.addHistory("world");

    try std.testing.expectEqual(@as(usize, 2), editor.history_entries.items.len);
}

test "word motion ctrl arrows" {
    const s = "foo bar_baz!! qux";
    try std.testing.expectEqual(@as(usize, 3), moveWordRight(s, 0));
    try std.testing.expectEqual(@as(usize, 11), moveWordRight(s, 3));
    try std.testing.expectEqual(@as(usize, 13), moveWordRight(s, 11));
    try std.testing.expectEqual(@as(usize, 4), moveWordLeft(s, 11));
    try std.testing.expectEqual(@as(usize, 0), moveWordLeft(s, 3));
}
