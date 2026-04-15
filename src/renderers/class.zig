//! Class diagram SVG renderer.
//! Expects a Value.node with `classes` (list of nodes with `name` and `members` string list)
//! and `relations` (list of nodes with `from`, `to`, `kind`, and optional `label`).
//! Classes are arranged in a fixed-width grid; relations are drawn behind the boxes.
const std = @import("std");
const Value = @import("../diagram/value.zig").Value;
const SvgWriter = @import("../svg/writer.zig").SvgWriter;
const theme = @import("../svg/theme.zig");

const CLASS_W: f32 = 160;
const CLASS_HEADER_H: f32 = 32;
const MEMBER_H: f32 = 20;
const GRID_COLS: usize = 3;
const COL_GAP: f32 = 80;
const ROW_GAP: f32 = 80;
const MARGIN: f32 = 40;

const Visibility = enum { public, private, protected, package, none };
const Member = struct {
    visibility: Visibility,
    name: []const u8,
    type_str: []const u8,
    is_method: bool,
};

const Class = struct {
    name: []const u8,
    stereotype: []const u8, // empty string if none, else "<<interface>>" etc.
    members: []Member,
    col: usize,
    row: usize,
};

// Relationship terminators
const RelKind = enum {
    inheritance,   // --|>  open triangle
    composition,   // --*   filled diamond
    aggregation,   // --o   open diamond
    association,   // -->   open arrow
    dependency,    // ..>   dashed open arrow
    realization,   // ..|>  dashed open triangle
    link,          // --    plain line
    link_dashed,   // ..    plain dashed
};

const Relation = struct {
    from: []const u8,
    to: []const u8,
    kind: RelKind,
    label: []const u8,
};

/// Render a class diagram SVG from `value`.
/// `value` must be a node with `classes` (list of class nodes carrying `name` and
/// a `members` string list) and `relations` (list of nodes with `from`, `to`, `kind`,
/// and optional `label`). Returns a caller-owned SVG string.
pub fn render(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    const node = value.asNode() orelse return renderFallback(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var classes: std.ArrayList(Class) = .empty;
    var relations: std.ArrayList(Relation) = .empty;

    // Collect classes
    for (node.getList("classes")) |cv| {
        const cn = cv.asNode() orelse continue;
        const name = cn.getString("name") orelse continue;

        const raw_members = cn.getList("members");
        var members: std.ArrayList(Member) = .empty;
        var stereotype: []const u8 = "";
        for (raw_members) |mv| {
            const ms = mv.asString() orelse continue;
            // Stereotype line: <<interface>>, <<abstract>>, etc.
            if (std.mem.startsWith(u8, ms, "<<") and std.mem.indexOf(u8, ms, ">>") != null) {
                stereotype = ms;
                continue;
            }
            const m = parseMember(ms);
            try members.append(a, m);
        }

        const idx = classes.items.len;
        try classes.append(a, Class{
            .name = name,
            .stereotype = stereotype,
            .members = try members.toOwnedSlice(a),
            .col = idx % GRID_COLS,
            .row = idx / GRID_COLS,
        });
    }

    // Collect relations
    for (node.getList("relations")) |rv| {
        const rn = rv.asNode() orelse continue;
        const from = rn.getString("from") orelse continue;
        const to = rn.getString("to") orelse continue;
        const kind_str = rn.getString("kind") orelse "association";
        const label = rn.getString("label") orelse "";
        try relations.append(a, Relation{
            .from = from,
            .to = to,
            .kind = parseRelKind(kind_str),
            .label = label,
        });
    }

    if (classes.items.len == 0) return renderFallback(allocator);

    const n_rows = (classes.items.len + GRID_COLS - 1) / GRID_COLS;
    // Find max members per row (stereotype row counts as +1 if present)
    var max_members_per_row = [_]usize{0} ** 64;
    for (classes.items) |cl| {
        const effective = cl.members.len + (if (cl.stereotype.len > 0) @as(usize, 1) else 0);
        if (cl.row < 64 and effective > max_members_per_row[cl.row])
            max_members_per_row[cl.row] = effective;
    }

    // Compute row Y offsets
    var row_y = [_]f32{0} ** 65;
    row_y[0] = MARGIN;
    for (0..n_rows) |r| {
        const h = CLASS_HEADER_H + @as(f32, @floatFromInt(max_members_per_row[r])) * MEMBER_H + 10;
        row_y[r + 1] = row_y[r] + h + ROW_GAP;
    }

    const note_extra: f32 = if (node.getList("notes").len > 0) 184 else 0;
    const total_w: u32 = @intFromFloat(
        MARGIN * 2 + @as(f32, @floatFromInt(GRID_COLS)) * (CLASS_W + COL_GAP) - COL_GAP + note_extra
    );
    const total_h: u32 = @intFromFloat(row_y[n_rows] + MARGIN);

    var svg = SvgWriter.init(allocator);
    defer svg.deinit();

    try svg.header(total_w, total_h);
    try svg.rect(0, 0, @floatFromInt(total_w), @floatFromInt(total_h), 0, theme.background, theme.background, 0);

    // Helper: get class box top-left
    const classX = struct {
        fn get(col: usize) f32 {
            return MARGIN + @as(f32, @floatFromInt(col)) * (CLASS_W + COL_GAP);
        }
    }.get;

    // Draw namespace boundary boxes (behind everything)
    for (node.getList("namespaces")) |nsv| {
        const nsn = nsv.asNode() orelse continue;
        const ns_name = nsn.getString("name") orelse continue;
        const members = nsn.getList("members");
        if (members.len == 0) continue;
        // Find bounding box over all member classes
        var min_col: usize = std.math.maxInt(usize);
        var max_col: usize = 0;
        var min_row: usize = std.math.maxInt(usize);
        var max_row: usize = 0;
        for (members) |mv| {
            const mname = mv.asString() orelse continue;
            const ci = classIndex(classes.items, mname) orelse continue;
            const cl = classes.items[ci];
            if (cl.col < min_col) min_col = cl.col;
            if (cl.col > max_col) max_col = cl.col;
            if (cl.row < min_row) min_row = cl.row;
            if (cl.row > max_row) max_row = cl.row;
        }
        if (min_col == std.math.maxInt(usize)) continue;
        const pad: f32 = 12;
        const bx = classX(min_col) - pad;
        const by = row_y[min_row] - pad;
        const bw = classX(max_col) + CLASS_W - bx + pad;
        const max_h = CLASS_HEADER_H + @as(f32, @floatFromInt(max_members_per_row[max_row])) * MEMBER_H + 10;
        const bh = row_y[max_row] + max_h - by + pad;
        try svg.rect(bx, by, bw, bh, 8.0, "#f0f4ff", "#8888cc", 1.5);
        try svg.text(bx + 8, by + 14, ns_name, "#6666aa", theme.font_size_small, .start, "bold");
    }

    // Draw relations first (behind boxes)
    for (relations.items) |rel| {
        const fi = classIndex(classes.items, rel.from) orelse continue;
        const ti = classIndex(classes.items, rel.to) orelse continue;
        const fc = classes.items[fi];
        const tc = classes.items[ti];

        const fh = CLASS_HEADER_H + @as(f32, @floatFromInt(fc.members.len)) * MEMBER_H + 10;
        const th = CLASS_HEADER_H + @as(f32, @floatFromInt(tc.members.len)) * MEMBER_H + 10;

        const fcx_left = classX(fc.col);
        const fcx_right = classX(fc.col) + CLASS_W;
        const fcy_mid = row_y[fc.row] + fh / 2;
        const fcy_bot = row_y[fc.row] + fh;

        const tcx_left = classX(tc.col);
        const tcx_right = classX(tc.col) + CLASS_W;
        const tcy_mid = row_y[tc.row] + th / 2;
        const tcy_bot = row_y[tc.row] + th;

        // Choose connection points: side edges for same row, top/bottom for different rows
        const from_x: f32, const from_y: f32, const to_x: f32, const to_y: f32 = blk: {
            if (fc.row == tc.row) {
                // Same row: connect right→left or left→right
                if (fc.col < tc.col) {
                    break :blk .{ fcx_right, fcy_mid, tcx_left, tcy_mid };
                } else {
                    break :blk .{ fcx_left, fcy_mid, tcx_right, tcy_mid };
                }
            } else if (fc.row < tc.row) {
                // From is above to: bottom of from → top of to
                break :blk .{ classX(fc.col) + CLASS_W / 2, fcy_bot,
                               classX(tc.col) + CLASS_W / 2, row_y[tc.row] };
            } else {
                // From is below to: top of from → bottom of to
                break :blk .{ classX(fc.col) + CLASS_W / 2, row_y[fc.row],
                               classX(tc.col) + CLASS_W / 2, tcy_bot };
            }
        };

        const dotted = rel.kind == .dependency or rel.kind == .realization or rel.kind == .link_dashed;
        if (dotted) {
            try svg.dashedLine(from_x, from_y, to_x, to_y, theme.line_color, 1.5, "6,3");
        } else {
            try svg.line(from_x, from_y, to_x, to_y, theme.line_color, 1.5);
        }

        // Terminator at `to` end
        try drawTerminator(&svg, to_x, to_y, from_x, from_y, rel.kind);

        // Label at midpoint
        if (rel.label.len > 0) {
            const mx = (from_x + to_x) / 2;
            const my = (from_y + to_y) / 2;
            try svg.text(mx, my - 6, rel.label, theme.text_color, theme.font_size_small, .middle, "normal");
        }
    }

    // Draw class boxes
    for (classes.items) |cl| {
        const bx = classX(cl.col);
        const by = row_y[cl.row];
        const ste_h: f32 = if (cl.stereotype.len > 0) MEMBER_H else 0;
        const bh = CLASS_HEADER_H + ste_h + @as(f32, @floatFromInt(cl.members.len)) * MEMBER_H + 10;

        // Box outline
        try svg.rect(bx, by, CLASS_W, bh, 4.0, theme.node_fill, theme.node_stroke, 1.5);

        // Stereotype (italic, above class name)
        if (cl.stereotype.len > 0) {
            var ste_buf: [128]u8 = undefined;
            const ste_raw = try std.fmt.bufPrint(&ste_buf, "{s}", .{cl.stereotype});
            try svg.text(bx + CLASS_W / 2, by + MEMBER_H / 2 + 4,
                ste_raw, "#666666", theme.font_size_small, .middle, "normal");
        }

        // Class name (convert ~T~ generics to <T> for display)
        const name_y = by + ste_h + CLASS_HEADER_H / 2 + 5;
        var name_buf: [128]u8 = undefined;
        const display_name = normalizeGenerics(cl.name, &name_buf) catch cl.name;
        try svg.text(bx + CLASS_W / 2, name_y, display_name, theme.text_color, theme.font_size, .middle, "bold");

        // Header separator
        try svg.line(bx, by + ste_h + CLASS_HEADER_H, bx + CLASS_W, by + ste_h + CLASS_HEADER_H, theme.node_stroke, 1.0);

        // Members
        const members_top = by + ste_h + CLASS_HEADER_H;
        for (cl.members, 0..) |m, mi| {
            const my = members_top + 6 + @as(f32, @floatFromInt(mi)) * MEMBER_H + MEMBER_H / 2;
            var buf: [320]u8 = undefined;
            const vis = visibilityChar(m.visibility);
            const name_display = normalizeGenerics(m.name, &buf) catch m.name;
            const type_display = normalizeGenerics(m.type_str, buf[128..]) catch m.type_str;
            const label = if (type_display.len > 0)
                std.fmt.bufPrint(buf[256..], "{s}{s} : {s}", .{ vis, name_display, type_display }) catch m.name
            else
                std.fmt.bufPrint(buf[256..], "{s}{s}", .{ vis, name_display }) catch m.name;
            const max_chars: usize = 22;
            const display = if (label.len > max_chars) label[0..max_chars] else label;
            try svg.text(bx + 8, my, display, theme.text_color, theme.font_size_small, .start, "normal");
        }
    }

    // Draw notes (yellow annotation boxes, right of target class or top-right corner)
    const NOTE_W: f32 = 160;
    const NOTE_H: f32 = 46;
    for (node.getList("notes")) |nv| {
        const nn = nv.asNode() orelse continue;
        const text = nn.getString("text") orelse continue;
        const target = nn.getString("target") orelse "";
        var nx: f32 = @as(f32, @floatFromInt(total_w)) - NOTE_W - MARGIN;
        var ny: f32 = MARGIN;
        if (target.len > 0) {
            if (classIndex(classes.items, target)) |ci| {
                const cl = classes.items[ci];
                nx = classX(cl.col) + CLASS_W + 12;
                const ste_h: f32 = if (cl.stereotype.len > 0) MEMBER_H else 0;
                const bh = CLASS_HEADER_H + ste_h + @as(f32, @floatFromInt(cl.members.len)) * MEMBER_H + 10;
                ny = row_y[cl.row] + bh / 2 - NOTE_H / 2;
                // Connector line from note to class right edge
                try svg.dashedLine(classX(cl.col) + CLASS_W, row_y[cl.row] + bh / 2,
                    nx, ny + NOTE_H / 2, "#aaaaaa", 1.0, "4,3");
            }
        }
        try svg.rect(nx, ny, NOTE_W, NOTE_H, 4.0, "#fffde7", "#f0c040", 1.2);
        try svg.textWrapped(nx + NOTE_W / 2, ny + NOTE_H / 2, text,
            NOTE_W - 8, theme.text_color, theme.font_size_small, .middle, "normal");
    }

    try svg.footer();
    return svg.toOwnedSlice();
}

fn drawTerminator(svg: *SvgWriter, tip_x: f32, tip_y: f32, from_x: f32, from_y: f32, kind: RelKind) !void {
    const dx = from_x - tip_x;
    const dy = from_y - tip_y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1.0) return;
    const ux = dx / len;
    const uy = dy / len;
    const perp_x = -uy;
    const perp_y = ux;
    const arr: f32 = 10.0;
    const half: f32 = 6.0;

    switch (kind) {
        .inheritance, .realization => {
            // Open triangle pointing at tip
            const b1x = tip_x + ux * arr + perp_x * half;
            const b1y = tip_y + uy * arr + perp_y * half;
            const b2x = tip_x + ux * arr - perp_x * half;
            const b2y = tip_y + uy * arr - perp_y * half;
            var pts_buf: [192]u8 = undefined;
            const pts = try std.fmt.bufPrint(&pts_buf,
                "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                .{ tip_x, tip_y, b1x, b1y, b2x, b2y });
            try svg.polygon(pts, theme.background, theme.line_color, 1.5);
        },
        .composition => {
            // Filled diamond (two triangles)
            const mid_x = tip_x + ux * arr;
            const mid_y = tip_y + uy * arr;
            const b1x = mid_x + perp_x * half;
            const b1y = mid_y + perp_y * half;
            const b2x = mid_x - perp_x * half;
            const b2y = mid_y - perp_y * half;
            const bx = tip_x + ux * arr * 2;
            const by = tip_y + uy * arr * 2;
            var pts_buf: [256]u8 = undefined;
            const pts = try std.fmt.bufPrint(&pts_buf,
                "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                .{ tip_x, tip_y, b1x, b1y, bx, by, b2x, b2y });
            try svg.polygon(pts, theme.node_stroke, theme.line_color, 1.5);
        },
        .aggregation => {
            // Open diamond
            const mid_x = tip_x + ux * arr;
            const mid_y = tip_y + uy * arr;
            const b1x = mid_x + perp_x * half;
            const b1y = mid_y + perp_y * half;
            const b2x = mid_x - perp_x * half;
            const b2y = mid_y - perp_y * half;
            const bx = tip_x + ux * arr * 2;
            const by = tip_y + uy * arr * 2;
            var pts_buf: [256]u8 = undefined;
            const pts = try std.fmt.bufPrint(&pts_buf,
                "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                .{ tip_x, tip_y, b1x, b1y, bx, by, b2x, b2y });
            try svg.polygon(pts, theme.background, theme.line_color, 1.5);
        },
        .association, .dependency => {
            // Open arrowhead
            const b1x = tip_x + ux * arr + perp_x * half;
            const b1y = tip_y + uy * arr + perp_y * half;
            const b2x = tip_x + ux * arr - perp_x * half;
            const b2y = tip_y + uy * arr - perp_y * half;
            var pts_buf: [192]u8 = undefined;
            const pts = try std.fmt.bufPrint(&pts_buf,
                "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
                .{ b1x, b1y, tip_x, tip_y, b2x, b2y });
            try svg.polygon(pts, "none", theme.line_color, 1.5);
        },
        .link, .link_dashed => {
            // No terminator
        },
    }
}

fn classIndex(classes: []const Class, name: []const u8) ?usize {
    for (classes, 0..) |c, i| if (std.mem.eql(u8, c.name, name)) return i;
    return null;
}

/// Convert mermaid generic notation `List~T~` to display form `List<T>`.
/// Writes into `buf` and returns the resulting slice; returns `s` unchanged on overflow.
fn normalizeGenerics(s: []const u8, buf: []u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '~') == null) return s;
    var out: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '~') {
            const close = std.mem.indexOfScalar(u8, s[i + 1..], '~') orelse {
                if (out >= buf.len) return error.NoSpaceLeft;
                buf[out] = s[i]; out += 1; i += 1; continue;
            };
            if (out + 1 + close + 1 + 1 > buf.len) return error.NoSpaceLeft;
            buf[out] = '<'; out += 1;
            @memcpy(buf[out .. out + close], s[i + 1 .. i + 1 + close]);
            out += close;
            buf[out] = '>'; out += 1;
            i += 1 + close + 1;
        } else {
            if (out >= buf.len) return error.NoSpaceLeft;
            buf[out] = s[i]; out += 1; i += 1;
        }
    }
    return buf[0..out];
}

fn parseMember(s: []const u8) Member {
    const trimmed = std.mem.trim(u8, s, " \t");
    var vis = Visibility.none;
    var rest = trimmed;
    if (rest.len > 0) {
        switch (rest[0]) {
            '+' => { vis = .public; rest = rest[1..]; },
            '-' => { vis = .private; rest = rest[1..]; },
            '#' => { vis = .protected; rest = rest[1..]; },
            '~' => { vis = .package; rest = rest[1..]; },
            else => {},
        }
    }
    const is_method = std.mem.indexOf(u8, rest, "(") != null;
    // Mermaid syntax: `Type name` : first token is type, second is name.
    // Display convention (UML): `+name : Type`.
    var name = rest;
    var type_str: []const u8 = "";
    if (std.mem.indexOf(u8, rest, " ")) |sp| {
        type_str = rest[0..sp];          // first token = type
        name = std.mem.trim(u8, rest[sp + 1..], " \t"); // second token = name
    }
    return Member{ .visibility = vis, .name = name, .type_str = type_str, .is_method = is_method };
}

fn visibilityChar(v: Visibility) []const u8 {
    return switch (v) {
        .public => "+",
        .private => "-",
        .protected => "#",
        .package => "~",
        .none => "",
    };
}

fn parseRelKind(s: []const u8) RelKind {
    if (std.mem.eql(u8, s, "inheritance") or std.mem.eql(u8, s, "extension")) return .inheritance;
    if (std.mem.eql(u8, s, "composition")) return .composition;
    if (std.mem.eql(u8, s, "aggregation")) return .aggregation;
    if (std.mem.eql(u8, s, "dependency")) return .dependency;
    if (std.mem.eql(u8, s, "realization")) return .realization;
    if (std.mem.eql(u8, s, "link_dashed")) return .link_dashed;
    if (std.mem.eql(u8, s, "link")) return .link;
    return .association;
}

fn renderFallback(allocator: std.mem.Allocator) ![]const u8 {
    var svg = SvgWriter.init(allocator);
    defer svg.deinit();
    try svg.header(400, 200);
    try svg.text(200, 100, "classDiagram", theme.text_color, theme.font_size, .middle, "normal");
    try svg.footer();
    return svg.toOwnedSlice();
}
