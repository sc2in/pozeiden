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
const parse_util = @import("parse_util.zig");

/// Internal XML well-formedness checker, `pub` only so the fuzz oracle and
/// the golden-file suite can assert that every successful render parses.
/// Not part of the public API.
pub const wellformed = @import("svg/wellformed.zig");

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
    /// The input exceeded `max_input_bytes` (or the per-call
    /// `RenderOptions.max_input_bytes`).  Guards against resource-exhaustion
    /// from untrusted input on the library and C-API paths (which are otherwise
    /// unbounded — the CLI/WASM wrappers impose their own byte limits).
    InputTooLarge,
    /// The diagram declared more nodes/edges/subgraphs than a renderer will
    /// lay out (see `svg/layout.zig` limits).  Guards against excessive
    /// memory and output size.
    DiagramTooLarge,
    /// A recursive structure (mindmap children) nested deeper than
    /// `renderers/mindmap.zig`'s `max_nesting_depth`.  Guards against stack
    /// exhaustion from untrusted input, particularly on WASM's fixed stack.
    NestingTooDeep,
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
/// Ownership contract: the returned slice is always freshly allocated with
/// the passed `allocator` (never static memory) and the caller frees it with
/// that same allocator.
///
/// This two-argument signature is a stable ABI: it is zigmark's
/// `MermaidRendererFn` plugin type, passed by address into its HTML/Typst
/// renderers.  It is safe to call concurrently from multiple threads.
pub fn render(allocator: std.mem.Allocator, mermaid_text: []const u8) ![]const u8 {
    return renderImpl(allocator, mermaid_text, max_input_bytes);
}

fn renderImpl(allocator: std.mem.Allocator, mermaid_text: []const u8, input_limit: usize) ![]const u8 {
    // Bound untrusted input up front so every entry point (library, C API,
    // renderWithOptions) is protected, not just the CLI/WASM wrappers.
    // A limit of 0 disables the check (renderWithOptions opt-in only).
    if (input_limit != 0 and mermaid_text.len > input_limit) return error.InputTooLarge;

    var pre = try preprocess(allocator, mermaid_text);
    defer pre.deinit(allocator);
    return renderPreprocessed(allocator, &pre);
}

/// Diagram source with front matter and accessibility directives factored
/// out before dispatch: parsers would otherwise treat `title:`/`accTitle:`
/// lines as diagram content (e.g. flowchart nodes).
const Preprocessed = struct {
    /// Diagram text with front matter and acc lines removed.  Points into the
    /// original input unless acc-line removal forced `owned_body`.
    body: []const u8,
    owned_body: ?[]u8 = null,
    /// Front-matter `title:` value (owned).
    title: ?[]u8 = null,
    /// `accTitle:` value (owned).
    acc_title: ?[]u8 = null,
    /// `accDescr:` / `accDescr { … }` value (owned).
    acc_descr: ?[]u8 = null,

    fn deinit(self: *const Preprocessed, allocator: std.mem.Allocator) void {
        if (self.owned_body) |b| allocator.free(b);
        if (self.title) |t| allocator.free(t);
        if (self.acc_title) |t| allocator.free(t);
        if (self.acc_descr) |d| allocator.free(d);
    }
};

fn preprocess(allocator: std.mem.Allocator, text: []const u8) !Preprocessed {
    const fm = detect.splitFrontmatter(text);
    var result = Preprocessed{ .body = fm.body };
    errdefer result.deinit(allocator);

    // Front-matter `title:` — the first one wins, quotes stripped.
    var fm_lines = std.mem.splitScalar(u8, fm.block, '\n');
    while (fm_lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "title:")) continue;
        const v = parse_util.stripQuotes(line["title:".len..]);
        if (v.len > 0) result.title = try allocator.dupe(u8, v);
        break;
    }

    // Fast path: no accessibility directives anywhere → zero-copy body.
    if (std.mem.indexOf(u8, fm.body, "accTitle") == null and
        std.mem.indexOf(u8, fm.body, "accDescr") == null)
        return result;

    // Slow path: rebuild the body without the acc lines, capturing their
    // values.  Later directives overwrite earlier ones (mermaid semantics).
    var cleaned: std.ArrayList(u8) = .empty;
    errdefer cleaned.deinit(allocator);
    var descr_buf: std.ArrayList(u8) = .empty;
    defer descr_buf.deinit(allocator);

    var in_descr_block = false;
    var it = std.mem.splitScalar(u8, fm.body, '\n');
    var first_line = true;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (in_descr_block) {
            if (std.mem.eql(u8, line, "}")) {
                in_descr_block = false;
                if (result.acc_descr) |d| allocator.free(d);
                result.acc_descr = try allocator.dupe(u8, std.mem.trim(u8, descr_buf.items, " "));
            } else if (line.len > 0) {
                if (descr_buf.items.len > 0) try descr_buf.append(allocator, ' ');
                try descr_buf.appendSlice(allocator, line);
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "accTitle:")) {
            const v = std.mem.trim(u8, line["accTitle:".len..], " \t");
            if (result.acc_title) |t| allocator.free(t);
            result.acc_title = try allocator.dupe(u8, v);
            continue;
        }
        if (std.mem.startsWith(u8, line, "accDescr")) {
            const rest = std.mem.trimStart(u8, line["accDescr".len..], " \t");
            if (rest.len > 0 and rest[0] == ':') {
                const v = std.mem.trim(u8, rest[1..], " \t");
                if (result.acc_descr) |d| allocator.free(d);
                result.acc_descr = try allocator.dupe(u8, v);
                continue;
            }
            if (rest.len > 0 and rest[0] == '{') {
                const inner = std.mem.trim(u8, rest[1..], " \t");
                if (std.mem.indexOfScalar(u8, inner, '}')) |close| {
                    // Single-line block form: accDescr { … }
                    if (result.acc_descr) |d| allocator.free(d);
                    result.acc_descr = try allocator.dupe(u8, std.mem.trim(u8, inner[0..close], " \t"));
                } else {
                    in_descr_block = true;
                    descr_buf.clearRetainingCapacity();
                    try descr_buf.appendSlice(allocator, inner);
                }
                continue;
            }
            // "accDescr" with neither ':' nor '{' — not a directive; keep it.
        }
        if (!first_line) try cleaned.append(allocator, '\n');
        try cleaned.appendSlice(allocator, raw);
        first_line = false;
    }

    result.owned_body = try cleaned.toOwnedSlice(allocator);
    result.body = result.owned_body.?;
    return result;
}

fn renderPreprocessed(allocator: std.mem.Allocator, pre: *const Preprocessed) ![]const u8 {
    const body = pre.body;

    // Apply %%{init: {...}}%% directive overrides for this render call.
    const applied_init = applyInitDirective(body);
    defer if (applied_init) theme.resetToDefaults();

    const diagram_type = detect.detect(body);

    const svg = switch (diagram_type) {
        .pie => try renderLangium(allocator, body, try getPieCache(), pie_renderer.render),
        .gitgraph => try renderLangium(allocator, body, try getGitCache(), gitgraph_renderer.render),
        .flowchart => try flowchart_parser.render(allocator, body),
        .sequence => try sequence_parser.render(allocator, body),
        .class => try class_parser.render(allocator, body),
        .state => try state_parser.render(allocator, body),
        .er => try er_parser.render(allocator, body),
        .gantt => try gantt_parser.render(allocator, body),
        .timeline => try timeline_parser.render(allocator, body),
        .xychart => try xychart_parser.render(allocator, body),
        .quadrant => try quadrant_parser.render(allocator, body),
        .mindmap => try mindmap_parser.render(allocator, body),
        .sankey => try sankey_parser.render(allocator, body),
        .c4 => try c4_parser.render(allocator, body),
        .block => try block_parser.render(allocator, body),
        .requirement => try requirement_parser.render(allocator, body),
        .kanban => try kanban_parser.render(allocator, body),
        // Emit a simple fallback SVG for unrecognised diagram types.
        .unknown => try renderUnknown(allocator, body),
    };

    // Accessibility metadata is injected only when the input declared some,
    // so plain renders stay byte-identical.
    const title = pre.acc_title orelse pre.title;
    if (title == null and pre.acc_descr == null) return svg;
    defer allocator.free(svg);
    return injectAccessibility(allocator, svg, title, pre.acc_descr);
}

/// Rewrite the root `<svg …>` opening tag to carry `role="img"` +
/// `aria-labelledby`, and insert `<title>`/`<desc>` children right after it,
/// sourcing mermaid `accTitle:`/`accDescr:` directives and the front-matter
/// `title:`.  Screen readers announce these; consumers embedding the SVG
/// (e.g. PolicyPress) no longer need to hardcode a generic label.
fn injectAccessibility(
    allocator: std.mem.Allocator,
    svg: []const u8,
    title: ?[]const u8,
    descr: ?[]const u8,
) ![]const u8 {
    const writer_mod = @import("svg/writer.zig");
    const tag_start = std.mem.indexOf(u8, svg, "<svg ") orelse return allocator.dupe(u8, svg);
    const tag_end = std.mem.indexOfScalarPos(u8, svg, tag_start, '>') orelse return allocator.dupe(u8, svg);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, svg[0..tag_end]);
    try out.appendSlice(allocator, " role=\"img\" aria-labelledby=\"");
    if (title != null) try out.appendSlice(allocator, "pz-title");
    if (title != null and descr != null) try out.append(allocator, ' ');
    if (descr != null) try out.appendSlice(allocator, "pz-desc");
    try out.appendSlice(allocator, "\">");
    if (title) |t| {
        try out.appendSlice(allocator, "<title id=\"pz-title\">");
        try writer_mod.xmlEscape(&out, allocator, t);
        try out.appendSlice(allocator, "</title>");
    }
    if (descr) |d| {
        try out.appendSlice(allocator, "<desc id=\"pz-desc\">");
        try writer_mod.xmlEscape(&out, allocator, d);
        try out.appendSlice(allocator, "</desc>");
    }
    try out.appendSlice(allocator, svg[tag_end + 1 ..]);
    return out.toOwnedSlice(allocator);
}

/// Options for `renderWithOptions`.
pub const RenderOptions = struct {
    /// Runtime theme overrides.  Unset fields use the mermaid default values.
    theme_override: theme.ThemeOverride = .{},

    /// When `true`, return `error.UnknownDiagramType` for unrecognised input
    /// instead of generating a fallback SVG.  Recommended for any pipeline
    /// rendering third-party input: with the lenient default, an unsupported
    /// diagram type (`journey`, `packet`, …) or a typo silently produces a
    /// placeholder SVG that can ship looking like a rendered diagram.
    ///
    /// Deprecation notice: the default flips to `true` in pozeiden 1.0.0 —
    /// the fallback becomes opt-in via an explicit `.strict = false`.
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

    /// Maximum accepted input size in bytes for this call.  Defaults to the
    /// module-level `max_input_bytes` (4 MiB).  Embedders rendering untrusted
    /// input can tighten it per call site; `0` disables the limit entirely —
    /// only do that for input you generated yourself.
    max_input_bytes: usize = max_input_bytes,
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
    const svg = try renderImpl(allocator, mermaid_text, options.max_input_bytes);

    const needs_scale = options.max_width != 0 or options.max_height != 0 or options.scale != 1.0;
    if (!needs_scale) return svg;

    // Post-process: patch width/height/viewBox on the root <svg> element.
    const scaled = scaleSvg(allocator, svg, options) catch return svg;
    allocator.free(svg);
    return scaled;
}

/// Result of `renderWithMetadata`.  Free with `deinit`.
pub const RenderResult = struct {
    /// The rendered SVG (identical to what `renderWithOptions` returns,
    /// including the embedded `<title>`/`<desc>` when metadata is present).
    svg: []const u8,
    /// The detected diagram type.
    diagram_type: DiagramType,
    /// Accessible title: `accTitle:` if declared, else the front-matter
    /// `title:`.  Useful as `alt`/`aria-label` text where the SVG's embedded
    /// `<title>` is unreachable (e.g. `<img>` or PDF embedding).
    title: ?[]const u8,
    /// Accessible description from `accDescr:` / `accDescr { … }`.
    descr: ?[]const u8,

    pub fn deinit(self: *const RenderResult, allocator: std.mem.Allocator) void {
        allocator.free(self.svg);
        if (self.title) |t| allocator.free(t);
        if (self.descr) |d| allocator.free(d);
    }
};

/// Like `renderWithOptions`, but also returns the detected diagram type and
/// the diagram's accessibility metadata as separate strings, for consumers
/// that embed the SVG somewhere its own `<title>`/`<desc>` cannot be read
/// (raster conversion, `<img>` tags, PDF figures).
pub fn renderWithMetadata(
    allocator: std.mem.Allocator,
    mermaid_text: []const u8,
    options: RenderOptions,
) !RenderResult {
    if (options.strict and detect.detect(mermaid_text) == .unknown)
        return error.UnknownDiagramType;
    theme.applyOverride(options.theme_override);
    defer theme.resetToDefaults();

    if (options.max_input_bytes != 0 and mermaid_text.len > options.max_input_bytes)
        return error.InputTooLarge;

    var pre = try preprocess(allocator, mermaid_text);
    var pre_owns_metadata = true;
    defer if (pre_owns_metadata) pre.deinit(allocator) else {
        if (pre.owned_body) |b| allocator.free(b);
    };

    var svg = try renderPreprocessed(allocator, &pre);
    const needs_scale = options.max_width != 0 or options.max_height != 0 or options.scale != 1.0;
    if (needs_scale) {
        if (scaleSvg(allocator, svg, options)) |scaled| {
            allocator.free(svg);
            svg = scaled;
        } else |_| {}
    }

    // Transfer metadata ownership to the result: the preferred title moves
    // out; whichever strings are not returned are freed here.
    const title: ?[]const u8 = pre.acc_title orelse pre.title;
    if (pre.acc_title != null and pre.title != null) allocator.free(pre.title.?);
    const descr: ?[]const u8 = pre.acc_descr;
    pre_owns_metadata = false;

    return .{
        .svg = svg,
        .diagram_type = detect.detect(pre.body),
        .title = title,
        .descr = descr,
    };
}

/// Like `renderWithOptions`, but writes the SVG to `writer` instead of
/// returning an allocated slice.  `allocator` is still used for the render
/// pipeline's internal work.
///
/// The SVG is currently built in memory and then written out; this signature
/// is the stable contract, and a future streaming implementation will not
/// change it.
pub fn renderToWriter(
    allocator: std.mem.Allocator,
    mermaid_text: []const u8,
    options: RenderOptions,
    writer: *std.Io.Writer,
) !void {
    const svg = try renderWithOptions(allocator, mermaid_text, options);
    defer allocator.free(svg);
    try writer.writeAll(svg);
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
