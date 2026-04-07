//! pozeiden public API: render mermaid diagram text to an SVG string.
const std = @import("std");
const detect = @import("detect.zig");
const Value = @import("diagram/value.zig").Value;

const langium_parser = @import("langium/parser.zig");
const langium_runtime = @import("langium/runtime.zig");
const langium_ast = @import("langium/ast.zig");

const jison_parser = @import("jison/parser.zig");
const jison_runtime = @import("jison/runtime.zig");

const pie_renderer = @import("renderers/pie.zig");
const flowchart_renderer = @import("renderers/flowchart.zig");
const sequence_renderer = @import("renderers/sequence.zig");
const gitgraph_renderer = @import("renderers/gitgraph.zig");

// Embedded grammar files (compiled into the binary)
const common_langium = @embedFile("grammars/common.langium");
const pie_langium = @embedFile("grammars/pie.langium");
const git_langium = @embedFile("grammars/gitGraph.langium");
const flow_jison = @embedFile("grammars/flow.jison");
const seq_jison = @embedFile("grammars/sequenceDiagram.jison");

pub const RenderError = error{
    UnknownDiagramType,
    ParseError,
    OutOfMemory,
};

/// Render `mermaid_text` to an SVG string.
/// Caller owns the returned slice (allocated with `allocator`).
pub fn render(allocator: std.mem.Allocator, mermaid_text: []const u8) ![]const u8 {
    const diagram_type = detect.detect(mermaid_text);

    switch (diagram_type) {
        .pie => return renderLangium(allocator, mermaid_text, pie_langium, pie_renderer.render),
        .gitgraph => return renderLangium(allocator, mermaid_text, git_langium, gitgraph_renderer.render),
        .flowchart => return renderFlowchartDirect(allocator, mermaid_text),
        .sequence => return renderSequenceDirect(allocator, mermaid_text),
        .unknown => {
            // Emit a simple fallback SVG for unrecognised diagram types
            return renderUnknown(allocator, mermaid_text);
        },
    }
}

fn renderLangium(
    allocator: std.mem.Allocator,
    input: []const u8,
    grammar_src: []const u8,
    renderer: fn (std.mem.Allocator, Value) anyerror![]const u8,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Parse common.langium (provides shared terminals)
    const common_grammar = langium_parser.parse(a, common_langium) catch return error.ParseError;
    const common_grammar_heap = try a.create(langium_ast.Grammar);
    common_grammar_heap.* = common_grammar;

    // Parse the specific grammar file
    const primary_grammar = langium_parser.parse(a, grammar_src) catch return error.ParseError;
    const primary_grammar_heap = try a.create(langium_ast.Grammar);
    primary_grammar_heap.* = primary_grammar;

    // Build merged grammar (primary + common as import)
    const imports = try a.alloc(*const langium_ast.Grammar, 1);
    imports[0] = common_grammar_heap;
    const merged = langium_ast.MergedGrammar{
        .primary = primary_grammar_heap,
        .imports = imports,
        .allocator = a,
    };
    const merged_heap = try a.create(langium_ast.MergedGrammar);
    merged_heap.* = merged;

    // Run the Langium runtime to produce a Value AST
    var runtime = langium_runtime.Runtime.init(a, merged_heap) catch return error.ParseError;
    const value = runtime.run(input) catch {
        return renderer(allocator, Value{ .null = {} });
    };

    // Render to SVG; result must be allocated with the caller's allocator
    return renderer(allocator, value);
}

fn renderJison(
    allocator: std.mem.Allocator,
    input: []const u8,
    grammar_src: []const u8,
    renderer: fn (std.mem.Allocator, Value) anyerror![]const u8,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Parse the .jison grammar
    const grammar = jison_parser.parse(a, grammar_src) catch return error.ParseError;
    const grammar_heap = try a.create(@TypeOf(grammar));
    grammar_heap.* = grammar;

    // Run the Jison runtime to produce a Value AST
    var runtime = jison_runtime.Runtime.init(a, grammar_heap) catch return error.ParseError;
    const value = runtime.run(input) catch {
        return renderer(allocator, Value{ .null = {} });
    };

    return renderer(allocator, value);
}

/// Parse a flowchart/graph node spec like "A", "A[label]", "A{label}", "A((label))", "A([label])"
/// Returns (id, label, shape_str)
fn parseNodeSpec(spec: []const u8) struct { []const u8, []const u8, []const u8 } {
    const s = std.mem.trim(u8, spec, " \t\r\n");
    if (s.len == 0) return .{ "", "", "rect" };
    // Find the first delimiter
    for (s, 0..) |c, i| {
        switch (c) {
            '[' => {
                const id = s[0..i];
                // Check for stadium ([...]) or subroutine [[...]]
                if (i + 1 < s.len and s[i + 1] == '[') {
                    const end = std.mem.lastIndexOfScalar(u8, s, ']') orelse s.len - 1;
                    return .{ id, s[i + 2 .. @min(end, s.len)], "subroutine" };
                }
                if (i + 1 < s.len and s[i + 1] == '(') {
                    const end = std.mem.lastIndexOfScalar(u8, s, ')') orelse s.len - 1;
                    return .{ id, s[i + 2 .. @min(end, s.len)], "stadium" };
                }
                const end = std.mem.lastIndexOfScalar(u8, s, ']') orelse s.len - 1;
                return .{ id, s[i + 1 .. @min(end, s.len)], "rect" };
            },
            '(' => {
                const id = s[0..i];
                // Circle: ((label))
                if (i + 1 < s.len and s[i + 1] == '(') {
                    const end = std.mem.lastIndexOfScalar(u8, s, ')') orelse s.len - 1;
                    return .{ id, s[i + 2 .. @min(end, s.len)], "circle" };
                }
                const end = std.mem.lastIndexOfScalar(u8, s, ')') orelse s.len - 1;
                return .{ id, s[i + 1 .. @min(end, s.len)], "round" };
            },
            '{' => {
                const id = s[0..i];
                const end = std.mem.lastIndexOfScalar(u8, s, '}') orelse s.len - 1;
                return .{ id, s[i + 1 .. @min(end, s.len)], "diamond" };
            },
            else => {},
        }
    }
    return .{ s, s, "rect" };
}

/// Find an edge arrow in the line. Returns the split position or null.
/// Handles: -->, --->, -.->  ==>, --
fn findEdgeArrow(line: []const u8) ?struct { usize, usize, []const u8 } {
    // Order matters: try longer patterns first
    const patterns = [_]struct { []const u8, []const u8 }{
        .{ "-.->", "dotted" },
        .{ "-.-", "dotted" },
        .{ "==>", "thick" },
        .{ "==", "thick" },
        .{ "--->", "solid" },
        .{ "-->", "solid" },
        .{ "---", "solid" },
        .{ "->", "solid" },
    };
    for (patterns) |p| {
        if (std.mem.indexOf(u8, line, p[0])) |pos| {
            return .{ pos, pos + p[0].len, p[1] };
        }
    }
    return null;
}

fn renderFlowchartDirect(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes_list: std.ArrayList(Value) = .empty;
    var edges_list: std.ArrayList(Value) = .empty;
    var seen_nodes = std.StringHashMap(void).init(a);
    var direction: []const u8 = "TB";

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        // Skip comments
        if (std.mem.startsWith(u8, line, "%%")) continue;

        if (first) {
            first = false;
            // Parse direction from header: "graph TD" or "flowchart LR"
            if (std.mem.indexOf(u8, line, " ")) |sp| {
                direction = std.mem.trim(u8, line[sp..], " \t");
            }
            continue;
        }

        // Try to find an edge arrow
        if (findEdgeArrow(line)) |arrow| {
            const from_part = std.mem.trim(u8, line[0..arrow[0]], " \t");
            var to_part = std.mem.trim(u8, line[arrow[1]..], " \t");

            // Edge label: |label| between arrow and destination
            var edge_label: ?[]const u8 = null;
            if (to_part.len > 0 and to_part[0] == '|') {
                const label_end = std.mem.indexOfScalar(u8, to_part[1..], '|') orelse 0;
                edge_label = to_part[1 .. 1 + label_end];
                to_part = std.mem.trim(u8, to_part[2 + label_end ..], " \t");
            }

            const from_id, const from_label, const from_shape = parseNodeSpec(from_part);
            const to_id, const to_label, const to_shape = parseNodeSpec(to_part);

            if (from_id.len == 0 or to_id.len == 0) continue;

            // Add nodes if not seen
            if (seen_nodes.get(from_id) == null) {
                try seen_nodes.put(from_id, {});
                var n = Value.Node{ .type_name = "node", .fields = .{} };
                try n.fields.put(a, "id", Value{ .string = from_id });
                try n.fields.put(a, "label", Value{ .string = from_label });
                try n.fields.put(a, "shape", Value{ .string = from_shape });
                try nodes_list.append(a, Value{ .node = n });
            }
            if (seen_nodes.get(to_id) == null) {
                try seen_nodes.put(to_id, {});
                var n = Value.Node{ .type_name = "node", .fields = .{} };
                try n.fields.put(a, "id", Value{ .string = to_id });
                try n.fields.put(a, "label", Value{ .string = to_label });
                try n.fields.put(a, "shape", Value{ .string = to_shape });
                try nodes_list.append(a, Value{ .node = n });
            }

            // Add edge
            var e = Value.Node{ .type_name = "edge", .fields = .{} };
            try e.fields.put(a, "from", Value{ .string = from_id });
            try e.fields.put(a, "to", Value{ .string = to_id });
            try e.fields.put(a, "style", Value{ .string = arrow[2] });
            if (edge_label) |lbl| {
                try e.fields.put(a, "label", Value{ .string = lbl });
            }
            try edges_list.append(a, Value{ .node = e });
        } else if (line.len > 0 and !std.mem.startsWith(u8, line, "subgraph") and !std.mem.eql(u8, line, "end")) {
            // Standalone node definition
            const node_id, const node_label, const node_shape = parseNodeSpec(line);
            if (node_id.len > 0 and seen_nodes.get(node_id) == null) {
                try seen_nodes.put(node_id, {});
                var n = Value.Node{ .type_name = "node", .fields = .{} };
                try n.fields.put(a, "id", Value{ .string = node_id });
                try n.fields.put(a, "label", Value{ .string = node_label });
                try n.fields.put(a, "shape", Value{ .string = node_shape });
                try nodes_list.append(a, Value{ .node = n });
            }
        }
    }

    var root = Value.Node{ .type_name = "flowchart", .fields = .{} };
    try root.fields.put(a, "direction", Value{ .string = direction });
    try root.fields.put(a, "nodes", Value{ .list = try nodes_list.toOwnedSlice(a) });
    try root.fields.put(a, "edges", Value{ .list = try edges_list.toOwnedSlice(a) });

    return flowchart_renderer.render(allocator, Value{ .node = root });
}

fn renderSequenceDirect(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var participants_list: std.ArrayList(Value) = .empty;
    var signals_list: std.ArrayList(Value) = .empty;
    var seen_actors = std.StringHashMap(void).init(a);

    // Arrow type detection helpers
    // signalType: "0"=solid-filled, "1"=dotted-filled, "2"=solid-open, "3"=dotted-open
    const ArrowDef = struct { []const u8, []const u8, []const u8 }; // needle, signalType, arrowType
    const arrow_types = [_]ArrowDef{
        .{ "-->x", "3", "CROSS" },
        .{ "->>", "0", "filled" },
        .{ "-->>", "1", "filled" },
        .{ "->x", "2", "CROSS" },
        .{ "->>", "0", "filled" },
        .{ "-->", "3", "OPEN" },  // dotted open
        .{ "->", "2", "OPEN" },   // solid open
    };
    _ = arrow_types; // will use inline below

    const BlockFrame = struct { kind: []const u8, label: []const u8, start: usize };
    var block_stack: std.ArrayList(BlockFrame) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "%%")) continue;

        if (first) { first = false; continue; } // skip "sequenceDiagram"

        // participant/actor declaration
        if (std.mem.startsWith(u8, line, "participant ") or std.mem.startsWith(u8, line, "actor ")) {
            const rest = if (std.mem.startsWith(u8, line, "participant "))
                line[12..] else line[6..];
            // Handle "Name as Alias"
            const name = if (std.mem.indexOf(u8, rest, " as ")) |ai|
                std.mem.trim(u8, rest[0..ai], " \t")
            else
                std.mem.trim(u8, rest, " \t");
            if (seen_actors.get(name) == null) {
                try seen_actors.put(name, {});
                try participants_list.append(a, Value{ .string = name });
            }
            continue;
        }

        // loop / alt / opt / par blocks
        if (std.mem.startsWith(u8, line, "loop ") or std.mem.eql(u8, line, "loop")) {
            const lbl = if (line.len > 5) line[5..] else "";
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "loopStart" });
            try sig.fields.put(a, "loopText", Value{ .string = lbl });
            try signals_list.append(a, Value{ .node = sig });
            try block_stack.append(a, .{ .kind = "loop", .label = lbl, .start = signals_list.items.len - 1 });
            continue;
        }
        if (std.mem.startsWith(u8, line, "alt ") or std.mem.eql(u8, line, "alt")) {
            const lbl = if (line.len > 4) line[4..] else "";
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "altStart" });
            try sig.fields.put(a, "altText", Value{ .string = lbl });
            try signals_list.append(a, Value{ .node = sig });
            try block_stack.append(a, .{ .kind = "alt", .label = lbl, .start = signals_list.items.len - 1 });
            continue;
        }
        if (std.mem.eql(u8, line, "end")) {
            if (block_stack.items.len > 0) {
                const top = block_stack.pop().?;
                const end_type = if (std.mem.eql(u8, top.kind, "loop")) "loopEnd" else "altEnd";
                var sig = Value.Node{ .type_name = "signal", .fields = .{} };
                try sig.fields.put(a, "type", Value{ .string = end_type });
                try signals_list.append(a, Value{ .node = sig });
            }
            continue;
        }

        // Message arrows: Actor->>Actor: text or Actor-->>Actor: text etc.
        // Try to find an arrow pattern
        const arrow_patterns = [_]struct { []const u8, []const u8 }{
            .{ "-->x", "3" }, .{ "-->>", "1" }, .{ "->>", "0" },
            .{ "-->", "3" }, .{ "->x", "2" }, .{ "->", "2" },
        };
        var found_arrow = false;
        for (arrow_patterns) |ap| {
            if (std.mem.indexOf(u8, line, ap[0])) |arrow_pos| {
                const from_raw = std.mem.trim(u8, line[0..arrow_pos], " \t");
                const after_arrow = line[arrow_pos + ap[0].len..];
                // Split on ":"
                const colon_pos = std.mem.indexOfScalar(u8, after_arrow, ':') orelse after_arrow.len;
                const to_raw = std.mem.trim(u8, after_arrow[0..colon_pos], " \t");
                const msg = if (colon_pos < after_arrow.len)
                    std.mem.trim(u8, after_arrow[colon_pos + 1..], " \t")
                else "";

                // Register actors
                for (&[_][]const u8{ from_raw, to_raw }) |actor| {
                    if (actor.len > 0 and seen_actors.get(actor) == null) {
                        try seen_actors.put(actor, {});
                        try participants_list.append(a, Value{ .string = actor });
                    }
                }

                var sig = Value.Node{ .type_name = "signal", .fields = .{} };
                try sig.fields.put(a, "type", Value{ .string = "addMessage" });
                try sig.fields.put(a, "from", Value{ .string = from_raw });
                try sig.fields.put(a, "to", Value{ .string = to_raw });
                try sig.fields.put(a, "msg", Value{ .string = msg });
                try sig.fields.put(a, "signalType", Value{ .string = ap[1] });
                try signals_list.append(a, Value{ .node = sig });
                found_arrow = true;
                break;
            }
        }
    }

    var root = Value.Node{ .type_name = "sequenceDiagram", .fields = .{} };
    try root.fields.put(a, "participants", Value{ .list = try participants_list.toOwnedSlice(a) });
    try root.fields.put(a, "signals", Value{ .list = try signals_list.toOwnedSlice(a) });

    return sequence_renderer.render(allocator, Value{ .node = root });
}

fn renderUnknown(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const writer_mod = @import("svg/writer.zig");
    const theme = @import("svg/theme.zig");
    var svg = writer_mod.SvgWriter.init(allocator);
    defer svg.deinit();
    try svg.header(400, 120);
    const preview = if (text.len > 40) text[0..40] else text;
    try svg.text(200, 60, preview, theme.text_color, theme.font_size, .middle, "normal");
    try svg.footer();
    return svg.toOwnedSlice();
}

test "detect and render pie" {
    const input = "pie\n\"Dogs\" : 50\n\"Cats\" : 50\n";
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "<path") != null);
}

test "detect and render flowchart" {
    const input = "graph TD\nA-->B\nB-->C\n";
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
}

test "detect and render sequence" {
    const input = "sequenceDiagram\nAlice->>Bob: hi\nBob-->>Alice: hello\n";
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "Alice") != null);
}

test "detect and render gitgraph" {
    const input = "gitGraph\ncommit\nbranch dev\ncheckout dev\ncommit\n";
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "<circle") != null);
}
