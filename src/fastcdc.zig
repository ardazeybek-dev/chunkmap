//! FastCDC content-defined chunking (Xia et al., USENIX ATC '16).
//!
//! A Gear rolling hash `fp = (fp << 1) + G[byte]` slides over the data and a
//! chunk boundary is declared where the top bits of `fp` are all zero. Because
//! boundaries depend only on the *content* of the last ~64 bytes (not on
//! offsets), inserting or deleting bytes only disturbs the chunks around the
//! edit — the rest of the file still produces identical chunks. That is what
//! lets chunkmap detect files that are *partially* identical.
//!
//! Normalized chunking: before the expected average we use a stricter mask
//! (`mask_s`, 2 extra bits), after it a looser one (`mask_l`, 2 fewer bits).
//! This squeezes the chunk-size distribution towards the target average,
//! improving deduplication without giving up speed.
const std = @import("std");

/// 256 pseudo-random 64-bit constants, generated at compile time with SplitMix64
/// so the table is reproducible and needs no external data.
pub const gear: [256]u64 = blk: {
    var table: [256]u64 = undefined;
    var state: u64 = 0x63686b6d61702121; // "chkmap!!"
    for (&table) |*slot| {
        state +%= 0x9E3779B97F4A7C15;
        var z = state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        slot.* = z ^ (z >> 31);
    }
    break :blk table;
};

pub const Params = struct {
    min_size: u32,
    avg_size: u32,
    max_size: u32,

    pub const min_avg: u32 = 256;
    pub const max_avg: u32 = 4 * 1024 * 1024;

    /// Derives min = avg/4 and max = avg*8 from a power-of-two average.
    pub fn fromAverage(avg: u64) error{InvalidChunkSize}!Params {
        if (avg < min_avg or avg > max_avg or !std.math.isPowerOfTwo(avg)) return error.InvalidChunkSize;
        const a: u32 = @intCast(avg);
        return .{ .min_size = a / 4, .avg_size = a, .max_size = a * 8 };
    }
};

fn topMask(bits: u32) u64 {
    return ~@as(u64, 0) << @intCast(64 - bits);
}

pub const Chunker = struct {
    params: Params,
    mask_s: u64,
    mask_l: u64,

    pub fn init(params: Params) Chunker {
        const bits: u32 = std.math.log2_int(u32, params.avg_size);
        return .{ .params = params, .mask_s = topMask(bits + 2), .mask_l = topMask(bits - 2) };
    }

    /// Returns the length of the chunk that starts at `data[0]`.
    ///
    /// The caller must pass at least `max_size` bytes unless `data` is the tail
    /// of the stream; otherwise boundaries would depend on buffer sizes.
    pub fn cut(self: Chunker, data: []const u8) usize {
        const p = self.params;
        const n = data.len;
        if (n <= p.min_size) return n;
        const limit = @min(n, p.max_size);
        const normal = @min(limit, p.avg_size);

        var fp: u64 = 0;
        var i: usize = p.min_size;
        while (i < normal) : (i += 1) {
            fp = (fp << 1) +% gear[data[i]];
            if (fp & self.mask_s == 0) return i + 1;
        }
        while (i < limit) : (i += 1) {
            fp = (fp << 1) +% gear[data[i]];
            if (fp & self.mask_l == 0) return i + 1;
        }
        return limit;
    }
};

/// Buffered streaming chunker over any reader exposing `read([]u8) !usize`.
pub fn ChunkStream(comptime Reader: type) type {
    return struct {
        const Self = @This();

        reader: Reader,
        chunker: Chunker,
        buf: []u8,
        start: usize = 0,
        end: usize = 0,
        eof: bool = false,

        /// `buf` must hold at least two maximum-size chunks.
        pub fn init(reader: Reader, chunker: Chunker, buf: []u8) Self {
            std.debug.assert(buf.len >= 2 * @as(usize, chunker.params.max_size));
            return .{ .reader = reader, .chunker = chunker, .buf = buf };
        }

        /// Returns the next chunk (valid until the following call) or null at EOF.
        pub fn next(self: *Self) !?[]const u8 {
            if (!self.eof and self.end - self.start < self.chunker.params.max_size) try self.refill();
            if (self.start == self.end) return null;
            const len = self.chunker.cut(self.buf[self.start..self.end]);
            const chunk = self.buf[self.start .. self.start + len];
            self.start += len;
            return chunk;
        }

        fn refill(self: *Self) !void {
            if (self.start > 0) {
                const live = self.end - self.start;
                std.mem.copyForwards(u8, self.buf[0..live], self.buf[self.start..self.end]);
                self.start = 0;
                self.end = live;
            }
            while (self.end < self.buf.len) {
                const n = try self.reader.read(self.buf[self.end..]);
                if (n == 0) {
                    self.eof = true;
                    break;
                }
                self.end += n;
            }
        }
    };
}

pub fn chunkStream(reader: anytype, chunker: Chunker, buf: []u8) ChunkStream(@TypeOf(reader)) {
    return ChunkStream(@TypeOf(reader)).init(reader, chunker, buf);
}

// ---------------------------------------------------------------- tests ----

fn randomBytes(alloc: std.mem.Allocator, len: usize, seed: u64) ![]u8 {
    const data = try alloc.alloc(u8, len);
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(data);
    return data;
}

fn cutAll(alloc: std.mem.Allocator, chunker: Chunker, data: []const u8) ![]usize {
    var lens = std.ArrayList(usize).init(alloc);
    var off: usize = 0;
    while (off < data.len) {
        const len = chunker.cut(data[off..]);
        try lens.append(len);
        off += len;
    }
    return lens.toOwnedSlice();
}

test "gear table is fully populated and distinct" {
    var seen = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer seen.deinit();
    for (gear) |g| try seen.put(g, {});
    try std.testing.expectEqual(@as(u32, 256), seen.count());
}

test "params validation" {
    try std.testing.expectError(error.InvalidChunkSize, Params.fromAverage(1000));
    try std.testing.expectError(error.InvalidChunkSize, Params.fromAverage(128));
    const p = try Params.fromAverage(16 * 1024);
    try std.testing.expectEqual(@as(u32, 4096), p.min_size);
    try std.testing.expectEqual(@as(u32, 131072), p.max_size);
}

test "chunks respect min/max bounds and cover the input" {
    const alloc = std.testing.allocator;
    const data = try randomBytes(alloc, 4 * 1024 * 1024, 1);
    defer alloc.free(data);
    const chunker = Chunker.init(try Params.fromAverage(8192));
    const lens = try cutAll(alloc, chunker, data);
    defer alloc.free(lens);
    var total: usize = 0;
    for (lens, 0..) |len, i| {
        total += len;
        try std.testing.expect(len <= chunker.params.max_size);
        if (i + 1 < lens.len) try std.testing.expect(len > chunker.params.min_size);
    }
    try std.testing.expectEqual(data.len, total);
}

test "normalized chunking keeps the average near the target" {
    const alloc = std.testing.allocator;
    const data = try randomBytes(alloc, 16 * 1024 * 1024, 7);
    defer alloc.free(data);
    const chunker = Chunker.init(try Params.fromAverage(16 * 1024));
    const lens = try cutAll(alloc, chunker, data);
    defer alloc.free(lens);
    const avg = data.len / lens.len;
    try std.testing.expect(avg > 8 * 1024 and avg < 32 * 1024);
}

test "streaming boundaries are independent of buffer size" {
    const alloc = std.testing.allocator;
    const data = try randomBytes(alloc, 3 * 1024 * 1024 + 777, 42);
    defer alloc.free(data);
    const chunker = Chunker.init(try Params.fromAverage(4096));
    const expected = try cutAll(alloc, chunker, data);
    defer alloc.free(expected);

    for ([_]usize{ 2 * 32768, 100_003, 1 << 20 }) |buf_len| {
        const buf = try alloc.alloc(u8, buf_len);
        defer alloc.free(buf);
        var fbs = std.io.fixedBufferStream(data);
        var stream = chunkStream(fbs.reader(), chunker, buf);
        var i: usize = 0;
        while (try stream.next()) |chunk| : (i += 1) {
            try std.testing.expectEqual(expected[i], chunk.len);
        }
        try std.testing.expectEqual(expected.len, i);
    }
}

test "an insertion only disturbs nearby chunks (shift resistance)" {
    const alloc = std.testing.allocator;
    const original = try randomBytes(alloc, 2 * 1024 * 1024, 99);
    defer alloc.free(original);
    // Insert 13 bytes in the middle of the file.
    const edited = try std.mem.concat(alloc, u8, &.{ original[0 .. 1024 * 1024], "inserted-text", original[1024 * 1024 ..] });
    defer alloc.free(edited);

    const chunker = Chunker.init(try Params.fromAverage(8192));
    var set = std.AutoHashMap(u64, void).init(alloc);
    defer set.deinit();
    var off: usize = 0;
    while (off < original.len) {
        const len = chunker.cut(original[off..]);
        try set.put(std.hash.Wyhash.hash(0, original[off .. off + len]), {});
        off += len;
    }
    var shared: usize = 0;
    off = 0;
    while (off < edited.len) {
        const len = chunker.cut(edited[off..]);
        if (set.contains(std.hash.Wyhash.hash(0, edited[off .. off + len]))) shared += len;
        off += len;
    }
    // Fixed-size blocks would share ~50%; content-defined chunks share almost everything.
    try std.testing.expect(@as(f64, @floatFromInt(shared)) / @as(f64, @floatFromInt(edited.len)) > 0.97);
}
