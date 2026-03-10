const std = @import("std");

const zero_width_cf = @import("wcwidth_manual.zig").zero_width_cf;
const wide_eastasian = @import("wcwidth_table_wide.zig").wide_eastasian;
const zero_width = @import("wcwidth_table_zero.zig").zero_width;

fn tableBisearch(ucs: u21, table: []const [2]u21) bool {
    if (table.len == 0) return false;

    var low: usize = 0;
    var high: usize = table.len - 1;

    if (ucs < table[low][0] or ucs > table[high][1]) return false;

    while (high >= low) {
        const mid = (low + high) / 2;
        if (ucs > table[mid][1]) {
            low = mid + 1;
        } else if (ucs < table[mid][0]) {
            if (mid == 0) return false;
            high = mid - 1;
        } else {
            return true;
        }
    }

    return false;
}

fn listBisearch(ucs: u21, list: []const u21) bool {
    if (list.len == 0) return false;

    var low: usize = 0;
    var high: usize = list.len - 1;

    if (ucs < list[low] or ucs > list[high]) return false;

    while (high >= low) {
        const mid = (low + high) / 2;
        if (ucs > list[mid]) {
            low = mid + 1;
        } else if (ucs < list[mid]) {
            if (mid == 0) return false;
            high = mid - 1;
        } else {
            return true;
        }
    }

    return false;
}

/// Returns terminal column width for one Unicode codepoint.
/// - `-1`: control/non-printable
/// - `0`: zero-width
/// - `1` or `2`: printable width
pub fn wcwidth(cp: u21) i8 {
    if (listBisearch(cp, &zero_width_cf)) return 0;
    if (cp < 32 or (cp >= 0x7f and cp < 0xa0)) return -1;
    if (tableBisearch(cp, &zero_width)) return 0;
    if (tableBisearch(cp, &wide_eastasian)) return 2;
    return 1;
}

/// Returns terminal display width of a UTF-8 slice.
/// Invalid UTF-8 bytes are counted as width 1.
pub fn utf8Width(s: []const u8) usize {
    const view = std.unicode.Utf8View.init(s) catch return s.len;
    var it = view.iterator();
    var width: usize = 0;
    while (it.nextCodepoint()) |cp| {
        const w = wcwidth(cp);
        if (w > 0) width += @as(usize, @intCast(w));
    }
    return width;
}

test "wcwidth basic" {
    try std.testing.expectEqual(@as(i8, 1), wcwidth('a'));
    try std.testing.expectEqual(@as(i8, 2), wcwidth('中'));
    try std.testing.expectEqual(@as(i8, 0), wcwidth(0x0301));
}

test "utf8Width combining" {
    try std.testing.expectEqual(@as(usize, 1), utf8Width("e\u{0301}"));
    try std.testing.expectEqual(@as(usize, 2), utf8Width("中"));
}
