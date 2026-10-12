//! Command-line parsing for `chunkmap <command> [options]`.
const std = @import("std");
const config = @import("config.zig");
const format = @import("format.zig");
const term = @import("term.zig");

pub const Command = union(enum) {
    scan,
    compare: struct { a: []const u8, b: []const u8 },
    help,
    version,
};

pub const usage =
    \\chunkmap — find where your disk space is duplicated, even inside files.
    \\
    \\USAGE
    \\  chunkmap scan [PATH ...] [options]     Analyze one or more folders (default: .)
    \\  chunkmap compare <FILE_A> <FILE_B>     Show which parts of two files are shared
    \\  chunkmap help | version
    \\
    \\SCAN OPTIONS
    \\  -o, --html FILE        Write an interactive, self-contained HTML report
    \\  -J, --json FILE        Write a machine-readable JSON report
    \\  -x, --exclude GLOB     Skip files/dirs matching GLOB (repeatable; * and ?)
    \\  -m, --min-size SIZE    Ignore files smaller than SIZE        (default 1)
    \\  -M, --max-size SIZE    Ignore files larger than SIZE
    \\  -n, --top N            Rows shown per terminal section       (default 10)
    \\  -s, --similarity F     Min. overlap for near-duplicates 0..1 (default 0.25)
    \\
    \\COMMON OPTIONS
    \\  -a, --avg-chunk SIZE   Average FastCDC chunk size, power of two (default 16K)
    \\  -j, --threads N        Worker threads                (default: CPU count)
    \\      --color MODE       auto | always | never         (default auto)
    \\      --env-file FILE    Load settings from FILE       (default .env)
    \\  -q, --quiet            No progress output
    \\
    \\SIZES accept B/K/M/G/T suffixes: 512, 16K, 64KiB, 1.5M, 2G
    \\Every option can also be set with a CHUNKMAP_* environment variable.
    \\
    \\EXAMPLES
    \\  chunkmap scan ~/Pictures ~/Downloads --html report.html
    \\  chunkmap scan . -x node_modules -x .git --min-size 1M
    \\  chunkmap compare backup-monday.tar backup-tuesday.tar
    \\
;

pub const ParseResult = struct {
    command: Command,
    /// Flags are applied after the environment, so they are kept until then.
    flags: []const Flag,
};

pub const Flag = struct { key: []const u8, value: []const u8 };

const Spec = struct { short: ?u8, long: []const u8, key: []const u8, takes_value: bool = true };

const specs = [_]Spec{
    .{ .short = 'o', .long = "html", .key = "CHUNKMAP_HTML" },
    .{ .short = 'J', .long = "json", .key = "CHUNKMAP_JSON" },
    .{ .short = 'x', .long = "exclude", .key = "CHUNKMAP_EXCLUDE" },
    .{ .short = 'm', .long = "min-size", .key = "CHUNKMAP_MIN_FILE_SIZE" },
    .{ .short = 'M', .long = "max-size", .key = "CHUNKMAP_MAX_FILE_SIZE" },
    .{ .short = 'n', .long = "top", .key = "CHUNKMAP_TOP" },
    .{ .short = 's', .long = "similarity", .key = "CHUNKMAP_SIMILARITY" },
    .{ .short = 'a', .long = "avg-chunk", .key = "CHUNKMAP_AVG_CHUNK" },
    .{ .short = 'j', .long = "threads", .key = "CHUNKMAP_THREADS" },
    .{ .short = null, .long = "color", .key = "CHUNKMAP_COLOR" },
    .{ .short = null, .long = "env-file", .key = "--env-file" },
    .{ .short = 'q', .long = "quiet", .key = "--quiet", .takes_value = false },
    .{ .short = null, .long = "no-color", .key = "--no-color", .takes_value = false },
};

fn findSpec(arg: []const u8) ?Spec {
    for (specs) |s| {
        if (std.mem.startsWith(u8, arg, "--") and std.mem.eql(u8, arg[2..], s.long)) return s;
        if (s.short) |c| if (arg.len == 2 and arg[0] == '-' and arg[1] == c) return s;
    }
    return null;
}

/// Parses argv (without the program name). Positional arguments go to
/// `cfg.roots` for `scan`; flags are returned to be applied later.
pub fn parse(arena: std.mem.Allocator, args: []const []const u8, cfg: *config.Config) config.Error!ParseResult {
    if (args.len == 0) return .{ .command = .help, .flags = &.{} };
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h"))
        return .{ .command = .help, .flags = &.{} };
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V"))
        return .{ .command = .version, .flags = &.{} };

    const is_scan = std.mem.eql(u8, cmd, "scan");
    const is_compare = std.mem.eql(u8, cmd, "compare");
    if (!is_scan and !is_compare) return config.fail("unknown command '{s}' (try 'chunkmap help')", .{cmd});

    var flags = std.ArrayList(Flag).init(arena);
    var positional = std.ArrayList([]const u8).init(arena);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            for (args[i + 1 ..]) |rest| try positional.append(rest);
            break;
        }
        if (arg.len > 1 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .{ .command = .help, .flags = &.{} };
            // Support --flag=value as well as --flag value.
            var name = arg;
            var inline_value: ?[]const u8 = null;
            if (std.mem.startsWith(u8, arg, "--")) if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                name = arg[0..eq];
                inline_value = arg[eq + 1 ..];
            };
            const spec = findSpec(name) orelse return config.fail("unknown option '{s}'", .{arg});
            if (!spec.takes_value) {
                try flags.append(.{ .key = spec.key, .value = "1" });
                continue;
            }
            const value = inline_value orelse blk: {
                i += 1;
                if (i >= args.len) return config.fail("option '{s}' needs a value", .{arg});
                break :blk args[i];
            };
            try flags.append(.{ .key = spec.key, .value = value });
            continue;
        }
        try positional.append(arg);
    }

    if (is_compare) {
        if (positional.items.len != 2) return config.fail("compare needs exactly two files", .{});
        return .{ .command = .{ .compare = .{ .a = positional.items[0], .b = positional.items[1] } }, .flags = flags.items };
    }
    try cfg.roots.appendSlice(positional.items);
    if (cfg.roots.items.len == 0) try cfg.roots.append(".");
    return .{ .command = .scan, .flags = flags.items };
}

/// Pulls out `--env-file` before the dotenv file is loaded.
pub fn preApply(cfg: *config.Config, flags: []const Flag) void {
    for (flags) |f| if (std.mem.eql(u8, f.key, "--env-file")) {
        cfg.env_file = f.value;
    };
}

/// Applies flags on top of the environment-derived configuration.
pub fn apply(cfg: *config.Config, arena: std.mem.Allocator, flags: []const Flag) config.Error!void {
    for (flags) |f| {
        if (std.mem.eql(u8, f.key, "--env-file")) continue;
        if (std.mem.eql(u8, f.key, "--quiet")) {
            cfg.quiet = true;
        } else if (std.mem.eql(u8, f.key, "--no-color")) {
            cfg.color = .never;
        } else {
            try config.applySetting(cfg, arena, f.key, f.value);
        }
    }
}

test "parse scan with flags and positional roots" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cfg = config.Config.init(arena);
    const args = [_][]const u8{ "scan", "photos", "-x", "node_modules", "--avg-chunk=64K", "docs", "-q", "--html", "r.html" };
    const res = try parse(arena, &args, &cfg);
    try std.testing.expect(res.command == .scan);
    try apply(&cfg, arena, res.flags);
    try std.testing.expectEqual(@as(usize, 2), cfg.roots.items.len);
    try std.testing.expectEqualStrings("docs", cfg.roots.items[1]);
    try std.testing.expectEqual(@as(u64, 65536), cfg.avg_chunk);
    try std.testing.expect(cfg.quiet);
    try std.testing.expectEqualStrings("r.html", cfg.html_path.?);
    try std.testing.expectEqualStrings("node_modules", cfg.excludes.items[0]);
}

test "parse compare and errors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cfg = config.Config.init(arena);
    const ok = try parse(arena, &.{ "compare", "a.tar", "b.tar" }, &cfg);
    try std.testing.expectEqualStrings("b.tar", ok.command.compare.b);
    try std.testing.expectError(error.InvalidValue, parse(arena, &.{ "compare", "a.tar" }, &cfg));
    try std.testing.expectError(error.InvalidValue, parse(arena, &.{ "scan", "--bogus" }, &cfg));
    try std.testing.expectError(error.InvalidValue, parse(arena, &.{ "scan", "--top" }, &cfg));
    try std.testing.expectError(error.InvalidValue, parse(arena, &.{"frobnicate"}, &cfg));
    const defaulted = try parse(arena, &.{"scan"}, &cfg);
    try std.testing.expect(defaulted.command == .scan);
    try std.testing.expectEqualStrings(".", cfg.roots.items[0]);
}
