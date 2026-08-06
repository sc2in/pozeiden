//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
//! Shared helpers for the hand-written line-oriented diagram parsers in
//! `root.zig`.  Centralising these removes the copy of each that used to be
//! inlined across the `render*Direct` functions.
const std = @import("std");

/// True if `line` should be skipped by a line-oriented parser: it is blank or
/// a `%%` comment/directive.  `line` is expected to already be trimmed of
/// surrounding whitespace by the caller.
pub fn isSkippable(line: []const u8) bool {
    return line.len == 0 or std.mem.startsWith(u8, line, "%%");
}

/// Iterator over the lines of a diagram source: yields each line trimmed of
/// surrounding ` \t\r`, skipping blank lines and `%%` comments/directives —
/// the loop header shared by most of the line-oriented parsers. Parsers whose
/// grammar makes indentation or comments significant (mindmap, kanban, and
/// sequence's multi-line `ref` blocks) keep their own raw-line loops.
pub const LineIter = struct {
    inner: std.mem.SplitIterator(u8, .scalar),

    pub fn init(text: []const u8) LineIter {
        return .{ .inner = std.mem.splitScalar(u8, text, '\n') };
    }

    /// Next non-blank, non-comment line, trimmed; `null` at end of input.
    pub fn next(self: *LineIter) ?[]const u8 {
        while (self.inner.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (isSkippable(line)) continue;
            return line;
        }
        return null;
    }
};

/// Split `s` at the first occurrence of `delim`, returning `.{ before, after }`
/// with `after` trimmed of spaces/tabs.  If `delim` is absent, returns
/// `.{ s, "" }`.
pub fn splitFirst(s: []const u8, delim: u8) [2][]const u8 {
    if (std.mem.indexOfScalar(u8, s, delim)) |i| {
        return .{ s[0..i], std.mem.trim(u8, s[i + 1 ..], " \t") };
    }
    return .{ s, "" };
}

/// Trim surrounding spaces/tabs from `s`, then strip a single pair of
/// enclosing double quotes if present.
pub fn stripQuotes(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') return t[1 .. t.len - 1];
    return t;
}

test "isSkippable: blank and comment lines" {
    try std.testing.expect(isSkippable(""));
    try std.testing.expect(isSkippable("%% a comment"));
    try std.testing.expect(!isSkippable("graph TD"));
    try std.testing.expect(!isSkippable("A --> B"));
}

test "splitFirst: with and without delimiter" {
    const a = splitFirst("key: value", ':');
    try std.testing.expectEqualStrings("key", a[0]);
    try std.testing.expectEqualStrings("value", a[1]);
    const b = splitFirst("nodelim", ':');
    try std.testing.expectEqualStrings("nodelim", b[0]);
    try std.testing.expectEqualStrings("", b[1]);
}

test "stripQuotes: quoted and unquoted" {
    try std.testing.expectEqualStrings("hi", stripQuotes("\"hi\""));
    try std.testing.expectEqualStrings("hi", stripQuotes("  hi  "));
    try std.testing.expectEqualStrings("a\"b", stripQuotes("a\"b"));
}
