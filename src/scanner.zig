//! Filesystem walker: collects regular files under one or more roots.
//!
//! Symlinks are never followed (no cycles, no double counting). Excluded
//! directories are pruned before descending, so `--exclude node_modules`
//! skips the whole subtree instead of filtering it afterwards.
const std = @import("std");
const builtin = @import("builtin");
const glob = @import("glob.zig");

pub const FileEntry = struct {
    /// Native path usable with `std.fs.cwd().openFile`.
    path: []const u8,
    size: u64,
};

pub const Options = struct {
    excludes: []const []const u8 = &.{},
    min_file_size: u64 = 1,
    max_file_size: u64 = std.math.maxInt(u64),
    /// Stat every file while walking. On Windows a stat opens the file (and
    /// triggers on-access antivirus scans) one by one on a single thread, so
    /// there the size is taken later by the parallel workers instead and
    /// `size` is left at 0 until then.
    stat_files: bool = builtin.os.tag != .windows,
};

pub const Stats = struct {
    dirs: u64 = 0,
    excluded: u64 = 0,
    symlinks: u64 = 0,
    filtered_by_size: u64 = 0,
    errors: u64 = 0,
};

/// Scans all roots. Every allocation is made from `arena`; callers are expected
/// to pass an arena that lives as long as the returned entries.
pub fn scan(arena: std.mem.Allocator, roots: []const []const u8, opts: Options, stats: *Stats) ![]FileEntry {
    var files = std.ArrayList(FileEntry).init(arena);
    for (roots) |root| try scanRoot(arena, trimSeparators(root), opts, &files, stats);

    std.mem.sort(FileEntry, files.items, {}, lessByPath);
    // Overlapping roots (e.g. `chunkmap scan a a/b`) must not count files twice.
    var unique: usize = 0;
    for (files.items) |entry| {
        if (unique > 0 and std.mem.eql(u8, files.items[unique - 1].path, entry.path)) continue;
        files.items[unique] = entry;
        unique += 1;
    }
    files.shrinkRetainingCapacity(unique);
    return files.toOwnedSlice();
}

fn lessByPath(_: void, a: FileEntry, b: FileEntry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn trimSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and (path[end - 1] == '/' or path[end - 1] == '\\')) : (end -= 1) {
        if (end == 3 and path[1] == ':') break; // keep "C:\"
    }
    return path[0..end];
}

fn scanRoot(arena: std.mem.Allocator, root: []const u8, opts: Options, files: *std.ArrayList(FileEntry), stats: *Stats) !void {
    const cwd = std.fs.cwd();
    var probe = cwd.openDir(root, .{}) catch |err| switch (err) {
        error.NotDir => {
            const st = try cwd.statFile(root);
            if (passesSize(st.size, opts)) {
                try files.append(.{ .path = try arena.dupe(u8, root), .size = st.size });
            } else stats.filtered_by_size += 1;
            return;
        },
        else => return err,
    };
    probe.close();

    var stack = std.ArrayList([]const u8).init(arena);
    try stack.append(try arena.dupe(u8, root));
    while (stack.pop()) |dir_path| {
        var dir = cwd.openDir(dir_path, .{ .iterate = true }) catch {
            stats.errors += 1;
            continue;
        };
        defer dir.close();
        stats.dirs += 1;

        var it = dir.iterate();
        while (true) {
            const maybe_entry = it.next() catch {
                stats.errors += 1;
                break;
            };
            const entry = maybe_entry orelse break;
            const full = try std.fs.path.join(arena, &.{ dir_path, entry.name });
            const rel = relativeTo(root, full);
            if (opts.excludes.len > 0 and glob.excluded(opts.excludes, entry.name, rel)) {
                stats.excluded += 1;
                continue;
            }
            switch (entry.kind) {
                .directory => try stack.append(full),
                .file => {
                    if (!opts.stat_files) {
                        try files.append(.{ .path = full, .size = 0 });
                        continue;
                    }
                    const st = dir.statFile(entry.name) catch {
                        stats.errors += 1;
                        continue;
                    };
                    if (passesSize(st.size, opts)) {
                        try files.append(.{ .path = full, .size = st.size });
                    } else stats.filtered_by_size += 1;
                },
                .sym_link => stats.symlinks += 1,
                else => {},
            }
        }
    }
}

fn passesSize(size: u64, opts: Options) bool {
    return size >= opts.min_file_size and size <= opts.max_file_size;
}

fn relativeTo(root: []const u8, full: []const u8) []const u8 {
    if (full.len > root.len and std.mem.startsWith(u8, full, root)) {
        var rest = full[root.len..];
        while (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\')) rest = rest[1..];
        return rest;
    }
    return full;
}

/// Converts a native path into the forward-slash form used in reports,
/// dropping a leading "./".
pub fn displayPath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, path);
    std.mem.replaceScalar(u8, out, '\\', '/');
    var view: []const u8 = out;
    while (std.mem.startsWith(u8, view, "./")) view = view[2..];
    return view;
}

test "scan walks, filters, excludes and sorts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("a/node_modules/pkg");
    try tmp.dir.makePath("b");
    try tmp.dir.writeFile(.{ .sub_path = "a/one.txt", .data = "hello world" });
    try tmp.dir.writeFile(.{ .sub_path = "a/node_modules/pkg/index.js", .data = "module.exports = 1" });
    try tmp.dir.writeFile(.{ .sub_path = "b/two.bin", .data = "0123456789abcdef" });
    try tmp.dir.writeFile(.{ .sub_path = "b/empty", .data = "" });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try tmp.dir.realpathAlloc(arena, ".");

    var stats = Stats{};
    const excludes = [_][]const u8{"node_modules"};
    const files = try scan(arena, &.{ root, root }, .{ .excludes = &excludes, .min_file_size = 1, .stat_files = true }, &stats);

    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expect(std.mem.endsWith(u8, files[0].path, "one.txt"));
    try std.testing.expectEqual(@as(u64, 11), files[0].size);
    try std.testing.expect(std.mem.endsWith(u8, files[1].path, "two.bin"));
    try std.testing.expectEqual(@as(u64, 2), stats.excluded);
    try std.testing.expectEqual(@as(u64, 2), stats.filtered_by_size);
}

test "displayPath normalizes separators" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("a/b/c.txt", try displayPath(arena_state.allocator(), ".\\a\\b\\c.txt"));
}
