//! Langium grammar runtime: tokenise mermaid text with a parsed Grammar,
//! then recursively interpret parser rules to produce a Value AST.
const std = @import("std");
const mvzr = @import("mvzr");
const ast = @import("ast.zig");
const Value = @import("../diagram/value.zig").Value;

// Use a larger regex to handle complex terminal patterns.
const Regex = mvzr.SizedRegex(256, 32);

pub const RuntimeError = error{
    ParseFailed,
    OutOfMemory,
    RegexCompileFailed,
};

// ── Regex preprocessing ───────────────────────────────────────────────────────

/// Convert a JS-style regex (from Langium grammar) to a format mvzr can compile.
/// Strips lookaheads, converts non-capturing groups, handles \u escapes.
pub fn jsToMvzr(allocator: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    var i: usize = 0;
    while (i < pattern.len) {
        if (i + 2 < pattern.len and pattern[i] == '(' and pattern[i + 1] == '?') {
            switch (pattern[i + 2]) {
                ':' => {
                    // Non-capturing group (?:...) → (...)
                    try buf.append('(');
                    i += 3;
                },
                '=', '!' => {
                    // Lookahead — skip the entire (?...) group
                    i = skipParenGroup(pattern, i);
                },
                else => {
                    try buf.append(pattern[i]);
                    i += 1;
                },
            }
        } else if (i + 1 < pattern.len and pattern[i] == '\\' and pattern[i + 1] == 'u') {
            // Unicode escape \uXXXX — skip for now (rare in mermaid grammars)
            i += 6;
        } else if (pattern[i] == '[' and i + 1 < pattern.len and pattern[i + 1] == 'S' and
            i + 2 < pattern.len and pattern[i + 2] == 's' and
            i + 3 < pattern.len and pattern[i + 3] == ']')
        {
            // [\S\s] → .* (any char including newline workaround)
            try buf.appendSlice("(.|\\n)");
            i += 4;
        } else {
            try buf.append(pattern[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice();
}

fn skipParenGroup(pattern: []const u8, start: usize) usize {
    var i = start + 1; // skip '('
    var depth: usize = 1;
    while (i < pattern.len and depth > 0) {
        if (pattern[i] == '\\') { i += 2; continue; }
        if (pattern[i] == '(') depth += 1;
        if (pattern[i] == ')') depth -= 1;
        i += 1;
    }
    return i;
}

// ── Compiled terminal ─────────────────────────────────────────────────────────

const CompiledTerminal = struct {
    name: []const u8,
    hidden: bool,
    /// Regex compiled with ^ anchor for position-locked matching.
    regex: ?Regex,
    /// For composition terminals (A | B), the list of referenced terminal names in order.
    composed: []const []const u8,
};

// ── Runtime ───────────────────────────────────────────────────────────────────

pub const Runtime = struct {
    arena: std.mem.Allocator,
    merged: *const ast.MergedGrammar,
    /// Compiled terminals in priority order (primary first, imports after).
    compiled: []CompiledTerminal,

    pub fn init(arena: std.mem.Allocator, merged: *const ast.MergedGrammar) !Runtime {
        const all_terminals = try merged.allTerminals(arena);
        var compiled = try arena.alloc(CompiledTerminal, all_terminals.len);
        for (all_terminals, 0..) |term, i| {
            compiled[i] = try compileTerminal(arena, term);
        }
        return Runtime{ .arena = arena, .merged = merged, .compiled = compiled };
    }

    /// Parse `input` using the entry rule and return a Value.
    pub fn run(self: *Runtime, input: []const u8) RuntimeError!Value {
        const entry = self.merged.entryRule() orelse return error.ParseFailed;
        var ctx = ParseCtx{
            .runtime = self,
            .input = input,
            .pos = 0,
        };
        const result = ctx.parseRule(entry) catch return error.ParseFailed;
        return result orelse error.ParseFailed;
    }
};

fn compileTerminal(arena: std.mem.Allocator, term: ast.Terminal) !CompiledTerminal {
    switch (term.body) {
        .regex => |pat| {
            // Anchor the pattern to current position
            const anchored = try std.fmt.allocPrint(arena, "^{s}", .{pat});
            const mvzr_pat = try jsToMvzr(arena, anchored);
            const regex = Regex.compile(mvzr_pat);
            return CompiledTerminal{
                .name = term.name,
                .hidden = term.hidden,
                .regex = regex,
                .composed = &.{},
            };
        },
        .alternatives => |refs| {
            // Build list of referenced names
            var names = std.ArrayList([]const u8).init(arena);
            for (refs) |ref| {
                switch (ref) {
                    .name => |n| try names.append(n),
                    .literal => |lit| {
                        // Compile literal as exact match regex
                        const escaped = try escapeLiteralForRegex(arena, lit);
                        const anchored = try std.fmt.allocPrint(arena, "^{s}", .{escaped});
                        try names.append(anchored); // marker: anchored literal
                        _ = escaped;
                    },
                }
            }
            return CompiledTerminal{
                .name = term.name,
                .hidden = term.hidden,
                .regex = null,
                .composed = try names.toOwnedSlice(),
            };
        },
    }
}

fn escapeLiteralForRegex(arena: std.mem.Allocator, lit: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(arena);
    const special = "^$.|?*+()[]{}\\";
    for (lit) |c| {
        if (std.mem.indexOfScalar(u8, special, c) != null) {
            try buf.append('\\');
        }
        try buf.append(c);
    }
    return buf.toOwnedSlice();
}

// ── Token ─────────────────────────────────────────────────────────────────────

const Token = struct {
    kind: []const u8, // terminal name
    text: []const u8, // matched text from input
    start: usize,
    end: usize,
};

// ── Parse context ─────────────────────────────────────────────────────────────

const ParseCtx = struct {
    runtime: *Runtime,
    input: []const u8,
    pos: usize,

    /// Try to match one token at current position. Skips hidden terminals.
    /// Returns null if nothing matches.
    fn nextToken(self: *ParseCtx) ?Token {
        var found: ?Token = null;
        var best_len: usize = 0;

        // Try all compiled terminals; pick the longest non-hidden match.
        // Hidden terminals are consumed but not returned.
        for (self.runtime.compiled) |ct| {
            if (self.matchTerminal(ct, self.pos)) |text| {
                if (ct.hidden) {
                    // Skip hidden token and recurse
                    self.pos += text.len;
                    return self.nextToken();
                }
                if (text.len > best_len) {
                    best_len = text.len;
                    found = Token{
                        .kind = ct.name,
                        .text = text,
                        .start = self.pos,
                        .end = self.pos + text.len,
                    };
                }
            }
        }
        return found;
    }

    /// Check if the terminal matches at `pos`. Returns matched slice or null.
    fn matchTerminal(self: *ParseCtx, ct: CompiledTerminal, pos: usize) ?[]const u8 {
        if (pos >= self.input.len) {
            // Check for EOF terminal
            if (std.mem.eql(u8, ct.name, "EOF")) return "";
            return null;
        }
        const sub = self.input[pos..];
        if (ct.regex) |*re| {
            const m = re.match(sub) orelse return null;
            if (m.start != 0) return null; // not anchored at pos
            return m.slice;
        }
        // Composed terminal: try each ref in order
        for (ct.composed) |ref_name| {
            // If ref starts with ^ it's an inline literal pattern
            if (ref_name.len > 0 and ref_name[0] == '^') {
                if (Regex.compile(ref_name)) |*re| {
                    const m = re.match(sub) orelse continue;
                    if (m.start != 0) continue;
                    return m.slice;
                }
                continue;
            }
            // Look up the referenced terminal
            for (self.runtime.compiled) |other| {
                if (std.mem.eql(u8, other.name, ref_name)) {
                    if (self.matchTerminal(other, pos)) |text| return text;
                    break;
                }
            }
        }
        return null;
    }

    // ── Rule parsing ───────────────────────────────────────────────────

    fn parseRule(self: *ParseCtx, rule: *const ast.Rule) !?Value {
        var node = Value.Node{
            .type_name = rule.name,
            .fields = .{},
        };
        const saved_pos = self.pos;
        if (try self.parseExpr(&rule.body, &node)) {
            return Value{ .node = node };
        }
        self.pos = saved_pos;
        return null;
    }

    /// Attempt to match `expr` at current position.
    /// Returns true on success (node fields populated), false on failure (pos restored).
    fn parseExpr(self: *ParseCtx, expr: *const ast.Expr, node: *Value.Node) std.mem.Allocator.Error!bool {
        switch (expr.*) {
            .sequence => |items| {
                const saved = self.pos;
                for (items) |*item| {
                    if (!try self.parseExpr(item, node)) {
                        self.pos = saved;
                        return false;
                    }
                }
                return true;
            },
            .alternative => |alts| {
                for (alts) |*alt| {
                    const saved = self.pos;
                    if (try self.parseExpr(alt, node)) return true;
                    self.pos = saved;
                }
                return false;
            },
            .group => |g| {
                return self.parseGrouped(g.inner, g.cardinality, node);
            },
            .keyword => |kw| {
                return self.matchKeyword(kw);
            },
            .ref => |name| {
                return self.matchRef(name, null, node);
            },
            .assign => |a| {
                return self.parseAssign(a, node);
            },
        }
    }

    fn parseGrouped(self: *ParseCtx, inner: *const ast.Expr, card: ast.Cardinality, node: *Value.Node) !bool {
        switch (card) {
            .once => return self.parseExpr(inner, node),
            .optional => {
                _ = try self.parseExpr(inner, node);
                return true;
            },
            .zero_or_more => {
                while (true) {
                    const saved = self.pos;
                    if (!try self.parseExpr(inner, node)) {
                        self.pos = saved;
                        break;
                    }
                }
                return true;
            },
            .one_or_more => {
                const saved = self.pos;
                if (!try self.parseExpr(inner, node)) { self.pos = saved; return false; }
                while (true) {
                    const s2 = self.pos;
                    if (!try self.parseExpr(inner, node)) { self.pos = s2; break; }
                }
                return true;
            },
        }
    }

    fn matchKeyword(self: *ParseCtx, kw: []const u8) bool {
        self.skipHidden();
        if (self.pos + kw.len > self.input.len) return false;
        if (!std.mem.eql(u8, self.input[self.pos .. self.pos + kw.len], kw)) return false;
        // Make sure it's not a prefix of a longer identifier
        if (kw.len < self.input.len - self.pos) {
            const next = self.input[self.pos + kw.len];
            if (isAlnum(next) or next == '_' or next == '-') return false;
        }
        self.pos += kw.len;
        return true;
    }

    fn matchRef(self: *ParseCtx, name: []const u8, _result_field: ?*Value, node: *Value.Node) !bool {
        _ = _result_field;
        self.skipHidden();
        // Try parser rule first
        if (self.runtime.merged.findRule(name)) |rule| {
            const saved = self.pos;
            if (try self.parseRule(rule)) |child_val| {
                // Merge fragment fields into node, or store as sub-node
                switch (child_val) {
                    .node => |cn| {
                        var it = cn.fields.iterator();
                        while (it.next()) |entry| {
                            try node.fields.put(self.runtime.arena, entry.key_ptr.*, entry.value_ptr.*);
                        }
                    },
                    else => {},
                }
                return true;
            }
            self.pos = saved;
            return false;
        }
        // Try terminal
        if (self.matchTerminal(name)) |text| {
            _ = text;
            return true;
        }
        return false;
    }

    fn matchTerminal(self: *ParseCtx, name: []const u8) ?[]const u8 {
        self.skipHidden();
        // Special: EOL / EOF
        if (std.mem.eql(u8, name, "EOL") or std.mem.eql(u8, name, "EOF")) {
            // EOL: consume newlines or accept at end
            if (self.pos >= self.input.len) return "";
            var p = self.pos;
            // skip optional whitespace
            while (p < self.input.len and (self.input[p] == ' ' or self.input[p] == '\t')) p += 1;
            if (p < self.input.len and (self.input[p] == '\n' or self.input[p] == '\r')) {
                if (self.input[p] == '\r' and p + 1 < self.input.len and self.input[p + 1] == '\n') p += 2
                else p += 1;
                const text = self.input[self.pos..p];
                self.pos = p;
                return text;
            }
            if (p >= self.input.len) {
                const text = self.input[self.pos..p];
                self.pos = p;
                return text;
            }
            return null;
        }
        for (self.runtime.compiled) |ct| {
            if (std.mem.eql(u8, ct.name, name)) {
                if (self.matchTerminalAt(ct, self.pos)) |text| {
                    self.pos += text.len;
                    return text;
                }
                return null;
            }
        }
        return null;
    }

    fn matchTerminalAt(self: *ParseCtx, ct: CompiledTerminal, pos: usize) ?[]const u8 {
        return self.matchTerminalCtx(ct, pos);
    }

    fn matchTerminalCtx(self: *ParseCtx, ct: CompiledTerminal, pos: usize) ?[]const u8 {
        if (pos >= self.input.len) return null;
        const sub = self.input[pos..];
        if (ct.regex) |*re| {
            const m = re.match(sub) orelse return null;
            if (m.start != 0) return null;
            return m.slice;
        }
        for (ct.composed) |ref_name| {
            if (ref_name.len > 0 and ref_name[0] == '^') {
                if (Regex.compile(ref_name)) |*re| {
                    const m = re.match(sub) orelse continue;
                    if (m.start != 0) continue;
                    return m.slice;
                }
                continue;
            }
            for (self.runtime.compiled) |other| {
                if (std.mem.eql(u8, other.name, ref_name)) {
                    if (self.matchTerminalCtx(other, pos)) |text| return text;
                    break;
                }
            }
        }
        return null;
    }

    fn parseAssign(self: *ParseCtx, a: ast.Expr.Assign, node: *Value.Node) !bool {
        self.skipHidden();
        switch (a.cardinality) {
            .once => {
                const val = try self.evalExprValue(a.inner) orelse return false;
                switch (a.op) {
                    .single => try node.fields.put(self.runtime.arena, a.field, val),
                    .list => {
                        const existing = node.fields.get(a.field);
                        if (existing) |ex| {
                            switch (ex) {
                                .list => |lst| {
                                    var new_list = try self.runtime.arena.alloc(Value, lst.len + 1);
                                    @memcpy(new_list[0..lst.len], lst);
                                    new_list[lst.len] = val;
                                    try node.fields.put(self.runtime.arena, a.field, Value{ .list = new_list });
                                },
                                else => {
                                    var new_list = try self.runtime.arena.alloc(Value, 2);
                                    new_list[0] = ex;
                                    new_list[1] = val;
                                    try node.fields.put(self.runtime.arena, a.field, Value{ .list = new_list });
                                },
                            }
                        } else {
                            var new_list = try self.runtime.arena.alloc(Value, 1);
                            new_list[0] = val;
                            try node.fields.put(self.runtime.arena, a.field, Value{ .list = new_list });
                        }
                    },
                    .boolean => try node.fields.put(self.runtime.arena, a.field, Value{ .boolean = true }),
                }
                return true;
            },
            .optional => {
                if (try self.evalExprValue(a.inner)) |val| {
                    switch (a.op) {
                        .single => try node.fields.put(self.runtime.arena, a.field, val),
                        .boolean => try node.fields.put(self.runtime.arena, a.field, Value{ .boolean = true }),
                        .list => {
                            var new_list = try self.runtime.arena.alloc(Value, 1);
                            new_list[0] = val;
                            try node.fields.put(self.runtime.arena, a.field, Value{ .list = new_list });
                        },
                    }
                }
                return true;
            },
            .zero_or_more, .one_or_more => {
                var list = std.ArrayList(Value).init(self.runtime.arena);
                if (node.fields.get(a.field)) |ex| {
                    switch (ex) {
                        .list => |l| try list.appendSlice(l),
                        else => try list.append(ex),
                    }
                }
                const min: usize = if (a.cardinality == .one_or_more) 1 else 0;
                var count: usize = 0;
                while (true) {
                    const saved = self.pos;
                    if (try self.evalExprValue(a.inner)) |val| {
                        try list.append(val);
                        count += 1;
                    } else {
                        self.pos = saved;
                        break;
                    }
                }
                if (count < min) return false;
                try node.fields.put(self.runtime.arena, a.field, Value{ .list = try list.toOwnedSlice() });
                return true;
            },
        }
    }

    /// Evaluate an expression and return the matched value (string for terminals, node for rules).
    fn evalExprValue(self: *ParseCtx, expr: *const ast.Expr) !?Value {
        self.skipHidden();
        switch (expr.*) {
            .keyword => |kw| {
                if (self.matchKeyword(kw)) return Value{ .string = kw };
                return null;
            },
            .ref => |name| {
                self.skipHidden();
                // Try rule
                if (self.runtime.merged.findRule(name)) |rule| {
                    return try self.parseRule(rule);
                }
                // Try terminal
                if (self.matchTerminal(name)) |text| {
                    return Value{ .string = text };
                }
                return null;
            },
            .string_lit => |s| {
                if (self.matchKeyword(s)) return Value{ .string = s };
                return null;
            },
            .alternative => |alts| {
                for (alts) |*alt| {
                    const saved = self.pos;
                    if (try self.evalExprValue(alt)) |v| return v;
                    self.pos = saved;
                }
                return null;
            },
            .sequence => |items| {
                var dummy_node = Value.Node{ .type_name = "", .fields = .{} };
                const saved = self.pos;
                for (items) |*item| {
                    if (!try self.parseExpr(item, &dummy_node)) {
                        self.pos = saved;
                        return null;
                    }
                }
                // Return string representation of consumed text
                return Value{ .string = self.input[saved..self.pos] };
            },
            .group => |g| {
                return self.evalGroupedValue(g.inner, g.cardinality);
            },
            .assign => |a| {
                var dummy = Value.Node{ .type_name = "", .fields = .{} };
                if (try self.parseAssign(a, &dummy)) {
                    return dummy.fields.get(a.field) orelse Value{ .boolean = true };
                }
                return null;
            },
        }
    }

    fn evalGroupedValue(self: *ParseCtx, inner: *const ast.Expr, card: ast.Cardinality) !?Value {
        switch (card) {
            .once => return self.evalExprValue(inner),
            .optional => {
                const saved = self.pos;
                const v = try self.evalExprValue(inner);
                if (v == null) self.pos = saved;
                return v orelse Value{ .null = {} };
            },
            .zero_or_more, .one_or_more => {
                var list = std.ArrayList(Value).init(self.runtime.arena);
                while (true) {
                    const saved = self.pos;
                    if (try self.evalExprValue(inner)) |v| {
                        try list.append(v);
                    } else {
                        self.pos = saved;
                        break;
                    }
                }
                if (card == .one_or_more and list.items.len == 0) return null;
                return Value{ .list = try list.toOwnedSlice() };
            },
        }
    }

    fn skipHidden(self: *ParseCtx) void {
        while (self.pos < self.input.len) {
            var matched = false;
            for (self.runtime.compiled) |ct| {
                if (!ct.hidden) continue;
                if (self.matchTerminalCtx(ct, self.pos)) |text| {
                    if (text.len > 0) {
                        self.pos += text.len;
                        matched = true;
                        break;
                    }
                }
            }
            if (!matched) break;
        }
    }
};

fn isAlnum(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}
