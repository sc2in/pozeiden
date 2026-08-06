//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
//! Hand-written sequenceDiagram parser (mermaid text → Value tree → SVG), moved
//! verbatim out of root.zig (#39). The public entry point is `render`.
const std = @import("std");

const parse_util = @import("../parse_util.zig");
const isSkippable = parse_util.isSkippable;
const splitFirst = parse_util.splitFirst;
const stripQuotes = parse_util.stripQuotes;
const Value = @import("../diagram/value.zig").Value;
const sequence_renderer = @import("../renderers/sequence.zig");

pub fn render(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var participants_list: std.ArrayList(Value) = .empty;
    var signals_list: std.ArrayList(Value) = .empty;
    var boxes_list: std.ArrayList(Value) = .empty;
    var seen_actors = std.StringHashMap(void).init(a);
    var autonumber = false;
    var msg_count: usize = 0; // track message count for note row positions

    const BlockFrame = struct {
        kind: []const u8,
        label: []const u8,
        start: usize,
        box_color: []const u8 = "", // only used when kind=="box"
        box_actor_start: usize = 0,
    };
    var block_stack: std.ArrayList(BlockFrame) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    // Manual loop rather than parse_util.LineIter: the `ref` block below
    // consumes lines from the same iterator with different skip semantics
    // (comments inside a ref block are part of its text).
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (isSkippable(line)) continue;

        if (first) {
            first = false;
            continue; // skip "sequenceDiagram"
        }

        // participant/actor declaration
        const is_actor_kw = std.mem.startsWith(u8, line, "actor ");
        const is_create_kw = std.mem.startsWith(u8, line, "create participant ") or
            std.mem.startsWith(u8, line, "create actor ");
        if (std.mem.startsWith(u8, line, "participant ") or is_actor_kw or is_create_kw) {
            const rest = if (std.mem.startsWith(u8, line, "participant ")) line[12..] else if (is_create_kw and std.mem.startsWith(u8, line, "create participant ")) line[19..] else if (is_create_kw and std.mem.startsWith(u8, line, "create actor ")) line[13..] else line[6..];
            // Handle "Name as Alias"
            const name = if (std.mem.indexOf(u8, rest, " as ")) |ai|
                std.mem.trim(u8, rest[0..ai], " \t")
            else
                std.mem.trim(u8, rest, " \t");
            if (seen_actors.get(name) == null) {
                try seen_actors.put(name, {});
                // Emit a Value.node with actor/name so the renderer can tell the kind
                const is_actor_type = is_actor_kw or
                    std.mem.startsWith(u8, line, "create actor ");
                var pn = Value.Node{ .type_name = "participant", .fields = .{} };
                try pn.fields.put(a, "actor", Value{ .string = name });
                if (is_actor_type) try pn.fields.put(a, "is_actor", Value{ .string = "1" });
                try participants_list.append(a, Value{ .node = pn });
            }
            continue;
        }
        // destroy: marks the end of an actor's lifeline
        if (std.mem.startsWith(u8, line, "destroy ")) {
            const actor_name = std.mem.trim(u8, line[8..], " \t");
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "destroy" });
            try sig.fields.put(a, "actor", Value{ .string = actor_name });
            try sig.fields.put(a, "row", Value{ .number = @floatFromInt(msg_count) });
            try signals_list.append(a, Value{ .node = sig });
            continue;
        }

        // loop / alt / opt / par blocks
        if (std.mem.startsWith(u8, line, "loop ") or std.mem.eql(u8, line, "loop")) {
            const lbl = if (line.len > 5) line[5..] else "";
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "loopStart" });
            try sig.fields.put(a, "loopText", Value{ .string = lbl });
            try signals_list.append(a, Value{ .node = sig });
            try block_stack.append(a, .{ .kind = "loop", .label = lbl, .start = signals_list.items.len - 1 });
            continue;
        }
        if (std.mem.startsWith(u8, line, "alt ") or std.mem.eql(u8, line, "alt")) {
            const lbl = if (line.len > 4) line[4..] else "";
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "altStart" });
            try sig.fields.put(a, "blockText", Value{ .string = lbl });
            try signals_list.append(a, Value{ .node = sig });
            try block_stack.append(a, .{ .kind = "alt", .label = lbl, .start = signals_list.items.len - 1 });
            continue;
        }
        if (std.mem.startsWith(u8, line, "opt ") or std.mem.eql(u8, line, "opt")) {
            const lbl = if (line.len > 4) line[4..] else "";
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "optStart" });
            try sig.fields.put(a, "blockText", Value{ .string = lbl });
            try signals_list.append(a, Value{ .node = sig });
            try block_stack.append(a, .{ .kind = "opt", .label = lbl, .start = signals_list.items.len - 1 });
            continue;
        }
        if (std.mem.startsWith(u8, line, "par ") or std.mem.eql(u8, line, "par")) {
            const lbl = if (line.len > 4) line[4..] else "";
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "parStart" });
            try sig.fields.put(a, "blockText", Value{ .string = lbl });
            try signals_list.append(a, Value{ .node = sig });
            try block_stack.append(a, .{ .kind = "par", .label = lbl, .start = signals_list.items.len - 1 });
            continue;
        }
        if (std.mem.startsWith(u8, line, "critical") or std.mem.eql(u8, line, "critical")) {
            const lbl = if (line.len > 9 and line[8] == ' ') std.mem.trim(u8, line[9..], " \t") else "";
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "criticalStart" });
            try sig.fields.put(a, "blockText", Value{ .string = lbl });
            try signals_list.append(a, Value{ .node = sig });
            try block_stack.append(a, .{ .kind = "critical", .label = lbl, .start = signals_list.items.len - 1 });
            continue;
        }
        if (std.mem.startsWith(u8, line, "break ") or std.mem.eql(u8, line, "break")) {
            const lbl = if (line.len > 6) std.mem.trim(u8, line[6..], " \t") else "";
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "breakStart" });
            try sig.fields.put(a, "blockText", Value{ .string = lbl });
            try signals_list.append(a, Value{ .node = sig });
            try block_stack.append(a, .{ .kind = "break", .label = lbl, .start = signals_list.items.len - 1 });
            continue;
        }
        if (std.mem.startsWith(u8, line, "neg ") or std.mem.eql(u8, line, "neg")) {
            const lbl = if (line.len > 4) std.mem.trim(u8, line[4..], " \t") else "";
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "negStart" });
            try sig.fields.put(a, "blockText", Value{ .string = lbl });
            try signals_list.append(a, Value{ .node = sig });
            try block_stack.append(a, .{ .kind = "neg", .label = lbl, .start = signals_list.items.len - 1 });
            continue;
        }
        // box [color] [label] ... end: colored background band behind actor columns.
        if (std.mem.startsWith(u8, line, "box ") or std.mem.eql(u8, line, "box")) {
            const rest = if (line.len > 4) std.mem.trim(u8, line[4..], " \t") else "";
            var color: []const u8 = "";
            var label: []const u8 = rest;
            if (std.mem.startsWith(u8, rest, "rgb(") or std.mem.startsWith(u8, rest, "rgba(")) {
                const close = std.mem.indexOfScalar(u8, rest, ')') orelse rest.len - 1;
                color = rest[0 .. close + 1];
                label = std.mem.trim(u8, rest[close + 1 ..], " \t");
            } else if (rest.len > 0 and rest[0] == '#') {
                const end_c = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
                color = rest[0..end_c];
                label = std.mem.trim(u8, rest[end_c..], " \t");
            }
            try block_stack.append(a, .{
                .kind = "box",
                .label = label,
                .start = signals_list.items.len,
                .box_color = color,
                .box_actor_start = participants_list.items.len,
            });
            continue;
        }
        if (std.mem.eql(u8, line, "autonumber")) {
            autonumber = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "activate ")) {
            const actor_name = std.mem.trim(u8, line[9..], " \t");
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "activate" });
            try sig.fields.put(a, "actor", Value{ .string = actor_name });
            try sig.fields.put(a, "row", Value{ .number = @floatFromInt(msg_count) });
            try signals_list.append(a, Value{ .node = sig });
            continue;
        }
        if (std.mem.startsWith(u8, line, "deactivate ")) {
            const actor_name = std.mem.trim(u8, line[11..], " \t");
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "deactivate" });
            try sig.fields.put(a, "actor", Value{ .string = actor_name });
            try sig.fields.put(a, "row", Value{ .number = @floatFromInt(msg_count) });
            try signals_list.append(a, Value{ .node = sig });
            continue;
        }
        if (std.mem.startsWith(u8, line, "note ") or std.mem.startsWith(u8, line, "Note ")) {
            // Note over A,B: text  /  Note right of A: text  /  Note left of A: text
            const rest = line[5..];
            const colon = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
            const pos_part = std.mem.trim(u8, rest[0..colon], " \t");
            const note_text = if (colon < rest.len) std.mem.trim(u8, rest[colon + 1 ..], " \t") else "";
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "note" });
            try sig.fields.put(a, "text", Value{ .string = note_text });
            try sig.fields.put(a, "row", Value{ .number = @floatFromInt(msg_count) });
            if (std.mem.startsWith(u8, pos_part, "over ")) {
                const actors_str = pos_part[5..];
                if (std.mem.indexOfScalar(u8, actors_str, ',')) |ci| {
                    try sig.fields.put(a, "actor1", Value{ .string = std.mem.trim(u8, actors_str[0..ci], " \t") });
                    try sig.fields.put(a, "actor2", Value{ .string = std.mem.trim(u8, actors_str[ci + 1 ..], " \t") });
                } else {
                    try sig.fields.put(a, "actor1", Value{ .string = std.mem.trim(u8, actors_str, " \t") });
                }
                try sig.fields.put(a, "position", Value{ .string = "over" });
            } else if (std.mem.startsWith(u8, pos_part, "right of ")) {
                try sig.fields.put(a, "actor1", Value{ .string = std.mem.trim(u8, pos_part[9..], " \t") });
                try sig.fields.put(a, "position", Value{ .string = "right" });
            } else if (std.mem.startsWith(u8, pos_part, "left of ")) {
                try sig.fields.put(a, "actor1", Value{ .string = std.mem.trim(u8, pos_part[8..], " \t") });
                try sig.fields.put(a, "position", Value{ .string = "left" });
            } else {
                try sig.fields.put(a, "actor1", Value{ .string = pos_part });
                try sig.fields.put(a, "position", Value{ .string = "over" });
            }
            try signals_list.append(a, Value{ .node = sig });
            continue;
        }
        // ref over Actor1[, Actor2]: text   — UML "ref" interaction fragment
        // Also supports multi-line: ref over Actor1\n  text\nend
        if (std.mem.startsWith(u8, line, "ref over ") or std.mem.startsWith(u8, line, "ref ")) {
            const after_kw: []const u8 = if (std.mem.startsWith(u8, line, "ref over ")) line[9..] else line[4..];
            const colon_pos = std.mem.indexOfScalar(u8, after_kw, ':');
            const actors_raw = std.mem.trim(u8, if (colon_pos) |cp| after_kw[0..cp] else after_kw, " \t");
            var ref_text: []const u8 = if (colon_pos) |cp| std.mem.trim(u8, after_kw[cp + 1 ..], " \t") else "";
            var actor1: []const u8 = actors_raw;
            var actor2: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, actors_raw, ',')) |ci| {
                actor1 = std.mem.trim(u8, actors_raw[0..ci], " \t");
                actor2 = std.mem.trim(u8, actors_raw[ci + 1 ..], " \t");
            }
            // Multi-line: collect lines until "end" when no inline text
            if (ref_text.len == 0) {
                var text_buf: std.ArrayList(u8) = .empty;
                while (lines.next()) |raw2| {
                    const l2 = std.mem.trim(u8, raw2, " \t\r");
                    if (std.mem.eql(u8, l2, "end")) break;
                    if (l2.len == 0) continue;
                    if (text_buf.items.len > 0) try text_buf.append(a, ' ');
                    try text_buf.appendSlice(a, l2);
                }
                ref_text = try text_buf.toOwnedSlice(a);
            }
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "ref" });
            try sig.fields.put(a, "actor1", Value{ .string = actor1 });
            if (actor2) |a2| try sig.fields.put(a, "actor2", Value{ .string = a2 });
            try sig.fields.put(a, "blockText", Value{ .string = ref_text });
            try sig.fields.put(a, "row", Value{ .number = @floatFromInt(msg_count) });
            try signals_list.append(a, Value{ .node = sig });
            msg_count += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "else") or
            std.mem.startsWith(u8, line, "and ") or std.mem.eql(u8, line, "and"))
        {
            // Emit a separator signal so the renderer can draw a divider line.
            const sep_label = if (std.mem.startsWith(u8, line, "else ")) std.mem.trim(u8, line[5..], " \t") else if (std.mem.startsWith(u8, line, "and ")) std.mem.trim(u8, line[4..], " \t") else "";
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "blockSep" });
            try sig.fields.put(a, "label", Value{ .string = sep_label });
            try sig.fields.put(a, "row", Value{ .number = @floatFromInt(msg_count) });
            try signals_list.append(a, Value{ .node = sig });
            continue;
        }
        // rect rgb(...) ... end: colored highlight span over a range of messages.
        if (std.mem.startsWith(u8, line, "rect ")) {
            const color_str = std.mem.trim(u8, line[5..], " \t");
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "rectStart" });
            try sig.fields.put(a, "blockText", Value{ .string = color_str });
            try signals_list.append(a, Value{ .node = sig });
            try block_stack.append(a, .{ .kind = "rect", .label = color_str, .start = signals_list.items.len - 1 });
            continue;
        }
        if (std.mem.eql(u8, line, "end")) {
            if (block_stack.items.len > 0) {
                const top = block_stack.pop().?;
                // "box" groups: emit colored band record into boxes_list
                if (std.mem.eql(u8, top.kind, "box")) {
                    var bxn = Value.Node{ .type_name = "box", .fields = .{} };
                    try bxn.fields.put(a, "color", Value{ .string = top.box_color });
                    try bxn.fields.put(a, "label", Value{ .string = top.label });
                    try bxn.fields.put(a, "actor_start", Value{ .number = @floatFromInt(top.box_actor_start) });
                    try bxn.fields.put(a, "actor_end", Value{ .number = @floatFromInt(participants_list.items.len) });
                    try boxes_list.append(a, Value{ .node = bxn });
                } else {
                    const end_type: []const u8 =
                        if (std.mem.eql(u8, top.kind, "loop")) "loopEnd" else if (std.mem.eql(u8, top.kind, "opt")) "optEnd" else if (std.mem.eql(u8, top.kind, "par")) "parEnd" else if (std.mem.eql(u8, top.kind, "rect")) "rectEnd" else if (std.mem.eql(u8, top.kind, "critical")) "criticalEnd" else if (std.mem.eql(u8, top.kind, "break")) "breakEnd" else if (std.mem.eql(u8, top.kind, "neg")) "negEnd" else "altEnd";
                    var sig = Value.Node{ .type_name = "signal", .fields = .{} };
                    try sig.fields.put(a, "type", Value{ .string = end_type });
                    try signals_list.append(a, Value{ .node = sig });
                }
            }
            continue;
        }

        // Message arrows: Actor->>Actor: text or Actor-->>Actor: text etc.
        // Try to find an arrow pattern
        const arrow_patterns = [_]struct { []const u8, []const u8 }{
            .{ "-->x", "3" }, .{ "-->>", "1" }, .{ "->>", "0" },
            .{ "-->", "3" },  .{ "->x", "2" },  .{ "->)", "0" },
            .{ "-)", "0" },   .{ "->", "2" },
        };
        var found_arrow = false;
        for (arrow_patterns) |ap| {
            if (std.mem.indexOf(u8, line, ap[0])) |arrow_pos| {
                const from_raw = std.mem.trim(u8, line[0..arrow_pos], " \t");
                const after_arrow = line[arrow_pos + ap[0].len ..];
                // Split on ":"
                const colon_pos = std.mem.indexOfScalar(u8, after_arrow, ':') orelse after_arrow.len;
                var to_raw = std.mem.trim(u8, after_arrow[0..colon_pos], " \t");
                const msg = if (colon_pos < after_arrow.len)
                    std.mem.trim(u8, after_arrow[colon_pos + 1 ..], " \t")
                else
                    "";

                // +/- activation marker on to-actor: prefix "+" or "-" or suffix "+" or "-"
                var activate_suffix: i8 = 0; // +1=activate, -1=deactivate
                if (to_raw.len > 0 and to_raw[0] == '+') {
                    to_raw = to_raw[1..];
                    activate_suffix = 1;
                } else if (to_raw.len > 0 and to_raw[0] == '-') {
                    to_raw = to_raw[1..];
                    activate_suffix = -1;
                } else if (to_raw.len > 0 and to_raw[to_raw.len - 1] == '+') {
                    to_raw = to_raw[0 .. to_raw.len - 1];
                    activate_suffix = 1;
                } else if (to_raw.len > 0 and to_raw[to_raw.len - 1] == '-') {
                    to_raw = to_raw[0 .. to_raw.len - 1];
                    activate_suffix = -1;
                }

                // Register actors
                for (&[_][]const u8{ from_raw, to_raw }) |actor| {
                    if (actor.len > 0 and seen_actors.get(actor) == null) {
                        try seen_actors.put(actor, {});
                        try participants_list.append(a, Value{ .string = actor });
                    }
                }

                var sig = Value.Node{ .type_name = "signal", .fields = .{} };
                try sig.fields.put(a, "type", Value{ .string = "addMessage" });
                try sig.fields.put(a, "from", Value{ .string = from_raw });
                try sig.fields.put(a, "to", Value{ .string = to_raw });
                try sig.fields.put(a, "msg", Value{ .string = msg });
                try sig.fields.put(a, "signalType", Value{ .string = ap[1] });
                try signals_list.append(a, Value{ .node = sig });
                msg_count += 1;

                // Emit activate/deactivate after message if +/- suffix was present
                if (activate_suffix == 1) {
                    var asig = Value.Node{ .type_name = "signal", .fields = .{} };
                    try asig.fields.put(a, "type", Value{ .string = "activate" });
                    try asig.fields.put(a, "actor", Value{ .string = to_raw });
                    try asig.fields.put(a, "row", Value{ .number = @floatFromInt(msg_count) });
                    try signals_list.append(a, Value{ .node = asig });
                } else if (activate_suffix == -1) {
                    var asig = Value.Node{ .type_name = "signal", .fields = .{} };
                    try asig.fields.put(a, "type", Value{ .string = "deactivate" });
                    try asig.fields.put(a, "actor", Value{ .string = to_raw });
                    try asig.fields.put(a, "row", Value{ .number = @floatFromInt(msg_count) });
                    try signals_list.append(a, Value{ .node = asig });
                }
                found_arrow = true;
                break;
            }
        }
    }

    var root = Value.Node{ .type_name = "sequenceDiagram", .fields = .{} };
    try root.fields.put(a, "participants", Value{ .list = try participants_list.toOwnedSlice(a) });
    try root.fields.put(a, "signals", Value{ .list = try signals_list.toOwnedSlice(a) });
    try root.fields.put(a, "boxes", Value{ .list = try boxes_list.toOwnedSlice(a) });
    try root.fields.put(a, "autonumber", Value{ .number = if (autonumber) 1.0 else 0.0 });

    return sequence_renderer.render(allocator, Value{ .node = root });
}

