# Changelog

All notable changes to pozeiden are documented here.

Versions track the rendering contract, not Zig. SVG output is deterministic
for a given (input, options, version), but byte-exact SVG stability is only
guaranteed within a patch series: minor releases may change output bytes
(layout, spacing, theming) and call it out under **Behaviour change** bullets;
patch releases change bytes only to fix rendering or security bugs. Downstream
golden baselines (e.g. PolicyPress's Typst goldens) should expect to
regenerate on minor bumps.

pozeiden 1.0.0 will be a soak-then-promote release: the only breaking change
reserved for it is flipping strict rendering to the default (see the
Deprecated section of 0.4.0).

## [Unreleased]

## [0.4.1] - 2026-08-07

### Fixed

- **Direction-override subgraphs could swap node positions** (#49). The
  sub-layout's coordinates were written back to the real nodes by pre-sort
  index, but layout reorders nodes within layers — so when a subgraph with
  its own `direction` declared same-layer members out of alphabetical order,
  nodes received each other's positions, defeating the crossing-reduction
  ordering. The write-back now matches by node id. Output changes only for
  affected diagrams (the committed baselines were not; goldens unchanged).

## [0.4.0] - 2026-08-06

### Fixed

- **YAML front matter corrupted rendered output.** Front matter was stripped
  only in detection (#45), so parsers received the raw text: `---` was
  consumed as the keyword line and lines like `title: My Chart` became
  flowchart nodes. `render` now strips the block once before dispatch.
- **Flowchart layouts deeper than 64 layers or wider than 128 nodes were
  silently corrupted.** Fixed-size scratch arrays in the layout engine
  aliased layer counters (`% 64` — a 70-node chain rendered 320 px wide
  instead of one column) and skipped barycenter ordering for nodes past the
  first 128 in a layer. Both died in the #42 rewrite; same-pattern `% 64`
  aliasing fixed in the block-beta elbow router.
- **Undefined behaviour on hostile block-beta sizes.** `columns -5`,
  `columns nan`, `columns 1e30`, and negative `id:N` spans flowed into
  `@intFromFloat(usize)` in the renderer — UB in unchecked builds. Values are
  clamped at the parse boundary.
- **Control bytes in labels made the SVG unparseable.** `xmlEscape` now drops
  bytes below 0x20 (except tab/LF/CR), which XML 1.0 cannot represent at all.
- Committed the corrected `build.zig.zon2json-lock` (mvzr ref pin, stale
  mecha entry); the pre-push hook now peels annotated release tags correctly.
- README/docs truth pass: WASM size, install URL, architecture tree (the
  removed jison backend), diagram count, build-steps table, refreshed
  benchmark tables.

### Added

- **Accessibility metadata.** Mermaid `accTitle:`/`accDescr:` directives
  (line and `{ block }` forms) and the front-matter `title:` are parsed out
  of the diagram and embedded as `<title>`/`<desc>` with `role="img"` +
  `aria-labelledby` on the root `<svg>`. New `renderWithMetadata` returns
  `{ svg, diagram_type, title, descr }` for consumers that embed the SVG
  where its own `<title>` is unreachable (raster, `<img>`, PDF figures).
- **`renderToWriter(allocator, text, options, *std.Io.Writer)`** completes
  the render / renderWithOptions / renderToWriter triad.
- **`RenderOptions.max_input_bytes`**: the 4 MiB input cap becomes a per-call
  knob (0 disables it).
- **Recursion and nesting guards**: mindmaps deeper than 100 levels return
  the new `error.NestingTooDeep`; flowcharts with more than 500 subgraphs
  return `error.DiagramTooLarge`.
- **SVG well-formedness oracle** (`fuzz_render_wellformed` + a golden-suite
  gate): any successful render must parse as XML, catching graceful wrong
  answers the no-crash fuzz targets swallow.
- **CI**: WASM build + Node *instantiation* smoke test on every PR (a
  build-only check cannot catch the #48 LinkError class); benchmark
  regression gate against the last release binary (fail at mean + 2σ);
  aarch64-darwin test leg; `ci-gate` aggregator as the single required
  check; all workflow actions pinned to commit SHAs.
- **Release safety**: publishing now happens inside the CI workflow behind
  `ci-gate` — a tag whose tests fail cannot release; `tools/check-release.sh`
  (also `nix run .#check-release`) verifies the CHANGELOG and the
  `build.zig.zon` version stamp against the tag; GitHub releases use a
  draft-then-undraft flow and ship SHA256SUMS plus a CycloneDX SBOM
  (`nix run .#sbom`); FlakeHub publishing re-enabled with a manual
  republish escape hatch.
- **Governance**: branch-protection rulesets as code (+ sync workflow),
  CODEOWNERS, CODE_OF_CONDUCT.md, LICENSING.md, per-file SPDX headers.
- Documented API contracts: thread safety of all render entry points, the
  `render` ownership contract (zigmark's `MermaidRendererFn` ABI), and the
  output-stability policy (header of this file).

### Changed

- **Flowchart layout rewritten from O(N²) to O(passes·(V+E))** (#42): every
  phase now walks per-node adjacency lists filled in global edge order, so
  output is byte-identical for previously-correct inputs (all 17 golden
  baselines unchanged). A 1000-node graph went from 1.39 s to ~12 ms;
  `max_nodes`/`max_edges` raised 10× to 10 000/20 000 (10 000 nodes lay out
  in ~66 ms).
- **`root.zig` de-monolithed** (#39): the 15 hand-written parsers moved to
  `src/parsers/` with a shared `LineIter`; root.zig shrank from ~4100 to
  ~550 lines of detection, dispatch, and theme plumbing. Pure refactor —
  goldens unchanged.
- **Behaviour change:** the default font stack gains `Liberation Sans` and
  `DejaVu Sans` before the generic fallback so headless SVG consumers
  (Typst, resvg, PDF pipelines) resolve real fonts. Every `<text>` element's
  `font-family` changes; golden baselines regenerated.
- Security regression tests moved to `src/security_test.zig` (one test per
  hardening fix, on `std.testing.allocator` so error-path leaks fail) and
  end-to-end tests to `src/render_test.zig`.

### Deprecated

- **Lenient rendering as the default.** Today an unrecognised diagram type
  silently renders a minimal fallback SVG — which can ship in a published
  document looking like a real diagram. In **1.0.0** the default flips to
  strict (`error.UnknownDiagramType`); pass an explicit `.strict = false` to
  keep the fallback. No API is removed — only the default changes.

### Known limitations

- Coverage-guided fuzzing (`zig build fuzz --fuzz`) is currently broken
  upstream in Zig 0.16's fuzz-mode test runner (a `StackTrace` type mismatch
  in `compiler/test_runner.zig`). Smoke mode still runs every target on each
  CI run; releases additionally get multi-seed sweeps.
- `x86_64-darwin` is declared but untested (no viable CI runner); documented
  as Tier 2 / best effort.

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
