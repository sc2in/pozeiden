//! C4 architecture diagram SVG renderer.
//! Supports C4Context, C4Container, C4Component, C4Dynamic, C4Deployment.
//! Expects a Value.node with `title`, `elements` (alias, label, tech, desc, kind),
//! `relations` (from, to, label, tech, bidirectional), and `boundaries` (alias, label,
//! members list). Elements are arranged in a grid with C4-standard colour coding.
const std = @import("std");
const Value = @import("../diagram/value.zig").Value;
const SvgWriter = @import("../svg/writer.zig").SvgWriter;
const theme = @import("../svg/theme.zig");

const BOX_W: f32 = 170;
const BOX_HEADER_H: f32 = 44; // stereotype + name
const BOX_DESC_LINE_H: f32 = 16;
const BOX_PAD_BOTTOM: f32 = 10;
const GRID_COLS: usize = 3;
const COL_GAP: f32 = 90;
const ROW_GAP: f32 = 90;
const MARGIN: f32 = 40;
const BOUNDARY_PAD: f32 = 16;

// C4 standard colors
const COLOR_PERSON = "#08427b";
const COLOR_PERSON_EXT = "#686868";
const COLOR_SYSTEM = "#1168bd";
const COLOR_SYSTEM_EXT = "#999999";
const COLOR_CONTAINER = "#438dd5";
const COLOR_CONTAINER_EXT = "#b3b3b3";
const COLOR_COMPONENT = "#85bbf0";
const COLOR_COMPONENT_EXT = "#cccccc";
const COLOR_DB_STRIPE = "#0b3e73";
const TEXT_LIGHT = "#ffffff";
const TEXT_DARK = "#333333";
const BOUNDARY_STROKE = "#666666";

const ElemKind = enum {
    person, person_ext,
    system, system_ext,
    system_db, system_db_ext,
    container, container_ext,
    container_db, container_db_ext,
    component, component_ext,
    node, node_ext,
};

const Element = struct {
    alias: []const u8,
    label: []const u8,
    tech: []const u8,   // technology/type string
    desc: []const u8,
    kind: ElemKind,
    col: usize,
    row: usize,
};

const Relation = struct {
    from: []const u8,
    to: []const u8,
    label: []const u8,
    tech: []const u8,
    bidirectional: bool,
};

const Boundary = struct {
    alias: []const u8,
    label: []const u8,
    is_enterprise: bool,
    members: []const []const u8,
};

/// Render a C4 architecture diagram SVG from `value`.
/// `value` must be a node with `title`, `elements` (nodes with `alias`, `label`,
/// `tech`, `desc`, `kind`), `relations` (nodes with `from`, `to`, `label`, `tech`,
/// `bidirectional`), and `boundaries` (nodes with `alias`, `label`, `members` list).
pub fn render(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    const node = value.asNode() orelse return renderFallback(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const title = node.getString("title") orelse "";
    const elem_list = node.getList("elements");
    const rel_list = node.getList("relations");
    const bound_list = node.getList("boundaries");

    if (elem_list.len == 0) return renderFallback(allocator);

    // Build element array
    var elems: std.ArrayList(Element) = .empty;
    for (elem_list) |ev| {
        const en = ev.asNode() orelse continue;
        const alias = en.getString("alias") orelse continue;
        const lbl = en.getString("label") orelse alias;
        const tech = en.getString("tech") orelse "";
        const desc = en.getString("desc") orelse "";
        const kind_str = en.getString("kind") orelse "system";
        const kind = parseKind(kind_str);
        const idx = elems.items.len;
        try elems.append(a, Element{
            .alias = alias,
            .label = lbl,
            .tech = tech,
            .desc = desc,
            .kind = kind,
            .col = idx % GRID_COLS,
            .row = idx / GRID_COLS,
        });
    }

    // Build boundary array
    var bounds: std.ArrayList(Boundary) = .empty;
    for (bound_list) |bv| {
        const bn = bv.asNode() orelse continue;
        const alias = bn.getString("alias") orelse continue;
        const lbl = bn.getString("label") orelse alias;
        const is_ent = bn.getString("enterprise") != null;
        const ml = bn.getList("members");
        var members: std.ArrayList([]const u8) = .empty;
        for (ml) |mv| {
            if (mv.asString()) |ms| try members.append(a, ms);
        }
        try bounds.append(a, Boundary{
            .alias = alias,
            .label = lbl,
            .is_enterprise = is_ent,
            .members = try members.toOwnedSlice(a),
        });
    }

    // Build relation array
    var rels: std.ArrayList(Relation) = .empty;
    for (rel_list) |rv| {
        const rn = rv.asNode() orelse continue;
        const from = rn.getString("from") orelse continue;
        const to = rn.getString("to") orelse continue;
        const lbl = rn.getString("label") orelse "";
        const tech = rn.getString("tech") orelse "";
        const bi = rn.getString("bidirectional") != null;
        try rels.append(a, Relation{
            .from = from, .to = to,
            .label = lbl, .tech = tech,
            .bidirectional = bi,
        });
    }

    // Compute per-row max description lines
    const n_rows = (elems.items.len + GRID_COLS - 1) / GRID_COLS;
    var max_desc_per_row = [_]usize{0} ** 64;
    for (elems.items) |el| {
        if (el.row < 64) {
            const dl = descLines(el.desc);
            if (dl > max_desc_per_row[el.row]) max_desc_per_row[el.row] = dl;
        }
    }

    // Compute row Y offsets
    var row_y = [_]f32{0} ** 65;
    const title_h: f32 = if (title.len > 0) 40 else 0;
    row_y[0] = MARGIN + title_h;
    for (0..n_rows) |r| {
        const bh = boxHeight(max_desc_per_row[r]);
        row_y[r + 1] = row_y[r] + bh + ROW_GAP;
    }

    const total_w: u32 = @intFromFloat(
        MARGIN * 2 + @as(f32, @floatFromInt(GRID_COLS)) * (BOX_W + COL_GAP) - COL_GAP
    );
    const total_h: u32 = @intFromFloat(row_y[n_rows] + MARGIN);

    var svg = SvgWriter.init(allocator);
    defer svg.deinit();

    try svg.header(total_w, total_h);
    try svg.rect(0, 0, @floatFromInt(total_w), @floatFromInt(total_h), 0, theme.background, theme.background, 0);

    // Title
    if (title.len > 0) {
        try svg.text(
            @as(f32, @floatFromInt(total_w)) / 2, MARGIN + 20,
            title, theme.text_color, theme.font_size + 4, .middle, "bold"
        );
    }

    // Helper: element top-left X
    const elemX = struct {
        fn get(col: usize) f32 {
            return MARGIN + @as(f32, @floatFromInt(col)) * (BOX_W + COL_GAP);
        }
    }.get;

    // Draw boundaries (behind boxes)
    for (bounds.items) |bnd| {
        var min_col: usize = GRID_COLS;
        var max_col: usize = 0;
        var min_row: usize = n_rows;
        var max_row: usize = 0;
        for (bnd.members) |alias| {
            if (elemByAlias(elems.items, alias)) |el| {
                if (el.col < min_col) min_col = el.col;
                if (el.col > max_col) max_col = el.col;
                if (el.row < min_row) min_row = el.row;
                if (el.row > max_row) max_row = el.row;
            }
        }
        if (min_row > max_row) continue;
        const bx = elemX(min_col) - BOUNDARY_PAD;
        const by = row_y[min_row] - BOUNDARY_PAD;
        const bw = elemX(max_col) + BOX_W + BOUNDARY_PAD - bx;
        const bh = row_y[max_row] + boxHeightAtRow(max_row, &max_desc_per_row) + BOUNDARY_PAD - by;
        const bstroke = if (bnd.is_enterprise) "#333333" else BOUNDARY_STROKE;
        const bstroke_w: f32 = if (bnd.is_enterprise) 2.5 else 1.0;
        const bfill = if (bnd.is_enterprise) "#f5f5f5" else "#fafafa";
        try svg.rect(bx, by, bw, bh, 6, bfill, bstroke, bstroke_w);
        // dashed overlay
        try svg.dashedLine(bx, by, bx + bw, by, bstroke, bstroke_w, "8,4");
        try svg.dashedLine(bx, by, bx, by + bh, bstroke, bstroke_w, "8,4");
        try svg.dashedLine(bx + bw, by, bx + bw, by + bh, bstroke, bstroke_w, "8,4");
        try svg.dashedLine(bx, by + bh, bx + bw, by + bh, bstroke, bstroke_w, "8,4");
        const blbl_style = if (bnd.is_enterprise) "bold" else "normal";
        try svg.text(bx + BOUNDARY_PAD, by - 6, bnd.label, bstroke, theme.font_size_small, .start, blbl_style);
    }

    // Draw relations (behind boxes)
    for (rels.items) |rel| {
        const fi = elemByAlias(elems.items, rel.from) orelse continue;
        const ti = elemByAlias(elems.items, rel.to) orelse continue;
        const fc = fi;
        const tc = ti;
        const fbh = boxHeight(if (fc.row < 64) max_desc_per_row[fc.row] else 0);
        const tbh = boxHeight(if (tc.row < 64) max_desc_per_row[tc.row] else 0);

        const fcx = elemX(fc.col) + BOX_W / 2;
        const fcy_mid = row_y[fc.row] + fbh / 2;
        const fcy_bot = row_y[fc.row] + fbh;
        const tcx = elemX(tc.col) + BOX_W / 2;
        const tcy_mid = row_y[tc.row] + tbh / 2;
        const tcy_top = row_y[tc.row];
        const tcy_bot = row_y[tc.row] + tbh;

        const from_x: f32, const from_y: f32, const to_x: f32, const to_y: f32 = blk: {
            if (fc.row == tc.row) {
                if (fc.col < tc.col) {
                    break :blk .{ elemX(fc.col) + BOX_W, fcy_mid, elemX(tc.col), tcy_mid };
                } else {
                    break :blk .{ elemX(fc.col), fcy_mid, elemX(tc.col) + BOX_W, tcy_mid };
                }
            } else if (fc.row < tc.row) {
                break :blk .{ fcx, fcy_bot, tcx, tcy_top };
            } else {
                break :blk .{ fcx, row_y[fc.row], tcx, tcy_bot };
            }
        };

        // Cubic Bezier edge: same-row arcs below to avoid crossing intermediate boxes;
        // different-row uses an S-curve for cleaner visual flow.
        const cx1: f32, const cy1: f32, const cx2: f32, const cy2: f32 = blk: {
            if (fc.row == tc.row) {
                const arc: f32 = 50;
                const dx_third = (to_x - from_x) / 3;
                break :blk .{ from_x + dx_third, from_y + arc, to_x - dx_third, to_y + arc };
            } else {
                const ctrl: f32 = ROW_GAP * 0.5;
                if (fc.row < tc.row) {
                    break :blk .{ from_x, from_y + ctrl, to_x, to_y - ctrl };
                } else {
                    break :blk .{ from_x, from_y - ctrl, to_x, to_y + ctrl };
                }
            }
        };
        var path_buf: [256]u8 = undefined;
        const path_d = try std.fmt.bufPrint(&path_buf,
            "M {d:.1} {d:.1} C {d:.1} {d:.1} {d:.1} {d:.1} {d:.1} {d:.1}",
            .{ from_x, from_y, cx1, cy1, cx2, cy2, to_x, to_y });
        try svg.path(path_d, "none", "#666666", 1.5, "stroke-dasharray=\"6,3\"");

        // Arrowhead tangent follows Bezier endpoint direction
        try drawArrow(&svg, to_x, to_y, cx2, cy2);
        if (rel.bidirectional) {
            try drawArrow(&svg, from_x, from_y, cx1, cy1);
        }

        // Label near midpoint (at the Bezier midpoint, t=0.5)
        const mx = 0.125 * from_x + 0.375 * cx1 + 0.375 * cx2 + 0.125 * to_x;
        const my = 0.125 * from_y + 0.375 * cy1 + 0.375 * cy2 + 0.125 * to_y;
        if (rel.label.len > 0) {
            try svg.text(mx, my - 6, rel.label, TEXT_DARK, theme.font_size_small, .middle, "normal");
        }
        if (rel.tech.len > 0) {
            try svg.text(mx, my + 8, rel.tech, "#666666", theme.font_size_small - 1, .middle, "normal");
        }
    }

    // Draw element boxes
    for (elems.items) |el| {
        const bx = elemX(el.col);
        const by = row_y[el.row];
        const bh = boxHeight(if (el.row < 64) max_desc_per_row[el.row] else 0);
        const fill = elemFill(el.kind);
        const text_col = if (isLightText(el.kind)) TEXT_LIGHT else TEXT_DARK;
        const stroke = elemStroke(el.kind);

        // Outer box — ext variants get a dashed border
        if (isExt(el.kind)) {
            var raw_buf: [256]u8 = undefined;
            const raw_str = try std.fmt.bufPrint(&raw_buf,
                "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"4\" " ++
                "fill=\"{s}\" stroke=\"{s}\" stroke-width=\"1.5\" stroke-dasharray=\"5,3\"/>\n",
                .{ bx, by, BOX_W, bh, fill, stroke });
            try svg.raw(raw_str);
        } else {
            try svg.rect(bx, by, BOX_W, bh, 4.0, fill, stroke, 1.5);
        }

        // Person: draw head circle above box
        if (el.kind == .person or el.kind == .person_ext) {
            try svg.circle(bx + BOX_W / 2, by - 12, 12, fill, stroke, 1.5);
        }

        // DB stripe at top
        if (isDb(el.kind)) {
            const stripe_h: f32 = 10;
            try svg.rect(bx, by, BOX_W, stripe_h, 4.0, darkerFill(el.kind), stroke, 0);
            // Cover bottom of stripe with same fill to get flat bottom
            try svg.rect(bx + 1, by + stripe_h / 2, BOX_W - 2, stripe_h / 2, 0, fill, "none", 0);
        }

        // Stereotype label (e.g. "[Person]", "[System]")
        const stereotype = stereotypeName(el.kind);
        try svg.text(bx + BOX_W / 2, by + 16, stereotype, text_col, theme.font_size_small - 1, .middle, "normal");

        // Name (bold, centered)
        try svg.text(bx + BOX_W / 2, by + 30, el.label, text_col, theme.font_size_small + 1, .middle, "bold");

        // Tech/type line below name
        if (el.tech.len > 0) {
            var tech_buf: [128]u8 = undefined;
            const tech_lbl = std.fmt.bufPrint(&tech_buf, "[{s}]", .{el.tech}) catch el.tech;
            try svg.text(bx + BOX_W / 2, by + 44, tech_lbl, text_col, theme.font_size_small - 1, .middle, "normal");
        }

        // Description lines
        if (el.desc.len > 0) {
            const desc_y_start = by + BOX_HEADER_H + (if (el.tech.len > 0) @as(f32, 14) else 0) + 8;
            // Draw separator line
            try svg.line(bx, desc_y_start - 4, bx + BOX_W, desc_y_start - 4, stroke, 0.5);
            // Word-wrap: break at ~24 chars
            var line_idx: usize = 0;
            var desc_rest: []const u8 = el.desc;
            while (desc_rest.len > 0 and line_idx < 4) {
                const chunk_len = if (desc_rest.len > 24) blk: {
                    // Try to break at last space before 24
                    var bp: usize = 24;
                    while (bp > 12 and desc_rest[bp] != ' ') : (bp -= 1) {}
                    break :blk if (desc_rest[bp] == ' ') bp else 24;
                } else desc_rest.len;
                const chunk = desc_rest[0..chunk_len];
                const ly = desc_y_start + @as(f32, @floatFromInt(line_idx)) * BOX_DESC_LINE_H + 12;
                try svg.text(bx + BOX_W / 2, ly, chunk, text_col, theme.font_size_small - 1, .middle, "normal");
                desc_rest = std.mem.trim(u8, desc_rest[chunk_len..], " ");
                line_idx += 1;
            }
        }
    }

    try svg.footer();
    return svg.toOwnedSlice();
}

fn drawArrow(svg: *SvgWriter, tip_x: f32, tip_y: f32, from_x: f32, from_y: f32) !void {
    const dx = from_x - tip_x;
    const dy = from_y - tip_y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1.0) return;
    const ux = dx / len;
    const uy = dy / len;
    const arr: f32 = 9.0;
    const half: f32 = 5.0;
    const b1x = tip_x + ux * arr + (-uy) * half;
    const b1y = tip_y + uy * arr + ux * half;
    const b2x = tip_x + ux * arr - (-uy) * half;
    const b2y = tip_y + uy * arr - ux * half;
    var pts_buf: [192]u8 = undefined;
    const pts = try std.fmt.bufPrint(&pts_buf,
        "{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}",
        .{ b1x, b1y, tip_x, tip_y, b2x, b2y });
    try svg.polygon(pts, "none", "#666666", 1.5);
}

fn elemByAlias(elems: []const Element, alias: []const u8) ?*const Element {
    for (elems) |*el| {
        if (std.mem.eql(u8, el.alias, alias)) return el;
    }
    return null;
}

fn descLines(desc: []const u8) usize {
    if (desc.len == 0) return 0;
    return (desc.len + 23) / 24; // approximate
}

fn boxHeight(max_desc_lines: usize) f32 {
    return BOX_HEADER_H + @as(f32, @floatFromInt(max_desc_lines)) * BOX_DESC_LINE_H + BOX_PAD_BOTTOM + 16;
}

fn boxHeightAtRow(row: usize, max_desc_per_row: *const [64]usize) f32 {
    return boxHeight(max_desc_per_row[row]);
}

fn parseKind(s: []const u8) ElemKind {
    if (std.mem.eql(u8, s, "person")) return .person;
    if (std.mem.eql(u8, s, "person_ext")) return .person_ext;
    if (std.mem.eql(u8, s, "system")) return .system;
    if (std.mem.eql(u8, s, "system_ext")) return .system_ext;
    if (std.mem.eql(u8, s, "system_db")) return .system_db;
    if (std.mem.eql(u8, s, "system_db_ext")) return .system_db_ext;
    if (std.mem.eql(u8, s, "container")) return .container;
    if (std.mem.eql(u8, s, "container_ext")) return .container_ext;
    if (std.mem.eql(u8, s, "container_db")) return .container_db;
    if (std.mem.eql(u8, s, "container_db_ext")) return .container_db_ext;
    if (std.mem.eql(u8, s, "component")) return .component;
    if (std.mem.eql(u8, s, "component_ext")) return .component_ext;
    if (std.mem.eql(u8, s, "node")) return .node;
    if (std.mem.eql(u8, s, "node_ext")) return .node_ext;
    return .system;
}

fn elemFill(k: ElemKind) []const u8 {
    return switch (k) {
        .person => COLOR_PERSON,
        .person_ext => COLOR_PERSON_EXT,
        .system, .system_db => COLOR_SYSTEM,
        .system_ext, .system_db_ext => COLOR_SYSTEM_EXT,
        .container, .container_db => COLOR_CONTAINER,
        .container_ext, .container_db_ext => COLOR_CONTAINER_EXT,
        .component => COLOR_COMPONENT,
        .component_ext => COLOR_COMPONENT_EXT,
        .node => COLOR_CONTAINER,
        .node_ext => COLOR_CONTAINER_EXT,
    };
}

fn elemStroke(k: ElemKind) []const u8 {
    return switch (k) {
        .person => "#052e56",
        .person_ext => "#454545",
        .system, .system_db => "#0b3e73",
        .system_ext, .system_db_ext => "#666666",
        .container, .container_db => "#2e6295",
        .container_ext, .container_db_ext => "#888888",
        .component => "#5882a4",
        .component_ext => "#999999",
        .node => "#2e6295",
        .node_ext => "#888888",
    };
}

fn darkerFill(k: ElemKind) []const u8 {
    return switch (k) {
        .system_db, .system => COLOR_DB_STRIPE,
        .container_db, .container => "#2e6295",
        else => "#555555",
    };
}

fn isLightText(k: ElemKind) bool {
    return switch (k) {
        .person, .system, .system_db, .container, .container_db, .node => true,
        else => false,
    };
}

fn isDb(k: ElemKind) bool {
    return switch (k) {
        .system_db, .system_db_ext, .container_db, .container_db_ext => true,
        else => false,
    };
}

fn isExt(k: ElemKind) bool {
    return switch (k) {
        .person_ext, .system_ext, .system_db_ext,
        .container_ext, .container_db_ext, .component_ext, .node_ext => true,
        else => false,
    };
}

fn stereotypeName(k: ElemKind) []const u8 {
    return switch (k) {
        .person, .person_ext => "[Person]",
        .system, .system_ext => "[Software System]",
        .system_db, .system_db_ext => "[Database]",
        .container, .container_ext => "[Container]",
        .container_db, .container_db_ext => "[Container: DB]",
        .component, .component_ext => "[Component]",
        .node, .node_ext => "[Node]",
    };
}

fn renderFallback(allocator: std.mem.Allocator) ![]const u8 {
    var svg = SvgWriter.init(allocator);
    defer svg.deinit();
    try svg.header(400, 200);
    try svg.text(200, 100, "C4 Diagram", theme.text_color, theme.font_size, .middle, "normal");
    try svg.footer();
    return svg.toOwnedSlice();
}
