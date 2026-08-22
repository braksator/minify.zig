//! Byte-level scanning helpers and the unified, per-language options
//! shape shared by css()/html()/js()/svg(), plus the batch entry
//! points minify()/minifyFiles() built on top of them.

const std = @import("std");
const html_mod = @import("html.zig");
const js_mod = @import("js.zig");
const css_mod = @import("css.zig");
const svg_mod = @import("svg.zig");


pub const html = html_mod.html;
pub const js = js_mod.js;
pub const css = css_mod.css;
pub const svg = svg_mod.svg;

pub fn isWsCore(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

pub fn isNameCharCore(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

pub const QuotedValue = struct {
    value: []const u8,
    end: usize,
};

/// Scans a quoted value starting at `input[start]`, which must be `"` or `'`.
pub fn scanQuotedValue(input: []const u8, start: usize) QuotedValue {
    const quote = input[start];
    var i = start + 1;
    const n = input.len;
    while (i < n and input[i] != quote) i += 1;
    const value = input[start + 1 .. i];
    if (i < n) i += 1;
    return .{ .value = value, .end = i };
}

pub const eventNames = [_][]const u8{
    "click",          "dblclick",     "mousedown",  "mouseup",     "mouseover",
    "mousemove",      "mouseout",     "mouseenter", "mouseleave",  "contextmenu",
    "keydown",        "keyup",        "keypress",
    "focus",          "blur",         "focusin",    "focusout",
    "change",         "input",        "submit",     "reset",       "select",
    "load",           "unload",       "beforeunload", "resize",    "scroll",
    "error",          "abort",
    "dragstart",      "drag",         "dragenter",  "dragleave",   "dragover", "drop", "dragend",
    "touchstart",     "touchmove",    "touchend",   "touchcancel",
    "play",           "pause",        "ended",      "volumechange", "timeupdate",
    "animationstart", "animationend", "animationiteration",
    "transitionend",
    "wheel",          "copy",         "cut",        "paste",
    "pointerdown",    "pointerup",    "pointermove", "pointerover", "pointerout",
    "toggle",         "cancel",
    "begin",          "end",          "repeat", // SVG/SMIL animation events
};

/// Reports whether `attrName` is a recognized `on<event>` name.
pub fn isEventAttrName(attrName: []const u8) bool {
    if (attrName.len < 3) return false;
    if (!std.ascii.eqlIgnoreCase(attrName[0..2], "on")) return false;
    const eventPart = attrName[2..];
    for (eventNames) |ev| {
        if (std.ascii.eqlIgnoreCase(eventPart, ev)) return true;
    }
    return false;
}

pub const SvgLevel = enum {
    none,
    base, // strips unreferenced id, version, xml:space, enable-background
    more, // also strips baseProfile
    all, // also strips xmlns; no longer opens standalone
};

pub const JsMangleOptions = struct {
    enabled: bool = true,
    top: bool = true,
    reserved: []const []const u8 = &.{},
    protect: []const []const u8 = &.{},
};

pub const JsOptions = struct {
    mangle: JsMangleOptions = .{},
};

pub const CssOptions = struct {};

pub const SvgOptions = struct {
    // null means "not explicitly set by the caller". `svg()` resolves
    // this to `.more` by default; `html()`/`css()` resolve it to
    // `.all` for SVG they find embedded, unless already set here.
    strip: ?SvgLevel = null,
    hypercrush: bool = true,
};

pub const HtmlOptions = struct {
    hypercrush: bool = true,
};

pub const MinifyOptions = struct {
    css: CssOptions = .{},
    html: HtmlOptions = .{},
    js: JsOptions = .{},
    svg: SvgOptions = .{},
};

/// Parses a `MinifyOptions` JSON string. `null`/empty/malformed input
/// all resolve to every field defaulting.
pub fn parseOptions(allocator: std.mem.Allocator, args: ?[]const u8) !std.json.Parsed(MinifyOptions) {
    const text = args orelse "{}";
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const jsonText = if (trimmed.len == 0) "{}" else trimmed;

    return std.json.parseFromSlice(MinifyOptions, allocator, jsonText, .{ .ignore_unknown_fields = true }) catch
        std.json.parseFromSlice(MinifyOptions, allocator, "{}", .{});
}

pub const Kind = enum { html, js, css, svg };

pub const Item = struct {
    kind: Kind,
    source: []const u8,
};

/// Minifies every item in `items` in place, sharing one JS
/// cross-reference pass across all of them first - a top-level name
/// declared in one item and referenced (or declared again) in another
/// is protected from mangling in both, the same protection `html()`
/// and `svg()` already give scripts within a single document, just
/// extended across separately-supplied sources.
///
/// On success, every `item.source` is replaced with a newly-allocated
/// minified copy and the original is freed. On error, `items` is left
/// completely unmodified - nothing is swapped or freed until every
/// item has minified successfully.
pub fn minify(allocator: std.mem.Allocator, items: []Item, args: ?[]const u8) !void {
    var parsed = try parseOptions(allocator, args);
    defer parsed.deinit();

    var collector = js_mod.JsCrossRefCollector.init(allocator);
    defer collector.deinit();

    for (items) |item| {
        switch (item.kind) {
            .js => try collector.add(item.source),
            .html => try html_mod.htmlCollectScriptSources(allocator, &collector, item.source),
            .svg => {
                var tree = svg_mod.svgParse(allocator, item.source) catch continue;
                defer tree.deinit();
                const root = tree.root orelse continue;
                svg_mod.svgCollectScriptSources(root, &collector) catch {};
            },
            .css => try css_mod.cssCollectScriptSources(allocator, &collector, item.source),
        }
    }

    const crossProtect = try collector.finalize(allocator);
    defer {
        for (crossProtect) |s| allocator.free(s);
        allocator.free(crossProtect);
    }

    var protect: std.ArrayList([]const u8) = .empty;
    defer protect.deinit(allocator);
    try protect.appendSlice(allocator, parsed.value.js.mangle.protect);
    try protect.appendSlice(allocator, crossProtect);
    parsed.value.js.mangle.protect = protect.items;

    var embeddedArgsBuf: std.Io.Writer.Allocating = .init(allocator);
    defer embeddedArgsBuf.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &embeddedArgsBuf.writer);
    const embeddedArgs: []const u8 = embeddedArgsBuf.written();

    const results = try allocator.alloc([]u8, items.len);
    defer allocator.free(results);
    var filled: usize = 0;
    errdefer for (results[0..filled]) |r| allocator.free(r);

    for (items, 0..) |item, idx| {
        results[idx] = switch (item.kind) {
            .html => try html_mod.html(allocator, item.source, embeddedArgs),
            .js => try js_mod.js(allocator, item.source, embeddedArgs),
            .css => try css_mod.css(allocator, item.source, embeddedArgs),
            .svg => try svg_mod.svg(allocator, item.source, embeddedArgs),
        };
        filled += 1;
    }

    for (items, results) |*item, result| {
        allocator.free(item.source);
        item.source = result;
    }
}

pub const FileItem = struct {
    kind: Kind,
    inPath: []const u8,
    outPath: []const u8,
};

/// Reads every `inPath`, minifies them all together via `minify()` (so
/// cross-file JS name protection applies across the whole batch), then
/// writes each result to its matching `outPath` - only once every item
/// has minified successfully. No file is written if any item fails to
/// read or minify. `io` is the caller's `std.Io` instance (e.g.
/// `std.process.Init.io` from `main`).
pub fn minifyFiles(allocator: std.mem.Allocator, io: std.Io, items: []const FileItem, args: ?[]const u8) !void {
    const cwd = std.Io.Dir.cwd();

    var work = try allocator.alloc(Item, items.len);
    defer allocator.free(work);
    var read: usize = 0;
    errdefer for (work[0..read]) |w| allocator.free(w.source);

    for (items, 0..) |fi, idx| {
        const bytes = try cwd.readFileAllocOptions(io, fi.inPath, allocator, .unlimited, .of(u8), null);
        work[idx] = .{ .kind = fi.kind, .source = bytes };
        read += 1;
    }

    try minify(allocator, work, args);
    defer for (work) |w| allocator.free(w.source);

    for (items, work) |fi, w| {
        try cwd.writeFile(io, .{ .sub_path = fi.outPath, .data = w.source });
    }
}
