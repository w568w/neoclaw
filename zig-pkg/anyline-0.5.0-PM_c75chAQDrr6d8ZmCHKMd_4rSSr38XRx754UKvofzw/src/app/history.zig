const std = @import("std");
const Allocator = std.mem.Allocator;

const globals = @import("globals.zig");
const supported_os = @import("supported_os.zig");

pub const AddHistoryError = error{} || Allocator.Error;

pub const WriteHistoryError =
    error{HomePathNotFound} ||
    std.fs.File.OpenError ||
    std.process.GetEnvVarOwnedError ||
    std.fs.File.WriteError;

pub const ReadHistoryError =
    error{HomePathNotFound} ||
    std.fs.File.OpenError ||
    std.process.GetEnvVarOwnedError ||
    std.Io.Reader.LimitedAllocError;

pub fn usingHistory() void {
    globals.is_using_history = true;
}

pub fn addHistory(alloc: Allocator, line: []const u8) AddHistoryError!void {
    const duped_line = try alloc.dupe(u8, line);
    try globals.history_entries.append(alloc, duped_line);
}

pub fn writeHistory(alloc: Allocator, maybe_absolute_path: ?[]const u8) WriteHistoryError!void {
    defer {
        globals.freeHistory(alloc);
        globals.freeKillRing(alloc);
    }
    var file = try openHistoryFile(alloc, maybe_absolute_path);
    defer file.close();

    const all_entries = try std.mem.join(alloc, supported_os.NEW_LINE, globals.history_entries.items);
    defer alloc.free(all_entries);

    try file.writeAll(all_entries);
}

pub fn readHistory(alloc: Allocator, maybe_absolute_path: ?[]const u8) ReadHistoryError!void {
    globals.is_using_history = true;

    var file = try openHistoryFile(alloc, maybe_absolute_path);
    defer file.close();

    var buffer: [1024]u8 = undefined;
    var reader = file.readerStreaming(&buffer);
    const data = try reader.interface.allocRemaining(alloc, .unlimited);
    defer alloc.free(data);

    var iterator = std.mem.tokenizeSequence(u8, data, supported_os.NEW_LINE);
    while (iterator.next()) |line| {
        const duped_line = try alloc.dupe(u8, line);
        try globals.history_entries.append(alloc, duped_line);
    }
}

fn openHistoryFile(alloc: std.mem.Allocator, absolute_path_maybe: ?[]const u8) !std.fs.File {
    const flags = std.fs.File.CreateFlags{ .read = true, .truncate = false };
    if (absolute_path_maybe) |absolute_path| {
        return try std.fs.createFileAbsolute(absolute_path, flags);
    }

    const home_path = std.process.getEnvVarOwned(alloc, supported_os.ENV_HOME_PATH) catch |err| {
        switch (err) {
            error.OutOfMemory => std.c._errno().* = @intFromEnum(std.c.E.NOMEM),
            error.EnvironmentVariableNotFound => std.c._errno().* = @intFromEnum(std.c.E.NOENT),
            error.InvalidWtf8 => unreachable,
        }
        return error.HomePathNotFound;
    };
    defer alloc.free(home_path);

    var home_dir = try std.fs.openDirAbsolute(home_path, std.fs.Dir.OpenOptions{});
    defer home_dir.close();

    return try home_dir.createFile(".history", flags);
}
