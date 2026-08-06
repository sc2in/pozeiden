//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
//! Hand-written gantt parser (mermaid text → Value tree → SVG), moved
//! verbatim out of root.zig (#39). The public entry point is `render`.
const std = @import("std");

const parse_util = @import("../parse_util.zig");
const isSkippable = parse_util.isSkippable;
const splitFirst = parse_util.splitFirst;
const stripQuotes = parse_util.stripQuotes;
const Value = @import("../diagram/value.zig").Value;
const gantt_renderer = @import("../renderers/gantt.zig");

// ─── gantt parser ─────────────────────────────────────────────────────────────

pub fn render(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var title: []const u8 = "gantt";
    var sections: std.ArrayList(Value) = .empty;
    var cur_section_label: []const u8 = "Tasks";
    var cur_tasks: std.ArrayList(Value) = .empty;
    var show_today: bool = false;
    var excludes_weekends: bool = false;

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
        if (std.mem.startsWith(u8, line, "excludes")) {
            const rest2 = std.mem.trim(u8, line[8..], " \t");
            if (std.mem.indexOf(u8, rest2, "weekends") != null or
                std.mem.indexOf(u8, rest2, "saturday") != null or
                std.mem.indexOf(u8, rest2, "sunday") != null)
            {
                excludes_weekends = true;
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "dateFormat") or
            std.mem.startsWith(u8, line, "axisFormat") or
            std.mem.startsWith(u8, line, "tickInterval"))
        {
            continue; // skip format directives
        }
        if (std.mem.startsWith(u8, line, "todayMarker")) {
            // "todayMarker off" disables it; anything else (including bare "todayMarker") enables
            const rest2 = std.mem.trim(u8, line[11..], " \t");
            if (!std.mem.eql(u8, rest2, "off")) {
                show_today = true;
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "section ") or std.mem.startsWith(u8, line, "section\t")) {
            // Save previous section
            if (cur_tasks.items.len > 0) {
                var sn = Value.Node{ .type_name = "section", .fields = .{} };
                try sn.fields.put(a, "label", Value{ .string = cur_section_label });
                try sn.fields.put(a, "tasks", Value{ .list = try cur_tasks.toOwnedSlice(a) });
                try sections.append(a, Value{ .node = sn });
                cur_tasks = .empty;
            }
            cur_section_label = std.mem.trim(u8, line[8..], " \t");
            continue;
        }

        // Task line: "Task name : flags, id, date, duration"
        if (std.mem.indexOf(u8, line, " : ") orelse std.mem.indexOf(u8, line, "\t:")) |colon| {
            const task_name = std.mem.trim(u8, line[0..colon], " \t");
            const rest = std.mem.trim(u8, line[colon + 3 ..], " \t");

            // Parse comma-separated fields; last numeric-ish field is duration
            var dur: []const u8 = "1d";
            var flags: []const u8 = "";
            var parts_iter = std.mem.splitScalar(u8, rest, ',');
            while (parts_iter.next()) |p| {
                const pt = std.mem.trim(u8, p, " \t");
                if (pt.len == 0) continue;
                if (std.mem.eql(u8, pt, "crit") or std.mem.eql(u8, pt, "done") or
                    std.mem.eql(u8, pt, "active") or std.mem.eql(u8, pt, "milestone"))
                {
                    flags = pt;
                } else if (pt.len > 0) {
                    const last = pt[pt.len - 1];
                    if (last == 'd' or last == 'h' or last == 'w' or std.ascii.isDigit(last)) {
                        dur = pt;
                    }
                }
            }

            var tn = Value.Node{ .type_name = "task", .fields = .{} };
            try tn.fields.put(a, "name", Value{ .string = task_name });
            try tn.fields.put(a, "duration", Value{ .string = dur });
            try tn.fields.put(a, "flags", Value{ .string = flags });
            try cur_tasks.append(a, Value{ .node = tn });
        }
    }

    // Flush last section
    if (cur_tasks.items.len > 0) {
        var sn = Value.Node{ .type_name = "section", .fields = .{} };
        try sn.fields.put(a, "label", Value{ .string = cur_section_label });
        try sn.fields.put(a, "tasks", Value{ .list = try cur_tasks.toOwnedSlice(a) });
        try sections.append(a, Value{ .node = sn });
    }

    var root = Value.Node{ .type_name = "gantt", .fields = .{} };
    try root.fields.put(a, "title", Value{ .string = title });
    try root.fields.put(a, "sections", Value{ .list = try sections.toOwnedSlice(a) });
    try root.fields.put(a, "show_today", Value{ .string = if (show_today) "1" else "0" });
    try root.fields.put(a, "excludes_weekends", Value{ .string = if (excludes_weekends) "1" else "0" });
    return gantt_renderer.render(allocator, Value{ .node = root });
}

