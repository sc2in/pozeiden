//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
//! Hand-written block-beta parser (mermaid text → Value tree → SVG), moved
//! verbatim out of root.zig (#39). The public entry point is `render`.
const std = @import("std");

const parse_util = @import("../parse_util.zig");
const isSkippable = parse_util.isSkippable;
const splitFirst = parse_util.splitFirst;
const stripQuotes = parse_util.stripQuotes;
const Value = @import("../diagram/value.zig").Value;
const block_renderer = @import("../renderers/block.zig");

// ─── block-beta parser ────────────────────────────────────────────────────────

pub fn render(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var blocks_list: std.ArrayList(Value) = .empty;
    var edges_list: std.ArrayList(Value) = .empty;
    var n_cols: f64 = 3.0;
    var seen_ids = std.StringHashMap(void).init(a);
    var space_counter: usize = 0;

    var lines = parse_util.LineIter.init(text);
    var first = true;
    while (lines.next()) |line| {
        if (first) {
            first = false;
            continue;
        } // skip "block-beta"

        // columns N
        if (std.mem.startsWith(u8, line, "columns ")) {
            n_cols = std.fmt.parseFloat(f64, std.mem.trim(u8, line[8..], " \t")) catch 3.0;
            continue;
        }

        // Edge: "id --> id" or "id --> id : label"
        if (std.mem.indexOf(u8, line, "-->")) |arrow_pos| {
            const from_raw = std.mem.trim(u8, line[0..arrow_pos], " \t");
            const after = std.mem.trim(u8, line[arrow_pos + 3 ..], " \t");
            const colon = std.mem.indexOf(u8, after, ":") orelse after.len;
            const to_raw = std.mem.trim(u8, after[0..colon], " \t");
            const lbl = if (colon < after.len) std.mem.trim(u8, after[colon + 1 ..], " \t") else "";
            // Auto-register bare ids as blocks
            for (&[_][]const u8{ from_raw, to_raw }) |bid| {
                if (bid.len > 0 and seen_ids.get(bid) == null) {
                    try seen_ids.put(bid, {});
                    var bn = Value.Node{ .type_name = "block", .fields = .{} };
                    try bn.fields.put(a, "id", Value{ .string = bid });
                    try bn.fields.put(a, "label", Value{ .string = bid });
                    try blocks_list.append(a, Value{ .node = bn });
                }
            }
            var en = Value.Node{ .type_name = "edge", .fields = .{} };
            try en.fields.put(a, "from", Value{ .string = from_raw });
            try en.fields.put(a, "to", Value{ .string = to_raw });
            if (lbl.len > 0) try en.fields.put(a, "label", Value{ .string = lbl });
            try edges_list.append(a, Value{ .node = en });
            continue;
        }

        // Block definition: id or id["label"] or id["label"]:N (width)
        // Multiple blocks per line; respect quoted labels with spaces.
        var pos: usize = 0;
        while (pos < line.len) {
            // Skip leading whitespace
            while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
            if (pos >= line.len) break;
            // Read id: up to '[' or space
            const id_start = pos;
            while (pos < line.len and line[pos] != '[' and line[pos] != ' ' and line[pos] != '\t') pos += 1;
            const raw_id = line[id_start..pos];
            if (raw_id.len == 0) {
                pos += 1;
                continue;
            }
            // Handle bare id:N width suffix (e.g. "space:2")
            var id = raw_id;
            var width_str: []const u8 = "";
            if (std.mem.indexOfScalar(u8, raw_id, ':')) |colon| {
                id = raw_id[0..colon];
                width_str = raw_id[colon + 1 ..];
            }
            // Check for ["label"] after id
            var lbl = id;
            if (pos < line.len and line[pos] == '[') {
                // Find matching ]
                const bracket_start = pos;
                pos += 1; // skip [
                // May have "label" inside
                if (pos < line.len and line[pos] == '"') {
                    pos += 1; // skip "
                    const lbl_start = pos;
                    while (pos < line.len and line[pos] != '"') pos += 1;
                    lbl = line[lbl_start..pos];
                    if (pos < line.len) pos += 1; // skip closing "
                }
                if (pos < line.len and line[pos] == ']') pos += 1; // skip ]
                _ = bracket_start;
                // Width: ]:N after the bracket
                if (pos < line.len and line[pos] == ':') {
                    pos += 1;
                    const w_start = pos;
                    while (pos < line.len and line[pos] != ' ' and line[pos] != '\t') pos += 1;
                    width_str = line[w_start..pos];
                }
            }
            const is_space = std.mem.eql(u8, id, "space");
            // Give each space block a unique synthetic id so multiple spaces
            // on the same line don't get deduped by seen_ids.
            const effective_id = if (is_space) blk: {
                space_counter += 1;
                break :blk try std.fmt.allocPrint(a, "__space{d}", .{space_counter});
            } else id;
            if (!is_space and seen_ids.get(id) != null) continue;
            if (!is_space) try seen_ids.put(id, {});
            const width = std.fmt.parseFloat(f64, width_str) catch 1.0;
            var bn = Value.Node{ .type_name = "block", .fields = .{} };
            try bn.fields.put(a, "id", Value{ .string = effective_id });
            try bn.fields.put(a, "label", Value{ .string = if (is_space) "" else lbl });
            try bn.fields.put(a, "width", Value{ .number = width });
            try bn.fields.put(a, "space", Value{ .number = if (is_space) 1.0 else 0.0 });
            try blocks_list.append(a, Value{ .node = bn });
        }
    }

    var root = Value.Node{ .type_name = "block-beta", .fields = .{} };
    try root.fields.put(a, "cols", Value{ .number = n_cols });
    try root.fields.put(a, "blocks", Value{ .list = try blocks_list.toOwnedSlice(a) });
    try root.fields.put(a, "edges", Value{ .list = try edges_list.toOwnedSlice(a) });
    return block_renderer.render(allocator, Value{ .node = root });
}

