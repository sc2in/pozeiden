//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
//! Hand-written C4 parser (mermaid text → Value tree → SVG), moved
//! verbatim out of root.zig (#39). The public entry point is `render`.
const std = @import("std");

const parse_util = @import("../parse_util.zig");
const isSkippable = parse_util.isSkippable;
const splitFirst = parse_util.splitFirst;
const stripQuotes = parse_util.stripQuotes;
const Value = @import("../diagram/value.zig").Value;
const c4_renderer = @import("../renderers/c4.zig");

// ─── C4 parser ────────────────────────────────────────────────────────────────

pub fn render(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var title: []const u8 = "";
    var elements: std.ArrayList(Value) = .empty;
    var relations: std.ArrayList(Value) = .empty;
    var boundaries: std.ArrayList(Value) = .empty;

    // Boundary tracking: stack of (alias, label, members)
    const BStack = struct { alias: []const u8, label: []const u8, members: std.ArrayList([]const u8), is_enterprise: bool };
    var bstack: std.ArrayList(BStack) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%") or
            std.mem.startsWith(u8, line, "//") or
            std.mem.startsWith(u8, line, "UpdateRel") or
            std.mem.startsWith(u8, line, "UpdateElement") or
            std.mem.startsWith(u8, line, "UpdateLayout"))
        {
            continue;
        }
        if (first) {
            first = false;
            continue;
        }

        if (std.mem.startsWith(u8, line, "title ") or std.mem.startsWith(u8, line, "title\t")) {
            title = std.mem.trim(u8, line[6..], " \t");
            continue;
        }

        // Close boundary
        if (std.mem.eql(u8, line, "}")) {
            if (bstack.items.len > 0) {
                const bs = bstack.pop().?;
                var bn = Value.Node{ .type_name = "boundary", .fields = .{} };
                try bn.fields.put(a, "alias", Value{ .string = bs.alias });
                try bn.fields.put(a, "label", Value{ .string = bs.label });
                if (bs.is_enterprise) try bn.fields.put(a, "enterprise", Value{ .string = "1" });
                var ml: std.ArrayList(Value) = .empty;
                for (bs.members.items) |m| try ml.append(a, Value{ .string = m });
                try bn.fields.put(a, "members", Value{ .list = try ml.toOwnedSlice(a) });
                try boundaries.append(a, Value{ .node = bn });
            }
            continue;
        }

        // Boundary open: *_Boundary(alias, "label") {
        if (std.mem.indexOf(u8, line, "_Boundary(") != null or
            std.mem.startsWith(u8, line, "Boundary("))
        {
            const args = extractArgs(line) orelse continue;
            const alias = nextArg(args, 0);
            const lbl = stripQuotes(nextArg(args, 1));
            const is_ent = std.mem.startsWith(u8, line, "Enterprise_Boundary");
            const bs = BStack{ .alias = alias, .label = lbl, .members = .empty, .is_enterprise = is_ent };
            try bstack.append(a, bs);
            continue;
        }

        // Relationship: Rel / BiRel / Rel_D / Rel_U / Rel_L / Rel_R / Rel_Back
        if (std.mem.startsWith(u8, line, "BiRel") or
            (std.mem.startsWith(u8, line, "Rel") and
                (line.len > 3 and (line[3] == '(' or line[3] == '_' or line[3] == ' '))))
        {
            const is_bi = std.mem.startsWith(u8, line, "BiRel");
            const is_back = std.mem.startsWith(u8, line, "Rel_Back");
            const args = extractArgs(line) orelse continue;
            // Rel_Back(from, to, ...) means arrow goes from `to` → `from`
            const raw_from = nextArg(args, 0);
            const raw_to = nextArg(args, 1);
            const actual_from = if (is_back) raw_to else raw_from;
            const actual_to = if (is_back) raw_from else raw_to;
            const lbl = stripQuotes(nextArg(args, 2));
            const tech = stripQuotes(nextArg(args, 3));
            var rn = Value.Node{ .type_name = "relation", .fields = .{} };
            try rn.fields.put(a, "from", Value{ .string = actual_from });
            try rn.fields.put(a, "to", Value{ .string = actual_to });
            try rn.fields.put(a, "label", Value{ .string = lbl });
            try rn.fields.put(a, "tech", Value{ .string = tech });
            if (is_bi) try rn.fields.put(a, "bidirectional", Value{ .string = "1" });
            try relations.append(a, Value{ .node = rn });
            continue;
        }

        // Element macros: Person, System, Container, Component, etc.
        if (parseC4Element(line)) |kv| {
            const kind_str = kv[0];
            const args = extractArgs(line) orelse continue;
            const alias = nextArg(args, 0);
            const lbl = stripQuotes(nextArg(args, 1));
            // For Container/Component: (alias, label, tech, desc)
            // For Person/System:       (alias, label, desc)
            var tech: []const u8 = "";
            var desc: []const u8 = "";
            const n4 = nextArg(args, 3);
            if (n4.len > 0) {
                // 4-arg form: Container(alias, label, tech, desc)
                tech = stripQuotes(nextArg(args, 2));
                desc = stripQuotes(n4);
            } else {
                desc = stripQuotes(nextArg(args, 2));
            }

            var en = Value.Node{ .type_name = "element", .fields = .{} };
            try en.fields.put(a, "alias", Value{ .string = alias });
            try en.fields.put(a, "label", Value{ .string = lbl });
            try en.fields.put(a, "tech", Value{ .string = tech });
            try en.fields.put(a, "desc", Value{ .string = desc });
            try en.fields.put(a, "kind", Value{ .string = kind_str });
            try elements.append(a, Value{ .node = en });

            // Register alias with open boundary
            if (bstack.items.len > 0) {
                try bstack.items[bstack.items.len - 1].members.append(a, alias);
            }
        }
    }

    var root = Value.Node{ .type_name = "c4", .fields = .{} };
    try root.fields.put(a, "title", Value{ .string = title });
    try root.fields.put(a, "elements", Value{ .list = try elements.toOwnedSlice(a) });
    try root.fields.put(a, "relations", Value{ .list = try relations.toOwnedSlice(a) });
    try root.fields.put(a, "boundaries", Value{ .list = try boundaries.toOwnedSlice(a) });
    return c4_renderer.render(allocator, Value{ .node = root });
}

/// Returns (kind_string, true) if `line` starts with a known C4 element macro.
fn parseC4Element(line: []const u8) ?[1][]const u8 {
    const macros = [_]struct { prefix: []const u8, kind: []const u8 }{
        .{ .prefix = "Person_Ext(", .kind = "person_ext" },
        .{ .prefix = "Person(", .kind = "person" },
        .{ .prefix = "SystemDb_Ext(", .kind = "system_db_ext" },
        .{ .prefix = "SystemDb(", .kind = "system_db" },
        .{ .prefix = "System_Ext(", .kind = "system_ext" },
        .{ .prefix = "System(", .kind = "system" },
        .{ .prefix = "ContainerDb_Ext(", .kind = "container_db_ext" },
        .{ .prefix = "ContainerDb(", .kind = "container_db" },
        .{ .prefix = "Container_Ext(", .kind = "container_ext" },
        .{ .prefix = "Container(", .kind = "container" },
        .{ .prefix = "ComponentDb_Ext(", .kind = "component_db_ext" },
        .{ .prefix = "ComponentDb(", .kind = "component_db" },
        .{ .prefix = "Component_Ext(", .kind = "component_ext" },
        .{ .prefix = "Component(", .kind = "component" },
        .{ .prefix = "Node_Ext(", .kind = "node_ext" },
        .{ .prefix = "Node(", .kind = "node" },
        .{ .prefix = "Deployment_Node(", .kind = "node" },
    };
    for (macros) |m| {
        if (std.mem.startsWith(u8, line, m.prefix)) return .{m.kind};
    }
    return null;
}

/// Extract everything inside the outermost parentheses of a call.
fn extractArgs(line: []const u8) ?[]const u8 {
    const open = std.mem.indexOf(u8, line, "(") orelse return null;
    const close = std.mem.lastIndexOf(u8, line, ")") orelse return null;
    if (close <= open) return null;
    return line[open + 1 .. close];
}

/// Get the Nth comma-separated argument (0-based), trimmed. Returns "" if not found.
fn nextArg(args: []const u8, n: usize) []const u8 {
    var iter = std.mem.splitScalar(u8, args, ',');
    var idx: usize = 0;
    while (iter.next()) |tok| {
        if (idx == n) return std.mem.trim(u8, tok, " \t");
        idx += 1;
    }
    return "";
}

