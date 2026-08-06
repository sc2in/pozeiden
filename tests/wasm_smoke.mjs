// Instantiation smoke test for the playground WASM module. Run from the repo
// root after `zig build playground`:
//
//   node tests/wasm_smoke.mjs
//
// A build-only check is not enough: issue #48 shipped a module that compiled
// fine but failed WebAssembly.instantiate with a LinkError (an unshimmed
// wasi_snapshot_preview1 import). This test instantiates the module with the
// real playground shim (playground/wasi-shim.js) and renders a diagram, so
// import-set drift and input/output ABI drift both fail CI.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { makeWasiShim } from '../playground/wasi-shim.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const wasmPath = process.argv[2] ?? join(root, 'zig-out/playground/pozeiden.wasm');

let wasm = null;
const shim = makeWasiShim(() => wasm.memory.buffer);
const { instance } = await WebAssembly.instantiate(readFileSync(wasmPath), shim);
wasm = instance.exports;

for (const sym of ['memory', 'get_input_ptr', 'get_output_ptr', 'render']) {
  if (!(sym in wasm)) throw new Error(`missing export: ${sym}`);
}

const input = new TextEncoder().encode('pie\n"Dogs" : 60\n"Cats" : 40\n');
new Uint8Array(wasm.memory.buffer).set(input, wasm.get_input_ptr());
const len = wasm.render(input.length);
const svg = new TextDecoder().decode(new Uint8Array(wasm.memory.buffer, wasm.get_output_ptr(), len));

if (len === 0) throw new Error('render() returned 0 bytes');
if (!svg.startsWith('<svg')) throw new Error(`output is not an SVG: ${svg.slice(0, 80)}`);
if (svg.includes('Parse / render error')) throw new Error('render() emitted the error diagram for valid input');
if (!svg.includes('<path')) throw new Error('pie render is missing its <path> slices');

console.log(`wasm smoke OK: rendered ${len}-byte SVG from ${wasmPath}`);
