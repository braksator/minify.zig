//! HTML minifier: whitespace/comment stripping, with embedded <script>,
//! <style>, and <svg> content delegated to the JS/CSS/SVG minifiers.

const std = @import("std");
const css = @import("css.zig");
const js = @import("js.zig");
const svg = @import("svg.zig");
const minify = @import("minify.zig");
const hypercrush = @import("hypercrush.zig");



const common = minify;

pub const MinifyOptions = minify.MinifyOptions;

fn htmlIsWs(c: u8) bool {
    return common.isWsCore(c) or c == '\n' or c == '\x0c';
}

fn htmlIsNameChar(c: u8) bool {
    return common.isNameCharCore(c);
}

const HtmlBuf = std.ArrayList(u8);

const htmlRawTextTags = [_][]const u8{ "script", "style", "textarea", "pre" };

fn htmlRawTextTag(name: []const u8) ?[]const u8 {
    for (htmlRawTextTags) |t| {
        if (std.ascii.eqlIgnoreCase(name, t)) return t;
    }
    return null;
}

/// Minifies HTML. `args` is an optional `MinifyOptions` JSON string;
/// see `minify.zig` for the full shape and defaults.
///
/// On error, no partial output is returned - fall back to the original
/// input, e.g. `html(allocator, input, null) catch input`.
pub fn html(allocator: std.mem.Allocator, input: []const u8, args: ?[]const u8) ![]u8 {
    var parsed = try minify.parseOptions(allocator, args);
    defer parsed.deinit();
    const useHypercrush = parsed.value.html.hypercrush;
    var out: HtmlBuf = .empty;
    errdefer out.deinit(allocator);

    const crossProtect = try htmlCollectCrossScriptNames(allocator, input);
    defer allocator.free(crossProtect);
    defer for (crossProtect) |s| allocator.free(s);

    // Inject cross-script protect names, then re-serialize so embedded
    // calls (js/css/svg) receive a single args string as normal.
    var protect: std.ArrayList([]const u8) = .empty;
    defer protect.deinit(allocator);
    try protect.appendSlice(allocator, parsed.value.js.mangle.protect);
    try protect.appendSlice(allocator, crossProtect);
    parsed.value.js.mangle.protect = protect.items;

    // Embedded SVG defaults to the more aggressive `.all` strip level
    // (dropping `xmlns` is safe once the SVG is inside another
    // document) unless the caller explicitly asked for a level.
    if (parsed.value.svg.strip == null) parsed.value.svg.strip = .all;

    var embeddedArgsBuf: std.Io.Writer.Allocating = .init(allocator);
    defer embeddedArgsBuf.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &embeddedArgsBuf.writer);
    const embeddedArgs: []const u8 = embeddedArgsBuf.written();

    var i: usize = 0;
    const n = input.len;
    var lastTagWasOpen = false;

    while (i < n) {
        const c = input[i];

        if (c == '<') {
            if (i + 3 < n and input[i + 1] == '!' and input[i + 2] == '-' and input[i + 3] == '-') {
                const isConditional = i + 8 <= n and std.mem.eql(u8, input[i + 4 .. i + 8], "[if ");
                const end = std.mem.indexOfPos(u8, input, i + 4, "-->");
                const stop = if (end) |e| e + 3 else n;
                if (isConditional) try out.appendSlice(allocator, input[i..stop]);
                i = stop;
                continue;
            }

            if (i + 1 < n and (input[i + 1] == '!' or input[i + 1] == '?')) {
                const end = std.mem.indexOfScalarPos(u8, input, i, '>');
                const stop = if (end) |e| e + 1 else n;
                try out.appendSlice(allocator, input[i..stop]);
                i = stop;
                continue;
            }

            const tagStart = i;
            const tag = htmlScanTag(input, tagStart);

            if (tag.tagName.len == 0) {
                try out.append(allocator, c);
                i += 1;
                continue;
            }

            if (!tag.isClose and std.ascii.eqlIgnoreCase(tag.tagName, "svg")) {
                const regionEnd = if (tag.isSelfClose) tag.tagEnd else htmlSvgRegionEnd(input, tag.tagEnd);
                const minified = try svg.svg(allocator, input[tagStart..regionEnd], embeddedArgs);
                defer allocator.free(minified);
                try out.appendSlice(allocator, minified);
                i = regionEnd;
                lastTagWasOpen = false;
                continue;
            }

            const tagMinifiedJs = try htmlMinifyEventHandlers(allocator, input[tagStart..tag.tagEnd], embeddedArgs);
            defer if (tagMinifiedJs) |owned| allocator.free(owned);
            try htmlCopyTag(allocator, &out, tagMinifiedJs orelse input[tagStart..tag.tagEnd], useHypercrush);
            i = tag.tagEnd;
            lastTagWasOpen = !tag.isClose;

            if (!tag.isClose) {
                if (htmlRawTextTag(tag.tagName)) |raw| {
                    const closePos = htmlFindCloseTagCI(input, i, raw);
                    const contentEnd = closePos orelse n;
                    const content = input[i..contentEnd];

                    if (std.ascii.eqlIgnoreCase(raw, "style")) {
                        const min = try css.css(allocator, content, embeddedArgs);
                        defer allocator.free(min);
                        try out.appendSlice(allocator, min);
                    } else if (std.ascii.eqlIgnoreCase(raw, "script") and htmlIsMinifiableScript(input, tagStart, i)) {
                        const min = try js.js(allocator, content, embeddedArgs);
                        defer allocator.free(min);
                        try out.appendSlice(allocator, min);
                    } else {
                        try out.appendSlice(allocator, content);
                    }
                    i = contentEnd;
                }
            }
            continue;
        }

        if (htmlIsWs(c)) {
            var j = i;
            while (j < n and htmlIsWs(input[j])) j += 1;
            const nextIsTag = j < n and input[j] == '<';
            const nextIsCloseTag = nextIsTag and j + 1 < n and input[j + 1] == '/';
            const prevIsTag = out.items.len > 0 and out.items[out.items.len - 1] == '>';
            // Base rule drops whitespace only directly between two tags.
            // hypercrush additionally drops it after any opening tag and
            // before any closing tag, but not the reverse.
            const dropWs = if (useHypercrush)
                (prevIsTag and lastTagWasOpen) or nextIsCloseTag
            else
                nextIsTag and prevIsTag;
            if (!dropWs) {
                try out.append(allocator, ' ');
            }
            i = j;
            continue;
        }

        try out.append(allocator, c);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

/// Walks `input` once, read-only, feeding every `<script>` body and
/// every `on*=`/`javascript:`-URL attribute value (including inside
/// nested `<svg>` regions) into a `JsCrossRefCollector`, then resolves
/// the document-wide protect list. See `js.zig` for why this
/// has to happen before any individual script is mangled.
fn htmlCollectCrossScriptNames(allocator: std.mem.Allocator, input: []const u8) ![]const []const u8 {
    var collector = js.JsCrossRefCollector.init(allocator);
    defer collector.deinit();
    try htmlCollectScriptSources(allocator, &collector, input);
    return collector.finalize(allocator);
}

/// Same walk as `htmlCollectCrossScriptNames`, but folding into a
/// caller-owned `collector` instead of allocating and finalizing its
/// own - lets `minify()` build one cross-reference set across several
/// top-level HTML/JS/CSS/SVG sources at once.
pub fn htmlCollectScriptSources(allocator: std.mem.Allocator, collector: *js.JsCrossRefCollector, input: []const u8) !void {
    var i: usize = 0;
    const n = input.len;
    while (i < n) {
        const c = input[i];
        if (c != '<') {
            i += 1;
            continue;
        }

        if (i + 3 < n and input[i + 1] == '!' and input[i + 2] == '-' and input[i + 3] == '-') {
            const end = std.mem.indexOfPos(u8, input, i + 4, "-->");
            i = if (end) |e| e + 3 else n;
            continue;
        }
        if (i + 1 < n and (input[i + 1] == '!' or input[i + 1] == '?')) {
            const end = std.mem.indexOfScalarPos(u8, input, i, '>');
            i = if (end) |e| e + 1 else n;
            continue;
        }

        const tagStart = i;
        const tag = htmlScanTag(input, tagStart);
        if (tag.tagName.len == 0) {
            i += 1;
            continue;
        }

        if (!tag.isClose and std.ascii.eqlIgnoreCase(tag.tagName, "svg")) {
            const regionEnd = if (tag.isSelfClose) tag.tagEnd else htmlSvgRegionEnd(input, tag.tagEnd);
            try htmlCollectSvgScriptSources(allocator, collector, input[tagStart..regionEnd]);
            i = regionEnd;
            continue;
        }

        try htmlCollectTagScriptSources(allocator, collector, input[tagStart..tag.tagEnd]);
        i = tag.tagEnd;

        if (!tag.isClose) {
            if (htmlRawTextTag(tag.tagName)) |raw| {
                const closePos = htmlFindCloseTagCI(input, i, raw);
                const contentEnd = closePos orelse n;
                if (std.ascii.eqlIgnoreCase(raw, "script") and htmlIsMinifiableScript(input, tagStart, i)) {
                    try collector.add(input[i..contentEnd]);
                }
                i = contentEnd;
            }
        }
    }
}

// Parses one `<svg>...</svg>` region just to feed its scripts/handlers
// into `collector` - discards the tree, since the real (mutating)
// pass reparses it later via `svg.svg`. A region that fails to
// parse contributes nothing, same as any other unparseable script.
fn htmlCollectSvgScriptSources(allocator: std.mem.Allocator, collector: *js.JsCrossRefCollector, svgRegion: []const u8) !void {
    var tree = svg.svgParse(allocator, svgRegion) catch return;
    defer tree.deinit();
    const root = tree.root orelse return;
    svg.svgCollectScriptSources(root, collector) catch {};
}

// Read-only counterpart of htmlMinifyEventHandlers: finds the same
// `on*=`/`javascript:`-URL attribute values (quoted or unquoted) and
// feeds their decoded JS into `collector`, without minifying anything.
fn htmlCollectTagScriptSources(allocator: std.mem.Allocator, collector: *js.JsCrossRefCollector, tag: []const u8) !void {
    var i: usize = 0;
    const n = tag.len;
    while (i < n) {
        const c = tag[i];

        if (c == '"' or c == '\'') {
            const attrName = htmlPrecedingAttrName(tag[0..i]);
            const scanned = common.scanQuotedValue(tag, i);
            const kind = if (attrName) |name| htmlAttrKindFor(name, scanned.value) else .none;
            if ((kind == .event_handler or kind == .javascript_url) and scanned.value.len > 0) {
                try htmlCollectOneJsAttrValue(allocator, collector, scanned.value, kind);
            }
            i = scanned.end;
            continue;
        }

        const attrName = htmlPrecedingAttrName(tag[0..i]);
        if (attrName != null and htmlEventAttrName(attrName.?)) {
            var end = i;
            while (end < n and !htmlIsUnquotedValueEnd(tag[end])) end += 1;
            const value = tag[i..end];
            if (value.len > 0) try htmlCollectOneJsAttrValue(allocator, collector, value, .event_handler);
            i = end;
            continue;
        }

        i += 1;
    }
}

fn htmlCollectOneJsAttrValue(allocator: std.mem.Allocator, collector: *js.JsCrossRefCollector, rawValue: []const u8, kind: HtmlAttrKind) !void {
    const decoded = try htmlDecodeEntities(allocator, rawValue);
    defer if (decoded) |d| allocator.free(d);
    const value = decoded orelse rawValue;
    const code = if (kind == .javascript_url)
        std.mem.trim(u8, value, " \t\n\r\x0c")["javascript:".len..]
    else
        value;
    try collector.add(code);
}

const HtmlTag = struct {
    tagEnd: usize, // exclusive index just past '>' (or end of input)
    tagName: []const u8,
    isClose: bool,
    isSelfClose: bool,
};

// Scans a single start/end tag beginning at `input[start] == '<'`
// (callers must have already ruled out comments/doctype/PI), respecting
// quoted attribute values so an embedded '>' doesn't end the tag early.
fn htmlScanTag(input: []const u8, start: usize) HtmlTag {
    const n = input.len;
    var j = start + 1;
    const isClose = j < n and input[j] == '/';
    if (isClose) j += 1;
    const nameStart = j;
    while (j < n and htmlIsNameChar(input[j])) j += 1;
    const tagName = input[nameStart..j];

    var k = j;
    var inQuote: u8 = 0;
    while (k < n) {
        const ch = input[k];
        if (inQuote != 0) {
            if (ch == inQuote) inQuote = 0;
        } else if (ch == '"' or ch == '\'') {
            inQuote = ch;
        } else if (ch == '>') {
            break;
        }
        k += 1;
    }
    const tagEnd = @min(k + 1, n);
    const isSelfClose = tagEnd >= 2 and input[tagEnd - 2] == '/';

    return .{ .tagEnd = tagEnd, .tagName = tagName, .isClose = isClose, .isSelfClose = isSelfClose };
}

// Finds the end of a `<svg>...</svg>` region, tracking nested <svg>
// elements by depth so an inner one doesn't end the region early.
// Returns `input.len` on truncated/malformed input.
fn htmlSvgRegionEnd(input: []const u8, afterOpenTag: usize) usize {
    const n = input.len;
    var i = afterOpenTag;
    var depth: usize = 1;
    while (i < n) {
        const c = input[i];
        if (c != '<') {
            i += 1;
            continue;
        }
        if (i + 3 < n and input[i + 1] == '!' and input[i + 2] == '-' and input[i + 3] == '-') {
            const end = std.mem.indexOfPos(u8, input, i + 4, "-->");
            i = if (end) |e| e + 3 else n;
            continue;
        }
        if (i + 1 < n and (input[i + 1] == '!' or input[i + 1] == '?')) {
            const end = std.mem.indexOfScalarPos(u8, input, i, '>');
            i = if (end) |e| e + 1 else n;
            continue;
        }
        const tag = htmlScanTag(input, i);
        if (tag.tagName.len == 0) {
            i += 1;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(tag.tagName, "svg")) {
            if (tag.isClose) {
                depth -= 1;
                if (depth == 0) return tag.tagEnd;
            } else if (!tag.isSelfClose) {
                depth += 1;
            }
        } else if (!tag.isClose and !tag.isSelfClose) {
            if (htmlRawTextTag(tag.tagName)) |raw| {
                i = htmlFindCloseTagCI(input, tag.tagEnd, raw) orelse n;
                continue;
            }
        }
        i = tag.tagEnd;
    }
    return n;
}

// `type` values (case-insensitive) whose content is real, executable
// JavaScript. A missing `type` attribute also means JavaScript.
const htmlJsScriptTypes = [_][]const u8{
    "text/javascript",
    "application/javascript",
    "module",
};

fn htmlIsMinifiableScript(input: []const u8, tagStart: usize, tagEnd: usize) bool {
    const tag = input[tagStart..tagEnd];
    var i: usize = 1;
    while (i < tag.len and htmlIsNameChar(tag[i])) i += 1;

    while (i < tag.len) {
        while (i < tag.len and htmlIsWs(tag[i])) i += 1;
        if (i >= tag.len or tag[i] == '>' or (tag[i] == '/' and i + 1 < tag.len and tag[i + 1] == '>')) break;

        const nameStart = i;
        while (i < tag.len and tag[i] != '=' and tag[i] != '>' and !htmlIsWs(tag[i]) and !(tag[i] == '/' and i + 1 < tag.len and tag[i + 1] == '>')) i += 1;
        const attrName = tag[nameStart..i];
        if (attrName.len == 0) {
            i += 1;
            continue;
        }

        var value: []const u8 = "";
        var hasValue = false;
        while (i < tag.len and htmlIsWs(tag[i])) i += 1;
        if (i < tag.len and tag[i] == '=') {
            i += 1;
            while (i < tag.len and htmlIsWs(tag[i])) i += 1;
            hasValue = true;
            if (i < tag.len and (tag[i] == '"' or tag[i] == '\'')) {
                const scanned = common.scanQuotedValue(tag, i);
                value = scanned.value;
                i = scanned.end;
            } else {
                const valStart = i;
                while (i < tag.len and !htmlIsWs(tag[i]) and tag[i] != '>') i += 1;
                value = tag[valStart..i];
            }
        }

        if (std.ascii.eqlIgnoreCase(attrName, "src")) return false;
        if (std.ascii.eqlIgnoreCase(attrName, "type") and hasValue) {
            const trimmed = std.mem.trim(u8, value, " \t\n\r\x0c");
            if (trimmed.len == 0) continue; // empty type="" means JS per the HTML spec
            for (htmlJsScriptTypes) |t| {
                if (std.ascii.eqlIgnoreCase(trimmed, t)) return true;
            }
            return false;
        }
    }
    return true;
}

// Known DOM event names, without the "on" prefix, so a non-event
// attribute merely starting with "on" (e.g. `ontology`) isn't matched.
fn htmlEventAttrName(attrName: []const u8) bool {
    return common.isEventAttrName(attrName);
}

// Decodes the handful of HTML character references that could appear
// inside an inline event-handler attribute and matter to JS syntax
// (quotes, ampersand, angle brackets) - not a general entity decoder.
fn htmlDecodeEntities(allocator: std.mem.Allocator, val: []const u8) !?[]u8 {
    if (std.mem.indexOfScalar(u8, val, '&') == null) return null;
    var out: HtmlBuf = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < val.len) {
        if (val[i] == '&') {
            if (htmlMatchEntity(val[i..])) |m| {
                try out.append(allocator, m.decoded);
                i += m.len;
                continue;
            }
        }
        try out.append(allocator, val[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

const HtmlEntityMatch = struct { decoded: u8, len: usize };

fn htmlMatchEntity(s: []const u8) ?HtmlEntityMatch {
    const named = [_]struct { name: []const u8, ch: u8 }{
        .{ .name = "&amp;", .ch = '&' },
        .{ .name = "&quot;", .ch = '"' },
        .{ .name = "&apos;", .ch = '\'' },
        .{ .name = "&lt;", .ch = '<' },
        .{ .name = "&gt;", .ch = '>' },
    };
    for (named) |e| {
        if (std.mem.startsWith(u8, s, e.name)) return .{ .decoded = e.ch, .len = e.name.len };
    }
    const numeric = [_]struct { code: []const u8, ch: u8 }{
        .{ .code = "&#39;", .ch = '\'' },
        .{ .code = "&#x27;", .ch = '\'' },
        .{ .code = "&#X27;", .ch = '\'' },
        .{ .code = "&#34;", .ch = '"' },
        .{ .code = "&#x22;", .ch = '"' },
        .{ .code = "&#X22;", .ch = '"' },
        .{ .code = "&#38;", .ch = '&' },
        .{ .code = "&#x26;", .ch = '&' },
        .{ .code = "&#X26;", .ch = '&' },
        .{ .code = "&#60;", .ch = '<' },
        .{ .code = "&#x3c;", .ch = '<' },
        .{ .code = "&#x3C;", .ch = '<' },
        .{ .code = "&#62;", .ch = '>' },
        .{ .code = "&#x3e;", .ch = '>' },
        .{ .code = "&#x3E;", .ch = '>' },
    };
    for (numeric) |e| {
        if (std.mem.startsWith(u8, s, e.code)) return .{ .decoded = e.ch, .len = e.code.len };
    }
    return null;
}

// Re-encodes only `&` and the matching quote character; `<`/`>` don't
// need escaping inside a quoted attribute value.
fn htmlEncodeForAttr(allocator: std.mem.Allocator, val: []const u8, quote: u8) ![]u8 {
    var out: HtmlBuf = .empty;
    errdefer out.deinit(allocator);
    for (val) |c| {
        if (c == '&') {
            try out.appendSlice(allocator, "&amp;");
        } else if (c == quote) {
            if (quote == '"') try out.appendSlice(allocator, "&quot;") else try out.appendSlice(allocator, "&apos;");
        } else {
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}

// Scans `tag` for quoted/unquoted `on*` event-handler attributes,
// `href`/`action`/`formaction` values starting with `javascript:`, and
// `style` attribute values, minifying each in place. Returns a new tag
// string, or `null` if nothing needed changing.
fn htmlMinifyJsAttrValue(allocator: std.mem.Allocator, value: []const u8, embeddedArgs: []const u8) ![]u8 {
    const decoded = try htmlDecodeEntities(allocator, value);
    defer if (decoded) |d| allocator.free(d);
    const jsInput = decoded orelse value;
    return js.js(allocator, jsInput, embeddedArgs);
}

fn htmlMinifyEventHandlers(allocator: std.mem.Allocator, tag: []const u8, embeddedArgs: []const u8) !?[]u8 {
    var out: HtmlBuf = .empty;
    errdefer out.deinit(allocator);
    var changed = false;

    var i: usize = 0;
    const n = tag.len;
    while (i < n) {
        const c = tag[i];

        if (c == '"' or c == '\'') {
            const attrName = htmlPrecedingAttrName(out.items);
            const scanned = common.scanQuotedValue(tag, i);
            const quote = c;
            const kind = if (attrName) |name| htmlAttrKindFor(name, scanned.value) else .none;

            if (kind != .none and scanned.value.len > 0) {
                const minified = switch (kind) {
                    .event_handler => try htmlMinifyJsAttrValue(allocator, scanned.value, embeddedArgs),
                    .javascript_url => blk: {
                        const trimmed = std.mem.trim(u8, scanned.value, " \t\n\r\x0c");
                        const code = trimmed["javascript:".len..];
                        const js_min = try htmlMinifyJsAttrValue(allocator, code, embeddedArgs);
                        defer allocator.free(js_min);
                        break :blk try std.mem.concat(allocator, u8, &.{ "javascript:", js_min });
                    },
                    .style_attr => try htmlMinifyStyleAttrValue(allocator, scanned.value, embeddedArgs),
                    .none => unreachable,
                };
                defer allocator.free(minified);
                const requoted = if ((kind == .event_handler or kind == .javascript_url) and quote == '"')
                    try js.jsRequoteDoubleToSingleWhereSafe(allocator, minified)
                else
                    null;
                defer if (requoted) |r| allocator.free(r);
                const toEncode = requoted orelse minified;
                const reencoded = try htmlEncodeForAttr(allocator, toEncode, quote);
                defer allocator.free(reencoded);
                try out.append(allocator, quote);
                try out.appendSlice(allocator, reencoded);
                try out.append(allocator, quote);
                changed = true;
            } else {
                try out.appendSlice(allocator, tag[i..scanned.end]);
            }
            i = scanned.end;
            continue;
        }

        const attrName = htmlPrecedingAttrName(out.items);
        const isUnquotedEvent = attrName != null and htmlEventAttrName(attrName.?);
        const isUnquotedStyle = attrName != null and std.ascii.eqlIgnoreCase(attrName.?, "style");
        if (isUnquotedEvent or isUnquotedStyle) {
            // An unquoted `on*=`/`style=` value: re-quote it so the
            // minified JS/CSS (which may itself contain
            // whitespace-significant bytes) can be written back out
            // safely.
            var end = i;
            while (end < n and !htmlIsUnquotedValueEnd(tag[end])) end += 1;
            const value = tag[i..end];
            if (value.len > 0) {
                const minified = if (isUnquotedEvent)
                    try htmlMinifyJsAttrValue(allocator, value, embeddedArgs)
                else
                    try htmlMinifyStyleAttrValue(allocator, value, embeddedArgs);
                defer allocator.free(minified);
                const requoted = if (isUnquotedEvent)
                    try js.jsRequoteDoubleToSingleWhereSafe(allocator, minified)
                else
                    null;
                defer if (requoted) |r| allocator.free(r);
                const toEncode = requoted orelse minified;
                const reencoded = try htmlEncodeForAttr(allocator, toEncode, '"');
                defer allocator.free(reencoded);
                try out.append(allocator, '"');
                try out.appendSlice(allocator, reencoded);
                try out.append(allocator, '"');
                changed = true;
                i = end;
                continue;
            }
        }

        try out.append(allocator, c);
        i += 1;
    }

    if (!changed) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

// `copied` is everything written so far, up to (not including) the
// opening quote or unquoted-value start just found. Returns the
// attribute name if that tail is exactly `<name>=` (whitespace-
// tolerant around the `=`), else `null`.
fn htmlPrecedingAttrName(copied: []const u8) ?[]const u8 {
    var j = copied.len;
    while (j > 0 and htmlIsWs(copied[j - 1])) j -= 1;
    if (j == 0 or copied[j - 1] != '=') return null;
    j -= 1;
    while (j > 0 and htmlIsWs(copied[j - 1])) j -= 1;
    const nameEnd = j;
    while (j > 0 and htmlIsNameChar(copied[j - 1])) j -= 1;
    return copied[j..nameEnd];
}

const HtmlAttrKind = enum { event_handler, javascript_url, style_attr, none };

fn htmlAttrKindFor(attrName: []const u8, value: []const u8) HtmlAttrKind {
    if (htmlEventAttrName(attrName)) return .event_handler;
    if (std.ascii.eqlIgnoreCase(attrName, "href") or std.ascii.eqlIgnoreCase(attrName, "action") or std.ascii.eqlIgnoreCase(attrName, "formaction")) {
        const trimmed = std.mem.trim(u8, value, " \t\n\r\x0c");
        if (htmlStartsWithJavascriptScheme(trimmed)) return .javascript_url;
    }
    if (std.ascii.eqlIgnoreCase(attrName, "style")) return .style_attr;
    return .none;
}

// A `style="..."` value is a bare CSS declaration list, not valid CSS
// on its own - wrap it as `a{...}` before handing it to `css.css`,
// then strip the wrapper back off. Same approach as the SVG minifier's
// `style` attribute handling.
fn htmlMinifyStyleAttrValue(allocator: std.mem.Allocator, value: []const u8, embeddedArgs: []const u8) ![]u8 {
    const decoded = try htmlDecodeEntities(allocator, value);
    defer if (decoded) |d| allocator.free(d);
    const cssInput = decoded orelse value;

    const wrapped = try std.fmt.allocPrint(allocator, "a{{{s}}}", .{cssInput});
    defer allocator.free(wrapped);

    const minifiedWrapped = try css.css(allocator, wrapped, embeddedArgs);
    defer allocator.free(minifiedWrapped);

    var inner = minifiedWrapped;
    if (std.mem.startsWith(u8, inner, "a{")) inner = inner[2..];
    if (std.mem.endsWith(u8, inner, "}")) inner = inner[0 .. inner.len - 1];

    return allocator.dupe(u8, inner);
}

fn htmlStartsWithJavascriptScheme(value: []const u8) bool {
    const prefix = "javascript:";
    if (value.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

// A byte that ends an unquoted HTML attribute value per spec.
fn htmlIsUnquotedValueEnd(c: u8) bool {
    return htmlIsWs(c) or c == '>';
}

fn htmlFindCloseTagCI(input: []const u8, from: usize, tag: []const u8) ?usize {
    var i = from;
    const n = input.len;
    while (i < n) {
        if (input[i] == '<' and i + 1 < n and input[i + 1] == '/') {
            const nameStart = i + 2;
            var j = nameStart;
            while (j < n and htmlIsNameChar(input[j])) j += 1;
            if (std.ascii.eqlIgnoreCase(input[nameStart..j], tag)) return i;
        }
        i += 1;
    }
    return null;
}

fn htmlCopyTag(allocator: std.mem.Allocator, out: *HtmlBuf, tag: []const u8, useHypercrush: bool) !void {
    if (!useHypercrush) {
        try htmlBaseCopyTag(allocator, out, tag);
        return;
    }
    try hypercrush.hcCopyTag(allocator, out, tag);
}

// Collapses internal whitespace runs to a single space and drops
// whitespace immediately before '>' or '/>'. Does not otherwise touch
// quoting, attribute values, or spacing between attributes.
fn htmlBaseCopyTag(allocator: std.mem.Allocator, out: *HtmlBuf, tag: []const u8) !void {
    var i: usize = 0;
    const n = tag.len;
    var pendingSpace = false;
    while (i < n) {
        const c = tag[i];
        if (c == '"' or c == '\'') {
            if (pendingSpace) {
                try out.append(allocator, ' ');
                pendingSpace = false;
            }
            const scanned = common.scanQuotedValue(tag, i);
            try out.appendSlice(allocator, tag[i..scanned.end]);
            i = scanned.end;
            continue;
        }
        if (htmlIsWs(c)) {
            pendingSpace = true;
            i += 1;
            continue;
        }
        if (pendingSpace) {
            const isSelfCloseSlash = c == '/' and i + 1 < n and tag[i + 1] == '>';
            if (c != '>' and !isSelfCloseSlash) {
                try out.append(allocator, ' ');
            }
            pendingSpace = false;
        }
        try out.append(allocator, c);
        i += 1;
    }
}
