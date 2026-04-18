//! Generic diagram AST value produced by both the Langium and Jison runtimes.
//!
//! Both grammar backends produce a `Value` tree that the renderers consume.
//! All slices inside a `Value` tree point into the arena allocator that was
//! passed to the runtime; renderers must not free individual fields.
const std = @import("std");

/// A tagged-union value in the diagram AST.
///
/// `.node` is the most common variant; it represents a typed record with
/// named fields.  `.list` holds an ordered sequence of child values.
/// `.string`, `.number`, and `.boolean` are leaf values.  `.null` represents
/// an absent optional.
const testing = std.testing;

pub const Value = union(enum) {
    string: []const u8,
    number: f64,
    boolean: bool,
    node: Node,
    list: []Value,
    null: void,

    /// A named record node with typed fields stored in a hash map.
    pub const Node = struct {
        /// The grammar rule or element kind that produced this node,
        /// e.g. `"pie"`, `"edge"`, `"signal"`.
        type_name: []const u8,
        fields: std.StringHashMapUnmanaged(Value),

        /// Return the raw `Value` for `key`, or `null` if absent.
        pub fn get(self: Node, key: []const u8) ?Value {
            return self.fields.get(key);
        }

        /// Return the string payload of field `key`, or `null` if absent or
        /// not a string.
        pub fn getString(self: Node, key: []const u8) ?[]const u8 {
            const v = self.fields.get(key) orelse return null;
            return switch (v) {
                .string => |s| s,
                else => null,
            };
        }

        /// Return the numeric payload of field `key` as `f64`, coercing from
        /// a string if necessary.  Returns `null` if absent or unparseable.
        pub fn getNumber(self: Node, key: []const u8) ?f64 {
            const v = self.fields.get(key) orelse return null;
            return switch (v) {
                .number => |n| n,
                .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n")) catch null,
                else => null,
            };
        }

        /// Return the boolean payload of field `key`, or `false` if absent or
        /// not a boolean.
        pub fn getBool(self: Node, key: []const u8) bool {
            const v = self.fields.get(key) orelse return false;
            return switch (v) {
                .boolean => |b| b,
                else => false,
            };
        }

        /// Return the list payload of field `key`, or an empty slice if absent
        /// or not a list.
        pub fn getList(self: Node, key: []const u8) []Value {
            const v = self.fields.get(key) orelse return &.{};
            return switch (v) {
                .list => |l| l,
                else => &.{},
            };
        }
    };

    /// Unwrap as a string, or return `null`.
    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    /// Unwrap as a number, coercing from string if needed, or return `null`.
    pub fn asNumber(self: Value) ?f64 {
        return switch (self) {
            .number => |n| n,
            .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n")) catch null,
            else => null,
        };
    }

    /// Unwrap as a boolean, or return `false`.
    pub fn asBool(self: Value) bool {
        return switch (self) {
            .boolean => |b| b,
            else => false,
        };
    }

    /// Unwrap as a `Node`, or return `null`.
    pub fn asNode(self: Value) ?Node {
        return switch (self) {
            .node => |n| n,
            else => null,
        };
    }

    /// Unwrap as a list, or return an empty slice.
    pub fn asList(self: Value) []Value {
        return switch (self) {
            .list => |l| l,
            else => &.{},
        };
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Value.asString returns string payload" {
    const v: Value = .{ .string = "hello" };
    try testing.expectEqualStrings("hello", v.asString().?);
}

test "Value.asString returns null for non-string" {
    try testing.expect((Value{ .number = 1.0 }).asString() == null);
    try testing.expect((Value{ .boolean = true }).asString() == null);
    try testing.expect((Value{ .null = {} }).asString() == null);
}

test "Value.asNumber returns number payload" {
    const v: Value = .{ .number = 3.14 };
    try testing.expectApproxEqAbs(@as(f64, 3.14), v.asNumber().?, 1e-9);
}

test "Value.asNumber coerces parseable string" {
    const v: Value = .{ .string = "42" };
    try testing.expectApproxEqAbs(@as(f64, 42.0), v.asNumber().?, 1e-9);
}

test "Value.asNumber coerces whitespace-padded string" {
    const v: Value = .{ .string = "  7.5  " };
    try testing.expectApproxEqAbs(@as(f64, 7.5), v.asNumber().?, 1e-9);
}

test "Value.asNumber returns null for boolean" {
    try testing.expect((Value{ .boolean = true }).asNumber() == null);
}

test "Value.asNumber returns null for unparseable string" {
    try testing.expect((Value{ .string = "abc" }).asNumber() == null);
}

test "Value.asBool returns bool payload" {
    try testing.expect((Value{ .boolean = true }).asBool() == true);
    try testing.expect((Value{ .boolean = false }).asBool() == false);
}

test "Value.asBool returns false for non-bool" {
    try testing.expect((Value{ .number = 1.0 }).asBool() == false);
    try testing.expect((Value{ .string = "true" }).asBool() == false);
    try testing.expect((Value{ .null = {} }).asBool() == false);
}

test "Value.asNode returns node payload" {
    const node: Value.Node = .{ .type_name = "test", .fields = .{} };
    const v: Value = .{ .node = node };
    try testing.expectEqualStrings("test", v.asNode().?.type_name);
}

test "Value.asNode returns null for non-node" {
    try testing.expect((Value{ .string = "x" }).asNode() == null);
    try testing.expect((Value{ .null = {} }).asNode() == null);
}

test "Value.asList returns list payload" {
    const items = [_]Value{.{ .number = 1 }, .{ .number = 2 }};
    const v: Value = .{ .list = @constCast(&items) };
    try testing.expectEqual(@as(usize, 2), v.asList().len);
}

test "Value.asList returns empty slice for non-list" {
    try testing.expectEqual(@as(usize, 0), (Value{ .string = "x" }).asList().len);
    try testing.expectEqual(@as(usize, 0), (Value{ .number = 1 }).asList().len);
}

test "Value.null.asList returns empty slice" {
    const v: Value = .{ .null = {} };
    try testing.expectEqual(@as(usize, 0), v.asList().len);
}

test "Node.get returns present value" {
    var fields: std.StringHashMapUnmanaged(Value) = .{};
    defer fields.deinit(testing.allocator);
    try fields.put(testing.allocator, "x", .{ .number = 5.0 });
    const node: Value.Node = .{ .type_name = "n", .fields = fields };
    try testing.expect(node.get("x") != null);
    try testing.expectApproxEqAbs(@as(f64, 5.0), node.get("x").?.number, 1e-9);
}

test "Node.get returns null for absent key" {
    const node: Value.Node = .{ .type_name = "n", .fields = .{} };
    try testing.expect(node.get("missing") == null);
}

test "Node.getString happy path" {
    var fields: std.StringHashMapUnmanaged(Value) = .{};
    defer fields.deinit(testing.allocator);
    try fields.put(testing.allocator, "label", .{ .string = "Alice" });
    const node: Value.Node = .{ .type_name = "n", .fields = fields };
    try testing.expectEqualStrings("Alice", node.getString("label").?);
}

test "Node.getString returns null when field is number" {
    var fields: std.StringHashMapUnmanaged(Value) = .{};
    defer fields.deinit(testing.allocator);
    try fields.put(testing.allocator, "val", .{ .number = 1.0 });
    const node: Value.Node = .{ .type_name = "n", .fields = fields };
    try testing.expect(node.getString("val") == null);
}

test "Node.getNumber happy path" {
    var fields: std.StringHashMapUnmanaged(Value) = .{};
    defer fields.deinit(testing.allocator);
    try fields.put(testing.allocator, "n", .{ .number = 99.0 });
    const node: Value.Node = .{ .type_name = "n", .fields = fields };
    try testing.expectApproxEqAbs(@as(f64, 99.0), node.getNumber("n").?, 1e-9);
}

test "Node.getNumber coerces string field" {
    var fields: std.StringHashMapUnmanaged(Value) = .{};
    defer fields.deinit(testing.allocator);
    try fields.put(testing.allocator, "n", .{ .string = "3.14" });
    const node: Value.Node = .{ .type_name = "n", .fields = fields };
    try testing.expectApproxEqAbs(@as(f64, 3.14), node.getNumber("n").?, 1e-9);
}

test "Node.getBool happy path and default false" {
    var fields: std.StringHashMapUnmanaged(Value) = .{};
    defer fields.deinit(testing.allocator);
    try fields.put(testing.allocator, "flag", .{ .boolean = true });
    const node: Value.Node = .{ .type_name = "n", .fields = fields };
    try testing.expect(node.getBool("flag") == true);
    try testing.expect(node.getBool("missing") == false);
}

test "Node.getList happy path and empty fallback" {
    var fields: std.StringHashMapUnmanaged(Value) = .{};
    defer fields.deinit(testing.allocator);
    const items = [_]Value{.{ .string = "a" }};
    try fields.put(testing.allocator, "items", .{ .list = @constCast(&items) });
    const node: Value.Node = .{ .type_name = "n", .fields = fields };
    try testing.expectEqual(@as(usize, 1), node.getList("items").len);
    try testing.expectEqual(@as(usize, 0), node.getList("missing").len);
}
