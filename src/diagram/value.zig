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
