//! A minimal XML tree parser/serializer scoped to what SVG needs: no DTD
//! validation, no external entity resolution, no namespace-URI resolution.
//! Qualified names like `xlink:href` are treated as opaque strings.
//!
//! The tree owns no allocations outside `arena` - every string stored on
//! a node is a slice into the original input buffer, so the input must
//! outlive the tree. `deinit` frees the whole tree in one shot.

const std = @import("std");
const css = @import("css.zig");
const js = @import("js.zig");
const minify = @import("minify.zig");
const hypercrush = @import("hypercrush.zig");



const common = minify;

pub const MinifyOptions = minify.MinifyOptions;

pub const SvgNodeKind = enum {
    element,
    text,
    comment,
    cdata,
    // XML prolog (`<?xml ... ?>`) or other processing instructions, and
    // the DOCTYPE, if present. Passed through byte-for-byte on output;
    // not otherwise inspected.
    passthrough,
};

pub const SvgAttr = struct {
    name: []const u8,
    value: []const u8,
};

pub const SvgNode = struct {
    kind: SvgNodeKind,
    // Populated for `.element` only.
    tagName: []const u8 = "",
    attrs: std.ArrayList(SvgAttr) = .empty,
    children: std.ArrayList(*SvgNode) = .empty,
    // Populated for `.text`, `.comment`, `.cdata`, `.passthrough`.
    // For `.text`, this is the raw (un-entity-decoded) source text -
    // decoding isn't needed since we only ever re-serialize it verbatim.
    text: []const u8 = "",
    // Null only for the document root. Kept in sync by `appendChild`
    // and `removeChild` - never assign `children` directly.
    parent: ?*SvgNode = null,

    /// Appends `child` to `self.children` and sets `child.parent`.
    pub fn appendChild(self: *SvgNode, allocator: std.mem.Allocator, child: *SvgNode) !void {
        child.parent = self;
        try self.children.append(allocator, child);
    }

    /// Removes `child` from `self.children` (must be present) and
    /// clears its parent pointer.
    pub fn removeChild(self: *SvgNode, child: *SvgNode) void {
        const idx = std.mem.indexOfScalar(*SvgNode, self.children.items, child).?;
        _ = self.children.orderedRemove(idx);
        child.parent = null;
    }

    pub fn findAttr(self: *const SvgNode, name: []const u8) ?[]const u8 {
        for (self.attrs.items) |a| {
            if (std.ascii.eqlIgnoreCase(a.name, name)) return a.value;
        }
        return null;
    }
};

pub const SvgTree = struct {
    arena: std.heap.ArenaAllocator,
    root: ?*SvgNode,

    pub fn deinit(self: *SvgTree) void {
        self.arena.deinit();
    }
};

pub const SvgParseError = error{
    UnexpectedEof,
    MismatchedCloseTag,
    OutOfMemory,
};

const SvgParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    i: usize = 0,

    fn peek(self: *SvgParser) ?u8 {
        if (self.i >= self.input.len) return null;
        return self.input[self.i];
    }

    fn startsWith(self: *SvgParser, s: []const u8) bool {
        return std.mem.startsWith(u8, self.input[self.i..], s);
    }

    fn skipWs(self: *SvgParser) void {
        while (self.i < self.input.len and svgIsWs(self.input[self.i])) self.i += 1;
    }

    // Appends `node` to `out`, and to `parent.children` (setting
    // `node.parent`) when `parent` is non-null.
    fn appendParsed(self: *SvgParser, out: *std.ArrayList(*SvgNode), parent: ?*SvgNode, node: *SvgNode) !void {
        if (parent) |p| {
            try p.appendChild(self.allocator, node);
        } else {
            try out.append(self.allocator, node);
        }
    }

    // Parses sibling nodes until EOF or a close tag matching `parentTag`
    // (null at the document root). A close tag for anything else is
    // treated as the implicit close of the current parent. `parent`
    // (null at the document root) is the node these children belong to,
    // used to set each child's `.parent`.
    fn parseChildren(self: *SvgParser, out: *std.ArrayList(*SvgNode), parent: ?*SvgNode, parentTag: ?[]const u8) SvgParseError!void {
        while (true) {
            self.skipWs();
            if (self.peek() == null) return;

            if (self.startsWith("</")) {
                if (parentTag == null) return; // stray close at root; stop
                return; // let caller consume it
            }

            if (self.startsWith("<!--")) {
                const node = try self.parseComment();
                try self.appendParsed(out, parent, node);
                continue;
            }

            if (self.startsWith("<![CDATA[")) {
                const node = try self.parseCData();
                try self.appendParsed(out, parent, node);
                continue;
            }

            if (self.startsWith("<!") or self.startsWith("<?")) {
                const node = try self.parsePassthrough();
                try self.appendParsed(out, parent, node);
                continue;
            }

            if (self.peek() == '<') {
                const node = try self.parseElement();
                try self.appendParsed(out, parent, node);
                continue;
            }

            const node = try self.parseText();
            if (node.text.len > 0) try self.appendParsed(out, parent, node);
        }
    }

    // Consumes content up to (not including) the literal `</tag`, case
    // insensitively, without treating any `<` inside as markup. Needed
    // for elements like `<script>` whose body isn't valid XML.
    fn parseRawTextChild(self: *SvgParser, parent: *SvgNode, tag: []const u8) SvgParseError!void {
        const start = self.i;
        var end = self.input.len;
        var i = self.i;
        while (i < self.input.len) : (i += 1) {
            if (self.input[i] != '<' or i + 1 >= self.input.len or self.input[i + 1] != '/') continue;
            const nameStart = i + 2;
            var j = nameStart;
            while (j < self.input.len and svgIsNameChar(self.input[j])) j += 1;
            if (std.ascii.eqlIgnoreCase(self.input[nameStart..j], tag)) {
                end = i;
                break;
            }
        }
        self.i = end;
        if (end > start) {
            const node = try self.allocator.create(SvgNode);
            node.* = .{ .kind = .text, .text = self.input[start..end] };
            try parent.appendChild(self.allocator, node);
        }
    }

    fn parseText(self: *SvgParser) SvgParseError!*SvgNode {
        const start = self.i;
        while (self.i < self.input.len and self.input[self.i] != '<') self.i += 1;
        const node = try self.allocator.create(SvgNode);
        node.* = .{ .kind = .text, .text = self.input[start..self.i] };
        return node;
    }

    fn parseComment(self: *SvgParser) SvgParseError!*SvgNode {
        std.debug.assert(self.startsWith("<!--"));
        self.i += 4;
        const start = self.i;
        while (self.i < self.input.len and !self.startsWith("-->")) self.i += 1;
        const contentEnd = self.i;
        if (self.i < self.input.len) self.i += 3;
        const node = try self.allocator.create(SvgNode);
        node.* = .{ .kind = .comment, .text = self.input[start..contentEnd] };
        return node;
    }

    fn parseCData(self: *SvgParser) SvgParseError!*SvgNode {
        std.debug.assert(self.startsWith("<![CDATA["));
        self.i += 9;
        const start = self.i;
        while (self.i < self.input.len and !self.startsWith("]]>")) self.i += 1;
        const contentEnd = self.i;
        if (self.i < self.input.len) self.i += 3;
        const node = try self.allocator.create(SvgNode);
        node.* = .{ .kind = .cdata, .text = self.input[start..contentEnd] };
        return node;
    }

    // `<!DOCTYPE ...>` or `<?xml ... ?>` / other processing instructions.
    // Kept byte-for-byte; SVG documents rarely need these mangled, and
    // getting DOCTYPE internal-subset parsing exactly right (nested `[...]`
    // blocks) is not worth it for a minifier's purposes.
    fn parsePassthrough(self: *SvgParser) SvgParseError!*SvgNode {
        const start = self.i;
        var depth: i32 = 0;
        while (self.i < self.input.len) {
            const c = self.input[self.i];
            if (c == '<') depth += 1;
            if (c == '>') {
                depth -= 1;
                self.i += 1;
                if (depth <= 0) break;
                continue;
            }
            self.i += 1;
        }
        const node = try self.allocator.create(SvgNode);
        node.* = .{ .kind = .passthrough, .text = self.input[start..self.i] };
        return node;
    }

    fn parseElement(self: *SvgParser) SvgParseError!*SvgNode {
        std.debug.assert(self.peek() == '<');
        self.i += 1;
        const nameStart = self.i;
        while (self.i < self.input.len and svgIsNameChar(self.input[self.i])) self.i += 1;
        const tagName = self.input[nameStart..self.i];

        const node = try self.allocator.create(SvgNode);
        node.* = .{ .kind = .element, .tagName = tagName };

        try self.parseAttrs(&node.attrs);

        self.skipWs();
        if (self.startsWith("/>")) {
            self.i += 2;
            return node; // self-closing, no children
        }
        if (self.peek() == '>') {
            self.i += 1;
        } else {
            // Unterminated start tag (truncated input); treat as
            // self-closing so callers still get a usable tree.
            return node;
        }

        if (std.ascii.eqlIgnoreCase(tagName, "script")) {
            try self.parseRawTextChild(node, "script");
        } else {
            try self.parseChildren(&node.children, node, tagName);
        }

        if (self.startsWith("</")) {
            const closeStart = self.i + 2;
            var j = closeStart;
            while (j < self.input.len and svgIsNameChar(self.input[j])) j += 1;
            const closeName = self.input[closeStart..j];
            self.i = j;
            self.skipWs();
            if (self.peek() == '>') self.i += 1;
            // A close tag that doesn't match is tolerated (not surfaced as
            // an error) - it just means parseChildren already stopped at
            // the wrong boundary, which only happens on malformed input,
            // and failing hard would make the whole minifier unusable on
            // input a browser would still render.
            _ = closeName;
        }

        return node;
    }

    fn parseAttrs(self: *SvgParser, out: *std.ArrayList(SvgAttr)) SvgParseError!void {
        while (true) {
            self.skipWs();
            const c = self.peek() orelse return;
            if (c == '>' or (c == '/' and self.startsWith("/>"))) return;

            const nameStart = self.i;
            while (self.i < self.input.len and self.input[self.i] != '=' and self.input[self.i] != '>' and
                !svgIsWs(self.input[self.i]) and !self.startsWith("/>")) self.i += 1;
            const name = self.input[nameStart..self.i];
            if (name.len == 0) {
                self.i += 1;
                continue;
            }

            self.skipWs();
            var value: []const u8 = "";
            if (self.peek() == '=') {
                self.i += 1;
                self.skipWs();
                if (self.peek() == '"' or self.peek() == '\'') {
                    const scanned = common.scanQuotedValue(self.input, self.i);
                    value = scanned.value;
                    self.i = scanned.end;
                } else {
                    // Unquoted attribute value - not valid XML, but tolerate
                    // it for HTML-inline SVG that a browser would still
                    // parse leniently.
                    const valStart = self.i;
                    while (self.i < self.input.len and !svgIsWs(self.input[self.i]) and self.input[self.i] != '>') self.i += 1;
                    value = self.input[valStart..self.i];
                }
            }

            try out.append(self.allocator, .{ .name = name, .value = value });
        }
    }
};

fn svgIsWs(c: u8) bool {
    return common.isWsCore(c) or c == '\n';
}

fn svgIsNameChar(c: u8) bool {
    return common.isNameCharCore(c) or c == ':' or c == '.';
}

/// Parses `input` (expected to be a single SVG document, i.e. everything
/// from `<svg` or an optional prolog/doctype through the matching
/// `</svg>`) into a tree. The returned tree borrows all its string data
/// from `input`, which must outlive it. Caller owns the tree and must
/// call `deinit`.
pub fn svgParse(allocator: std.mem.Allocator, input: []const u8) SvgParseError!SvgTree {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arenaAllocator = arena.allocator();

    var parser = SvgParser{ .allocator = arenaAllocator, .input = input };
    var topLevel: std.ArrayList(*SvgNode) = .empty;
    try parser.parseChildren(&topLevel, null, null);

    var root: ?*SvgNode = null;
    for (topLevel.items) |node| {
        if (node.kind == .element) {
            root = node;
            break;
        }
    }

    return .{ .arena = arena, .root = root };
}

/// Anything that can make an `id` load-bearing: `url(#id)` (in a
/// plain attribute or inline `style` value), a `#id`-fragment
/// `href`/`xlink:href`, or a SMIL `begin`/`end` timing reference
/// (`id.event`). Only ids absent from this set may ever be stripped.
pub const SvgIdRefSet = struct {
    arena: std.heap.ArenaAllocator,
    ids: std.StringHashMapUnmanaged(void),

    pub fn deinit(self: *SvgIdRefSet) void {
        self.arena.deinit();
    }

    pub fn contains(self: *const SvgIdRefSet, id: []const u8) bool {
        return self.ids.contains(id);
    }
};

/// Walks the whole tree and collects every `id` that is referenced from
/// anywhere else in the document, including a `getElementById`/
/// `getElementsByName` literal-string call in a `<script>` or `on*=`
/// handler. Call this before stripping any `id` attribute - an id
/// present in the returned set must be kept.
pub fn svgCollectIdRefs(allocator: std.mem.Allocator, root: *SvgNode) !SvgIdRefSet {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var ids: std.StringHashMapUnmanaged(void) = .empty;

    try svgCollectIdRefsWalk(arena.allocator(), &ids, root);
    try svgCollectScriptIdRefsWalk(allocator, arena.allocator(), &ids, root);

    return .{ .arena = arena, .ids = ids };
}

fn svgCollectIdRefsWalk(allocator: std.mem.Allocator, ids: *std.StringHashMapUnmanaged(void), node: *SvgNode) !void {
    if (node.kind == .element) {
        for (node.attrs.items) |attr| {
            try svgCollectIdRefsFromAttr(allocator, ids, attr.name, attr.value);
        }
        for (node.children.items) |child| {
            try svgCollectIdRefsWalk(allocator, ids, child);
        }
    }
}

fn svgCollectScriptIdRefsWalk(scratchAllocator: std.mem.Allocator, arenaAllocator: std.mem.Allocator, ids: *std.StringHashMapUnmanaged(void), node: *SvgNode) !void {
    if (node.kind != .element) return;

    if (std.ascii.eqlIgnoreCase(node.tagName, "script")) {
        for (node.children.items) |child| {
            if (child.kind != .text and child.kind != .cdata) continue;
            if (child.text.len == 0) continue;
            try svgAddElementIdLookups(scratchAllocator, arenaAllocator, ids, child.text);
        }
        return;
    }

    for (node.attrs.items) |attr| {
        if (svgIsEventHandlerAttr(attr.name) and attr.value.len > 0) {
            try svgAddElementIdLookups(scratchAllocator, arenaAllocator, ids, attr.value);
        }
    }

    for (node.children.items) |child| {
        try svgCollectScriptIdRefsWalk(scratchAllocator, arenaAllocator, ids, child);
    }
}

fn svgAddElementIdLookups(scratchAllocator: std.mem.Allocator, arenaAllocator: std.mem.Allocator, ids: *std.StringHashMapUnmanaged(void), source: []const u8) !void {
    const found = try js.jsCollectElementIdLookups(scratchAllocator, source);
    defer {
        for (found) |s| scratchAllocator.free(s);
        scratchAllocator.free(found);
    }
    for (found) |id| try svgAddId(arenaAllocator, ids, id);
}

fn svgCollectIdRefsFromAttr(allocator: std.mem.Allocator, ids: *std.StringHashMapUnmanaged(void), attrName: []const u8, value: []const u8) !void {
    // href="#id" / xlink:href="#id"
    if (std.ascii.eqlIgnoreCase(attrName, "href") or std.ascii.endsWithIgnoreCase(attrName, ":href")) {
        if (value.len > 0 and value[0] == '#') {
            try svgAddId(allocator, ids, value[1..]);
        }
        return;
    }

    // begin="otherId.click" / end="otherId.end" (SMIL timing references).
    // A bare "otherId" (no dot) is also a valid syncbase reference.
    if (std.ascii.eqlIgnoreCase(attrName, "begin") or std.ascii.eqlIgnoreCase(attrName, "end")) {
        try svgCollectSmilTimingRefs(allocator, ids, value);
        return;
    }

    // Scans for url(#id) occurrences, including inside
    // `style="fill:url(#id)"` - a plain substring search, no CSS
    // parsing needed.
    try svgCollectUrlRefs(allocator, ids, value);
}

fn svgCollectUrlRefs(allocator: std.mem.Allocator, ids: *std.StringHashMapUnmanaged(void), value: []const u8) !void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, value, pos, "url(")) |urlStart| {
        var i = urlStart + 4;
        while (i < value.len and (value[i] == ' ' or value[i] == '\t')) i += 1;
        if (i < value.len and (value[i] == '"' or value[i] == '\'')) i += 1;
        if (i < value.len and value[i] == '#') {
            i += 1;
            const idStart = i;
            while (i < value.len and value[i] != ')' and value[i] != '"' and value[i] != '\'' and value[i] != ' ') i += 1;
            try svgAddId(allocator, ids, value[idStart..i]);
        }
        pos = urlStart + 4;
    }
}

fn svgCollectSmilTimingRefs(allocator: std.mem.Allocator, ids: *std.StringHashMapUnmanaged(void), value: []const u8) !void {
    // begin/end can be a semicolon-separated list of timing values; only
    // ones with an id component (`id.event` or bare `id`, as opposed to
    // pure offsets like "2s" or wallclock/indefinite values) reference
    // another element.
    var it = std.mem.splitScalar(u8, value, ';');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) continue;
        // Reject pure offset/keyword forms: "2s", "+5s", "-1s", "indefinite".
        const c0 = trimmed[0];
        if (std.ascii.isDigit(c0) or c0 == '+' or c0 == '-') continue;
        if (std.ascii.eqlIgnoreCase(trimmed, "indefinite")) continue;
        const dotIdx = std.mem.indexOfScalar(u8, trimmed, '.');
        const id = if (dotIdx) |d| trimmed[0..d] else trimmed;
        if (id.len == 0) continue;
        try svgAddId(allocator, ids, id);
    }
}

fn svgAddId(allocator: std.mem.Allocator, ids: *std.StringHashMapUnmanaged(void), id: []const u8) !void {
    if (id.len == 0) return;
    if (ids.contains(id)) return;
    const owned = try allocator.dupe(u8, id);
    try ids.put(allocator, owned, {});
}

// Canonical definition is `minify.SvgLevel` (see `minify.zig`'s
// options-shape doc comment) - aliased here since svg.zig's own
// stripping logic is written against this name throughout.
pub const SvgLevel = minify.SvgLevel;

pub const SvgStripOptions = struct {
    level: SvgLevel = .none,
};

// Attributes always dropped at every level >= .base, wherever they
// appear, since they carry no rendering information a conforming SVG
// viewer depends on. `id` is handled separately below (conditional on
// the reference set).
const svgAlwaysStrippedAttrs = [_][]const u8{ "xml:space", "enable-background" };

// `version`, `baseProfile`, and `xmlns*` are only meaningful on the svg
// root; skipping them elsewhere avoids re-deriving root-ness per attr.
fn svgIsRootOnlyAttr(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "version") or
        std.ascii.eqlIgnoreCase(name, "baseprofile") or
        std.ascii.startsWithIgnoreCase(name, "xmlns");
}

/// Mutates `root` in place, removing attributes safe to drop at the
/// given `options.level`. `refs` (from `svgCollectIdRefs`, called on
/// this tree *before* any mutation) protects any actually-referenced
/// `id` from being stripped, regardless of level.
///
/// Must be called with `refs` computed from the tree's unmodified
/// state; stripping attributes doesn't change what ids are
/// referenced, so one ref-collection pass up front is sufficient.
pub fn svgStrip(root: *SvgNode, refs: *const SvgIdRefSet, options: SvgStripOptions) void {
    if (options.level == .none) return;
    svgStripWalk(root, refs, options, true);
}

fn svgStripWalk(node: *SvgNode, refs: *const SvgIdRefSet, options: SvgStripOptions, isRoot: bool) void {
    if (node.kind != .element) return;

    var i: usize = 0;
    while (i < node.attrs.items.len) {
        const attr = node.attrs.items[i];
        if (svgShouldStripAttr(attr.name, attr.value, refs, options, isRoot)) {
            _ = node.attrs.orderedRemove(i);
            continue;
        }
        i += 1;
    }

    // Only the svg root itself gets root-only-attr treatment; a nested
    // <svg> (unusual but legal) is not treated as "the" root.
    for (node.children.items) |child| {
        svgStripWalk(child, refs, options, false);
    }
}

fn svgShouldStripAttr(name: []const u8, value: []const u8, refs: *const SvgIdRefSet, options: SvgStripOptions, isRoot: bool) bool {
    if (std.ascii.eqlIgnoreCase(name, "id")) {
        return !refs.contains(value);
    }

    for (svgAlwaysStrippedAttrs) |s| {
        if (std.ascii.eqlIgnoreCase(name, s)) return true;
    }

    if (!isRoot or !svgIsRootOnlyAttr(name)) return false;

    if (std.ascii.eqlIgnoreCase(name, "version")) return true;

    if (@intFromEnum(options.level) >= @intFromEnum(SvgLevel.more)) {
        if (std.ascii.eqlIgnoreCase(name, "baseprofile")) return true;
    }
    if (@intFromEnum(options.level) >= @intFromEnum(SvgLevel.all)) {
        if (std.ascii.startsWithIgnoreCase(name, "xmlns")) return true;
    }
    return false;
}

// One inherited presentation property's name and initial value, per
// the SVG spec. Only properties with a plain, context-independent
// default are listed - "context" (fill/stroke default to the paint
// server producing black) and anything percentage-of-viewport-based
// is excluded, since eliding those would need more than a literal
// string match against `defaultValue`.
const SvgInheritedDefault = struct {
    name: []const u8,
    defaultValue: []const u8,
};

const svgInheritedDefaults = [_]SvgInheritedDefault{
    .{ .name = "fill", .defaultValue = "black" },
    .{ .name = "fill-opacity", .defaultValue = "1" },
    .{ .name = "fill-rule", .defaultValue = "nonzero" },
    .{ .name = "stroke", .defaultValue = "none" },
    .{ .name = "stroke-width", .defaultValue = "1" },
    .{ .name = "stroke-opacity", .defaultValue = "1" },
    .{ .name = "stroke-linecap", .defaultValue = "butt" },
    .{ .name = "stroke-linejoin", .defaultValue = "miter" },
    .{ .name = "stroke-miterlimit", .defaultValue = "4" },
    .{ .name = "stroke-dasharray", .defaultValue = "none" },
    .{ .name = "stroke-dashoffset", .defaultValue = "0" },
    .{ .name = "opacity", .defaultValue = "1" },
    .{ .name = "visibility", .defaultValue = "visible" },
    .{ .name = "color", .defaultValue = "black" },
    .{ .name = "font-style", .defaultValue = "normal" },
    .{ .name = "font-weight", .defaultValue = "normal" },
    .{ .name = "text-anchor", .defaultValue = "start" },
};

/// Mutates `root` in place, dropping a presentation attribute when its
/// value matches the SVG initial value for that property and no
/// ancestor sets that property to something else (an ancestor's own
/// default-valued instance of the same attribute counts as "not
/// overriding" and is fine to drop too, walking outward in the same
/// pass). Skips any node carrying a `style` attribute entirely, since
/// a shorthand or `!important` there could change what's actually in
/// effect and this pass only reasons about the XML presentation
/// attributes themselves.
pub fn svgElideDefaults(root: *SvgNode) void {
    svgElideDefaultsWalk(root);
}

fn svgElideDefaultsWalk(node: *SvgNode) void {
    if (node.kind != .element) return;

    if (node.findAttr("style") == null) {
        var i: usize = 0;
        while (i < node.attrs.items.len) {
            const attr = node.attrs.items[i];
            if (svgIsElidableDefault(node, attr.name, attr.value)) {
                _ = node.attrs.orderedRemove(i);
                continue;
            }
            i += 1;
        }
    }

    for (node.children.items) |child| {
        svgElideDefaultsWalk(child);
    }
}

fn svgIsElidableDefault(node: *const SvgNode, name: []const u8, value: []const u8) bool {
    const def = for (svgInheritedDefaults) |d| {
        if (std.ascii.eqlIgnoreCase(name, d.name)) break d;
    } else return false;

    if (!std.ascii.eqlIgnoreCase(value, def.defaultValue)) return false;
    return !svgAncestorOverrides(node.parent, name, def.defaultValue);
}

// Walks upward from `parent` looking for a value of `name` that isn't
// the property's own default - that would mean the current node's
// default-valued attribute is load-bearing (it resets an ancestor's
// override back to default) and must be kept.
fn svgAncestorOverrides(parent: ?*SvgNode, name: []const u8, defaultValue: []const u8) bool {
    var cur = parent;
    while (cur) |n| : (cur = n.parent) {
        if (n.kind != .element) continue;
        if (n.findAttr("style") != null) return true; // unknown effective value; assume override
        if (n.findAttr(name)) |v| {
            return !std.ascii.eqlIgnoreCase(v, defaultValue);
        }
    }
    return false;
}

// Container elements that render nothing by themselves - safe to drop
// outright when they have no children left, and safe to unwrap into
// their single child's slot when they have exactly one and no
// attributes worth keeping. `svg` (root) and `symbol`/`marker`/
// `pattern`/`mask`/`clipPath` (definitions, meaningful even when
// empty or referenced only by id) are deliberately excluded.
const svgCollapsibleContainerTags = [_][]const u8{ "g", "a", "switch" };

fn svgIsCollapsibleContainerTag(tagName: []const u8) bool {
    for (svgCollapsibleContainerTags) |t| {
        if (std.ascii.eqlIgnoreCase(tagName, t)) return true;
    }
    return false;
}

/// Mutates `root` in place: removes a childless `g`/`a`/`switch`
/// (never `root` itself), and unwraps a single-child one directly into
/// its parent's child list, when doing so is safe - the element itself
/// has no meaningful attributes (its `id`, if any, isn't referenced;
/// see `refs`) and the sole remaining child isn't a `.text` node,
/// since `<g>text</g>` and bare `text` differ in a browser's default
/// treatment of whitespace/rendering context. Runs bottom-up so a
/// container left empty by unwrapping its own children is itself
/// considered for removal in the same pass.
///
/// `arenaAllocator` must be the tree's own arena allocator (same one
/// passed to `svgParse`) - unwrapping re-splices an existing node, not
/// allocate a new one, but the child list itself may need to grow.
pub fn svgCollapseContainers(arenaAllocator: std.mem.Allocator, root: *SvgNode, refs: *const SvgIdRefSet) !void {
    try svgCollapseContainersWalk(arenaAllocator, root, refs);
}

fn svgCollapseContainersWalk(arenaAllocator: std.mem.Allocator, node: *SvgNode, refs: *const SvgIdRefSet) !void {
    if (node.kind != .element) return;

    // Bottom-up: collapse descendants first so removals/unwraps here
    // see their final shape.
    var i: usize = 0;
    while (i < node.children.items.len) {
        const child = node.children.items[i];
        try svgCollapseContainersWalk(arenaAllocator, child, refs);

        if (child.kind != .element or !svgIsCollapsibleContainerTag(child.tagName)) {
            i += 1;
            continue;
        }
        if (!svgContainerAttrsAreSafe(child, refs)) {
            i += 1;
            continue;
        }

        if (child.children.items.len == 0) {
            node.removeChild(child);
            continue; // re-check the same index; next child (if any) shifted down
        }

        if (child.children.items.len == 1 and child.children.items[0].kind != .text) {
            const grandchild = child.children.items[0];
            node.removeChild(child);
            grandchild.parent = node;
            try node.children.insert(arenaAllocator, i, grandchild);
            i += 1;
            continue;
        }

        i += 1;
    }
}

// No attribute worth keeping other than an `id` that's actually
// referenced. Anything else present (event handlers, `style`,
// `transform`, presentation attributes, `clip-path`, etc.) might carry
// meaning that would be lost by removing or unwrapping the element, so
// such a node is left alone.
fn svgContainerAttrsAreSafe(node: *const SvgNode, refs: *const SvgIdRefSet) bool {
    for (node.attrs.items) |attr| {
        if (std.ascii.eqlIgnoreCase(attr.name, "id")) {
            if (refs.contains(attr.value)) return false;
            continue;
        }
        return false;
    }
    return true;
}

/// Rounds and re-formats numbers embedded in coordinate/dimension
/// attribute values: "100.00000001" -> "100", "0.500" -> ".5",
/// "1.0e2" -> "100", keeping at most `svgMaxDecimals` fractional
/// digits.
///
/// SAFETY NOTE (CSS-in-SVG hazard): only touches attributes named in
/// `svgNumericAttrs` below - a fixed allowlist of XML presentation
/// attributes. Never touches the `style` attribute's value (a CSS
/// declaration list) or `<style>` element text (a CSS stylesheet).
const svgMaxDecimals: u8 = 3;

// Attributes whose value is a single bare number, possibly with a unit
// suffix (e.g. "10px" - units pass through untouched).
const svgSingleNumberAttrs = [_][]const u8{
    "x",     "y",      "width",  "height", "cx",   "cy",       "r",
    "rx",    "ry",     "x1",     "y1",     "x2",   "y2",       "fx",
    "fy",    "fr",     "dx",     "dy",     "offset",
};

// Attributes whose value is a whitespace/comma-separated list of numbers.
const svgNumberListAttrs = [_][]const u8{ "viewBox", "points", "stroke-dasharray" };

fn svgIsNumericListAttr(name: []const u8) bool {
    for (svgNumberListAttrs) |a| {
        if (std.ascii.eqlIgnoreCase(name, a)) return true;
    }
    return false;
}

fn svgIsSingleNumberAttr(name: []const u8) bool {
    for (svgSingleNumberAttrs) |a| {
        if (std.ascii.eqlIgnoreCase(name, a)) return true;
    }
    return false;
}

/// Mutates `root` in place, reformatting numeric values on the fixed set
/// of known-numeric presentation attributes (see `svgSingleNumberAttrs`
/// and `svgNumberListAttrs`), plus `d` (path data) and `transform`, each
/// with their own command/function-aware grammar since both interleave
/// numbers with command letters or function names. A value that doesn't
/// parse as its attribute's expected grammar is left unchanged.
///
/// Rewritten values are allocated into `arenaAllocator` (pass the
/// tree's own arena allocator so lifetime matches the rest of the tree).
fn svgTrimNumbers(arenaAllocator: std.mem.Allocator, root: *SvgNode) !void {
    try svgTrimNumbersWalk(arenaAllocator, root);
}

fn svgTrimNumbersWalk(arenaAllocator: std.mem.Allocator, node: *SvgNode) !void {
    if (node.kind != .element) return;

    // Never descend into a <style> element - its text content is a CSS
    // stylesheet, not markup this pass should touch.
    if (std.ascii.eqlIgnoreCase(node.tagName, "style")) return;

    for (node.attrs.items) |*attr| {
        // Never touch `style` - it's a CSS declaration list, not one
        // of the XML attributes this pass understands.
        if (std.ascii.eqlIgnoreCase(attr.name, "style")) continue;

        if (svgIsSingleNumberAttr(attr.name)) {
            attr.value = try svgTrimSingleNumber(arenaAllocator, attr.value);
        } else if (svgIsNumericListAttr(attr.name)) {
            attr.value = try svgTrimNumberList(arenaAllocator, attr.value);
        } else if (std.ascii.eqlIgnoreCase(attr.name, "d")) {
            attr.value = try svgTrimPathData(arenaAllocator, attr.value);
        } else if (std.ascii.eqlIgnoreCase(attr.name, "transform")) {
            attr.value = try svgTrimTransform(arenaAllocator, attr.value);
        }
    }

    for (node.children.items) |child| {
        try svgTrimNumbersWalk(arenaAllocator, child);
    }
}

// Reformats a single "<number><optional unit suffix>" value, e.g.
// "10.500px" -> "10.5px". A non-numeric `value` is returned unchanged.
// A '%' suffix is handled the same as any other unit.
fn svgTrimSingleNumber(arenaAllocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const parsed = svgParseNumber(value, 0) orelse return value;
    const suffix = value[parsed.end..];
    // No savings possible and no unit to normalize: skip the allocation.
    if (suffix.len == 0 and svgNumberIsAlreadyMinimal(value[0..parsed.end])) return value;

    var out: SvgBuf = .empty;
    defer out.deinit(arenaAllocator);
    try svgFormatNumber(arenaAllocator, &out, parsed.value, svgMaxDecimals);
    try out.appendSlice(arenaAllocator, suffix);
    return out.toOwnedSlice(arenaAllocator);
}

// Reformats a whitespace/comma-separated list of numbers, always
// re-emitting a single space between entries regardless of the
// source's comma-vs-space choice.
fn svgTrimNumberList(arenaAllocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: SvgBuf = .empty;
    defer out.deinit(arenaAllocator);

    var i: usize = 0;
    var wroteAny = false;
    while (i < value.len) {
        while (i < value.len and svgIsListSep(value[i])) i += 1;
        if (i >= value.len) break;

        const parsed = svgParseNumber(value, i) orelse {
            // Malformed input - bail out and keep the original value.
            return value;
        };

        if (wroteAny) try out.append(arenaAllocator, ' ');
        try svgFormatNumber(arenaAllocator, &out, parsed.value, svgMaxDecimals);
        wroteAny = true;
        i = parsed.end;
    }

    if (!wroteAny) return value;
    return out.toOwnedSlice(arenaAllocator);
}

fn svgIsListSep(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == ',';
}

// Reformats a `transform="translate(10.500 20) rotate(45.0000)"`-style
// value: function names and parens are copied verbatim; only the
// numbers inside each pair of parens are reformatted, via
// `svgTrimNumberListInto`. A single space separates functions.
fn svgTrimTransform(arenaAllocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: SvgBuf = .empty;
    defer out.deinit(arenaAllocator);

    var i: usize = 0;
    var wroteAny = false;
    while (i < value.len) {
        while (i < value.len and svgIsListSep(value[i])) i += 1;
        if (i >= value.len) break;

        const nameStart = i;
        while (i < value.len and value[i] != '(' and !svgIsListSep(value[i])) i += 1;
        const name = value[nameStart..i];
        if (name.len == 0) return value; // malformed; bail out unchanged

        while (i < value.len and svgIsListSep(value[i])) i += 1;
        if (i >= value.len or value[i] != '(') return value; // malformed

        const argsStart = i + 1;
        const closeIdx = std.mem.indexOfScalarPos(u8, value, argsStart, ')') orelse return value;
        const args = value[argsStart..closeIdx];

        if (wroteAny) try out.append(arenaAllocator, ' ');
        try out.appendSlice(arenaAllocator, name);
        try out.append(arenaAllocator, '(');
        svgTrimNumberListInto(arenaAllocator, &out, args) catch |err| switch (err) {
            error.NotANumberList => return value,
            else => |e| return e,
        };
        try out.append(arenaAllocator, ')');
        wroteAny = true;
        i = closeIdx + 1;
    }

    if (!wroteAny) return value;
    return out.toOwnedSlice(arenaAllocator);
}

// Shared core of svgTrimNumberList, extracted so svgTrimTransform can
// reformat args into an already-open output buffer instead of
// allocating a separate string per function call. Returns
// error.NotANumberList when `value` isn't a valid number list.
fn svgTrimNumberListInto(arenaAllocator: std.mem.Allocator, out: *SvgBuf, value: []const u8) !void {
    var i: usize = 0;
    var wroteAny = false;
    while (i < value.len) {
        while (i < value.len and svgIsListSep(value[i])) i += 1;
        if (i >= value.len) break;

        const parsed = svgParseNumber(value, i) orelse return error.NotANumberList;

        if (wroteAny) try out.append(arenaAllocator, ' ');
        try svgFormatNumber(arenaAllocator, out, parsed.value, svgMaxDecimals);
        wroteAny = true;
        i = parsed.end;
    }
}

// How many numeric args follow each path command letter (case-insensitive
// - lower/upper only affects absolute-vs-relative interpretation of the
// numbers, not the argument count). 'z'/'Z' (closepath) takes none and
// isn't in this table; it's handled directly in svgTrimPathData. 'a'/'A'
// (elliptical arc) is handled specially (see svgTrimPathArcArgs): its
// args are [rx, ry, x-axis-rotation, large-arc-flag, sweep-flag, x, y]
// where the two flags are single-digit booleans that may have no
// separator at all from whatever follows.
const SvgPathCommandArgCount = struct { letter: u8, argCount: u8 };
const svgPathCommandArgCounts = [_]SvgPathCommandArgCount{
    .{ .letter = 'm', .argCount = 2 },
    .{ .letter = 'l', .argCount = 2 },
    .{ .letter = 'h', .argCount = 1 },
    .{ .letter = 'v', .argCount = 1 },
    .{ .letter = 'c', .argCount = 6 },
    .{ .letter = 's', .argCount = 4 },
    .{ .letter = 'q', .argCount = 4 },
    .{ .letter = 't', .argCount = 2 },
};

fn svgPathCommandArgCount(lowerLetter: u8) ?u8 {
    for (svgPathCommandArgCounts) |c| {
        if (c.letter == lowerLetter) return c.argCount;
    }
    return null;
}

/// Reformats a `d="M10.500 20 L30 40.0000"`-style SVG path data value.
/// Copies command letters through verbatim; reformats each command's
/// numeric arguments via `svgFormatNumber`, always emitting a single
/// space between numbers rather than reproducing separator-elision
/// tricks like "1-2" or ".5.5". Falls back to returning `value`
/// unchanged if the path data doesn't parse as valid command+number
/// syntax at any point.
fn svgTrimPathData(arenaAllocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: SvgBuf = .empty;
    defer out.deinit(arenaAllocator);

    var i: usize = 0;
    var currentLetter: u8 = 0; // 0 = none yet; path data must start with M/m
    // True once at least one arg has been written for the current
    // command letter - controls whether the next arg needs a leading
    // separating space.
    var needSpace = false;
    while (i < value.len) {
        while (i < value.len and svgIsListSep(value[i])) i += 1;
        if (i >= value.len) break;

        const c = value[i];
        if (std.ascii.isAlphabetic(c)) {
            const lowerC = std.ascii.toLower(c);
            if (lowerC != 'z' and lowerC != 'a' and svgPathCommandArgCount(lowerC) == null) {
                return value; // unknown command letter: malformed, bail out unchanged
            }

            // A letter is always an unambiguous boundary against a
            // number, so never needs a separating space either side.
            currentLetter = c;
            try out.append(arenaAllocator, c);
            i += 1;
            needSpace = false; // no space between a command letter and its first arg

            if (lowerC == 'z') continue; // no args

            while (i < value.len and svgIsListSep(value[i])) i += 1;
            continue;
        }

        if (currentLetter == 0) return value; // args before any command letter: malformed

        const lower = std.ascii.toLower(currentLetter);
        if (lower == 'a') {
            i = svgTrimPathArcArgs(arenaAllocator, &out, value, i, &needSpace) catch |err| switch (err) {
                error.NotANumberList => return value,
                else => |e| return e,
            };
        } else {
            const argCount = svgPathCommandArgCount(lower) orelse return value; // unknown command letter
            var argIdx: u8 = 0;
            while (argIdx < argCount) : (argIdx += 1) {
                while (i < value.len and svgIsListSep(value[i])) i += 1;
                const parsed = svgParseNumber(value, i) orelse return value;
                if (needSpace) try out.append(arenaAllocator, ' ');
                try svgFormatNumber(arenaAllocator, &out, parsed.value, svgMaxDecimals);
                needSpace = true;
                i = parsed.end;
            }
        }

        while (i < value.len and svgIsListSep(value[i])) i += 1;

        // Path data allows repeating a command's args without restating
        // the letter (e.g. "L10 10 20 20" is two lineto points): the
        // outer loop's next iteration falls through to the
        // currentLetter != 0 branch with needSpace still true.
    }

    return out.toOwnedSlice(arenaAllocator);
}

// Reads and reformats the 7 arguments of an elliptical-arc ("A"/"a")
// command starting at `i`: rx, ry, x-axis-rotation (plain numbers),
// large-arc-flag, sweep-flag (single-digit 0/1 booleans, parsed
// separately since they can be glued to adjacent digits with zero
// separator), then x, y. Appends the reformatted args to `out`, using
// `needSpace.*` the same way svgTrimPathData's own loop does. Returns
// the index just past the last argument, or error.NotANumberList if
// the expected shape isn't found.
fn svgTrimPathArcArgs(arenaAllocator: std.mem.Allocator, out: *SvgBuf, value: []const u8, startIdx: usize, needSpace: *bool) !usize {
    var i = startIdx;

    // rx, ry, x-axis-rotation
    var argIdx: u8 = 0;
    while (argIdx < 3) : (argIdx += 1) {
        while (i < value.len and svgIsListSep(value[i])) i += 1;
        const parsed = svgParseNumber(value, i) orelse return error.NotANumberList;
        if (needSpace.*) try out.append(arenaAllocator, ' ');
        try svgFormatNumber(arenaAllocator, out, parsed.value, svgMaxDecimals);
        needSpace.* = true;
        i = parsed.end;
    }

    // large-arc-flag, sweep-flag: exactly one digit each, '0' or '1'.
    // svgParseNumber would be wrong here - it would consume "10" as a
    // single number instead of two flags "1" then "0" glued together.
    argIdx = 0;
    while (argIdx < 2) : (argIdx += 1) {
        while (i < value.len and svgIsListSep(value[i])) i += 1;
        if (i >= value.len or (value[i] != '0' and value[i] != '1')) return error.NotANumberList;
        if (needSpace.*) try out.append(arenaAllocator, ' ');
        try out.append(arenaAllocator, value[i]);
        needSpace.* = true;
        i += 1;
    }

    // x, y
    argIdx = 0;
    while (argIdx < 2) : (argIdx += 1) {
        while (i < value.len and svgIsListSep(value[i])) i += 1;
        const parsed = svgParseNumber(value, i) orelse return error.NotANumberList;
        if (needSpace.*) try out.append(arenaAllocator, ' ');
        try svgFormatNumber(arenaAllocator, out, parsed.value, svgMaxDecimals);
        needSpace.* = true;
        i = parsed.end;
    }

    return i;
}

const SvgParsedNumber = struct {
    value: f64,
    end: usize,
};

// Parses an SVG-grammar number (`[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?`)
// starting at `start`. Returns null if `start` isn't the beginning of a
// valid number.
fn svgParseNumber(s: []const u8, start: usize) ?SvgParsedNumber {
    var i = start;
    const numStart = i;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;

    var sawDigits = false;
    while (i < s.len and std.ascii.isDigit(s[i])) {
        i += 1;
        sawDigits = true;
    }
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) {
            i += 1;
            sawDigits = true;
        }
    }
    if (!sawDigits) return null;

    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var j = i + 1;
        if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
        var sawExpDigits = false;
        while (j < s.len and std.ascii.isDigit(s[j])) {
            j += 1;
            sawExpDigits = true;
        }
        if (sawExpDigits) i = j;
    }

    const text = s[numStart..i];
    const value = std.fmt.parseFloat(f64, text) catch return null;
    return .{ .value = value, .end = i };
}

// True if `text` is already the minimal representation `svgFormatNumber`
// would produce for its own parsed value, so re-formatting would be
// wasted work. Deliberately conservative: only skips the allocation
// for a plain non-negative integer with no leading zeros (e.g. "10",
// "0"); any other shape always goes through the formatter.
fn svgNumberIsAlreadyMinimal(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text[0] == '0' and text.len > 1) return false;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

// Formats `value` as a minimal SVG-legal number: rounds to at most
// `maxDecimals` fractional digits, strips trailing zeros and a trailing
// '.', and drops a redundant leading '0' before the decimal point
// (SVGO-style: "0.5" -> ".5"). Negative zero collapses to "0".
fn svgFormatNumber(allocator: std.mem.Allocator, out: *SvgBuf, value: f64, maxDecimals: u8) !void {
    var v = value;
    if (v == 0) v = 0; // collapses -0.0 to 0.0

    var buf: [64]u8 = undefined;
    const rounded = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ v, maxDecimals }) catch {
        // Fallback for a value bufPrint's fixed buffer can't hold (not
        // realistic for SVG geometry, but fail safe): emit the
        // shortest round-trip representation instead of a truncated one.
        var fallback: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&fallback, "{d}", .{v}) catch return error.OutOfMemory;
        try out.appendSlice(allocator, s);
        return;
    };

    var s: []const u8 = rounded;
    if (std.mem.indexOfScalar(u8, s, '.') != null) {
        s = std.mem.trimEnd(u8, s, "0");
        s = std.mem.trimEnd(u8, s, ".");
    }
    if (s.len == 0 or (s.len == 1 and s[0] == '-')) s = "0";

    // Drop a redundant leading zero before the decimal point: "0.5" ->
    // ".5", "-0.5" -> "-.5".
    if (std.mem.startsWith(u8, s, "0.")) {
        s = s[1..];
    } else if (std.mem.startsWith(u8, s, "-0.")) {
        try out.append(allocator, '-');
        s = s[2..];
    }

    try out.appendSlice(allocator, s);
}

/// SVGs can carry stylesheet and script content: a <style> element's
/// text (a full CSS stylesheet), a `style="..."` attribute's value (a
/// bare CSS declaration list), an `on*="..."` event-handler
/// attribute's value (a JS statement list), and a <script> element's
/// text (JavaScript). None of these are XML/attribute syntax, so this
/// delegates to the project's CSS and JS minifiers (`css.css`,
/// `js.js`) rather than reimplementing that logic - this is why every
/// other pass in this file skips `<style>`/`<script>` children and
/// `style`/`on*` attribute values outright.
///
/// Mutates `root` in place: minifies every `<style>` element's text
/// and every `style="..."` attribute's value via `css.css`, every
/// `<script>` element's text and every `on*="..."` attribute's value
/// via `js.js`. A `style` attribute value isn't valid CSS on its own,
/// so it's temporarily wrapped as `a{...}` before being handed to
/// `css.css`, and the wrapper stripped back off the result.
///
/// Attribute values are stored raw (un-entity-decoded, see `SvgNode`'s
/// doc comment) and handed to `js.js`/`css.css` as-is: a handler value
/// containing a literal character-reference entity (`onclick="a&amp;&amp;b()"`)
/// is fed to the JS minifier with the entity still in place rather
/// than decoded to `&&` first, same tradeoff the pre-existing `style`
/// attribute delegation above already makes for CSS.
///
/// Rewritten values are allocated into `arenaAllocator` (the tree's
/// own arena). Uses `scratchAllocator` for temporary buffers that
/// don't need to outlive this call, to avoid growing the arena with
/// garbage that's freed only when the whole tree is torn down.
/// Walks `root`'s tree minifying any `<style>`/`style="..."` CSS and
/// `<script>`/`on*=` JS it finds.
pub fn svgMinifyEmbeddedCode(arenaAllocator: std.mem.Allocator, scratchAllocator: std.mem.Allocator, root: *SvgNode, embeddedArgs: []const u8) !void {
    try svgMinifyEmbeddedCodeWalk(arenaAllocator, scratchAllocator, root, embeddedArgs);
}

fn svgMinifyEmbeddedCodeWalk(arenaAllocator: std.mem.Allocator, scratchAllocator: std.mem.Allocator, node: *SvgNode, embeddedArgs: []const u8) !void {
    if (node.kind != .element) return;

    if (std.ascii.eqlIgnoreCase(node.tagName, "style")) {
        try svgMinifyStyleElementText(arenaAllocator, scratchAllocator, node, embeddedArgs);
        // A <style> element's only meaningful content is its CSS text -
        // nothing else in it is markup any pass should look inside.
        return;
    }

    if (std.ascii.eqlIgnoreCase(node.tagName, "script")) {
        try svgMinifyScriptElementText(arenaAllocator, scratchAllocator, node, embeddedArgs);
        return;
    }

    for (node.attrs.items) |*attr| {
        if (std.ascii.eqlIgnoreCase(attr.name, "style")) {
            if (attr.value.len == 0) continue;
            attr.value = try svgMinifyStyleAttrValue(arenaAllocator, scratchAllocator, attr.value, embeddedArgs);
        } else if (svgIsEventHandlerAttr(attr.name)) {
            if (attr.value.len == 0) continue;
            attr.value = try svgMinifyEventHandlerAttrValue(arenaAllocator, scratchAllocator, attr.value, embeddedArgs);
        }
    }

    for (node.children.items) |child| {
        try svgMinifyEmbeddedCodeWalk(arenaAllocator, scratchAllocator, child, embeddedArgs);
    }
}

fn svgIsEventHandlerAttr(name: []const u8) bool {
    return common.isEventAttrName(name);
}

/// Feeds every `<script>` element and `on*=` attribute under `node`
/// into `collector` without minifying anything - the read-only half of
/// `svgMinifyEmbeddedCodeWalk`, used to build the document-wide
/// cross-script protect list before any one script is mangled. See
/// `js.zig`.
pub fn svgCollectScriptSources(node: *SvgNode, collector: *js.JsCrossRefCollector) !void {
    if (node.kind != .element) return;

    if (std.ascii.eqlIgnoreCase(node.tagName, "script")) {
        for (node.children.items) |child| {
            if (child.kind != .text and child.kind != .cdata) continue;
            if (child.text.len == 0) continue;
            try collector.add(child.text);
        }
        return;
    }

    for (node.attrs.items) |attr| {
        if (svgIsEventHandlerAttr(attr.name) and attr.value.len > 0) {
            try collector.add(attr.value);
        }
    }

    for (node.children.items) |child| {
        try svgCollectScriptSources(child, collector);
    }
}

fn svgMinifyEventHandlerAttrValue(arenaAllocator: std.mem.Allocator, scratchAllocator: std.mem.Allocator, value: []const u8, embeddedArgs: []const u8) ![]const u8 {
    const minified = try js.js(scratchAllocator, value, embeddedArgs);
    defer scratchAllocator.free(minified);
    // SVG attributes are always "-delimited (svgSerializeAttrValue),
    // so a tied string-quote choice needs to prefer ' here to avoid
    // needing &quot; once re-serialized.
    const requoted = try js.jsRequoteDoubleToSingleWhereSafe(scratchAllocator, minified);
    defer scratchAllocator.free(requoted);
    return arenaAllocator.dupe(u8, requoted);
}

fn svgMinifyStyleElementText(arenaAllocator: std.mem.Allocator, scratchAllocator: std.mem.Allocator, styleNode: *SvgNode, embeddedArgs: []const u8) !void {
    for (styleNode.children.items) |child| {
        if (child.kind != .text and child.kind != .cdata) continue;
        if (child.text.len == 0) continue;
        const minified = try css.css(scratchAllocator, child.text, embeddedArgs);
        defer scratchAllocator.free(minified);
        child.text = try arenaAllocator.dupe(u8, minified);
    }
}

fn svgMinifyScriptElementText(arenaAllocator: std.mem.Allocator, scratchAllocator: std.mem.Allocator, scriptNode: *SvgNode, embeddedArgs: []const u8) !void {
    for (scriptNode.children.items) |child| {
        if (child.kind != .text and child.kind != .cdata) continue;
        if (child.text.len == 0) continue;
        const minified = try js.js(scratchAllocator, child.text, embeddedArgs);
        defer scratchAllocator.free(minified);
        child.text = try arenaAllocator.dupe(u8, minified);
    }
}

fn svgMinifyStyleAttrValue(arenaAllocator: std.mem.Allocator, scratchAllocator: std.mem.Allocator, value: []const u8, embeddedArgs: []const u8) ![]const u8 {
    const wrapped = try std.fmt.allocPrint(scratchAllocator, "a{{{s}}}", .{value});
    defer scratchAllocator.free(wrapped);

    const minifiedWrapped = try css.css(scratchAllocator, wrapped, embeddedArgs);
    defer scratchAllocator.free(minifiedWrapped);

    // Strip the "a{" prefix and "}" suffix back off - css.css always
    // preserves the selector and outer braces verbatim, so this is an
    // exact unwrap.
    var inner = minifiedWrapped;
    if (std.mem.startsWith(u8, inner, "a{")) inner = inner[2..];
    if (std.mem.endsWith(u8, inner, "}")) inner = inner[0 .. inner.len - 1];

    return arenaAllocator.dupe(u8, inner);
}

const SvgBuf = std.ArrayList(u8);

/// Serializes `root` back to minified XML text (single-space-collapsed
/// attribute layout, no inter-element whitespace beyond what significant
/// text nodes already carry). Caller owns the returned slice.
pub fn svgSerialize(allocator: std.mem.Allocator, root: *SvgNode, args: SvgArgs) ![]u8 {
    var out: SvgBuf = .empty;
    errdefer out.deinit(allocator);
    try svgSerializeNode(allocator, &out, root, args);
    return out.toOwnedSlice(allocator);
}

fn svgSerializeNode(allocator: std.mem.Allocator, out: *SvgBuf, node: *SvgNode, args: SvgArgs) !void {
    switch (node.kind) {
        .text => try out.appendSlice(allocator, node.text),
        .comment => {
            try out.appendSlice(allocator, "<!--");
            try out.appendSlice(allocator, node.text);
            try out.appendSlice(allocator, "-->");
        },
        .cdata => {
            try out.appendSlice(allocator, "<![CDATA[");
            try out.appendSlice(allocator, node.text);
            try out.appendSlice(allocator, "]]>");
        },
        .passthrough => try out.appendSlice(allocator, node.text),
        .element => {
            var tagBuf: SvgBuf = .empty;
            defer tagBuf.deinit(allocator);
            try tagBuf.append(allocator, '<');
            try tagBuf.appendSlice(allocator, node.tagName);
            for (node.attrs.items) |attr| {
                try tagBuf.append(allocator, ' ');
                try tagBuf.appendSlice(allocator, attr.name);
                if (attr.value.len > 0 or svgAttrAlwaysHasEquals(attr.name)) {
                    try tagBuf.appendSlice(allocator, "=\"");
                    try svgSerializeAttrValue(allocator, &tagBuf, attr.value);
                    try tagBuf.append(allocator, '"');
                }
            }
            const selfClose = node.children.items.len == 0;
            try tagBuf.appendSlice(allocator, if (selfClose) "/>" else ">");

            if (args.hypercrush) {
                try hypercrush.hcCopyTag(allocator, out, tagBuf.items);
            } else {
                try out.appendSlice(allocator, tagBuf.items);
            }
            if (selfClose) return;

            for (node.children.items) |child| {
                try svgSerializeNode(allocator, out, child, args);
            }
            try out.appendSlice(allocator, "</");
            try out.appendSlice(allocator, node.tagName);
            try out.append(allocator, '>');
        },
    }
}

// XML (unlike HTML) has no boolean/valueless-attribute concept, but an
// explicitly empty value (`id=""`) is legal and distinct from a bare
// name, so always emit `="..."` and let callers drop empty attributes
// before serializing if they want that.
fn svgAttrAlwaysHasEquals(name: []const u8) bool {
    _ = name;
    return true;
}

fn svgSerializeAttrValue(allocator: std.mem.Allocator, out: *SvgBuf, value: []const u8) !void {
    // Values are stored as raw source text (not entity-decoded), so
    // only a literal `"` byte can break the surrounding double-quote
    // delimiter - re-escape just that; everything else round-trips.
    for (value) |c| {
        if (c == '"') {
            try out.appendSlice(allocator, "&quot;");
        } else {
            try out.append(allocator, c);
        }
    }
}

const SvgArgs = struct {
    hypercrush: bool = false,
};



/// Minifies an SVG document. `args` is an optional `MinifyOptions`
/// JSON string; see `minify.zig` for the full shape and defaults.
/// Multiple `<script>` elements and `on*=` handlers in the same
/// document are treated as able to share top-level names; see
/// `js.zig`. At default options this still round-trips
/// through the parser/serializer, normalizing quoting and
/// whitespace-between-attributes.
///
/// An unset `strip` resolves to `.more` here - `.all` strips `xmlns`,
/// which a standalone file needs to open on its own. Callers that
/// embed SVG inside another document (where `.all` is safe) resolve
/// their own default before calling in; see `html()`'s and `css()`'s
/// handling of embedded SVG.
pub fn svg(allocator: std.mem.Allocator, input: []const u8, args: ?[]const u8) anyerror![]u8 {
    var parsed = try minify.parseOptions(allocator, args);
    defer parsed.deinit();
    const svgOpts = parsed.value.svg;
    const stripLevel = svgOpts.strip orelse .more;

    var tree = try svgParse(allocator, input);
    defer tree.deinit();

    const root = tree.root orelse return allocator.dupe(u8, input);

    if (stripLevel != .none) {
        var refs = try svgCollectIdRefs(allocator, root);
        defer refs.deinit();
        svgStrip(root, &refs, .{ .level = stripLevel });
        try svgTrimNumbers(tree.arena.allocator(), root);
        svgElideDefaults(root);
        try svgCollapseContainers(tree.arena.allocator(), root, &refs);
    } else {
        try svgTrimNumbers(tree.arena.allocator(), root);
    }

    var collector = js.JsCrossRefCollector.init(allocator);
    defer collector.deinit();
    try svgCollectScriptSources(root, &collector);
    const ownCrossProtect = try collector.finalize(allocator);
    defer {
        for (ownCrossProtect) |s| allocator.free(s);
        allocator.free(ownCrossProtect);
    }

    var protect: std.ArrayList([]const u8) = .empty;
    defer protect.deinit(allocator);
    try protect.appendSlice(allocator, parsed.value.js.mangle.protect);
    try protect.appendSlice(allocator, ownCrossProtect);
    parsed.value.js.mangle.protect = protect.items;

    var embeddedArgsBuf: std.Io.Writer.Allocating = .init(allocator);
    defer embeddedArgsBuf.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &embeddedArgsBuf.writer);
    const embeddedArgs: []const u8 = embeddedArgsBuf.written();

    try svgMinifyEmbeddedCode(tree.arena.allocator(), allocator, root, embeddedArgs);

    return svgSerialize(allocator, root, .{ .hypercrush = svgOpts.hypercrush });
}
