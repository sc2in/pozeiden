//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
//! DAG layout engine used by the flowchart renderer.
//!
//! Implements a simplified Sugiyama algorithm:
//! 0. Cycle breaking: iterative DFS marks back edges as logically reversed.
//! 1. Layer assignment: longest-path BFS from source nodes.
//! 2. Node ordering: alphabetical seed, then a barycenter heuristic
//!    (3 down + 3 up sweeps) plus a subgraph-clustering pass.
//! 3. Coordinate assignment: evenly-spaced grid positions.
//!
//! Every phase walks per-node adjacency lists built once per `layout` call
//! (O(passes·(V+E)) overall, issue #42); the lists are filled in global edge
//! order so traversal order — and therefore the emitted SVG — is identical to
//! the earlier implementation that re-scanned the whole edge slice per node.
//!
//! The `H_GAP` and `V_GAP` constants are exported so that the flowchart
//! renderer can derive Bezier control-point offsets that match the layout.
const std = @import("std");
const testing = std.testing;

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
    color: ?[]const u8 = null, // from linkStyle override
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
/// Layout is O(passes·(V+E)), but a cap still bounds the memory and SVG size
/// an untrusted input can demand. These limits are far beyond any legible
/// flowchart; larger graphs yield `error.DiagramTooLarge`.
///
/// Measured basis (issue #42): the pre-rewrite O(N²) ordering took 1.39 s at
/// N=1000 (ReleaseFast, the old cap); after the adjacency rewrite a mixed
/// chain/fan graph renders end-to-end in ~12 ms at N=1000 and ~66 ms at
/// N=10000, so the caps were raised 10×.
pub const max_nodes: usize = 10_000;
pub const max_edges: usize = 20_000;

/// A `graph.edges` entry with both endpoint ids resolved to `graph.nodes`
/// indices; edges naming unknown ids resolve to null and are skipped by the
/// graph phases (they still render as dangling edges downstream).
const ResolvedEdge = struct { from: usize, to: usize };

/// Compressed sparse row adjacency: `row(u)` is the payload list for node
/// `u`. Rows are filled in global edge order, so per-node iteration matches
/// the edge-scan order of the previous whole-slice implementation — keeping
/// DFS traversal, BFS relaxation, and barycenter float accumulation (and
/// therefore the emitted SVG) byte-identical.
const Csr = struct {
    offsets: []usize,
    data: []usize,

    /// `keys[i]` is the node index owning `payloads[i]`; both are consumed in
    /// order.
    fn init(allocator: std.mem.Allocator, n: usize, keys: []const usize, payloads: []const usize) !Csr {
        const offsets = try allocator.alloc(usize, n + 1);
        errdefer allocator.free(offsets);
        @memset(offsets, 0);
        for (keys) |k| offsets[k + 1] += 1;
        for (1..n + 1) |i| offsets[i] += offsets[i - 1];
        const data = try allocator.alloc(usize, keys.len);
        errdefer allocator.free(data);
        const cursor = try allocator.alloc(usize, n);
        defer allocator.free(cursor);
        @memcpy(cursor, offsets[0..n]);
        for (keys, payloads) |k, p| {
            data[cursor[k]] = p;
            cursor[k] += 1;
        }
        return .{ .offsets = offsets, .data = data };
    }

    fn deinit(self: *Csr, allocator: std.mem.Allocator) void {
        allocator.free(self.offsets);
        allocator.free(self.data);
    }

    fn row(self: *const Csr, u: usize) []const usize {
        return self.data[self.offsets[u]..self.offsets[u + 1]];
    }
};

pub fn layout(allocator: std.mem.Allocator, graph: *Graph) !void {
    if (graph.nodes.len == 0) return;
    if (graph.nodes.len > max_nodes or graph.edges.len > max_edges)
        return error.DiagramTooLarge;

    // Shared id → index map and per-edge resolved endpoints, built once.
    // Valid through phases 0–1; `orderNodes` reorders node structs within
    // their array positions and rebuilds its own view.
    var idx_map = std.StringHashMap(usize).init(allocator);
    defer idx_map.deinit();
    for (graph.nodes, 0..) |n, i| try idx_map.put(n.id, i);

    const resolved = try allocator.alloc(?ResolvedEdge, graph.edges.len);
    defer allocator.free(resolved);
    for (graph.edges, 0..) |e, ei| {
        resolved[ei] = if (idx_map.get(e.from)) |f|
            if (idx_map.get(e.to)) |t| .{ .from = f, .to = t } else null
        else
            null;
    }

    // 0. Break cycles: mark back edges as reversed so BFS layer assignment works
    try breakCycles(allocator, graph, resolved);

    // 1. Assign layers using longest path from sources (respects reversed edges)
    try assignLayers(allocator, graph, &idx_map, resolved);

    // 2. Order nodes with barycenter heuristic to reduce edge crossings
    try orderNodes(allocator, graph);

    // 3. Assign coordinates
    try assignCoordinates(allocator, graph);
}

const NODE_W: f32 = 140;
const NODE_H: f32 = 44;
pub const H_GAP: f32 = 60;
pub const V_GAP: f32 = 80;
const MARGIN: f32 = 40;

fn assignLayers(
    allocator: std.mem.Allocator,
    graph: *Graph,
    idx_map: *const std.StringHashMap(usize),
    resolved: []const ?ResolvedEdge,
) !void {
    var in_degree = try allocator.alloc(usize, graph.nodes.len);
    defer allocator.free(in_degree);
    @memset(in_degree, 0);

    // Reversed edges contribute in-degree to the *from* node (logical target).
    // An edge whose source id is unknown still counts toward its target's
    // in-degree — such edges are never traversed, so that in-degree is never
    // consumed and the target only unlocks through its other in-edges.
    for (graph.edges) |e| {
        const target = if (e.reversed) e.from else e.to;
        const to_idx = idx_map.get(target) orelse continue;
        in_degree[to_idx] += 1;
    }

    // Logical out-adjacency (reversed edges traversed to→from), payload =
    // logical target index.
    var keys: std.ArrayList(usize) = .empty;
    defer keys.deinit(allocator);
    var payloads: std.ArrayList(usize) = .empty;
    defer payloads.deinit(allocator);
    for (graph.edges, 0..) |e, ei| {
        const r = resolved[ei] orelse continue;
        try keys.append(allocator, if (e.reversed) r.to else r.from);
        try payloads.append(allocator, if (e.reversed) r.from else r.to);
    }
    var out = try Csr.init(allocator, graph.nodes.len, keys.items, payloads.items);
    defer out.deinit(allocator);

    // Layer assignment: BFS from sources (in_degree == 0)
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

        for (out.row(cur)) |to_idx| {
            if (layers[to_idx] < cur_layer + 1) {
                layers[to_idx] = cur_layer + 1;
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
fn breakCycles(allocator: std.mem.Allocator, graph: *Graph, resolved: []const ?ResolvedEdge) !void {
    const n = graph.nodes.len;
    if (n == 0) return;

    // Out-adjacency in physical edge direction, payload = edge index (so back
    // edges can be flagged on the real `graph.edges` entry).
    var keys: std.ArrayList(usize) = .empty;
    defer keys.deinit(allocator);
    var payloads: std.ArrayList(usize) = .empty;
    defer payloads.deinit(allocator);
    for (resolved, 0..) |r_opt, ei| {
        const r = r_opt orelse continue;
        try keys.append(allocator, r.from);
        try payloads.append(allocator, ei);
    }
    var out = try Csr.init(allocator, n, keys.items, payloads.items);
    defer out.deinit(allocator);

    // 3-colour DFS: 0 = white, 1 = gray (on stack), 2 = black (done)
    var color = try allocator.alloc(u8, n);
    defer allocator.free(color);
    @memset(color, 0);

    // Iterative DFS to avoid call-stack overflow on large graphs.
    // Each frame stores the node index and the scan position in its
    // out-adjacency row.
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
            const out_edges = out.row(u);

            while (ei < out_edges.len) {
                const edge_idx = out_edges[ei];
                ei += 1;
                const to_idx = resolved[edge_idx].?.to;

                if (color[to_idx] == 1) {
                    graph.edges[edge_idx].reversed = true; // back edge
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
///
/// Node ids are unique (the flowchart parser dedups them), so the stable
/// per-layer sorts here reproduce the old exchange-sort/insertion-sort
/// orderings exactly.
fn orderNodes(allocator: std.mem.Allocator, graph: *Graph) !void {
    const nodes = graph.nodes;
    if (nodes.len == 0) return;

    var max_layer: usize = 0;
    for (nodes) |nd| {
        if (nd.layer > max_layer) max_layer = nd.layer;
    }

    // Per-layer lists of array positions, in array order. Replaces the old
    // fixed scratch arrays whose `% 64` layer indexing corrupted orders past
    // layer 63 and whose `[128]` length silently left nodes past the first
    // 128 in a layer unordered.
    var layer_pos = try allocator.alloc(std.ArrayList(usize), max_layer + 1);
    defer {
        for (layer_pos) |*l| l.deinit(allocator);
        allocator.free(layer_pos);
    }
    for (layer_pos) |*l| l.* = .empty;
    for (nodes, 0..) |nd, ni| try layer_pos[nd.layer].append(allocator, ni);

    // Phase 1: initial alphabetical sort within each layer. Structs are
    // gathered per layer, sorted by id, and scattered back into the same
    // array positions — the layer → positions map of the global array (and
    // therefore SVG paint order) is unchanged.
    {
        var scratch: std.ArrayList(GraphNode) = .empty;
        defer scratch.deinit(allocator);
        for (layer_pos) |*l| {
            if (l.items.len <= 1) continue;
            scratch.clearRetainingCapacity();
            for (l.items) |ni| try scratch.append(allocator, nodes[ni]);
            std.mem.sort(GraphNode, scratch.items, {}, struct {
                fn lessThan(_: void, a: GraphNode, b: GraphNode) bool {
                    return std.mem.order(u8, a.id, b.id) == .lt;
                }
            }.lessThan);
            for (l.items, scratch.items) |ni, sorted_nd| nodes[ni] = sorted_nd;
        }
    }

    // Initial order: rank within layer (array order == id order after Phase 1).
    {
        var lc = try allocator.alloc(usize, max_layer + 1);
        defer allocator.free(lc);
        @memset(lc, 0);
        for (nodes) |*nd| {
            nd.order = lc[nd.layer];
            lc[nd.layer] += 1;
        }
    }

    if (max_layer == 0) return; // single layer — no crossings possible

    // Incidence adjacency in logical direction (neighbour node indices),
    // built after the Phase-1 struct moves and filled in global edge order so
    // each node's barycenter sum accumulates in the old edge-scan order.
    // Matching the old id-equality scan: an edge contributes one incidence to
    // its logical source (neighbour = target) unless only the target matches
    // (neighbour = source); a self-loop therefore contributes once.
    var idx_map = std.StringHashMap(usize).init(allocator);
    defer idx_map.deinit();
    for (nodes, 0..) |nd, i| try idx_map.put(nd.id, i);

    var inc = blk: {
        var keys: std.ArrayList(usize) = .empty;
        defer keys.deinit(allocator);
        var payloads: std.ArrayList(usize) = .empty;
        defer payloads.deinit(allocator);
        for (graph.edges) |e| {
            const fid = if (e.reversed) e.to else e.from;
            const tid = if (e.reversed) e.from else e.to;
            const fi = idx_map.get(fid);
            const ti = idx_map.get(tid);
            if (fi) |f| if (ti) |t| {
                try keys.append(allocator, f);
                try payloads.append(allocator, t);
                if (f != t) {
                    try keys.append(allocator, t);
                    try payloads.append(allocator, f);
                }
            };
        }
        break :blk try Csr.init(allocator, nodes.len, keys.items, payloads.items);
    };
    defer inc.deinit(allocator);

    // Phase 2: barycenter heuristic — 3 down + 3 up alternating sweeps.
    var bary = try allocator.alloc(f32, nodes.len);
    defer allocator.free(bary);

    var scratch_idx: std.ArrayList(usize) = .empty;
    defer scratch_idx.deinit(allocator);

    for (0..6) |pass| {
        const down = (pass % 2 == 0);
        for (0..max_layer + 1) |li| {
            const layer: usize = if (down) li else max_layer - li;
            // Reference layer: the already-fixed adjacent layer in sweep direction.
            const ref_signed: i64 = @as(i64, @intCast(layer)) + if (down) @as(i64, -1) else @as(i64, 1);
            if (ref_signed < 0 or ref_signed > @as(i64, @intCast(max_layer))) continue;
            const ref_layer: usize = @intCast(ref_signed);

            // Compute barycenter for each node in `layer` (array order).
            for (layer_pos[layer].items) |ni| {
                var sum: f32 = 0;
                var cnt: u32 = 0;
                for (inc.row(ni)) |nbi| {
                    if (nodes[nbi].layer == ref_layer) {
                        sum += @floatFromInt(nodes[nbi].order);
                        cnt += 1;
                    }
                }
                bary[ni] = if (cnt > 0)
                    sum / @as(f32, @floatFromInt(cnt))
                else
                    @as(f32, @floatFromInt(nodes[ni].order));
            }

            // Stable-sort a copy of this layer's positions by bary (fresh
            // array-order input each pass, like the old re-collected idxs),
            // then reassign contiguous orders.
            scratch_idx.clearRetainingCapacity();
            try scratch_idx.appendSlice(allocator, layer_pos[layer].items);
            std.mem.sort(usize, scratch_idx.items, bary, struct {
                fn lessThan(b: []const f32, x: usize, y: usize) bool {
                    return b[x] < b[y];
                }
            }.lessThan);
            for (scratch_idx.items, 0..) |ni, ord| {
                nodes[ni].order = ord;
            }
        }
    }

    // Final pass: cluster subgraph members within each layer.
    // For each layer, compute group centroid (mean order of members with same
    // subgraph id), then stable-sort by (group_centroid, member_order) so
    // same-subgraph nodes are adjacent while the group sits at its
    // barycenter-computed position.
    {
        const Group = struct { sum: f32, cnt: usize };
        var groups = std.AutoHashMap(usize, Group).init(allocator);
        defer groups.deinit();

        const Entry = struct { ni: usize, cent: f32, ord: usize };
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(allocator);

        var layer: usize = 0;
        while (layer <= max_layer) : (layer += 1) {
            const items = layer_pos[layer].items;
            if (items.len <= 1) continue;

            // Group sums accumulate in layer order — the same order the old
            // pairwise scan added members, so centroids are float-identical.
            groups.clearRetainingCapacity();
            for (items) |ni| {
                const sg = nodes[ni].subgraph;
                if (sg == std.math.maxInt(usize)) continue;
                const g = try groups.getOrPut(sg);
                if (!g.found_existing) g.value_ptr.* = .{ .sum = 0, .cnt = 0 };
                g.value_ptr.sum += @floatFromInt(nodes[ni].order);
                g.value_ptr.cnt += 1;
            }

            entries.clearRetainingCapacity();
            for (items) |ni| {
                const sg = nodes[ni].subgraph;
                const cent: f32 = if (sg == std.math.maxInt(usize))
                    @floatFromInt(nodes[ni].order)
                else blk: {
                    const g = groups.get(sg).?;
                    break :blk g.sum / @as(f32, @floatFromInt(g.cnt));
                };
                try entries.append(allocator, .{ .ni = ni, .cent = cent, .ord = nodes[ni].order });
            }

            std.mem.sort(Entry, entries.items, {}, struct {
                fn lessThan(_: void, a: Entry, b: Entry) bool {
                    if (a.cent != b.cent) return a.cent < b.cent;
                    return a.ord < b.ord;
                }
            }.lessThan);
            for (entries.items, 0..) |en, ord| {
                nodes[en.ni].order = ord;
            }
        }
    }
}

fn assignCoordinates(allocator: std.mem.Allocator, graph: *Graph) !void {
    // Determine how many nodes per layer.
    var max_layer: usize = 0;
    for (graph.nodes) |n| {
        if (n.layer > max_layer) max_layer = n.layer;
    }
    var layer_counts = try allocator.alloc(usize, max_layer + 1);
    defer allocator.free(layer_counts);
    @memset(layer_counts, 0);
    for (graph.nodes) |n| {
        layer_counts[n.layer] += 1;
    }

    // Assign coordinates centered around origin; translateNodes shifts to MARGIN.
    for (graph.nodes) |*n| {
        const per_layer = layer_counts[n.layer];
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
    const resolved = [_]?ResolvedEdge{ .{ .from = 0, .to = 1 }, .{ .from = 1, .to = 0 } };
    try breakCycles(testing.allocator, &g, &resolved);
    var any_reversed = false;
    for (edges) |e| if (e.reversed) {
        any_reversed = true;
    };
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

test "layout deep chain: one node per layer, single column" {
    // 70 layers exceeded the old fixed [64] layer-count arrays; the `% 64`
    // wraparound aliased layer n onto layer n mod 64, giving nodes past layer
    // 63 phantom siblings and shifting them sideways. Correct layout: every
    // layer holds exactly one node, so orders are all zero and the whole chain
    // is one column wide.
    const n = 70;
    var id_buf: [n][3]u8 = undefined;
    var nodes: [n]GraphNode = undefined;
    var edges: [n - 1]GraphEdge = undefined;
    for (0..n) |i| {
        id_buf[i] = .{ 'n', '0' + @as(u8, @intCast(i / 10)), '0' + @as(u8, @intCast(i % 10)) };
        nodes[i] = makeNode(&id_buf[i]);
    }
    for (0..n - 1) |i| edges[i] = makeEdge(&id_buf[i], &id_buf[i + 1]);
    var g: Graph = .{ .nodes = &nodes, .edges = &edges, .direction = .tb };
    try layout(testing.allocator, &g);
    for (nodes, 0..) |nd, i| {
        try testing.expectEqual(i, nd.layer);
        try testing.expectEqual(@as(usize, 0), nd.order);
        try testing.expectEqual(nodes[0].x, nd.x);
    }
    // One column: MARGIN + NODE_W + MARGIN.
    try testing.expectEqual(@as(u32, 220), svgWidth(&nodes));
}

test "layout wide layer: barycenter orders all 200 children" {
    // The old barycenter/clustering passes used fixed [128] scratch arrays and
    // silently skipped nodes past the first 128 in a layer. With two roots and
    // 200 children alternating between them, a full barycenter pass must give
    // each root's children one contiguous order block.
    const kids = 200;
    var id_buf: [kids][4]u8 = undefined;
    var nodes: [kids + 2]GraphNode = undefined;
    var edges: [kids]GraphEdge = undefined;
    nodes[0] = makeNode("r1");
    nodes[1] = makeNode("r2");
    for (0..kids) |i| {
        id_buf[i] = .{
            'c',
            '0' + @as(u8, @intCast(i / 100)),
            '0' + @as(u8, @intCast((i / 10) % 10)),
            '0' + @as(u8, @intCast(i % 10)),
        };
        nodes[i + 2] = makeNode(&id_buf[i]);
        edges[i] = makeEdge(if (i % 2 == 0) "r1" else "r2", &id_buf[i]);
    }
    var g: Graph = .{ .nodes = &nodes, .edges = &edges, .direction = .tb };
    try layout(testing.allocator, &g);
    // Orders within the child layer must be a permutation of 0..199 …
    var seen: [kids]bool = @splat(false);
    for (nodes) |nd| {
        if (nd.layer != 1) continue;
        try testing.expect(nd.order < kids);
        try testing.expect(!seen[nd.order]);
        seen[nd.order] = true;
    }
    // … and every r1 child must sort before every r2 child (bary 0 vs 1).
    var max_r1: usize = 0;
    var min_r2: usize = std.math.maxInt(usize);
    for (nodes, 0..) |nd, ni| {
        if (ni < 2) continue;
        const child_i = ni - 2;
        _ = child_i;
        // Recover the parent from the id parity encoded above.
        const idx = (@as(usize, nd.id[1] - '0') * 100) +
            (@as(usize, nd.id[2] - '0') * 10) + @as(usize, nd.id[3] - '0');
        if (idx % 2 == 0) {
            if (nd.order > max_r1) max_r1 = nd.order;
        } else {
            if (nd.order < min_r2) min_r2 = nd.order;
        }
    }
    try testing.expect(max_r1 < min_r2);
}

test "layout coordinate snapshot: fork/join with back edge" {
    // Exact coordinates recorded from the pre-rewrite O(N²) implementation —
    // the adjacency-list rewrite must reproduce them byte-for-byte.
    var nodes = [_]GraphNode{
        makeNode("A"), makeNode("B"), makeNode("C"), makeNode("D"), makeNode("E"),
        makeNode("F"), makeNode("G"), makeNode("H"), makeNode("I"), makeNode("J"),
    };
    var edges = [_]GraphEdge{
        makeEdge("A", "B"), makeEdge("A", "C"), makeEdge("A", "D"),
        makeEdge("B", "E"), makeEdge("C", "E"), makeEdge("D", "F"),
        makeEdge("E", "G"), makeEdge("F", "G"), makeEdge("G", "H"),
        makeEdge("H", "I"), makeEdge("I", "J"), makeEdge("J", "E"),
    };
    var g: Graph = .{ .nodes = &nodes, .edges = &edges, .direction = .tb };
    try layout(testing.allocator, &g);
    const expected = [_]struct { []const u8, usize, usize, f32, f32 }{
        .{ "A", 0, 0, 240, 40 },
        .{ "B", 1, 0, 40, 164 },
        .{ "C", 1, 1, 240, 164 },
        .{ "D", 1, 2, 440, 164 },
        .{ "E", 2, 0, 140, 288 },
        .{ "F", 2, 1, 340, 288 },
        .{ "G", 3, 0, 240, 412 },
        .{ "H", 4, 0, 240, 536 },
        .{ "I", 5, 0, 240, 660 },
        .{ "J", 6, 0, 240, 784 },
    };
    for (expected) |exp| {
        for (nodes) |nd| {
            if (!std.mem.eql(u8, nd.id, exp[0])) continue;
            try testing.expectEqual(exp[1], nd.layer);
            try testing.expectEqual(exp[2], nd.order);
            try testing.expectEqual(exp[3], nd.x);
            try testing.expectEqual(exp[4], nd.y);
        }
    }
}

test "translateNodes: minimum coordinate shifted to MARGIN" {
    var nodes = [_]GraphNode{makeNode("A")};
    var edges = [_]GraphEdge{};
    var g: Graph = .{ .nodes = &nodes, .edges = &edges, .direction = .tb };
    try layout(testing.allocator, &g);
    // After translate, minimum x and y should be >= MARGIN
    try testing.expect(nodes[0].x >= MARGIN - 0.1);
    try testing.expect(nodes[0].y >= MARGIN - 0.1);
}
