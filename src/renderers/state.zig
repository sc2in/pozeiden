//! State diagram SVG renderer.
//! Expects a Value.node with `states` (list of nodes with `id` and optional `label`)
//! and `transitions` (list of nodes with `from`, `to`, and optional `label`).
//! States are placed in rows by BFS depth from `[*]` (or the first state); transitions
//! are drawn as directed arrows between state box centres.
const std = @import("std");
const Value = @import("../diagram/value.zig").Value;
const SvgWriter = @import("../svg/writer.zig").SvgWriter;
const theme = @import("../svg/theme.zig");

const STATE_W: f32 = 140;
const STATE_H: f32 = 36;
const COL_GAP: f32 = 80;
const ROW_GAP: f32 = 60;
const MARGIN: f32 = 40;
const START_R: f32 = 10;

const State = struct {
    id: []const u8,
    label: []const u8,
    shape: []const u8, // "" = normal rect, "fork"/"join" = bar, "choice" = diamond
    depth: usize,
    col: usize, // column within its depth row
};

const Transition = struct {
    from: []const u8,
    to: []const u8,
    label: []const u8,
};

/// Render a state diagram SVG from `value`.
/// `value` must be a node with `states` (list of nodes with `id` and optional `label`)
/// and `transitions` (list of nodes with `from`, `to`, and optional `label`).
/// States are placed in BFS-depth rows from `[*]`; arrows connect state box centres.
pub fn render(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    const node = value.asNode() orelse return renderFallback(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var states: std.ArrayList(State) = .empty;
    var transitions: std.ArrayList(Transition) = .empty;
    var seen = std.StringHashMap(void).init(a);

    // Helper: ensure state exists (shape = "" for normal states)
    const ensureState = struct {
        fn run(sl: *std.ArrayList(State), s_map: *std.StringHashMap(void), alloc: std.mem.Allocator, id: []const u8, lbl: []const u8) !void {
            if (s_map.get(id) != null) return;
            try s_map.put(id, {});
            try sl.append(alloc, State{ .id = id, .label = lbl, .shape = "", .depth = 0, .col = 0 });
        }
    }.run;

    for (node.getList("states")) |sv| {
        const sn = sv.asNode() orelse continue;
        const id = sn.getString("id") orelse continue;
        const lbl = sn.getString("label") orelse id;
        const shp = sn.getString("shape") orelse "";
        if (seen.get(id) != null) continue;
        try seen.put(id, {});
        try states.append(a, State{ .id = id, .label = lbl, .shape = shp, .depth = 0, .col = 0 });
    }

    for (node.getList("transitions")) |tv| {
        const tn = tv.asNode() orelse continue;
        const from = tn.getString("from") orelse continue;
        const to = tn.getString("to") orelse continue;
        const lbl = tn.getString("label") orelse "";
        try ensureState(&states, &seen, a, from, from);
        try ensureState(&states, &seen, a, to, to);
        try transitions.append(a, Transition{ .from = from, .to = to, .label = lbl });
    }

    if (states.items.len == 0) return renderFallback(allocator);

    // BFS to assign depths
    var depth_map = std.StringHashMap(usize).init(a);
    // Find start: nodes with no incoming edge (or explicit [*])
    var queue: std.ArrayList([]const u8) = .empty;
    if (seen.get("[*]") != null) {
        try depth_map.put("[*]", 0);
        try queue.append(a, "[*]");
    } else {
        // Use first state
        try depth_map.put(states.items[0].id, 0);
        try queue.append(a, states.items[0].id);
    }
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const cur = queue.items[qi];
        const cur_depth = depth_map.get(cur) orelse 0;
        for (transitions.items) |t| {
            if (!std.mem.eql(u8, t.from, cur)) continue;
            if (depth_map.get(t.to) != null) continue;
            try depth_map.put(t.to, cur_depth + 1);
            try queue.append(a, t.to);
        }
    }
    // Any unreachable states get depth = max+1
    var max_depth: usize = 0;
    for (states.items) |s| {
        if (depth_map.get(s.id)) |d| { if (d > max_depth) max_depth = d; }
    }
    for (states.items) |*s| {
        s.depth = depth_map.get(s.id) orelse max_depth + 1;
    }

    // Assign columns within each row
    var col_count = [_]usize{0} ** 128;
    for (states.items) |*s| {
        if (s.depth < 128) {
            s.col = col_count[s.depth];
            col_count[s.depth] += 1;
        }
    }

    // Compute canvas size
    var max_col: usize = 0;
    for (col_count[0..max_depth + 2]) |c| { if (c > max_col) max_col = c; }
    const n_rows = max_depth + 2;

    const total_w: u32 = @intFromFloat(
        MARGIN * 2 + @as(f32, @floatFromInt(if (max_col > 0) max_col else 1)) * (STATE_W + COL_GAP) - COL_GAP
    );
    const total_h: u32 = @intFromFloat(
        MARGIN * 2 + @as(f32, @floatFromInt(n_rows)) * (STATE_H + ROW_GAP)
    );

    var svg = SvgWriter.init(allocator);
    defer svg.deinit();

    try svg.header(total_w, total_h);
    try svg.rect(0, 0, @floatFromInt(total_w), @floatFromInt(total_h), 0, theme.background, theme.background, 0);

    // Helper: get state center
    const stateX = struct {
        fn get(col: usize) f32 {
            return MARGIN + @as(f32, @floatFromInt(col)) * (STATE_W + COL_GAP) + STATE_W / 2;
        }
    }.get;
    const stateY = struct {
        fn get(depth: usize) f32 {
            return MARGIN + @as(f32, @floatFromInt(depth)) * (STATE_H + ROW_GAP) + STATE_H / 2;
        }
    }.get;

    // Draw transitions first
    for (transitions.items) |t| {
        const fi = stateIndex(states.items, t.from) orelse continue;
        const ti = stateIndex(states.items, t.to) orelse continue;
        const fs = states.items[fi];
        const ts = states.items[ti];

        const fx = stateX(fs.col);
        const fy = stateY(fs.depth);
        const tx = stateX(ts.col);
        const ty = stateY(ts.depth);

        // From center-bottom to center-top (or bend for same-depth)
        const from_y = fy + (if (std.mem.eql(u8, t.from, "[*]")) START_R else STATE_H / 2);
        const to_y = ty - (if (std.mem.eql(u8, t.to, "[*]")) START_R else STATE_H / 2);

        try svg.line(fx, from_y, tx, to_y, theme.edge_color, 1.5);

        // Arrowhead at destination
        const dx = tx - fx;
        const dy = to_y - from_y;
        const dlen = @sqrt(dx * dx + dy * dy);
        if (dlen > 1.0) {
            const ux = dx / dlen;
            const uy = dy / dlen;
            const arr: f32 = 8.0;
            var pts_buf: [192]u8 = undefined;
            const pts = try std.fmt.bufPrint(&pts_buf,
                "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                .{ tx - ux * arr - uy * arr / 2, to_y - uy * arr + ux * arr / 2,
                   tx, to_y,
                   tx - ux * arr + uy * arr / 2, to_y - uy * arr - ux * arr / 2 });
            try svg.polygon(pts, theme.edge_color, theme.edge_color, 1.0);
        }

        if (t.label.len > 0) {
            try svg.text((fx + tx) / 2 + 4, (from_y + to_y) / 2 - 6, t.label, theme.text_color, theme.font_size_small, .start, "normal");
        }
    }

    // Draw states
    for (states.items) |s| {
        const cx = stateX(s.col);
        const cy = stateY(s.depth);

        if (std.mem.eql(u8, s.id, "[*]")) {
            // Start/end: filled circle
            try svg.circle(cx, cy, START_R, theme.edge_color, theme.edge_color, 0);
        } else if (std.mem.eql(u8, s.shape, "fork") or std.mem.eql(u8, s.shape, "join")) {
            // Fork/join: filled horizontal bar (wide, short)
            const bar_w: f32 = STATE_W * 0.8;
            const bar_h: f32 = 8;
            try svg.rect(cx - bar_w / 2, cy - bar_h / 2, bar_w, bar_h, 0, theme.edge_color, theme.edge_color, 0);
        } else if (std.mem.eql(u8, s.shape, "choice")) {
            // Choice: diamond
            const hw: f32 = STATE_W * 0.35;
            const hh: f32 = STATE_H * 0.55;
            var pts_buf: [192]u8 = undefined;
            const pts = try std.fmt.bufPrint(&pts_buf,
                "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                .{ cx, cy - hh, cx + hw, cy, cx, cy + hh, cx - hw, cy });
            try svg.polygon(pts, theme.node_fill, theme.node_stroke, 1.5);
        } else {
            try svg.rect(cx - STATE_W / 2, cy - STATE_H / 2, STATE_W, STATE_H, 18.0, theme.node_fill, theme.node_stroke, 1.5);
            try svg.text(cx, cy + 5, s.label, theme.text_color, theme.font_size, .middle, "normal");
        }
    }

    try svg.footer();
    return svg.toOwnedSlice();
}

fn stateIndex(states: []const State, id: []const u8) ?usize {
    for (states, 0..) |s, i| if (std.mem.eql(u8, s.id, id)) return i;
    return null;
}

fn renderFallback(allocator: std.mem.Allocator) ![]const u8 {
    var svg = SvgWriter.init(allocator);
    defer svg.deinit();
    try svg.header(400, 200);
    try svg.text(200, 100, "stateDiagram", theme.text_color, theme.font_size, .middle, "normal");
    try svg.footer();
    return svg.toOwnedSlice();
}
