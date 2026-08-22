//! Tokenizer, AST, and recursive-descent parser for the subset of
//! ECMAScript this project needs, combined into one module so the
//! parser stands as a single complete unit.
//!
//! - Statements: recursive descent, one function per statement kind,
//!   dispatched by the first token.
//! - Expressions: precedence climbing (a.k.a. a Pratt parser).
//!
//! Error handling: on a genuine syntax error, JsParseError.SyntaxError is
//! returned. This parser does not attempt error recovery - a script
//! this can't parse is a script the caller should fall back to leaving
//! untouched.

const std = @import("std");


fn jsIsIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

fn jsIsIdentPart(c: u8) bool {
    return jsIsIdentStart(c) or std.ascii.isDigit(c);
}

pub const jsIsIdentStartChar = jsIsIdentStart;
pub const jsIsIdentPartChar = jsIsIdentPart;

fn jsIsWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\x0c' or c == '\x0b';
}

pub const JsTokenType = enum {
    eof,
    invalid,
    identifier,
    number,
    string,
    template,
    regex,
    comment,
    newline,

    assign,
    plus,
    minus,
    asterisk,
    slash,
    percent,
    dot,
    comma,
    semicolon,
    colon,
    question,
    bang,
    amp,
    pipe,
    caret,
    tilde,
    lt,
    gt,
    other_punct,

    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
};

pub const JsLoc = struct {
    start: usize,
    end: usize,
};

pub const JsToken = struct {
    tag: JsTokenType,
    loc: JsLoc,
    // true if at least one newline appeared in the whitespace/comments
    // immediately preceding this token (relevant for ASI).
    newline_before: bool,
};

/// Reports whether a '/' immediately following the previous significant
/// token should be treated as a regex literal start rather than division.
pub fn jsRegexAllowedAfter(prevTag: ?JsTokenType, prevText: []const u8) bool {
    const prev = prevTag orelse return true;
    return switch (prev) {
        .identifier => jsIsKeywordExpressionEnd(prevText),
        .number, .string, .template, .regex => false,
        .r_paren, .r_bracket => false,
        // Note: '}' is ambiguous (block end vs object literal end) without
        // a real parser; treating it as "allow regex" is the more common
        // case (end of a block statement) and matches most minifiers'
        // heuristic default.
        else => true,
    };
}

// Identifiers that, despite tokenizing as `identifier`, act like operators
// or keywords which precede a value (so a following '/' is a regex start).
fn jsIsKeywordExpressionEnd(text: []const u8) bool {
    const valueKeywords = [_][]const u8{
        "return", "typeof",  "instanceof", "in",     "of",     "new",
        "delete", "void",    "throw",      "case",   "do",     "else",
        "yield",  "await",   "extends",    "default",
    };
    for (valueKeywords) |kw| {
        if (std.mem.eql(u8, text, kw)) return true;
    }
    return false;
}

// Names the mangler must never generate as a short identifier: all
// ECMA-262 reserved words, over-inclusive across strict-mode/module/
// async contexts to avoid emitting invalid JS. async, as, from, get,
// of, set are excluded from this list since they're never reserved.
pub const jsReservedWordsAlways = [_][]const u8{
    "break",  "case",     "catch",    "class",   "const",    "continue",
    "debugger", "default", "delete",  "do",      "else",     "export",
    "extends", "false",   "finally",  "for",     "function", "if",
    "import", "in",       "instanceof", "new",   "null",     "return",
    "super",  "switch",   "this",     "throw",   "true",     "try",
    "typeof", "var",      "void",     "while",   "with",
};

// Reserved only in strict-mode code, treated as always-reserved here
// since this project can't always prove code isn't strict mode.
pub const jsReservedWordsStrictMode = [_][]const u8{
    "let", "static", "yield", "arguments", "eval",
};

// Reserved only in module code or inside an async function body (same
// caveat: treated as always-reserved here).
pub const jsReservedWordsModuleOrAsync = [_][]const u8{
    "await",
};

// Future reserved words: unused by the language today, but reserved
// for a potential future keyword, so still illegal as an identifier.
pub const jsReservedWordsFutureAlways = [_][]const u8{
    "enum",
};

pub const jsReservedWordsFutureStrictMode = [_][]const u8{
    "implements", "interface", "package", "private", "protected", "public",
};

// Future reserved words no longer reserved by the current spec, but
// excluded anyway for backwards compatibility with older engines.
pub const jsReservedWordsLegacy = [_][]const u8{
    "abstract", "boolean", "byte",   "char",         "double",
    "final",    "float",   "goto",   "int",          "long",
    "native",   "short",   "synchronized", "throws", "transient",
    "volatile",
};

/// Reports whether `name` is any word this project's mangler must
/// never hand out as a generated identifier.
pub fn jsIsReservedWord(name: []const u8) bool {
    const groups = [_][]const []const u8{
        &jsReservedWordsAlways,
        &jsReservedWordsStrictMode,
        &jsReservedWordsModuleOrAsync,
        &jsReservedWordsFutureAlways,
        &jsReservedWordsFutureStrictMode,
        &jsReservedWordsLegacy,
    };
    for (groups) |group| {
        for (group) |w| {
            if (std.mem.eql(u8, name, w)) return true;
        }
    }
    return false;
}

pub const JsTokenizer = struct {
    buffer: []const u8,
    index: usize,
    lastSignificantTag: ?JsTokenType,
    lastSignificantText: []const u8,

    pub fn init(buffer: []const u8) JsTokenizer {
        return .{
            .buffer = buffer,
            .index = 0,
            .lastSignificantTag = null,
            .lastSignificantText = &[_]u8{},
        };
    }

    fn peek(self: *JsTokenizer) ?u8 {
        if (self.index >= self.buffer.len) return null;
        return self.buffer[self.index];
    }

    fn peekAt(self: *JsTokenizer, offset: usize) ?u8 {
        const idx = self.index + offset;
        if (idx >= self.buffer.len) return null;
        return self.buffer[idx];
    }

    fn advance(self: *JsTokenizer) ?u8 {
        const c = self.peek();
        if (c != null) self.index += 1;
        return c;
    }

    fn text(self: *JsTokenizer, loc: JsLoc) []const u8 {
        return self.buffer[loc.start..loc.end];
    }

    // Skips whitespace and comments, returns whether a newline was seen and
    // the location of the last comment skipped, if any (comments are not
    // emitted as separate significant tokens here; they're just consumed).
    fn skipTrivia(self: *JsTokenizer) bool {
        var sawNewline = false;
        while (self.peek()) |c| {
            if (c == '\n') {
                sawNewline = true;
                self.index += 1;
                continue;
            }
            if (jsIsWs(c)) {
                self.index += 1;
                continue;
            }
            if (c == '/' and self.peekAt(1) == '/') {
                self.index += 2;
                while (self.peek()) |nc| {
                    if (nc == '\n') break;
                    self.index += 1;
                }
                continue;
            }
            if (c == '/' and self.peekAt(1) == '*') {
                self.index += 2;
                while (self.peek()) |nc| {
                    if (nc == '*' and self.peekAt(1) == '/') {
                        self.index += 2;
                        break;
                    }
                    if (nc == '\n') sawNewline = true;
                    self.index += 1;
                }
                continue;
            }
            break;
        }
        return sawNewline;
    }

    pub fn next(self: *JsTokenizer) JsToken {
        const newlineBefore = self.skipTrivia();
        const start = self.index;

        const c = self.advance() orelse {
            const tok = JsToken{ .tag = .eof, .loc = .{ .start = start, .end = start }, .newline_before = newlineBefore };
            return tok;
        };

        var tok: JsToken = switch (c) {
            '(' => self.simple(.l_paren, start),
            ')' => self.simple(.r_paren, start),
            '{' => self.simple(.l_brace, start),
            '}' => self.simple(.r_brace, start),
            '[' => self.simple(.l_bracket, start),
            ']' => self.simple(.r_bracket, start),
            ';' => self.simple(.semicolon, start),
            ',' => self.simple(.comma, start),
            ':' => self.simple(.colon, start),
            '~' => self.simple(.tilde, start),
            '+', '-', '*', '%', '^', '=', '!', '&', '|', '<', '>', '?' => self.punctuator(start),
            '.' => blk: {
                if (self.peek() != null and std.ascii.isDigit(self.peek().?)) {
                    break :blk self.number(start);
                }
                if (self.peek() == @as(u8, '.') and self.peekAt(1) == @as(u8, '.')) {
                    self.index += 2;
                    break :blk self.simple(.other_punct, start);
                }
                break :blk self.simple(.dot, start);
            },
            '/' => self.slashOrComment(start),
            '"', '\'' => self.stringLiteral(start, c),
            '`' => self.templateLiteral(start),
            else => blk: {
                if (std.ascii.isDigit(c)) break :blk self.number(start);
                if (jsIsIdentStart(c)) break :blk self.identifier(start);
                break :blk JsToken{ .tag = .invalid, .loc = .{ .start = start, .end = self.index }, .newline_before = false };
            },
        };
        tok.newline_before = newlineBefore;

        if (tok.tag != .comment) {
            self.lastSignificantTag = tok.tag;
            self.lastSignificantText = self.text(tok.loc);
        }
        return tok;
    }

    fn simple(self: *JsTokenizer, tag: JsTokenType, start: usize) JsToken {
        return .{ .tag = tag, .loc = .{ .start = start, .end = self.index }, .newline_before = false };
    }

    fn punctuator(self: *JsTokenizer, start: usize) JsToken {
        // Longest-match-first table of multi-char punctuators. Exact
        // operator identity doesn't matter for minification, so every
        // match maps to .other_punct except single-char forms.
        const four = [_][]const u8{">>>="};
        const three = [_][]const u8{ "===", "!==", "**=", "<<=", ">>=", "&&=", "||=", "??=", ">>>" };
        const two = [_][]const u8{ "=>", "==", "!=", "<=", ">=", "&&", "||", "??", "?.", "++", "--", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<", ">>", "**" };

        if (self.matchesFrom(start, four[0])) {
            self.index = start + 4;
            return self.simple(.other_punct, start);
        }
        for (three) |op| {
            if (self.matchesFrom(start, op)) {
                self.index = start + op.len;
                return self.simple(.other_punct, start);
            }
        }
        for (two) |op| {
            if (self.matchesFrom(start, op)) {
                self.index = start + 2;
                return self.simple(.other_punct, start);
            }
        }
        self.index = start + 1;
        return self.singleCharTag(start);
    }

    fn matchesFrom(self: *JsTokenizer, from: usize, s: []const u8) bool {
        if (from + s.len > self.buffer.len) return false;
        return std.mem.eql(u8, self.buffer[from .. from + s.len], s);
    }

    fn singleCharTag(self: *JsTokenizer, start: usize) JsToken {
        const c = self.buffer[start];
        const tag: JsTokenType = switch (c) {
            '+' => .plus,
            '-' => .minus,
            '*' => .asterisk,
            '%' => .percent,
            '^' => .caret,
            '=' => .assign,
            '!' => .bang,
            '&' => .amp,
            '|' => .pipe,
            '<' => .lt,
            '>' => .gt,
            '?' => .question,
            else => .other_punct,
        };
        return self.simple(tag, start);
    }

    fn slashOrComment(self: *JsTokenizer, start: usize) JsToken {
        if (jsRegexAllowedAfter(self.lastSignificantTag, self.lastSignificantText)) {
            if (self.tryRegex(start)) |tok| return tok;
        }
        if (self.peek() == @as(u8, '=')) self.index += 1;
        return self.simple(.slash, start);
    }

    fn tryRegex(self: *JsTokenizer, start: usize) ?JsToken {
        const savedIndex = self.index;
        var inClass = false;
        while (self.peek()) |c| {
            if (c == '\n') {
                self.index = savedIndex;
                return null;
            }
            if (c == '\\') {
                self.index += 1;
                if (self.peek() != null) self.index += 1;
                continue;
            }
            if (c == '[') inClass = true;
            if (c == ']') inClass = false;
            if (c == '/' and !inClass) {
                self.index += 1;
                while (self.peek()) |fc| {
                    if (!jsIsIdentPart(fc)) break;
                    self.index += 1;
                }
                return self.simple(.regex, start);
            }
            self.index += 1;
        }
        self.index = savedIndex;
        return null;
    }

    fn stringLiteral(self: *JsTokenizer, start: usize, quote: u8) JsToken {
        while (self.peek()) |c| {
            if (c == quote) {
                self.index += 1;
                break;
            }
            if (c == '\n') break;
            if (c == '\\') {
                self.index += 1;
                if (self.peek() != null) self.index += 1;
                continue;
            }
            self.index += 1;
        }
        return self.simple(.string, start);
    }

    fn templateLiteral(self: *JsTokenizer, start: usize) JsToken {
        var depth: i32 = 0;
        while (self.peek()) |c| {
            if (c == '\\') {
                self.index += 1;
                if (self.peek() != null) self.index += 1;
                continue;
            }
            if (c == '`' and depth == 0) {
                self.index += 1;
                break;
            }
            if (c == '$' and self.peekAt(1) == '{') {
                self.index += 2;
                depth += 1;
                continue;
            }
            if (c == '}' and depth > 0) {
                depth -= 1;
                self.index += 1;
                continue;
            }
            if (c == '{' and depth > 0) {
                depth += 1;
                self.index += 1;
                continue;
            }
            self.index += 1;
        }
        return self.simple(.template, start);
    }

    fn number(self: *JsTokenizer, start: usize) JsToken {
        // hex / octal / binary prefixes
        if (self.buffer[start] == '0' and self.peek() != null) {
            const p = self.peek().?;
            if (p == 'x' or p == 'X' or p == 'o' or p == 'O' or p == 'b' or p == 'B') {
                self.index += 1;
                while (self.peek()) |c| {
                    if (jsIsIdentPart(c) or c == '_') {
                        self.index += 1;
                    } else break;
                }
                return self.simple(.number, start);
            }
        }
        while (self.peek()) |c| {
            if (std.ascii.isDigit(c) or c == '_') {
                self.index += 1;
            } else break;
        }
        if (self.peek() == @as(u8, '.')) {
            self.index += 1;
            while (self.peek()) |c| {
                if (std.ascii.isDigit(c) or c == '_') {
                    self.index += 1;
                } else break;
            }
        }
        if (self.peek() == @as(u8, 'e') or self.peek() == @as(u8, 'E')) {
            const savedIndex = self.index;
            self.index += 1;
            if (self.peek() == @as(u8, '+') or self.peek() == @as(u8, '-')) self.index += 1;
            if (self.peek() != null and std.ascii.isDigit(self.peek().?)) {
                while (self.peek()) |c| {
                    if (std.ascii.isDigit(c)) {
                        self.index += 1;
                    } else break;
                }
            } else {
                self.index = savedIndex;
            }
        }
        if (self.peek() == @as(u8, 'n')) self.index += 1; // BigInt suffix
        return self.simple(.number, start);
    }

    fn identifier(self: *JsTokenizer, start: usize) JsToken {
        while (self.peek()) |c| {
            if (jsIsIdentPart(c)) {
                self.index += 1;
            } else break;
        }
        return self.simple(.identifier, start);
    }
};


pub const JsAstLoc = JsLoc;

pub const JsAstProgram = struct {
    body: []const *JsAstNode,
    loc: JsAstLoc,
};

pub const JsAstNode = struct {
    loc: JsAstLoc,
    data: Data,

    pub const Data = union(enum) {
        /// `{ ...body }` - also used for a function body and (with a
        /// synthetic loc) a JsAstProgram's implicit top-level block.
        block: JsAstBlock,

        var_decl: JsAstVarDecl,

        /// A bare expression used as a statement (`foo();`, `a = b;`).
        expr_stmt: *JsAstNode,

        if_stmt: JsAstIf,
        for_stmt: JsAstFor,

        /// `for (left in/of right) body` - `is_of` distinguishes
        /// `for...of` from `for...in`.
        for_in_of: JsAstForInOf,

        while_stmt: JsAstWhile,

        /// `do body while (test);`
        do_while: JsAstDoWhile,

        return_stmt: ?*JsAstNode,
        break_stmt: ?[]const u8,
        continue_stmt: ?[]const u8,
        throw_stmt: *JsAstNode,
        try_stmt: JsAstTry,
        switch_stmt: JsAstSwitch,

        /// `label: body`
        labeled_stmt: JsAstLabeled,

        /// A function declaration (statement position, hoisted). Uses
        /// the same payload as `function_expr`.
        function_decl: JsAstFunction,

        /// A class declaration (statement position).
        class_decl: JsAstClass,

        /// `;` on its own.
        empty_stmt,

        debugger_stmt,

        /// `with (object) body`.
        with_stmt: JsAstWith,

        /// A bare identifier reference (`foo`).
        identifier: []const u8,

        this_expr,
        super_expr,

        number_literal: []const u8,
        string_literal: []const u8,
        regex_literal: []const u8,
        template_literal: JsAstTemplateLiteral,

        /// `` tag`...` `` / `` a.b`...` `` - a call/member chain
        /// immediately followed by a template literal.
        tagged_template: JsAstTaggedTemplate,
        boolean_literal: bool,
        null_literal,

        /// `[elements]` - a `null` element represents an elided/hole
        /// slot (`[a, , b]`); a `spread` node represents `...expr`.
        array_literal: []const ?*JsAstNode,

        object_literal: []const JsAstObjectProperty,

        /// `...argument` in call arguments, array literals, or (via
        /// `JsAstPattern.rest`) destructuring patterns.
        spread: *JsAstNode,

        /// A function expression. Same payload as `function_decl`.
        function_expr: JsAstFunction,

        /// `(params) => body` / `param => body` - `body` is a `block`
        /// JsAstNode for the braced form, or any expression JsAstNode for the
        /// concise `=> expr` form.
        arrow_function: JsAstArrow,

        /// A class expression.
        class_expr: JsAstClass,

        /// `left OP right` for any binary operator. `op` is the exact
        /// source text rather than an enum.
        binary: JsAstBinary,

        /// `left = right` / `left += right` / etc.
        assignment: JsAstBinary,

        /// `left ?? right`, `left && right`, `left || right` - split
        /// from `binary` since these short-circuit.
        logical: JsAstBinary,

        /// Prefix operator (`typeof`, `void`, `delete`, `!`, `~`,
        /// unary `+`/`-`, prefix `++`/`--`).
        unary: JsAstUnary,

        /// Postfix `++`/`--`.
        update: JsAstUnary,

        conditional: JsAstConditional,

        /// `callee(arguments)` - `optional` is true for `callee?.(...)`.
        call: JsAstCall,

        new_expr: JsAstCall,

        /// `object.property` - `optional` is true for `object?.property`.
        member: JsAstMember,

        /// `object[property]` - `optional` is true for `object?.[property]`.
        computed_member: JsAstComputedMember,

        /// `(expression)` - kept as its own node so a later printer
        /// pass can decide whether the parens are still needed.
        paren: *JsAstNode,

        /// `a, b, c` comma operator.
        sequence: []const *JsAstNode,

        /// `yield [argument]` - `delegate` is true for `yield* argument`.
        yield_expr: JsAstYield,

        await_expr: *JsAstNode,

        /// A destructuring pattern as an assignment target, a
        /// declarator's binding target, or a parameter.
        pattern: JsAstPattern,
    };
};

pub const JsAstBlock = struct {
    body: []const *JsAstNode,
};

pub const JsAstVarDecl = struct {
    kind: JsAstVarKind,
    declarators: []const JsAstDeclarator,
};

pub const JsAstVarKind = enum { @"var", @"let", @"const" };

pub const JsAstDeclarator = struct {
    /// An `identifier` JsAstNode or a `pattern` JsAstNode.
    id: *JsAstNode,
    init: ?*JsAstNode,
};

pub const JsAstIf = struct {
    test_: *JsAstNode,
    consequent: *JsAstNode,
    alternate: ?*JsAstNode,
};

pub const JsAstFor = struct {
    /// A `var_decl` JsAstNode, an expression JsAstNode, or `null` (`for (;;)`).
    init: ?*JsAstNode,
    test_: ?*JsAstNode,
    update: ?*JsAstNode,
    body: *JsAstNode,
};

pub const JsAstForInOf = struct {
    /// A `var_decl` JsAstNode or an assignment-target expression JsAstNode.
    left: *JsAstNode,
    right: *JsAstNode,
    body: *JsAstNode,
    is_of: bool,
    /// `for await (x of y)` - only meaningful when `is_of` is true.
    is_await: bool,
};

pub const JsAstWhile = struct {
    test_: *JsAstNode,
    body: *JsAstNode,
};

pub const JsAstDoWhile = struct {
    body: *JsAstNode,
    test_: *JsAstNode,
};

pub const JsAstTry = struct {
    block: *JsAstNode,
    /// `(param)` in `catch (param)` - `null` for parameterless `catch`.
    catch_param: ?*JsAstNode,
    /// `null` when there is no `catch` clause (`try`/`finally` alone
    /// is legal). Distinct from `catch_param` being `null`.
    catch_body: ?*JsAstNode,
    finally_body: ?*JsAstNode,
};

pub const JsAstSwitch = struct {
    discriminant: *JsAstNode,
    cases: []const JsAstCase,
};

pub const JsAstCase = struct {
    /// `null` for the `default:` case.
    test_: ?*JsAstNode,
    body: []const *JsAstNode,
};

pub const JsAstLabeled = struct {
    label: []const u8,
    body: *JsAstNode,
};

pub const JsAstWith = struct {
    object: *JsAstNode,
    body: *JsAstNode,
};

pub const JsAstFunction = struct {
    /// `null` for an anonymous function expression; always present
    /// for a declaration.
    name: ?[]const u8,
    params: []const *JsAstNode,
    body: *JsAstNode, // always a `block` JsAstNode
    is_generator: bool,
    is_async: bool,
};

pub const JsAstArrow = struct {
    params: []const *JsAstNode,
    /// A `block` JsAstNode (braced form) or any expression JsAstNode (concise
    /// form) - distinguished by checking `body.data == .block`.
    body: *JsAstNode,
    is_async: bool,
};

pub const JsAstClass = struct {
    /// `null` for an anonymous class expression; always present for
    /// a declaration.
    name: ?[]const u8,
    super_class: ?*JsAstNode,
    members: []const JsAstClassMember,
};

pub const JsAstClassMember = struct {
    kind: JsAstClassMemberKind,
    /// The member's name for a plain identifier/string/number key.
    /// `null` for a computed key, where `computed_key` holds the key
    /// expression instead.
    key: ?[]const u8,
    computed_key: ?*JsAstNode,
    /// `JsAstFunction` payload for `{method, getter, setter}`; `null` for
    /// `field`, where `field_init` holds the optional initializer.
    value: ?JsAstFunction,
    field_init: ?*JsAstNode,
    is_static: bool,
    /// `#name` private member - `key`/`computed_key` hold the name
    /// without the leading `#`.
    is_private: bool,
};

pub const JsAstClassMemberKind = enum { method, getter, setter, field, static_block };

pub const JsAstTaggedTemplate = struct {
    tag: *JsAstNode,
    quasi: JsAstTemplateLiteral,
};

pub const JsAstTemplateLiteral = struct {
    /// Raw source text of each literal chunk, including delimiters,
    /// kept verbatim rather than unescaped. Always
    /// `expressions.len + 1` entries.
    quasis: []const []const u8,
    expressions: []const *JsAstNode,
};

pub const JsAstObjectProperty = struct {
    kind: JsAstObjectPropertyKind,
    /// `null` for a computed key or `kind == .spread`, where
    /// `computed_key`/`value` is used instead.
    key: ?[]const u8,
    computed_key: ?*JsAstNode,
    /// Value expression for `.normal`; a `JsAstFunction` wrapped as
    /// `function_expr` for `.method`/`.getter`/`.setter`; the spread
    /// operand for `.spread`.
    value: *JsAstNode,
    /// True for shorthand `{a}`.
    shorthand: bool,
};

pub const JsAstObjectPropertyKind = enum { normal, method, getter, setter, spread };

pub const JsAstBinary = struct {
    /// Exact source text of the operator - see `Data.binary` for why
    /// this isn't a separate enum.
    op: []const u8,
    left: *JsAstNode,
    right: *JsAstNode,
};

pub const JsAstUnary = struct {
    op: []const u8,
    argument: *JsAstNode,
};

pub const JsAstConditional = struct {
    test_: *JsAstNode,
    consequent: *JsAstNode,
    alternate: *JsAstNode,
};

pub const JsAstCall = struct {
    callee: *JsAstNode,
    arguments: []const *JsAstNode,
    /// Always `false` for `new_expr` (optional chaining cannot appear
    /// directly on a `new` callee).
    optional: bool,
};

pub const JsAstMember = struct {
    object: *JsAstNode,
    property: []const u8,
    optional: bool,
    /// `#name` private field access - `property` omits the leading `#`.
    is_private: bool,
};

pub const JsAstComputedMember = struct {
    object: *JsAstNode,
    property: *JsAstNode,
    optional: bool,
};

pub const JsAstYield = struct {
    argument: ?*JsAstNode,
    delegate: bool,
};

pub const JsAstPattern = struct {
    kind: JsAstPatternKind,
    /// Destructured properties for `.object`, or elements for
    /// `.array` (a `null` `value` is an elided/hole slot).
    properties: []const JsAstPatternProperty,
    /// `...rest` binding if this pattern ends with one, else `null`.
    rest: ?*JsAstNode,
};

pub const JsAstPatternKind = enum { object, array };

pub const JsAstPatternProperty = struct {
    /// Source-side key - `null` for an array element or a computed
    /// object-pattern key, where `computed_key` holds it instead.
    key: ?[]const u8,
    computed_key: ?*JsAstNode,
    /// The binding target: an `identifier` JsAstNode or nested `pattern`
    /// JsAstNode. `null` only for an array pattern's elided slot.
    value: ?*JsAstNode,
    /// `= expr` default value, if present.
    default: ?*JsAstNode,
    /// True for shorthand `{a}` / `{a = 1}`.
    shorthand: bool,
};

/// Owns the arena every JsAstNode in a parsed tree is allocated from.
pub const JsAst = struct {
    arena: std.heap.ArenaAllocator,
    program: JsAstProgram,

    pub fn deinit(self: *JsAst) void {
        self.arena.deinit();
    }
};

pub const JsParseError = error{
    SyntaxError,
} || std.mem.Allocator.Error;

pub fn jsParse(allocator: std.mem.Allocator, source: []const u8) JsParseError!JsAst {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var p = JsParse{
        .allocator = a,
        .tokenizer = JsTokenizer.init(source),
        .lookahead = std.ArrayList(JsToken).empty,
        .source = source,
    };

    const startLoc = JsAstLoc{ .start = 0, .end = source.len };
    var body: std.ArrayList(*JsAstNode) = .empty;
    while (!p.check(.eof)) {
        const stmt = try jsParseStatement(&p);
        try body.append(a, stmt);
    }

    return JsAst{
        .arena = arena,
        .program = .{ .body = try body.toOwnedSlice(a), .loc = startLoc },
    };
}

// Owns a small forward-only lookahead buffer on top of the tokenizer.
// The tokenizer must never be rewound (its regex-vs-divide state
// commits on each `next()` call), so lookahead pulls tokens forward
// into `lookahead` and buffers them instead of re-lexing.
const JsParse = struct {
    allocator: std.mem.Allocator,
    tokenizer: JsTokenizer,
    lookahead: std.ArrayList(JsToken),
    source: []const u8,

    fn fillTo(self: *JsParse, count: usize) !void {
        while (self.lookahead.items.len < count) {
            const t = self.tokenizer.next();
            try self.lookahead.append(self.allocator, t);
        }
    }

    fn peek(self: *JsParse) !JsToken {
        try self.fillTo(1);
        return self.lookahead.items[0];
    }

    fn peekAt(self: *JsParse, offset: usize) !JsToken {
        try self.fillTo(offset + 1);
        return self.lookahead.items[offset];
    }

    fn advance(self: *JsParse) !JsToken {
        try self.fillTo(1);
        return self.lookahead.orderedRemove(0);
    }

    fn text(self: *JsParse, t: JsToken) []const u8 {
        return self.source[t.loc.start..t.loc.end];
    }

    // `check*` helpers return a plain `bool` rather than `!bool` for
    // call-site ergonomics. `peek`/`peekAt` can only fail via
    // allocator OOM in `fillTo`; swallowing that here as `false` just
    // delays the error to the next real `advance`/`expect` call, which
    // does propagate it.
    fn check(self: *JsParse, tag: JsTokenType) bool {
        const t = self.peek() catch return false;
        return t.tag == tag;
    }

    // Whether the current token is an identifier (reserved or not)
    // whose text equals `kw` - used for contextual/reserved keywords,
    // which the tokenizer emits as plain `.identifier` tokens.
    fn checkKeyword(self: *JsParse, kw: []const u8) bool {
        const t = self.peek() catch return false;
        if (t.tag != .identifier) return false;
        return std.mem.eql(u8, self.text(t), kw);
    }

    fn checkKeywordAt(self: *JsParse, offset: usize, kw: []const u8) bool {
        const t = self.peekAt(offset) catch return false;
        if (t.tag != .identifier) return false;
        return std.mem.eql(u8, self.text(t), kw);
    }

    fn expect(self: *JsParse, tag: JsTokenType) JsParseError!JsToken {
        const t = try self.advance();
        if (t.tag != tag) return error.SyntaxError;
        return t;
    }

    fn expectKeyword(self: *JsParse, kw: []const u8) JsParseError!JsToken {
        const t = try self.advance();
        if (t.tag != .identifier or !std.mem.eql(u8, self.text(t), kw)) return error.SyntaxError;
        return t;
    }

    // Consumes a `;` if present. Otherwise applies ASI: valid when the
    // next token is `}`, EOF, or preceded by a newline; a syntax error
    // otherwise.
    fn consumeSemicolon(self: *JsParse) JsParseError!void {
        if (self.check(.semicolon)) {
            _ = try self.advance();
            return;
        }
        const t = try self.peek();
        if (t.tag == .r_brace or t.tag == .eof or t.newline_before) return;
        return error.SyntaxError;
    }

    fn newNode(self: *JsParse, loc: JsAstLoc, data: JsAstNode.Data) !*JsAstNode {
        const n = try self.allocator.create(JsAstNode);
        n.* = .{ .loc = loc, .data = data };
        return n;
    }
};

// JS operator precedence (lowest to highest binding), per the
// ECMAScript spec's grammar:
//   1. sequence (comma)
//   2. assignment (=, +=, -=, ..., &&=, ||=, ??=) - right-associative
//   3. conditional (?:) - right-associative
//   4. nullish-coalescing (??) - can't mix with && / || without
//      explicit parens at the grammar level; this parser doesn't
//      enforce that, it just parses whichever operator appears
//   5. logical OR (||)
//   6. logical AND (&&)
//   7. bitwise OR (|)
//   8. bitwise XOR (^)
//   9. bitwise AND (&)
//   10. equality (==, !=, ===, !==)
//   11. relational (<, >, <=, >=, in, instanceof)
//   12. shift (<<, >>, >>>)
//   13. additive (+, -)
//   14. multiplicative (*, /, %)
//   15. exponent (**) - right-associative
//   16. unary (prefix ++/--, +, -, !, ~, typeof, void, delete, await)
//   17. postfix (++/--)
//   18. call/member/optional-chaining (a(), a.b, a[b], a?.b, new a())
//   19. primary (literals, identifiers, parenthesized, arrays,
//       objects, functions, classes, templates)
//
// JsAstBinary/logical operators (5-15) are handled by one table-driven
// `jsParseBinaryExpr` using precedence levels, rather than one function
// per level. Everything above that (unary through primary) still
// needs its own function since each level's grammar shape differs.
const JsParseBinOpInfo = struct { text: []const u8, prec: u8, is_logical: bool };

// Precedence numbers only need to be internally consistent (higher
// binds tighter) - spaced by 10 for readability while editing this
// table, the gaps carry no meaning.
const jsParseBinaryOps = [_]JsParseBinOpInfo{
    .{ .text = "??", .prec = 30, .is_logical = true },
    .{ .text = "||", .prec = 40, .is_logical = true },
    .{ .text = "&&", .prec = 50, .is_logical = true },
    .{ .text = "|", .prec = 60, .is_logical = false },
    .{ .text = "^", .prec = 70, .is_logical = false },
    .{ .text = "&", .prec = 80, .is_logical = false },
    .{ .text = "==", .prec = 90, .is_logical = false },
    .{ .text = "!=", .prec = 90, .is_logical = false },
    .{ .text = "===", .prec = 90, .is_logical = false },
    .{ .text = "!==", .prec = 90, .is_logical = false },
    .{ .text = "<", .prec = 100, .is_logical = false },
    .{ .text = ">", .prec = 100, .is_logical = false },
    .{ .text = "<=", .prec = 100, .is_logical = false },
    .{ .text = ">=", .prec = 100, .is_logical = false },
    .{ .text = "in", .prec = 100, .is_logical = false },
    .{ .text = "instanceof", .prec = 100, .is_logical = false },
    .{ .text = "<<", .prec = 110, .is_logical = false },
    .{ .text = ">>", .prec = 110, .is_logical = false },
    .{ .text = ">>>", .prec = 110, .is_logical = false },
    .{ .text = "+", .prec = 120, .is_logical = false },
    .{ .text = "-", .prec = 120, .is_logical = false },
    .{ .text = "*", .prec = 130, .is_logical = false },
    .{ .text = "/", .prec = 130, .is_logical = false },
    .{ .text = "%", .prec = 130, .is_logical = false },
    // "**" (exponent) is handled separately in jsParseExponent, not
    // through this table, since it's right-associative while every
    // operator above is left-associative.
};

const jsParseAssignOps = [_][]const u8{
    "=",  "+=",  "-=",  "*=",  "/=",   "%=",  "**=",
    "<<=", ">>=", ">>>=", "&=", "|=", "^=", "&&=", "||=", "??=",
};

fn jsParseLookupBinaryOp(text: []const u8) ?JsParseBinOpInfo {
    for (jsParseBinaryOps) |op| {
        if (std.mem.eql(u8, op.text, text)) return op;
    }
    return null;
}

fn jsParseIsAssignOp(text: []const u8) bool {
    for (jsParseAssignOps) |op| {
        if (std.mem.eql(u8, op, text)) return true;
    }
    return false;
}

// Tags that can start an operator-shaped punctuator token whose exact
// identity (===, &&, etc.) is only recoverable from its source text,
// not its tag - the parser un-collapses these by comparing text
// instead of tag wherever operator identity matters. Single-char
// operators keep distinct tags (`.plus`, `.minus`, etc.) but are
// included here too so every operator-shaped token is checked the
// same way by callers.
fn jsParseLooksLikeOperator(tagVal: JsTokenType) bool {
    return switch (tagVal) {
        .assign, .plus, .minus, .asterisk, .slash, .percent, .amp, .pipe, .caret, .lt, .gt, .bang, .question, .other_punct => true,
        else => false,
    };
}

fn jsParseExpression(p: *JsParse) JsParseError!*JsAstNode {
    const first = try jsParseAssignExpr(p);
    if (!p.check(.comma)) return first;

    var items: std.ArrayList(*JsAstNode) = .empty;
    try items.append(p.allocator, first);
    while (p.check(.comma)) {
        _ = try p.advance();
        try items.append(p.allocator, try jsParseAssignExpr(p));
    }
    const loc = JsAstLoc{ .start = first.loc.start, .end = items.items[items.items.len - 1].loc.end };
    return p.newNode(loc, .{ .sequence = try items.toOwnedSlice(p.allocator) });
}

// Parses a single assignment-level expression (no top-level comma) -
// used everywhere a full `jsParseExpression` would be too permissive
// (call arguments, array/object elements, for-loop clauses), since
// those must not swallow a bare comma as part of one expression.
fn jsParseAssignExpr(p: *JsParse) JsParseError!*JsAstNode {
    // `yield`/`async`/arrow-function detection all need more than one
    // token of lookahead before committing to a parse path, which is
    // why this function is the dispatch point for them - assignment
    // level is the widest-scoped place all of them can appear.
    if (p.checkKeyword("yield")) return jsParseYield(p);

    if (try jsParseTryParseArrow(p)) |arrow| return arrow;

    const left = try jsParseConditional(p);

    const t = p.peek() catch return left;
    if (t.tag == .eof) return left;
    if (jsParseLooksLikeOperator(t.tag)) {
        const opText = p.text(t);
        if (jsParseIsAssignOp(opText)) {
            _ = try p.advance();
            const right = try jsParseAssignExpr(p);
            const target = try jsParseToAssignmentTarget(p, left);
            const loc = JsAstLoc{ .start = target.loc.start, .end = right.loc.end };
            return p.newNode(loc, .{ .assignment = .{ .op = opText, .left = target, .right = right } });
        }
    }
    return left;
}

fn jsParseYield(p: *JsParse) JsParseError!*JsAstNode {
    const start = try p.expectKeyword("yield");
    var delegate = false;
    if (p.check(.asterisk)) {
        _ = try p.advance();
        delegate = true;
    }
    // `yield` with no argument: either nothing follows on the same
    // logical statement (a newline before the next token means no
    // argument), or the next token can't start an expression
    // (`)`, `]`, `}`, `,`, `;`, eof).
    const nt = try p.peek();
    const hasArg = !(nt.newline_before or nt.tag == .r_paren or nt.tag == .r_bracket or
        nt.tag == .r_brace or nt.tag == .comma or nt.tag == .semicolon or nt.tag == .eof or nt.tag == .colon);
    var argument: ?*JsAstNode = null;
    var endPos = start.loc.end;
    if (hasArg) {
        const arg = try jsParseAssignExpr(p);
        argument = arg;
        endPos = arg.loc.end;
    }
    return p.newNode(.{ .start = start.loc.start, .end = endPos }, .{ .yield_expr = .{ .argument = argument, .delegate = delegate } });
}

fn jsParseConditional(p: *JsParse) JsParseError!*JsAstNode {
    const test_ = try jsParseBinaryExpr(p, 0);
    if (!p.check(.question)) return test_;
    _ = try p.advance();
    const consequent = try jsParseAssignExpr(p);
    _ = try p.expect(.colon);
    const alternate = try jsParseAssignExpr(p);
    const loc = JsAstLoc{ .start = test_.loc.start, .end = alternate.loc.end };
    return p.newNode(loc, .{ .conditional = .{ .test_ = test_, .consequent = consequent, .alternate = alternate } });
}

// Precedence-climbing core: parses a binary/logical expression chain
// where every operator binds at or above `minPrec`. All binary/
// logical levels (5-15 in the table above) share this function;
// unary/exponent is the base case it climbs down to.
fn jsParseBinaryExpr(p: *JsParse, minPrec: u8) JsParseError!*JsAstNode {
    var left = try jsParseExponent(p);
    while (true) {
        const t = p.peek() catch return left;
        if (t.tag == .eof or !jsParseLooksLikeOperator(t.tag)) break;
        const opText = p.text(t);
        // `in` and `instanceof` tokenize as plain identifiers, not
        // operator-tagged punctuators - checked separately since
        // `jsParseLooksLikeOperator` (by tag) can't see them.
        const info = jsParseLookupBinaryOp(opText) orelse blk: {
            if (t.tag == .identifier and (std.mem.eql(u8, opText, "in") or std.mem.eql(u8, opText, "instanceof"))) {
                break :blk jsParseLookupBinaryOp(opText);
            }
            break :blk null;
        } orelse break;
        if (info.prec < minPrec) break;
        _ = try p.advance();
        // Left-associative: the right operand only climbs operators
        // strictly tighter than this one (prec + 1), so a same-
        // precedence operator to the right becomes a new top-level
        // left-fold instead of nesting into this call's right operand.
        const right = try jsParseBinaryExpr(p, info.prec + 1);
        const loc = JsAstLoc{ .start = left.loc.start, .end = right.loc.end };
        left = try p.newNode(loc, if (info.is_logical)
            .{ .logical = .{ .op = opText, .left = left, .right = right } }
        else
            .{ .binary = .{ .op = opText, .left = left, .right = right } });
    }
    return left;
}

// `**` (exponentiation) is right-associative, unlike every other
// binary operator - handled as its own level above unary rather than
// folded into jsParseBinaryExpr's left-associative loop.
fn jsParseExponent(p: *JsParse) JsParseError!*JsAstNode {
    const left = try jsParseUnary(p);
    const t = p.peek() catch return left;
    // `**` tokenizes as one `.other_punct` token (the two-char
    // punctuator table matches "**" before the single-char
    // `.asterisk` fallback), so this checks text, not tag.
    if (t.tag == .other_punct and std.mem.eql(u8, p.text(t), "**")) {
        _ = try p.advance();
        // Right-associative: the right operand recurses back into
        // jsParseExponent, so `2 ** 3 ** 2` parses as `2 ** (3 ** 2)`.
        const right = try jsParseExponent(p);
        const loc = JsAstLoc{ .start = left.loc.start, .end = right.loc.end };
        return p.newNode(loc, .{ .binary = .{ .op = "**", .left = left, .right = right } });
    }
    return left;
}

const jsParseUnaryOps = [_][]const u8{ "+", "-", "!", "~", "++", "--" };
const jsParseUnaryKeywords = [_][]const u8{ "typeof", "void", "delete" };

fn jsParseUnary(p: *JsParse) JsParseError!*JsAstNode {
    const t = try p.peek();
    if (t.tag == .identifier) {
        for (jsParseUnaryKeywords) |kw| {
            if (std.mem.eql(u8, p.text(t), kw)) {
                _ = try p.advance();
                const argument = try jsParseUnary(p);
                return p.newNode(.{ .start = t.loc.start, .end = argument.loc.end }, .{ .unary = .{ .op = kw, .argument = argument } });
            }
        }
        if (std.mem.eql(u8, p.text(t), "await")) {
            _ = try p.advance();
            const argument = try jsParseUnary(p);
            return p.newNode(.{ .start = t.loc.start, .end = argument.loc.end }, .{ .await_expr = argument });
        }
    }
    if (jsParseLooksLikeOperator(t.tag)) {
        for (jsParseUnaryOps) |op| {
            if (std.mem.eql(u8, p.text(t), op)) {
                _ = try p.advance();
                const argument = try jsParseUnary(p);
                return p.newNode(.{ .start = t.loc.start, .end = argument.loc.end }, .{ .unary = .{ .op = op, .argument = argument } });
            }
        }
    }
    return jsParsePostfix(p);
}

fn jsParsePostfix(p: *JsParse) JsParseError!*JsAstNode {
    const expr = try jsParseCallMemberChain(p);
    const t = p.peek() catch return expr;
    // Postfix ++/-- is only valid with no line break between the
    // operand and the operator - a newline here means the ++/-- (if
    // any) belongs to the next statement instead.
    if (!t.newline_before and (std.mem.eql(u8, p.text(t), "++") or std.mem.eql(u8, p.text(t), "--"))) {
        _ = try p.advance();
        return p.newNode(.{ .start = expr.loc.start, .end = t.loc.end }, .{ .update = .{ .op = p.text(t), .argument = expr } });
    }
    return expr;
}

// The left-recursive postfix chain: member access, computed member
// access, calls, and optional-chaining, all at the same precedence
// level and freely mixable (`a.b[c](d).e`) - one loop that keeps
// wrapping the previous result, since each operator in the chain
// takes the whole preceding expression as its "object"/"callee".
fn jsParseCallMemberChain(p: *JsParse) JsParseError!*JsAstNode {
    var expr = if (try jsParseTryParseNewExpr(p)) |n| n else try jsParsePrimary(p);

    while (true) {
        const t = p.peek() catch break;
        if (t.tag == .dot) {
            _ = try p.advance();
            const name = try jsParsePropertyName(p);
            expr = try p.newNode(.{ .start = expr.loc.start, .end = name.loc.end }, .{ .member = .{ .object = expr, .property = name.text, .optional = false, .is_private = name.is_private } });
        } else if (t.tag == .l_bracket) {
            _ = try p.advance();
            const prop = try jsParseExpression(p);
            const close = try p.expect(.r_bracket);
            expr = try p.newNode(.{ .start = expr.loc.start, .end = close.loc.end }, .{ .computed_member = .{ .object = expr, .property = prop, .optional = false } });
        } else if (t.tag == .l_paren) {
            const args = try jsParseArguments(p);
            expr = try p.newNode(.{ .start = expr.loc.start, .end = args.end }, .{ .call = .{ .callee = expr, .arguments = args.items, .optional = false } });
        } else if (t.tag == .template) {
            _ = try p.advance();
            const quasi = try jsParseTemplateLiteral(p, t);
            expr = try p.newNode(.{ .start = expr.loc.start, .end = quasi.loc.end }, .{ .tagged_template = .{ .tag = expr, .quasi = quasi.data.template_literal } });
        } else if (t.tag == .other_punct and std.mem.eql(u8, p.text(t), "?.")) {
            _ = try p.advance();
            const nt = try p.peek();
            if (nt.tag == .l_paren) {
                const args = try jsParseArguments(p);
                expr = try p.newNode(.{ .start = expr.loc.start, .end = args.end }, .{ .call = .{ .callee = expr, .arguments = args.items, .optional = true } });
            } else if (nt.tag == .l_bracket) {
                _ = try p.advance();
                const prop = try jsParseExpression(p);
                const close = try p.expect(.r_bracket);
                expr = try p.newNode(.{ .start = expr.loc.start, .end = close.loc.end }, .{ .computed_member = .{ .object = expr, .property = prop, .optional = true } });
            } else {
                const name = try jsParsePropertyName(p);
                expr = try p.newNode(.{ .start = expr.loc.start, .end = name.loc.end }, .{ .member = .{ .object = expr, .property = name.text, .optional = true, .is_private = name.is_private } });
            }
        } else {
            break;
        }
    }
    return expr;
}

const JsParsePropName = struct { text: []const u8, loc: JsAstLoc, is_private: bool };

fn jsParsePropertyName(p: *JsParse) JsParseError!JsParsePropName {
    const t = try p.peek();
    // Private names (`#foo`): the tokenizer has no notion of `#`, so
    // it lexes as `.invalid`, with `foo` as a separate `.identifier`
    // token right after - not one combined "#foo" token. Handled here
    // by recognizing that `.invalid` "#" + `.identifier` pair and
    // stitching them back into one private name.
    if (t.tag == .invalid and std.mem.eql(u8, p.text(t), "#")) {
        _ = try p.advance();
        const name = try p.expect(.identifier);
        return .{ .text = p.text(name), .loc = .{ .start = t.loc.start, .end = name.loc.end }, .is_private = true };
    }
    const name = try p.advance();
    if (name.tag != .identifier) return error.SyntaxError;
    return .{ .text = p.text(name), .loc = name.loc, .is_private = false };
}

// The result of parsing a key at a "key position" - an object
// literal property, a destructuring pattern property, or a class
// member - where (unlike plain `a.b` member access) the grammar also
// allows a quoted string or numeric literal key (`{"a-b":1}`,
// `{0:1}`). An `.identifier`/private-name key is still returned as
// plain text via `name`, exactly as `jsParsePropertyName` would;
// a string/number key is instead returned as `literal`, an
// already-parsed `string_literal`/`number_literal` JsAstNode, for
// the caller to store as a `computed_key` - the printer already
// knows how to unquote such a literal back to a bare identifier when
// safe, or print it as a plain literal otherwise, exactly as it does
// for a genuine bracket-computed key.
const JsParseKeyName = union(enum) {
    name: JsParsePropName,
    literal: *JsAstNode,
};

fn jsParseKeyPropertyName(p: *JsParse) JsParseError!JsParseKeyName {
    const t = try p.peek();
    if (t.tag == .string) {
        _ = try p.advance();
        return .{ .literal = try p.newNode(t.loc, .{ .string_literal = p.text(t) }) };
    }
    if (t.tag == .number) {
        _ = try p.advance();
        return .{ .literal = try p.newNode(t.loc, .{ .number_literal = p.text(t) }) };
    }
    return .{ .name = try jsParsePropertyName(p) };
}

const JsParseArgs = struct { items: []const *JsAstNode, end: usize };

fn jsParseArguments(p: *JsParse) JsParseError!JsParseArgs {
    _ = try p.expect(.l_paren);
    var items: std.ArrayList(*JsAstNode) = .empty;
    while (!p.check(.r_paren)) {
        if (jsParseIsSpreadNext(p)) {
            const spreadStart = try p.advance();
            const arg = try jsParseAssignExpr(p);
            const spread = try p.newNode(.{ .start = spreadStart.loc.start, .end = arg.loc.end }, .{ .spread = arg });
            try items.append(p.allocator, spread);
        } else {
            try items.append(p.allocator, try jsParseAssignExpr(p));
        }
        if (p.check(.comma)) {
            _ = try p.advance();
        } else break;
    }
    const close = try p.expect(.r_paren);
    return .{ .items = try items.toOwnedSlice(p.allocator), .end = close.loc.end };
}

// Whether the current token is exactly the three-char "..." spread/
// rest punctuator - the tokenizer collapses two lookahead dots after
// a `.` into one `.other_punct` token when not part of a number
// literal, so a plain text comparison after the tag check is enough.
fn jsParseIsSpreadNext(p: *JsParse) bool {
    const t = p.peek() catch return false;
    return t.tag == .other_punct and std.mem.eql(u8, p.text(t), "...");
}

// `new callee(args)` - handled outside the generic postfix chain
// because `new` changes how the callee is parsed: it binds tighter
// than a call would (`new a.b.c()` calls `a.b.c`, not `(new a.b).c()`
// and not `new (a.b.c())`), and nested `new` needs its own recursive
// handling (`new new A()`). Returns `null` when the current token
// isn't `new`, so the caller falls through to `jsParsePrimary`.
fn jsParseTryParseNewExpr(p: *JsParse) JsParseError!?*JsAstNode {
    if (!p.checkKeyword("new")) return null;
    const start = try p.advance();

    // `new.target` meta-property.
    if (p.check(.dot)) {
        _ = try p.advance();
        const name = try p.expect(.identifier);
        if (!std.mem.eql(u8, p.text(name), "target")) return error.SyntaxError;
        return try p.newNode(.{ .start = start.loc.start, .end = name.loc.end }, .{ .identifier = "new.target" });
    }

    // The callee: another `new` (recursive), or a primary expression
    // followed by only `.`/`[]` member access - NOT calls, since a
    // `(...)` here belongs to `new`'s own argument list.
    var callee = if (try jsParseTryParseNewExpr(p)) |n| n else try jsParsePrimary(p);
    while (true) {
        const t = p.peek() catch break;
        if (t.tag == .dot) {
            _ = try p.advance();
            const name = try jsParsePropertyName(p);
            callee = try p.newNode(.{ .start = callee.loc.start, .end = name.loc.end }, .{ .member = .{ .object = callee, .property = name.text, .optional = false, .is_private = name.is_private } });
        } else if (t.tag == .l_bracket) {
            _ = try p.advance();
            const prop = try jsParseExpression(p);
            const close = try p.expect(.r_bracket);
            callee = try p.newNode(.{ .start = callee.loc.start, .end = close.loc.end }, .{ .computed_member = .{ .object = callee, .property = prop, .optional = false } });
        } else {
            break;
        }
    }

    if (p.check(.l_paren)) {
        const args = try jsParseArguments(p);
        return try p.newNode(.{ .start = start.loc.start, .end = args.end }, .{ .new_expr = .{ .callee = callee, .arguments = args.items, .optional = false } });
    }
    // `new Foo` with no parens at all - equivalent to `new Foo()`.
    return try p.newNode(.{ .start = start.loc.start, .end = callee.loc.end }, .{ .new_expr = .{ .callee = callee, .arguments = &[_]*JsAstNode{}, .optional = false } });
}

// JsAstArrow function detection: `(a, b) => ...`, `a => ...`, and their
// async forms all start identically to a parenthesized expression or
// a bare identifier, so this must look ahead past the matching `)`
// to see whether `=>` follows, before committing to a parse path.
// Done by scanning the lookahead buffer (via peekAt) rather than
// parsing speculatively and backtracking, since backtracking would
// require rewinding the tokenizer, which is never done.
//
// Returns `null` (having consumed nothing) when the current position
// isn't the start of an arrow function, so the caller falls through
// to its own normal parse path.
fn jsParseTryParseArrow(p: *JsParse) JsParseError!?*JsAstNode {
    var isAsync = false;
    var startOffset: usize = 0;
    if (p.checkKeyword("async")) {
        // `async` starts an arrow only when NOT followed by a newline
        // (ASI: `async\n() => {}` is `async` as a plain identifier
        // reference, then a separate statement) and only when what
        // follows actually looks like arrow params - otherwise
        // `async` is just an ordinary identifier.
        const nt = try p.peekAt(1);
        if (!nt.newline_before and (nt.tag == .identifier or nt.tag == .l_paren)) {
            isAsync = true;
            startOffset = 1;
        } else {
            return null;
        }
    }

    const first = try p.peekAt(startOffset);
    if (first.tag == .identifier and !jsIsReservedWord(p.text(first))) {
        // Bare single-parameter form: `a => ...`. Only an arrow if
        // `=>` immediately follows (no line break, per spec). A
        // newline before `=>` is a spec syntax error, but this parser
        // just doesn't treat it as an arrow, falling through to parse
        // `a` as a plain identifier expression instead.
        const second = try p.peekAt(startOffset + 1);
        if (second.tag == .other_punct and std.mem.eql(u8, p.text(second), "=>") and !second.newline_before) {
            if (isAsync) _ = try p.advance(); // consume 'async'
            const nameTok = try p.advance();
            const param = try p.newNode(nameTok.loc, .{ .identifier = p.text(nameTok) });
            _ = try p.advance(); // consume '=>'
            const params = try p.allocator.alloc(*JsAstNode, 1);
            params[0] = param;
            return try jsParseFinishArrow(p, params, isAsync, nameTok.loc.start);
        }
        return null;
    }

    if (first.tag != .l_paren) return null;

    // Parenthesized form: scan the buffer forward from `first` to find
    // this paren's match, tracking nesting depth, then check whether
    // `=>` immediately follows the matching `)`. A long parameter
    // list gets fully buffered before arrow-ness is known, but that
    // buffering happens exactly once - the same buffer is consumed
    // for real by jsParseParamList below, never re-lexed.
    var depth: i32 = 0;
    var i: usize = startOffset;
    var matchIndex: ?usize = null;
    while (true) {
        const t = try p.peekAt(i);
        if (t.tag == .eof) break;
        if (t.tag == .l_paren) depth += 1;
        if (t.tag == .r_paren) {
            depth -= 1;
            if (depth == 0) {
                matchIndex = i;
                break;
            }
        }
        i += 1;
    }
    const closeIdx = matchIndex orelse return error.SyntaxError;
    const afterClose = try p.peekAt(closeIdx + 1);
    if (!(afterClose.tag == .other_punct and std.mem.eql(u8, p.text(afterClose), "=>") and !afterClose.newline_before)) {
        return null;
    }

    if (isAsync) _ = try p.advance(); // consume 'async'
    const openLoc = (try p.peek()).loc;
    const params = try jsParseParamList(p);
    _ = try p.advance(); // consume '=>'
    return try jsParseFinishArrow(p, params, isAsync, openLoc.start);
}

fn jsParseFinishArrow(p: *JsParse, params: []const *JsAstNode, isAsync: bool, startPos: usize) JsParseError!*JsAstNode {
    const body = if (p.check(.l_brace)) try jsParseBlock(p) else try jsParseAssignExpr(p);
    return try p.newNode(.{ .start = startPos, .end = body.loc.end }, .{ .arrow_function = .{ .params = params, .body = body, .is_async = isAsync } });
}

// A "binding target" is either a plain `identifier` JsAstNode or a
// `pattern` JsAstNode - both appear in the same positions (declarator ids,
// parameters, pattern property values, rest targets), so this is the
// one entry point all of those use.
fn jsParseBindingTarget(p: *JsParse) JsParseError!*JsAstNode {
    if (p.check(.l_brace)) return jsParseObjectPattern(p);
    if (p.check(.l_bracket)) return jsParseArrayPattern(p);
    const t = try p.expect(.identifier);
    return p.newNode(t.loc, .{ .identifier = p.text(t) });
}

fn jsParseObjectPattern(p: *JsParse) JsParseError!*JsAstNode {
    const open = try p.expect(.l_brace);
    var props: std.ArrayList(JsAstPatternProperty) = .empty;
    var rest: ?*JsAstNode = null;
    while (!p.check(.r_brace)) {
        if (jsParseIsSpreadNext(p)) {
            _ = try p.advance();
            rest = try jsParseBindingTarget(p);
            break; // rest must be the last entry in the pattern
        }
        var key: ?[]const u8 = null;
        var computedKey: ?*JsAstNode = null;
        var value: ?*JsAstNode = null;
        var shorthand = false;

        if (p.check(.l_bracket)) {
            _ = try p.advance();
            computedKey = try jsParseAssignExpr(p);
            _ = try p.expect(.r_bracket);
            _ = try p.expect(.colon);
            value = try jsParseBindingTarget(p);
        } else switch (try jsParseKeyPropertyName(p)) {
            .name => |name| {
                key = name.text;
                if (p.check(.colon)) {
                    _ = try p.advance();
                    value = try jsParseBindingTarget(p);
                } else {
                    shorthand = true;
                    value = try p.newNode(name.loc, .{ .identifier = name.text });
                }
            },
            // A string/number key has no shorthand form (`{"foo"} = x`
            // isn't legal - only `{"foo":x}` is), so `:binding` is
            // mandatory here.
            .literal => |lit| {
                computedKey = lit;
                _ = try p.expect(.colon);
                value = try jsParseBindingTarget(p);
            },
        }

        var default: ?*JsAstNode = null;
        if (p.check(.assign)) {
            _ = try p.advance();
            default = try jsParseAssignExpr(p);
        }

        try props.append(p.allocator, .{ .key = key, .computed_key = computedKey, .value = value, .default = default, .shorthand = shorthand });
        if (p.check(.comma)) {
            _ = try p.advance();
        } else break;
    }
    const close = try p.expect(.r_brace);
    return p.newNode(.{ .start = open.loc.start, .end = close.loc.end }, .{ .pattern = .{ .kind = .object, .properties = try props.toOwnedSlice(p.allocator), .rest = rest } });
}

fn jsParseArrayPattern(p: *JsParse) JsParseError!*JsAstNode {
    const open = try p.expect(.l_bracket);
    var props: std.ArrayList(JsAstPatternProperty) = .empty;
    var rest: ?*JsAstNode = null;
    while (!p.check(.r_bracket)) {
        if (p.check(.comma)) {
            // Elided/hole slot: `[a, , b]`.
            try props.append(p.allocator, .{ .key = null, .computed_key = null, .value = null, .default = null, .shorthand = false });
            _ = try p.advance();
            continue;
        }
        if (jsParseIsSpreadNext(p)) {
            _ = try p.advance();
            rest = try jsParseBindingTarget(p);
            break;
        }
        const value = try jsParseBindingTarget(p);
        var default: ?*JsAstNode = null;
        if (p.check(.assign)) {
            _ = try p.advance();
            default = try jsParseAssignExpr(p);
        }
        try props.append(p.allocator, .{ .key = null, .computed_key = null, .value = value, .default = default, .shorthand = false });
        if (p.check(.comma)) {
            _ = try p.advance();
        } else break;
    }
    const close = try p.expect(.r_bracket);
    return p.newNode(.{ .start = open.loc.start, .end = close.loc.end }, .{ .pattern = .{ .kind = .array, .properties = try props.toOwnedSlice(p.allocator), .rest = rest } });
}

// A parameter list is a binding-target list where each entry may also
// carry a `= default`. There's no dedicated "default parameter" node
// kind - a defaulted parameter reuses the `assignment` Data tag with
// op "=" (target on the left, default on the right), the same shape a
// default takes inside an object/array pattern property. A parameter
// with no default is stored as the bare identifier/pattern node.
fn jsParseParamList(p: *JsParse) JsParseError![]const *JsAstNode {
    _ = try p.expect(.l_paren);
    var items: std.ArrayList(*JsAstNode) = .empty;
    while (!p.check(.r_paren)) {
        if (jsParseIsSpreadNext(p)) {
            const spreadStart = try p.advance();
            const target = try jsParseBindingTarget(p);
            const spread = try p.newNode(.{ .start = spreadStart.loc.start, .end = target.loc.end }, .{ .spread = target });
            try items.append(p.allocator, spread);
            break; // rest parameter must be last
        }
        const target = try jsParseBindingTarget(p);
        if (p.check(.assign)) {
            _ = try p.advance();
            const def = try jsParseAssignExpr(p);
            const wrapped = try p.newNode(.{ .start = target.loc.start, .end = def.loc.end }, .{ .assignment = .{ .op = "=", .left = target, .right = def } });
            try items.append(p.allocator, wrapped);
        } else {
            try items.append(p.allocator, target);
        }
        if (p.check(.comma)) {
            _ = try p.advance();
        } else break;
    }
    _ = try p.expect(.r_paren);
    return items.toOwnedSlice(p.allocator);
}

// Converts an already-parsed expression into a valid assignment
// target. Most of the time `expr` is already fine as-is (an
// `identifier`, `member`, or `computed_member` - the only shapes
// that are actually valid targets per spec). The real conversion
// needed: `{a, b} = obj` and `[a, b] = obj` destructuring-assignment
// syntax is syntactically indistinguishable from an object/array
// literal until the `=` is reached, so a literal on the left of `=`
// is re-shaped into an equivalent `pattern` node here, once confirmed
// to be in target position. This parser does not attempt to reject
// an invalid target (e.g. `1 = 2`) as a parse error; anything not
// recognized here is passed through unchanged.
//
// A property/element with its own default (`{a = 1} = obj`,
// `[a = 1] = obj`) parses, before this conversion runs, as a plain
// `assignment` expression node in that slot - split back into the
// (target, default) pair a JsAstPatternProperty expects by `jsParseSplitDefault`
// below, called at each property/element site since
// `jsParseToAssignmentTarget` itself has nowhere to put a second return
// value.
fn jsParseToAssignmentTarget(p: *JsParse, expr: *JsAstNode) JsParseError!*JsAstNode {
    return switch (expr.data) {
        .object_literal => |props| blk: {
            var patProps: std.ArrayList(JsAstPatternProperty) = .empty;
            var rest: ?*JsAstNode = null;
            for (props) |prop| {
                if (prop.kind == .spread) {
                    rest = try jsParseToAssignmentTarget(p, prop.value);
                    continue;
                }
                const split = jsParseSplitDefault(prop.value);
                const value = try jsParseToAssignmentTarget(p, split.target);
                try patProps.append(p.allocator, .{ .key = prop.key, .computed_key = prop.computed_key, .value = value, .default = split.default, .shorthand = prop.shorthand });
            }
            break :blk try p.newNode(expr.loc, .{ .pattern = .{ .kind = .object, .properties = try patProps.toOwnedSlice(p.allocator), .rest = rest } });
        },
        .array_literal => |elements| blk: {
            var patProps: std.ArrayList(JsAstPatternProperty) = .empty;
            var rest: ?*JsAstNode = null;
            for (elements) |maybeEl| {
                const el = maybeEl orelse {
                    try patProps.append(p.allocator, .{ .key = null, .computed_key = null, .value = null, .default = null, .shorthand = false });
                    continue;
                };
                if (el.data == .spread) {
                    rest = try jsParseToAssignmentTarget(p, el.data.spread);
                    continue;
                }
                const split = jsParseSplitDefault(el);
                const value = try jsParseToAssignmentTarget(p, split.target);
                try patProps.append(p.allocator, .{ .key = null, .computed_key = null, .value = value, .default = split.default, .shorthand = false });
            }
            break :blk try p.newNode(expr.loc, .{ .pattern = .{ .kind = .array, .properties = try patProps.toOwnedSlice(p.allocator), .rest = rest } });
        },
        else => expr,
    };
}

const JsParseTargetAndDefault = struct { target: *JsAstNode, default: ?*JsAstNode };

// Splits `target = default` (parsed as a plain `assignment` node
// wherever it appears inside an object/array literal being
// reinterpreted as a pattern) back into its two parts. Anything that
// isn't an `.assignment` node has no default at all.
fn jsParseSplitDefault(expr: *JsAstNode) JsParseTargetAndDefault {
    return switch (expr.data) {
        .assignment => |bin| if (std.mem.eql(u8, bin.op, "="))
            .{ .target = bin.left, .default = bin.right }
        else
            .{ .target = expr, .default = null },
        else => .{ .target = expr, .default = null },
    };
}

// The tokenizer emits a whole template literal - backticks, every
// quasi chunk, and every `${...}` substitution alike - as ONE opaque
// `.template` token, tracked only by brace-depth to find the correct
// closing backtick. It does not tokenize substitutions into separate
// tokens, so this function splits that raw text itself, walking it
// with the same escape/depth-tracking rules the tokenizer uses to
// find each `${`/`}` pair, then parsing the text between them as a
// full expression via a nested `jsParseExpression` call over a freshly
// constructed `JsParse` sharing this parser's own allocator.
fn jsParseTemplateLiteral(p: *JsParse, t: JsToken) JsParseError!*JsAstNode {
    const raw = p.text(t);
    var quasis: std.ArrayList([]const u8) = .empty;
    var expressions: std.ArrayList(*JsAstNode) = .empty;

    var i: usize = 1; // skip the opening backtick
    var chunkStart: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '\\') {
            i += 2;
            continue;
        }
        if (c == '`') {
            try quasis.append(p.allocator, raw[chunkStart .. i + 1]);
            break;
        }
        if (c == '$' and i + 1 < raw.len and raw[i + 1] == '{') {
            try quasis.append(p.allocator, raw[chunkStart..i]);
            // Find this substitution's matching `}`, tracking nested
            // braces/backticks (a substitution can itself contain a
            // nested template literal). Brace-depth alone suffices
            // since a string/regex/nested-template inside the
            // substitution is re-lexed correctly by the nested parser
            // below; this outer scan only needs to find where the
            // substitution text ends.
            const exprStart = i + 2;
            var depth: i32 = 1;
            var j = exprStart;
            while (j < raw.len and depth > 0) {
                const jc = raw[j];
                if (jc == '\\') {
                    j += 2;
                    continue;
                }
                if (jc == '{') depth += 1;
                if (jc == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
                if (jc == '`') {
                    // Nested template literal inside the substitution -
                    // skip over it wholesale (same brace-depth scan as
                    // the tokenizer's own templateLiteral, inlined
                    // here to interoperate with this function's own
                    // depth counter for the outer `${...}`).
                    j += 1;
                    var tplDepth: i32 = 0;
                    while (j < raw.len) {
                        const tc = raw[j];
                        if (tc == '\\') {
                            j += 2;
                            continue;
                        }
                        if (tc == '`' and tplDepth == 0) {
                            j += 1;
                            break;
                        }
                        if (tc == '$' and j + 1 < raw.len and raw[j + 1] == '{') {
                            tplDepth += 1;
                            j += 2;
                            continue;
                        }
                        if (tc == '}' and tplDepth > 0) {
                            tplDepth -= 1;
                            j += 1;
                            continue;
                        }
                        j += 1;
                    }
                    continue;
                }
                j += 1;
            }
            const exprText = raw[exprStart..j];
            var sub = JsParse{
                .allocator = p.allocator,
                .tokenizer = JsTokenizer.init(exprText),
                .lookahead = std.ArrayList(JsToken).empty,
                .source = exprText,
            };
            const subExpr = try jsParseExpression(&sub);
            try expressions.append(p.allocator, subExpr);
            i = j + 1; // past the closing `}`
            chunkStart = i;
            continue;
        }
        i += 1;
    }

    return p.newNode(t.loc, .{ .template_literal = .{
        .quasis = try quasis.toOwnedSlice(p.allocator),
        .expressions = try expressions.toOwnedSlice(p.allocator),
    } });
}

// The base case of the expression grammar - literals, identifiers,
// parenthesized expressions, array/object literals, function/class
// expressions, templates. Everything above this level (unary, binary,
// call/member, etc.) eventually bottoms out here.
fn jsParsePrimary(p: *JsParse) JsParseError!*JsAstNode {
    const t = try p.peek();
    switch (t.tag) {
        .number => {
            _ = try p.advance();
            return p.newNode(t.loc, .{ .number_literal = p.text(t) });
        },
        .string => {
            _ = try p.advance();
            return p.newNode(t.loc, .{ .string_literal = p.text(t) });
        },
        .regex => {
            _ = try p.advance();
            return p.newNode(t.loc, .{ .regex_literal = p.text(t) });
        },
        .template => {
            _ = try p.advance();
            return jsParseTemplateLiteral(p, t);
        },
        .l_paren => {
            _ = try p.advance();
            const inner = try jsParseExpression(p);
            const close = try p.expect(.r_paren);
            return p.newNode(.{ .start = t.loc.start, .end = close.loc.end }, .{ .paren = inner });
        },
        .l_bracket => return jsParseArrayLiteral(p),
        .l_brace => return jsParseObjectLiteral(p),
        .identifier => {
            const name = p.text(t);
            if (std.mem.eql(u8, name, "true")) {
                _ = try p.advance();
                return p.newNode(t.loc, .{ .boolean_literal = true });
            }
            if (std.mem.eql(u8, name, "false")) {
                _ = try p.advance();
                return p.newNode(t.loc, .{ .boolean_literal = false });
            }
            if (std.mem.eql(u8, name, "null")) {
                _ = try p.advance();
                return p.newNode(t.loc, .null_literal);
            }
            if (std.mem.eql(u8, name, "this")) {
                _ = try p.advance();
                return p.newNode(t.loc, .this_expr);
            }
            if (std.mem.eql(u8, name, "super")) {
                _ = try p.advance();
                return p.newNode(t.loc, .super_expr);
            }
            if (std.mem.eql(u8, name, "function")) {
                return jsParseFunction(p, false);
            }
            if (std.mem.eql(u8, name, "class")) {
                return jsParseClass(p);
            }
            if (std.mem.eql(u8, name, "async") and p.checkKeywordAt(1, "function")) {
                _ = try p.advance(); // consume 'async'
                return jsParseFunction(p, true);
            }
            _ = try p.advance();
            return p.newNode(t.loc, .{ .identifier = name });
        },
        else => return error.SyntaxError,
    }
}

fn jsParseArrayLiteral(p: *JsParse) JsParseError!*JsAstNode {
    const open = try p.expect(.l_bracket);
    var elements: std.ArrayList(?*JsAstNode) = .empty;
    while (!p.check(.r_bracket)) {
        if (p.check(.comma)) {
            // Elided/hole slot: `[a, , b]`.
            try elements.append(p.allocator, null);
            _ = try p.advance();
            continue;
        }
        if (jsParseIsSpreadNext(p)) {
            const spreadStart = try p.advance();
            const arg = try jsParseAssignExpr(p);
            const spread = try p.newNode(.{ .start = spreadStart.loc.start, .end = arg.loc.end }, .{ .spread = arg });
            try elements.append(p.allocator, spread);
        } else {
            try elements.append(p.allocator, try jsParseAssignExpr(p));
        }
        if (p.check(.comma)) {
            _ = try p.advance();
        } else break;
    }
    const close = try p.expect(.r_bracket);
    return p.newNode(.{ .start = open.loc.start, .end = close.loc.end }, .{ .array_literal = try elements.toOwnedSlice(p.allocator) });
}

fn jsParseObjectLiteral(p: *JsParse) JsParseError!*JsAstNode {
    const open = try p.expect(.l_brace);
    var props: std.ArrayList(JsAstObjectProperty) = .empty;
    while (!p.check(.r_brace)) {
        try props.append(p.allocator, try jsParseObjectProperty(p));
        if (p.check(.comma)) {
            _ = try p.advance();
        } else break;
    }
    const close = try p.expect(.r_brace);
    return p.newNode(.{ .start = open.loc.start, .end = close.loc.end }, .{ .object_literal = try props.toOwnedSlice(p.allocator) });
}

fn jsParseObjectProperty(p: *JsParse) JsParseError!JsAstObjectProperty {
    if (jsParseIsSpreadNext(p)) {
        _ = try p.advance();
        const arg = try jsParseAssignExpr(p);
        return .{ .kind = .spread, .key = null, .computed_key = null, .value = arg, .shorthand = false };
    }

    var isAsync = false;
    var isGenerator = false;
    if (p.checkKeyword("async")) {
        const nt = try p.peekAt(1);
        if (nt.tag != .colon and nt.tag != .l_paren and nt.tag != .comma and nt.tag != .r_brace) {
            isAsync = true;
            _ = try p.advance();
        }
    }
    if (p.check(.asterisk)) {
        isGenerator = true;
        _ = try p.advance();
    }

    var isGetter = false;
    var isSetter = false;
    if (p.checkKeyword("get") or p.checkKeyword("set")) {
        const nt = try p.peekAt(1);
        if (nt.tag != .colon and nt.tag != .l_paren and nt.tag != .comma and nt.tag != .r_brace) {
            isGetter = p.checkKeyword("get");
            isSetter = p.checkKeyword("set");
            _ = try p.advance();
        }
    }

    var key: ?[]const u8 = null;
    var keyLoc: JsAstLoc = .{ .start = 0, .end = 0 };
    var computedKey: ?*JsAstNode = null;
    if (p.check(.l_bracket)) {
        _ = try p.advance();
        computedKey = try jsParseAssignExpr(p);
        _ = try p.expect(.r_bracket);
    } else {
        switch (try jsParseKeyPropertyName(p)) {
            .name => |name| {
                key = name.text;
                keyLoc = name.loc;
            },
            .literal => |lit| {
                computedKey = lit;
                keyLoc = lit.loc;
            },
        }
    }

    if (p.check(.l_paren)) {
        // Method shorthand: `foo(...) { ... }`.
        const params = try jsParseParamList(p);
        const body = try jsParseBlock(p);
        const fn_ = JsAstFunction{ .name = key, .params = params, .body = body, .is_generator = isGenerator, .is_async = isAsync };
        const kind: JsAstObjectPropertyKind = if (isGetter) .getter else if (isSetter) .setter else .method;
        const valueNode = try p.newNode(body.loc, .{ .function_expr = fn_ });
        return .{ .kind = kind, .key = key, .computed_key = computedKey, .value = valueNode, .shorthand = false };
    }

    if (p.check(.colon)) {
        _ = try p.advance();
        const value = try jsParseAssignExpr(p);
        return .{ .kind = .normal, .key = key, .computed_key = computedKey, .value = value, .shorthand = false };
    }

    // Shorthand `{a}` or `{a = 1}` (the latter only valid in
    // destructuring-assignment position, parsed the same way here and
    // reinterpreted by jsParseToAssignmentTarget/jsParseSplitDefault if it turns out
    // to be on the left of `=`).
    if (key == null) return error.SyntaxError;
    const keyText = key.?;
    var value: *JsAstNode = try p.newNode(keyLoc, .{ .identifier = keyText });
    if (p.check(.assign)) {
        _ = try p.advance();
        const def = try jsParseAssignExpr(p);
        value = try p.newNode(.{ .start = keyLoc.start, .end = def.loc.end }, .{ .assignment = .{ .op = "=", .left = value, .right = def } });
    }
    return .{ .kind = .normal, .key = keyText, .computed_key = null, .value = value, .shorthand = true };
}

fn jsParseBlock(p: *JsParse) JsParseError!*JsAstNode {
    const open = try p.expect(.l_brace);
    var body: std.ArrayList(*JsAstNode) = .empty;
    while (!p.check(.r_brace)) {
        try body.append(p.allocator, try jsParseStatement(p));
    }
    const close = try p.expect(.r_brace);
    return p.newNode(.{ .start = open.loc.start, .end = close.loc.end }, .{ .block = .{ .body = try body.toOwnedSlice(p.allocator) } });
}

fn jsParseFunction(p: *JsParse, isAsync: bool) JsParseError!*JsAstNode {
    const start = try p.expectKeyword("function");
    var isGenerator = false;
    if (p.check(.asterisk)) {
        isGenerator = true;
        _ = try p.advance();
    }
    var name: ?[]const u8 = null;
    if (p.check(.identifier)) {
        const nameTok = try p.advance();
        name = p.text(nameTok);
    }
    const params = try jsParseParamList(p);
    const body = try jsParseBlock(p);
    return p.newNode(.{ .start = start.loc.start, .end = body.loc.end }, .{ .function_expr = .{
        .name = name,
        .params = params,
        .body = body,
        .is_generator = isGenerator,
        .is_async = isAsync,
    } });
}

fn jsParseClass(p: *JsParse) JsParseError!*JsAstNode {
    const start = try p.expectKeyword("class");
    var name: ?[]const u8 = null;
    if (p.check(.identifier) and !p.checkKeyword("extends")) {
        const nameTok = try p.advance();
        name = p.text(nameTok);
    }
    var superClass: ?*JsAstNode = null;
    if (p.checkKeyword("extends")) {
        _ = try p.advance();
        superClass = try jsParseCallMemberChain(p);
    }
    _ = try p.expect(.l_brace);
    var members: std.ArrayList(JsAstClassMember) = .empty;
    while (!p.check(.r_brace)) {
        if (p.check(.semicolon)) {
            _ = try p.advance();
            continue;
        }
        try members.append(p.allocator, try jsParseClassMember(p));
    }
    const close = try p.expect(.r_brace);
    return p.newNode(.{ .start = start.loc.start, .end = close.loc.end }, .{ .class_expr = .{
        .name = name,
        .super_class = superClass,
        .members = try members.toOwnedSlice(p.allocator),
    } });
}

fn jsParseClassMember(p: *JsParse) JsParseError!JsAstClassMember {
    var isStatic = false;
    if (p.checkKeyword("static")) {
        const nt = try p.peekAt(1);
        if (nt.tag != .l_paren and nt.tag != .assign) {
            isStatic = true;
            _ = try p.advance();
        }
    }

    var isAsync = false;
    var isGenerator = false;
    if (p.checkKeyword("async")) {
        const nt = try p.peekAt(1);
        if (nt.tag != .l_paren and nt.tag != .assign and !nt.newline_before) {
            isAsync = true;
            _ = try p.advance();
        }
    }
    if (p.check(.asterisk)) {
        isGenerator = true;
        _ = try p.advance();
    }

    var isGetter = false;
    var isSetter = false;
    if (p.checkKeyword("get") or p.checkKeyword("set")) {
        const nt = try p.peekAt(1);
        if (nt.tag != .l_paren and nt.tag != .assign and nt.tag != .semicolon) {
            isGetter = p.checkKeyword("get");
            isSetter = p.checkKeyword("set");
            _ = try p.advance();
        }
    }

    var key: ?[]const u8 = null;
    var computedKey: ?*JsAstNode = null;
    var isPrivate = false;
    if (p.check(.l_bracket)) {
        _ = try p.advance();
        computedKey = try jsParseAssignExpr(p);
        _ = try p.expect(.r_bracket);
    } else {
        // jsParseKeyPropertyName itself recognizes and stitches
        // together a private `#name` (via jsParsePropertyName) - no
        // separate pre-check needed here. A private name can never
        // be a string/number literal key, so it always comes back as
        // `.name`, never `.literal`.
        switch (try jsParseKeyPropertyName(p)) {
            .name => |name| {
                key = name.text;
                isPrivate = name.is_private;
            },
            .literal => |lit| computedKey = lit,
        }
    }

    if (p.check(.l_paren)) {
        const params = try jsParseParamList(p);
        const body = try jsParseBlock(p);
        const fn_ = JsAstFunction{ .name = key, .params = params, .body = body, .is_generator = isGenerator, .is_async = isAsync };
        const kind: JsAstClassMemberKind = if (isGetter) .getter else if (isSetter) .setter else .method;
        return .{ .kind = kind, .key = key, .computed_key = computedKey, .value = fn_, .field_init = null, .is_static = isStatic, .is_private = isPrivate };
    }

    // Field: `name;` or `name = init;`.
    var fieldInit: ?*JsAstNode = null;
    if (p.check(.assign)) {
        _ = try p.advance();
        fieldInit = try jsParseAssignExpr(p);
    }
    try p.consumeSemicolon();
    return .{ .kind = .field, .key = key, .computed_key = computedKey, .value = null, .field_init = fieldInit, .is_static = isStatic, .is_private = isPrivate };
}

fn jsParseVarDecl(p: *JsParse) JsParseError!*JsAstNode {
    const kindTok = try p.advance();
    const kind: JsAstVarKind = if (std.mem.eql(u8, p.text(kindTok), "var"))
        .@"var"
    else if (std.mem.eql(u8, p.text(kindTok), "let"))
        .@"let"
    else
        .@"const";

    var declarators: std.ArrayList(JsAstDeclarator) = .empty;
    while (true) {
        const id = try jsParseBindingTarget(p);
        var init_: ?*JsAstNode = null;
        if (p.check(.assign)) {
            _ = try p.advance();
            init_ = try jsParseAssignExpr(p);
        }
        try declarators.append(p.allocator, .{ .id = id, .init = init_ });
        if (p.check(.comma)) {
            _ = try p.advance();
        } else break;
    }
    const lastEnd = blk: {
        const last = declarators.items[declarators.items.len - 1];
        break :blk if (last.init) |i| i.loc.end else last.id.loc.end;
    };
    const node = try p.newNode(.{ .start = kindTok.loc.start, .end = lastEnd }, .{ .var_decl = .{ .kind = kind, .declarators = try declarators.toOwnedSlice(p.allocator) } });
    try p.consumeSemicolon();
    return node;
}

fn jsParseStatement(p: *JsParse) JsParseError!*JsAstNode {
    const t = try p.peek();

    if (t.tag == .l_brace) return jsParseBlock(p);
    if (t.tag == .semicolon) {
        _ = try p.advance();
        return p.newNode(t.loc, .empty_stmt);
    }

    if (t.tag == .identifier) {
        const kw = p.text(t);
        if (std.mem.eql(u8, kw, "var") or std.mem.eql(u8, kw, "let") or std.mem.eql(u8, kw, "const")) {
            // `let`/`const` are contextual - only treat as a
            // declaration keyword when followed by something that can
            // start a binding target, so `let` used as an ordinary
            // identifier elsewhere isn't misparsed. `var` has no such
            // ambiguity.
            if (std.mem.eql(u8, kw, "var")) return jsParseVarDecl(p);
            const nt = try p.peekAt(1);
            if (nt.tag == .identifier or nt.tag == .l_brace or nt.tag == .l_bracket) return jsParseVarDecl(p);
        }
        if (std.mem.eql(u8, kw, "function")) return try jsParseWrapAsDecl(p, try jsParseFunction(p, false));
        if (std.mem.eql(u8, kw, "async") and p.checkKeywordAt(1, "function")) {
            _ = try p.advance();
            return try jsParseWrapAsDecl(p, try jsParseFunction(p, true));
        }
        if (std.mem.eql(u8, kw, "class")) return try jsParseWrapAsDecl(p, try jsParseClass(p));
        if (std.mem.eql(u8, kw, "return")) {
            _ = try p.advance();
            const nt = try p.peek();
            var argument: ?*JsAstNode = null;
            if (!(nt.newline_before or nt.tag == .semicolon or nt.tag == .r_brace or nt.tag == .eof)) {
                argument = try jsParseExpression(p);
            }
            const endPos = if (argument) |a| a.loc.end else t.loc.end;
            const node = try p.newNode(.{ .start = t.loc.start, .end = endPos }, .{ .return_stmt = argument });
            try p.consumeSemicolon();
            return node;
        }
        if (std.mem.eql(u8, kw, "debugger")) {
            _ = try p.advance();
            const node = try p.newNode(t.loc, .debugger_stmt);
            try p.consumeSemicolon();
            return node;
        }
        if (std.mem.eql(u8, kw, "if")) return jsParseIf(p);
        if (std.mem.eql(u8, kw, "for")) return jsParseFor(p);
        if (std.mem.eql(u8, kw, "while")) return jsParseWhile(p);
        if (std.mem.eql(u8, kw, "do")) return jsParseDoWhile(p);
        if (std.mem.eql(u8, kw, "switch")) return jsParseSwitch(p);
        if (std.mem.eql(u8, kw, "try")) return jsParseTry(p);
        if (std.mem.eql(u8, kw, "throw")) {
            _ = try p.advance();
            // No ASI/no-newline exception here (unlike `return`) is
            // actually WRONG per spec - `throw` specifically forbids a
            // line break before its argument (`throw\nx` is a syntax
            // error, not `throw; x`) - but this parser doesn't enforce
            // that; it simply always parses the following expression
            // as the argument.
            const argument = try jsParseExpression(p);
            const node = try p.newNode(.{ .start = t.loc.start, .end = argument.loc.end }, .{ .throw_stmt = argument });
            try p.consumeSemicolon();
            return node;
        }
        if (std.mem.eql(u8, kw, "break")) {
            _ = try p.advance();
            const label = try jsParseOptionalLabel(p);
            const node = try p.newNode(t.loc, .{ .break_stmt = label });
            try p.consumeSemicolon();
            return node;
        }
        if (std.mem.eql(u8, kw, "continue")) {
            _ = try p.advance();
            const label = try jsParseOptionalLabel(p);
            const node = try p.newNode(t.loc, .{ .continue_stmt = label });
            try p.consumeSemicolon();
            return node;
        }
        if (std.mem.eql(u8, kw, "with")) return jsParseWith(p);

        // JsAstLabeled statement: `identifier :`. Checked after every
        // other keyword above (all of which are just ordinary
        // identifiers as far as the tokenizer is concerned) so a
        // genuine reserved-word-shaped label doesn't accidentally
        // shadow a real keyword statement; in practice a keyword is
        // never legally used as a label anyway, so this ordering is
        // conservative rather than load-bearing.
        if ((try p.peekAt(1)).tag == .colon) {
            _ = try p.advance();
            _ = try p.advance(); // consume ':'
            const body = try jsParseStatement(p);
            return p.newNode(.{ .start = t.loc.start, .end = body.loc.end }, .{ .labeled_stmt = .{ .label = kw, .body = body } });
        }
    }

    // Fall through: a bare expression statement.
    const expr = try jsParseExpression(p);
    const node = try p.newNode(expr.loc, .{ .expr_stmt = expr });
    try p.consumeSemicolon();
    return node;
}

// `function_expr`/`class_expr` are what jsParseFunction/jsParseClass
// always produce (they're shared with the expression-position case in
// jsParsePrimary) - when actually reached from statement position, this
// just re-tags the same payload as the declaration variant, since the
// two only differ in which position they were parsed from, not in
// shape.
fn jsParseWrapAsDecl(p: *JsParse, exprNode: *JsAstNode) JsParseError!*JsAstNode {
    return switch (exprNode.data) {
        .function_expr => |f| p.newNode(exprNode.loc, .{ .function_decl = f }),
        .class_expr => |c| p.newNode(exprNode.loc, .{ .class_decl = c }),
        else => exprNode,
    };
}

// `break`/`continue`'s optional label - per spec, a line break
// between `break`/`continue` and the label means there is no label at
// all (ASI applies: `break\nlabel;` is `break;` followed by a
// separate `label;` expression statement). Also no label at all if
// what follows can't be one (`;`, `}`, eof).
fn jsParseOptionalLabel(p: *JsParse) JsParseError!?[]const u8 {
    const nt = try p.peek();
    if (nt.newline_before or nt.tag != .identifier) return null;
    _ = try p.advance();
    return p.text(nt);
}

fn jsParseIf(p: *JsParse) JsParseError!*JsAstNode {
    const start = try p.expectKeyword("if");
    _ = try p.expect(.l_paren);
    const test_ = try jsParseExpression(p);
    _ = try p.expect(.r_paren);
    const consequent = try jsParseStatement(p);
    var alternate: ?*JsAstNode = null;
    var endPos = consequent.loc.end;
    if (p.checkKeyword("else")) {
        _ = try p.advance();
        const alt = try jsParseStatement(p);
        alternate = alt;
        endPos = alt.loc.end;
    }
    return p.newNode(.{ .start = start.loc.start, .end = endPos }, .{ .if_stmt = .{ .test_ = test_, .consequent = consequent, .alternate = alternate } });
}

fn jsParseWhile(p: *JsParse) JsParseError!*JsAstNode {
    const start = try p.expectKeyword("while");
    _ = try p.expect(.l_paren);
    const test_ = try jsParseExpression(p);
    _ = try p.expect(.r_paren);
    const body = try jsParseStatement(p);
    return p.newNode(.{ .start = start.loc.start, .end = body.loc.end }, .{ .while_stmt = .{ .test_ = test_, .body = body } });
}

fn jsParseDoWhile(p: *JsParse) JsParseError!*JsAstNode {
    const start = try p.expectKeyword("do");
    const body = try jsParseStatement(p);
    _ = try p.expectKeyword("while");
    _ = try p.expect(.l_paren);
    const test_ = try jsParseExpression(p);
    const close = try p.expect(.r_paren);
    // A `;` after `do...while(...)` is optional even without the
    // usual ASI conditions (newline/`}`/eof) - a special-cased
    // "always allowed" exception specific to do-while. This calls
    // consumeSemicolon only when a `;` is actually present, and skips
    // the check otherwise rather than erroring.
    if (p.check(.semicolon)) _ = try p.advance();
    return p.newNode(.{ .start = start.loc.start, .end = close.loc.end }, .{ .do_while = .{ .body = body, .test_ = test_ } });
}

// `for (...)` has three shapes that all start identically (`for (`
// then either nothing, an expression, or a var/let/const declaration)
// and only diverge once `in`/`of` vs `;` is seen - resolved here via
// the same lookahead-buffer scanning technique jsParseTryParseArrow uses,
// rather than backtracking, since the tokenizer must never be
// rewound.
fn jsParseFor(p: *JsParse) JsParseError!*JsAstNode {
    const start = try p.expectKeyword("for");
    var isAwait = false;
    if (p.checkKeyword("await")) {
        isAwait = true;
        _ = try p.advance();
    }
    _ = try p.expect(.l_paren);

    if (p.check(.semicolon)) {
        // `for (; test; update)` - no init at all, so no in/of
        // ambiguity is even possible.
        return jsParseFinishForClassic(p, start, null);
    }

    const isDecl = p.checkKeyword("var") or p.checkKeyword("let") or p.checkKeyword("const");
    if (isDecl) {
        const declStart = try p.peek();
        const kindTok = try p.advance();
        const kind: JsAstVarKind = if (std.mem.eql(u8, p.text(kindTok), "var"))
            .@"var"
        else if (std.mem.eql(u8, p.text(kindTok), "let"))
            .@"let"
        else
            .@"const";
        const target = try jsParseBindingTarget(p);

        if (p.checkKeyword("in") or p.checkKeyword("of")) {
            const isOf = p.checkKeyword("of");
            _ = try p.advance();
            const declNode = try p.newNode(target.loc, .{ .var_decl = .{ .kind = kind, .declarators = try p.allocator.dupe(JsAstDeclarator, &[_]JsAstDeclarator{.{ .id = target, .init = null }}) } });
            return jsParseFinishForInOf(p, start, declNode, isOf, isAwait);
        }

        // Classic form: finish this declarator (possible `= init`),
        // any further comma-separated declarators, then `;`.
        var declarators: std.ArrayList(JsAstDeclarator) = .empty;
        var init_: ?*JsAstNode = null;
        if (p.check(.assign)) {
            _ = try p.advance();
            init_ = try jsParseAssignExpr(p);
        }
        try declarators.append(p.allocator, .{ .id = target, .init = init_ });
        while (p.check(.comma)) {
            _ = try p.advance();
            const id = try jsParseBindingTarget(p);
            var di: ?*JsAstNode = null;
            if (p.check(.assign)) {
                _ = try p.advance();
                di = try jsParseAssignExpr(p);
            }
            try declarators.append(p.allocator, .{ .id = id, .init = di });
        }
        const lastEnd = blk: {
            const last = declarators.items[declarators.items.len - 1];
            break :blk if (last.init) |ini| ini.loc.end else last.id.loc.end;
        };
        const declNode = try p.newNode(.{ .start = declStart.loc.start, .end = lastEnd }, .{ .var_decl = .{ .kind = kind, .declarators = try declarators.toOwnedSlice(p.allocator) } });
        return jsParseFinishForClassic(p, start, declNode);
    }

    // No `var`/`let`/`const` - either `for (x in/of y)` with a plain
    // assignment-target expression, or classic `for (expr; ...)`.
    const first = try jsParseExpression(p);
    if (p.checkKeyword("in") or p.checkKeyword("of")) {
        const isOf = p.checkKeyword("of");
        _ = try p.advance();
        const target = try jsParseToAssignmentTarget(p, first);
        return jsParseFinishForInOf(p, start, target, isOf, isAwait);
    }
    return jsParseFinishForClassic(p, start, first);
}

fn jsParseFinishForInOf(p: *JsParse, start: JsToken, left: *JsAstNode, isOf: bool, isAwait: bool) JsParseError!*JsAstNode {
    const right = if (isOf) try jsParseAssignExpr(p) else try jsParseExpression(p);
    _ = try p.expect(.r_paren);
    const body = try jsParseStatement(p);
    return p.newNode(.{ .start = start.loc.start, .end = body.loc.end }, .{ .for_in_of = .{ .left = left, .right = right, .body = body, .is_of = isOf, .is_await = isAwait } });
}

fn jsParseFinishForClassic(p: *JsParse, start: JsToken, init_: ?*JsAstNode) JsParseError!*JsAstNode {
    _ = try p.expect(.semicolon);
    var test_: ?*JsAstNode = null;
    if (!p.check(.semicolon)) test_ = try jsParseExpression(p);
    _ = try p.expect(.semicolon);
    var update: ?*JsAstNode = null;
    if (!p.check(.r_paren)) update = try jsParseExpression(p);
    _ = try p.expect(.r_paren);
    const body = try jsParseStatement(p);
    return p.newNode(.{ .start = start.loc.start, .end = body.loc.end }, .{ .for_stmt = .{ .init = init_, .test_ = test_, .update = update, .body = body } });
}

fn jsParseSwitch(p: *JsParse) JsParseError!*JsAstNode {
    const start = try p.expectKeyword("switch");
    _ = try p.expect(.l_paren);
    const discriminant = try jsParseExpression(p);
    _ = try p.expect(.r_paren);
    _ = try p.expect(.l_brace);
    var cases: std.ArrayList(JsAstCase) = .empty;
    while (!p.check(.r_brace)) {
        var test_: ?*JsAstNode = null;
        if (p.checkKeyword("default")) {
            _ = try p.advance();
        } else {
            _ = try p.expectKeyword("case");
            test_ = try jsParseExpression(p);
        }
        _ = try p.expect(.colon);
        var body: std.ArrayList(*JsAstNode) = .empty;
        while (!p.check(.r_brace) and !p.checkKeyword("case") and !p.checkKeyword("default")) {
            try body.append(p.allocator, try jsParseStatement(p));
        }
        try cases.append(p.allocator, .{ .test_ = test_, .body = try body.toOwnedSlice(p.allocator) });
    }
    const close = try p.expect(.r_brace);
    return p.newNode(.{ .start = start.loc.start, .end = close.loc.end }, .{ .switch_stmt = .{ .discriminant = discriminant, .cases = try cases.toOwnedSlice(p.allocator) } });
}

fn jsParseTry(p: *JsParse) JsParseError!*JsAstNode {
    const start = try p.expectKeyword("try");
    const block = try jsParseBlock(p);
    var catchParam: ?*JsAstNode = null;
    var catchBody: ?*JsAstNode = null;
    var finallyBody: ?*JsAstNode = null;
    var endPos = block.loc.end;

    if (p.checkKeyword("catch")) {
        _ = try p.advance();
        if (p.check(.l_paren)) {
            _ = try p.advance();
            catchParam = try jsParseBindingTarget(p);
            _ = try p.expect(.r_paren);
        }
        const cb = try jsParseBlock(p);
        catchBody = cb;
        endPos = cb.loc.end;
    }
    if (p.checkKeyword("finally")) {
        _ = try p.advance();
        const fb = try jsParseBlock(p);
        finallyBody = fb;
        endPos = fb.loc.end;
    }
    return p.newNode(.{ .start = start.loc.start, .end = endPos }, .{ .try_stmt = .{ .block = block, .catch_param = catchParam, .catch_body = catchBody, .finally_body = finallyBody } });
}

fn jsParseWith(p: *JsParse) JsParseError!*JsAstNode {
    const start = try p.expectKeyword("with");
    _ = try p.expect(.l_paren);
    const object = try jsParseExpression(p);
    _ = try p.expect(.r_paren);
    const body = try jsParseStatement(p);
    return p.newNode(.{ .start = start.loc.start, .end = body.loc.end }, .{ .with_stmt = .{ .object = object, .body = body } });
}
