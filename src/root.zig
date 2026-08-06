//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
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
/// The type of diagram identified in a mermaid source string.
/// Re-exported from `detect.zig` for library consumers.
pub const DiagramType = detect.DiagramType;
const Value = @import("diagram/value.zig").Value;

const langium_ast = @import("langium/ast.zig");
const langium_parser = @import("langium/parser.zig");
const langium_runtime = @import("langium/runtime.zig");

// Hand-written parsers, one per diagram type (see src/parsers/, #39). Each
// exposes `render(allocator, text) ![]const u8` and owns its Value → SVG
// renderer import; root.zig is just detection, dispatch, and theme plumbing.
const block_parser = @import("parsers/block.zig");
const c4_parser = @import("parsers/c4.zig");
const class_parser = @import("parsers/class.zig");
const er_parser = @import("parsers/er.zig");
const flowchart_parser = @import("parsers/flowchart.zig");
const gantt_parser = @import("parsers/gantt.zig");
const kanban_parser = @import("parsers/kanban.zig");
const mindmap_parser = @import("parsers/mindmap.zig");
const quadrant_parser = @import("parsers/quadrant.zig");
const requirement_parser = @import("parsers/requirement.zig");
const sankey_parser = @import("parsers/sankey.zig");
const sequence_parser = @import("parsers/sequence.zig");
const state_parser = @import("parsers/state.zig");
const timeline_parser = @import("parsers/timeline.zig");
const xychart_parser = @import("parsers/xychart.zig");

// pie and gitgraph go through the langium grammar runtime instead of a
// hand-written parser, so their Value → SVG renderers are dispatched here.
const gitgraph_renderer = @import("renderers/gitgraph.zig");
const pie_renderer = @import("renderers/pie.zig");
const theme = @import("svg/theme.zig");

// Embedded grammar files (compiled into the binary)
const common_langium = @embedFile("grammars/common.langium");
const pie_langium = @embedFile("grammars/pie.langium");
const git_langium = @embedFile("grammars/gitGraph.langium");

// ── Grammar cache ─────────────────────────────────────────────────────────────
// Grammars are parsed from embedded source on first use and kept for the
// process lifetime.  All lazy initialisation happens under `grammar_lock` so
// concurrent first calls (e.g. document pipelines rendering diagrams from
// multiple threads) cannot race on `grammar_arena` or the cached_* slots.
// A spinlock rather than a mutex because pozeiden has no std.Io context to
// lock with; the critical section is a one-time grammar parse and every later
// call holds it only for a null-check.  On single-threaded targets (WASM) the
// atomics lower to plain loads/stores.

const LangiumCache = struct {
    merged: *const langium_ast.MergedGrammar,
    compiled: []const langium_runtime.CompiledTerminal,
};

var grammar_lock: std.atomic.Value(bool) = .init(false);
var grammar_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var cached_common_grammar: ?*const langium_ast.Grammar = null;
var cached_pie: ?LangiumCache = null;
var cached_git: ?LangiumCache = null;

fn grammarLockAcquire() void {
    while (grammar_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn grammarLockRelease() void {
    grammar_lock.store(false, .release);
}

/// Caller must hold `grammar_lock`.
fn getCommonGrammar() !*const langium_ast.Grammar {
    if (cached_common_grammar) |g| return g;
    const ga = grammar_arena.allocator();
    const g = try ga.create(langium_ast.Grammar);
    g.* = langium_parser.parse(ga, common_langium) catch return error.ParseError;
    cached_common_grammar = g;
    return g;
}

fn buildLangiumCache(primary_src: []const u8) !LangiumCache {
    const ga = grammar_arena.allocator();
    const common = try getCommonGrammar();
    const primary = try ga.create(langium_ast.Grammar);
    primary.* = langium_parser.parse(ga, primary_src) catch return error.ParseError;
    const imports = try ga.alloc(*const langium_ast.Grammar, 1);
    imports[0] = common;
    const merged = try ga.create(langium_ast.MergedGrammar);
    merged.* = .{ .primary = primary, .imports = imports, .allocator = ga };
    const compiled = try langium_runtime.compileTerminals(ga, merged);
    return .{ .merged = merged, .compiled = compiled };
}

fn getPieCache() !LangiumCache {
    grammarLockAcquire();
    defer grammarLockRelease();
    if (cached_pie) |c| return c;
    cached_pie = try buildLangiumCache(pie_langium);
    return cached_pie.?;
}

fn getGitCache() !LangiumCache {
    grammarLockAcquire();
    defer grammarLockRelease();
    if (cached_git) |c| return c;
    cached_git = try buildLangiumCache(git_langium);
    return cached_git.?;
}

/// Detect the diagram type from the first non-blank, non-comment line of
/// `mermaid_text`.  Returns `.unknown` if no recognised keyword is found.
/// Useful when the caller needs to filter or route before calling `render`.
pub fn detectDiagramType(mermaid_text: []const u8) DiagramType {
    return detect.detect(mermaid_text);
}

/// Errors that `render` can return in addition to `std.mem.Allocator.Error`.
pub const RenderError = error{
    /// The diagram type could not be identified from the first non-blank line.
    UnknownDiagramType,
    /// A grammar file embedded in the binary failed to parse (should not occur
    /// with an unmodified build).
    ParseError,
    /// The input exceeded `max_input_bytes`.  Guards against resource-exhaustion
    /// from untrusted input on the library and C-API paths (which are otherwise
    /// unbounded — the CLI/WASM wrappers impose their own byte limits).
    InputTooLarge,
    /// The diagram declared more nodes/edges than a renderer will lay out (see
    /// `svg/layout.zig` limits).  Guards against super-linear layout cost.
    DiagramTooLarge,
    /// Memory allocation failed.
    OutOfMemory,
};

/// Maximum accepted input size for `render`/`renderWithOptions` (and thus the
/// C API).  4 MiB comfortably exceeds any real diagram while bounding the work
/// an embedder can be forced to do by untrusted input.  Inputs larger than this
/// yield `error.InputTooLarge`.
pub const max_input_bytes: usize = 4 * 1024 * 1024;

/// Render `mermaid_text` to a self-contained SVG string.
///
/// The diagram type is detected automatically from the first non-blank,
/// non-comment line.  Seventeen diagram types are supported; unrecognised
/// input produces a minimal fallback SVG rather than an error.
///
/// The caller owns the returned slice and must free it with `allocator`.
pub fn render(allocator: std.mem.Allocator, mermaid_text: []const u8) ![]const u8 {
    // Bound untrusted input up front so every entry point (library, C API,
    // renderWithOptions) is protected, not just the CLI/WASM wrappers.
    if (mermaid_text.len > max_input_bytes) return error.InputTooLarge;

    // Strip a leading YAML front-matter block once, before dispatch, so its
    // body lines (`title:`, `config:` …) never reach a parser — the parsers
    // would otherwise treat them as diagram content (e.g. flowchart nodes).
    const body = detect.stripFrontmatter(mermaid_text);

    // Apply %%{init: {...}}%% directive overrides for this render call.
    const applied_init = applyInitDirective(body);
    defer if (applied_init) theme.resetToDefaults();

    const diagram_type = detect.detect(body);

    switch (diagram_type) {
        .pie => return renderLangium(allocator, body, try getPieCache(), pie_renderer.render),
        .gitgraph => return renderLangium(allocator, body, try getGitCache(), gitgraph_renderer.render),
        .flowchart => return flowchart_parser.render(allocator, body),
        .sequence => return sequence_parser.render(allocator, body),
        .class => return class_parser.render(allocator, body),
        .state => return state_parser.render(allocator, body),
        .er => return er_parser.render(allocator, body),
        .gantt => return gantt_parser.render(allocator, body),
        .timeline => return timeline_parser.render(allocator, body),
        .xychart => return xychart_parser.render(allocator, body),
        .quadrant => return quadrant_parser.render(allocator, body),
        .mindmap => return mindmap_parser.render(allocator, body),
        .sankey => return sankey_parser.render(allocator, body),
        .c4 => return c4_parser.render(allocator, body),
        .block => return block_parser.render(allocator, body),
        .requirement => return requirement_parser.render(allocator, body),
        .kanban => return kanban_parser.render(allocator, body),
        .unknown => {
            // Emit a simple fallback SVG for unrecognised diagram types
            return renderUnknown(allocator, body);
        },
    }
}

/// Options for `renderWithOptions`.
pub const RenderOptions = struct {
    /// Runtime theme overrides.  Unset fields use the mermaid default values.
    theme_override: theme.ThemeOverride = .{},

    /// When `true`, return `error.UnknownDiagramType` for unrecognised input
    /// instead of generating a fallback SVG.  Useful for pipeline callers that
    /// need to distinguish a real render from a no-op.
    strict: bool = false,

    /// If non-zero, scale the output SVG so its width does not exceed this
    /// value (in SVG user units / pixels).  Height scales proportionally.
    /// Applied after `max_height`.
    max_width: u32 = 0,

    /// If non-zero, scale the output SVG so its height does not exceed this
    /// value.  Width scales proportionally.  `max_width` takes precedence when
    /// both constraints would apply simultaneously.
    max_height: u32 = 0,

    /// Uniform scale factor applied to the SVG `viewBox` (e.g. `0.5` = 50%).
    /// Ignored when `max_width` or `max_height` are non-zero.
    scale: f32 = 1.0,
};

/// Like `render`, but accepts a `RenderOptions` to customise the output.
/// Theme overrides are applied for the duration of the call and reset
/// automatically when it returns (including on error).
pub fn renderWithOptions(
    allocator: std.mem.Allocator,
    mermaid_text: []const u8,
    options: RenderOptions,
) ![]const u8 {
    if (options.strict and detect.detect(mermaid_text) == .unknown)
        return error.UnknownDiagramType;
    theme.applyOverride(options.theme_override);
    defer theme.resetToDefaults();
    const svg = try render(allocator, mermaid_text);

    const needs_scale = options.max_width != 0 or options.max_height != 0 or options.scale != 1.0;
    if (!needs_scale) return svg;

    // Post-process: patch width/height/viewBox on the root <svg> element.
    const scaled = scaleSvg(allocator, svg, options) catch return svg;
    allocator.free(svg);
    return scaled;
}

/// Parse the `width` and `height` attributes from the root `<svg ...>` element
/// and rewrite them (plus the `viewBox`) to apply dimension constraints.
fn scaleSvg(
    allocator: std.mem.Allocator,
    svg: []const u8,
    options: RenderOptions,
) ![]const u8 {
    // Locate the root <svg ...> opening tag.
    const svg_tag_start = std.mem.indexOf(u8, svg, "<svg ") orelse return error.NotSvg;
    const svg_tag_end = std.mem.indexOfScalarPos(u8, svg, svg_tag_start, '>') orelse return error.NotSvg;
    const header = svg[svg_tag_start .. svg_tag_end + 1];

    // Extract width and height attribute values (integers).
    const orig_w = parseSvgDimAttr(header, "width") orelse return error.NoDimensions;
    const orig_h = parseSvgDimAttr(header, "height") orelse return error.NoDimensions;
    if (orig_w == 0 or orig_h == 0) return error.NoDimensions;

    // Compute the effective scale factor.
    var s: f32 = if (options.scale != 1.0) options.scale else 1.0;

    if (options.max_width != 0 or options.max_height != 0) {
        var sw: f32 = 1.0;
        var sh: f32 = 1.0;
        if (options.max_width != 0) {
            sw = @as(f32, @floatFromInt(options.max_width)) / @as(f32, @floatFromInt(orig_w));
        }
        if (options.max_height != 0) {
            sh = @as(f32, @floatFromInt(options.max_height)) / @as(f32, @floatFromInt(orig_h));
        }
        // Use the smaller of the two to satisfy both constraints simultaneously.
        s = @min(sw, sh);
        // Never upscale via max_* constraints; only shrink.
        if (s > 1.0) s = 1.0;
    }

    if (s == 1.0) return allocator.dupe(u8, svg);

    const new_w: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(orig_w)) * s));
    const new_h: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(orig_h)) * s));

    // Build a replacement <svg ...> tag keeping the original viewBox but
    // replacing width and height so the SVG scales to the requested size.
    // viewBox stays as "0 0 orig_w orig_h" to preserve all content.
    var new_header_buf: [256]u8 = undefined;
    const new_header = try std.fmt.bufPrint(&new_header_buf, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 {d} {d}\">", .{ new_w, new_h, orig_w, orig_h });

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, svg[0..svg_tag_start]);
    try out.appendSlice(allocator, new_header);
    try out.appendSlice(allocator, svg[svg_tag_end + 1 ..]);
    return out.toOwnedSlice(allocator);
}

/// Parse a numeric SVG attribute like `width="640"` from the tag string.
/// Internal helper, `pub` only so the scale/clamp tests in render_test.zig can
/// assert against the same parser `scaleSvg` uses. Not part of the public API.
pub fn parseSvgDimAttr(tag: []const u8, attr: []const u8) ?u32 {
    const needle_len = attr.len + 2; // attr + '="'
    var i: usize = 0;
    while (i + needle_len < tag.len) : (i += 1) {
        if (!std.mem.eql(u8, tag[i .. i + attr.len], attr)) continue;
        const after = i + attr.len;
        if (tag[after] != '=') continue;
        if (tag[after + 1] != '"') continue;
        const v_start = after + 2;
        var v_end = v_start;
        while (v_end < tag.len and tag[v_end] != '"') v_end += 1;
        return std.fmt.parseInt(u32, tag[v_start..v_end], 10) catch null;
    }
    return null;
}

fn renderLangium(
    allocator: std.mem.Allocator,
    input: []const u8,
    cache: LangiumCache,
    renderer: fn (std.mem.Allocator, Value) anyerror![]const u8,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Run the Langium runtime to produce a Value AST (grammar already compiled)
    var runtime = langium_runtime.Runtime.initPrecompiled(a, cache.merged, cache.compiled);
    const value = runtime.run(input) catch {
        return renderer(allocator, Value{ .null = {} });
    };

    // Render to SVG; result must be allocated with the caller's allocator
    return renderer(allocator, value);
}


/// Scan `text` for a `%%{init: {...}}%%` directive and apply any theme overrides
/// found within it.  Supports both single-quoted and double-quoted JSON.
/// Handles `theme` (named preset) and `themeVariables` (individual color keys).
/// Returns `true` if an init directive was found and applied.
fn applyInitDirective(text: []const u8) bool {
    const marker = "%%{init";
    const start = std.mem.indexOf(u8, text, marker) orelse return false;
    const colon = std.mem.indexOfScalarPos(u8, text, start + marker.len, ':') orelse return false;
    const end_marker = "}%%";
    const end = std.mem.indexOfPos(u8, text, colon, end_marker) orelse return false;
    // json_src is everything between the ':' and the closing '}%%'
    const json_src = std.mem.trim(u8, text[colon + 1 .. end + 1], " \t\n\r");

    var ov = theme.ThemeOverride{};

    // Extract named theme preset
    if (jsonStringValue(json_src, "theme")) |t| {
        if (std.mem.eql(u8, t, "dark")) {
            ov.background = "#1a1a2e";
            ov.text_color = "#e0e0e0";
            ov.node_fill = "#16213e";
            ov.node_stroke = "#0f3460";
            ov.edge_color = "#aaaaaa";
        } else if (std.mem.eql(u8, t, "forest")) {
            ov.background = "#f8fff8";
            ov.node_fill = "#d5e8d4";
            ov.node_stroke = "#82b366";
        } else if (std.mem.eql(u8, t, "neutral")) {
            ov.background = "#f5f5f5";
            ov.node_fill = "#e8e8e8";
            ov.node_stroke = "#888888";
            ov.text_color = "#333333";
        } // "default"/"base" → no override needed
    }

    // Extract themeVariables block — find its '{' and '}' and scan within.
    if (std.mem.indexOf(u8, json_src, "themeVariables")) |tv_pos| {
        const brace = std.mem.indexOfScalarPos(u8, json_src, tv_pos, '{') orelse 0;
        const close = std.mem.indexOfScalarPos(u8, json_src, brace, '}') orelse json_src.len;
        const vars = json_src[brace .. close + 1];
        if (jsonStringValue(vars, "primaryColor")) |v| {
            ov.node_fill = v;
        }
        if (jsonStringValue(vars, "primaryTextColor")) |v| {
            ov.text_color = v;
        }
        if (jsonStringValue(vars, "primaryBorderColor")) |v| {
            ov.node_stroke = v;
        }
        if (jsonStringValue(vars, "lineColor")) |v| {
            ov.edge_color = v;
        }
        if (jsonStringValue(vars, "background")) |v| {
            ov.background = v;
        }
        if (jsonStringValue(vars, "mainBkg")) |v| {
            ov.background = v;
        }
        if (jsonStringValue(vars, "fontFamily")) |v| {
            ov.font_family = v;
        }
    }

    theme.applyOverride(ov);
    return true;
}

/// Extract a JSON string value for `key` from a JSON-like object string.
/// Handles both single-quoted and double-quoted strings.
fn jsonStringValue(json: []const u8, key: []const u8) ?[]const u8 {
    // Search for key as a quoted string
    var i: usize = 0;
    while (i < json.len) {
        // Find a quote character
        const q_pos = std.mem.indexOfAnyPos(u8, json, i, "\"'") orelse break;
        const quote = json[q_pos];
        // Check if this is our key
        const key_end = q_pos + 1 + key.len;
        if (key_end < json.len and
            std.mem.eql(u8, json[q_pos + 1 .. key_end], key) and
            json[key_end] == quote)
        {
            // Skip past key, optional whitespace, colon, optional whitespace
            var j = key_end + 1;
            while (j < json.len and (json[j] == ' ' or json[j] == '\t')) j += 1;
            if (j < json.len and json[j] == ':') j += 1;
            while (j < json.len and (json[j] == ' ' or json[j] == '\t')) j += 1;
            if (j < json.len and (json[j] == '"' or json[j] == '\'')) {
                const vq = json[j];
                j += 1;
                const v_start = j;
                while (j < json.len and json[j] != vq) j += 1;
                return json[v_start..j];
            }
        }
        i = q_pos + 1;
    }
    return null;
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


test {
    // Pull the end-to-end and security suites into `zig build test`. Both
    // files import root.zig back for the public API; the cycle is fine.
    _ = @import("render_test.zig");
    _ = @import("security_test.zig");
}
