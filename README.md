# pozeiden

[![CI](https://github.com/sc2in/pozeiden/actions/workflows/ci.yml/badge.svg)](https://github.com/sc2in/pozeiden/actions/workflows/ci.yml)

A pure-Zig drop-in replacement for [mermaid.js](https://mermaid.js.org). Parses mermaid diagram text and produces self-contained SVG — no JavaScript runtime, no npm, no external processes. Compiles to a \~295 KB WebAssembly module (vs mermaid.js's \~1 MB+) and runs at sub-millisecond speeds.

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

## Requirements

- Zig **0.15.2** or later

## Installation

Add pozeiden as a dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .pozeiden = .{
        .url = "https://github.com/sc2in/pozeiden/archive/refs/tags/v0.1.0.tar.gz",
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
# zig-out/playground/pozeiden.wasm  (~295 KB)
# zig-out/playground/index.html
```

JavaScript interface:

```js
const { instance } = await WebAssembly.instantiateStreaming(fetch("pozeiden.wasm"));
const wasm = instance.exports;

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
    new Uint8Array(wasm.memory.buffer, outputPtr, svgLen)
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
| Fuzz (coverage) | `zig build fuzz --fuzz` | — |
| Benchmark | `zig build bench` | timing output to stdout |
| Update README bench | `nix run .#bench` | rewrites the Performance section |
| API docs | `zig build docs` | `zig-out/docs/` |

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

\_Last updated: 2026-04-20 - run: nix run .\#bench

### Render time

| diagram | iters | min\_µs | mean\_µs | max\_µs |
|---|---|---|---|---|
| pie | 1000 | 205.4 | 300.7 | 3432.9 |
| flowchart | 1000 | 267.3 | 369.0 | 1785.5 |
| sequence | 1000 | 156.5 | 192.7 | 1137.3 |
| gitgraph | 1000 | 724.5 | 808.4 | 1341.5 |
| class | 1000 | 96.1 | 114.3 | 617.1 |
| state | 1000 | 140.4 | 163.4 | 792.5 |
| er | 1000 | 109.5 | 141.8 | 925.1 |
| gantt | 1000 | 65.1 | 93.2 | 771.8 |
| timeline | 1000 | 44.2 | 75.9 | 528.3 |
| xychart | 1000 | 26.9 | 42.2 | 573.7 |
| quadrant | 1000 | 29.3 | 38.3 | 752.6 |
| mindmap | 1000 | 152.7 | 206.0 | 845.1 |
| sankey | 1000 | 100.4 | 111.4 | 472.3 |
| c4 | 1000 | 136.4 | 158.3 | 608.5 |
| block | 1000 | 60.9 | 72.2 | 1001.2 |
| requirement | 1000 | 77.6 | 95.8 | 605.9 |
| kanban | 1000 | 53.4 | 87.0 | 723.5 |

### vs mermaid-cli (3 iterations each)

| diagram | poz\_µs | mmdc\_µs | speedup |
|---|---|---|---|
| pie | 279.6 | 2376285.4 | 8499.8x |
| flowchart | 600.1 | 2638367.3 | 4396.9x |
| sequence | 212.7 | 2144423.0 | 10081.4x |
| gitgraph | 1582.1 | 2506957.1 | 1584.6x |
| class | 117.1 | 2312115.2 | 19740.6x |
| state | 190.1 | 2755229.2 | 14491.2x |
| er | 119.2 | 2455002.7 | 20600.5x |
| gantt | 169.0 | 2300938.5 | 13611.2x |
| timeline | 62.3 | 3198155.0 | 51339.7x |
| xychart | 74.5 | 2270786.0 | 30473.0x |
| quadrant | 40.1 | 2073034.2 | 51679.9x |
| mindmap | 191.3 | 3386923.6 | 17700.4x |
| sankey | 119.5 | 2085439.2 | 17450.8x |
| c4 | 360.9 | 1973762.7 | 5468.7x |
| block | 76.6 | 2197381.3 | 28679.7x |
| requirement | 96.1 | 2170166.8 | 22589.0x |
| kanban | 65.7 | 2577871.5 | 39219.1x |

<!-- bench-end -->

## Architecture

```text
src/
  root.zig              Public API: detect type, parse, dispatch to renderer
  detect.zig            First-line diagram type detection
  main.zig              CLI entry point
  wasm.zig              WebAssembly entry point (get_input_ptr / render / get_output_ptr)
  capi.zig              C ABI exports (pozeiden_render, pozeiden_free, ...)
  diagram/
    value.zig           Generic AST value (string | number | bool | node | list)
  svg/
    writer.zig          Low-level SVG string builder
    theme.zig           Mermaid default theme constants
    layout.zig          DAG layout (simplified Sugiyama) for flowcharts
  renderers/
    pie.zig             Pie chart
    flowchart.zig       Flowchart / graph (shapes, edge labels, dashed/thick edges)
    sequence.zig        Sequence diagram (activation bars, notes, autonumber)
    gitgraph.zig        Git graph
    class.zig           Class diagram (stereotypes, generics, visibility)
    state.zig           State diagram (fork/join bars, choice diamonds)
    er.zig              Entity-relationship diagram
    gantt.zig           Gantt chart (today marker, section backgrounds)
    timeline.zig        Timeline
    xychart.zig         XY chart (bar + line)
    quadrant.zig        Quadrant chart
    mindmap.zig         Mindmap (radial tree)
    sankey.zig          Sankey diagram
    c4.zig              C4 architecture diagrams (ext dashed borders, enterprise boundaries)
    block.zig           Block diagram (grid layout)
    requirement.zig     Requirement diagram (two-section boxes)
    kanban.zig          Kanban board (column + card layout)
  langium/              Parser for .langium grammar files
  jison/                Parser for .jison grammar files
grammars/               Embedded .langium and .jison grammar definitions
examples/               Source .mmd files for each diagram type
playground/             HTML + JS source for the live browser playground
include/                C API header (pozeiden.h)
```

Two grammar backends are used:

- **Langium backend**: for diagram types with a formal `.langium` grammar
  (pie, gitGraph). Parses the grammar file at compile time via `@embedFile`,
  then tokenises and interprets diagram text at runtime.
- **Direct parsers**: all other diagram types use hand-written line-oriented
  parsers in `root.zig`, which are simpler and faster for the formats mermaid uses.

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
