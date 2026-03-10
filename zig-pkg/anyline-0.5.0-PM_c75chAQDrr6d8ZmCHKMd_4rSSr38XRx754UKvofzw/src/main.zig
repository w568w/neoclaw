const std = @import("std");

const anyline = @import("root.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const outlive_allocator = gpa.allocator();

    anyline.usingHistory();

    const path = "/home/theshinx317/Coding/Zig/anyline/.history";
    try anyline.readHistory(outlive_allocator, path);
    errdefer {
        anyline.freeHistory(outlive_allocator);
        anyline.freeKillRing(outlive_allocator);
    }

    while (true) {
        const line = anyline.readLine(outlive_allocator, ">> ") catch |err| switch (err) {
            error.ProcessExit => std.process.exit(130),
            else => return err,
        };
        defer outlive_allocator.free(line);

        if (std.mem.eql(u8, line, ".exit")) {
            break;
        } else if (line.len > 0) {
            try anyline.addHistory(outlive_allocator, line);
        }
    }

    try anyline.writeHistory(outlive_allocator, path);
}
