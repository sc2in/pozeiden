//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
//! Hand-written kanban parser (mermaid text → Value tree → SVG), moved
//! verbatim out of root.zig (#39). The public entry point is `render`.
const std = @import("std");

const parse_util = @import("../parse_util.zig");
const isSkippable = parse_util.isSkippable;
const splitFirst = parse_util.splitFirst;
const stripQuotes = parse_util.stripQuotes;
const Value = @import("../diagram/value.zig").Value;
const kanban_renderer = @import("../renderers/kanban.zig");

// ─── kanban parser ────────────────────────────────────────────────────────────

pub fn render(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var columns: std.ArrayList(Value) = .empty;
    var current_col_label: ?[]const u8 = null;
    var current_items: std.ArrayList(Value) = .empty;
    var title: []const u8 = "";

    const flushColumn = struct {
        fn run(cols: *std.ArrayList(Value), label: []const u8, items: *std.ArrayList(Value), alloc: std.mem.Allocator) !void {
            var cn = Value.Node{ .type_name = "column", .fields = .{} };
            try cn.fields.put(alloc, "label", Value{ .string = label });
            try cn.fields.put(alloc, "items", Value{ .list = try items.toOwnedSlice(alloc) });
            try cols.append(alloc, Value{ .node = cn });
        }
    }.run;

    // First pass: detect column-header indent level (minimum indent of content
    // lines after the first line, ignoring blank/comment lines and the "title"
    // directive).
    var col_indent: usize = std.math.maxInt(usize);
    {
        var scan = std.mem.splitScalar(u8, text, '\n');
        var skip_first = true;
        while (scan.next()) |raw| {
            if (skip_first) {
                skip_first = false;
                continue;
            }
            const line = std.mem.trim(u8, raw, " \t\r");
            if (isSkippable(line)) continue;
            if (std.mem.startsWith(u8, line, "title ")) continue;
            // Count leading spaces/tabs
            var ind: usize = 0;
            for (raw) |c| {
                if (c == ' ') {
                    ind += 1;
                } else if (c == '\t') {
                    ind += 4;
                } else break;
            }
            if (ind < col_indent) col_indent = ind;
        }
        if (col_indent == std.math.maxInt(usize)) col_indent = 0;
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (isSkippable(line)) continue;
        if (first) {
            first = false;
            // "kanban" or "kanban title" on first line
            if (std.mem.indexOf(u8, line, " ")) |sp| {
                title = std.mem.trim(u8, line[sp..], " \t");
            }
            continue;
        }

        // Skip standalone "title" directive
        if (std.mem.startsWith(u8, line, "title ")) continue;

        // Measure this line's indentation
        var ind: usize = 0;
        for (raw) |c| {
            if (c == ' ') {
                ind += 1;
            } else if (c == '\t') {
                ind += 4;
            } else break;
        }

        if (ind <= col_indent) {
            // Column header
            if (current_col_label) |lbl| {
                try flushColumn(&columns, lbl, &current_items, a);
                current_items = .empty;
            }
            current_col_label = line;
        } else if (current_col_label != null) {
            // Item inside current column.
            // Strip trailing @{...} metadata — not rendered yet.
            var item_line = line;
            if (std.mem.indexOf(u8, item_line, "@{")) |at| {
                item_line = std.mem.trimEnd(u8, item_line[0..at], " \t");
            }
            // Syntax: id["label"] or "label" (bare string) or plain id
            var item_label = item_line;
            var item_id = item_line;
            if (std.mem.indexOf(u8, item_line, "[\"")) |lb| {
                item_id = item_line[0..lb];
                const rb = std.mem.indexOf(u8, item_line[lb..], "\"]") orelse (item_line.len - lb);
                item_label = item_line[lb + 2 .. @min(lb + rb, item_line.len)];
            } else if (item_line.len > 0 and item_line[0] == '"') {
                // Bare quoted string — use as label, generate id from position
                item_label = std.mem.trim(u8, item_line, "\"");
                item_id = item_label;
            }
            var iv = Value.Node{ .type_name = "item", .fields = .{} };
            try iv.fields.put(a, "id", Value{ .string = item_id });
            try iv.fields.put(a, "label", Value{ .string = item_label });
            try current_items.append(a, Value{ .node = iv });
        }
    }
    if (current_col_label) |lbl| {
        try flushColumn(&columns, lbl, &current_items, a);
    }

    if (columns.items.len == 0) return kanban_renderer.render(allocator, Value{ .null = {} });

    var root = Value.Node{ .type_name = "kanban", .fields = .{} };
    try root.fields.put(a, "title", Value{ .string = title });
    try root.fields.put(a, "columns", Value{ .list = try columns.toOwnedSlice(a) });
    return kanban_renderer.render(allocator, Value{ .node = root });
}

