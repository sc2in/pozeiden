# Changelog

## [Unreleased]

## [0.3.0] - 2026-07-11

### Security

- **SVG output injection / stored XSS** (GHSA-p2c5-qmq5-3r4f) – `SvgWriter` now
  XML-escapes the user-controllable attribute values (`fill`, `stroke`,
  `font-weight`, `font-family`), so `style`/`classDef`/`linkStyle` colours and
  `%%{init:}%%` theme variables can no longer break out of a quoted attribute.
  Flowchart `click … href` links are scheme-validated (only `http`/`https`/
  `mailto` and relative URLs; `javascript:`/`data:`/`vbscript:` are rejected,
  including whitespace-obfuscated variants) and escaped, and now carry
  `rel="noopener noreferrer"`. The quadrant y-axis labels are escaped too.
- **Out-of-bounds read/write on valid diagrams** (GHSA-rg4m-w3p2-gf3p) – the
  grid-layout renderers (`c4`, `class`, `er`, `requirement`) and state diagrams
  sized fixed `[64]`/`[128]` row/column arrays that a diagram with enough
  elements or deep enough nesting could index past — a crash/DoS in safe builds
  and memory corruption in the safety-off WASM build. These arrays are now
  sized to the actual row/depth count, so large diagrams render fully instead
  of aborting.

### Added

- **Resource limits** on the library and C-API paths, which were previously
  unbounded. Input larger than `pozeiden.max_input_bytes` (4 MiB) returns
  `error.InputTooLarge`; a flowchart above 1000 nodes / 2000 edges returns
  `error.DiagramTooLarge`. Adds the `InputTooLarge` and `DiagramTooLarge`
  variants to `RenderError`.
- **Golden-file test suite** covering all 17 diagram types, regenerable with
  `zig build update-golden`, plus end-to-end security-regression tests.
- **CI** now runs the fuzz targets (`zig build fuzz`) and the test suite under
  `ReleaseSafe` on every PR; `src/fuzz.zig` is updated for the Zig 0.16
  `std.testing.fuzz` API (it previously did not compile).
- **README “Limitations” section** documenting unsupported diagram types,
  markdown-string labels, `@{shape}` syntax, the `%%{init}%%` subset, front
  matter handling, and the resource limits.

### Changed

- The C shared library now uses `std.heap.smp_allocator` instead of
  `DebugAllocator` — still thread-safe for concurrent `pozeiden_render`, but
  without leak-tracking overhead or a single global lock serialising renders.
- WASM `render()` emits the error diagram instead of silently truncating
  over-large input (>1 MiB) or output (>512 KiB) into malformed SVG.
- Diagram detection now skips a complete leading `--- … ---` YAML front-matter
  block, so front-matter-authored diagrams render instead of falling back to a
  raw-text dump.

### Fixed

- **Playground** – completed the WebAssembly WASI shim so `pozeiden.wasm` links
  in the browser (it was failing with `LinkError: … 'random_get' is not a
  Function`).
- Removed the dead jison parser subsystem and the unused `mecha` dependency;
  fixed the `mvzr` dependency version pin and the README install version.

## [0.2.0] - 2026-07-03

### Changed

- **Update to Zig 0.16.0** including addressing Io-gate

### Fixed

- **Thread safety** – `render`/`renderWithOptions` can now be called from
  multiple threads concurrently. Theme variables (including `ThemeOverride`
  and `%%{init:}%%` directive application) are `threadlocal`, so overrides on
  one thread never leak into renders on another, and the lazily-initialised
  langium grammar caches (pie, gitGraph) are built under a lock so concurrent
  first calls cannot race. On single-threaded targets (WASM) both mechanisms
  lower to the previous plain-global behaviour. Adds a multi-threaded stress
  test.

## [0.1.2] - 2026-04-21

### Fixed

- **Flowchart** – edge labels (`Yes`, `No`, `retry`, etc.) are now drawn in a
  second pass after all edge paths, so no arc can overwrite a label rendered
  in an earlier iteration.
- **Flowchart** – subgraph nodes that declare their own `direction` (e.g.
  `direction LR` inside a top-level `TD` graph) now route edges with the
  correct connection points and arrowhead orientation.
- **Flowchart** – added missing white background rect, matching every other
  renderer.
- **Flowchart** – subgraph labels no longer include surrounding quotes
  (e.g. `"Input Layer"` → `Input Layer`).
- **Flowchart** – node labels with double-delimiter shapes (`[\/…\/]`,
  `[\…\]`) no longer bleed the delimiter characters into the rendered label.
- **Pie chart** – percentage labels are given a white background rect so they
  remain legible when adjacent slices crowd the label ring.
- **Pie chart** – canvas, pie disk, and legend geometry adjusted so labels
  cannot overflow the left edge or collide with the legend column.
- **Mindmap** – leaf-node labels now use `textWrapped` for all bounded shapes,
  preventing overflow beyond node boundaries; bang/starburst nodes also get a
  white pill behind their label text.
- **Requirement diagram** – header names are truncated at 22 characters to fit
  within the node box; relationship-kind labels are given white background
  rects and a larger perpendicular offset for legibility on dense diagrams.

## [0.1.0] - 2026-04-19

### Added

- Initial public release
- 17 diagram types: pie, flowchart, sequence, gitGraph, classDiagram,
  stateDiagram-v2, erDiagram, gantt, timeline, xychart-beta, quadrantChart,
  mindmap, sankey-beta, C4Context/Container/Component/Dynamic/Deployment,
  block-beta, requirementDiagram, kanban
- Pure-Zig renderer — no JavaScript runtime, no external processes
- ~295 KB WebAssembly module (wasm32-wasi, `zig build playground`)
- C ABI shared library (`libpozeiden.so`) with `include/pozeiden.h`
- CLI binary with stdin/stdout, file I/O, and JSON envelope output (`--format json`)
- Live browser playground (`zig build playground`)
- Fuzzing harness (`zig build fuzz`) and benchmark suite (`zig build bench`)
- Nix flake with `nix run .` and `nix run .#playground`
