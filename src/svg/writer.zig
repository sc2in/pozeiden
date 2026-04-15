//! Low-level SVG string builder used by all renderers.
//!
//! `SvgWriter` accumulates SVG markup in an internal `ArrayList(u8)`.
//! Callers write elements via typed methods (`rect`, `circle`, `text`, etc.),
//! then call `toOwnedSlice` to obtain the final string.  Text content is
//! automatically XML-escaped; attribute values must be safe before being
//! passed in.
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
        return .{ .buf = .empty, .allocator = allocator };
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

    /// Emit the SVG root element opening tag with explicit `width`/`height`
    /// and a matching `viewBox`.
    pub fn header(self: *SvgWriter, width: u32, height: u32) !void {
        try self.buf.writer(self.allocator).print(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 {d} {d}\">\n",
            .{ width, height, width, height },
        );
    }

    /// Emit the SVG root element closing tag.
    pub fn footer(self: *SvgWriter) !void {
        try self.buf.writer(self.allocator).writeAll("</svg>\n");
    }

    /// Open a `<g>` group element.  Pass `attrs` for additional SVG attributes
    /// (e.g. `"opacity=\"0.5\""`), or an empty string for a plain `<g>`.
    pub fn openGroup(self: *SvgWriter, attrs: []const u8) !void {
        if (attrs.len > 0) {
            try self.buf.writer(self.allocator).print("<g {s}>\n", .{attrs});
        } else {
            try self.buf.writer(self.allocator).writeAll("<g>\n");
        }
    }

    /// Close the current `<g>` group element.
    pub fn closeGroup(self: *SvgWriter) !void {
        try self.buf.writer(self.allocator).writeAll("</g>\n");
    }

    /// Emit a `<defs>` block containing the raw `content` string.
    /// Used for marker, gradient, and filter definitions.
    pub fn defs(self: *SvgWriter, content: []const u8) !void {
        try self.buf.writer(self.allocator).print("<defs>\n{s}</defs>\n", .{content});
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
        try self.buf.writer(self.allocator).print(
            "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" rx=\"{d:.2}\" fill=\"{s}\" stroke=\"{s}\" stroke-width=\"{d:.1}\"/>\n",
            .{ x, y, width, height, rx, fill, stroke, stroke_width },
        );
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
        try self.buf.writer(self.allocator).print(
            "<circle cx=\"{d:.2}\" cy=\"{d:.2}\" r=\"{d:.2}\" fill=\"{s}\" stroke=\"{s}\" stroke-width=\"{d:.1}\"/>\n",
            .{ cx, cy, r, fill, stroke, stroke_width },
        );
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
        try self.buf.writer(self.allocator).print(
            "<line x1=\"{d:.2}\" y1=\"{d:.2}\" x2=\"{d:.2}\" y2=\"{d:.2}\" stroke=\"{s}\" stroke-width=\"{d:.1}\"/>\n",
            .{ x1, y1, x2, y2, stroke, stroke_width },
        );
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
        if (extra_attrs.len > 0) {
            try self.buf.writer(self.allocator).print(
                "<path d=\"{s}\" fill=\"{s}\" stroke=\"{s}\" stroke-width=\"{d:.1}\" {s}/>\n",
                .{ d, fill, stroke, stroke_width, extra_attrs },
            );
        } else {
            try self.buf.writer(self.allocator).print(
                "<path d=\"{s}\" fill=\"{s}\" stroke=\"{s}\" stroke-width=\"{d:.1}\"/>\n",
                .{ d, fill, stroke, stroke_width },
            );
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
        try self.buf.writer(self.allocator).print(
            "<text x=\"{d:.2}\" y=\"{d:.2}\" fill=\"{s}\" font-size=\"{d}\" text-anchor=\"{s}\" font-weight=\"{s}\" font-family=\"{s}\">",
            .{ x, y, fill, font_size, anchor_str, font_weight, theme.font_family },
        );
        try xmlEscape(self.buf.writer(self.allocator), content);
        try self.buf.writer(self.allocator).writeAll("</text>\n");
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
        try self.buf.writer(self.allocator).print(
            "<polygon points=\"{s}\" fill=\"{s}\" stroke=\"{s}\" stroke-width=\"{d:.1}\"/>\n",
            .{ points, fill, stroke, stroke_width },
        );
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
        try self.buf.writer(self.allocator).print(
            "<line x1=\"{d:.2}\" y1=\"{d:.2}\" x2=\"{d:.2}\" y2=\"{d:.2}\" stroke=\"{s}\" stroke-width=\"{d:.1}\" stroke-dasharray=\"{s}\"/>\n",
            .{ x1, y1, x2, y2, stroke, stroke_width, dasharray },
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
        const w = self.buf.writer(self.allocator);
        try w.print(
            "<text fill=\"{s}\" font-size=\"{d}\" text-anchor=\"{s}\" font-weight=\"{s}\" font-family=\"{s}\">",
            .{ fill, font_size, anchor_str, font_weight, theme.font_family },
        );
        try w.print("<tspan x=\"{d:.2}\" y=\"{d:.2}\">", .{ x, y1 });
        try xmlEscape(w, line1);
        try w.writeAll("</tspan>");
        try w.print("<tspan x=\"{d:.2}\" y=\"{d:.2}\">", .{ x, y2 });
        try xmlEscape(w, line2);
        try w.writeAll("</tspan></text>\n");
    }

    /// Append a raw SVG fragment verbatim.  Use sparingly: no escaping or
    /// validation is applied.  Useful for SVG features (e.g. rotated text)
    /// that do not have a dedicated method.
    pub fn raw(self: *SvgWriter, fragment: []const u8) !void {
        try self.buf.writer(self.allocator).writeAll(fragment);
    }
};

/// Write `s` to `writer` with XML special characters replaced by their
/// entity equivalents (`&amp;`, `&lt;`, `&gt;`, `&quot;`, `&#39;`).
pub fn xmlEscape(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#39;"),
            else => try writer.writeByte(c),
        }
    }
}

pub const arrow_marker_defs =
    "  <marker id=\"arrow\" markerWidth=\"10\" markerHeight=\"7\" refX=\"10\" refY=\"3.5\" orient=\"auto\">\n" ++
    "    <polygon points=\"0 0, 10 3.5, 0 7\" fill=\"#333333\"/>\n" ++
    "  </marker>\n" ++
    "  <marker id=\"arrow-open\" markerWidth=\"10\" markerHeight=\"7\" refX=\"10\" refY=\"3.5\" orient=\"auto\">\n" ++
    "    <polyline points=\"0 0, 10 3.5, 0 7\" fill=\"none\" stroke=\"#333333\" stroke-width=\"1.5\"/>\n" ++
    "  </marker>\n";
