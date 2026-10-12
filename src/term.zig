//! Terminal styling: ANSI truecolor palette, Unicode bars and Windows console setup.
const std = @import("std");
const builtin = @import("builtin");

pub const ColorMode = enum { auto, always, never };

pub const Rgb = struct { r: u8, g: u8, b: u8 };

/// Brand palette shared by the terminal and HTML reports.
pub const palette = struct {
    pub const amber = Rgb{ .r = 255, .g = 184, .b = 77 };
    pub const teal = Rgb{ .r = 64, .g = 224, .b = 196 };
    pub const coral = Rgb{ .r = 255, .g = 112, .b = 102 };
    pub const violet = Rgb{ .r = 167, .g = 139, .b = 250 };
    pub const muted = Rgb{ .r = 128, .g = 136, .b = 152 };
    pub const faint = Rgb{ .r = 70, .g = 76, .b = 90 };
    pub const text = Rgb{ .r = 226, .g = 230, .b = 238 };
};

pub const Style = struct {
    enabled: bool,

    pub fn fg(self: Style, c: Rgb) Fg {
        return .{ .enabled = self.enabled, .c = c };
    }
    pub fn bold(self: Style) []const u8 {
        return if (self.enabled) "\x1b[1m" else "";
    }
    pub fn dim(self: Style) []const u8 {
        return if (self.enabled) "\x1b[2m" else "";
    }
    pub fn reset(self: Style) []const u8 {
        return if (self.enabled) "\x1b[0m" else "";
    }
};

pub const Fg = struct {
    enabled: bool,
    c: Rgb,

    pub fn format(self: Fg, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        if (self.enabled) try writer.print("\x1b[38;2;{d};{d};{d}m", .{ self.c.r, self.c.g, self.c.b });
    }
};

/// Decides whether to emit ANSI escapes for the given output file.
pub fn detect(mode: ColorMode, file: std.fs.File, no_color_env: bool) Style {
    return .{ .enabled = switch (mode) {
        .always => true,
        .never => false,
        .auto => !no_color_env and file.getOrEnableAnsiEscapeSupport(),
    } };
}

extern "kernel32" fn SetConsoleOutputCP(code_page: c_uint) callconv(.winapi) c_int;

/// Switches the Windows console to UTF-8 so box-drawing characters render.
pub fn setupConsole() void {
    if (builtin.os.tag == .windows) _ = SetConsoleOutputCP(65001);
}

const eighths = [_][]const u8{ "", "▏", "▎", "▍", "▌", "▋", "▊", "▉" };

/// Writes a smooth horizontal bar `width` cells wide filled to `frac` (0..1).
pub fn bar(writer: anytype, style: Style, frac_in: f64, width: usize, fill: Rgb, track: Rgb) !void {
    const frac = std.math.clamp(frac_in, 0, 1);
    const total_eighths: usize = @intFromFloat(@round(frac * @as(f64, @floatFromInt(width * 8))));
    const full = total_eighths / 8;
    const part = total_eighths % 8;
    try writer.print("{}", .{style.fg(fill)});
    for (0..full) |_| try writer.writeAll("█");
    var used = full;
    if (part > 0 and used < width) {
        try writer.writeAll(eighths[part]);
        used += 1;
    }
    try writer.print("{}", .{style.fg(track)});
    for (used..width) |_| try writer.writeAll(if (style.enabled) "─" else "·");
    try writer.writeAll(style.reset());
}

/// Eight-level sparkline glyphs for histograms.
pub const spark = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

test "bar renders exact width without color" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try bar(fbs.writer(), .{ .enabled = false }, 0.5, 10, palette.teal, palette.faint);
    try std.testing.expectEqual(@as(usize, 10), try std.unicode.utf8CountCodepoints(fbs.getWritten()));
}
