//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
//! Security regression suite. One test per hardening fix, so a fixed
//! vulnerability class can never silently regress:
//!   - GHSA-rg4m-w3p2-gf3p — out-of-bounds writes from oversized diagram
//!     grids (fixed-size row/column arrays in the grid renderers).
//!   - GHSA-p2c5-qmq5-3r4f — SVG/XSS injection through click hrefs,
//!     classDef/style values, and %%{init}%% themeVariables.
//!   - Resource-exhaustion guards: max_input_bytes and DiagramTooLarge.
//! All tests run under std.testing.allocator on purpose: an error-path
//! allocation leak fails the test.
const std = @import("std");

const pozeiden = @import("root.zig");
const render = pozeiden.render;
const renderWithOptions = pozeiden.renderWithOptions;
const max_input_bytes = pozeiden.max_input_bytes;

// ── Regression: grid-layout renderers must not overflow row arrays (GHSA-rg4m)
// Diagrams with more than GRID_COLS*64 = 192 elements previously indexed past
// fixed [64]/[65] arrays, aborting in safe builds and corrupting memory in the
// safety-off wasm build. Render well past that threshold and assert valid SVG.

test "security: large grid diagrams do not overflow row arrays" {
    const gpa = std.testing.allocator;

    const Gen = struct {
        fn run(a: std.mem.Allocator, header: []const u8, comptime line_fmt: []const u8) !void {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(a);
            try buf.appendSlice(a, header);
            var i: usize = 0;
            while (i < 300) : (i += 1) try buf.print(a, line_fmt, .{i});
            const svg = try render(a, buf.items);
            defer a.free(svg);
            try std.testing.expect(std.mem.indexOf(u8, svg, "<svg") != null);
            try std.testing.expect(std.mem.indexOf(u8, svg, "</svg>") != null);
        }
    };

    try Gen.run(gpa, "C4Context\n", "Person(p{0d}, \"P{0d}\")\n");
    try Gen.run(gpa, "classDiagram\n", "class C{0d}\n");
    try Gen.run(gpa, "erDiagram\n", "E{0d}\n");
}

test "security: large requirement diagram does not overflow row arrays" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "requirementDiagram\n");
    var i: usize = 0;
    while (i < 300) : (i += 1)
        try buf.print(gpa, "requirement r{d} {{\nid: {d}\ntext: t\nrisk: high\nverifymethod: test\n}}\n", .{ i, i });
    const svg = try render(gpa, buf.items);
    defer gpa.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "</svg>") != null);
}

test "security: deeply nested state diagram does not overflow col_count" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "stateDiagram-v2\n");
    var i: usize = 0;
    while (i < 200) : (i += 1) try buf.print(gpa, "state s{d} {{\n", .{i});
    try buf.appendSlice(gpa, "x\n");
    i = 0;
    while (i < 200) : (i += 1) try buf.appendSlice(gpa, "}\n");
    const svg = try render(gpa, buf.items);
    defer gpa.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "</svg>") != null);
}

// ── Security regression: SVG output injection (GHSA-p2c5) ───────────────────
// Untrusted diagram text must never break out of an attribute/element into the
// emitted SVG. Consumers embed this SVG raw in HTML, so a leak here is XSS.
// Each test renders a malicious diagram and asserts no *unescaped* payload
// survives. See src/svg/writer.zig (attrEsc / isSafeUrl / openAnchor).

test "security: click href javascript: scheme is rejected" {
    const svg = try render(std.testing.allocator, "flowchart TD\nA[x]\nclick A href \"javascript:alert(1)\"\n");
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "javascript:") == null);
}

test "security: click href attribute breakout does not inject script" {
    const svg = try render(std.testing.allocator, "flowchart TD\nA[x]\nclick A href \"x\"><script>alert(1)</script>\"\n");
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<script") == null);
}

test "security: legitimate https href still renders as a link" {
    const svg = try render(std.testing.allocator, "flowchart TD\nA[x]\nclick A href \"https://example.com\"\n");
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<a href=\"https://example.com\"") != null);
}

test "security: style fill does not break out of rect tag" {
    const svg = try render(std.testing.allocator, "flowchart TD\nA[x]\nstyle A fill:red\">\n");
    defer std.testing.allocator.free(svg);
    // The breakout form fill="red"> must not appear; the '>' must be escaped.
    try std.testing.expect(std.mem.indexOf(u8, svg, "fill=\"red\">") == null);
}

test "security: style value cannot inject an event handler attribute" {
    const svg = try render(std.testing.allocator, "flowchart TD\nA[x]\nstyle A fill:red\"onx=\"y\n");
    defer std.testing.allocator.free(svg);
    // A real handler attribute would be onx="...; the escaped form is onx=&quot;
    try std.testing.expect(std.mem.indexOf(u8, svg, "onx=\"") == null);
}

test "security: text color style cannot inject script" {
    const svg = try render(std.testing.allocator, "flowchart TD\nA[hello]\nstyle A color:red\"><script>alert(1)</script>\n");
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<script") == null);
}

test "security: init themeVariables single-quote breakout cannot inject handler" {
    const svg = try render(std.testing.allocator, "%%{init: {'themeVariables': {'primaryColor': 'red\" onload=\"alert(1)'}}}%%\nflowchart TD\nA[x]\n");
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, " onload=\"") == null);
}

test "security: quadrant y-axis label cannot inject script" {
    const svg = try render(std.testing.allocator, "quadrantChart\nx-axis Low --> High\ny-axis \"a</text><script>alert(1)</script>\" --> Hi\nCampaign A: [0.3, 0.6]\n");
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<script") == null);
}

// ── Resource limits (issue #37) ─────────────────────────────────────────────

test "render rejects input larger than max_input_bytes" {
    const big = try std.testing.allocator.alloc(u8, max_input_bytes + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'a');
    try std.testing.expectError(error.InputTooLarge, render(std.testing.allocator, big));
}

test "render accepts input at the max_input_bytes boundary" {
    // A buffer exactly at the cap must not be rejected for size (it renders
    // as an unknown-type fallback, which is fine — we only assert no error).
    const buf = try std.testing.allocator.alloc(u8, max_input_bytes);
    defer std.testing.allocator.free(buf);
    @memset(buf, 'a');
    const svg = try render(std.testing.allocator, buf);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<svg") != null);
}

test "render rejects a deeply nested mindmap with NestingTooDeep" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "mindmap\nroot((r))\n");
    // 150 levels of two-space indent (> mindmap max_nesting_depth = 100):
    // the radial layout recurses once per level, so unbounded depth is a
    // stack-exhaustion vector (especially on WASM's fixed stack).
    var depth: usize = 1;
    while (depth <= 150) : (depth += 1) {
        for (0..depth) |_| try buf.appendSlice(gpa, "  ");
        try buf.print(gpa, "n{d}\n", .{depth});
    }
    try std.testing.expectError(error.NestingTooDeep, render(gpa, buf.items));
}

test "render rejects a flowchart subgraph bomb with DiagramTooLarge" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "graph TD\n");
    // 600 nested subgraphs (> flowchart max_subgraphs = 500). Every node
    // records membership in all enclosing subgraphs, so unbounded nesting
    // lets a small input demand quadratic storage and rendering work.
    var i: usize = 0;
    while (i < 600) : (i += 1) try buf.print(gpa, "subgraph s{d}\n", .{i});
    try std.testing.expectError(error.DiagramTooLarge, render(gpa, buf.items));
}

test "renderWithOptions max_input_bytes tightens and loosens the limit" {
    const gpa = std.testing.allocator;
    const input = "graph TD\nA-->B\n";
    // Tightened per-call limit rejects input the default would accept …
    try std.testing.expectError(
        error.InputTooLarge,
        renderWithOptions(gpa, input, .{ .max_input_bytes = 4 }),
    );
    // … an explicit larger/disabled limit accepts it, and the boundary is
    // inclusive.
    const at_boundary = try renderWithOptions(gpa, input, .{ .max_input_bytes = input.len });
    defer gpa.free(at_boundary);
    try std.testing.expect(std.mem.startsWith(u8, at_boundary, "<svg"));
    const unlimited = try renderWithOptions(gpa, input, .{ .max_input_bytes = 0 });
    defer gpa.free(unlimited);
    try std.testing.expectEqualStrings(at_boundary, unlimited);
}

test "control bytes in labels are dropped from the SVG output" {
    const gpa = std.testing.allocator;
    const svg = try render(gpa, "graph TD\nA[\x01bad\x1flabel\x7f] --> B\n");
    defer gpa.free(svg);
    // XML 1.0 cannot represent bytes < 0x20 (other than \t \n \r) even as
    // character references; they must not reach the output.
    for (svg) |c| {
        try std.testing.expect(c == '\t' or c == '\n' or c == '\r' or c >= 0x20);
    }
    try std.testing.expect(std.mem.indexOf(u8, svg, "badlabel") != null);
}

test "block-beta negative or huge columns/width values are clamped" {
    const gpa = std.testing.allocator;
    // Negative / NaN / oversized floats previously flowed into
    // @intFromFloat(usize) in the renderer — UB in unchecked builds.
    const cases = [_][]const u8{
        "block-beta\ncolumns -5\nA B C\n",
        "block-beta\ncolumns nan\nA B C\n",
        "block-beta\ncolumns 1e30\nA B C\n",
        "block-beta\ncolumns 3\nA:-7 B C\n",
    };
    for (cases) |input| {
        const svg = try render(gpa, input);
        defer gpa.free(svg);
        try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    }
}

test "render rejects an oversized flowchart with DiagramTooLarge" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "graph TD\n");
    // 10_500 distinct nodes (> layout.max_nodes = 10_000), under the byte cap.
    var i: usize = 0;
    while (i < 10_500) : (i += 1) try buf.print(gpa, "n{d}\n", .{i});
    try std.testing.expectError(error.DiagramTooLarge, render(gpa, buf.items));
}

