//! pozeiden CLI: renders mermaid diagrams to SVG.
//!
//! Usage:
//!   pozeiden [-i input.mmd] [-o output.svg] [--format svg|json] [--version]
//!
//! With no arguments, reads from stdin and writes to stdout.
//!
//! --format json wraps the SVG in a JSON envelope:
//!   {"svg":"...","diagram_type":"flowchart"}
const std = @import("std");

const pozeiden = @import("pozeiden");
const config = @import("config");

const Format = enum { svg, json };

// Cap input size to avoid unbounded allocation / OOM on huge or malformed input.
const max_input_bytes = 16 * 1024 * 1024; // 16 MiB

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_it.skip(); // skip argv[0]

    var input_path: ?[:0]const u8 = null;
    var output_path: ?[:0]const u8 = null;
    var format: Format = .svg;

    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-i")) {
            input_path = arg_it.next() orelse {
                try std.Io.File.stderr().writeStreamingAll(io, "error: -i requires a file path\n");
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-o")) {
            output_path = arg_it.next() orelse {
                try std.Io.File.stderr().writeStreamingAll(io, "error: -o requires a file path\n");
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--format")) {
            const fmt = arg_it.next() orelse {
                try std.Io.File.stderr().writeStreamingAll(io, "error: --format requires a value (svg or json)\n");
                std.process.exit(1);
            };
            if (std.mem.eql(u8, fmt, "json")) {
                format = .json;
            } else if (!std.mem.eql(u8, fmt, "svg")) {
                try std.Io.File.stderr().writeStreamingAll(io, "error: --format must be svg or json\n");
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            try std.Io.File.stdout().writeStreamingAll(io, config.version ++ "\n");
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.Io.File.stderr().writeStreamingAll(io,
                \\Usage: pozeiden [-i input.mmd] [-o output.svg] [--format svg|json]
                \\
                \\Reads mermaid diagram text and writes an SVG (default) or JSON envelope.
                \\With no arguments reads stdin and writes stdout.
                \\
                \\Options:
                \\  -i <file>        Input .mmd file (default: stdin)
                \\  -o <file>        Output file (default: stdout)
                \\  --format svg     Output raw SVG (default)
                \\  --format json    Output JSON: {"svg":"...","diagram_type":"..."}
                \\  --version, -V    Print version and exit
                \\  --help, -h       Print this help and exit
                \\
            );
            return;
        } else {
            try std.Io.File.stderr().writeStreamingAll(io, "error: unknown argument '");
            try std.Io.File.stderr().writeStreamingAll(io, arg);
            try std.Io.File.stderr().writeStreamingAll(io, "'\n");
            std.process.exit(1);
        }
    }

    // Read input
    const input = if (input_path) |path| blk: {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var rbuf: [4096]u8 = undefined;
        var rdr = file.reader(io, &rbuf);
        break :blk try rdr.interface.allocRemaining(allocator, .limited(max_input_bytes));
    } else blk: {
        var rbuf: [4096]u8 = undefined;
        var rdr = std.Io.File.stdin().reader(io, &rbuf);
        break :blk try rdr.interface.allocRemaining(allocator, .limited(max_input_bytes));
    };
    defer allocator.free(input);

    // Detect diagram type before rendering (needed for JSON output)
    const diagram_type = pozeiden.detectDiagramType(input);

    // Render
    const svg = try pozeiden.render(allocator, input);
    defer allocator.free(svg);

    // Build output bytes
    const output_bytes: []const u8 = switch (format) {
        .svg => svg,
        .json => blk: {
            const type_name = @tagName(diagram_type);
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            try buf.appendSlice(allocator, "{\"svg\":\"");
            for (svg) |c| {
                switch (c) {
                    '"' => try buf.appendSlice(allocator, "\\\""),
                    '\\' => try buf.appendSlice(allocator, "\\\\"),
                    '\n' => try buf.appendSlice(allocator, "\\n"),
                    '\r' => try buf.appendSlice(allocator, "\\r"),
                    else => try buf.append(allocator, c),
                }
            }
            try buf.print(allocator, "\",\"diagram_type\":\"{s}\"}}\n", .{type_name});
            break :blk try buf.toOwnedSlice(allocator);
        },
    };
    defer if (format == .json) allocator.free(output_bytes);

    // Write output
    if (output_path) |path| {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, output_bytes);
    } else {
        try std.Io.File.stdout().writeStreamingAll(io, output_bytes);
    }
}
