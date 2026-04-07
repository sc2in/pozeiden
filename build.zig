const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mvzr = b.dependency("mvzr", .{
        .target = target,
        .optimize = optimize,
    });
    const mecha = b.dependency("mecha", .{});
    const zigmark = b.dependency("zigmark", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("pozeiden", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("mvzr", mvzr.module("mvzr"));
    mod.addImport("mecha", mecha.module("mecha"));
    mod.addImport("zigmark", zigmark.module("zigmark"));

    const exe = b.addExecutable(.{
        .name = "pozeiden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pozeiden", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    // ── examples step ─────────────────────────────────────────────────────────
    // Renders one mermaid diagram of each supported type and installs the
    // resulting SVGs to zig-out/examples/.
    //
    //   zig build examples
    //   open zig-out/examples/pie.svg

    const Example = struct { name: []const u8, mmd: []const u8 };
    const examples = [_]Example{
        .{
            .name = "pie",
            .mmd =
            \\pie title Pets adopted by volunteers
            \\"Dogs" : 386
            \\"Cats" : 200
            \\"Rats" : 15
            \\
            ,
        },
        .{
            .name = "flowchart",
            .mmd =
            \\graph TD
            \\    A[Start] --> B{Decision}
            \\    B -->|Yes| C[Process]
            \\    B -->|No| D[End]
            \\    C --> D
            \\
            ,
        },
        .{
            .name = "sequence",
            .mmd =
            \\sequenceDiagram
            \\    participant Alice
            \\    participant Bob
            \\    Alice->>Bob: Hello Bob!
            \\    Bob-->>Alice: Hi Alice!
            \\    loop every minute
            \\        Bob->>Bob: health check
            \\    end
            \\
            ,
        },
        .{
            .name = "gitgraph",
            .mmd =
            \\gitGraph
            \\    commit
            \\    branch develop
            \\    checkout develop
            \\    commit
            \\    commit
            \\    checkout main
            \\    merge develop
            \\    commit
            \\
            ,
        },
        .{
            .name = "class",
            .mmd =
            \\classDiagram
            \\    class Animal {
            \\        +String name
            \\        +makeSound() void
            \\    }
            \\    class Duck {
            \\        +swim() void
            \\    }
            \\    class Fish
            \\    Animal <|-- Duck
            \\    Animal <|-- Fish
            \\    Duck --> Fish : chases
            \\
            ,
        },
        .{
            .name = "state",
            .mmd =
            \\stateDiagram-v2
            \\    [*] --> Idle
            \\    Idle --> Running : start
            \\    Running --> Idle : stop
            \\    Running --> Error : fail
            \\    Error --> Idle : reset
            \\    Idle --> [*]
            \\
            ,
        },
        .{
            .name = "er",
            .mmd =
            \\erDiagram
            \\    CUSTOMER ||--o{ ORDER : "places"
            \\    ORDER ||--|{ LINE-ITEM : "contains"
            \\    CUSTOMER {
            \\        string name PK
            \\        string email
            \\    }
            \\    ORDER {
            \\        int orderNumber PK
            \\        string status
            \\    }
            \\
            ,
        },
        .{
            .name = "gantt",
            .mmd =
            \\gantt
            \\    title Project Timeline
            \\    dateFormat YYYY-MM-DD
            \\    section Design
            \\        Research        : done, 3d
            \\        Wireframes      : done, 2d
            \\    section Development
            \\        Backend         : crit, 5d
            \\        Frontend        : 4d
            \\    section Testing
            \\        QA              : 3d
            \\        Bug fixes       : 2d
            \\
            ,
        },
        .{
            .name = "timeline",
            .mmd =
            \\timeline
            \\    title History of Social Media
            \\    2002 : LinkedIn
            \\    2004 : Facebook
            \\    2005 : YouTube
            \\    2006 : Twitter
            \\    2010 : Instagram
            \\    2016 : TikTok
            \\
            ,
        },
    };

    const examples_step = b.step("examples", "Render example SVGs to zig-out/examples/");
    for (examples) |ex| {
        const run = b.addRunArtifact(exe);
        run.setStdIn(.{ .bytes = ex.mmd });
        const svg = run.captureStdOut();
        const install = b.addInstallFile(svg, b.fmt("examples/{s}.svg", .{ex.name}));
        examples_step.dependOn(&install.step);
    }
}
