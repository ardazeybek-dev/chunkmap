//! Parallel chunk-and-hash pipeline.
//!
//! Worker threads pull file indices from a shared atomic cursor (work
//! stealing without queues), stream each file through FastCDC and hash every
//! chunk with BLAKE3. A whole-file BLAKE3 digest is computed in the same pass,
//! so every byte is read from disk exactly once.
const std = @import("std");
const fastcdc = @import("fastcdc.zig");
const scanner = @import("scanner.zig");

const Blake3 = std.crypto.hash.Blake3;

pub const Chunk = struct {
    /// First 128 bits of the chunk's BLAKE3 digest.
    hash: u128,
    len: u32,
};

pub const FileResult = struct {
    chunks: []Chunk = &.{},
    digest: u128 = 0,
    /// Size observed when the file was opened (authoritative on Windows,
    /// where the walker does not stat files).
    size: u64 = 0,
    ok: bool = false,
    /// Skipped because its size is outside the configured range.
    filtered: bool = false,
};

pub const SizeRange = struct {
    min: u64 = 0,
    max: u64 = std.math.maxInt(u64),
};

pub const Progress = struct {
    files_done: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    bytes_done: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

/// Chunks a single file. `scratch` is reused between calls to avoid churn;
/// the returned chunk slice is allocated from `alloc`.
pub fn processFile(
    alloc: std.mem.Allocator,
    path: []const u8,
    chunker: fastcdc.Chunker,
    buf: []u8,
    scratch: *std.ArrayList(Chunk),
    progress: ?*Progress,
    range: SizeRange,
) !FileResult {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const size = try file.getEndPos();
    if (size < range.min or size > range.max) return .{ .size = size, .filtered = true };

    scratch.clearRetainingCapacity();
    var whole = Blake3.init(.{});
    var stream = fastcdc.chunkStream(file, chunker, buf);
    while (try stream.next()) |piece| {
        whole.update(piece);
        try scratch.append(.{ .hash = digest128(piece), .len = @intCast(piece.len) });
        if (progress) |p| _ = p.bytes_done.fetchAdd(piece.len, .monotonic);
    }
    var out: [32]u8 = undefined;
    whole.final(&out);
    return .{
        .chunks = try alloc.dupe(Chunk, scratch.items),
        .digest = std.mem.readInt(u128, out[0..16], .little),
        .size = size,
        .ok = true,
    };
}

pub fn digest128(data: []const u8) u128 {
    var out: [32]u8 = undefined;
    Blake3.hash(data, &out, .{});
    return std.mem.readInt(u128, out[0..16], .little);
}

const Shared = struct {
    alloc: std.mem.Allocator,
    files: []const scanner.FileEntry,
    results: []FileResult,
    chunker: fastcdc.Chunker,
    range: SizeRange,
    cursor: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    progress: *Progress,
};

fn worker(shared: *Shared) void {
    const buf_len = @max(@as(usize, 1 << 20), 4 * @as(usize, shared.chunker.params.max_size));
    const buf = shared.alloc.alloc(u8, buf_len) catch {
        drain(shared);
        return;
    };
    defer shared.alloc.free(buf);
    var scratch = std.ArrayList(Chunk).init(shared.alloc);
    defer scratch.deinit();

    while (true) {
        const i = shared.cursor.fetchAdd(1, .monotonic);
        if (i >= shared.files.len) break;
        shared.results[i] = processFile(shared.alloc, shared.files[i].path, shared.chunker, buf, &scratch, shared.progress, shared.range) catch .{};
        _ = shared.progress.files_done.fetchAdd(1, .release);
    }
}

/// Marks remaining files as failed if a worker cannot even allocate its buffer.
fn drain(shared: *Shared) void {
    while (true) {
        const i = shared.cursor.fetchAdd(1, .monotonic);
        if (i >= shared.files.len) break;
        _ = shared.progress.files_done.fetchAdd(1, .release);
    }
}

pub const Run = struct {
    results: []FileResult,
    alloc: std.mem.Allocator,

    pub fn deinit(self: Run) void {
        for (self.results) |r| if (r.ok) self.alloc.free(r.chunks);
        self.alloc.free(self.results);
    }
};

/// Processes all files with `threads` workers. `alloc` must be thread-safe.
/// `on_tick` is invoked roughly every 100ms on the calling thread until done.
pub fn run(
    alloc: std.mem.Allocator,
    files: []const scanner.FileEntry,
    chunker: fastcdc.Chunker,
    range: SizeRange,
    threads: usize,
    progress: *Progress,
    tick_ctx: anytype,
    comptime on_tick: ?fn (@TypeOf(tick_ctx), *Progress) void,
) !Run {
    const results = try alloc.alloc(FileResult, files.len);
    @memset(results, .{});
    var shared = Shared{ .alloc = alloc, .files = files, .results = results, .chunker = chunker, .range = range, .progress = progress };

    const n = @max(1, @min(threads, files.len));
    const handles = try alloc.alloc(std.Thread, n);
    defer alloc.free(handles);
    var spawned: usize = 0;
    for (handles) |*h| {
        h.* = std.Thread.spawn(.{}, worker, .{&shared}) catch break;
        spawned += 1;
    }
    if (spawned == 0) worker(&shared);

    while (progress.files_done.load(.acquire) < files.len) {
        if (on_tick) |f| f(tick_ctx, progress);
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    for (handles[0..spawned]) |h| h.join();
    if (on_tick) |f| f(tick_ctx, progress);
    return .{ .results = results, .alloc = alloc };
}

test "pipeline chunks files in parallel and detects identical content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var prng = std.Random.DefaultPrng.init(5);
    var data: [200_000]u8 = undefined;
    prng.random().bytes(&data);
    try tmp.dir.writeFile(.{ .sub_path = "a.bin", .data = &data });
    try tmp.dir.writeFile(.{ .sub_path = "b.bin", .data = &data });
    try tmp.dir.writeFile(.{ .sub_path = "c.bin", .data = data[0..1000] });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stats = scanner.Stats{};
    const root = try tmp.dir.realpathAlloc(arena, ".");
    const files = try scanner.scan(arena, &.{root}, .{}, &stats);

    var progress = Progress{};
    const chunker = fastcdc.Chunker.init(try fastcdc.Params.fromAverage(4096));
    const result = try run(std.testing.allocator, files, chunker, .{}, 4, &progress, {}, null);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.results.len);
    for (result.results) |r| try std.testing.expect(r.ok);
    try std.testing.expectEqual(@as(u64, 1000), result.results[2].size);

    var progress2 = Progress{};
    const filtered = try run(std.testing.allocator, files, chunker, .{ .min = 1001 }, 2, &progress2, {}, null);
    defer filtered.deinit();
    try std.testing.expect(filtered.results[2].filtered and !filtered.results[2].ok);
    try std.testing.expect(filtered.results[0].ok);
    try std.testing.expectEqual(result.results[0].digest, result.results[1].digest);
    try std.testing.expect(result.results[0].digest != result.results[2].digest);
    try std.testing.expectEqual(@as(u64, 401_000), progress.bytes_done.load(.monotonic));
    var total: u64 = 0;
    for (result.results[0].chunks) |c| total += c.len;
    try std.testing.expectEqual(@as(u64, 200_000), total);
}
