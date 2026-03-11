const std = @import("std");

const source_url = "https://raw.githubusercontent.com/unicode-rs/unicode-segmentation/master/src/tables.rs";
const out_path = "src/generated/grapheme_tables.zig";

const Cat = enum {
    GC_CR,
    GC_LF,
    GC_Control,
    GC_Extend,
    GC_ZWJ,
    GC_Regional_Indicator,
    GC_Prepend,
    GC_SpacingMark,
    GC_L,
    GC_V,
    GC_T,
    GC_LV,
    GC_LVT,
    GC_Extended_Pictographic,
    GC_InCB_Consonant,
};

const Data = struct {
    gcb_cr: std.ArrayList([2]u21) = .empty,
    gcb_lf: std.ArrayList([2]u21) = .empty,
    gcb_control: std.ArrayList([2]u21) = .empty,
    gcb_extend: std.ArrayList([2]u21) = .empty,
    gcb_zwj: std.ArrayList([2]u21) = .empty,
    gcb_regional_indicator: std.ArrayList([2]u21) = .empty,
    gcb_prepend: std.ArrayList([2]u21) = .empty,
    gcb_spacing_mark: std.ArrayList([2]u21) = .empty,
    gcb_l: std.ArrayList([2]u21) = .empty,
    gcb_v: std.ArrayList([2]u21) = .empty,
    gcb_t: std.ArrayList([2]u21) = .empty,
    gcb_lv: std.ArrayList([2]u21) = .empty,
    gcb_lvt: std.ArrayList([2]u21) = .empty,
    gcb_extended_pictographic: std.ArrayList([2]u21) = .empty,
    gcb_incb_consonant: std.ArrayList([2]u21) = .empty,
    incb_extend: std.ArrayList([2]u21) = .empty,
    incb_linker: std.ArrayList(u21) = .empty,

    fn deinit(self: *Data, allocator: std.mem.Allocator) void {
        self.gcb_cr.deinit(allocator);
        self.gcb_lf.deinit(allocator);
        self.gcb_control.deinit(allocator);
        self.gcb_extend.deinit(allocator);
        self.gcb_zwj.deinit(allocator);
        self.gcb_regional_indicator.deinit(allocator);
        self.gcb_prepend.deinit(allocator);
        self.gcb_spacing_mark.deinit(allocator);
        self.gcb_l.deinit(allocator);
        self.gcb_v.deinit(allocator);
        self.gcb_t.deinit(allocator);
        self.gcb_lv.deinit(allocator);
        self.gcb_lvt.deinit(allocator);
        self.gcb_extended_pictographic.deinit(allocator);
        self.gcb_incb_consonant.deinit(allocator);
        self.incb_extend.deinit(allocator);
        self.incb_linker.deinit(allocator);
    }

    fn appendRange(self: *Data, allocator: std.mem.Allocator, cat: Cat, lo: u21, hi: u21) !void {
        const list = switch (cat) {
            .GC_CR => &self.gcb_cr,
            .GC_LF => &self.gcb_lf,
            .GC_Control => &self.gcb_control,
            .GC_Extend => &self.gcb_extend,
            .GC_ZWJ => &self.gcb_zwj,
            .GC_Regional_Indicator => &self.gcb_regional_indicator,
            .GC_Prepend => &self.gcb_prepend,
            .GC_SpacingMark => &self.gcb_spacing_mark,
            .GC_L => &self.gcb_l,
            .GC_V => &self.gcb_v,
            .GC_T => &self.gcb_t,
            .GC_LV => &self.gcb_lv,
            .GC_LVT => &self.gcb_lvt,
            .GC_Extended_Pictographic => &self.gcb_extended_pictographic,
            .GC_InCB_Consonant => &self.gcb_incb_consonant,
        };
        try appendMergedRange(list, allocator, lo, hi);
    }
};

fn appendMergedRange(list: *std.ArrayList([2]u21), allocator: std.mem.Allocator, lo: u21, hi: u21) !void {
    if (list.items.len > 0) {
        const last_idx = list.items.len - 1;
        const last = list.items[last_idx];
        if (lo <= last[1] + 1) {
            list.items[last_idx][1] = @max(last[1], hi);
            return;
        }
    }
    try list.append(allocator, .{ lo, hi });
}

fn appendUniqueCodepoint(list: *std.ArrayList(u21), allocator: std.mem.Allocator, cp: u21) !void {
    for (list.items) |existing| {
        if (existing == cp) return;
    }
    try list.append(allocator, cp);
}

fn fetchSource(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var http_client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer http_client.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const result = try http_client.fetch(.{
        .location = .{ .url = source_url },
        .response_writer = &out.writer,
    });
    if (result.status != .ok) {
        std.debug.print("failed to fetch tables.rs: status={d}\n", .{@intFromEnum(result.status)});
        return error.FetchFailed;
    }
    return try out.toOwnedSlice();
}

fn findSection(content: []const u8, start_marker: []const u8, end_marker: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, content, start_marker) orelse return error.ParseFailed;
    const end = std.mem.indexOfPos(u8, content, start, end_marker) orelse return error.ParseFailed;
    return content[start..end];
}

fn parseNextCodepoint(s: []const u8, from: usize) !struct { cp: u21, next: usize } {
    const u_idx = std.mem.indexOfPos(u8, s, from, "\\u{") orelse return error.ParseFailed;
    const hex_start = u_idx + 3;
    const hex_end = std.mem.indexOfScalarPos(u8, s, hex_start, '}') orelse return error.ParseFailed;
    const cp = try std.fmt.parseInt(u21, s[hex_start..hex_end], 16);
    return .{ .cp = cp, .next = hex_end + 1 };
}

fn parseCatIdent(s: []const u8, from: usize) !struct { cat: Cat, next: usize } {
    const gc_idx = std.mem.indexOfPos(u8, s, from, "GC_") orelse return error.ParseFailed;
    var end = gc_idx + 3;
    while (end < s.len) : (end += 1) {
        const c = s[end];
        if (!(std.ascii.isAlphabetic(c) or c == '_')) break;
    }
    const ident = s[gc_idx..end];
    const cat = std.meta.stringToEnum(Cat, ident) orelse return error.ParseFailed;
    return .{ .cat = cat, .next = end };
}

fn parseGraphemeCatTable(allocator: std.mem.Allocator, data: *Data, section: []const u8) !void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, section, pos, "('\\u{")) |entry_pos| {
        const c1 = try parseNextCodepoint(section, entry_pos);
        const c2 = try parseNextCodepoint(section, c1.next);
        const cat = try parseCatIdent(section, c2.next);
        try data.appendRange(allocator, cat.cat, c1.cp, c2.cp);
        pos = cat.next;
    }
}

fn parseSimpleRangeTable(allocator: std.mem.Allocator, list: *std.ArrayList([2]u21), section: []const u8) !void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, section, pos, "('\\u{")) |entry_pos| {
        const c1 = try parseNextCodepoint(section, entry_pos);
        const c2 = try parseNextCodepoint(section, c1.next);
        try appendMergedRange(list, allocator, c1.cp, c2.cp);
        pos = c2.next;
    }
}

fn parseLinkers(allocator: std.mem.Allocator, data: *Data, section: []const u8) !void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, section, pos, "\\u{")) |u_idx| {
        const parsed = try parseNextCodepoint(section, u_idx);
        try appendUniqueCodepoint(&data.incb_linker, allocator, parsed.cp);
        pos = parsed.next;
    }
}

fn writeRanges(writer: *std.Io.Writer, name: []const u8, ranges: []const [2]u21) !void {
    try writer.print("pub const {s} = [_][2]u21{{\n", .{name});
    for (ranges) |r| {
        try writer.print("    .{{ 0x{X}, 0x{X} }},\n", .{ r[0], r[1] });
    }
    try writer.writeAll("};\n\n");
}

fn render(allocator: std.mem.Allocator, data: *const Data) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.writeAll("// Generated by tools/gen_grapheme_tables.zig\n");
    try out.writer.writeAll("// Source:\n");
    try out.writer.print("// - {s}\n\n", .{source_url});

    try writeRanges(&out.writer, "gcb_cr", data.gcb_cr.items);
    try writeRanges(&out.writer, "gcb_lf", data.gcb_lf.items);
    try writeRanges(&out.writer, "gcb_control", data.gcb_control.items);
    try writeRanges(&out.writer, "gcb_extend", data.gcb_extend.items);
    try writeRanges(&out.writer, "gcb_zwj", data.gcb_zwj.items);
    try writeRanges(&out.writer, "gcb_regional_indicator", data.gcb_regional_indicator.items);
    try writeRanges(&out.writer, "gcb_prepend", data.gcb_prepend.items);
    try writeRanges(&out.writer, "gcb_spacing_mark", data.gcb_spacing_mark.items);
    try writeRanges(&out.writer, "gcb_l", data.gcb_l.items);
    try writeRanges(&out.writer, "gcb_v", data.gcb_v.items);
    try writeRanges(&out.writer, "gcb_t", data.gcb_t.items);
    try writeRanges(&out.writer, "gcb_lv", data.gcb_lv.items);
    try writeRanges(&out.writer, "gcb_lvt", data.gcb_lvt.items);
    try writeRanges(&out.writer, "gcb_extended_pictographic", data.gcb_extended_pictographic.items);
    try writeRanges(&out.writer, "gcb_incb_consonant", data.gcb_incb_consonant.items);
    try writeRanges(&out.writer, "incb_extend", data.incb_extend.items);

    try out.writer.writeAll("pub const incb_linker = [_]u21{\n");
    for (data.incb_linker.items) |cp| {
        try out.writer.print("    0x{X},\n", .{cp});
    }
    try out.writer.writeAll("};\n");

    return try out.toOwnedSlice();
}

fn writeIfChanged(io: std.Io, allocator: std.mem.Allocator, path: []const u8, new_content: []const u8) !bool {
    const existing = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing) |buf| allocator.free(buf);

    if (existing) |buf| {
        if (std.mem.eql(u8, buf, new_content)) return false;
    }

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = new_content,
        .flags = .{ .truncate = true },
    });
    return true;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const source = try fetchSource(allocator, init.io);

    if (std.mem.indexOf(u8, source, "const grapheme_cat_table") == null) {
        const n = @min(source.len, 200);
        std.debug.print("unexpected payload prefix:\n{s}\n", .{source[0..n]});
        return error.ParseFailed;
    }

    var data: Data = .{};
    defer data.deinit(allocator);

    const grapheme_section = try findSection(
        source,
        "const grapheme_cat_table: &[(char, char, GraphemeCat)] = &[",
        "];",
    );
    try parseGraphemeCatTable(allocator, &data, grapheme_section);

    const incb_extend_section = try findSection(
        source,
        "const InCB_Extend_table: &[(char, char)] = &[",
        "];",
    );
    try parseSimpleRangeTable(allocator, &data.incb_extend, incb_extend_section);

    const linker_section = try findSection(
        source,
        "pub fn is_incb_linker(c: char) -> bool {",
        "}\n\npub mod grapheme",
    );
    try parseLinkers(allocator, &data, linker_section);

    const generated = try render(allocator, &data);
    const changed = try writeIfChanged(init.io, allocator, out_path, generated);

    if (changed) {
        std.debug.print("updated {s}\n", .{out_path});
    } else {
        std.debug.print("no changes in {s}\n", .{out_path});
    }
}
