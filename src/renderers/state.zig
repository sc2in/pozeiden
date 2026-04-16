//! State diagram SVG renderer.
//! Supports compound (nested) states with hierarchical two-pass layout so that
//! member states are guaranteed to live inside their compound box, never
//! overlapping sibling top-level states.  Concurrent orthogonal regions
//! (separated by `--`) are laid out side-by-side within the compound.
const std = @import("std");
const Value = @import("../diagram/value.zig").Value;
const SvgWriter = @import("../svg/writer.zig").SvgWriter;
const theme = @import("../svg/theme.zig");

const STATE_W: f32 = 140;
const STATE_H: f32 = 36;
const COL_GAP: f32 = 60;
const ROW_GAP: f32 = 50;
const MARGIN: f32 = 50;
const START_R: f32 = 10;
const COMP_PAD: f32 = 18;
const COMP_LABEL_H: f32 = 22;
const REGION_GAP: f32 = 2; // width of the dashed divider line area between regions

const State = struct {
    id: []const u8,
    label: []const u8,
    shape: []const u8,
    // Global grid (non-member states only)
    depth: usize = 0,
    col: usize = 0,
    // Compound membership
    is_member: bool = false,
    is_compound: bool = false, // true = compound header (rendered as box, not rect)
    compound_id: ?[]const u8 = null,
    // Local grid within compound (member states only)
    local_col: usize = 0,
    local_depth: usize = 0,
    region_idx: usize = 0, // which concurrent region this member belongs to
    // Final rendered centre position (pixels)
    px: f32 = 0,
    py: f32 = 0,
    // Compound box dimensions (compound states only)
    box_w: f32 = 0,
    box_h: f32 = 0,
};

const Transition = struct {
    from: []const u8,
    to: []const u8,
    label: []const u8,
};

/// Compute (max_col+1, max_depth+1) for a set of member states within `region_members`.
/// Returns the grid size as {cols, rows}.
fn regionGridSize(states: []const State, member_ids: []const []const u8) struct { cols: usize, rows: usize } {
    var max_col: usize = 0;
    var max_depth: usize = 0;
    for (member_ids) |mid| {
        for (states) |s| {
            if (!std.mem.eql(u8, s.id, mid)) continue;
            if (s.local_col > max_col) max_col = s.local_col;
            if (s.local_depth > max_depth) max_depth = s.local_depth;
        }
    }
    return .{ .cols = max_col + 1, .rows = max_depth + 1 };
}

/// Run BFS starting from `start_id` following only transitions whose both
/// endpoints are in `member_set`, assigning `local_col`/`local_depth` to
/// states whose IDs are found in `member_set`.  Returns max_depth reached.
fn localBfs(
    states: []State,
    transitions: []const Transition,
    member_set: std.StringHashMap(void),
    start_id: []const u8,
    region_i: usize,
    allocator: std.mem.Allocator,
) !usize {
    var local_depth_map = std.StringHashMap(usize).init(allocator);
    defer local_depth_map.deinit();

    var queue: std.ArrayList([]const u8) = .empty;

    if (member_set.get(start_id) != null) {
        try local_depth_map.put(start_id, 0);
        try queue.append(allocator, start_id);
    } else {
        // start_id not in member set — pick first member for this region
        for (states) |s| {
            if (s.compound_id != null and std.mem.eql(u8, s.compound_id.?, start_id)) {
                if (s.region_idx != region_i) continue;
                try local_depth_map.put(s.id, 0);
                try queue.append(allocator, s.id);
                break;
            }
        }
    }

    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const cur = queue.items[qi];
        const cur_depth = local_depth_map.get(cur) orelse 0;
        for (transitions) |t| {
            if (!std.mem.eql(u8, t.from, cur)) continue;
            if (member_set.get(t.to) == null) continue;
            if (local_depth_map.get(t.to) != null) continue;
            try local_depth_map.put(t.to, cur_depth + 1);
            try queue.append(allocator, t.to);
        }
    }

    // Any member not reached gets depth = max + 1
    var max_d: usize = 0;
    for (states) |s| {
        if (!s.is_member or s.region_idx != region_i) continue;
        if (s.compound_id == null) continue;
        if (local_depth_map.get(s.id)) |d| { if (d > max_d) max_d = d; }
    }
    for (states) |*s| {
        if (!s.is_member or s.region_idx != region_i) continue;
        if (member_set.get(s.id) == null) continue;
        s.local_depth = local_depth_map.get(s.id) orelse max_d + 1;
    }

    // Assign local columns (within depth row, ordered by queue encounter order)
    var col_count = [_]usize{0} ** 64;
    for (queue.items) |qid| {
        for (states) |*s| {
            if (!std.mem.eql(u8, s.id, qid)) continue;
            if (!s.is_member or s.region_idx != region_i) continue;
            const d = s.local_depth;
            s.local_col = if (d < 64) blk: {
                const c = col_count[d];
                col_count[d] += 1;
                break :blk c;
            } else 0;
        }
    }
    // Members not in queue (unreachable from start)
    for (states) |*s| {
        if (!s.is_member or s.region_idx != region_i) continue;
        if (local_depth_map.get(s.id) != null) continue; // already handled
        const d = s.local_depth;
        s.local_col = if (d < 64) blk: {
            const c = col_count[d];
            col_count[d] += 1;
            break :blk c;
        } else 0;
    }

    return max_d;
}

/// Render a state diagram SVG from `value`.
/// `value` must be a node with `states`, `transitions`, `compounds`, and `notes` lists.
pub fn render(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    const node = value.asNode() orelse return renderFallback(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var states: std.ArrayList(State) = .empty;
    var transitions: std.ArrayList(Transition) = .empty;
    var seen = std.StringHashMap(void).init(a);

    const ensureState = struct {
        fn run(sl: *std.ArrayList(State), s_map: *std.StringHashMap(void), alloc: std.mem.Allocator, id: []const u8, lbl: []const u8, shp: []const u8) !void {
            if (s_map.get(id) != null) return;
            try s_map.put(id, {});
            try sl.append(alloc, State{ .id = id, .label = lbl, .shape = shp });
        }
    }.run;

    for (node.getList("states")) |sv| {
        const sn = sv.asNode() orelse continue;
        const id = sn.getString("id") orelse continue;
        const lbl = sn.getString("label") orelse id;
        const shp = sn.getString("shape") orelse "";
        if (seen.get(id) != null) continue;
        try seen.put(id, {});
        try states.append(a, State{ .id = id, .label = lbl, .shape = shp });
    }

    for (node.getList("transitions")) |tv| {
        const tn = tv.asNode() orelse continue;
        const from = tn.getString("from") orelse continue;
        const to = tn.getString("to") orelse continue;
        const lbl = tn.getString("label") orelse "";
        try ensureState(&states, &seen, a, from, from, "");
        try ensureState(&states, &seen, a, to, to, "");
        try transitions.append(a, Transition{ .from = from, .to = to, .label = lbl });
    }

    if (states.items.len == 0) return renderFallback(allocator);

    // ── Step 1: Identify compound headers and members ─────────────────────────
    //
    // `compounds` is a list of nodes with:
    //   - id: compound header state id
    //   - regions: list of lists of member state ids (one list per concurrent region)
    //     (fallback: `members` flat list treated as single region)
    //
    // We build:
    //   member_to_compound: state_id → compound_id
    //   compound_regions: compound_id → list of (region_idx, member_ids slice)
    var member_to_compound = std.StringHashMap([]const u8).init(a);
    var compound_ids_set = std.StringHashMap(void).init(a);

    // Collect all compound member assignments
    const compounds_val = node.getList("compounds");
    for (compounds_val) |cv| {
        const cn = cv.asNode() orelse continue;
        const comp_id = cn.getString("id") orelse continue;
        try compound_ids_set.put(comp_id, {});

        // Try `regions` first (list of lists), fall back to flat `members`
        const regions_val = cn.getList("regions");
        if (regions_val.len > 0) {
            for (regions_val, 0..) |rv, ri| {
                for (rv.asList()) |mv| {
                    const mid = mv.asString() orelse continue;
                    try member_to_compound.put(mid, comp_id);
                    // Mark region on state
                    for (states.items) |*s| {
                        if (std.mem.eql(u8, s.id, mid)) {
                            s.region_idx = ri;
                            break;
                        }
                    }
                }
            }
        } else {
            for (cn.getList("members")) |mv| {
                const mid = mv.asString() orelse continue;
                try member_to_compound.put(mid, comp_id);
            }
        }
    }

    // Mark states as is_member / is_compound
    for (states.items) |*s| {
        if (member_to_compound.get(s.id)) |cid| {
            s.is_member = true;
            s.compound_id = cid;
        }
        if (compound_ids_set.get(s.id) != null or std.mem.eql(u8, s.shape, "compound")) {
            s.is_compound = true;
        }
    }

    // ── Step 2: Global BFS (non-member states only) ────────────────────────────
    var depth_map = std.StringHashMap(usize).init(a);
    var queue: std.ArrayList([]const u8) = .empty;

    // Find start: global [*] (non-member) or first non-member state
    const global_start: []const u8 = blk: {
        if (seen.get("[*]") != null and member_to_compound.get("[*]") == null)
            break :blk "[*]";
        for (states.items) |s| {
            if (!s.is_member) break :blk s.id;
        }
        break :blk states.items[0].id;
    };
    try depth_map.put(global_start, 0);
    try queue.append(a, global_start);

    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const cur = queue.items[qi];
        const cur_depth = depth_map.get(cur) orelse 0;
        for (transitions.items) |t| {
            if (!std.mem.eql(u8, t.from, cur)) continue;
            if (member_to_compound.get(t.to) != null) continue; // skip member states
            if (depth_map.get(t.to) != null) continue;
            try depth_map.put(t.to, cur_depth + 1);
            try queue.append(a, t.to);
        }
    }
    // Unreachable non-member states get max_depth+1
    var global_max_depth: usize = 0;
    for (states.items) |s| {
        if (s.is_member) continue;
        if (depth_map.get(s.id)) |d| { if (d > global_max_depth) global_max_depth = d; }
    }
    for (states.items) |*s| {
        if (s.is_member) continue;
        s.depth = depth_map.get(s.id) orelse global_max_depth + 1;
    }

    // Assign global columns
    var col_count = [_]usize{0} ** 128;
    for (states.items) |*s| {
        if (s.is_member) continue;
        const d = s.depth;
        if (d < 128) {
            s.col = col_count[d];
            col_count[d] += 1;
        }
    }

    // ── Step 3: Local BFS per compound ────────────────────────────────────────
    //
    // For each compound, run local BFS over its members (per region if concurrent).
    // After this step, each member state has local_col, local_depth, region_idx.
    // We also compute the compound's box_w and box_h.

    for (compounds_val) |cv| {
        const cn = cv.asNode() orelse continue;
        const comp_id = cn.getString("id") orelse continue;

        // Collect regions (list of member-id slices)
        var region_member_lists: std.ArrayList([]const []const u8) = .empty;
        const regions_val = cn.getList("regions");
        if (regions_val.len > 0) {
            for (regions_val) |rv| {
                var ids: std.ArrayList([]const u8) = .empty;
                for (rv.asList()) |mv| {
                    if (mv.asString()) |mid| try ids.append(a, mid);
                }
                try region_member_lists.append(a, ids.items);
            }
        } else {
            // Flat members = single region
            var ids: std.ArrayList([]const u8) = .empty;
            for (cn.getList("members")) |mv| {
                if (mv.asString()) |mid| try ids.append(a, mid);
            }
            if (ids.items.len > 0) try region_member_lists.append(a, ids.items);
        }

        if (region_member_lists.items.len == 0) continue;

        // Per-region local layout
        var region_widths: std.ArrayList(f32) = .empty;
        var region_heights: std.ArrayList(f32) = .empty;

        for (region_member_lists.items, 0..) |region_ids, ri| {
            // Build member set for this region
            var member_set = std.StringHashMap(void).init(a);
            for (region_ids) |mid| {
                try member_set.put(mid, {});
                // Assign region_idx on state
                for (states.items) |*s| {
                    if (std.mem.eql(u8, s.id, mid)) { s.region_idx = ri; break; }
                }
            }

            // Local BFS start: compound-scoped [*] for this region, or first member
            const local_start_prefix = try std.fmt.allocPrint(a, "{s}.[*]", .{comp_id});
            var local_start: []const u8 = local_start_prefix; // default
            // Find compound-scoped initial state for this region
            var found_scoped_start = false;
            for (region_ids) |mid| {
                if (std.mem.eql(u8, mid, local_start_prefix)) {
                    found_scoped_start = true;
                    break;
                }
            }
            if (!found_scoped_start and region_ids.len > 0) {
                local_start = region_ids[0];
            }

            _ = try localBfs(states.items, transitions.items, member_set, local_start, ri, a);

            // Compute region grid size
            var max_lc: usize = 0;
            var max_ld: usize = 0;
            for (states.items) |s| {
                if (!s.is_member or s.region_idx != ri) continue;
                if (s.compound_id == null or !std.mem.eql(u8, s.compound_id.?, comp_id)) continue;
                if (s.local_col > max_lc) max_lc = s.local_col;
                if (s.local_depth > max_ld) max_ld = s.local_depth;
            }
            const n_cols: f32 = @floatFromInt(max_lc + 1);
            const n_rows: f32 = @floatFromInt(max_ld + 1);
            const rw = n_cols * STATE_W + (n_cols - 1) * COL_GAP;
            const rh = n_rows * STATE_H + (n_rows - 1) * ROW_GAP;
            try region_widths.append(a, rw);
            try region_heights.append(a, rh);
        }

        // Compound box dimensions
        var total_region_w: f32 = 0;
        var max_region_h: f32 = 0;
        for (region_widths.items) |rw| total_region_w += rw;
        for (region_heights.items) |rh| { if (rh > max_region_h) max_region_h = rh; }
        // Add gaps between regions
        if (region_widths.items.len > 1) {
            total_region_w += @as(f32, @floatFromInt(region_widths.items.len - 1)) * (COL_GAP + REGION_GAP);
        }

        const comp_w = total_region_w + 2 * COMP_PAD;
        const comp_h = max_region_h + COMP_LABEL_H + 2 * COMP_PAD;

        // Store dimensions on compound header state
        for (states.items) |*s| {
            if (std.mem.eql(u8, s.id, comp_id)) {
                s.box_w = comp_w;
                s.box_h = comp_h;
                break;
            }
        }
    }

    // ── Step 4: Compute pixel positions ────────────────────────────────────────
    //
    // Use variable-height rows and variable-width columns so that compound boxes
    // (which may be much taller/wider than a single state) do not overlap sibling
    // states in the global grid.

    var max_global_col: usize = 0;
    for (col_count[0 .. global_max_depth + 2]) |c| { if (c > max_global_col) max_global_col = c; }
    const N_ROWS = global_max_depth + 2;
    const N_COLS = if (max_global_col > 0) max_global_col else 1;

    // row_h[d] = visual height of row d (STATE_H for normal states, box_h for compounds)
    var row_h = try a.alloc(f32, N_ROWS + 1);
    for (row_h) |*rh| rh.* = STATE_H;
    for (states.items) |s| {
        if (s.is_compound and s.box_h > 0 and s.depth < N_ROWS and s.box_h > row_h[s.depth])
            row_h[s.depth] = s.box_h;
    }
    // row_y[d] = top-left y of row d
    var row_y = try a.alloc(f32, N_ROWS + 1);
    row_y[0] = MARGIN;
    for (1..N_ROWS + 1) |d| row_y[d] = row_y[d - 1] + row_h[d - 1] + ROW_GAP;

    // col_w[c] = visual width of column c
    var col_w = try a.alloc(f32, N_COLS + 1);
    for (col_w) |*cw| cw.* = STATE_W;
    for (states.items) |s| {
        if (s.is_compound and s.box_w > 0 and s.col < N_COLS and s.box_w > col_w[s.col])
            col_w[s.col] = s.box_w;
    }
    // col_x[c] = left-edge x of column c
    var col_x = try a.alloc(f32, N_COLS + 1);
    col_x[0] = MARGIN;
    for (1..N_COLS + 1) |c| col_x[c] = col_x[c - 1] + col_w[c - 1] + COL_GAP;

    // Assign pixel positions to non-member states
    for (states.items) |*s| {
        if (s.is_member) continue;
        const ci = s.col;
        const di = s.depth;
        if (s.is_compound) {
            const bh = if (s.box_h > 0) s.box_h else STATE_H;
            s.px = col_x[ci] + (if (ci < N_COLS) col_w[ci] else STATE_W) / 2;
            s.py = row_y[di] + bh / 2;
        } else {
            s.px = col_x[ci] + (if (ci < N_COLS) col_w[ci] else STATE_W) / 2;
            s.py = row_y[di] + STATE_H / 2;
        }
    }

    // Member pixel positions: compound box top-left + local offset
    for (compounds_val) |cv| {
        const cn = cv.asNode() orelse continue;
        const comp_id = cn.getString("id") orelse continue;

        // Find compound header to get its global px/py and box dimensions
        var comp_px: f32 = 0;
        var comp_py: f32 = 0;
        var comp_box_w: f32 = STATE_W;
        var comp_box_h: f32 = STATE_H;
        for (states.items) |s| {
            if (std.mem.eql(u8, s.id, comp_id)) {
                comp_px = s.px;
                comp_py = s.py;
                comp_box_w = if (s.box_w > 0) s.box_w else STATE_W;
                comp_box_h = if (s.box_h > 0) s.box_h else STATE_H;
                break;
            }
        }
        const box_left = comp_px - comp_box_w / 2;
        const box_top  = comp_py - comp_box_h / 2;

        // Collect region widths for x-offset calculation
        var region_x_offsets: std.ArrayList(f32) = .empty;
        const regions_val = cn.getList("regions");
        var x_cursor: f32 = box_left + COMP_PAD;
        if (regions_val.len > 0) {
            for (regions_val) |rv| {
                try region_x_offsets.append(a, x_cursor);
                // Compute this region's width
                var max_lc: usize = 0;
                const region_list = rv.asList();
                for (region_list) |mv| {
                    const mid = mv.asString() orelse continue;
                    for (states.items) |s| {
                        if (std.mem.eql(u8, s.id, mid) and s.is_member and s.local_col > max_lc)
                            max_lc = s.local_col;
                    }
                }
                const rw = @as(f32, @floatFromInt(max_lc + 1)) * STATE_W +
                           @as(f32, @floatFromInt(max_lc)) * COL_GAP;
                x_cursor += rw + COL_GAP + REGION_GAP;
            }
        } else {
            try region_x_offsets.append(a, x_cursor);
        }

        // Assign member pixel positions
        for (states.items) |*s| {
            if (!s.is_member) continue;
            if (s.compound_id == null or !std.mem.eql(u8, s.compound_id.?, comp_id)) continue;

            const rx_off = if (s.region_idx < region_x_offsets.items.len)
                region_x_offsets.items[s.region_idx]
            else
                box_left + COMP_PAD;

            s.px = rx_off + @as(f32, @floatFromInt(s.local_col)) * (STATE_W + COL_GAP) + STATE_W / 2;
            s.py = box_top + COMP_LABEL_H + COMP_PAD +
                   @as(f32, @floatFromInt(s.local_depth)) * (STATE_H + ROW_GAP) + STATE_H / 2;
        }
    }

    // ── Step 5: Canvas size ────────────────────────────────────────────────────

    var max_px: f32 = 0;
    var max_py: f32 = 0;
    for (states.items) |s| {
        const right = s.px + (if (s.is_compound) s.box_w / 2 else STATE_W / 2) + MARGIN;
        const bot   = s.py + (if (s.is_compound) s.box_h / 2 else STATE_H / 2) + MARGIN;
        if (right > max_px) max_px = right;
        if (bot   > max_py) max_py = bot;
    }

    // Back edges route to the right — ensure extra canvas width
    for (transitions.items) |t| {
        const fi = stateIndex(states.items, t.from) orelse continue;
        const ti = stateIndex(states.items, t.to) orelse continue;
        const fs = states.items[fi];
        const ts = states.items[ti];
        if (fs.depth > ts.depth) {
            const layer_diff: f32 = @floatFromInt(fs.depth - ts.depth);
            const lateral: f32 = @max(COL_GAP * 2.0, layer_diff * STATE_W * 0.4 + COL_GAP);
            const rx = fs.px + STATE_W / 2 + lateral + MARGIN;
            if (rx > max_px) max_px = rx;
        }
    }

    const total_w: u32 = @intFromFloat(@max(max_px, 200));
    const total_h: u32 = @intFromFloat(@max(max_py, 120));

    var svg = SvgWriter.init(allocator);
    defer svg.deinit();

    try svg.header(total_w, total_h);
    try svg.rect(0, 0, @floatFromInt(total_w), @floatFromInt(total_h), 0, theme.background, theme.background, 0);

    // ── Step 6: Draw compound boxes (behind everything) ────────────────────────
    for (compounds_val) |cv| {
        const cn = cv.asNode() orelse continue;
        const comp_id = cn.getString("id") orelse continue;

        var comp_px: f32 = 0;
        var comp_py: f32 = 0;
        var comp_box_w: f32 = 0;
        var comp_box_h: f32 = 0;
        for (states.items) |s| {
            if (std.mem.eql(u8, s.id, comp_id)) {
                comp_px = s.px; comp_py = s.py;
                comp_box_w = if (s.box_w > 0) s.box_w else STATE_W + 2 * COMP_PAD;
                comp_box_h = if (s.box_h > 0) s.box_h else STATE_H + COMP_LABEL_H + 2 * COMP_PAD;
                break;
            }
        }
        if (comp_box_w == 0) continue;

        const bx = comp_px - comp_box_w / 2;
        const by = comp_py - comp_box_h / 2;

        try svg.rect(bx, by, comp_box_w, comp_box_h, 6.0, theme.node_fill, theme.node_stroke, 1.5);
        // Label: compound state name at top of box
        const lbl = blk: {
            for (states.items) |s| { if (std.mem.eql(u8, s.id, comp_id)) break :blk s.label; }
            break :blk comp_id;
        };
        try svg.text(bx + 8, by + COMP_LABEL_H - 6, lbl, theme.text_color, theme.font_size_small, .start, "bold");

        // Divider line(s) between concurrent regions
        const regions_val = cn.getList("regions");
        if (regions_val.len > 1) {
            // Find region x-boundaries to draw vertical dividers
            var x_cursor: f32 = bx + COMP_PAD;
            for (regions_val, 0..) |rv, ri| {
                var max_lc: usize = 0;
                for (rv.asList()) |mv| {
                    const mid = mv.asString() orelse continue;
                    for (states.items) |s| {
                        if (std.mem.eql(u8, s.id, mid) and s.is_member and s.region_idx == ri and s.local_col > max_lc)
                            max_lc = s.local_col;
                    }
                }
                const rw = @as(f32, @floatFromInt(max_lc + 1)) * STATE_W +
                           @as(f32, @floatFromInt(max_lc)) * COL_GAP;
                x_cursor += rw;
                if (ri < regions_val.len - 1) {
                    // Draw dashed vertical divider
                    const div_x = x_cursor + (COL_GAP + REGION_GAP) / 2;
                    const inner_top  = by + COMP_LABEL_H + COMP_PAD / 2;
                    const inner_bot  = by + comp_box_h - COMP_PAD / 2;
                    var div_buf: [128]u8 = undefined;
                    const div_d = try std.fmt.bufPrint(&div_buf,
                        "M {d:.1} {d:.1} L {d:.1} {d:.1}", .{ div_x, inner_top, div_x, inner_bot });
                    try svg.path(div_d, "none", theme.node_stroke, 1.0, "stroke-dasharray=\"5,3\"");
                    x_cursor += COL_GAP + REGION_GAP;
                }
            }
        }
    }

    // ── Step 7: Draw transitions ───────────────────────────────────────────────
    for (transitions.items) |t| {
        const fi = stateIndex(states.items, t.from) orelse continue;
        const ti = stateIndex(states.items, t.to) orelse continue;
        const fs = states.items[fi];
        const ts = states.items[ti];

        const fx = fs.px;
        const fy = fs.py;
        const tx = ts.px;
        const ty = ts.py;
        const stroke = theme.edge_color;
        const sw: f32 = 1.5;

        // ── Self-loop ──────────────────────────────────────────────────────────
        if (std.mem.eql(u8, t.from, t.to)) {
            const lp: f32 = 38.0;
            const ex = fx - STATE_W / 2.0;
            const y1 = fy - 14.0;
            const y2 = fy + 14.0;
            var loop_buf: [256]u8 = undefined;
            const loop_d = try std.fmt.bufPrint(&loop_buf,
                "M {d:.1} {d:.1} C {d:.1} {d:.1} {d:.1} {d:.1} {d:.1} {d:.1}",
                .{ ex, y1, ex - lp, y1, ex - lp, y2, ex, y2 });
            try svg.path(loop_d, "none", stroke, sw, "");
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

        // ── Cubic Bezier ───────────────────────────────────────────────────────
        var pfx: f32 = fx;
        var pfy: f32 = fy;
        var ptx: f32 = tx;
        var pty: f32 = ty;
        var cx1: f32 = 0;
        var cy1: f32 = 0;
        var cx2: f32 = 0;
        var cy2: f32 = 0;

        // Determine if same depth (horizontal arc) or forward/back (vertical curve).
        // Use actual depth values for non-member states; for member states use py.
        const same_depth = (fs.depth == ts.depth) and !fs.is_member and !ts.is_member;
        const is_forward = (pfy < pty - 4.0) or (same_depth and false);
        const is_back    = !same_depth and (pfy > pty + 4.0);
        _ = is_forward;

        if (same_depth) {
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
        } else if (is_back) {
            // Back edge: route around the right side
            const dy: f32 = @abs(fy - ty);
            const lateral: f32 = @max(COL_GAP * 2.0, dy * 0.4 + COL_GAP);
            pfx = fx + STATE_W / 2.0; ptx = tx + STATE_W / 2.0;
            cx1 = pfx + lateral; cy1 = pfy;
            cx2 = ptx + lateral; cy2 = pty;
        } else {
            // Forward edge: exit bottom, enter top
            const from_r: f32 = if (isInitial(fs)) START_R else if (fs.is_compound) fs.box_h / 2 else STATE_H / 2.0;
            const to_r: f32   = if (isInitial(ts)) START_R else if (ts.is_compound) ts.box_h / 2 else STATE_H / 2.0;
            pfy = fy + from_r;
            pty = ty - to_r;
            const ctrl: f32 = @max(ROW_GAP * 0.6, @abs(pty - pfy) * 0.4);
            cx1 = pfx; cy1 = pfy + ctrl;
            cx2 = ptx; cy2 = pty - ctrl;
        }

        var path_buf: [256]u8 = undefined;
        const path_d = try std.fmt.bufPrint(&path_buf,
            "M {d:.1} {d:.1} C {d:.1} {d:.1} {d:.1} {d:.1} {d:.1} {d:.1}",
            .{ pfx, pfy, cx1, cy1, cx2, cy2, ptx, pty });
        try svg.path(path_d, "none", stroke, sw, "");

        // Arrowhead
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
                    ptx - ux * arr - uy * half, pty - uy * arr + ux * half,
                    ptx, pty,
                    ptx - ux * arr + uy * half, pty - uy * arr - ux * half,
                });
            try svg.polygon(pts, stroke, stroke, 1.0);
        }

        if (t.label.len > 0) {
            const mid_x = 0.125 * pfx + 0.375 * cx1 + 0.375 * cx2 + 0.125 * ptx;
            const mid_y = 0.125 * pfy + 0.375 * cy1 + 0.375 * cy2 + 0.125 * pty;
            try svg.text(mid_x + 4, mid_y - 6, t.label, theme.text_color, theme.font_size_small, .start, "normal");
        }
    }

    // ── Step 8: Draw states ────────────────────────────────────────────────────
    for (states.items) |s| {
        if (s.is_compound) continue; // rendered as compound box above

        const cx = s.px;
        const cy = s.py;

        if (isInitial(s)) {
            try svg.circle(cx, cy, START_R, theme.edge_color, theme.edge_color, 0);
        } else if (isFinal(s)) {
            try svg.circle(cx, cy, START_R + 5, "none", theme.edge_color, 2.0);
            try svg.circle(cx, cy, START_R - 1, theme.edge_color, theme.edge_color, 0);
        } else if (std.mem.eql(u8, s.shape, "fork") or std.mem.eql(u8, s.shape, "join")) {
            const bar_w: f32 = STATE_W * 0.8;
            const bar_h: f32 = 8;
            try svg.rect(cx - bar_w / 2, cy - bar_h / 2, bar_w, bar_h, 0, theme.edge_color, theme.edge_color, 0);
        } else if (std.mem.eql(u8, s.shape, "choice")) {
            const hw: f32 = STATE_W * 0.35;
            const hh: f32 = STATE_H * 0.55;
            var pts_buf: [192]u8 = undefined;
            const pts = try std.fmt.bufPrint(&pts_buf,
                "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                .{ cx, cy - hh, cx + hw, cy, cx, cy + hh, cx - hw, cy });
            try svg.polygon(pts, theme.node_fill, theme.node_stroke, 1.5);
        } else if (std.mem.eql(u8, s.shape, "history") or std.mem.eql(u8, s.shape, "deepHistory")) {
            const r: f32 = START_R + 4;
            try svg.circle(cx, cy, r, theme.node_fill, theme.node_stroke, 1.5);
            const hist_lbl = if (std.mem.eql(u8, s.shape, "deepHistory")) "H*" else "H";
            try svg.text(cx, cy + 4, hist_lbl, theme.text_color, 10, .middle, "bold");
        } else {
            try svg.rect(cx - STATE_W / 2, cy - STATE_H / 2, STATE_W, STATE_H, 18.0, theme.node_fill, theme.node_stroke, 1.5);
            try svg.textWrapped(cx, cy + 5, s.label, STATE_W - 8, theme.text_color, theme.font_size, .middle, "normal");
        }
    }

    // ── Step 9: Draw notes ─────────────────────────────────────────────────────
    for (node.getList("notes")) |nv| {
        const nn = nv.asNode() orelse continue;
        const state_id = nn.getString("state") orelse continue;
        const text = nn.getString("text") orelse continue;
        const position = nn.getString("position") orelse "right";
        const si = stateIndex(states.items, state_id) orelse continue;
        const s = states.items[si];
        const sx = s.px;
        const sy = s.py;
        const NOTE_W: f32 = 120;
        const NOTE_H2: f32 = 32;
        const nx: f32 = if (std.mem.eql(u8, position, "left"))
            sx - STATE_W / 2 - NOTE_W - 14
        else
            sx + STATE_W / 2 + 14;
        try svg.rect(nx, sy - NOTE_H2 / 2, NOTE_W, NOTE_H2, 4.0, "#fffde7", "#f0c040", 1.2);
        const conn_x: f32 = if (std.mem.eql(u8, position, "left")) nx + NOTE_W else nx;
        const state_edge_x: f32 = if (std.mem.eql(u8, position, "left"))
            sx - STATE_W / 2 else sx + STATE_W / 2;
        try svg.dashedLine(conn_x, sy, state_edge_x, sy, "#aaaaaa", 1.0, "4,3");
        try svg.text(nx + NOTE_W / 2, sy + 5, text, theme.text_color, theme.font_size_small, .middle, "normal");
    }

    try svg.footer();
    return svg.toOwnedSlice();
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn isInitial(s: State) bool {
    return std.mem.eql(u8, s.id, "[*]") or
        std.mem.endsWith(u8, s.id, ".[*]") or
        std.mem.eql(u8, s.shape, "initial");
}

fn isFinal(s: State) bool {
    return std.mem.eql(u8, s.id, "[*]-end") or
        std.mem.endsWith(u8, s.id, ".[*]-end") or
        std.mem.eql(u8, s.shape, "final");
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
