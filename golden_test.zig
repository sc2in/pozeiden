//! Golden-file regression tests.
//!
//! Each case renders an `examples/*.mmd` diagram and asserts the output is
//! byte-for-byte identical to the committed baseline in `tests/golden/*.svg`.
//! This is the exact-output complement to the substring assertions elsewhere:
//! it catches any unintended change to rendered markup (including a regression
//! that leaked unescaped bytes into an attribute) and gives every diagram type
//! — several of which have no other dedicated tests — a concrete baseline.
//!
//! This file lives at the repository root because `@embedFile` resolves paths
//! within the module's root directory; keeping it here lets it reach both
//! `examples/` and `tests/golden/` without escaping that root.
//!
//! When a rendering change is intentional, regenerate the baselines with
//! `zig build update-golden` and review the resulting `git diff tests/golden/`.
const std = @import("std");
const pozeiden = @import("pozeiden");

const Case = struct { name: []const u8, input: []const u8, golden: []const u8 };

fn case(comptime name: []const u8) Case {
    return .{
        .name = name,
        .input = @embedFile("examples/" ++ name ++ ".mmd"),
        .golden = @embedFile("tests/golden/" ++ name ++ ".svg"),
    };
}

const cases = [_]Case{
    case("pie"),         case("flowchart"), case("sequence"),
    case("gitgraph"),    case("class"),     case("state"),
    case("er"),          case("gantt"),     case("timeline"),
    case("xychart"),     case("quadrant"),  case("mindmap"),
    case("sankey"),      case("c4"),        case("block"),
    case("requirement"), case("kanban"),
};

test "golden: example diagrams render to their committed baselines" {
    for (cases) |c| {
        const svg = try pozeiden.render(std.testing.allocator, c.input);
        defer std.testing.allocator.free(svg);
        std.testing.expectEqualStrings(c.golden, svg) catch |err| {
            std.debug.print(
                "\ngolden mismatch for '{s}'. If this change is intentional, run" ++
                    " `zig build update-golden` and review the diff.\n",
                .{c.name},
            );
            return err;
        };
    }
}

test "golden: every example diagram type has a baseline" {
    try std.testing.expectEqual(@as(usize, 17), cases.len);
}
