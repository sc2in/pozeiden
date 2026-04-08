//! WebAssembly entry point for the Pozeiden playground.
//!
//! JS usage:
//!   const inputPtr = wasm.get_input_ptr();
//!   new Uint8Array(wasm.memory.buffer).set(encodedText, inputPtr);
//!   const svgLen = wasm.render(encodedText.length);
//!   const svg = decode(new Uint8Array(wasm.memory.buffer, wasm.get_output_ptr(), svgLen));
const std = @import("std");
const pozeiden = @import("pozeiden");

// wasm_allocator is backed by @wasmMemoryGrow — no OS calls needed.
const alloc = std.heap.wasm_allocator;

// 1 MB static input buffer — JS writes UTF-8 mermaid text here.
var input_buf: [1 * 1024 * 1024]u8 = undefined;

// Last rendered SVG (heap-allocated; freed on next render() call).
// Stored as const slice because render() returns []const u8.
var last_svg: []const u8 = "";

/// Return a pointer to the input buffer.
/// JS writes UTF-8 mermaid source here, then calls render().
export fn get_input_ptr() [*]u8 {
    return &input_buf;
}

/// Render the mermaid text in the input buffer.
/// `len` — number of UTF-8 bytes written to the input buffer.
/// Returns the SVG byte length (0 on hard allocation failure).
/// Call get_output_ptr() to read the result.
export fn render(len: u32) u32 {
    if (last_svg.len > 0) {
        alloc.free(last_svg);
        last_svg = "";
    }
    const input = input_buf[0..@min(len, input_buf.len)];
    last_svg = pozeiden.render(alloc, input) catch
        (alloc.dupe(u8, error_svg) catch return 0);
    return @intCast(last_svg.len);
}

/// Return a pointer to the SVG output from the last render() call.
/// The pointer is valid until the next render() call.
export fn get_output_ptr() [*]u8 {
    // JS only reads from this pointer; const-casting is safe.
    return @constCast(last_svg.ptr);
}

const error_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="420" height="90">
    \\  <rect width="420" height="90" rx="8" fill="#fff5f5"/>
    \\  <text x="210" y="38" fill="#c0392b" text-anchor="middle"
    \\        font-family="monospace" font-size="13" font-weight="bold">Parse / render error</text>
    \\  <text x="210" y="60" fill="#888" text-anchor="middle"
    \\        font-family="monospace" font-size="11">Check the syntax and try again.</text>
    \\</svg>
;
