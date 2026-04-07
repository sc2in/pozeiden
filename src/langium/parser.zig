//! Parse .langium grammar definition files into a Grammar AST.
//! Hand-rolled recursive descent; uses no external parser library.
const std = @import("std");
const ast = @import("ast.zig");

pub const ParseError = error{
    UnexpectedChar,
    UnexpectedEnd,
    InvalidRegex,
    OutOfMemory,
};

/// Parse a .langium source file and return an owned Grammar.
/// All strings in the Grammar are slices into the arena.
pub fn parse(arena: std.mem.Allocator, source: []const u8) ParseError!ast.Grammar {
    var p = Parser.init(arena, source);
    return p.parseGrammar();
}

// ── Tokenizer ─────────────────────────────────────────────────────────────────

const TokKind = enum {
    // Keywords
    kw_grammar,
    kw_import,
    kw_entry,
    kw_fragment,
    kw_hidden,
    kw_terminal,
    kw_returns,
    // Punctuation
    colon,
    semicolon,
    pipe,
    lparen,
    rparen,
    star,
    plus,
    question,
    eq,
    plus_eq, // +=
    question_eq, // ?=
    // Values
    ident,
    string_lit, // "..." or '...'
    regex_lit, // /.../
    // End
    eof,
};

const Token = struct {
    kind: TokKind,
    text: []const u8,
    pos: usize,
};

const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize,
    peek_buf: ?Token,

    fn init(arena: std.mem.Allocator, src: []const u8) Parser {
        return .{ .arena = arena, .src = src, .pos = 0, .peek_buf = null };
    }

    // ── Low-level char helpers ──────────────────────────────────────────

    fn skipWsAndComments(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                // Line comment
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn nextToken(self: *Parser) ParseError!Token {
        self.skipWsAndComments();
        if (self.pos >= self.src.len) return Token{ .kind = .eof, .text = "", .pos = self.pos };

        const start = self.pos;
        const c = self.src[self.pos];

        // Regex literal
        if (c == '/') {
            self.pos += 1;
            while (self.pos < self.src.len) {
                const rc = self.src[self.pos];
                self.pos += 1;
                if (rc == '\\' and self.pos < self.src.len) {
                    self.pos += 1; // skip escaped char
                } else if (rc == '/') {
                    break;
                }
            }
            return Token{ .kind = .regex_lit, .text = self.src[start..self.pos], .pos = start };
        }

        // String literal
        if (c == '"' or c == '\'') {
            const q = c;
            self.pos += 1;
            while (self.pos < self.src.len) {
                const sc = self.src[self.pos];
                self.pos += 1;
                if (sc == '\\' and self.pos < self.src.len) {
                    self.pos += 1;
                } else if (sc == q) {
                    break;
                }
            }
            return Token{ .kind = .string_lit, .text = self.src[start..self.pos], .pos = start };
        }

        // Punctuation
        switch (c) {
            ':' => { self.pos += 1; return Token{ .kind = .colon, .text = self.src[start..self.pos], .pos = start }; },
            ';' => { self.pos += 1; return Token{ .kind = .semicolon, .text = self.src[start..self.pos], .pos = start }; },
            '|' => { self.pos += 1; return Token{ .kind = .pipe, .text = self.src[start..self.pos], .pos = start }; },
            '(' => { self.pos += 1; return Token{ .kind = .lparen, .text = self.src[start..self.pos], .pos = start }; },
            ')' => { self.pos += 1; return Token{ .kind = .rparen, .text = self.src[start..self.pos], .pos = start }; },
            '*' => { self.pos += 1; return Token{ .kind = .star, .text = self.src[start..self.pos], .pos = start }; },
            '+' => {
                self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    return Token{ .kind = .plus_eq, .text = self.src[start..self.pos], .pos = start };
                }
                return Token{ .kind = .plus, .text = self.src[start..self.pos], .pos = start };
            },
            '?' => {
                self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    return Token{ .kind = .question_eq, .text = self.src[start..self.pos], .pos = start };
                }
                return Token{ .kind = .question, .text = self.src[start..self.pos], .pos = start };
            },
            '=' => {
                self.pos += 1;
                return Token{ .kind = .eq, .text = self.src[start..self.pos], .pos = start };
            },
            else => {},
        }

        // Identifier or keyword
        if (isIdentStart(c)) {
            while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) self.pos += 1;
            const text = self.src[start..self.pos];
            const kind: TokKind = if (std.mem.eql(u8, text, "grammar")) .kw_grammar
                else if (std.mem.eql(u8, text, "import")) .kw_import
                else if (std.mem.eql(u8, text, "entry")) .kw_entry
                else if (std.mem.eql(u8, text, "fragment")) .kw_fragment
                else if (std.mem.eql(u8, text, "hidden")) .kw_hidden
                else if (std.mem.eql(u8, text, "terminal")) .kw_terminal
                else if (std.mem.eql(u8, text, "returns")) .kw_returns
                else .ident;
            return Token{ .kind = kind, .text = text, .pos = start };
        }

        // Unknown character — skip it
        self.pos += 1;
        return self.nextToken();
    }

    fn peek(self: *Parser) ParseError!Token {
        if (self.peek_buf) |t| return t;
        const t = try self.nextToken();
        self.peek_buf = t;
        return t;
    }

    fn consume(self: *Parser) ParseError!Token {
        if (self.peek_buf) |t| {
            self.peek_buf = null;
            return t;
        }
        return self.nextToken();
    }

    fn expect(self: *Parser, kind: TokKind) ParseError!Token {
        const t = try self.consume();
        if (t.kind != kind) return error.UnexpectedChar;
        return t;
    }

    fn tryConsume(self: *Parser, kind: TokKind) ParseError!?Token {
        const t = try self.peek();
        if (t.kind == kind) {
            _ = try self.consume();
            return t;
        }
        return null;
    }

    // ── Grammar-level parsing ──────────────────────────────────────────

    fn parseGrammar(self: *Parser) ParseError!ast.Grammar {
        var imports = std.ArrayList([]const u8).init(self.arena);
        var rules = std.ArrayList(ast.Rule).init(self.arena);
        var terminals = std.ArrayList(ast.Terminal).init(self.arena);

        // Optionally consume "grammar Name"
        var name: []const u8 = "unnamed";
        const first = try self.peek();
        if (first.kind == .kw_grammar) {
            _ = try self.consume();
            const n = try self.expect(.ident);
            name = n.text;
        }

        while (true) {
            const t = try self.peek();
            switch (t.kind) {
                .eof => break,
                .kw_import => {
                    _ = try self.consume();
                    const path_tok = try self.expect(.string_lit);
                    // Strip quotes
                    const raw = path_tok.text[1 .. path_tok.text.len - 1];
                    try imports.append(raw);
                    _ = try self.tryConsume(.semicolon);
                },
                .kw_hidden => {
                    _ = try self.consume();
                    const kw = try self.peek();
                    if (kw.kind == .kw_terminal) {
                        const term = try self.parseTerminal(true);
                        try terminals.append(term);
                    }
                    // else ignore
                },
                .kw_terminal => {
                    const term = try self.parseTerminal(false);
                    try terminals.append(term);
                },
                .kw_entry, .kw_fragment, .ident => {
                    const rule = try self.parseRule();
                    try rules.append(rule);
                },
                else => {
                    _ = try self.consume(); // skip unknown tokens
                },
            }
        }

        return ast.Grammar{
            .name = name,
            .imports = try imports.toOwnedSlice(),
            .rules = try rules.toOwnedSlice(),
            .terminals = try terminals.toOwnedSlice(),
        };
    }

    fn parseTerminal(self: *Parser, hidden: bool) ParseError!ast.Terminal {
        _ = try self.expect(.kw_terminal);
        const name_tok = try self.expect(.ident);
        var returns_type: ?[]const u8 = null;

        // Optional "returns type"
        const maybe_returns = try self.peek();
        if (maybe_returns.kind == .kw_returns) {
            _ = try self.consume();
            const rt = try self.consume();
            returns_type = rt.text;
        }

        _ = try self.expect(.colon);

        // Terminal body: either /regex/ or Name ('|' Name)*
        const body = try self.parseTerminalBody();
        _ = try self.tryConsume(.semicolon);

        return ast.Terminal{
            .name = name_tok.text,
            .hidden = hidden,
            .returns_type = returns_type,
            .body = body,
        };
    }

    fn parseTerminalBody(self: *Parser) ParseError!ast.TerminalBody {
        const t = try self.peek();
        if (t.kind == .regex_lit) {
            _ = try self.consume();
            // Strip the surrounding / ... /
            const inner = t.text[1 .. t.text.len - 1];
            return ast.TerminalBody{ .regex = inner };
        }
        // Alternatives: Name | 'lit' | ...
        var alts = std.ArrayList(ast.TerminalRef).init(self.arena);
        while (true) {
            const item = try self.peek();
            if (item.kind == .ident) {
                _ = try self.consume();
                try alts.append(ast.TerminalRef{ .name = item.text });
            } else if (item.kind == .string_lit) {
                _ = try self.consume();
                const inner = stripQuotes(item.text);
                try alts.append(ast.TerminalRef{ .literal = inner });
            } else {
                break;
            }
            if (try self.tryConsume(.pipe) == null) break;
        }
        return ast.TerminalBody{ .alternatives = try alts.toOwnedSlice() };
    }

    fn parseRule(self: *Parser) ParseError!ast.Rule {
        var is_entry = false;
        var is_fragment = false;

        const first = try self.peek();
        if (first.kind == .kw_entry) {
            _ = try self.consume();
            is_entry = true;
        } else if (first.kind == .kw_fragment) {
            _ = try self.consume();
            is_fragment = true;
        }

        const name_tok = try self.expect(.ident);
        var returns_type: ?[]const u8 = null;

        const maybe_returns = try self.peek();
        if (maybe_returns.kind == .kw_returns) {
            _ = try self.consume();
            const rt = try self.consume();
            returns_type = rt.text;
        }

        _ = try self.expect(.colon);
        const body = try self.parseExpr();
        _ = try self.tryConsume(.semicolon);

        return ast.Rule{
            .name = name_tok.text,
            .is_entry = is_entry,
            .is_fragment = is_fragment,
            .returns_type = returns_type,
            .body = body,
        };
    }

    // ── Expression parsing (precedence: alternative > sequence > atom+card) ──

    fn parseExpr(self: *Parser) ParseError!ast.Expr {
        return self.parseAlternative();
    }

    fn parseAlternative(self: *Parser) ParseError!ast.Expr {
        var items = std.ArrayList(ast.Expr).init(self.arena);
        try items.append(try self.parseSequence());

        while (true) {
            const t = try self.peek();
            if (t.kind != .pipe) break;
            _ = try self.consume();
            try items.append(try self.parseSequence());
        }

        if (items.items.len == 1) return items.items[0];
        return ast.Expr{ .alternative = try items.toOwnedSlice() };
    }

    fn parseSequence(self: *Parser) ParseError!ast.Expr {
        var items = std.ArrayList(ast.Expr).init(self.arena);

        while (true) {
            const t = try self.peek();
            // Sequence ends at: | ) ; eof
            if (t.kind == .pipe or t.kind == .rparen or t.kind == .semicolon or t.kind == .eof) break;
            const atom = try self.parseAtomWithCard() orelse break;
            try items.append(atom);
        }

        if (items.items.len == 0) return ast.Expr{ .sequence = &.{} };
        if (items.items.len == 1) return items.items[0];
        return ast.Expr{ .sequence = try items.toOwnedSlice() };
    }

    fn parseAtomWithCard(self: *Parser) ParseError!?ast.Expr {
        const t = try self.peek();

        // Check for assignment patterns first: ident = / ident += / ident ?=
        if (t.kind == .ident) {
            // Look ahead for assignment operators
            // We'll try consuming the ident, then check
            const saved_pos = self.pos;
            const saved_peek = self.peek_buf;
            _ = try self.consume();
            const next = try self.peek();
            if (next.kind == .eq or next.kind == .plus_eq or next.kind == .question_eq) {
                const op_tok = try self.consume();
                const op: ast.AssignOp = switch (op_tok.kind) {
                    .eq => .single,
                    .plus_eq => .list,
                    .question_eq => .boolean,
                    else => unreachable,
                };
                // For ?= the RHS is a string literal (boolean flag)
                const inner = try self.parseAtomNoCard();
                const cardinality = try self.parseCardinality();
                const inner_ptr = try self.arena.create(ast.Expr);
                inner_ptr.* = inner orelse ast.Expr{ .ref = t.text };
                return ast.Expr{ .assign = .{
                    .field = t.text,
                    .op = op,
                    .inner = inner_ptr,
                    .cardinality = cardinality,
                } };
            } else {
                // Not an assignment — restore state
                self.pos = saved_pos;
                self.peek_buf = saved_peek;
            }
        }

        const atom = try self.parseAtomNoCard() orelse return null;
        const cardinality = try self.parseCardinality();

        if (cardinality == .once) return atom;

        const inner_ptr = try self.arena.create(ast.Expr);
        inner_ptr.* = atom;
        return ast.Expr{ .group = .{ .inner = inner_ptr, .cardinality = cardinality } };
    }

    fn parseAtomNoCard(self: *Parser) ParseError!?ast.Expr {
        const t = try self.peek();
        switch (t.kind) {
            .lparen => {
                _ = try self.consume();
                const inner = try self.parseExpr();
                _ = try self.expect(.rparen);
                return inner;
            },
            .string_lit => {
                _ = try self.consume();
                const kw = stripQuotes(t.text);
                return ast.Expr{ .keyword = kw };
            },
            .ident => {
                _ = try self.consume();
                return ast.Expr{ .ref = t.text };
            },
            else => return null,
        }
    }

    fn parseCardinality(self: *Parser) ParseError!ast.Cardinality {
        const t = try self.peek();
        switch (t.kind) {
            .question => { _ = try self.consume(); return .optional; },
            .star => { _ = try self.consume(); return .zero_or_more; },
            .plus => { _ = try self.consume(); return .one_or_more; },
            else => return .once,
        }
    }
};

// ── Helpers ───────────────────────────────────────────────────────────────────

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'')) {
        return s[1 .. s.len - 1];
    }
    return s;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "parse pie grammar" {
    const src = @embedFile("../../grammars/pie.langium");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const g = try parse(arena.allocator(), src);
    try std.testing.expectEqualStrings("PieGrammar", g.name);
    try std.testing.expect(g.rules.len > 0);
    try std.testing.expect(g.terminals.len > 0);
}

test "parse common grammar" {
    const src = @embedFile("../../grammars/common.langium");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const g = try parse(arena.allocator(), src);
    try std.testing.expect(g.terminals.len > 0);
}
