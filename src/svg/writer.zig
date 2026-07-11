//! Low-level SVG string builder used by all renderers.
//!
//! `SvgWriter` accumulates SVG markup in an internal `ArrayList(u8)`.
//! Callers write elements via typed methods (`rect`, `circle`, `text`, etc.),
//! then call `toOwnedSlice` to obtain the final string.  Text content and the
//! user-controllable attribute values (`fill`, `stroke`, `font-weight`,
//! `font-family`) are XML-escaped automatically, so untrusted color/style
//! strings cannot break out of a quoted attribute.  The structural escape
//! hatches — `openGroup(attrs)`, `defs(content)`, `path(extra_attrs)` and
//! `raw(fragment)` — are emitted verbatim and MUST only be passed
//! renderer-controlled (non-user) markup.
//!
//! Typical usage:
//! ```zig
//! var svg = SvgWriter.init(allocator);
//! defer svg.deinit();
//! try svg.header(800, 600);
//! try svg.rect(10, 10, 200, 100, 4.0, "#ececff", "#9370db", 1.5);
//! try svg.text(110, 65, "Hello", "#333", 14, .middle, "normal");
//! try svg.footer();
//! const output = try svg.toOwnedSlice(); // caller owns this
//! ```
const std = @import("std");
const theme = @import("theme.zig");

/// Streaming SVG builder.  Call methods in document order; `header` first,
/// `footer` last, `toOwnedSlice` after `footer`.
pub const SvgWriter = struct {
    buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    /// Initialise an empty writer backed by `allocator`.
    pub fn init(allocator: std.mem.Allocator) SvgWriter {
        var buf: std.ArrayList(u8) = .empty;
        buf.ensureTotalCapacity(allocator, 8192) catch {};
        return .{ .buf = buf, .allocator = allocator };
    }

    /// Release the internal buffer.  Do not call after `toOwnedSlice`.
    pub fn deinit(self: *SvgWriter) void {
        self.buf.deinit(self.allocator);
    }

    /// Transfer ownership of the accumulated SVG bytes to the caller.
    /// The writer must not be used after this call.
    pub fn toOwnedSlice(self: *SvgWriter) ![]u8 {
        return self.buf.toOwnedSlice(self.allocator);
    }

    /// Emit ` name="value"` with `value` XML-escaped.  Used for the
    /// user-controllable colour/font attributes so an embedded `"` or `>`
    /// cannot break out of the attribute or the element.
    fn attrEsc(self: *SvgWriter, name: []const u8, value: []const u8) !void {
        try self.buf.print(self.allocator, " {s}=\"", .{name});
        try xmlEscape(&self.buf, self.allocator, value);
        try self.buf.append(self.allocator, '"');
    }

    /// Emit the SVG root element opening tag with explicit `width`/`height`
    /// and a matching `viewBox`.
    pub fn header(self: *SvgWriter, width: u32, height: u32) !void {
        try self.buf.print(self.allocator,
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 {d} {d}\">\n",
            .{ width, height, width, height },
        );
    }

    /// Emit the SVG root element closing tag.
    pub fn footer(self: *SvgWriter) !void {
        try self.buf.appendSlice(self.allocator, "</svg>\n");
    }

    /// Open a `<g>` group element.  Pass `attrs` for additional SVG attributes
    /// (e.g. `"opacity=\"0.5\""`), or an empty string for a plain `<g>`.
    pub fn openGroup(self: *SvgWriter, attrs: []const u8) !void {
        if (attrs.len > 0) {
            try self.buf.print(self.allocator, "<g {s}>\n", .{attrs});
        } else {
            try self.buf.appendSlice(self.allocator, "<g>\n");
        }
    }

    /// Close the current `<g>` group element.
    pub fn closeGroup(self: *SvgWriter) !void {
        try self.buf.appendSlice(self.allocator, "</g>\n");
    }

    /// Emit a `<defs>` block containing the raw `content` string.
    /// Used for marker, gradient, and filter definitions.
    pub fn defs(self: *SvgWriter, content: []const u8) !void {
        try self.buf.print(self.allocator, "<defs>\n{s}</defs>\n", .{content});
    }

    /// Emit a `<rect>` element.  `rx` is the corner radius (0 for sharp corners).
    pub fn rect(
        self: *SvgWriter,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        rx: f32,
        fill: []const u8,
        stroke: []const u8,
        stroke_width: f32,
    ) !void {
        try self.buf.print(self.allocator,
            "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" rx=\"{d:.2}\"",
            .{ x, y, width, height, rx },
        );
        try self.attrEsc("fill", fill);
        try self.attrEsc("stroke", stroke);
        try self.buf.print(self.allocator, " stroke-width=\"{d:.1}\"/>\n", .{stroke_width});
    }

    /// Emit a `<circle>` element centred at (`cx`, `cy`) with radius `r`.
    pub fn circle(
        self: *SvgWriter,
        cx: f32,
        cy: f32,
        r: f32,
        fill: []const u8,
        stroke: []const u8,
        stroke_width: f32,
    ) !void {
        try self.buf.print(self.allocator,
            "<circle cx=\"{d:.2}\" cy=\"{d:.2}\" r=\"{d:.2}\"",
            .{ cx, cy, r },
        );
        try self.attrEsc("fill", fill);
        try self.attrEsc("stroke", stroke);
        try self.buf.print(self.allocator, " stroke-width=\"{d:.1}\"/>\n", .{stroke_width});
    }

    /// Emit a solid `<line>` element.
    pub fn line(
        self: *SvgWriter,
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        stroke: []const u8,
        stroke_width: f32,
    ) !void {
        try self.buf.print(self.allocator,
            "<line x1=\"{d:.2}\" y1=\"{d:.2}\" x2=\"{d:.2}\" y2=\"{d:.2}\"",
            .{ x1, y1, x2, y2 },
        );
        try self.attrEsc("stroke", stroke);
        try self.buf.print(self.allocator, " stroke-width=\"{d:.1}\"/>\n", .{stroke_width});
    }

    /// Emit a `<path>` element with SVG path data `d`.
    /// Pass `extra_attrs` for additional attributes such as
    /// `"stroke-dasharray=\"5,5\""` or `"fill-opacity=\"0.4\""`,
    /// or an empty string for none.
    pub fn path(
        self: *SvgWriter,
        d: []const u8,
        fill: []const u8,
        stroke: []const u8,
        stroke_width: f32,
        extra_attrs: []const u8,
    ) !void {
        try self.buf.print(self.allocator, "<path d=\"{s}\"", .{d});
        try self.attrEsc("fill", fill);
        try self.attrEsc("stroke", stroke);
        if (extra_attrs.len > 0) {
            try self.buf.print(self.allocator,
                " stroke-width=\"{d:.1}\" {s}/>\n",
                .{ stroke_width, extra_attrs },
            );
        } else {
            try self.buf.print(self.allocator, " stroke-width=\"{d:.1}\"/>\n", .{stroke_width});
        }
    }

    /// Horizontal text alignment for `text`.
    pub const TextAnchor = enum { start, middle, end };

    /// Emit a `<text>` element.  `content` is XML-escaped automatically.
    pub fn text(
        self: *SvgWriter,
        x: f32,
        y: f32,
        content: []const u8,
        fill: []const u8,
        font_size: u32,
        anchor: TextAnchor,
        font_weight: []const u8,
    ) !void {
        const anchor_str: []const u8 = switch (anchor) {
            .start => "start",
            .middle => "middle",
            .end => "end",
        };
        try self.buf.print(self.allocator, "<text x=\"{d:.2}\" y=\"{d:.2}\"", .{ x, y });
        try self.attrEsc("fill", fill);
        try self.buf.print(self.allocator, " font-size=\"{d}\" text-anchor=\"{s}\"", .{ font_size, anchor_str });
        try self.attrEsc("font-weight", font_weight);
        try self.attrEsc("font-family", theme.font_family);
        try self.buf.append(self.allocator, '>');
        try xmlEscape(&self.buf, self.allocator, content);
        try self.buf.appendSlice(self.allocator, "</text>\n");
    }

    /// Emit a `<polygon>` element.  `points` is a space-separated list of
    /// `x,y` coordinate pairs, e.g. `"0,0 10,5 0,10"`.
    pub fn polygon(
        self: *SvgWriter,
        points: []const u8,
        fill: []const u8,
        stroke: []const u8,
        stroke_width: f32,
    ) !void {
        try self.buf.print(self.allocator, "<polygon points=\"{s}\"", .{points});
        try self.attrEsc("fill", fill);
        try self.attrEsc("stroke", stroke);
        try self.buf.print(self.allocator, " stroke-width=\"{d:.1}\"/>\n", .{stroke_width});
    }

    /// Emit a `<line>` element with `stroke-dasharray` set to `dasharray`
    /// (e.g. `"5,3"` or `"4,4"`).
    pub fn dashedLine(
        self: *SvgWriter,
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        stroke: []const u8,
        stroke_width: f32,
        dasharray: []const u8,
    ) !void {
        try self.buf.print(self.allocator,
            "<line x1=\"{d:.2}\" y1=\"{d:.2}\" x2=\"{d:.2}\" y2=\"{d:.2}\"",
            .{ x1, y1, x2, y2 },
        );
        try self.attrEsc("stroke", stroke);
        try self.buf.print(self.allocator,
            " stroke-width=\"{d:.1}\" stroke-dasharray=\"{s}\"/>\n",
            .{ stroke_width, dasharray },
        );
    }

    /// Emit a `<text>` element with automatic word-wrapping via `<tspan>`.
    /// Text wider than `max_w` pixels wraps to a second line; any overflow
    /// beyond two lines is truncated with an ellipsis. Character width is
    /// approximated as `font_size * 0.55`.
    pub fn textWrapped(
        self: *SvgWriter,
        x: f32,
        cy: f32,
        content: []const u8,
        max_w: f32,
        fill: []const u8,
        font_size: u32,
        anchor: TextAnchor,
        font_weight: []const u8,
    ) !void {
        const char_w: f32 = @as(f32, @floatFromInt(font_size)) * 0.55;
        const chars_per_line: usize = @max(1, @as(usize, @intFromFloat(max_w / char_w)));

        if (content.len <= chars_per_line) {
            return self.text(x, cy, content, fill, font_size, anchor, font_weight);
        }

        // Find last word boundary at or before chars_per_line.
        const search_end = @min(chars_per_line + 1, content.len);
        const split_at: usize = blk: {
            if (std.mem.lastIndexOfScalar(u8, content[0..search_end], ' ')) |sp| break :blk sp;
            break :blk chars_per_line; // hard split — no space found
        };
        const line1 = content[0..split_at];
        const line2_start = if (split_at < content.len and content[split_at] == ' ')
            split_at + 1
        else
            split_at;
        const rest = content[line2_start..];

        // Truncate line2 if still too wide.
        var trunc_buf: [128]u8 = undefined;
        const line2: []const u8 = if (rest.len > chars_per_line) blk: {
            var cut = if (chars_per_line > 3) chars_per_line - 3 else 0;
            while (cut > 0 and rest[cut] != ' ') : (cut -= 1) {}
            if (cut == 0 and chars_per_line > 3) cut = chars_per_line - 3;
            const truncated = std.fmt.bufPrint(&trunc_buf, "{s}...", .{rest[0..cut]}) catch rest[0..@min(rest.len, chars_per_line)];
            break :blk truncated;
        } else rest;

        const line_h: f32 = @as(f32, @floatFromInt(font_size)) + 2.0;
        const y1 = cy - line_h / 2.0;
        const y2 = cy + line_h / 2.0;
        const anchor_str: []const u8 = switch (anchor) {
            .start => "start",
            .middle => "middle",
            .end => "end",
        };
        try self.buf.appendSlice(self.allocator, "<text");
        try self.attrEsc("fill", fill);
        try self.buf.print(self.allocator, " font-size=\"{d}\" text-anchor=\"{s}\"", .{ font_size, anchor_str });
        try self.attrEsc("font-weight", font_weight);
        try self.attrEsc("font-family", theme.font_family);
        try self.buf.append(self.allocator, '>');
        try self.buf.print(self.allocator, "<tspan x=\"{d:.2}\" y=\"{d:.2}\">", .{ x, y1 });
        try xmlEscape(&self.buf, self.allocator, line1);
        try self.buf.appendSlice(self.allocator, "</tspan>");
        try self.buf.print(self.allocator, "<tspan x=\"{d:.2}\" y=\"{d:.2}\">", .{ x, y2 });
        try xmlEscape(&self.buf, self.allocator, line2);
        try self.buf.appendSlice(self.allocator, "</tspan></text>\n");
    }

    /// Emit a `<text>` element rotated `deg` degrees about (`ox`, `oy`).
    /// Content, `fill`, and the theme font-family are XML-escaped.
    pub fn textRotated(
        self: *SvgWriter,
        x: f32,
        y: f32,
        content: []const u8,
        fill: []const u8,
        font_size: u32,
        anchor: TextAnchor,
        deg: f32,
        ox: f32,
        oy: f32,
    ) !void {
        const anchor_str: []const u8 = switch (anchor) {
            .start => "start",
            .middle => "middle",
            .end => "end",
        };
        try self.buf.print(self.allocator, "<text x=\"{d:.1}\" y=\"{d:.1}\"", .{ x, y });
        try self.attrEsc("fill", fill);
        try self.buf.print(self.allocator, " font-size=\"{d}\" text-anchor=\"{s}\"", .{ font_size, anchor_str });
        try self.attrEsc("font-family", theme.font_family);
        try self.buf.print(self.allocator, " transform=\"rotate({d:.1} {d:.1} {d:.1})\">", .{ deg, ox, oy });
        try xmlEscape(&self.buf, self.allocator, content);
        try self.buf.appendSlice(self.allocator, "</text>\n");
    }

    /// Emit an `<ellipse>` element centred at (`cx`, `cy`).
    pub fn ellipse(
        self: *SvgWriter,
        cx: f32,
        cy: f32,
        rx: f32,
        ry: f32,
        fill: []const u8,
        stroke: []const u8,
        stroke_width: f32,
    ) !void {
        try self.buf.print(self.allocator,
            "<ellipse cx=\"{d:.1}\" cy=\"{d:.1}\" rx=\"{d:.1}\" ry=\"{d:.1}\"",
            .{ cx, cy, rx, ry },
        );
        try self.attrEsc("fill", fill);
        try self.attrEsc("stroke", stroke);
        try self.buf.print(self.allocator, " stroke-width=\"{d:.1}\"/>\n", .{stroke_width});
    }

    /// Open an `<a>` hyperlink around subsequent elements.  The URL is
    /// scheme-validated (only `http`/`https`/`mailto` and scheme-less relative
    /// URLs are allowed; `javascript:`/`data:`/`vbscript:` and other schemes are
    /// rejected) and XML-escaped.  Returns `true` if the anchor was emitted — in
    /// which case the caller MUST later call `closeAnchor` — or `false` if the
    /// URL was rejected, in which case no anchor was written.
    pub fn openAnchor(self: *SvgWriter, url: []const u8) !bool {
        if (!isSafeUrl(url)) return false;
        try self.buf.appendSlice(self.allocator, "<a href=\"");
        try xmlEscape(&self.buf, self.allocator, url);
        try self.buf.appendSlice(self.allocator, "\" target=\"_blank\" rel=\"noopener noreferrer\">");
        return true;
    }

    /// Close an `<a>` hyperlink previously opened with `openAnchor`.
    pub fn closeAnchor(self: *SvgWriter) !void {
        try self.buf.appendSlice(self.allocator, "</a>\n");
    }

    /// Append a raw SVG fragment verbatim.  Use sparingly: no escaping or
    /// validation is applied.  Only pass renderer-controlled (non-user) markup.
    pub fn raw(self: *SvgWriter, fragment: []const u8) !void {
        try self.buf.appendSlice(self.allocator, fragment);
    }
};

/// Return true if `url` is safe to place in an `href` attribute: a scheme-less
/// (relative/anchor) URL, or one whose scheme is `http`, `https`, or `mailto`.
/// ASCII whitespace and control bytes are ignored while parsing the scheme,
/// matching how browsers normalise URLs (so `java\tscript:` is still caught).
pub fn isSafeUrl(url: []const u8) bool {
    var scheme_buf: [16]u8 = undefined;
    var n: usize = 0;
    var seen_scheme_char = false;
    for (url) |c| {
        if (c <= 0x20) continue; // whitespace/control: browsers strip these
        switch (c) {
            ':' => {
                if (!seen_scheme_char) return true; // leading ':' — not a scheme
                if (n > scheme_buf.len) return false; // scheme too long to be allowlisted
                const scheme = scheme_buf[0..n];
                return std.mem.eql(u8, scheme, "http") or
                    std.mem.eql(u8, scheme, "https") or
                    std.mem.eql(u8, scheme, "mailto");
            },
            '/', '?', '#' => return true, // path/query/fragment first → relative
            'a'...'z', '0'...'9', '+', '.', '-' => {
                if (n < scheme_buf.len) scheme_buf[n] = c;
                n += 1;
                seen_scheme_char = true;
            },
            'A'...'Z' => {
                if (n < scheme_buf.len) scheme_buf[n] = c + 32; // to lowercase
                n += 1;
                seen_scheme_char = true;
            },
            else => return true, // any other char before ':' → not a scheme
        }
    }
    return true; // no ':' → relative URL
}

/// Write `s` to `buf` with XML special characters replaced by their
/// entity equivalents (`&amp;`, `&lt;`, `&gt;`, `&quot;`, `&#39;`).
pub fn xmlEscape(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try buf.appendSlice(allocator, "&amp;"),
            '<' => try buf.appendSlice(allocator, "&lt;"),
            '>' => try buf.appendSlice(allocator, "&gt;"),
            '"' => try buf.appendSlice(allocator, "&quot;"),
            '\'' => try buf.appendSlice(allocator, "&#39;"),
            else => try buf.append(allocator, c),
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "SvgWriter header emits svg element with correct dimensions" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.header(800, 600);
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "width=\"800\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "height=\"600\"") != null);
}

test "SvgWriter header viewBox matches width and height" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.header(400, 300);
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "viewBox=\"0 0 400 300\"") != null);
}

test "SvgWriter footer emits closing svg tag" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.footer();
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "</svg>") != null);
}

test "SvgWriter header+footer produces valid envelope" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.header(100, 100);
    try w.footer();
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<svg") != null);
    try testing.expect(std.mem.indexOf(u8, out, "</svg>") != null);
}

test "SvgWriter rect emits rect element with all attributes" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.rect(10, 20, 100, 50, 4.0, "#fff", "#000", 1.5);
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<rect") != null);
    try testing.expect(std.mem.indexOf(u8, out, "fill=\"#fff\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "stroke=\"#000\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "rx=\"4.00\"") != null);
}

test "SvgWriter rect with rx=0 for sharp corners" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.rect(0, 0, 50, 30, 0.0, "#fff", "#000", 1.0);
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "rx=\"0.00\"") != null);
}

test "SvgWriter circle emits circle element" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.circle(50, 60, 20, "#blue", "#red", 2.0);
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<circle") != null);
    try testing.expect(std.mem.indexOf(u8, out, "cx=\"50.00\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "r=\"20.00\"") != null);
}

test "SvgWriter line emits line element" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.line(0, 0, 100, 100, "#333", 1.0);
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<line") != null);
    try testing.expect(std.mem.indexOf(u8, out, "x1=\"0.00\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "x2=\"100.00\"") != null);
}

test "SvgWriter dashedLine emits stroke-dasharray attribute" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.dashedLine(0, 0, 50, 50, "#333", 1.0, "5,3");
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "stroke-dasharray=\"5,3\"") != null);
}

test "SvgWriter path without extra_attrs" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.path("M 0 0 L 100 100", "none", "#333", 1.5, "");
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<path") != null);
    try testing.expect(std.mem.indexOf(u8, out, "M 0 0 L 100 100") != null);
    try testing.expect(std.mem.indexOf(u8, out, "stroke=\"#333\"") != null);
}

test "SvgWriter path with extra_attrs appended" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.path("M 0 0", "none", "#000", 1.0, "stroke-dasharray=\"4,4\"");
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "stroke-dasharray=\"4,4\"") != null);
}

test "SvgWriter polygon emits polygon element" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.polygon("0,0 10,5 0,10", "#fff", "#000", 1.0);
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<polygon") != null);
    try testing.expect(std.mem.indexOf(u8, out, "points=\"0,0 10,5 0,10\"") != null);
}

test "SvgWriter text anchor=start" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.text(10, 20, "Hi", "#000", 14, .start, "normal");
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "text-anchor=\"start\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">Hi<") != null);
}

test "SvgWriter text anchor=middle" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.text(50, 50, "Mid", "#000", 14, .middle, "normal");
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "text-anchor=\"middle\"") != null);
}

test "SvgWriter text anchor=end" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.text(90, 20, "End", "#000", 14, .end, "normal");
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "text-anchor=\"end\"") != null);
}

test "SvgWriter text XML-escapes ampersand" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.text(0, 0, "A & B", "#000", 12, .start, "normal");
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "&amp;") != null);
}

test "SvgWriter text XML-escapes less-than" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.text(0, 0, "a<b", "#000", 12, .start, "normal");
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "&lt;") != null);
}

test "SvgWriter text XML-escapes greater-than" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.text(0, 0, "a>b", "#000", 12, .start, "normal");
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "&gt;") != null);
}

test "SvgWriter text XML-escapes double-quote" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.text(0, 0, "say \"hi\"", "#000", 12, .start, "normal");
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "&quot;") != null);
}

test "SvgWriter text XML-escapes apostrophe" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.text(0, 0, "it's", "#000", 12, .start, "normal");
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "&#39;") != null);
}

test "SvgWriter openGroup with empty attrs emits bare g tag" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.openGroup("");
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<g>") != null);
}

test "SvgWriter openGroup with attrs includes attribute string" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.openGroup("opacity=\"0.5\"");
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "opacity=\"0.5\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<g ") != null);
}

test "SvgWriter closeGroup emits closing g tag" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.closeGroup();
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "</g>") != null);
}

test "SvgWriter defs wraps content" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.defs("<marker id=\"m\"/>\n");
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<defs>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "</defs>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<marker id=\"m\"/>") != null);
}

test "SvgWriter raw appends fragment verbatim" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.raw("<custom-element/>");
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<custom-element/>") != null);
}

test "SvgWriter textWrapped short content single-line" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    // 14px font, max_w=500 => chars_per_line ~= 64. "Hi" is well under.
    try w.textWrapped(100, 50, "Hi", 500, "#000", 14, .middle, "normal");
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    // Short content delegates to text(), which emits a plain <text> without <tspan>
    try testing.expect(std.mem.indexOf(u8, out, "<text") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<tspan") == null);
}

test "SvgWriter textWrapped long content emits tspan elements" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    // 14px font, max_w=50 => chars_per_line ~= 6. Use a longer string to force wrap.
    try w.textWrapped(100, 50, "Hello World Overflow", 50, "#000", 14, .middle, "normal");
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<tspan") != null);
}

test "SvgWriter rect escapes a breakout in the fill value" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.rect(0, 0, 10, 10, 0, "red\">", "#000", 1.0);
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    // The raw breakout fill="red"> must not appear; the quote/gt are escaped.
    try testing.expect(std.mem.indexOf(u8, out, "fill=\"red\">") == null);
    try testing.expect(std.mem.indexOf(u8, out, "&quot;") != null);
}

test "SvgWriter text escapes font-weight attribute value" {
    var w = SvgWriter.init(testing.allocator);
    defer w.deinit();
    try w.text(0, 0, "hi", "#000", 12, .start, "bold\"onx=\"y");
    const out = try w.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "onx=\"") == null);
}

test "isSafeUrl allows http, https, mailto, and relative URLs" {
    try testing.expect(isSafeUrl("https://example.com"));
    try testing.expect(isSafeUrl("http://example.com/path?q=1"));
    try testing.expect(isSafeUrl("HTTPS://EXAMPLE.COM"));
    try testing.expect(isSafeUrl("mailto:a@b.com"));
    try testing.expect(isSafeUrl("/relative/path"));
    try testing.expect(isSafeUrl("#anchor"));
    try testing.expect(isSafeUrl("./page.html"));
    try testing.expect(isSafeUrl("")); // empty href is harmless
}

test "isSafeUrl rejects dangerous schemes including obfuscated ones" {
    try testing.expect(!isSafeUrl("javascript:alert(1)"));
    try testing.expect(!isSafeUrl("JavaScript:alert(1)"));
    try testing.expect(!isSafeUrl("data:text/html,<script>alert(1)</script>"));
    try testing.expect(!isSafeUrl("vbscript:msgbox(1)"));
    // Whitespace/control obfuscation the browser would strip must still be caught.
    try testing.expect(!isSafeUrl("java\tscript:alert(1)"));
    try testing.expect(!isSafeUrl("  javascript:alert(1)"));
    try testing.expect(!isSafeUrl("java\nscript:alert(1)"));
}

test "xmlEscape all five special characters" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try xmlEscape(&buf, testing.allocator, "&<>\"'");
    const out = buf.items;
    try testing.expect(std.mem.indexOf(u8, out, "&amp;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "&lt;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "&quot;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "&#39;") != null);
}

pub const arrow_marker_defs =
    "  <marker id=\"arrow\" markerWidth=\"10\" markerHeight=\"7\" refX=\"10\" refY=\"3.5\" orient=\"auto\">\n" ++
    "    <polygon points=\"0 0, 10 3.5, 0 7\" fill=\"#333333\"/>\n" ++
    "  </marker>\n" ++
    "  <marker id=\"arrow-open\" markerWidth=\"10\" markerHeight=\"7\" refX=\"10\" refY=\"3.5\" orient=\"auto\">\n" ++
    "    <polyline points=\"0 0, 10 3.5, 0 7\" fill=\"none\" stroke=\"#333333\" stroke-width=\"1.5\"/>\n" ++
    "  </marker>\n";
