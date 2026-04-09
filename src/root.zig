//! pozeiden: mermaid diagram renderer.
//!
//! The single public entry point is `render`, which accepts any mermaid diagram
//! text and returns a self-contained SVG string.  Seventeen diagram types are
//! supported; see `detect.DiagramType` for the full list.
//!
//! All internal work uses a short-lived `ArenaAllocator` that is freed before
//! `render` returns.  The returned SVG slice is allocated with the caller's
//! `allocator` and must be freed by the caller.
const std = @import("std");
const detect = @import("detect.zig");
const Value = @import("diagram/value.zig").Value;
const theme = @import("svg/theme.zig");

const langium_parser = @import("langium/parser.zig");
const langium_runtime = @import("langium/runtime.zig");
const langium_ast = @import("langium/ast.zig");

const jison_parser = @import("jison/parser.zig");
const jison_runtime = @import("jison/runtime.zig");

const pie_renderer = @import("renderers/pie.zig");
const flowchart_renderer = @import("renderers/flowchart.zig");
const sequence_renderer = @import("renderers/sequence.zig");
const gitgraph_renderer = @import("renderers/gitgraph.zig");
const class_renderer = @import("renderers/class.zig");
const state_renderer = @import("renderers/state.zig");
const er_renderer = @import("renderers/er.zig");
const gantt_renderer = @import("renderers/gantt.zig");
const timeline_renderer = @import("renderers/timeline.zig");
const xychart_renderer = @import("renderers/xychart.zig");
const quadrant_renderer = @import("renderers/quadrant.zig");
const mindmap_renderer = @import("renderers/mindmap.zig");
const sankey_renderer = @import("renderers/sankey.zig");
const c4_renderer = @import("renderers/c4.zig");
const block_renderer = @import("renderers/block.zig");
const requirement_renderer = @import("renderers/requirement.zig");
const kanban_renderer = @import("renderers/kanban.zig");

// Embedded grammar files (compiled into the binary)
const common_langium = @embedFile("grammars/common.langium");
const pie_langium = @embedFile("grammars/pie.langium");
const git_langium = @embedFile("grammars/gitGraph.langium");
const flow_jison = @embedFile("grammars/flow.jison");
const seq_jison = @embedFile("grammars/sequenceDiagram.jison");

/// Errors that `render` can return in addition to `std.mem.Allocator.Error`.
pub const RenderError = error{
    /// The diagram type could not be identified from the first non-blank line.
    UnknownDiagramType,
    /// A grammar file embedded in the binary failed to parse (should not occur
    /// with an unmodified build).
    ParseError,
    /// Memory allocation failed.
    OutOfMemory,
};

/// Render `mermaid_text` to a self-contained SVG string.
///
/// The diagram type is detected automatically from the first non-blank,
/// non-comment line.  Fourteen diagram types are supported; unrecognised
/// input produces a minimal fallback SVG rather than an error.
///
/// The caller owns the returned slice and must free it with `allocator`.
pub fn render(allocator: std.mem.Allocator, mermaid_text: []const u8) ![]const u8 {
    const diagram_type = detect.detect(mermaid_text);

    switch (diagram_type) {
        .pie => return renderLangium(allocator, mermaid_text, pie_langium, pie_renderer.render),
        .gitgraph => return renderLangium(allocator, mermaid_text, git_langium, gitgraph_renderer.render),
        .flowchart => return renderFlowchartDirect(allocator, mermaid_text),
        .sequence => return renderSequenceDirect(allocator, mermaid_text),
        .class => return renderClassDirect(allocator, mermaid_text),
        .state => return renderStateDirect(allocator, mermaid_text),
        .er => return renderErDirect(allocator, mermaid_text),
        .gantt => return renderGanttDirect(allocator, mermaid_text),
        .timeline => return renderTimelineDirect(allocator, mermaid_text),
        .xychart => return renderXyChartDirect(allocator, mermaid_text),
        .quadrant => return renderQuadrantDirect(allocator, mermaid_text),
        .mindmap => return renderMindmapDirect(allocator, mermaid_text),
        .sankey => return renderSankeyDirect(allocator, mermaid_text),
        .c4 => return renderC4Direct(allocator, mermaid_text),
        .block => return renderBlockDirect(allocator, mermaid_text),
        .requirement => return renderRequirementDirect(allocator, mermaid_text),
        .kanban => return renderKanbanDirect(allocator, mermaid_text),
        .unknown => {
            // Emit a simple fallback SVG for unrecognised diagram types
            return renderUnknown(allocator, mermaid_text);
        },
    }
}

/// Options for `renderWithOptions`.
pub const RenderOptions = struct {
    /// Runtime theme overrides.  Unset fields use the mermaid default values.
    theme_override: theme.ThemeOverride = .{},
};

/// Like `render`, but accepts a `RenderOptions` to customise the output.
/// Theme overrides are applied for the duration of the call and reset
/// automatically when it returns (including on error).
pub fn renderWithOptions(
    allocator: std.mem.Allocator,
    mermaid_text: []const u8,
    options: RenderOptions,
) ![]const u8 {
    theme.applyOverride(options.theme_override);
    defer theme.resetToDefaults();
    return render(allocator, mermaid_text);
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
// ─── block-beta parser ────────────────────────────────────────────────────────

fn renderBlockDirect(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var blocks_list: std.ArrayList(Value) = .empty;
    var edges_list: std.ArrayList(Value) = .empty;
    var n_cols: f64 = 3.0;
    var seen_ids = std.StringHashMap(void).init(a);
    var space_counter: usize = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (first) { first = false; continue; } // skip "block-beta"

        // columns N
        if (std.mem.startsWith(u8, line, "columns ")) {
            n_cols = std.fmt.parseFloat(f64, std.mem.trim(u8, line[8..], " \t")) catch 3.0;
            continue;
        }

        // Edge: "id --> id" or "id --> id : label"
        if (std.mem.indexOf(u8, line, "-->")) |arrow_pos| {
            const from_raw = std.mem.trim(u8, line[0..arrow_pos], " \t");
            const after = std.mem.trim(u8, line[arrow_pos + 3..], " \t");
            const colon = std.mem.indexOf(u8, after, ":") orelse after.len;
            const to_raw = std.mem.trim(u8, after[0..colon], " \t");
            const lbl = if (colon < after.len) std.mem.trim(u8, after[colon + 1..], " \t") else "";
            // Auto-register bare ids as blocks
            for (&[_][]const u8{ from_raw, to_raw }) |bid| {
                if (bid.len > 0 and seen_ids.get(bid) == null) {
                    try seen_ids.put(bid, {});
                    var bn = Value.Node{ .type_name = "block", .fields = .{} };
                    try bn.fields.put(a, "id", Value{ .string = bid });
                    try bn.fields.put(a, "label", Value{ .string = bid });
                    try blocks_list.append(a, Value{ .node = bn });
                }
            }
            var en = Value.Node{ .type_name = "edge", .fields = .{} };
            try en.fields.put(a, "from", Value{ .string = from_raw });
            try en.fields.put(a, "to", Value{ .string = to_raw });
            if (lbl.len > 0) try en.fields.put(a, "label", Value{ .string = lbl });
            try edges_list.append(a, Value{ .node = en });
            continue;
        }

        // Block definition: id or id["label"] or id["label"]:N (width)
        // Multiple blocks per line; respect quoted labels with spaces.
        var pos: usize = 0;
        while (pos < line.len) {
            // Skip leading whitespace
            while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
            if (pos >= line.len) break;
            // Read id: up to '[' or space
            const id_start = pos;
            while (pos < line.len and line[pos] != '[' and line[pos] != ' ' and line[pos] != '\t') pos += 1;
            const raw_id = line[id_start..pos];
            if (raw_id.len == 0) { pos += 1; continue; }
            // Handle bare id:N width suffix (e.g. "space:2")
            var id = raw_id;
            var width_str: []const u8 = "";
            if (std.mem.indexOfScalar(u8, raw_id, ':')) |colon| {
                id = raw_id[0..colon];
                width_str = raw_id[colon + 1..];
            }
            // Check for ["label"] after id
            var lbl = id;
            if (pos < line.len and line[pos] == '[') {
                // Find matching ]
                const bracket_start = pos;
                pos += 1; // skip [
                // May have "label" inside
                if (pos < line.len and line[pos] == '"') {
                    pos += 1; // skip "
                    const lbl_start = pos;
                    while (pos < line.len and line[pos] != '"') pos += 1;
                    lbl = line[lbl_start..pos];
                    if (pos < line.len) pos += 1; // skip closing "
                }
                if (pos < line.len and line[pos] == ']') pos += 1; // skip ]
                _ = bracket_start;
                // Width: ]:N after the bracket
                if (pos < line.len and line[pos] == ':') {
                    pos += 1;
                    const w_start = pos;
                    while (pos < line.len and line[pos] != ' ' and line[pos] != '\t') pos += 1;
                    width_str = line[w_start..pos];
                }
            }
            const is_space = std.mem.eql(u8, id, "space");
            // Give each space block a unique synthetic id so multiple spaces
            // on the same line don't get deduped by seen_ids.
            const effective_id = if (is_space) blk: {
                space_counter += 1;
                break :blk try std.fmt.allocPrint(a, "__space{d}", .{space_counter});
            } else id;
            if (!is_space and seen_ids.get(id) != null) continue;
            if (!is_space) try seen_ids.put(id, {});
            const width = std.fmt.parseFloat(f64, width_str) catch 1.0;
            var bn = Value.Node{ .type_name = "block", .fields = .{} };
            try bn.fields.put(a, "id", Value{ .string = effective_id });
            try bn.fields.put(a, "label", Value{ .string = if (is_space) "" else lbl });
            try bn.fields.put(a, "width", Value{ .number = width });
            try bn.fields.put(a, "space", Value{ .number = if (is_space) 1.0 else 0.0 });
            try blocks_list.append(a, Value{ .node = bn });
        }
    }

    var root = Value.Node{ .type_name = "block-beta", .fields = .{} };
    try root.fields.put(a, "cols", Value{ .number = n_cols });
    try root.fields.put(a, "blocks", Value{ .list = try blocks_list.toOwnedSlice(a) });
    try root.fields.put(a, "edges", Value{ .list = try edges_list.toOwnedSlice(a) });
    return block_renderer.render(allocator, Value{ .node = root });
}

// ─── requirementDiagram parser ───────────────────────────────────────────────

fn renderRequirementDirect(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var requirements: std.ArrayList(Value) = .empty;
    var elements: std.ArrayList(Value) = .empty;
    var relationships: std.ArrayList(Value) = .empty;

    var current_kind: []const u8 = ""; // "requirement" or "element"
    var current_node: ?Value.Node = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (first) { first = false; continue; } // skip "requirementDiagram"

        // End of block
        if (std.mem.eql(u8, line, "}")) {
            if (current_node) |n| {
                if (std.mem.eql(u8, current_kind, "requirement")) {
                    try requirements.append(a, Value{ .node = n });
                } else {
                    try elements.append(a, Value{ .node = n });
                }
                current_node = null;
                current_kind = "";
            }
            continue;
        }

        // Block start: "requirement name {" or "element name {"
        if (std.mem.startsWith(u8, line, "requirement ") or
            std.mem.startsWith(u8, line, "functionalRequirement ") or
            std.mem.startsWith(u8, line, "performanceRequirement ") or
            std.mem.startsWith(u8, line, "interfaceRequirement ") or
            std.mem.startsWith(u8, line, "physicalRequirement ") or
            std.mem.startsWith(u8, line, "designConstraint "))
        {
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
            const rest = std.mem.trim(u8, line[sp..], " \t{");
            current_kind = "requirement";
            current_node = Value.Node{ .type_name = "requirement", .fields = .{} };
            try current_node.?.fields.put(a, "name", Value{ .string = rest });
            continue;
        }
        if (std.mem.startsWith(u8, line, "element ")) {
            const rest = std.mem.trim(u8, line[8..], " \t{");
            current_kind = "element";
            current_node = Value.Node{ .type_name = "element", .fields = .{} };
            try current_node.?.fields.put(a, "name", Value{ .string = rest });
            continue;
        }

        // Attribute inside block: "key: value"
        if (current_node != null) {
            if (std.mem.indexOf(u8, line, ":")) |ci| {
                const key = std.mem.trim(u8, line[0..ci], " \t");
                const val = std.mem.trim(u8, line[ci + 1..], " \t\"");
                try current_node.?.fields.put(a, key, Value{ .string = val });
            }
            continue;
        }

        // Relationship: "A - kind -> B" or "A - kind - B"
        if (std.mem.indexOf(u8, line, " - ")) |d1| {
            const from = std.mem.trim(u8, line[0..d1], " \t");
            const rest = line[d1 + 3..];
            const d2 = std.mem.indexOf(u8, rest, " - ") orelse std.mem.indexOf(u8, rest, " -> ") orelse rest.len;
            if (d2 < rest.len) {
                const kind = std.mem.trim(u8, rest[0..d2], " \t");
                const arrow_len: usize = if (std.mem.startsWith(u8, rest[d2..], " -> ")) 4 else 3;
                const to = std.mem.trim(u8, rest[d2 + arrow_len..], " \t");
                var rn = Value.Node{ .type_name = "relationship", .fields = .{} };
                try rn.fields.put(a, "from", Value{ .string = from });
                try rn.fields.put(a, "to", Value{ .string = to });
                try rn.fields.put(a, "kind", Value{ .string = kind });
                try relationships.append(a, Value{ .node = rn });
            }
        }
    }

    var root = Value.Node{ .type_name = "requirementDiagram", .fields = .{} };
    try root.fields.put(a, "requirements", Value{ .list = try requirements.toOwnedSlice(a) });
    try root.fields.put(a, "elements", Value{ .list = try elements.toOwnedSlice(a) });
    try root.fields.put(a, "relationships", Value{ .list = try relationships.toOwnedSlice(a) });
    return requirement_renderer.render(allocator, Value{ .node = root });
}

// ─── kanban parser ────────────────────────────────────────────────────────────

fn renderKanbanDirect(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var columns: std.ArrayList(Value) = .empty;
    var current_col_label: ?[]const u8 = null;
    var current_items: std.ArrayList(Value) = .empty;
    var title: []const u8 = "";

    const flushColumn = struct {
        fn run(cols: *std.ArrayList(Value), label: []const u8, items: *std.ArrayList(Value), alloc: std.mem.Allocator) !void {
            var cn = Value.Node{ .type_name = "column", .fields = .{} };
            try cn.fields.put(alloc, "label", Value{ .string = label });
            try cn.fields.put(alloc, "items", Value{ .list = try items.toOwnedSlice(alloc) });
            try cols.append(alloc, Value{ .node = cn });
        }
    }.run;

    // First pass: detect column-header indent level (minimum indent of content
    // lines after the first line, ignoring blank/comment lines and the "title"
    // directive).
    var col_indent: usize = std.math.maxInt(usize);
    {
        var scan = std.mem.splitScalar(u8, text, '\n');
        var skip_first = true;
        while (scan.next()) |raw| {
            if (skip_first) { skip_first = false; continue; }
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
            if (std.mem.startsWith(u8, line, "title ")) continue;
            // Count leading spaces/tabs
            var ind: usize = 0;
            for (raw) |c| {
                if (c == ' ') { ind += 1; }
                else if (c == '\t') { ind += 4; }
                else break;
            }
            if (ind < col_indent) col_indent = ind;
        }
        if (col_indent == std.math.maxInt(usize)) col_indent = 0;
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (first) {
            first = false;
            // "kanban" or "kanban title" on first line
            if (std.mem.indexOf(u8, line, " ")) |sp| {
                title = std.mem.trim(u8, line[sp..], " \t");
            }
            continue;
        }

        // Skip standalone "title" directive
        if (std.mem.startsWith(u8, line, "title ")) continue;

        // Measure this line's indentation
        var ind: usize = 0;
        for (raw) |c| {
            if (c == ' ') { ind += 1; }
            else if (c == '\t') { ind += 4; }
            else break;
        }

        if (ind <= col_indent) {
            // Column header
            if (current_col_label) |lbl| {
                try flushColumn(&columns, lbl, &current_items, a);
                current_items = .empty;
            }
            current_col_label = line;
        } else if (current_col_label != null) {
            // Item inside current column.
            // Strip trailing @{...} metadata — not rendered yet.
            var item_line = line;
            if (std.mem.indexOf(u8, item_line, "@{")) |at| {
                item_line = std.mem.trimRight(u8, item_line[0..at], " \t");
            }
            // Syntax: id["label"] or "label" (bare string) or plain id
            var item_label = item_line;
            var item_id = item_line;
            if (std.mem.indexOf(u8, item_line, "[\"")) |lb| {
                item_id = item_line[0..lb];
                const rb = std.mem.indexOf(u8, item_line[lb..], "\"]") orelse (item_line.len - lb);
                item_label = item_line[lb + 2 .. @min(lb + rb, item_line.len)];
            } else if (item_line.len > 0 and item_line[0] == '"') {
                // Bare quoted string — use as label, generate id from position
                item_label = std.mem.trim(u8, item_line, "\"");
                item_id = item_label;
            }
            var iv = Value.Node{ .type_name = "item", .fields = .{} };
            try iv.fields.put(a, "id", Value{ .string = item_id });
            try iv.fields.put(a, "label", Value{ .string = item_label });
            try current_items.append(a, Value{ .node = iv });
        }
    }
    if (current_col_label) |lbl| {
        try flushColumn(&columns, lbl, &current_items, a);
    }

    if (columns.items.len == 0) return kanban_renderer.render(allocator, Value{ .null = {} });

    var root = Value.Node{ .type_name = "kanban", .fields = .{} };
    try root.fields.put(a, "title", Value{ .string = title });
    try root.fields.put(a, "columns", Value{ .list = try columns.toOwnedSlice(a) });
    return kanban_renderer.render(allocator, Value{ .node = root });
}

/// Extract a CSS-style property value from a comma-separated style string.
/// e.g. flowchartParseProp("fill:#f9f,stroke:#333", "fill") → "#f9f"
fn flowchartParseProp(style: []const u8, prop: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, style, ',');
    while (it.next()) |token| {
        const t = std.mem.trim(u8, token, " \t");
        if (std.mem.startsWith(u8, t, prop)) {
            const rest = t[prop.len..];
            if (rest.len > 0 and rest[0] == ':')
                return std.mem.trim(u8, rest[1..], " \t");
        }
    }
    return null;
}

fn parseNodeSpec(spec: []const u8) struct { []const u8, []const u8, []const u8 } {
    const s = std.mem.trim(u8, spec, " \t\r\n");
    if (s.len == 0) return .{ "", "", "rect" };
    // Find the first delimiter
    for (s, 0..) |c, i| {
        switch (c) {
            '[' => {
                const id = s[0..i];
                // Subroutine: [[label]]
                if (i + 1 < s.len and s[i + 1] == '[') {
                    const end = std.mem.indexOf(u8, s[i..], "]]") orelse (s.len - i - 1);
                    return .{ id, s[i + 2 .. @min(i + end, s.len)], "subroutine" };
                }
                // Cylinder: [(label)]  -- note: starts with `[` then `(`
                if (i + 1 < s.len and s[i + 1] == '(') {
                    const end = std.mem.lastIndexOfScalar(u8, s, ')') orelse s.len - 1;
                    return .{ id, s[i + 2 .. @min(end, s.len)], "cylinder" };
                }
                // Parallelogram: [/label/]
                if (i + 1 < s.len and s[i + 1] == '/') {
                    const end = std.mem.indexOf(u8, s[i..], "/]") orelse (s.len - i - 1);
                    return .{ id, s[i + 2 .. @min(i + end, s.len)], "parallelogram" };
                }
                // Rect: [label]
                const end = std.mem.lastIndexOfScalar(u8, s, ']') orelse s.len - 1;
                return .{ id, s[i + 1 .. @min(end, s.len)], "rect" };
            },
            '(' => {
                const id = s[0..i];
                // Circle: ((label))
                if (i + 1 < s.len and s[i + 1] == '(') {
                    const end = std.mem.indexOf(u8, s[i..], "))") orelse (s.len - i - 1);
                    return .{ id, s[i + 2 .. @min(i + end, s.len)], "circle" };
                }
                // Stadium: ([label])  -- note: starts with `(` then `[`
                if (i + 1 < s.len and s[i + 1] == '[') {
                    const end = std.mem.indexOf(u8, s[i..], "])") orelse (s.len - i - 1);
                    return .{ id, s[i + 2 .. @min(i + end, s.len)], "stadium" };
                }
                // Round rectangle: (label)
                const end = std.mem.lastIndexOfScalar(u8, s, ')') orelse s.len - 1;
                return .{ id, s[i + 1 .. @min(end, s.len)], "round" };
            },
            '{' => {
                const id = s[0..i];
                // Hexagon: {{label}}
                if (i + 1 < s.len and s[i + 1] == '{') {
                    const end = std.mem.indexOf(u8, s[i..], "}}") orelse (s.len - i - 1);
                    return .{ id, s[i + 2 .. @min(i + end, s.len)], "hexagon" };
                }
                // Diamond: {label}
                const end = std.mem.lastIndexOfScalar(u8, s, '}') orelse s.len - 1;
                return .{ id, s[i + 1 .. @min(end, s.len)], "diamond" };
            },
            '>' => {
                // Asymmetric: id>label]  -- only if `]` exists and no space/dash right after `>`
                if (i + 1 < s.len and s[i + 1] != ' ' and s[i + 1] != '\t' and s[i + 1] != '-') {
                    if (std.mem.lastIndexOfScalar(u8, s[i..], ']') != null) {
                        const id = s[0..i];
                        const end = (std.mem.lastIndexOfScalar(u8, s, ']') orelse s.len - 1);
                        return .{ id, s[i + 1 .. @min(end, s.len)], "asymmetric" };
                    }
                }
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

    // classDef name → raw style string ("fill:#f9f,stroke:#333")
    var class_defs = std.StringHashMap([]const u8).init(a);
    // node_id → class name (from "class nodeId className" or "A:::className")
    var node_class_map = std.StringHashMap([]const u8).init(a);

    // Subgraph tracking
    const Subgraph = struct {
        label: []const u8,
        members: std.ArrayList(Value),
    };
    var subgraphs: std.ArrayList(Subgraph) = .empty;
    var cur_subgraph: ?usize = null; // index into subgraphs

    const addNodeToSubgraph = struct {
        fn run(sgs: *std.ArrayList(Subgraph), idx: ?usize, alloc: std.mem.Allocator, id: []const u8) !void {
            const i = idx orelse return;
            try sgs.items[i].members.append(alloc, Value{ .string = id });
        }
    }.run;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        // Skip comments
        if (std.mem.startsWith(u8, line, "%%")) continue;
        // classDef myClass fill:#f9f,stroke:#333
        if (std.mem.startsWith(u8, line, "classDef ")) {
            const rest = line[9..];
            if (std.mem.indexOfScalar(u8, rest, ' ')) |sp| {
                const cname = rest[0..sp];
                const cstyle = std.mem.trim(u8, rest[sp + 1 ..], " \t");
                if (cname.len > 0 and cstyle.len > 0)
                    try class_defs.put(cname, cstyle);
            }
            continue;
        }
        // class node1,node2 className
        if (std.mem.startsWith(u8, line, "class ")) {
            const rest = line[6..];
            if (std.mem.lastIndexOfScalar(u8, rest, ' ')) |sp| {
                const ids_part = rest[0..sp];
                const cname = std.mem.trim(u8, rest[sp + 1 ..], " \t");
                if (cname.len > 0) {
                    var it = std.mem.splitScalar(u8, ids_part, ',');
                    while (it.next()) |id_raw| {
                        const nid = std.mem.trim(u8, id_raw, " \t");
                        if (nid.len > 0) try node_class_map.put(nid, cname);
                    }
                }
            }
            continue;
        }
        // Skip linkStyle and per-node style overrides (not yet supported)
        if (std.mem.startsWith(u8, line, "style ") or
            std.mem.startsWith(u8, line, "linkStyle ")) continue;

        if (first) {
            first = false;
            // Parse direction from header: "graph TD" or "flowchart LR"
            if (std.mem.indexOf(u8, line, " ")) |sp| {
                direction = std.mem.trim(u8, line[sp..], " \t");
            }
            continue;
        }

        // Subgraph start: "subgraph id" or "subgraph id [label]" or "subgraph [label]"
        if (std.mem.startsWith(u8, line, "subgraph")) {
            const rest = std.mem.trim(u8, line[8..], " \t");
            // Extract display label: prefer bracket content, else use rest
            const label = if (std.mem.indexOf(u8, rest, "[")) |lb|
                if (std.mem.indexOf(u8, rest, "]")) |rb| rest[lb + 1 .. rb] else rest
            else if (rest.len > 0) rest else "group";
            const sg_idx = subgraphs.items.len;
            try subgraphs.append(a, .{ .label = label, .members = .empty });
            cur_subgraph = sg_idx;
            continue;
        }
        if (std.mem.eql(u8, line, "end") and cur_subgraph != null) {
            cur_subgraph = null;
            continue;
        }

        // Skip subgraph-local direction directives (direction LR / direction TB etc.)
        if (std.mem.startsWith(u8, line, "direction ")) continue;

        // Try to find an edge arrow
        if (findEdgeArrow(line)) |arrow| {
            var from_raw = std.mem.trim(u8, line[0..arrow[0]], " \t");
            var to_part = std.mem.trim(u8, line[arrow[1]..], " \t");

            // Strip inline class annotations: A[label]:::myClass
            var from_inline_class: ?[]const u8 = null;
            if (std.mem.indexOf(u8, from_raw, ":::")) |cp| {
                from_inline_class = std.mem.trim(u8, from_raw[cp + 3 ..], " \t");
                from_raw = from_raw[0..cp];
            }
            var to_inline_class: ?[]const u8 = null;
            if (std.mem.indexOf(u8, to_part, ":::")) |cp| {
                to_inline_class = std.mem.trim(u8, to_part[cp + 3 ..], " \t");
                to_part = to_part[0..cp];
            }

            // Edge label: |label| between arrow and destination (A --> |label| B)
            var edge_label: ?[]const u8 = null;
            if (to_part.len > 0 and to_part[0] == '|') {
                const label_end = std.mem.indexOfScalar(u8, to_part[1..], '|') orelse 0;
                edge_label = to_part[1 .. 1 + label_end];
                to_part = std.mem.trim(u8, to_part[2 + label_end ..], " \t");
            }

            // Edge label embedded before arrow: "A -- label -->" or "A -- label ---"
            // Detect: from_raw contains " -- " and has content before it
            if (edge_label == null) {
                if (std.mem.lastIndexOf(u8, from_raw, " -- ")) |dash_pos| {
                    const node_part = std.mem.trim(u8, from_raw[0..dash_pos], " \t");
                    const lbl = std.mem.trim(u8, from_raw[dash_pos + 4 ..], " \t");
                    if (node_part.len > 0 and lbl.len > 0) {
                        from_raw = node_part;
                        edge_label = lbl;
                    }
                }
            }

            const from_part = from_raw;
            const from_id, const from_label, const from_shape = parseNodeSpec(from_part);
            const to_id, const to_label, const to_shape = parseNodeSpec(to_part);

            if (from_id.len == 0 or to_id.len == 0) continue;

            // Record inline class assignments
            if (from_inline_class) |cn| try node_class_map.put(from_id, cn);
            if (to_inline_class) |cn| try node_class_map.put(to_id, cn);

            // Add nodes if not seen
            if (seen_nodes.get(from_id) == null) {
                try seen_nodes.put(from_id, {});
                var n = Value.Node{ .type_name = "node", .fields = .{} };
                try n.fields.put(a, "id", Value{ .string = from_id });
                try n.fields.put(a, "label", Value{ .string = from_label });
                try n.fields.put(a, "shape", Value{ .string = from_shape });
                try nodes_list.append(a, Value{ .node = n });
                try addNodeToSubgraph(&subgraphs, cur_subgraph, a, from_id);
            }
            if (seen_nodes.get(to_id) == null) {
                try seen_nodes.put(to_id, {});
                var n = Value.Node{ .type_name = "node", .fields = .{} };
                try n.fields.put(a, "id", Value{ .string = to_id });
                try n.fields.put(a, "label", Value{ .string = to_label });
                try n.fields.put(a, "shape", Value{ .string = to_shape });
                try nodes_list.append(a, Value{ .node = n });
                try addNodeToSubgraph(&subgraphs, cur_subgraph, a, to_id);
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
        } else if (line.len > 0 and !std.mem.eql(u8, line, "end")) {
            // Standalone node definition — strip optional :::className first
            var standalone = line;
            var standalone_class: ?[]const u8 = null;
            if (std.mem.indexOf(u8, standalone, ":::")) |cp| {
                standalone_class = std.mem.trim(u8, standalone[cp + 3 ..], " \t");
                standalone = standalone[0..cp];
            }
            const node_id, const node_label, const node_shape = parseNodeSpec(standalone);
            if (node_id.len > 0 and seen_nodes.get(node_id) == null) {
                try seen_nodes.put(node_id, {});
                var n = Value.Node{ .type_name = "node", .fields = .{} };
                try n.fields.put(a, "id", Value{ .string = node_id });
                try n.fields.put(a, "label", Value{ .string = node_label });
                try n.fields.put(a, "shape", Value{ .string = node_shape });
                try nodes_list.append(a, Value{ .node = n });
                try addNodeToSubgraph(&subgraphs, cur_subgraph, a, node_id);
                if (standalone_class) |cn| try node_class_map.put(node_id, cn);
            }
        }
    }

    // Apply classDef styles to nodes that carry a class assignment.
    for (nodes_list.items) |*nv| {
        // Need mutable access to the Node; check tag then take pointer.
        const is_node = switch (nv.*) { .node => true, else => false };
        if (!is_node) continue;
        const nn = &nv.node;
        const nid = nn.getString("id") orelse continue;
        const cname = node_class_map.get(nid) orelse continue;
        const style = class_defs.get(cname) orelse continue;
        if (flowchartParseProp(style, "fill"))   |v| try nn.fields.put(a, "fill",       Value{ .string = v });
        if (flowchartParseProp(style, "stroke"))  |v| try nn.fields.put(a, "stroke",     Value{ .string = v });
        if (flowchartParseProp(style, "color"))   |v| try nn.fields.put(a, "text_color", Value{ .string = v });
    }

    // Build subgraphs list for the renderer
    var subgraphs_val: std.ArrayList(Value) = .empty;
    for (subgraphs.items) |*sg| {
        if (sg.members.items.len == 0) continue;
        var sgn = Value.Node{ .type_name = "subgraph", .fields = .{} };
        try sgn.fields.put(a, "label", Value{ .string = sg.label });
        try sgn.fields.put(a, "members", Value{ .list = try sg.members.toOwnedSlice(a) });
        try subgraphs_val.append(a, Value{ .node = sgn });
    }

    var root = Value.Node{ .type_name = "flowchart", .fields = .{} };
    try root.fields.put(a, "direction", Value{ .string = direction });
    try root.fields.put(a, "nodes", Value{ .list = try nodes_list.toOwnedSlice(a) });
    try root.fields.put(a, "edges", Value{ .list = try edges_list.toOwnedSlice(a) });
    try root.fields.put(a, "subgraphs", Value{ .list = try subgraphs_val.toOwnedSlice(a) });

    return flowchart_renderer.render(allocator, Value{ .node = root });
}

fn renderSequenceDirect(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var participants_list: std.ArrayList(Value) = .empty;
    var signals_list: std.ArrayList(Value) = .empty;
    var seen_actors = std.StringHashMap(void).init(a);
    var autonumber = false;
    var msg_count: usize = 0; // track message count for note row positions

    const BlockFrame = struct { kind: []const u8, label: []const u8, start: usize };
    var block_stack: std.ArrayList(BlockFrame) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "%%")) continue;

        if (first) {
            first = false;
            continue; // skip "sequenceDiagram"
        }

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
            try sig.fields.put(a, "blockText", Value{ .string = lbl });
            try signals_list.append(a, Value{ .node = sig });
            try block_stack.append(a, .{ .kind = "alt", .label = lbl, .start = signals_list.items.len - 1 });
            continue;
        }
        if (std.mem.startsWith(u8, line, "opt ") or std.mem.eql(u8, line, "opt")) {
            const lbl = if (line.len > 4) line[4..] else "";
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "optStart" });
            try sig.fields.put(a, "blockText", Value{ .string = lbl });
            try signals_list.append(a, Value{ .node = sig });
            try block_stack.append(a, .{ .kind = "opt", .label = lbl, .start = signals_list.items.len - 1 });
            continue;
        }
        if (std.mem.startsWith(u8, line, "par ") or std.mem.eql(u8, line, "par")) {
            const lbl = if (line.len > 4) line[4..] else "";
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "parStart" });
            try sig.fields.put(a, "blockText", Value{ .string = lbl });
            try signals_list.append(a, Value{ .node = sig });
            try block_stack.append(a, .{ .kind = "par", .label = lbl, .start = signals_list.items.len - 1 });
            continue;
        }
        // box <color> <label> ... end: treat as a visual grouping; skip header/end,
        // participants inside are still parsed normally.
        if (std.mem.startsWith(u8, line, "box ") or std.mem.eql(u8, line, "box")) {
            try block_stack.append(a, .{ .kind = "box", .label = "", .start = signals_list.items.len });
            continue;
        }
        if (std.mem.eql(u8, line, "autonumber")) {
            autonumber = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "activate ")) {
            const actor_name = std.mem.trim(u8, line[9..], " \t");
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "activate" });
            try sig.fields.put(a, "actor", Value{ .string = actor_name });
            try sig.fields.put(a, "row", Value{ .number = @floatFromInt(msg_count) });
            try signals_list.append(a, Value{ .node = sig });
            continue;
        }
        if (std.mem.startsWith(u8, line, "deactivate ")) {
            const actor_name = std.mem.trim(u8, line[11..], " \t");
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "deactivate" });
            try sig.fields.put(a, "actor", Value{ .string = actor_name });
            try sig.fields.put(a, "row", Value{ .number = @floatFromInt(msg_count) });
            try signals_list.append(a, Value{ .node = sig });
            continue;
        }
        if (std.mem.startsWith(u8, line, "note ") or std.mem.startsWith(u8, line, "Note ")) {
            // Note over A,B: text  /  Note right of A: text  /  Note left of A: text
            const rest = line[5..];
            const colon = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
            const pos_part = std.mem.trim(u8, rest[0..colon], " \t");
            const note_text = if (colon < rest.len) std.mem.trim(u8, rest[colon + 1..], " \t") else "";
            var sig = Value.Node{ .type_name = "signal", .fields = .{} };
            try sig.fields.put(a, "type", Value{ .string = "note" });
            try sig.fields.put(a, "text", Value{ .string = note_text });
            try sig.fields.put(a, "row", Value{ .number = @floatFromInt(msg_count) });
            if (std.mem.startsWith(u8, pos_part, "over ")) {
                const actors_str = pos_part[5..];
                if (std.mem.indexOfScalar(u8, actors_str, ',')) |ci| {
                    try sig.fields.put(a, "actor1", Value{ .string = std.mem.trim(u8, actors_str[0..ci], " \t") });
                    try sig.fields.put(a, "actor2", Value{ .string = std.mem.trim(u8, actors_str[ci + 1..], " \t") });
                } else {
                    try sig.fields.put(a, "actor1", Value{ .string = std.mem.trim(u8, actors_str, " \t") });
                }
                try sig.fields.put(a, "position", Value{ .string = "over" });
            } else if (std.mem.startsWith(u8, pos_part, "right of ")) {
                try sig.fields.put(a, "actor1", Value{ .string = std.mem.trim(u8, pos_part[9..], " \t") });
                try sig.fields.put(a, "position", Value{ .string = "right" });
            } else if (std.mem.startsWith(u8, pos_part, "left of ")) {
                try sig.fields.put(a, "actor1", Value{ .string = std.mem.trim(u8, pos_part[8..], " \t") });
                try sig.fields.put(a, "position", Value{ .string = "left" });
            } else {
                try sig.fields.put(a, "actor1", Value{ .string = pos_part });
                try sig.fields.put(a, "position", Value{ .string = "over" });
            }
            try signals_list.append(a, Value{ .node = sig });
            continue;
        }
        if (std.mem.startsWith(u8, line, "else") or
            std.mem.startsWith(u8, line, "and ") or std.mem.eql(u8, line, "and")) {
            continue; // alt/par branch separator, skip
        }
        if (std.mem.eql(u8, line, "end")) {
            if (block_stack.items.len > 0) {
                const top = block_stack.pop().?;
                // "box" groups are visual-only; no signal emitted for them
                if (std.mem.eql(u8, top.kind, "box")) {
                    // nothing to emit
                } else {
                    const end_type: []const u8 =
                        if (std.mem.eql(u8, top.kind, "loop")) "loopEnd"
                        else if (std.mem.eql(u8, top.kind, "opt")) "optEnd"
                        else if (std.mem.eql(u8, top.kind, "par")) "parEnd"
                        else "altEnd";
                    var sig = Value.Node{ .type_name = "signal", .fields = .{} };
                    try sig.fields.put(a, "type", Value{ .string = end_type });
                    try signals_list.append(a, Value{ .node = sig });
                }
            }
            continue;
        }

        // Message arrows: Actor->>Actor: text or Actor-->>Actor: text etc.
        // Try to find an arrow pattern
        const arrow_patterns = [_]struct { []const u8, []const u8 }{
            .{ "-->x", "3" }, .{ "-->>", "1" }, .{ "->>", "0" },
            .{ "-->", "3" }, .{ "->x", "2" }, .{ "->)", "0" }, .{ "-)", "0" }, .{ "->", "2" },
        };
        var found_arrow = false;
        for (arrow_patterns) |ap| {
            if (std.mem.indexOf(u8, line, ap[0])) |arrow_pos| {
                const from_raw = std.mem.trim(u8, line[0..arrow_pos], " \t");
                const after_arrow = line[arrow_pos + ap[0].len..];
                // Split on ":"
                const colon_pos = std.mem.indexOfScalar(u8, after_arrow, ':') orelse after_arrow.len;
                var to_raw = std.mem.trim(u8, after_arrow[0..colon_pos], " \t");
                const msg = if (colon_pos < after_arrow.len)
                    std.mem.trim(u8, after_arrow[colon_pos + 1..], " \t")
                else "";

                // +/- activation marker on to-actor: prefix "+" or "-" or suffix "+" or "-"
                var activate_suffix: i8 = 0; // +1=activate, -1=deactivate
                if (to_raw.len > 0 and to_raw[0] == '+') {
                    to_raw = to_raw[1..];
                    activate_suffix = 1;
                } else if (to_raw.len > 0 and to_raw[0] == '-') {
                    to_raw = to_raw[1..];
                    activate_suffix = -1;
                } else if (to_raw.len > 0 and to_raw[to_raw.len - 1] == '+') {
                    to_raw = to_raw[0 .. to_raw.len - 1];
                    activate_suffix = 1;
                } else if (to_raw.len > 0 and to_raw[to_raw.len - 1] == '-') {
                    to_raw = to_raw[0 .. to_raw.len - 1];
                    activate_suffix = -1;
                }

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
                msg_count += 1;

                // Emit activate/deactivate after message if +/- suffix was present
                if (activate_suffix == 1) {
                    var asig = Value.Node{ .type_name = "signal", .fields = .{} };
                    try asig.fields.put(a, "type", Value{ .string = "activate" });
                    try asig.fields.put(a, "actor", Value{ .string = to_raw });
                    try asig.fields.put(a, "row", Value{ .number = @floatFromInt(msg_count) });
                    try signals_list.append(a, Value{ .node = asig });
                } else if (activate_suffix == -1) {
                    var asig = Value.Node{ .type_name = "signal", .fields = .{} };
                    try asig.fields.put(a, "type", Value{ .string = "deactivate" });
                    try asig.fields.put(a, "actor", Value{ .string = to_raw });
                    try asig.fields.put(a, "row", Value{ .number = @floatFromInt(msg_count) });
                    try signals_list.append(a, Value{ .node = asig });
                }
                found_arrow = true;
                break;
            }
        }
    }

    var root = Value.Node{ .type_name = "sequenceDiagram", .fields = .{} };
    try root.fields.put(a, "participants", Value{ .list = try participants_list.toOwnedSlice(a) });
    try root.fields.put(a, "signals", Value{ .list = try signals_list.toOwnedSlice(a) });
    try root.fields.put(a, "autonumber", Value{ .number = if (autonumber) 1.0 else 0.0 });

    return sequence_renderer.render(allocator, Value{ .node = root });
}

// ─── classDiagram parser ──────────────────────────────────────────────────────

fn renderClassDirect(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // class_name → list of member strings
    var class_map = std.StringArrayHashMap(std.ArrayList([]const u8)).init(a);
    var relations: std.ArrayList(Value) = .empty;

    // Relationship patterns (order: longer first)
    const RelPat = struct { []const u8, []const u8 };
    const rel_patterns = [_]RelPat{
        .{ "<|--", "inheritance" }, .{ "--|>", "inheritance" },
        .{ "*--",  "composition" }, .{ "--*",  "composition" },
        .{ "o--",  "aggregation" }, .{ "--o",  "aggregation" },
        .{ "<..",  "dependency"  }, .{ "..>",  "dependency"  },
        .{ "<|..", "realization" }, .{ "..|>", "realization" },
        .{ "-->",  "association" }, .{ "<--",  "association" },
        .{ "..",   "link_dashed" },
        .{ "--",   "link"        },
    };

    var current_class: ?[]const u8 = null; // inside a `class X {` block
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (first) { first = false; continue; } // skip "classDiagram"

        // End of class block
        if (std.mem.eql(u8, line, "}")) { current_class = null; continue; }

        // Start of class block: "class Foo {" or "class Foo <<interface>>"
        if (std.mem.startsWith(u8, line, "class ")) {
            const rest = std.mem.trim(u8, line[6..], " \t");
            const name_end = std.mem.indexOfAny(u8, rest, " {") orelse rest.len;
            const name = std.mem.trim(u8, rest[0..name_end], " \t");
            const entry = try class_map.getOrPut(name);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            // Inline stereotype: "class Foo <<interface>>" or "class Foo <<interface>> {"
            if (name_end < rest.len) {
                const after = std.mem.trim(u8, rest[name_end..], " \t{");
                if (std.mem.startsWith(u8, after, "<<") and std.mem.indexOf(u8, after, ">>") != null) {
                    const ste_end = (std.mem.indexOf(u8, after, ">>") orelse after.len - 2) + 2;
                    try entry.value_ptr.append(a, after[0..ste_end]);
                }
            }
            if (std.mem.indexOf(u8, line, "{") != null) {
                current_class = name;
            }
            continue;
        }

        // Member inside a block
        if (current_class) |cls| {
            const entry = class_map.getPtr(cls) orelse continue;
            try entry.append(a, line);
            continue;
        }

        // ClassName : member (outside block)
        if (std.mem.indexOf(u8, line, " : ")) |colon_pos| {
            const lhs = std.mem.trim(u8, line[0..colon_pos], " \t");
            const member = std.mem.trim(u8, line[colon_pos + 3..], " \t");
            // Only treat as member if lhs has no relationship chars
            if (std.mem.indexOf(u8, lhs, "<") == null and
                std.mem.indexOf(u8, lhs, ">") == null and
                std.mem.indexOf(u8, lhs, "*") == null and
                std.mem.indexOf(u8, lhs, "o") == null and
                std.mem.indexOfScalar(u8, lhs, '.') == null)
            {
                const entry = class_map.getPtr(lhs) orelse blk: {
                    try class_map.put(lhs, .empty);
                    break :blk class_map.getPtr(lhs).?;
                };
                try entry.append(a, member);
                continue;
            }
        }

        // Relationship line: detect pattern
        for (rel_patterns) |rp| {
            if (std.mem.indexOf(u8, line, rp[0])) |pat_pos| {
                const left = std.mem.trim(u8, line[0..pat_pos], " \t");
                const after = std.mem.trim(u8, line[pat_pos + rp[0].len..], " \t");
                // Extract `to` and optional label after ` : `
                const right_end = std.mem.indexOf(u8, after, " : ") orelse after.len;
                const right = std.mem.trim(u8, after[0..right_end], " \t");
                const label = if (right_end < after.len)
                    std.mem.trim(u8, after[right_end + 3..], " \t") else "";

                // Determine from/to based on arrow direction
                const from, const to = if (std.mem.startsWith(u8, rp[0], "<"))
                    .{ right, left } else .{ left, right };

                if (!class_map.contains(from)) try class_map.put(from, .empty);
                if (!class_map.contains(to)) try class_map.put(to, .empty);

                var rn = Value.Node{ .type_name = "relation", .fields = .{} };
                try rn.fields.put(a, "from", Value{ .string = from });
                try rn.fields.put(a, "to", Value{ .string = to });
                try rn.fields.put(a, "kind", Value{ .string = rp[1] });
                try rn.fields.put(a, "label", Value{ .string = label });
                try relations.append(a, Value{ .node = rn });
                break;
            }
        }
    }

    // Build class Value list
    var class_list: std.ArrayList(Value) = .empty;
    var it = class_map.iterator();
    while (it.next()) |entry| {
        var members_list: std.ArrayList(Value) = .empty;
        for (entry.value_ptr.items) |m| {
            try members_list.append(a, Value{ .string = m });
        }
        var cn = Value.Node{ .type_name = "class", .fields = .{} };
        try cn.fields.put(a, "name", Value{ .string = entry.key_ptr.* });
        try cn.fields.put(a, "members", Value{ .list = try members_list.toOwnedSlice(a) });
        try class_list.append(a, Value{ .node = cn });
    }

    var root = Value.Node{ .type_name = "classDiagram", .fields = .{} };
    try root.fields.put(a, "classes", Value{ .list = try class_list.toOwnedSlice(a) });
    try root.fields.put(a, "relations", Value{ .list = try relations.toOwnedSlice(a) });
    return class_renderer.render(allocator, Value{ .node = root });
}

// ─── stateDiagram parser ──────────────────────────────────────────────────────

fn renderStateDirect(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var states: std.ArrayList(Value) = .empty;
    var transitions: std.ArrayList(Value) = .empty;
    var seen = std.StringHashMap(void).init(a);

    const addState = struct {
        fn run(sl: *std.ArrayList(Value), s: *std.StringHashMap(void), alloc: std.mem.Allocator, id: []const u8, lbl: []const u8) !void {
            if (s.get(id) != null) return;
            try s.put(id, {});
            var sn = Value.Node{ .type_name = "state", .fields = .{} };
            try sn.fields.put(alloc, "id", Value{ .string = id });
            try sn.fields.put(alloc, "label", Value{ .string = lbl });
            try sl.append(alloc, Value{ .node = sn });
        }
    }.run;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (first) { first = false; continue; } // skip header

        // `state "long name" as id` or `state id {` (compound)
        // Also handles: `state id <<fork>>` / `<<join>>` / `<<choice>>`
        if (std.mem.startsWith(u8, line, "state ")) {
            const rest = line[6..];
            // Check for stereotype: state id <<fork>> etc.
            if (std.mem.indexOf(u8, rest, "<<")) |ss| {
                const id = std.mem.trim(u8, rest[0..ss], " \t");
                const ste_start = ss + 2;
                const ste_end = std.mem.indexOf(u8, rest[ste_start..], ">>") orelse (rest.len - ste_start);
                const ste = rest[ste_start .. ste_start + ste_end];
                if (id.len > 0) {
                    if (seen.get(id) == null) {
                        try seen.put(id, {});
                        var sn = Value.Node{ .type_name = "state", .fields = .{} };
                        try sn.fields.put(a, "id", Value{ .string = id });
                        try sn.fields.put(a, "label", Value{ .string = id });
                        try sn.fields.put(a, "shape", Value{ .string = ste });
                        try states.append(a, Value{ .node = sn });
                    }
                }
            } else if (std.mem.indexOf(u8, rest, " as ")) |ai| {
                const lbl_raw = std.mem.trim(u8, rest[0..ai], " \t\"");
                const id = std.mem.trim(u8, rest[ai + 4..], " \t{");
                if (id.len > 0) try addState(&states, &seen, a, id, lbl_raw);
            } else {
                // "state id" or "state id {": register with id as label
                const id = std.mem.trim(u8, rest, " \t{\"");
                if (id.len > 0) try addState(&states, &seen, a, id, id);
            }
            continue;
        }

        // Skip compound state opens/closes
        if (std.mem.eql(u8, line, "}") or std.mem.indexOf(u8, line, "{") != null) continue;
        // Skip note lines
        if (std.mem.startsWith(u8, line, "note")) continue;

        // Transition: `A --> B` or `A --> B : label`
        if (std.mem.indexOf(u8, line, "-->")) |arrow_pos| {
            const from = std.mem.trim(u8, line[0..arrow_pos], " \t");
            const after = std.mem.trim(u8, line[arrow_pos + 3..], " \t");
            const colon = std.mem.indexOfScalar(u8, after, ':') orelse after.len;
            const to = std.mem.trim(u8, after[0..colon], " \t");
            const lbl = if (colon < after.len)
                std.mem.trim(u8, after[colon + 1..], " \t") else "";

            if (from.len == 0 or to.len == 0) continue;
            // [*] as source = initial pseudo-state; [*] as target = final pseudo-state.
            // Use distinct ids so the BFS places the end state below the diagram.
            const from_id = if (std.mem.eql(u8, from, "[*]")) "[*]" else from;
            const to_id = if (std.mem.eql(u8, to, "[*]")) "[*]-end" else to;
            try addState(&states, &seen, a, from_id, from_id);
            try addState(&states, &seen, a, to_id, to_id);

            var tn = Value.Node{ .type_name = "transition", .fields = .{} };
            try tn.fields.put(a, "from", Value{ .string = from_id });
            try tn.fields.put(a, "to", Value{ .string = to_id });
            try tn.fields.put(a, "label", Value{ .string = lbl });
            try transitions.append(a, Value{ .node = tn });
        }
    }

    var root = Value.Node{ .type_name = "stateDiagram", .fields = .{} };
    try root.fields.put(a, "states", Value{ .list = try states.toOwnedSlice(a) });
    try root.fields.put(a, "transitions", Value{ .list = try transitions.toOwnedSlice(a) });
    return state_renderer.render(allocator, Value{ .node = root });
}

// ─── erDiagram parser ─────────────────────────────────────────────────────────

fn renderErDirect(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // entity_name → list of attr nodes
    var entity_map = std.StringArrayHashMap(std.ArrayList(Value)).init(a);
    var relations: std.ArrayList(Value) = .empty;

    var current_entity: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (first) { first = false; continue; }

        if (std.mem.eql(u8, line, "}")) { current_entity = null; continue; }

        // Entity block start: "ENTITY {" or "ENTITY{"
        if (std.mem.indexOf(u8, line, "{") != null and
            std.mem.indexOf(u8, line, "--") == null and
            std.mem.indexOf(u8, line, "..") == null)
        {
            const name = std.mem.trim(u8, line[0..std.mem.indexOfScalar(u8, line, '{').?], " \t");
            if (name.len > 0) {
                if (!entity_map.contains(name)) try entity_map.put(name, .empty);
                current_entity = name;
            }
            continue;
        }

        // Attribute inside entity block: "type name" or "type name PK"
        if (current_entity) |ent| {
            const parts = splitFirst(line, ' ');
            if (parts[0].len > 0 and parts[1].len > 0) {
                const entry = entity_map.getPtr(ent) orelse continue;
                const attr_name_raw = parts[1];
                const is_key = std.mem.indexOf(u8, attr_name_raw, "PK") != null or
                               std.mem.indexOf(u8, attr_name_raw, "FK") != null;
                const attr_name = blk: {
                    var n = attr_name_raw;
                    if (std.mem.indexOf(u8, n, " ")) |sp| n = n[0..sp];
                    break :blk n;
                };
                var an = Value.Node{ .type_name = "attr", .fields = .{} };
                try an.fields.put(a, "type", Value{ .string = parts[0] });
                try an.fields.put(a, "name", Value{ .string = attr_name });
                if (is_key) try an.fields.put(a, "key", Value{ .string = "true" });
                try entry.append(a, Value{ .node = an });
            }
            continue;
        }

        // Relationship: ENTITY_A rel ENTITY_B : "label"
        // rel pattern contains -- or ..
        if (std.mem.indexOf(u8, line, "--") orelse std.mem.indexOf(u8, line, "..")) |connector_pos| {
            // The full rel token includes cardinality chars before and after the connector.
            // Walk backward from connector_pos to find where the rel token starts (first space or start of line).
            var rel_token_start = connector_pos;
            while (rel_token_start > 0 and line[rel_token_start - 1] != ' ' and line[rel_token_start - 1] != '\t') {
                rel_token_start -= 1;
            }
            // Walk forward from connector_pos to find where the rel token ends (next space).
            const after_connector = line[connector_pos..];
            var rel_token_len: usize = after_connector.len;
            for (after_connector, 0..) |c, i| {
                if (c == ' ') { rel_token_len = i; break; }
            }
            const rel_str = line[rel_token_start..connector_pos + rel_token_len];
            const from = std.mem.trimRight(u8, std.mem.trim(u8, line[0..rel_token_start], " \t"), "|o{}< \t");
            // Everything after the rel token
            const after_rel = line[connector_pos + rel_token_len..];
            const rest = std.mem.trim(u8, after_rel, " \t");
            // rest: "ENTITY_B : label" or just "ENTITY_B"
            const colon = std.mem.indexOf(u8, rest, " : ") orelse rest.len;
            const to = std.mem.trim(u8, rest[0..colon], " \t");
            const label = if (colon < rest.len)
                std.mem.trim(u8, rest[colon + 3..], " \t\"") else "";

            if (from.len == 0 or to.len == 0) continue;
            if (!entity_map.contains(from)) try entity_map.put(from, .empty);
            if (!entity_map.contains(to)) try entity_map.put(to, .empty);

            var rn = Value.Node{ .type_name = "relation", .fields = .{} };
            try rn.fields.put(a, "from", Value{ .string = from });
            try rn.fields.put(a, "to", Value{ .string = to });
            try rn.fields.put(a, "rel", Value{ .string = rel_str });
            try rn.fields.put(a, "label", Value{ .string = label });
            try relations.append(a, Value{ .node = rn });
        }
    }

    var entity_list: std.ArrayList(Value) = .empty;
    var it = entity_map.iterator();
    while (it.next()) |entry| {
        var en = Value.Node{ .type_name = "entity", .fields = .{} };
        try en.fields.put(a, "name", Value{ .string = entry.key_ptr.* });
        try en.fields.put(a, "attrs", Value{ .list = try entry.value_ptr.toOwnedSlice(a) });
        try entity_list.append(a, Value{ .node = en });
    }

    var root = Value.Node{ .type_name = "erDiagram", .fields = .{} };
    try root.fields.put(a, "entities", Value{ .list = try entity_list.toOwnedSlice(a) });
    try root.fields.put(a, "relations", Value{ .list = try relations.toOwnedSlice(a) });
    return er_renderer.render(allocator, Value{ .node = root });
}

/// Split `s` on the first occurrence of `delim`, returning [before, after].
fn splitFirst(s: []const u8, delim: u8) [2][]const u8 {
    if (std.mem.indexOfScalar(u8, s, delim)) |i| {
        return .{ s[0..i], std.mem.trim(u8, s[i + 1..], " \t") };
    }
    return .{ s, "" };
}

// ─── gantt parser ─────────────────────────────────────────────────────────────

fn renderGanttDirect(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var title: []const u8 = "gantt";
    var sections: std.ArrayList(Value) = .empty;
    var cur_section_label: []const u8 = "Tasks";
    var cur_tasks: std.ArrayList(Value) = .empty;
    var show_today: bool = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (first) { first = false; continue; }

        if (std.mem.startsWith(u8, line, "title ") or std.mem.startsWith(u8, line, "title\t")) {
            title = std.mem.trim(u8, line[6..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, line, "dateFormat") or
            std.mem.startsWith(u8, line, "axisFormat") or
            std.mem.startsWith(u8, line, "excludes") or
            std.mem.startsWith(u8, line, "tickInterval"))
        {
            continue; // skip format directives
        }
        if (std.mem.startsWith(u8, line, "todayMarker")) {
            // "todayMarker off" disables it; anything else (including bare "todayMarker") enables
            const rest2 = std.mem.trim(u8, line[11..], " \t");
            if (!std.mem.eql(u8, rest2, "off")) {
                show_today = true;
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "section ") or std.mem.startsWith(u8, line, "section\t")) {
            // Save previous section
            if (cur_tasks.items.len > 0) {
                var sn = Value.Node{ .type_name = "section", .fields = .{} };
                try sn.fields.put(a, "label", Value{ .string = cur_section_label });
                try sn.fields.put(a, "tasks", Value{ .list = try cur_tasks.toOwnedSlice(a) });
                try sections.append(a, Value{ .node = sn });
                cur_tasks = .empty;
            }
            cur_section_label = std.mem.trim(u8, line[8..], " \t");
            continue;
        }

        // Task line: "Task name : flags, id, date, duration"
        if (std.mem.indexOf(u8, line, " : ") orelse std.mem.indexOf(u8, line, "\t:")) |colon| {
            const task_name = std.mem.trim(u8, line[0..colon], " \t");
            const rest = std.mem.trim(u8, line[colon + 3..], " \t");

            // Parse comma-separated fields; last numeric-ish field is duration
            var dur: []const u8 = "1d";
            var flags: []const u8 = "";
            var parts_iter = std.mem.splitScalar(u8, rest, ',');
            while (parts_iter.next()) |p| {
                const pt = std.mem.trim(u8, p, " \t");
                if (pt.len == 0) continue;
                if (std.mem.eql(u8, pt, "crit") or std.mem.eql(u8, pt, "done") or
                    std.mem.eql(u8, pt, "active") or std.mem.eql(u8, pt, "milestone"))
                {
                    flags = pt;
                } else if (pt.len > 0) {
                    const last = pt[pt.len - 1];
                    if (last == 'd' or last == 'h' or last == 'w' or std.ascii.isDigit(last)) {
                        dur = pt;
                    }
                }
            }

            var tn = Value.Node{ .type_name = "task", .fields = .{} };
            try tn.fields.put(a, "name", Value{ .string = task_name });
            try tn.fields.put(a, "duration", Value{ .string = dur });
            try tn.fields.put(a, "flags", Value{ .string = flags });
            try cur_tasks.append(a, Value{ .node = tn });
        }
    }

    // Flush last section
    if (cur_tasks.items.len > 0) {
        var sn = Value.Node{ .type_name = "section", .fields = .{} };
        try sn.fields.put(a, "label", Value{ .string = cur_section_label });
        try sn.fields.put(a, "tasks", Value{ .list = try cur_tasks.toOwnedSlice(a) });
        try sections.append(a, Value{ .node = sn });
    }

    var root = Value.Node{ .type_name = "gantt", .fields = .{} };
    try root.fields.put(a, "title", Value{ .string = title });
    try root.fields.put(a, "sections", Value{ .list = try sections.toOwnedSlice(a) });
    try root.fields.put(a, "show_today", Value{ .string = if (show_today) "1" else "0" });
    return gantt_renderer.render(allocator, Value{ .node = root });
}

// ─── timeline parser ──────────────────────────────────────────────────────────

fn renderTimelineDirect(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var title: []const u8 = "";
    var sections: std.ArrayList(Value) = .empty;
    var cur_label: []const u8 = "";
    var cur_events: std.ArrayList(Value) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (first) { first = false; continue; }

        if (std.mem.startsWith(u8, line, "title ") or std.mem.startsWith(u8, line, "title\t")) {
            title = std.mem.trim(u8, line[6..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, line, "section ") or std.mem.startsWith(u8, line, "section\t")) {
            // flush only if current section has events
            if (cur_events.items.len > 0) {
                var sn = Value.Node{ .type_name = "section", .fields = .{} };
                try sn.fields.put(a, "label", Value{ .string = cur_label });
                try sn.fields.put(a, "events", Value{ .list = try cur_events.toOwnedSlice(a) });
                try sections.append(a, Value{ .node = sn });
                cur_events = .empty;
            }
            cur_label = std.mem.trim(u8, line[8..], " \t");
            continue;
        }

        // `date : event1 : event2` or just `event`
        if (std.mem.indexOf(u8, line, " : ")) |colon| {
            const era = std.mem.trim(u8, line[0..colon], " \t");
            // Flush previous section if era changed
            if (era.len > 0 and !std.mem.eql(u8, era, cur_label)) {
                if (cur_events.items.len > 0) {
                    var sn = Value.Node{ .type_name = "section", .fields = .{} };
                    try sn.fields.put(a, "label", Value{ .string = cur_label });
                    try sn.fields.put(a, "events", Value{ .list = try cur_events.toOwnedSlice(a) });
                    try sections.append(a, Value{ .node = sn });
                    cur_events = .empty;
                }
                cur_label = era;
            }
            // Add events (may be multiple colon-separated)
            var ev_iter = std.mem.splitSequence(u8, line[colon + 3..], " : ");
            while (ev_iter.next()) |ev| {
                const evt = std.mem.trim(u8, ev, " \t");
                if (evt.len > 0) {
                    try cur_events.append(a, Value{ .string = evt });
                }
            }
        } else {
            // Continuation event (indented, no era)
            try cur_events.append(a, Value{ .string = line });
        }
    }
    // Flush last section (only if it has events)
    if (cur_events.items.len > 0) {
        var sn = Value.Node{ .type_name = "section", .fields = .{} };
        try sn.fields.put(a, "label", Value{ .string = cur_label });
        try sn.fields.put(a, "events", Value{ .list = try cur_events.toOwnedSlice(a) });
        try sections.append(a, Value{ .node = sn });
    }

    var root = Value.Node{ .type_name = "timeline", .fields = .{} };
    try root.fields.put(a, "title", Value{ .string = title });
    try root.fields.put(a, "sections", Value{ .list = try sections.toOwnedSlice(a) });
    return timeline_renderer.render(allocator, Value{ .node = root });
}

// ─── xychart parser ───────────────────────────────────────────────────────────

fn renderXyChartDirect(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var title: []const u8 = "";
    var y_min: f64 = 0;
    var y_max: f64 = 100;
    var x_labels: std.ArrayList(Value) = .empty;
    var series: std.ArrayList(Value) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (first) { first = false; continue; }

        if (std.mem.startsWith(u8, line, "title ") or std.mem.startsWith(u8, line, "title\t")) {
            title = std.mem.trim(u8, line[6..], " \t\"");
            continue;
        }

        if (std.mem.startsWith(u8, line, "x-axis ") or std.mem.startsWith(u8, line, "x-axis\t")) {
            const rest = std.mem.trim(u8, line[7..], " \t");
            // Extract bracket content [a, b, c]
            if (std.mem.indexOf(u8, rest, "[")) |lb| {
                const rb = std.mem.lastIndexOf(u8, rest, "]") orelse rest.len;
                var iter = std.mem.splitScalar(u8, rest[lb + 1..rb], ',');
                while (iter.next()) |tok| {
                    var t = std.mem.trim(u8, tok, " \t");
                    // Strip surrounding quotes if present
                    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0])
                        t = t[1 .. t.len - 1];
                    if (t.len > 0) try x_labels.append(a, Value{ .string = t });
                }
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "y-axis ") or std.mem.startsWith(u8, line, "y-axis\t")) {
            const rest = std.mem.trim(u8, line[7..], " \t");
            // Find --> separator for range
            if (std.mem.indexOf(u8, rest, "-->")) |arrow| {
                const rhs = std.mem.trim(u8, rest[arrow + 3..], " \t");
                y_max = std.fmt.parseFloat(f64, rhs) catch 100;
                // Left of --> may be: "label" min or just min
                var lhs = std.mem.trim(u8, rest[0..arrow], " \t");
                if (lhs.len > 0 and lhs[0] == '"') {
                    // Strip quoted label
                    const qend = std.mem.indexOf(u8, lhs[1..], "\"") orelse lhs.len - 1;
                    lhs = std.mem.trim(u8, lhs[qend + 2..], " \t");
                }
                y_min = std.fmt.parseFloat(f64, lhs) catch 0;
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "bar ") or std.mem.startsWith(u8, line, "bar\t") or
            std.mem.startsWith(u8, line, "line ") or std.mem.startsWith(u8, line, "line\t"))
        {
            const is_line = std.mem.startsWith(u8, line, "line");
            const kind: []const u8 = if (is_line) "line" else "bar";
            const rest = std.mem.trim(u8, line[if (is_line) 5 else 4..], " \t");
            var vals: std.ArrayList(Value) = .empty;
            if (std.mem.indexOf(u8, rest, "[")) |lb| {
                const rb = std.mem.lastIndexOf(u8, rest, "]") orelse rest.len;
                var iter = std.mem.splitScalar(u8, rest[lb + 1..rb], ',');
                while (iter.next()) |tok| {
                    const t = std.mem.trim(u8, tok, " \t");
                    const v = std.fmt.parseFloat(f64, t) catch continue;
                    try vals.append(a, Value{ .number = v });
                }
            }
            if (vals.items.len > 0) {
                var sn = Value.Node{ .type_name = "series", .fields = .{} };
                try sn.fields.put(a, "kind", Value{ .string = kind });
                try sn.fields.put(a, "values", Value{ .list = try vals.toOwnedSlice(a) });
                try series.append(a, Value{ .node = sn });
            }
            continue;
        }
    }

    var root = Value.Node{ .type_name = "xychart", .fields = .{} };
    try root.fields.put(a, "title", Value{ .string = title });
    try root.fields.put(a, "y_min", Value{ .number = y_min });
    try root.fields.put(a, "y_max", Value{ .number = y_max });
    try root.fields.put(a, "x_labels", Value{ .list = try x_labels.toOwnedSlice(a) });
    try root.fields.put(a, "series", Value{ .list = try series.toOwnedSlice(a) });
    return xychart_renderer.render(allocator, Value{ .node = root });
}

// ─── quadrantChart parser ─────────────────────────────────────────────────────

fn renderQuadrantDirect(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var title: []const u8 = "";
    var x_left: []const u8 = "";
    var x_right: []const u8 = "";
    var y_bottom: []const u8 = "";
    var y_top: []const u8 = "";
    var q = [4][]const u8{ "", "", "", "" };
    var points: std.ArrayList(Value) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (first) { first = false; continue; }

        if (std.mem.startsWith(u8, line, "title ") or std.mem.startsWith(u8, line, "title\t")) {
            title = std.mem.trim(u8, line[6..], " \t");
            continue;
        }

        if (std.mem.startsWith(u8, line, "x-axis ") or std.mem.startsWith(u8, line, "x-axis\t")) {
            const rest = std.mem.trim(u8, line[7..], " \t");
            if (std.mem.indexOf(u8, rest, " --> ")) |arrow| {
                x_left = std.mem.trim(u8, rest[0..arrow], " \t");
                x_right = std.mem.trim(u8, rest[arrow + 5..], " \t");
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "y-axis ") or std.mem.startsWith(u8, line, "y-axis\t")) {
            const rest = std.mem.trim(u8, line[7..], " \t");
            if (std.mem.indexOf(u8, rest, " --> ")) |arrow| {
                y_bottom = std.mem.trim(u8, rest[0..arrow], " \t");
                y_top = std.mem.trim(u8, rest[arrow + 5..], " \t");
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "quadrant-")) {
            const num_char = if (line.len > 9) line[9] else '0';
            const num = num_char - '0';
            if (num >= 1 and num <= 4) {
                q[num - 1] = std.mem.trim(u8, line[10..], " \t");
            }
            continue;
        }

        // Point: "Label: [x, y]"
        if (std.mem.indexOf(u8, line, ": [")) |colon_bracket| {
            const lbl = std.mem.trim(u8, line[0..colon_bracket], " \t");
            const bracket_start = colon_bracket + 2;
            const bracket_end = std.mem.indexOf(u8, line[bracket_start..], "]") orelse continue;
            var coord_iter = std.mem.splitScalar(u8, line[bracket_start + 1..bracket_start + bracket_end], ',');
            const xv = std.fmt.parseFloat(f64, std.mem.trim(u8, coord_iter.next() orelse "0", " \t")) catch 0.5;
            const yv = std.fmt.parseFloat(f64, std.mem.trim(u8, coord_iter.next() orelse "0", " \t")) catch 0.5;
            var pn = Value.Node{ .type_name = "point", .fields = .{} };
            try pn.fields.put(a, "label", Value{ .string = lbl });
            try pn.fields.put(a, "x", Value{ .number = xv });
            try pn.fields.put(a, "y", Value{ .number = yv });
            try points.append(a, Value{ .node = pn });
            continue;
        }
    }

    var root = Value.Node{ .type_name = "quadrantChart", .fields = .{} };
    try root.fields.put(a, "title", Value{ .string = title });
    try root.fields.put(a, "x_left", Value{ .string = x_left });
    try root.fields.put(a, "x_right", Value{ .string = x_right });
    try root.fields.put(a, "y_bottom", Value{ .string = y_bottom });
    try root.fields.put(a, "y_top", Value{ .string = y_top });
    try root.fields.put(a, "q1", Value{ .string = q[0] });
    try root.fields.put(a, "q2", Value{ .string = q[1] });
    try root.fields.put(a, "q3", Value{ .string = q[2] });
    try root.fields.put(a, "q4", Value{ .string = q[3] });
    try root.fields.put(a, "points", Value{ .list = try points.toOwnedSlice(a) });
    return quadrant_renderer.render(allocator, Value{ .node = root });
}

// ─── mindmap parser ───────────────────────────────────────────────────────────

fn renderMindmapDirect(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const MmItem = struct { indent: usize, label: []const u8, shape: []const u8 };
    var flat: std.ArrayList(MmItem) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const trimmed_right = std.mem.trimRight(u8, raw, " \t\r");
        if (trimmed_right.len == 0 or
            std.mem.startsWith(u8, std.mem.trim(u8, trimmed_right, " \t"), "%%")) continue;
        if (first) { first = false; continue; }

        var indent: usize = 0;
        for (trimmed_right) |ch| {
            if (ch == ' ') { indent += 1; }
            else if (ch == '\t') { indent += 2; }
            else break;
        }
        const content = std.mem.trim(u8, trimmed_right, " \t");
        if (content.len == 0) continue;
        // Skip ::icon() and ::class() directives — decorators, not nodes
        if (std.mem.startsWith(u8, content, "::")) continue;

        var label: []const u8 = content;
        var shape: []const u8 = "ellipse";
        // Strip optional leading word identifier (e.g. "root" in "root((label))")
        var id_end: usize = 0;
        for (content) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '_') id_end += 1 else break;
        }
        const sc = if (id_end > 0 and id_end < content.len and
            (content[id_end] == '(' or content[id_end] == '[' or content[id_end] == '{'))
            content[id_end..]
        else
            content;
        if (std.mem.startsWith(u8, sc, "((") and std.mem.endsWith(u8, sc, "))")) {
            label = sc[2..sc.len - 2];
            shape = "circle";
        } else if (std.mem.startsWith(u8, sc, "{{") and std.mem.endsWith(u8, sc, "}}")) {
            label = sc[2..sc.len - 2];
            shape = "hexagon";
        } else if (std.mem.startsWith(u8, sc, "[") and std.mem.endsWith(u8, sc, "]")) {
            label = sc[1..sc.len - 1];
            shape = "rect";
        } else if (std.mem.startsWith(u8, sc, "(") and std.mem.endsWith(u8, sc, ")")) {
            label = sc[1..sc.len - 1];
            shape = "rounded";
        }
        // Replace literal \n escape with an actual newline for multi-line rendering
        const label_clean = try std.mem.replaceOwned(u8, a, label, "\\n", "\n");
        try flat.append(a, .{ .indent = indent, .label = label_clean, .shape = shape });
    }

    if (flat.items.len == 0) return mindmap_renderer.render(allocator, Value{ .null = {} });

    // Build Value tree bottom-up using a value stack.
    // Process items in reverse: each node collects children with indent > own indent.
    const VEntry = struct { indent: usize, value: Value };
    var value_stack: std.ArrayList(VEntry) = .empty;

    var i: usize = flat.items.len;
    while (i > 0) {
        i -= 1;
        const item = flat.items[i];
        // Pop children: entries with strictly greater indent
        var children: std.ArrayList(Value) = .empty;
        while (value_stack.items.len > 0 and
               value_stack.items[value_stack.items.len - 1].indent > item.indent)
        {
            const child = value_stack.pop().?;
            try children.append(a, child.value);
        }
        // Children were collected in reverse; reverse to restore order
        std.mem.reverse(Value, children.items);

        var n = Value.Node{ .type_name = "mmnode", .fields = .{} };
        try n.fields.put(a, "label", Value{ .string = item.label });
        try n.fields.put(a, "shape", Value{ .string = item.shape });
        try n.fields.put(a, "children", Value{ .list = try children.toOwnedSlice(a) });
        try value_stack.append(a, .{ .indent = item.indent, .value = Value{ .node = n } });
    }

    const root_value = if (value_stack.items.len > 0)
        value_stack.items[value_stack.items.len - 1].value
    else
        Value{ .null = {} };

    var root_node = Value.Node{ .type_name = "mindmap", .fields = .{} };
    const nodes_list = try a.alloc(Value, 1);
    nodes_list[0] = root_value;
    try root_node.fields.put(a, "nodes", Value{ .list = nodes_list });
    return mindmap_renderer.render(allocator, Value{ .node = root_node });
}

// ─── sankey parser ────────────────────────────────────────────────────────────

fn renderSankeyDirect(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var flows: std.ArrayList(Value) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (first) { first = false; continue; }

        // CSV: from,to,value
        var parts = std.mem.splitScalar(u8, line, ',');
        const from = std.mem.trim(u8, parts.next() orelse continue, " \t");
        const to = std.mem.trim(u8, parts.next() orelse continue, " \t");
        const val_str = std.mem.trim(u8, parts.next() orelse continue, " \t");
        if (from.len == 0 or to.len == 0) continue;
        const val = std.fmt.parseFloat(f64, val_str) catch continue;

        var fn2 = Value.Node{ .type_name = "flow", .fields = .{} };
        try fn2.fields.put(a, "from", Value{ .string = from });
        try fn2.fields.put(a, "to", Value{ .string = to });
        try fn2.fields.put(a, "value", Value{ .number = val });
        try flows.append(a, Value{ .node = fn2 });
    }

    var root = Value.Node{ .type_name = "sankey", .fields = .{} };
    try root.fields.put(a, "flows", Value{ .list = try flows.toOwnedSlice(a) });
    return sankey_renderer.render(allocator, Value{ .node = root });
}

// ─── C4 parser ────────────────────────────────────────────────────────────────

fn renderC4Direct(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var title: []const u8 = "";
    var elements: std.ArrayList(Value) = .empty;
    var relations: std.ArrayList(Value) = .empty;
    var boundaries: std.ArrayList(Value) = .empty;

    // Boundary tracking: stack of (alias, label, members)
    const BStack = struct { alias: []const u8, label: []const u8, members: std.ArrayList([]const u8), is_enterprise: bool };
    var bstack: std.ArrayList(BStack) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%") or
            std.mem.startsWith(u8, line, "//") or
            std.mem.startsWith(u8, line, "UpdateRel") or
            std.mem.startsWith(u8, line, "UpdateElement") or
            std.mem.startsWith(u8, line, "UpdateLayout"))
        {
            continue;
        }
        if (first) { first = false; continue; }

        if (std.mem.startsWith(u8, line, "title ") or std.mem.startsWith(u8, line, "title\t")) {
            title = std.mem.trim(u8, line[6..], " \t");
            continue;
        }

        // Close boundary
        if (std.mem.eql(u8, line, "}")) {
            if (bstack.items.len > 0) {
                const bs = bstack.pop().?;
                var bn = Value.Node{ .type_name = "boundary", .fields = .{} };
                try bn.fields.put(a, "alias", Value{ .string = bs.alias });
                try bn.fields.put(a, "label", Value{ .string = bs.label });
                if (bs.is_enterprise) try bn.fields.put(a, "enterprise", Value{ .string = "1" });
                var ml: std.ArrayList(Value) = .empty;
                for (bs.members.items) |m| try ml.append(a, Value{ .string = m });
                try bn.fields.put(a, "members", Value{ .list = try ml.toOwnedSlice(a) });
                try boundaries.append(a, Value{ .node = bn });
            }
            continue;
        }

        // Boundary open: *_Boundary(alias, "label") {
        if (std.mem.indexOf(u8, line, "_Boundary(") != null or
            std.mem.startsWith(u8, line, "Boundary("))
        {
            const args = extractArgs(line) orelse continue;
            const alias = nextArg(args, 0);
            const lbl = stripQuotes(nextArg(args, 1));
            const is_ent = std.mem.startsWith(u8, line, "Enterprise_Boundary");
            const bs = BStack{ .alias = alias, .label = lbl, .members = .empty, .is_enterprise = is_ent };
            try bstack.append(a, bs);
            continue;
        }

        // Relationship: Rel / BiRel / Rel_D / Rel_U / Rel_L / Rel_R / Rel_Back
        if (std.mem.startsWith(u8, line, "BiRel") or
            (std.mem.startsWith(u8, line, "Rel") and
             (line.len > 3 and (line[3] == '(' or line[3] == '_' or line[3] == ' '))))
        {
            const is_bi = std.mem.startsWith(u8, line, "BiRel");
            const is_back = std.mem.startsWith(u8, line, "Rel_Back");
            const args = extractArgs(line) orelse continue;
            // Rel_Back(from, to, ...) means arrow goes from `to` → `from`
            const raw_from = nextArg(args, 0);
            const raw_to = nextArg(args, 1);
            const actual_from = if (is_back) raw_to else raw_from;
            const actual_to = if (is_back) raw_from else raw_to;
            const lbl = stripQuotes(nextArg(args, 2));
            const tech = stripQuotes(nextArg(args, 3));
            var rn = Value.Node{ .type_name = "relation", .fields = .{} };
            try rn.fields.put(a, "from", Value{ .string = actual_from });
            try rn.fields.put(a, "to", Value{ .string = actual_to });
            try rn.fields.put(a, "label", Value{ .string = lbl });
            try rn.fields.put(a, "tech", Value{ .string = tech });
            if (is_bi) try rn.fields.put(a, "bidirectional", Value{ .string = "1" });
            try relations.append(a, Value{ .node = rn });
            continue;
        }

        // Element macros: Person, System, Container, Component, etc.
        if (parseC4Element(line)) |kv| {
            const kind_str = kv[0];
            const args = extractArgs(line) orelse continue;
            const alias = nextArg(args, 0);
            const lbl = stripQuotes(nextArg(args, 1));
            // For Container/Component: (alias, label, tech, desc)
            // For Person/System:       (alias, label, desc)
            var tech: []const u8 = "";
            var desc: []const u8 = "";
            const n4 = nextArg(args, 3);
            if (n4.len > 0) {
                // 4-arg form: Container(alias, label, tech, desc)
                tech = stripQuotes(nextArg(args, 2));
                desc = stripQuotes(n4);
            } else {
                desc = stripQuotes(nextArg(args, 2));
            }

            var en = Value.Node{ .type_name = "element", .fields = .{} };
            try en.fields.put(a, "alias", Value{ .string = alias });
            try en.fields.put(a, "label", Value{ .string = lbl });
            try en.fields.put(a, "tech", Value{ .string = tech });
            try en.fields.put(a, "desc", Value{ .string = desc });
            try en.fields.put(a, "kind", Value{ .string = kind_str });
            try elements.append(a, Value{ .node = en });

            // Register alias with open boundary
            if (bstack.items.len > 0) {
                try bstack.items[bstack.items.len - 1].members.append(a, alias);
            }
        }
    }

    var root = Value.Node{ .type_name = "c4", .fields = .{} };
    try root.fields.put(a, "title", Value{ .string = title });
    try root.fields.put(a, "elements", Value{ .list = try elements.toOwnedSlice(a) });
    try root.fields.put(a, "relations", Value{ .list = try relations.toOwnedSlice(a) });
    try root.fields.put(a, "boundaries", Value{ .list = try boundaries.toOwnedSlice(a) });
    return c4_renderer.render(allocator, Value{ .node = root });
}

/// Returns (kind_string, true) if `line` starts with a known C4 element macro.
fn parseC4Element(line: []const u8) ?[1][]const u8 {
    const macros = [_]struct { prefix: []const u8, kind: []const u8 }{
        .{ .prefix = "Person_Ext(",       .kind = "person_ext" },
        .{ .prefix = "Person(",           .kind = "person" },
        .{ .prefix = "SystemDb_Ext(",     .kind = "system_db_ext" },
        .{ .prefix = "SystemDb(",         .kind = "system_db" },
        .{ .prefix = "System_Ext(",       .kind = "system_ext" },
        .{ .prefix = "System(",           .kind = "system" },
        .{ .prefix = "ContainerDb_Ext(",  .kind = "container_db_ext" },
        .{ .prefix = "ContainerDb(",      .kind = "container_db" },
        .{ .prefix = "Container_Ext(",    .kind = "container_ext" },
        .{ .prefix = "Container(",        .kind = "container" },
        .{ .prefix = "ComponentDb_Ext(",  .kind = "component_db_ext" },
        .{ .prefix = "ComponentDb(",      .kind = "component_db" },
        .{ .prefix = "Component_Ext(",    .kind = "component_ext" },
        .{ .prefix = "Component(",        .kind = "component" },
        .{ .prefix = "Node_Ext(",         .kind = "node_ext" },
        .{ .prefix = "Node(",             .kind = "node" },
        .{ .prefix = "Deployment_Node(",  .kind = "node" },
    };
    for (macros) |m| {
        if (std.mem.startsWith(u8, line, m.prefix)) return .{m.kind};
    }
    return null;
}

/// Extract everything inside the outermost parentheses of a call.
fn extractArgs(line: []const u8) ?[]const u8 {
    const open = std.mem.indexOf(u8, line, "(") orelse return null;
    const close = std.mem.lastIndexOf(u8, line, ")") orelse return null;
    if (close <= open) return null;
    return line[open + 1..close];
}

/// Get the Nth comma-separated argument (0-based), trimmed. Returns "" if not found.
fn nextArg(args: []const u8, n: usize) []const u8 {
    var iter = std.mem.splitScalar(u8, args, ',');
    var idx: usize = 0;
    while (iter.next()) |tok| {
        if (idx == n) return std.mem.trim(u8, tok, " \t");
        idx += 1;
    }
    return "";
}

fn stripQuotes(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') return t[1..t.len - 1];
    return t;
}

fn renderUnknown(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const writer_mod = @import("svg/writer.zig");
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

test "detect and render classDiagram" {
    const input =
        \\classDiagram
        \\    class Animal {
        \\        +String name
        \\        +makeSound() void
        \\    }
        \\    class Duck
        \\    Animal <|-- Duck
        \\
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "Animal") != null);
}

test "detect and render stateDiagram" {
    const input =
        \\stateDiagram-v2
        \\    [*] --> Idle
        \\    Idle --> Running : start
        \\    Running --> Idle : stop
        \\
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "Idle") != null);
}

test "detect and render erDiagram" {
    const input =
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : "places"
        \\    CUSTOMER {
        \\        string name PK
        \\    }
        \\
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "CUSTOMER") != null);
}

test "detect and render gantt" {
    const input =
        \\gantt
        \\    title My Project
        \\    section Phase 1
        \\        Task A : 2d
        \\        Task B : crit, 3d
        \\
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "Task A") != null);
}

test "detect and render timeline" {
    const input =
        \\timeline
        \\    title Tech History
        \\    2000 : Y2K survived
        \\    2007 : iPhone
        \\    2020 : COVID remote work
        \\
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "iPhone") != null);
}

test "detect and render xychart" {
    const input =
        \\xychart-beta
        \\    title "Revenue"
        \\    x-axis [Q1, Q2, Q3, Q4]
        \\    y-axis 0 --> 10000
        \\    bar [2000, 4000, 6000, 8000]
        \\    line [3000, 3500, 5000, 7000]
        \\
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
}

test "detect and render quadrantChart" {
    const input =
        \\quadrantChart
        \\    title Effort vs Impact
        \\    x-axis Low Effort --> High Effort
        \\    y-axis Low Impact --> High Impact
        \\    quadrant-1 Quick Wins
        \\    Campaign A: [0.3, 0.7]
        \\    Campaign B: [0.8, 0.4]
        \\
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "<circle") != null);
}

test "detect and render mindmap" {
    const input =
        \\mindmap
        \\  root((Main Topic))
        \\    Branch A
        \\      Leaf A1
        \\    Branch B
        \\
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "Main Topic") != null);
}

test "detect and render sankey" {
    const input =
        \\sankey-beta
        \\A,B,40
        \\B,C,30
        \\A,C,10
        \\
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "<path") != null);
}

test "detect and render C4Context" {
    const input =
        \\C4Context
        \\  title System Context
        \\  Person(user, "User", "A person using the system")
        \\  System(webapp, "Web App", "The main application")
        \\  System_Ext(email, "Email System", "Sends notifications")
        \\  Rel(user, webapp, "Uses")
        \\  Rel(webapp, email, "Sends email", "SMTP")
        \\
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "Web App") != null);
}

// ─── Flowchart feature tests ──────────────────────────────────────────────────

test "flowchart LR direction" {
    const input = "graph LR\nStart --> Process --> End\n";
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Process") != null);
}

test "flowchart diamond and circle shapes" {
    const input =
        \\graph TD
        \\A{Decision}
        \\B((Circle))
        \\A --> B
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<polygon") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<circle") != null);
}

test "flowchart edge label and dotted style" {
    const input =
        \\graph TD
        \\A --> |yes| B
        \\B -.-> C
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "stroke-dasharray") != null);
}

test "flowchart multi-node chain" {
    const input = "graph TD\nA[Start] --> B[Middle] --> C[End]\n";
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Start") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Middle") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "End") != null);
}

test "flowchart BT direction" {
    const input = "graph BT\nA --> B\n";
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
}

test "flowchart bezier path connector" {
    // Bezier routing: edges use <path> with cubic curve data
    const input = "graph TD\nA --> B\nB --> C\n";
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<path") != null);
    // Cubic bezier uses 'C' command
    try std.testing.expect(std.mem.indexOf(u8, svg, " C ") != null);
}

test "flowchart cylinder hexagon subroutine shapes" {
    const input =
        \\graph TD
        \\A[(Database)]
        \\B{{Hexagon}}
        \\C[[Subroutine]]
        \\A --> B --> C
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    // Cylinder: ellipse element
    try std.testing.expect(std.mem.indexOf(u8, svg, "<ellipse") != null);
    // Hexagon: polygon with 6 points
    try std.testing.expect(std.mem.indexOf(u8, svg, "<polygon") != null);
    // Subroutine: rect + inner vertical lines
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Database") != null);
}

test "flowchart stadium and round shapes" {
    const input =
        \\graph LR
        \\A([Stadium])
        \\B(Round)
        \\A --> B
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Stadium") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Round") != null);
}

test "flowchart -- label --> edge syntax" {
    const input =
        \\graph TD
        \\A -- yes --> B
        \\A -- no --> C
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "no") != null);
}

// ─── Sequence feature tests ───────────────────────────────────────────────────

test "sequence self-message" {
    const input =
        \\sequenceDiagram
        \\Alice->>Alice: Think
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Think") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<line") != null);
}

test "sequence dotted return arrow" {
    const input =
        \\sequenceDiagram
        \\Alice->>Bob: request
        \\Bob-->>Alice: response
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "request") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "stroke-dasharray") != null);
}

test "sequence loop block" {
    const input =
        \\sequenceDiagram
        \\loop Retry
        \\Alice->>Bob: ping
        \\end
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Retry") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
}

test "sequence alt block" {
    const input =
        \\sequenceDiagram
        \\alt success
        \\Alice->>Bob: ok
        \\end
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "success") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
}

test "sequence participants declared explicitly" {
    const input =
        \\sequenceDiagram
        \\participant Server
        \\participant Client
        \\Server->>Client: data
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Server") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Client") != null);
}

test "sequence opt block rendered" {
    const input =
        \\sequenceDiagram
        \\Alice->>Bob: request
        \\opt retry
        \\Bob->>Bob: retry
        \\end
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "retry") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
}

test "sequence par block rendered" {
    const input =
        \\sequenceDiagram
        \\par send emails
        \\Alice->>Bob: email1
        \\and send notifications
        \\Alice->>Carol: email2
        \\end
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "send emails") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
}

test "sequence note rendered" {
    const input =
        \\sequenceDiagram
        \\Alice->>Bob: hello
        \\Note right of Bob: thinking
        \\Bob-->>Alice: world
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "world") != null);
    // Note box rendered
    try std.testing.expect(std.mem.indexOf(u8, svg, "thinking") != null);
}

test "sequence note over two actors" {
    const input =
        \\sequenceDiagram
        \\Alice->>Bob: request
        \\Note over Alice,Bob: processing
        \\Bob-->>Alice: response
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "processing") != null);
}

test "sequence activation box" {
    const input =
        \\sequenceDiagram
        \\Alice->>Bob: request
        \\activate Bob
        \\Bob-->>Alice: response
        \\deactivate Bob
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "request") != null);
    // Activation bar is a narrow rect
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
}

test "sequence autonumber" {
    const input =
        \\sequenceDiagram
        \\autonumber
        \\Alice->>Bob: hello
        \\Bob-->>Alice: world
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "1.") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "2.") != null);
}

// ─── ClassDiagram feature tests ───────────────────────────────────────────────

test "classDiagram inheritance terminator" {
    const input =
        \\classDiagram
        \\class Vehicle
        \\class Car
        \\Vehicle <|-- Car
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Vehicle") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<polygon") != null);
}

test "classDiagram composition terminator" {
    const input =
        \\classDiagram
        \\class Engine
        \\class Car
        \\Car *-- Engine
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<polygon") != null);
}

test "classDiagram visibility modifiers rendered" {
    const input =
        \\classDiagram
        \\class BankAccount {
        \\    +String owner
        \\    -float balance
        \\    +deposit(amount) void
        \\}
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "BankAccount") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "owner") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "balance") != null);
}

test "classDiagram dependency dashed line" {
    const input =
        \\classDiagram
        \\class Logger
        \\class Service
        \\Service ..> Logger
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "stroke-dasharray") != null);
}

test "classDiagram relation label" {
    const input =
        \\classDiagram
        \\class Driver
        \\class Car
        \\Driver --> Car : drives
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "drives") != null);
}

test "classDiagram stereotype inline" {
    const input =
        \\classDiagram
        \\class Animal <<interface>> {
        \\  +makeSound() String
        \\}
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Animal") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "interface") != null);
}

test "classDiagram stereotype block" {
    const input =
        \\classDiagram
        \\class Shape {
        \\  <<abstract>>
        \\  +draw() void
        \\}
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "abstract") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "draw") != null);
}

test "classDiagram generic type notation" {
    const input =
        \\classDiagram
        \\class Container~T~ {
        \\  +items List~T~
        \\  +add(item T) void
        \\}
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    // Generic types rendered as <T>
    try std.testing.expect(std.mem.indexOf(u8, svg, "List") != null);
}

// ─── StateDiagram feature tests ───────────────────────────────────────────────

test "stateDiagram entry and exit star" {
    const input =
        \\stateDiagram-v2
        \\[*] --> Active
        \\Active --> [*]
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<circle") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Active") != null);
}

test "stateDiagram transition labels" {
    const input =
        \\stateDiagram-v2
        \\Idle --> Running : start
        \\Running --> Idle : stop
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "start") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "stop") != null);
}

test "stateDiagram multiple states" {
    const input =
        \\stateDiagram-v2
        \\[*] --> Idle
        \\Idle --> Processing
        \\Processing --> Done
        \\Done --> [*]
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Idle") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Processing") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Done") != null);
}

test "stateDiagram compound state label" {
    const input =
        \\stateDiagram-v2
        \\state "Running State" as Running {
        \\    [*] --> A
        \\    A --> B
        \\}
        \\[*] --> Running
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Running State") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Running") != null);
}

// ─── ER Diagram feature tests ──────────────────────────────────────────────────

test "erDiagram one-to-many relation" {
    const input =
        \\erDiagram
        \\CUSTOMER ||--o{ ORDER : "places"
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "CUSTOMER") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "ORDER") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "places") != null);
}

test "erDiagram zero-or-one cardinality circle" {
    const input =
        \\erDiagram
        \\PERSON o|--|| PASSPORT : "has"
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<circle") != null);
}

test "erDiagram attribute PK marker" {
    const input =
        \\erDiagram
        \\PRODUCT {
        \\    int id PK
        \\    string name
        \\}
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "PRODUCT") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "PK") != null);
}

test "erDiagram dashed relationship line" {
    const input =
        \\erDiagram
        \\EMPLOYEE }o..o{ PROJECT : "works on"
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "stroke-dasharray") != null);
}

// ─── Gantt feature tests ───────────────────────────────────────────────────────

test "gantt crit task color" {
    const input =
        \\gantt
        \\title Sprint
        \\section Dev
        \\Critical path : crit, 3d
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "#e55039") != null);
}

test "gantt done task color" {
    const input =
        \\gantt
        \\title Project
        \\section Phase 1
        \\Finished task : done, 2d
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "#95a5a6") != null);
}

test "gantt multiple sections" {
    const input =
        \\gantt
        \\title Roadmap
        \\section Alpha
        \\Feature A : 2d
        \\section Beta
        \\Feature B : 3d
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Beta") != null);
}

test "gantt title in SVG" {
    const input =
        \\gantt
        \\title My Timeline
        \\section Work
        \\Task : 1d
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "My Timeline") != null);
}

test "gantt milestone diamond rendered" {
    const input =
        \\gantt
        \\title Release
        \\section Launch
        \\Deploy : milestone, 0d
        \\Verify : 1d
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<polygon") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Deploy") != null);
}

test "flowchart subgraph background box" {
    const input =
        \\graph TD
        \\subgraph Service Layer
        \\A[Auth] --> B[API]
        \\end
        \\B --> C[DB]
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Service Layer") != null);
}

// ─── block-beta tests ─────────────────────────────────────────────────────────

test "block-beta basic grid" {
    const input =
        \\block-beta
        \\columns 3
        \\A["Block A"] B["Block B"] C["Block C"]
        \\A --> B
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Block A") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Block B") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<line") != null);
}

test "block-beta bare ids" {
    const input =
        \\block-beta
        \\columns 2
        \\A B
        \\A --> B
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
}

// ─── requirementDiagram tests ─────────────────────────────────────────────────

test "requirementDiagram basic" {
    const input =
        \\requirementDiagram
        \\requirement req1 {
        \\id: 1
        \\text: "Shall do X"
        \\risk: high
        \\verifyMethod: test
        \\}
        \\element sys1 {
        \\type: simulation
        \\}
        \\sys1 - satisfies -> req1
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "req1") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "satisfies") != null);
}

// ─── kanban tests ─────────────────────────────────────────────────────────────

test "kanban basic board" {
    const input =
        \\kanban
        \\todo
        \\  id1["Task A"]
        \\  id2["Task B"]
        \\in-progress
        \\  id3["Task C"]
        \\done
        \\  id4["Task D"]
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "todo") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Task A") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "done") != null);
}
