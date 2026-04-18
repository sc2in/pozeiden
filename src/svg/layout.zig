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
    /// Optional per-node style from `classDef`/`class`. Null = use theme default.
    fill: ?[]const u8 = null,
    stroke: ?[]const u8 = null,
    label_color: ?[]const u8 = null,
    font_weight: ?[]const u8 = null,
    href: ?[]const u8 = null,
    /// Index of the subgraph this node belongs to. `std.math.maxInt(usize)` = none.
    subgraph: usize = std.math.maxInt(usize),
};

/// Mermaid flowchart node shapes.
pub const NodeShape = enum {
    rect,
    round,
    diamond,
    circle,
    double_circle,
    stadium,
    subroutine,
    cylinder,
    hexagon,
    ellipse,
    parallelogram,
    parallelogram_alt,
    trapezoid,
    trapezoid_alt,
    asymmetric,
};

/// A directed edge between two nodes.
pub const GraphEdge = struct {
    from: []const u8,
    to: []const u8,
    label: ?[]const u8,
    style: EdgeStyle,
    color: ?[]const u8 = null,   // from linkStyle override
    /// Set by `breakCycles`: edge points against the DAG flow and is treated
    /// as logically reversed (to→from) during layer assignment.
    reversed: bool = false,
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

/// Assign `(x, y)` coordinates to every node in `graph` using a three-phase
/// Sugiyama algorithm: cycle-breaking → layer assignment → barycenter ordering
/// → coordinates. Modifies `graph.nodes` and `graph.edges` in place.
pub fn layout(allocator: std.mem.Allocator, graph: *Graph) !void {
    if (graph.nodes.len == 0) return;

    // 0. Break cycles: mark back edges as reversed so BFS layer assignment works
    try breakCycles(allocator, graph);

    // 1. Assign layers using longest path from sources (respects reversed edges)
    try assignLayers(allocator, graph);

    // 2. Order nodes with barycenter heuristic to reduce edge crossings
    try orderNodes(allocator, graph);

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
        // Reversed edges contribute in-degree to the *from* node (logical target).
        const target = if (e.reversed) e.from else e.to;
        const to_idx = idx_map.get(target) orelse continue;
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
            // For reversed edges treat the direction as to→from.
            const logical_from = if (e.reversed) e.to else e.from;
            const logical_to   = if (e.reversed) e.from else e.to;
            const from_idx = idx_map.get(logical_from) orelse continue;
            if (from_idx != cur) continue;
            const to_idx = idx_map.get(logical_to) orelse continue;
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

/// DFS-based cycle-breaking: marks back edges with `reversed = true` so that
/// `assignLayers` can treat them as forward edges and produce correct depths.
fn breakCycles(allocator: std.mem.Allocator, graph: *Graph) !void {
    const n = graph.nodes.len;
    if (n == 0) return;

    var idx_map = std.StringHashMap(usize).init(allocator);
    defer idx_map.deinit();
    for (graph.nodes, 0..) |nd, i| try idx_map.put(nd.id, i);

    // 3-colour DFS: 0 = white, 1 = gray (on stack), 2 = black (done)
    var color = try allocator.alloc(u8, n);
    defer allocator.free(color);
    @memset(color, 0);

    // Iterative DFS to avoid call-stack overflow on large graphs.
    // Each frame stores the node index and our current scan position in the
    // global edge slice (we scan all edges looking for outgoing from this node).
    const Frame = struct { u: usize, ei: usize };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(allocator);

    for (0..n) |start| {
        if (color[start] != 0) continue;
        color[start] = 1;
        try stack.append(allocator, .{ .u = start, .ei = 0 });

        outer: while (stack.items.len > 0) {
            const top = stack.items.len - 1;
            const u = stack.items[top].u;
            var ei = stack.items[top].ei;

            while (ei < graph.edges.len) {
                const e = &graph.edges[ei];
                ei += 1;
                // Only follow edges that are not already reversed.
                const from_idx = idx_map.get(e.from) orelse continue;
                if (from_idx != u) continue;
                const to_idx = idx_map.get(e.to) orelse continue;

                if (color[to_idx] == 1) {
                    e.reversed = true; // back edge
                } else if (color[to_idx] == 0) {
                    // Tree edge — push and continue DFS from to_idx.
                    stack.items[top].ei = ei; // save scan position
                    color[to_idx] = 1;
                    try stack.append(allocator, .{ .u = to_idx, .ei = 0 });
                    continue :outer;
                }
                // color == 2: cross/forward edge, nothing to do
            }
            // All outgoing edges processed — finish this node.
            color[u] = 2;
            _ = stack.pop();
        }
    }
}

/// Order nodes within each layer using the barycenter heuristic (3 alternating
/// down/up passes) to reduce edge crossings, initialised with a stable
/// alphabetical sort so results are deterministic.
fn orderNodes(allocator: std.mem.Allocator, graph: *Graph) !void {
    const nodes = graph.nodes;

    // Phase 1: initial alphabetical sort within each layer.
    {
        var i: usize = 0;
        while (i < nodes.len) : (i += 1) {
            var j: usize = i + 1;
            while (j < nodes.len) : (j += 1) {
                if (nodes[i].layer == nodes[j].layer and
                    std.mem.order(u8, nodes[i].id, nodes[j].id) == .gt)
                {
                    const tmp = nodes[i];
                    nodes[i] = nodes[j];
                    nodes[j] = tmp;
                }
            }
        }
    }
    var lc = std.mem.zeroes([64]usize);
    for (nodes) |*nd| {
        nd.order = lc[nd.layer % 64];
        lc[nd.layer % 64] += 1;
    }

    var max_layer: usize = 0;
    for (nodes) |nd| if (nd.layer > max_layer) { max_layer = nd.layer; };
    if (max_layer == 0) return; // single layer — no crossings possible

    // Phase 2: barycenter heuristic — 3 down + 3 up alternating sweeps.
    var bary = try allocator.alloc(f32, nodes.len);
    defer allocator.free(bary);

    for (0..6) |pass| {
        const down = (pass % 2 == 0);
        for (0..max_layer + 1) |li| {
            const layer: usize = if (down) li else max_layer - li;
            // Reference layer: the already-fixed adjacent layer in sweep direction.
            const ref_signed: i64 = @as(i64, @intCast(layer)) + if (down) @as(i64, -1) else @as(i64, 1);
            if (ref_signed < 0 or ref_signed > @as(i64, @intCast(max_layer))) continue;
            const ref_layer: usize = @intCast(ref_signed);

            // Compute barycenter for each node in `layer`.
            for (nodes, 0..) |*nd, ni| {
                if (nd.layer != layer) { bary[ni] = -1; continue; }
                var sum: f32 = 0;
                var cnt: u32 = 0;
                for (graph.edges) |e| {
                    // Use logical direction (accounting for reversed edges).
                    const fid = if (e.reversed) e.to else e.from;
                    const tid = if (e.reversed) e.from else e.to;
                    const nbr_id: []const u8 = if (std.mem.eql(u8, nd.id, fid))
                        tid
                    else if (std.mem.eql(u8, nd.id, tid))
                        fid
                    else
                        continue;
                    for (nodes) |nb| {
                        if (nb.layer == ref_layer and std.mem.eql(u8, nb.id, nbr_id)) {
                            sum += @floatFromInt(nb.order);
                            cnt += 1;
                            break;
                        }
                    }
                }
                bary[ni] = if (cnt > 0) sum / @as(f32, @floatFromInt(cnt)) else @as(f32, @floatFromInt(nd.order));
            }

            // Collect indices of nodes in this layer, sort by bary, reassign order.
            var idxs: [128]usize = undefined;
            var ic: usize = 0;
            for (nodes, 0..) |nd, ni| {
                if (nd.layer == layer and ic < idxs.len) {
                    idxs[ic] = ni;
                    ic += 1;
                }
            }
            // Insertion sort on idxs by bary value.
            var s: usize = 1;
            while (s < ic) : (s += 1) {
                const key_i = idxs[s];
                const key_b = bary[key_i];
                var t: usize = s;
                while (t > 0 and bary[idxs[t - 1]] > key_b) : (t -= 1) {
                    idxs[t] = idxs[t - 1];
                }
                idxs[t] = key_i;
            }
            for (idxs[0..ic], 0..) |ni, ord| {
                nodes[ni].order = ord;
            }
        }
    }

    // Final pass: cluster subgraph members within each layer.
    // For each layer, compute group centroid (mean order of members with same subgraph id),
    // then sort by (group_centroid, member_order) so same-subgraph nodes are adjacent
    // while the group sits at its barycenter-computed position.
    {
        var layer: usize = 0;
        while (layer <= max_layer) : (layer += 1) {
            // Collect node indices in this layer
            var idxs: [128]usize = undefined;
            var ic: usize = 0;
            for (nodes, 0..) |nd, ni| {
                if (nd.layer == layer and ic < idxs.len) { idxs[ic] = ni; ic += 1; }
            }
            if (ic <= 1) continue;

            // Compute group centroid per subgraph_id (within this layer)
            // Use a simple map: scan all pairs (O(n²) is fine for small layers)
            // centroid[i] = mean order of all nodes in same subgraph as idxs[i]
            var centroids: [128]f32 = undefined;
            for (idxs[0..ic], 0..) |ni, ii| {
                const sg = nodes[ni].subgraph;
                if (sg == std.math.maxInt(usize)) {
                    centroids[ii] = @floatFromInt(nodes[ni].order);
                    continue;
                }
                var sum: f32 = 0;
                var cnt: usize = 0;
                for (idxs[0..ic]) |nj| {
                    if (nodes[nj].subgraph == sg) {
                        sum += @floatFromInt(nodes[nj].order);
                        cnt += 1;
                    }
                }
                centroids[ii] = sum / @as(f32, @floatFromInt(cnt));
            }

            // Insertion sort idxs by (centroid, order)
            var s: usize = 1;
            while (s < ic) : (s += 1) {
                const key_i = idxs[s];
                const key_c = centroids[s];
                const key_o = nodes[key_i].order;
                var t: usize = s;
                while (t > 0) : (t -= 1) {
                    const pc = centroids[t - 1];
                    const po = nodes[idxs[t - 1]].order;
                    if (pc < key_c or (pc == key_c and po <= key_o)) break;
                    idxs[t] = idxs[t - 1];
                    centroids[t] = centroids[t - 1];
                }
                idxs[t] = key_i;
                centroids[t] = key_c;
            }
            for (idxs[0..ic], 0..) |ni, ord| {
                nodes[ni].order = ord;
            }
        }
    }
}

fn assignCoordinates(graph: *Graph) void {
    // Determine how many nodes per layer
    var layer_counts = std.mem.zeroes([64]usize);
    for (graph.nodes) |n| {
        layer_counts[n.layer % 64] += 1;
    }

    // Assign coordinates centered around origin; translateNodes shifts to MARGIN.
    for (graph.nodes) |*n| {
        const per_layer = layer_counts[n.layer % 64];
        const total_w = @as(f32, @floatFromInt(per_layer)) * (NODE_W + H_GAP) - H_GAP;

        switch (graph.direction) {
            .tb, .bt => {
                const x_start = @as(f32, @floatFromInt(n.order)) * (NODE_W + H_GAP) - total_w / 2.0;
                const y = @as(f32, @floatFromInt(n.layer)) * (NODE_H + V_GAP);
                n.x = x_start;
                n.y = if (graph.direction == .bt) -y else y;
            },
            .lr, .rl => {
                const y_start = @as(f32, @floatFromInt(n.order)) * (NODE_H + H_GAP) - total_w / 2.0;
                const x = @as(f32, @floatFromInt(n.layer)) * (NODE_W + V_GAP);
                n.y = y_start;
                n.x = if (graph.direction == .rl) -x else x;
            },
        }
    }

    // Shift all nodes so the minimum coordinate is at MARGIN.
    translateNodes(graph);
}

fn translateNodes(graph: *Graph) void {
    if (graph.nodes.len == 0) return;
    var min_x: f32 = graph.nodes[0].x;
    var min_y: f32 = graph.nodes[0].y;
    for (graph.nodes[1..]) |n| {
        if (n.x < min_x) min_x = n.x;
        if (n.y < min_y) min_y = n.y;
    }
    const dx = MARGIN - min_x;
    const dy = MARGIN - min_y;
    for (graph.nodes) |*n| {
        n.x += dx;
        n.y += dy;
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
pub fn svgWidth(nodes: []const GraphNode) u32 {
    if (nodes.len == 0) return 300;
    var max_x: f32 = 0;
    for (nodes) |n| {
        if (n.x + n.w > max_x) max_x = n.x + n.w;
    }
    return @intFromFloat(max_x + MARGIN);
}

/// Return a suitable SVG canvas height for the given laid-out nodes.
pub fn svgHeight(nodes: []const GraphNode) u32 {
    if (nodes.len == 0) return 200;
    var max_y: f32 = 0;
    for (nodes) |n| {
        if (n.y + n.h > max_y) max_y = n.y + n.h;
    }
    return @intFromFloat(max_y + MARGIN);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeNode(id: []const u8) GraphNode {
    return .{ .id = id, .label = id, .shape = .rect };
}

fn makeEdge(from: []const u8, to: []const u8) GraphEdge {
    return .{ .from = from, .to = to, .label = null, .style = .solid };
}

test "layout empty graph is no-op" {
    var nodes = [_]GraphNode{};
    var edges = [_]GraphEdge{};
    var g: Graph = .{ .nodes = &nodes, .edges = &edges, .direction = .tb };
    try layout(testing.allocator, &g);
}

test "layout single node placed at margin" {
    var nodes = [_]GraphNode{makeNode("A")};
    var edges = [_]GraphEdge{};
    var g: Graph = .{ .nodes = &nodes, .edges = &edges, .direction = .tb };
    try layout(testing.allocator, &g);
    try testing.expect(nodes[0].x >= MARGIN - 1.0);
    try testing.expect(nodes[0].y >= MARGIN - 1.0);
}

test "layout two nodes TB: A above B" {
    var nodes = [_]GraphNode{ makeNode("A"), makeNode("B") };
    var edges = [_]GraphEdge{makeEdge("A", "B")};
    var g: Graph = .{ .nodes = &nodes, .edges = &edges, .direction = .tb };
    try layout(testing.allocator, &g);
    // Find A and B by id since orderNodes may reorder the slice
    var a_y: f32 = 0;
    var b_y: f32 = 0;
    for (nodes) |n| {
        if (std.mem.eql(u8, n.id, "A")) a_y = n.y;
        if (std.mem.eql(u8, n.id, "B")) b_y = n.y;
    }
    try testing.expect(a_y < b_y);
}

test "layout two nodes LR: A left of B" {
    var nodes = [_]GraphNode{ makeNode("A"), makeNode("B") };
    var edges = [_]GraphEdge{makeEdge("A", "B")};
    var g: Graph = .{ .nodes = &nodes, .edges = &edges, .direction = .lr };
    try layout(testing.allocator, &g);
    var a_x: f32 = 0;
    var b_x: f32 = 0;
    for (nodes) |n| {
        if (std.mem.eql(u8, n.id, "A")) a_x = n.x;
        if (std.mem.eql(u8, n.id, "B")) b_x = n.x;
    }
    try testing.expect(a_x < b_x);
}

test "layout two nodes RL: A right of B" {
    var nodes = [_]GraphNode{ makeNode("A"), makeNode("B") };
    var edges = [_]GraphEdge{makeEdge("A", "B")};
    var g: Graph = .{ .nodes = &nodes, .edges = &edges, .direction = .rl };
    try layout(testing.allocator, &g);
    var a_x: f32 = 0;
    var b_x: f32 = 0;
    for (nodes) |n| {
        if (std.mem.eql(u8, n.id, "A")) a_x = n.x;
        if (std.mem.eql(u8, n.id, "B")) b_x = n.x;
    }
    try testing.expect(a_x > b_x);
}

test "layout two nodes BT: A below B" {
    var nodes = [_]GraphNode{ makeNode("A"), makeNode("B") };
    var edges = [_]GraphEdge{makeEdge("A", "B")};
    var g: Graph = .{ .nodes = &nodes, .edges = &edges, .direction = .bt };
    try layout(testing.allocator, &g);
    var a_y: f32 = 0;
    var b_y: f32 = 0;
    for (nodes) |n| {
        if (std.mem.eql(u8, n.id, "A")) a_y = n.y;
        if (std.mem.eql(u8, n.id, "B")) b_y = n.y;
    }
    try testing.expect(a_y > b_y);
}

test "layout three-node chain: sequential layers" {
    var nodes = [_]GraphNode{ makeNode("A"), makeNode("B"), makeNode("C") };
    var edges = [_]GraphEdge{ makeEdge("A", "B"), makeEdge("B", "C") };
    var g: Graph = .{ .nodes = &nodes, .edges = &edges, .direction = .tb };
    try layout(testing.allocator, &g);
    var layers: [3]usize = undefined;
    for (nodes) |n| {
        if (std.mem.eql(u8, n.id, "A")) layers[0] = n.layer;
        if (std.mem.eql(u8, n.id, "B")) layers[1] = n.layer;
        if (std.mem.eql(u8, n.id, "C")) layers[2] = n.layer;
    }
    try testing.expect(layers[0] < layers[1]);
    try testing.expect(layers[1] < layers[2]);
}

test "layout parallel nodes: same layer" {
    var nodes = [_]GraphNode{ makeNode("A"), makeNode("B"), makeNode("C") };
    // A -> B and A -> C: B and C should be in same layer
    var edges = [_]GraphEdge{ makeEdge("A", "B"), makeEdge("A", "C") };
    var g: Graph = .{ .nodes = &nodes, .edges = &edges, .direction = .tb };
    try layout(testing.allocator, &g);
    var b_layer: usize = 99;
    var c_layer: usize = 99;
    for (nodes) |n| {
        if (std.mem.eql(u8, n.id, "B")) b_layer = n.layer;
        if (std.mem.eql(u8, n.id, "C")) c_layer = n.layer;
    }
    try testing.expectEqual(b_layer, c_layer);
}

test "layout cycle is broken: both nodes get valid coordinates" {
    var nodes = [_]GraphNode{ makeNode("A"), makeNode("B") };
    var edges = [_]GraphEdge{ makeEdge("A", "B"), makeEdge("B", "A") };
    var g: Graph = .{ .nodes = &nodes, .edges = &edges, .direction = .tb };
    try layout(testing.allocator, &g);
    // At least one edge should be reversed after cycle breaking
    var any_reversed = false;
    for (edges) |e| {
        if (e.reversed) any_reversed = true;
    }
    try testing.expect(any_reversed);
    // Both nodes should have valid (non-negative) coordinates
    for (nodes) |n| {
        try testing.expect(n.x >= 0);
        try testing.expect(n.y >= 0);
    }
}

test "layout diamond graph: fork then join, all nodes placed" {
    var nodes = [_]GraphNode{ makeNode("A"), makeNode("B"), makeNode("C"), makeNode("D") };
    var edges = [_]GraphEdge{
        makeEdge("A", "B"), makeEdge("A", "C"),
        makeEdge("B", "D"), makeEdge("C", "D"),
    };
    var g: Graph = .{ .nodes = &nodes, .edges = &edges, .direction = .tb };
    try layout(testing.allocator, &g);
    for (nodes) |n| {
        try testing.expect(n.x >= 0);
        try testing.expect(n.y >= 0);
    }
}

test "layout self-loop edge does not panic" {
    var nodes = [_]GraphNode{makeNode("A")};
    var edges = [_]GraphEdge{makeEdge("A", "A")};
    var g: Graph = .{ .nodes = &nodes, .edges = &edges, .direction = .tb };
    try layout(testing.allocator, &g);
}

test "layout edge referencing unknown node id is skipped" {
    var nodes = [_]GraphNode{makeNode("A")};
    var edges = [_]GraphEdge{makeEdge("A", "MISSING")};
    var g: Graph = .{ .nodes = &nodes, .edges = &edges, .direction = .tb };
    try layout(testing.allocator, &g);
    try testing.expect(nodes[0].x >= 0);
}

test "boundingBox empty slice returns default" {
    const bb = boundingBox(&.{});
    try testing.expectApproxEqAbs(@as(f32, 400), bb.w, 1.0);
    try testing.expectApproxEqAbs(@as(f32, 300), bb.h, 1.0);
}

test "boundingBox single node includes margin" {
    const n: GraphNode = .{ .id = "A", .label = "A", .shape = .rect, .x = 40, .y = 40, .w = 120, .h = 40 };
    const bb = boundingBox(&[_]GraphNode{n});
    try testing.expect(bb.w > 0);
    try testing.expect(bb.h > 0);
}

test "boundingBox multiple nodes spans all" {
    const n1: GraphNode = .{ .id = "A", .label = "A", .shape = .rect, .x = 40, .y = 40, .w = 120, .h = 40 };
    const n2: GraphNode = .{ .id = "B", .label = "B", .shape = .rect, .x = 300, .y = 200, .w = 120, .h = 40 };
    const bb = boundingBox(&[_]GraphNode{ n1, n2 });
    // bounding box must be wider than just n1
    try testing.expect(bb.w > n1.w + 2 * MARGIN);
}

test "svgWidth empty nodes returns minimum" {
    try testing.expectEqual(@as(u32, 300), svgWidth(&.{}));
}

test "svgWidth single laid-out node" {
    const n: GraphNode = .{ .id = "A", .label = "A", .shape = .rect, .x = 40, .y = 40, .w = 120, .h = 40 };
    const w = svgWidth(&[_]GraphNode{n});
    try testing.expect(w > @as(u32, @intFromFloat(40 + 120)));
}

test "svgHeight empty nodes returns minimum" {
    try testing.expectEqual(@as(u32, 200), svgHeight(&.{}));
}

test "svgHeight single laid-out node" {
    const n: GraphNode = .{ .id = "A", .label = "A", .shape = .rect, .x = 40, .y = 40, .w = 120, .h = 40 };
    const h = svgHeight(&[_]GraphNode{n});
    try testing.expect(h > @as(u32, @intFromFloat(40 + 40)));
}

test "breakCycles: back edge marked reversed" {
    var nodes = [_]GraphNode{ makeNode("A"), makeNode("B") };
    var edges = [_]GraphEdge{ makeEdge("A", "B"), makeEdge("B", "A") };
    var g: Graph = .{ .nodes = &nodes, .edges = &edges, .direction = .tb };
    try breakCycles(testing.allocator, &g);
    var any_reversed = false;
    for (edges) |e| if (e.reversed) { any_reversed = true; };
    try testing.expect(any_reversed);
}

test "assignLayers: disconnected component gets layer 0" {
    // Two isolated nodes with no edges - both should be at layer 0
    var nodes = [_]GraphNode{ makeNode("A"), makeNode("B") };
    var edges = [_]GraphEdge{};
    var g: Graph = .{ .nodes = &nodes, .edges = &edges, .direction = .tb };
    try layout(testing.allocator, &g);
    try testing.expectEqual(@as(usize, 0), nodes[0].layer);
    try testing.expectEqual(@as(usize, 0), nodes[1].layer);
}

test "translateNodes: minimum coordinate shifted to MARGIN" {
    var nodes = [_]GraphNode{ makeNode("A") };
    var edges = [_]GraphEdge{};
    var g: Graph = .{ .nodes = &nodes, .edges = &edges, .direction = .tb };
    try layout(testing.allocator, &g);
    // After translate, minimum x and y should be >= MARGIN
    try testing.expect(nodes[0].x >= MARGIN - 0.1);
    try testing.expect(nodes[0].y >= MARGIN - 0.1);
}
