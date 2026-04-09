//! Quadrant chart SVG renderer.
//! Expects a Value.node with axis label strings (`x_left`, `x_right`, `y_bottom`,
//! `y_top`), quadrant label strings (`q1` to `q4`), optional `title`, and `points`
//! (list of nodes with `label`, `x`, and `y` in the [0, 1] normalised range).
const std = @import("std");
const Value = @import("../diagram/value.zig").Value;
const SvgWriter = @import("../svg/writer.zig").SvgWriter;
const theme = @import("../svg/theme.zig");

const MARGIN: f32 = 70;
const TITLE_H: f32 = 40;
const PLOT_SIZE: f32 = 440;
const TOTAL_W: u32 = 580;
const TOTAL_H: u32 = 580;

/// Render a quadrant chart SVG from `value`.
/// `value` must be a node with axis strings (`x_left`, `x_right`, `y_bottom`, `y_top`),
/// quadrant label strings (`q1` to `q4`), optional `title`, and `points` (list of nodes
/// with `label` and `x`/`y` coordinates normalised to [0, 1]).
pub fn render(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    const node = value.asNode() orelse return renderFallback(allocator);

    const title = node.getString("title") orelse "";
    const x_left = node.getString("x_left") orelse "";
    const x_right = node.getString("x_right") orelse "";
    const y_bottom = node.getString("y_bottom") orelse "";
    const y_top = node.getString("y_top") orelse "";
    const q1 = node.getString("q1") orelse "";
    const q2 = node.getString("q2") orelse "";
    const q3 = node.getString("q3") orelse "";
    const q4 = node.getString("q4") orelse "";
    const points = node.getList("points");

    var svg = SvgWriter.init(allocator);
    defer svg.deinit();

    try svg.header(TOTAL_W, TOTAL_H);
    try svg.rect(0, 0, @floatFromInt(TOTAL_W), @floatFromInt(TOTAL_H), 0, theme.background, theme.background, 0);

    // Title
    if (title.len > 0) {
        try svg.text(@as(f32, @floatFromInt(TOTAL_W)) / 2, TITLE_H / 2 + 10,
            title, theme.text_color, theme.font_size + 2, .middle, "bold");
    }

    const plot_x = MARGIN;
    const plot_y = TITLE_H;
    const mid_x = plot_x + PLOT_SIZE / 2;
    const mid_y = plot_y + PLOT_SIZE / 2;

    // Plot border
    try svg.rect(plot_x, plot_y, PLOT_SIZE, PLOT_SIZE, 0, "#fafafa", "#cccccc", 1.0);

    // Midlines
    try svg.line(mid_x, plot_y, mid_x, plot_y + PLOT_SIZE, "#cccccc", 1.0);
    try svg.line(plot_x, mid_y, plot_x + PLOT_SIZE, mid_y, "#cccccc", 1.0);

    // Quadrant labels (centered in each quadrant)
    const q_label_color = "#aaaaaa";
    const qfs = theme.font_size_small;
    // Q2 top-left
    try svg.text(plot_x + PLOT_SIZE / 4, plot_y + PLOT_SIZE / 4, q2, q_label_color, qfs, .middle, "normal");
    // Q1 top-right
    try svg.text(plot_x + PLOT_SIZE * 3 / 4, plot_y + PLOT_SIZE / 4, q1, q_label_color, qfs, .middle, "normal");
    // Q3 bottom-left
    try svg.text(plot_x + PLOT_SIZE / 4, plot_y + PLOT_SIZE * 3 / 4, q3, q_label_color, qfs, .middle, "normal");
    // Q4 bottom-right
    try svg.text(plot_x + PLOT_SIZE * 3 / 4, plot_y + PLOT_SIZE * 3 / 4, q4, q_label_color, qfs, .middle, "normal");

    // Axis end labels
    try svg.text(plot_x + 4, plot_y + PLOT_SIZE + 16, x_left, theme.text_color, qfs, .start, "normal");
    try svg.text(plot_x + PLOT_SIZE, plot_y + PLOT_SIZE + 16, x_right, theme.text_color, qfs, .end, "normal");

    // Y-axis labels via raw SVG (rotated text)
    {
        var buf: [512]u8 = undefined;
        const yl_x = plot_x - 14;
        const yl_bot_y = plot_y + PLOT_SIZE;
        const yl_top_y = plot_y + 4;
        const frag_bot = try std.fmt.bufPrint(&buf,
            "<text x=\"{d:.1}\" y=\"{d:.1}\" fill=\"{s}\" font-size=\"{d}\" text-anchor=\"end\" " ++
            "font-family=\"trebuchet ms,verdana,arial,sans-serif\" " ++
            "transform=\"rotate(-90 {d:.1} {d:.1})\">{s}</text>\n",
            .{ yl_x, yl_bot_y, theme.text_color, qfs, yl_x, yl_bot_y, y_bottom });
        try svg.raw(frag_bot);
        const frag_top = try std.fmt.bufPrint(&buf,
            "<text x=\"{d:.1}\" y=\"{d:.1}\" fill=\"{s}\" font-size=\"{d}\" text-anchor=\"end\" " ++
            "font-family=\"trebuchet ms,verdana,arial,sans-serif\" " ++
            "transform=\"rotate(-90 {d:.1} {d:.1})\">{s}</text>\n",
            .{ yl_x, yl_top_y, theme.text_color, qfs, yl_x, yl_top_y, y_top });
        try svg.raw(frag_top);
    }

    // Points
    for (points, 0..) |pv, pi| {
        const pn = pv.asNode() orelse continue;
        const lbl = pn.getString("label") orelse "";
        const px_norm: f32 = @floatCast(pn.getNumber("x") orelse 0.5);
        const py_norm: f32 = @floatCast(pn.getNumber("y") orelse 0.5);
        const px = plot_x + std.math.clamp(px_norm, 0.0, 1.0) * PLOT_SIZE;
        const py = plot_y + (1.0 - std.math.clamp(py_norm, 0.0, 1.0)) * PLOT_SIZE;
        const color = theme.pie_colors[pi % theme.pie_colors.len];
        try svg.circle(px, py, 5.0, color, theme.background, 1.5);
        try svg.text(px + 8, py + 4, lbl, theme.text_color, qfs, .start, "normal");
    }

    try svg.footer();
    return svg.toOwnedSlice();
}

fn renderFallback(allocator: std.mem.Allocator) ![]const u8 {
    var svg = SvgWriter.init(allocator);
    defer svg.deinit();
    try svg.header(400, 200);
    try svg.text(200, 100, "quadrantChart", theme.text_color, theme.font_size, .middle, "normal");
    try svg.footer();
    return svg.toOwnedSlice();
}
