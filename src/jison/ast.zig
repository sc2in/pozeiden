//! Jison grammar AST: structural representation of a .jison file.
//! We parse enough to build a stateful lexer and LL parser.
const std = @import("std");

/// A single lexer rule: optional state, regex pattern, extracted token name,
/// and extracted state transitions from the action.
pub const LexRule = struct {
    /// null means "matches in all states" (same as INITIAL)
    state: ?[]const u8,
    /// Raw regex pattern string (JS regex, needs conversion)
    pattern: []const u8,
    /// Token name extracted from `return 'TOKEN'` or `return "TOKEN"` in action.
    /// null means the rule performs a state change but emits no token.
    token: ?[]const u8,
    /// State transitions: .begin("X") calls, .pushState("X") calls, .popState() calls.
    transitions: []Transition,
};

pub const TransitionKind = enum { begin, push, pop };

pub const Transition = struct {
    kind: TransitionKind,
    state: ?[]const u8, // null for pop
};

/// A BNF grammar rule alternative (one production).
pub const Alternative = struct {
    /// Sequence of token/rule references in this production (actions stripped).
    symbols: [][]const u8,
};

/// A BNF grammar rule (non-terminal).
pub const BnfRule = struct {
    name: []const u8,
    alternatives: []Alternative,
};

pub const JisonGrammar = struct {
    /// Declared extra lexer states (beyond INITIAL).
    states: [][]const u8,
    /// Lexer rules in definition order (first match wins).
    lex_rules: []LexRule,
    /// Grammar rules.
    bnf_rules: []BnfRule,
    /// Start rule name.
    start_rule: []const u8,

    pub fn findBnfRule(self: JisonGrammar, name: []const u8) ?*const BnfRule {
        for (self.bnf_rules) |*r| {
            if (std.mem.eql(u8, r.name, name)) return r;
        }
        return null;
    }
};
