//! Block diagram SVG renderer (block-beta).
//! Expects a Value.node with `cols` (number of grid columns), `blocks` (list of nodes
//! with `id`, `label`, and optional `width` in grid units), and `edges` (list of nodes
//! with `from`, `to`, and optional `label`). Blocks are placed left-to-right wrapping
//! at `cols`; edges are drawn as straight arrowed lines between block centers.
const std = @import("std");
const Value = @import("../diagram/value.zig").Value;
const SvgWriter = @import("../svg/writer.zig").SvgWriter;
const theme = @import("../svg/theme.zig");

const CELL_W: f32 = 140;
const CELL_H: f32 = 60;
const GAP: f32 = 20;
const MARGIN: f32 = 40;

/// Render a block-beta diagram SVG from `value`.
/// `value` must be a node with `cols` (grid column count), `blocks` (list of nodes
/// with `id`, `label`, and optional `width`), and `edges` (list of nodes with
/// `from`, `to`, and optional `label`). Returns a caller-owned SVG string.
pub fn render(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    const node = value.asNode() orelse return renderFallback(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const n_cols: usize = @intFromFloat(node.getNumber("cols") orelse 3.0);
    const cols: usize = if (n_cols == 0) 3 else n_cols;

    const BlockEntry = struct {
        id: []const u8,
        label: []const u8,
        width: usize,  // grid units wide
        grid_col: usize,
        grid_row: usize,
        x: f32,
        y: f32,
        w: f32,
    };

    var blocks: std.ArrayList(BlockEntry) = .empty;
    var block_map = std.StringArrayHashMap(usize).init(a); // id -> index

    // Place blocks in grid
    var cur_col: usize = 0;
    var cur_row: usize = 0;
    for (node.getList("blocks")) |bv| {
        const bn = bv.asNode() orelse continue;
        const id = bn.getString("id") orelse continue;
        const label = bn.getString("label") orelse id;
        const width: usize = @intFromFloat(bn.getNumber("width") orelse 1.0);
        const w = @as(f32, @floatFromInt(width)) * CELL_W + @as(f32, @floatFromInt(width - 1)) * GAP;

        // Wrap if this block doesn't fit in the current row
        if (cur_col + width > cols and cur_col > 0) {
            cur_col = 0;
            cur_row += 1;
        }

        const x = MARGIN + @as(f32, @floatFromInt(cur_col)) * (CELL_W + GAP);
        const y = MARGIN + @as(f32, @floatFromInt(cur_row)) * (CELL_H + GAP);

        try block_map.put(id, blocks.items.len);
        try blocks.append(a, BlockEntry{
            .id = id, .label = label, .width = width,
            .grid_col = cur_col, .grid_row = cur_row,
            .x = x, .y = y, .w = w,
        });

        cur_col += width;
        if (cur_col >= cols) { cur_col = 0; cur_row += 1; }
    }

    if (blocks.items.len == 0) return renderFallback(allocator);

    const n_rows = cur_row + (if (cur_col > 0) @as(usize, 1) else @as(usize, 0));
    const total_w: u32 = @intFromFloat(
        MARGIN * 2 + @as(f32, @floatFromInt(cols)) * CELL_W + @as(f32, @floatFromInt(cols - 1)) * GAP
    );
    const total_h: u32 = @intFromFloat(
        MARGIN * 2 + @as(f32, @floatFromInt(n_rows)) * CELL_H + @as(f32, @floatFromInt(n_rows - 1)) * GAP
    );

    var svg = SvgWriter.init(allocator);
    defer svg.deinit();

    try svg.header(total_w, total_h);
    try svg.rect(0, 0, @floatFromInt(total_w), @floatFromInt(total_h), 0, theme.background, theme.background, 0);

    // Draw edges first (behind blocks)
    for (node.getList("edges")) |ev| {
        const en = ev.asNode() orelse continue;
        const from_id = en.getString("from") orelse continue;
        const to_id = en.getString("to") orelse continue;
        const label = en.getString("label");

        const fi = block_map.get(from_id) orelse continue;
        const ti = block_map.get(to_id) orelse continue;
        const fb = blocks.items[fi];
        const tb = blocks.items[ti];

        const fx = fb.x + fb.w / 2;
        const fy = fb.y + CELL_H / 2;
        const tx = tb.x + tb.w / 2;
        const ty = tb.y + CELL_H / 2;

        try svg.line(fx, fy, tx, ty, theme.edge_color, 1.5);

        // Arrowhead at destination
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
            try svg.polygon(pts, theme.edge_color, theme.edge_color, 0);
        }

        if (label) |lbl| {
            try svg.text((fx + tx) / 2, (fy + ty) / 2 - 6, lbl,
                theme.text_color, theme.font_size_small, .middle, "normal");
        }
    }

    // Draw blocks
    for (blocks.items, 0..) |b, bi| {
        const color = theme.pie_colors[bi % theme.pie_colors.len];
        try svg.rect(b.x, b.y, b.w, CELL_H, 6.0, theme.node_fill, color, 2.0);
        try svg.text(b.x + b.w / 2, b.y + CELL_H / 2 + 4,
            b.label, theme.text_color, theme.font_size, .middle, "normal");
    }

    try svg.footer();
    return svg.toOwnedSlice();
}

fn renderFallback(allocator: std.mem.Allocator) ![]const u8 {
    var svg = SvgWriter.init(allocator);
    defer svg.deinit();
    try svg.header(400, 200);
    try svg.text(200, 100, "block-beta", theme.text_color, theme.font_size, .middle, "normal");
    try svg.footer();
    return svg.toOwnedSlice();
}
