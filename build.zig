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
    // Renders the .mmd files in examples/ to SVGs in zig-out/examples/.
    //
    //   zig build examples
    //   open zig-out/examples/pie.svg

    const example_names = [_][]const u8{
        "pie", "flowchart", "sequence", "gitgraph", "class",
        "state", "er", "gantt", "timeline", "xychart",
        "quadrant", "mindmap", "sankey", "c4",
        "block", "requirement", "kanban",
    };

    const examples_step = b.step("examples", "Render example SVGs to zig-out/examples/");
    for (example_names) |name| {
        const mmd = b.path(b.fmt("examples/{s}.mmd", .{name}));
        const run = b.addRunArtifact(exe);
        run.setStdIn(.{ .lazy_path = mmd });
        const svg = run.captureStdOut();
        const install = b.addInstallFile(svg, b.fmt("examples/{s}.svg", .{name}));
        examples_step.dependOn(&install.step);
    }
}
