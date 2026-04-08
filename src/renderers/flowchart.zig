//! Flowchart SVG renderer.
//! Builds a Graph from the Jison runtime's Value AST, runs layout, and emits SVG.
//! Expects a Value.node with `nodes` (id, label, shape), `edges` (from, to, label,
//! style), `subgraphs` (label, members list), and optional `direction` ("TB"/"LR"/etc.).
const std = @import("std");
const Value = @import("../diagram/value.zig").Value;
const SvgWriter = @import("../svg/writer.zig").SvgWriter;
const layout = @import("../svg/layout.zig");
const theme = @import("../svg/theme.zig");
const arrow_marker_defs = @import("../svg/writer.zig").arrow_marker_defs;

/// Render a flowchart SVG from `value`.
/// `value` must be a node with `nodes` (list of nodes with `id`, `label`, `shape`),
/// `edges` (list of nodes with `from`, `to`, `label`, `style`), optional `subgraphs`
/// (with `label` and `members` list), and optional `direction` ("TB"/"LR"/"RL"/"BT").
pub fn render(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    // Build graph from the flat Jison-parse output.
    // The Jison runtime for flowchart doesn't produce a structured AST like Langium;
    // instead we receive what was extracted.  For now we accept a Value.node with
    // fields: "nodes" (list of node records) and "edges" (list of edge records).
    const node = value.asNode() orelse return renderFallback(allocator, "flowchart");

    // Collect nodes
    var graph_nodes: std.ArrayList(layout.GraphNode) = .empty;
    defer graph_nodes.deinit(allocator);
    var graph_edges: std.ArrayList(layout.GraphEdge) = .empty;
    defer graph_edges.deinit(allocator);

    const nodes_val = node.getList("nodes");
    for (nodes_val) |nv| {
        const nn = nv.asNode() orelse continue;
        const id = nn.getString("id") orelse continue;
        const label = nn.getString("label") orelse id;
        const shape_str = nn.getString("shape") orelse "rect";
        const shape = parseShape(shape_str);
        try graph_nodes.append(allocator, layout.GraphNode{
            .id = id,
            .label = label,
            .shape = shape,
        });
    }

    const edges_val = node.getList("edges");
    for (edges_val) |ev| {
        const en = ev.asNode() orelse continue;
        const from = en.getString("from") orelse continue;
        const to = en.getString("to") orelse continue;
        const label = en.getString("label");
        const style_str = en.getString("style") orelse "solid";
        const style = parseEdgeStyle(style_str);
        try graph_edges.append(allocator, layout.GraphEdge{
            .from = from,
            .to = to,
            .label = label,
            .style = style,
        });
    }

    // If no nodes were extracted, emit a placeholder
    if (graph_nodes.items.len == 0) {
        return renderFallback(allocator, "flowchart (no nodes parsed)");
    }

    const dir_str = node.getString("direction") orelse "TB";
    const direction = parseDirection(dir_str);

    var graph = layout.Graph{
        .nodes = graph_nodes.items,
        .edges = graph_edges.items,
        .direction = direction,
    };

    try layout.layout(allocator, &graph);

    const svg_w = layout.svgWidth(graph.nodes) + 80;
    const svg_h = layout.svgHeight(graph.nodes) + 80;

    var svg = SvgWriter.init(allocator);
    defer svg.deinit();

    try svg.header(svg_w, svg_h);
    try svg.defs(arrow_marker_defs);

    // Draw subgraph background boxes (behind edges and nodes)
    const subgraphs_val = node.getList("subgraphs");
    for (subgraphs_val) |sgv| {
        const sgn = sgv.asNode() orelse continue;
        const label = sgn.getString("label") orelse "";
        const members = sgn.getList("members");
        if (members.len == 0) continue;

        // Compute bounding box of member nodes
        var min_x: f32 = std.math.floatMax(f32);
        var min_y: f32 = std.math.floatMax(f32);
        var max_x: f32 = -std.math.floatMax(f32);
        var max_y: f32 = -std.math.floatMax(f32);
        for (members) |mv| {
            const mid = mv.asString() orelse continue;
            const mn = findNode(graph.nodes, mid) orelse continue;
            if (mn.x < min_x) min_x = mn.x;
            if (mn.y < min_y) min_y = mn.y;
            if (mn.x + mn.w > max_x) max_x = mn.x + mn.w;
            if (mn.y + mn.h > max_y) max_y = mn.y + mn.h;
        }
        if (min_x >= max_x) continue;
        const pad: f32 = 16;
        try svg.rect(min_x - pad, min_y - pad, max_x - min_x + pad * 2, max_y - min_y + pad * 2,
            6.0, "#f0f4ff", "#b0c0e8", 1.2);
        try svg.text(min_x - pad + 6, min_y - pad + 13, label,
            "#4466aa", theme.font_size_small, .start, "normal");
    }

    // Draw edges first (behind nodes)
    for (graph.edges) |e| {
        const from_node = findNode(graph.nodes, e.from) orelse continue;
        const to_node = findNode(graph.nodes, e.to) orelse continue;

        // Connection points: exit bottom-center / enter top-center for TB,
        // exit right-center / enter left-center for LR, etc.
        const fx: f32, const fy: f32, const tx: f32, const ty: f32 = switch (direction) {
            .lr => .{
                from_node.x + from_node.w,
                from_node.y + from_node.h / 2,
                to_node.x,
                to_node.y + to_node.h / 2,
            },
            .rl => .{
                from_node.x,
                from_node.y + from_node.h / 2,
                to_node.x + to_node.w,
                to_node.y + to_node.h / 2,
            },
            .bt => .{
                from_node.x + from_node.w / 2,
                from_node.y,
                to_node.x + to_node.w / 2,
                to_node.y + to_node.h,
            },
            .tb => .{
                from_node.x + from_node.w / 2,
                from_node.y + from_node.h,
                to_node.x + to_node.w / 2,
                to_node.y,
            },
        };

        // Cubic Bezier control points pull the curve away from the straight-line path.
        // For TB/BT: control points extend vertically from the exit/entry points.
        // For LR/RL: control points extend horizontally.
        const ctrl: f32 = switch (direction) {
            .tb, .bt => layout.V_GAP * 0.6,
            .lr, .rl => layout.H_GAP,
        };
        const cx1: f32, const cy1: f32, const cx2: f32, const cy2: f32 = switch (direction) {
            .tb  => .{ fx,        fy + ctrl, tx,        ty - ctrl },
            .bt  => .{ fx,        fy - ctrl, tx,        ty + ctrl },
            .lr  => .{ fx + ctrl, fy,        tx - ctrl, ty },
            .rl  => .{ fx - ctrl, fy,        tx + ctrl, ty },
        };

        const stroke = theme.edge_color;
        const sw = theme.edge_stroke_width;

        var path_buf: [256]u8 = undefined;
        const path_d = try std.fmt.bufPrint(&path_buf,
            "M {d:.1} {d:.1} C {d:.1} {d:.1} {d:.1} {d:.1} {d:.1} {d:.1}",
            .{ fx, fy, cx1, cy1, cx2, cy2, tx, ty });

        if (e.style == .dotted) {
            try svg.path(path_d, "none", stroke, sw, "stroke-dasharray=\"5,5\"");
        } else if (e.style == .thick) {
            try svg.path(path_d, "none", stroke, sw + 1.5, "");
        } else {
            try svg.path(path_d, "none", stroke, sw, "");
        }

        // Direction-aware arrowhead: tangent at Bezier t=1 is (P3 - C2)
        const tang_x = tx - cx2;
        const tang_y = ty - cy2;
        const tang_len = @sqrt(tang_x * tang_x + tang_y * tang_y);
        if (tang_len > 0.5) {
            const ux = tang_x / tang_len;
            const uy = tang_y / tang_len;
            const arr: f32 = 8.0;
            const half: f32 = 4.5;
            var pts_buf: [128]u8 = undefined;
            const pts = try std.fmt.bufPrint(&pts_buf,
                "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                .{
                    tx - ux * arr - uy * half,
                    ty - uy * arr + ux * half,
                    tx, ty,
                    tx - ux * arr + uy * half,
                    ty - uy * arr - ux * half,
                });
            try svg.polygon(pts, stroke, stroke, 0);
        }

        // Edge label at Bezier midpoint (t=0.5)
        if (e.label) |lbl| {
            const mid_x = 0.125 * fx + 0.375 * cx1 + 0.375 * cx2 + 0.125 * tx;
            const mid_y = 0.125 * fy + 0.375 * cy1 + 0.375 * cy2 + 0.125 * ty;
            try svg.text(mid_x, mid_y - 6, lbl, theme.text_color, theme.font_size_small, .middle, "normal");
        }
    }

    // Draw nodes
    for (graph.nodes) |n| {
        try drawNode(&svg, n);
    }

    try svg.footer();
    return svg.toOwnedSlice();
}

fn drawNode(svg: *SvgWriter, n: layout.GraphNode) !void {
    const x = n.x;
    const y = n.y;
    const w = n.w;
    const h = n.h;
    const cx = x + w / 2;
    const cy = y + h / 2;

    switch (n.shape) {
        .diamond => {
            var pts_buf: [256]u8 = undefined;
            const pts = try std.fmt.bufPrint(&pts_buf,
                "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                .{ cx, y, x + w, cy, cx, y + h, x, cy });
            try svg.polygon(pts, theme.node_fill, theme.node_stroke, theme.node_stroke_width);
        },
        .circle => {
            try svg.circle(cx, cy, h / 2, theme.node_fill, theme.node_stroke, theme.node_stroke_width);
        },
        .stadium => {
            try svg.rect(x, y, w, h, h / 2, theme.node_fill, theme.node_stroke, theme.node_stroke_width);
        },
        .round => {
            try svg.rect(x, y, w, h, 8.0, theme.node_fill, theme.node_stroke, theme.node_stroke_width);
        },
        .hexagon => {
            // Flat-sided hexagon: pointed left and right, flat top and bottom
            const dx = w / 4;
            var pts_buf: [256]u8 = undefined;
            const pts = try std.fmt.bufPrint(&pts_buf,
                "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                .{ x + dx, y, x + w - dx, y, x + w, cy, x + w - dx, y + h, x + dx, y + h, x, cy });
            try svg.polygon(pts, theme.node_fill, theme.node_stroke, theme.node_stroke_width);
        },
        .cylinder => {
            // Cylinder: rect body with elliptical top cap
            const ry: f32 = h * 0.18;
            // Body rect (below top cap center)
            try svg.rect(x, y + ry, w, h - ry, 0, theme.node_fill, theme.node_stroke, theme.node_stroke_width);
            // Top ellipse (drawn last to cover the top edge of the rect)
            var buf: [384]u8 = undefined;
            const top_ellipse = try std.fmt.bufPrint(&buf,
                "<ellipse cx=\"{d:.1}\" cy=\"{d:.1}\" rx=\"{d:.1}\" ry=\"{d:.1}\" " ++
                "fill=\"{s}\" stroke=\"{s}\" stroke-width=\"{d:.1}\"/>\n",
                .{ cx, y + ry, w / 2, ry, theme.node_fill, theme.node_stroke, theme.node_stroke_width });
            try svg.raw(top_ellipse);
            // Bottom arc (stroke only, lower half of ellipse)
            const bot_d = try std.fmt.bufPrint(&buf,
                "M {d:.1},{d:.1} A {d:.1},{d:.1},0,0,1,{d:.1},{d:.1}",
                .{ x, y + h - ry, w / 2, ry, x + w, y + h - ry });
            try svg.path(bot_d, "none", theme.node_stroke, theme.node_stroke_width, "");
        },
        .subroutine => {
            // Rect with inner vertical lines near left and right edges
            try svg.rect(x, y, w, h, 0, theme.node_fill, theme.node_stroke, theme.node_stroke_width);
            const inset: f32 = 8.0;
            try svg.line(x + inset, y, x + inset, y + h, theme.node_stroke, theme.node_stroke_width);
            try svg.line(x + w - inset, y, x + w - inset, y + h, theme.node_stroke, theme.node_stroke_width);
        },
        .parallelogram => {
            // Slanted parallelogram (slant to the right)
            const slant: f32 = h * 0.3;
            var pts_buf: [256]u8 = undefined;
            const pts = try std.fmt.bufPrint(&pts_buf,
                "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                .{ x + slant, y, x + w, y, x + w - slant, y + h, x, y + h });
            try svg.polygon(pts, theme.node_fill, theme.node_stroke, theme.node_stroke_width);
        },
        .asymmetric => {
            // Flag/arrow shape: rectangle with a pointed right side notch on left
            const notch: f32 = h * 0.35;
            var pts_buf: [256]u8 = undefined;
            const pts = try std.fmt.bufPrint(&pts_buf,
                "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                .{ x, y, x + w, y, x + w, y + h, x, y + h, x + notch, cy });
            try svg.polygon(pts, theme.node_fill, theme.node_stroke, theme.node_stroke_width);
        },
        .ellipse => {
            var buf: [256]u8 = undefined;
            const ellipse_svg = try std.fmt.bufPrint(&buf,
                "<ellipse cx=\"{d:.1}\" cy=\"{d:.1}\" rx=\"{d:.1}\" ry=\"{d:.1}\" " ++
                "fill=\"{s}\" stroke=\"{s}\" stroke-width=\"{d:.1}\"/>\n",
                .{ cx, cy, w / 2, h / 2, theme.node_fill, theme.node_stroke, theme.node_stroke_width });
            try svg.raw(ellipse_svg);
        },
        else => {
            try svg.rect(x, y, w, h, 4.0, theme.node_fill, theme.node_stroke, theme.node_stroke_width);
        },
    }

    // Node label
    try svg.text(cx, cy + 4, n.label, theme.text_color, theme.font_size, .middle, "normal");
}

fn renderFallback(allocator: std.mem.Allocator, msg: []const u8) ![]const u8 {
    var svg = SvgWriter.init(allocator);
    defer svg.deinit();
    try svg.header(400, 200);
    try svg.text(200, 100, msg, theme.text_color, theme.font_size, .middle, "normal");
    try svg.footer();
    return svg.toOwnedSlice();
}

fn findNode(nodes: []layout.GraphNode, id: []const u8) ?*layout.GraphNode {
    for (nodes) |*n| {
        if (std.mem.eql(u8, n.id, id)) return n;
    }
    return null;
}

fn parseShape(s: []const u8) layout.NodeShape {
    if (std.mem.eql(u8, s, "diamond")) return .diamond;
    if (std.mem.eql(u8, s, "circle")) return .circle;
    if (std.mem.eql(u8, s, "stadium")) return .stadium;
    if (std.mem.eql(u8, s, "round")) return .round;
    if (std.mem.eql(u8, s, "subroutine")) return .subroutine;
    if (std.mem.eql(u8, s, "cylinder")) return .cylinder;
    if (std.mem.eql(u8, s, "hexagon")) return .hexagon;
    if (std.mem.eql(u8, s, "ellipse")) return .ellipse;
    if (std.mem.eql(u8, s, "parallelogram")) return .parallelogram;
    if (std.mem.eql(u8, s, "asymmetric")) return .asymmetric;
    return .rect;
}

fn parseEdgeStyle(s: []const u8) layout.EdgeStyle {
    if (std.mem.eql(u8, s, "dotted")) return .dotted;
    if (std.mem.eql(u8, s, "thick")) return .thick;
    return .solid;
}

fn parseDirection(s: []const u8) layout.Direction {
    if (std.mem.eql(u8, s, "LR")) return .lr;
    if (std.mem.eql(u8, s, "RL")) return .rl;
    if (std.mem.eql(u8, s, "BT")) return .bt;
    return .tb;
}
