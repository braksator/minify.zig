//! The "hypercrush" attribute/tag squeeze: unquotes attribute values
//! where safe, drops a redundant leading zero off bare decimals, and
//! collapses whitespace inside a tag. Operates on raw tag text - one
//! `<tag ...>` or `<tag .../>` at a time - so it applies identically
//! whether the tag came from HTML or from serialized SVG/XML.

const std = @import("std");
const common = @import("minify.zig");

fn hcIsWs(c: u8) bool {
    return common.isWsCore(c) or c == '\n' or c == '\x0c';
}

fn hcIsNameChar(c: u8) bool {
    return common.isNameCharCore(c);
}

/// Index of the '0' to omit in a bare decimal like "0.5" or "-0.5"
/// (whole value only - "0.5-notes.html" is left alone), or null.
pub fn hcLeadingZeroSkipIndex(val: []const u8) ?usize {
    if (val.len >= 2 and val[0] == '0' and val[1] == '.') {
        var j: usize = 2;
        while (j < val.len and std.ascii.isDigit(val[j])) j += 1;
        if (j == val.len) return 0;
    }
    if (val.len >= 3 and val[0] == '-' and val[1] == '0' and val[2] == '.') {
        var j: usize = 3;
        while (j < val.len and std.ascii.isDigit(val[j])) j += 1;
        if (j == val.len) return 1;
    }
    return null;
}

fn hcCanUnquote(val: []const u8, skip: ?usize) bool {
    if (val.len == 0) return false;
    if (val.len == 1 and skip != null) return false;
    for (val, 0..) |c, idx| {
        if (skip) |s| {
            if (idx == s) continue;
        }
        if (hcIsWs(c) or c == '"' or c == '\'' or c == '`' or c == '=' or c == '<' or c == '>') return false;
    }
    return true;
}

/// Emits `=value` for an attribute, unquoting when safe. Returns
/// whether the value was left unquoted, so the caller can tell if a
/// space is needed before whatever comes right after it.
fn hcEmitAttrValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), val: []const u8) !bool {
    const skip = hcLeadingZeroSkipIndex(val);
    const needsQuotes = !hcCanUnquote(val, skip);
    try out.append(allocator, '=');
    if (needsQuotes) try out.append(allocator, '"');
    if (skip) |idx| {
        try out.appendSlice(allocator, val[0..idx]);
        try out.appendSlice(allocator, val[idx + 1 ..]);
    } else {
        try out.appendSlice(allocator, val);
    }
    if (needsQuotes) try out.append(allocator, '"');
    return !needsQuotes;
}

/// Rewrites one tag's raw text (`<div class="x">`, `<br/>`, `</div>`, ...)
/// with hypercrush's attribute squeeze: whitespace collapsed to single
/// spaces, dropped around `=`, and unquoted where the value permits it.
pub fn hcCopyTag(allocator: std.mem.Allocator, out: *std.ArrayList(u8), tag: []const u8) !void {
    if (tag.len == 0) return;
    var i: usize = 0;
    const n = tag.len;
    var lastWasUnquotedValue = false;

    try out.append(allocator, tag[i]); // '<'
    i += 1;
    if (i < n and tag[i] == '/') {
        try out.append(allocator, tag[i]);
        i += 1;
    }
    while (i < n and hcIsNameChar(tag[i])) {
        try out.append(allocator, tag[i]);
        i += 1;
    }

    while (i < n) {
        while (i < n and hcIsWs(tag[i])) i += 1;
        if (i >= n) break;
        if (tag[i] == '>') break;
        if (tag[i] == '/' and i + 1 < n and tag[i + 1] == '>') break;

        const attrNameStart = i;
        while (i < n and tag[i] != '=' and tag[i] != '>' and !hcIsWs(tag[i]) and !(tag[i] == '/' and i + 1 < n and tag[i + 1] == '>')) i += 1;
        const attrName = tag[attrNameStart..i];
        if (attrName.len == 0) {
            i += 1;
            continue;
        }

        while (i < n and hcIsWs(tag[i])) i += 1;

        // A closing quote is itself an unambiguous attribute boundary,
        // so no space is needed there. Anything else needs a space or
        // two tokens would fuse.
        if (out.items.len > 0) {
            const lastByte = out.items[out.items.len - 1];
            if (lastByte != '"' and lastByte != '\'') {
                try out.append(allocator, ' ');
            }
        }
        try out.appendSlice(allocator, attrName);
        lastWasUnquotedValue = false;

        if (i < n and tag[i] == '=') {
            i += 1;
            while (i < n and hcIsWs(tag[i])) i += 1;
            if (i < n and (tag[i] == '"' or tag[i] == '\'')) {
                const scanned = common.scanQuotedValue(tag, i);
                i = scanned.end;
                lastWasUnquotedValue = try hcEmitAttrValue(allocator, out, scanned.value);
            } else {
                const valStart = i;
                while (i < n and !hcIsWs(tag[i]) and tag[i] != '>') i += 1;
                const val = tag[valStart..i];
                try out.append(allocator, '=');
                try out.appendSlice(allocator, val);
                lastWasUnquotedValue = true;
            }
        }
    }

    while (i < n and hcIsWs(tag[i])) i += 1;
    if (i < n and tag[i] == '/' and i + 1 < n and tag[i + 1] == '>') {
        // A space is only needed if the byte immediately before `/>`
        // is an unquoted attribute value - anything else (a bare tag
        // name, a closing quote) is already an unambiguous boundary.
        if (lastWasUnquotedValue) {
            try out.appendSlice(allocator, " />");
        } else {
            try out.appendSlice(allocator, "/>");
        }
    } else if (i < n and tag[i] == '>') {
        try out.append(allocator, '>');
    }
}
