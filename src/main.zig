//! chunkmap — find where your disk space is duplicated, even inside files.
const std = @import("std");
const build_options = @import("build_options");

const cli = @import("cli.zig");
const config = @import("config.zig");
const fastcdc = @import("fastcdc.zig");
const scanner = @import("scanner.zig");
const pipeline = @import("pipeline.zig");
const analysis = @import("analysis.zig");
const compare = @import("compare.zig");
const term = @import("term.zig");
const fmt = @import("format.zig");
const model = @import("report/model.zig");
const writers = @import("report/writers.zig");
const terminal = @import("report/terminal.zig");

pub const version = build_options.version;

pub fn main() !void {
    term.setupConsole();
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const stderr = std.io.getStdErr();
    const code = run(arena) catch |err| blk: {
        const msg = switch (err) {
            error.InvalidValue => config.errorMessage(),
            error.FileNotFound => "file or directory not found",
            error.AccessDenied => "permission denied",
            else => @errorName(err),
        };
        stderr.writer().print("chunkmap: error: {s}\n", .{msg}) catch {};
        break :blk @as(u8, if (err == error.InvalidValue) 2 else 1);
    };
    std.process.exit(code);
}

fn run(arena: std.mem.Allocator) !u8 {
    const argv = try std.process.argsAlloc(arena);
    var cfg = config.Config.init(arena);
    const parsed = try cli.parse(arena, argv[1..], &cfg);
    cli.preApply(&cfg, parsed.flags);
    try config.loadEnvironment(&cfg, arena);
    try cli.apply(&cfg, arena, parsed.flags);

    const stdout_file = std.io.getStdOut();
    var out = std.io.bufferedWriter(stdout_file.writer());
    defer out.flush() catch {};
    const style = term.detect(cfg.color, stdout_file, cfg.no_color_env);

    switch (parsed.command) {
        .help => try out.writer().writeAll(cli.usage),
        .version => try out.writer().print("chunkmap {s}\n", .{version}),
        .compare => |c| {
            for ([_][]const u8{ c.a, c.b }) |p| std.fs.cwd().access(p, .{}) catch |err|
                return config.fail("cannot open '{s}': {s}", .{ p, @errorName(err) });
            const params = fastcdc.Params.fromAverage(cfg.avg_chunk) catch return badChunk(cfg.avg_chunk);
            const result = try compare.compareFiles(std.heap.smp_allocator, c.a, c.b, fastcdc.Chunker.init(params));
            try compare.render(out.writer(), style, c.a, c.b, result, params);
        },
        .scan => try scan(arena, cfg, style, out.writer()),
    }
    return 0;
}

fn badChunk(avg: u64) error{InvalidValue} {
    return config.fail("average chunk size must be a power of two between 256 B and 4 MiB (got {d})", .{avg});
}

/// Renders "?" while the total is unknown (Windows defers stat to workers).
const TotalBytes = struct {
    v: u64,
    pub fn format(self: TotalBytes, comptime f: []const u8, o: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.v == 0) return writer.writeAll("?");
        try fmt.bytes(self.v).format(f, o, writer);
    }
};

const Ticker = struct {
    enabled: bool,
    style: term.Style,
    total_files: usize,
    total_bytes: u64,
    started: std.time.Instant,
    frame: usize = 0,

    fn tick(self: *Ticker, p: *pipeline.Progress) void {
        if (!self.enabled) return;
        const spinner = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
        self.frame +%= 1;
        const done_files = p.files_done.load(.monotonic);
        const done_bytes = p.bytes_done.load(.monotonic);
        const now = std.time.Instant.now() catch return;
        const secs = @max(@as(f64, @floatFromInt(now.since(self.started))) / std.time.ns_per_s, 0.001);
        const rate: u64 = @intFromFloat(@as(f64, @floatFromInt(done_bytes)) / secs);
        const st = self.style;
        std.io.getStdErr().writer().print("\r\x1b[2K  {}{s}{s} chunking {} / {} files  {}{} / {} · {}/s{s}", .{
            st.fg(term.palette.amber), spinner[self.frame % spinner.len],   st.reset(),
            fmt.count(done_files),     fmt.count(self.total_files),         st.fg(term.palette.muted),
            fmt.bytes(done_bytes),     TotalBytes{ .v = self.total_bytes }, fmt.bytes(rate),
            st.reset(),
        }) catch {};
    }

    fn clear(self: *Ticker) void {
        if (self.enabled) std.io.getStdErr().writeAll("\r\x1b[2K") catch {};
    }
};

fn scan(arena: std.mem.Allocator, cfg: config.Config, style: term.Style, w: anytype) !void {
    const params = fastcdc.Params.fromAverage(cfg.avg_chunk) catch return badChunk(cfg.avg_chunk);
    const threads = cfg.effectiveThreads();
    for (cfg.roots.items) |root| std.fs.cwd().access(root, .{}) catch |err|
        return config.fail("cannot open '{s}': {s}", .{ root, @errorName(err) });
    const started = try std.time.Instant.now();
    const stderr_file = std.io.getStdErr();
    const progress_on = !cfg.quiet and stderr_file.isTty() and stderr_file.getOrEnableAnsiEscapeSupport();
    const err_style = term.detect(cfg.color, stderr_file, cfg.no_color_env);

    if (progress_on) stderr_file.writer().print("  {}⠿{s} walking {d} path(s)…", .{ err_style.fg(term.palette.amber), err_style.reset(), cfg.roots.items.len }) catch {};
    var stats = scanner.Stats{};
    const walked = try scanner.scan(arena, cfg.roots.items, .{
        .excludes = cfg.excludes.items,
        .min_file_size = cfg.min_file_size,
        .max_file_size = cfg.max_file_size,
    }, &stats);
    var total_bytes: u64 = 0;
    for (walked) |f| total_bytes += f.size;

    var ticker = Ticker{ .enabled = progress_on, .style = err_style, .total_files = walked.len, .total_bytes = total_bytes, .started = started };
    var progress = pipeline.Progress{};
    // Workers allocate concurrently, so they use the thread-safe SMP allocator.
    const range = pipeline.SizeRange{ .min = cfg.min_file_size, .max = cfg.max_file_size };
    const processed = try pipeline.run(std.heap.smp_allocator, walked, fastcdc.Chunker.init(params), range, threads, &progress, &ticker, Ticker.tick);
    ticker.clear();

    // Adopt the sizes observed by the workers and drop size-filtered files.
    var files = std.ArrayList(scanner.FileEntry).init(arena);
    var results = std.ArrayList(pipeline.FileResult).init(arena);
    for (walked, processed.results) |f, r| {
        if (r.filtered) {
            stats.filtered_by_size += 1;
            continue;
        }
        try files.append(.{ .path = f.path, .size = if (r.ok) r.size else f.size });
        try results.append(r);
    }

    const display = try arena.alloc([]const u8, files.items.len);
    for (files.items, display) |f, *d| d.* = try scanner.displayPath(arena, f.path);

    const result = try analysis.analyze(arena, files.items, display, results.items, .{ .similarity = cfg.similarity });
    const elapsed = (try std.time.Instant.now()).since(started);

    if (cfg.html_path != null or cfg.json_path != null) {
        const report = try model.build(arena, .{
            .version = version,
            .duration_ns = elapsed,
            .roots = cfg.roots.items,
            .files = files.items,
            .display = display,
            .result = &result,
            .stats = stats,
            .chunk_params = params,
            .threads = threads,
            .min_file_size = cfg.min_file_size,
            .similarity = cfg.similarity,
            .excludes = cfg.excludes.items,
            .groups_total = result.groups_total,
        });
        if (cfg.html_path) |p| try writers.writeFile(arena, p, report, .html);
        if (cfg.json_path) |p| try writers.writeFile(arena, p, report, .json);
    }

    try terminal.render(w, .{
        .version = version,
        .style = style,
        .files = files.items,
        .display = display,
        .result = &result,
        .stats = stats,
        .chunk_params = params,
        .threads = threads,
        .elapsed_ns = elapsed,
        .top = cfg.top,
        .groups_total = result.groups_total,
        .html_path = cfg.html_path,
        .json_path = cfg.json_path,
    });
}

test {
    _ = @import("format.zig");
    _ = @import("glob.zig");
    _ = @import("term.zig");
    _ = @import("fastcdc.zig");
    _ = @import("scanner.zig");
    _ = @import("pipeline.zig");
    _ = @import("analysis.zig");
    _ = @import("config.zig");
    _ = @import("cli.zig");
    _ = @import("compare.zig");
    _ = @import("report/model.zig");
    _ = @import("report/writers.zig");
    _ = @import("report/terminal.zig");
}
