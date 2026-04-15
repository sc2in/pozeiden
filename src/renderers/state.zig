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

    const base_w: f32 = MARGIN * 2 +
        @as(f32, @floatFromInt(if (max_col > 0) max_col else 1)) * (STATE_W + COL_GAP) - COL_GAP;

    // Back edges route laterally to the right; ensure canvas is wide enough.
    var back_edge_max_x: f32 = 0;
    for (transitions.items) |t| {
        const fi2 = stateIndex(states.items, t.from) orelse continue;
        const ti2 = stateIndex(states.items, t.to) orelse continue;
        const fs2 = states.items[fi2];
        const ts2 = states.items[ti2];
        if (fs2.depth > ts2.depth) {
            const layer_diff: f32 = @floatFromInt(fs2.depth - ts2.depth);
            const lateral: f32 = @max(COL_GAP * 2.0, layer_diff * STATE_W * 0.4 + COL_GAP);
            const right_x = MARGIN + @as(f32, @floatFromInt(fs2.col)) * (STATE_W + COL_GAP) +
                STATE_W + lateral + MARGIN;
            if (right_x > back_edge_max_x) back_edge_max_x = right_x;
        }
    }

    const total_w: u32 = @intFromFloat(@max(base_w, back_edge_max_x));
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

    // Draw compound state containers (concurrent regions) — drawn first so states sit on top
    for (node.getList("compounds")) |cv| {
        const cn = cv.asNode() orelse continue;
        const comp_id = cn.getString("id") orelse continue;
        const members_list = cn.getList("members");
        const dividers = cn.getNumber("dividers") orelse 0;
        const num_dividers: usize = @intFromFloat(dividers);

        var c_min_col: usize = std.math.maxInt(usize);
        var c_max_col: usize = 0;
        var c_min_depth: usize = std.math.maxInt(usize);
        var c_max_depth: usize = 0;
        var member_found = false;
        for (members_list) |mv| {
            const mid = mv.asString() orelse continue;
            const si = stateIndex(states.items, mid) orelse continue;
            const s = states.items[si];
            member_found = true;
            if (s.col < c_min_col) c_min_col = s.col;
            if (s.col > c_max_col) c_max_col = s.col;
            if (s.depth < c_min_depth) c_min_depth = s.depth;
            if (s.depth > c_max_depth) c_max_depth = s.depth;
        }
        if (!member_found) continue;

        const COMP_PAD: f32 = 18;
        const bx = stateX(c_min_col) - STATE_W / 2 - COMP_PAD;
        const by = stateY(c_min_depth) - STATE_H / 2 - COMP_PAD;
        const bw = stateX(c_max_col) + STATE_W / 2 + COMP_PAD - bx;
        const bh = stateY(c_max_depth) + STATE_H / 2 + COMP_PAD - by;

        try svg.rect(bx, by, bw, bh, 6.0, "none", theme.node_stroke, 1.5);
        try svg.text(bx + 8, by + 14, comp_id, theme.text_color, theme.font_size_small, .start, "bold");

        if (num_dividers > 0) {
            const num_regions: f32 = @floatFromInt(num_dividers + 1);
            for (0..num_dividers) |di| {
                const div_y = by + (@as(f32, @floatFromInt(di + 1)) / num_regions) * bh;
                var div_buf: [128]u8 = undefined;
                const div_d = try std.fmt.bufPrint(&div_buf,
                    "M {d:.1} {d:.1} L {d:.1} {d:.1}", .{ bx, div_y, bx + bw, div_y });
                try svg.path(div_d, "none", theme.node_stroke, 1.0, "stroke-dasharray=\"5,3\"");
            }
        }
    }

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
        const stroke = theme.edge_color;
        const sw: f32 = 1.5;

        // ── Self-loop ─────────────────────────────────────────────────────
        if (std.mem.eql(u8, t.from, t.to)) {
            const lp: f32 = 38.0;
            const ex = fx - STATE_W / 2.0; // left edge of the state box
            const y1 = fy - 14.0;
            const y2 = fy + 14.0;
            var loop_buf: [256]u8 = undefined;
            const loop_d = try std.fmt.bufPrint(&loop_buf,
                "M {d:.1} {d:.1} C {d:.1} {d:.1} {d:.1} {d:.1} {d:.1} {d:.1}",
                .{ ex, y1, ex - lp, y1, ex - lp, y2, ex, y2 });
            try svg.path(loop_d, "none", stroke, sw, "");
            // Tangent at t=1: (ex,y2)-(ex-lp,y2) = (lp,0) → arrowhead points right
            const arr: f32 = 8.0;
            const half: f32 = 4.5;
            var pts_buf: [128]u8 = undefined;
            const pts = try std.fmt.bufPrint(&pts_buf,
                "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                .{ ex - arr, y2 - half, ex, y2, ex - arr, y2 + half });
            try svg.polygon(pts, stroke, stroke, 1.0);
            if (t.label.len > 0) {
                try svg.text(ex - lp / 2.0, fy - 8.0, t.label, theme.text_color, theme.font_size_small, .middle, "normal");
            }
            continue;
        }

        // ── Cubic Bezier path ─────────────────────────────────────────────
        // Connection points and control points vary by edge type.
        var pfx: f32 = fx;
        var pfy: f32 = fy;
        var ptx: f32 = tx;
        var pty: f32 = ty;
        var cx1: f32 = 0;
        var cy1: f32 = 0;
        var cx2: f32 = 0;
        var cy2: f32 = 0;

        if (fs.depth == ts.depth) {
            // Same depth row: connect side-to-side with a horizontal arc
            const ctrl: f32 = COL_GAP * 0.8;
            if (tx >= fx) {
                pfx = fx + STATE_W / 2.0; ptx = tx - STATE_W / 2.0;
                cx1 = pfx + ctrl; cy1 = pfy;
                cx2 = ptx - ctrl; cy2 = pty;
            } else {
                pfx = fx - STATE_W / 2.0; ptx = tx + STATE_W / 2.0;
                cx1 = pfx - ctrl; cy1 = pfy;
                cx2 = ptx + ctrl; cy2 = pty;
            }
        } else if (fs.depth < ts.depth) {
            // Forward edge: exit bottom-center, enter top-center
            pfy = fy + (if (std.mem.eql(u8, t.from, "[*]")) START_R else STATE_H / 2.0);
            pty = ty - (if (std.mem.eql(u8, t.to, "[*]")) START_R else STATE_H / 2.0);
            const ctrl: f32 = ROW_GAP * 0.6;
            cx1 = pfx; cy1 = pfy + ctrl;
            cx2 = ptx; cy2 = pty - ctrl;
        } else {
            // Back edge: route around the right side
            const layer_diff: f32 = @floatFromInt(fs.depth - ts.depth);
            const lateral: f32 = @max(COL_GAP * 2.0, layer_diff * STATE_W * 0.4 + COL_GAP);
            pfx = fx + STATE_W / 2.0; ptx = tx + STATE_W / 2.0;
            cx1 = pfx + lateral; cy1 = pfy;
            cx2 = ptx + lateral; cy2 = pty;
        }

        var path_buf: [256]u8 = undefined;
        const path_d = try std.fmt.bufPrint(&path_buf,
            "M {d:.1} {d:.1} C {d:.1} {d:.1} {d:.1} {d:.1} {d:.1} {d:.1}",
            .{ pfx, pfy, cx1, cy1, cx2, cy2, ptx, pty });
        try svg.path(path_d, "none", stroke, sw, "");

        // Arrowhead: tangent at Bezier t=1 is (P3 - C2)
        const tang_x = ptx - cx2;
        const tang_y = pty - cy2;
        const tang_len = @sqrt(tang_x * tang_x + tang_y * tang_y);
        if (tang_len > 0.5) {
            const ux = tang_x / tang_len;
            const uy = tang_y / tang_len;
            const arr: f32 = 8.0;
            const half: f32 = 4.5;
            var pts_buf: [192]u8 = undefined;
            const pts = try std.fmt.bufPrint(&pts_buf,
                "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                .{
                    ptx - ux * arr - uy * half,
                    pty - uy * arr + ux * half,
                    ptx, pty,
                    ptx - ux * arr + uy * half,
                    pty - uy * arr - ux * half,
                });
            try svg.polygon(pts, stroke, stroke, 1.0);
        }

        if (t.label.len > 0) {
            const mid_x = 0.125 * pfx + 0.375 * cx1 + 0.375 * cx2 + 0.125 * ptx;
            const mid_y = 0.125 * pfy + 0.375 * cy1 + 0.375 * cy2 + 0.125 * pty;
            try svg.text(mid_x + 4, mid_y - 6, t.label, theme.text_color, theme.font_size_small, .start, "normal");
        }
    }

    // Draw states
    for (states.items) |s| {
        const cx = stateX(s.col);
        const cy = stateY(s.depth);

        if (std.mem.eql(u8, s.id, "[*]")) {
            // Initial pseudo-state: filled circle
            try svg.circle(cx, cy, START_R, theme.edge_color, theme.edge_color, 0);
        } else if (std.mem.eql(u8, s.id, "[*]-end")) {
            // Final pseudo-state: filled circle inside a ring (double circle)
            try svg.circle(cx, cy, START_R + 5, "none", theme.edge_color, 2.0);
            try svg.circle(cx, cy, START_R - 1, theme.edge_color, theme.edge_color, 0);
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
        } else if (std.mem.eql(u8, s.shape, "history") or std.mem.eql(u8, s.shape, "deepHistory")) {
            // Shallow history [H] or deep history [H*]: circle with label inside
            const r: f32 = START_R + 4;
            try svg.circle(cx, cy, r, theme.node_fill, theme.node_stroke, 1.5);
            const hist_lbl = if (std.mem.eql(u8, s.shape, "deepHistory")) "H*" else "H";
            try svg.text(cx, cy + 4, hist_lbl, theme.text_color, 10, .middle, "bold");
        } else {
            try svg.rect(cx - STATE_W / 2, cy - STATE_H / 2, STATE_W, STATE_H, 18.0, theme.node_fill, theme.node_stroke, 1.5);
            try svg.textWrapped(cx, cy + 5, s.label, STATE_W - 8, theme.text_color, theme.font_size, .middle, "normal");
        }
    }

    // Draw notes (sticky-note boxes anchored to the right or left of their target state)
    for (node.getList("notes")) |nv| {
        const nn = nv.asNode() orelse continue;
        const state_id = nn.getString("state") orelse continue;
        const text = nn.getString("text") orelse continue;
        const position = nn.getString("position") orelse "right";
        const si = stateIndex(states.items, state_id) orelse continue;
        const s = states.items[si];
        const sx = stateX(s.col);
        const sy = stateY(s.depth);
        const NOTE_W: f32 = 110;
        const NOTE_H2: f32 = 32;
        const nx: f32 = if (std.mem.eql(u8, position, "left"))
            sx - STATE_W / 2 - NOTE_W - 12
        else
            sx + STATE_W / 2 + 12;
        try svg.rect(nx, sy - NOTE_H2 / 2, NOTE_W, NOTE_H2, 4.0, "#fffde7", "#f0c040", 1.2);
        // Connector line from note to state edge
        const conn_x: f32 = if (std.mem.eql(u8, position, "left")) nx + NOTE_W else nx;
        const state_edge_x: f32 = if (std.mem.eql(u8, position, "left"))
            sx - STATE_W / 2 else sx + STATE_W / 2;
        try svg.dashedLine(conn_x, sy, state_edge_x, sy, "#aaaaaa", 1.0, "4,3");
        try svg.text(nx + NOTE_W / 2, sy + 5, text, theme.text_color, theme.font_size_small, .middle, "normal");
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
