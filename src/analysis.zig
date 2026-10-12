//! Turns per-file chunk lists into answers:
//!
//! * **Exact duplicates** — files with the same size and whole-file digest.
//! * **Near-duplicates** — different files that share a large fraction of
//!   their chunks (edited copies, versioned backups, re-exported media...).
//! * **Redundancy attribution** — for every file, how many of its bytes were
//!   already seen earlier in the scan. The sum over all files equals
//!   `total - unique`, i.e. exactly what a deduplicating store would save.
//! * Rollups by directory, extension and a chunk-size histogram.
const std = @import("std");
const scanner = @import("scanner.zig");
const pipeline = @import("pipeline.zig");

pub const Options = struct {
    /// Minimum containment (shared / smaller file) for a near-duplicate pair.
    similarity: f64 = 0.25,
    /// Chunks present in more files than this are ignored for pairing
    /// (e.g. runs of zeros) to keep pairing linear instead of quadratic.
    fanout_cap: u32 = 24,
    max_pairs: usize = 500,
    max_groups: usize = 500,
};

pub const DupGroup = struct {
    size: u64,
    digest: u128,
    files: []u32,
    wasted: u64,
};

pub const SimilarPair = struct {
    a: u32,
    b: u32,
    shared: u64,
    /// shared / min(size_a, size_b): "how much of the smaller file exists in the other".
    containment: f64,
    /// shared / (size_a + size_b - shared).
    jaccard: f64,
};

pub const Rollup = struct {
    key: []const u8,
    files: u64 = 0,
    bytes: u64 = 0,
    redundant: u64 = 0,
};

pub const histogram_buckets = 24;

pub const Summary = struct {
    files: u64 = 0,
    failed_files: u64 = 0,
    bytes: u64 = 0,
    unique_bytes: u64 = 0,
    redundant_bytes: u64 = 0,
    exact_dup_bytes: u64 = 0,
    internal_redundant_bytes: u64 = 0,
    chunks_total: u64 = 0,
    chunks_unique: u64 = 0,

    pub fn dedupRatio(self: Summary) f64 {
        if (self.unique_bytes == 0) return 1;
        return @as(f64, @floatFromInt(self.bytes)) / @as(f64, @floatFromInt(self.unique_bytes));
    }
};

pub const Analysis = struct {
    summary: Summary,
    /// Per-file bytes already seen earlier in the scan (index-aligned with files).
    redundant: []u64,
    groups: []DupGroup,
    /// Number of duplicate groups before `groups` was capped.
    groups_total: usize,
    pairs: []SimilarPair,
    dirs: []Rollup,
    exts: []Rollup,
    /// Distinct chunks per power-of-two size bucket: bucket i holds [2^i, 2^(i+1)).
    histogram: [histogram_buckets]u64,
};

const ChunkMeta = struct {
    len: u32,
    distinct_files: u32,
    last_file: u32,
};

/// Runs every analysis pass. All memory comes from `arena`.
pub fn analyze(
    arena: std.mem.Allocator,
    files: []const scanner.FileEntry,
    display: []const []const u8,
    results: []const pipeline.FileResult,
    opts: Options,
) !Analysis {
    var summary = Summary{};
    var histogram = [_]u64{0} ** histogram_buckets;
    const redundant = try arena.alloc(u64, files.len);
    @memset(redundant, 0);

    // Pass 1: global chunk index + per-file redundancy attribution.
    var index = std.AutoHashMap(u128, ChunkMeta).init(arena);
    for (results, 0..) |res, fi| {
        const file_idx: u32 = @intCast(fi);
        if (!res.ok) {
            summary.failed_files += 1;
            continue;
        }
        summary.files += 1;
        summary.bytes += files[fi].size;
        for (res.chunks) |c| {
            summary.chunks_total += 1;
            const gop = try index.getOrPut(c.hash);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .len = c.len, .distinct_files = 1, .last_file = file_idx };
                summary.unique_bytes += c.len;
                summary.chunks_unique += 1;
                histogram[@min(histogram_buckets - 1, std.math.log2_int(u32, @max(c.len, 1)))] += 1;
                continue;
            }
            redundant[fi] += c.len;
            if (gop.value_ptr.last_file == file_idx) {
                summary.internal_redundant_bytes += c.len;
            } else {
                gop.value_ptr.distinct_files += 1;
                gop.value_ptr.last_file = file_idx;
            }
        }
    }
    summary.redundant_bytes = summary.bytes - summary.unique_bytes;

    // Pass 2: exact duplicate groups keyed by (digest, size).
    const groups = try exactGroups(arena, files, results, opts.max_groups, &summary);

    // Representatives only: the 2nd..nth copy of an identical file adds no
    // information to near-duplicate pairing.
    const is_rep = try arena.alloc(bool, files.len);
    for (results, 0..) |r, i| is_rep[i] = r.ok and r.chunks.len > 0;
    for (groups.all) |g| for (g.files[1..]) |f| {
        is_rep[f] = false;
    };

    const pairs = try similarPairs(arena, files, results, &index, is_rep, opts);
    const dirs = try rollup(arena, files, display, results, redundant, .dir);
    const exts = try rollup(arena, files, display, results, redundant, .ext);

    return .{
        .summary = summary,
        .redundant = redundant,
        .groups = groups.top,
        .groups_total = groups.all.len,
        .pairs = pairs,
        .dirs = dirs,
        .exts = exts,
        .histogram = histogram,
    };
}

const Groups = struct { all: []DupGroup, top: []DupGroup };

fn exactGroups(
    arena: std.mem.Allocator,
    files: []const scanner.FileEntry,
    results: []const pipeline.FileResult,
    max_groups: usize,
    summary: *Summary,
) !Groups {
    const Key = struct { digest: u128, size: u64 };
    var by_digest = std.AutoArrayHashMap(Key, std.ArrayListUnmanaged(u32)).init(arena);
    for (results, 0..) |r, i| {
        if (!r.ok or files[i].size == 0) continue;
        const gop = try by_digest.getOrPut(.{ .digest = r.digest, .size = files[i].size });
        if (!gop.found_existing) gop.value_ptr.* = .{};
        try gop.value_ptr.append(arena, @intCast(i));
    }
    var list = std.ArrayList(DupGroup).init(arena);
    var it = by_digest.iterator();
    while (it.next()) |e| {
        const members = e.value_ptr.items;
        if (members.len < 2) continue;
        const wasted = e.key_ptr.size * (members.len - 1);
        summary.exact_dup_bytes += wasted;
        try list.append(.{ .size = e.key_ptr.size, .digest = e.key_ptr.digest, .files = members, .wasted = wasted });
    }
    std.mem.sort(DupGroup, list.items, {}, struct {
        fn lt(_: void, a: DupGroup, b: DupGroup) bool {
            if (a.wasted != b.wasted) return a.wasted > b.wasted;
            return a.files[0] < b.files[0];
        }
    }.lt);
    return .{ .all = list.items, .top = list.items[0..@min(max_groups, list.items.len)] };
}

fn similarPairs(
    arena: std.mem.Allocator,
    files: []const scanner.FileEntry,
    results: []const pipeline.FileResult,
    index: *const std.AutoHashMap(u128, ChunkMeta),
    is_rep: []const bool,
    opts: Options,
) ![]SimilarPair {
    // Postings: chunk -> distinct representative files containing it.
    var postings = std.AutoHashMap(u128, std.ArrayListUnmanaged(u32)).init(arena);
    for (results, 0..) |r, fi| {
        if (!is_rep[fi]) continue;
        const file_idx: u32 = @intCast(fi);
        for (r.chunks) |c| {
            const meta = index.get(c.hash) orelse continue;
            if (meta.distinct_files < 2 or meta.distinct_files > opts.fanout_cap) continue;
            const gop = try postings.getOrPut(c.hash);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            const items = gop.value_ptr.items;
            if (items.len > 0 and items[items.len - 1] == file_idx) continue; // repeated inside the file
            try gop.value_ptr.append(arena, file_idx);
        }
    }

    // Accumulate shared bytes per unordered file pair.
    var shared = std.AutoHashMap(u64, u64).init(arena);
    var pit = postings.iterator();
    while (pit.next()) |e| {
        const members = e.value_ptr.items;
        if (members.len < 2) continue;
        const len = index.get(e.key_ptr.*).?.len;
        for (members, 0..) |a, i| for (members[i + 1 ..]) |b| {
            const key = (@as(u64, @min(a, b)) << 32) | @max(a, b);
            const gop = try shared.getOrPut(key);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += len;
        };
    }

    var pairs = std.ArrayList(SimilarPair).init(arena);
    var sit = shared.iterator();
    while (sit.next()) |e| {
        const a: u32 = @intCast(e.key_ptr.* >> 32);
        const b: u32 = @intCast(e.key_ptr.* & 0xffff_ffff);
        if (results[a].digest == results[b].digest and files[a].size == files[b].size) continue;
        const s = e.value_ptr.*;
        const sa = files[a].size;
        const sb = files[b].size;
        const smaller = @max(1, @min(sa, sb));
        const containment = @min(1.0, @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(smaller)));
        if (containment < opts.similarity) continue;
        const union_bytes = @max(1, sa + sb -| s);
        try pairs.append(.{
            .a = a,
            .b = b,
            .shared = s,
            .containment = containment,
            .jaccard = @min(1.0, @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(union_bytes))),
        });
    }
    std.mem.sort(SimilarPair, pairs.items, {}, struct {
        fn lt(_: void, x: SimilarPair, y: SimilarPair) bool {
            if (x.shared != y.shared) return x.shared > y.shared;
            if (x.a != y.a) return x.a < y.a;
            return x.b < y.b;
        }
    }.lt);
    return pairs.items[0..@min(opts.max_pairs, pairs.items.len)];
}

const RollupKind = enum { dir, ext };

fn rollup(
    arena: std.mem.Allocator,
    files: []const scanner.FileEntry,
    display: []const []const u8,
    results: []const pipeline.FileResult,
    redundant: []const u64,
    kind: RollupKind,
) ![]Rollup {
    var map = std.StringArrayHashMap(Rollup).init(arena);
    for (files, 0..) |f, i| {
        if (!results[i].ok) continue;
        const key = switch (kind) {
            .dir => std.fs.path.dirnamePosix(display[i]) orelse ".",
            .ext => try extensionKey(arena, display[i]),
        };
        const gop = try map.getOrPut(key);
        if (!gop.found_existing) gop.value_ptr.* = .{ .key = key };
        gop.value_ptr.files += 1;
        gop.value_ptr.bytes += f.size;
        gop.value_ptr.redundant += redundant[i];
    }
    const items = map.values();
    std.mem.sort(Rollup, items, {}, struct {
        fn lt(_: void, a: Rollup, b: Rollup) bool {
            if (a.redundant != b.redundant) return a.redundant > b.redundant;
            if (a.bytes != b.bytes) return a.bytes > b.bytes;
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lt);
    return items;
}

fn extensionKey(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    var base = std.fs.path.basenamePosix(path);
    // Rotated files (app.log.1, backup.tar.3) are grouped with their real type.
    while (std.mem.lastIndexOfScalar(u8, base, '.')) |d| {
        if (d + 1 >= base.len or !allDigits(base[d + 1 ..])) break;
        base = base[0..d];
    }
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "(none)";
    if (dot == 0 or dot == base.len - 1) return "(none)";
    const ext = base[dot..];
    if (ext.len > 12) return "(other)";
    const lower = try arena.dupe(u8, ext);
    for (lower) |*c| c.* = std.ascii.toLower(c.*);
    return lower;
}

fn allDigits(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

// ---------------------------------------------------------------- tests ----

fn fakeResult(arena: std.mem.Allocator, digest: u128, chunks: []const pipeline.Chunk) !pipeline.FileResult {
    return .{ .chunks = try arena.dupe(pipeline.Chunk, chunks), .digest = digest, .ok = true };
}

test "redundancy, exact groups and near-duplicate pairs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // a and b are identical; c shares 3 of its 4 chunks with a; d repeats a chunk internally.
    const files = [_]scanner.FileEntry{
        .{ .path = "x/a.bin", .size = 400 },
        .{ .path = "x/b.bin", .size = 400 },
        .{ .path = "y/c.BIN", .size = 400 },
        .{ .path = "y/d.log", .size = 200 },
    };
    const display = [_][]const u8{ "x/a.bin", "x/b.bin", "y/c.BIN", "y/d.log" };
    const results = [_]pipeline.FileResult{
        try fakeResult(arena, 1, &.{ .{ .hash = 10, .len = 100 }, .{ .hash = 11, .len = 100 }, .{ .hash = 12, .len = 100 }, .{ .hash = 13, .len = 100 } }),
        try fakeResult(arena, 1, &.{ .{ .hash = 10, .len = 100 }, .{ .hash = 11, .len = 100 }, .{ .hash = 12, .len = 100 }, .{ .hash = 13, .len = 100 } }),
        try fakeResult(arena, 2, &.{ .{ .hash = 10, .len = 100 }, .{ .hash = 11, .len = 100 }, .{ .hash = 12, .len = 100 }, .{ .hash = 99, .len = 100 } }),
        try fakeResult(arena, 3, &.{ .{ .hash = 50, .len = 100 }, .{ .hash = 50, .len = 100 } }),
    };

    const a = try analyze(arena, &files, &display, &results, .{});
    try std.testing.expectEqual(@as(u64, 1400), a.summary.bytes);
    try std.testing.expectEqual(@as(u64, 600), a.summary.unique_bytes); // 10,11,12,13,99,50
    try std.testing.expectEqual(@as(u64, 800), a.summary.redundant_bytes);
    try std.testing.expectEqual(@as(u64, 100), a.summary.internal_redundant_bytes);
    try std.testing.expectEqual(@as(u64, 400), a.summary.exact_dup_bytes);

    try std.testing.expectEqual(@as(usize, 1), a.groups.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, a.groups[0].files);

    try std.testing.expectEqual(@as(usize, 1), a.pairs.len);
    try std.testing.expectEqual(@as(u32, 0), a.pairs[0].a);
    try std.testing.expectEqual(@as(u32, 2), a.pairs[0].b);
    try std.testing.expectEqual(@as(u64, 300), a.pairs[0].shared);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), a.pairs[0].containment, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), a.pairs[0].jaccard, 1e-9);

    var sum: u64 = 0;
    for (a.redundant) |r| sum += r;
    try std.testing.expectEqual(a.summary.redundant_bytes, sum);

    try std.testing.expectEqualStrings("x", a.dirs[0].key);
    try std.testing.expectEqual(@as(u64, 400), a.dirs[0].redundant);
    try std.testing.expectEqualStrings(".bin", a.exts[0].key);
    try std.testing.expectEqual(@as(u64, 3), a.exts[0].files);
}

test "extension keys fold rotations and normalise case" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(".log", try extensionKey(arena, "logs/app.log.1"));
    try std.testing.expectEqualStrings(".gz", try extensionKey(arena, "logs/app.log.2.gz"));
    try std.testing.expectEqualStrings(".jpg", try extensionKey(arena, "a/IMG.JPG"));
    try std.testing.expectEqualStrings("(none)", try extensionKey(arena, "Makefile"));
    try std.testing.expectEqualStrings("(none)", try extensionKey(arena, ".bashrc"));
}

test "failed files are excluded from totals" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const files = [_]scanner.FileEntry{ .{ .path = "a", .size = 10 }, .{ .path = "b", .size = 99 } };
    const display = [_][]const u8{ "a", "b" };
    const results = [_]pipeline.FileResult{ try fakeResult(arena, 7, &.{.{ .hash = 1, .len = 10 }}), .{} };
    const a = try analyze(arena, &files, &display, &results, .{});
    try std.testing.expectEqual(@as(u64, 1), a.summary.failed_files);
    try std.testing.expectEqual(@as(u64, 10), a.summary.bytes);
    try std.testing.expectEqual(@as(usize, 0), a.groups.len);
}
