//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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

// Io context captured in main; println keeps its call sites one-liners.
var g_io: std.Io = undefined;

fn println(line: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(g_io, line);
}

fn nowNs() i128 {
    return std.Io.Clock.now(.awake, g_io).nanoseconds;
}

fn readExample(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(g_io, path, .{});
    defer file.close(g_io);
    var rbuf: [4096]u8 = undefined;
    var rdr = file.reader(g_io, &rbuf);
    return rdr.interface.allocRemaining(allocator, .limited(1024 * 1024));
}

fn mmdcAvailable() bool {
    var child = std.process.spawn(g_io, .{
        .argv = &.{ "mmdc", "--version" },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(g_io) catch return false;
    return term == .exited;
}

fn benchMmdc(name: []const u8, iters: usize) !struct { min: i128, mean: i128, max: i128 } {
    var path_buf: [64]u8 = undefined;
    const input_path = try std.fmt.bufPrint(&path_buf, "examples/{s}.mmd", .{name});

    var out_path_buf: [64]u8 = undefined;
    const out_path = try std.fmt.bufPrint(&out_path_buf, "/tmp/pozeiden_bench_{s}.svg", .{name});

    var min_ns: i128 = std.math.maxInt(i128);
    var max_ns: i128 = 0;
    var total_ns: i128 = 0;

    for (0..iters) |_| {
        const t1 = nowNs();
        var child = try std.process.spawn(g_io, .{
            .argv = &.{ "mmdc", "-i", input_path, "-o", out_path },
            .stdout = .ignore,
            .stderr = .ignore,
        });
        _ = try child.wait(g_io);
        const t2 = nowNs();
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

pub fn main(init: std.process.Init) !void {
    g_io = init.io;
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
        const src = try readExample(allocator, path);
        defer allocator.free(src);

        var min_ns: i128 = std.math.maxInt(i128);
        var max_ns: i128 = 0;
        var total_ns: i128 = 0;

        for (0..ITERS) |_| {
            const t1 = nowNs();
            const svg = try pozeiden.render(allocator, src);
            const t2 = nowNs();
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
    if (!mmdcAvailable()) {
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
        const src = try readExample(allocator, path);
        defer allocator.free(src);

        var poz_total: i128 = 0;
        for (0..MMDC_ITERS) |_| {
            const t1 = nowNs();
            const svg = try pozeiden.render(allocator, src);
            const t2 = nowNs();
            allocator.free(svg);
            poz_total += t2 - t1;
        }
        const poz_mean = @divTrunc(poz_total, @as(i128, MMDC_ITERS));

        const mmdc = try benchMmdc(name, MMDC_ITERS);

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
