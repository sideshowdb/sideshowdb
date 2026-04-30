//! Token preview / redaction helpers.
//!
//! `tokenPreview` produces a short, human-readable summary of a token
//! that is safe to print to terminals or write to logs. The output
//! preserves the GitHub PAT family prefix (`ghp_`, `gho_`, `ghu_`, etc.)
//! so users can confirm they pasted the right *kind* of token, plus the
//! last 4 characters as a fingerprint. Everything else is masked.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Number of trailing token characters surfaced in the preview.
pub const tail_chars: usize = 4;

/// Builds a preview like `ghp_****…ab12` or, for short tokens,
/// `****…1234`. Caller owns the returned slice.
pub fn tokenPreview(gpa: Allocator, token: []const u8) ![]u8 {
    if (token.len == 0) return try gpa.dupe(u8, "(empty)");

    const tail_start = if (token.len > tail_chars) token.len - tail_chars else 0;
    const tail = token[tail_start..];

    const prefix_end = findPrefixEnd(token);
    if (prefix_end > 0 and prefix_end + tail_chars + 1 < token.len) {
        return try std.fmt.allocPrint(
            gpa,
            "{s}****\u{2026}{s}",
            .{ token[0..prefix_end], tail },
        );
    }
    return try std.fmt.allocPrint(gpa, "****\u{2026}{s}", .{tail});
}

fn findPrefixEnd(token: []const u8) usize {
    const i = std.mem.indexOfScalar(u8, token, '_') orelse return 0;
    if (i + 1 >= token.len) return 0;
    return i + 1;
}

test "tokenPreview keeps GitHub prefix and last 4" {
    const gpa = std.testing.allocator;
    const out = try tokenPreview(gpa, "ghp_abcdefghijklmnop1234");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("ghp_****\u{2026}1234", out);
}

test "tokenPreview falls back to mask for prefix-less tokens" {
    const gpa = std.testing.allocator;
    const out = try tokenPreview(gpa, "abcdef1234");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("****\u{2026}1234", out);
}

test "tokenPreview handles empty token" {
    const gpa = std.testing.allocator;
    const out = try tokenPreview(gpa, "");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("(empty)", out);
}
