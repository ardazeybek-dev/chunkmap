//! Human-friendly formatting helpers: byte sizes, counts, durations, percentages.
const std = @import("std");

/// Formats a byte count using binary units (KiB, MiB, ...).
pub const Bytes = struct {
    value: u64,

    pub fn format(self: Bytes, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        var buf: [32]u8 = undefined;
        try std.fmt.formatBuf(render(&buf, self.value), options, writer);
    }

    pub fn render(buf: []u8, value: u64) []const u8 {
        const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" };
        if (value < 1024) return std.fmt.bufPrint(buf, "{d} B", .{value}) catch "?";
        var v: f64 = @floatFromInt(value);
        var i: usize = 0;
        while (v >= 1024 and i < units.len - 1) : (i += 1) v /= 1024;
        return (if (v >= 100)
            std.fmt.bufPrint(buf, "{d:.0} {s}", .{ v, units[i] })
        else if (v >= 10)
            std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[i] })
        else
            std.fmt.bufPrint(buf, "{d:.2} {s}", .{ v, units[i] })) catch "?";
    }
};

pub fn bytes(value: u64) Bytes {
    return .{ .value = value };
}

/// Formats an integer with thousands separators: 1234567 -> "1,234,567".
pub const Count = struct {
    value: u64,

    pub fn format(self: Count, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        var buf: [32]u8 = undefined;
        try std.fmt.formatBuf(render(&buf, self.value), options, writer);
    }

    pub fn render(buf: []u8, value: u64) []const u8 {
        var digits: [20]u8 = undefined;
        const raw = std.fmt.bufPrint(&digits, "{d}", .{value}) catch return "?";
        var out: usize = 0;
        for (raw, 0..) |c, i| {
            if (i != 0 and (raw.len - i) % 3 == 0) {
                buf[out] = ',';
                out += 1;
            }
            buf[out] = c;
            out += 1;
        }
        return buf[0..out];
    }
};

pub fn count(value: u64) Count {
    return .{ .value = value };
}

/// Formats nanoseconds as "320ms", "41.2s" or "3m 07s".
pub const Duration = struct {
    ns: u64,

    pub fn format(self: Duration, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        var buf: [32]u8 = undefined;
        try std.fmt.formatBuf(render(&buf, self.ns), options, writer);
    }

    pub fn render(buf: []u8, ns: u64) []const u8 {
        const ms = ns / std.time.ns_per_ms;
        if (ms < 1000) return std.fmt.bufPrint(buf, "{d}ms", .{ms}) catch "?";
        const secs: f64 = @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
        if (secs < 60) return std.fmt.bufPrint(buf, "{d:.1}s", .{secs}) catch "?";
        const whole: u64 = @intFromFloat(secs);
        return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ whole / 60, whole % 60 }) catch "?";
    }
};

pub fn duration(ns: u64) Duration {
    return .{ .ns = ns };
}

/// Safe ratio that returns 0 for an empty denominator.
pub fn ratio(num: u64, den: u64) f64 {
    if (den == 0) return 0;
    return @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(den));
}

/// Parses human sizes such as "512", "16K", "16KiB", "1.5M", "2g" into bytes (binary units).
pub fn parseSize(text: []const u8) error{InvalidSize}!u64 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return error.InvalidSize;
    var end: usize = 0;
    while (end < trimmed.len and (std.ascii.isDigit(trimmed[end]) or trimmed[end] == '.')) end += 1;
    if (end == 0) return error.InvalidSize;
    const number = std.fmt.parseFloat(f64, trimmed[0..end]) catch return error.InvalidSize;
    var unit = std.mem.trim(u8, trimmed[end..], " ");
    if (unit.len > 0 and (unit[unit.len - 1] == 'b' or unit[unit.len - 1] == 'B')) unit = unit[0 .. unit.len - 1];
    if (unit.len == 2 and (unit[1] == 'i' or unit[1] == 'I')) unit = unit[0..1];
    if (unit.len > 1) return error.InvalidSize;
    const multiplier: f64 = if (unit.len == 0) 1 else switch (std.ascii.toLower(unit[0])) {
        'k' => 1024,
        'm' => 1024 * 1024,
        'g' => 1024 * 1024 * 1024,
        't' => 1024 * 1024 * 1024 * 1024,
        else => return error.InvalidSize,
    };
    const result = number * multiplier;
    if (result < 0 or result > 9.0e18) return error.InvalidSize;
    return @intFromFloat(@round(result));
}

test "bytes rendering" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512 B", Bytes.render(&buf, 512));
    try std.testing.expectEqualStrings("1.00 KiB", Bytes.render(&buf, 1024));
    try std.testing.expectEqualStrings("16.0 KiB", Bytes.render(&buf, 16 * 1024));
    try std.testing.expectEqualStrings("1.50 GiB", Bytes.render(&buf, 3 * 512 * 1024 * 1024));
}

test "count rendering" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0", Count.render(&buf, 0));
    try std.testing.expectEqualStrings("999", Count.render(&buf, 999));
    try std.testing.expectEqualStrings("1,000", Count.render(&buf, 1000));
    try std.testing.expectEqualStrings("12,345,678", Count.render(&buf, 12345678));
}

test "duration rendering" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("320ms", Duration.render(&buf, 320 * std.time.ns_per_ms));
    try std.testing.expectEqualStrings("41.2s", Duration.render(&buf, 41_200 * std.time.ns_per_ms));
    try std.testing.expectEqualStrings("3m 07s", Duration.render(&buf, 187 * std.time.ns_per_s));
}

test "parseSize" {
    try std.testing.expectEqual(@as(u64, 512), try parseSize("512"));
    try std.testing.expectEqual(@as(u64, 16384), try parseSize("16K"));
    try std.testing.expectEqual(@as(u64, 16384), try parseSize("16KiB"));
    try std.testing.expectEqual(@as(u64, 16384), try parseSize("16kb"));
    try std.testing.expectEqual(@as(u64, 1572864), try parseSize("1.5M"));
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024 * 1024), try parseSize("2g"));
    try std.testing.expectError(error.InvalidSize, parseSize(""));
    try std.testing.expectError(error.InvalidSize, parseSize("abc"));
    try std.testing.expectError(error.InvalidSize, parseSize("12Q"));
}
