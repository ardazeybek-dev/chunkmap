//! Colourful terminal summary of an analysis.
const std = @import("std");
const analysis = @import("../analysis.zig");
const scanner = @import("../scanner.zig");
const fastcdc = @import("../fastcdc.zig");
const term = @import("../term.zig");
const fmt = @import("../format.zig");

const pal = term.palette;
const path_width = 62;

pub const Context = struct {
    version: []const u8,
    style: term.Style,
    files: []const scanner.FileEntry,
    display: []const []const u8,
    result: *const analysis.Analysis,
    stats: scanner.Stats,
    chunk_params: fastcdc.Params,
    threads: usize,
    elapsed_ns: u64,
    top: usize,
    groups_total: usize,
    html_path: ?[]const u8,
    json_path: ?[]const u8,
};

pub fn render(w: anytype, c: Context) !void {
    const st = c.style;
    const s = c.result.summary;

    try w.print("\n  {}▚▞{s} {s}chunkmap{s} {}{s}{s}  {}·  FastCDC avg {}  ·  BLAKE3  ·  {d} threads{s}\n\n", .{
        st.fg(pal.amber), st.reset(),                         st.bold(), st.reset(), st.fg(pal.muted), c.version, st.reset(),
        st.fg(pal.muted), fmt.bytes(c.chunk_params.avg_size), c.threads, st.reset(),
    });

    const secs = @max(@as(f64, @floatFromInt(c.elapsed_ns)) / std.time.ns_per_s, 0.001);
    const speed: u64 = @intFromFloat(@as(f64, @floatFromInt(s.bytes)) / secs);
    try label(w, st, "SCANNED");
    try w.print("{s}{}{s}  in {} files  {}· {} · {}/s{s}\n", .{
        st.bold(), fmt.bytes(s.bytes), st.reset(), fmt.count(s.files), st.fg(pal.muted), fmt.duration(c.elapsed_ns), fmt.bytes(speed), st.reset(),
    });
    try label(w, st, "UNIQUE");
    try w.print("{}  {}in {} distinct chunks{s}\n", .{ fmt.bytes(s.unique_bytes), st.fg(pal.muted), fmt.count(s.chunks_unique), st.reset() });

    const frac = fmt.ratio(s.redundant_bytes, s.bytes);
    try label(w, st, "RECLAIMABLE");
    try w.print("{}{s}{}{s}  {d:.1}%  ", .{ st.fg(pal.coral), st.bold(), fmt.bytes(s.redundant_bytes), st.reset(), frac * 100 });
    try term.bar(w, st, frac, 28, pal.coral, pal.faint);
    try w.print("\n               {}exact copies {}  ·  partial / in-file {}{s}\n", .{
        st.fg(pal.muted), fmt.bytes(s.exact_dup_bytes), fmt.bytes(s.redundant_bytes -| s.exact_dup_bytes), st.reset(),
    });
    try label(w, st, "DEDUP RATIO");
    try w.print("{}{d:.2}×{s}\n", .{ st.fg(pal.teal), s.dedupRatio(), st.reset() });
    if (s.failed_files > 0 or c.stats.errors > 0) {
        try w.print("  {}⚠ {d} files could not be read, {d} directory errors (permissions?){s}\n", .{ st.fg(pal.amber), s.failed_files, c.stats.errors, st.reset() });
    }

    try exactSection(w, c);
    try pairSection(w, c);
    try dirSection(w, c);
    try extSection(w, c);
    try histogramSection(w, c);

    try w.writeAll("\n");
    if (c.html_path) |p| try w.print("  {}➜{s} Interactive report  {s}{s}{s}\n", .{ st.fg(pal.teal), st.reset(), st.bold(), p, st.reset() });
    if (c.json_path) |p| try w.print("  {}➜{s} JSON report         {s}\n", .{ st.fg(pal.teal), st.reset(), p });
    if (c.html_path == null) try w.print("  {}tip: add --html report.html for an interactive treemap of this scan{s}\n", .{ st.fg(pal.muted), st.reset() });
    try w.writeAll("\n");
}

fn label(w: anytype, st: term.Style, text: []const u8) !void {
    try w.print("  {}{s:<13}{s}", .{ st.fg(pal.muted), text, st.reset() });
}

fn heading(w: anytype, st: term.Style, title: []const u8, hint: []const u8) !void {
    try w.print("\n  {}━━{s} {s}{s}{s} {}{s}{s}\n", .{ st.fg(pal.amber), st.reset(), st.bold(), title, st.reset(), st.fg(pal.muted), hint, st.reset() });
}

fn exactSection(w: anytype, c: Context) !void {
    const st = c.style;
    const groups = c.result.groups;
    var hint_buf: [96]u8 = undefined;
    const hint = std.fmt.bufPrint(&hint_buf, "{} groups · {} wasted", .{ fmt.count(c.groups_total), fmt.bytes(c.result.summary.exact_dup_bytes) }) catch "";
    try heading(w, st, "EXACT DUPLICATES", hint);
    if (groups.len == 0) return w.print("    {}none — no byte-identical files{s}\n", .{ st.fg(pal.muted), st.reset() });
    for (groups[0..@min(c.top, groups.len)]) |g| {
        try w.print("  {}{:>10}{s}  {}×{d}{s}  {s}{s}{s}  {}({} each){s}\n", .{
            st.fg(pal.coral), fmt.bytes(g.wasted),                              st.reset(), st.fg(pal.amber), g.files.len,       st.reset(),
            st.bold(),        std.fs.path.basenamePosix(c.display[g.files[0]]), st.reset(), st.fg(pal.muted), fmt.bytes(g.size), st.reset(),
        });
        const shown = @min(g.files.len, 4);
        for (g.files[0..shown], 0..) |f, i| {
            const branch = if (i + 1 == shown and g.files.len <= 4) "└" else "├";
            try w.print("               {}{s}{s} ", .{ st.fg(pal.faint), branch, st.reset() });
            try pathLine(w, st, c.display[f]);
        }
        if (g.files.len > 4) try w.print("               {}└ … {d} more{s}\n", .{ st.fg(pal.faint), g.files.len - 4, st.reset() });
    }
}

fn pairSection(w: anytype, c: Context) !void {
    const st = c.style;
    const pairs = c.result.pairs;
    try heading(w, st, "NEAR-DUPLICATES", "share content but are not identical");
    if (pairs.len == 0) return w.print("    {}none above the similarity threshold{s}\n", .{ st.fg(pal.muted), st.reset() });
    for (pairs[0..@min(c.top, pairs.len)]) |p| {
        try w.print("  {}{d:>9.0}%{s}  ", .{ st.fg(pal.teal), p.containment * 100, st.reset() });
        try term.bar(w, st, p.containment, 12, pal.teal, pal.faint);
        try w.print("  {} shared\n", .{fmt.bytes(p.shared)});
        try w.print("               {}├{s} ", .{ st.fg(pal.faint), st.reset() });
        try pathLine(w, st, c.display[p.a]);
        try w.print("               {}└{s} ", .{ st.fg(pal.faint), st.reset() });
        try pathLine(w, st, c.display[p.b]);
    }
}

fn dirSection(w: anytype, c: Context) !void {
    const st = c.style;
    try heading(w, st, "HOTSPOT FOLDERS", "by bytes already stored elsewhere");
    var shown: usize = 0;
    for (c.result.dirs) |d| {
        if (d.redundant == 0 or shown == c.top) break;
        shown += 1;
        try w.print("  {:>10}  {d:>3.0}%  ", .{ fmt.bytes(d.redundant), fmt.ratio(d.redundant, d.bytes) * 100 });
        try term.bar(w, st, fmt.ratio(d.redundant, d.bytes), 10, pal.amber, pal.faint);
        try w.writeAll("  ");
        try pathLine(w, st, d.key);
    }
    if (shown == 0) try w.print("    {}no folder holds redundant data{s}\n", .{ st.fg(pal.muted), st.reset() });
}

fn extSection(w: anytype, c: Context) !void {
    const st = c.style;
    try heading(w, st, "BY FILE TYPE", "redundant of total");
    for (c.result.exts[0..@min(c.top, c.result.exts.len)]) |e| {
        try w.print("  {s}{s:<9}{s} {:>10} of {:<10} ", .{ st.bold(), e.key, st.reset(), fmt.bytes(e.redundant), fmt.bytes(e.bytes) });
        try term.bar(w, st, fmt.ratio(e.redundant, e.bytes), 16, pal.violet, pal.faint);
        try w.print("  {}{} file{s}{s}\n", .{ st.fg(pal.muted), fmt.count(e.files), if (e.files == 1) "" else "s", st.reset() });
    }
}

fn histogramSection(w: anytype, c: Context) !void {
    const st = c.style;
    const h = c.result.histogram;
    var first: usize = h.len;
    var last: usize = 0;
    var max: u64 = 0;
    for (h, 0..) |v, i| if (v > 0) {
        first = @min(first, i);
        last = i;
        max = @max(max, v);
    };
    if (max == 0) return;
    try heading(w, st, "CHUNK SIZES", "distinct chunks per size bucket");
    try w.print("  {}", .{st.fg(pal.amber)});
    for (h[first .. last + 1]) |v| {
        const level: usize = if (v == 0) 0 else @min(7, (v * 8) / (max + 1));
        try w.writeAll(if (v == 0) " " else term.spark[level]);
        try w.writeAll(if (v == 0) " " else term.spark[level]);
    }
    const s = c.result.summary;
    try w.print("{s}  {}{} … {}  ·  mean {}{s}\n", .{
        st.reset(),                                                                   st.fg(pal.muted),
        fmt.bytes(@as(u64, 1) << @intCast(first)),                                    fmt.bytes(@as(u64, 2) << @intCast(last)),
        fmt.bytes(if (s.chunks_unique == 0) 0 else s.unique_bytes / s.chunks_unique), st.reset(),
    });
}

/// Prints a path, middle-truncated to fit, with the directory dimmed.
fn pathLine(w: anytype, st: term.Style, path: []const u8) !void {
    var buf: [path_width * 4]u8 = undefined;
    const shown = truncateMiddle(&buf, path, path_width);
    const slash = std.mem.lastIndexOfScalar(u8, shown, '/');
    if (slash) |i| {
        try w.print("{}{s}{s}{s}\n", .{ st.fg(pal.muted), shown[0 .. i + 1], st.reset(), shown[i + 1 ..] });
    } else try w.print("{s}\n", .{shown});
}

/// Shortens `text` to at most `max` code points as "head…tail", never splitting UTF-8.
pub fn truncateMiddle(buf: []u8, text: []const u8, max: usize) []const u8 {
    const cps = std.unicode.utf8CountCodepoints(text) catch text.len;
    if (cps <= max) return text;
    const keep_head = (max - 1) / 3;
    const keep_tail = max - 1 - keep_head;
    var head_end: usize = 0;
    var n: usize = 0;
    while (head_end < text.len and n < keep_head) : (n += 1) head_end += seqLen(text[head_end]);
    var tail_start = text.len;
    n = 0;
    while (tail_start > head_end and n < keep_tail) : (n += 1) {
        tail_start -= 1;
        while (tail_start > head_end and (text[tail_start] & 0xC0) == 0x80) tail_start -= 1;
    }
    head_end = @min(head_end, text.len);
    return std.fmt.bufPrint(buf, "{s}…{s}", .{ text[0..head_end], text[tail_start..] }) catch text;
}

fn seqLen(first: u8) usize {
    return std.unicode.utf8ByteSequenceLength(first) catch 1;
}

test "truncateMiddle keeps short strings and respects UTF-8" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("short/path.txt", truncateMiddle(&buf, "short/path.txt", 20));
    const out = truncateMiddle(&buf, "very/long/directory/structure/with/many/levels/file.txt", 20);
    try std.testing.expectEqual(@as(usize, 20), try std.unicode.utf8CountCodepoints(out));
    try std.testing.expect(std.mem.endsWith(u8, out, "file.txt"));
    const utf = truncateMiddle(&buf, "ççççççççççççççççççççççççç/ğğğğğğğğğğğğğ.txt", 12);
    try std.testing.expect(std.unicode.utf8ValidateSlice(utf));
    try std.testing.expectEqual(@as(usize, 12), try std.unicode.utf8CountCodepoints(utf));
}
