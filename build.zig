const std = @import("std");

const zon = @import("build.zig.zon");

fn trimLeadingV(s: []const u8) []const u8 {
    return if (s.len > 0 and s[0] == 'v') s[1..] else s;
}

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

    // Version priority: -Dversion flag > git describe > build.zig.zon
    // The flag lets Nix (and other sandboxed builds) inject the version
    // without requiring git in the build environment.
    const options = b.addOptions();
    const version = b.option([]const u8, "version", "Override version string") orelse blk: {
        var exit_code: u8 = undefined;
        const git_describe = b.runAllowFail(
            &.{ "git", "describe", "--tags", "--always" },
            &exit_code,
            .Ignore,
        ) catch "";
        break :blk if (git_describe.len > 0) trimLeadingV(git_describe) else zon.version;
    };
    options.addOption([]const u8, "version", version);

    const mod = b.addModule("pozeiden", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("config", options);
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
    exe.root_module.addOptions("config", options);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .name = "pozeiden",
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    // C API tests — capi.zig is not part of the pozeiden module, so it needs
    // its own test artifact that imports pozeiden as a dependency.
    const capi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pozeiden", .module = mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(capi_tests).step);

    // ── check step ────────────────────────────────────────────────────────────
    // Semantic analysis without running — used by ZLS and CI.
    //
    //   zig build check

    const check_step = b.step("check", "Check for semantic errors (ZLS)");
    check_step.dependOn(&mod_tests.step);

    // ── docs step ─────────────────────────────────────────────────────────────
    // Generate API documentation.
    //
    //   zig build docs
    //   open zig-out/docs/index.html

    const docs_step = b.step("docs", "Generate API documentation to zig-out/docs/");
    const docs = b.addInstallDirectory(.{
        .source_dir = mod_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&docs.step);

    // ── lib step ──────────────────────────────────────────────────────────────
    // Builds a C-ABI shared library (libpozeiden.so) and installs the public
    // header.
    //
    //   zig build lib
    //   # produces zig-out/lib/libpozeiden.so and zig-out/include/pozeiden.h

    const capi_mod = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pozeiden", .module = mod },
        },
    });

    const ver = std.SemanticVersion.parse(zon.version) catch std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };
    const shared_lib = b.addLibrary(.{
        .name = "pozeiden",
        .root_module = capi_mod,
        .linkage = .dynamic,
        .version = .{ .major = ver.major, .minor = ver.minor, .patch = ver.patch },
    });

    b.installArtifact(shared_lib);
    b.installFile("include/pozeiden.h", "include/pozeiden.h");

    const lib_step = b.step("lib", "Build C shared library (libpozeiden.so)");
    lib_step.dependOn(b.getInstallStep());

    // ── playground step ───────────────────────────────────────────────────────
    // Compiles pozeiden to WebAssembly and bundles it with the HTML playground.
    //
    //   zig build playground
    //   cd zig-out/playground && python3 -m http.server
    //   open http://localhost:8000

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    const mvzr_wasm = b.dependency("mvzr", .{
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const mecha_wasm = b.dependency("mecha", .{});
    const zigmark_wasm = b.dependency("zigmark", .{
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const mod_wasm = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .single_threaded = true,
    });
    mod_wasm.addOptions("config", options);
    mod_wasm.addImport("mvzr", mvzr_wasm.module("mvzr"));
    mod_wasm.addImport("mecha", mecha_wasm.module("mecha"));
    mod_wasm.addImport("zigmark", zigmark_wasm.module("zigmark"));

    const wasm_exe = b.addExecutable(.{
        .name = "pozeiden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .single_threaded = true,
            .imports = &.{
                .{ .name = "pozeiden", .module = mod_wasm },
            },
        }),
    });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;

    const playground_step = b.step("playground", "Build WASM + HTML playground to zig-out/playground/");
    const install_wasm = b.addInstallArtifact(wasm_exe, .{
        .dest_dir = .{ .override = .{ .custom = "playground" } },
    });
    const install_html = b.addInstallFile(
        b.path("playground/index.html"),
        "playground/index.html",
    );
    playground_step.dependOn(&install_wasm.step);
    playground_step.dependOn(&install_html.step);

    // Copy .mmd example files into zig-out/playground/examples/ so the
    // playground can fetch them at runtime without hardcoding their content.
    const example_names_pg = [_][]const u8{
        "pie", "flowchart", "sequence", "gitgraph", "class",
        "state", "er", "gantt", "timeline", "xychart",
        "quadrant", "mindmap", "sankey", "c4",
        "block", "requirement", "kanban",
    };
    for (example_names_pg) |name| {
        const install_mmd = b.addInstallFile(
            b.path(b.fmt("examples/{s}.mmd", .{name})),
            b.fmt("playground/examples/{s}.mmd", .{name}),
        );
        playground_step.dependOn(&install_mmd.step);
    }

    // ── site step ─────────────────────────────────────────────────────────────
    // Combines playground + API docs into a single static site at zig-out/site/.
    // Playground files at the root; docs at /docs.
    //
    //   zig build site
    //   cd zig-out/site && python3 -m http.server

    const site_step = b.step("site", "Build combined site (playground + docs) to zig-out/site/");

    const site_wasm = b.addInstallArtifact(wasm_exe, .{
        .dest_dir = .{ .override = .{ .custom = "site" } },
    });
    site_step.dependOn(&site_wasm.step);

    const site_html = b.addInstallFile(b.path("playground/index.html"), "site/index.html");
    site_step.dependOn(&site_html.step);

    for (example_names_pg) |name| {
        const install_mmd = b.addInstallFile(
            b.path(b.fmt("examples/{s}.mmd", .{name})),
            b.fmt("site/examples/{s}.mmd", .{name}),
        );
        site_step.dependOn(&install_mmd.step);
    }

    const site_docs = b.addInstallDirectory(.{
        .source_dir = mod_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "site/docs",
    });
    site_step.dependOn(&site_docs.step);

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

    // ── fuzz step ─────────────────────────────────────────────────────────────
    // Smoke test:               zig build fuzz
    // Coverage-guided fuzzing:  zig build fuzz --fuzz

    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "pozeiden", .module = mod },
            },
        }),
        .use_llvm = true,
    });
    const fuzz_step = b.step("fuzz", "Run fuzz tests (append --fuzz for coverage-guided fuzzing)");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    // ── bench step ────────────────────────────────────────────────────────────
    // zig build bench

    const bench_exe = b.addExecutable(.{
        .name = "pozeiden-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "pozeiden", .module = mod },
            },
        }),
    });
    const bench_step = b.step("bench", "Benchmark render() over all 17 example diagrams");
    bench_step.dependOn(&b.addRunArtifact(bench_exe).step);
}
