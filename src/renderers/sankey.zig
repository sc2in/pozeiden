//! Sankey diagram SVG renderer (simplified column layout with Bezier bands).
//! Expects a Value.node with `flows` (list of nodes each carrying `from`, `to`,
//! and numeric `value`). Node depths are inferred by iterative relaxation; columns
//! are stacked vertically and flows are drawn as semi-transparent cubic Bezier bands.
const std = @import("std");
const Value = @import("../diagram/value.zig").Value;
const SvgWriter = @import("../svg/writer.zig").SvgWriter;
const theme = @import("../svg/theme.zig");

const NODE_W: f32 = 20;
const COL_GAP: f32 = 160;
const CHART_H: f32 = 400;
const MARGIN: f32 = 40;
const LABEL_PAD: f32 = 6;
const NODE_GAP: f32 = 8;
const MIN_BAND_H: f32 = 2;

const Flow = struct {
    from: []const u8,
    to: []const u8,
    value: f32,
};

/// Render a Sankey diagram SVG from `value`.
/// `value` must be a node with `flows` (list of nodes each carrying string fields
/// `from` and `to` and a numeric `value`). Node column depths are inferred automatically;
/// flows are drawn as semi-transparent cubic Bezier bands proportional to their value.
pub fn render(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    const node = value.asNode() orelse return renderFallback(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const flow_list = node.getList("flows");
    if (flow_list.len == 0) return renderFallback(allocator);

    // Collect unique node names in order
    var name_map = std.StringArrayHashMap(void).init(a);
    var flows: std.ArrayList(Flow) = .empty;

    for (flow_list) |fv| {
        const fn2 = fv.asNode() orelse continue;
        const from = fn2.getString("from") orelse continue;
        const to = fn2.getString("to") orelse continue;
        const val: f32 = @floatCast(fn2.getNumber("value") orelse 0.0);
        if (val <= 0) continue;
        try name_map.put(from, {});
        try name_map.put(to, {});
        try flows.append(a, .{ .from = from, .to = to, .value = val });
    }

    const names = name_map.keys();
    const n_nodes = names.len;
    if (n_nodes == 0) return renderFallback(allocator);

    // Assign depths via iterative relaxation (max 20 passes)
    var depths = try a.alloc(usize, n_nodes);
    @memset(depths, 0);
    for (0..20) |_| {
        var changed = false;
        for (flows.items) |fl| {
            const fi = name_map.getIndex(fl.from) orelse continue;
            const ti = name_map.getIndex(fl.to) orelse continue;
            if (depths[ti] <= depths[fi]) {
                depths[ti] = depths[fi] + 1;
                changed = true;
            }
        }
        if (!changed) break;
    }

    var max_depth: usize = 0;
    for (depths) |d| { if (d > max_depth) max_depth = d; }
    const n_cols = max_depth + 1;

    // Compute total flow per node (max of in/out)
    var total_out = try a.alloc(f32, n_nodes);
    var total_in = try a.alloc(f32, n_nodes);
    @memset(total_out, 0);
    @memset(total_in, 0);
    for (flows.items) |fl| {
        const fi = name_map.getIndex(fl.from) orelse continue;
        const ti = name_map.getIndex(fl.to) orelse continue;
        total_out[fi] += fl.value;
        total_in[ti] += fl.value;
    }
    var node_flow = try a.alloc(f32, n_nodes);
    for (0..n_nodes) |ni| {
        node_flow[ni] = @max(total_out[ni], total_in[ni]);
    }

    // Find max column total flow to normalize heights
    var col_total = try a.alloc(f32, n_cols);
    @memset(col_total, 0);
    for (0..n_nodes) |ni| {
        col_total[depths[ni]] += node_flow[ni];
    }
    var max_col_total: f32 = 0;
    for (col_total) |ct| { if (ct > max_col_total) max_col_total = ct; }
    if (max_col_total <= 0) max_col_total = 1;

    // Node positions: stack within column
    var node_x = try a.alloc(f32, n_nodes);
    var node_y = try a.alloc(f32, n_nodes);
    var node_h = try a.alloc(f32, n_nodes);

    // Count nodes per column
    var col_nodes = try a.alloc(std.ArrayList(usize), n_cols);
    for (0..n_cols) |ci| {
        col_nodes[ci] = .empty;
    }
    for (0..n_nodes) |ni| {
        try col_nodes[depths[ni]].append(a, ni);
    }

    for (0..n_cols) |ci| {
        const col_x = MARGIN + @as(f32, @floatFromInt(ci)) * (NODE_W + COL_GAP);
        const indices = col_nodes[ci].items;
        const n_in_col = indices.len;
        if (n_in_col == 0) continue;

        // Compute heights proportional to flow
        var col_h_total: f32 = 0;
        for (indices) |ni| {
            const h = @max(MIN_BAND_H, node_flow[ni] / max_col_total * CHART_H);
            node_h[ni] = h;
            col_h_total += h;
        }
        const gap_total = NODE_GAP * @as(f32, @floatFromInt(if (n_in_col > 0) n_in_col - 1 else 0));
        const used = col_h_total + gap_total;
        const start_y = MARGIN + (CHART_H - used) / 2;

        var cur_y = start_y;
        for (indices) |ni| {
            node_x[ni] = col_x;
            node_y[ni] = cur_y;
            cur_y += node_h[ni] + NODE_GAP;
        }
    }

    // Compute canvas size
    const total_w: u32 = @intFromFloat(
        MARGIN * 2 + @as(f32, @floatFromInt(n_cols)) * NODE_W +
        @as(f32, @floatFromInt(if (n_cols > 1) n_cols - 1 else 0)) * COL_GAP + 80
    );
    const total_h: u32 = @intFromFloat(MARGIN * 2 + CHART_H);

    var svg = SvgWriter.init(allocator);
    defer svg.deinit();

    try svg.header(total_w, total_h);
    try svg.rect(0, 0, @floatFromInt(total_w), @floatFromInt(total_h), 0, theme.background, theme.background, 0);

    // Draw Bezier flow bands
    // Track outflow/inflow offsets per node
    var out_offset = try a.alloc(f32, n_nodes);
    var in_offset = try a.alloc(f32, n_nodes);
    @memset(out_offset, 0);
    @memset(in_offset, 0);

    for (flows.items, 0..) |fl, fi_idx| {
        const fi = name_map.getIndex(fl.from) orelse continue;
        const ti = name_map.getIndex(fl.to) orelse continue;

        const band_h = @max(MIN_BAND_H, fl.value / max_col_total * CHART_H);
        const color = theme.pie_colors[fi_idx % theme.pie_colors.len];

        const ax = node_x[fi] + NODE_W;
        const ay1 = node_y[fi] + out_offset[fi];
        const ay2 = ay1 + band_h;
        out_offset[fi] += band_h;

        const bx = node_x[ti];
        const by1 = node_y[ti] + in_offset[ti];
        const by2 = by1 + band_h;
        in_offset[ti] += band_h;

        const mid_x = (ax + bx) / 2;

        var path_buf: [512]u8 = undefined;
        const d = try std.fmt.bufPrint(&path_buf,
            "M {d:.1},{d:.1} C {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} " ++
            "L {d:.1},{d:.1} C {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} Z",
            .{
                ax, ay1,  mid_x, ay1,  mid_x, by1,  bx, by1,
                bx, by2,  mid_x, by2,  mid_x, ay2,  ax, ay2,
            });
        try svg.path(d, color, "none", 0, "fill-opacity=\"0.45\"");
    }

    // Draw node rects
    for (0..n_nodes) |ni| {
        const color = theme.pie_colors[ni % theme.pie_colors.len];
        try svg.rect(node_x[ni], node_y[ni], NODE_W, node_h[ni], 2, color, "none", 0);
    }

    // Draw labels
    for (0..n_nodes) |ni| {
        const name = names[ni];
        const is_source = total_in[ni] == 0;
        const is_sink = total_out[ni] == 0;
        const label_x = if (is_source)
            node_x[ni] - LABEL_PAD
        else if (is_sink)
            node_x[ni] + NODE_W + LABEL_PAD
        else
            node_x[ni] + NODE_W + LABEL_PAD;
        const anchor: SvgWriter.TextAnchor = if (is_source) .end else .start;
        const label_y = node_y[ni] + node_h[ni] / 2 + 4;
        try svg.text(label_x, label_y, name, theme.text_color, theme.font_size_small, anchor, "normal");
    }

    try svg.footer();
    return svg.toOwnedSlice();
}

fn renderFallback(allocator: std.mem.Allocator) ![]const u8 {
    var svg = SvgWriter.init(allocator);
    defer svg.deinit();
    try svg.header(400, 200);
    try svg.text(200, 100, "sankey-beta", theme.text_color, theme.font_size, .middle, "normal");
    try svg.footer();
    return svg.toOwnedSlice();
}
