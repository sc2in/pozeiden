//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
//! Hand-written erDiagram parser (mermaid text → Value tree → SVG), moved
//! verbatim out of root.zig (#39). The public entry point is `render`.
const std = @import("std");

const parse_util = @import("../parse_util.zig");
const isSkippable = parse_util.isSkippable;
const splitFirst = parse_util.splitFirst;
const stripQuotes = parse_util.stripQuotes;
const Value = @import("../diagram/value.zig").Value;
const er_renderer = @import("../renderers/er.zig");

// ─── erDiagram parser ─────────────────────────────────────────────────────────

pub fn render(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // entity_name → list of attr nodes
    var entity_map: std.StringArrayHashMapUnmanaged(std.ArrayList(Value)) = .empty;
    var relations: std.ArrayList(Value) = .empty;

    var current_entity: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (isSkippable(line)) continue;
        if (first) {
            first = false;
            continue;
        }

        if (std.mem.eql(u8, line, "}")) {
            current_entity = null;
            continue;
        }

        // Entity block start: "ENTITY {" or "ENTITY{"
        if (std.mem.indexOf(u8, line, "{") != null and
            std.mem.indexOf(u8, line, "--") == null and
            std.mem.indexOf(u8, line, "..") == null)
        {
            const name = std.mem.trim(u8, line[0..std.mem.indexOfScalar(u8, line, '{').?], " \t");
            if (name.len > 0) {
                if (!entity_map.contains(name)) try entity_map.put(a, name, .empty);
                current_entity = name;
            }
            continue;
        }

        // Attribute inside entity block: "type name" or "type name PK"
        if (current_entity) |ent| {
            const parts = splitFirst(line, ' ');
            if (parts[0].len > 0 and parts[1].len > 0) {
                const entry = entity_map.getPtr(ent) orelse continue;
                const attr_name_raw = parts[1];
                const is_key = std.mem.indexOf(u8, attr_name_raw, "PK") != null or
                    std.mem.indexOf(u8, attr_name_raw, "FK") != null;
                const attr_name = blk: {
                    var n = attr_name_raw;
                    if (std.mem.indexOf(u8, n, " ")) |sp| n = n[0..sp];
                    break :blk n;
                };
                var an = Value.Node{ .type_name = "attr", .fields = .{} };
                try an.fields.put(a, "type", Value{ .string = parts[0] });
                try an.fields.put(a, "name", Value{ .string = attr_name });
                if (is_key) try an.fields.put(a, "key", Value{ .string = "true" });
                try entry.append(a, Value{ .node = an });
            }
            continue;
        }

        // Relationship: ENTITY_A rel ENTITY_B : "label"
        // rel pattern contains -- or ..
        if (std.mem.indexOf(u8, line, "--") orelse std.mem.indexOf(u8, line, "..")) |connector_pos| {
            // The full rel token includes cardinality chars before and after the connector.
            // Walk backward from connector_pos to find where the rel token starts (first space or start of line).
            var rel_token_start = connector_pos;
            while (rel_token_start > 0 and line[rel_token_start - 1] != ' ' and line[rel_token_start - 1] != '\t') {
                rel_token_start -= 1;
            }
            // Walk forward from connector_pos to find where the rel token ends (next space).
            const after_connector = line[connector_pos..];
            var rel_token_len: usize = after_connector.len;
            for (after_connector, 0..) |c, i| {
                if (c == ' ') {
                    rel_token_len = i;
                    break;
                }
            }
            const rel_str = line[rel_token_start .. connector_pos + rel_token_len];
            const from = std.mem.trimEnd(u8, std.mem.trim(u8, line[0..rel_token_start], " \t"), "|o{}< \t");
            // Everything after the rel token
            const after_rel = line[connector_pos + rel_token_len ..];
            const rest = std.mem.trim(u8, after_rel, " \t");
            // rest: "ENTITY_B : label" or just "ENTITY_B"
            const colon = std.mem.indexOf(u8, rest, " : ") orelse rest.len;
            const to = std.mem.trim(u8, rest[0..colon], " \t");
            const label = if (colon < rest.len)
                std.mem.trim(u8, rest[colon + 3 ..], " \t\"")
            else
                "";

            if (from.len == 0 or to.len == 0) continue;
            if (!entity_map.contains(from)) try entity_map.put(a, from, .empty);
            if (!entity_map.contains(to)) try entity_map.put(a, to, .empty);

            var rn = Value.Node{ .type_name = "relation", .fields = .{} };
            try rn.fields.put(a, "from", Value{ .string = from });
            try rn.fields.put(a, "to", Value{ .string = to });
            try rn.fields.put(a, "rel", Value{ .string = rel_str });
            try rn.fields.put(a, "label", Value{ .string = label });
            try relations.append(a, Value{ .node = rn });
        }
    }

    var entity_list: std.ArrayList(Value) = .empty;
    var it = entity_map.iterator();
    while (it.next()) |entry| {
        var en = Value.Node{ .type_name = "entity", .fields = .{} };
        try en.fields.put(a, "name", Value{ .string = entry.key_ptr.* });
        try en.fields.put(a, "attrs", Value{ .list = try entry.value_ptr.toOwnedSlice(a) });
        try entity_list.append(a, Value{ .node = en });
    }

    var root = Value.Node{ .type_name = "erDiagram", .fields = .{} };
    try root.fields.put(a, "entities", Value{ .list = try entity_list.toOwnedSlice(a) });
    try root.fields.put(a, "relations", Value{ .list = try relations.toOwnedSlice(a) });
    return er_renderer.render(allocator, Value{ .node = root });
}

