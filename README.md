# pozeiden

A pure-Zig mermaid diagram renderer. Parses mermaid diagram text and produces
self-contained SVG output with no JavaScript runtime, no external processes,
and no heap allocations beyond the arena used during rendering.

## Supported diagram types

| Type                | Keyword                                                                    |
| ------------------- | -------------------------------------------------------------------------- |
| Pie chart           | `pie`                                                                      |
| Flowchart           | `graph` / `flowchart`                                                      |
| Sequence diagram    | `sequenceDiagram`                                                          |
| Git graph           | `gitGraph`                                                                 |
| Class diagram       | `classDiagram`                                                             |
| State diagram       | `stateDiagram-v2`                                                          |
| ER diagram          | `erDiagram`                                                                |
| Gantt chart         | `gantt`                                                                    |
| Timeline            | `timeline`                                                                 |
| XY chart            | `xychart-beta`                                                             |
| Quadrant chart      | `quadrantChart`                                                            |
| Mindmap             | `mindmap`                                                                  |
| Sankey diagram      | `sankey-beta`                                                              |
| C4 architecture     | `C4Context` / `C4Container` / `C4Component` / `C4Dynamic` / `C4Deployment` |
| Block diagram       | `block-beta`                                                               |
| Requirement diagram | `requirementDiagram`                                                       |
| Kanban board        | `kanban`                                                                   |

## Requirements

- Zig **0.15.2** or later

## Build

```sh
zig build            # builds the pozeiden CLI binary to zig-out/bin/
zig build test       # runs the test suite
zig build examples   # renders examples/*.mmd to zig-out/examples/*.svg
zig build playground # compiles pozeiden to WASM and bundles the live playground
                     # to zig-out/playground/
```

## Playground

A live browser playground is included. It compiles pozeiden to a ~295 KB
WebAssembly module and serves a split-pane editor where edits render instantly.

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

## CLI usage

```sh
# stdin → stdout
echo 'pie title Pets
"Dogs" : 60
"Cats" : 40' | pozeiden > out.svg

# explicit files
pozeiden -i diagram.mmd -o diagram.svg

# help
pozeiden --help
```

## Library usage

Add pozeiden as a dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .pozeiden = .{
        .url = "...",
        .hash = "...",
    },
},
```

Wire it up in `build.zig`:

```zig
const pozeiden = b.dependency("pozeiden", .{
    .target = target,
    .optimize = optimize,
});
your_module.addImport("pozeiden", pozeiden.module("pozeiden"));
```

Then call the single public function:

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

## Architecture

```text
src/
  root.zig              Public API: detect type, parse, dispatch to renderer
  detect.zig            First-line diagram type detection
  main.zig              CLI entry point
  wasm.zig              WebAssembly entry point (get_input_ptr / render / get_output_ptr)
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
  langium/              Parser for .langium grammar files (pie, gitGraph)
  jison/                Parser for .jison grammar files (flowchart)
grammars/               Embedded .langium and .jison grammar definitions
examples/               Source .mmd files for each diagram type
playground/             HTML + JS source for the live browser playground
```

Two grammar backends are used:

- **Langium backend**: for diagram types with a formal `.langium` grammar
  (pie, gitGraph). Parses the grammar file at compile time via `@embedFile`,
  then tokenises and interprets diagram text at runtime.
- **Direct parsers**: all other diagram types use hand-written line-oriented
  parsers in `root.zig`, which are simpler and faster for the formats mermaid uses.

## License

PolyForm NonCommercial v1.0.0
