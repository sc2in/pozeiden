//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
//! Minimal single-pass XML well-formedness checker for pozeiden's own SVG
//! output.  Not a general XML validator — just enough to catch emitter bugs
//! (unbalanced tags, unterminated/unquoted attributes, raw `<`/`&`/control
//! bytes in text) that substring and golden-byte assertions cannot see: those
//! pin what we emit, not that it parses.  This is the oracle behind the
//! `fuzz_render_wellformed` target and a deterministic gate over the golden
//! baselines.  Graceful wrong answers (a render error) are out of scope; a
//! *successful* render must always pass this check.

const std = @import("std");

pub const WellformedError = error{
    UnbalancedTag,
    MismatchedClosingTag,
    UnterminatedTag,
    BadAttribute,
    BadEntity,
    ControlByte,
    NoRootElement,
    MultipleRootElements,
    RootIsNotSvg,
    TrailingContent,
};

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':' or c == '.';
}

/// Validate an entity reference starting at `s[i]` == '&'.  Returns the index
/// one past the terminating ';'.  Accepts the five predefined names plus
/// decimal/hex character references — everything `xmlEscape` can produce.
fn checkEntity(s: []const u8, i: usize) WellformedError!usize {
    const semi = std.mem.indexOfScalarPos(u8, s, i + 1, ';') orelse return error.BadEntity;
    const name = s[i + 1 .. semi];
    if (name.len == 0 or name.len > 8) return error.BadEntity;
    if (name[0] == '#') {
        const digits = if (name.len > 2 and (name[1] == 'x' or name[1] == 'X')) name[2..] else name[1..];
        if (digits.len == 0) return error.BadEntity;
        for (digits) |c| if (!std.ascii.isHex(c)) return error.BadEntity;
        return semi + 1;
    }
    const known = [_][]const u8{ "amp", "lt", "gt", "quot", "apos" };
    for (known) |k| if (std.mem.eql(u8, name, k)) return semi + 1;
    return error.BadEntity;
}

/// Check that `svg` is a well-formed XML document with a single `<svg>` root.
pub fn check(svg: []const u8) WellformedError!void {
    var stack_buf: [64][]const u8 = undefined; // deepest pozeiden output is a few levels
    var depth: usize = 0;
    var roots: usize = 0;
    var i: usize = 0;

    while (i < svg.len) {
        const c = svg[i];
        if (c == '<') {
            const is_closing = i + 1 < svg.len and svg[i + 1] == '/';
            var j = i + (@as(usize, if (is_closing) 2 else 1));
            const name_start = j;
            while (j < svg.len and isNameChar(svg[j])) j += 1;
            if (j == name_start) return error.UnterminatedTag; // "<>" / "< " / "</>"
            const name = svg[name_start..j];

            if (is_closing) {
                // Closing tag: optional whitespace then '>'.
                while (j < svg.len and std.ascii.isWhitespace(svg[j])) j += 1;
                if (j >= svg.len or svg[j] != '>') return error.UnterminatedTag;
                if (depth == 0) return error.UnbalancedTag;
                depth -= 1;
                if (!std.mem.eql(u8, stack_buf[depth], name)) return error.MismatchedClosingTag;
                i = j + 1;
                continue;
            }

            // Opening tag: attributes until '>' or '/>'.
            var self_closing = false;
            while (true) {
                while (j < svg.len and std.ascii.isWhitespace(svg[j])) j += 1;
                if (j >= svg.len) return error.UnterminatedTag;
                if (svg[j] == '>') break;
                if (svg[j] == '/') {
                    if (j + 1 >= svg.len or svg[j + 1] != '>') return error.UnterminatedTag;
                    self_closing = true;
                    j += 1;
                    break;
                }
                // Attribute name.
                const attr_start = j;
                while (j < svg.len and isNameChar(svg[j])) j += 1;
                if (j == attr_start) return error.BadAttribute;
                if (j >= svg.len or svg[j] != '=') return error.BadAttribute;
                j += 1;
                if (j >= svg.len or svg[j] != '"') return error.BadAttribute;
                j += 1;
                // Quoted value: no raw '<'; '&' must be a valid entity.
                while (j < svg.len and svg[j] != '"') {
                    if (svg[j] == '<') return error.BadAttribute;
                    if (svg[j] == '&') {
                        j = try checkEntity(svg, j);
                        continue;
                    }
                    if (svg[j] < 0x20 and svg[j] != '\t' and svg[j] != '\n' and svg[j] != '\r')
                        return error.ControlByte;
                    j += 1;
                }
                if (j >= svg.len) return error.BadAttribute; // unterminated value
                j += 1;
            }
            if (depth == 0) {
                roots += 1;
                if (roots > 1) return error.MultipleRootElements;
                if (!std.mem.eql(u8, name, "svg")) return error.RootIsNotSvg;
            }
            if (!self_closing) {
                if (depth >= stack_buf.len) return error.UnbalancedTag;
                stack_buf[depth] = name;
                depth += 1;
            }
            i = j + 1;
            continue;
        }
        // Text content.
        if (c == '&') {
            i = try checkEntity(svg, i);
            continue;
        }
        if (c < 0x20 and c != '\t' and c != '\n' and c != '\r') return error.ControlByte;
        if (depth == 0 and roots > 0 and !std.ascii.isWhitespace(c)) return error.TrailingContent;
        if (depth == 0 and roots == 0 and !std.ascii.isWhitespace(c)) return error.NoRootElement;
        i += 1;
    }

    if (depth != 0) return error.UnbalancedTag;
    if (roots == 0) return error.NoRootElement;
}

// ── Tests: the checker itself, against hand-broken fragments ────────────────

const testing = std.testing;

test "wellformed: accepts a minimal valid svg" {
    try check("<svg xmlns=\"x\"><g><text>a &amp; b</text></g><path d=\"M 0 0\"/></svg>");
}

test "wellformed: accepts entities and numeric references" {
    try check("<svg a=\"&quot;q&#39;s&#x27;\">&lt;&gt;</svg>");
}

test "wellformed: rejects unbalanced tags" {
    try testing.expectError(error.UnbalancedTag, check("<svg><g></svg>"));
}

test "wellformed: rejects mismatched closing tag" {
    try testing.expectError(error.MismatchedClosingTag, check("<svg><g></p></svg>"));
}

test "wellformed: rejects unquoted attribute" {
    try testing.expectError(error.BadAttribute, check("<svg width=10></svg>"));
}

test "wellformed: rejects unterminated attribute value" {
    try testing.expectError(error.BadAttribute, check("<svg width=\"10></svg>"));
}

test "wellformed: rejects raw ampersand" {
    try testing.expectError(error.BadEntity, check("<svg>a & b</svg>"));
}

test "wellformed: rejects control byte in text" {
    try testing.expectError(error.ControlByte, check("<svg>a\x01b</svg>"));
}

test "wellformed: rejects multiple roots and non-svg root" {
    try testing.expectError(error.MultipleRootElements, check("<svg></svg><svg></svg>"));
    try testing.expectError(error.RootIsNotSvg, check("<html></html>"));
}

test "wellformed: rejects unterminated tag" {
    try testing.expectError(error.UnterminatedTag, check("<svg"));
}
