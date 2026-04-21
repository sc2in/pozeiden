# Changelog

## [Unreleased]

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
