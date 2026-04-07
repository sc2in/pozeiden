//! Mermaid default theme constants.
//! Colors sourced from mermaid's default theme CSS variables.

pub const font_family = "trebuchet ms, verdana, arial, sans-serif";
pub const font_size: u32 = 14;
pub const font_size_small: u32 = 12;

pub const background = "#ffffff";
pub const text_color = "#333333";
pub const line_color = "#333333";

// Node fill/stroke (flowchart)
pub const node_fill = "#ececff";
pub const node_stroke = "#9370db";
pub const node_stroke_width: f32 = 1.5;

// Edge color
pub const edge_color = "#333333";
pub const edge_stroke_width: f32 = 1.5;

// Subgraph
pub const subgraph_fill = "#fafafa";
pub const subgraph_stroke = "#cccccc";

// Sequence diagram
pub const actor_fill = "#ececff";
pub const actor_stroke = "#9370db";
pub const signal_color = "#333333";
pub const label_background = "#ffffff";
pub const loop_fill = "#fafafa";
pub const loop_stroke = "#aaaaaa";
pub const note_fill = "#fff5ad";
pub const note_stroke = "#aaaaaa";

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
pub const pie_label_radius: f32 = 190.0; // radius for label placement
pub const pie_legend_x: f32 = 370.0;
pub const pie_legend_y_start: f32 = 80.0;
pub const pie_legend_line_height: f32 = 24.0;
pub const pie_width: u32 = 600;
pub const pie_height: u32 = 400;
pub const pie_cx: f32 = 220.0;
pub const pie_cy: f32 = 200.0;
