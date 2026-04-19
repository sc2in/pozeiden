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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var format: Format = .svg;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-i") and i + 1 < args.len) {
            i += 1;
            input_path = args[i];
        } else if (std.mem.eql(u8, args[i], "-o") and i + 1 < args.len) {
            i += 1;
            output_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--format") and i + 1 < args.len) {
            i += 1;
            if (std.mem.eql(u8, args[i], "json")) {
                format = .json;
            } else if (!std.mem.eql(u8, args[i], "svg")) {
                try std.fs.File.stderr().writeAll("error: --format must be svg or json\n");
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, args[i], "--version") or std.mem.eql(u8, args[i], "-V")) {
            try std.fs.File.stdout().writeAll(config.version ++ "\n");
            return;
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            try std.fs.File.stderr().writeAll(
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
        }
    }

    // Read input
    const input = if (input_path) |path| blk: {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    } else blk: {
        break :blk try std.fs.File.stdin().readToEndAlloc(allocator, 16 * 1024 * 1024);
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
            var buf = std.ArrayList(u8){};
            errdefer buf.deinit(allocator);
            const w = buf.writer(allocator);
            try w.writeAll("{\"svg\":\"");
            for (svg) |c| {
                switch (c) {
                    '"' => try w.writeAll("\\\""),
                    '\\' => try w.writeAll("\\\\"),
                    '\n' => try w.writeAll("\\n"),
                    '\r' => try w.writeAll("\\r"),
                    else => try w.writeByte(c),
                }
            }
            try w.print("\",\"diagram_type\":\"{s}\"}}\n", .{type_name});
            break :blk try buf.toOwnedSlice(allocator);
        },
    };
    defer if (format == .json) allocator.free(output_bytes);

    // Write output
    if (output_path) |path| {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(output_bytes);
    } else {
        try std.fs.File.stdout().writeAll(output_bytes);
    }
}
