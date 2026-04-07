//! pozeiden CLI: renders mermaid diagrams to SVG.
//!
//! Usage:
//!   pozeiden [-i input.mmd] [-o output.svg]
//!
//! With no arguments, reads from stdin and writes to stdout.
const std = @import("std");
const pozeiden = @import("pozeiden");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-i") and i + 1 < args.len) {
            i += 1;
            input_path = args[i];
        } else if (std.mem.eql(u8, args[i], "-o") and i + 1 < args.len) {
            i += 1;
            output_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            try std.fs.File.stderr().writeAll(
                \\Usage: pozeiden [-i input.mmd] [-o output.svg]
                \\
                \\Reads mermaid diagram text and writes an SVG.
                \\With no arguments reads stdin and writes stdout.
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

    // Render
    const svg = try pozeiden.render(allocator, input);
    defer allocator.free(svg);

    // Write output
    if (output_path) |path| {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(svg);
    } else {
        try std.fs.File.stdout().writeAll(svg);
    }
}
