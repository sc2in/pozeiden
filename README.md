# pozeiden

A pure-Zig mermaid diagram renderer. Parses mermaid diagram text and produces
self-contained SVG output with no JavaScript runtime, no external processes,
and no heap allocations beyond the arena used during rendering.

## Supported diagram types

| Type | Keyword |
| ---- | ------- |
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

## Requirements

- Zig **0.15.2** or later

## Build

```sh
zig build          # builds the pozeiden CLI binary to zig-out/bin/
zig build test     # runs the test suite
zig build examples # renders examples/*.mmd to zig-out/examples/*.svg
```

## CLI usage

```sh
# stdin to stdout
echo 'pie\n"A": 1\n"B": 2' | pozeiden > out.svg

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
  c4.mmd          flowchart.mmd   gantt.mmd    gitgraph.mmd
  class.mmd       er.mmd          mindmap.mmd  pie.mmd
  quadrant.mmd    sankey.mmd      sequence.mmd state.mmd
  timeline.mmd    xychart.mmd
```

## Architecture

```text
src/
  root.zig              Public API: detect type, parse, dispatch to renderer
  detect.zig            First-line diagram type detection
  main.zig              CLI entry point
  diagram/
    value.zig           Generic AST value (string | number | bool | node | list)
  svg/
    writer.zig          Low-level SVG string builder
    theme.zig           Mermaid default theme constants
    layout.zig          DAG layout (simplified Sugiyama) for flowcharts
  renderers/
    pie.zig             Pie chart
    flowchart.zig       Flowchart / graph
    sequence.zig        Sequence diagram
    gitgraph.zig        Git graph
    class.zig           Class diagram
    state.zig           State diagram
    er.zig              Entity-relationship diagram
    gantt.zig           Gantt chart
    timeline.zig        Timeline
    xychart.zig         XY chart (bar + line)
    quadrant.zig        Quadrant chart
    mindmap.zig         Mindmap (radial tree)
    sankey.zig          Sankey diagram
    c4.zig              C4 architecture diagrams
  langium/              Parser for .langium grammar files (pie, gitGraph)
  jison/                Parser for .jison grammar files (flowchart)
grammars/               Embedded .langium and .jison grammar definitions
examples/               Source .mmd files for each diagram type
```

Two grammar backends are used:

- **Langium backend**: for diagram types with a formal `.langium` grammar
  (pie, gitGraph). Parses the grammar file at compile time via `@embedFile`,
  then tokenises and interprets diagram text at runtime.
- **Direct parsers**: all other diagram types use hand-written line-oriented
  parsers in `root.zig`, which are simpler and faster for the formats mermaid uses.

## License

MIT
