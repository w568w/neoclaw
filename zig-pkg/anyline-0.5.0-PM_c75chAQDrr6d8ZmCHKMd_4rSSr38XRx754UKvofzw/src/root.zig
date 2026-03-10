const globals = @import("app/globals.zig");
const history = @import("app/history.zig");
const read_line = @import("app/read_line.zig");

pub const freeHistory = globals.freeHistory;
pub const freeKillRing = globals.freeKillRing;

pub const addHistory = history.addHistory;
pub const readHistory = history.readHistory;
pub const usingHistory = history.usingHistory;
pub const writeHistory = history.writeHistory;

pub const readLine = read_line.readLine;

test {
    _ = read_line;
}
