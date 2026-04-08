//! DAG layout engine used by the flowchart renderer.
//!
//! Implements a simplified three-phase Sugiyama algorithm:
//! 1. Layer assignment: longest-path BFS from source nodes.
//! 2. Node ordering: stable sort by id within each layer.
//! 3. Coordinate assignment: evenly-spaced grid positions.
//!
//! The `H_GAP` and `V_GAP` constants are exported so that the flowchart
//! renderer can derive Bezier control-point offsets that match the layout.
const std = @import("std");

/// A 2-D point in SVG coordinate space.
pub const Point = struct { x: f32, y: f32 };
/// An axis-aligned rectangle in SVG coordinate space.
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

// ── Flowchart DAG layout ──────────────────────────────────────────────────────

/// A node in the flowchart graph.  `x`, `y`, `w`, `h` are zero-initialised
/// and filled in by `layout`.
pub const GraphNode = struct {
    id: []const u8,
    label: []const u8,
    shape: NodeShape,
    /// Top-left x coordinate (assigned by `layout`).
    x: f32 = 0,
    /// Top-left y coordinate (assigned by `layout`).
    y: f32 = 0,
    w: f32 = 120,
    h: f32 = 40,
    layer: usize = 0,
    order: usize = 0,
};

/// Mermaid flowchart node shapes.
pub const NodeShape = enum {
    rect,
    round,
    diamond,
    circle,
    stadium,
    subroutine,
    cylinder,
    hexagon,
    ellipse,
};

/// A directed edge between two nodes.
pub const GraphEdge = struct {
    from: []const u8,
    to: []const u8,
    label: ?[]const u8,
    style: EdgeStyle,
};

/// Edge line style.
pub const EdgeStyle = enum { solid, dotted, thick };

/// Flowchart layout direction, matching mermaid's `TD`/`TB`/`LR`/`RL`/`BT`
/// keywords.
pub const Direction = enum { tb, lr, rl, bt };

/// A complete flowchart graph.  Pass to `layout` to assign coordinates.
pub const Graph = struct {
    nodes: []GraphNode,
    edges: []GraphEdge,
    direction: Direction,
};

/// Assign `(x, y)` coordinates to every node in `graph` using a simplified
/// three-phase Sugiyama algorithm (layer assignment → ordering → coordinates).
/// Modifies `graph.nodes` in place; `graph.edges` is read-only.
pub fn layout(allocator: std.mem.Allocator, graph: *Graph) !void {
    if (graph.nodes.len == 0) return;

    // 1. Assign layers using longest path from sources
    try assignLayers(allocator, graph);

    // 2. Order nodes within each layer (simple: stable sort by id)
    orderNodes(graph);

    // 3. Assign coordinates
    assignCoordinates(graph);
}

const NODE_W: f32 = 140;
const NODE_H: f32 = 44;
pub const H_GAP: f32 = 60;
pub const V_GAP: f32 = 80;
const MARGIN: f32 = 40;

fn assignLayers(allocator: std.mem.Allocator, graph: *Graph) !void {
    // Build adjacency: for each node, track which nodes point INTO it (in-edges)
    var in_degree = try allocator.alloc(usize, graph.nodes.len);
    defer allocator.free(in_degree);
    @memset(in_degree, 0);

    // Map node id -> index
    var idx_map = std.StringHashMap(usize).init(allocator);
    defer idx_map.deinit();
    for (graph.nodes, 0..) |n, i| {
        try idx_map.put(n.id, i);
    }

    for (graph.edges) |e| {
        const to_idx = idx_map.get(e.to) orelse continue;
        in_degree[to_idx] += 1;
    }

    // Layer assignment: BFS from sources (in_degree == 0)
    var max_layer: usize = 0;
    var layers = try allocator.alloc(usize, graph.nodes.len);
    defer allocator.free(layers);
    @memset(layers, 0);

    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(allocator);

    for (in_degree, 0..) |d, i| {
        if (d == 0) try queue.append(allocator, i);
    }

    var head: usize = 0;
    while (head < queue.items.len) {
        const cur = queue.items[head];
        head += 1;
        const cur_layer = layers[cur];
        if (cur_layer > max_layer) max_layer = cur_layer;

        for (graph.edges) |e| {
            const from_idx = idx_map.get(e.from) orelse continue;
            if (from_idx != cur) continue;
            const to_idx = idx_map.get(e.to) orelse continue;
            if (layers[to_idx] < cur_layer + 1) {
                layers[to_idx] = cur_layer + 1;
                if (layers[to_idx] > max_layer) max_layer = layers[to_idx];
            }
            in_degree[to_idx] -= 1;
            if (in_degree[to_idx] == 0) try queue.append(allocator, to_idx);
        }
    }

    for (graph.nodes, 0..) |*n, i| {
        n.layer = layers[i];
        n.w = NODE_W;
        n.h = NODE_H;
    }
}

fn orderNodes(graph: *Graph) void {
    // Sort by (layer, id) to get a stable order within each layer
    const nodes = graph.nodes;
    // Bubble sort (small N)
    var i: usize = 0;
    while (i < nodes.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < nodes.len) : (j += 1) {
            if (nodes[i].layer == nodes[j].layer) {
                if (std.mem.order(u8, nodes[i].id, nodes[j].id) == .gt) {
                    const tmp = nodes[i];
                    nodes[i] = nodes[j];
                    nodes[j] = tmp;
                }
            }
        }
    }
    // Assign order within layer
    var layer_count = std.mem.zeroes([64]usize);
    for (nodes) |*n| {
        n.order = layer_count[n.layer % 64];
        layer_count[n.layer % 64] += 1;
    }
}

fn assignCoordinates(graph: *Graph) void {
    // Determine how many nodes per layer
    var layer_counts = std.mem.zeroes([64]usize);
    for (graph.nodes) |n| {
        layer_counts[n.layer % 64] += 1;
    }

    for (graph.nodes) |*n| {
        const per_layer = layer_counts[n.layer % 64];
        const total_w = @as(f32, @floatFromInt(per_layer)) * (NODE_W + H_GAP) - H_GAP;

        switch (graph.direction) {
            .tb, .bt => {
                const x_start = MARGIN + (@as(f32, @floatFromInt(n.order)) * (NODE_W + H_GAP)) -
                    total_w / 2.0 + 400.0;
                const y = MARGIN + @as(f32, @floatFromInt(n.layer)) * (NODE_H + V_GAP);
                n.x = x_start;
                n.y = if (graph.direction == .bt) -y else y;
            },
            .lr, .rl => {
                const y_start = MARGIN + (@as(f32, @floatFromInt(n.order)) * (NODE_H + H_GAP)) -
                    total_w / 2.0 + 300.0;
                const x = MARGIN + @as(f32, @floatFromInt(n.layer)) * (NODE_W + V_GAP);
                n.y = y_start;
                n.x = if (graph.direction == .rl) -x else x;
            },
        }
    }
}

/// Return the axis-aligned bounding box that encloses all `nodes`.
/// Returns a 400×300 default rectangle when `nodes` is empty.
pub fn boundingBox(nodes: []const GraphNode) Rect {
    if (nodes.len == 0) return .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    var min_x: f32 = nodes[0].x;
    var min_y: f32 = nodes[0].y;
    var max_x: f32 = nodes[0].x + nodes[0].w;
    var max_y: f32 = nodes[0].y + nodes[0].h;
    for (nodes[1..]) |n| {
        if (n.x < min_x) min_x = n.x;
        if (n.y < min_y) min_y = n.y;
        if (n.x + n.w > max_x) max_x = n.x + n.w;
        if (n.y + n.h > max_y) max_y = n.y + n.h;
    }
    return .{
        .x = min_x - MARGIN,
        .y = min_y - MARGIN,
        .w = max_x - min_x + MARGIN * 2,
        .h = max_y - min_y + MARGIN * 2,
    };
}

/// Return a suitable SVG canvas width for the given laid-out nodes.
/// The result is at least 400 pixels.
pub fn svgWidth(nodes: []const GraphNode) u32 {
    const bb = boundingBox(nodes);
    return @intFromFloat(@max(400, bb.w + bb.x + MARGIN));
}

/// Return a suitable SVG canvas height for the given laid-out nodes.
/// The result is at least 300 pixels.
pub fn svgHeight(nodes: []const GraphNode) u32 {
    const bb = boundingBox(nodes);
    return @intFromFloat(@max(300, bb.h + bb.y + MARGIN));
}
