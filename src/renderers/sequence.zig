//! Sequence diagram SVG renderer.
const std = @import("std");
const Value = @import("../diagram/value.zig").Value;
const SvgWriter = @import("../svg/writer.zig").SvgWriter;
const theme = @import("../svg/theme.zig");
const arrow_marker_defs = @import("../svg/writer.zig").arrow_marker_defs;

const ACTOR_W: f32 = 120;
const ACTOR_H: f32 = 40;
const LANE_GAP: f32 = 160;
const ROW_H: f32 = 50;
const MARGIN_X: f32 = 40;
const MARGIN_Y: f32 = 20;
const ACTOR_TOP_Y: f32 = 20;
const FIRST_MSG_Y: f32 = 100;

pub fn render(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    const node = value.asNode() orelse return renderFallback(allocator);

    // Collect actors in order of first appearance
    var actors: std.ArrayList([]const u8) = .empty;
    defer actors.deinit(allocator);
    var messages: std.ArrayList(Message) = .empty;
    defer messages.deinit(allocator);
    var blocks: std.ArrayList(Block) = .empty;
    defer blocks.deinit(allocator);

    // Parse participants
    const parts = node.getList("participants");
    for (parts) |pv| {
        if (pv.asNode()) |pn| {
            const name = pn.getString("actor") orelse continue;
            if (!hasActor(actors.items, name)) try actors.append(allocator, name);
        } else if (pv.asString()) |s| {
            if (!hasActor(actors.items, s)) try actors.append(allocator, s);
        }
    }

    // Parse messages/signals
    const sigs = node.getList("signals");
    for (sigs) |sv| {
        const sn = sv.asNode() orelse continue;
        const msg_type = sn.getString("type") orelse "";
        if (std.mem.eql(u8, msg_type, "addMessage")) {
            const from = sn.getString("from") orelse continue;
            const to = sn.getString("to") orelse continue;
            const text = sn.getString("msg") orelse "";
            const signal_type = sn.getString("signalType") orelse "0";
            if (!hasActor(actors.items, from)) try actors.append(allocator, from);
            if (!hasActor(actors.items, to)) try actors.append(allocator, to);
            try messages.append(allocator, Message{
                .from = from,
                .to = to,
                .text = text,
                .dotted = isDotted(signal_type),
                .arrow_kind = arrowKind(signal_type),
            });
        } else if (std.mem.eql(u8, msg_type, "loopStart")) {
            const lbl = sn.getString("loopText") orelse sn.getString("blockText") orelse "";
            try blocks.append(allocator, Block{ .kind = .loop, .label = lbl, .start_row = messages.items.len });
        } else if (std.mem.eql(u8, msg_type, "loopEnd")) {
            for (blocks.items) |*b| {
                if (b.kind == .loop and b.end_row == null) {
                    b.end_row = messages.items.len;
                    break;
                }
            }
        } else if (std.mem.eql(u8, msg_type, "altStart")) {
            const lbl = sn.getString("altText") orelse sn.getString("blockText") orelse "";
            try blocks.append(allocator, Block{ .kind = .alt, .label = lbl, .start_row = messages.items.len });
        } else if (std.mem.eql(u8, msg_type, "altEnd")) {
            for (blocks.items) |*b| {
                if (b.kind == .alt and b.end_row == null) {
                    b.end_row = messages.items.len;
                    break;
                }
            }
        } else if (std.mem.eql(u8, msg_type, "optStart")) {
            const lbl = sn.getString("blockText") orelse "";
            try blocks.append(allocator, Block{ .kind = .opt, .label = lbl, .start_row = messages.items.len });
        } else if (std.mem.eql(u8, msg_type, "optEnd")) {
            for (blocks.items) |*b| {
                if (b.kind == .opt and b.end_row == null) {
                    b.end_row = messages.items.len;
                    break;
                }
            }
        } else if (std.mem.eql(u8, msg_type, "parStart")) {
            const lbl = sn.getString("blockText") orelse "";
            try blocks.append(allocator, Block{ .kind = .par, .label = lbl, .start_row = messages.items.len });
        } else if (std.mem.eql(u8, msg_type, "parEnd")) {
            for (blocks.items) |*b| {
                if (b.kind == .par and b.end_row == null) {
                    b.end_row = messages.items.len;
                    break;
                }
            }
        }
    }

    // If nothing parsed, fallback
    if (actors.items.len == 0 and messages.items.len == 0) {
        return renderFallback(allocator);
    }

    const n_actors = actors.items.len;
    const n_msgs = messages.items.len;
    const total_w: u32 = @intFromFloat(
        MARGIN_X * 2 + @as(f32, @floatFromInt(n_actors)) * LANE_GAP
    );
    const total_h: u32 = @intFromFloat(
        FIRST_MSG_Y + @as(f32, @floatFromInt(n_msgs + 1)) * ROW_H + ACTOR_H + MARGIN_Y * 2
    );

    var svg = SvgWriter.init(allocator);
    defer svg.deinit();

    try svg.header(total_w, total_h);
    try svg.defs(arrow_marker_defs);

    // Background
    try svg.rect(0, 0, @floatFromInt(total_w), @floatFromInt(total_h), 0, theme.background, theme.background, 0);

    // 1. Loop/alt blocks first — behind everything
    for (blocks.items) |b| {
        const end = b.end_row orelse n_msgs;
        const by = FIRST_MSG_Y + @as(f32, @floatFromInt(b.start_row)) * ROW_H - 10;
        const bh = @as(f32, @floatFromInt(end - b.start_row)) * ROW_H + 20;
        const bx: f32 = MARGIN_X - 10;
        const bw: f32 = @as(f32, @floatFromInt(total_w)) - (MARGIN_X - 10) * 2;
        try svg.rect(bx, by, bw, bh, 4.0, theme.loop_fill, theme.loop_stroke, 1.0);
        var kind_label_buf: [64]u8 = undefined;
        const kind_str = switch (b.kind) { .loop => "loop", .alt => "alt", .opt => "opt", .par => "par" };
        const kind_label = try std.fmt.bufPrint(&kind_label_buf, "{s} {s}", .{ kind_str, b.label });
        try svg.text(bx + 4, by + 14, kind_label, theme.text_color, theme.font_size_small, .start, "normal");
    }

    // 2. Lifelines — on top of blocks, behind actor boxes and messages
    for (actors.items, 0..) |_, i| {
        const lx = MARGIN_X + @as(f32, @floatFromInt(i)) * LANE_GAP;
        const line_x = lx + ACTOR_W / 2;
        const line_top = ACTOR_TOP_Y + ACTOR_H;
        const line_bot = @as(f32, @floatFromInt(total_h)) - ACTOR_H - MARGIN_Y;
        try svg.dashedLine(line_x, line_top, line_x, line_bot, theme.signal_color, 1.0, "4,4");
    }

    // 3. Actor boxes — on top of lifelines and blocks
    for (actors.items, 0..) |actor, i| {
        const lx = MARGIN_X + @as(f32, @floatFromInt(i)) * LANE_GAP;
        const line_bot = @as(f32, @floatFromInt(total_h)) - ACTOR_H - MARGIN_Y;
        try drawActorBox(&svg, lx, ACTOR_TOP_Y, actor);
        try drawActorBox(&svg, lx, line_bot, actor);
    }

    // 4. Messages — topmost layer
    for (messages.items, 0..) |msg, mi| {
        const my = FIRST_MSG_Y + @as(f32, @floatFromInt(mi)) * ROW_H + ROW_H / 2;

        const from_idx = actorIndex(actors.items, msg.from) orelse 0;
        const to_idx = actorIndex(actors.items, msg.to) orelse 0;

        const fx = MARGIN_X + @as(f32, @floatFromInt(from_idx)) * LANE_GAP + ACTOR_W / 2;
        const tx = MARGIN_X + @as(f32, @floatFromInt(to_idx)) * LANE_GAP + ACTOR_W / 2;

        if (from_idx == to_idx) {
            // Self-message: right-bracket shape — out, down, back with arrowhead
            const loop_w: f32 = 40;
            const loop_h: f32 = ROW_H * 0.6;
            const arr: f32 = 8.0;

            try svg.line(fx, my, fx + loop_w, my, theme.signal_color, 1.5);
            try svg.line(fx + loop_w, my, fx + loop_w, my + loop_h, theme.signal_color, 1.5);
            if (msg.dotted) {
                try svg.dashedLine(fx + loop_w, my + loop_h, fx, my + loop_h, theme.signal_color, 1.5, "5,3");
            } else {
                try svg.line(fx + loop_w, my + loop_h, fx, my + loop_h, theme.signal_color, 1.5);
            }
            // Arrowhead pointing left at return end
            var pts_buf: [128]u8 = undefined;
            const pts = try std.fmt.bufPrint(&pts_buf,
                "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                .{ fx + arr, my + loop_h - arr / 2, fx, my + loop_h, fx + arr, my + loop_h + arr / 2 });
            try svg.polygon(pts, theme.signal_color, theme.signal_color, 1.0);
            // Label above outgoing segment
            try svg.text(fx + loop_w / 2, my - 6, msg.text, theme.text_color, theme.font_size_small, .start, "normal");
        } else {
            // Normal arrow between two different actors
            if (msg.dotted) {
                try svg.dashedLine(fx, my, tx, my, theme.signal_color, 1.5, "5,3");
            } else {
                try svg.line(fx, my, tx, my, theme.signal_color, 1.5);
            }

            // Arrowhead
            const dir: f32 = if (tx > fx) 1.0 else -1.0;
            const arr: f32 = 8.0;
            var pts_buf: [128]u8 = undefined;
            const pts = switch (msg.arrow_kind) {
                .open => try std.fmt.bufPrint(&pts_buf,
                    "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                    .{ tx - dir * arr, my - arr / 2, tx, my, tx - dir * arr, my + arr / 2 }),
                .filled => try std.fmt.bufPrint(&pts_buf,
                    "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                    .{ tx - dir * arr, my - arr / 2, tx, my, tx - dir * arr, my + arr / 2 }),
                .cross => try std.fmt.bufPrint(&pts_buf,
                    "{d:.1},{d:.1} {d:.1},{d:.1}",
                    .{ tx - dir * arr, my - arr / 2, tx, my }),
            };
            try svg.polygon(pts, theme.signal_color, theme.signal_color, 1.0);

            // Message text above arrow
            try svg.text((fx + tx) / 2, my - 6, msg.text, theme.text_color, theme.font_size_small, .middle, "normal");
        }
    }

    try svg.footer();
    return svg.toOwnedSlice();
}

fn drawActorBox(svg: *SvgWriter, x: f32, y: f32, name: []const u8) !void {
    try svg.rect(x, y, ACTOR_W, ACTOR_H, 4.0, theme.actor_fill, theme.actor_stroke, 1.5);
    try svg.text(x + ACTOR_W / 2, y + ACTOR_H / 2 + 4, name, theme.text_color, theme.font_size, .middle, "normal");
}

fn hasActor(actors: []const []const u8, name: []const u8) bool {
    for (actors) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}

fn actorIndex(actors: []const []const u8, name: []const u8) ?usize {
    for (actors, 0..) |a, i| if (std.mem.eql(u8, a, name)) return i;
    return null;
}

fn isDotted(signal_type: []const u8) bool {
    // Jison runtime might give us integer strings or type names
    const n = std.fmt.parseInt(u32, signal_type, 10) catch return false;
    // In mermaid: dotted types are odd numbers in LINETYPE enum
    return n % 2 == 1;
}

const ArrowKind = enum { filled, open, cross };

fn arrowKind(signal_type: []const u8) ArrowKind {
    if (std.mem.indexOf(u8, signal_type, "CROSS") != null) return .cross;
    if (std.mem.indexOf(u8, signal_type, "OPEN") != null) return .open;
    return .filled;
}

const Block = struct {
    kind: enum { loop, alt, opt, par },
    label: []const u8,
    start_row: usize,
    end_row: ?usize = null,
};

const Message = struct {
    from: []const u8,
    to: []const u8,
    text: []const u8,
    dotted: bool,
    arrow_kind: ArrowKind,
};

fn renderFallback(allocator: std.mem.Allocator) ![]const u8 {
    var svg = SvgWriter.init(allocator);
    defer svg.deinit();
    try svg.header(400, 200);
    try svg.text(200, 100, "sequenceDiagram", theme.text_color, theme.font_size, .middle, "normal");
    try svg.footer();
    return svg.toOwnedSlice();
}
