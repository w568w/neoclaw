const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// A thread-safe MPMC queue, similar to an unbounded version of std.Io.Queue.
///
/// Unlike Io.Queue, this queue has no fixed capacity: `put` never blocks on
/// space. `putFront` allows high-priority elements to be inserted at the head.
/// Consumers block in `take` when the queue is empty and are woken by
/// producers. All list operations are O(1).
pub fn Mailbox(Elem: type) type {
    return struct {
        const Node = struct {
            link: std.DoublyLinkedList.Node = .{},
            data: Elem,
        };

        list: std.DoublyLinkedList = .{},
        mutex: Io.Mutex = .init,
        cond: Io.Condition = .init,

        /// Appends a single element to the tail of the queue.
        /// Uses lockUncancelable — the producer is never interrupted.
        /// On allocation failure, `elem` is not consumed; the caller retains
        /// ownership and is responsible for freeing it.
        pub fn put(self: *@This(), io: Io, allocator: Allocator, elem: Elem) Allocator.Error!void {
            const node = try allocator.create(Node);
            node.* = .{ .data = elem };
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.list.append(&node.link);
            self.cond.signal(io);
        }

        /// Prepends a single element to the head of the queue.
        /// Uses lockUncancelable — the producer is never interrupted.
        /// On allocation failure, `elem` is not consumed; the caller retains
        /// ownership and is responsible for freeing it.
        pub fn putFront(self: *@This(), io: Io, allocator: Allocator, elem: Elem) Allocator.Error!void {
            const node = try allocator.create(Node);
            node.* = .{ .data = elem };
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.list.prepend(&node.link);
            self.cond.signal(io);
        }

        /// Removes and returns the first element, blocking when the queue is
        /// empty. Returns error.Canceled when the Io task is canceled.
        /// The node is freed internally; the caller receives ownership of the
        /// element value only.
        pub fn take(self: *@This(), io: Io, allocator: Allocator) Io.Cancelable!Elem {
            try self.mutex.lock(io);
            errdefer self.mutex.unlock(io);

            while (self.list.first == null) {
                try self.cond.wait(io, &self.mutex);
            }

            const link = self.list.popFirst().?;
            self.mutex.unlock(io);

            const node: *Node = @fieldParentPtr("link", link);
            const elem = node.data;
            allocator.destroy(node);
            return elem;
        }

        /// Atomically removes all nodes from the mailbox and destroys them.
        /// If `free_elem` is provided, it is called for each element before
        /// its node is destroyed, allowing the caller to release owned
        /// resources within the element.
        /// The entire operation runs under the mailbox mutex so no producer
        /// can insert new elements while the drain is in progress.
        /// The mailbox remains usable after this call.
        pub fn removeAll(
            self: *@This(),
            io: Io,
            allocator: Allocator,
            free_elem: ?*const fn (*Elem, Allocator) void,
        ) void {
            self.mutex.lockUncancelable(io);
            while (self.list.popFirst()) |link| {
                const node: *Node = @fieldParentPtr("link", link);
                if (free_elem) |f| f(&node.data, allocator);
                allocator.destroy(node);
            }
            self.mutex.unlock(io);
        }

        /// Atomically drains all nodes and releases their memory, then
        /// invalidates the mailbox. If `free_elem` is provided, it is
        /// called for each element before its node is destroyed.
        /// See `removeAll` for details on atomicity.
        pub fn deinit(
            self: *@This(),
            io: Io,
            allocator: Allocator,
            free_elem: ?*const fn (*Elem, Allocator) void,
        ) void {
            self.removeAll(io, allocator, free_elem);
            self.* = undefined;
        }
    };
}
