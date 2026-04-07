//! Generic diagram AST value produced by both Langium and Jison runtimes.
//! All memory is owned by the arena passed to the runtime.
const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    number: f64,
    boolean: bool,
    node: Node,
    list: []Value,
    null: void,

    pub const Node = struct {
        type_name: []const u8,
        fields: std.StringHashMapUnmanaged(Value),

        pub fn get(self: Node, key: []const u8) ?Value {
            return self.fields.get(key);
        }

        pub fn getString(self: Node, key: []const u8) ?[]const u8 {
            const v = self.fields.get(key) orelse return null;
            return switch (v) {
                .string => |s| s,
                else => null,
            };
        }

        pub fn getNumber(self: Node, key: []const u8) ?f64 {
            const v = self.fields.get(key) orelse return null;
            return switch (v) {
                .number => |n| n,
                else => null,
            };
        }

        pub fn getBool(self: Node, key: []const u8) bool {
            const v = self.fields.get(key) orelse return false;
            return switch (v) {
                .boolean => |b| b,
                else => false,
            };
        }

        pub fn getList(self: Node, key: []const u8) []Value {
            const v = self.fields.get(key) orelse return &.{};
            return switch (v) {
                .list => |l| l,
                else => &.{},
            };
        }
    };

    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asNumber(self: Value) ?f64 {
        return switch (self) {
            .number => |n| n,
            else => null,
        };
    }

    pub fn asBool(self: Value) bool {
        return switch (self) {
            .boolean => |b| b,
            else => false,
        };
    }

    pub fn asNode(self: Value) ?Node {
        return switch (self) {
            .node => |n| n,
            else => null,
        };
    }

    pub fn asList(self: Value) []Value {
        return switch (self) {
            .list => |l| l,
            else => &.{},
        };
    }
};
