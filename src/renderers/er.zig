//! Entity-relationship diagram SVG renderer.
const std = @import("std");
const Value = @import("../diagram/value.zig").Value;
const SvgWriter = @import("../svg/writer.zig").SvgWriter;
const theme = @import("../svg/theme.zig");

const ENTITY_W: f32 = 160;
const HEADER_H: f32 = 30;
const ATTR_H: f32 = 20;
const GRID_COLS: usize = 3;
const COL_GAP: f32 = 100;
const ROW_GAP: f32 = 80;
const MARGIN: f32 = 40;

const Attribute = struct {
    type_str: []const u8,
    name: []const u8,
    key: bool,
};

const Entity = struct {
    name: []const u8,
    attrs: []Attribute,
    col: usize,
    row: usize,
};

// Crow's foot cardinality
const Cardinality = enum { one, zero_or_one, many, one_or_many, zero_or_many };

const Relation = struct {
    from: []const u8,
    to: []const u8,
    from_card: Cardinality,
    to_card: Cardinality,
    label: []const u8,
    dashed: bool,
};

pub fn render(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    const node = value.asNode() orelse return renderFallback(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var entities: std.ArrayList(Entity) = .empty;
    var relations: std.ArrayList(Relation) = .empty;

    for (node.getList("entities")) |ev| {
        const en = ev.asNode() orelse continue;
        const name = en.getString("name") orelse continue;
        const raw_attrs = en.getList("attrs");
        var attrs: std.ArrayList(Attribute) = .empty;
        for (raw_attrs) |av| {
            const an = av.asNode() orelse continue;
            const atype = an.getString("type") orelse "";
            const aname = an.getString("name") orelse continue;
            const key = an.getString("key") != null;
            try attrs.append(a, Attribute{ .type_str = atype, .name = aname, .key = key });
        }
        const idx = entities.items.len;
        try entities.append(a, Entity{
            .name = name,
            .attrs = try attrs.toOwnedSlice(a),
            .col = idx % GRID_COLS,
            .row = idx / GRID_COLS,
        });
    }

    for (node.getList("relations")) |rv| {
        const rn = rv.asNode() orelse continue;
        const from = rn.getString("from") orelse continue;
        const to = rn.getString("to") orelse continue;
        const lbl = rn.getString("label") orelse "";
        const rel_str = rn.getString("rel") orelse "||--||";
        const dashed = std.mem.indexOf(u8, rel_str, "..") != null;
        try relations.append(a, Relation{
            .from = from,
            .to = to,
            .from_card = parseCardinality(rel_str, true),
            .to_card = parseCardinality(rel_str, false),
            .label = stripQuotes(lbl),
            .dashed = dashed,
        });
    }

    if (entities.items.len == 0) return renderFallback(allocator);

    const n_rows = (entities.items.len + GRID_COLS - 1) / GRID_COLS;
    var max_attrs_per_row = [_]usize{0} ** 64;
    for (entities.items) |en| {
        if (en.row < 64 and en.attrs.len > max_attrs_per_row[en.row])
            max_attrs_per_row[en.row] = en.attrs.len;
    }

    var row_y = [_]f32{0} ** 65;
    row_y[0] = MARGIN;
    for (0..n_rows) |r| {
        const h = HEADER_H + @as(f32, @floatFromInt(max_attrs_per_row[r])) * ATTR_H + 8;
        row_y[r + 1] = row_y[r] + h + ROW_GAP;
    }

    const total_w: u32 = @intFromFloat(
        MARGIN * 2 + @as(f32, @floatFromInt(GRID_COLS)) * (ENTITY_W + COL_GAP) - COL_GAP
    );
    const total_h: u32 = @intFromFloat(row_y[n_rows] + MARGIN);

    var svg = SvgWriter.init(allocator);
    defer svg.deinit();

    try svg.header(total_w, total_h);
    try svg.rect(0, 0, @floatFromInt(total_w), @floatFromInt(total_h), 0, theme.background, theme.background, 0);

    const entityX = struct {
        fn get(col: usize) f32 {
            return MARGIN + @as(f32, @floatFromInt(col)) * (ENTITY_W + COL_GAP);
        }
    }.get;

    // Draw relations behind boxes
    for (relations.items) |rel| {
        const fi = entityIndex(entities.items, rel.from) orelse continue;
        const ti = entityIndex(entities.items, rel.to) orelse continue;
        const fe = entities.items[fi];
        const te = entities.items[ti];

        const fh = HEADER_H + @as(f32, @floatFromInt(fe.attrs.len)) * ATTR_H + 8;
        const th = HEADER_H + @as(f32, @floatFromInt(te.attrs.len)) * ATTR_H + 8;

        const fx = entityX(fe.col) + ENTITY_W / 2;
        const fy = row_y[fe.row] + fh / 2;
        const tx = entityX(te.col) + ENTITY_W / 2;
        const ty = row_y[te.row] + th / 2;

        // Connect right/left edges if same row, top/bottom otherwise
        const from_x = if (fe.row == te.row and fe.col < te.col) entityX(fe.col) + ENTITY_W else fx;
        const from_y2 = if (fe.row != te.row) (if (fe.row < te.row) row_y[fe.row] + fh else row_y[fe.row]) else fy;
        const to_x = if (fe.row == te.row and fe.col < te.col) entityX(te.col) else tx;
        const to_y2 = if (fe.row != te.row) (if (fe.row < te.row) row_y[te.row] else row_y[te.row] + th) else ty;

        if (rel.dashed) {
            try svg.dashedLine(from_x, from_y2, to_x, to_y2, theme.line_color, 1.5, "6,3");
        } else {
            try svg.line(from_x, from_y2, to_x, to_y2, theme.line_color, 1.5);
        }

        // Draw crow's foot terminators
        try drawCrowsFoot(&svg, from_x, from_y2, to_x, to_y2, rel.to_card);
        try drawCrowsFoot(&svg, to_x, to_y2, from_x, from_y2, rel.from_card);

        if (rel.label.len > 0) {
            try svg.text((from_x + to_x) / 2, (from_y2 + to_y2) / 2 - 8, rel.label, theme.text_color, theme.font_size_small, .middle, "normal");
        }
    }

    // Draw entity boxes
    for (entities.items) |en| {
        const bx = entityX(en.col);
        const by = row_y[en.row];
        const bh = HEADER_H + @as(f32, @floatFromInt(en.attrs.len)) * ATTR_H + 8;

        try svg.rect(bx, by, ENTITY_W, bh, 3.0, theme.node_fill, theme.node_stroke, 1.5);
        try svg.line(bx, by + HEADER_H, bx + ENTITY_W, by + HEADER_H, theme.node_stroke, 1.0);
        try svg.text(bx + ENTITY_W / 2, by + HEADER_H / 2 + 5, en.name, theme.text_color, theme.font_size, .middle, "bold");

        for (en.attrs, 0..) |attr, ai| {
            const ay = by + HEADER_H + 4 + @as(f32, @floatFromInt(ai)) * ATTR_H + ATTR_H / 2;
            var buf: [128]u8 = undefined;
            const lbl = std.fmt.bufPrint(&buf, "{s} {s}{s}", .{
                attr.type_str, attr.name,
                if (attr.key) " PK" else "",
            }) catch attr.name;
            try svg.text(bx + 6, ay, lbl, theme.text_color, theme.font_size_small, .start, "normal");
        }
    }

    try svg.footer();
    return svg.toOwnedSlice();
}

fn drawCrowsFoot(svg: *SvgWriter, tip_x: f32, tip_y: f32, from_x: f32, from_y: f32, card: Cardinality) !void {
    const dx = from_x - tip_x;
    const dy = from_y - tip_y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1.0) return;
    const ux = dx / len;
    const uy = dy / len;
    const px = -uy;
    const py = ux;
    const d: f32 = 12.0;
    const hw: f32 = 7.0;

    switch (card) {
        .one => {
            // Single bar
            try svg.line(tip_x + ux * d - px * hw, tip_y + uy * d - py * hw,
                         tip_x + ux * d + px * hw, tip_y + uy * d + py * hw,
                         theme.line_color, 1.5);
        },
        .zero_or_one => {
            // Bar + circle
            try svg.line(tip_x + ux * d - px * hw, tip_y + uy * d - py * hw,
                         tip_x + ux * d + px * hw, tip_y + uy * d + py * hw,
                         theme.line_color, 1.5);
            try svg.circle(tip_x + ux * d * 2, tip_y + uy * d * 2, 4.0, theme.background, theme.line_color, 1.5);
        },
        .many => {
            // Crow's foot (3 lines)
            try svg.line(tip_x, tip_y, tip_x + ux * d + px * hw, tip_y + uy * d + py * hw, theme.line_color, 1.5);
            try svg.line(tip_x, tip_y, tip_x + ux * d - px * hw, tip_y + uy * d - py * hw, theme.line_color, 1.5);
            try svg.line(tip_x, tip_y, tip_x + ux * d, tip_y + uy * d, theme.line_color, 1.5);
        },
        .one_or_many => {
            // Crow's foot + bar
            try svg.line(tip_x, tip_y, tip_x + ux * d + px * hw, tip_y + uy * d + py * hw, theme.line_color, 1.5);
            try svg.line(tip_x, tip_y, tip_x + ux * d - px * hw, tip_y + uy * d - py * hw, theme.line_color, 1.5);
            try svg.line(tip_x, tip_y, tip_x + ux * d, tip_y + uy * d, theme.line_color, 1.5);
            try svg.line(tip_x + ux * d * 1.5 - px * hw, tip_y + uy * d * 1.5 - py * hw,
                         tip_x + ux * d * 1.5 + px * hw, tip_y + uy * d * 1.5 + py * hw,
                         theme.line_color, 1.5);
        },
        .zero_or_many => {
            // Crow's foot + circle
            try svg.line(tip_x, tip_y, tip_x + ux * d + px * hw, tip_y + uy * d + py * hw, theme.line_color, 1.5);
            try svg.line(tip_x, tip_y, tip_x + ux * d - px * hw, tip_y + uy * d - py * hw, theme.line_color, 1.5);
            try svg.line(tip_x, tip_y, tip_x + ux * d, tip_y + uy * d, theme.line_color, 1.5);
            try svg.circle(tip_x + ux * d * 1.8, tip_y + uy * d * 1.8, 4.0, theme.background, theme.line_color, 1.5);
        },
    }
}

fn entityIndex(entities: []const Entity, name: []const u8) ?usize {
    for (entities, 0..) |e, i| if (std.mem.eql(u8, e.name, name)) return i;
    return null;
}

/// Parse the cardinality marker from a relationship string like `||--o{`.
/// `from_side=true` reads the left half, `false` reads the right.
fn parseCardinality(rel: []const u8, from_side: bool) Cardinality {
    // Find the connector (-- or ..)
    const sep = std.mem.indexOf(u8, rel, "--") orelse std.mem.indexOf(u8, rel, "..") orelse return .one;
    const connector_len: usize = 2;
    const left = rel[0..sep];
    const right = rel[sep + connector_len..];
    const side = if (from_side) left else right;
    // Cardinality chars: | = exactly one, o = zero, { = many (right), } = many (left)
    const has_circle = std.mem.indexOf(u8, side, "o") != null;
    const has_bar = std.mem.indexOfScalar(u8, side, '|') != null;
    const has_many = std.mem.indexOfScalar(u8, side, '{') != null or
                     std.mem.indexOfScalar(u8, side, '}') != null;
    if (has_many and has_bar) return .one_or_many;
    if (has_many and has_circle) return .zero_or_many;
    if (has_many) return .many;
    if (has_circle and has_bar) return .zero_or_one;
    return .one;
}

fn stripQuotes(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') return t[1..t.len - 1];
    return t;
}

fn renderFallback(allocator: std.mem.Allocator) ![]const u8 {
    var svg = SvgWriter.init(allocator);
    defer svg.deinit();
    try svg.header(400, 200);
    try svg.text(200, 100, "erDiagram", theme.text_color, theme.font_size, .middle, "normal");
    try svg.footer();
    return svg.toOwnedSlice();
}
