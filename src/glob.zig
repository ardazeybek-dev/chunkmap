//! Minimal, allocation-free glob matching used for `--exclude` patterns.
//!
//! Supported syntax: `*` (any run of characters, including `/`) and `?`
//! (exactly one character). Matching is ASCII case-insensitive and treats `\`
//! and `/` as the same separator, so patterns behave identically everywhere.
const std = @import("std");

pub fn match(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star_p: ?usize = null;
    var star_t: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or charEq(pattern[p], text[t]))) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star_p = p;
            star_t = t;
            p += 1;
        } else if (star_p) |sp| {
            p = sp + 1;
            star_t += 1;
            t = star_t;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn charEq(a: u8, b: u8) bool {
    const na: u8 = if (a == '\\') '/' else a;
    const nb: u8 = if (b == '\\') '/' else b;
    return std.ascii.toLower(na) == std.ascii.toLower(nb);
}

/// Returns true when any pattern matches. Patterns containing a path separator
/// are matched against the root-relative path, all others against the basename.
pub fn excluded(patterns: []const []const u8, basename: []const u8, rel_path: []const u8) bool {
    for (patterns) |pat| {
        const has_sep = std.mem.indexOfAny(u8, pat, "/\\") != null;
        if (match(pat, if (has_sep) rel_path else basename)) return true;
    }
    return false;
}

test "literal and wildcard matching" {
    try std.testing.expect(match("node_modules", "node_modules"));
    try std.testing.expect(match("node_modules", "Node_Modules"));
    try std.testing.expect(!match("node_modules", "node_module"));
    try std.testing.expect(match("*.iso", "ubuntu-24.04.iso"));
    try std.testing.expect(!match("*.iso", "ubuntu.iso.txt"));
    try std.testing.expect(match("IMG_????.JPG", "img_2041.jpg"));
    try std.testing.expect(match("*", ""));
    try std.testing.expect(match("a*b*c", "aXXbYYc"));
    try std.testing.expect(!match("a*b*c", "aXXbYY"));
}

test "path patterns use the relative path" {
    const pats = [_][]const u8{ "build/*", ".git" };
    try std.testing.expect(excluded(&pats, "out.o", "build/obj/out.o"));
    try std.testing.expect(excluded(&pats, "out.o", "build\\obj\\out.o"));
    try std.testing.expect(excluded(&pats, ".git", "src/.git"));
    try std.testing.expect(!excluded(&pats, "main.zig", "src/main.zig"));
}
