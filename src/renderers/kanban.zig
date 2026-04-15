//! Kanban board SVG renderer.
//! Expects a Value.node with `columns` (list of nodes with `label` and `items`, where
//! each item is a node with `id` and `label`). Columns are rendered side-by-side with
//! a header band and stacked card rectangles below.
const std = @import("std");
const Value = @import("../diagram/value.zig").Value;
const SvgWriter = @import("../svg/writer.zig").SvgWriter;
const theme = @import("../svg/theme.zig");

const COL_W: f32 = 180;
const COL_GAP: f32 = 16;
const HEADER_H: f32 = 36;
const CARD_H: f32 = 40;
const CARD_PAD: f32 = 8;
const MARGIN: f32 = 24;
const TITLE_H: f32 = 40;

/// Render a kanban board SVG from `value`.
/// `value` must be a node with optional `title` and `columns` (list of nodes with
/// `label` and `items` list where each item has `id` and `label`). Returns a
/// caller-owned SVG string.
pub fn render(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    const node = value.asNode() orelse return renderFallback(allocator);

    const title = node.getString("title") orelse "";
    const cols_val = node.getList("columns");
    if (cols_val.len == 0) return renderFallback(allocator);

    // Compute max items per column to determine height
    var max_items: usize = 0;
    for (cols_val) |cv| {
        const cn = cv.asNode() orelse continue;
        const n = cn.getList("items").len;
        if (n > max_items) max_items = n;
    }

    const n_cols: usize = cols_val.len;
    const title_offset: f32 = if (title.len > 0) TITLE_H else 0;
    const total_w: u32 = @intFromFloat(
        MARGIN * 2 + @as(f32, @floatFromInt(n_cols)) * COL_W +
        @as(f32, @floatFromInt(n_cols - 1)) * COL_GAP
    );
    const total_h: u32 = @intFromFloat(
        MARGIN + title_offset + HEADER_H +
        @as(f32, @floatFromInt(max_items)) * (CARD_H + CARD_PAD) + CARD_PAD + MARGIN
    );

    const col_colors = [_][]const u8{
        "#74c0fc", "#51cf66", "#ffd43b", "#ff6b6b",
        "#cc5de8", "#20c997", "#fd7e14", "#339af0",
    };

    var svg = SvgWriter.init(allocator);
    defer svg.deinit();

    try svg.header(total_w, total_h);
    try svg.rect(0, 0, @floatFromInt(total_w), @floatFromInt(total_h), 0, theme.background, theme.background, 0);

    // Title
    if (title.len > 0) {
        try svg.text(@as(f32, @floatFromInt(total_w)) / 2, MARGIN + TITLE_H / 2 + 5,
            title, theme.text_color, theme.font_size + 2, .middle, "bold");
    }

    // Columns
    for (cols_val, 0..) |cv, ci| {
        const cn = cv.asNode() orelse continue;
        const col_label = cn.getString("label") orelse "";
        const items = cn.getList("items");
        const color = col_colors[ci % col_colors.len];

        const cx = MARGIN + @as(f32, @floatFromInt(ci)) * (COL_W + COL_GAP);
        const cy = MARGIN + title_offset;

        // Column header
        try svg.rect(cx, cy, COL_W, HEADER_H, 6.0, color, "none", 0);
        try svg.text(cx + COL_W / 2, cy + HEADER_H / 2 + 5,
            col_label, theme.background, theme.font_size, .middle, "bold");

        // Column body background
        const body_h = @as(f32, @floatFromInt(max_items)) * (CARD_H + CARD_PAD) + CARD_PAD;
        try svg.rect(cx, cy + HEADER_H, COL_W, body_h, 0, "#f8f9fa", "#dee2e6", 1.0);

        // Cards
        for (items, 0..) |iv, ii| {
            const item_n = iv.asNode();
            const item_label = if (item_n) |n2| n2.getString("label") orelse n2.getString("id") orelse ""
                               else iv.asString() orelse "";
            const card_y = cy + HEADER_H + CARD_PAD + @as(f32, @floatFromInt(ii)) * (CARD_H + CARD_PAD);
            try svg.rect(cx + 8, card_y, COL_W - 16, CARD_H, 4.0, theme.node_fill, color, 1.0);
            try svg.textWrapped(cx + COL_W / 2, card_y + CARD_H / 2 + 4, item_label,
                COL_W - 32, theme.text_color, theme.font_size_small, .middle, "normal");
        }
    }

    try svg.footer();
    return svg.toOwnedSlice();
}

fn renderFallback(allocator: std.mem.Allocator) ![]const u8 {
    var svg = SvgWriter.init(allocator);
    defer svg.deinit();
    try svg.header(400, 200);
    try svg.text(200, 100, "kanban", theme.text_color, theme.font_size, .middle, "normal");
    try svg.footer();
    return svg.toOwnedSlice();
}
