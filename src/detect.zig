//! Identify the mermaid diagram type from the first meaningful line.
const std = @import("std");

pub const DiagramType = enum {
    pie,
    flowchart,
    sequence,
    gitgraph,
    class,
    state,
    er,
    gantt,
    timeline,
    xychart,
    quadrant,
    mindmap,
    sankey,
    unknown,
};

/// Detect diagram type by inspecting the first non-blank, non-comment line.
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
