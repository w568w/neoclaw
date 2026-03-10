const std = @import("std");

const supported_os = @import("../app/supported_os.zig");

const string = @cImport(@cInclude("string.h"));
const unistd = @cImport(@cInclude("unistd.h"));

old_termios: std.posix.termios,

const Unix = @This();

pub const Error = std.posix.TermiosGetError || std.posix.TermiosSetError;

pub fn init() Error!Unix {
    const stdin_handle = std.fs.File.stdin().handle;
    const old_termios: std.posix.termios = try std.posix.tcgetattr(stdin_handle);

    var new_termios = old_termios;
    new_termios.lflag.ICANON = false;
    new_termios.lflag.ECHO = false;

    new_termios.cc[@intFromEnum(std.posix.V.INTR)] = unistd._POSIX_VDISABLE;
    if (supported_os.SUPPORTED_OS.isBSD()) {
        new_termios.cc[@intFromEnum(std.posix.V.DSUSP)] = unistd._POSIX_VDISABLE;
        new_termios.cc[@intFromEnum(std.posix.V.SUSP)] = unistd._POSIX_VDISABLE;
    }

    try std.posix.tcsetattr(stdin_handle, std.posix.TCSA.NOW, new_termios);

    return Unix{ .old_termios = old_termios };
}

pub fn deinit(unix: Unix) void {
    const stdin_handle = std.fs.File.stdin().handle;

    std.posix.tcsetattr(stdin_handle, std.posix.TCSA.NOW, unix.old_termios) catch {
        const errno_val = std.c._errno().*;
        const errno_string = string.strerror(errno_val);

        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);

        stderr_writer.interface.print("{s}\n", .{errno_string}) catch {};
    };
}
