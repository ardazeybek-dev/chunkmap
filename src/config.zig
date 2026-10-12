//! Configuration resolution.
//!
//! Precedence (lowest → highest): built-in defaults → `.env` file →
//! process environment → command-line flags. Every option has a
//! `CHUNKMAP_*` environment variable; see `.env.example`.
const std = @import("std");
const format = @import("format.zig");
const term = @import("term.zig");

pub const Config = struct {
    roots: std.ArrayList([]const u8),
    excludes: std.ArrayList([]const u8),
    avg_chunk: u64 = 16 * 1024,
    threads: usize = 0, // 0 = one per CPU
    min_file_size: u64 = 1,
    max_file_size: u64 = std.math.maxInt(u64),
    html_path: ?[]const u8 = null,
    json_path: ?[]const u8 = null,
    top: usize = 10,
    similarity: f64 = 0.25,
    color: term.ColorMode = .auto,
    no_color_env: bool = false,
    quiet: bool = false,
    env_file: []const u8 = ".env",

    pub fn init(arena: std.mem.Allocator) Config {
        return .{
            .roots = std.ArrayList([]const u8).init(arena),
            .excludes = std.ArrayList([]const u8).init(arena),
        };
    }

    pub fn effectiveThreads(self: Config) usize {
        if (self.threads > 0) return self.threads;
        return std.Thread.getCpuCount() catch 4;
    }
};

pub const Error = error{InvalidValue} || std.mem.Allocator.Error;

/// Holds the message for the last configuration error so `main` can print it.
pub var last_error: [256]u8 = undefined;
pub var last_error_len: usize = 0;

pub fn fail(comptime fmt: []const u8, args: anytype) error{InvalidValue} {
    const msg = std.fmt.bufPrint(&last_error, fmt, args) catch last_error[0..];
    last_error_len = msg.len;
    return error.InvalidValue;
}

pub fn errorMessage() []const u8 {
    return last_error[0..last_error_len];
}

/// Applies a single `KEY=value` setting. Unknown keys are ignored so a shared
/// `.env` file can hold settings for other tools too.
pub fn applySetting(cfg: *Config, arena: std.mem.Allocator, key: []const u8, value: []const u8) Error!void {
    const eq = std.mem.eql;
    if (eq(u8, key, "CHUNKMAP_AVG_CHUNK")) {
        cfg.avg_chunk = format.parseSize(value) catch return fail("{s}: invalid size '{s}'", .{ key, value });
    } else if (eq(u8, key, "CHUNKMAP_THREADS")) {
        cfg.threads = std.fmt.parseInt(usize, value, 10) catch return fail("{s}: expected a number, got '{s}'", .{ key, value });
    } else if (eq(u8, key, "CHUNKMAP_MIN_FILE_SIZE")) {
        cfg.min_file_size = format.parseSize(value) catch return fail("{s}: invalid size '{s}'", .{ key, value });
    } else if (eq(u8, key, "CHUNKMAP_MAX_FILE_SIZE")) {
        cfg.max_file_size = format.parseSize(value) catch return fail("{s}: invalid size '{s}'", .{ key, value });
    } else if (eq(u8, key, "CHUNKMAP_EXCLUDE")) {
        var it = std.mem.tokenizeScalar(u8, value, ',');
        while (it.next()) |raw| {
            const pat = std.mem.trim(u8, raw, " \t");
            if (pat.len > 0) try cfg.excludes.append(try arena.dupe(u8, pat));
        }
    } else if (eq(u8, key, "CHUNKMAP_HTML")) {
        cfg.html_path = if (value.len == 0) null else try arena.dupe(u8, value);
    } else if (eq(u8, key, "CHUNKMAP_JSON")) {
        cfg.json_path = if (value.len == 0) null else try arena.dupe(u8, value);
    } else if (eq(u8, key, "CHUNKMAP_TOP")) {
        cfg.top = std.fmt.parseInt(usize, value, 10) catch return fail("{s}: expected a number, got '{s}'", .{ key, value });
    } else if (eq(u8, key, "CHUNKMAP_SIMILARITY")) {
        cfg.similarity = parseUnit(value) catch return fail("{s}: expected a number between 0 and 1, got '{s}'", .{ key, value });
    } else if (eq(u8, key, "CHUNKMAP_COLOR")) {
        cfg.color = std.meta.stringToEnum(term.ColorMode, value) orelse return fail("{s}: expected auto|always|never, got '{s}'", .{ key, value });
    } else if (eq(u8, key, "NO_COLOR")) {
        cfg.no_color_env = value.len > 0;
    }
}

pub fn parseUnit(text: []const u8) !f64 {
    const v = try std.fmt.parseFloat(f64, std.mem.trim(u8, text, " "));
    if (!(v >= 0 and v <= 1)) return error.OutOfRange;
    return v;
}

/// Parses dotenv syntax: `KEY=value`, `export KEY=value`, `# comments`,
/// single/double quoted values and trailing ` # comments` on unquoted values.
pub fn parseDotenv(arena: std.mem.Allocator, text: []const u8) !std.StringArrayHashMap([]const u8) {
    var map = std.StringArrayHashMap([]const u8).init(arena);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimLeft(u8, line[7..], " \t");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) continue;
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len >= 2 and (value[0] == '"' or value[0] == '\'')) {
            if (std.mem.indexOfScalarPos(u8, value, 1, value[0])) |close| value = value[1..close];
        } else if (std.mem.indexOf(u8, value, " #")) |hash| {
            value = std.mem.trimRight(u8, value[0..hash], " \t");
        }
        try map.put(try arena.dupe(u8, key), try arena.dupe(u8, value));
    }
    return map;
}

/// Loads settings from the dotenv file (if present) and then the process environment.
pub fn loadEnvironment(cfg: *Config, arena: std.mem.Allocator) Error!void {
    if (std.fs.cwd().readFileAlloc(arena, cfg.env_file, 1 << 20)) |text| {
        var map = parseDotenv(arena, text) catch return fail("could not parse {s}", .{cfg.env_file});
        var it = map.iterator();
        while (it.next()) |e| try applySetting(cfg, arena, e.key_ptr.*, e.value_ptr.*);
    } else |_| {}

    var env = std.process.getEnvMap(arena) catch return fail("could not read the process environment", .{});
    var it = env.iterator();
    while (it.next()) |e| try applySetting(cfg, arena, e.key_ptr.*, e.value_ptr.*);
}

test "dotenv parsing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text =
        \\# comment
        \\CHUNKMAP_AVG_CHUNK=64K
        \\export CHUNKMAP_THREADS = 3
        \\CHUNKMAP_EXCLUDE="node_modules, .git,*.iso"
        \\CHUNKMAP_TOP=7 # inline comment
        \\BROKEN LINE
        \\
    ;
    var map = try parseDotenv(arena_state.allocator(), text);
    try std.testing.expectEqual(@as(usize, 4), map.count());
    try std.testing.expectEqualStrings("64K", map.get("CHUNKMAP_AVG_CHUNK").?);
    try std.testing.expectEqualStrings("3", map.get("CHUNKMAP_THREADS").?);
    try std.testing.expectEqualStrings("node_modules, .git,*.iso", map.get("CHUNKMAP_EXCLUDE").?);
    try std.testing.expectEqualStrings("7", map.get("CHUNKMAP_TOP").?);
}

test "applySetting validates and converts values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cfg = Config.init(arena);
    try applySetting(&cfg, arena, "CHUNKMAP_AVG_CHUNK", "64KiB");
    try applySetting(&cfg, arena, "CHUNKMAP_EXCLUDE", "node_modules, .git ,");
    try applySetting(&cfg, arena, "CHUNKMAP_COLOR", "never");
    try applySetting(&cfg, arena, "UNRELATED", "whatever");
    try std.testing.expectEqual(@as(u64, 65536), cfg.avg_chunk);
    try std.testing.expectEqual(@as(usize, 2), cfg.excludes.items.len);
    try std.testing.expectEqualStrings(".git", cfg.excludes.items[1]);
    try std.testing.expectEqual(term.ColorMode.never, cfg.color);
    try std.testing.expectError(error.InvalidValue, applySetting(&cfg, arena, "CHUNKMAP_SIMILARITY", "1.5"));
    try std.testing.expectError(error.InvalidValue, applySetting(&cfg, arena, "CHUNKMAP_THREADS", "many"));
}
