//! Langium grammar internal representation.
//! All strings are slices into arena-allocated memory.
const std = @import("std");

pub const Cardinality = enum {
    once,
    optional, // ?
    zero_or_more, // *
    one_or_more, // +
};

pub const AssignOp = enum {
    single, // field=X
    list, // field+=X
    boolean, // field?="keyword"
};

pub const TerminalBody = union(enum) {
    /// A regex literal like /[0-9]+/
    regex: []const u8,
    /// Composition of other terminals: A | B | C (each element is a name or literal)
    alternatives: []TerminalRef,
};

pub const TerminalRef = union(enum) {
    /// Reference to another terminal by name
    name: []const u8,
    /// Literal string that must match
    literal: []const u8,
};

pub const Terminal = struct {
    name: []const u8,
    hidden: bool,
    returns_type: ?[]const u8,
    body: TerminalBody,
};

/// A fragment or parser rule expression node.
pub const Expr = union(enum) {
    sequence: []Expr,
    alternative: []Expr,
    group: Group,
    keyword: []const u8, // "word" or 'word'
    ref: []const u8, // reference to a rule or terminal
    assign: Assign,

    pub const Group = struct {
        inner: *Expr,
        cardinality: Cardinality,
    };

    pub const Assign = struct {
        field: []const u8,
        op: AssignOp,
        inner: *Expr,
        cardinality: Cardinality,
    };
};

pub const Rule = struct {
    name: []const u8,
    is_entry: bool,
    is_fragment: bool,
    returns_type: ?[]const u8,
    body: Expr,
};

pub const Grammar = struct {
    name: []const u8,
    imports: [][]const u8,
    rules: []Rule,
    terminals: []Terminal,

    pub fn findRule(self: Grammar, name: []const u8) ?*const Rule {
        for (self.rules) |*rule| {
            if (std.mem.eql(u8, rule.name, name)) return rule;
        }
        return null;
    }

    pub fn findTerminal(self: Grammar, name: []const u8) ?*const Terminal {
        for (self.terminals) |*term| {
            if (std.mem.eql(u8, term.name, name)) return term;
        }
        return null;
    }

    pub fn entryRule(self: Grammar) ?*const Rule {
        for (self.rules) |*rule| {
            if (rule.is_entry) return rule;
        }
        return null;
    }
};

/// A merged grammar that combines an importing grammar with its imported grammars.
/// Import order: own terminals first (higher priority), then imported terminals.
pub const MergedGrammar = struct {
    primary: *const Grammar,
    /// Imported grammars in order (last import has lowest priority).
    imports: []*const Grammar,
    allocator: std.mem.Allocator,

    /// All terminals in priority order: primary own terminals, then imports.
    pub fn allTerminals(self: MergedGrammar, arena: std.mem.Allocator) ![]Terminal {
        var list: std.ArrayList(Terminal) = .empty;
        for (self.primary.terminals) |t| try list.append(arena, t);
        for (self.imports) |imp| {
            for (imp.terminals) |t| try list.append(arena, t);
        }
        return list.toOwnedSlice(arena);
    }

    pub fn findRule(self: MergedGrammar, name: []const u8) ?*const Rule {
        if (self.primary.findRule(name)) |r| return r;
        for (self.imports) |imp| {
            if (imp.findRule(name)) |r| return r;
        }
        return null;
    }

    pub fn entryRule(self: MergedGrammar) ?*const Rule {
        return self.primary.entryRule();
    }
};
