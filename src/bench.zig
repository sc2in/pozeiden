const std = @import("std");
const pozeiden = @import("pozeiden");

const ITERS: usize = 1000;

const example_names = [_][]const u8{
    "pie", "flowchart", "sequence", "gitgraph", "class",
    "state", "er", "gantt", "timeline", "xychart",
    "quadrant", "mindmap", "sankey", "c4",
    "block", "requirement", "kanban",
};

fn println(line: []const u8) !void {
    try std.fs.File.stdout().writeAll(line);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var line_buf: [256]u8 = undefined;

    try println(try std.fmt.bufPrint(&line_buf,
        "| {s:<12} | {s:>5} | {s:>8} | {s:>9} | {s:>8} |\n",
        .{ "diagram", "iters", "min_µs", "mean_µs", "max_µs" }));
    try println(try std.fmt.bufPrint(&line_buf,
        "|{s:-<14}|{s:->7}|{s:->10}|{s:->11}|{s:->10}|\n",
        .{ "-", "-", "-", "-", "-" }));

    for (example_names) |name| {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "examples/{s}.mmd", .{name});
        const src = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        defer allocator.free(src);

        var min_ns: i128 = std.math.maxInt(i128);
        var max_ns: i128 = 0;
        var total_ns: i128 = 0;

        for (0..ITERS) |_| {
            const t1 = std.time.nanoTimestamp();
            const svg = try pozeiden.render(allocator, src);
            const t2 = std.time.nanoTimestamp();
            allocator.free(svg);
            const elapsed = t2 - t1;
            if (elapsed < min_ns) min_ns = elapsed;
            if (elapsed > max_ns) max_ns = elapsed;
            total_ns += elapsed;
        }

        const mean_ns = @divTrunc(total_ns, @as(i128, ITERS));
        try println(try std.fmt.bufPrint(&line_buf,
            "| {s:<12} | {d:>5} | {d:>8.1} | {d:>9.1} | {d:>8.1} |\n", .{
            name, ITERS,
            @as(f64, @floatFromInt(min_ns)) / 1000.0,
            @as(f64, @floatFromInt(mean_ns)) / 1000.0,
            @as(f64, @floatFromInt(max_ns)) / 1000.0,
        }));
    }
}
