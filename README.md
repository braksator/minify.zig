# `minify.zig` - HTML/CSS/JS/SVG Minifier

Minifier for web output: HTML, CSS, JavaScript, and SVG.  **For use in Zig lang projects.**

> Minify loaded code strings or files on disk.

## Adding it to your project

**This project is written against the zig0.17-dev branch.  It will not compile on earlier versions.  That's just how it is for now.**

#1. Add **minify.zig** as a dependency in your project:

`zig fetch --save https://github.com/braksator/minify.zig/archive/refs/tags/v0.2.0.tar.gz`


#2. Then in your *build.zig* add the module:

```zig
const mod = b.dependency("minify_zig", .{
    .target = target,
    .optimize = optimize,
}).module("minify.zig");

exe.root_module.addImport("minify.zig", mod);
```
`target` and `optimize` should be the target and optimize options from your build() function.
This makes `minify.zig` available to import...

### Import minify.zig

```zig
const minify = @import("minify.zig");
```

## HTML string: `html()`

```zig
const out = try minify.html(allocator, input, null);
defer allocator.free(out);
```

## CSS string: `css()`

```zig
const out = try minify.css(allocator, input, null);
defer allocator.free(out);
```

## JavaScript string: `js()`

```zig
const out = try minify.js(allocator, input, null);
defer allocator.free(out);
```

## SVG string: `svg()`

```zig
const out = try minify.svg(allocator, input, null);
defer allocator.free(out);
```

- This does real SVG compression!

## Batches: `minify()`

Minify several sources in one call. This allows automated cross-reference
protections when mangling JavaScript identifiers.

```zig
var items = [_]minify.Item{
    .{ .kind = .html, .source = pageHtml },
    .{ .kind = .css, .source = sharedStylesheet },
    .{ .kind = .js, .source = jsFileAContents },
    .{ .kind = .js, .source = jsFileBContents },
};

try minify.minify(allocator, &items, null);

// items[0].source and items[1].source are now the minified text,
// each a fresh allocation you're responsible for freeing.
```

- Items are mutated in place, any failure aborts the whole call.

## Files: `minifyFiles()`

Same as `minify()` but reads/writes files on disk.

```zig
const items = [_]minify.FileItem{
    .{ .kind = .html, .inPath = "src/page.html", .outPath = "dist/page.html" },
    .{ .kind = .css,  .inPath = "src/site.css",  .outPath = "dist/site.css" },
    .{ .kind = .js,   .inPath = "src/app.js",    .outPath = "dist/app.js" },
};

try minify.minifyFiles(allocator, io, &items, null);
```

- `io` is your `std.Io` instance; `std.process.Init.io`.
- All files are read first, then all contents passed through `minify()`, then output files are written after.
- JS files share mangling protections with JS code found in HTML files, etc...
- Any failure prevents all the output files from being written.


## Options

Very few config options exist here, not because this minifier is lacking
in utility - but because we've already decided what works best.
The more config options you're bogged down in the more you have to understand how
this software works - and that's not fair on you. The few options that are
provided allow for an escape-hatch for potential conflicts with your input.

Applies to all of: `html()`, `css()`, `js()`, `svg()`, `minify()`, and `minifyFiles()`.

The last parameter to all of those is the same: `args: ?[]const u8`.
It is a JSON string with all the options, usually left as `null` which defaults to:

```zig
\\{
\\  "html": { "hypercrush": true },
\\  "css": {},
\\  "js": {
\\    "mangle": {
\\      "enabled": true,
\\      "top": true,
\\      "reserved": [],
\\      "protect": []
\\    }
\\  },
\\  "svg": { "strip": "more", "hypercrush": true }
\\}
```

- **`html`**
    - `hypercrush` applies unorthodox optimizations.
- **`css`**
    - *no options available*
- **`js`**
    - `mangle` is the "uglify" style variable/function name shortening.
    These can be disabled at the `top` level. You can use `reserved` to prevent
    certain short identifiers from being generated, and `protect` to prevent specific
    existing identifiers from being touched by this. (Efforts have already been taken
    to share mangled identifiers across scripts found by the minifier where possible.)
- **`svg`**
    - SVGs are always properly compressed. You can disable `hypercrush` to
    ease off on that a bit.
    - `strip` is one of: `"none"`, `"base"`, `"more"`, or `"all"`.
    The `strip` options affect SVG's usability as a standalone file: `"more"` prevents
    the file being opened in Illustrator, and `"all"` makes it usable only as a DOM-embedded
    tag. The SVG data gets a little smaller at each increasing level. If an embedded
    SVG is detected, the `strip` level is automatically increased to `"all"` unless your
    JSON options overrode that.


You only need to include the fields you're overriding:

```zig
const out = try minify.js(allocator, input, \\{"js":{"mangle":{"top":false}}});
```
...would disable top-level js identifer mangling.
(anything omitted from the passed-in JSON args keeps its default):


*If you need more fine-tuned control than this, your best bet is to go with the
classic JavaScript packages that exist for minification.*

## What gets minified inside what

Every case below is handled automatically.

| Found inside | Content | Handled as |
|---|---|---|
| HTML | `<script>...</script>` text | JS, mangled |
| HTML | `<style>...</style>` text | CSS |
| HTML | `style="..."` attribute value | CSS |
| HTML | `<svg>...</svg>` region | SVG, `strip:"all"`, `hypercrush` |
| HTML | `on*="..."` event-handler attribute | JS, mangled |
| HTML | `href`/`action`/`formaction="javascript:..."` | JS, mangled |
| CSS | `url(...)` containing `data:image/svg+xml` URI or raw `<svg>...` | SVG, `strip:"all"`, `hypercrush` |
| SVG | `<style>...</style>` text | CSS |
| SVG | `style="..."` attribute value | CSS |
| SVG | `<script>...</script>` text | JS, mangled |
| SVG | `on*="..."` event-handler attribute value | JS, mangled |

Not handled: anything embedded *inside JavaScript*. We can't guess what
the JS is doing, so we don't touch it. The theory is that a JS developer
can add minification on their end if they want it.

Embedded SVG unhandled case: `url(...)` case only recognizes `data:image/svg+xml`
not a raw UNQUOTED `<svg ...>`/`<?xml ...>` - too risky - (works if in quotes).

### Cross-script name protection for embedded JS

Within one `html()`, `svg()`, or `css()` call, every `<script>`
element, inline `on*=`/`javascript:` handler, and any JS reachable
through nested embedding (an `<svg>` inside that HTML, an SVG-in-CSS
`url(...)`, and so on) is scanned first to find which top-level names
are declared or referenced in more than one place. Those names are
added to `js.mangle.protect` before any embedded script is actually
mangled, so a name one script declares and another references keeps
its exact spelling even under `top:true` (the default) - only that
shared subset is protected, not top-level mangling as a whole. This
is automatic.

# Caveats

- No vendor prefix removal (CSS).
- No dead code removal (CSS/JS).
- No source maps.
- No precomputing colors (e.g. `color-mix()`, `rgb(from red ...)`).
- SVG: No gradient/pattern deduplication, no path data rewriting.
- JS: No inlining vars/funcs, simplifying logic, function shape conversion
  (e.g. to arrows), or special handling around directive strings or
  completion values.

# JS Parser

Includes a full JS parser which can be usurped for your own purposes.