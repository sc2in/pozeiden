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
        is_space: bool,
    };

    var blocks: std.ArrayList(BlockEntry) = .empty;
    var block_map = std.StringArrayHashMap(usize).init(a); // id -> index

    // Place blocks in grid
    var cur_col: usize = 0;
    var cur_row: usize = 0;
    for (node.getList("blocks")) |bv| {
        const bn = bv.asNode() orelse continue;
        const id = bn.getString("id") orelse continue;
        const is_space = (bn.getNumber("space") orelse 0.0) != 0.0;
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
            .is_space = is_space,
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

    // ── Edge routing ──────────────────────────────────────────────────────
    // Elbow routes (crossing rows and columns) are collected first so we can
    // run greedy interval-graph coloring per row-gap before rendering.  This
    // gives each horizontal segment its own y track within the gap, preventing
    // paths from running on top of one another when they share the same gap.
    const ElbowRoute = struct {
        src_x: f32, src_y: f32,
        tgt_x: f32, tgt_y: f32,
        gap_row: usize,
        base_gap_y: f32,
        gap_y: f32,        // filled after track assignment
        horiz_min: f32,    // x interval of the horizontal segment
        horiz_max: f32,
        end_uy: f32,       // direction of last (vertical) segment for arrowhead
        label: ?[]const u8,
        track: usize,
    };

    var elbow_routes: std.ArrayList(ElbowRoute) = .empty;

    // Pass 1: direct edges rendered immediately; elbow edges collected.
    for (node.getList("edges")) |ev| {
        const en = ev.asNode() orelse continue;
        const from_id = en.getString("from") orelse continue;
        const to_id = en.getString("to") orelse continue;
        const label = en.getString("label");

        const fi = block_map.get(from_id) orelse continue;
        const ti = block_map.get(to_id) orelse continue;
        const fb = blocks.items[fi];
        const tb = blocks.items[ti];

        const fcx = fb.x + fb.w / 2.0;
        const fcy = fb.y + CELL_H / 2.0;
        const tcx = tb.x + tb.w / 2.0;
        const tcy = tb.y + CELL_H / 2.0;
        const dx = tcx - fcx;
        const dy = tcy - fcy;
        const len = @sqrt(dx * dx + dy * dy);
        if (len < 1.0) continue;
        const ux = dx / len;
        const uy = dy / len;

        const src = rectEdgePoint(fcx, fcy, fb.w, CELL_H, ux, uy);
        const tgt = rectEdgePoint(tcx, tcy, tb.w, CELL_H, -ux, -uy);

        const same_row = fb.grid_row == tb.grid_row;
        const same_col = fb.grid_col == tb.grid_col;
        const arr: f32 = 8.0;
        const half: f32 = 4.5;

        if (!same_row and !same_col) {
            const row_min = @min(fb.grid_row, tb.grid_row);
            const base_gap_y = MARGIN +
                @as(f32, @floatFromInt(row_min + 1)) * (CELL_H + GAP) - GAP / 2.0;
            try elbow_routes.append(a, .{
                .src_x = src.x, .src_y = src.y,
                .tgt_x = tgt.x, .tgt_y = tgt.y,
                .gap_row = row_min,
                .base_gap_y = base_gap_y,
                .gap_y = base_gap_y,
                .horiz_min = @min(src.x, tgt.x),
                .horiz_max = @max(src.x, tgt.x),
                .end_uy = if (tb.grid_row > fb.grid_row) 1.0 else -1.0,
                .label = label,
                .track = 0,
            });
        } else {
            // Same row or column: straight boundary-to-boundary line.
            try svg.line(src.x, src.y, tgt.x, tgt.y, theme.edge_color, 1.5);
            var pts_buf: [128]u8 = undefined;
            const pts = try std.fmt.bufPrint(&pts_buf,
                "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                .{
                    tgt.x - ux * arr - uy * half, tgt.y - uy * arr + ux * half,
                    tgt.x, tgt.y,
                    tgt.x - ux * arr + uy * half, tgt.y - uy * arr - ux * half,
                });
            try svg.polygon(pts, theme.edge_color, theme.edge_color, 0);
            if (label) |lbl| {
                try svg.text((src.x + tgt.x) / 2.0, (src.y + tgt.y) / 2.0 - 6, lbl,
                    theme.text_color, theme.font_size_small, .middle, "normal");
            }
        }
    }

    // Pass 2: assign y tracks for elbow routes within each row gap.
    // Sort by (gap_row, horiz_min) so the greedy interval-coloring processes
    // segments left-to-right within each gap, producing the minimum track count.
    std.mem.sort(ElbowRoute, elbow_routes.items, {}, struct {
        fn lt(_: void, a_: ElbowRoute, b_: ElbowRoute) bool {
            if (a_.gap_row != b_.gap_row) return a_.gap_row < b_.gap_row;
            return a_.horiz_min < b_.horiz_min;
        }
    }.lt);

    // track_end_x[gap_row][track] = horiz_max of last segment assigned to that track.
    const MAX_TRACKS = 7;
    var track_end_x = std.mem.zeroes([64][MAX_TRACKS]f32);
    var track_count = std.mem.zeroes([64]usize);

    for (elbow_routes.items) |*r| {
        const gr = r.gap_row % 64;
        var assigned = false;
        for (0..track_count[gr]) |t| {
            if (track_end_x[gr][t] <= r.horiz_min) {
                track_end_x[gr][t] = r.horiz_max;
                r.track = t;
                assigned = true;
                break;
            }
        }
        if (!assigned and track_count[gr] < MAX_TRACKS) {
            const t = track_count[gr];
            track_end_x[gr][t] = r.horiz_max;
            track_count[gr] = t + 1;
            r.track = t;
        }
    }

    // Space tracks evenly within the gap, centred on base_gap_y.
    for (elbow_routes.items) |*r| {
        const gr = r.gap_row % 64;
        const n: f32 = @floatFromInt(track_count[gr]);
        const t: f32 = @floatFromInt(r.track);
        const pitch = if (n > 1) GAP / (n + 1.0) else 0.0;
        r.gap_y = r.base_gap_y + (t - (n - 1.0) / 2.0) * pitch;
    }

    // Pass 3: render elbow routes with assigned gap_y values.
    for (elbow_routes.items) |r| {
        var path_buf: [256]u8 = undefined;
        const path_d = try std.fmt.bufPrint(&path_buf,
            "M {d:.1} {d:.1} L {d:.1} {d:.1} L {d:.1} {d:.1} L {d:.1} {d:.1}",
            .{ r.src_x, r.src_y, r.src_x, r.gap_y, r.tgt_x, r.gap_y, r.tgt_x, r.tgt_y });
        try svg.path(path_d, "none", theme.edge_color, 1.5, "");

        const arr: f32 = 8.0;
        const half: f32 = 4.5;
        var pts_buf: [128]u8 = undefined;
        const pts = try std.fmt.bufPrint(&pts_buf,
            "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
            .{
                r.tgt_x - r.end_uy * half, r.tgt_y - r.end_uy * arr,
                r.tgt_x, r.tgt_y,
                r.tgt_x + r.end_uy * half, r.tgt_y - r.end_uy * arr,
            });
        try svg.polygon(pts, theme.edge_color, theme.edge_color, 0);
        if (r.label) |lbl| {
            try svg.text((r.src_x + r.tgt_x) / 2.0, r.gap_y - 6, lbl,
                theme.text_color, theme.font_size_small, .middle, "normal");
        }
    }

    // Draw blocks (skip space placeholders)
    var color_idx: usize = 0;
    for (blocks.items) |b| {
        if (b.is_space) continue;
        const color = theme.pie_colors[color_idx % theme.pie_colors.len];
        color_idx += 1;
        try svg.rect(b.x, b.y, b.w, CELL_H, 6.0, theme.node_fill, color, 2.0);
        try svg.textWrapped(b.x + b.w / 2, b.y + CELL_H / 2 + 4,
            b.label, b.w - 8, theme.text_color, theme.font_size, .middle, "normal");
    }

    try svg.footer();
    return svg.toOwnedSlice();
}

/// Returns the point where a ray from (cx, cy) in direction (dx, dy)
/// exits the rectangle of size (w, h) centred at (cx, cy).
fn rectEdgePoint(cx: f32, cy: f32, w: f32, h: f32, dx: f32, dy: f32) struct { x: f32, y: f32 } {
    const hw = w / 2.0;
    const hh = h / 2.0;
    var t: f32 = std.math.inf(f32);
    if (@abs(dx) > 0.001) t = @min(t, hw / @abs(dx));
    if (@abs(dy) > 0.001) t = @min(t, hh / @abs(dy));
    return .{ .x = cx + t * dx, .y = cy + t * dy };
}

fn renderFallback(allocator: std.mem.Allocator) ![]const u8 {
    var svg = SvgWriter.init(allocator);
    defer svg.deinit();
    try svg.header(400, 200);
    try svg.text(200, 100, "block-beta", theme.text_color, theme.font_size, .middle, "normal");
    try svg.footer();
    return svg.toOwnedSlice();
}
