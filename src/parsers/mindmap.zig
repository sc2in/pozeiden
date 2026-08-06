//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
//! Hand-written mindmap parser (mermaid text → Value tree → SVG), moved
//! verbatim out of root.zig (#39). The public entry point is `render`.
const std = @import("std");

const parse_util = @import("../parse_util.zig");
const isSkippable = parse_util.isSkippable;
const splitFirst = parse_util.splitFirst;
const stripQuotes = parse_util.stripQuotes;
const Value = @import("../diagram/value.zig").Value;
const mindmap_renderer = @import("../renderers/mindmap.zig");

// ─── mindmap parser ───────────────────────────────────────────────────────────

pub fn render(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const MmItem = struct { indent: usize, label: []const u8, shape: []const u8 };
    var flat: std.ArrayList(MmItem) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const trimmed_right = std.mem.trimEnd(u8, raw, " \t\r");
        if (trimmed_right.len == 0 or
            std.mem.startsWith(u8, std.mem.trim(u8, trimmed_right, " \t"), "%%")) continue;
        if (first) {
            first = false;
            continue;
        }

        var indent: usize = 0;
        for (trimmed_right) |ch| {
            if (ch == ' ') {
                indent += 1;
            } else if (ch == '\t') {
                indent += 2;
            } else break;
        }
        const content = std.mem.trim(u8, trimmed_right, " \t");
        if (content.len == 0) continue;
        // Skip ::icon() and ::class() directives — decorators, not nodes
        if (std.mem.startsWith(u8, content, "::")) continue;

        var label: []const u8 = content;
        var shape: []const u8 = "ellipse";
        // Strip optional leading word identifier (e.g. "root" in "root((label))")
        var id_end: usize = 0;
        for (content) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '_') id_end += 1 else break;
        }
        const sc = if (id_end > 0 and id_end < content.len and
            (content[id_end] == '(' or content[id_end] == '[' or content[id_end] == '{'))
            content[id_end..]
        else
            content;
        if (std.mem.startsWith(u8, sc, "((") and std.mem.endsWith(u8, sc, "))")) {
            label = sc[2 .. sc.len - 2];
            shape = "circle";
        } else if (std.mem.startsWith(u8, sc, "{{") and std.mem.endsWith(u8, sc, "}}")) {
            label = sc[2 .. sc.len - 2];
            shape = "hexagon";
        } else if (std.mem.startsWith(u8, sc, "))") and std.mem.endsWith(u8, sc, "((")) {
            // Bang/starburst: ))label((
            label = sc[2 .. sc.len - 2];
            shape = "bang";
        } else if (std.mem.startsWith(u8, sc, ")") and std.mem.endsWith(u8, sc, "(")) {
            // Cloud: )label(
            label = sc[1 .. sc.len - 1];
            shape = "cloud";
        } else if (std.mem.startsWith(u8, sc, "[") and std.mem.endsWith(u8, sc, "]")) {
            label = sc[1 .. sc.len - 1];
            shape = "rect";
        } else if (std.mem.startsWith(u8, sc, "(") and std.mem.endsWith(u8, sc, ")")) {
            label = sc[1 .. sc.len - 1];
            shape = "rounded";
        }
        // Replace literal \n escape with an actual newline for multi-line rendering
        const label_clean = try std.mem.replaceOwned(u8, a, label, "\\n", "\n");
        try flat.append(a, .{ .indent = indent, .label = label_clean, .shape = shape });
    }

    if (flat.items.len == 0) return mindmap_renderer.render(allocator, Value{ .null = {} });

    // Build Value tree bottom-up using a value stack.
    // Process items in reverse: each node collects children with indent > own indent.
    const VEntry = struct { indent: usize, value: Value };
    var value_stack: std.ArrayList(VEntry) = .empty;

    var i: usize = flat.items.len;
    while (i > 0) {
        i -= 1;
        const item = flat.items[i];
        // Pop children: entries with strictly greater indent
        var children: std.ArrayList(Value) = .empty;
        while (value_stack.items.len > 0 and
            value_stack.items[value_stack.items.len - 1].indent > item.indent)
        {
            const child = value_stack.pop().?;
            try children.append(a, child.value);
        }
        // Children were collected in reverse; reverse to restore order
        std.mem.reverse(Value, children.items);

        var n = Value.Node{ .type_name = "mmnode", .fields = .{} };
        try n.fields.put(a, "label", Value{ .string = item.label });
        try n.fields.put(a, "shape", Value{ .string = item.shape });
        try n.fields.put(a, "children", Value{ .list = try children.toOwnedSlice(a) });
        try value_stack.append(a, .{ .indent = item.indent, .value = Value{ .node = n } });
    }

    const root_value = if (value_stack.items.len > 0)
        value_stack.items[value_stack.items.len - 1].value
    else
        Value{ .null = {} };

    var root_node = Value.Node{ .type_name = "mindmap", .fields = .{} };
    const nodes_list = try a.alloc(Value, 1);
    nodes_list[0] = root_value;
    try root_node.fields.put(a, "nodes", Value{ .list = nodes_list });
    return mindmap_renderer.render(allocator, Value{ .node = root_node });
}

