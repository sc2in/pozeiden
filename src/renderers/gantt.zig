//! Gantt chart SVG renderer.
//! Expects a Value.node with `title` (string) and `sections` (list of nodes with
//! `label` and `tasks`). Each task node carries `name`, `duration` (e.g. "2d", "4h"),
//! and `flags` (comma-separated: "crit", "done", "active", "milestone").
//! Tasks are stacked sequentially left-to-right across the shared timeline.
const std = @import("std");
const Value = @import("../diagram/value.zig").Value;
const SvgWriter = @import("../svg/writer.zig").SvgWriter;
const theme = @import("../svg/theme.zig");

const LABEL_W: f32 = 140; // left column for task names
const BAR_AREA_W: f32 = 480; // width of the bar chart area
const ROW_H: f32 = 28;
const BAR_H: f32 = 18;
const MARGIN_X: f32 = 20;
const MARGIN_Y: f32 = 30;
const TITLE_H: f32 = 36;

const section_colors = [_][]const u8{
    "#74c0fc", "#51cf66", "#ffd43b", "#ff6b6b",
    "#cc5de8", "#20c997", "#fd7e14", "#339af0",
};

const Task = struct {
    name: []const u8,
    section_idx: usize,
    duration: f32, // in units
    flags: []const u8, // "crit", "done", "active"
};

const Section = struct {
    label: []const u8,
    task_start: usize,
    task_end: usize,
};

/// Render a Gantt chart SVG from `value`.
/// `value` must be a node with `title` (string) and `sections` (list of nodes with
/// `label` and `tasks`). Each task carries `name`, `duration` ("2d"/"4h"/"1w"),
/// and `flags` (e.g. "crit", "done", "milestone"). Tasks are laid out sequentially.
pub fn render(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    const node = value.asNode() orelse return renderFallback(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const title = node.getString("title") orelse "gantt";
    var tasks: std.ArrayList(Task) = .empty;
    var sections: std.ArrayList(Section) = .empty;

    for (node.getList("sections")) |sv| {
        const sn = sv.asNode() orelse continue;
        const lbl = sn.getString("label") orelse "Section";
        const start_idx = tasks.items.len;

        for (sn.getList("tasks")) |tv| {
            const tn = tv.asNode() orelse continue;
            const tname = tn.getString("name") orelse "";
            const flags = tn.getString("flags") orelse "";
            const dur_str = tn.getString("duration") orelse "1d";
            const dur = parseDuration(dur_str);
            try tasks.append(a, Task{
                .name = tname,
                .section_idx = sections.items.len,
                .duration = dur,
                .flags = flags,
            });
        }

        try sections.append(a, Section{
            .label = lbl,
            .task_start = start_idx,
            .task_end = tasks.items.len,
        });
    }

    if (tasks.items.len == 0) return renderFallback(allocator);

    // Total duration = sum of all task durations (sequential layout)
    var total_dur: f32 = 0;
    for (tasks.items) |t| total_dur += t.duration;
    if (total_dur < 1.0) total_dur = 1.0;

    // Count section header rows too
    const n_rows = tasks.items.len + sections.items.len;
    const total_w: u32 = @intFromFloat(MARGIN_X * 2 + LABEL_W + BAR_AREA_W);
    const total_h: u32 = @intFromFloat(MARGIN_Y * 2 + TITLE_H + @as(f32, @floatFromInt(n_rows)) * ROW_H);

    var svg = SvgWriter.init(allocator);
    defer svg.deinit();

    try svg.header(total_w, total_h);
    try svg.rect(0, 0, @floatFromInt(total_w), @floatFromInt(total_h), 0, theme.background, theme.background, 0);

    // Title
    try svg.text(@as(f32, @floatFromInt(total_w)) / 2, MARGIN_Y + TITLE_H / 2 + 5,
        title, theme.text_color, theme.font_size + 2, .middle, "bold");

    // Bar area background
    const bar_x = MARGIN_X + LABEL_W;
    const bar_top = MARGIN_Y + TITLE_H;
    const bar_bot = bar_top + @as(f32, @floatFromInt(n_rows)) * ROW_H;
    try svg.rect(bar_x, bar_top, BAR_AREA_W, bar_bot - bar_top, 0, "#f8f9fa", "#dee2e6", 1.0);

    // Grid lines (5 vertical divisions)
    const divisions: usize = 5;
    for (0..divisions + 1) |gi| {
        const gx = bar_x + BAR_AREA_W * @as(f32, @floatFromInt(gi)) / @as(f32, @floatFromInt(divisions));
        try svg.dashedLine(gx, bar_top, gx, bar_bot, "#ced4da", 1.0, "4,4");
    }

    // Rows
    var cursor: f32 = 0; // running time offset
    var row_idx: usize = 0;
    for (sections.items, 0..) |sec, si| {
        const sect_color = section_colors[si % section_colors.len];
        const sect_y = bar_top + @as(f32, @floatFromInt(row_idx)) * ROW_H;

        // Section header row
        try svg.rect(MARGIN_X, sect_y, LABEL_W + BAR_AREA_W, ROW_H, 0, sect_color, "none", 0);
        try svg.text(MARGIN_X + 6, sect_y + ROW_H / 2 + 5, sec.label, theme.background, theme.font_size_small, .start, "bold");
        row_idx += 1;

        // Tasks in this section
        for (tasks.items[sec.task_start..sec.task_end]) |t| {
            const ty = bar_top + @as(f32, @floatFromInt(row_idx)) * ROW_H;
            const bar_y = ty + (ROW_H - BAR_H) / 2;

            // Task label
            try svg.text(MARGIN_X + LABEL_W - 4, ty + ROW_H / 2 + 4, t.name, theme.text_color, theme.font_size_small, .end, "normal");

            // Bar or milestone diamond
            const bx = bar_x + (cursor / total_dur) * BAR_AREA_W;
            const bw = (t.duration / total_dur) * BAR_AREA_W;
            const is_crit = std.mem.indexOf(u8, t.flags, "crit") != null;
            const is_done = std.mem.indexOf(u8, t.flags, "done") != null;
            const is_milestone = std.mem.indexOf(u8, t.flags, "milestone") != null;
            const bar_fill = if (is_crit) "#e55039"
                             else if (is_done) "#95a5a6"
                             else sect_color;
            if (is_milestone) {
                // Render as a diamond at the task's start position
                const cx = bx;
                const cy = bar_y + BAR_H / 2;
                const r: f32 = BAR_H * 0.6;
                var pts_buf: [192]u8 = undefined;
                const pts = try std.fmt.bufPrint(&pts_buf,
                    "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                    .{ cx, cy - r, cx + r, cy, cx, cy + r, cx - r, cy });
                try svg.polygon(pts, bar_fill, bar_fill, 0);
            } else {
                try svg.rect(bx, bar_y, bw, BAR_H, 3.0, bar_fill, "none", 0);
            }

            cursor += t.duration;
            row_idx += 1;
        }
    }

    try svg.footer();
    return svg.toOwnedSlice();
}

fn parseDuration(s: []const u8) f32 {
    // "2d" → 2, "4h" → 0.5, "1w" → 7, plain number → that number
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0) return 1.0;
    const last = trimmed[trimmed.len - 1];
    const num_str = if (std.ascii.isAlphabetic(last)) trimmed[0..trimmed.len - 1] else trimmed;
    const n = std.fmt.parseFloat(f32, num_str) catch 1.0;
    return switch (last) {
        'h', 'H' => n / 8.0,
        'w', 'W' => n * 5.0,
        'd', 'D' => n,
        else => n,
    };
}

fn renderFallback(allocator: std.mem.Allocator) ![]const u8 {
    var svg = SvgWriter.init(allocator);
    defer svg.deinit();
    try svg.header(400, 200);
    try svg.text(200, 100, "gantt", theme.text_color, theme.font_size, .middle, "normal");
    try svg.footer();
    return svg.toOwnedSlice();
}
