const std = @import("std");

const CSI = "\x1B[";

pub fn setCursorColumn(out: *std.Io.Writer, column: usize) !void {
    try out.print(CSI ++ "{}G", .{column + 1});
}

pub fn setCursor(out: *std.Io.Writer, x: usize, y: usize) !void {
    try out.print(CSI ++ "{};{}H", .{ y + 1, x + 1 });
}

pub fn clearFromCursorToLineEnd(out: *std.Io.Writer) !void {
    try out.writeAll(CSI ++ "K");
}

pub fn clearEntireScreen(out: *std.Io.Writer) !void {
    try out.writeAll(CSI ++ "2J");
}

pub fn queryCursorPosition(out: *std.Io.Writer) !void {
    try out.writeAll(CSI ++ "6n");
}
