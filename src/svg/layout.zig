//! DAG layout for flowchart diagrams (simplified Sugiyama).
//! Also provides helpers for sequence diagram lifeline spacing.
const std = @import("std");

pub const Point = struct { x: f32, y: f32 };
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

// ── Flowchart DAG layout ──────────────────────────────────────────────────────

pub const GraphNode = struct {
    id: []const u8,
    label: []const u8,
    shape: NodeShape,
    /// Assigned by layout
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 120,
    h: f32 = 40,
    layer: usize = 0,
    order: usize = 0,
};

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

pub const GraphEdge = struct {
    from: []const u8,
    to: []const u8,
    label: ?[]const u8,
    style: EdgeStyle,
};

pub const EdgeStyle = enum { solid, dotted, thick };

pub const Direction = enum { tb, lr, rl, bt };

pub const Graph = struct {
    nodes: []GraphNode,
    edges: []GraphEdge,
    direction: Direction,
};

/// Assign (x, y) coordinates to nodes using a simplified Sugiyama algorithm.
/// Modifies nodes in place.
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
const H_GAP: f32 = 60;
const V_GAP: f32 = 80;
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

    var queue = std.ArrayList(usize).init(allocator);
    defer queue.deinit();

    for (in_degree, 0..) |d, i| {
        if (d == 0) try queue.append(i);
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
            if (in_degree[to_idx] == 0) try queue.append(to_idx);
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

pub fn svgWidth(nodes: []const GraphNode) u32 {
    const bb = boundingBox(nodes);
    return @intFromFloat(@max(400, bb.w + bb.x + MARGIN));
}

pub fn svgHeight(nodes: []const GraphNode) u32 {
    const bb = boundingBox(nodes);
    return @intFromFloat(@max(300, bb.h + bb.y + MARGIN));
}
