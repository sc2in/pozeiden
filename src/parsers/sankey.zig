//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
//! Hand-written sankey-beta parser (mermaid text → Value tree → SVG), moved
//! verbatim out of root.zig (#39). The public entry point is `render`.
const std = @import("std");

const parse_util = @import("../parse_util.zig");
const isSkippable = parse_util.isSkippable;
const splitFirst = parse_util.splitFirst;
const stripQuotes = parse_util.stripQuotes;
const Value = @import("../diagram/value.zig").Value;
const sankey_renderer = @import("../renderers/sankey.zig");

// ─── sankey parser ────────────────────────────────────────────────────────────

pub fn render(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var flows: std.ArrayList(Value) = .empty;

    var lines = parse_util.LineIter.init(text);
    var first = true;
    while (lines.next()) |line| {
        if (first) {
            first = false;
            continue;
        }

        // CSV: from,to,value
        var parts = std.mem.splitScalar(u8, line, ',');
        const from = std.mem.trim(u8, parts.next() orelse continue, " \t");
        const to = std.mem.trim(u8, parts.next() orelse continue, " \t");
        const val_str = std.mem.trim(u8, parts.next() orelse continue, " \t");
        if (from.len == 0 or to.len == 0) continue;
        const val = std.fmt.parseFloat(f64, val_str) catch continue;

        var fn2 = Value.Node{ .type_name = "flow", .fields = .{} };
        try fn2.fields.put(a, "from", Value{ .string = from });
        try fn2.fields.put(a, "to", Value{ .string = to });
        try fn2.fields.put(a, "value", Value{ .number = val });
        try flows.append(a, Value{ .node = fn2 });
    }

    var root = Value.Node{ .type_name = "sankey", .fields = .{} };
    try root.fields.put(a, "flows", Value{ .list = try flows.toOwnedSlice(a) });
    return sankey_renderer.render(allocator, Value{ .node = root });
}

