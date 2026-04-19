const std = @import("std");
const pozeiden = @import("pozeiden");

test "fuzz_render" {
    try std.testing.fuzz({}, fuzzRender, .{});
}

fn fuzzRender(_: void, input: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const svg = pozeiden.render(arena.allocator(), input) catch return;
    _ = svg;
}

test "fuzz_detect" {
    try std.testing.fuzz({}, fuzzDetect, .{});
}

fn fuzzDetect(_: void, input: []const u8) anyerror!void {
    _ = pozeiden.detectDiagramType(input);
}

test "fuzz_render_strict" {
    try std.testing.fuzz({}, fuzzRenderStrict, .{});
}

fn fuzzRenderStrict(_: void, input: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const svg = pozeiden.renderWithOptions(arena.allocator(), input, .{ .strict = true }) catch return;
    _ = svg;
}
