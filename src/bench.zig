const std = @import("std");
const pozeiden = @import("pozeiden");

const ITERS: usize = 1000;
const MMDC_ITERS: usize = 3;

const example_names = [_][]const u8{
    "pie", "flowchart", "sequence", "gitgraph", "class",
    "state", "er", "gantt", "timeline", "xychart",
    "quadrant", "mindmap", "sankey", "c4",
    "block", "requirement", "kanban",
};

fn println(line: []const u8) !void {
    try std.fs.File.stdout().writeAll(line);
}

fn mmdcAvailable(allocator: std.mem.Allocator) bool {
    var child = std.process.Child.init(&.{ "mmdc", "--version" }, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return term == .Exited;
}

fn benchMmdc(allocator: std.mem.Allocator, name: []const u8, iters: usize) !struct { min: i128, mean: i128, max: i128 } {
    var path_buf: [64]u8 = undefined;
    const input_path = try std.fmt.bufPrint(&path_buf, "examples/{s}.mmd", .{name});

    var out_path_buf: [64]u8 = undefined;
    const out_path = try std.fmt.bufPrint(&out_path_buf, "/tmp/pozeiden_bench_{s}.svg", .{name});

    var min_ns: i128 = std.math.maxInt(i128);
    var max_ns: i128 = 0;
    var total_ns: i128 = 0;

    for (0..iters) |_| {
        const t1 = std.time.nanoTimestamp();
        var child = std.process.Child.init(
            &.{ "mmdc", "-i", input_path, "-o", out_path },
            allocator,
        );
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        _ = try child.wait();
        const t2 = std.time.nanoTimestamp();
        const elapsed = t2 - t1;
        if (elapsed < min_ns) min_ns = elapsed;
        if (elapsed > max_ns) max_ns = elapsed;
        total_ns += elapsed;
    }

    return .{
        .min = min_ns,
        .mean = @divTrunc(total_ns, @as(i128, iters)),
        .max = max_ns,
    };
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var line_buf: [320]u8 = undefined;

    // ── pozeiden benchmark ────────────────────────────────────────────────────
    try println("### Render time\n\n");
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

    // ── mermaid-cli comparison ────────────────────────────────────────────────
    if (!mmdcAvailable(allocator)) {
        try println("\n(mermaid-cli not found in PATH — skipping comparison; add it via `nix develop`)\n");
        return;
    }

    try println(try std.fmt.bufPrint(&line_buf,
        "\n### vs mermaid-cli ({d} iterations each)\n\n",
        .{MMDC_ITERS}));
    try println(try std.fmt.bufPrint(&line_buf,
        "| {s:<12} | {s:>10} | {s:>10} | {s:>8} |\n",
        .{ "diagram", "poz_µs", "mmdc_µs", "speedup" }));
    try println(try std.fmt.bufPrint(&line_buf,
        "|{s:-<14}|{s:->12}|{s:->12}|{s:->10}|\n",
        .{ "-", "-", "-", "-" }));

    // Re-run pozeiden with MMDC_ITERS so the comparison is on the same sample size.
    for (example_names) |name| {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "examples/{s}.mmd", .{name});
        const src = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        defer allocator.free(src);

        var poz_total: i128 = 0;
        for (0..MMDC_ITERS) |_| {
            const t1 = std.time.nanoTimestamp();
            const svg = try pozeiden.render(allocator, src);
            const t2 = std.time.nanoTimestamp();
            allocator.free(svg);
            poz_total += t2 - t1;
        }
        const poz_mean = @divTrunc(poz_total, @as(i128, MMDC_ITERS));

        const mmdc = try benchMmdc(allocator, name, MMDC_ITERS);

        const speedup = @as(f64, @floatFromInt(mmdc.mean)) / @as(f64, @floatFromInt(poz_mean));
        try println(try std.fmt.bufPrint(&line_buf,
            "| {s:<12} | {d:>10.1} | {d:>10.1} | {d:>7.1}x |\n", .{
            name,
            @as(f64, @floatFromInt(poz_mean)) / 1000.0,
            @as(f64, @floatFromInt(mmdc.mean)) / 1000.0,
            speedup,
        }));
    }
}
