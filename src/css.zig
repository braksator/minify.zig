//! CSS minifier: comment/whitespace stripping with spec-aware serialization
//! for grid-template strings and math-function expressions.

const std = @import("std");
const common = @import("minify.zig");
const svg = @import("svg.zig");
const js = @import("js.zig");
const minify = common;

pub const MinifyOptions = minify.MinifyOptions;

/// Resolves `args`' `svg.strip` to `.all` when unset, for SVG this
/// pass finds embedded in a `url(...)`. Returns null (caller falls
/// back to the original `args`) when no rewrite was needed.
fn cssEmbeddedSvgArgs(allocator: std.mem.Allocator, args: ?[]const u8) !?[]u8 {
    var parsed = try minify.parseOptions(allocator, args);
    defer parsed.deinit();
    if (parsed.value.svg.strip != null) return null;
    parsed.value.svg.strip = .all;

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &buf.writer);
    return try allocator.dupe(u8, buf.written());
}

fn cssIsWs(c: u8) bool {
    return common.isWsCore(c) or c == '\n';
}

const CssBuf = std.ArrayList(u8);

/// Minifies CSS. `args` is an optional `MinifyOptions` JSON string;
/// `.css` is reserved for future css()-specific knobs (there are none
/// yet). Any embedded SVG this pass finds (a `url(...)` holding an
/// inline SVG document) is minified with the same options, except an
/// unset `svg.strip` resolves to `.all` rather than `svg()`'s own
/// standalone default of `.more`.
pub fn css(allocator: std.mem.Allocator, input: []const u8, args: ?[]const u8) ![]u8 {
    const resolvedSvgArgs = try cssEmbeddedSvgArgs(allocator, args);
    defer if (resolvedSvgArgs) |a| allocator.free(a);
    const svgArgs: ?[]const u8 = resolvedSvgArgs orelse args;

    var out: CssBuf = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    const n = input.len;
    var pendingSpace = false;

    while (i < n) {
        const c = input[i];

        if (c == '/' and i + 1 < n and input[i + 1] == '*') {
            i += 2;
            while (i + 1 < n and !(input[i] == '*' and input[i + 1] == '/')) i += 1;
            i = @min(i + 2, n);
            pendingSpace = true;
            continue;
        }

        if (c == '"' or c == '\'') {
            try cssFlushSpace(allocator, &out, &pendingSpace);
            if (cssIsInsideUrlFunction(out.items)) {
                try cssCopyUrlSvgString(allocator, &out, input, &i, c, svgArgs);
            } else if (cssIsInsideGridTemplateValue(out.items)) {
                try cssCopyGridTemplateString(allocator, &out, input, &i, c);
            } else {
                try cssCopyQuoted(allocator, &out, input, &i, c);
            }
            continue;
        }

        if (cssIsWs(c)) {
            pendingSpace = true;
            i += 1;
            continue;
        }

        if ((c == '+' or c == '-') and cssIsInsideMathFunction(out.items)) {
            try cssFlushSpace(allocator, &out, &pendingSpace);
            try out.append(allocator, c);
            try out.append(allocator, ' ');
            pendingSpace = false;
            i += 1;
            while (i < n and cssIsWs(input[i])) i += 1;
            continue;
        }

        if (c == '#' and cssIsInsideDeclarationValue(out.items) and !cssIsInsideUrlCall(out.items)) {
            var handled = false;
            if (cssCurrentDeclarationProperty(out.items)) |prop| {
                if (cssIsColorProperty(prop)) {
                    if (try cssTryShortenHexColorToName(allocator, input, i)) |result| {
                        try cssFlushSpace(allocator, &out, &pendingSpace);
                        try out.appendSlice(allocator, result.text);
                        allocator.free(result.text);
                        i += result.consumed;
                        handled = true;
                    }
                }
            }
            if (handled) continue;
            if (cssTryShortenHexColor(input, i)) |consumed| {
                try cssFlushSpace(allocator, &out, &pendingSpace);
                try cssWriteShortHex(allocator, &out, input[i .. i + consumed]);
                i += consumed;
                continue;
            }
        }

        if (cssIsIdentStart(c) and cssIsAtIdentBoundary(out.items)) {
            if (cssCurrentDeclarationProperty(out.items)) |prop| {
                if (cssIsColorProperty(prop)) {
                    if (try cssTryRewriteColorFunction(allocator, input, i)) |result| {
                        try cssFlushSpace(allocator, &out, &pendingSpace);
                        try out.appendSlice(allocator, result.text);
                        allocator.free(result.text);
                        i += result.consumed;
                        continue;
                    }
                    if (try cssTryShortenNamedColor(allocator, input, i)) |result| {
                        try cssFlushSpace(allocator, &out, &pendingSpace);
                        try out.appendSlice(allocator, result.text);
                        allocator.free(result.text);
                        i += result.consumed;
                        continue;
                    }
                }
            }
        }

        if (c == '{' or c == '}' or c == ':' or c == ';' or c == ',' or c == '>' or c == '~' or c == '+' or c == '(' or c == ')') {
            if (c == '(' and pendingSpace and cssIsMediaKeywordBeforeParen(out.items)) {
                // A space before `(` must survive here: `and(`/`or(`/`not(`
                // parses as a function token, not the media-query/@supports
                // keyword followed by a group - see the errata to the media
                // queries spec.
                try out.append(allocator, ' ');
                pendingSpace = false;
                try out.append(allocator, c);
                i += 1;
                continue;
            }
            cssTrimTrailingSpace(&out);
            pendingSpace = false;
            if (c == '}' and out.items.len > 0 and out.items[out.items.len - 1] == ';') {
                _ = out.pop();
            }
            try out.append(allocator, c);
            i += 1;
            if (c == '(' and cssIsInsideUrlFunction(out.items)) {
                if (try cssTryCopyUnquotedUrlSvgBody(allocator, &out, input, &i, svgArgs)) continue;
            }
            continue;
        }

        try cssFlushSpace(allocator, &out, &pendingSpace);
        try out.append(allocator, c);
        i += 1;
    }

    const combined = try cssCombineShorthands(allocator, out.items);
    out.deinit(allocator);
    const shortened = try cssShortenPositionValues(allocator, combined);
    allocator.free(combined);
    const zeroed = try cssTrimZeroUnits(allocator, shortened);
    allocator.free(shortened);
    const merged = try cssMergeAdjacentRules(allocator, zeroed);
    allocator.free(zeroed);
    const folded = try cssFoldCalc(allocator, merged);
    allocator.free(merged);
    return folded;
}

// A group of longhand properties that combine into one shorthand,
// in the value order the shorthand expects (top/right/bottom/left
// for the box properties below).
const CssShorthandGroup = struct {
    shorthand: []const u8,
    longhands: [4][]const u8,
};

const cssShorthandGroups = [_]CssShorthandGroup{
    .{ .shorthand = "margin", .longhands = .{ "margin-top", "margin-right", "margin-bottom", "margin-left" } },
    .{ .shorthand = "padding", .longhands = .{ "padding-top", "padding-right", "padding-bottom", "padding-left" } },
    .{ .shorthand = "border-width", .longhands = .{ "border-top-width", "border-right-width", "border-bottom-width", "border-left-width" } },
    .{ .shorthand = "border-style", .longhands = .{ "border-top-style", "border-right-style", "border-bottom-style", "border-left-style" } },
    .{ .shorthand = "border-color", .longhands = .{ "border-top-color", "border-right-color", "border-bottom-color", "border-left-color" } },
};

const CssDecl = struct {
    property: []const u8,
    value: []const u8, // trimmed, with any trailing "!important" already stripped
    important: bool,
};

// Rewrites every rule block's declaration list, combining any
// contiguous, complete, `!important`-consistent run of a shorthand
// group's longhands into the single shorthand declaration. Runs a
// second pass over the already-minified text rather than folding
// into the main scan, since combining needs to see a whole
// declaration list at once instead of one token at a time.
fn cssCombineShorthands(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: CssBuf = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    var copiedUpTo: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == '"' or c == '\'') {
            i += 1;
            while (i < input.len and input[i] != c) {
                i += if (input[i] == '\\' and i + 1 < input.len) 2 else 1;
            }
            i += @intFromBool(i < input.len);
            continue;
        }
        if (c == '{') {
            const blockStart = i + 1;
            const blockEnd = cssFindMatchingBrace(input, blockStart) orelse {
                i += 1;
                continue;
            };
            var decls = try cssSplitDeclarations(allocator, input[blockStart..blockEnd]);
            defer decls.deinit(allocator);

            // An empty `decls` here means either a genuinely empty
            // block or one holding a nested rule (e.g. inside
            // `@media`) rather than a flat declaration list; either
            // way step in one token at a time so a nested block's own
            // `{` is found and combined on a later iteration.
            if (decls.items.len > 0 and cssBlockNeedsCombining(decls.items)) {
                try out.appendSlice(allocator, input[copiedUpTo..blockStart]);
                try cssWriteCombinedBlock(allocator, &out, decls.items);
                copiedUpTo = blockEnd + 1; // cssWriteCombinedBlock already wrote the `}`
                i = blockEnd + 1;
                continue;
            }
            i = blockStart;
            continue;
        }
        i += 1;
    }
    try out.appendSlice(allocator, input[copiedUpTo..]);
    return out.toOwnedSlice(allocator);
}

fn cssFindMatchingBrace(input: []const u8, start: usize) ?usize {
    var i = start;
    var depth: i32 = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == '"' or c == '\'') {
            i += 1;
            while (i < input.len and input[i] != c) {
                i += if (input[i] == '\\' and i + 1 < input.len) 2 else 1;
            }
            i += @intFromBool(i < input.len);
            continue;
        }
        if (c == '{') depth += 1;
        if (c == '}') {
            if (depth == 0) return i;
            depth -= 1;
        }
        i += 1;
    }
    return null;
}

// Splits the declaration list of one rule block (the text strictly
// between its `{` and `}`) on top-level `;`, skipping over nested
// parens and quoted strings so a `;` inside e.g. a data-URI or
// `content` string doesn't split a declaration in half. A nested
// rule block (a `{` before the next `;`) is skipped rather than
// combined across: it returns an empty list.
fn cssSplitDeclarations(allocator: std.mem.Allocator, block: []const u8) !std.ArrayList(CssDecl) {
    var decls: std.ArrayList(CssDecl) = .empty;
    errdefer decls.deinit(allocator);

    var i: usize = 0;
    var declStart: usize = 0;
    var parenDepth: i32 = 0;
    while (i < block.len) {
        const c = block[i];
        if (c == '"' or c == '\'') {
            i += 1;
            while (i < block.len and block[i] != c) {
                i += if (block[i] == '\\' and i + 1 < block.len) 2 else 1;
            }
            i += @intFromBool(i < block.len);
            continue;
        }
        if (c == '{') {
            decls.clearRetainingCapacity();
            return decls;
        }
        if (c == '(') {
            parenDepth += 1;
        } else if (c == ')') {
            parenDepth -= 1;
        } else if (c == ';' and parenDepth == 0) {
            cssAppendDecl(&decls, allocator, block[declStart..i]) catch {};
            declStart = i + 1;
        }
        i += 1;
    }
    if (declStart < block.len) {
        cssAppendDecl(&decls, allocator, block[declStart..block.len]) catch {};
    }
    return decls;
}

fn cssAppendDecl(decls: *std.ArrayList(CssDecl), allocator: std.mem.Allocator, text: []const u8) !void {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.NotADeclaration;
    const property = text[0..colon];
    if (property.len == 0 or !cssIsIdentChar(property[0])) return error.NotADeclaration;

    var value = text[colon + 1 ..];
    var important = false;
    if (std.ascii.endsWithIgnoreCase(value, "!important")) {
        important = true;
        value = std.mem.trimEnd(u8, value[0 .. value.len - "!important".len], " \t\n!");
    }
    try decls.append(allocator, .{ .property = property, .value = value, .important = important });
}

fn cssBlockNeedsCombining(decls: []const CssDecl) bool {
    for (cssShorthandGroups) |group| {
        var start: usize = 0;
        while (start + group.longhands.len <= decls.len) : (start += 1) {
            if (cssRunAt(decls, start, group) != null) return true;
        }
    }
    return false;
}

const CssCombinableRun = struct { from: usize, to: usize }; // [from, to) into decls, len 4

fn cssLonghandSlot(group: CssShorthandGroup, property: []const u8) ?usize {
    for (group.longhands, 0..) |name, idx| {
        if (std.mem.eql(u8, property, name)) return idx;
    }
    return null;
}

// Rewrites one rule block's declaration list, replacing every
// combinable run with its shorthand and copying every other
// declaration through unchanged, each still separated by `;`.
fn cssWriteCombinedBlock(allocator: std.mem.Allocator, out: *CssBuf, decls: []const CssDecl) !void {
    var idx: usize = 0;
    var wroteAny = false;
    while (idx < decls.len) {
        var matchedGroup: ?CssShorthandGroup = null;
        var run: CssCombinableRun = undefined;
        for (cssShorthandGroups) |group| {
            if (idx + group.longhands.len <= decls.len) {
                if (cssRunAt(decls, idx, group)) |r| {
                    matchedGroup = group;
                    run = r;
                    break;
                }
            }
        }

        if (wroteAny) try out.append(allocator, ';');
        if (matchedGroup) |group| {
            try cssWriteCombinedDecl(allocator, out, decls[run.from..run.to], group);
            idx = run.to;
        } else {
            const d = decls[idx];
            try out.appendSlice(allocator, d.property);
            try out.append(allocator, ':');
            try out.appendSlice(allocator, d.value);
            if (d.important) try out.appendSlice(allocator, "!important");
            idx += 1;
        }
        wroteAny = true;
    }
    try out.append(allocator, '}');
}

// Whether `decls[idx..idx+4]` covers each of `group`'s longhands
// exactly once with a consistent `!important`.
fn cssRunAt(decls: []const CssDecl, idx: usize, group: CssShorthandGroup) ?CssCombinableRun {
    var seen: [4]bool = .{ false, false, false, false };
    const important = decls[idx].important;
    for (0..group.longhands.len) |offset| {
        const d = decls[idx + offset];
        const slot = cssLonghandSlot(group, d.property) orelse return null;
        if (seen[slot] or d.important != important) return null;
        seen[slot] = true;
    }
    return .{ .from = idx, .to = idx + group.longhands.len };
}

fn cssWriteCombinedDecl(allocator: std.mem.Allocator, out: *CssBuf, run: []const CssDecl, group: CssShorthandGroup) !void {
    var values: [4][]const u8 = undefined;
    for (run) |d| {
        values[cssLonghandSlot(group, d.property).?] = d.value;
    }

    try out.appendSlice(allocator, group.shorthand);
    try out.append(allocator, ':');
    try cssWriteBoxValueOrder(allocator, out, values);
    if (run[0].important) try out.appendSlice(allocator, "!important");
}

// Writes top/right/bottom/left values using the shortest equivalent
// CSS box shorthand form - trailing values that repeat an earlier one
// in [top right bottom left] order are omitted: left dropped when it
// equals right, then bottom when it equals top, then right when it
// equals top.
fn cssWriteBoxValueOrder(allocator: std.mem.Allocator, out: *CssBuf, values: [4][]const u8) !void {
    const top = values[0];
    const right = values[1];
    const bottom = values[2];
    const left = values[3];

    var count: usize = 4;
    if (std.mem.eql(u8, left, right)) {
        count = 3;
        if (std.mem.eql(u8, bottom, top)) {
            count = 2;
            if (std.mem.eql(u8, right, top)) count = 1;
        }
    }

    try out.appendSlice(allocator, top);
    if (count >= 2) {
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, right);
    }
    if (count >= 3) {
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, bottom);
    }
    if (count >= 4) {
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, left);
    }
}

// Walks every rule block's declaration list, calling `rewriteValue`
// on each declaration's value; a block is rewritten only if at least
// one declaration's value actually changes, so blocks needing no
// change are byte-for-byte copied through untouched.
fn cssRewriteDeclValues(
    allocator: std.mem.Allocator,
    input: []const u8,
    rewriteValue: *const fn (property: []const u8, value: []const u8) []const u8,
) ![]u8 {
    var out: CssBuf = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    var copiedUpTo: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == '"' or c == '\'') {
            i += 1;
            while (i < input.len and input[i] != c) {
                i += if (input[i] == '\\' and i + 1 < input.len) 2 else 1;
            }
            i += @intFromBool(i < input.len);
            continue;
        }
        if (c == '{') {
            const blockStart = i + 1;
            const blockEnd = cssFindMatchingBrace(input, blockStart) orelse {
                i += 1;
                continue;
            };
            var decls = try cssSplitDeclarations(allocator, input[blockStart..blockEnd]);
            defer decls.deinit(allocator);

            var needsRewrite = false;
            for (decls.items) |d| {
                if (rewriteValue(d.property, d.value).len != d.value.len) {
                    needsRewrite = true;
                    break;
                }
            }

            if (needsRewrite) {
                try out.appendSlice(allocator, input[copiedUpTo..blockStart]);
                for (decls.items, 0..) |d, idx| {
                    if (idx > 0) try out.append(allocator, ';');
                    try out.appendSlice(allocator, d.property);
                    try out.append(allocator, ':');
                    try out.appendSlice(allocator, rewriteValue(d.property, d.value));
                    if (d.important) try out.appendSlice(allocator, "!important");
                }
                try out.append(allocator, '}');
                copiedUpTo = blockEnd + 1;
                i = blockEnd + 1;
                continue;
            }
            i = blockStart;
            continue;
        }
        i += 1;
    }
    try out.appendSlice(allocator, input[copiedUpTo..]);
    return out.toOwnedSlice(allocator);
}

// Two-value (or, for transform-origin, three-value) position
// shorthands: `x y` where a trailing `center` (the axis default)
// can be dropped, and `center center` collapses to just `center`.
const cssPositionProperties = [_][]const u8{
    "background-position",
    "object-position",
    "perspective-origin",
    "transform-origin",
};

fn cssIsPositionProperty(name: []const u8) bool {
    for (cssPositionProperties) |p| {
        if (std.ascii.eqlIgnoreCase(name, p)) return true;
    }
    return false;
}

// Drops a trailing `center` from a position value's x/y pair, since
// `center` is the default for the second axis: `left center` -> `left`,
// `center center` -> `center`. Left alone for anything but a plain
// two-token value - `transform-origin`'s optional third (z) token,
// percentages, multi-position `background-position` lists (commas),
// and `var()`/`calc()` all take the value untouched.
fn cssShortenPositionValue(property: []const u8, value: []const u8) []const u8 {
    if (!cssIsPositionProperty(property)) return value;
    var it = std.mem.splitScalar(u8, value, ' ');
    const first = it.next() orelse return value;
    const second = it.next() orelse return value;
    if (it.next() != null) return value;
    if (!std.ascii.eqlIgnoreCase(second, "center")) return value;
    return value[0..first.len];
}

fn cssShortenPositionValues(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return cssRewriteDeclValues(allocator, input, cssShortenPositionValue);
}

// Length and angle units where CSS defines a bare `0` as equivalent -
// see https://www.w3.org/TR/css-values-4/#lengths and #angles. Every
// other numeric unit (time, frequency, resolution, flex) requires its
// unit even at zero, so is deliberately left out.
const cssZeroableUnits = [_][]const u8{
    "px",  "em",   "rem", "ex",   "ch", "vw", "vh", "vmin", "vmax", "cm", "mm", "q", "in", "pt", "pc",
    "deg", "grad", "rad", "turn",
};

// Whether `token` is a zero length/angle with a droppable unit or an
// unnecessarily-signed/decimal spelling of unitless zero - `0px`,
// `-0`, `+0`, `0.0` all become `0`; anything else (a nonzero number,
// an unrecognized or non-length/angle unit, `0%` is handled by callers
// that special-case percent) is returned unchanged.
fn cssZeroedToken(token: []const u8) ?[]const u8 {
    var i: usize = 0;
    if (i < token.len and (token[i] == '+' or token[i] == '-')) i += 1;
    const digitsStart = i;
    var sawNonZeroDigit = false;
    while (i < token.len and ((token[i] >= '0' and token[i] <= '9') or token[i] == '.')) {
        if (token[i] >= '1' and token[i] <= '9') sawNonZeroDigit = true;
        i += 1;
    }
    if (i == digitsStart or sawNonZeroDigit) return null;

    const unit = token[i..];
    if (unit.len == 0) {
        return if (token.len != 1 or token[0] != '0') "0" else null;
    }
    if (std.mem.eql(u8, unit, "%")) return "0%";
    for (cssZeroableUnits) |u| {
        if (std.ascii.eqlIgnoreCase(unit, u)) return "0";
    }
    return null;
}

// Strips the unit off every zero length/angle token in a declaration
// value, skipping anything inside a function call - a bare top-level,
// space-separated token is the only shape this is safe for: a zero
// argument to `rgb()`/`hsl()`/`calc()`/a custom property, for example,
// may need to keep a type-specific unit to stay valid or keep its
// meaning, and this pass has no per-function knowledge to tell.
fn cssTrimZeroUnitsValue(allocator: std.mem.Allocator, value: []const u8) !?[]u8 {
    if (std.mem.indexOfScalar(u8, value, '(') != null) return null;

    var changed = false;
    var it = std.mem.splitScalar(u8, value, ' ');
    while (it.next()) |token| {
        if (cssZeroedToken(token)) |z| {
            if (!std.mem.eql(u8, z, token)) changed = true;
        }
    }
    if (!changed) return null;

    var out: CssBuf = .empty;
    errdefer out.deinit(allocator);
    it = std.mem.splitScalar(u8, value, ' ');
    var wroteAny = false;
    while (it.next()) |token| {
        if (wroteAny) try out.append(allocator, ' ');
        try out.appendSlice(allocator, cssZeroedToken(token) orelse token);
        wroteAny = true;
    }
    return try out.toOwnedSlice(allocator);
}

// Rewrites every rule block's declaration list, dropping the unit off
// any zero length/angle token found at the top level of a value.
fn cssTrimZeroUnits(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: CssBuf = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    var copiedUpTo: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == '"' or c == '\'') {
            i += 1;
            while (i < input.len and input[i] != c) {
                i += if (input[i] == '\\' and i + 1 < input.len) 2 else 1;
            }
            i += @intFromBool(i < input.len);
            continue;
        }
        if (c == '{') {
            const blockStart = i + 1;
            const blockEnd = cssFindMatchingBrace(input, blockStart) orelse {
                i += 1;
                continue;
            };
            var decls = try cssSplitDeclarations(allocator, input[blockStart..blockEnd]);
            defer decls.deinit(allocator);

            var rewritten = try allocator.alloc(?[]u8, decls.items.len);
            defer {
                for (rewritten) |r| if (r) |v| allocator.free(v);
                allocator.free(rewritten);
            }
            var needsRewrite = false;
            for (decls.items, 0..) |d, idx| {
                rewritten[idx] = try cssTrimZeroUnitsValue(allocator, d.value);
                if (rewritten[idx] != null) needsRewrite = true;
            }

            if (needsRewrite) {
                try out.appendSlice(allocator, input[copiedUpTo..blockStart]);
                for (decls.items, 0..) |d, idx| {
                    if (idx > 0) try out.append(allocator, ';');
                    try out.appendSlice(allocator, d.property);
                    try out.append(allocator, ':');
                    try out.appendSlice(allocator, rewritten[idx] orelse d.value);
                    if (d.important) try out.appendSlice(allocator, "!important");
                }
                try out.append(allocator, '}');
                copiedUpTo = blockEnd + 1;
                i = blockEnd + 1;
                continue;
            }
            i = blockStart;
            continue;
        }
        i += 1;
    }
    try out.appendSlice(allocator, input[copiedUpTo..]);
    return out.toOwnedSlice(allocator);
}

// One top-level rule: `selector{declBlock}`, spans into the source
// text. `declBlock` excludes the braces; a rule whose block holds a
// nested rule (an `@media` etc) has `isNested = true` and is never a
// merge candidate itself, though its contents get walked separately.
const CssRule = struct {
    selector: []const u8,
    declBlock: []const u8,
    start: usize, // offset of `selector` in the source text
    end: usize, // offset just past the closing `}`
    isNested: bool,
};

// Merges directly adjacent rules that share either selector or
// declarations: `.a{color:red}.b{color:red}` becomes
// `.a,.b{color:red}` (shared declarations, selectors joined), and
// `.a{color:red}.a{margin:0}` becomes `.a{color:red;margin:0}`
// (shared selector, declarations concatenated - safe regardless of
// property overlap, since concatenation preserves the original
// cascade order). Only ever merges rules sitting back-to-back in the
// source, so no reasoning about what a rule in between might override
// is needed. An `@`-prefixed selector (`@media`, `@font-face`, ...)
// is never merged into a neighbor, since two at-rules sharing a
// declaration-shaped body don't mean the same thing as two style
// rules would.
fn cssMergeAdjacentRules(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: CssBuf = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    var copiedUpTo: usize = 0;
    while (i < input.len) {
        const rule = cssParseRuleAt(input, i) orelse {
            i = cssSkipOneToken(input, i);
            continue;
        };
        if (rule.isNested or cssSelectorIsAtRule(rule.selector)) {
            // Recurse into the block's own contents rather than
            // treating the whole thing as one opaque span, so a
            // nested rule inside e.g. `@media` still gets merged
            // with its own siblings.
            i = rule.start + rule.selector.len + 1;
            continue;
        }

        var run: std.ArrayList(CssRule) = .empty;
        defer run.deinit(allocator);
        try run.append(allocator, rule);
        var next = cssParseRuleAt(input, rule.end);
        var mode: enum { undecided, sameSelector, sameDecls } = .undecided;
        while (next) |n| {
            if (n.isNested or cssSelectorIsAtRule(n.selector)) break;
            switch (mode) {
                .undecided => {
                    if (std.mem.eql(u8, rule.selector, n.selector)) {
                        mode = .sameSelector;
                    } else if (std.mem.eql(u8, rule.declBlock, n.declBlock)) {
                        mode = .sameDecls;
                    } else break;
                },
                .sameSelector => if (!std.mem.eql(u8, rule.selector, n.selector)) break,
                .sameDecls => if (!std.mem.eql(u8, rule.declBlock, n.declBlock)) break,
            }
            try run.append(allocator, n);
            next = cssParseRuleAt(input, n.end);
        }

        if (run.items.len == 1) {
            i = rule.end;
            continue;
        }

        try out.appendSlice(allocator, input[copiedUpTo..rule.start]);
        try cssWriteMergedRun(allocator, &out, run.items, mode == .sameDecls);
        copiedUpTo = run.items[run.items.len - 1].end;
        i = copiedUpTo;
    }
    try out.appendSlice(allocator, input[copiedUpTo..]);
    return out.toOwnedSlice(allocator);
}

fn cssSkipOneToken(input: []const u8, i: usize) usize {
    if (input[i] == '"' or input[i] == '\'') {
        const quote = input[i];
        var j = i + 1;
        while (j < input.len and input[j] != quote) {
            j += if (input[j] == '\\' and j + 1 < input.len) 2 else 1;
        }
        return j + @intFromBool(j < input.len);
    }
    return i + 1;
}

fn cssSelectorIsAtRule(selector: []const u8) bool {
    return selector.len > 0 and selector[0] == '@';
}

// Parses one `selector{declBlock}` rule starting exactly at `start`
// (which must sit at the first byte of the selector - a prior sibling
// rule's `end`, or a scan position already known to be at a
// selector). Returns null if `start` isn't the beginning of a
// selector - e.g. it's mid-way through a value, or there's no rule
// left to parse before the end of input.
fn cssParseRuleAt(input: []const u8, start: usize) ?CssRule {
    if (start >= input.len) return null;
    var i = start;
    var parenDepth: i32 = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == '"' or c == '\'') {
            i = cssSkipOneToken(input, i);
            continue;
        }
        if (c == '(') parenDepth += 1;
        if (c == ')') parenDepth -= 1;
        if (c == '{' and parenDepth == 0) {
            const selector = input[start..i];
            const blockStart = i + 1;
            const blockEnd = cssFindMatchingBrace(input, blockStart) orelse return null;
            const declBlock = input[blockStart..blockEnd];
            return .{
                .selector = selector,
                .declBlock = declBlock,
                .start = start,
                .end = blockEnd + 1,
                .isNested = std.mem.indexOfScalar(u8, declBlock, '{') != null,
            };
        }
        if (c == ';' or c == '}') return null; // not sitting at a selector
        i += 1;
    }
    return null;
}

fn cssWriteMergedRun(allocator: std.mem.Allocator, out: *CssBuf, run: []const CssRule, sameDecls: bool) !void {
    if (sameDecls) {
        for (run, 0..) |r, idx| {
            if (idx > 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, r.selector);
        }
        try out.append(allocator, '{');
        try out.appendSlice(allocator, run[0].declBlock);
        try out.append(allocator, '}');
        return;
    }

    // Same selector, different declarations - concatenate the blocks
    // in source order so a later duplicate property still wins.
    try out.appendSlice(allocator, run[0].selector);
    try out.append(allocator, '{');
    var wroteAny = false;
    for (run) |r| {
        if (r.declBlock.len == 0) continue;
        if (wroteAny) try out.append(allocator, ';');
        try out.appendSlice(allocator, r.declBlock);
        wroteAny = true;
    }
    try out.append(allocator, '}');
}

// A resolved calc() operand: a plain number (`unit.len == 0`) or a
// dimensioned value (`10px`, `50%`). Arithmetic between two operands
// is only defined when the shapes line up - see cssEvalCalcExpr.
const CssCalcValue = struct {
    number: f64,
    unit: []const u8,
};

// Scans for every top-level `calc(...)` call (case-insensitive, at an
// identifier boundary so e.g. `foo-calc(` doesn't match) and replaces
// it with a single resolved number where the whole expression folds
// to one - `calc(100px * 2)` -> `200px`. A nested `calc(`/`min(`/etc,
// a `var()`, or any operand this parser doesn't resolve leaves that
// whole `calc(...)` span untouched, since a partial fold could change
// meaning (e.g. losing the `calc()` wrapper that makes a mixed-unit
// expression valid at all).
fn cssFoldCalc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: CssBuf = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    var copiedUpTo: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == '"' or c == '\'') {
            i = cssSkipOneToken(input, i);
            continue;
        }
        if (cssIsIdentStart(c) and (i == 0 or !cssIsIdentChar(input[i - 1]))) {
            const nameEnd = i + 4; // "calc".len
            if (nameEnd < input.len and std.ascii.eqlIgnoreCase(input[i..nameEnd], "calc") and input[nameEnd] == '(') {
                const argsStart = nameEnd + 1;
                if (cssFindMatchingParen(input, argsStart)) |argsEnd| {
                    if (cssEvalCalcExpr(input[argsStart..argsEnd])) |result| {
                        try out.appendSlice(allocator, input[copiedUpTo..i]);
                        try cssWriteCalcValue(allocator, &out, result);
                        copiedUpTo = argsEnd + 1;
                        i = argsEnd + 1;
                        continue;
                    }
                    // Not fully resolvable - leave it alone, but still
                    // skip straight past the closing paren so a folded
                    // operand doesn't get mistaken for its own call.
                    i = argsEnd + 1;
                    continue;
                }
            }
        }
        i += 1;
    }
    try out.appendSlice(allocator, input[copiedUpTo..]);
    return out.toOwnedSlice(allocator);
}

// Finds the `)` matching the `(` implicitly opened just before
// `start` (i.e. `start` is the first byte of the arguments), skipping
// over quoted strings and any nested parens.
fn cssFindMatchingParen(input: []const u8, start: usize) ?usize {
    var i = start;
    var depth: i32 = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == '"' or c == '\'') {
            i = cssSkipOneToken(input, i);
            continue;
        }
        if (c == '(') depth += 1;
        if (c == ')') {
            if (depth == 0) return i;
            depth -= 1;
        }
        i += 1;
    }
    return null;
}

fn cssWriteCalcValue(allocator: std.mem.Allocator, out: *CssBuf, value: CssCalcValue) !void {
    var buf: [64]u8 = undefined;
    const text = cssFormatCalcNumber(&buf, value.number);
    try out.appendSlice(allocator, text);
    try out.appendSlice(allocator, value.unit);
}

// Formats a resolved calc() number as CSS-legal shortest text: an
// integer whenever the value is a whole number (calc() results are
// rounded to avoid float noise like `29.999999999999996`), otherwise
// up to 5 fractional digits with trailing zeros trimmed.
fn cssFormatCalcNumber(buf: *[64]u8, value: f64) []const u8 {
    var v = value;
    if (v == 0) v = 0; // collapses -0.0 to 0.0
    if (@abs(v - @round(v)) < 1e-9) {
        return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(@round(v)))}) catch "0";
    }
    const rounded = std.fmt.bufPrint(buf, "{d:.5}", .{v}) catch return "0";
    var s: []const u8 = rounded;
    s = std.mem.trimEnd(u8, s, "0");
    s = std.mem.trimEnd(u8, s, ".");
    return s;
}

// Recursive-descent evaluator for the contents of one `calc(...)`
// call: `expr := term (('+'|'-') term)*`, `term := factor (('*'|'/')
// factor)*`, `factor := number unit? | '(' expr ')'`. Returns null
// (leave the source untouched) for anything outside that grammar -
// `var()`, a nested math function, a bare identifier/keyword operand
// - and for any `+`/`-` between two operands whose units don't allow
// static addition (different non-empty units; a unitless number can
// only combine with another unitless number via `+`/`-`, since
// `calc(1 + 2px)` isn't valid CSS to begin with).
fn cssEvalCalcExpr(text: []const u8) ?CssCalcValue {
    var pos: usize = 0;
    const result = cssParseCalcSum(text, &pos) orelse return null;
    cssSkipCalcWs(text, &pos);
    if (pos != text.len) return null; // trailing junk - not a clean expression
    return result;
}

fn cssSkipCalcWs(text: []const u8, pos: *usize) void {
    while (pos.* < text.len and cssIsWs(text[pos.*])) pos.* += 1;
}

fn cssParseCalcSum(text: []const u8, pos: *usize) ?CssCalcValue {
    var acc = cssParseCalcProduct(text, pos) orelse return null;
    while (true) {
        cssSkipCalcWs(text, pos);
        if (pos.* >= text.len or (text[pos.*] != '+' and text[pos.*] != '-')) break;
        const op = text[pos.*];
        pos.* += 1;
        cssSkipCalcWs(text, pos);
        const rhs = cssParseCalcProduct(text, pos) orelse return null;
        acc = cssAddCalcValues(acc, rhs, op) orelse return null;
    }
    return acc;
}

fn cssAddCalcValues(lhs: CssCalcValue, rhs: CssCalcValue, op: u8) ?CssCalcValue {
    if (!std.mem.eql(u8, lhs.unit, rhs.unit)) return null; // mixed units - not statically foldable
    const n = if (op == '+') lhs.number + rhs.number else lhs.number - rhs.number;
    return .{ .number = n, .unit = lhs.unit };
}

fn cssParseCalcProduct(text: []const u8, pos: *usize) ?CssCalcValue {
    var acc = cssParseCalcFactor(text, pos) orelse return null;
    while (true) {
        cssSkipCalcWs(text, pos);
        if (pos.* >= text.len or (text[pos.*] != '*' and text[pos.*] != '/')) break;
        const op = text[pos.*];
        pos.* += 1;
        cssSkipCalcWs(text, pos);
        const rhs = cssParseCalcFactor(text, pos) orelse return null;
        acc = cssMulCalcValues(acc, rhs, op) orelse return null;
    }
    return acc;
}

// `*`/`/` are only defined in calc() when at least one side is a
// plain unitless number - `10px * 2px` isn't valid CSS (nothing
// multiplies units together into a new unit here), and division
// specifically requires the right side to be unitless.
fn cssMulCalcValues(lhs: CssCalcValue, rhs: CssCalcValue, op: u8) ?CssCalcValue {
    if (op == '*') {
        if (lhs.unit.len == 0) return .{ .number = lhs.number * rhs.number, .unit = rhs.unit };
        if (rhs.unit.len == 0) return .{ .number = lhs.number * rhs.number, .unit = lhs.unit };
        return null;
    }
    if (rhs.unit.len != 0) return null;
    if (rhs.number == 0) return null; // division by zero - leave the source alone
    return .{ .number = lhs.number / rhs.number, .unit = lhs.unit };
}

fn cssParseCalcFactor(text: []const u8, pos: *usize) ?CssCalcValue {
    cssSkipCalcWs(text, pos);
    if (pos.* < text.len and text[pos.*] == '(') {
        pos.* += 1;
        const inner = cssParseCalcSum(text, pos) orelse return null;
        cssSkipCalcWs(text, pos);
        if (pos.* >= text.len or text[pos.*] != ')') return null;
        pos.* += 1;
        return inner;
    }
    return cssParseCalcNumber(text, pos);
}

fn cssParseCalcNumber(text: []const u8, pos: *usize) ?CssCalcValue {
    const start = pos.*;
    var i = pos.*;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
    var sawDigit = false;
    while (i < text.len and ((text[i] >= '0' and text[i] <= '9') or text[i] == '.')) {
        if (text[i] != '.') sawDigit = true;
        i += 1;
    }
    if (!sawDigit) return null; // not a number at all - bare keyword/ident operand etc.

    const numText = text[start..i];
    const number = std.fmt.parseFloat(f64, numText) catch return null;

    var unitEnd = i;
    if (unitEnd < text.len and text[unitEnd] == '%') {
        unitEnd += 1;
    } else {
        while (unitEnd < text.len and cssIsIdentChar(text[unitEnd])) unitEnd += 1;
    }
    const unit = text[i..unitEnd];
    pos.* = unitEnd;
    return .{ .number = number, .unit = unit };
}

// Whether the most recently emitted `:` belongs to a grid-template
// property, whose quoted string values get dedicated row serialization
// (each row is one string; runs of `.` collapse to a single null-cell
// token; cells are separated by exactly one space) rather than being
// preserved verbatim like an ordinary CSS string.
const cssGridTemplateProps = [_][]const u8{ "grid-template-areas", "grid-template", "grid" };

fn cssIsInsideGridTemplateValue(items: []const u8) bool {
    var i: usize = items.len;
    var parenDepth: i32 = 0;
    while (i > 0) {
        i -= 1;
        const c = items[i];
        if (c == '{' or c == ';' or c == '}') return false;
        if (c == ')') {
            parenDepth += 1;
            continue;
        }
        if (c == '(') {
            if (parenDepth == 0) return false;
            parenDepth -= 1;
            continue;
        }
        if (c == ':' and parenDepth == 0) {
            var nameEnd = i;
            while (nameEnd > 0 and (items[nameEnd - 1] == ' ')) nameEnd -= 1;
            var nameStart = nameEnd;
            while (nameStart > 0 and cssIsIdentChar(items[nameStart - 1])) nameStart -= 1;
            const name = items[nameStart..nameEnd];
            for (cssGridTemplateProps) |p| {
                if (std.ascii.eqlIgnoreCase(name, p)) return true;
            }
            return false;
        }
    }
    return false;
}

// Whether the position about to be written is currently inside the
// parens of a `url(...)` call (unquoted form) already emitted to
// `items` - used to keep hex-color shortening away from URL text,
// e.g. a fragment identifier like `url(icon.svg#aabbcc)` must never
// be rewritten to `url(icon.svg#abc)`.
fn cssIsInsideUrlCall(items: []const u8) bool {
    var depth: i32 = 0;
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        const c = items[i];
        if (c == ')') depth += 1;
        if (c == '(') {
            if (depth == 0) {
                var nameEnd = i;
                while (nameEnd > 0 and cssIsIdentChar(items[nameEnd - 1])) nameEnd -= 1;
                return std.ascii.eqlIgnoreCase(items[nameEnd..i], "url");
            }
            depth -= 1;
        }
        if (c == '{' or c == '}' or c == ';') return false;
    }
    return false;
}

// Whether the position about to be written is inside a declaration's
// *value* (after its `:`, before the terminating `;`/`}`), as opposed
// to selector text or an at-rule prelude. `#rrggbb` is only ever a
// color in value position - in a selector `#abcdef{...}` is an ID
// selector and must never be rewritten.
//
// A pseudo-class colon (`:hover`, `::before`) looks identical to a
// declaration colon by itself, so this also checks what precedes the
// identifier before the `:`: a property name is always the first
// thing in its declaration, immediately after `{`, `;`, or the start
// of the buffer (whitespace never survives in the already-minified
// `out` buffer at a point like this) - a pseudo-class's identifier is
// preceded by more selector text instead (a tag name, `.`, `#`, `&`,
// or a combinator).
fn cssIsInsideDeclarationValue(items: []const u8) bool {
    return cssCurrentDeclarationProperty(items) != null;
}

// Returns the property name of the declaration `items` currently sits
// inside the value of (e.g. "color" for "...;color:"), or null if
// `items` isn't in declaration-value position at all. Used both by
// the plain value-position check above and by color-value rewriting,
// which needs to know the specific property to stay inside a known
// color-accepting allowlist - the same identifier text is a valid,
// unrelated value in other properties (a font named "Coral", an
// animation-name, a counter name), so rewriting must not apply blind.
//
// `parenDepth` counts, walking backward: `)` for a pair fully closed
// within what's been scanned so far (+1, skip its contents), `(` for
// stepping back out of a pair - including one whose `)` was never
// seen because the scan started inside it, e.g. a color nested inside
// `linear-gradient(...)` within the value (this can drive depth
// negative, which is fine: negative just means "outside N enclosing
// parens relative to the scan start", so `:`/`{`/`}`/`;` there are
// real declaration-level structure again, not further-nested value
// text). Only depth > 0 - meaning we're still inside a pair that
// closed somewhere in the scanned region - means keep skipping.
fn cssCurrentDeclarationProperty(items: []const u8) ?[]const u8 {
    var i: usize = items.len;
    var parenDepth: i32 = 0;
    while (i > 0) {
        i -= 1;
        const c = items[i];
        if (c == ')') {
            parenDepth += 1;
            continue;
        }
        if (c == '(') {
            parenDepth -= 1;
            continue;
        }
        if (parenDepth > 0) continue;
        if (c == ':') return cssPropertyNameBeforeColon(items, i);
        if (c == '{' or c == '}' or c == ';') return null;
    }
    return null;
}

fn cssPropertyNameBeforeColon(items: []const u8, colonPos: usize) ?[]const u8 {
    var nameStart = colonPos;
    while (nameStart > 0 and cssIsIdentChar(items[nameStart - 1])) nameStart -= 1;
    if (nameStart == colonPos) return null; // bare ':' with no property name before it
    if (nameStart == 0) return null; // no preceding '{'/';' possible - can't be a real declaration
    if (items[nameStart - 1] != '{' and items[nameStart - 1] != ';') return null;
    return items[nameStart..colonPos];
}

fn cssIsHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

// Checks whether `input[hashPos..]` is a `#` followed by exactly 6 or 8
// hex digits (not part of a longer hex-shaped run, and not followed by
// another identifier character, which would mean this isn't a
// standalone color token - e.g. an id selector like `#abcdef1` has 7
// digits and must be left alone entirely). Returns how many bytes to
// consume (7 or 9, including the `#`) only when every digit pair
// repeats (`rr gg bb` / `rr gg bb aa`), which is the only case where
// shortening to `#rgb`/`#rgba` is lossless.
fn cssTryShortenHexColor(input: []const u8, hashPos: usize) ?usize {
    const n = input.len;
    var digits: usize = 0;
    while (hashPos + 1 + digits < n and cssIsHexDigit(input[hashPos + 1 + digits])) digits += 1;

    if (digits != 6 and digits != 8) return null;

    // A longer run (e.g. 7 digits, or 6/8 immediately followed by more
    // ident chars like a trailing letter) means this wasn't actually a
    // clean 6/8-digit color token - leave it untouched.
    const afterDigits = hashPos + 1 + digits;
    if (afterDigits < n and cssIsIdentChar(input[afterDigits])) return null;

    const hex = input[hashPos + 1 .. hashPos + 1 + digits];
    var pair: usize = 0;
    while (pair < digits) : (pair += 2) {
        if (std.ascii.toLower(hex[pair]) != std.ascii.toLower(hex[pair + 1])) return null;
    }

    return 1 + digits;
}

fn cssWriteShortHex(allocator: std.mem.Allocator, out: *CssBuf, hexToken: []const u8) !void {
    try out.append(allocator, '#');
    var pair: usize = 1;
    while (pair < hexToken.len) : (pair += 2) {
        try out.append(allocator, hexToken[pair]);
    }
}

// Tries to replace a `#rrggbb`/`#rrggbbaa` (opaque alpha only) color
// token with the shortest equivalent <color> syntax, hex or named,
// e.g. `#ff0000` -> `red` (shorter than `#f00`), `#aabbcc` -> stays
// hex (no name matches). Reuses `cssTryShortenHexColor`'s exact-
// token-boundary check so this only ever fires on the same clean
// 6/8-digit color tokens that function already recognizes, not
// mid-run inside a longer hex-shaped identifier. Returns null when
// the original token (or its own hex-shortened form) is already the
// shortest available spelling - callers should fall back to plain
// hex shortening in that case.
fn cssTryShortenHexColorToName(allocator: std.mem.Allocator, input: []const u8, hashPos: usize) !?CssColorRewrite {
    const n = input.len;
    var digits: usize = 0;
    while (hashPos + 1 + digits < n and cssIsHexDigit(input[hashPos + 1 + digits])) digits += 1;
    if (digits != 6 and digits != 8) return null;

    const afterDigits = hashPos + 1 + digits;
    if (afterDigits < n and cssIsIdentChar(input[afterDigits])) return null;

    const hex = input[hashPos + 1 .. hashPos + 1 + digits];
    if (digits == 8 and !std.ascii.eqlIgnoreCase(hex[6..8], "ff")) return null;

    const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;

    const consumed = 1 + digits;
    // For an 8-digit source, the real competing hex form keeps the
    // alpha pair (`cssTryShortenHexColor` never drops it) - one more
    // hex digit per channel-form, i.e. +1 for the compact `#rgba`
    // form or +2 for the full `#rrggbbaa` form.
    const rgbHexLen = cssFormatShortestHex(r, g, b).len;
    const shortestHexLen = if (digits == 8) rgbHexLen + (if (rgbHexLen == 4) @as(usize, 1) else @as(usize, 2)) else rgbHexLen;
    const name = shortestNameForRgb(r, g, b, shortestHexLen) orelse return null;
    return .{ .text = try allocator.dupe(u8, name), .consumed = consumed };
}

fn cssIsIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
}

fn cssIsIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

// Whether the position about to be written is the START of a new
// identifier token, i.e. the previously-written char (if any) is not
// itself an identifier char. Prevents matching color names/functions
// midway through a longer word (e.g. the "red" inside "bored").
fn cssIsAtIdentBoundary(items: []const u8) bool {
    if (items.len == 0) return true;
    return !cssIsIdentChar(items[items.len - 1]);
}

// Properties whose value can be (or contain, for shorthands) a plain
// <color> - named color, hex color, or rgb()/hsl() function.
// Deliberately conservative: only properties independently confirmed
// (via MDN) to accept <color> are included. A color-shaped identifier
// in the value of any other property (font-family, animation-name,
// counter-reset, custom idents, ...) is left untouched, since the
// same text is a legitimate, unrelated value there.
const cssColorProperties = [_][]const u8{
    "color",
    "background-color",
    "border-color",
    "border-top-color",
    "border-right-color",
    "border-bottom-color",
    "border-left-color",
    "outline-color",
    "text-decoration-color",
    "text-emphasis-color",
    "caret-color",
    "column-rule-color",
    "background",
    "border",
    "border-top",
    "border-right",
    "border-bottom",
    "border-left",
    "outline",
    "box-shadow",
    "text-shadow",
    "fill",
    "stroke",
    "stop-color",
};

fn cssIsColorProperty(name: []const u8) bool {
    for (cssColorProperties) |p| {
        if (std.ascii.eqlIgnoreCase(name, p)) return true;
    }
    return false;
}

// Whether `items` ends with `keyword` as a whole word (not glued onto
// a longer identifier, e.g. "grand" doesn't end with "and" here).
fn cssEndsWithKeyword(items: []const u8, keyword: []const u8) bool {
    if (items.len < keyword.len) return false;
    const start = items.len - keyword.len;
    if (!std.ascii.eqlIgnoreCase(items[start..], keyword)) return false;
    if (start > 0 and cssIsIdentChar(items[start - 1])) return false;
    return true;
}

const cssMediaKeywords = [_][]const u8{ "and", "or", "not" };

fn cssIsMediaKeywordBeforeParen(items: []const u8) bool {
    for (cssMediaKeywords) |kw| {
        if (cssEndsWithKeyword(items, kw)) return true;
    }
    return false;
}

/// Reformats one row string of a grid-template value: runs of '.'
/// collapse to a single '.', cells are separated by exactly one space,
/// everything else elided. Area name text is copied through unchanged.
fn cssCopyGridTemplateString(allocator: std.mem.Allocator, out: *CssBuf, input: []const u8, i: *usize, quote: u8) !void {
    try out.append(allocator, quote);
    i.* += 1;
    const n = input.len;
    var pendingCellSpace = false;
    var atRowStart = true;
    while (i.* < n and input[i.*] != quote) {
        const c = input[i.*];
        if (c == '\\' and i.* + 1 < n) {
            if (pendingCellSpace and !atRowStart) try out.append(allocator, ' ');
            pendingCellSpace = false;
            atRowStart = false;
            try out.append(allocator, c);
            try out.append(allocator, input[i.* + 1]);
            i.* += 2;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0c') {
            pendingCellSpace = true;
            i.* += 1;
            continue;
        }
        if (c == '.') {
            if (pendingCellSpace and !atRowStart) try out.append(allocator, ' ');
            pendingCellSpace = false;
            atRowStart = false;
            try out.append(allocator, '.');
            i.* += 1;
            while (i.* < n and input[i.*] == '.') i.* += 1;
            continue;
        }
        if (pendingCellSpace and !atRowStart) try out.append(allocator, ' ');
        pendingCellSpace = false;
        atRowStart = false;
        try out.append(allocator, c);
        i.* += 1;
    }
    if (i.* < n) {
        try out.append(allocator, quote);
        i.* += 1;
    }
}

// Whether the quoted string about to be copied is the argument of a
// `url(...)` function, as opposed to e.g. a content: string or a
// selector attribute-value string.
fn cssIsInsideUrlFunction(items: []const u8) bool {
    if (items.len == 0 or items[items.len - 1] != '(') return false;
    var end = items.len - 1;
    while (end > 0 and items[end - 1] == ' ') end -= 1;
    var start = end;
    while (start > 0 and cssIsIdentChar(items[start - 1])) start -= 1;
    return std.ascii.eqlIgnoreCase(items[start..end], "url");
}

/// Handles an unquoted `url(...)` body positioned right after `out`'s
/// trailing `(` (`i.*` is the input offset of the first body byte,
/// including any leading whitespace, which is legal around an
/// unquoted body and skipped here same as trailing whitespace before
/// `)`). Recognizes and rewrites only a `data:image/svg+xml` URI -
/// the one unquoted-body shape that's actually safe to touch, since
/// raw `<svg ...>`/`<?xml ...>` markup contains spaces, quotes, and
/// parens that are illegal unquoted-`url()` bytes per spec and would
/// need re-quoting to survive, which isn't attempted here. Returns
/// `true` (and writes the body itself, rewritten or verbatim) whenever
/// it recognized and consumed a body; `false` leaves `i.*` untouched
/// so the caller's normal per-character loop continues unchanged
/// (this also covers a body that begins with a quote, which the
/// existing quoted-body path already handles instead).
fn cssTryCopyUnquotedUrlSvgBody(allocator: std.mem.Allocator, out: *CssBuf, input: []const u8, i: *usize, args: ?[]const u8) !bool {
    const n = input.len;
    var bodyStart = i.*;
    while (bodyStart < n and cssIsWs(input[bodyStart])) bodyStart += 1;
    if (bodyStart >= n) return false;
    if (input[bodyStart] == '"' or input[bodyStart] == '\'') return false;

    var j = bodyStart;
    while (j < n and input[j] != ')') {
        if (input[j] == '\\' and j + 1 < n) {
            j += 2;
            continue;
        }
        // A literal quote or paren inside an unquoted url() body is
        // not valid CSS to begin with - bail out to a verbatim copy
        // rather than guessing where the body actually ends. Trailing
        // whitespace before `)` is legal and handled below.
        if (input[j] == '"' or input[j] == '\'' or input[j] == '(') return false;
        j += 1;
    }
    if (j >= n) return false; // unterminated - let the normal loop handle/report it

    var bodyEnd = j;
    while (bodyEnd > bodyStart and cssIsWs(input[bodyEnd - 1])) bodyEnd -= 1;

    const body = input[bodyStart..bodyEnd];
    for (body) |bc| {
        if (cssIsWs(bc)) return false; // invalid unquoted url() body
    }
    if (!std.mem.startsWith(u8, body, dataSvgPrefix)) return false;

    if (try cssMinifyBase64SvgDataUri(allocator, body, args)) |rewritten| {
        defer allocator.free(rewritten);
        try out.appendSlice(allocator, rewritten);
        i.* = j;
        return true;
    }

    try out.appendSlice(allocator, body);
    i.* = j;
    return true;
}

const dataSvgPrefix = "data:image/svg+xml";

// Resolves CSS string escapes (`\"`, `\\`, an escaped literal
// newline as a no-output line continuation) in `body` to their real
// characters, for feeding the unescaped text to the SVG minifier.
fn cssUnescapeString(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var buf: CssBuf = .empty;
    errdefer buf.deinit(allocator);
    var k: usize = 0;
    while (k < body.len) {
        if (body[k] == '\\' and k + 1 < body.len) {
            const next = body[k + 1];
            if (next == '\n') {
                k += 2;
                continue;
            }
            try buf.append(allocator, next);
            k += 2;
            continue;
        }
        try buf.append(allocator, body[k]);
        k += 1;
    }
    return buf.toOwnedSlice(allocator);
}

// Only `\` and the delimiting quote itself need escaping in a CSS
// string; minified SVG output contains neither the ambient quote char
// as unescaped data nor backslashes in practice, but this stays
// correct if either shows up.
fn cssAppendEscapedForQuote(allocator: std.mem.Allocator, out: *CssBuf, text: []const u8, quote: u8) !void {
    for (text) |c| {
        if (c == quote or c == '\\') try out.append(allocator, '\\');
        try out.append(allocator, c);
    }
}

fn cssCopyUrlSvgString(allocator: std.mem.Allocator, out: *CssBuf, input: []const u8, i: *usize, quote: u8, args: ?[]const u8) !void {
    const bodyStart = i.* + 1;
    var j = bodyStart;
    const n = input.len;
    while (j < n and input[j] != quote) {
        if (input[j] == '\\' and j + 1 < n) {
            j += 2;
            continue;
        }
        j += 1;
    }
    const body = input[bodyStart..j];
    const unescaped = try cssUnescapeString(allocator, body);
    defer allocator.free(unescaped);

    if (std.mem.startsWith(u8, unescaped, "<svg") or std.mem.startsWith(u8, unescaped, "<?xml")) {
        if (svg.svg(allocator, unescaped, args)) |minified| {
            defer allocator.free(minified);
            try out.append(allocator, quote);
            try cssAppendEscapedForQuote(allocator, out, minified, quote);
            try out.append(allocator, quote);
            i.* = if (j < n) j + 1 else j;
            return;
        } else |_| {} // fall through to verbatim copy below
    } else if (std.mem.startsWith(u8, unescaped, dataSvgPrefix)) {
        if (try cssMinifyBase64SvgDataUri(allocator, unescaped, args)) |rewritten| {
            defer allocator.free(rewritten);
            try out.append(allocator, quote);
            try out.appendSlice(allocator, rewritten);
            try out.append(allocator, quote);
            i.* = if (j < n) j + 1 else j;
            return;
        }
    }

    try cssCopyQuoted(allocator, out, input, i, quote);
}

/// Decodes the base64 payload of a `data:image/svg+xml;base64,...`
/// URI, minifies it, and re-encodes. Returns null (caller falls back
/// to verbatim copy) if the URI isn't the expected `;base64,` shape,
/// or decoding fails - a malformed/foreign data URI must never be
/// mangled.
fn cssMinifyBase64SvgDataUri(allocator: std.mem.Allocator, body: []const u8, args: ?[]const u8) !?[]u8 {
    const marker = ";base64,";
    const markerPos = std.mem.indexOf(u8, body, marker) orelse return null;
    const commaPos = markerPos + marker.len;
    const payload = body[commaPos..];

    const decoder = std.base64.standard.Decoder;
    const decodedLen = decoder.calcSizeForSlice(payload) catch return null;
    const decoded = try allocator.alloc(u8, decodedLen);
    defer allocator.free(decoded);
    decoder.decode(decoded, payload) catch return null;

    const minifiedSvg = svg.svg(allocator, decoded, args) catch return null;
    defer allocator.free(minifiedSvg);

    const encoder = std.base64.standard.Encoder;
    const encodedLen = encoder.calcSize(minifiedSvg.len);
    var result: CssBuf = .empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, body[0..commaPos]);
    try result.resize(allocator, commaPos + encodedLen);
    _ = encoder.encode(result.items[commaPos..], minifiedSvg);
    return try result.toOwnedSlice(allocator);
}

/// Read-only counterpart of the `url(...)` SVG-embedding handled
/// inline during `css()` (`cssCopyUrlSvgString` / `cssTryCopyUnquotedUrlSvgBody`):
/// walks `input` for every `url(...)` holding a `<svg`/`<?xml` literal
/// or a `data:image/svg+xml` URI (quoted or unquoted, base64 or not),
/// and feeds any `<script>`/`on*=` content found inside into
/// `collector`. Used by `minify()` to build a cross-reference set that
/// spans a CSS source's embedded SVG scripts alongside its other
/// top-level inputs. Never mutates or minifies anything itself.
pub fn cssCollectScriptSources(allocator: std.mem.Allocator, collector: *js.JsCrossRefCollector, input: []const u8) !void {
    const n = input.len;
    var i: usize = 0;
    while (i < n) {
        if (input[i] != 'u' and input[i] != 'U') {
            i += 1;
            continue;
        }
        if (i + 4 > n or !std.ascii.eqlIgnoreCase(input[i .. i + 3], "url") or input[i + 3] != '(') {
            i += 1;
            continue;
        }
        var bodyStart = i + 4;
        while (bodyStart < n and cssIsWs(input[bodyStart])) bodyStart += 1;
        i = bodyStart;

        if (bodyStart < n and (input[bodyStart] == '"' or input[bodyStart] == '\'')) {
            const quote = input[bodyStart];
            var j = bodyStart + 1;
            while (j < n and input[j] != quote) {
                if (input[j] == '\\' and j + 1 < n) {
                    j += 2;
                    continue;
                }
                j += 1;
            }
            const rawBody = input[bodyStart + 1 .. @min(j, n)];
            const unescaped = try cssUnescapeString(allocator, rawBody);
            defer allocator.free(unescaped);
            try cssCollectSvgPayload(allocator, collector, unescaped);
            i = if (j < n) j + 1 else j;
            continue;
        }

        var j = bodyStart;
        while (j < n and input[j] != ')') {
            if (input[j] == '\\' and j + 1 < n) {
                j += 2;
                continue;
            }
            j += 1;
        }
        var bodyEnd = j;
        while (bodyEnd > bodyStart and cssIsWs(input[bodyEnd - 1])) bodyEnd -= 1;
        try cssCollectSvgPayload(allocator, collector, input[bodyStart..bodyEnd]);
        i = j;
    }
}

// Feeds `body` into `collector` if it's a raw SVG literal or a
// `data:image/svg+xml` URI (base64 or plain); anything else is
// silently ignored, same as the minifying path's fallback-to-verbatim.
fn cssCollectSvgPayload(allocator: std.mem.Allocator, collector: *js.JsCrossRefCollector, body: []const u8) !void {
    if (std.mem.startsWith(u8, body, "<svg") or std.mem.startsWith(u8, body, "<?xml")) {
        try svgCollectFromText(allocator, collector, body);
        return;
    }
    if (!std.mem.startsWith(u8, body, dataSvgPrefix)) return;

    const marker = ";base64,";
    if (std.mem.indexOf(u8, body, marker)) |markerPos| {
        const payload = body[markerPos + marker.len ..];
        const decoder = std.base64.standard.Decoder;
        const decodedLen = decoder.calcSizeForSlice(payload) catch return;
        const decoded = try allocator.alloc(u8, decodedLen);
        defer allocator.free(decoded);
        decoder.decode(decoded, payload) catch return;
        try svgCollectFromText(allocator, collector, decoded);
    }
}

fn svgCollectFromText(allocator: std.mem.Allocator, collector: *js.JsCrossRefCollector, text: []const u8) !void {
    var tree = svg.svgParse(allocator, text) catch return;
    defer tree.deinit();
    const root = tree.root orelse return;
    svg.svgCollectScriptSources(root, collector) catch {};
}

fn cssCopyQuoted(allocator: std.mem.Allocator, out: *CssBuf, input: []const u8, i: *usize, quote: u8) !void {
    try out.append(allocator, quote);
    i.* += 1;
    const n = input.len;
    while (i.* < n and input[i.*] != quote) {
        if (input[i.*] == '\\' and i.* + 1 < n) {
            try out.append(allocator, input[i.*]);
            try out.append(allocator, input[i.* + 1]);
            i.* += 2;
            continue;
        }
        try out.append(allocator, input[i.*]);
        i.* += 1;
    }
    if (i.* < n) {
        try out.append(allocator, quote);
        i.* += 1;
    }
}

fn cssFlushSpace(allocator: std.mem.Allocator, out: *CssBuf, pendingSpace: *bool) !void {
    if (pendingSpace.* and out.items.len > 0) {
        const last = out.items[out.items.len - 1];
        if (last != '{' and last != ';' and last != ',' and last != ':' and last != '>' and last != '~' and last != '+' and last != '(') {
            try out.append(allocator, ' ');
        }
    }
    pendingSpace.* = false;
}

fn cssTrimTrailingSpace(out: *CssBuf) void {
    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        _ = out.pop();
    }
}

// calc/min/max/clamp take calculation expressions as arguments, where a
// binary +/- needs a mandatory surrounding space to parse (without it,
// a leading +/- reads as a unary sign glued onto the number).
const cssMathFunctionNames = [_][]const u8{ "calc", "min", "max", "clamp" };

fn cssIsInsideMathFunction(items: []const u8) bool {
    var depth: i32 = 0;
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        const c = items[i];
        if (c == ')') depth += 1;
        if (c == '(') {
            if (depth == 0) {
                for (cssMathFunctionNames) |name| {
                    if (i < name.len) continue;
                    const nameStart = i - name.len;
                    if (!std.ascii.eqlIgnoreCase(items[nameStart..i], name)) continue;
                    if (nameStart > 0 and cssIsIdentChar(items[nameStart - 1])) continue;
                    return true;
                }
                return false;
            }
            depth -= 1;
        }
    }
    return false;
}

// Picks whichever of the shortest hex form or the shortest matching
// named color is fewer bytes for an exact RGB value - used wherever a
// color's channel values are already known and any equivalent <color>
// syntax is fair game (as opposed to `cssTryShortenNamedColor`, which
// only ever rewrites a name the source already wrote as a name).
// `currentLen` is the length of the token being replaced, so a
// same-length or longer candidate is never substituted.
fn cssShortestColorText(allocator: std.mem.Allocator, r: u8, g: u8, b: u8, currentLen: usize) !?[]const u8 {
    const hex = cssFormatShortestHex(r, g, b);
    var best: []const u8 = hex.slice();
    if (shortestNameForRgb(r, g, b, best.len)) |name| best = name;
    if (best.len >= currentLen) return null;
    return try allocator.dupe(u8, best);
}

const CssColorRewrite = struct { text: []const u8, consumed: usize };

// Reads a bare identifier token starting at `start` and, if it names
// a CSS named color AND a hex form is strictly shorter, returns the
// hex replacement. Returns null for non-color identifiers, and for
// named colors whose hex form isn't actually shorter (most named
// colors are already the same length as or shorter than their hex
// equivalent - only a few, like "white" -> "#fff", benefit).
fn cssTryShortenNamedColor(allocator: std.mem.Allocator, input: []const u8, start: usize) !?CssColorRewrite {
    var end = start;
    while (end < input.len and cssIsIdentChar(input[end])) end += 1;
    const word = input[start..end];

    const entry = lookupNamedColor(word) orelse return null;
    const hex = cssFormatShortestHex(entry.r, entry.g, entry.b);
    if (hex.len >= word.len) return null;
    return .{ .text = try allocator.dupe(u8, hex.slice()), .consumed = end - start };
}

const CssHexBuf = struct {
    buf: [7]u8 = undefined,
    len: usize = 0,
    fn slice(self: *const CssHexBuf) []const u8 {
        return self.buf[0..self.len];
    }
};

// Formats r/g/b as the shortest valid hex color: `#rgb` when each
// channel's two hex digits repeat, `#rrggbb` otherwise.
fn cssFormatShortestHex(r: u8, g: u8, b: u8) CssHexBuf {
    var out: CssHexBuf = .{};
    const hexChars = "0123456789abcdef";
    const rHi = r >> 4;
    const rLo = r & 0xf;
    const gHi = g >> 4;
    const gLo = g & 0xf;
    const bHi = b >> 4;
    const bLo = b & 0xf;
    if (rHi == rLo and gHi == gLo and bHi == bLo) {
        out.buf[0] = '#';
        out.buf[1] = hexChars[rHi];
        out.buf[2] = hexChars[gHi];
        out.buf[3] = hexChars[bHi];
        out.len = 4;
    } else {
        out.buf[0] = '#';
        out.buf[1] = hexChars[rHi];
        out.buf[2] = hexChars[rLo];
        out.buf[3] = hexChars[gHi];
        out.buf[4] = hexChars[gLo];
        out.buf[5] = hexChars[bHi];
        out.buf[6] = hexChars[bLo];
        out.len = 7;
    }
    return out;
}

// Attempts to parse an `rgb(...)`/`rgba(...)`/`hsl(...)`/`hsla(...)`
// call starting at `start` and, if every argument is a literal number
// (no var(), calc(), or other nested function), returns the shortest
// hex-color replacement. Returns null (leaving the original text
// untouched) for anything not a clean literal call - including
// legacy comma vs modern space syntax edge cases this parser doesn't
// specifically distinguish beyond "are the numeric tokens all plain
// numbers/percentages", which is true for both syntaxes.
fn cssTryRewriteColorFunction(allocator: std.mem.Allocator, input: []const u8, start: usize) !?CssColorRewrite {
    var end = start;
    while (end < input.len and cssIsIdentChar(input[end])) end += 1;
    const name = input[start..end];

    const isHsl = std.ascii.eqlIgnoreCase(name, "hsl") or std.ascii.eqlIgnoreCase(name, "hsla");
    const isRgb = std.ascii.eqlIgnoreCase(name, "rgb") or std.ascii.eqlIgnoreCase(name, "rgba");
    if (!isHsl and !isRgb) return null;
    if (end >= input.len or input[end] != '(') return null;

    var args: [4]CssColorArg = undefined;
    var argCount: usize = 0;
    var pos = end + 1;
    while (true) {
        while (pos < input.len and cssIsWs(input[pos])) pos += 1;
        const argStart = pos;
        var isPercent = false;
        if (pos < input.len and (input[pos] == '-' or input[pos] == '+')) pos += 1;
        var sawDigit = false;
        while (pos < input.len and ((input[pos] >= '0' and input[pos] <= '9') or input[pos] == '.')) {
            if (input[pos] != '.') sawDigit = true;
            pos += 1;
        }
        if (!sawDigit) return null; // not a literal number - var()/calc()/keyword arg etc.
        if (pos < input.len and input[pos] == '%') {
            isPercent = true;
            pos += 1;
        }
        const numText = input[argStart..pos];
        var value = std.fmt.parseFloat(f64, if (isPercent) numText[0 .. numText.len - 1] else numText) catch return null;
        // The hue argument of hsl()/hsla() may carry an angle unit
        // (`deg`/`rad`/`grad`/`turn`) instead of being unitless -
        // normalize it to degrees here so hslToRgb always sees the
        // same units, regardless of which the source used.
        if (isHsl and argCount == 0 and !isPercent) {
            if (cssTryConsumeAngleUnit(input, pos)) |angle| {
                value = cssAngleToDegrees(value, angle.unit);
                pos = angle.end;
            }
        }
        if (argCount >= args.len) return null; // too many args - not a call we understand
        args[argCount] = .{ .value = value, .isPercent = isPercent };
        argCount += 1;

        while (pos < input.len and cssIsWs(input[pos])) pos += 1;
        if (pos >= input.len) return null;
        if (input[pos] == ')') {
            pos += 1;
            break;
        }
        if (input[pos] == ',' or input[pos] == '/') {
            pos += 1;
            continue;
        }
        // Modern space-separated syntax: no separator char, just whitespace
        // already consumed above - loop back to parse the next number.
        if (cssIsIdentChar(input[pos]) or input[pos] == '-' or input[pos] == '.' or (input[pos] >= '0' and input[pos] <= '9')) continue;
        return null;
    }
    if (argCount < 3) return null;

    var r: u8 = undefined;
    var g: u8 = undefined;
    var b: u8 = undefined;
    if (isRgb) {
        r = cssClampChannel(args[0].value, args[0].isPercent);
        g = cssClampChannel(args[1].value, args[1].isPercent);
        b = cssClampChannel(args[2].value, args[2].isPercent);
    } else {
        const rgb = hslToRgb(args[0].value, args[1].value, args[2].value);
        r = rgb.r;
        g = rgb.g;
        b = rgb.b;
    }

    // Alpha present and not fully opaque: hex-with-alpha is longer
    // than most rgba() calls in practice once you include the '#'
    // plus 8 digits vs "rgba(r,g,b,a)" - only worth it when the
    // 4/8-digit hex form is still shorter than the original text.
    if (argCount == 4) {
        const alphaVal = args[3].value;
        const alphaIsPercent = args[3].isPercent;
        const alphaPct = if (alphaIsPercent) alphaVal else alphaVal * 100.0;
        const a: u8 = @intFromFloat(@round(std.math.clamp(alphaPct, 0.0, 100.0) / 100.0 * 255.0));
        if (a == 255) {
            const consumed = pos - start;
            if (try cssShortestColorText(allocator, r, g, b, consumed)) |text| {
                return .{ .text = text, .consumed = consumed };
            }
            return null;
        }
        const hexWithAlpha = cssFormatHexWithAlpha(r, g, b, a);
        const consumed = pos - start;
        if (hexWithAlpha.len < consumed) {
            return .{ .text = try allocator.dupe(u8, hexWithAlpha.slice()), .consumed = consumed };
        }
        return null;
    }

    const consumed = pos - start;
    if (try cssShortestColorText(allocator, r, g, b, consumed)) |text| {
        return .{ .text = text, .consumed = consumed };
    }
    return null;
}

const CssColorArg = struct { value: f64, isPercent: bool };

const CssAngleUnit = enum { deg, rad, grad, turn };
const CssConsumedAngle = struct { unit: CssAngleUnit, end: usize };

// Recognizes one of the four CSS angle units immediately at `pos`,
// provided it's not itself the start of a longer identifier (so
// `rad` doesn't match inside e.g. a hypothetical `radius` keyword
// arg) - the byte right after the unit must not still be an ident
// char.
fn cssTryConsumeAngleUnit(input: []const u8, pos: usize) ?CssConsumedAngle {
    const units = [_]struct { text: []const u8, unit: CssAngleUnit }{
        .{ .text = "deg", .unit = .deg },
        .{ .text = "grad", .unit = .grad },
        .{ .text = "rad", .unit = .rad },
        .{ .text = "turn", .unit = .turn },
    };
    for (units) |u| {
        const end = pos + u.text.len;
        if (end <= input.len and std.ascii.eqlIgnoreCase(input[pos..end], u.text)) {
            if (end < input.len and cssIsIdentChar(input[end])) continue;
            return .{ .unit = u.unit, .end = end };
        }
    }
    return null;
}

fn cssAngleToDegrees(value: f64, unit: CssAngleUnit) f64 {
    return switch (unit) {
        .deg => value,
        .rad => value * (180.0 / std.math.pi),
        .grad => value * 0.9,
        .turn => value * 360.0,
    };
}

fn cssClampChannel(value: f64, isPercent: bool) u8 {
    const v = if (isPercent) value / 100.0 * 255.0 else value;
    return @intFromFloat(@round(std.math.clamp(v, 0.0, 255.0)));
}

const CssHexAlphaBuf = struct {
    buf: [9]u8 = undefined,
    len: usize = 0,
    fn slice(self: *const CssHexAlphaBuf) []const u8 {
        return self.buf[0..self.len];
    }
};

fn cssFormatHexWithAlpha(r: u8, g: u8, b: u8, a: u8) CssHexAlphaBuf {
    var out: CssHexAlphaBuf = .{};
    const hexChars = "0123456789abcdef";
    const rHi = r >> 4;
    const rLo = r & 0xf;
    const gHi = g >> 4;
    const gLo = g & 0xf;
    const bHi = b >> 4;
    const bLo = b & 0xf;
    const aHi = a >> 4;
    const aLo = a & 0xf;
    if (rHi == rLo and gHi == gLo and bHi == bLo and aHi == aLo) {
        out.buf[0] = '#';
        out.buf[1] = hexChars[rHi];
        out.buf[2] = hexChars[gHi];
        out.buf[3] = hexChars[bHi];
        out.buf[4] = hexChars[aHi];
        out.len = 5;
    } else {
        out.buf[0] = '#';
        out.buf[1] = hexChars[rHi];
        out.buf[2] = hexChars[rLo];
        out.buf[3] = hexChars[gHi];
        out.buf[4] = hexChars[gLo];
        out.buf[5] = hexChars[bHi];
        out.buf[6] = hexChars[bLo];
        out.buf[7] = hexChars[aHi];
        out.buf[8] = hexChars[aLo];
        out.len = 9;
    }
    return out;
}

// Named-color table and RGB/HSL conversion helpers used above to
// shorten color values. Source data: W3C CSS Color Module Level 4
// named-color table (148 entries including rebeccapurple),
// cross-checked against multiple independently published copies of
// the same spec table before being transcribed here.
// Generated from the W3C CSS Color Module Level 4 named-color table
// (148 entries, including rebeccapurple; verified against multiple
// independent published copies of the spec table before use here).
const CssNamedColor = struct { name: []const u8, r: u8, g: u8, b: u8 };
const cssNamedColors = [_]CssNamedColor{
    .{ .name = "aliceblue", .r = 240, .g = 248, .b = 255 },
    .{ .name = "antiquewhite", .r = 250, .g = 235, .b = 215 },
    .{ .name = "aqua", .r = 0, .g = 255, .b = 255 },
    .{ .name = "aquamarine", .r = 127, .g = 255, .b = 212 },
    .{ .name = "azure", .r = 240, .g = 255, .b = 255 },
    .{ .name = "beige", .r = 245, .g = 245, .b = 220 },
    .{ .name = "bisque", .r = 255, .g = 228, .b = 196 },
    .{ .name = "black", .r = 0, .g = 0, .b = 0 },
    .{ .name = "blanchedalmond", .r = 255, .g = 235, .b = 205 },
    .{ .name = "blue", .r = 0, .g = 0, .b = 255 },
    .{ .name = "blueviolet", .r = 138, .g = 43, .b = 226 },
    .{ .name = "brown", .r = 165, .g = 42, .b = 42 },
    .{ .name = "burlywood", .r = 222, .g = 184, .b = 135 },
    .{ .name = "cadetblue", .r = 95, .g = 158, .b = 160 },
    .{ .name = "chartreuse", .r = 127, .g = 255, .b = 0 },
    .{ .name = "chocolate", .r = 210, .g = 105, .b = 30 },
    .{ .name = "coral", .r = 255, .g = 127, .b = 80 },
    .{ .name = "cornflowerblue", .r = 100, .g = 149, .b = 237 },
    .{ .name = "cornsilk", .r = 255, .g = 248, .b = 220 },
    .{ .name = "crimson", .r = 220, .g = 20, .b = 60 },
    .{ .name = "cyan", .r = 0, .g = 255, .b = 255 },
    .{ .name = "darkblue", .r = 0, .g = 0, .b = 139 },
    .{ .name = "darkcyan", .r = 0, .g = 139, .b = 139 },
    .{ .name = "darkgoldenrod", .r = 184, .g = 134, .b = 11 },
    .{ .name = "darkgray", .r = 169, .g = 169, .b = 169 },
    .{ .name = "darkgreen", .r = 0, .g = 100, .b = 0 },
    .{ .name = "darkgrey", .r = 169, .g = 169, .b = 169 },
    .{ .name = "darkkhaki", .r = 189, .g = 183, .b = 107 },
    .{ .name = "darkmagenta", .r = 139, .g = 0, .b = 139 },
    .{ .name = "darkolivegreen", .r = 85, .g = 107, .b = 47 },
    .{ .name = "darkorange", .r = 255, .g = 140, .b = 0 },
    .{ .name = "darkorchid", .r = 153, .g = 50, .b = 204 },
    .{ .name = "darkred", .r = 139, .g = 0, .b = 0 },
    .{ .name = "darksalmon", .r = 233, .g = 150, .b = 122 },
    .{ .name = "darkseagreen", .r = 143, .g = 188, .b = 143 },
    .{ .name = "darkslateblue", .r = 72, .g = 61, .b = 139 },
    .{ .name = "darkslategray", .r = 47, .g = 79, .b = 79 },
    .{ .name = "darkslategrey", .r = 47, .g = 79, .b = 79 },
    .{ .name = "darkturquoise", .r = 0, .g = 206, .b = 209 },
    .{ .name = "darkviolet", .r = 148, .g = 0, .b = 211 },
    .{ .name = "deeppink", .r = 255, .g = 20, .b = 147 },
    .{ .name = "deepskyblue", .r = 0, .g = 191, .b = 255 },
    .{ .name = "dimgray", .r = 105, .g = 105, .b = 105 },
    .{ .name = "dimgrey", .r = 105, .g = 105, .b = 105 },
    .{ .name = "dodgerblue", .r = 30, .g = 144, .b = 255 },
    .{ .name = "firebrick", .r = 178, .g = 34, .b = 34 },
    .{ .name = "floralwhite", .r = 255, .g = 250, .b = 240 },
    .{ .name = "forestgreen", .r = 34, .g = 139, .b = 34 },
    .{ .name = "fuchsia", .r = 255, .g = 0, .b = 255 },
    .{ .name = "gainsboro", .r = 220, .g = 220, .b = 220 },
    .{ .name = "ghostwhite", .r = 248, .g = 248, .b = 255 },
    .{ .name = "gold", .r = 255, .g = 215, .b = 0 },
    .{ .name = "goldenrod", .r = 218, .g = 165, .b = 32 },
    .{ .name = "gray", .r = 128, .g = 128, .b = 128 },
    .{ .name = "green", .r = 0, .g = 128, .b = 0 },
    .{ .name = "greenyellow", .r = 173, .g = 255, .b = 47 },
    .{ .name = "grey", .r = 128, .g = 128, .b = 128 },
    .{ .name = "honeydew", .r = 240, .g = 255, .b = 240 },
    .{ .name = "hotpink", .r = 255, .g = 105, .b = 180 },
    .{ .name = "indianred", .r = 205, .g = 92, .b = 92 },
    .{ .name = "indigo", .r = 75, .g = 0, .b = 130 },
    .{ .name = "ivory", .r = 255, .g = 255, .b = 240 },
    .{ .name = "khaki", .r = 240, .g = 230, .b = 140 },
    .{ .name = "lavender", .r = 230, .g = 230, .b = 250 },
    .{ .name = "lavenderblush", .r = 255, .g = 240, .b = 245 },
    .{ .name = "lawngreen", .r = 124, .g = 252, .b = 0 },
    .{ .name = "lemonchiffon", .r = 255, .g = 250, .b = 205 },
    .{ .name = "lightblue", .r = 173, .g = 216, .b = 230 },
    .{ .name = "lightcoral", .r = 240, .g = 128, .b = 128 },
    .{ .name = "lightcyan", .r = 224, .g = 255, .b = 255 },
    .{ .name = "lightgoldenrodyellow", .r = 250, .g = 250, .b = 210 },
    .{ .name = "lightgray", .r = 211, .g = 211, .b = 211 },
    .{ .name = "lightgreen", .r = 144, .g = 238, .b = 144 },
    .{ .name = "lightgrey", .r = 211, .g = 211, .b = 211 },
    .{ .name = "lightpink", .r = 255, .g = 182, .b = 193 },
    .{ .name = "lightsalmon", .r = 255, .g = 160, .b = 122 },
    .{ .name = "lightseagreen", .r = 32, .g = 178, .b = 170 },
    .{ .name = "lightskyblue", .r = 135, .g = 206, .b = 250 },
    .{ .name = "lightslategray", .r = 119, .g = 136, .b = 153 },
    .{ .name = "lightslategrey", .r = 119, .g = 136, .b = 153 },
    .{ .name = "lightsteelblue", .r = 176, .g = 196, .b = 222 },
    .{ .name = "lightyellow", .r = 255, .g = 255, .b = 224 },
    .{ .name = "lime", .r = 0, .g = 255, .b = 0 },
    .{ .name = "limegreen", .r = 50, .g = 205, .b = 50 },
    .{ .name = "linen", .r = 250, .g = 240, .b = 230 },
    .{ .name = "magenta", .r = 255, .g = 0, .b = 255 },
    .{ .name = "maroon", .r = 128, .g = 0, .b = 0 },
    .{ .name = "mediumaquamarine", .r = 102, .g = 205, .b = 170 },
    .{ .name = "mediumblue", .r = 0, .g = 0, .b = 205 },
    .{ .name = "mediumorchid", .r = 186, .g = 85, .b = 211 },
    .{ .name = "mediumpurple", .r = 147, .g = 112, .b = 219 },
    .{ .name = "mediumseagreen", .r = 60, .g = 179, .b = 113 },
    .{ .name = "mediumslateblue", .r = 123, .g = 104, .b = 238 },
    .{ .name = "mediumspringgreen", .r = 0, .g = 250, .b = 154 },
    .{ .name = "mediumturquoise", .r = 72, .g = 209, .b = 204 },
    .{ .name = "mediumvioletred", .r = 199, .g = 21, .b = 133 },
    .{ .name = "midnightblue", .r = 25, .g = 25, .b = 112 },
    .{ .name = "mintcream", .r = 245, .g = 255, .b = 250 },
    .{ .name = "mistyrose", .r = 255, .g = 228, .b = 225 },
    .{ .name = "moccasin", .r = 255, .g = 228, .b = 181 },
    .{ .name = "navajowhite", .r = 255, .g = 222, .b = 173 },
    .{ .name = "navy", .r = 0, .g = 0, .b = 128 },
    .{ .name = "oldlace", .r = 253, .g = 245, .b = 230 },
    .{ .name = "olive", .r = 128, .g = 128, .b = 0 },
    .{ .name = "olivedrab", .r = 107, .g = 142, .b = 35 },
    .{ .name = "orange", .r = 255, .g = 165, .b = 0 },
    .{ .name = "orangered", .r = 255, .g = 69, .b = 0 },
    .{ .name = "orchid", .r = 218, .g = 112, .b = 214 },
    .{ .name = "palegoldenrod", .r = 238, .g = 232, .b = 170 },
    .{ .name = "palegreen", .r = 152, .g = 251, .b = 152 },
    .{ .name = "paleturquoise", .r = 175, .g = 238, .b = 238 },
    .{ .name = "palevioletred", .r = 219, .g = 112, .b = 147 },
    .{ .name = "papayawhip", .r = 255, .g = 239, .b = 213 },
    .{ .name = "peachpuff", .r = 255, .g = 218, .b = 185 },
    .{ .name = "peru", .r = 205, .g = 133, .b = 63 },
    .{ .name = "pink", .r = 255, .g = 192, .b = 203 },
    .{ .name = "plum", .r = 221, .g = 160, .b = 221 },
    .{ .name = "powderblue", .r = 176, .g = 224, .b = 230 },
    .{ .name = "purple", .r = 128, .g = 0, .b = 128 },
    .{ .name = "rebeccapurple", .r = 102, .g = 51, .b = 153 },
    .{ .name = "red", .r = 255, .g = 0, .b = 0 },
    .{ .name = "rosybrown", .r = 188, .g = 143, .b = 143 },
    .{ .name = "royalblue", .r = 65, .g = 105, .b = 225 },
    .{ .name = "saddlebrown", .r = 139, .g = 69, .b = 19 },
    .{ .name = "salmon", .r = 250, .g = 128, .b = 114 },
    .{ .name = "sandybrown", .r = 244, .g = 164, .b = 96 },
    .{ .name = "seagreen", .r = 46, .g = 139, .b = 87 },
    .{ .name = "seashell", .r = 255, .g = 245, .b = 238 },
    .{ .name = "sienna", .r = 160, .g = 82, .b = 45 },
    .{ .name = "silver", .r = 192, .g = 192, .b = 192 },
    .{ .name = "skyblue", .r = 135, .g = 206, .b = 235 },
    .{ .name = "slateblue", .r = 106, .g = 90, .b = 205 },
    .{ .name = "slategray", .r = 112, .g = 128, .b = 144 },
    .{ .name = "slategrey", .r = 112, .g = 128, .b = 144 },
    .{ .name = "snow", .r = 255, .g = 250, .b = 250 },
    .{ .name = "springgreen", .r = 0, .g = 255, .b = 127 },
    .{ .name = "steelblue", .r = 70, .g = 130, .b = 180 },
    .{ .name = "tan", .r = 210, .g = 180, .b = 140 },
    .{ .name = "teal", .r = 0, .g = 128, .b = 128 },
    .{ .name = "thistle", .r = 216, .g = 191, .b = 216 },
    .{ .name = "tomato", .r = 255, .g = 99, .b = 71 },
    .{ .name = "turquoise", .r = 64, .g = 224, .b = 208 },
    .{ .name = "violet", .r = 238, .g = 130, .b = 238 },
    .{ .name = "wheat", .r = 245, .g = 222, .b = 179 },
    .{ .name = "white", .r = 255, .g = 255, .b = 255 },
    .{ .name = "whitesmoke", .r = 245, .g = 245, .b = 245 },
    .{ .name = "yellow", .r = 255, .g = 255, .b = 0 },
    .{ .name = "yellowgreen", .r = 154, .g = 205, .b = 50 },
};

/// Looks up a named color by name (case-insensitive). Returns null if
/// `name` isn't one of the 148 CSS named colors.
pub fn lookupNamedColor(name: []const u8) ?CssNamedColor {
    for (cssNamedColors) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry;
    }
    return null;
}

/// Finds the shortest named-color spelling for an exact RGB value, if
/// any named color matches and is shorter than `currentLen` bytes.
/// Several RGB values have more than one name (e.g. gray/grey,
/// cyan/aqua) - picks the first, shortest match in table order.
pub fn shortestNameForRgb(r: u8, g: u8, b: u8, currentLen: usize) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (cssNamedColors) |entry| {
        if (entry.r != r or entry.g != g or entry.b != b) continue;
        if (best == null or entry.name.len < best.?.len) best = entry.name;
    }
    if (best) |name| {
        if (name.len < currentLen) return name;
    }
    return null;
}

/// Converts an HSL color (h in degrees, s/l as 0-100 percentages) to
/// RGB. Standard CSS HSL-to-RGB conversion.
pub fn hslToRgb(hDeg: f64, sPct: f64, lPct: f64) struct { r: u8, g: u8, b: u8 } {
    const h = @mod(hDeg, 360.0) / 360.0;
    const s = std.math.clamp(sPct / 100.0, 0.0, 1.0);
    const l = std.math.clamp(lPct / 100.0, 0.0, 1.0);

    if (s == 0.0) {
        const v: u8 = @intFromFloat(@round(l * 255.0));
        return .{ .r = v, .g = v, .b = v };
    }

    const q: f64 = if (l < 0.5) l * (1.0 + s) else l + s - l * s;
    const p: f64 = 2.0 * l - q;

    return .{
        .r = hueToRgbChannel(p, q, h + 1.0 / 3.0),
        .g = hueToRgbChannel(p, q, h),
        .b = hueToRgbChannel(p, q, h - 1.0 / 3.0),
    };
}

fn hueToRgbChannel(p: f64, q: f64, tIn: f64) u8 {
    var t = tIn;
    if (t < 0.0) t += 1.0;
    if (t > 1.0) t -= 1.0;
    var v: f64 = undefined;
    if (t < 1.0 / 6.0) {
        v = p + (q - p) * 6.0 * t;
    } else if (t < 1.0 / 2.0) {
        v = q;
    } else if (t < 2.0 / 3.0) {
        v = p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    } else {
        v = p;
    }
    return @intFromFloat(@round(std.math.clamp(v, 0.0, 1.0) * 255.0));
}
