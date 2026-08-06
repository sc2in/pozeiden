//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
//! Hand-written stateDiagram parser (mermaid text → Value tree → SVG), moved
//! verbatim out of root.zig (#39). The public entry point is `render`.
const std = @import("std");

const parse_util = @import("../parse_util.zig");
const isSkippable = parse_util.isSkippable;
const splitFirst = parse_util.splitFirst;
const stripQuotes = parse_util.stripQuotes;
const Value = @import("../diagram/value.zig").Value;
const state_renderer = @import("../renderers/state.zig");

// ─── stateDiagram parser ──────────────────────────────────────────────────────

pub fn render(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var states: std.ArrayList(Value) = .empty;
    var transitions: std.ArrayList(Value) = .empty;
    var notes_list: std.ArrayList(Value) = .empty;
    var seen = std.StringHashMap(void).init(a);

    // CompoundInfo tracks per-compound membership, split by concurrent region.
    // `regions` is a list of member-id lists, one per region separated by `--`.
    const CompoundInfo = struct {
        id: []const u8,
        regions: std.ArrayList(std.ArrayList([]const u8)) = .empty,

        fn currentRegion(self: *@This()) *std.ArrayList([]const u8) {
            return &self.regions.items[self.regions.items.len - 1];
        }
        fn addMember(self: *@This(), alloc: std.mem.Allocator, id: []const u8) !void {
            const region = self.currentRegion();
            for (region.items) |m| if (std.mem.eql(u8, m, id)) return;
            try region.append(alloc, id);
        }
    };
    var compound_stack: std.ArrayList(CompoundInfo) = .empty;
    var compounds_list: std.ArrayList(Value) = .empty;

    const addState = struct {
        fn run(sl: *std.ArrayList(Value), s: *std.StringHashMap(void), alloc: std.mem.Allocator, id: []const u8, lbl: []const u8, shp: []const u8) !void {
            if (s.get(id) != null) return;
            try s.put(id, {});
            var sn = Value.Node{ .type_name = "state", .fields = .{} };
            try sn.fields.put(alloc, "id", Value{ .string = id });
            try sn.fields.put(alloc, "label", Value{ .string = lbl });
            if (shp.len > 0) try sn.fields.put(alloc, "shape", Value{ .string = shp });
            try sl.append(alloc, Value{ .node = sn });
        }
    }.run;

    var lines = parse_util.LineIter.init(text);
    var first = true;
    while (lines.next()) |line| {
        if (first) {
            first = false;
            continue;
        } // skip header

        // `state "long name" as id` or `state id {` (compound)
        // Also handles: `state id <<fork>>` / `<<join>>` / `<<choice>>`
        if (std.mem.startsWith(u8, line, "state ")) {
            const rest = line[6..];
            // Check for stereotype: state id <<fork>> etc.
            if (std.mem.indexOf(u8, rest, "<<")) |ss| {
                const id = std.mem.trim(u8, rest[0..ss], " \t");
                const ste_start = ss + 2;
                const ste_end = std.mem.indexOf(u8, rest[ste_start..], ">>") orelse (rest.len - ste_start);
                const ste = rest[ste_start .. ste_start + ste_end];
                if (id.len > 0) {
                    if (seen.get(id) == null) {
                        try seen.put(id, {});
                        var sn = Value.Node{ .type_name = "state", .fields = .{} };
                        try sn.fields.put(a, "id", Value{ .string = id });
                        try sn.fields.put(a, "label", Value{ .string = id });
                        try sn.fields.put(a, "shape", Value{ .string = ste });
                        try states.append(a, Value{ .node = sn });
                    }
                }
            } else if (std.mem.indexOf(u8, rest, " as ")) |ai| {
                const lbl_raw = std.mem.trim(u8, rest[0..ai], " \t\"");
                const id = std.mem.trim(u8, rest[ai + 4 ..], " \t{");
                if (id.len > 0) try addState(&states, &seen, a, id, lbl_raw, "");
            } else {
                // "state id" or "state id {": register with id as label
                const id = std.mem.trim(u8, rest, " \t{\"");
                const is_compound_opener = id.len > 0 and std.mem.indexOf(u8, rest, "{") != null;
                // Compound headers get shape "compound" so the renderer knows not to draw them as rects
                if (id.len > 0) try addState(&states, &seen, a, id, id, if (is_compound_opener) "compound" else "");
                // Compound opener: push a new compound entry
                if (is_compound_opener) {
                    if (compound_stack.items.len > 0) {
                        // Register this compound as a member of its parent compound
                        try compound_stack.items[compound_stack.items.len - 1].addMember(a, id);
                    }
                    var ci = CompoundInfo{ .id = try a.dupe(u8, id) };
                    // Start with one empty region
                    const first_region: std.ArrayList([]const u8) = .empty;
                    try ci.regions.append(a, first_region);
                    try compound_stack.append(a, ci);
                }
            }
            continue;
        }

        // Compound state close: pop compound stack and record it
        if (std.mem.eql(u8, line, "}")) {
            if (compound_stack.items.len > 0) {
                const ci = compound_stack.pop().?;
                var cn = Value.Node{ .type_name = "compound", .fields = .{} };
                try cn.fields.put(a, "id", Value{ .string = ci.id });
                // Emit `regions`: list of lists, one per concurrent region
                var regions_val: std.ArrayList(Value) = .empty;
                for (ci.regions.items) |region| {
                    var region_val: std.ArrayList(Value) = .empty;
                    for (region.items) |m| try region_val.append(a, Value{ .string = m });
                    try regions_val.append(a, Value{ .list = try region_val.toOwnedSlice(a) });
                }
                try cn.fields.put(a, "regions", Value{ .list = try regions_val.toOwnedSlice(a) });
                try compounds_list.append(a, Value{ .node = cn });
            }
            continue;
        }
        // Skip orphan `{` lines
        if (std.mem.indexOf(u8, line, "{") != null) continue;
        // Concurrent region separator (-- or ---): start a new region
        if (std.mem.eql(u8, line, "---") or std.mem.eql(u8, line, "--")) {
            if (compound_stack.items.len > 0) {
                const new_region: std.ArrayList([]const u8) = .empty;
                try compound_stack.items[compound_stack.items.len - 1].regions.append(a, new_region);
            }
            continue;
        }
        // note right of StateId: text  /  note left of StateId: text
        if (std.mem.startsWith(u8, line, "note ")) {
            const rest = line[5..];
            const colon = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
            const pos_part = std.mem.trim(u8, rest[0..colon], " \t");
            const note_text = if (colon < rest.len) std.mem.trim(u8, rest[colon + 1 ..], " \t") else "";
            var state_id: []const u8 = "";
            var position: []const u8 = "right";
            if (std.mem.startsWith(u8, pos_part, "right of ")) {
                state_id = std.mem.trim(u8, pos_part[9..], " \t");
            } else if (std.mem.startsWith(u8, pos_part, "left of ")) {
                state_id = std.mem.trim(u8, pos_part[8..], " \t");
                position = "left";
            }
            if (state_id.len > 0 and note_text.len > 0) {
                var nn = Value.Node{ .type_name = "note", .fields = .{} };
                try nn.fields.put(a, "state", Value{ .string = state_id });
                try nn.fields.put(a, "text", Value{ .string = note_text });
                try nn.fields.put(a, "position", Value{ .string = position });
                try notes_list.append(a, Value{ .node = nn });
            }
            continue;
        }

        // Transition: `A --> B` or `A --> B : label`
        if (std.mem.indexOf(u8, line, "-->")) |arrow_pos| {
            const from = std.mem.trim(u8, line[0..arrow_pos], " \t");
            const after = std.mem.trim(u8, line[arrow_pos + 3 ..], " \t");
            const colon = std.mem.indexOfScalar(u8, after, ':') orelse after.len;
            const to = std.mem.trim(u8, after[0..colon], " \t");
            const lbl = if (colon < after.len)
                std.mem.trim(u8, after[colon + 1 ..], " \t")
            else
                "";

            if (from.len == 0 or to.len == 0) continue;
            // Map pseudo-state identifiers to canonical IDs.
            // When inside a compound, scope [*] to avoid aliasing the global initial state.
            // [H] = shallow history; [H*] = deep history.
            const in_compound = compound_stack.items.len > 0;
            const comp_id_cur: []const u8 = if (in_compound)
                compound_stack.items[compound_stack.items.len - 1].id
            else "";

            const from_id: []const u8 = if (std.mem.eql(u8, from, "[*]")) blk: {
                if (in_compound)
                    break :blk try std.fmt.allocPrint(a, "{s}.[*]", .{comp_id_cur})
                else
                    break :blk "[*]";
            } else from;

            const to_id: []const u8 = if (std.mem.eql(u8, to, "[*]")) blk: {
                if (in_compound)
                    break :blk try std.fmt.allocPrint(a, "{s}.[*]-end", .{comp_id_cur})
                else
                    break :blk "[*]-end";
            } else to;

            const from_shp = if (std.mem.eql(u8, from, "[H]")) "history"
                             else if (std.mem.eql(u8, from, "[H*]")) "deepHistory" else "";
            const to_shp   = if (std.mem.eql(u8, to, "[H]")) "history"
                             else if (std.mem.eql(u8, to, "[H*]")) "deepHistory" else "";
            // Scoped initial/final states get shape "initial"/"final" so renderer can draw them
            const from_shp2 = if (std.mem.endsWith(u8, from_id, ".[*]")) "initial"
                              else if (std.mem.endsWith(u8, from_id, ".[*]-end")) "final"
                              else from_shp;
            const to_shp2   = if (std.mem.endsWith(u8, to_id, ".[*]")) "initial"
                              else if (std.mem.endsWith(u8, to_id, ".[*]-end")) "final"
                              else to_shp;
            try addState(&states, &seen, a, from_id, from_id, from_shp2);
            try addState(&states, &seen, a, to_id, to_id, to_shp2);

            var tn = Value.Node{ .type_name = "transition", .fields = .{} };
            try tn.fields.put(a, "from", Value{ .string = from_id });
            try tn.fields.put(a, "to", Value{ .string = to_id });
            try tn.fields.put(a, "label", Value{ .string = lbl });
            try transitions.append(a, Value{ .node = tn });
            // Track both endpoints as members of the active compound's current region
            if (in_compound) {
                const top = &compound_stack.items[compound_stack.items.len - 1];
                for ([2][]const u8{ from_id, to_id }) |sid| {
                    // Don't add the compound header itself as its own member
                    if (std.mem.eql(u8, sid, top.id)) continue;
                    try top.addMember(a, sid);
                }
            }
        }
    }

    var root = Value.Node{ .type_name = "stateDiagram", .fields = .{} };
    try root.fields.put(a, "states", Value{ .list = try states.toOwnedSlice(a) });
    try root.fields.put(a, "transitions", Value{ .list = try transitions.toOwnedSlice(a) });
    try root.fields.put(a, "notes", Value{ .list = try notes_list.toOwnedSlice(a) });
    try root.fields.put(a, "compounds", Value{ .list = try compounds_list.toOwnedSlice(a) });
    return state_renderer.render(allocator, Value{ .node = root });
}

