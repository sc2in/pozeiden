//! XY chart (bar/line) SVG renderer.
//! Expects a Value.node with `title`, `y_min`, `y_max`, `x_labels` (list of strings),
//! and `series` (list of nodes with `kind` ("bar" or "line") and `values`, a list of
//! numbers). Multiple bar series are grouped side-by-side; line series are drawn as
//! connected polylines with dot markers.
const std = @import("std");
const Value = @import("../diagram/value.zig").Value;
const SvgWriter = @import("../svg/writer.zig").SvgWriter;
const theme = @import("../svg/theme.zig");

const MARGIN_L: f32 = 60;
const MARGIN_R: f32 = 20;
const MARGIN_T: f32 = 20;
const TITLE_H: f32 = 36;
const CHART_H: f32 = 300;
const AXIS_H: f32 = 30;
const MARGIN_B: f32 = 20;
const COL_W: f32 = 90;
const BAR_PAD: f32 = 8;
const GRID_LINES: usize = 5;

/// Render an XY chart (bar or line) SVG from `value`.
/// `value` must be a node with `title`, `y_min`, `y_max`, `x_labels` (list of strings),
/// and `series` (list of nodes with `kind` ("bar"/"line") and `values`, a number list).
/// Bar series are grouped side-by-side per category; line series render as connected dots.
pub fn render(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    const node = value.asNode() orelse return renderFallback(allocator);

    const title = node.getString("title") orelse "";
    const y_min: f32 = @floatCast(node.getNumber("y_min") orelse 0.0);
    const y_max_raw: f32 = @floatCast(node.getNumber("y_max") orelse 100.0);
    const y_max: f32 = if (y_max_raw <= y_min) y_min + 100.0 else y_max_raw;
    const y_range: f32 = y_max - y_min;

    const x_labels = node.getList("x_labels");
    const series_list = node.getList("series");

    if (x_labels.len == 0 and series_list.len == 0) return renderFallback(allocator);

    const n_cats: usize = if (x_labels.len > 0) x_labels.len else blk: {
        var mx: usize = 0;
        for (series_list) |sv| {
            const sn = sv.asNode() orelse continue;
            const vl = sn.getList("values");
            if (vl.len > mx) mx = vl.len;
        }
        break :blk mx;
    };
    if (n_cats == 0) return renderFallback(allocator);

    const chart_w = @as(f32, @floatFromInt(n_cats)) * COL_W;
    const total_w: u32 = @intFromFloat(MARGIN_L + chart_w + MARGIN_R);
    const total_h: u32 = @intFromFloat(MARGIN_T + TITLE_H + CHART_H + AXIS_H + MARGIN_B);

    const chart_x = MARGIN_L;           // left edge of chart area
    const chart_top = MARGIN_T + TITLE_H;
    const chart_bot = chart_top + CHART_H;

    var svg = SvgWriter.init(allocator);
    defer svg.deinit();

    try svg.header(total_w, total_h);
    try svg.rect(0, 0, @floatFromInt(total_w), @floatFromInt(total_h), 0, theme.background, theme.background, 0);

    // Title
    if (title.len > 0) {
        try svg.text(@as(f32, @floatFromInt(total_w)) / 2, MARGIN_T + TITLE_H / 2 + 5,
            title, theme.text_color, theme.font_size + 2, .middle, "bold");
    }

    // Grid lines + Y-axis labels
    for (0..GRID_LINES + 1) |gi| {
        const t = @as(f32, @floatFromInt(gi)) / @as(f32, @floatFromInt(GRID_LINES));
        const gy = chart_bot - t * CHART_H;
        const gv = y_min + t * y_range;
        try svg.dashedLine(chart_x, gy, chart_x + chart_w, gy, "#dddddd", 1.0, "4,3");
        var buf: [32]u8 = undefined;
        const lbl = std.fmt.bufPrint(&buf, "{d:.0}", .{gv}) catch "?";
        try svg.text(chart_x - 6, gy + 4, lbl, theme.text_color, theme.font_size_small, .end, "normal");
    }

    // Axes
    try svg.line(chart_x, chart_top, chart_x, chart_bot, theme.line_color, 1.5);
    try svg.line(chart_x, chart_bot, chart_x + chart_w, chart_bot, theme.line_color, 1.5);

    // X-axis labels + tick marks
    for (0..n_cats) |ci| {
        const cx = chart_x + (@as(f32, @floatFromInt(ci)) + 0.5) * COL_W;
        try svg.line(cx, chart_bot, cx, chart_bot + 4, theme.line_color, 1.0);
        const lbl = if (ci < x_labels.len) x_labels[ci].asString() orelse "" else "";
        try svg.text(cx, chart_bot + AXIS_H - 6, lbl, theme.text_color, theme.font_size_small, .middle, "normal");
    }

    // Count bar series for side-by-side grouping
    var n_bar_series: usize = 0;
    for (series_list) |sv| {
        const sn = sv.asNode() orelse continue;
        const kind = sn.getString("kind") orelse "";
        if (std.mem.eql(u8, kind, "bar")) n_bar_series += 1;
    }

    // Draw series
    var color_idx: usize = 0;
    var bar_series_idx: usize = 0;
    for (series_list) |sv| {
        const sn = sv.asNode() orelse continue;
        const kind = sn.getString("kind") orelse "bar";
        const vals = sn.getList("values");
        const color = theme.pie_colors[color_idx % theme.pie_colors.len];
        color_idx += 1;

        if (std.mem.eql(u8, kind, "bar")) {
            const group_w = COL_W - BAR_PAD * 2;
            const bar_w = if (n_bar_series > 1)
                group_w / @as(f32, @floatFromInt(n_bar_series))
            else
                group_w;

            for (vals, 0..) |vv, ci| {
                const v: f32 = @floatCast(vv.asNumber() orelse 0.0);
                const norm = std.math.clamp((v - y_min) / y_range, 0.0, 1.0);
                const bh = norm * CHART_H;
                const bx = chart_x + @as(f32, @floatFromInt(ci)) * COL_W + BAR_PAD +
                    @as(f32, @floatFromInt(bar_series_idx)) * bar_w;
                const by = chart_bot - bh;
                try svg.rect(bx, by, bar_w, bh, 2.0, color, "none", 0);
            }
            bar_series_idx += 1;
        } else if (std.mem.eql(u8, kind, "line")) {
            // Build polyline path
            var path_buf: std.ArrayList(u8) = .empty;
            defer path_buf.deinit(allocator);

            for (vals, 0..) |vv, ci| {
                const v: f32 = @floatCast(vv.asNumber() orelse 0.0);
                const norm = std.math.clamp((v - y_min) / y_range, 0.0, 1.0);
                const px = chart_x + (@as(f32, @floatFromInt(ci)) + 0.5) * COL_W;
                const py = chart_bot - norm * CHART_H;
                if (ci == 0) {
                    try path_buf.writer(allocator).print("M {d:.1},{d:.1}", .{ px, py });
                } else {
                    try path_buf.writer(allocator).print(" L {d:.1},{d:.1}", .{ px, py });
                }
                try svg.circle(px, py, 3.5, color, theme.background, 1.5);
            }

            if (path_buf.items.len > 0) {
                try svg.path(path_buf.items, "none", color, 2.0, "");
            }
        }
    }

    try svg.footer();
    return svg.toOwnedSlice();
}

fn renderFallback(allocator: std.mem.Allocator) ![]const u8 {
    var svg = SvgWriter.init(allocator);
    defer svg.deinit();
    try svg.header(400, 200);
    try svg.text(200, 100, "xychart-beta", theme.text_color, theme.font_size, .middle, "normal");
    try svg.footer();
    return svg.toOwnedSlice();
}
