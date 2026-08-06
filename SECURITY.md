# Security Policy

## Reporting a Vulnerability

**Do not open a public issue for security vulnerabilities.**

If you discover a security issue, please report it responsibly by emailing
**security@sc2.in** with:

- A description of the vulnerability
- Steps to reproduce (a minimal `.mmd` input if applicable)
- Any relevant details (affected versions, exploitability, suggested fix)

You will receive acknowledgement within **72 hours** and we will work with you
on a fix before any public disclosure.

## Supported Versions

Security fixes are applied to the latest release only. We do not backport
fixes to older versions.

## Scope

The following are in scope:

- Memory safety bugs in the parsers (use-after-free, buffer over-read, etc.)
- Denial-of-service via crafted mermaid input (CPU or memory exhaustion)
- SVG output that enables XSS in downstream applications that embed it
- Information disclosure via the C ABI or WASM interface

Out of scope: issues in transitive build-only dependencies that do not affect
the compiled output.

## Handling untrusted mermaid input

pozeiden is designed to render untrusted diagram text safely; these are the
knobs and their defaults:

- **Strict mode.** By default an unrecognised diagram type renders a minimal
  fallback SVG. For pipelines rendering third-party input, pass
  `renderWithOptions(…, .{ .strict = true })` so unsupported input surfaces
  as `error.UnknownDiagramType` you can handle. (The default flips to strict
  in 1.0.0.)
- **Resource limits.** Input above 4 MiB → `error.InputTooLarge`
  (tighten or loosen per call via `RenderOptions.max_input_bytes`); flowcharts
  above 10 000 nodes / 20 000 edges / 500 subgraphs → `error.DiagramTooLarge`;
  mindmaps nested deeper than 100 levels → `error.NestingTooDeep`.
- **SVG output posture.** All text and attribute values are XML-escaped
  (control bytes are dropped); `click … href` URLs are scheme-validated and
  emitted with `rel="noopener noreferrer"`; `click … call` script callbacks
  are not supported at all. A well-formedness oracle runs in the fuzz harness
  and over the golden baselines.
- **C ABI / WASM.** `pozeiden_render` enforces the same limits;
  `pozeiden_last_error` is per-thread. The WASM entry point bounds input to
  its 1 MiB buffer and never emits a truncated SVG.
- **Thread safety.** All render entry points are safe for concurrent use
  (thread-local theme state, locked grammar-cache init).

## Known limitations

- The WASM module is built with a size-optimised, safety-off release mode:
  a memory-safety bug that safe builds would catch as a panic can corrupt
  memory there. The input/output buffers are bounds-checked at the entry
  point, and the same parsers are continuously fuzzed with safety on.
- Coverage-guided fuzzing (`zig build fuzz --fuzz`) is currently broken
  upstream in Zig 0.16's fuzz-mode test runner; every fuzz target still runs
  in smoke mode on each CI run, plus multi-seed sweeps before releases.
- Rendering is CPU-bounded by the input caps above, not by a timeout; callers
  with hard latency budgets should run renders under their own deadline.
