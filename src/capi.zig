//! C ABI entry points for libpozeiden.
//!
//! Link against libpozeiden.so (or .a) and include <pozeiden.h>.
//!
//! Typical usage:
//!
//!   char *svg;
//!   size_t svg_len;
//!   if (pozeiden_render(src, src_len, &svg, &svg_len) == 0) {
//!       /* use svg[0..svg_len] */
//!       pozeiden_free(svg);
//!   } else {
//!       fprintf(stderr, "error: %s\n", pozeiden_last_error());
//!   }
//!
//!   const char *type = pozeiden_detect(src, src_len);
//!   /* type is a string literal — do NOT free it */
const std = @import("std");
const pozeiden = @import("pozeiden");

// Module-level GPA backing all C API allocations.
var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_state.allocator();

// Thread-local last-error buffer (256 bytes; truncates longer messages).
threadlocal var last_err_buf: [256]u8 = undefined;
threadlocal var last_err_len: usize = 0;

fn setError(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(&last_err_buf, fmt, args) catch &last_err_buf;
    last_err_len = msg.len;
}

/// Render `input_len` bytes of mermaid source at `input`.
///
/// On success: sets `*out_svg` to a heap-allocated, NUL-terminated SVG string,
/// sets `*out_len` to the byte count (excluding NUL), and returns 0.
///
/// On failure: sets `*out_svg` to NULL, `*out_len` to 0, records the error
/// message accessible via `pozeiden_last_error()`, and returns -1.
///
/// The caller must free the SVG with `pozeiden_free()`.
export fn pozeiden_render(
    input: [*]const u8,
    input_len: usize,
    out_svg: *[*:0]u8,
    out_len: *usize,
) c_int {
    out_svg.* = @ptrCast(@constCast(""));
    out_len.* = 0;

    const src = input[0..input_len];
    const svg = pozeiden.render(gpa, src) catch |err| {
        setError("render failed: {s}", .{@errorName(err)});
        return -1;
    };
    defer gpa.free(svg);

    // Allocate NUL-terminated copy for the caller.
    const buf = gpa.allocSentinel(u8, svg.len, 0) catch {
        setError("out of memory", .{});
        return -1;
    };
    @memcpy(buf, svg);
    out_svg.* = buf;
    out_len.* = svg.len;
    return 0;
}

/// Free an SVG string previously returned by `pozeiden_render`.
/// Passing NULL is safe (no-op).
export fn pozeiden_free(ptr: ?[*:0]u8) void {
    const p = ptr orelse return;
    const len = std.mem.len(p);
    gpa.free(p[0 .. len + 1]);
}

/// Return the error message from the most recent failed `pozeiden_render` call
/// on this thread.  The pointer is valid until the next call on this thread.
/// Returns an empty string if no error has occurred.
export fn pozeiden_last_error() [*:0]const u8 {
    if (last_err_len == 0) return "";
    last_err_buf[last_err_len] = 0;
    return @ptrCast(&last_err_buf);
}

/// Detect the diagram type of `input_len` bytes at `input`.
/// Returns a string literal (e.g. "flowchart", "sequence", "unknown").
/// The returned pointer is a compile-time constant — do NOT free it.
export fn pozeiden_detect(
    input: [*]const u8,
    input_len: usize,
) [*:0]const u8 {
    const src = input[0..input_len];
    const dt = pozeiden.detectDiagramType(src);
    return @tagName(dt);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = @import("std").testing;

test "pozeiden_detect returns flowchart for graph TD input" {
    const src = "graph TD\nA-->B\n";
    const result = pozeiden_detect(src.ptr, src.len);
    try testing.expectEqualStrings("flowchart", @import("std").mem.span(result));
}

test "pozeiden_detect returns pie for pie keyword" {
    const src = "pie\n\"A\" : 60\n\"B\" : 40\n";
    const result = pozeiden_detect(src.ptr, src.len);
    try testing.expectEqualStrings("pie", @import("std").mem.span(result));
}

test "pozeiden_detect returns unknown for unrecognised input" {
    const src = "not a diagram\n";
    const result = pozeiden_detect(src.ptr, src.len);
    try testing.expectEqualStrings("unknown", @import("std").mem.span(result));
}

test "pozeiden_render succeeds on valid pie input" {
    const src = "pie\n\"Dogs\" : 60\n\"Cats\" : 40\n";
    var out_svg: [*:0]u8 = undefined;
    var out_len: usize = 0;
    const rc = pozeiden_render(src.ptr, src.len, &out_svg, &out_len);
    defer if (rc == 0) pozeiden_free(out_svg);
    try testing.expectEqual(@as(c_int, 0), rc);
    try testing.expect(out_len > 0);
    try testing.expect(@import("std").mem.indexOf(u8, out_svg[0..out_len], "<svg") != null);
}

test "pozeiden_render out_svg is NUL-terminated" {
    const src = "pie\n\"A\" : 100\n";
    var out_svg: [*:0]u8 = undefined;
    var out_len: usize = 0;
    const rc = pozeiden_render(src.ptr, src.len, &out_svg, &out_len);
    defer if (rc == 0) pozeiden_free(out_svg);
    try testing.expectEqual(@as(c_int, 0), rc);
    try testing.expectEqual(@as(u8, 0), out_svg[out_len]);
}

test "pozeiden_last_error returns a valid NUL-terminated pointer" {
    const err = pozeiden_last_error();
    // The returned pointer must be NUL-terminated and readable.
    // We simply verify mem.span doesn't crash.
    const span = @import("std").mem.span(err);
    _ = span;
}

test "pozeiden_free null pointer is safe no-op" {
    pozeiden_free(null);
}
