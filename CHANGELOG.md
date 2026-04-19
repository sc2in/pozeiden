# Changelog

## [Unreleased]

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
