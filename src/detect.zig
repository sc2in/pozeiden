//! Diagram type detection from the opening keyword of a mermaid source file.
//!
//! Mermaid files start with a keyword that identifies the diagram type
//! (`pie`, `graph TD`, `sequenceDiagram`, etc.).  `detect` skips blank lines,
//! YAML front-matter delimiters, and `%%`-prefixed directives before matching
//! that keyword.
const std = @import("std");

/// Every diagram type that pozeiden can render, plus `.unknown` for
/// unrecognised input.
pub const DiagramType = enum {
    /// `pie [title ...]`
    pie,
    /// `graph <dir>` or `flowchart <dir>`
    flowchart,
    /// `sequenceDiagram`
    sequence,
    /// `gitGraph`
    gitgraph,
    /// `classDiagram`
    class,
    /// `stateDiagram-v2`
    state,
    /// `erDiagram`
    er,
    /// `gantt`
    gantt,
    /// `timeline`
    timeline,
    /// `xychart-beta`
    xychart,
    /// `quadrantChart`
    quadrant,
    /// `mindmap`
    mindmap,
    /// `sankey-beta`
    sankey,
    /// `C4Context` / `C4Container` / `C4Component` / `C4Dynamic` / `C4Deployment`
    c4,
    /// `block-beta`
    block,
    /// `requirementDiagram`
    requirement,
    /// `kanban`
    kanban,
    /// The opening keyword was not recognised.
    unknown,
};

/// Return the diagram type by inspecting the first non-blank, non-comment line
/// of `text`.  Returns `.unknown` if no recognised keyword is found.
pub fn detect(text: []const u8) DiagramType {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        // Skip YAML front matter delimiter
        if (std.mem.startsWith(u8, line, "---")) continue;
        // Skip %%-style comments and directives
        if (std.mem.startsWith(u8, line, "%%")) continue;

        if (std.mem.startsWith(u8, line, "pie")) return .pie;

        if (std.mem.startsWith(u8, line, "flowchart") or
            std.mem.startsWith(u8, line, "graph ") or
            std.mem.startsWith(u8, line, "graph\t") or
            std.mem.eql(u8, line, "graph"))
            return .flowchart;

        if (std.mem.startsWith(u8, line, "sequenceDiagram")) return .sequence;

        if (std.mem.startsWith(u8, line, "gitGraph")) return .gitgraph;

        if (std.mem.startsWith(u8, line, "classDiagram")) return .class;

        if (std.mem.startsWith(u8, line, "stateDiagram")) return .state;

        if (std.mem.startsWith(u8, line, "erDiagram")) return .er;

        if (std.mem.startsWith(u8, line, "gantt")) return .gantt;

        if (std.mem.startsWith(u8, line, "timeline")) return .timeline;

        if (std.mem.startsWith(u8, line, "xychart-beta")) return .xychart;

        if (std.mem.startsWith(u8, line, "quadrantChart")) return .quadrant;

        if (std.mem.startsWith(u8, line, "mindmap")) return .mindmap;

        if (std.mem.startsWith(u8, line, "sankey-beta")) return .sankey;

        if (std.mem.startsWith(u8, line, "C4Context") or
            std.mem.startsWith(u8, line, "C4Container") or
            std.mem.startsWith(u8, line, "C4Component") or
            std.mem.startsWith(u8, line, "C4Dynamic") or
            std.mem.startsWith(u8, line, "C4Deployment"))
            return .c4;

        if (std.mem.startsWith(u8, line, "block-beta")) return .block;

        if (std.mem.startsWith(u8, line, "requirementDiagram")) return .requirement;

        if (std.mem.startsWith(u8, line, "kanban")) return .kanban;

        return .unknown;
    }
    return .unknown;
}

test "detect pie" {
    try std.testing.expectEqual(DiagramType.pie, detect("pie title Pets\n\"Dogs\" : 50\n"));
    try std.testing.expectEqual(DiagramType.pie, detect("\npie\n\"A\": 1\n"));
}

test "detect flowchart" {
    try std.testing.expectEqual(DiagramType.flowchart, detect("graph TD\nA-->B\n"));
    try std.testing.expectEqual(DiagramType.flowchart, detect("flowchart LR\nA-->B\n"));
}

test "detect sequence" {
    try std.testing.expectEqual(DiagramType.sequence, detect("sequenceDiagram\nAlice->>Bob: hi\n"));
}

test "detect gitgraph" {
    try std.testing.expectEqual(DiagramType.gitgraph, detect("gitGraph\ncommit\n"));
}

test "detect stateDiagram" {
    try std.testing.expectEqual(DiagramType.state, detect("stateDiagram-v2\n[*] --> A\n"));
    try std.testing.expectEqual(DiagramType.state, detect("stateDiagram\n[*] --> A\n"));
}

test "detect erDiagram" {
    try std.testing.expectEqual(DiagramType.er, detect("erDiagram\nCUSTOMER ||--o{ ORDER : places\n"));
}

test "detect gantt" {
    try std.testing.expectEqual(DiagramType.gantt, detect("gantt\ntitle Schedule\n"));
}

test "detect timeline" {
    try std.testing.expectEqual(DiagramType.timeline, detect("timeline\ntitle History\n"));
}

test "detect xychart" {
    try std.testing.expectEqual(DiagramType.xychart, detect("xychart-beta\nbar [1,2,3]\n"));
}

test "detect quadrantChart" {
    try std.testing.expectEqual(DiagramType.quadrant, detect("quadrantChart\nx-axis A --> B\n"));
}

test "detect mindmap" {
    try std.testing.expectEqual(DiagramType.mindmap, detect("mindmap\nroot((Root))\n"));
}

test "detect sankey" {
    try std.testing.expectEqual(DiagramType.sankey, detect("sankey-beta\nA,B,10\n"));
}

test "detect C4Context" {
    try std.testing.expectEqual(DiagramType.c4, detect("C4Context\nPerson(u, \"User\")\n"));
}

test "detect C4Container" {
    try std.testing.expectEqual(DiagramType.c4, detect("C4Container\nContainer(api, \"API\")\n"));
}

test "detect block-beta" {
    try std.testing.expectEqual(DiagramType.block, detect("block-beta\nA B\n"));
}

test "detect requirementDiagram" {
    try std.testing.expectEqual(DiagramType.requirement, detect("requirementDiagram\nrequirement req1 {}\n"));
}

test "detect kanban" {
    try std.testing.expectEqual(DiagramType.kanban, detect("kanban\ntodo\n  id1[\"Task\"]\n"));
}

test "detect unknown returns .unknown" {
    try std.testing.expectEqual(DiagramType.unknown, detect("hello world\n"));
    try std.testing.expectEqual(DiagramType.unknown, detect(""));
}

test "detect skips blank lines before keyword" {
    try std.testing.expectEqual(DiagramType.pie, detect("\n\n  \npie\n\"A\" : 1\n"));
}

test "detect skips YAML front-matter delimiter" {
    // detect skips lines starting with "---" but not other YAML content
    try std.testing.expectEqual(DiagramType.flowchart, detect("---\ngraph TD\nA-->B\n"));
}

test "detect skips %% comment lines" {
    try std.testing.expectEqual(DiagramType.pie, detect("%% a comment\npie\n\"A\" : 1\n"));
}

test "detect bare graph keyword (no direction)" {
    try std.testing.expectEqual(DiagramType.flowchart, detect("graph\nA-->B\n"));
}
