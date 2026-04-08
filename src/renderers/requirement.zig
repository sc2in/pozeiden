//! Requirement diagram SVG renderer.
//! Expects a Value.node with `requirements` (list of nodes with `id`, `name`, `text`,
//! `risk`, `verifyMethod`), `elements` (list of nodes with `name`, `type`, `docRef`),
//! and `relationships` (list of nodes with `from`, `to`, `kind`). Requirements and
//! elements are rendered as two-section boxes; relationships as labeled arrows.
const std = @import("std");
const Value = @import("../diagram/value.zig").Value;
const SvgWriter = @import("../svg/writer.zig").SvgWriter;
const theme = @import("../svg/theme.zig");

const NODE_W: f32 = 180;
const HEADER_H: f32 = 28;
const ATTR_H: f32 = 18;
const MARGIN: f32 = 40;
const COL_GAP: f32 = 80;
const ROW_GAP: f32 = 60;
const COLS: usize = 3;

/// Render a requirementDiagram SVG from `value`.
/// `value` must be a node with `requirements` (list of requirement nodes) and
/// `elements` (list of element nodes) with `relationships` (list of relationship nodes
/// each carrying `from`, `to`, and `kind`). Returns a caller-owned SVG string.
pub fn render(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    const node = value.asNode() orelse return renderFallback(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ReqNode = struct {
        name: []const u8,
        attrs: [][]const u8, // lines to display in body
        x: f32,
        y: f32,
        h: f32,
    };

    var nodes: std.ArrayList(ReqNode) = .empty;
    var node_map = std.StringArrayHashMap(usize).init(a);

    // Collect requirements
    for (node.getList("requirements")) |rv| {
        const rn = rv.asNode() orelse continue;
        const name = rn.getString("name") orelse continue;
        var attrs: std.ArrayList([]const u8) = .empty;
        if (rn.getString("id")) |v| try attrs.append(a, try std.fmt.allocPrint(a, "id: {s}", .{v}));
        if (rn.getString("text")) |v| try attrs.append(a, try std.fmt.allocPrint(a, "text: {s}", .{v}));
        if (rn.getString("risk")) |v| try attrs.append(a, try std.fmt.allocPrint(a, "risk: {s}", .{v}));
        if (rn.getString("verifyMethod")) |v| try attrs.append(a, try std.fmt.allocPrint(a, "verify: {s}", .{v}));
        const h = HEADER_H + @as(f32, @floatFromInt(attrs.items.len)) * ATTR_H + 6;
        try node_map.put(name, nodes.items.len);
        try nodes.append(a, ReqNode{ .name = name, .attrs = try attrs.toOwnedSlice(a), .x = 0, .y = 0, .h = h });
    }

    // Collect elements
    for (node.getList("elements")) |ev| {
        const en = ev.asNode() orelse continue;
        const name = en.getString("name") orelse continue;
        var attrs: std.ArrayList([]const u8) = .empty;
        if (en.getString("type")) |v| try attrs.append(a, try std.fmt.allocPrint(a, "type: {s}", .{v}));
        if (en.getString("docRef")) |v| try attrs.append(a, try std.fmt.allocPrint(a, "ref: {s}", .{v}));
        const h = HEADER_H + @as(f32, @floatFromInt(attrs.items.len)) * ATTR_H + 6;
        try node_map.put(name, nodes.items.len);
        try nodes.append(a, ReqNode{ .name = name, .attrs = try attrs.toOwnedSlice(a), .x = 0, .y = 0, .h = h });
    }

    if (nodes.items.len == 0) return renderFallback(allocator);

    // Assign grid positions
    var max_row_h = [_]f32{0.0} ** 64;
    for (nodes.items, 0..) |nd, i| {
        const row = i / COLS;
        if (row < 64 and nd.h > max_row_h[row]) max_row_h[row] = nd.h;
    }
    var row_y = [_]f32{0.0} ** 65;
    row_y[0] = MARGIN;
    const n_rows = (nodes.items.len + COLS - 1) / COLS;
    for (0..n_rows) |r| row_y[r + 1] = row_y[r] + max_row_h[r] + ROW_GAP;

    for (nodes.items, 0..) |*nd, i| {
        nd.x = MARGIN + @as(f32, @floatFromInt(i % COLS)) * (NODE_W + COL_GAP);
        nd.y = row_y[i / COLS];
    }

    const total_w: u32 = @intFromFloat(
        MARGIN * 2 + @as(f32, @floatFromInt(COLS)) * NODE_W + @as(f32, @floatFromInt(COLS - 1)) * COL_GAP
    );
    const total_h: u32 = @intFromFloat(row_y[n_rows] + MARGIN);

    var svg = SvgWriter.init(allocator);
    defer svg.deinit();

    try svg.header(total_w, total_h);
    try svg.rect(0, 0, @floatFromInt(total_w), @floatFromInt(total_h), 0, theme.background, theme.background, 0);

    // Draw relationships (behind nodes)
    for (node.getList("relationships")) |rv| {
        const rn = rv.asNode() orelse continue;
        const from_name = rn.getString("from") orelse continue;
        const to_name = rn.getString("to") orelse continue;
        const kind = rn.getString("kind") orelse "";

        const fi = node_map.get(from_name) orelse continue;
        const ti = node_map.get(to_name) orelse continue;
        const fn2 = nodes.items[fi];
        const tn = nodes.items[ti];

        const fx = fn2.x + NODE_W / 2;
        const fy = fn2.y + fn2.h / 2;
        const tx = tn.x + NODE_W / 2;
        const ty = tn.y + tn.h / 2;

        try svg.line(fx, fy, tx, ty, theme.line_color, 1.5);

        // Arrowhead
        const dx = tx - fx;
        const dy = ty - fy;
        const len = @sqrt(dx * dx + dy * dy);
        if (len > 1.0) {
            const ux = dx / len;
            const uy = dy / len;
            const arr: f32 = 8.0;
            const half: f32 = 4.5;
            var pts_buf: [128]u8 = undefined;
            const pts = try std.fmt.bufPrint(&pts_buf,
                "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                .{
                    tx - ux * arr - uy * half, ty - uy * arr + ux * half,
                    tx, ty,
                    tx - ux * arr + uy * half, ty - uy * arr - ux * half,
                });
            try svg.polygon(pts, theme.line_color, theme.line_color, 0);
        }

        // Relationship kind label at midpoint
        if (kind.len > 0) {
            try svg.text((fx + tx) / 2, (fy + ty) / 2 - 6, kind,
                theme.text_color, theme.font_size_small, .middle, "normal");
        }
    }

    // Draw node boxes
    for (nodes.items, 0..) |nd, ni| {
        const color = theme.pie_colors[ni % theme.pie_colors.len];
        // Outer box
        try svg.rect(nd.x, nd.y, NODE_W, nd.h, 4.0, theme.node_fill, color, 1.5);
        // Header band
        try svg.rect(nd.x, nd.y, NODE_W, HEADER_H, 4.0, color, color, 0);
        // Name in header
        try svg.text(nd.x + NODE_W / 2, nd.y + HEADER_H / 2 + 5,
            nd.name, theme.background, theme.font_size_small, .middle, "bold");
        // Attribute rows
        for (nd.attrs, 0..) |attr, ai| {
            const ay = nd.y + HEADER_H + 4 + @as(f32, @floatFromInt(ai)) * ATTR_H + ATTR_H / 2;
            // Truncate long attribute text
            const max_len: usize = 24;
            const display = if (attr.len > max_len) attr[0..max_len] else attr;
            try svg.text(nd.x + 6, ay, display, theme.text_color, theme.font_size_small, .start, "normal");
        }
    }

    try svg.footer();
    return svg.toOwnedSlice();
}

fn renderFallback(allocator: std.mem.Allocator) ![]const u8 {
    var svg = SvgWriter.init(allocator);
    defer svg.deinit();
    try svg.header(400, 200);
    try svg.text(200, 100, "requirementDiagram", theme.text_color, theme.font_size, .middle, "normal");
    try svg.footer();
    return svg.toOwnedSlice();
}
