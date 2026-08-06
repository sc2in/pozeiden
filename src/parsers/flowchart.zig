//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
//! Hand-written flowchart/graph parser (mermaid text → Value tree → SVG), moved
//! verbatim out of root.zig (#39). The public entry point is `render`.
const std = @import("std");

const parse_util = @import("../parse_util.zig");
const isSkippable = parse_util.isSkippable;
const splitFirst = parse_util.splitFirst;
const stripQuotes = parse_util.stripQuotes;
const Value = @import("../diagram/value.zig").Value;
const flowchart_renderer = @import("../renderers/flowchart.zig");

/// Extract a CSS-style property value from a comma-separated style string.
/// e.g. flowchartParseProp("fill:#f9f,stroke:#333", "fill") → "#f9f"
fn flowchartParseProp(style: []const u8, prop: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, style, ',');
    while (it.next()) |token| {
        const t = std.mem.trim(u8, token, " \t");
        if (std.mem.startsWith(u8, t, prop)) {
            const rest = t[prop.len..];
            if (rest.len > 0 and rest[0] == ':')
                return std.mem.trim(u8, rest[1..], " \t");
        }
    }
    return null;
}

/// Parse a flowchart/graph node spec like "A", "A[label]", "A{label}", "A((label))", "A([label])"
/// Returns (id, label, shape_str)
fn parseNodeSpec(spec: []const u8) struct { []const u8, []const u8, []const u8 } {
    const s = std.mem.trim(u8, spec, " \t\r\n");
    if (s.len == 0) return .{ "", "", "rect" };
    // Find the first delimiter
    for (s, 0..) |c, i| {
        switch (c) {
            '[' => {
                const id = s[0..i];
                // Subroutine: [[label]]
                if (i + 1 < s.len and s[i + 1] == '[') {
                    const end = std.mem.indexOf(u8, s[i..], "]]") orelse (s.len - i - 1);
                    return .{ id, s[i + 2 .. @min(i + end, s.len)], "subroutine" };
                }
                // Cylinder: [(label)]  -- note: starts with `[` then `(`
                if (i + 1 < s.len and s[i + 1] == '(') {
                    const end = std.mem.lastIndexOfScalar(u8, s, ')') orelse s.len - 1;
                    return .{ id, s[i + 2 .. @min(end, s.len)], "cylinder" };
                }
                // Parallelogram [/label/] or trapezoid [/label\]
                if (i + 1 < s.len and s[i + 1] == '/') {
                    // trapezoid closes with \] ; parallelogram closes with /]
                    const close_trap = std.mem.indexOf(u8, s[i..], "\\]");
                    const close_para = std.mem.indexOf(u8, s[i..], "/]");
                    if (close_trap != null and (close_para == null or close_trap.? < close_para.?)) {
                        const end = close_trap.?;
                        return .{ id, s[i + 2 .. @min(i + end, s.len)], "trapezoid" };
                    }
                    const end = close_para orelse (s.len - i - 1);
                    return .{ id, s[i + 2 .. @min(i + end, s.len)], "parallelogram" };
                }
                // Inverted parallelogram [\label\] or trapezoid-alt [\label/]
                // Also handles the [\/label\/] double-delimiter variant.
                if (i + 1 < s.len and s[i + 1] == '\\') {
                    // When the opening is [\/ (backslash+slash), the label starts one
                    // character later and the closing \/ before ] must also be trimmed.
                    const double_open = i + 2 < s.len and s[i + 2] == '/';
                    const label_offset: usize = if (double_open) 3 else 2;
                    const close_trap = std.mem.indexOf(u8, s[i..], "/]");
                    const close_para = std.mem.indexOf(u8, s[i..], "\\]");
                    if (close_trap != null and (close_para == null or close_trap.? < close_para.?)) {
                        const end = close_trap.?;
                        // If closing is \/], trim the trailing \ too.
                        const trim_close: usize = if (double_open and end > 0 and s[i + end - 1] == '\\') 1 else 0;
                        return .{ id, s[i + label_offset .. @min(i + end - trim_close, s.len)], "trapezoid_alt" };
                    }
                    const end = close_para orelse (s.len - i - 1);
                    const trim_close: usize = if (double_open and end > 0 and s[i + end - 1] == '/') 1 else 0;
                    return .{ id, s[i + label_offset .. @min(i + end - trim_close, s.len)], "parallelogram_alt" };
                }
                // Rect: [label]
                const end = std.mem.lastIndexOfScalar(u8, s, ']') orelse s.len - 1;
                return .{ id, s[i + 1 .. @min(end, s.len)], "rect" };
            },
            '(' => {
                const id = s[0..i];
                // Double-circle: (((label)))  — check before ((
                if (i + 2 < s.len and s[i + 1] == '(' and s[i + 2] == '(') {
                    const end = std.mem.indexOf(u8, s[i..], ")))") orelse (s.len - i - 1);
                    return .{ id, s[i + 3 .. @min(i + end, s.len)], "double_circle" };
                }
                // Circle: ((label))
                if (i + 1 < s.len and s[i + 1] == '(') {
                    const end = std.mem.indexOf(u8, s[i..], "))") orelse (s.len - i - 1);
                    return .{ id, s[i + 2 .. @min(i + end, s.len)], "circle" };
                }
                // Stadium: ([label])  -- note: starts with `(` then `[`
                if (i + 1 < s.len and s[i + 1] == '[') {
                    const end = std.mem.indexOf(u8, s[i..], "])") orelse (s.len - i - 1);
                    return .{ id, s[i + 2 .. @min(i + end, s.len)], "stadium" };
                }
                // Round rectangle: (label)
                const end = std.mem.lastIndexOfScalar(u8, s, ')') orelse s.len - 1;
                return .{ id, s[i + 1 .. @min(end, s.len)], "round" };
            },
            '{' => {
                const id = s[0..i];
                // Hexagon: {{label}}
                if (i + 1 < s.len and s[i + 1] == '{') {
                    const end = std.mem.indexOf(u8, s[i..], "}}") orelse (s.len - i - 1);
                    return .{ id, s[i + 2 .. @min(i + end, s.len)], "hexagon" };
                }
                // Diamond: {label}
                const end = std.mem.lastIndexOfScalar(u8, s, '}') orelse s.len - 1;
                return .{ id, s[i + 1 .. @min(end, s.len)], "diamond" };
            },
            '>' => {
                // Asymmetric: id>label]  -- only if `]` exists and no space/dash right after `>`
                if (i + 1 < s.len and s[i + 1] != ' ' and s[i + 1] != '\t' and s[i + 1] != '-') {
                    if (std.mem.lastIndexOfScalar(u8, s[i..], ']') != null) {
                        const id = s[0..i];
                        const end = (std.mem.lastIndexOfScalar(u8, s, ']') orelse s.len - 1);
                        return .{ id, s[i + 1 .. @min(end, s.len)], "asymmetric" };
                    }
                }
            },
            else => {},
        }
    }
    return .{ s, s, "rect" };
}

/// Find an edge arrow in the line. Returns the split position or null.
/// Handles: -->, --->, -.->  ==>, --
fn findEdgeArrow(line: []const u8) ?struct { usize, usize, []const u8 } {
    // Order matters: try longer patterns first
    const patterns = [_]struct { []const u8, []const u8 }{
        .{ "-.->", "dotted" },
        .{ "-.-", "dotted" },
        .{ "==>", "thick" },
        .{ "==", "thick" },
        .{ "--->", "solid" },
        .{ "-->", "solid" },
        .{ "---", "solid" },
        .{ "->", "solid" },
    };
    for (patterns) |p| {
        if (std.mem.indexOf(u8, line, p[0])) |pos| {
            return .{ pos, pos + p[0].len, p[1] };
        }
    }
    return null;
}

pub fn render(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes_list: std.ArrayList(Value) = .empty;
    var edges_list: std.ArrayList(Value) = .empty;
    var seen_nodes = std.StringHashMap(void).init(a);
    var direction: []const u8 = "TB";

    // classDef name → raw style string ("fill:#f9f,stroke:#333")
    var class_defs = std.StringHashMap([]const u8).init(a);
    // node_id → class name (from "class nodeId className" or "A:::className")
    var node_class_map = std.StringHashMap([]const u8).init(a);
    // node_id → direct style string (from "style nodeId fill:#xxx,stroke:#yyy")
    var node_styles = std.StringHashMap([]const u8).init(a);
    // edge index → style string (from "linkStyle N stroke:#xxx,stroke-width:2px")
    var link_styles = std.AutoHashMap(usize, []const u8).init(a);
    // node_id → href URL (from "click A href \"url\"")
    var node_hrefs = std.StringHashMap([]const u8).init(a);

    // Subgraph tracking
    const Subgraph = struct {
        id: []const u8,
        label: []const u8,
        members: std.ArrayList(Value),
        direction: []const u8 = "",
    };
    var subgraphs: std.ArrayList(Subgraph) = .empty;
    // Stack of subgraph indices — supports arbitrary nesting depth.
    // The top of the stack is the innermost (currently active) subgraph.
    var subgraph_stack: std.ArrayList(usize) = .empty;

    const addNodeToSubgraph = struct {
        fn run(sgs: *std.ArrayList(Subgraph), stack: *const std.ArrayList(usize), alloc: std.mem.Allocator, id: []const u8) !void {
            // Add the node to all active subgraphs (innermost + ancestors) so that
            // outer bounding boxes correctly enclose their nested children.
            for (stack.items) |sg_idx| {
                try sgs.items[sg_idx].members.append(alloc, Value{ .string = id });
            }
        }
    }.run;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        // Skip comments
        if (std.mem.startsWith(u8, line, "%%")) continue;
        // classDef myClass fill:#f9f,stroke:#333
        if (std.mem.startsWith(u8, line, "classDef ")) {
            const rest = line[9..];
            if (std.mem.indexOfScalar(u8, rest, ' ')) |sp| {
                const cname = rest[0..sp];
                const cstyle = std.mem.trim(u8, rest[sp + 1 ..], " \t");
                if (cname.len > 0 and cstyle.len > 0)
                    try class_defs.put(cname, cstyle);
            }
            continue;
        }
        // class node1,node2 className
        if (std.mem.startsWith(u8, line, "class ")) {
            const rest = line[6..];
            if (std.mem.lastIndexOfScalar(u8, rest, ' ')) |sp| {
                const ids_part = rest[0..sp];
                const cname = std.mem.trim(u8, rest[sp + 1 ..], " \t");
                if (cname.len > 0) {
                    var it = std.mem.splitScalar(u8, ids_part, ',');
                    while (it.next()) |id_raw| {
                        const nid = std.mem.trim(u8, id_raw, " \t");
                        if (nid.len > 0) try node_class_map.put(nid, cname);
                    }
                }
            }
            continue;
        }
        // style nodeId fill:#xxx,stroke:#yyy  (direct per-node override)
        if (std.mem.startsWith(u8, line, "style ")) {
            const rest = line[6..];
            if (std.mem.indexOfAny(u8, rest, " \t")) |sp| {
                const nid = std.mem.trim(u8, rest[0..sp], " \t");
                const cstyle = std.mem.trim(u8, rest[sp + 1 ..], " \t");
                if (nid.len > 0 and cstyle.len > 0) try node_styles.put(nid, cstyle);
            }
            continue;
        }
        // click A href "url"  (node hyperlink)
        if (std.mem.startsWith(u8, line, "click ")) {
            const rest = line[6..];
            if (std.mem.indexOf(u8, rest, " href ")) |hp| {
                const nid = std.mem.trim(u8, rest[0..hp], " \t");
                const url_raw = std.mem.trim(u8, rest[hp + 6 ..], " \t\"");
                if (nid.len > 0 and url_raw.len > 0) try node_hrefs.put(nid, url_raw);
            }
            continue;
        }
        // linkStyle N stroke:#xxx,stroke-width:2px  (per-edge style by insertion index)
        if (std.mem.startsWith(u8, line, "linkStyle ")) {
            const rest = line[10..];
            var tok_end: usize = 0;
            while (tok_end < rest.len and rest[tok_end] != ' ' and rest[tok_end] != '\t') tok_end += 1;
            const indices_str = rest[0..tok_end];
            const style_str = std.mem.trim(u8, rest[tok_end..], " \t");
            if (style_str.len > 0) {
                var idx_it = std.mem.splitScalar(u8, indices_str, ',');
                while (idx_it.next()) |idx_s| {
                    const idx = std.fmt.parseUnsigned(usize, std.mem.trim(u8, idx_s, " \t"), 10) catch continue;
                    try link_styles.put(idx, style_str);
                }
            }
            continue;
        }

        if (first) {
            first = false;
            // Parse direction from header: "graph TD" or "flowchart LR"
            if (std.mem.indexOf(u8, line, " ")) |sp| {
                direction = std.mem.trim(u8, line[sp..], " \t");
            }
            continue;
        }

        // Subgraph start: "subgraph id" or "subgraph id [label]" or "subgraph [label]"
        if (std.mem.startsWith(u8, line, "subgraph")) {
            const rest = std.mem.trim(u8, line[8..], " \t");
            // When brackets present: "SG1 [My Label]" → id="SG1", label="My Label"
            // Without brackets: "Service Layer" → id=label=entire rest
            const sg_id: []const u8, const label: []const u8 = if (std.mem.indexOf(u8, rest, "[")) |lb| blk: {
                const id = std.mem.trim(u8, rest[0..lb], " \t");
                const rb = std.mem.indexOf(u8, rest, "]") orelse (rest.len - 1);
                const raw_label = rest[lb + 1 .. rb];
                // Strip surrounding quotes from e.g. ["Input Layer"] → Input Layer
                const label_unquoted = if (raw_label.len >= 2 and
                    (raw_label[0] == '"' or raw_label[0] == '\'') and
                    raw_label[raw_label.len - 1] == raw_label[0])
                    raw_label[1 .. raw_label.len - 1]
                else
                    raw_label;
                break :blk .{ id, label_unquoted };
            } else blk: {
                const lbl = if (rest.len > 0) rest else "group";
                break :blk .{ lbl, lbl };
            };
            const sg_idx = subgraphs.items.len;
            try subgraphs.append(a, .{ .id = sg_id, .label = label, .members = .empty });
            try subgraph_stack.append(a, sg_idx);
            continue;
        }
        if (std.mem.eql(u8, line, "end") and subgraph_stack.items.len > 0) {
            _ = subgraph_stack.pop();
            continue;
        }

        // Capture subgraph-local direction directives (direction LR / direction TB etc.)
        if (std.mem.startsWith(u8, line, "direction ") and subgraph_stack.items.len > 0) {
            const dir_val = std.mem.trim(u8, line[10..], " \t");
            const top = subgraph_stack.items[subgraph_stack.items.len - 1];
            subgraphs.items[top].direction = dir_val;
            continue;
        }
        if (std.mem.startsWith(u8, line, "direction ")) continue;

        // Try to find an edge arrow
        if (findEdgeArrow(line)) |arrow| {
            var from_raw = std.mem.trim(u8, line[0..arrow[0]], " \t");
            var to_part = std.mem.trim(u8, line[arrow[1]..], " \t");

            // Strip inline class annotations: A[label]:::myClass
            var from_inline_class: ?[]const u8 = null;
            if (std.mem.indexOf(u8, from_raw, ":::")) |cp| {
                from_inline_class = std.mem.trim(u8, from_raw[cp + 3 ..], " \t");
                from_raw = from_raw[0..cp];
            }
            var to_inline_class: ?[]const u8 = null;
            if (std.mem.indexOf(u8, to_part, ":::")) |cp| {
                to_inline_class = std.mem.trim(u8, to_part[cp + 3 ..], " \t");
                to_part = to_part[0..cp];
            }

            // Edge label: |label| between arrow and destination (A --> |label| B)
            var edge_label: ?[]const u8 = null;
            if (to_part.len > 0 and to_part[0] == '|') {
                const label_end = std.mem.indexOfScalar(u8, to_part[1..], '|') orelse 0;
                edge_label = to_part[1 .. 1 + label_end];
                to_part = std.mem.trim(u8, to_part[2 + label_end ..], " \t");
            }

            // Edge label embedded before arrow: "A -- label -->" or "A -- label ---"
            // Detect: from_raw contains " -- " and has content before it
            if (edge_label == null) {
                if (std.mem.lastIndexOf(u8, from_raw, " -- ")) |dash_pos| {
                    const node_part = std.mem.trim(u8, from_raw[0..dash_pos], " \t");
                    const lbl = std.mem.trim(u8, from_raw[dash_pos + 4 ..], " \t");
                    if (node_part.len > 0 and lbl.len > 0) {
                        from_raw = node_part;
                        edge_label = lbl;
                    }
                }
            }

            const from_part = from_raw;
            const from_id, const from_label, const from_shape = parseNodeSpec(from_part);
            const to_id, const to_label, const to_shape = parseNodeSpec(to_part);

            if (from_id.len == 0 or to_id.len == 0) continue;

            // Record inline class assignments
            if (from_inline_class) |cn| try node_class_map.put(from_id, cn);
            if (to_inline_class) |cn| try node_class_map.put(to_id, cn);

            // Add nodes if not seen
            if (seen_nodes.get(from_id) == null) {
                try seen_nodes.put(from_id, {});
                var n = Value.Node{ .type_name = "node", .fields = .{} };
                try n.fields.put(a, "id", Value{ .string = from_id });
                try n.fields.put(a, "label", Value{ .string = from_label });
                try n.fields.put(a, "shape", Value{ .string = from_shape });
                try nodes_list.append(a, Value{ .node = n });
                try addNodeToSubgraph(&subgraphs, &subgraph_stack, a, from_id);
            }
            if (seen_nodes.get(to_id) == null) {
                try seen_nodes.put(to_id, {});
                var n = Value.Node{ .type_name = "node", .fields = .{} };
                try n.fields.put(a, "id", Value{ .string = to_id });
                try n.fields.put(a, "label", Value{ .string = to_label });
                try n.fields.put(a, "shape", Value{ .string = to_shape });
                try nodes_list.append(a, Value{ .node = n });
                try addNodeToSubgraph(&subgraphs, &subgraph_stack, a, to_id);
            }

            // Add edge
            var e = Value.Node{ .type_name = "edge", .fields = .{} };
            try e.fields.put(a, "from", Value{ .string = from_id });
            try e.fields.put(a, "to", Value{ .string = to_id });
            try e.fields.put(a, "style", Value{ .string = arrow[2] });
            if (edge_label) |lbl| {
                try e.fields.put(a, "label", Value{ .string = lbl });
            }
            try edges_list.append(a, Value{ .node = e });
        } else if (line.len > 0 and !std.mem.eql(u8, line, "end")) {
            // Standalone node definition — strip optional :::className first
            var standalone = line;
            var standalone_class: ?[]const u8 = null;
            if (std.mem.indexOf(u8, standalone, ":::")) |cp| {
                standalone_class = std.mem.trim(u8, standalone[cp + 3 ..], " \t");
                standalone = standalone[0..cp];
            }
            const node_id, const node_label, const node_shape = parseNodeSpec(standalone);
            if (node_id.len > 0 and seen_nodes.get(node_id) == null) {
                try seen_nodes.put(node_id, {});
                var n = Value.Node{ .type_name = "node", .fields = .{} };
                try n.fields.put(a, "id", Value{ .string = node_id });
                try n.fields.put(a, "label", Value{ .string = node_label });
                try n.fields.put(a, "shape", Value{ .string = node_shape });
                try nodes_list.append(a, Value{ .node = n });
                try addNodeToSubgraph(&subgraphs, &subgraph_stack, a, node_id);
                if (standalone_class) |cn| try node_class_map.put(node_id, cn);
            }
        }
    }

    // Build subgraph ID → index map for post-processing
    var subgraph_id_map = std.StringHashMap(usize).init(a);
    for (subgraphs.items, 0..) |sg, si| {
        if (sg.id.len > 0) try subgraph_id_map.put(sg.id, si);
    }

    // Rewire edges that target a subgraph ID: point to the subgraph's first member instead.
    for (edges_list.items) |*ev| {
        const en = switch (ev.*) {
            .node => |*n| n,
            else => continue,
        };
        if (en.getString("from")) |fid| {
            if (subgraph_id_map.get(fid)) |si| {
                const sg = &subgraphs.items[si];
                if (sg.members.items.len > 0) {
                    if (sg.members.items[0].asString()) |mid|
                        try en.fields.put(a, "from", Value{ .string = mid });
                }
            }
        }
        if (en.getString("to")) |tid| {
            if (subgraph_id_map.get(tid)) |si| {
                const sg = &subgraphs.items[si];
                if (sg.members.items.len > 0) {
                    if (sg.members.items[0].asString()) |mid|
                        try en.fields.put(a, "to", Value{ .string = mid });
                }
            }
        }
    }

    // Remove phantom nodes whose IDs are subgraph IDs (they were created by edge parsing).
    {
        var filtered: std.ArrayList(Value) = .empty;
        for (nodes_list.items) |nv| {
            const nid = switch (nv) {
                .node => |n| n.getString("id") orelse "",
                else => "",
            };
            if (nid.len > 0 and subgraph_id_map.contains(nid)) continue;
            try filtered.append(a, nv);
        }
        nodes_list = filtered;
    }

    // Apply classDef styles to nodes that carry a class assignment.
    for (nodes_list.items) |*nv| {
        const is_node = switch (nv.*) {
            .node => true,
            else => false,
        };
        if (!is_node) continue;
        const nn = &nv.node;
        const nid = nn.getString("id") orelse continue;
        if (node_class_map.get(nid)) |cname| {
            if (class_defs.get(cname)) |style| {
                if (flowchartParseProp(style, "fill")) |v| try nn.fields.put(a, "fill", Value{ .string = v });
                if (flowchartParseProp(style, "stroke")) |v| try nn.fields.put(a, "stroke", Value{ .string = v });
                if (flowchartParseProp(style, "color")) |v| try nn.fields.put(a, "text_color", Value{ .string = v });
                if (flowchartParseProp(style, "font-weight")) |v| try nn.fields.put(a, "font_weight", Value{ .string = v });
            }
        }
        // Direct `style` overrides take priority over classDef.
        if (node_styles.get(nid)) |style| {
            if (flowchartParseProp(style, "fill")) |v| try nn.fields.put(a, "fill", Value{ .string = v });
            if (flowchartParseProp(style, "stroke")) |v| try nn.fields.put(a, "stroke", Value{ .string = v });
            if (flowchartParseProp(style, "color")) |v| try nn.fields.put(a, "text_color", Value{ .string = v });
            if (flowchartParseProp(style, "font-weight")) |v| try nn.fields.put(a, "font_weight", Value{ .string = v });
        }
        // Hyperlink from click directive
        if (node_hrefs.get(nid)) |url| {
            try nn.fields.put(a, "href", Value{ .string = url });
        }
    }

    // Apply linkStyle overrides to edges by insertion index.
    for (edges_list.items, 0..) |*ev, ei| {
        const style = link_styles.get(ei) orelse continue;
        const en = switch (ev.*) {
            .node => |*n| n,
            else => continue,
        };
        if (flowchartParseProp(style, "stroke")) |v| try en.fields.put(a, "edge_color", Value{ .string = v });
    }

    // Build subgraphs list for the renderer
    var subgraphs_val: std.ArrayList(Value) = .empty;
    for (subgraphs.items) |*sg| {
        if (sg.members.items.len == 0) continue;
        var sgn = Value.Node{ .type_name = "subgraph", .fields = .{} };
        try sgn.fields.put(a, "id", Value{ .string = sg.id });
        try sgn.fields.put(a, "label", Value{ .string = sg.label });
        try sgn.fields.put(a, "members", Value{ .list = try sg.members.toOwnedSlice(a) });
        if (sg.direction.len > 0)
            try sgn.fields.put(a, "direction", Value{ .string = sg.direction });
        try subgraphs_val.append(a, Value{ .node = sgn });
    }

    var root = Value.Node{ .type_name = "flowchart", .fields = .{} };
    try root.fields.put(a, "direction", Value{ .string = direction });
    try root.fields.put(a, "nodes", Value{ .list = try nodes_list.toOwnedSlice(a) });
    try root.fields.put(a, "edges", Value{ .list = try edges_list.toOwnedSlice(a) });
    try root.fields.put(a, "subgraphs", Value{ .list = try subgraphs_val.toOwnedSlice(a) });

    return flowchart_renderer.render(allocator, Value{ .node = root });
}

