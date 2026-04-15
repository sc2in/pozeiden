//! Sequence diagram SVG renderer.
//! Expects a Value.node with `participants` (list of actor names or nodes with
//! `actor`) and `signals` (list of typed message nodes with `from`, `to`, `msg`,
//! `signalType`, and block markers such as loopStart/loopEnd, altStart/altEnd).
//! Each actor gets a vertical lifeline; blocks are drawn as labelled background boxes.
//! Activation bars, notes, and autonumber are also supported.
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
const ACT_BAR_W: f32 = 10; // activation bar half-width (total 10px)
const NOTE_H: f32 = 28;
const NOTE_PAD: f32 = 8;

/// Render a sequence diagram SVG from `value`.
/// `value` must be a node with `participants` (actor names or nodes with `actor`) and
/// `signals` (typed nodes: `addMessage` with `from`, `to`, `msg`, `signalType`;
/// block markers loopStart/loopEnd, altStart/altEnd, optStart/optEnd, parStart/parEnd;
/// `activate`/`deactivate` with `actor` and `row`; `note` with `position`, `actor1`,
/// optional `actor2`, `text`, `row`). Optional `autonumber` flag prefixes messages.
pub fn render(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    const node = value.asNode() orelse return renderFallback(allocator);

    var actors: std.ArrayList([]const u8) = .empty;
    defer actors.deinit(allocator);
    var messages: std.ArrayList(Message) = .empty;
    defer messages.deinit(allocator);
    var blocks: std.ArrayList(Block) = .empty;
    defer blocks.deinit(allocator);
    var activations: std.ArrayList(Activation) = .empty;
    defer activations.deinit(allocator);
    var notes: std.ArrayList(Note) = .empty;
    defer notes.deinit(allocator);
    var refs: std.ArrayList(RefBox) = .empty;
    defer refs.deinit(allocator);
    var bands: std.ArrayList(ActorBand) = .empty;
    defer bands.deinit(allocator);
    var separators: std.ArrayList(Separator) = .empty;
    defer separators.deinit(allocator);
    var destroys = std.StringHashMap(usize).init(allocator); // actor → row where destroyed
    defer destroys.deinit();

    const do_autonumber = (node.getNumber("autonumber") orelse 0.0) != 0.0;

    // Activation tracking: per actor, a stack of start rows
    var act_stack = std.StringHashMap(std.ArrayList(usize)).init(allocator);
    defer {
        var it = act_stack.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit(allocator);
        act_stack.deinit();
    }

    // Parse box bands
    for (node.getList("boxes")) |bv| {
        const bn = bv.asNode() orelse continue;
        const color = bn.getString("color") orelse "";
        const label = bn.getString("label") orelse "";
        const actor_start: usize = @intFromFloat(bn.getNumber("actor_start") orelse 0);
        const actor_end: usize = @intFromFloat(bn.getNumber("actor_end") orelse 0);
        if (actor_end > actor_start)
            try bands.append(allocator, .{ .color = color, .label = label, .actor_start = actor_start, .actor_end = actor_end });
    }

    // Parse participants — track which are actor-type (stickman) vs participant (box)
    var actor_kinds = std.StringHashMap(bool).init(allocator); // true = actor stickman
    defer actor_kinds.deinit();

    const parts = node.getList("participants");
    for (parts) |pv| {
        if (pv.asNode()) |pn| {
            const name = pn.getString("actor") orelse continue;
            if (!hasActor(actors.items, name)) try actors.append(allocator, name);
            const is_actor_type = (pn.getString("is_actor") != null);
            try actor_kinds.put(name, is_actor_type);
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
        } else if (std.mem.eql(u8, msg_type, "activate")) {
            const actor = sn.getString("actor") orelse continue;
            const row: usize = @intFromFloat(sn.getNumber("row") orelse @as(f64, @floatFromInt(messages.items.len)));
            const entry = try act_stack.getOrPut(actor);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(allocator, row);
        } else if (std.mem.eql(u8, msg_type, "deactivate")) {
            const actor = sn.getString("actor") orelse continue;
            const row: usize = @intFromFloat(sn.getNumber("row") orelse @as(f64, @floatFromInt(messages.items.len)));
            if (act_stack.getPtr(actor)) |stack| {
                if (stack.items.len > 0) {
                    const start_row = stack.pop().?;
                    try activations.append(allocator, Activation{
                        .actor = actor,
                        .start_row = start_row,
                        .end_row = row,
                    });
                }
            }
        } else if (std.mem.eql(u8, msg_type, "note")) {
            const row: usize = @intFromFloat(sn.getNumber("row") orelse @as(f64, @floatFromInt(messages.items.len)));
            const text = sn.getString("text") orelse "";
            const actor1 = sn.getString("actor1") orelse "";
            const actor2 = sn.getString("actor2");
            const position = sn.getString("position") orelse "over";
            try notes.append(allocator, Note{
                .actor1 = actor1,
                .actor2 = actor2,
                .position = position,
                .text = text,
                .row = row,
            });
        } else if (std.mem.eql(u8, msg_type, "ref")) {
            const row: usize = @intFromFloat(sn.getNumber("row") orelse @as(f64, @floatFromInt(messages.items.len)));
            const actor1 = sn.getString("actor1") orelse "";
            const actor2 = sn.getString("actor2");
            const text = sn.getString("blockText") orelse "";
            try refs.append(allocator, RefBox{
                .actor1 = actor1,
                .actor2 = actor2,
                .text = text,
                .row = row,
            });
        } else if (std.mem.eql(u8, msg_type, "loopStart")) {
            const lbl = sn.getString("loopText") orelse sn.getString("blockText") orelse "";
            try blocks.append(allocator, Block{ .kind = .loop, .label = lbl, .start_row = messages.items.len });
        } else if (std.mem.eql(u8, msg_type, "loopEnd")) {
            for (blocks.items) |*b| {
                if (b.kind == .loop and b.end_row == null) { b.end_row = messages.items.len; break; }
            }
        } else if (std.mem.eql(u8, msg_type, "altStart")) {
            const lbl = sn.getString("altText") orelse sn.getString("blockText") orelse "";
            try blocks.append(allocator, Block{ .kind = .alt, .label = lbl, .start_row = messages.items.len });
        } else if (std.mem.eql(u8, msg_type, "altEnd")) {
            for (blocks.items) |*b| {
                if (b.kind == .alt and b.end_row == null) { b.end_row = messages.items.len; break; }
            }
        } else if (std.mem.eql(u8, msg_type, "optStart")) {
            const lbl = sn.getString("blockText") orelse "";
            try blocks.append(allocator, Block{ .kind = .opt, .label = lbl, .start_row = messages.items.len });
        } else if (std.mem.eql(u8, msg_type, "optEnd")) {
            for (blocks.items) |*b| {
                if (b.kind == .opt and b.end_row == null) { b.end_row = messages.items.len; break; }
            }
        } else if (std.mem.eql(u8, msg_type, "parStart")) {
            const lbl = sn.getString("blockText") orelse "";
            try blocks.append(allocator, Block{ .kind = .par, .label = lbl, .start_row = messages.items.len });
        } else if (std.mem.eql(u8, msg_type, "parEnd")) {
            for (blocks.items) |*b| {
                if (b.kind == .par and b.end_row == null) { b.end_row = messages.items.len; break; }
            }
        } else if (std.mem.eql(u8, msg_type, "rectStart")) {
            const color = sn.getString("blockText") orelse "";
            try blocks.append(allocator, Block{ .kind = .rect, .label = color, .start_row = messages.items.len });
        } else if (std.mem.eql(u8, msg_type, "rectEnd")) {
            for (blocks.items) |*b| {
                if (b.kind == .rect and b.end_row == null) { b.end_row = messages.items.len; break; }
            }
        } else if (std.mem.eql(u8, msg_type, "criticalStart")) {
            const lbl = sn.getString("blockText") orelse "";
            try blocks.append(allocator, Block{ .kind = .critical, .label = lbl, .start_row = messages.items.len });
        } else if (std.mem.eql(u8, msg_type, "criticalEnd")) {
            for (blocks.items) |*b| {
                if (b.kind == .critical and b.end_row == null) { b.end_row = messages.items.len; break; }
            }
        } else if (std.mem.eql(u8, msg_type, "breakStart")) {
            const lbl = sn.getString("blockText") orelse "";
            try blocks.append(allocator, Block{ .kind = .brk, .label = lbl, .start_row = messages.items.len });
        } else if (std.mem.eql(u8, msg_type, "breakEnd")) {
            for (blocks.items) |*b| {
                if (b.kind == .brk and b.end_row == null) { b.end_row = messages.items.len; break; }
            }
        } else if (std.mem.eql(u8, msg_type, "negStart")) {
            const lbl = sn.getString("blockText") orelse "";
            try blocks.append(allocator, Block{ .kind = .neg, .label = lbl, .start_row = messages.items.len });
        } else if (std.mem.eql(u8, msg_type, "negEnd")) {
            for (blocks.items) |*b| {
                if (b.kind == .neg and b.end_row == null) { b.end_row = messages.items.len; break; }
            }
        } else if (std.mem.eql(u8, msg_type, "blockSep")) {
            const lbl = sn.getString("label") orelse "";
            const row: usize = @intFromFloat(sn.getNumber("row") orelse @as(f64, @floatFromInt(messages.items.len)));
            try separators.append(allocator, Separator{ .label = lbl, .row = row });
        } else if (std.mem.eql(u8, msg_type, "destroy")) {
            const actor_name = sn.getString("actor") orelse continue;
            const row: usize = @intFromFloat(sn.getNumber("row") orelse @as(f64, @floatFromInt(messages.items.len)));
            try destroys.put(actor_name, row);
        }
    }

    // Close any unclosed activations
    {
        var it = act_stack.iterator();
        while (it.next()) |kv| {
            for (kv.value_ptr.items) |start_row| {
                try activations.append(allocator, Activation{
                    .actor = kv.key_ptr.*,
                    .start_row = start_row,
                    .end_row = messages.items.len,
                });
            }
        }
    }

    if (actors.items.len == 0 and messages.items.len == 0) {
        return renderFallback(allocator);
    }

    const n_actors = actors.items.len;
    const n_msgs = messages.items.len;
    // Width: span to the right edge of the last actor box, plus room for a
    // "Note right of <last actor>" (NOTE_PAD + ~100 px) and a right margin.
    const total_w: u32 = @intFromFloat(
        MARGIN_X * 2 + @as(f32, @floatFromInt(n_actors -| 1)) * LANE_GAP + ACTOR_W + NOTE_PAD + 100
    );
    const total_h: u32 = @intFromFloat(
        FIRST_MSG_Y + @as(f32, @floatFromInt(n_msgs + 1)) * ROW_H + ACTOR_H + MARGIN_Y * 2
    );

    var svg = SvgWriter.init(allocator);
    defer svg.deinit();

    try svg.header(total_w, total_h);
    try svg.defs(arrow_marker_defs);
    try svg.rect(0, 0, @floatFromInt(total_w), @floatFromInt(total_h), 0, theme.background, theme.background, 0);

    // 0. Actor group bands (box rgb(...) ... end)
    for (bands.items) |band| {
        if (band.color.len == 0) continue;
        const bx = MARGIN_X + @as(f32, @floatFromInt(band.actor_start)) * LANE_GAP - LANE_GAP / 4.0;
        const bw = @as(f32, @floatFromInt(band.actor_end - band.actor_start)) * LANE_GAP + LANE_GAP / 2.0;
        const by: f32 = ACTOR_TOP_Y;
        const bh: f32 = @as(f32, @floatFromInt(total_h)) - ACTOR_TOP_Y - MARGIN_Y;
        try svg.rect(bx, by, bw, bh, 6.0, band.color, "none", 0);
        if (band.label.len > 0)
            try svg.text(bx + bw / 2.0, by + 14, band.label, theme.text_color, theme.font_size_small, .middle, "bold");
    }

    // 1. Loop/alt/opt/par blocks (background)
    for (blocks.items) |b| {
        const end = b.end_row orelse n_msgs;
        const by = FIRST_MSG_Y + @as(f32, @floatFromInt(b.start_row)) * ROW_H - 10;
        const bh = @as(f32, @floatFromInt(end - b.start_row)) * ROW_H + 20;
        const bx: f32 = MARGIN_X - 10;
        const bw: f32 = @as(f32, @floatFromInt(total_w)) - (MARGIN_X - 10) * 2;
        if (b.kind == .rect) {
            // rect block: user-specified fill color, no border label
            const color = if (b.label.len > 0) b.label else "rgba(200,200,200,0.2)";
            try svg.rect(bx, by, bw, bh, 4.0, color, "none", 0);
            continue;
        }
        const blk_fill = switch (b.kind) {
            .loop     => "#f0f4ff",
            .alt      => "#fff8f0",
            .opt      => "#f0fff4",
            .par      => "#fdf0ff",
            .critical => "#fff0f0",
            .brk      => "#fff4e6",
            .neg      => "#f8f0ff",
            .rect     => unreachable,
        };
        const blk_stroke = switch (b.kind) {
            .loop     => "#b0c0e8",
            .alt      => "#e8c8a0",
            .opt      => "#a0d8b0",
            .par      => "#c8a0d8",
            .critical => "#e88080",
            .brk      => "#e8b070",
            .neg      => "#b080d8",
            .rect     => unreachable,
        };
        try svg.rect(bx, by, bw, bh, 4.0, blk_fill, blk_stroke, 1.0);
        var kind_label_buf: [64]u8 = undefined;
        const kind_str: []const u8 = switch (b.kind) {
            .loop => "loop", .alt => "alt", .opt => "opt", .par => "par",
            .critical => "critical", .brk => "break", .neg => "neg",
            .rect => unreachable,
        };
        const kind_label = try std.fmt.bufPrint(&kind_label_buf, "{s} {s}", .{ kind_str, b.label });
        try svg.text(bx + 4, by + 14, kind_label, theme.text_color, theme.font_size_small, .start, "normal");
    }

    // 1b. else/and separators — dashed horizontal dividers within blocks
    for (separators.items) |sep| {
        const sy = FIRST_MSG_Y + @as(f32, @floatFromInt(sep.row)) * ROW_H - ROW_H / 4.0;
        const sx: f32 = MARGIN_X - 10;
        const sw: f32 = @as(f32, @floatFromInt(total_w)) - (MARGIN_X - 10) * 2;
        try svg.dashedLine(sx, sy, sx + sw, sy, "#aaaaaa", 1.0, "4,3");
        if (sep.label.len > 0)
            try svg.text(sx + 4, sy - 3, sep.label, theme.text_color, theme.font_size_small, .start, "italic");
    }

    // 2. Lifelines
    for (actors.items, 0..) |_, i| {
        const lx = MARGIN_X + @as(f32, @floatFromInt(i)) * LANE_GAP;
        const line_x = lx + ACTOR_W / 2;
        const line_top = ACTOR_TOP_Y + ACTOR_H;
        const line_bot = @as(f32, @floatFromInt(total_h)) - ACTOR_H - MARGIN_Y;
        try svg.dashedLine(line_x, line_top, line_x, line_bot, theme.signal_color, 1.0, "4,4");
    }

    // 3. Activation bars (narrow rectangles on lifelines, stacked for nested activations)
    for (activations.items, 0..) |act, ai_idx| {
        const ai = actorIndex(actors.items, act.actor) orelse continue;
        const lx = MARGIN_X + @as(f32, @floatFromInt(ai)) * LANE_GAP;
        const cx = lx + ACTOR_W / 2;
        // Compute nesting depth: count earlier activations on same actor that contain this one
        var depth: f32 = 0;
        for (activations.items[0..ai_idx]) |prev| {
            if (!std.mem.eql(u8, prev.actor, act.actor)) continue;
            if (prev.start_row <= act.start_row and prev.end_row >= act.end_row) depth += 1;
        }
        const bar_x = cx - ACT_BAR_W / 2 + depth * (ACT_BAR_W + 2);
        const bar_y = FIRST_MSG_Y + @as(f32, @floatFromInt(act.start_row)) * ROW_H - ROW_H / 2;
        const bar_h = @as(f32, @floatFromInt(act.end_row - act.start_row)) * ROW_H + ROW_H / 2;
        try svg.rect(bar_x, bar_y, ACT_BAR_W, bar_h, 2.0,
            theme.actor_fill, theme.actor_stroke, 1.0);
    }

    // 4. Actor boxes / stickman figures + destroy X markers
    for (actors.items, 0..) |actor, i| {
        const lx = MARGIN_X + @as(f32, @floatFromInt(i)) * LANE_GAP;
        const line_bot = @as(f32, @floatFromInt(total_h)) - ACTOR_H - MARGIN_Y;
        const is_stickman = actor_kinds.get(actor) orelse false;
        if (is_stickman) {
            try drawActorStickman(&svg, lx + ACTOR_W / 2, ACTOR_TOP_Y, actor);
            try drawActorStickman(&svg, lx + ACTOR_W / 2, line_bot, actor);
        } else {
            try drawActorBox(&svg, lx, ACTOR_TOP_Y, actor);
            try drawActorBox(&svg, lx, line_bot, actor);
        }
        // Destroy marker: X on the lifeline at the destroy row
        if (destroys.get(actor)) |destroy_row| {
            const dx = lx + ACTOR_W / 2;
            const dy = FIRST_MSG_Y + @as(f32, @floatFromInt(destroy_row)) * ROW_H;
            const hs: f32 = 8;
            try svg.line(dx - hs, dy - hs, dx + hs, dy + hs, "#cc0000", 2.0);
            try svg.line(dx + hs, dy - hs, dx - hs, dy + hs, "#cc0000", 2.0);
        }
    }

    // 5. Notes (rounded rect boxes at their row positions)
    for (notes.items) |nt| {
        const a1_idx = actorIndex(actors.items, nt.actor1) orelse 0;
        const a2_idx = if (nt.actor2) |a2| actorIndex(actors.items, a2) orelse a1_idx else a1_idx;
        const min_idx = @min(a1_idx, a2_idx);
        const max_idx = @max(a1_idx, a2_idx);

        const lx_left = MARGIN_X + @as(f32, @floatFromInt(min_idx)) * LANE_GAP;
        const lx_right = MARGIN_X + @as(f32, @floatFromInt(max_idx)) * LANE_GAP;

        const note_x: f32 = switch (positionKind(nt.position)) {
            .right => lx_left + ACTOR_W + NOTE_PAD,
            .left => lx_left - NOTE_PAD - 100,
            .over => lx_left + NOTE_PAD,
        };
        const note_w: f32 = switch (positionKind(nt.position)) {
            .over => lx_right + ACTOR_W - lx_left - NOTE_PAD * 2,
            else => 100,
        };
        const note_y = FIRST_MSG_Y + @as(f32, @floatFromInt(nt.row)) * ROW_H - NOTE_H / 2 - 4;

        try svg.rect(note_x, note_y, @max(note_w, 80), NOTE_H, 4.0, "#fffde7", "#f0c040", 1.2);
        try svg.text(note_x + @max(note_w, 80) / 2, note_y + NOTE_H / 2 + 4,
            nt.text, theme.text_color, theme.font_size_small, .middle, "normal");
    }

    // 5b. Ref boxes (UML "ref" interaction fragments — dashed rectangle spanning actors)
    for (refs.items) |rb| {
        const a1_idx = actorIndex(actors.items, rb.actor1) orelse 0;
        const a2_idx = if (rb.actor2) |a2| actorIndex(actors.items, a2) orelse a1_idx else a1_idx;
        const min_idx = @min(a1_idx, a2_idx);
        const max_idx = @max(a1_idx, a2_idx);

        // Span from left edge of min actor to right edge of max actor, with padding
        const bx = MARGIN_X + @as(f32, @floatFromInt(min_idx)) * LANE_GAP - ACTOR_W * 0.1;
        const bw = @as(f32, @floatFromInt(max_idx - min_idx)) * LANE_GAP + ACTOR_W * 1.2;
        const ref_h: f32 = ROW_H - 8;
        const by = FIRST_MSG_Y + @as(f32, @floatFromInt(rb.row)) * ROW_H - ref_h / 2 + 2;

        // Dashed-border background box
        var path_buf: [256]u8 = undefined;
        const path_d = try std.fmt.bufPrint(&path_buf,
            "M {d:.1},{d:.1} L {d:.1},{d:.1} L {d:.1},{d:.1} L {d:.1},{d:.1} Z",
            .{ bx, by, bx + bw, by, bx + bw, by + ref_h, bx, by + ref_h });
        try svg.path(path_d, "#f0f4ff", "#6688cc", 1.2, "stroke-dasharray=\"6,3\"");
        // "ref" corner label box (solid fill, small)
        const ref_lbl_w: f32 = 26;
        const ref_lbl_h: f32 = 14;
        try svg.rect(bx, by, ref_lbl_w, ref_lbl_h, 0, "#6688cc", "#6688cc", 0);
        try svg.text(bx + ref_lbl_w / 2, by + ref_lbl_h / 2 + 4, "ref", "#ffffff", 9, .middle, "bold");
        // Description text centered in the box
        if (rb.text.len > 0) {
            try svg.text(bx + bw / 2, by + ref_h / 2 + 4, rb.text, theme.text_color, theme.font_size_small, .middle, "normal");
        }
    }

    // 6. Messages
    var msg_counter: usize = 0;
    for (messages.items, 0..) |msg, mi| {
        const my = FIRST_MSG_Y + @as(f32, @floatFromInt(mi)) * ROW_H + ROW_H / 2;
        msg_counter += 1;

        const from_idx = actorIndex(actors.items, msg.from) orelse 0;
        const to_idx = actorIndex(actors.items, msg.to) orelse 0;

        const fx = MARGIN_X + @as(f32, @floatFromInt(from_idx)) * LANE_GAP + ACTOR_W / 2;
        const tx = MARGIN_X + @as(f32, @floatFromInt(to_idx)) * LANE_GAP + ACTOR_W / 2;

        // Build display text (with optional autonumber prefix)
        var label_buf: [256]u8 = undefined;
        const display_text = if (do_autonumber)
            std.fmt.bufPrint(&label_buf, "{d}. {s}", .{ msg_counter, msg.text }) catch msg.text
        else
            msg.text;

        if (from_idx == to_idx) {
            // Self-message: right-bracket shape
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
            var pts_buf: [128]u8 = undefined;
            const pts = try std.fmt.bufPrint(&pts_buf,
                "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                .{ fx + arr, my + loop_h - arr / 2, fx, my + loop_h, fx + arr, my + loop_h + arr / 2 });
            try svg.polygon(pts, theme.signal_color, theme.signal_color, 1.0);
            try svg.text(fx + loop_w / 2, my - 6, display_text, theme.text_color, theme.font_size_small, .start, "normal");
        } else {
            if (msg.dotted) {
                try svg.dashedLine(fx, my, tx, my, theme.signal_color, 1.5, "5,3");
            } else {
                try svg.line(fx, my, tx, my, theme.signal_color, 1.5);
            }
            const dir: f32 = if (tx > fx) 1.0 else -1.0;
            const arr: f32 = 8.0;
            var pts_buf: [128]u8 = undefined;
            if (msg.arrow_kind == .point) {
                // Point arrowhead: small filled circle at target
                try svg.circle(tx, my, arr / 2, theme.signal_color, theme.signal_color, 0);
            } else {
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
                    .point => unreachable,
                };
                try svg.polygon(pts, theme.signal_color, theme.signal_color, 1.0);
            }
            try svg.text((fx + tx) / 2, my - 6, display_text, theme.text_color, theme.font_size_small, .middle, "normal");
        }
    }

    try svg.footer();
    return svg.toOwnedSlice();
}

fn drawActorBox(svg: *SvgWriter, x: f32, y: f32, name: []const u8) !void {
    try svg.rect(x, y, ACTOR_W, ACTOR_H, 4.0, theme.actor_fill, theme.actor_stroke, 1.5);
    try svg.text(x + ACTOR_W / 2, y + ACTOR_H / 2 + 4, name, theme.text_color, theme.font_size, .middle, "normal");
}

fn drawActorStickman(svg: *SvgWriter, cx: f32, top_y: f32, name: []const u8) !void {
    // Stickman: head circle, body line, arms, legs.  Total height = ACTOR_H.
    const head_r: f32 = 8;
    const body_top = top_y + head_r * 2;
    const body_bot = top_y + ACTOR_H - 10;
    const arm_y   = body_top + (body_bot - body_top) * 0.35;
    const arm_span: f32 = 14;
    const leg_span: f32 = 10;
    try svg.circle(cx, top_y + head_r, head_r, theme.actor_fill, theme.actor_stroke, 1.5);
    try svg.line(cx, body_top, cx, body_bot, theme.actor_stroke, 1.5);
    try svg.line(cx - arm_span, arm_y, cx + arm_span, arm_y, theme.actor_stroke, 1.5);
    try svg.line(cx, body_bot, cx - leg_span, top_y + ACTOR_H, theme.actor_stroke, 1.5);
    try svg.line(cx, body_bot, cx + leg_span, top_y + ACTOR_H, theme.actor_stroke, 1.5);
    try svg.text(cx, top_y + ACTOR_H + 12, name, theme.text_color, theme.font_size_small, .middle, "normal");
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
    const n = std.fmt.parseInt(u32, signal_type, 10) catch return false;
    return n % 2 == 1;
}

const ArrowKind = enum { filled, open, cross, point };

fn arrowKind(signal_type: []const u8) ArrowKind {
    if (std.mem.indexOf(u8, signal_type, "CROSS") != null) return .cross;
    if (std.mem.indexOf(u8, signal_type, "OPEN") != null) return .open;
    if (std.mem.indexOf(u8, signal_type, "POINT") != null) return .point;
    return .filled;
}

const PosKind = enum { over, right, left };

fn positionKind(s: []const u8) PosKind {
    if (std.mem.eql(u8, s, "right")) return .right;
    if (std.mem.eql(u8, s, "left")) return .left;
    return .over;
}

const Block = struct {
    kind: enum { loop, alt, opt, par, rect, critical, brk, neg },
    label: []const u8,   // for rect: the color string
    start_row: usize,
    end_row: ?usize = null,
};

const Separator = struct {
    label: []const u8,
    row: usize,
};

const ActorBand = struct {
    color: []const u8,
    label: []const u8,
    actor_start: usize,
    actor_end: usize,
};

const Message = struct {
    from: []const u8,
    to: []const u8,
    text: []const u8,
    dotted: bool,
    arrow_kind: ArrowKind,
};

const Activation = struct {
    actor: []const u8,
    start_row: usize,
    end_row: usize,
};

const Note = struct {
    actor1: []const u8,
    actor2: ?[]const u8,
    position: []const u8,
    text: []const u8,
    row: usize,
};

/// UML "ref" interaction fragment — a box spanning specified actors that
/// references another interaction by name/label.
const RefBox = struct {
    actor1: []const u8,
    actor2: ?[]const u8, // if null, only span actor1's lane
    text: []const u8,
    row: usize,
};

fn renderFallback(allocator: std.mem.Allocator) ![]const u8 {
    var svg = SvgWriter.init(allocator);
    defer svg.deinit();
    try svg.header(400, 200);
    try svg.text(200, 100, "sequenceDiagram", theme.text_color, theme.font_size, .middle, "normal");
    try svg.footer();
    return svg.toOwnedSlice();
}
