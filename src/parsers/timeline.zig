//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
//! Hand-written timeline parser (mermaid text → Value tree → SVG), moved
//! verbatim out of root.zig (#39). The public entry point is `render`.
const std = @import("std");

const parse_util = @import("../parse_util.zig");
const isSkippable = parse_util.isSkippable;
const splitFirst = parse_util.splitFirst;
const stripQuotes = parse_util.stripQuotes;
const Value = @import("../diagram/value.zig").Value;
const timeline_renderer = @import("../renderers/timeline.zig");

// ─── timeline parser ──────────────────────────────────────────────────────────

pub fn render(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var title: []const u8 = "";
    var sections: std.ArrayList(Value) = .empty;
    var cur_label: []const u8 = "";
    var cur_events: std.ArrayList(Value) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (isSkippable(line)) continue;
        if (first) {
            first = false;
            continue;
        }

        if (std.mem.startsWith(u8, line, "title ") or std.mem.startsWith(u8, line, "title\t")) {
            title = std.mem.trim(u8, line[6..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, line, "section ") or std.mem.startsWith(u8, line, "section\t")) {
            // flush only if current section has events
            if (cur_events.items.len > 0) {
                var sn = Value.Node{ .type_name = "section", .fields = .{} };
                try sn.fields.put(a, "label", Value{ .string = cur_label });
                try sn.fields.put(a, "events", Value{ .list = try cur_events.toOwnedSlice(a) });
                try sections.append(a, Value{ .node = sn });
                cur_events = .empty;
            }
            cur_label = std.mem.trim(u8, line[8..], " \t");
            continue;
        }

        // `date : event1 : event2` or just `event`
        if (std.mem.indexOf(u8, line, " : ")) |colon| {
            const era = std.mem.trim(u8, line[0..colon], " \t");
            // Flush previous section if era changed
            if (era.len > 0 and !std.mem.eql(u8, era, cur_label)) {
                if (cur_events.items.len > 0) {
                    var sn = Value.Node{ .type_name = "section", .fields = .{} };
                    try sn.fields.put(a, "label", Value{ .string = cur_label });
                    try sn.fields.put(a, "events", Value{ .list = try cur_events.toOwnedSlice(a) });
                    try sections.append(a, Value{ .node = sn });
                    cur_events = .empty;
                }
                cur_label = era;
            }
            // Add events (may be multiple colon-separated)
            var ev_iter = std.mem.splitSequence(u8, line[colon + 3 ..], " : ");
            while (ev_iter.next()) |ev| {
                const evt = std.mem.trim(u8, ev, " \t");
                if (evt.len > 0) {
                    try cur_events.append(a, Value{ .string = evt });
                }
            }
        } else {
            // Continuation event (indented, no era)
            try cur_events.append(a, Value{ .string = line });
        }
    }
    // Flush last section (only if it has events)
    if (cur_events.items.len > 0) {
        var sn = Value.Node{ .type_name = "section", .fields = .{} };
        try sn.fields.put(a, "label", Value{ .string = cur_label });
        try sn.fields.put(a, "events", Value{ .list = try cur_events.toOwnedSlice(a) });
        try sections.append(a, Value{ .node = sn });
    }

    var root = Value.Node{ .type_name = "timeline", .fields = .{} };
    try root.fields.put(a, "title", Value{ .string = title });
    try root.fields.put(a, "sections", Value{ .list = try sections.toOwnedSlice(a) });
    return timeline_renderer.render(allocator, Value{ .node = root });
}

