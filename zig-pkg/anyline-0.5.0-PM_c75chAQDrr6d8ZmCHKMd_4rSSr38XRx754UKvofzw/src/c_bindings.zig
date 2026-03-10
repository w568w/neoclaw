const std = @import("std");

const read_line = @import("app/read_line.zig");
const history = @import("app/history.zig");

const alloc = std.heap.raw_c_allocator;

export fn readline(prompt: [*c]const u8) [*c]u8 {
    const prompt_slice = std.mem.span(prompt);
    const line_slice = read_line.readLine(alloc, prompt_slice) catch |err| switch (err) {
        error.ProcessExit => std.process.exit(130),
        else => return null,
    };
    var line_slice_z = alloc.realloc(line_slice, line_slice.len + 1) catch {
        return null;
    };
    line_slice_z[line_slice_z.len - 1] = 0;
    return @ptrCast(@alignCast(line_slice_z.ptr));
}

export fn add_history(line: [*c]const u8) void {
    const line_slice = if (line) |l| std.mem.span(l) else "";
    history.addHistory(alloc, line_slice) catch {};
}

export fn read_history(filename: [*c]const u8) c_int {
    const maybe_absolute_path = if (filename) |f| std.mem.span(f) else null;
    history.readHistory(alloc, maybe_absolute_path) catch {
        return std.c._errno().*;
    };
    return 0;
}

export fn write_history(filename: [*c]const u8) c_int {
    const maybe_absolute_path = if (filename) |f| std.mem.span(f) else null;
    history.writeHistory(alloc, maybe_absolute_path) catch {
        return std.c._errno().*;
    };
    return 0;
}

export fn using_history() void {
    history.usingHistory();
}
