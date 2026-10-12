//! `chunkmap compare A B` — a visual, chunk-level diff of two (large) files.
//!
//! Useful for questions like "how different are these two backups / VM images
//! / video exports really?" without loading either file into memory.
const std = @import("std");
const fastcdc = @import("fastcdc.zig");
const pipeline = @import("pipeline.zig");
const term = @import("term.zig");
const fmt = @import("format.zig");

const pal = term.palette;
pub const strip_width = 64;

pub const Side = struct {
    size: u64,
    shared: u64,
    /// Fraction of bytes in each strip cell that also occur in the other file.
    cells: [strip_width]f64,
    first_diff: ?u64,
};

pub const Result = struct {
    a: Side,
    b: Side,
    identical: bool,
    chunks_a: usize,
    chunks_b: usize,
};

pub fn compareFiles(alloc: std.mem.Allocator, path_a: []const u8, path_b: []const u8, chunker: fastcdc.Chunker) !Result {
    const buf = try alloc.alloc(u8, @max(@as(usize, 1 << 20), 4 * @as(usize, chunker.params.max_size)));
    defer alloc.free(buf);
    var scratch = std.ArrayList(pipeline.Chunk).init(alloc);
    defer scratch.deinit();

    const ra = try pipeline.processFile(alloc, path_a, chunker, buf, &scratch, null, .{});
    defer alloc.free(ra.chunks);
    const rb = try pipeline.processFile(alloc, path_b, chunker, buf, &scratch, null, .{});
    defer alloc.free(rb.chunks);
    return compareChunks(alloc, ra, rb);
}

pub fn compareChunks(alloc: std.mem.Allocator, ra: pipeline.FileResult, rb: pipeline.FileResult) !Result {
    var set_a = std.AutoHashMap(u128, void).init(alloc);
    defer set_a.deinit();
    var set_b = std.AutoHashMap(u128, void).init(alloc);
    defer set_b.deinit();
    for (ra.chunks) |c| try set_a.put(c.hash, {});
    for (rb.chunks) |c| try set_b.put(c.hash, {});
    const a = side(ra.chunks, &set_b);
    const b = side(rb.chunks, &set_a);
    return .{ .a = a, .b = b, .identical = ra.digest == rb.digest and a.size == b.size, .chunks_a = ra.chunks.len, .chunks_b = rb.chunks.len };
}

fn side(chunks: []const pipeline.Chunk, other: *const std.AutoHashMap(u128, void)) Side {
    var size: u64 = 0;
    for (chunks) |c| size += c.len;
    var out = Side{ .size = size, .shared = 0, .cells = [_]f64{0} ** strip_width, .first_diff = null };
    if (size == 0) return out;

    var shared_per_cell = [_]u64{0} ** strip_width;
    var off: u64 = 0;
    for (chunks) |c| {
        const hit = other.contains(c.hash);
        if (hit) out.shared += c.len else if (out.first_diff == null) out.first_diff = off;
        if (hit) {
            // Spread the chunk's bytes over every cell it overlaps.
            var pos = off;
            const end = off + c.len;
            while (pos < end) {
                const cell: usize = @intCast(@min(strip_width - 1, pos * strip_width / size));
                const cell_end = @max(pos + 1, (@as(u64, cell) + 1) * size / strip_width);
                const take = @min(end, cell_end) - pos;
                shared_per_cell[cell] += take;
                pos += take;
            }
        }
        off += c.len;
    }
    for (&out.cells, 0..) |*cell, i| {
        const lo = @as(u64, i) * size / strip_width;
        const hi = (@as(u64, i) + 1) * size / strip_width;
        cell.* = if (hi > lo) @min(1.0, @as(f64, @floatFromInt(shared_per_cell[i])) / @as(f64, @floatFromInt(hi - lo))) else 1.0;
    }
    return out;
}

pub fn render(w: anytype, st: term.Style, path_a: []const u8, path_b: []const u8, r: Result, params: fastcdc.Params) !void {
    try w.print("\n  {}▚▞{s} {s}chunkmap compare{s}  {}FastCDC avg {} · {d} + {d} chunks{s}\n\n", .{
        st.fg(pal.amber), st.reset(), st.bold(), st.reset(), st.fg(pal.muted), fmt.bytes(params.avg_size), r.chunks_a, r.chunks_b, st.reset(),
    });
    if (r.identical) {
        try w.print("  {}{s}✔ identical{s} — both files have the same BLAKE3 digest ({})\n\n", .{ st.fg(pal.teal), st.bold(), st.reset(), fmt.bytes(r.a.size) });
        return;
    }
    try sideLine(w, st, "A", path_a, r.a);
    try sideLine(w, st, "B", path_b, r.b);
    if (st.enabled) {
        try w.print("\n  {}█{s} shared with the other file   {}█{s} only in this file\n", .{ st.fg(pal.teal), st.reset(), st.fg(pal.coral), st.reset() });
    } else try w.writeAll("\n  █ shared   ▓ mostly shared   ▒ partly shared   ░ only in this file\n");
    if (r.a.first_diff) |d| try w.print("  {}first difference in A at byte offset ~{} ({}){s}\n", .{ st.fg(pal.muted), fmt.count(d), fmt.bytes(d), st.reset() });
    const verdict = fmt.ratio(r.a.shared + r.b.shared, r.a.size + r.b.size);
    try w.print("\n  {s}{d:.1}%{s} of the combined bytes are shared — storing both deduplicated needs {}{}{s} instead of {}.\n\n", .{
        st.bold(), verdict * 100, st.reset(), st.fg(pal.teal), fmt.bytes(r.a.size + r.b.size - r.b.shared), st.reset(), fmt.bytes(r.a.size + r.b.size),
    });
}

fn sideLine(w: anytype, st: term.Style, tag: []const u8, path: []const u8, s: Side) !void {
    try w.print("  {s}{s}{s}  {s}\n     ", .{ st.bold(), tag, st.reset(), path });
    for (s.cells) |f| {
        if (st.enabled) {
            const col = mix(pal.coral, pal.teal, f);
            try w.print("{}█", .{st.fg(col)});
        } else {
            try w.writeAll(if (f > 0.9) "█" else if (f > 0.5) "▓" else if (f > 0.1) "▒" else "░");
        }
    }
    try w.print("{s}  {d:.1}% shared  {}({} of {}){s}\n", .{ st.reset(), fmt.ratio(s.shared, s.size) * 100, st.fg(pal.muted), fmt.bytes(s.shared), fmt.bytes(s.size), st.reset() });
}

fn mix(a: term.Rgb, b: term.Rgb, t: f64) term.Rgb {
    const f = std.math.clamp(t, 0, 1);
    const lerp = struct {
        fn l(x: u8, y: u8, k: f64) u8 {
            return @intFromFloat(@round(@as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(y)) - @as(f64, @floatFromInt(x))) * k));
        }
    }.l;
    return .{ .r = lerp(a.r, b.r, f), .g = lerp(a.g, b.g, f), .b = lerp(a.b, b.b, f) };
}

test "compare reports shared bytes and first difference" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var prng = std.Random.DefaultPrng.init(11);
    const base = try alloc.alloc(u8, 600_000);
    defer alloc.free(base);
    prng.random().bytes(base);
    const edited = try alloc.dupe(u8, base);
    defer alloc.free(edited);
    @memset(edited[400_000..420_000], 0xAB); // overwrite a 20 KB region

    try tmp.dir.writeFile(.{ .sub_path = "a", .data = base });
    try tmp.dir.writeFile(.{ .sub_path = "b", .data = edited });
    const pa = try tmp.dir.realpathAlloc(alloc, "a");
    defer alloc.free(pa);
    const pb = try tmp.dir.realpathAlloc(alloc, "b");
    defer alloc.free(pb);

    const chunker = fastcdc.Chunker.init(try fastcdc.Params.fromAverage(4096));
    const r = try compareFiles(alloc, pa, pb, chunker);
    try std.testing.expect(!r.identical);
    const frac = fmt.ratio(r.a.shared, r.a.size);
    try std.testing.expect(frac > 0.9 and frac < 1.0);
    const d = r.a.first_diff.?;
    try std.testing.expect(d > 370_000 and d <= 400_000);
    try std.testing.expect(r.a.cells[0] == 1.0);

    const same = try compareFiles(alloc, pa, pa, chunker);
    try std.testing.expect(same.identical);
}
