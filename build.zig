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
        .{
            .name = "xychart",
            .mmd =
            \\xychart-beta
            \\    title "Monthly Revenue"
            \\    x-axis [Jan, Feb, Mar, Apr, May, Jun]
            \\    y-axis "Revenue ($k)" 0 --> 120
            \\    bar [42, 55, 78, 90, 105, 115]
            \\    line [50, 60, 70, 85, 100, 110]
            \\
            ,
        },
        .{
            .name = "quadrant",
            .mmd =
            \\quadrantChart
            \\    title Feature Prioritization
            \\    x-axis Low Effort --> High Effort
            \\    y-axis Low Value --> High Value
            \\    quadrant-1 Schedule
            \\    quadrant-2 Do Now
            \\    quadrant-3 Deprioritize
            \\    quadrant-4 Delegate
            \\    Search: [0.3, 0.8]
            \\    Analytics: [0.7, 0.9]
            \\    Dark Mode: [0.2, 0.4]
            \\    Export CSV: [0.8, 0.3]
            \\    Onboarding: [0.5, 0.7]
            \\
            ,
        },
        .{
            .name = "mindmap",
            .mmd =
            \\mindmap
            \\  root((Software\nArchitecture))
            \\    Frontend
            \\      React
            \\      CSS
            \\    Backend
            \\      API
            \\      Database
            \\    DevOps
            \\      CI/CD
            \\      Monitoring
            \\
            ,
        },
        .{
            .name = "sankey",
            .mmd =
            \\sankey-beta
            \\Electricity,Lighting,25
            \\Electricity,Heating,40
            \\Electricity,Cooling,20
            \\Gas,Heating,60
            \\Gas,Cooking,15
            \\Heating,House,100
            \\Lighting,House,25
            \\Cooling,House,20
            \\Cooking,House,15
            \\
            ,
        },
        .{
            .name = "c4",
            .mmd =
            \\C4Context
            \\  title System Context for Online Shop
            \\  Person(customer, "Customer", "A shopper browsing and buying products")
            \\  Person(admin, "Admin", "Manages inventory and orders")
            \\  Enterprise_Boundary(b0, "Online Shop") {
            \\    System(webapp, "Web Application", "Serves the storefront and checkout")
            \\    System(orderSvc, "Order Service", "Processes and tracks orders")
            \\    SystemDb(db, "Product DB", "Stores product and order data")
            \\  }
            \\  System_Ext(payment, "Payment Gateway", "Handles card payments")
            \\  System_Ext(email, "Email System", "Sends order confirmations")
            \\  Rel(customer, webapp, "Browses and orders")
            \\  Rel(admin, webapp, "Manages catalogue")
            \\  Rel(webapp, orderSvc, "Places orders", "REST")
            \\  Rel(orderSvc, db, "Reads/writes", "SQL")
            \\  Rel(orderSvc, payment, "Charges card", "HTTPS")
            \\  Rel(orderSvc, email, "Sends confirmation", "SMTP")
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
