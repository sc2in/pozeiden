//! Timeline diagram SVG renderer.
//! Expects a Value.node with `title` (string) and `sections` (list of nodes with
//! `label` and `events` (list of plain strings)). Sections are evenly spaced
//! along a horizontal spine; events hang below each section tick as labelled boxes.
const std = @import("std");
const Value = @import("../diagram/value.zig").Value;
const SvgWriter = @import("../svg/writer.zig").SvgWriter;
const theme = @import("../svg/theme.zig");

const SPINE_Y: f32 = 120; // Y position of the horizontal spine
const SECTION_W: f32 = 150; // width per section/era
const EVENT_H: f32 = 22;
const EVENT_W: f32 = 132;
const MARGIN_X: f32 = 40;
const MARGIN_Y: f32 = 20;
const TITLE_H: f32 = 36;

const section_colors = [_][]const u8{
    "#74c0fc", "#51cf66", "#ffd43b", "#ff6b6b",
    "#cc5de8", "#20c997", "#fd7e14", "#339af0",
};

const TlEvent = struct { text: []const u8 };

const TlSection = struct {
    label: []const u8,
    events: []TlEvent,
};

/// Render a timeline diagram SVG from `value`.
/// `value` must be a node with `title` (optional string) and `sections` (list of nodes
/// with `label` and `events` (list of plain strings)). Sections are evenly spaced
/// along a horizontal spine; events hang below as small labelled rectangles.
pub fn render(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    const node = value.asNode() orelse return renderFallback(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const title = node.getString("title") orelse "";
    var sections: std.ArrayList(TlSection) = .empty;

    for (node.getList("sections")) |sv| {
        const sn = sv.asNode() orelse continue;
        const lbl = sn.getString("label") orelse "";
        const raw_events = sn.getList("events");
        var events: std.ArrayList(TlEvent) = .empty;
        for (raw_events) |ev| {
            const es = ev.asString() orelse continue;
            try events.append(a, TlEvent{ .text = es });
        }
        try sections.append(a, TlSection{
            .label = lbl,
            .events = try events.toOwnedSlice(a),
        });
    }

    if (sections.items.len == 0) return renderFallback(allocator);

    // Max events below spine determines height
    var max_events: usize = 0;
    for (sections.items) |s| { if (s.events.len > max_events) max_events = s.events.len; }

    const total_w: u32 = @intFromFloat(
        MARGIN_X * 2 + @as(f32, @floatFromInt(sections.items.len)) * SECTION_W
    );
    const spine_y_actual = MARGIN_Y + TITLE_H + SPINE_Y;
    const total_h: u32 = @intFromFloat(
        spine_y_actual + 30 + @as(f32, @floatFromInt(max_events + 1)) * (EVENT_H + 8) + MARGIN_Y
    );

    var svg = SvgWriter.init(allocator);
    defer svg.deinit();

    try svg.header(total_w, total_h);
    try svg.rect(0, 0, @floatFromInt(total_w), @floatFromInt(total_h), 0, theme.background, theme.background, 0);

    // Title
    if (title.len > 0) {
        try svg.text(@as(f32, @floatFromInt(total_w)) / 2, MARGIN_Y + TITLE_H / 2 + 5,
            title, theme.text_color, theme.font_size + 2, .middle, "bold");
    }

    // Spine
    try svg.line(MARGIN_X, spine_y_actual, @as(f32, @floatFromInt(total_w)) - MARGIN_X, spine_y_actual,
        theme.line_color, 2.5);

    for (sections.items, 0..) |sec, si| {
        const sx = MARGIN_X + @as(f32, @floatFromInt(si)) * SECTION_W;
        const cx = sx + SECTION_W / 2;
        const color = section_colors[si % section_colors.len];

        // Tick on spine
        try svg.line(cx, spine_y_actual - 8, cx, spine_y_actual + 8, theme.line_color, 2.0);

        // Section label above spine
        const label_box_h: f32 = 28;
        try svg.rect(sx + 4, spine_y_actual - 50, SECTION_W - 8, label_box_h, 4.0, color, "none", 0);
        try svg.text(cx, spine_y_actual - 50 + label_box_h / 2 + 5, sec.label, theme.background, theme.font_size_small, .middle, "bold");

        // Events below spine
        for (sec.events, 0..) |ev, ei| {
            const ey = spine_y_actual + 20 + @as(f32, @floatFromInt(ei)) * (EVENT_H + 8);
            try svg.rect(sx + 10, ey, EVENT_W, EVENT_H, 3.0, "#f8f9fa", color, 1.0);
            // Truncate long event text
            const max_len: usize = 19;
            const display = if (ev.text.len > max_len) ev.text[0..max_len] else ev.text;
            try svg.text(sx + 10 + EVENT_W / 2, ey + EVENT_H / 2 + 4, display, theme.text_color, theme.font_size_small, .middle, "normal");
        }
    }

    try svg.footer();
    return svg.toOwnedSlice();
}

fn renderFallback(allocator: std.mem.Allocator) ![]const u8 {
    var svg = SvgWriter.init(allocator);
    defer svg.deinit();
    try svg.header(400, 200);
    try svg.text(200, 100, "timeline", theme.text_color, theme.font_size, .middle, "normal");
    try svg.footer();
    return svg.toOwnedSlice();
}
