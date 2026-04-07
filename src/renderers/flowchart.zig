//! Flowchart SVG renderer.
//! Builds a Graph from the Jison runtime's Value AST, runs layout, and emits SVG.
const std = @import("std");
const Value = @import("../diagram/value.zig").Value;
const SvgWriter = @import("../svg/writer.zig").SvgWriter;
const layout = @import("../svg/layout.zig");
const theme = @import("../svg/theme.zig");
const arrow_marker_defs = @import("../svg/writer.zig").arrow_marker_defs;

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

    // Draw edges first (behind nodes)
    for (graph.edges) |e| {
        const from_node = findNode(graph.nodes, e.from) orelse continue;
        const to_node = findNode(graph.nodes, e.to) orelse continue;

        const fx = from_node.x + from_node.w / 2;
        const fy = from_node.y + from_node.h;
        const tx = to_node.x + to_node.w / 2;
        const ty = to_node.y;

        const stroke = theme.edge_color;
        const sw = theme.edge_stroke_width;

        if (e.style == .dotted) {
            try svg.dashedLine(fx, fy, tx, ty, stroke, sw, "5,5");
        } else {
            try svg.line(fx, fy, tx, ty, stroke, sw);
        }

        // Arrowhead: draw a small triangle at (tx, ty)
        const arr_size: f32 = 8;
        var pts_buf: [128]u8 = undefined;
        const pts = try std.fmt.bufPrint(&pts_buf, "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
            .{ tx - arr_size / 2, ty - arr_size, tx + arr_size / 2, ty - arr_size, tx, ty });
        try svg.polygon(pts, stroke, stroke, 0);

        // Edge label
        if (e.label) |lbl| {
            try svg.text((fx + tx) / 2, (fy + ty) / 2 - 5, lbl, theme.text_color, theme.font_size_small, .middle, "normal");
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

    switch (n.shape) {
        .diamond => {
            // Diamond: rotated square
            const cx = x + w / 2;
            const cy = y + h / 2;
            var pts_buf: [256]u8 = undefined;
            const pts = try std.fmt.bufPrint(&pts_buf, "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                .{ cx, y, x + w, cy, cx, y + h, x, cy });
            try svg.polygon(pts, theme.node_fill, theme.node_stroke, theme.node_stroke_width);
        },
        .circle => {
            try svg.circle(x + w / 2, y + h / 2, h / 2, theme.node_fill, theme.node_stroke, theme.node_stroke_width);
        },
        .stadium => {
            try svg.rect(x, y, w, h, h / 2, theme.node_fill, theme.node_stroke, theme.node_stroke_width);
        },
        .round => {
            try svg.rect(x, y, w, h, 8.0, theme.node_fill, theme.node_stroke, theme.node_stroke_width);
        },
        else => {
            // Default: rect
            try svg.rect(x, y, w, h, 4.0, theme.node_fill, theme.node_stroke, theme.node_stroke_width);
        },
    }

    // Node label
    try svg.text(x + w / 2, y + h / 2 + 4, n.label, theme.text_color, theme.font_size, .middle, "normal");
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
