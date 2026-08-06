//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
//! Hand-written classDiagram parser (mermaid text → Value tree → SVG), moved
//! verbatim out of root.zig (#39). The public entry point is `render`.
const std = @import("std");

const parse_util = @import("../parse_util.zig");
const isSkippable = parse_util.isSkippable;
const splitFirst = parse_util.splitFirst;
const stripQuotes = parse_util.stripQuotes;
const Value = @import("../diagram/value.zig").Value;
const class_renderer = @import("../renderers/class.zig");

// ─── classDiagram parser ──────────────────────────────────────────────────────

pub fn render(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // class_name → list of member strings
    var class_map: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    var relations: std.ArrayList(Value) = .empty;

    // Relationship patterns (order: longer first)
    const RelPat = struct { []const u8, []const u8 };
    const rel_patterns = [_]RelPat{
        .{ "<|--", "inheritance" }, .{ "--|>", "inheritance" },
        .{ "*--", "composition" },  .{ "--*", "composition" },
        .{ "o--", "aggregation" },  .{ "--o", "aggregation" },
        .{ "<..", "dependency" },   .{ "..>", "dependency" },
        .{ "<|..", "realization" }, .{ "..|>", "realization" },
        .{ "-->", "association" },  .{ "<--", "association" },
        .{ "..", "link_dashed" },   .{ "--", "link" },
    };

    var current_class: ?[]const u8 = null; // inside a `class X {` block
    var current_namespace: ?[]const u8 = null; // inside a `namespace Foo {` block
    var namespace_depth: usize = 0; // brace nesting inside namespace
    // namespace_name → list of class names
    var namespace_map: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    // class_name → namespace (for renderer lookup)
    var class_namespace = std.StringHashMap([]const u8).init(a);
    var class_notes: std.ArrayList(Value) = .empty;

    var lines = parse_util.LineIter.init(text);
    var first = true;
    while (lines.next()) |line| {
        if (first) {
            first = false;
            continue;
        } // skip "classDiagram"

        // namespace Foo { ... }
        if (std.mem.startsWith(u8, line, "namespace ") and std.mem.indexOf(u8, line, "{") != null) {
            const rest = std.mem.trim(u8, line[10..], " \t{");
            current_namespace = rest;
            namespace_depth = 1;
            const entry = try namespace_map.getOrPut(a, rest);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            continue;
        }

        // End of class or namespace block
        if (std.mem.eql(u8, line, "}")) {
            if (current_class != null) {
                current_class = null;
                continue;
            }
            if (current_namespace != null) {
                if (namespace_depth > 0) namespace_depth -= 1;
                if (namespace_depth == 0) current_namespace = null;
                continue;
            }
            continue;
        }

        // Start of class block: "class Foo {" or "class Foo <<interface>>"
        if (std.mem.startsWith(u8, line, "class ")) {
            const rest = std.mem.trim(u8, line[6..], " \t");
            const name_end = std.mem.indexOfAny(u8, rest, " {") orelse rest.len;
            const name = std.mem.trim(u8, rest[0..name_end], " \t");
            const entry = try class_map.getOrPut(a, name);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            // Inline stereotype: "class Foo <<interface>>" or "class Foo <<interface>> {"
            if (name_end < rest.len) {
                const after = std.mem.trim(u8, rest[name_end..], " \t{");
                if (std.mem.startsWith(u8, after, "<<") and std.mem.indexOf(u8, after, ">>") != null) {
                    const ste_end = (std.mem.indexOf(u8, after, ">>") orelse after.len - 2) + 2;
                    try entry.value_ptr.append(a, after[0..ste_end]);
                }
            }
            // Track namespace membership
            if (current_namespace) |ns| {
                if (!class_namespace.contains(name)) {
                    try class_namespace.put(name, ns);
                    const ns_entry = namespace_map.getPtr(ns) orelse continue;
                    try ns_entry.append(a, name);
                }
            }
            if (std.mem.indexOf(u8, line, "{") != null) {
                current_class = name;
            }
            continue;
        }

        // Member inside a block
        if (current_class) |cls| {
            const entry = class_map.getPtr(cls) orelse continue;
            try entry.append(a, line);
            continue;
        }

        // ClassName : member (outside block)
        if (std.mem.indexOf(u8, line, " : ")) |colon_pos| {
            const lhs = std.mem.trim(u8, line[0..colon_pos], " \t");
            const member = std.mem.trim(u8, line[colon_pos + 3 ..], " \t");
            // Only treat as member if lhs has no relationship chars
            if (std.mem.indexOf(u8, lhs, "<") == null and
                std.mem.indexOf(u8, lhs, ">") == null and
                std.mem.indexOf(u8, lhs, "*") == null and
                std.mem.indexOf(u8, lhs, "o") == null and
                std.mem.indexOfScalar(u8, lhs, '.') == null)
            {
                const entry = class_map.getPtr(lhs) orelse blk: {
                    try class_map.put(a, lhs, .empty);
                    break :blk class_map.getPtr(lhs).?;
                };
                try entry.append(a, member);
                continue;
            }
        }

        // note "text" or note for ClassName "text"
        if (std.mem.startsWith(u8, line, "note ")) {
            const rest = std.mem.trim(u8, line[5..], " \t");
            var target: []const u8 = "";
            var note_text: []const u8 = "";
            if (std.mem.startsWith(u8, rest, "for ")) {
                const after_for = std.mem.trim(u8, rest[4..], " \t");
                const sp = std.mem.indexOfScalar(u8, after_for, ' ') orelse after_for.len;
                target = after_for[0..sp];
                const txt_rest = std.mem.trim(u8, after_for[sp..], " \t\"");
                note_text = txt_rest;
            } else {
                // note "text"
                const q1 = std.mem.indexOfScalar(u8, rest, '"') orelse rest.len;
                const q2 = if (q1 < rest.len) (std.mem.indexOfScalar(u8, rest[q1 + 1 ..], '"') orelse (rest.len - q1 - 1)) + q1 + 1 else rest.len;
                note_text = if (q1 < rest.len) rest[q1 + 1 .. @min(q2, rest.len)] else rest;
            }
            var nn = Value.Node{ .type_name = "note", .fields = .{} };
            try nn.fields.put(a, "text", Value{ .string = note_text });
            try nn.fields.put(a, "target", Value{ .string = target });
            try class_notes.append(a, Value{ .node = nn });
            continue;
        }

        // Relationship line: detect pattern
        for (rel_patterns) |rp| {
            if (std.mem.indexOf(u8, line, rp[0])) |pat_pos| {
                const left = std.mem.trim(u8, line[0..pat_pos], " \t");
                const after = std.mem.trim(u8, line[pat_pos + rp[0].len ..], " \t");
                // Extract `to` and optional label after ` : `
                const right_end = std.mem.indexOf(u8, after, " : ") orelse after.len;
                const right = std.mem.trim(u8, after[0..right_end], " \t");
                const label = if (right_end < after.len)
                    std.mem.trim(u8, after[right_end + 3 ..], " \t")
                else
                    "";

                // Determine from/to based on arrow direction
                const from, const to = if (std.mem.startsWith(u8, rp[0], "<"))
                    .{ right, left }
                else
                    .{ left, right };

                if (!class_map.contains(from)) try class_map.put(a, from, .empty);
                if (!class_map.contains(to)) try class_map.put(a, to, .empty);

                var rn = Value.Node{ .type_name = "relation", .fields = .{} };
                try rn.fields.put(a, "from", Value{ .string = from });
                try rn.fields.put(a, "to", Value{ .string = to });
                try rn.fields.put(a, "kind", Value{ .string = rp[1] });
                try rn.fields.put(a, "label", Value{ .string = label });
                try relations.append(a, Value{ .node = rn });
                break;
            }
        }
    }

    // Build class Value list
    var class_list: std.ArrayList(Value) = .empty;
    var it = class_map.iterator();
    while (it.next()) |entry| {
        var members_list: std.ArrayList(Value) = .empty;
        for (entry.value_ptr.items) |m| {
            try members_list.append(a, Value{ .string = m });
        }
        var cn = Value.Node{ .type_name = "class", .fields = .{} };
        try cn.fields.put(a, "name", Value{ .string = entry.key_ptr.* });
        try cn.fields.put(a, "members", Value{ .list = try members_list.toOwnedSlice(a) });
        if (class_namespace.get(entry.key_ptr.*)) |ns|
            try cn.fields.put(a, "namespace", Value{ .string = ns });
        try class_list.append(a, Value{ .node = cn });
    }

    // Build namespace boundary list
    var ns_list: std.ArrayList(Value) = .empty;
    var ns_it = namespace_map.iterator();
    while (ns_it.next()) |entry| {
        var member_vals: std.ArrayList(Value) = .empty;
        for (entry.value_ptr.items) |m| try member_vals.append(a, Value{ .string = m });
        var nsn = Value.Node{ .type_name = "namespace", .fields = .{} };
        try nsn.fields.put(a, "name", Value{ .string = entry.key_ptr.* });
        try nsn.fields.put(a, "members", Value{ .list = try member_vals.toOwnedSlice(a) });
        try ns_list.append(a, Value{ .node = nsn });
    }

    var root = Value.Node{ .type_name = "classDiagram", .fields = .{} };
    try root.fields.put(a, "classes", Value{ .list = try class_list.toOwnedSlice(a) });
    try root.fields.put(a, "relations", Value{ .list = try relations.toOwnedSlice(a) });
    try root.fields.put(a, "namespaces", Value{ .list = try ns_list.toOwnedSlice(a) });
    try root.fields.put(a, "notes", Value{ .list = try class_notes.toOwnedSlice(a) });
    return class_renderer.render(allocator, Value{ .node = root });
}

