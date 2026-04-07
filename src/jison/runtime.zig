//! Jison grammar runtime: stateful lexer + LL recursive-descent parser.
//! Produces a Value AST from mermaid diagram text.
const std = @import("std");
const mvzr = @import("mvzr");
const ast = @import("ast.zig");
const Value = @import("../diagram/value.zig").Value;

const Regex = mvzr.SizedRegex(256, 32);

pub const RuntimeError = error{
    ParseFailed,
    OutOfMemory,
    LexError,
};

// ── Regex preprocessing (same as Langium runtime) ─────────────────────────────

fn jsToMvzr(allocator: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < pattern.len) {
        if (i + 2 < pattern.len and pattern[i] == '(' and pattern[i + 1] == '?') {
            switch (pattern[i + 2]) {
                ':' => { try buf.append(allocator, '('); i += 3; },
                '=', '!' => {
                    i = skipParenGroup(pattern, i);
                    // Skip any quantifier following the removed lookahead
                    if (i < pattern.len) switch (pattern[i]) {
                        '*', '+', '?' => i += 1,
                        '{' => { while (i < pattern.len and pattern[i] != '}') i += 1; if (i < pattern.len) i += 1; },
                        else => {},
                    };
                },
                else => { try buf.append(allocator, pattern[i]); i += 1; },
            }
        } else if (i + 1 < pattern.len and pattern[i] == '\\' and pattern[i + 1] == 'u') {
            i += 6; // skip \uXXXX
        } else {
            try buf.append(allocator, pattern[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn skipParenGroup(pattern: []const u8, start: usize) usize {
    var i = start + 1;
    var depth: usize = 1;
    while (i < pattern.len and depth > 0) {
        if (pattern[i] == '\\') { i += 2; continue; }
        if (pattern[i] == '(') depth += 1;
        if (pattern[i] == ')') depth -= 1;
        i += 1;
    }
    return i;
}

// ── Compiled lex rule ─────────────────────────────────────────────────────────

const CompiledLexRule = struct {
    source: *const ast.LexRule,
    regex: ?Regex,
};

// ── Token ─────────────────────────────────────────────────────────────────────

pub const Token = struct {
    kind: []const u8,
    text: []const u8,
    start: usize,
    end: usize,
};

// ── Runtime ───────────────────────────────────────────────────────────────────

pub const Runtime = struct {
    arena: std.mem.Allocator,
    grammar: *const ast.JisonGrammar,
    compiled: []CompiledLexRule,

    pub fn init(arena: std.mem.Allocator, grammar: *const ast.JisonGrammar) !Runtime {
        var compiled = try arena.alloc(CompiledLexRule, grammar.lex_rules.len);
        for (grammar.lex_rules, 0..) |*rule, i| {
            compiled[i] = try compileLexRule(arena, rule);
        }
        return Runtime{ .arena = arena, .grammar = grammar, .compiled = compiled };
    }

    /// Lex the entire input into a token list, applying state transitions.
    pub fn lex(self: *Runtime, input: []const u8) RuntimeError![]Token {
        var tokens: std.ArrayList(Token) = .empty;
        var pos: usize = 0;
        var state_stack: std.ArrayList([]const u8) = .empty;
        try state_stack.append(self.arena, "INITIAL");

        while (pos <= input.len) {
            // Skip whitespace (spaces/tabs — but NOT newlines, which may be tokens)
            while (pos < input.len and (input[pos] == ' ' or input[pos] == '\t')) {
                // Check if any lex rule explicitly handles whitespace — if not, skip
                const ws_handled = blk: {
                    for (self.compiled) |*cr| {
                        if (!ruleMatchesState(cr.source, currentState(state_stack.items))) continue;
                        if (cr.regex) |*re| {
                            const sub = input[pos..];
                            if (re.match(sub)) |m| {
                                if (m.start == 0 and m.slice.len > 0 and (m.slice[0] == ' ' or m.slice[0] == '\t')) {
                                    break :blk true;
                                }
                            }
                        }
                    }
                    break :blk false;
                };
                if (!ws_handled) pos += 1 else break;
            }

            if (pos >= input.len) {
                try tokens.append(self.arena, Token{ .kind = "EOF", .text = "", .start = pos, .end = pos });
                break;
            }

            const current = currentState(state_stack.items);
            var matched = false;

            for (self.compiled) |*cr| {
                if (!ruleMatchesState(cr.source, current)) continue;
                const cr_regex = cr.regex orelse continue;
                const sub = input[pos..];
                const m = cr_regex.match(sub) orelse continue;
                if (m.start != 0) continue;
                if (m.slice.len == 0) continue;

                const text = m.slice;
                const rule = cr.source;

                // Apply state transitions
                for (rule.transitions) |tr| {
                    switch (tr.kind) {
                        .begin => {
                            if (tr.state) |s| {
                                state_stack.clearRetainingCapacity();
                                try state_stack.append(self.arena, s);
                            }
                        },
                        .push => {
                            if (tr.state) |s| try state_stack.append(self.arena, s);
                        },
                        .pop => {
                            if (state_stack.items.len > 1) _ = state_stack.pop();
                        },
                    }
                }

                // Emit token if rule has one
                if (rule.token) |tok| {
                    try tokens.append(self.arena, Token{
                        .kind = tok,
                        .text = text,
                        .start = pos,
                        .end = pos + text.len,
                    });
                }

                pos += text.len;
                matched = true;
                break;
            }

            if (!matched) {
                // Unrecognised character — skip it
                pos += 1;
            }
        }

        return tokens.toOwnedSlice(self.arena);
    }

    /// Parse `tokens` using the grammar's BNF rules starting from `start_rule`.
    pub fn parse(self: *Runtime, tokens: []const Token) RuntimeError!Value {
        var ctx = ParseCtx{
            .runtime = self,
            .tokens = tokens,
            .pos = 0,
        };
        const start = self.grammar.findBnfRule(self.grammar.start_rule) orelse return error.ParseFailed;
        const result = ctx.parseRule(start) catch return error.ParseFailed;
        return result orelse error.ParseFailed;
    }

    /// Convenience: lex + parse.
    pub fn run(self: *Runtime, input: []const u8) RuntimeError!Value {
        const tokens = try self.lex(input);
        return self.parse(tokens);
    }
};

/// Expand Jison's "literal" quoting: "text" → escaped regex for text.
/// In Jison lex rules, a "quoted" portion is a literal match, not a regex.
fn expandJisonLiterals(allocator: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_bracket: bool = false;
    while (i < pattern.len) {
        const c = pattern[i];
        // Track character classes to avoid treating " inside [...] as a quote
        if (c == '\\' and i + 1 < pattern.len) {
            try buf.append(allocator, c);
            try buf.append(allocator, pattern[i + 1]);
            i += 2;
            continue;
        }
        if (c == '[' and !in_bracket) { in_bracket = true; try buf.append(allocator, c); i += 1; continue; }
        if (c == ']' and in_bracket) { in_bracket = false; try buf.append(allocator, c); i += 1; continue; }
        if (c == '"' and !in_bracket) {
            // Quoted literal: expand content with regex escaping
            i += 1;
            while (i < pattern.len and pattern[i] != '"') {
                const lc = pattern[i];
                const special = "^$.|?*+()[]{}\\";
                if (std.mem.indexOfScalar(u8, special, lc) != null) try buf.append(allocator, '\\');
                try buf.append(allocator, lc);
                i += 1;
            }
            if (i < pattern.len) i += 1; // skip closing "
        } else {
            try buf.append(allocator, c);
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn compileLexRule(arena: std.mem.Allocator, rule: *const ast.LexRule) !CompiledLexRule {
    const unquoted = try expandJisonLiterals(arena, rule.pattern);
    const anchored = try std.fmt.allocPrint(arena, "^{s}", .{unquoted});
    const pat = try jsToMvzr(arena, anchored);
    const regex = Regex.compile(pat);
    return CompiledLexRule{ .source = rule, .regex = regex };
}

fn currentState(stack: []const []const u8) []const u8 {
    return if (stack.len > 0) stack[stack.len - 1] else "INITIAL";
}

fn ruleMatchesState(rule: *const ast.LexRule, state: []const u8) bool {
    if (rule.state) |rs| {
        // Rule has explicit state requirement
        return std.mem.eql(u8, rs, state);
    }
    // No state means INITIAL only (common Jison convention)
    return std.mem.eql(u8, state, "INITIAL");
}

// ── LL recursive descent over BNF rules ──────────────────────────────────────

const ParseCtx = struct {
    runtime: *Runtime,
    tokens: []const Token,
    pos: usize,

    fn peek(self: *ParseCtx) Token {
        if (self.pos >= self.tokens.len) return Token{ .kind = "EOF", .text = "", .start = 0, .end = 0 };
        return self.tokens[self.pos];
    }

    fn consume(self: *ParseCtx) Token {
        const t = self.peek();
        if (self.pos < self.tokens.len) self.pos += 1;
        return t;
    }

    fn matchToken(self: *ParseCtx, kind: []const u8) ?Token {
        const t = self.peek();
        if (std.mem.eql(u8, t.kind, kind)) {
            _ = self.consume();
            return t;
        }
        return null;
    }

    fn parseRule(self: *ParseCtx, rule: *const ast.BnfRule) std.mem.Allocator.Error!?Value {
        var node = Value.Node{
            .type_name = rule.name,
            .fields = .{},
        };
        for (rule.alternatives) |alt| {
            const saved = self.pos;
            if (try self.parseAlternative(alt, &node)) {
                return Value{ .node = node };
            }
            self.pos = saved;
        }
        return null;
    }

    fn parseAlternative(self: *ParseCtx, alt: ast.Alternative, node: *Value.Node) std.mem.Allocator.Error!bool {
        if (alt.symbols.len == 0) return true; // empty production

        for (alt.symbols) |sym| {
            const saved = self.pos;
            if (!try self.parseSym(sym, node)) {
                self.pos = saved;
                return false;
            }
        }
        return true;
    }

    fn parseSym(self: *ParseCtx, sym: []const u8, node: *Value.Node) std.mem.Allocator.Error!bool {
        // Quoted string = literal token match
        if (sym.len >= 2 and (sym[0] == '\'' or sym[0] == '"')) {
            const inner = sym[1 .. sym.len - 1];
            const t = self.peek();
            if (std.mem.eql(u8, t.text, inner) or std.mem.eql(u8, t.kind, inner)) {
                _ = self.consume();
                return true;
            }
            return false;
        }
        // Terminal token: uppercase or known token name
        if (isTerminalName(sym)) {
            if (self.matchToken(sym)) |tok| {
                _ = tok;
                return true;
            }
            return false;
        }
        // Non-terminal rule reference
        if (self.runtime.grammar.findBnfRule(sym)) |sub_rule| {
            if (try self.parseRule(sub_rule)) |child| {
                // Merge child node fields
                if (child.asNode()) |cn| {
                    var it = cn.fields.iterator();
                    while (it.next()) |entry| {
                        try node.fields.put(self.runtime.arena, entry.key_ptr.*, entry.value_ptr.*);
                    }
                }
                return true;
            }
            return false;
        }
        // Unknown symbol — try as token name
        if (self.matchToken(sym) != null) return true;
        return false;
    }
};

fn isTerminalName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!((c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_')) return false;
    }
    return true;
}
