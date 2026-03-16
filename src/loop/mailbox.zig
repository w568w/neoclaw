const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// A thread-safe MPMC queue, similar to an unbounded version of std.Io.Queue.
///
/// Unlike Io.Queue, this queue has no fixed capacity: `put` never blocks on
/// space (it grows the backing ArrayList instead). Consumers block in
/// `takeBatch` when the queue is empty and are woken by producers.
pub fn Mailbox(Elem: type) type {
    return struct {
        items: std.ArrayList(Elem) = .empty,
        mutex: Io.Mutex = .init,
        cond: Io.Condition = .init,

        /// Appends a single element to the queue. Never blocks on capacity.
        /// Uses lockUncancelable — the producer is never interrupted.
        /// On allocation failure, `elem` is not consumed; the caller retains
        /// ownership and is responsible for freeing it.
        pub fn put(self: *@This(), io: Io, allocator: Allocator, elem: Elem) Allocator.Error!void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            try self.items.append(allocator, elem);
            self.cond.signal(io);
        }

        /// Takes all pending elements as a batch, blocking when the queue is
        /// empty. Returns error.Canceled when the Io task is canceled.
        ///
        /// The returned ArrayList is owned by the caller.
        pub fn takeBatch(self: *@This(), io: Io) Io.Cancelable!std.ArrayList(Elem) {
            try self.mutex.lock(io);
            errdefer self.mutex.unlock(io);

            while (self.items.items.len == 0) {
                try self.cond.wait(io, &self.mutex);
            }

            const batch = self.items;
            self.items = .empty;
            self.mutex.unlock(io);
            return batch;
        }

        /// Drains all pending elements without blocking. Uses lockUncancelable.
        /// The returned ArrayList is owned by the caller (may be empty).
        pub fn drain(self: *@This(), io: Io) std.ArrayList(Elem) {
            self.mutex.lockUncancelable(io);
            const batch = self.items;
            self.items = .empty;
            self.mutex.unlock(io);
            return batch;
        }

        /// Releases the underlying ArrayList storage. Does NOT free the
        /// elements themselves — the caller must drain or deinit elements
        /// before calling this.
        pub fn deinit(self: *@This(), allocator: Allocator) void {
            self.items.deinit(allocator);
            self.* = undefined;
        }
    };
}
