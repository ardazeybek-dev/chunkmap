//! Serializable report model shared by the JSON and HTML outputs.
const std = @import("std");
const analysis = @import("../analysis.zig");
const scanner = @import("../scanner.zig");
const fastcdc = @import("../fastcdc.zig");

pub const schema_version = 1;
/// Largest files embedded in reports; the remainder is summarized.
pub const max_files = 25_000;

pub const Params = struct {
    avg_chunk: u32,
    min_chunk: u32,
    max_chunk: u32,
    threads: usize,
    min_file_size: u64,
    similarity: f64,
    excludes: []const []const u8,
};

pub const SummaryOut = struct {
    files: u64,
    failed_files: u64,
    bytes: u64,
    unique_bytes: u64,
    reclaimable_bytes: u64,
    exact_duplicate_bytes: u64,
    partial_redundant_bytes: u64,
    internal_redundant_bytes: u64,
    chunks_total: u64,
    chunks_unique: u64,
    dedup_ratio: f64,
};

pub const GroupOut = struct {
    size: u64,
    wasted: u64,
    digest: []const u8,
    paths: []const []const u8,
};

pub const PairOut = struct {
    a: []const u8,
    b: []const u8,
    size_a: u64,
    size_b: u64,
    shared: u64,
    containment: f64,
    jaccard: f64,
};

pub const HistOut = struct { min_bytes: u64, count: u64 };

/// Compact keys keep large reports small: p = path, s = size, r = redundant bytes.
pub const FileOut = struct { p: []const u8, s: u64, r: u64 };

pub const Report = struct {
    schema: u32 = schema_version,
    tool: []const u8 = "chunkmap",
    version: []const u8,
    generated_at: i64,
    duration_ms: u64,
    roots: []const []const u8,
    params: Params,
    summary: SummaryOut,
    scan: scanner.Stats,
    duplicate_groups: []const GroupOut,
    duplicate_groups_total: usize,
    similar_pairs: []const PairOut,
    directories: []const analysis.Rollup,
    extensions: []const analysis.Rollup,
    chunk_histogram: []const HistOut,
    files: []const FileOut,
    files_omitted: u64,
    bytes_omitted: u64,
};

pub const Inputs = struct {
    version: []const u8,
    duration_ns: u64,
    roots: []const []const u8,
    files: []const scanner.FileEntry,
    display: []const []const u8,
    result: *const analysis.Analysis,
    stats: scanner.Stats,
    chunk_params: fastcdc.Params,
    threads: usize,
    min_file_size: u64,
    similarity: f64,
    excludes: []const []const u8,
    groups_total: usize,
};

pub fn build(arena: std.mem.Allocator, in: Inputs) !Report {
    const a = in.result;
    const s = a.summary;

    const groups = try arena.alloc(GroupOut, a.groups.len);
    for (a.groups, groups) |g, *out| {
        const paths = try arena.alloc([]const u8, g.files.len);
        for (g.files, paths) |f, *p| p.* = in.display[f];
        out.* = .{
            .size = g.size,
            .wasted = g.wasted,
            .digest = try std.fmt.allocPrint(arena, "{x:0>32}", .{g.digest}),
            .paths = paths,
        };
    }

    const pairs = try arena.alloc(PairOut, a.pairs.len);
    for (a.pairs, pairs) |p, *out| out.* = .{
        .a = in.display[p.a],
        .b = in.display[p.b],
        .size_a = in.files[p.a].size,
        .size_b = in.files[p.b].size,
        .shared = p.shared,
        .containment = p.containment,
        .jaccard = p.jaccard,
    };

    var hist = std.ArrayList(HistOut).init(arena);
    for (a.histogram, 0..) |count, i| if (count > 0) try hist.append(.{ .min_bytes = @as(u64, 1) << @intCast(i), .count = count });

    // Embed the largest files; everything else is reported as an aggregate.
    const order = try arena.alloc(u32, in.files.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, in.files, struct {
        fn lt(files: []const scanner.FileEntry, x: u32, y: u32) bool {
            if (files[x].size != files[y].size) return files[x].size > files[y].size;
            return x < y;
        }
    }.lt);
    var file_list = std.ArrayList(FileOut).init(arena);
    var omitted: u64 = 0;
    var omitted_bytes: u64 = 0;
    for (order) |i| {
        if (in.files[i].size == 0) continue;
        if (file_list.items.len < max_files) {
            try file_list.append(.{ .p = in.display[i], .s = in.files[i].size, .r = a.redundant[i] });
        } else {
            omitted += 1;
            omitted_bytes += in.files[i].size;
        }
    }

    return .{
        .version = in.version,
        .generated_at = std.time.timestamp(),
        .duration_ms = in.duration_ns / std.time.ns_per_ms,
        .roots = in.roots,
        .params = .{
            .avg_chunk = in.chunk_params.avg_size,
            .min_chunk = in.chunk_params.min_size,
            .max_chunk = in.chunk_params.max_size,
            .threads = in.threads,
            .min_file_size = in.min_file_size,
            .similarity = in.similarity,
            .excludes = in.excludes,
        },
        .summary = .{
            .files = s.files,
            .failed_files = s.failed_files,
            .bytes = s.bytes,
            .unique_bytes = s.unique_bytes,
            .reclaimable_bytes = s.redundant_bytes,
            .exact_duplicate_bytes = s.exact_dup_bytes,
            .partial_redundant_bytes = s.redundant_bytes -| s.exact_dup_bytes,
            .internal_redundant_bytes = s.internal_redundant_bytes,
            .chunks_total = s.chunks_total,
            .chunks_unique = s.chunks_unique,
            .dedup_ratio = s.dedupRatio(),
        },
        .scan = in.stats,
        .duplicate_groups = groups,
        .duplicate_groups_total = in.groups_total,
        .similar_pairs = pairs,
        .directories = a.dirs[0..@min(a.dirs.len, 300)],
        .extensions = a.exts[0..@min(a.exts.len, 40)],
        .chunk_histogram = hist.items,
        .files = file_list.items,
        .files_omitted = omitted,
        .bytes_omitted = omitted_bytes,
    };
}
