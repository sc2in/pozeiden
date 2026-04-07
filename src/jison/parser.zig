//! Parse a .jison grammar file into a JisonGrammar AST.
//! We parse structure only — JavaScript action bodies are extracted for token
//! and state-transition information, but not executed.
const std = @import("std");
const ast = @import("ast.zig");

pub const ParseError = error{ UnexpectedEnd, OutOfMemory };

pub fn parse(arena: std.mem.Allocator, source: []const u8) ParseError!ast.JisonGrammar {
    var p = JisonParser.init(arena, source);
    return p.parse();
}

const JisonParser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize,

    fn init(arena: std.mem.Allocator, src: []const u8) JisonParser {
        return .{ .arena = arena, .src = src, .pos = 0 };
    }

    fn parse(self: *JisonParser) ParseError!ast.JisonGrammar {
        var states = std.ArrayList([]const u8).init(self.arena);
        var lex_rules = std.ArrayList(ast.LexRule).init(self.arena);
        var bnf_rules = std.ArrayList(ast.BnfRule).init(self.arena);
        var start_rule: []const u8 = "start";

        // 1. Find %lex...%% section
        const lex_start = findStr(self.src, "%lex") orelse return ast.JisonGrammar{
            .states = &.{},
            .lex_rules = &.{},
            .bnf_rules = &.{},
            .start_rule = start_rule,
        };

        const lex_rules_start = findStr(self.src[lex_start..], "%%") orelse
            return ast.JisonGrammar{ .states = &.{}, .lex_rules = &.{}, .bnf_rules = &.{}, .start_rule = start_rule };
        const lex_rules_abs = lex_start + lex_rules_start + 2;

        const lex_end = findStr(self.src[lex_rules_abs..], "/lex") orelse self.src.len;
        const lex_end_abs = lex_rules_abs + lex_end;

        // Parse state declarations from the lex header region
        const lex_header = self.src[lex_start..lex_rules_abs];
        try self.parseStates(lex_header, &states);

        // Parse lex rules
        const lex_body = self.src[lex_rules_abs..lex_end_abs];
        try self.parseLexRules(lex_body, &lex_rules);

        // 2. Parse %start directive (between /lex and first %%)
        const after_lex = self.src[lex_end_abs..];
        if (findStr(after_lex, "%start")) |si| {
            const rest = after_lex[si + 6 ..];
            start_rule = trimmedWord(rest);
        }

        // 3. Find the BNF section: last %% in file
        const grammar_sep = findLastStr(self.src, "%%") orelse return ast.JisonGrammar{
            .states = try states.toOwnedSlice(),
            .lex_rules = try lex_rules.toOwnedSlice(),
            .bnf_rules = &.{},
            .start_rule = start_rule,
        };
        const bnf_body = self.src[grammar_sep + 2 ..];
        // Strip trailing %%
        const bnf_end = findLastStr(bnf_body, "%%") orelse bnf_body.len;
        try self.parseBnfRules(bnf_body[0..bnf_end], &bnf_rules);

        return ast.JisonGrammar{
            .states = try states.toOwnedSlice(),
            .lex_rules = try lex_rules.toOwnedSlice(),
            .bnf_rules = try bnf_rules.toOwnedSlice(),
            .start_rule = start_rule,
        };
    }

    fn parseStates(self: *JisonParser, header: []const u8, states: *std.ArrayList([]const u8)) !void {
        var i: usize = 0;
        while (i < header.len) {
            // Look for "%x stateName1 stateName2 ..."
            const xi = findStr(header[i..], "%x") orelse break;
            i += xi + 2;
            // Skip to end of line, collecting state names
            while (i < header.len and header[i] != '\n') : (i += 1) {
                if (header[i] == ' ' or header[i] == '\t') continue;
                const start = i;
                while (i < header.len and header[i] != ' ' and header[i] != '\t' and header[i] != '\n') i += 1;
                if (i > start) try states.append(header[start..i]);
            }
        }
    }

    fn parseLexRules(self: *JisonParser, body: []const u8, rules: *std.ArrayList(ast.LexRule)) !void {
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimRight(u8, raw_line, "\r");
            if (line.len == 0) continue;
            // Skip comment lines
            if (std.mem.startsWith(u8, line, "//") or std.mem.startsWith(u8, line, "/*")) continue;

            // Parse: optional <STATE> prefix, then PATTERN, then { action } or bare action
            var rule_state: ?[]const u8 = null;
            var rest = line;

            // <STATE> prefix
            if (rest.len > 0 and rest[0] == '<') {
                const end_angle = std.mem.indexOfScalar(u8, rest, '>') orelse continue;
                const state_str = rest[1..end_angle];
                // <*> means "any state"
                if (!std.mem.eql(u8, state_str, "*")) {
                    rule_state = state_str;
                }
                rest = rest[end_angle + 1 ..];
            }

            // Skip leading whitespace
            rest = std.mem.trimLeft(u8, rest, " \t");
            if (rest.len == 0) continue;
            // Skip lines that are pure comment or directives
            if (std.mem.startsWith(u8, rest, "//") or std.mem.startsWith(u8, rest, "%")) continue;

            // Extract pattern (everything up to first whitespace that's NOT inside [...] or (...))
            const pattern, const after_pattern = extractPattern(rest);
            if (pattern.len == 0) continue;

            // Extract action from the rest of the line
            const action = std.mem.trim(u8, after_pattern, " \t");

            // Extract token name from action: return 'TOKEN' or return "TOKEN"
            const token = extractReturnToken(action);

            // Extract state transitions
            var transitions = std.ArrayList(ast.Transition).init(self.arena);
            try extractTransitions(action, &transitions);

            try rules.append(ast.LexRule{
                .state = rule_state,
                .pattern = pattern,
                .token = token,
                .transitions = try transitions.toOwnedSlice(),
            });
        }
    }

    fn parseBnfRules(self: *JisonParser, body: []const u8, rules: *std.ArrayList(ast.BnfRule)) !void {
        var i: usize = 0;
        while (i < body.len) {
            // Skip whitespace and comments
            while (i < body.len and isWs(body[i])) i += 1;
            if (i >= body.len) break;

            // Rule name: identifier followed by newline/whitespace then :
            const name_start = i;
            while (i < body.len and !isWs(body[i]) and body[i] != ':') i += 1;
            if (i >= body.len) break;
            const rule_name = body[name_start..i];
            if (rule_name.len == 0) { i += 1; continue; }

            // Skip to ':'
            while (i < body.len and body[i] != ':') i += 1;
            if (i >= body.len) break;
            i += 1; // consume ':'

            // Collect alternatives until ';' or next top-level rule
            var alts = std.ArrayList(ast.Alternative).init(self.arena);
            var current_alt = std.ArrayList([]const u8).init(self.arena);

            while (i < body.len) {
                while (i < body.len and isWs(body[i]) and body[i] != '\n') i += 1;

                if (i >= body.len) break;

                // End of rule
                if (body[i] == ';') { i += 1; break; }

                // Newline: might be start of new rule or continuation
                if (body[i] == '\n') { i += 1; continue; }

                // Alternative separator
                if (body[i] == '|') {
                    if (current_alt.items.len > 0 or true) {
                        try alts.append(ast.Alternative{
                            .symbols = try current_alt.toOwnedSlice(),
                        });
                        current_alt = std.ArrayList([]const u8).init(self.arena);
                    }
                    i += 1;
                    continue;
                }

                // JS action block: { ... } — skip it
                if (body[i] == '{') {
                    i = skipBraceBlock(body, i);
                    continue;
                }

                // Comment
                if (i + 1 < body.len and body[i] == '/' and body[i + 1] == '/') {
                    while (i < body.len and body[i] != '\n') i += 1;
                    continue;
                }
                if (i + 1 < body.len and body[i] == '/' and body[i + 1] == '*') {
                    const close = findStr(body[i..], "*/") orelse body.len - i;
                    i += close + 2;
                    continue;
                }

                // Token/rule symbol: identifier, quoted string, or special
                const sym_start = i;
                if (body[i] == '\'' or body[i] == '"') {
                    const q = body[i];
                    i += 1;
                    while (i < body.len and body[i] != q) i += 1;
                    if (i < body.len) i += 1;
                } else {
                    while (i < body.len and !isWs(body[i]) and body[i] != '|' and body[i] != ';' and body[i] != '{' and body[i] != '}') i += 1;
                }
                const sym = std.mem.trim(u8, body[sym_start..i], " \t\r\n");
                if (sym.len > 0 and !std.mem.eql(u8, sym, "/*") and !std.mem.eql(u8, sym, "//")) {
                    try current_alt.append(sym);
                }
            }

            if (current_alt.items.len > 0) {
                try alts.append(ast.Alternative{ .symbols = try current_alt.toOwnedSlice() });
            }

            if (alts.items.len > 0) {
                try rules.append(ast.BnfRule{
                    .name = rule_name,
                    .alternatives = try alts.toOwnedSlice(),
                });
            }
        }
    }
};

// ── Helpers ───────────────────────────────────────────────────────────────────

fn findStr(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}

fn findLastStr(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.lastIndexOf(u8, haystack, needle);
}

fn trimmedWord(s: []const u8) []const u8 {
    const t = std.mem.trimLeft(u8, s, " \t");
    var end: usize = 0;
    while (end < t.len and !isWs(t[end])) end += 1;
    return t[0..end];
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Extract a lex pattern from the start of `line`, stopping at first unbalanced
/// whitespace. Returns (pattern, rest).
fn extractPattern(line: []const u8) struct { []const u8, []const u8 } {
    var i: usize = 0;
    var depth_paren: usize = 0;
    var depth_bracket: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '\\' and i + 1 < line.len) { i += 2; continue; }
        if (c == '[') depth_bracket += 1;
        if (c == ']' and depth_bracket > 0) depth_bracket -= 1;
        if (c == '(' and depth_bracket == 0) depth_paren += 1;
        if (c == ')' and depth_bracket == 0 and depth_paren > 0) depth_paren -= 1;
        if ((c == ' ' or c == '\t') and depth_paren == 0 and depth_bracket == 0) {
            return .{ line[0..i], line[i..] };
        }
        i += 1;
    }
    return .{ line[0..i], "" };
}

/// Extract `return 'TOKEN'` or `return "TOKEN"` from action text.
fn extractReturnToken(action: []const u8) ?[]const u8 {
    const ret = std.mem.indexOf(u8, action, "return") orelse return null;
    var i = ret + 6;
    // Skip whitespace
    while (i < action.len and (action[i] == ' ' or action[i] == '\t')) i += 1;
    if (i >= action.len) return null;
    const q = action[i];
    if (q != '\'' and q != '"') return null;
    i += 1;
    const start = i;
    while (i < action.len and action[i] != q) i += 1;
    if (i >= action.len) return null;
    return action[start..i];
}

/// Extract state transitions: this.begin/pushState/popState.
fn extractTransitions(action: []const u8, list: *std.ArrayList(ast.Transition)) !void {
    var i: usize = 0;
    while (i < action.len) {
        if (std.mem.indexOf(u8, action[i..], "this.begin(")) |off| {
            const p = i + off + 11;
            if (p < action.len and (action[p] == '\'' or action[p] == '"')) {
                const q = action[p];
                const start = p + 1;
                var end = start;
                while (end < action.len and action[end] != q) end += 1;
                try list.append(ast.Transition{ .kind = .begin, .state = action[start..end] });
                i = p;
            } else { i += off + 1; }
        } else if (std.mem.indexOf(u8, action[i..], "this.pushState(")) |off| {
            const p = i + off + 15;
            if (p < action.len and (action[p] == '\'' or action[p] == '"')) {
                const q = action[p];
                const start = p + 1;
                var end = start;
                while (end < action.len and action[end] != q) end += 1;
                try list.append(ast.Transition{ .kind = .push, .state = action[start..end] });
                i = p;
            } else { i += off + 1; }
        } else if (std.mem.indexOf(u8, action[i..], "this.popState(")) |off| {
            try list.append(ast.Transition{ .kind = .pop, .state = null });
            i += off + 14;
        } else {
            break;
        }
    }
}

fn skipBraceBlock(src: []const u8, start: usize) usize {
    var i = start + 1;
    var depth: usize = 1;
    while (i < src.len and depth > 0) {
        if (src[i] == '\\') { i += 2; continue; }
        if (src[i] == '\'' or src[i] == '"') {
            const q = src[i];
            i += 1;
            while (i < src.len and src[i] != q) { if (src[i] == '\\') i += 1; i += 1; }
        }
        if (src[i] == '{') depth += 1;
        if (src[i] == '}') depth -= 1;
        i += 1;
    }
    return i;
}

test "parse flow.jison" {
    const src = @embedFile("../../grammars/flow.jison");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const g = try parse(arena.allocator(), src);
    try std.testing.expect(g.lex_rules.len > 0);
    try std.testing.expect(g.bnf_rules.len > 0);
}
