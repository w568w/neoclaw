const std = @import("std");

const deque = @import("../vendored/deque.zig");

pub var is_using_history = false;

pub var history_entries = std.ArrayListUnmanaged([]const u8).empty;
pub fn freeHistory(alloc: std.mem.Allocator) void {
    for (history_entries.items) |entry| {
        alloc.free(entry);
    }
    history_entries.clearAndFree(alloc);
}

pub var kill_ring = deque.Deque([]const u8).empty;
pub fn freeKillRing(alloc: std.mem.Allocator) void {
    for (0..kill_ring.len) |i| {
        alloc.free(kill_ring.at(i));
    }
    kill_ring.deinit(alloc);
}
