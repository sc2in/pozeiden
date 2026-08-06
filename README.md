# pozeiden

[![CI](https://github.com/sc2in/pozeiden/actions/workflows/ci.yml/badge.svg)](https://github.com/sc2in/pozeiden/actions/workflows/ci.yml)

A pure-Zig drop-in replacement for [mermaid.js](https://mermaid.js.org). Parses mermaid diagram text and produces self-contained SVG — no JavaScript runtime, no npm, no external processes. Compiles to a \~500 KB WebAssembly module (vs mermaid.js's \~1 MB+) and runs at sub-millisecond speeds.

Supported interfaces: Zig library, C shared library, WebAssembly (wasm32-wasi), CLI.

## Supported diagram types

| Type | Keyword |
|---|---|
| Pie chart | `pie` |
| Flowchart | `graph` / `flowchart` |
| Sequence diagram | `sequenceDiagram` |
| Git graph | `gitGraph` |
| Class diagram | `classDiagram` |
| State diagram | `stateDiagram-v2` |
| ER diagram | `erDiagram` |
| Gantt chart | `gantt` |
| Timeline | `timeline` |
| XY chart | `xychart-beta` |
| Quadrant chart | `quadrantChart` |
| Mindmap | `mindmap` |
| Sankey diagram | `sankey-beta` |
| C4 architecture | `C4Context` / `C4Container` / `C4Component` / `C4Dynamic` / `C4Deployment` |
| Block diagram | `block-beta` |
| Requirement diagram | `requirementDiagram` |
| Kanban board | `kanban` |

## Limitations

pozeiden targets the common, static subset of mermaid. Known gaps as of the
current release:

- **Unsupported diagram types.** `journey`, `packet`, `architecture`,
  `treemap`, and `radar` are not implemented. Unrecognised input renders a
  minimal fallback SVG rather than erroring — pass `RenderOptions.strict = true`
  (see below) to get `error.UnknownDiagramType` instead.
- **No markdown string labels.** Backtick/`**bold**` markdown inside labels is
  rendered literally, not formatted.
- **No `@{ shape: … }` (mermaid v11) node syntax.** Use the classic shape
  delimiters (`[]`, `()`, `{}`, `([])`, `[()]`, …).
- **Narrow `%%{init: …}%%` support.** Only the `dark`/`forest`/`neutral` theme
  presets and the `themeVariables` keys `primaryColor`, `primaryTextColor`,
  `primaryBorderColor`, `lineColor`, `background`, `mainBkg`, and `fontFamily`
  are honoured. Other init keys are ignored.
- **YAML front matter: `title` only.** A leading `--- … ---` block is stripped
  before parsing; its `title:` becomes the SVG's accessible `<title>` (see
  below), but `config:` settings are not consumed.
- **`click … call` callbacks are not supported** (only `click … href` links,
  which are scheme-validated and escaped). This is intentional for the
  embed-SVG-in-HTML use case.
- **Resource limits.** Input above 4 MiB yields `error.InputTooLarge`
  (per-call override: `RenderOptions.max_input_bytes`); flowcharts above
  10 000 nodes / 20 000 edges / 500 subgraphs yield `error.DiagramTooLarge`;
  mindmaps nested deeper than 100 levels yield `error.NestingTooDeep`.

### Accessibility

Mermaid's `accTitle:` / `accDescr:` directives (and the front-matter `title:`)
are parsed out of the diagram and embedded as `<title>`/`<desc>` children with
`role="img"` + `aria-labelledby` on the root `<svg>`, so screen readers
announce a meaningful label. For consumers that embed the SVG where its own
`<title>` is unreachable (raster conversion, `<img>`, PDF figures),
`renderWithMetadata` additionally returns the title/description as strings.

### Rendering untrusted input

pozeiden escapes text and attribute values and validates link schemes, so its
SVG is safe to embed. When rendering untrusted diagrams into a published page,
prefer `renderWithOptions(..., .{ .strict = true })` so an unrecognised or
malformed diagram surfaces as an error you can handle (e.g. fall back to a code
block) instead of silently emitting a fallback SVG.

### Fonts

The default font family is `"trebuchet ms, verdana, arial, Liberation Sans, DejaVu Sans, sans-serif"` — mermaid-parity faces first for browsers, then the
two metric-compatible faces shipped by virtually every Linux distribution so
that headless SVG consumers (Typst, resvg, PDF pipelines) can resolve real
fonts. To match a specific environment set
`RenderOptions.theme_override.font_family` (or `%%{init: {'themeVariables': {'fontFamily': '…'}}}%%`).

### Thread safety

`render`, `renderWithOptions`, `renderWithMetadata`, `renderToWriter`, and
`pozeiden_render` are safe to call concurrently from multiple threads: theme
overrides are thread-local, and the lazily-built grammar caches initialise
under a lock (verified by a multi-threaded stress test in the suite). On WASM
the atomics lower to plain loads/stores.

### Output stability

SVG output is deterministic for a given (input, options, version). Byte-exact
stability is guaranteed only within a patch series: minor releases may change
output bytes (layout, spacing, theming) and call it out in the changelog under
**Behaviour change** bullets; patch releases change bytes only to fix
rendering or security bugs. Downstream golden baselines that embed pozeiden
SVG byte-for-byte should expect to regenerate on minor bumps.

## Requirements

- Zig **0.16.0** or later

## Supported platforms

| Tier | Platforms |
|---|---|
| Tier 1 (CI-tested) | x86\_64-linux, aarch64-linux, aarch64-darwin, wasm32-wasi |
| Tier 2 (best effort) | x86\_64-darwin |

Release binaries ship for Linux; darwin consumers build via Nix/FlakeHub or
`zig build`.

## Installation

Add pozeiden as a dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .pozeiden = .{
        .url = "https://github.com/sc2in/pozeiden/archive/refs/tags/v0.4.0.tar.gz",
        .hash = "...",  // run: zig fetch --save <url>
    },
},
```

Wire it up in `build.zig`:

```zig
const pozeiden_dep = b.dependency("pozeiden", .{
    .target = target,
    .optimize = optimize,
});
your_module.addImport("pozeiden", pozeiden_dep.module("pozeiden"));
```

## Zig library usage

```zig
const pozeiden = @import("pozeiden");

pub fn example(allocator: std.mem.Allocator) !void {
    const mermaid =
        \\pie title Pets
        \\"Dogs" : 60
        \\"Cats" : 40
    ;
    const svg = try pozeiden.render(allocator, mermaid);
    defer allocator.free(svg);
    // svg is a self-contained SVG string
}
```

`render` returns a heap-allocated slice that the caller owns. All internal
allocations use a short-lived arena that is freed before the function returns.

You can also detect the diagram type without rendering:

```zig
const kind = pozeiden.detectDiagramType(mermaid);
// kind is a DiagramType enum: .pie, .flowchart, .sequence, etc.
```

## C shared library

Build and install:

```sh
zig build lib
# zig-out/lib/libpozeiden.so
# zig-out/include/pozeiden.h
```

API:

```c
#include "pozeiden.h"

// Render mermaid text to SVG.
// Returns 0 on success; *out_svg is heap-allocated, free with pozeiden_free().
// Returns -1 on failure; call pozeiden_last_error() for the message.
int pozeiden_render(const char *input, size_t input_len,
                    char **out_svg, size_t *out_len);

// Free an SVG string returned by pozeiden_render(). NULL is a safe no-op.
void pozeiden_free(char *svg);

// Return the last error message on this thread. Do NOT free the pointer.
const char *pozeiden_last_error(void);

// Detect diagram type. Returns a string constant ("flowchart", "pie", etc.),
// or "unknown". Do NOT free the pointer.
const char *pozeiden_detect(const char *input, size_t input_len);
```

Example:

```c
char *svg = NULL;
size_t svg_len = 0;
if (pozeiden_render(src, src_len, &svg, &svg_len) == 0) {
    fwrite(svg, 1, svg_len, stdout);
    pozeiden_free(svg);
} else {
    fprintf(stderr, "pozeiden error: %s\n", pozeiden_last_error());
}
```

## WebAssembly

Build:

```sh
zig build playground
# zig-out/playground/pozeiden.wasm  (~500 KB)
# zig-out/playground/index.html
# zig-out/playground/wasi-shim.js
```

JavaScript interface — the module imports a handful of WASI functions
transitively from the Zig std library, so instantiate it with the bundled
shim (`wasi-shim.js`, also exercised by CI's Node smoke test):

```js
import { makeWasiShim } from "./wasi-shim.js";

let wasm = null;
const shim = makeWasiShim(() => wasm.memory.buffer);
const { instance } = await WebAssembly.instantiateStreaming(
  fetch("pozeiden.wasm"),
  shim,
);
wasm = instance.exports;

// Write mermaid source into the 1 MB input buffer
const encoder = new TextEncoder();
const bytes = encoder.encode(mermaidText);
const inputPtr = wasm.get_input_ptr();
new Uint8Array(wasm.memory.buffer, inputPtr, bytes.length).set(bytes);

// Render — returns SVG byte length (0 on error)
const svgLen = wasm.render(bytes.length);

// Read SVG from the 512 KB output buffer
const outputPtr = wasm.get_output_ptr();
const svg = new TextDecoder().decode(
  new Uint8Array(wasm.memory.buffer, outputPtr, svgLen),
);
```

## CLI usage

```sh
# stdin → stdout
echo 'pie title Pets
"Dogs" : 60
"Cats" : 40' | pozeiden > out.svg

# explicit files
pozeiden -i diagram.mmd -o diagram.svg

# JSON envelope: {"svg":"...","diagram_type":"..."}
pozeiden -i diagram.mmd --format json

# version
pozeiden --version

# help
pozeiden --help
```

## Playground

A live browser playground is included. It compiles pozeiden to WebAssembly and
serves a split-pane editor where edits render instantly.

```sh
nix run .#playground          # build WASM + serve on http://localhost:8080
nix run .#playground -- 3000  # custom port
```

Without Nix:

```sh
zig build playground
cd zig-out/playground && python3 -m http.server
```

All 17 diagram types are available as presets in the example dropdown.

## Build steps

| Step | Command | Output |
|---|---|---|
| CLI binary | `zig build` | `zig-out/bin/pozeiden` |
| Unit tests | `zig build test` | — |
| Semantic check | `zig build check` | — |
| C shared library | `zig build lib` | `zig-out/lib/libpozeiden.so` + `zig-out/include/pozeiden.h` |
| WASM playground | `zig build playground` | `zig-out/playground/` |
| Example SVGs | `zig build examples` | `zig-out/examples/*.svg` |
| Fuzz (smoke) | `zig build fuzz` | — |
| Fuzz (coverage) | `zig build fuzz --fuzz` | — (currently broken upstream in Zig 0.16's fuzz runner) |
| Benchmark | `zig build bench` | timing output to stdout |
| Update README bench | `nix run .#bench` | rewrites the Performance section |
| Update goldens | `zig build update-golden` | regenerates `tests/golden/*.svg` from `examples/` |
| API docs | `zig build docs` | `zig-out/docs/` |
| Static site | `zig build site` | `zig-out/site/` (playground + docs) |

## Examples

The `examples/` directory contains one `.mmd` source file per diagram type.
Run `zig build examples` to render them all to `zig-out/examples/*.svg`.

```text
examples/
  block.mmd       c4.mmd          class.mmd       er.mmd
  flowchart.mmd   gantt.mmd       gitgraph.mmd    kanban.mmd
  mindmap.mmd     pie.mmd         quadrant.mmd    requirement.mmd
  sankey.mmd      sequence.mmd    state.mmd       timeline.mmd
  xychart.mmd
```

## Performance

Run `nix run .#bench` to regenerate (requires Linux with mermaid-cli available via the dev shell).

<!-- bench-start -->

\_Last updated: 2026-08-06 - run: nix run .\#bench

### Render time

| diagram | iters | min\_µs | mean\_µs | max\_µs |
|---|---|---|---|---|
| pie | 1000 | 211.0 | 225.4 | 405.3 |
| flowchart | 1000 | 486.8 | 581.5 | 1596.8 |
| sequence | 1000 | 169.5 | 199.9 | 605.4 |
| gitgraph | 1000 | 764.8 | 799.6 | 1389.6 |
| class | 1000 | 111.1 | 123.8 | 312.4 |
| state | 1000 | 146.2 | 187.3 | 548.9 |
| er | 1000 | 109.5 | 128.4 | 326.4 |
| gantt | 1000 | 73.7 | 83.5 | 316.5 |
| timeline | 1000 | 55.6 | 65.6 | 296.0 |
| xychart | 1000 | 28.7 | 33.6 | 385.5 |
| quadrant | 1000 | 35.7 | 40.3 | 259.2 |
| mindmap | 1000 | 167.5 | 182.3 | 393.9 |
| sankey | 1000 | 115.0 | 139.7 | 415.9 |
| c4 | 1000 | 163.4 | 178.8 | 406.2 |
| block | 1000 | 58.3 | 118.7 | 4940.8 |
| requirement | 1000 | 99.7 | 199.8 | 2355.1 |
| kanban | 1000 | 59.9 | 84.1 | 242.0 |

### vs mermaid-cli (3 iterations each)

| diagram | poz\_µs | mmdc\_µs | speedup |
|---|---|---|---|
| pie | 225.6 | 2149899.2 | 9528.1x |
| flowchart | 551.6 | 2190009.5 | 3970.4x |
| sequence | 363.9 | 1984607.5 | 5454.4x |
| gitgraph | 893.1 | 2167946.1 | 2427.6x |
| class | 130.8 | 2294778.6 | 17546.3x |
| state | 172.7 | 2314158.0 | 13402.3x |
| er | 220.8 | 2471392.7 | 11191.0x |
| gantt | 116.5 | 2245483.1 | 19267.6x |
| timeline | 75.2 | 2160721.2 | 28734.9x |
| xychart | 39.5 | 2101654.3 | 53222.6x |
| quadrant | 50.4 | 2186819.5 | 43363.5x |
| mindmap | 196.2 | 2401877.2 | 12241.2x |
| sankey | 140.4 | 2025918.1 | 14433.8x |
| c4 | 204.5 | 2155159.0 | 10539.3x |
| block | 126.1 | 2023757.2 | 16051.9x |
| requirement | 197.1 | 1925335.9 | 9769.9x |
| kanban | 124.1 | 2054981.8 | 16559.7x |

<!-- bench-end -->

## Architecture

```text
src/
  root.zig              Public API: detection, dispatch, options, theme plumbing
  detect.zig            First-line diagram type detection + front-matter handling
  parse_util.zig        Shared line-parser helpers (LineIter, splitFirst, …)
  main.zig              CLI entry point
  wasm.zig              WebAssembly entry point (get_input_ptr / render / get_output_ptr)
  capi.zig              C ABI exports (pozeiden_render, pozeiden_free, ...)
  fuzz.zig              Fuzz targets (no-crash + well-formedness oracle)
  bench.zig             Benchmark harness (optionally vs mermaid-cli)
  render_test.zig       End-to-end tests of the public API
  security_test.zig     Security regression suite (one test per hardening fix)
  diagram/
    value.zig           Generic AST value (string | number | bool | node | list)
  svg/
    writer.zig          Low-level SVG string builder
    theme.zig           Mermaid default theme constants
    layout.zig          DAG layout (simplified Sugiyama) for flowcharts
    wellformed.zig      Minimal XML well-formedness checker (test/fuzz oracle)
  parsers/              Hand-written line-oriented parser per diagram type
    flowchart.zig sequence.zig class.zig state.zig er.zig gantt.zig
    timeline.zig xychart.zig quadrant.zig mindmap.zig sankey.zig c4.zig
    block.zig requirement.zig kanban.zig
  renderers/            Value-AST → SVG renderer per diagram type
    pie.zig flowchart.zig sequence.zig gitgraph.zig class.zig state.zig
    er.zig gantt.zig timeline.zig xychart.zig quadrant.zig mindmap.zig
    sankey.zig c4.zig block.zig requirement.zig kanban.zig
  langium/              Parser for .langium grammar files
grammars/               Embedded .langium grammar definitions (pie, gitGraph)
examples/               Source .mmd files for each diagram type
tests/                  Golden SVG baselines + WASM instantiation smoke test
tools/                  Release guards (check-release.sh) + SBOM generator
playground/             HTML + JS source for the live browser playground
include/                C API header (pozeiden.h)
```

Two parsing backends are used:

- **Langium backend**: for diagram types with a formal `.langium` grammar
  (pie, gitGraph). Parses the grammar file at compile time via `@embedFile`,
  then tokenises and interprets diagram text at runtime.
- **Direct parsers**: all other diagram types use hand-written line-oriented
  parsers in `src/parsers/`, which are simpler and faster for the formats
  mermaid uses.

## Nix

```sh
nix run .                     # render stdin → stdout
nix run .#playground          # build WASM + serve playground
nix run .#bench               # run benchmarks and update README (Linux)
nix build .#pozeiden-safe     # ReleaseSafe binary in result/
nix build .#pozeiden-fast     # ReleaseFast binary
nix build .#pozeiden-small    # ReleaseSmall binary
nix flake check               # run test suite
```

## License

[PolyForm Noncommercial 1.0.0](LICENSE) — free for noncommercial use.
Commercial licensing: [<inquiries@sc2.in>](mailto:inquiries@sc2.in)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

See [SECURITY.md](SECURITY.md). Report vulnerabilities to [<security@sc2.in>](mailto:security@sc2.in).
