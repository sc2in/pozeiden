//! Copyright © 2026 [Star City Security Consulting, LLC (SC2)](https://sc2.in)
//! SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//!
//! End-to-end render tests for the public API, moved verbatim out of
//! root.zig (#39). Every test goes through `render`/`renderWithOptions`,
//! so they live at the shell level rather than with any single parser.
const std = @import("std");

const pozeiden = @import("root.zig");
const render = pozeiden.render;
const renderWithOptions = pozeiden.renderWithOptions;
const detectDiagramType = pozeiden.detectDiagramType;
const DiagramType = pozeiden.DiagramType;
const parseSvgDimAttr = pozeiden.parseSvgDimAttr;

test "front matter is stripped before rendering" {
    // A titleless front-matter render must be byte-identical to the same
    // diagram without front matter — previously the block leaked into the
    // flowchart parser and its lines became nodes.
    const bare = "graph TD\n  A[Start] --> B[End]\n";
    const with_fm = "---\nconfig:\n  layout: dagre\n---\n" ++ bare;
    const expected = try render(std.testing.allocator, bare);
    defer std.testing.allocator.free(expected);
    const actual = try render(std.testing.allocator, with_fm);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);

    // With a front-matter title, the title text appears only as SVG metadata
    // (<title>), never as a diagram node (<text>).
    const titled = try render(std.testing.allocator, "---\ntitle: My Chart\n---\n" ++ bare);
    defer std.testing.allocator.free(titled);
    try std.testing.expect(std.mem.indexOf(u8, titled, "<title id=\"pz-title\">My Chart</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, titled, ">My Chart</text>") == null);
}

test "front matter followed by init directive still applies the directive" {
    const input = "---\ntitle: t\n---\n%%{init: {'theme':'dark'}}%%\ngraph TD\nA-->B\n";
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    // Dark theme's node fill replaces the default #ececff.
    try std.testing.expect(std.mem.indexOf(u8, svg, "#16213e") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "#ececff") == null);
}

test "unterminated front matter is still treated as ordinary content" {
    const input = "---\ngraph TD\nA-->B\n";
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
}

test "front-matter-only input falls back to the unknown renderer" {
    const svg = try render(std.testing.allocator, "---\ntitle: nothing else\n---\n");
    defer std.testing.allocator.free(svg);
    // The unknown fallback is a fixed 400x120 placeholder; the front-matter
    // title may appear only as SVG metadata, never as rendered diagram text.
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, ">nothing else</text>") == null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<title id=\"pz-title\">nothing else</title>") != null);
}

test "accTitle/accDescr become SVG title/desc with aria wiring" {
    const gpa = std.testing.allocator;
    const input = "graph TD\naccTitle: Deploy pipeline\naccDescr: Build, test and ship\nA-->B\n";
    const svg = try render(gpa, input);
    defer gpa.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "role=\"img\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "aria-labelledby=\"pz-title pz-desc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<title id=\"pz-title\">Deploy pipeline</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<desc id=\"pz-desc\">Build, test and ship</desc>") != null);
    // The directives must not leak into the diagram as nodes.
    try std.testing.expect(std.mem.indexOf(u8, svg, "accTitle") == null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "accDescr") == null);
}

test "accDescr block form is captured and removed" {
    const gpa = std.testing.allocator;
    const input = "graph TD\naccDescr {\n  spans multiple\n  lines\n}\nA-->B\n";
    const svg = try render(gpa, input);
    defer gpa.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<desc id=\"pz-desc\">spans multiple lines</desc>") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "aria-labelledby=\"pz-desc\"") != null);
}

test "front-matter title becomes the SVG title" {
    const gpa = std.testing.allocator;
    const input = "---\ntitle: \"Quarterly Plan\"\n---\ngraph TD\nA-->B\n";
    const svg = try render(gpa, input);
    defer gpa.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<title id=\"pz-title\">Quarterly Plan</title>") != null);
}

test "accessibility metadata is escaped in the SVG" {
    const gpa = std.testing.allocator;
    const input = "graph TD\naccTitle: </title><script>alert(1)</script>\nA-->B\n";
    const svg = try render(gpa, input);
    defer gpa.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "&lt;script&gt;") != null);
}

test "no accessibility metadata leaves the output untouched" {
    const gpa = std.testing.allocator;
    const svg = try render(gpa, "graph TD\nA-->B\n");
    defer gpa.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "role=\"img\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<title") == null);
}

test "renderWithMetadata returns type, title and description" {
    const gpa = std.testing.allocator;
    const input = "---\ntitle: FM Title\n---\ngraph TD\naccDescr: what it shows\nA-->B\n";
    const result = try pozeiden.renderWithMetadata(gpa, input, .{});
    defer result.deinit(gpa);
    try std.testing.expectEqual(DiagramType.flowchart, result.diagram_type);
    // No accTitle declared, so the front-matter title is the accessible name.
    try std.testing.expectEqualStrings("FM Title", result.title.?);
    try std.testing.expectEqualStrings("what it shows", result.descr.?);
    try std.testing.expect(std.mem.startsWith(u8, result.svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, result.svg, "<title id=\"pz-title\">FM Title</title>") != null);
}

test "renderWithMetadata prefers accTitle over front-matter title" {
    const gpa = std.testing.allocator;
    const input = "---\ntitle: FM Title\n---\ngraph TD\naccTitle: Acc Title\nA-->B\n";
    const result = try pozeiden.renderWithMetadata(gpa, input, .{});
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("Acc Title", result.title.?);
    try std.testing.expect(result.descr == null);
}

test "detect and render pie" {
    const input = "pie\n\"Dogs\" : 50\n\"Cats\" : 50\n";
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "<path") != null);
}

test "detect and render flowchart" {
    const input = "graph TD\nA-->B\nB-->C\n";
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
}

test "detect and render sequence" {
    const input = "sequenceDiagram\nAlice->>Bob: hi\nBob-->>Alice: hello\n";
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "Alice") != null);
}

test "detect and render gitgraph" {
    const input = "gitGraph\ncommit\nbranch dev\ncheckout dev\ncommit\n";
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "<circle") != null);
}

test "detect and render classDiagram" {
    const input =
        \\classDiagram
        \\    class Animal {
        \\        +String name
        \\        +makeSound() void
        \\    }
        \\    class Duck
        \\    Animal <|-- Duck
        \\
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "Animal") != null);
}

test "detect and render stateDiagram" {
    const input =
        \\stateDiagram-v2
        \\    [*] --> Idle
        \\    Idle --> Running : start
        \\    Running --> Idle : stop
        \\
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "Idle") != null);
}

test "detect and render erDiagram" {
    const input =
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : "places"
        \\    CUSTOMER {
        \\        string name PK
        \\    }
        \\
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "CUSTOMER") != null);
}

test "detect and render gantt" {
    const input =
        \\gantt
        \\    title My Project
        \\    section Phase 1
        \\        Task A : 2d
        \\        Task B : crit, 3d
        \\
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "Task A") != null);
}

test "detect and render timeline" {
    const input =
        \\timeline
        \\    title Tech History
        \\    2000 : Y2K survived
        \\    2007 : iPhone
        \\    2020 : COVID remote work
        \\
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "iPhone") != null);
}

test "detect and render xychart" {
    const input =
        \\xychart-beta
        \\    title "Revenue"
        \\    x-axis [Q1, Q2, Q3, Q4]
        \\    y-axis 0 --> 10000
        \\    bar [2000, 4000, 6000, 8000]
        \\    line [3000, 3500, 5000, 7000]
        \\
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
}

test "detect and render quadrantChart" {
    const input =
        \\quadrantChart
        \\    title Effort vs Impact
        \\    x-axis Low Effort --> High Effort
        \\    y-axis Low Impact --> High Impact
        \\    quadrant-1 Quick Wins
        \\    Campaign A: [0.3, 0.7]
        \\    Campaign B: [0.8, 0.4]
        \\
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "<circle") != null);
}

test "detect and render mindmap" {
    const input =
        \\mindmap
        \\  root((Main Topic))
        \\    Branch A
        \\      Leaf A1
        \\    Branch B
        \\
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "Main Topic") != null);
}

test "detect and render sankey" {
    const input =
        \\sankey-beta
        \\A,B,40
        \\B,C,30
        \\A,C,10
        \\
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "<path") != null);
}

test "detect and render C4Context" {
    const input =
        \\C4Context
        \\  title System Context
        \\  Person(user, "User", "A person using the system")
        \\  System(webapp, "Web App", "The main application")
        \\  System_Ext(email, "Email System", "Sends notifications")
        \\  Rel(user, webapp, "Uses")
        \\  Rel(webapp, email, "Sends email", "SMTP")
        \\
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "Web App") != null);
}

// ─── Flowchart feature tests ──────────────────────────────────────────────────

test "flowchart LR direction" {
    const input = "graph LR\nStart --> Process --> End\n";
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Process") != null);
}

test "flowchart diamond and circle shapes" {
    const input =
        \\graph TD
        \\A{Decision}
        \\B((Circle))
        \\A --> B
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<polygon") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<circle") != null);
}

test "flowchart edge label and dotted style" {
    const input =
        \\graph TD
        \\A --> |yes| B
        \\B -.-> C
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "stroke-dasharray") != null);
}

test "flowchart multi-node chain" {
    const input = "graph TD\nA[Start] --> B[Middle] --> C[End]\n";
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Start") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Middle") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "End") != null);
}

test "flowchart BT direction" {
    const input = "graph BT\nA --> B\n";
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
}

test "flowchart orthogonal path connector" {
    // Orthogonal routing: edges use <path> with lineto (L) segments
    const input = "graph TD\nA --> B\nB --> C\n";
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<path") != null);
    // Orthogonal routing uses 'L' (lineto) commands, not Bezier 'C'
    try std.testing.expect(std.mem.indexOf(u8, svg, " L ") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, " C ") == null);
}

test "flowchart cylinder hexagon subroutine shapes" {
    const input =
        \\graph TD
        \\A[(Database)]
        \\B{{Hexagon}}
        \\C[[Subroutine]]
        \\A --> B --> C
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    // Cylinder: ellipse element
    try std.testing.expect(std.mem.indexOf(u8, svg, "<ellipse") != null);
    // Hexagon: polygon with 6 points
    try std.testing.expect(std.mem.indexOf(u8, svg, "<polygon") != null);
    // Subroutine: rect + inner vertical lines
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Database") != null);
}

test "flowchart stadium and round shapes" {
    const input =
        \\graph LR
        \\A([Stadium])
        \\B(Round)
        \\A --> B
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Stadium") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Round") != null);
}

test "flowchart -- label --> edge syntax" {
    const input =
        \\graph TD
        \\A -- yes --> B
        \\A -- no --> C
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "no") != null);
}

// ─── Sequence feature tests ───────────────────────────────────────────────────

test "sequence self-message" {
    const input =
        \\sequenceDiagram
        \\Alice->>Alice: Think
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Think") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<line") != null);
}

test "sequence dotted return arrow" {
    const input =
        \\sequenceDiagram
        \\Alice->>Bob: request
        \\Bob-->>Alice: response
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "request") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "stroke-dasharray") != null);
}

test "sequence loop block" {
    const input =
        \\sequenceDiagram
        \\loop Retry
        \\Alice->>Bob: ping
        \\end
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Retry") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
}

test "sequence alt block" {
    const input =
        \\sequenceDiagram
        \\alt success
        \\Alice->>Bob: ok
        \\end
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "success") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
}

test "sequence participants declared explicitly" {
    const input =
        \\sequenceDiagram
        \\participant Server
        \\participant Client
        \\Server->>Client: data
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Server") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Client") != null);
}

test "sequence opt block rendered" {
    const input =
        \\sequenceDiagram
        \\Alice->>Bob: request
        \\opt retry
        \\Bob->>Bob: retry
        \\end
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "retry") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
}

test "sequence par block rendered" {
    const input =
        \\sequenceDiagram
        \\par send emails
        \\Alice->>Bob: email1
        \\and send notifications
        \\Alice->>Carol: email2
        \\end
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "send emails") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
}

test "sequence note rendered" {
    const input =
        \\sequenceDiagram
        \\Alice->>Bob: hello
        \\Note right of Bob: thinking
        \\Bob-->>Alice: world
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "world") != null);
    // Note box rendered
    try std.testing.expect(std.mem.indexOf(u8, svg, "thinking") != null);
}

test "sequence note over two actors" {
    const input =
        \\sequenceDiagram
        \\Alice->>Bob: request
        \\Note over Alice,Bob: processing
        \\Bob-->>Alice: response
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "processing") != null);
}

test "sequence activation box" {
    const input =
        \\sequenceDiagram
        \\Alice->>Bob: request
        \\activate Bob
        \\Bob-->>Alice: response
        \\deactivate Bob
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "request") != null);
    // Activation bar is a narrow rect
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
}

test "sequence autonumber" {
    const input =
        \\sequenceDiagram
        \\autonumber
        \\Alice->>Bob: hello
        \\Bob-->>Alice: world
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "1.") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "2.") != null);
}

// ─── ClassDiagram feature tests ───────────────────────────────────────────────

test "classDiagram inheritance terminator" {
    const input =
        \\classDiagram
        \\class Vehicle
        \\class Car
        \\Vehicle <|-- Car
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Vehicle") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<polygon") != null);
}

test "classDiagram composition terminator" {
    const input =
        \\classDiagram
        \\class Engine
        \\class Car
        \\Car *-- Engine
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<polygon") != null);
}

test "classDiagram visibility modifiers rendered" {
    const input =
        \\classDiagram
        \\class BankAccount {
        \\    +String owner
        \\    -float balance
        \\    +deposit(amount) void
        \\}
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "BankAccount") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "owner") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "balance") != null);
}

test "classDiagram dependency dashed line" {
    const input =
        \\classDiagram
        \\class Logger
        \\class Service
        \\Service ..> Logger
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "stroke-dasharray") != null);
}

test "classDiagram relation label" {
    const input =
        \\classDiagram
        \\class Driver
        \\class Car
        \\Driver --> Car : drives
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "drives") != null);
}

test "classDiagram stereotype inline" {
    const input =
        \\classDiagram
        \\class Animal <<interface>> {
        \\  +makeSound() String
        \\}
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Animal") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "interface") != null);
}

test "classDiagram stereotype block" {
    const input =
        \\classDiagram
        \\class Shape {
        \\  <<abstract>>
        \\  +draw() void
        \\}
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "abstract") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "draw") != null);
}

test "classDiagram generic type notation" {
    const input =
        \\classDiagram
        \\class Container~T~ {
        \\  +items List~T~
        \\  +add(item T) void
        \\}
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    // Generic types rendered as <T>
    try std.testing.expect(std.mem.indexOf(u8, svg, "List") != null);
}

// ─── StateDiagram feature tests ───────────────────────────────────────────────

test "stateDiagram entry and exit star" {
    const input =
        \\stateDiagram-v2
        \\[*] --> Active
        \\Active --> [*]
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<circle") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Active") != null);
}

test "stateDiagram transition labels" {
    const input =
        \\stateDiagram-v2
        \\Idle --> Running : start
        \\Running --> Idle : stop
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "start") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "stop") != null);
}

test "stateDiagram multiple states" {
    const input =
        \\stateDiagram-v2
        \\[*] --> Idle
        \\Idle --> Processing
        \\Processing --> Done
        \\Done --> [*]
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Idle") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Processing") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Done") != null);
}

test "stateDiagram compound state label" {
    const input =
        \\stateDiagram-v2
        \\state "Running State" as Running {
        \\    [*] --> A
        \\    A --> B
        \\}
        \\[*] --> Running
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Running State") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Running") != null);
}

// ─── ER Diagram feature tests ──────────────────────────────────────────────────

test "erDiagram one-to-many relation" {
    const input =
        \\erDiagram
        \\CUSTOMER ||--o{ ORDER : "places"
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "CUSTOMER") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "ORDER") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "places") != null);
}

test "erDiagram zero-or-one cardinality circle" {
    const input =
        \\erDiagram
        \\PERSON o|--|| PASSPORT : "has"
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<circle") != null);
}

test "erDiagram attribute PK marker" {
    const input =
        \\erDiagram
        \\PRODUCT {
        \\    int id PK
        \\    string name
        \\}
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "PRODUCT") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "PK") != null);
}

test "erDiagram dashed relationship line" {
    const input =
        \\erDiagram
        \\EMPLOYEE }o..o{ PROJECT : "works on"
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "stroke-dasharray") != null);
}

// ─── Gantt feature tests ───────────────────────────────────────────────────────

test "gantt crit task color" {
    const input =
        \\gantt
        \\title Sprint
        \\section Dev
        \\Critical path : crit, 3d
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "#e55039") != null);
}

test "gantt done task color" {
    const input =
        \\gantt
        \\title Project
        \\section Phase 1
        \\Finished task : done, 2d
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "#95a5a6") != null);
}

test "gantt multiple sections" {
    const input =
        \\gantt
        \\title Roadmap
        \\section Alpha
        \\Feature A : 2d
        \\section Beta
        \\Feature B : 3d
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Beta") != null);
}

test "gantt title in SVG" {
    const input =
        \\gantt
        \\title My Timeline
        \\section Work
        \\Task : 1d
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "My Timeline") != null);
}

test "gantt milestone diamond rendered" {
    const input =
        \\gantt
        \\title Release
        \\section Launch
        \\Deploy : milestone, 0d
        \\Verify : 1d
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<polygon") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Deploy") != null);
}

test "flowchart subgraph background box" {
    const input =
        \\graph TD
        \\subgraph Service Layer
        \\A[Auth] --> B[API]
        \\end
        \\B --> C[DB]
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Service Layer") != null);
}

// ─── block-beta tests ─────────────────────────────────────────────────────────

test "block-beta basic grid" {
    const input =
        \\block-beta
        \\columns 3
        \\A["Block A"] B["Block B"] C["Block C"]
        \\A --> B
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Block A") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Block B") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<line") != null);
}

test "block-beta bare ids" {
    const input =
        \\block-beta
        \\columns 2
        \\A B
        \\A --> B
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
}

// ─── requirementDiagram tests ─────────────────────────────────────────────────

test "requirementDiagram basic" {
    const input =
        \\requirementDiagram
        \\requirement req1 {
        \\id: 1
        \\text: "Shall do X"
        \\risk: high
        \\verifyMethod: test
        \\}
        \\element sys1 {
        \\type: simulation
        \\}
        \\sys1 - satisfies -> req1
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "req1") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "satisfies") != null);
}

// ─── kanban tests ─────────────────────────────────────────────────────────────

test "kanban basic board" {
    const input =
        \\kanban
        \\todo
        \\  id1["Task A"]
        \\  id2["Task B"]
        \\in-progress
        \\  id3["Task C"]
        \\done
        \\  id4["Task D"]
    ;
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "todo") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Task A") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "done") != null);
}

test "detectDiagramType public API" {
    try std.testing.expectEqual(DiagramType.pie, detectDiagramType("pie title Pets\n"));
    try std.testing.expectEqual(DiagramType.flowchart, detectDiagramType("graph TD\nA-->B\n"));
    try std.testing.expectEqual(DiagramType.sequence, detectDiagramType("sequenceDiagram\n"));
    try std.testing.expectEqual(DiagramType.unknown, detectDiagramType("notADiagram\n"));
}

test "renderWithOptions font_family override" {
    const input = "pie\n\"A\" : 60\n\"B\" : 40\n";
    const svg = try renderWithOptions(std.testing.allocator, input, .{
        .theme_override = .{ .font_family = "Liberation Sans, sans-serif" },
    });
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Liberation Sans") != null);
    // Ensure default font is NOT present after override
    try std.testing.expect(std.mem.indexOf(u8, svg, "trebuchet") == null);
}

test "renderWithOptions max_width shrinks SVG" {
    const input = "pie\n\"A\" : 60\n\"B\" : 40\n";
    const svg_full = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg_full);
    const full_w = parseSvgDimAttr(svg_full[0 .. std.mem.indexOf(u8, svg_full, ">").? + 1], "width") orelse 0;
    try std.testing.expect(full_w > 0);

    const svg_small = try renderWithOptions(std.testing.allocator, input, .{ .max_width = full_w / 2 });
    defer std.testing.allocator.free(svg_small);
    const small_w = parseSvgDimAttr(svg_small[0 .. std.mem.indexOf(u8, svg_small, ">").? + 1], "width") orelse 0;
    try std.testing.expect(small_w <= full_w / 2 + 1); // allow ±1 for rounding
    // viewBox should still reference original dimensions
    try std.testing.expect(std.mem.indexOf(u8, svg_small, "viewBox") != null);
}

test "renderWithOptions scale factor" {
    const input = "pie\n\"A\" : 60\n\"B\" : 40\n";
    const svg_full = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg_full);
    const full_w = parseSvgDimAttr(svg_full[0 .. std.mem.indexOf(u8, svg_full, ">").? + 1], "width") orelse 0;

    const svg_half = try renderWithOptions(std.testing.allocator, input, .{ .scale = 0.5 });
    defer std.testing.allocator.free(svg_half);
    const half_w = parseSvgDimAttr(svg_half[0 .. std.mem.indexOf(u8, svg_half, ">").? + 1], "width") orelse 0;
    const expected: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(full_w)) * 0.5));
    try std.testing.expectEqual(expected, half_w);
}

test "render unknown diagram type emits fallback SVG" {
    const svg = try render(std.testing.allocator, "not a diagram at all\n");
    defer std.testing.allocator.free(svg);
    // Unknown input produces a fallback SVG, not an error
    try std.testing.expect(std.mem.indexOf(u8, svg, "<svg") != null);
}

test "renderWithOptions strict=true returns UnknownDiagramType error" {
    try std.testing.expectError(
        error.UnknownDiagramType,
        renderWithOptions(std.testing.allocator, "not a diagram\n", .{ .strict = true }),
    );
}

test "renderWithOptions max_height shrinks SVG proportionally" {
    const input = "graph TD\nA-->B\nB-->C\n";
    const svg_full = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg_full);
    const orig_h = parseSvgDimAttr(svg_full[0 .. std.mem.indexOf(u8, svg_full, ">").? + 1], "height") orelse 0;
    try std.testing.expect(orig_h > 0);

    const max_h = orig_h / 2;
    const svg_small = try renderWithOptions(std.testing.allocator, input, .{ .max_height = max_h });
    defer std.testing.allocator.free(svg_small);
    const small_h = parseSvgDimAttr(svg_small[0 .. std.mem.indexOf(u8, svg_small, ">").? + 1], "height") orelse 0;
    try std.testing.expect(small_h <= max_h + 1);
}

test "renderWithOptions scale=1.0 is identity" {
    const input = "pie\n\"A\" : 50\n\"B\" : 50\n";
    const svg_base = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg_base);
    const svg_scaled = try renderWithOptions(std.testing.allocator, input, .{ .scale = 1.0 });
    defer std.testing.allocator.free(svg_scaled);
    const w_base = parseSvgDimAttr(svg_base[0 .. std.mem.indexOf(u8, svg_base, ">").? + 1], "width") orelse 0;
    const w_scaled = parseSvgDimAttr(svg_scaled[0 .. std.mem.indexOf(u8, svg_scaled, ">").? + 1], "width") orelse 0;
    try std.testing.expectEqual(w_base, w_scaled);
}

test "renderWithOptions max_width larger than SVG does not upscale" {
    const input = "pie\n\"A\" : 50\n\"B\" : 50\n";
    const svg_full = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg_full);
    const orig_w = parseSvgDimAttr(svg_full[0 .. std.mem.indexOf(u8, svg_full, ">").? + 1], "width") orelse 0;

    const svg_big = try renderWithOptions(std.testing.allocator, input, .{ .max_width = orig_w * 10 });
    defer std.testing.allocator.free(svg_big);
    const big_w = parseSvgDimAttr(svg_big[0 .. std.mem.indexOf(u8, svg_big, ">").? + 1], "width") orelse 0;
    // Should not be upscaled beyond original
    try std.testing.expectEqual(orig_w, big_w);
}

test "render init directive dark theme applies dark background" {
    // Use pie chart — it draws an explicit background rect using theme.background
    const input = "%%{init: {'theme': 'dark'}}%%\npie\n\"A\" : 100\n";
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "#1a1a2e") != null);
}

test "render init directive themeVariables primaryColor overrides node fill" {
    const input = "%%{init: {'themeVariables': {'primaryColor': '#ff1234'}}}%%\ngraph TD\nA-->B\n";
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "#ff1234") != null);
}

test "render init directive unknown theme is silently ignored" {
    const input = "%%{init: {'theme': 'nonexistent'}}%%\npie\n\"A\" : 100\n";
    // Should not error — unknown theme is a no-op
    const svg = try render(std.testing.allocator, input);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<svg") != null);
}

test "concurrent rendering across threads is safe" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    const pie_src = "pie title Pets\n\"Dogs\" : 60\n\"Cats\" : 40\n";
    const git_src = "gitGraph\n  commit\n  commit\n  branch dev\n  commit\n";
    const flow_src = "graph TD\nA-->B\nB-->C\n";

    const Worker = struct {
        // Each worker uses its own allocator so leak detection stays per-thread.
        fn run(failed: *std.atomic.Value(bool), font: ?[]const u8) void {
            var dbg: std.heap.DebugAllocator(.{}) = .init;
            defer if (dbg.deinit() == .leak) failed.store(true, .release);
            const a = dbg.allocator();

            var i: usize = 0;
            while (i < 25) : (i += 1) {
                // Hit the lazily-initialised langium caches (pie, gitGraph) and
                // a direct parser (flowchart) from every thread at once.
                inline for (.{ pie_src, git_src, flow_src }) |src| {
                    const svg = render(a, src) catch {
                        failed.store(true, .release);
                        return;
                    };
                    a.free(svg);
                }

                // Theme isolation: an override must show up in this thread's
                // output and never leak into threads rendering with defaults.
                const svg = if (font) |f|
                    renderWithOptions(a, pie_src, .{ .theme_override = .{ .font_family = f } }) catch {
                        failed.store(true, .release);
                        return;
                    }
                else
                    render(a, pie_src) catch {
                        failed.store(true, .release);
                        return;
                    };
                defer a.free(svg);

                const expected = font orelse "trebuchet ms";
                if (std.mem.indexOf(u8, svg, expected) == null) failed.store(true, .release);
                if (font == null and std.mem.indexOf(u8, svg, "PPThreadFont") != null) failed.store(true, .release);
            }
        }
    };

    var failed: std.atomic.Value(bool) = .init(false);
    const fonts = [_]?[]const u8{ "PPThreadFontA", "PPThreadFontB", null, null };
    var threads: [fonts.len]std.Thread = undefined;
    for (fonts, 0..) |font, i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{ &failed, font });
    }
    for (&threads) |*t| t.join();

    try std.testing.expect(!failed.load(.acquire));
}
