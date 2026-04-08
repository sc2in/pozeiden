//! Git graph SVG renderer.
//! Draws parallel horizontal lanes (one per branch), commit circles, and merge edges.
//! Expects a Value.node with `statements` (list of typed nodes): Branch (`name`),
//! Checkout (`branch`), Commit (`id`, `message`, `type`), and Merge (`branch`, `id`).
const std = @import("std");
const Value = @import("../diagram/value.zig").Value;
const SvgWriter = @import("../svg/writer.zig").SvgWriter;
const theme = @import("../svg/theme.zig");

const LANE_H: f32 = 60;
const COMMIT_R: f32 = 12;
const COMMIT_STEP: f32 = 80;
const MARGIN_X: f32 = 60;
const MARGIN_Y: f32 = 40;
const LABEL_W: f32 = 80;

// Branch lane colors cycling through theme pie palette (reuse for variety)
const BRANCH_COLORS = [_][]const u8{
    "#6466f1", "#22c55e", "#f59e0b", "#ef4444",
    "#06b6d4", "#a855f7", "#ec4899", "#84cc16",
};

const Commit = struct {
    id: []const u8,
    branch: []const u8,
    label: []const u8,
    commit_type: []const u8, // "NORMAL", "REVERSE", "HIGHLIGHT"
    merge_from: ?[]const u8, // branch name being merged if this is a merge commit
    x: f32 = 0,
    y: f32 = 0,
};

const Branch = struct {
    name: []const u8,
    lane: usize,
    color: []const u8,
};

/// Render a git graph SVG from `value`.
/// `value` must be a node with a `statements` list of typed nodes: Branch (`name`),
/// Checkout (`branch`), Commit (`id`, `message`, `type`), and Merge (`branch`, `id`).
/// Each branch is assigned a horizontal lane; commits are drawn left to right over time.
pub fn render(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    const node = value.asNode() orelse return renderFallback(allocator);

    // Use an arena for all intermediate state; only the final SVG string is returned
    // via the caller's allocator.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var branches: std.ArrayList(Branch) = .empty;
    var commits: std.ArrayList(Commit) = .empty;

    // "main" is always the first branch
    try branches.append(a, Branch{ .name = "main", .lane = 0, .color = BRANCH_COLORS[0] });

    var current_branch: []const u8 = "main";
    var commit_counter: usize = 0;

    // Per-branch commit counter (for x positioning)
    var branch_x = std.StringHashMap(f32).init(a);
    try branch_x.put("main", MARGIN_X);

    const stmts = node.getList("statements");
    for (stmts) |sv| {
        const sn = sv.asNode() orelse continue;
        const type_name = sn.type_name;

        if (std.mem.eql(u8, type_name, "Branch")) {
            const name = sn.getString("name") orelse continue;
            if (!hasBranch(branches.items, name)) {
                const lane = branches.items.len;
                const color = BRANCH_COLORS[lane % BRANCH_COLORS.len];
                try branches.append(a, Branch{ .name = name, .lane = lane, .color = color });
                // Inherit x position from current branch
                const cur_x = branch_x.get(current_branch) orelse MARGIN_X;
                try branch_x.put(name, cur_x);
            }
        } else if (std.mem.eql(u8, type_name, "Checkout")) {
            const br = sn.getString("branch") orelse continue;
            current_branch = br;
        } else if (std.mem.eql(u8, type_name, "Commit")) {
            var id_buf: [32]u8 = undefined;
            const id = sn.getString("id") orelse blk: {
                commit_counter += 1;
                break :blk try std.fmt.bufPrint(&id_buf, "c{d}", .{commit_counter});
            };
            const msg = sn.getString("message") orelse id;
            const ctype = sn.getString("type") orelse "NORMAL";

            const cur_x = branch_x.get(current_branch) orelse MARGIN_X;
            const new_x = cur_x + COMMIT_STEP;
            try branch_x.put(current_branch, new_x);

            const lane = branchLane(branches.items, current_branch) orelse 0;
            const y = MARGIN_Y + @as(f32, @floatFromInt(lane)) * LANE_H + LANE_H / 2;

            const id_owned = try a.dupe(u8, id);
            const msg_owned = try a.dupe(u8, msg);
            const branch_owned = try a.dupe(u8, current_branch);
            const ctype_owned = try a.dupe(u8, ctype);
            try commits.append(a, Commit{
                .id = id_owned,
                .branch = branch_owned,
                .label = msg_owned,
                .commit_type = ctype_owned,
                .merge_from = null,
                .x = new_x,
                .y = y,
            });
        } else if (std.mem.eql(u8, type_name, "Merge")) {
            const target_branch = sn.getString("branch") orelse continue;
            const merge_id = sn.getString("id") orelse blk: {
                commit_counter += 1;
                const b = try std.fmt.allocPrint(a, "m{d}", .{commit_counter});
                break :blk b;
            };

            const cur_x = branch_x.get(current_branch) orelse MARGIN_X;
            const new_x = cur_x + COMMIT_STEP;
            try branch_x.put(current_branch, new_x);

            const lane = branchLane(branches.items, current_branch) orelse 0;
            const y = MARGIN_Y + @as(f32, @floatFromInt(lane)) * LANE_H + LANE_H / 2;

            const target_owned = try a.dupe(u8, target_branch);
            const cur_owned = try a.dupe(u8, current_branch);
            try commits.append(a, Commit{
                .id = merge_id,
                .branch = cur_owned,
                .label = "",
                .commit_type = "NORMAL",
                .merge_from = target_owned,
                .x = new_x,
                .y = y,
            });
        }
    }

    if (commits.items.len == 0) return renderFallback(allocator);

    // Calculate SVG dimensions
    var max_x: f32 = MARGIN_X;
    {
        var it = branch_x.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* > max_x) max_x = entry.value_ptr.*;
        }
    }
    const svg_w: u32 = @intFromFloat(max_x + MARGIN_X + LABEL_W);
    const svg_h: u32 = @intFromFloat(MARGIN_Y * 2 + @as(f32, @floatFromInt(branches.items.len)) * LANE_H);

    var svg = SvgWriter.init(allocator);
    defer svg.deinit();

    try svg.header(svg_w, svg_h);
    // Background
    try svg.rect(0, 0, @floatFromInt(svg_w), @floatFromInt(svg_h), 0, theme.background, theme.background, 0);

    // Draw branch lane lines
    for (branches.items) |br| {
        const y = MARGIN_Y + @as(f32, @floatFromInt(br.lane)) * LANE_H + LANE_H / 2;
        const lane_end_x = max_x + COMMIT_STEP / 2;
        try svg.line(MARGIN_X / 2, y, lane_end_x, y, br.color, 2.0);
        // Branch label on right
        try svg.text(lane_end_x + 8, y + 4, br.name, br.color, theme.font_size_small, .start, "bold");
    }

    // Draw merge edges (connect last commit on merge_from branch to this commit)
    for (commits.items, 0..) |c, ci| {
        if (c.merge_from) |from_branch| {
            // Find the last commit on from_branch before this commit index
            const from_commit = lastCommitOnBranch(commits.items[0..ci], from_branch);
            if (from_commit) |fc| {
                try svg.line(fc.x, fc.y, c.x, c.y, theme.signal_color, 1.5);
            }
        }
        // Connect consecutive commits on same branch
        if (ci > 0) {
            const prev = findPrevOnBranch(commits.items[0..ci], c.branch);
            if (prev) |pc| {
                const br = getBranch(branches.items, c.branch);
                const color = if (br) |b| b.color else theme.signal_color;
                try svg.line(pc.x, pc.y, c.x, c.y, color, 2.0);
            }
        }
    }

    // Draw commit circles
    for (commits.items) |c| {
        const br = getBranch(branches.items, c.branch);
        const color = if (br) |b| b.color else theme.node_fill;
        const fill = if (std.mem.eql(u8, c.commit_type, "HIGHLIGHT")) color else theme.background;
        const stroke = color;
        try svg.circle(c.x, c.y, COMMIT_R, fill, stroke, 2.5);
        // Commit label below circle
        if (c.label.len > 0 and !std.mem.eql(u8, c.label, c.id)) {
            try svg.text(c.x, c.y + COMMIT_R + 14, c.label, theme.text_color, theme.font_size_small, .middle, "normal");
        }
    }

    try svg.footer();
    return svg.toOwnedSlice();
}

fn hasBranch(branches: []const Branch, name: []const u8) bool {
    for (branches) |b| if (std.mem.eql(u8, b.name, name)) return true;
    return false;
}

fn branchLane(branches: []const Branch, name: []const u8) ?usize {
    for (branches) |b| if (std.mem.eql(u8, b.name, name)) return b.lane;
    return null;
}

fn getBranch(branches: []const Branch, name: []const u8) ?Branch {
    for (branches) |b| if (std.mem.eql(u8, b.name, name)) return b;
    return null;
}

fn lastCommitOnBranch(commits: []const Commit, branch: []const u8) ?*const Commit {
    var result: ?*const Commit = null;
    for (commits) |*c| {
        if (std.mem.eql(u8, c.branch, branch)) result = c;
    }
    return result;
}

fn findPrevOnBranch(commits: []const Commit, branch: []const u8) ?*const Commit {
    var result: ?*const Commit = null;
    for (commits) |*c| {
        if (std.mem.eql(u8, c.branch, branch)) result = c;
    }
    return result;
}

fn renderFallback(allocator: std.mem.Allocator) ![]const u8 {
    var svg = SvgWriter.init(allocator);
    defer svg.deinit();
    try svg.header(400, 200);
    try svg.text(200, 100, "gitGraph", theme.text_color, theme.font_size, .middle, "normal");
    try svg.footer();
    return svg.toOwnedSlice();
}
