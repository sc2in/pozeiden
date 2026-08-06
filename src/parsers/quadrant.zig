//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
//! Hand-written quadrantChart parser (mermaid text → Value tree → SVG), moved
//! verbatim out of root.zig (#39). The public entry point is `render`.
const std = @import("std");

const parse_util = @import("../parse_util.zig");
const isSkippable = parse_util.isSkippable;
const splitFirst = parse_util.splitFirst;
const stripQuotes = parse_util.stripQuotes;
const Value = @import("../diagram/value.zig").Value;
const quadrant_renderer = @import("../renderers/quadrant.zig");

// ─── quadrantChart parser ─────────────────────────────────────────────────────

pub fn render(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var title: []const u8 = "";
    var x_left: []const u8 = "";
    var x_right: []const u8 = "";
    var y_bottom: []const u8 = "";
    var y_top: []const u8 = "";
    var q = [4][]const u8{ "", "", "", "" };
    var points: std.ArrayList(Value) = .empty;

    var lines = parse_util.LineIter.init(text);
    var first = true;
    while (lines.next()) |line| {
        if (first) {
            first = false;
            continue;
        }

        if (std.mem.startsWith(u8, line, "title ") or std.mem.startsWith(u8, line, "title\t")) {
            title = std.mem.trim(u8, line[6..], " \t");
            continue;
        }

        if (std.mem.startsWith(u8, line, "x-axis ") or std.mem.startsWith(u8, line, "x-axis\t")) {
            const rest = std.mem.trim(u8, line[7..], " \t");
            if (std.mem.indexOf(u8, rest, " --> ")) |arrow| {
                x_left = std.mem.trim(u8, rest[0..arrow], " \t");
                x_right = std.mem.trim(u8, rest[arrow + 5 ..], " \t");
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "y-axis ") or std.mem.startsWith(u8, line, "y-axis\t")) {
            const rest = std.mem.trim(u8, line[7..], " \t");
            if (std.mem.indexOf(u8, rest, " --> ")) |arrow| {
                y_bottom = std.mem.trim(u8, rest[0..arrow], " \t");
                y_top = std.mem.trim(u8, rest[arrow + 5 ..], " \t");
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "quadrant-")) {
            const num_char = if (line.len > 9) line[9] else '0';
            const num = num_char - '0';
            if (num >= 1 and num <= 4) {
                q[num - 1] = std.mem.trim(u8, line[10..], " \t");
            }
            continue;
        }

        // Point: "Label: [x, y]"
        if (std.mem.indexOf(u8, line, ": [")) |colon_bracket| {
            const lbl = std.mem.trim(u8, line[0..colon_bracket], " \t");
            const bracket_start = colon_bracket + 2;
            const bracket_end = std.mem.indexOf(u8, line[bracket_start..], "]") orelse continue;
            var coord_iter = std.mem.splitScalar(u8, line[bracket_start + 1 .. bracket_start + bracket_end], ',');
            const xv = std.fmt.parseFloat(f64, std.mem.trim(u8, coord_iter.next() orelse "0", " \t")) catch 0.5;
            const yv = std.fmt.parseFloat(f64, std.mem.trim(u8, coord_iter.next() orelse "0", " \t")) catch 0.5;
            var pn = Value.Node{ .type_name = "point", .fields = .{} };
            try pn.fields.put(a, "label", Value{ .string = lbl });
            try pn.fields.put(a, "x", Value{ .number = xv });
            try pn.fields.put(a, "y", Value{ .number = yv });
            try points.append(a, Value{ .node = pn });
            continue;
        }
    }

    var root = Value.Node{ .type_name = "quadrantChart", .fields = .{} };
    try root.fields.put(a, "title", Value{ .string = title });
    try root.fields.put(a, "x_left", Value{ .string = x_left });
    try root.fields.put(a, "x_right", Value{ .string = x_right });
    try root.fields.put(a, "y_bottom", Value{ .string = y_bottom });
    try root.fields.put(a, "y_top", Value{ .string = y_top });
    try root.fields.put(a, "q1", Value{ .string = q[0] });
    try root.fields.put(a, "q2", Value{ .string = q[1] });
    try root.fields.put(a, "q3", Value{ .string = q[2] });
    try root.fields.put(a, "q4", Value{ .string = q[3] });
    try root.fields.put(a, "points", Value{ .list = try points.toOwnedSlice(a) });
    return quadrant_renderer.render(allocator, Value{ .node = root });
}

