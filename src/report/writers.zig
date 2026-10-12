//! JSON and self-contained HTML report writers.
const std = @import("std");
const model = @import("model.zig");

const template = @embedFile("template.html");
const marker = "__CHUNKMAP_DATA__";

pub fn writeJson(report: model.Report, writer: anytype) !void {
    try std.json.stringify(report, .{ .whitespace = .indent_2 }, writer);
    try writer.writeByte('\n');
}

/// Writes the HTML template with the report embedded as JSON. Every `<` is
/// emitted as `\u003c` so file names can never close the <script> element.
pub fn writeHtml(arena: std.mem.Allocator, report: model.Report, writer: anytype) !void {
    const at = comptime blk: {
        @setEvalBranchQuota(1_000_000);
        break :blk std.mem.indexOf(u8, template, marker) orelse @compileError("template has no data marker");
    };
    var json = std.ArrayList(u8).init(arena);
    try std.json.stringify(report, .{}, json.writer());

    try writer.writeAll(template[0..at]);
    var last: usize = 0;
    for (json.items, 0..) |c, i| {
        if (c != '<') continue;
        try writer.writeAll(json.items[last..i]);
        try writer.writeAll("\\u003c");
        last = i + 1;
    }
    try writer.writeAll(json.items[last..]);
    try writer.writeAll(template[at + marker.len ..]);
}

pub fn writeFile(arena: std.mem.Allocator, path: []const u8, report: model.Report, comptime kind: enum { json, html }) !void {
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var buffered = std.io.bufferedWriter(file.writer());
    switch (kind) {
        .json => try writeJson(report, buffered.writer()),
        .html => try writeHtml(arena, report, buffered.writer()),
    }
    try buffered.flush();
}

test "html embedding escapes script terminators" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const evil = [_]model.FileOut{.{ .p = "</script><script>alert(1)</script>", .s = 1, .r = 0 }};
    const report = model.Report{
        .version = "test",
        .generated_at = 0,
        .duration_ms = 0,
        .roots = &.{"."},
        .params = .{ .avg_chunk = 1, .min_chunk = 1, .max_chunk = 1, .threads = 1, .min_file_size = 1, .similarity = 0.25, .excludes = &.{} },
        .summary = std.mem.zeroes(model.SummaryOut),
        .scan = .{},
        .duplicate_groups = &.{},
        .duplicate_groups_total = 0,
        .similar_pairs = &.{},
        .directories = &.{},
        .extensions = &.{},
        .chunk_histogram = &.{},
        .files = &evil,
        .files_omitted = 0,
        .bytes_omitted = 0,
    };
    var out = std.ArrayList(u8).init(arena);
    try writeHtml(arena, report, out.writer());
    const html = out.items;
    const data_start = std.mem.indexOf(u8, html, "id=\"chunkmap-data\"").?;
    const data_end = std.mem.indexOfPos(u8, html, data_start, "</script>").?;
    const embedded = html[data_start..data_end];
    try std.testing.expect(std.mem.indexOf(u8, embedded, "\\u003c/script>") != null);
    try std.testing.expect(std.mem.indexOf(u8, embedded, "alert(1)") != null);

    var json = std.ArrayList(u8).init(arena);
    try writeJson(report, json.writer());
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, json.items, .{});
    try std.testing.expectEqualStrings("chunkmap", parsed.value.object.get("tool").?.string);
}
