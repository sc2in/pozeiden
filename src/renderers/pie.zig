//! Pie chart SVG renderer.
//! Reads a Value.node with fields: title, showData, sections (list of {label, value}).
const std = @import("std");
const Value = @import("../diagram/value.zig").Value;
const SvgWriter = @import("../svg/writer.zig").SvgWriter;
const theme = @import("../svg/theme.zig");
const xmlEscape = @import("../svg/writer.zig").xmlEscape;

pub fn render(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    const node = value.asNode() orelse return error.InvalidInput;

    // Collect sections
    const raw_sections = node.getList("sections");
    if (raw_sections.len == 0) return renderEmpty(allocator);

    // Compute total
    var total: f64 = 0;
    for (raw_sections) |sv| {
        if (sv.asNode()) |sn| {
            total += sn.getNumber("value") orelse 0;
        }
    }
    if (total == 0) return renderEmpty(allocator);

    const title_opt = node.getString("title");

    // Determine canvas size based on number of sections (legend grows)
    const legend_height: u32 = @intFromFloat(
        @as(f32, @floatFromInt(raw_sections.len)) * theme.pie_legend_line_height +
        theme.pie_legend_y_start + 20.0
    );
    const height = @max(theme.pie_height, legend_height);

    var svg = SvgWriter.init(allocator);
    defer svg.deinit();

    try svg.header(theme.pie_width, height);

    // Background
    try svg.rect(0, 0, @floatFromInt(theme.pie_width), @floatFromInt(height),
        0, theme.background, theme.background, 0);

    // Title
    if (title_opt) |title| {
        if (title.len > 0) {
            const clean_title = cleanTitle(title);
            try svg.text(
                @floatFromInt(theme.pie_width / 2),
                32.0,
                clean_title,
                theme.text_color,
                theme.font_size + 2,
                .middle,
                "bold",
            );
        }
    }

    // Draw slices
    const cx = theme.pie_cx;
    const cy = theme.pie_cy;
    const r = theme.pie_outer_radius;
    const math = std.math;
    var start_angle: f64 = -math.pi / 2.0; // Start at top

    for (raw_sections, 0..) |sv, idx| {
        const sn = sv.asNode() orelse continue;
        const val = sn.getNumber("value") orelse continue;
        const fraction = val / total;
        const sweep_angle = fraction * 2.0 * math.pi;
        const end_angle = start_angle + sweep_angle;

        const color = theme.pie_colors[idx % theme.pie_colors.len];

        // Compute arc endpoints
        const x1 = cx + r * @as(f32, @floatCast(@cos(start_angle)));
        const y1 = cy + r * @as(f32, @floatCast(@sin(start_angle)));
        const x2 = cx + r * @as(f32, @floatCast(@cos(end_angle)));
        const y2 = cy + r * @as(f32, @floatCast(@sin(end_angle)));
        const large_arc: u8 = if (fraction > 0.5) 1 else 0;

        // Build SVG path: move to center, line to arc start, arc, close
        var path_buf: [512]u8 = undefined;
        const path_d = try std.fmt.bufPrint(&path_buf,
            "M {d:.2} {d:.2} L {d:.2} {d:.2} A {d:.2} {d:.2} 0 {d} 1 {d:.2} {d:.2} Z",
            .{ cx, cy, x1, y1, r, r, large_arc, x2, y2 }
        );

        try svg.path(path_d, color, theme.pie_stroke, theme.pie_stroke_width, "");

        // Label at midpoint of arc
        const mid_angle = start_angle + sweep_angle / 2.0;
        const label_r = theme.pie_label_radius;
        const lx = cx + label_r * @as(f32, @floatCast(@cos(mid_angle)));
        const ly = cy + label_r * @as(f32, @floatCast(@sin(mid_angle)));

        // Only show label if slice is big enough (>5%)
        if (fraction > 0.05) {
            const pct = @round(fraction * 1000.0) / 10.0;
            var label_buf: [64]u8 = undefined;
            const pct_text = try std.fmt.bufPrint(&label_buf, "{d:.1}%", .{pct});
            try svg.text(lx, ly + 4.0, pct_text, theme.pie_text_color, theme.font_size_small, .middle, "normal");
        }

        start_angle = end_angle;
    }

    // Legend (right side)
    const leg_x = theme.pie_legend_x;
    for (raw_sections, 0..) |sv, idx| {
        const sn = sv.asNode() orelse continue;
        const label_raw = sn.getString("label") orelse continue;
        const val = sn.getNumber("value") orelse continue;
        const label = stripStringQuotes(label_raw);
        const color = theme.pie_colors[idx % theme.pie_colors.len];
        const ly = theme.pie_legend_y_start + @as(f32, @floatFromInt(idx)) * theme.pie_legend_line_height;

        // Color swatch
        try svg.rect(leg_x, ly - 10.0, 14.0, 14.0, 2.0, color, color, 0);

        // Label text
        var legend_buf: [256]u8 = undefined;
        const node_show_data = node.getBool("showData");
        const legend_text = if (node_show_data)
            try std.fmt.bufPrint(&legend_buf, "{s} [{d:.1}]", .{ label, val })
        else
            try std.fmt.bufPrint(&legend_buf, "{s}", .{label});

        try svg.text(leg_x + 20.0, ly + 2.0, legend_text, theme.text_color, theme.font_size, .start, "normal");
    }

    try svg.footer();
    return svg.toOwnedSlice();
}

fn renderEmpty(allocator: std.mem.Allocator) ![]const u8 {
    var svg = SvgWriter.init(allocator);
    defer svg.deinit();
    try svg.header(theme.pie_width, theme.pie_height);
    try svg.text(
        @floatFromInt(theme.pie_width / 2),
        @floatFromInt(theme.pie_height / 2),
        "(empty pie chart)",
        theme.text_color,
        theme.font_size,
        .middle,
        "normal",
    );
    try svg.footer();
    return svg.toOwnedSlice();
}

/// Strip surrounding quotes from a string literal value.
fn stripStringQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'')) {
        return s[1 .. s.len - 1];
    }
    return s;
}

/// Remove "title " prefix and extra whitespace from a TITLE terminal match.
fn cleanTitle(s: []const u8) []const u8 {
    var t = std.mem.trimLeft(u8, s, " \t");
    if (std.mem.startsWith(u8, t, "title")) t = std.mem.trimLeft(u8, t[5..], " \t");
    return std.mem.trimRight(u8, t, " \t\r\n");
}
