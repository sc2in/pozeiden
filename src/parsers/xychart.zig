//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
//! Hand-written xychart-beta parser (mermaid text → Value tree → SVG), moved
//! verbatim out of root.zig (#39). The public entry point is `render`.
const std = @import("std");

const parse_util = @import("../parse_util.zig");
const isSkippable = parse_util.isSkippable;
const splitFirst = parse_util.splitFirst;
const stripQuotes = parse_util.stripQuotes;
const Value = @import("../diagram/value.zig").Value;
const xychart_renderer = @import("../renderers/xychart.zig");

// ─── xychart parser ───────────────────────────────────────────────────────────

pub fn render(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var title: []const u8 = "";
    var y_min: f64 = 0;
    var y_max: f64 = 100;
    var x_labels: std.ArrayList(Value) = .empty;
    var series: std.ArrayList(Value) = .empty;

    var lines = parse_util.LineIter.init(text);
    var first = true;
    while (lines.next()) |line| {
        if (first) {
            first = false;
            continue;
        }

        if (std.mem.startsWith(u8, line, "title ") or std.mem.startsWith(u8, line, "title\t")) {
            title = std.mem.trim(u8, line[6..], " \t\"");
            continue;
        }

        if (std.mem.startsWith(u8, line, "x-axis ") or std.mem.startsWith(u8, line, "x-axis\t")) {
            const rest = std.mem.trim(u8, line[7..], " \t");
            // Extract bracket content [a, b, c]
            if (std.mem.indexOf(u8, rest, "[")) |lb| {
                const rb = std.mem.lastIndexOf(u8, rest, "]") orelse rest.len;
                var iter = std.mem.splitScalar(u8, rest[lb + 1 .. rb], ',');
                while (iter.next()) |tok| {
                    var t = std.mem.trim(u8, tok, " \t");
                    // Strip surrounding quotes if present
                    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0])
                        t = t[1 .. t.len - 1];
                    if (t.len > 0) try x_labels.append(a, Value{ .string = t });
                }
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "y-axis ") or std.mem.startsWith(u8, line, "y-axis\t")) {
            const rest = std.mem.trim(u8, line[7..], " \t");
            // Find --> separator for range
            if (std.mem.indexOf(u8, rest, "-->")) |arrow| {
                const rhs = std.mem.trim(u8, rest[arrow + 3 ..], " \t");
                y_max = std.fmt.parseFloat(f64, rhs) catch 100;
                // Left of --> may be: "label" min or just min
                var lhs = std.mem.trim(u8, rest[0..arrow], " \t");
                if (lhs.len > 0 and lhs[0] == '"') {
                    // Strip quoted label
                    const qend = std.mem.indexOf(u8, lhs[1..], "\"") orelse lhs.len - 1;
                    lhs = std.mem.trim(u8, lhs[qend + 2 ..], " \t");
                }
                y_min = std.fmt.parseFloat(f64, lhs) catch 0;
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "bar ") or std.mem.startsWith(u8, line, "bar\t") or
            std.mem.startsWith(u8, line, "line ") or std.mem.startsWith(u8, line, "line\t"))
        {
            const is_line = std.mem.startsWith(u8, line, "line");
            const kind: []const u8 = if (is_line) "line" else "bar";
            const rest = std.mem.trim(u8, line[if (is_line) 5 else 4..], " \t");
            var vals: std.ArrayList(Value) = .empty;
            if (std.mem.indexOf(u8, rest, "[")) |lb| {
                const rb = std.mem.lastIndexOf(u8, rest, "]") orelse rest.len;
                var iter = std.mem.splitScalar(u8, rest[lb + 1 .. rb], ',');
                while (iter.next()) |tok| {
                    const t = std.mem.trim(u8, tok, " \t");
                    const v = std.fmt.parseFloat(f64, t) catch continue;
                    try vals.append(a, Value{ .number = v });
                }
            }
            if (vals.items.len > 0) {
                var sn = Value.Node{ .type_name = "series", .fields = .{} };
                try sn.fields.put(a, "kind", Value{ .string = kind });
                try sn.fields.put(a, "values", Value{ .list = try vals.toOwnedSlice(a) });
                try series.append(a, Value{ .node = sn });
            }
            continue;
        }
    }

    var root = Value.Node{ .type_name = "xychart", .fields = .{} };
    try root.fields.put(a, "title", Value{ .string = title });
    try root.fields.put(a, "y_min", Value{ .number = y_min });
    try root.fields.put(a, "y_max", Value{ .number = y_max });
    try root.fields.put(a, "x_labels", Value{ .list = try x_labels.toOwnedSlice(a) });
    try root.fields.put(a, "series", Value{ .list = try series.toOwnedSlice(a) });
    return xychart_renderer.render(allocator, Value{ .node = root });
}

