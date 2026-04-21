//! Mermaid default theme constants.
//! Colors sourced from mermaid's default theme CSS variables.
//!
//! Most fields are runtime-mutable `var`s so that `renderWithOptions` can
//! temporarily apply a `ThemeOverride` without touching any renderer code.
//! Fields that are arrays or rarely overridden remain compile-time `const`.
//! This is intentionally not thread-safe; pozeiden targets single-threaded
//! (WASM) use.

pub var font_size: u32 = 14;
pub var font_size_small: u32 = 12;
/// CSS font-family string used for all SVG text elements.
/// Override via `ThemeOverride.font_family` to ensure a font that is available
/// in your target environment (important for PDF/Typst rendering where system
/// fonts may not be present).
pub var font_family: []const u8 = "trebuchet ms, verdana, arial, sans-serif";

pub var background: []const u8 = "#ffffff";
pub var text_color: []const u8 = "#333333";
pub var line_color: []const u8 = "#333333";

// Node fill/stroke (flowchart)
pub var node_fill: []const u8 = "#ececff";
pub var node_stroke: []const u8 = "#9370db";
pub const node_stroke_width: f32 = 1.5;

// Edge color
pub var edge_color: []const u8 = "#333333";
pub const edge_stroke_width: f32 = 1.5;

// Subgraph
pub var subgraph_fill: []const u8 = "#fafafa";
pub var subgraph_stroke: []const u8 = "#cccccc";

// Sequence diagram
pub var actor_fill: []const u8 = "#ececff";
pub var actor_stroke: []const u8 = "#9370db";
pub var signal_color: []const u8 = "#333333";
pub var label_background: []const u8 = "#ffffff";
pub var loop_fill: []const u8 = "#fafafa";
pub var loop_stroke: []const u8 = "#aaaaaa";
pub var note_fill: []const u8 = "#fff5ad";
pub var note_stroke: []const u8 = "#aaaaaa";

// Git graph
pub const git_branch_colors = [_][]const u8{
    "#f08d49", "#56a3a6", "#f6b93b", "#e55039", "#1abc9c",
    "#2980b9", "#9b59b6", "#e74c3c",
};
pub const git_commit_fill = "#f4f4f4";
pub const git_commit_stroke = "#555555";
pub const git_label_fill = "#f4f4f4";

// Pie chart slice colors (mermaid default 12-color palette)
pub const pie_colors = [_][]const u8{
    "#12b886", "#228be6", "#fd7e14", "#fa5252", "#be4bdb",
    "#74c0fc", "#ffd43b", "#51cf66", "#ff6b6b", "#cc5de8",
    "#339af0", "#20c997",
};
pub const pie_stroke = "#ffffff";
pub const pie_stroke_width: f32 = 2.0;
pub const pie_text_color = "#333333";
pub const pie_outer_radius: f32 = 150.0;
pub const pie_inner_radius: f32 = 0.0; // solid pie (not donut)
pub const pie_label_radius: f32 = 170.0; // radius for label placement (kept inside legend zone)
pub const pie_legend_x: f32 = 420.0;
pub const pie_legend_y_start: f32 = 80.0;
pub const pie_legend_line_height: f32 = 24.0;
pub const pie_width: u32 = 700;
pub const pie_height: u32 = 400;
pub const pie_cx: f32 = 195.0;
pub const pie_cy: f32 = 200.0;

// ── Runtime theme override ─────────────────────────────────────────────────

/// Optional overrides for the most commonly customised theme fields.
/// Pass to `renderWithOptions` via `RenderOptions`.
pub const ThemeOverride = struct {
    background:       ?[]const u8 = null,
    text_color:       ?[]const u8 = null,
    node_fill:        ?[]const u8 = null,
    node_stroke:      ?[]const u8 = null,
    edge_color:       ?[]const u8 = null,
    font_size:        ?u32 = null,
    font_size_small:  ?u32 = null,
    /// Override the CSS font-family for all SVG text. Useful when embedding SVG
    /// in environments where the default fonts are unavailable (e.g. Typst PDF).
    /// Example: `"Liberation Sans, Arial, sans-serif"`
    font_family:      ?[]const u8 = null,
};

/// Apply `ov` to the module-level theme vars.  Call `resetToDefaults` when
/// rendering is complete.  Not thread-safe.
pub fn applyOverride(ov: ThemeOverride) void {
    if (ov.background)      |v| background      = v;
    if (ov.text_color)      |v| text_color       = v;
    if (ov.node_fill)       |v| node_fill        = v;
    if (ov.node_stroke)     |v| node_stroke      = v;
    if (ov.edge_color)      |v| edge_color       = v;
    if (ov.font_size)       |v| font_size        = v;
    if (ov.font_size_small) |v| font_size_small  = v;
    if (ov.font_family)     |v| font_family      = v;
    // Derived fields that mirror overridden values for visual consistency.
    if (ov.background)      |v| label_background = v;
    if (ov.text_color)      |v| { signal_color = v; line_color = v; }
    if (ov.node_fill)       |v| { actor_fill = v; }
    if (ov.node_stroke)     |v| { actor_stroke = v; }
}

/// Reset all overridable vars to their mermaid default values.
pub fn resetToDefaults() void {
    font_size        = 14;
    font_size_small  = 12;
    font_family      = "trebuchet ms, verdana, arial, sans-serif";
    background       = "#ffffff";
    text_color       = "#333333";
    line_color       = "#333333";
    node_fill        = "#ececff";
    node_stroke      = "#9370db";
    edge_color       = "#333333";
    subgraph_fill    = "#fafafa";
    subgraph_stroke  = "#cccccc";
    actor_fill       = "#ececff";
    actor_stroke     = "#9370db";
    signal_color     = "#333333";
    label_background = "#ffffff";
    loop_fill        = "#fafafa";
    loop_stroke      = "#aaaaaa";
    note_fill        = "#fff5ad";
    note_stroke      = "#aaaaaa";
}
