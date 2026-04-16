//! WebAssembly entry point for the Pozeiden playground.
//!
//! JS usage:
//!   const inputPtr  = wasm.get_input_ptr();
//!   const outputPtr = wasm.get_output_ptr();
//!   new Uint8Array(wasm.memory.buffer).set(encodedText, inputPtr);
//!   const svgLen = wasm.render(encodedText.length);
//!   const svg = decode(new Uint8Array(wasm.memory.buffer, outputPtr, svgLen));
const std = @import("std");
const pozeiden = @import("pozeiden");

// ── Static buffers — no heap allocator is used between render calls. ──────────
//
// Each render() creates a fresh FixedBufferAllocator over scratch_buf, then
// wraps it in an ArenaAllocator for the entire render pipeline.  Because the
// FBA is a local variable initialised with end_index=0 every call, the
// allocator state is completely clean on every render — no free-list
// fragmentation, no cross-render heap mutation.
//
// The final SVG is copied from scratch_buf into output_buf before render()
// returns, so get_output_ptr() stays valid until the next render() call.

/// 1 MB: JS writes UTF-8 mermaid source here before calling render().
var input_buf: [1 * 1024 * 1024]u8 = undefined;

/// 8 MB scratch arena — wiped implicitly on every render() call by
/// re-initialising the FixedBufferAllocator local.  All parse-tree nodes,
/// layout data, and SVG-string building happen inside this buffer.
var scratch_buf: [8 * 1024 * 1024]u8 = undefined;

/// 512 KB output buffer.  The largest example SVG (c4, ~28 KB) fits with
/// ~18× headroom; hand-crafted diagrams are unlikely to exceed this.
var output_buf: [512 * 1024]u8 = undefined;

/// Return a pointer to the input buffer.
/// JS writes UTF-8 mermaid source here before calling render().
export fn get_input_ptr() [*]u8 {
    return &input_buf;
}

/// Return a pointer to the output buffer.
/// Valid from after render() returns until the next render() call.
export fn get_output_ptr() [*]u8 {
    return &output_buf;
}

/// Render the mermaid text in the input buffer.
/// `len` — number of UTF-8 bytes written to the input buffer.
/// Returns the SVG byte length written to the output buffer (0 on error).
export fn render(len: u32) u32 {
    // Fresh FBA every call → zero accumulated heap state between renders.
    var fba = std.heap.FixedBufferAllocator.init(&scratch_buf);
    // ArenaAllocator over FBA handles ArrayList growth correctly (FBA alone
    // can only resize the most-recently-allocated block).
    var arena = std.heap.ArenaAllocator.init(fba.allocator());

    const input = input_buf[0..@min(len, input_buf.len)];
    const svg = pozeiden.render(arena.allocator(), input) catch error_svg;

    const out_len = @min(svg.len, output_buf.len);
    @memcpy(output_buf[0..out_len], svg[0..out_len]);
    return @intCast(out_len);
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
