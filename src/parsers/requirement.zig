//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
//! Hand-written requirementDiagram parser (mermaid text → Value tree → SVG), moved
//! verbatim out of root.zig (#39). The public entry point is `render`.
const std = @import("std");

const parse_util = @import("../parse_util.zig");
const isSkippable = parse_util.isSkippable;
const splitFirst = parse_util.splitFirst;
const stripQuotes = parse_util.stripQuotes;
const Value = @import("../diagram/value.zig").Value;
const requirement_renderer = @import("../renderers/requirement.zig");

// ─── requirementDiagram parser ───────────────────────────────────────────────

pub fn render(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var requirements: std.ArrayList(Value) = .empty;
    var elements: std.ArrayList(Value) = .empty;
    var relationships: std.ArrayList(Value) = .empty;

    var current_kind: []const u8 = ""; // "requirement" or "element"
    var current_node: ?Value.Node = null;

    var lines = parse_util.LineIter.init(text);
    var first = true;
    while (lines.next()) |line| {
        if (first) {
            first = false;
            continue;
        } // skip "requirementDiagram"

        // End of block
        if (std.mem.eql(u8, line, "}")) {
            if (current_node) |n| {
                if (std.mem.eql(u8, current_kind, "requirement")) {
                    try requirements.append(a, Value{ .node = n });
                } else {
                    try elements.append(a, Value{ .node = n });
                }
                current_node = null;
                current_kind = "";
            }
            continue;
        }

        // Block start: "requirement name {" or "element name {"
        if (std.mem.startsWith(u8, line, "requirement ") or
            std.mem.startsWith(u8, line, "functionalRequirement ") or
            std.mem.startsWith(u8, line, "performanceRequirement ") or
            std.mem.startsWith(u8, line, "interfaceRequirement ") or
            std.mem.startsWith(u8, line, "physicalRequirement ") or
            std.mem.startsWith(u8, line, "designConstraint "))
        {
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
            const rest = std.mem.trim(u8, line[sp..], " \t{");
            current_kind = "requirement";
            current_node = Value.Node{ .type_name = "requirement", .fields = .{} };
            try current_node.?.fields.put(a, "name", Value{ .string = rest });
            continue;
        }
        if (std.mem.startsWith(u8, line, "element ")) {
            const rest = std.mem.trim(u8, line[8..], " \t{");
            current_kind = "element";
            current_node = Value.Node{ .type_name = "element", .fields = .{} };
            try current_node.?.fields.put(a, "name", Value{ .string = rest });
            continue;
        }

        // Attribute inside block: "key: value"
        if (current_node != null) {
            if (std.mem.indexOf(u8, line, ":")) |ci| {
                const key = std.mem.trim(u8, line[0..ci], " \t");
                const val = std.mem.trim(u8, line[ci + 1 ..], " \t\"");
                try current_node.?.fields.put(a, key, Value{ .string = val });
            }
            continue;
        }

        // Relationship: "A - kind -> B" or "A - kind - B"
        if (std.mem.indexOf(u8, line, " - ")) |d1| {
            const from = std.mem.trim(u8, line[0..d1], " \t");
            const rest = line[d1 + 3 ..];
            const d2 = std.mem.indexOf(u8, rest, " - ") orelse std.mem.indexOf(u8, rest, " -> ") orelse rest.len;
            if (d2 < rest.len) {
                const kind = std.mem.trim(u8, rest[0..d2], " \t");
                const arrow_len: usize = if (std.mem.startsWith(u8, rest[d2..], " -> ")) 4 else 3;
                const to = std.mem.trim(u8, rest[d2 + arrow_len ..], " \t");
                var rn = Value.Node{ .type_name = "relationship", .fields = .{} };
                try rn.fields.put(a, "from", Value{ .string = from });
                try rn.fields.put(a, "to", Value{ .string = to });
                try rn.fields.put(a, "kind", Value{ .string = kind });
                try relationships.append(a, Value{ .node = rn });
            }
        }
    }

    var root = Value.Node{ .type_name = "requirementDiagram", .fields = .{} };
    try root.fields.put(a, "requirements", Value{ .list = try requirements.toOwnedSlice(a) });
    try root.fields.put(a, "elements", Value{ .list = try elements.toOwnedSlice(a) });
    try root.fields.put(a, "relationships", Value{ .list = try relationships.toOwnedSlice(a) });
    return requirement_renderer.render(allocator, Value{ .node = root });
}

