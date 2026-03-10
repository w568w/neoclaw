const std = @import("std");
const tables = @import("grapheme_tables.zig");

const Gcb = enum {
    other,
    cr,
    lf,
    control,
    extend,
    zwj,
    regional_indicator,
    prepend,
    spacing_mark,
    l,
    v,
    t,
    lv,
    lvt,
    extended_pictographic,
    incb_consonant,
};

fn inRanges(cp: u21, ranges: []const [2]u21) bool {
    if (ranges.len == 0) return false;
    if (cp < ranges[0][0] or cp > ranges[ranges.len - 1][1]) return false;

    var lo: usize = 0;
    var hi: usize = ranges.len - 1;
    while (lo <= hi) {
        const mid = (lo + hi) / 2;
        const r = ranges[mid];
        if (cp < r[0]) {
            if (mid == 0) return false;
            hi = mid - 1;
        } else if (cp > r[1]) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

fn gcbOf(cp: u21) Gcb {
    if (inRanges(cp, &tables.gcb_cr)) return .cr;
    if (inRanges(cp, &tables.gcb_lf)) return .lf;
    if (inRanges(cp, &tables.gcb_control)) return .control;
    if (inRanges(cp, &tables.gcb_l)) return .l;
    if (inRanges(cp, &tables.gcb_v)) return .v;
    if (inRanges(cp, &tables.gcb_t)) return .t;
    if (inRanges(cp, &tables.gcb_lv)) return .lv;
    if (inRanges(cp, &tables.gcb_lvt)) return .lvt;
    if (inRanges(cp, &tables.gcb_regional_indicator)) return .regional_indicator;
    if (inRanges(cp, &tables.gcb_prepend)) return .prepend;
    if (inRanges(cp, &tables.gcb_spacing_mark)) return .spacing_mark;
    if (inRanges(cp, &tables.gcb_zwj)) return .zwj;
    if (inRanges(cp, &tables.gcb_extend)) return .extend;
    if (inRanges(cp, &tables.gcb_incb_consonant)) return .incb_consonant;
    if (inRanges(cp, &tables.gcb_extended_pictographic)) return .extended_pictographic;
    return .other;
}

fn isIncbExtend(cp: u21) bool {
    return inRanges(cp, &tables.incb_extend);
}

fn isIncbLinker(cp: u21) bool {
    for (tables.incb_linker) |x| {
        if (x == cp) return true;
    }
    return false;
}

fn decodeAt(buf: []const u8, pos: usize) struct { cp: u21, len: usize } {
    if (pos >= buf.len) return .{ .cp = 0, .len = 0 };
    const len = std.unicode.utf8ByteSequenceLength(buf[pos]) catch 1;
    if (pos + len > buf.len) return .{ .cp = buf[pos], .len = 1 };

    const cp: u21 = switch (len) {
        1 => buf[pos],
        2 => std.unicode.utf8Decode2(buf[pos..][0..2].*) catch return .{ .cp = buf[pos], .len = 1 },
        3 => std.unicode.utf8Decode3AllowSurrogateHalf(buf[pos..][0..3].*) catch return .{ .cp = buf[pos], .len = 1 },
        4 => std.unicode.utf8Decode4(buf[pos..][0..4].*) catch return .{ .cp = buf[pos], .len = 1 },
        else => return .{ .cp = buf[pos], .len = 1 },
    };
    return .{ .cp = cp, .len = len };
}

fn prevCodepointStart(buf: []const u8, pos: usize) ?usize {
    if (pos == 0) return null;
    var i = pos - 1;
    var n: usize = 0;
    while (i > 0 and n < 3 and (buf[i] & 0xC0) == 0x80) : (n += 1) {
        i -= 1;
    }
    return i;
}

fn noBreakGb11(buf: []const u8, cluster_start: usize, curr_start: usize, curr_cat: Gcb) bool {
    if (curr_cat != .extended_pictographic) return false;
    const zwj_start = prevCodepointStart(buf, curr_start) orelse return false;
    const zwj = decodeAt(buf, zwj_start);
    if (gcbOf(zwj.cp) != .zwj) return false;

    var i_opt = prevCodepointStart(buf, zwj_start);
    while (i_opt) |i| {
        if (i < cluster_start) break;
        const d = decodeAt(buf, i);
        const cat = gcbOf(d.cp);
        if (cat == .extend) {
            i_opt = prevCodepointStart(buf, i);
            continue;
        }
        return cat == .extended_pictographic;
    }
    return false;
}

fn noBreakGb9c(buf: []const u8, cluster_start: usize, curr_start: usize, curr_cat: Gcb) bool {
    if (curr_cat != .incb_consonant) return false;
    const prev_start = prevCodepointStart(buf, curr_start) orelse return false;

    var i = prev_start;
    var saw_linker = false;
    while (true) {
        if (i < cluster_start) return false;
        const d = decodeAt(buf, i);
        if (isIncbLinker(d.cp)) {
            saw_linker = true;
        } else if (!isIncbExtend(d.cp)) {
            break;
        }
        i = prevCodepointStart(buf, i) orelse return false;
    }
    return saw_linker and gcbOf(decodeAt(buf, i).cp) == .incb_consonant;
}

fn noBreak(buf: []const u8, cluster_start: usize, curr_start: usize, before: Gcb, after: Gcb) bool {

    if (before == .cr and after == .lf) return true;
    if (before == .control or before == .cr or before == .lf) return false;
    if (after == .control or after == .cr or after == .lf) return false;

    if (before == .l and (after == .l or after == .v or after == .lv or after == .lvt)) return true;
    if ((before == .lv or before == .v) and (after == .v or after == .t)) return true;
    if ((before == .lvt or before == .t) and after == .t) return true;

    if (after == .extend or after == .zwj) return true;
    if (after == .spacing_mark) return true;
    if (before == .prepend) return true;

    if (noBreakGb9c(buf, cluster_start, curr_start, after)) return true;
    if (before == .zwj and noBreakGb11(buf, cluster_start, curr_start, after)) return true;

    if (before == .regional_indicator and after == .regional_indicator) {
        var run: usize = 1;
        var i_opt = prevCodepointStart(buf, curr_start);
        if (i_opt == null) return false;
        i_opt = prevCodepointStart(buf, i_opt.?);
        while (i_opt) |i| {
            if (i < cluster_start) break;
            const d = decodeAt(buf, i);
            if (gcbOf(d.cp) != .regional_indicator) break;
            run += 1;
            i_opt = prevCodepointStart(buf, i);
        }
        return (run % 2) == 1;
    }

    return false;
}

pub fn nextLen(buf: []const u8, pos: usize) usize {
    if (pos >= buf.len) return 0;

    const first = decodeAt(buf, pos);
    if (first.len == 0) return 0;

    var p = pos + first.len;
    var prev_cat = gcbOf(first.cp);
    while (p < buf.len) {
        const d = decodeAt(buf, p);
        if (d.len == 0) break;
        const curr_cat = gcbOf(d.cp);
        if (!noBreak(buf, pos, p, prev_cat, curr_cat)) break;
        prev_cat = curr_cat;
        p += d.len;
    }
    return p - pos;
}

pub fn prevLen(buf: []const u8, pos: usize) usize {
    if (pos == 0) return 0;

    var i: usize = 0;
    var prev: usize = 0;
    while (i < pos) {
        prev = i;
        const step = nextLen(buf, i);
        if (step == 0 or i + step > pos) break;
        i += step;
    }
    return pos - prev;
}

test "uax29 combining" {
    const s = "e\u{0301}x";
    try std.testing.expectEqual(@as(usize, 3), nextLen(s, 0));
    try std.testing.expectEqual(@as(usize, 3), prevLen(s, 3));
}

test "uax29 emoji zwj" {
    const s = "👨\u{200D}👩\u{200D}👧!";
    const a = nextLen(s, 0);
    try std.testing.expect(a > 4);
    try std.testing.expectEqual(@as(usize, 1), nextLen(s, a));
}

test "uax29 regional indicator pair" {
    const s = "🇨🇳🇺🇸";
    const a = nextLen(s, 0);
    const b = nextLen(s, a);
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(s.len, a + b);
}

test "uax29 indic conjunct gb9c" {
    const s = "क\u{094D}क";
    try std.testing.expectEqual(s.len, nextLen(s, 0));
}
