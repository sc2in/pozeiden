//! Mindmap SVG renderer (radial tree layout).
//! Expects a Value.node with a `nodes` list; the first entry is the root node.
//! Each node has `label`, `shape` (circle/rect/rounded/hexagon/ellipse), and a
//! recursive `children` list. Positions are computed via proportional sector division.
const std = @import("std");
const Value = @import("../diagram/value.zig").Value;
const SvgWriter = @import("../svg/writer.zig").SvgWriter;
const theme = @import("../svg/theme.zig");

const LEVEL_RADIUS: f32 = 130;
const ROOT_R: f32 = 42;
const NODE_W: f32 = 88;
const NODE_H: f32 = 28;
const MARGIN: f32 = 60;

const MmShape = enum { circle, rect, rounded, hexagon, ellipse };

const MmNode = struct {
    label: []const u8,
    shape: MmShape,
    depth: usize,
    parent: usize, // index into flat array; root has parent = maxInt
    children_start: usize = 0,
    children_end: usize = 0,
    // layout
    x: f32 = 0,
    y: f32 = 0,
    leaf_count: usize = 1,
};

/// Render a mindmap SVG from `value`.
/// `value` must be a node with a `nodes` list whose first entry is the root; each node
/// carries `label`, `shape` (circle/rect/rounded/hexagon/ellipse), and a recursive
/// `children` list. Positions are assigned via radial proportional sector subdivision.
pub fn render(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    const node = value.asNode() orelse return renderFallback(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Flatten the recursive value tree into an array of MmNode
    var flat: std.ArrayList(MmNode) = .empty;
    const root_list = node.getList("nodes");
    if (root_list.len == 0) return renderFallback(allocator);

    try flattenNode(a, &flat, root_list[0], std.math.maxInt(usize), 0);
    if (flat.items.len == 0) return renderFallback(allocator);

    // Build children_start/end ranges (children follow parents depth-first)
    // The flattenNode DFS ensures children are laid out consecutively after parent.
    // We need to record for each node the range of its children in the flat array.
    // flattenNode already fills parent index. Rebuild children ranges.
    for (flat.items, 0..) |*mn, i| {
        mn.children_start = i + 1;
        mn.children_end = i + 1;
    }
    // Walk backwards: for each node, extend parent's children_end
    var i: usize = flat.items.len;
    while (i > 0) {
        i -= 1;
        const parent_idx = flat.items[i].parent;
        if (parent_idx != std.math.maxInt(usize)) {
            if (flat.items[parent_idx].children_end <= i) {
                flat.items[parent_idx].children_end = i + 1;
            }
        }
    }

    // Compute leaf_count bottom-up
    var j: usize = flat.items.len;
    while (j > 0) {
        j -= 1;
        const mn = &flat.items[j];
        if (mn.children_start == mn.children_end) {
            mn.leaf_count = 1;
        } else {
            var lc: usize = 0;
            var ci = mn.children_start;
            while (ci < mn.children_end) {
                // Only direct children (depth = mn.depth + 1)
                if (flat.items[ci].depth == mn.depth + 1) {
                    lc += flat.items[ci].leaf_count;
                }
                ci += 1;
            }
            mn.leaf_count = if (lc > 0) lc else 1;
        }
    }

    // Find max depth
    var max_depth: usize = 0;
    for (flat.items) |mn| {
        if (mn.depth > max_depth) max_depth = mn.depth;
    }

    const canvas_r = @as(f32, @floatFromInt(max_depth + 1)) * LEVEL_RADIUS + NODE_W + MARGIN;
    const total_dim: u32 = @intFromFloat(canvas_r * 2);
    const cx = canvas_r;
    const cy = canvas_r;

    // Layout: assign positions using radial sector recursion
    flat.items[0].x = cx;
    flat.items[0].y = cy;
    layoutChildren(flat.items, 0, cx, cy, 0.0, std.math.tau);

    var svg = SvgWriter.init(allocator);
    defer svg.deinit();

    try svg.header(total_dim, total_dim);
    try svg.rect(0, 0, @floatFromInt(total_dim), @floatFromInt(total_dim), 0, theme.background, theme.background, 0);

    // Draw edges first
    for (flat.items) |mn| {
        if (mn.parent == std.math.maxInt(usize)) continue;
        const parent = flat.items[mn.parent];
        try svg.line(parent.x, parent.y, mn.x, mn.y, "#cccccc", 1.5);
    }

    // Draw nodes
    for (flat.items) |mn| {
        const color = theme.pie_colors[mn.depth % theme.pie_colors.len];
        try drawNode(&svg, mn.x, mn.y, mn.label, mn.shape, mn.depth, color, allocator);
    }

    try svg.footer();
    return svg.toOwnedSlice();
}

fn flattenNode(
    a: std.mem.Allocator,
    flat: *std.ArrayList(MmNode),
    value: Value,
    parent_idx: usize,
    depth: usize,
) !void {
    const n = value.asNode() orelse return;
    const label = n.getString("label") orelse "";
    const shape_str = n.getString("shape") orelse "ellipse";
    const shape = parseShape(shape_str);
    const my_idx = flat.items.len;
    try flat.append(a, .{
        .label = label,
        .shape = shape,
        .depth = depth,
        .parent = parent_idx,
    });
    for (n.getList("children")) |child| {
        try flattenNode(a, flat, child, my_idx, depth + 1);
    }
}

fn layoutChildren(
    nodes: []MmNode,
    parent_idx: usize,
    px: f32,
    py: f32,
    angle_start: f32,
    angle_end: f32,
) void {
    const parent = &nodes[parent_idx];
    const depth = parent.depth;
    const r = @as(f32, @floatFromInt(depth + 1)) * LEVEL_RADIUS;

    var cur_angle = angle_start;
    var ci = parent.children_start;
    while (ci < parent.children_end) : (ci += 1) {
        if (nodes[ci].depth != depth + 1) continue;
        const child_leaves = @as(f32, @floatFromInt(nodes[ci].leaf_count));
        const parent_leaves = @as(f32, @floatFromInt(parent.leaf_count));
        const sector = (angle_end - angle_start) * (child_leaves / parent_leaves);
        const mid_angle = cur_angle + sector / 2;
        nodes[ci].x = px + r * @cos(mid_angle);
        nodes[ci].y = py + r * @sin(mid_angle);
        layoutChildren(nodes, ci, px, py, cur_angle, cur_angle + sector);
        cur_angle += sector;
    }
}

fn drawNode(svg: *SvgWriter, x: f32, y: f32, label: []const u8, shape: MmShape, depth: usize, color: []const u8, allocator: std.mem.Allocator) !void {
    _ = allocator;
    const text_color = if (depth == 0) theme.background else theme.text_color;
    const fill = if (depth == 0) color else theme.background;
    const stroke = color;

    switch (shape) {
        .circle => {
            const r = if (depth == 0) ROOT_R else NODE_H / 2 + 4;
            try svg.circle(x, y, r, fill, stroke, 2.0);
            try svg.text(x, y + 4, label, text_color, theme.font_size_small, .middle, "normal");
        },
        .rect => {
            try svg.rect(x - NODE_W / 2, y - NODE_H / 2, NODE_W, NODE_H, 0, fill, stroke, 1.5);
            try svg.text(x, y + 4, label, theme.text_color, theme.font_size_small, .middle, "normal");
        },
        .rounded => {
            try svg.rect(x - NODE_W / 2, y - NODE_H / 2, NODE_W, NODE_H, 8, fill, stroke, 1.5);
            try svg.text(x, y + 4, label, theme.text_color, theme.font_size_small, .middle, "normal");
        },
        .hexagon => {
            const hw = NODE_W / 2;
            const hh = NODE_H / 2;
            const indent = hh * 0.6;
            var pts_buf: [256]u8 = undefined;
            const pts = try std.fmt.bufPrint(&pts_buf,
                "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                .{
                    x - hw,         y,
                    x - hw + indent, y - hh,
                    x + hw - indent, y - hh,
                    x + hw,          y,
                    x + hw - indent, y + hh,
                    x - hw + indent, y + hh,
                });
            try svg.polygon(pts, fill, stroke, 1.5);
            try svg.text(x, y + 4, label, theme.text_color, theme.font_size_small, .middle, "normal");
        },
        .ellipse => {
            // SVG arc-based ellipse via path
            const rx = NODE_W / 2;
            const ry = NODE_H / 2 + 2;
            var path_buf: [256]u8 = undefined;
            const d = try std.fmt.bufPrint(&path_buf,
                "M {d:.1},{d:.1} A {d:.1},{d:.1} 0 1 0 {d:.1},{d:.1} A {d:.1},{d:.1} 0 1 0 {d:.1},{d:.1} Z",
                .{ x - rx, y, rx, ry, x + rx, y, rx, ry, x - rx, y });
            try svg.path(d, fill, stroke, 1.5, "");
            try svg.text(x, y + 4, label, theme.text_color, theme.font_size_small, .middle, "normal");
        },
    }
}

fn parseShape(s: []const u8) MmShape {
    if (std.mem.eql(u8, s, "circle")) return .circle;
    if (std.mem.eql(u8, s, "rect")) return .rect;
    if (std.mem.eql(u8, s, "rounded")) return .rounded;
    if (std.mem.eql(u8, s, "hexagon")) return .hexagon;
    return .ellipse;
}

fn renderFallback(allocator: std.mem.Allocator) ![]const u8 {
    var svg = SvgWriter.init(allocator);
    defer svg.deinit();
    try svg.header(400, 200);
    try svg.text(200, 100, "mindmap", theme.text_color, theme.font_size, .middle, "normal");
    try svg.footer();
    return svg.toOwnedSlice();
}
