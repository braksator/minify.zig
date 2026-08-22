//! JavaScript minifier: parses to an AST and reprints it minified,
//! with optional identifier mangling. Falls back to the older
//! token-stream strip pass (`jsStrip`, below) only when the parser
//! can't handle the input at all, or scope resolution finds a
//! `with` statement (which makes static mangling unsafe) - so a
//! script this project can't fully understand still comes out
//! comment/whitespace-stripped rather than untouched or erroring.

const std = @import("std");
const parser = @import("js_parser.zig");
const tok = parser;
const jsast = parser;
const minify = @import("minify.zig");

pub const MinifyOptions = minify.MinifyOptions;

const JsBuf = std.ArrayList(u8);
const JsTokenType = tok.JsTokenType;

fn jsIsIdentLike(t: JsTokenType) bool {
    return switch (t) {
        .identifier, .number, .regex => true,
        else => false,
    };
}

/// Reports whether a literal separator is required between two adjacent
/// tokens to avoid the output re-lexing differently than intended.
fn jsNeedsSeparator(prev: JsTokenType, prevText: []const u8, next: JsTokenType, nextText: []const u8) bool {
    if (jsIsIdentLike(prev) and jsIsIdentLike(next)) return true;
    if (jsIsPunctToken(prev) and jsIsPunctToken(next) and prevText.len > 0 and nextText.len > 0) {
        const a = prevText[prevText.len - 1];
        const b = nextText[0];
        if (jsIsDangerousAdjacentPair(a, b)) return true;
    }
    if (prev == .slash and next == .regex) return true;
    if (prev == .regex and (next == .identifier or next == .regex)) return true;
    return false;
}

fn jsIsPunctToken(t: JsTokenType) bool {
    return switch (t) {
        .assign, .plus, .minus, .asterisk, .slash, .percent, .dot, .question, .bang, .amp, .pipe, .caret, .lt, .gt, .other_punct => true,
        else => false,
    };
}

// Pairs that are the first two characters of some real multi-char JS
// operator; adjacent tokens ending/starting with such a pair must not be
// concatenated without a separator, or they'd re-lex as that operator.
// Update in lockstep with the tokenizer's punctuator tables.
fn jsIsDangerousAdjacentPair(a: u8, b: u8) bool {
    const pairs = [_][2]u8{
        .{ '!', '=' }, .{ '%', '=' }, .{ '&', '&' }, .{ '&', '=' },
        .{ '*', '*' }, .{ '*', '=' }, .{ '+', '+' }, .{ '+', '=' },
        .{ '-', '-' }, .{ '-', '=' }, .{ '/', '=' }, .{ '<', '<' },
        .{ '<', '=' }, .{ '=', '=' }, .{ '=', '>' }, .{ '>', '=' },
        .{ '>', '>' }, .{ '?', '.' }, .{ '?', '?' }, .{ '^', '=' },
        .{ '|', '=' }, .{ '|', '|' },
    };
    for (pairs) |p| {
        if (p[0] == a and p[1] == b) return true;
    }
    return false;
}

/// Fallback path: comment/whitespace stripping with no reprinting
/// and no mangling, driven directly off the token stream rather than
/// a parsed AST. Used only when `js()` can't use the parser-based
/// pipeline for `input` at all.
fn jsStrip(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: JsBuf = .empty;
    errdefer out.deinit(allocator);

    var t = tok.JsTokenizer.init(input);
    var prevTag: ?JsTokenType = null;
    var prevText: []const u8 = &[_]u8{};

    while (true) {
        const token = t.next();
        if (token.tag == .eof) break;
        if (token.tag == .invalid) {
            try out.appendSlice(allocator, input[token.loc.start..token.loc.end]);
            prevTag = null;
            prevText = &[_]u8{};
            continue;
        }

        const text = input[token.loc.start..token.loc.end];

        if (prevTag) |pt| {
            if (token.newline_before and jsAsiNeedsNewline(pt, prevText, token.tag, text)) {
                try out.append(allocator, '\n');
            } else if (jsNeedsSeparator(pt, prevText, token.tag, text)) {
                try out.append(allocator, ' ');
            }
        }

        try out.appendSlice(allocator, text);
        prevTag = token.tag;
        prevText = text;
    }

    return out.toOwnedSlice(allocator);
}

const JsArgs = struct {
    mangle: bool = false,
    top: bool = true,
    reserved: []const []const u8 = &.{},
    protect: []const []const u8 = &.{},
};

/// Minifies JavaScript. `args` is an optional `MinifyOptions` JSON
/// string; see `minify.zig` for the full shape and defaults.
/// Falls back to `jsStrip` when the input can't be parsed.
pub fn js(allocator: std.mem.Allocator, input: []const u8, args: ?[]const u8) ![]u8 {
    const parsed = try minify.parseOptions(allocator, args);
    defer parsed.deinit();
    const m = parsed.value.js.mangle;
    return jsMinify(allocator, input, .{
        .mangle = m.enabled,
        .top = m.top,
        .reserved = m.reserved,
        .protect = m.protect,
    });
}

fn jsMinify(allocator: std.mem.Allocator, input: []const u8, parsedArgs: JsArgs) ![]u8 {
    var tree = parser.jsParse(allocator, input) catch |err| switch (err) {
        error.SyntaxError => return jsStrip(allocator, input),
        else => |e| return e,
    };
    defer tree.deinit();

    var scopeTree = try jsScopeBuild(allocator, &tree.program);
    defer scopeTree.deinit();

    if (parsedArgs.mangle) {
        const skipScope: ?JsScopeId = if (parsedArgs.top) null else 0;
        try jsMangleAssignShortNames(allocator, &scopeTree, parsedArgs.reserved, parsedArgs.protect, skipScope);
    }
    defer if (parsedArgs.mangle) {
        for (scopeTree.scopes.items) |s| {
            for (s.decls.items) |d| {
                if (d.shortName.len > 0) allocator.free(d.shortName);
            }
        }
    };

    try jsJoinStatements(tree.arena.allocator(), &tree.program);

    return jsPrint(allocator, &tree.program, &scopeTree);
}

/// The global-scope names one script/handler exposes to (or expects
/// from) any other script/handler on the same page: every name it
/// declares at top level, and every name it references without a
/// local declaration (a real global, or one this call can't see
/// because it's declared elsewhere on the page). Used by callers that
/// process multiple `<script>`/`on*=` sources from one document (see
/// `html.zig`, `svg.zig`) to compute which top-level names are unsafe
/// to mangle before minifying any of them individually.
pub const JsTopLevelNames = struct {
    declared: []const []const u8,
    unresolved: []const []const u8,

    pub fn deinit(self: JsTopLevelNames, allocator: std.mem.Allocator) void {
        jsFreeDupedStrings(allocator, self.declared);
        jsFreeDupedStrings(allocator, self.unresolved);
    }
};

/// Parses `input` and reports its top-level `JsTopLevelNames`,
/// without minifying or mangling anything. Returns empty lists (not
/// an error) when `input` can't be parsed - a script that fails to
/// parse also fails to mangle (see `js`'s own fallback to `jsStrip`),
/// so it has nothing to protect other scripts from.
pub fn jsCollectTopLevelNames(allocator: std.mem.Allocator, input: []const u8) !JsTopLevelNames {
    var tree = parser.jsParse(allocator, input) catch |err| switch (err) {
        error.SyntaxError => return .{ .declared = &.{}, .unresolved = &.{} },
        else => |e| return e,
    };
    defer tree.deinit();

    var scopeTree = try jsScopeBuild(allocator, &tree.program);
    defer scopeTree.deinit();

    var declared: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer declared.deinit(allocator);
    for (scopeTree.scopes.items[0].decls.items) |d| {
        try declared.put(allocator, d.name, {});
    }

    var unresolved: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer unresolved.deinit(allocator);
    for (scopeTree.references.items) |r| {
        if (r.resolvedScope == null) try unresolved.put(allocator, r.name, {});
    }

    return .{
        .declared = try jsDupeStrings(allocator, declared.keys()),
        .unresolved = try jsDupeStrings(allocator, unresolved.keys()),
    };
}

/// Every string-literal argument to a `getElementById`/`getElementsByName`
/// call found anywhere in `input`, e.g. `document.getElementById("x")` or
/// a chained/aliased receiver like `doc.getElementById('x')`. Used by
/// callers (see `svg.zig`) to protect an id a script depends on from a
/// strip pass that only sees markup. Only the literal-string-argument
/// call shape is recognized; a computed/built string or a wrapping
/// helper function is invisible to this. Returns an empty list (not an
/// error) when `input` can't be parsed.
pub fn jsCollectElementIdLookups(allocator: std.mem.Allocator, input: []const u8) ![]const []const u8 {
    var tree = parser.jsParse(allocator, input) catch |err| switch (err) {
        error.SyntaxError => return &.{},
        else => |e| return e,
    };
    defer tree.deinit();

    var ids: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer {
        for (ids.keys()) |k| allocator.free(k);
        ids.deinit(allocator);
    }

    for (tree.program.body) |stmt| try jsWalkForElementIdLookups(allocator, &ids, stmt);

    return jsDupeStrings(allocator, ids.keys());
}

const jsElementIdLookupCallees = [_][]const u8{ "getElementById", "getElementsByName" };

fn jsIsElementIdLookupCallee(node: *const jsast.JsAstNode) bool {
    if (node.data != .member) return false;
    for (jsElementIdLookupCallees) |name| {
        if (std.mem.eql(u8, node.data.member.property, name)) return true;
    }
    return false;
}

/// A plain single/double-quoted string literal with no escape sequences
/// - the bounded "literal-string call pattern" this pass targets, not a
/// general JS string decoder. `null` for anything else (a template
/// literal, a literal containing `\`, an unterminated/malformed token).
fn jsStringLiteralPlainContent(raw: []const u8) ?[]const u8 {
    if (raw.len < 2) return null;
    const quote = raw[0];
    if (quote != '"' and quote != '\'') return null;
    if (raw[raw.len - 1] != quote) return null;
    const inner = raw[1 .. raw.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '\\') != null) return null;
    return inner;
}

fn jsWalkForElementIdLookups(allocator: std.mem.Allocator, ids: *std.StringArrayHashMapUnmanaged(void), node: *const jsast.JsAstNode) !void {
    switch (node.data) {
        .call => |c| {
            if (jsIsElementIdLookupCallee(c.callee) and c.arguments.len >= 1 and c.arguments[0].data == .string_literal) {
                if (jsStringLiteralPlainContent(c.arguments[0].data.string_literal)) |id| {
                    if (!ids.contains(id)) try ids.put(allocator, try allocator.dupe(u8, id), {});
                }
            }
            try jsWalkForElementIdLookups(allocator, ids, c.callee);
            for (c.arguments) |arg| try jsWalkForElementIdLookups(allocator, ids, arg);
        },
        .new_expr => |c| {
            try jsWalkForElementIdLookups(allocator, ids, c.callee);
            for (c.arguments) |arg| try jsWalkForElementIdLookups(allocator, ids, arg);
        },
        .block => |b| for (b.body) |s| try jsWalkForElementIdLookups(allocator, ids, s),
        .var_decl => |vd| for (vd.declarators) |d| {
            if (d.init) |i| try jsWalkForElementIdLookups(allocator, ids, i);
        },
        .expr_stmt => |e| try jsWalkForElementIdLookups(allocator, ids, e),
        .if_stmt => |s| {
            try jsWalkForElementIdLookups(allocator, ids, s.test_);
            try jsWalkForElementIdLookups(allocator, ids, s.consequent);
            if (s.alternate) |alt| try jsWalkForElementIdLookups(allocator, ids, alt);
        },
        .for_stmt => |s| {
            if (s.init) |i| try jsWalkForElementIdLookups(allocator, ids, i);
            if (s.test_) |t| try jsWalkForElementIdLookups(allocator, ids, t);
            if (s.update) |u| try jsWalkForElementIdLookups(allocator, ids, u);
            try jsWalkForElementIdLookups(allocator, ids, s.body);
        },
        .for_in_of => |s| {
            try jsWalkForElementIdLookups(allocator, ids, s.left);
            try jsWalkForElementIdLookups(allocator, ids, s.right);
            try jsWalkForElementIdLookups(allocator, ids, s.body);
        },
        .while_stmt => |s| {
            try jsWalkForElementIdLookups(allocator, ids, s.test_);
            try jsWalkForElementIdLookups(allocator, ids, s.body);
        },
        .do_while => |s| {
            try jsWalkForElementIdLookups(allocator, ids, s.body);
            try jsWalkForElementIdLookups(allocator, ids, s.test_);
        },
        .return_stmt => |arg| if (arg) |a| try jsWalkForElementIdLookups(allocator, ids, a),
        .throw_stmt => |arg| try jsWalkForElementIdLookups(allocator, ids, arg),
        .try_stmt => |s| {
            try jsWalkForElementIdLookups(allocator, ids, s.block);
            if (s.catch_body) |cb| try jsWalkForElementIdLookups(allocator, ids, cb);
            if (s.finally_body) |fb| try jsWalkForElementIdLookups(allocator, ids, fb);
        },
        .switch_stmt => |s| {
            try jsWalkForElementIdLookups(allocator, ids, s.discriminant);
            for (s.cases) |c| {
                if (c.test_) |t| try jsWalkForElementIdLookups(allocator, ids, t);
                for (c.body) |stmt| try jsWalkForElementIdLookups(allocator, ids, stmt);
            }
        },
        .labeled_stmt => |s| try jsWalkForElementIdLookups(allocator, ids, s.body),
        .function_decl, .function_expr => |f| try jsWalkForElementIdLookups(allocator, ids, f.body),
        .arrow_function => |a| try jsWalkForElementIdLookups(allocator, ids, a.body),
        .class_decl, .class_expr => |c| {
            if (c.super_class) |sc| try jsWalkForElementIdLookups(allocator, ids, sc);
            for (c.members) |m| {
                if (m.computed_key) |ck| try jsWalkForElementIdLookups(allocator, ids, ck);
                if (m.value) |f| try jsWalkForElementIdLookups(allocator, ids, f.body);
                if (m.field_init) |fi| try jsWalkForElementIdLookups(allocator, ids, fi);
            }
        },
        .with_stmt => |s| {
            try jsWalkForElementIdLookups(allocator, ids, s.object);
            try jsWalkForElementIdLookups(allocator, ids, s.body);
        },
        .template_literal => |t| for (t.expressions) |e| try jsWalkForElementIdLookups(allocator, ids, e),
        .tagged_template => |t| {
            try jsWalkForElementIdLookups(allocator, ids, t.tag);
            for (t.quasi.expressions) |e| try jsWalkForElementIdLookups(allocator, ids, e);
        },
        .array_literal => |elements| for (elements) |maybeEl| {
            if (maybeEl) |el| try jsWalkForElementIdLookups(allocator, ids, el);
        },
        .object_literal => |props| for (props) |prop| {
            if (prop.computed_key) |ck| try jsWalkForElementIdLookups(allocator, ids, ck);
            try jsWalkForElementIdLookups(allocator, ids, prop.value);
        },
        .spread => |arg| try jsWalkForElementIdLookups(allocator, ids, arg),
        .binary, .assignment, .logical => |bin| {
            try jsWalkForElementIdLookups(allocator, ids, bin.left);
            try jsWalkForElementIdLookups(allocator, ids, bin.right);
        },
        .unary, .update => |u| try jsWalkForElementIdLookups(allocator, ids, u.argument),
        .conditional => |c| {
            try jsWalkForElementIdLookups(allocator, ids, c.test_);
            try jsWalkForElementIdLookups(allocator, ids, c.consequent);
            try jsWalkForElementIdLookups(allocator, ids, c.alternate);
        },
        .member => |m| try jsWalkForElementIdLookups(allocator, ids, m.object),
        .computed_member => |m| {
            try jsWalkForElementIdLookups(allocator, ids, m.object);
            try jsWalkForElementIdLookups(allocator, ids, m.property);
        },
        .paren => |inner| try jsWalkForElementIdLookups(allocator, ids, inner),
        .sequence => |items| for (items) |item| try jsWalkForElementIdLookups(allocator, ids, item),
        .yield_expr => |y| if (y.argument) |a| try jsWalkForElementIdLookups(allocator, ids, a),
        .await_expr => |arg| try jsWalkForElementIdLookups(allocator, ids, arg),
        else => {},
    }
}

fn jsFreeDupedStrings(allocator: std.mem.Allocator, strs: []const []const u8) void {
    for (strs) |s| allocator.free(s);
    allocator.free(strs);
}

fn jsDupeStrings(allocator: std.mem.Allocator, strs: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, strs.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |s| allocator.free(s);
        allocator.free(out);
    }
    for (strs, 0..) |s, i| {
        out[i] = try allocator.dupe(u8, s);
        filled += 1;
    }
    return out;
}

// ASI guard. Restricted-production keywords (return/break/continue/
// throw/yield) always keep a following newline. Otherwise, keep a
// newline unless the previous token can end a statement and the next
// token can only continue the existing expression.
fn jsAsiNeedsNewline(prev: JsTokenType, prevText: []const u8, next: JsTokenType, nextText: []const u8) bool {
    if (prev == .identifier and jsIsRestrictedProductionKeyword(prevText)) return true;

    const prevEndsStatement = switch (prev) {
        .identifier, .number, .string, .template, .regex, .r_paren, .r_bracket, .r_brace => true,
        .other_punct => std.mem.eql(u8, prevText, "++") or std.mem.eql(u8, prevText, "--"),
        else => false,
    };
    if (!prevEndsStatement) return false;

    return switch (next) {
        .r_paren, .r_bracket, .r_brace, .comma, .semicolon, .colon, .dot, .question => false,
        .asterisk, .percent, .caret, .lt, .gt, .amp, .pipe, .assign => false,
        .l_brace => false,
        .other_punct => std.mem.eql(u8, nextText, "++") or std.mem.eql(u8, nextText, "--"),
        else => true,
    };
}

fn jsIsRestrictedProductionKeyword(text: []const u8) bool {
    const kws = [_][]const u8{ "return", "break", "continue", "throw", "yield" };
    for (kws) |kw| {
        if (std.mem.eql(u8, text, kw)) return true;
    }
    return false;
}

const JsAstProgram = parser.JsAstProgram;
const JsAstNode = parser.JsAstNode;

pub const JsScopeKind = enum {
    /// The whole program.
    global,
    /// A function body - where `var`/function declarations hoist to.
    function,
    /// Any other `{ }` block: if/for/while/bare block bodies, a
    /// catch block, a class body.
    block,
};

/// How a name was declared.
pub const JsScopeDeclKind = enum {
    @"var",
    @"let",
    @"const",
    function,
    class,
    param,
    catch_param,
};

pub const JsScopeDecl = struct {
    name: []const u8,
    kind: JsScopeDeclKind,
    /// The `identifier` JsAstNode this name was declared at.
    node: *JsAstNode,
    /// Assigned by a later mangling pass; empty until then.
    shortName: []const u8 = &[_]u8{},
};

pub const JsScopeId = usize;

pub const JsScope = struct {
    kind: JsScopeKind,
    parent: ?JsScopeId,
    children: std.ArrayList(JsScopeId),
    decls: std.ArrayList(JsScopeDecl),
    /// Set on the scope a `with` statement's body opens, and
    /// inherited by every scope nested inside it. `with` makes
    /// static resolution of any bare name inside it unreliable
    /// (it might resolve to an object property at runtime instead
    /// of the declaration this pass found), so nothing declared or
    /// referenced in such a scope is safe to rename.
    unsafeToMangle: bool = false,
};

/// A single identifier reference (not a declaration) and which
/// declaration, if any, it resolved to.
pub const JsScopeReference = struct {
    node: *JsAstNode,
    name: []const u8,
    fromScope: JsScopeId,
    /// `null` means unresolved: a genuine global, or declared
    /// somewhere this pass doesn't track (e.g. a different script).
    resolvedScope: ?JsScopeId = null,
    resolvedDeclIndex: ?usize = null,
};

pub const JsScopeTree = struct {
    allocator: std.mem.Allocator,
    scopes: std.ArrayList(JsScope),
    references: std.ArrayList(JsScopeReference),

    pub fn deinit(self: *JsScopeTree) void {
        for (self.scopes.items) |*s| {
            s.children.deinit(self.allocator);
            s.decls.deinit(self.allocator);
        }
        self.scopes.deinit(self.allocator);
        self.references.deinit(self.allocator);
    }
};

const JsScopeWalkError = std.mem.Allocator.Error;

const JsScopeBuilder = struct {
    allocator: std.mem.Allocator,
    tree: *JsScopeTree,
    /// Currently-open scopes, innermost last.
    scopeStack: std.ArrayList(JsScopeId),

    fn jsScopeCurrentScope(self: *const JsScopeBuilder) JsScopeId {
        return self.scopeStack.items[self.scopeStack.items.len - 1];
    }

    fn jsScopePushScope(self: *JsScopeBuilder, kind: JsScopeKind) !JsScopeId {
        const parent = self.jsScopeCurrentScope();
        const id = self.tree.scopes.items.len;
        const inheritedUnsafe = self.tree.scopes.items[parent].unsafeToMangle;
        try self.tree.scopes.append(self.allocator, .{ .kind = kind, .parent = parent, .children = .empty, .decls = .empty, .unsafeToMangle = inheritedUnsafe });
        try self.tree.scopes.items[parent].children.append(self.allocator, id);
        try self.scopeStack.append(self.allocator, id);
        return id;
    }

    fn jsScopePopScope(self: *JsScopeBuilder) void {
        _ = self.scopeStack.pop();
    }

    fn jsScopeAddDecl(self: *JsScopeBuilder, scope: JsScopeId, name: []const u8, kind: JsScopeDeclKind, node: *JsAstNode) !void {
        try self.tree.scopes.items[scope].decls.append(self.allocator, .{ .name = name, .kind = kind, .node = node });
    }

    fn jsScopeAddReference(self: *JsScopeBuilder, name: []const u8, node: *JsAstNode) !void {
        try self.tree.references.append(self.allocator, .{ .node = node, .name = name, .fromScope = self.jsScopeCurrentScope() });
    }
};

/// Builds a scope tree from a parsed `JsAstProgram` and binds every
/// identifier reference to its declaration.
pub fn jsScopeBuild(allocator: std.mem.Allocator, program: *const parser.JsAstProgram) !JsScopeTree {
    var tree = JsScopeTree{
        .allocator = allocator,
        .scopes = .empty,
        .references = .empty,
    };
    errdefer tree.deinit();

    try tree.scopes.append(allocator, .{ .kind = .global, .parent = null, .children = .empty, .decls = .empty });

    var b = JsScopeBuilder{
        .allocator = allocator,
        .tree = &tree,
        .scopeStack = .empty,
    };
    defer b.scopeStack.deinit(allocator);
    try b.scopeStack.append(allocator, 0);

    // `var`/function declarations hoist to the top of their enclosing
    // function/global scope, so they must be visible to a reference
    // that textually precedes them - collect them across the whole
    // body first, then walk statements for nested scopes/references.
    try jsScopeHoistBlockBody(&b, program.body, b.jsScopeCurrentScope());
    for (program.body) |stmt| try jsScopeWalkStatement(&b, stmt);

    resolveReferences(&tree);
    return tree;
}

// Recursive pre-pass that finds every `var` declaration and function
// declaration reachable from `body` without crossing a function
// boundary (nested blocks/if/for/etc. are descended into; nested
// functions/arrows are not), and records each in `target` - the
// enclosing function-or-global scope. This is what makes `var`
// hoisting work regardless of how deep in nested blocks the
// declaration textually appears, and is only ever run once per
// function/global scope, from that scope's own entry point.
fn jsScopeHoistBlockBody(b: *JsScopeBuilder, body: []const *JsAstNode, target: JsScopeId) JsScopeWalkError!void {
    for (body) |stmt| try jsScopeHoistStatement(b, stmt, target);
}

fn jsScopeHoistStatement(b: *JsScopeBuilder, node: *JsAstNode, target: JsScopeId) JsScopeWalkError!void {
    switch (node.data) {
        .var_decl => |vd| {
            if (vd.kind == .@"var") {
                for (vd.declarators) |d| try jsScopeHoistBindingTarget(b, d.id, target);
            }
        },
        .function_decl => |f| {
            if (f.name) |name| try b.jsScopeAddDecl(target, name, .function, node);
        },
        .if_stmt => |s| {
            try jsScopeHoistStatement(b, s.consequent, target);
            if (s.alternate) |alt| try jsScopeHoistStatement(b, alt, target);
        },
        .for_stmt => |s| {
            if (s.init) |i| try jsScopeHoistStatement(b, i, target);
            try jsScopeHoistStatement(b, s.body, target);
        },
        .for_in_of => |s| {
            try jsScopeHoistStatement(b, s.left, target);
            try jsScopeHoistStatement(b, s.body, target);
        },
        .while_stmt => |s| try jsScopeHoistStatement(b, s.body, target),
        .do_while => |s| try jsScopeHoistStatement(b, s.body, target),
        .try_stmt => |s| {
            try jsScopeHoistStatement(b, s.block, target);
            if (s.catch_body) |cb| try jsScopeHoistStatement(b, cb, target);
            if (s.finally_body) |fb| try jsScopeHoistStatement(b, fb, target);
        },
        .switch_stmt => |s| {
            for (s.cases) |c| try jsScopeHoistBlockBody(b, c.body, target);
        },
        .labeled_stmt => |s| try jsScopeHoistStatement(b, s.body, target),
        .with_stmt => |s| try jsScopeHoistStatement(b, s.body, target),
        .block => |blk| try jsScopeHoistBlockBody(b, blk.body, target),
        // JsAstFunction/class declarations, expressions, and everything
        // else are scope boundaries or non-hoisting - stop here.
        else => {},
    }
}

// Registers a block's own *direct* function declarations (only - not
// `var`, which is handled once, non-locally, by jsScopeHoistBlockBody above)
// into that block's own scope. Unlike jsScopeHoistBlockBody this does not
// recurse into nested blocks - each block registers only its own
// immediate function declarations, not a descendant block's.
fn jsScopeRegisterBlockLocalFunctions(b: *JsScopeBuilder, body: []const *JsAstNode, blockScope: JsScopeId) JsScopeWalkError!void {
    for (body) |stmt| {
        if (stmt.data == .function_decl) {
            if (stmt.data.function_decl.name) |name| try b.jsScopeAddDecl(blockScope, name, .function, stmt);
        }
    }
}

// Records every bound name in a binding-target node (`identifier` or
// `pattern`) as a `var`-kind decl in `target`, without walking into
// any initializer/default-value expression - those get walked for
// real (references, nested scopes) in the main pass.
fn jsScopeHoistBindingTarget(b: *JsScopeBuilder, node: *JsAstNode, target: JsScopeId) JsScopeWalkError!void {
    switch (node.data) {
        .identifier => |name| try b.jsScopeAddDecl(target, name, .@"var", node),
        .pattern => |p| {
            for (p.properties) |prop| {
                if (prop.value) |v| try jsScopeHoistBindingTarget(b, v, target);
            }
            if (p.rest) |r| try jsScopeHoistBindingTarget(b, r, target);
        },
        else => {},
    }
}

fn jsScopeWalkStatement(b: *JsScopeBuilder, node: *JsAstNode) JsScopeWalkError!void {
    switch (node.data) {
        .block => |blk| {
            _ = try b.jsScopePushScope(.block);
            try jsScopeRegisterBlockLocalFunctions(b, blk.body, b.jsScopeCurrentScope());
            for (blk.body) |stmt| try jsScopeWalkStatement(b, stmt);
            b.jsScopePopScope();
        },
        .var_decl => |vd| try jsScopeWalkVarDecl(b, vd),
        .expr_stmt => |e| try jsScopeWalkExpr(b, e),
        .if_stmt => |s| {
            try jsScopeWalkExpr(b, s.test_);
            try jsScopeWalkStatement(b, s.consequent);
            if (s.alternate) |alt| try jsScopeWalkStatement(b, alt);
        },
        .for_stmt => |s| {
            // A `let`/`const` init needs its own scope wrapping the
            // whole loop (test/update/body all see it, but nothing
            // outside the loop does); a `var` init or plain
            // expression needs no extra scope.
            const needsScope = if (s.init) |i| i.data == .var_decl and i.data.var_decl.kind != .@"var" else false;
            if (needsScope) _ = try b.jsScopePushScope(.block);
            if (s.init) |i| {
                if (i.data == .var_decl) {
                    try jsScopeWalkVarDecl(b, i.data.var_decl);
                } else {
                    try jsScopeWalkExpr(b, i);
                }
            }
            if (s.test_) |t| try jsScopeWalkExpr(b, t);
            if (s.update) |u| try jsScopeWalkExpr(b, u);
            try jsScopeWalkStatement(b, s.body);
            if (needsScope) b.jsScopePopScope();
        },
        .for_in_of => |s| {
            const needsScope = s.left.data == .var_decl and s.left.data.var_decl.kind != .@"var";
            if (needsScope) _ = try b.jsScopePushScope(.block);
            if (s.left.data == .var_decl) {
                try jsScopeWalkVarDecl(b, s.left.data.var_decl);
            } else {
                try jsScopeWalkAssignmentTarget(b, s.left);
            }
            try jsScopeWalkExpr(b, s.right);
            try jsScopeWalkStatement(b, s.body);
            if (needsScope) b.jsScopePopScope();
        },
        .while_stmt => |s| {
            try jsScopeWalkExpr(b, s.test_);
            try jsScopeWalkStatement(b, s.body);
        },
        .do_while => |s| {
            try jsScopeWalkStatement(b, s.body);
            try jsScopeWalkExpr(b, s.test_);
        },
        .return_stmt => |arg| if (arg) |a| try jsScopeWalkExpr(b, a),
        .break_stmt, .continue_stmt => {}, // the label, if any, is not a reference
        .throw_stmt => |arg| try jsScopeWalkExpr(b, arg),
        .try_stmt => |s| {
            try jsScopeWalkStatement(b, s.block);
            if (s.catch_body) |cb| {
                _ = try b.jsScopePushScope(.block);
                if (s.catch_param) |param| try jsScopeWalkCatchParam(b, param);
                try jsScopeRegisterBlockLocalFunctions(b, cb.data.block.body, b.jsScopeCurrentScope());
                for (cb.data.block.body) |stmt| try jsScopeWalkStatement(b, stmt);
                b.jsScopePopScope();
            }
            if (s.finally_body) |fb| try jsScopeWalkStatement(b, fb);
        },
        .switch_stmt => |s| {
            try jsScopeWalkExpr(b, s.discriminant);
            _ = try b.jsScopePushScope(.block);
            for (s.cases) |c| try jsScopeRegisterBlockLocalFunctions(b, c.body, b.jsScopeCurrentScope());
            for (s.cases) |c| {
                if (c.test_) |t| try jsScopeWalkExpr(b, t);
                for (c.body) |stmt| try jsScopeWalkStatement(b, stmt);
            }
            b.jsScopePopScope();
        },
        .labeled_stmt => |s| try jsScopeWalkStatement(b, s.body),
        .function_decl => |f| try jsScopeWalkFunction(b, f, node),
        .class_decl => |c| try jsScopeWalkClass(b, c, node),
        .with_stmt => |s| {
            try jsScopeWalkExpr(b, s.object);
            const withScope = try b.jsScopePushScope(.block);
            b.tree.scopes.items[withScope].unsafeToMangle = true;
            try jsScopeWalkStatement(b, s.body);
            b.jsScopePopScope();
        },
        .empty_stmt, .debugger_stmt => {},
        else => try jsScopeWalkExpr(b, node), // a stray expression node used as a statement body
    }
}

fn jsScopeWalkVarDecl(b: *JsScopeBuilder, vd: parser.JsAstVarDecl) JsScopeWalkError!void {
    // `var` names were already recorded by the hoisting pre-pass;
    // `let`/`const` are block-scoped and recorded here, at the point
    // they're actually reached, since TDZ ordering isn't this pass's
    // concern - only which scope owns the name.
    for (vd.declarators) |d| {
        if (vd.kind != .@"var") {
            try jsScopeDeclareBindingTarget(b, d.id, if (vd.kind == .@"let") .@"let" else .@"const", b.jsScopeCurrentScope());
        }
        if (d.init) |init_| try jsScopeWalkExpr(b, init_);
    }
}

fn jsScopeDeclareBindingTarget(b: *JsScopeBuilder, node: *JsAstNode, kind: JsScopeDeclKind, target: JsScopeId) JsScopeWalkError!void {
    switch (node.data) {
        .identifier => |name| try b.jsScopeAddDecl(target, name, kind, node),
        .pattern => |p| {
            for (p.properties) |prop| {
                if (prop.computed_key) |ck| try jsScopeWalkExpr(b, ck);
                if (prop.value) |v| try jsScopeDeclareBindingTarget(b, v, kind, target);
                if (prop.default) |def| try jsScopeWalkExpr(b, def);
            }
            if (p.rest) |r| try jsScopeDeclareBindingTarget(b, r, kind, target);
        },
        else => {},
    }
}

fn jsScopeWalkCatchParam(b: *JsScopeBuilder, node: *JsAstNode) JsScopeWalkError!void {
    try jsScopeDeclareBindingTarget(b, node, .catch_param, b.jsScopeCurrentScope());
}

// Walks an already-parsed expression that sits in assignment-target
// position (a `for-in`/`for-of` left-hand side with no declaration
// keyword, or the left side of `a = b`) - binds each identifier as a
// reference to an existing declaration rather than a new declaration.
fn jsScopeWalkAssignmentTarget(b: *JsScopeBuilder, node: *JsAstNode) JsScopeWalkError!void {
    switch (node.data) {
        .identifier => |name| try b.jsScopeAddReference(name, node),
        .pattern => |p| {
            for (p.properties) |prop| {
                if (prop.computed_key) |ck| try jsScopeWalkExpr(b, ck);
                if (prop.value) |v| try jsScopeWalkAssignmentTarget(b, v);
                if (prop.default) |def| try jsScopeWalkExpr(b, def);
            }
            if (p.rest) |r| try jsScopeWalkAssignmentTarget(b, r);
        },
        else => try jsScopeWalkExpr(b, node),
    }
}

fn jsScopeWalkFunction(b: *JsScopeBuilder, f: parser.JsAstFunction, declNode: *JsAstNode) JsScopeWalkError!void {
    // The declaration name itself was already hoisted into the
    // enclosing scope by jsScopeHoistStatement/jsScopeHoistBlockBody; a named
    // function *expression*'s name is handled separately in
    // jsScopeWalkExpr, since it's visible only inside its own body.
    _ = declNode;
    const fnScope = try b.jsScopePushScope(.function);
    for (f.params) |param| try jsScopeDeclareParam(b, param);
    _ = try b.jsScopePushScope(.block);
    try jsScopeHoistBlockBody(b, f.body.data.block.body, fnScope);
    for (f.body.data.block.body) |stmt| try jsScopeWalkStatement(b, stmt);
    b.jsScopePopScope();
    b.jsScopePopScope();
}

// A parameter is either a bare binding target, or an `assignment`
// node (`op = "="`) wrapping one with a default value - see
// `parseParamList`'s own doc comment in js_parser.zig for why there's
// no separate "default parameter" AST shape.
fn jsScopeDeclareParam(b: *JsScopeBuilder, node: *JsAstNode) JsScopeWalkError!void {
    switch (node.data) {
        .assignment => |a| {
            try jsScopeDeclareBindingTarget(b, a.left, .param, b.jsScopeCurrentScope());
            try jsScopeWalkExpr(b, a.right);
        },
        .spread => |target| try jsScopeDeclareBindingTarget(b, target, .param, b.jsScopeCurrentScope()),
        else => try jsScopeDeclareBindingTarget(b, node, .param, b.jsScopeCurrentScope()),
    }
}

fn jsScopeWalkClass(b: *JsScopeBuilder, c: parser.JsAstClass, declNode: *JsAstNode) JsScopeWalkError!void {
    // Same hoisting split as jsScopeWalkFunction: a class *declaration*'s
    // name was already recorded by the caller for non-hoisting
    // declaration kinds - class isn't var-hoisted, so it's declared
    // here instead, in the current (not enclosing-function) scope.
    if (c.name) |name| try b.jsScopeAddDecl(b.jsScopeCurrentScope(), name, .class, declNode);
    if (c.super_class) |sc| try jsScopeWalkExpr(b, sc);
    _ = try b.jsScopePushScope(.block);
    for (c.members) |member| try jsScopeWalkClassMember(b, member);
    b.jsScopePopScope();
}

fn jsScopeWalkClassMember(b: *JsScopeBuilder, member: parser.JsAstClassMember) JsScopeWalkError!void {
    if (member.computed_key) |ck| try jsScopeWalkExpr(b, ck);
    if (member.value) |f| {
        const fnScope = try b.jsScopePushScope(.function);
        for (f.params) |param| try jsScopeDeclareParam(b, param);
        _ = try b.jsScopePushScope(.block);
        try jsScopeHoistBlockBody(b, f.body.data.block.body, fnScope);
        for (f.body.data.block.body) |stmt| try jsScopeWalkStatement(b, stmt);
        b.jsScopePopScope();
        b.jsScopePopScope();
    }
    if (member.field_init) |init_| try jsScopeWalkExpr(b, init_);
}

fn jsScopeWalkExpr(b: *JsScopeBuilder, node: *JsAstNode) JsScopeWalkError!void {
    switch (node.data) {
        .identifier => |name| try b.jsScopeAddReference(name, node),
        .this_expr, .super_expr, .number_literal, .string_literal, .regex_literal, .boolean_literal, .null_literal => {},
        .template_literal => |t| for (t.expressions) |e| try jsScopeWalkExpr(b, e),
        .tagged_template => |t| {
            try jsScopeWalkExpr(b, t.tag);
            for (t.quasi.expressions) |e| try jsScopeWalkExpr(b, e);
        },
        .array_literal => |elements| {
            for (elements) |maybeEl| {
                if (maybeEl) |el| try jsScopeWalkExpr(b, el);
            }
        },
        .object_literal => |props| {
            for (props) |prop| {
                if (prop.computed_key) |ck| try jsScopeWalkExpr(b, ck);
                try jsScopeWalkExpr(b, prop.value);
            }
        },
        .spread => |arg| try jsScopeWalkExpr(b, arg),
        .function_expr => |f| {
            // A named function expression's own name is visible only
            // inside its own body - a fresh wrapping scope holds just
            // that one binding, mirroring how a real closure sees it.
            if (f.name != null) _ = try b.jsScopePushScope(.function);
            if (f.name) |name| try b.jsScopeAddDecl(b.jsScopeCurrentScope(), name, .function, node);
            try jsScopeWalkFunction(b, f, node);
            if (f.name != null) b.jsScopePopScope();
        },
        .arrow_function => |a| {
            const fnScope = try b.jsScopePushScope(.function);
            for (a.params) |param| try jsScopeDeclareParam(b, param);
            if (a.body.data == .block) {
                _ = try b.jsScopePushScope(.block);
                try jsScopeHoistBlockBody(b, a.body.data.block.body, fnScope);
                for (a.body.data.block.body) |stmt| try jsScopeWalkStatement(b, stmt);
                b.jsScopePopScope();
            } else {
                try jsScopeWalkExpr(b, a.body);
            }
            b.jsScopePopScope();
        },
        .class_expr => |c| try jsScopeWalkClass(b, c, node),
        .binary, .assignment, .logical => |bin| {
            if (node.data == .assignment) {
                try jsScopeWalkAssignmentTarget(b, bin.left);
            } else {
                try jsScopeWalkExpr(b, bin.left);
            }
            try jsScopeWalkExpr(b, bin.right);
        },
        .unary, .update => |u| try jsScopeWalkExpr(b, u.argument),
        .conditional => |c| {
            try jsScopeWalkExpr(b, c.test_);
            try jsScopeWalkExpr(b, c.consequent);
            try jsScopeWalkExpr(b, c.alternate);
        },
        .call, .new_expr => |c| {
            try jsScopeWalkExpr(b, c.callee);
            for (c.arguments) |arg| try jsScopeWalkExpr(b, arg);
        },
        .member => |m| try jsScopeWalkExpr(b, m.object),
        .computed_member => |m| {
            try jsScopeWalkExpr(b, m.object);
            try jsScopeWalkExpr(b, m.property);
        },
        .paren => |inner| try jsScopeWalkExpr(b, inner),
        .sequence => |items| for (items) |item| try jsScopeWalkExpr(b, item),
        .yield_expr => |y| if (y.argument) |a| try jsScopeWalkExpr(b, a),
        .await_expr => |arg| try jsScopeWalkExpr(b, arg),
        .pattern => try jsScopeWalkAssignmentTarget(b, node),
        else => {}, // statement-shaped Data reached from expression position: nothing to do
    }
}

/// JsAstFor every recorded JsScopeReference, walks outward through parent scopes
/// for a matching decl name. Innermost match wins.
pub fn resolveReferences(tree: *JsScopeTree) void {
    for (tree.references.items) |*ref| {
        var scopeId: ?JsScopeId = ref.fromScope;
        while (scopeId) |id| {
            const s = &tree.scopes.items[id];
            var idx = s.decls.items.len;
            while (idx > 0) {
                idx -= 1;
                if (std.mem.eql(u8, s.decls.items[idx].name, ref.name)) {
                    ref.resolvedScope = id;
                    ref.resolvedDeclIndex = idx;
                    break;
                }
            }
            if (ref.resolvedScope != null) break;
            scopeId = s.parent;
        }
    }
}

// Generates short identifier names in order: a, b, c, ..., z, A, B,
// ..., Z, $, _, aa, ab, ... increasing length, shortest first.
const jsMangleShortNameAlphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ$_";
// Digits are legal in a JS identifier after the first character, and
// are included in the pool once the single-character alphabet above
// is exhausted, but never as the first character of a generated name.
const jsMangleShortNameDigits = "0123456789";

fn jsMangleNthShortName(allocator: std.mem.Allocator, n: usize) ![]u8 {
    const firstAlphabetLen = jsMangleShortNameAlphabet.len;
    const contAlphabetLen = jsMangleShortNameAlphabet.len + jsMangleShortNameDigits.len;

    // Dense base-firstAlphabetLen for the first character,
    // base-contAlphabetLen after, enumerated in increasing length.
    var remaining = n;
    var length: usize = 1;
    var levelSize: usize = firstAlphabetLen;
    while (remaining >= levelSize) {
        remaining -= levelSize;
        length += 1;
        levelSize = firstAlphabetLen * std.math.pow(usize, contAlphabetLen, length - 1);
    }

    var buf = try allocator.alloc(u8, length);
    errdefer allocator.free(buf);

    // Decode digit-by-digit, least significant (last char) first.
    var idx = remaining;
    var pos = length;
    while (pos > 1) {
        pos -= 1;
        const d = idx % contAlphabetLen;
        buf[pos] = if (d < firstAlphabetLen) jsMangleShortNameAlphabet[d] else jsMangleShortNameDigits[d - firstAlphabetLen];
        idx /= contAlphabetLen;
    }
    buf[0] = jsMangleShortNameAlphabet[idx % firstAlphabetLen];

    return buf;
}

const JsMangleNameSet = std.StringHashMap(void);

// (scopeId, declIndex) identifies one decl uniquely across the tree.
const JsMangleDeclKey = struct { scopeId: JsScopeId, declIndex: usize };
const JsMangleDeclSet = std.AutoHashMap(JsMangleDeclKey, void);

// Short names already in use for a scope: its own in-progress decls
// plus every short name visible from any ancestor.
fn jsMangleCollectVisibleNames(tree: *const JsScopeTree, scopeId: JsScopeId, out: *JsMangleNameSet) !void {
    var current: ?JsScopeId = scopeId;
    while (current) |id| {
        for (tree.scopes.items[id].decls.items) |d| {
            if (d.shortName.len > 0) {
                try out.put(d.shortName, {});
            }
        }
        current = tree.scopes.items[id].parent;
    }
}

/// Assigns `shortName` on every `JsScopeDecl` in `tree`, walking scopes
/// top-down so a child scope already knows every name its ancestors
/// used. Reserved words, names in `reserved`, and unresolved globals
/// are skipped as candidates. Decls whose original name is in
/// `protect` are left unmangled entirely, as is any decl reachable
/// from inside a `with` (its own scope, or referenced from one - see
/// `JsScope.unsafeToMangle`). Within each scope, decls are assigned
/// in descending order of reference count so the most-referenced
/// binding gets the shortest available name. Pass a `JsScopeId` for
/// `skipScope` (typically `0`, the global scope) to leave that one
/// scope's own decls unmangled while still mangling everything
/// nested inside it; pass `null` to mangle every scope.
pub fn jsMangleAssignShortNames(allocator: std.mem.Allocator, tree: *JsScopeTree, reserved: []const []const u8, protect: []const []const u8, skipScope: ?JsScopeId) !void {
    var globals = JsMangleNameSet.init(allocator);
    defer globals.deinit();
    try jsMangleCollectUnresolvedGlobalNames(tree, &globals);

    var withReached = JsMangleDeclSet.init(allocator);
    defer withReached.deinit();
    try jsMangleCollectWithReachedDecls(tree, &withReached);

    const refCounts = try jsMangleCountReferencesPerDecl(allocator, tree);
    defer jsMangleFreeCountsPerDecl(allocator, refCounts);

    try jsMangleAssignShortNamesRec(allocator, tree, 0, reserved, protect, skipScope, &globals, &withReached, refCounts);
}

fn jsMangleIsProtected(name: []const u8, protect: []const []const u8) bool {
    for (protect) |p| {
        if (std.mem.eql(u8, name, p)) return true;
    }
    return false;
}

// Every distinct name referenced but never resolved to a declaration -
// a real global, or one declared in a different <script> tag. A
// generated short name that collides with one would break the file.
fn jsMangleCollectUnresolvedGlobalNames(tree: *const JsScopeTree, out: *JsMangleNameSet) !void {
    for (tree.references.items) |r| {
        if (r.resolvedScope == null) {
            try out.put(r.name, {});
        }
    }
}

// Every decl that must not be renamed because a `with` statement
// could shadow it at runtime: one declared inside `with`'s own body
// scope (or nested inside it), or one declared outside but referenced
// from inside such a scope - a rename would still change behavior
// there if the `with` object happens to have a same-named property.
fn jsMangleCollectWithReachedDecls(tree: *const JsScopeTree, out: *JsMangleDeclSet) !void {
    for (tree.scopes.items, 0..) |s, scopeId| {
        if (!s.unsafeToMangle) continue;
        for (0..s.decls.items.len) |declIndex| {
            try out.put(.{ .scopeId = scopeId, .declIndex = declIndex }, {});
        }
    }
    for (tree.references.items) |r| {
        if (r.resolvedScope) |sid| {
            if (tree.scopes.items[r.fromScope].unsafeToMangle) {
                try out.put(.{ .scopeId = sid, .declIndex = r.resolvedDeclIndex.? }, {});
            }
        }
    }
}

// For each scope, a decls-length slice of reference counts, indexed
// the same way JsScope.decls is. Freed via jsMangleFreeCountsPerDecl.
fn jsMangleCountReferencesPerDecl(allocator: std.mem.Allocator, tree: *const JsScopeTree) ![][]usize {
    const perScope = try allocator.alloc([]usize, tree.scopes.items.len);
    var filled: usize = 0;
    errdefer {
        for (perScope[0..filled]) |s| allocator.free(s);
        allocator.free(perScope);
    }
    for (tree.scopes.items, 0..) |s, i| {
        const counts = try allocator.alloc(usize, s.decls.items.len);
        @memset(counts, 0);
        perScope[i] = counts;
        filled += 1;
    }
    for (tree.references.items) |r| {
        if (r.resolvedScope) |sid| {
            perScope[sid][r.resolvedDeclIndex.?] += 1;
        }
    }
    return perScope;
}

fn jsMangleFreeCountsPerDecl(allocator: std.mem.Allocator, counts: [][]usize) void {
    for (counts) |c| allocator.free(c);
    allocator.free(counts);
}

// Builds the order (a permutation of 0..declCount) in which a scope's
// decls should be assigned short names: descending by reference
// count, ties broken by original index.
fn jsMangleBuildAssignmentOrder(allocator: std.mem.Allocator, counts: []const usize) ![]usize {
    const order = try allocator.alloc(usize, counts.len);
    for (order, 0..) |*o, i| o.* = i;

    // Manual insertion sort rather than std.sort.*: counts.len is
    // always small.
    var i: usize = 1;
    while (i < order.len) : (i += 1) {
        const key = order[i];
        const keyCount = counts[key];
        var j: usize = i;
        while (j > 0 and counts[order[j - 1]] < keyCount) : (j -= 1) {
            order[j] = order[j - 1];
        }
        order[j] = key;
    }
    return order;
}

fn jsMangleAssignShortNamesRec(allocator: std.mem.Allocator, tree: *JsScopeTree, scopeId: JsScopeId, reserved: []const []const u8, protect: []const []const u8, skipScope: ?JsScopeId, globals: *const JsMangleNameSet, withReached: *const JsMangleDeclSet, refCounts: [][]usize) !void {
    if (skipScope == null or skipScope.? != scopeId) {
        var visible = JsMangleNameSet.init(allocator);
        defer visible.deinit();
        try jsMangleCollectVisibleNames(tree, scopeId, &visible);

        const decls = tree.scopes.items[scopeId].decls.items;
        const order = try jsMangleBuildAssignmentOrder(allocator, refCounts[scopeId]);
        defer allocator.free(order);

        for (order) |declIdx| {
            const d = &decls[declIdx];
            if (jsMangleIsProtected(d.name, protect)) continue;
            if (withReached.contains(.{ .scopeId = scopeId, .declIndex = declIdx })) continue;
            var n: usize = 0;
            while (true) {
                const candidate = try jsMangleNthShortName(allocator, n);
                if (jsMangleIsNameUsable(candidate, &visible, reserved, globals)) {
                    d.shortName = candidate;
                    try visible.put(candidate, {});
                    break;
                }
                allocator.free(candidate);
                n += 1;
            }
        }
    }

    for (tree.scopes.items[scopeId].children.items) |childId| {
        try jsMangleAssignShortNamesRec(allocator, tree, childId, reserved, protect, skipScope, globals, withReached, refCounts);
    }
}

fn jsMangleIsNameUsable(name: []const u8, visible: *const JsMangleNameSet, reserved: []const []const u8, globals: *const JsMangleNameSet) bool {
    if (parser.jsIsReservedWord(name)) return false;
    for (reserved) |r| {
        if (std.mem.eql(u8, name, r)) return false;
    }
    if (visible.contains(name)) return false;
    if (globals.contains(name)) return false;
    return true;
}

/// Walks `program` and every nested statement list, merging runs of
/// adjacent `expr_stmt`s in place. Allocates any new/resized node
/// lists from `allocator`, which must be the same arena the tree
/// itself was parsed into (merged nodes are never freed separately).
pub fn jsJoinStatements(allocator: std.mem.Allocator, program: *JsAstProgram) std.mem.Allocator.Error!void {
    program.body = try jsJoinList(allocator, program.body, true);
    for (program.body) |stmt| try jsJoinNode(allocator, stmt);
}

fn jsJoinNode(allocator: std.mem.Allocator, node: *JsAstNode) std.mem.Allocator.Error!void {
    switch (node.data) {
        .block => |*b| {
            b.body = try jsJoinList(allocator, b.body, false);
            for (b.body) |stmt| try jsJoinNode(allocator, stmt);
        },
        .var_decl => |vd| {
            for (vd.declarators) |d| if (d.init) |init_| try jsJoinNode(allocator, init_);
        },
        .expr_stmt => |e| try jsJoinNode(allocator, e),
        .if_stmt => |s| {
            try jsJoinNode(allocator, s.test_);
            try jsJoinNode(allocator, s.consequent);
            if (s.alternate) |a| try jsJoinNode(allocator, a);
        },
        .for_stmt => |s| {
            if (s.init) |i| try jsJoinNode(allocator, i);
            if (s.test_) |t| try jsJoinNode(allocator, t);
            if (s.update) |u| try jsJoinNode(allocator, u);
            try jsJoinNode(allocator, s.body);
        },
        .for_in_of => |s| {
            try jsJoinNode(allocator, s.left);
            try jsJoinNode(allocator, s.right);
            try jsJoinNode(allocator, s.body);
        },
        .while_stmt => |s| {
            try jsJoinNode(allocator, s.test_);
            try jsJoinNode(allocator, s.body);
        },
        .do_while => |s| {
            try jsJoinNode(allocator, s.body);
            try jsJoinNode(allocator, s.test_);
        },
        .return_stmt => |arg| if (arg) |a| try jsJoinNode(allocator, a),
        .throw_stmt => |a| try jsJoinNode(allocator, a),
        .try_stmt => |s| {
            try jsJoinNode(allocator, s.block);
            if (s.catch_body) |c| try jsJoinNode(allocator, c);
            if (s.finally_body) |f| try jsJoinNode(allocator, f);
        },
        .switch_stmt => |*s| {
            try jsJoinNode(allocator, s.discriminant);
            const newCases = try allocator.alloc(parser.JsAstCase, s.cases.len);
            for (s.cases, 0..) |c, i| {
                const newBody = try jsJoinList(allocator, c.body, false);
                for (newBody) |stmt| try jsJoinNode(allocator, stmt);
                newCases[i] = .{ .test_ = c.test_, .body = newBody };
            }
            s.cases = newCases;
        },
        .labeled_stmt => |s| try jsJoinNode(allocator, s.body),
        .function_decl, .function_expr => |f| try jsJoinNode(allocator, f.body),
        .class_decl, .class_expr => |c| try jsJoinClass(allocator, c),
        .with_stmt => |s| {
            try jsJoinNode(allocator, s.object);
            try jsJoinNode(allocator, s.body);
        },
        .array_literal => |elems| for (elems) |el| if (el) |e| try jsJoinNode(allocator, e),
        .object_literal => |props| for (props) |p| {
            if (p.computed_key) |ck| try jsJoinNode(allocator, ck);
            try jsJoinNode(allocator, p.value);
        },
        .spread => |a| try jsJoinNode(allocator, a),
        .arrow_function => |f| try jsJoinNode(allocator, f.body),
        .binary, .assignment, .logical => |b| {
            try jsJoinNode(allocator, b.left);
            try jsJoinNode(allocator, b.right);
        },
        .unary, .update => |u| try jsJoinNode(allocator, u.argument),
        .conditional => |c| {
            try jsJoinNode(allocator, c.test_);
            try jsJoinNode(allocator, c.consequent);
            try jsJoinNode(allocator, c.alternate);
        },
        .call, .new_expr => |c| {
            try jsJoinNode(allocator, c.callee);
            for (c.arguments) |a| try jsJoinNode(allocator, a);
        },
        .member => |m| try jsJoinNode(allocator, m.object),
        .computed_member => |m| {
            try jsJoinNode(allocator, m.object);
            try jsJoinNode(allocator, m.property);
        },
        .paren => |inner| try jsJoinNode(allocator, inner),
        .sequence => |items| for (items) |i| try jsJoinNode(allocator, i),
        .yield_expr => |y| if (y.argument) |a| try jsJoinNode(allocator, a),
        .await_expr => |a| try jsJoinNode(allocator, a),
        .template_literal => |t| for (t.expressions) |e| try jsJoinNode(allocator, e),
        .tagged_template => |t| {
            try jsJoinNode(allocator, t.tag);
            for (t.quasi.expressions) |e| try jsJoinNode(allocator, e);
        },
        else => {},
    }
}

fn jsJoinClass(allocator: std.mem.Allocator, c: parser.JsAstClass) std.mem.Allocator.Error!void {
    if (c.super_class) |sc| try jsJoinNode(allocator, sc);
    for (c.members) |m| {
        if (m.computed_key) |ck| try jsJoinNode(allocator, ck);
        if (m.field_init) |fi| try jsJoinNode(allocator, fi);
        if (m.value) |f| try jsJoinNode(allocator, f.body);
    }
}

// A directive-prologue string literal (`"use strict"` and similar) is
// only meaningful as its own leading statement; folding it into a
// sequence turns it into a plain evaluated expression and silently
// drops the directive. The prologue can be more than one such
// statement in a row, so every leading bare string-literal statement
// is protected, not just the first.
fn jsIsDirectivePrologueCandidate(node: *const JsAstNode) bool {
    return node.data == .string_literal;
}

// Whether `expr_stmt` node `n` is a plain expression statement, i.e.
// the only shape the comma operator can combine.
fn jsIsExprStmt(n: *const JsAstNode) bool {
    return n.data == .expr_stmt;
}

// Rebuilds `body` with every maximal run of adjacent, joinable
// `expr_stmt`s collapsed into one `expr_stmt` wrapping a `sequence`.
// A run of length 1 is left as-is (nothing to gain). `topLevel`
// marks a program/function body, where a leading run of
// directive-prologue string statements is left untouched entirely,
// since folding any of them into a sequence would drop its directive
// meaning; an ordinary block has no such position, since a directive
// is only recognized at the very start of a program or function
// body.
fn jsJoinList(allocator: std.mem.Allocator, body: []const *JsAstNode, topLevel: bool) std.mem.Allocator.Error![]const *JsAstNode {
    var out: std.ArrayList(*JsAstNode) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    if (topLevel) {
        while (i < body.len and jsIsExprStmt(body[i]) and jsIsDirectivePrologueCandidate(body[i].data.expr_stmt)) : (i += 1) {
            try out.append(allocator, body[i]);
        }
    }

    while (i < body.len) {
        if (!jsIsExprStmt(body[i])) {
            try out.append(allocator, body[i]);
            i += 1;
            continue;
        }

        var runEnd = i + 1;
        while (runEnd < body.len and jsIsExprStmt(body[runEnd])) runEnd += 1;

        if (runEnd - i < 2) {
            try out.append(allocator, body[i]);
            i = runEnd;
            continue;
        }

        try out.append(allocator, try jsMergeRun(allocator, body[i..runEnd]));
        i = runEnd;
    }

    return out.toOwnedSlice(allocator);
}

// Combines a run of `expr_stmt` nodes into a single `expr_stmt`
// wrapping a flat `sequence` (a `sequence` inside a `sequence` would
// print correctly but needlessly nests, so a joinable member that's
// itself already a bare `sequence` expression is spliced in flat
// rather than nested one level deeper).
fn jsMergeRun(allocator: std.mem.Allocator, run: []const *JsAstNode) std.mem.Allocator.Error!*JsAstNode {
    var items: std.ArrayList(*JsAstNode) = .empty;
    errdefer items.deinit(allocator);

    for (run) |stmt| {
        const e = stmt.data.expr_stmt;
        if (e.data == .sequence) {
            try items.appendSlice(allocator, e.data.sequence);
        } else {
            try items.append(allocator, e);
        }
    }

    const seq = try allocator.create(JsAstNode);
    seq.* = .{ .loc = run[0].loc, .data = .{ .sequence = try items.toOwnedSlice(allocator) } };

    const stmt = try allocator.create(JsAstNode);
    stmt.* = .{ .loc = run[0].loc, .data = .{ .expr_stmt = seq } };
    return stmt;
}

const JsPrintRenameMap = std.AutoHashMap(*const JsAstNode, []const u8);
const JsPrintResolvedSet = std.AutoHashMap(*const JsAstNode, void);

const JsPrintError = std.mem.Allocator.Error;

/// Builds the `*JsAstNode -> shortName` lookup a `JsPrinter` substitutes
/// from: every `JsScopeDecl` whose binding site is an `identifier` JsAstNode
/// (`var`/`let`/`const`/`param`/`catch_param`), every `JsScopeReference`
/// resolved to a `shortName`-bearing decl, and every `function`/
/// `class`-kind decl (whose binding site is the declaration/
/// expression JsAstNode itself, not a separate identifier).
fn jsPrintBuildRenameMap(allocator: std.mem.Allocator, tree: *const JsScopeTree) JsPrintError!JsPrintRenameMap {
    var map = JsPrintRenameMap.init(allocator);
    errdefer map.deinit();

    for (tree.scopes.items) |s| {
        for (s.decls.items) |d| {
            if (d.shortName.len > 0) try map.put(d.node, d.shortName);
        }
    }
    for (tree.references.items) |r| {
        if (r.resolvedScope) |sid| {
            const d = tree.scopes.items[sid].decls.items[r.resolvedDeclIndex.?];
            if (d.shortName.len > 0) try map.put(r.node, d.shortName);
        }
    }
    return map;
}

// The set of identifier reference nodes known to resolve to an
// actual binding this pass tracked (a `var`/`let`/`const`/param/
// function/class/catch-param declared somewhere in the program) -
// as opposed to a genuine global or a name this pass couldn't trace
// (e.g. a different `<script>`'s declaration). Used to gate the
// `typeof x === "undefined"` -> `x === void 0` rewrite: that rewrite
// changes an undeclared `x` from "safely evaluates to `undefined`"
// to "throws a ReferenceError", so it's only safe applied to a name
// with a real, resolved binding.
fn jsPrintBuildResolvedSet(allocator: std.mem.Allocator, tree: *const JsScopeTree) JsPrintError!JsPrintResolvedSet {
    var set = JsPrintResolvedSet.init(allocator);
    errdefer set.deinit();

    for (tree.references.items) |r| {
        if (r.resolvedScope != null) try set.put(r.node, {});
    }
    return set;
}

/// Prints `program` as minified text, substituting any renamed
/// identifiers found in `tree`. `tree` must have been built from
/// `program` itself (so its `*JsAstNode` keys are found by identity).
pub fn jsPrint(allocator: std.mem.Allocator, program: *const JsAstProgram, tree: *const JsScopeTree) JsPrintError![]u8 {
    var renames = try jsPrintBuildRenameMap(allocator, tree);
    defer renames.deinit();
    var resolved = try jsPrintBuildResolvedSet(allocator, tree);
    defer resolved.deinit();

    var p = JsPrinter{ .allocator = allocator, .renames = &renames, .resolved = &resolved, .out = .empty };
    errdefer p.out.deinit(allocator);

    var lastDroppable = false;
    for (program.body) |stmt| lastDroppable = try p.jsPrintStatement(stmt);
    if (lastDroppable) jsPrintTrimTrailingSemi(&p.out); // no statement follows the last one

    return p.out.toOwnedSlice(allocator);
}

// Drops a single trailing `;` if `out` currently ends with one - used
// wherever a `;` was just written but turns out to have nothing after
// it to separate from (immediately before a block's closing `}`, or
// at the very end of the whole program). Matches the same trim
// `css.zig` already does before its own `}`.
fn jsPrintTrimTrailingSemi(out: *std.ArrayList(u8)) void {
    if (out.items.len > 0 and out.items[out.items.len - 1] == ';') {
        _ = out.pop();
    }
}

const JsPrinter = struct {
    allocator: std.mem.Allocator,
    renames: *const JsPrintRenameMap,
    resolved: *const JsPrintResolvedSet,
    out: std.ArrayList(u8),

    // Emits `text` verbatim, first inserting a single space if
    // omitting one would let `text`'s first byte merge with the
    // previously emitted byte into something that re-lexes
    // differently (two identifier/digit runs fusing into one, or two
    // punctuation characters completing a longer real operator).
    fn jsPrintWrite(self: *JsPrinter, text: []const u8) JsPrintError!void {
        if (text.len == 0) return;
        if (self.out.items.len > 0 and jsPrintNeedsSeparator(self.out.items[self.out.items.len - 1], text[0])) {
            try self.out.append(self.allocator, ' ');
        }
        try self.out.appendSlice(self.allocator, text);
    }

    // A `/regex/` literal's leading `/` is ordinary punctuation as
    // far as `jsPrintWrite`'s general separator rule is concerned - unlike a
    // binary division operator's `/`, though, an identifier
    // immediately before it (`return/x/`) is genuinely ambiguous with
    // division on the page, even though this parse tree already
    // disambiguated it. Force the space so the output isn't
    // misleading to read or to any other tool that re-lexes it.
    fn jsPrintWriteRegex(self: *JsPrinter, text: []const u8) JsPrintError!void {
        if (self.out.items.len > 0 and jsPrintIsIdentByte(self.out.items[self.out.items.len - 1])) {
            try self.out.append(self.allocator, ' ');
        }
        try self.out.appendSlice(self.allocator, text);
    }

    // Prints a string literal's raw source text (`t`, including its
    // surrounding quotes) after normalizing to whichever quote
    // character needs fewer escapes for this particular content -
    // `'it\'s'` -> `"it's"`, and the reverse when double quotes are
    // the ones that occur more often inside. A tie (including the
    // common case of no quote characters in the content at all)
    // always prefers `"` - standardizing on one quote character
    // across the whole file gives a downstream gzip pass more
    // repeated bytes to exploit than leaving a mix of `'` and `"` in
    // place. Every other escape sequence (`\n`, `\\`, `\u{...}`, etc.)
    // is left completely untouched - only the two quote characters
    // ever get escaped or unescaped, so this needs no real
    // string-literal decoding.
    fn jsPrintStringLiteral(self: *JsPrinter, t: []const u8) JsPrintError!void {
        if (t.len < 2) return self.jsPrintWrite(t);
        const originalQuote = t[0];
        if ((originalQuote != '\'' and originalQuote != '"') or t[t.len - 1] != originalQuote) {
            return self.jsPrintWrite(t);
        }
        const inner = t[1 .. t.len - 1];

        var singleCount: usize = 0;
        var doubleCount: usize = 0;
        var i: usize = 0;
        while (i < inner.len) {
            const c = inner[i];
            if (c == '\\' and i + 1 < inner.len) {
                // A quote character right after a backslash is
                // already escaped in the source; it's still counted
                // here since escaped-ness only affects how the
                // rewrite loop below handles it, not which delimiter
                // would need fewer total escapes.
                const escaped = inner[i + 1];
                if (escaped == '\'') singleCount += 1;
                if (escaped == '"') doubleCount += 1;
                i += 2;
                continue;
            }
            if (c == '\'') singleCount += 1;
            if (c == '"') doubleCount += 1;
            i += 1;
        }

        // The delimiter with fewer occurrences in the content needs
        // fewer escapes; a tie always prefers `"` regardless of the
        // literal's original delimiter, since raw byte count is
        // identical either way.
        const newQuote: u8 = if (singleCount == doubleCount)
            '"'
        else if (doubleCount < singleCount)
            '"'
        else
            '\'';
        if (newQuote == originalQuote) return self.jsPrintWrite(t);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        try out.append(self.allocator, newQuote);
        i = 0;
        while (i < inner.len) {
            const c = inner[i];
            if (c == '\\' and i + 1 < inner.len) {
                // An existing escape for the *old* delimiter is no
                // longer needed once it's no longer the delimiter;
                // any other escape (including one for the new
                // delimiter, which must stay escaped) passes through
                // unchanged.
                if (inner[i + 1] == originalQuote) {
                    try out.append(self.allocator, originalQuote);
                } else {
                    try out.appendSlice(self.allocator, inner[i .. i + 2]);
                }
                i += 2;
                continue;
            }
            if (c == newQuote) {
                try out.append(self.allocator, '\\');
            }
            try out.append(self.allocator, c);
            i += 1;
        }
        try out.append(self.allocator, newQuote);
        try self.jsPrintWrite(out.items);
    }

    // An `identifier` JsAstNode's text: its declaration/reference site's
    // assigned shortName if one was recorded, else the original name.
    fn jsPrintIdentText(self: *const JsPrinter, node: *const JsAstNode, name: []const u8) []const u8 {
        return self.renames.get(node) orelse name;
    }

    fn jsPrintNameFor(self: *const JsPrinter, declNode: *const JsAstNode, name: []const u8) []const u8 {
        return self.renames.get(declNode) orelse name;
    }

    // Prints one statement from a statement list (a block's body, or
    // the top-level program body) and reports whether the byte it
    // just wrote is a `;` that's safe for the caller to drop if
    // nothing follows in the list. True for any statement whose own
    // printed form ends directly in a redundant terminator `;`
    // (`var_decl`, `expr_stmt`, `return`, etc., and - via
    // `jsPrintLoopBody`'s guard - a `for`/`while`/labeled/`with`
    // statement whose single-statement body itself ended that way).
    // False whenever the last byte written is instead a `}` (a block,
    // function, class, try, switch), or a `;` that's the entire
    // content of a mandatory body slot rather than a terminator on
    // something else (a bare `for(;;);`).
    fn jsPrintStatement(self: *JsPrinter, node: *JsAstNode) JsPrintError!bool {
        switch (node.data) {
            .block => |b| {
                try self.jsPrintBlock(b);
                return false;
            },
            .var_decl => |vd| {
                try self.jsPrintVarDecl(vd);
                try self.jsPrintWrite(";");
                return true;
            },
            .expr_stmt => |e| {
                try self.jsPrintExprStmtLead(e);
                try self.jsPrintWrite(";");
                return true;
            },
            .if_stmt => |s| {
                return try self.jsPrintIf(s);
            },
            .for_stmt => |s| {
                return try self.jsPrintFor(s);
            },
            .for_in_of => |s| {
                return try self.jsPrintForInOf(s);
            },
            .while_stmt => |s| {
                try self.jsPrintWrite("while");
                try self.jsPrintWrite("(");
                try self.jsPrintExpr(s.test_);
                try self.jsPrintWrite(")");
                return try self.jsPrintLoopBody(s.body);
            },
            .do_while => |s| {
                try self.jsPrintWrite("do");
                _ = try self.jsPrintLoopBody(s.body);
                try self.jsPrintWrite("while");
                try self.jsPrintWrite("(");
                try self.jsPrintExpr(s.test_);
                try self.jsPrintWrite(")");
                try self.jsPrintWrite(";");
                return true;
            },
            .return_stmt => |arg| {
                try self.jsPrintWrite("return");
                if (arg) |a| try self.jsPrintExpr(a);
                try self.jsPrintWrite(";");
                return true;
            },
            .break_stmt => |label| {
                try self.jsPrintWrite("break");
                if (label) |l| try self.jsPrintWrite(l);
                try self.jsPrintWrite(";");
                return true;
            },
            .continue_stmt => |label| {
                try self.jsPrintWrite("continue");
                if (label) |l| try self.jsPrintWrite(l);
                try self.jsPrintWrite(";");
                return true;
            },
            .throw_stmt => |arg| {
                try self.jsPrintWrite("throw");
                try self.jsPrintExpr(arg);
                try self.jsPrintWrite(";");
                return true;
            },
            .try_stmt => |s| {
                try self.jsPrintTry(s);
                return false;
            },
            .switch_stmt => |s| {
                try self.jsPrintSwitch(s);
                return false;
            },
            .labeled_stmt => |s| {
                try self.jsPrintWrite(s.label);
                try self.jsPrintWrite(":");
                return try self.jsPrintLoopBody(s.body);
            },
            .function_decl => |f| {
                try self.jsPrintFunction(f, node);
                return false;
            },
            .class_decl => |c| {
                try self.jsPrintClass(c, node);
                return false;
            },
            .empty_stmt => {
                try self.jsPrintWrite(";");
                // This `;` IS the statement (an explicit no-op), not a
                // terminator attached to some other content. Reporting
                // `true` here is only safe because every single-
                // statement body slot (`for(...)<body>`,
                // `while(...)<body>`, a label's `<label>:<body>`)
                // routes through `jsPrintLoopBody`, which specifically
                // re-checks `body.data != .empty_stmt` before
                // forwarding this `true` any further - so a bare `;`
                // serving as `for(;;);`'s mandatory body is never
                // mistaken there for a droppable, redundant one. A
                // block's statement list (`jsPrintBlock`) has no such
                // override, so a genuinely redundant stray `;` at the
                // end of a block IS dropped, as intended.
                return true;
            },
            .debugger_stmt => return false, // stripped entirely - no debug-time behavior to preserve in minified output; body-required positions substitute their own `;` (see jsPrintBodyStatement)
            .with_stmt => |s| {
                try self.jsPrintWrite("with");
                try self.jsPrintWrite("(");
                try self.jsPrintExpr(s.object);
                try self.jsPrintWrite(")");
                return try self.jsPrintLoopBody(s.body);
            },
            else => {
                // A stray expression-shaped JsAstNode used directly as a
                // statement body.
                try self.jsPrintExprStmtLead(node);
                try self.jsPrintWrite(";");
                return true;
            },
        }
    }

    // Prints a single-statement body slot (`for(...)<here>`,
    // `while(...)<here>`, `with(...)<here>`, `if(...)<here>`, a
    // label's `<label>:<here>`) and reports whether its trailing `;`,
    // if any, is safe for an enclosing list to drop when nothing
    // follows. A bare `empty_stmt` or a stripped `debugger_stmt` body
    // is special-cased: the body slot syntactically requires SOME
    // statement here, so a stripped `debugger_stmt` (which prints
    // nothing as an ordinary list member) gets an explicit `;`
    // substituted for it here instead - and, like `empty_stmt`, that
    // `;` IS the entire body, so it must never be reported droppable
    // (a bare `;` serving as e.g. `for(;;);`'s mandatory body must
    // survive even when nothing follows).
    fn jsPrintLoopBody(self: *JsPrinter, body: *JsAstNode) JsPrintError!bool {
        if (body.data == .debugger_stmt) {
            try self.jsPrintWrite(";");
            return false;
        }
        const droppable = try self.jsPrintStatement(body);
        return droppable and body.data != .empty_stmt;
    }

    fn jsPrintBlock(self: *JsPrinter, b: parser.JsAstBlock) JsPrintError!void {
        try self.jsPrintWrite("{");
        var lastDroppable = false;
        for (b.body) |stmt| lastDroppable = try self.jsPrintStatement(stmt);
        if (lastDroppable) jsPrintTrimTrailingSemi(&self.out);
        try self.jsPrintWrite("}");
    }

    // A statement-position expression whose first printed token could
    // otherwise be misread as starting a different construct
    // (`{`, `function`, `class`, `let[`) needs parenthesizing when
    // printed at statement level. The parser only ever produces such
    // an expression here already wrapped in a source-level `paren`
    // JsAstNode (since that's the only way it could have parsed), so this
    // is a defensive no-op today, not a rewrite this pass performs.
    fn jsPrintExprStmtLead(self: *JsPrinter, node: *JsAstNode) JsPrintError!void {
        try self.jsPrintExpr(node);
    }

    fn jsPrintVarDecl(self: *JsPrinter, vd: parser.JsAstVarDecl) JsPrintError!void {
        try self.jsPrintWrite(switch (vd.kind) {
            .@"var" => "var",
            .@"let" => "let",
            .@"const" => "const",
        });
        for (vd.declarators, 0..) |d, i| {
            if (i > 0) try self.jsPrintWrite(",");
            try self.jsPrintBindingTarget(d.id);
            if (d.init) |init_| {
                try self.jsPrintWrite("=");
                try self.jsPrintAssignRhs(init_);
            }
        }
    }

    // The right-hand side of `=` in a declarator: a bare `sequence`
    // expression there would need parens to keep its commas from
    // being misread as separating further declarators, but (as with
    // jsPrintExprStmtLead) the parser only ever hands this pass such an
    // expression already `paren`-wrapped.
    fn jsPrintAssignRhs(self: *JsPrinter, node: *JsAstNode) JsPrintError!void {
        try self.jsPrintExpr(node);
    }

    fn jsPrintBindingTarget(self: *JsPrinter, node: *JsAstNode) JsPrintError!void {
        switch (node.data) {
            .identifier => |name| try self.jsPrintWrite(self.jsPrintIdentText(node, name)),
            .pattern => |p| try self.jsPrintPattern(p),
            else => try self.jsPrintExpr(node),
        }
    }

    fn jsPrintPattern(self: *JsPrinter, p: parser.JsAstPattern) JsPrintError!void {
        try self.jsPrintWrite(if (p.kind == .object) "{" else "[");
        var first = true;
        for (p.properties) |prop| {
            if (!first) try self.jsPrintWrite(",");
            first = false;
            try self.jsPrintPatternProperty(p.kind, prop);
        }
        if (p.rest) |r| {
            if (!first) try self.jsPrintWrite(",");
            try self.jsPrintWrite("...");
            try self.jsPrintBindingTarget(r);
        }
        try self.jsPrintWrite(if (p.kind == .object) "}" else "]");
    }

    // Prints a `computed_key` at an object-literal,
    // destructuring-pattern, or class-member key position (never at
    // `obj.prop`/`obj[prop]` member access - `jsPrintExpr`'s own
    // `.computed_member` case handles that separately). Such a key is
    // only ever a `string_literal` or `number_literal` node -
    // `jsParseKeyPropertyName` never produces any other computed_key
    // shape here - so, unlike a real computed member expression, it
    // never strictly needs the `[...]` wrapper for correctness: a
    // safe-bare-identifier string prints unquoted (`{"a":1}` ->
    // `{a:1}`), any other string/numeric literal prints as the
    // literal itself with no brackets (`{0:1}` stays `{0:1}`, a
    // non-identifier-shaped string like `{"a-b":1}` stays quoted but
    // still bracket-free).
    fn jsPrintKeyExpr(self: *JsPrinter, node: *JsAstNode) JsPrintError!void {
        var numBuf: [64]u8 = undefined;
        switch (node.data) {
            .string_literal => |t| {
                if (jsPrintSafeBracketPropName(node)) |name| {
                    try self.jsPrintWrite(name);
                } else {
                    try self.jsPrintStringLiteral(t);
                }
            },
            .number_literal => |t| try self.jsPrintWrite(jsPrintShortenNumber(&numBuf, t)),
            else => unreachable, // only ever a literal at these key positions
        }
    }

    fn jsPrintPatternProperty(self: *JsPrinter, kind: parser.JsAstPatternKind, prop: parser.JsAstPatternProperty) JsPrintError!void {
        if (kind == .array) {
            // An elided slot (`[, a]`) prints nothing for this entry;
            // the surrounding commas alone mark the hole.
            if (prop.value) |v| try self.jsPrintBindingTarget(v);
            if (prop.default) |def| {
                try self.jsPrintWrite("=");
                try self.jsPrintExpr(def);
            }
            return;
        }
        if (prop.computed_key) |ck| {
            if (ck.data == .string_literal or ck.data == .number_literal) {
                try self.jsPrintKeyExpr(ck);
            } else {
                try self.jsPrintWrite("[");
                try self.jsPrintExpr(ck);
                try self.jsPrintWrite("]");
            }
            try self.jsPrintWrite(":");
            try self.jsPrintBindingTarget(prop.value.?);
        } else if (prop.shorthand) {
            // Shorthand `{a}`/`{a = 1}`: `a` is simultaneously the
            // object's real property name (must stay literal - it's
            // not a binding, renaming it would read a different
            // property) and the new local binding (safe to rename).
            // A renamed binding needs the explicit `key:binding` form
            // to keep reading the same property; only an unrenamed
            // one can stay true shorthand.
            const renamed = self.jsPrintIdentTextForShorthand(prop.value.?);
            if (renamed) |r| {
                try self.jsPrintWrite(prop.key.?);
                try self.jsPrintWrite(":");
                try self.jsPrintWrite(r);
            } else {
                try self.jsPrintBindingTarget(prop.value.?);
            }
        } else {
            try self.jsPrintWrite(prop.key.?);
            try self.jsPrintWrite(":");
            try self.jsPrintBindingTarget(prop.value.?);
        }
        if (prop.default) |def| {
            try self.jsPrintWrite("=");
            try self.jsPrintExpr(def);
        }
    }

    fn jsPrintIf(self: *JsPrinter, s: parser.JsAstIf) JsPrintError!bool {
        try self.jsPrintWrite("if");
        try self.jsPrintWrite("(");
        try self.jsPrintExpr(s.test_);
        try self.jsPrintWrite(")");
        var droppable = try self.jsPrintLoopBody(s.consequent);
        if (s.alternate) |alt| {
            try self.jsPrintWrite("else");
            droppable = try self.jsPrintLoopBody(alt);
        }
        return droppable;
    }

    fn jsPrintFor(self: *JsPrinter, s: parser.JsAstFor) JsPrintError!bool {
        try self.jsPrintWrite("for");
        try self.jsPrintWrite("(");
        if (s.init) |i| {
            if (i.data == .var_decl) {
                try self.jsPrintVarDecl(i.data.var_decl);
            } else {
                try self.jsPrintExpr(i);
            }
        }
        try self.jsPrintWrite(";");
        if (s.test_) |t| try self.jsPrintExpr(t);
        try self.jsPrintWrite(";");
        if (s.update) |u| try self.jsPrintExpr(u);
        try self.jsPrintWrite(")");
        return try self.jsPrintLoopBody(s.body);
    }

    fn jsPrintForInOf(self: *JsPrinter, s: parser.JsAstForInOf) JsPrintError!bool {
        try self.jsPrintWrite("for");
        if (s.is_await) try self.jsPrintWrite("await");
        try self.jsPrintWrite("(");
        if (s.left.data == .var_decl) {
            try self.jsPrintVarDecl(s.left.data.var_decl);
        } else if (s.left.data == .identifier) {
            // An assignment target, not a value read - same hazard
            // as `.assignment`/`.update` above.
            try self.jsPrintWrite(self.jsPrintIdentText(s.left, s.left.data.identifier));
        } else {
            try self.jsPrintExpr(s.left);
        }
        try self.jsPrintWrite(if (s.is_of) "of" else "in");
        try self.jsPrintExpr(s.right);
        try self.jsPrintWrite(")");
        return try self.jsPrintLoopBody(s.body);
    }

    fn jsPrintTry(self: *JsPrinter, s: parser.JsAstTry) JsPrintError!void {
        try self.jsPrintWrite("try");
        _ = try self.jsPrintStatement(s.block);
        if (s.catch_body) |cb| {
            try self.jsPrintWrite("catch");
            if (s.catch_param) |param| {
                try self.jsPrintWrite("(");
                try self.jsPrintBindingTarget(param);
                try self.jsPrintWrite(")");
            }
            _ = try self.jsPrintStatement(cb);
        }
        if (s.finally_body) |fb| {
            try self.jsPrintWrite("finally");
            _ = try self.jsPrintStatement(fb);
        }
    }

    fn jsPrintSwitch(self: *JsPrinter, s: parser.JsAstSwitch) JsPrintError!void {
        try self.jsPrintWrite("switch");
        try self.jsPrintWrite("(");
        try self.jsPrintExpr(s.discriminant);
        try self.jsPrintWrite(")");
        try self.jsPrintWrite("{");
        for (s.cases) |c| {
            if (c.test_) |t| {
                try self.jsPrintWrite("case");
                try self.jsPrintExpr(t);
            } else {
                try self.jsPrintWrite("default");
            }
            try self.jsPrintWrite(":");
            // Not applying the trailing-`;` drop within a case body:
            // a case's statement list isn't followed by its own `}` -
            // the next bytes are either another `case`/`default`
            // label or the switch's closing `}`, and unlike a block
            // this isn't a dedicated scope boundary, so treating it
            // the same way isn't validated here.
            for (c.body) |stmt| _ = try self.jsPrintStatement(stmt);
        }
        try self.jsPrintWrite("}");
    }

    fn jsPrintFunction(self: *JsPrinter, f: parser.JsAstFunction, declNode: *JsAstNode) JsPrintError!void {
        if (f.is_async) try self.jsPrintWrite("async");
        try self.jsPrintWrite("function");
        if (f.is_generator) try self.jsPrintWrite("*");
        if (f.name) |name| try self.jsPrintWrite(self.jsPrintNameFor(declNode, name));
        try self.jsPrintParamList(f.params);
        try self.jsPrintBlock(f.body.data.block);
    }

    fn jsPrintParamList(self: *JsPrinter, params: []const *JsAstNode) JsPrintError!void {
        try self.jsPrintWrite("(");
        for (params, 0..) |param, i| {
            if (i > 0) try self.jsPrintWrite(",");
            try self.jsPrintParam(param);
        }
        try self.jsPrintWrite(")");
    }

    fn jsPrintParam(self: *JsPrinter, node: *JsAstNode) JsPrintError!void {
        switch (node.data) {
            .assignment => |a| {
                try self.jsPrintBindingTarget(a.left);
                try self.jsPrintWrite("=");
                try self.jsPrintExpr(a.right);
            },
            .spread => |target| {
                try self.jsPrintWrite("...");
                try self.jsPrintBindingTarget(target);
            },
            else => try self.jsPrintBindingTarget(node),
        }
    }

    fn jsPrintClass(self: *JsPrinter, c: parser.JsAstClass, declNode: *JsAstNode) JsPrintError!void {
        try self.jsPrintWrite("class");
        if (c.name) |name| try self.jsPrintWrite(self.jsPrintNameFor(declNode, name));
        if (c.super_class) |sc| {
            try self.jsPrintWrite("extends");
            try self.jsPrintExpr(sc);
        }
        try self.jsPrintWrite("{");
        for (c.members) |member| try self.jsPrintClassMember(member);
        try self.jsPrintWrite("}");
    }

    fn jsPrintClassMember(self: *JsPrinter, member: parser.JsAstClassMember) JsPrintError!void {
        if (member.kind == .static_block) {
            if (member.value) |f| {
                try self.jsPrintWrite("static");
                try self.jsPrintBlock(f.body.data.block);
            }
            return;
        }
        if (member.is_static) try self.jsPrintWrite("static");
        switch (member.kind) {
            .getter => try self.jsPrintWrite("get"),
            .setter => try self.jsPrintWrite("set"),
            else => {},
        }
        if (member.value) |f| {
            if (f.is_async) try self.jsPrintWrite("async");
            if (f.is_generator) try self.jsPrintWrite("*");
        }
        try self.jsPrintMemberKey(member);
        if (member.value) |f| {
            try self.jsPrintParamList(f.params);
            try self.jsPrintBlock(f.body.data.block);
        } else {
            if (member.field_init) |init_| {
                try self.jsPrintWrite("=");
                try self.jsPrintExpr(init_);
            }
            try self.jsPrintWrite(";");
        }
    }

    fn jsPrintMemberKey(self: *JsPrinter, member: parser.JsAstClassMember) JsPrintError!void {
        if (member.computed_key) |ck| {
            if (ck.data == .string_literal or ck.data == .number_literal) {
                try self.jsPrintKeyExpr(ck);
            } else {
                try self.jsPrintWrite("[");
                try self.jsPrintExpr(ck);
                try self.jsPrintWrite("]");
            }
            return;
        }
        if (member.is_private) try self.jsPrintWrite("#");
        try self.jsPrintWrite(member.key.?);
    }

    fn jsPrintExpr(self: *JsPrinter, node: *JsAstNode) JsPrintError!void {
        var numBuf: [64]u8 = undefined;
        switch (node.data) {
            .identifier => |name| {
                if (self.jsPrintGlobalBuiltinName(node)) |builtin| {
                    try self.jsPrintWrite(if (std.mem.eql(u8, builtin, "undefined")) "void 0" else "1/0");
                } else {
                    try self.jsPrintWrite(self.jsPrintIdentText(node, name));
                }
            },
            .this_expr => try self.jsPrintWrite("this"),
            .super_expr => try self.jsPrintWrite("super"),
            .number_literal => |t| try self.jsPrintWrite(jsPrintShortenNumber(&numBuf, t)),
            .string_literal => |t| try self.jsPrintStringLiteral(t),
            .regex_literal => |t| try self.jsPrintWriteRegex(t),
            .boolean_literal => |v| try self.jsPrintWrite(if (v) "!0" else "!1"),
            .null_literal => try self.jsPrintWrite("null"),
            .template_literal => |t| try self.jsPrintTemplateLiteral(t),
            .tagged_template => |t| {
                try self.jsPrintExprAsMemberBase(t.tag);
                try self.jsPrintTemplateLiteral(t.quasi);
            },
            .array_literal => |elements| try self.jsPrintArrayLiteral(elements),
            .object_literal => |props| try self.jsPrintObjectLiteral(props),
            .spread => |arg| {
                try self.jsPrintWrite("...");
                try self.jsPrintExpr(arg);
            },
            .function_expr => |f| try self.jsPrintFunction(f, node),
            .arrow_function => |a| try self.jsPrintArrow(a),
            .class_expr => |c| try self.jsPrintClass(c, node),
            .binary => |bin| try self.jsPrintComparison(bin.op, bin.left, bin.right),
            .assignment => |bin| {
                // The left side of `=` is an assignment target, not
                // a value read - even though `undefined`/`Infinity`
                // are ordinary identifiers grammatically, substituting
                // `void 0`/`1/0` here would produce an invalid
                // assignment target (`void 0=5` is a syntax error).
                // Print it as plain text, bypassing the substitution
                // in `jsPrintExpr`'s `.identifier` case.
                if (bin.left.data == .identifier) {
                    try self.jsPrintWrite(self.jsPrintIdentText(bin.left, bin.left.data.identifier));
                } else {
                    try self.jsPrintExpr(bin.left);
                }
                try self.jsPrintWrite(bin.op);
                try self.jsPrintExpr(bin.right);
            },
            .logical => |bin| try self.jsPrintBinary(bin.op, bin.left, bin.right),
            .unary => |u| {
                try self.jsPrintWrite(u.op);
                try self.jsPrintExpr(u.argument);
            },
            .update => |u| {
                // Same assignment-target hazard as `.assignment`
                // above - `undefined`/`Infinity` must print as plain
                // identifiers here, not their substituted form.
                if (u.argument.data == .identifier) {
                    try self.jsPrintWrite(self.jsPrintIdentText(u.argument, u.argument.data.identifier));
                } else {
                    try self.jsPrintExpr(u.argument);
                }
                try self.jsPrintWrite(u.op);
            },
            .conditional => |c| {
                try self.jsPrintExpr(c.test_);
                try self.jsPrintWrite("?");
                try self.jsPrintExpr(c.consequent);
                try self.jsPrintWrite(":");
                try self.jsPrintExpr(c.alternate);
            },
            .call => |c| try self.jsPrintCall(c),
            .new_expr => |c| {
                try self.jsPrintWrite("new");
                try self.jsPrintExprAsMemberBase(c.callee);
                try self.jsPrintArgs(c.arguments);
            },
            .member => |m| {
                try self.jsPrintExprAsMemberBase(m.object);
                try self.jsPrintWrite(if (m.optional) "?." else ".");
                if (m.is_private) try self.jsPrintWrite("#");
                try self.jsPrintWrite(m.property);
            },
            .computed_member => |m| {
                try self.jsPrintExprAsMemberBase(m.object);
                // A trailing digit right before `.propName` would
                // re-lex as (the start of) a decimal literal instead
                // of a member access - e.g. `1.x` is not `1` then
                // `.x`. Bracket notation always stays unambiguous.
                const objEndsInDigit = self.out.items.len > 0 and std.ascii.isDigit(self.out.items[self.out.items.len - 1]);
                const safeName = if (!m.optional and !objEndsInDigit) jsPrintSafeBracketPropName(m.property) else null;
                if (safeName) |name| {
                    try self.jsPrintWrite(".");
                    try self.jsPrintWrite(name);
                } else {
                    try self.jsPrintWrite(if (m.optional) "?.[" else "[");
                    try self.jsPrintExpr(m.property);
                    try self.jsPrintWrite("]");
                }
            },
            .paren => |inner| {
                try self.jsPrintWrite("(");
                try self.jsPrintExpr(inner);
                try self.jsPrintWrite(")");
            },
            .sequence => |items| {
                for (items, 0..) |item, i| {
                    if (i > 0) try self.jsPrintWrite(",");
                    try self.jsPrintExpr(item);
                }
            },
            .yield_expr => |y| {
                try self.jsPrintWrite(if (y.delegate) "yield*" else "yield");
                if (y.argument) |a| try self.jsPrintExpr(a);
            },
            .await_expr => |arg| {
                try self.jsPrintWrite("await");
                try self.jsPrintExpr(arg);
            },
            .pattern => |p| try self.jsPrintPattern(p),
            else => unreachable, // statement-shaped Data never reached from expression position
        }
    }

    fn jsPrintBinary(self: *JsPrinter, op: []const u8, left: *JsAstNode, right: *JsAstNode) JsPrintError!void {
        try self.jsPrintExpr(left);
        try self.jsPrintWrite(op);
        try self.jsPrintExpr(right);
    }

    // A `==`/`===`/`!=`/`!==` comparison gets two independent
    // structural rewrites applied before falling back to the generic
    // `jsPrintBinary`:
    //
    // - `typeof x === "undefined"` (either operand order, any of the
    //   four operators) -> `x === void 0`. Only applied when `x` is a
    //   plain identifier this pass resolved to a real binding -
    //   `typeof` is specifically safe to use on an undeclared name
    //   (evaluates to `"undefined"`, no ReferenceError); `void 0`
    //   directly evaluates `x`, which throws ReferenceError if `x`
    //   isn't actually declared anywhere. Never applied to a
    //   `typeof` on anything other than a bare identifier (a member
    //   expression like `typeof a.b` already safely evaluates `a`
    //   either way, but that's not the common case this targets and
    //   isn't worth the extra branching to special-case).
    //
    // - A `true`/`false` operand of a LOOSE `==`/`!=` comparison ->
    //   `1`/`0` (shorter than the `!0`/`!1` `boolean_literal` prints
    //   as everywhere else). Sound only for loose equality: `x==true`
    //   and `x==1` coerce identically for every possible `x` (both go
    //   through ToNumber(true)=1). NOT sound for strict `===`/`!==`
    //   (`1===true` is `false` while `1===1` is `true` - strict
    //   equality doesn't coerce), so those keep the `!0`/`!1` form
    //   `jsPrintExpr` already prints, and are left to `jsPrintBinary`
    //   below unchanged.
    fn jsPrintComparison(self: *JsPrinter, op: []const u8, left: *JsAstNode, right: *JsAstNode) JsPrintError!void {
        const isEq = std.mem.eql(u8, op, "===") or std.mem.eql(u8, op, "==");
        const isNeq = std.mem.eql(u8, op, "!==") or std.mem.eql(u8, op, "!=");
        if (isEq or isNeq) {
            if (jsPrintIsStringUndefined(right)) {
                if (self.jsPrintTypeofUndefinedOperand(left)) |x| {
                    try self.jsPrintWrite(x);
                    try self.jsPrintWrite(op);
                    try self.jsPrintWrite("void");
                    try self.jsPrintWrite("0");
                    return;
                }
            }
            if (jsPrintIsStringUndefined(left)) {
                if (self.jsPrintTypeofUndefinedOperand(right)) |x| {
                    try self.jsPrintWrite("void");
                    try self.jsPrintWrite("0");
                    try self.jsPrintWrite(op);
                    try self.jsPrintWrite(x);
                    return;
                }
            }
        }
        const isLooseEq = std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=");
        if (isLooseEq and (left.data == .boolean_literal or right.data == .boolean_literal)) {
            if (left.data == .boolean_literal) {
                try self.jsPrintWrite(if (left.data.boolean_literal) "1" else "0");
            } else {
                try self.jsPrintExpr(left);
            }
            try self.jsPrintWrite(op);
            if (right.data == .boolean_literal) {
                try self.jsPrintWrite(if (right.data.boolean_literal) "1" else "0");
            } else {
                try self.jsPrintExpr(right);
            }
            return;
        }
        try self.jsPrintBinary(op, left, right);
    }

    // Whether `node` is an identifier reference to the genuine global
    // `undefined`/`Infinity` - i.e. no local binding shadows it. Only
    // an unresolved reference qualifies: `self.resolved` holds every
    // reference this pass traced back to a real declared binding
    // (see `jsPrintTypeofUndefinedOperand` above for the same
    // reasoning), so a name absent from it is either a genuine
    // global or a name from a different, untracked `<script>` - both
    // cases where the identifier still means the real `undefined`/
    // `Infinity`, never a shadowing local this pass lost track of.
    fn jsPrintGlobalBuiltinName(self: *const JsPrinter, node: *JsAstNode) ?[]const u8 {
        if (node.data != .identifier) return null;
        const name = node.data.identifier;
        if (!std.mem.eql(u8, name, "undefined") and !std.mem.eql(u8, name, "Infinity")) return null;
        if (self.resolved.contains(node)) return null;
        return name;
    }

    // Prints `node` the same as `jsPrintExpr`, except the global
    // `undefined`/`Infinity` substitution (if it applies) is wrapped
    // in parens. Use this wherever grammar requires a
    // `MemberExpression`-grade operand with nothing looser allowed
    // unparenthesized - the base of a `.`/`?.`/`[...]` access, a
    // call/`new` callee, or a tagged template's tag - since `void 0`/
    // `1/0` are unary/binary expressions there and `void 0.toString()`
    // (say) would otherwise silently re-parse as
    // `void (0.toString())` instead of `(void 0).toString()`. Also
    // covers the `new` case, where an unparenthesized unary callee
    // (`new void 0`) is a syntax error, not just a different meaning.
    fn jsPrintExprAsMemberBase(self: *JsPrinter, node: *JsAstNode) JsPrintError!void {
        if (self.jsPrintGlobalBuiltinName(node)) |name| {
            try self.jsPrintWrite("(");
            if (std.mem.eql(u8, name, "undefined")) {
                try self.jsPrintWrite("void 0");
            } else {
                try self.jsPrintWrite("1/0");
            }
            try self.jsPrintWrite(")");
            return;
        }
        try self.jsPrintExpr(node);
    }

    // Whether `node` is exactly the string literal `"undefined"`
    // (either quote style) - the one value that makes a `typeof x`
    // comparison rewritable, see `jsPrintComparison`.
    fn jsPrintIsStringUndefined(node: *JsAstNode) bool {
        if (node.data != .string_literal) return false;
        const t = node.data.string_literal;
        return t.len == 11 and (std.mem.eql(u8, t, "\"undefined\"") or std.mem.eql(u8, t, "'undefined'"));
    }

    // If `node` is `typeof <identifier>` and that identifier resolved
    // to a real binding, returns the identifier's printed text (its
    // rename if one was assigned); otherwise `null`. `typeof` on
    // anything other than a bare identifier, or on an unresolved
    // (genuinely global/untracked) name, doesn't qualify - see
    // `jsPrintComparison`.
    fn jsPrintTypeofUndefinedOperand(self: *JsPrinter, node: *JsAstNode) ?[]const u8 {
        if (node.data != .unary) return null;
        const u = node.data.unary;
        if (!std.mem.eql(u8, u.op, "typeof")) return null;
        if (u.argument.data != .identifier) return null;
        if (!self.resolved.contains(u.argument)) return null;
        // The OTHER side of the comparison must be exactly the
        // string "undefined" for this rewrite to apply at all - the
        // caller only reaches here already knowing the operator is
        // ==/===/!=/!==, but still needs to check the sibling
        // operand, which this helper doesn't have. Checked by the
        // caller instead (see the two call sites in
        // jsPrintComparison, each paired with a same-call check of
        // the opposite operand).
        return self.jsPrintIdentText(u.argument, u.argument.data.identifier);
    }

    fn jsPrintCall(self: *JsPrinter, c: parser.JsAstCall) JsPrintError!void {
        try self.jsPrintExprAsMemberBase(c.callee);
        try self.jsPrintWrite(if (c.optional) "?." else "");
        try self.jsPrintArgs(c.arguments);
    }

    fn jsPrintArgs(self: *JsPrinter, args: []const *JsAstNode) JsPrintError!void {
        try self.jsPrintWrite("(");
        for (args, 0..) |arg, i| {
            if (i > 0) try self.jsPrintWrite(",");
            try self.jsPrintExpr(arg);
        }
        try self.jsPrintWrite(")");
    }

    fn jsPrintArrayLiteral(self: *JsPrinter, elements: []const ?*JsAstNode) JsPrintError!void {
        try self.jsPrintWrite("[");
        for (elements, 0..) |maybeEl, i| {
            if (i > 0) try self.jsPrintWrite(",");
            if (maybeEl) |el| try self.jsPrintExpr(el);
        }
        try self.jsPrintWrite("]");
    }

    fn jsPrintObjectLiteral(self: *JsPrinter, props: []const parser.JsAstObjectProperty) JsPrintError!void {
        try self.jsPrintWrite("{");
        for (props, 0..) |prop, i| {
            if (i > 0) try self.jsPrintWrite(",");
            try self.jsPrintObjectProperty(prop);
        }
        try self.jsPrintWrite("}");
    }

    fn jsPrintObjectProperty(self: *JsPrinter, prop: parser.JsAstObjectProperty) JsPrintError!void {
        if (prop.kind == .spread) {
            try self.jsPrintWrite("...");
            try self.jsPrintExpr(prop.value);
            return;
        }
        switch (prop.kind) {
            .getter => try self.jsPrintWrite("get"),
            .setter => try self.jsPrintWrite("set"),
            else => {},
        }
        if (prop.kind == .method) {
            const f = prop.value.data.function_expr;
            if (f.is_async) try self.jsPrintWrite("async");
            if (f.is_generator) try self.jsPrintWrite("*");
        }
        if (prop.computed_key) |ck| {
            if (ck.data == .string_literal or ck.data == .number_literal) {
                try self.jsPrintKeyExpr(ck);
            } else {
                try self.jsPrintWrite("[");
                try self.jsPrintExpr(ck);
                try self.jsPrintWrite("]");
            }
        } else {
            try self.jsPrintWrite(prop.key.?);
        }
        switch (prop.kind) {
            .method, .getter, .setter => {
                const f = prop.value.data.function_expr;
                try self.jsPrintParamList(f.params);
                try self.jsPrintBlock(f.body.data.block);
            },
            .normal => {
                if (!prop.shorthand) {
                    try self.jsPrintWrite(":");
                    try self.jsPrintExpr(prop.value);
                } else {
                    // Shorthand `{a}` - `prop.value` is the same
                    // identifier as the key; only its resolved
                    // reference/decl rename (if any) is emitted after
                    // the key, so a mangled binding still reads back
                    // correctly (`{a:b}`) while an unmangled one
                    // collapses to true shorthand (`{a}`).
                    const renamed = self.jsPrintIdentTextForShorthand(prop.value);
                    if (renamed) |r| {
                        try self.jsPrintWrite(":");
                        try self.jsPrintWrite(r);
                    }
                }
            },
            .spread => unreachable,
        }
    }

    // `null` when the shorthand property's value identifier was not
    // renamed, so a caller can tell whether the shorthand form is
    // still valid as-is.
    fn jsPrintIdentTextForShorthand(self: *const JsPrinter, node: *JsAstNode) ?[]const u8 {
        return switch (node.data) {
            .identifier => self.renames.get(node),
            else => null,
        };
    }

    fn jsPrintArrow(self: *JsPrinter, a: parser.JsAstArrow) JsPrintError!void {
        if (a.is_async) try self.jsPrintWrite("async");
        // A sole bare-identifier parameter can drop the parens
        // entirely (`x=>...` instead of `(x)=>...`) - safe post-
        // mangling too, since every name a `.identifier` param node
        // can ever hold, original or a generated short name alike, is
        // by construction already a valid bare identifier (the parser
        // only produces this node from a real identifier token; the
        // mangler only ever generates names from its own always-valid
        // alphabet). Any other param shape - zero or 2+ params, a
        // destructuring pattern, a default value, a rest param - still
        // needs the parens and goes through the ordinary list form.
        if (a.params.len == 1 and a.params[0].data == .identifier) {
            const p = a.params[0];
            try self.jsPrintWrite(self.jsPrintIdentText(p, p.data.identifier));
        } else {
            try self.jsPrintParamList(a.params);
        }
        try self.jsPrintWrite("=>");
        if (a.body.data == .block) {
            try self.jsPrintBlock(a.body.data.block);
        } else {
            try self.jsPrintExpr(a.body);
        }
    }

    // Appends `text` with no separator logic at all - for fragments
    // that are never ambiguous with whatever precedes/follows them
    // (a template literal's backtick/quasi text and its `${`/`}`
    // delimiters), where the normal `jsPrintWrite` boundary check could
    // otherwise insert a byte into what must stay literal content.
    fn jsPrintWriteRaw(self: *JsPrinter, text: []const u8) JsPrintError!void {
        try self.out.appendSlice(self.allocator, text);
    }

    fn jsPrintTemplateLiteral(self: *JsPrinter, t: parser.JsAstTemplateLiteral) JsPrintError!void {
        for (t.quasis, 0..) |quasi, i| {
            // Raw quasi text as sliced by the parser excludes the
            // `${`/`}` substitution delimiters themselves (see
            // parseTemplateLiteral) - restored here around each
            // embedded expression.
            try self.jsPrintWriteRaw(quasi);
            if (i < t.expressions.len) {
                try self.jsPrintWriteRaw("${");
                try self.jsPrintExpr(t.expressions[i]);
                try self.jsPrintWriteRaw("}");
            }
        }
    }
};

// Whether `propertyNode` is a string literal whose unescaped content
// is a safe bare identifier - i.e. `foo["bar"]`/`{["bar"]:1}` could
// instead be written `foo.bar`/`{bar:1}` with identical meaning.
// Returns the identifier text (the literal's raw source with its
// surrounding quotes stripped) when safe, else `null`. Only ever
// returns non-null for a literal with no escape sequences at all -
// `"\x62ar"` is left as bracket notation rather than decoded, since
// an escaped-but-otherwise-safe name is rare and decoding correctly
// would need real string-literal escape handling this check doesn't
// otherwise need. A reserved word is left as bracket notation even
// though `foo.class` is legal for a member/computed-key property
// name (unlike a binding); it's simpler and still always correct to
// treat reserved words as unsafe here.
fn jsPrintSafeBracketPropName(propertyNode: *const JsAstNode) ?[]const u8 {
    if (propertyNode.data != .string_literal) return null;
    const raw = propertyNode.data.string_literal;
    if (raw.len < 2) return null;
    const quote = raw[0];
    if (quote != '"' and quote != '\'') return null;
    if (raw[raw.len - 1] != quote) return null;
    const inner = raw[1 .. raw.len - 1];
    if (inner.len == 0) return null;
    if (!parser.jsIsIdentStartChar(inner[0])) return null;
    for (inner[1..]) |c| {
        if (!parser.jsIsIdentPartChar(c)) return null;
    }
    if (parser.jsIsReservedWord(inner)) return null;
    return inner;
}

// Rewrites a decimal numeric literal's source text to the shortest
// string that still parses to the identical `Number` value: strips
// numeric separators, a leading `0` before the decimal point, a
// trailing `0`/`.` in the fraction, and switches to/from exponential
// notation when that's shorter. Left untouched (returned as-is):
// hex/octal/binary literals (`0x1f`, `0o17`, `0b101` - a different
// literal form, not just a different spelling of the same digits)
// and BigInt literals (`10n` - a different type, not just a shorter
// Number). `buf` must be at least 64 bytes; real-world source numbers
// never approach that, and this function bails out to the original
// text rather than risk overflowing it.
fn jsPrintShortenNumber(buf: []u8, text: []const u8) []const u8 {
    if (text.len < 2) return text;
    if (text[0] == '0' and text.len > 1) {
        const p = text[1];
        if (p == 'x' or p == 'X' or p == 'o' or p == 'O' or p == 'b' or p == 'B') return text;
    }
    if (text[text.len - 1] == 'n') return text; // BigInt

    // Split into integer/fraction/exponent digit runs, dropping `_`
    // separators as they're copied - they carry no value and are
    // illegal in the numeric value itself.
    var intPart: [32]u8 = undefined;
    var intLen: usize = 0;
    var fracPart: [32]u8 = undefined;
    var fracLen: usize = 0;
    var expPart: [16]u8 = undefined;
    var expLen: usize = 0;
    var expNegative = false;

    var i: usize = 0;
    while (i < text.len and (std.ascii.isDigit(text[i]) or text[i] == '_')) : (i += 1) {
        if (text[i] == '_') continue;
        if (intLen >= intPart.len) return text;
        intPart[intLen] = text[i];
        intLen += 1;
    }
    if (i < text.len and text[i] == '.') {
        i += 1;
        while (i < text.len and (std.ascii.isDigit(text[i]) or text[i] == '_')) : (i += 1) {
            if (text[i] == '_') continue;
            if (fracLen >= fracPart.len) return text;
            fracPart[fracLen] = text[i];
            fracLen += 1;
        }
    }
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) {
            expNegative = text[i] == '-';
            i += 1;
        }
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
            if (expLen >= expPart.len) return text;
            expPart[expLen] = text[i];
            expLen += 1;
        }
    }
    if (i != text.len) return text; // trailing junk this function doesn't understand - leave alone

    // Normalize to a single digit run plus a decimal-point exponent:
    // "digits" with the point implicitly after position `pointExp`
    // digits from the left, e.g. 1500 with pointExp=4 is 1500.,
    // 0.025 becomes digits="25" with pointExp=-2.
    var digits: [48]u8 = undefined;
    var digitsLen: usize = 0;
    for (intPart[0..intLen]) |c| {
        digits[digitsLen] = c;
        digitsLen += 1;
    }
    for (fracPart[0..fracLen]) |c| {
        digits[digitsLen] = c;
        digitsLen += 1;
    }
    var pointExp: i32 = @intCast(intLen);
    if (expLen > 0) {
        const expVal = std.fmt.parseInt(i32, expPart[0..expLen], 10) catch return text;
        pointExp += if (expNegative) -expVal else expVal;
    }

    // Strip leading zeros in the digit run (they don't affect value),
    // then trailing zeros (ditto), adjusting pointExp/digitsLen to
    // match what was removed.
    var start: usize = 0;
    while (start < digitsLen and digits[start] == '0') : (start += 1) pointExp -= 1;
    var stop: usize = digitsLen;
    while (stop > start and digits[stop - 1] == '0') : (stop -= 1) {}
    if (start >= stop) {
        // The whole literal is zero.
        return jsPrintShorterOf(buf, text, "0");
    }
    const sig = digits[start..stop];

    // Plain (non-exponential) rendering: sig digits with the decimal
    // point at `pointExp` digits in from the left, zero-padding
    // either side as needed. pointExp <= 0 means leading ".000digits";
    // pointExp >= sig.len means trailing "digits000".
    var plainBuf: [48]u8 = undefined;
    var w: usize = 0;
    if (pointExp <= 0) {
        plainBuf[w] = '.';
        w += 1;
        var z: i32 = 0;
        while (z < -pointExp) : (z += 1) {
            plainBuf[w] = '0';
            w += 1;
        }
        @memcpy(plainBuf[w .. w + sig.len], sig);
        w += sig.len;
    } else if (@as(usize, @intCast(pointExp)) >= sig.len) {
        @memcpy(plainBuf[w .. w + sig.len], sig);
        w += sig.len;
        var z: usize = sig.len;
        while (z < @as(usize, @intCast(pointExp))) : (z += 1) {
            plainBuf[w] = '0';
            w += 1;
        }
    } else {
        const intDigits: usize = @intCast(pointExp);
        @memcpy(plainBuf[w .. w + intDigits], sig[0..intDigits]);
        w += intDigits;
        plainBuf[w] = '.';
        w += 1;
        @memcpy(plainBuf[w .. w + (sig.len - intDigits)], sig[intDigits..]);
        w += sig.len - intDigits;
    }
    const plain = plainBuf[0..w];

    // Exponential rendering: one significant digit before the point
    // (if more than one digit, `.` then the rest), `e`, then the
    // power of ten - the shortest exponential form is always
    // normalized this way (`1.5e3`, never `15e2`).
    var expBuf: [32]u8 = undefined;
    var ew: usize = 0;
    expBuf[ew] = sig[0];
    ew += 1;
    if (sig.len > 1) {
        expBuf[ew] = '.';
        ew += 1;
        @memcpy(expBuf[ew .. ew + sig.len - 1], sig[1..]);
        ew += sig.len - 1;
    }
    expBuf[ew] = 'e';
    ew += 1;
    const power = pointExp - 1;
    if (power < 0) {
        expBuf[ew] = '-';
        ew += 1;
    }
    var powBuf: [8]u8 = undefined;
    const powStr = std.fmt.bufPrint(&powBuf, "{d}", .{@abs(power)}) catch return jsPrintShorterOf(buf, text, plain);
    @memcpy(expBuf[ew .. ew + powStr.len], powStr);
    ew += powStr.len;
    const expForm = expBuf[0..ew];

    const best = if (expForm.len < plain.len) expForm else plain;
    return jsPrintShorterOf(buf, text, best);
}

// Copies `candidate` into `buf` and returns it if strictly shorter
// than `original`; otherwise returns `original` unchanged (ties keep
// the source spelling rather than needlessly rewriting it).
fn jsPrintShorterOf(buf: []u8, original: []const u8, candidate: []const u8) []const u8 {
    if (candidate.len >= original.len) return original;
    @memcpy(buf[0..candidate.len], candidate);
    return buf[0..candidate.len];
}

fn jsPrintIsIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

// A conservative, punctuation-pair-based separator check operating on
// the last byte already emitted and the first byte about to be
// emitted: this printer only ever has a suffix and a prefix of what
// may be much larger fragments on hand at once (e.g. two operators
// from unrelated Nodes ending up adjacent), never two full token
// texts to compare. Two identifier/digit characters always need a
// separator (they'd otherwise fuse into one longer identifier); two
// punctuation characters need one only when that exact pair is the
// first two characters of some real multi-character JS operator, or
// output would re-lex differently than intended.
fn jsPrintNeedsSeparator(prev: u8, next: u8) bool {
    if (jsPrintIsIdentByte(prev) and jsPrintIsIdentByte(next)) return true;
    return jsPrintIsDangerousAdjacentPair(prev, next);
}

// Kept in sync with the tokenizer's punctuator tables, and with the
// equivalent token-based check used by the fallback strip pass.
fn jsPrintIsDangerousAdjacentPair(a: u8, b: u8) bool {
    const pairs = [_][2]u8{
        .{ '!', '=' }, .{ '%', '=' }, .{ '&', '&' }, .{ '&', '=' },
        .{ '*', '*' }, .{ '*', '=' }, .{ '+', '+' }, .{ '+', '=' },
        .{ '-', '-' }, .{ '-', '=' }, .{ '/', '=' }, .{ '<', '<' },
        .{ '<', '=' }, .{ '=', '=' }, .{ '=', '>' }, .{ '>', '=' },
        .{ '>', '>' }, .{ '?', '.' }, .{ '?', '?' }, .{ '^', '=' },
        .{ '|', '=' }, .{ '|', '|' }, .{ '/', '/' }, .{ '/', '*' },
    };
    for (pairs) |p| {
        if (p[0] == a and p[1] == b) return true;
    }
    return false;
}

/// Post-processes already-minified JS text, rewriting every
/// double-quoted string literal to single-quoted wherever its content
/// contains no `'` - so the result can be embedded in an HTML/SVG
/// `"`-delimited attribute without needing any `&quot;` escapes.
/// Leaves every other token (including double-quoted strings that do
/// contain a `'`, which would gain escapes by switching) untouched.
/// `text` must be valid, already-minified JS (e.g. `js.js`'s own
/// output) - used only by callers embedding JS into a quoted
/// attribute, never by `js.js` itself, which always prefers `"`.
pub fn jsRequoteDoubleToSingleWhereSafe(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var tzr = parser.JsTokenizer.init(text);
    var pos: usize = 0;
    while (true) {
        const t = tzr.next();
        if (t.tag == .eof) break;

        // Whatever sat between the previous token and this one
        // (whitespace - minified output has no comments) copies
        // through verbatim.
        try out.appendSlice(allocator, text[pos..t.loc.start]);

        if (t.tag == .string and t.loc.end - t.loc.start >= 2 and text[t.loc.start] == '"') {
            const inner = text[t.loc.start + 1 .. t.loc.end - 1];
            if (std.mem.indexOfScalar(u8, inner, '\'') == null) {
                try out.append(allocator, '\'');
                var i: usize = 0;
                while (i < inner.len) {
                    const c = inner[i];
                    if (c == '\\' and i + 1 < inner.len and inner[i + 1] == '"') {
                        // No longer the delimiter once re-quoted with
                        // ' - the escape is no longer needed.
                        try out.append(allocator, '"');
                        i += 2;
                        continue;
                    }
                    try out.append(allocator, c);
                    i += 1;
                }
                try out.append(allocator, '\'');
                pos = t.loc.end;
                continue;
            }
        }

        try out.appendSlice(allocator, text[t.loc.start..t.loc.end]);
        pos = t.loc.end;
    }
    try out.appendSlice(allocator, text[pos..]);

    return out.toOwnedSlice(allocator);
}

const NameSet = std.StringArrayHashMapUnmanaged(void);

/// Built by one `add` call per `<script>`/handler source on a page,
/// then turned into a `protect` list via `finalize`.
pub const JsCrossRefCollector = struct {
    allocator: std.mem.Allocator,
    /// Every name declared at top level in some source, and how many
    /// distinct sources declare it.
    declaredCount: std.StringArrayHashMapUnmanaged(usize) = .empty,
    /// Every name referenced without a local declaration in some
    /// source (a real global, or one declared in another source).
    unresolved: NameSet = .empty,

    pub fn init(allocator: std.mem.Allocator) JsCrossRefCollector {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *JsCrossRefCollector) void {
        for (self.declaredCount.keys()) |k| self.allocator.free(k);
        self.declaredCount.deinit(self.allocator);
        for (self.unresolved.keys()) |k| self.allocator.free(k);
        self.unresolved.deinit(self.allocator);
    }

    /// Parses `source` and folds its top-level names in. Safe to call
    /// with unparseable input - contributes nothing.
    pub fn add(self: *JsCrossRefCollector, source: []const u8) !void {
        const names = try jsCollectTopLevelNames(self.allocator, source);
        defer names.deinit(self.allocator);

        for (names.declared) |name| {
            const entry = try self.declaredCount.getOrPut(self.allocator, name);
            if (entry.found_existing) {
                entry.value_ptr.* += 1;
            } else {
                entry.key_ptr.* = try self.allocator.dupe(u8, name);
                entry.value_ptr.* = 1;
            }
        }
        for (names.unresolved) |name| {
            if (!self.unresolved.contains(name)) {
                try self.unresolved.put(self.allocator, try self.allocator.dupe(u8, name), {});
            }
        }
    }

    /// A top-level name is unsafe for any one source to mangle away if
    /// another source could be relying on that exact spelling: it's
    /// declared in more than one source (each source's copy might be
    /// the one another source's unresolved reference actually means),
    /// or it's declared in at least one source and left unresolved
    /// (referenced but not locally declared) in at least one - since
    /// with only one source's worth of information at a time there's
    /// no way to tell whether that reference means this declaration or
    /// a same-named global that happens not to exist.
    ///
    /// Returned list (and every name in it) is owned by `allocator`,
    /// independent of `self` - safe to use after `self.deinit()`.
    pub fn finalize(self: *const JsCrossRefCollector, allocator: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |s| allocator.free(s);
            out.deinit(allocator);
        }

        for (self.declaredCount.keys(), self.declaredCount.values()) |name, count| {
            if (count > 1 or self.unresolved.contains(name)) {
                try out.append(allocator, try allocator.dupe(u8, name));
            }
        }
        return out.toOwnedSlice(allocator);
    }
};
