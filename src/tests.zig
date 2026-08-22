//! Test suite for all `src/` minifiers, grouped one namespace per
//! former test file so identically-named local helpers don't collide.
const std = @import("std");

const css_html_tests = struct {
    const testing = std.testing;
    const cssMinify = @import("css.zig").css;
    const html = @import("html.zig").html;

    // Opts out of every default-on feature so tests can assert exact
    // output without interference from mangling/stripping/hypercrush.
    const conservativeArgs = "{\"js\":{\"mangle\":{\"enabled\":false}},\"html\":{\"hypercrush\":false},\"svg\":{\"strip\":\"none\",\"hypercrush\":false}}";

    fn expectCSS(input: []const u8, expected: []const u8) !void {
        const out = try cssMinify(testing.allocator, input, conservativeArgs);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(expected, out);
    }

    fn expectHTML(input: []const u8, expected: []const u8, args: []const []const u8) !void {
        var jsonArgs: []const u8 = conservativeArgs;
        var mangle = false;
        var hypercrush = false;
        var svgDefault = false;
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "hypercrush")) hypercrush = true;
            if (std.mem.eql(u8, arg, "mangle")) mangle = true;
            if (std.mem.eql(u8, arg, "svgDefault")) svgDefault = true;
            if (std.mem.eql(u8, arg, "bogus")) {} // unknown args are ignored
        }
        if (mangle and hypercrush) {
            jsonArgs = "{\"js\":{\"mangle\":{\"enabled\":true}},\"html\":{\"hypercrush\":true},\"svg\":{\"strip\":\"none\",\"hypercrush\":false}}";
        } else if (hypercrush and svgDefault) {
            jsonArgs = "{\"js\":{\"mangle\":{\"enabled\":false}},\"html\":{\"hypercrush\":true}}";
        } else if (hypercrush) {
            jsonArgs = "{\"js\":{\"mangle\":{\"enabled\":false}},\"html\":{\"hypercrush\":true},\"svg\":{\"strip\":\"none\",\"hypercrush\":false}}";
        } else if (mangle) {
            jsonArgs = "{\"js\":{\"mangle\":{\"enabled\":true}},\"html\":{\"hypercrush\":false},\"svg\":{\"strip\":\"none\",\"hypercrush\":false}}";
        } else if (svgDefault) {
            jsonArgs = "{\"js\":{\"mangle\":{\"enabled\":false}},\"html\":{\"hypercrush\":false}}";
        }
        const out = try html(testing.allocator, input, jsonArgs);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(expected, out);
    }

    test "css: basic whitespace collapse" {
        try expectCSS(
            \\body {
            \\  color: red;
            \\  margin: 0 ;
            \\}
        ,
            "body{color:red;margin:0}",
        );
    }

    test "css: comments stripped" {
        try expectCSS("/* hi */a{color:red}/* bye */", "a{color:red}");
    }

    test "css: selector list spacing" {
        try expectCSS("h1, h2 ,h3 { color: red }", "h1,h2,h3{color:red}");
    }

    test "css: combinators" {
        try expectCSS("div > p ~ span + a { color: red }", "div>p~span+a{color:red}");
    }

    test "css: strings preserved" {
        try expectCSS("a{content: \"  spaced  \"}", "a{content:\"  spaced  \"}");
    }

    test "css: paren whitespace collapsed" {
        try expectCSS("a:not( .x )   { color:red }", "a:not(.x){color:red}");
    }

    test "css: calc spacing preserved" {
        try expectCSS("div{width:calc(100% - 10px)}", "div{width:calc(100% - 10px)}");
    }

    test "css: calc nested" {
        try expectCSS("div{width:calc(  100% - calc(5px + 2px)  )}", "div{width:calc(100% - calc(5px + 2px))}");
    }

    test "css: calc addition of same-unit values folds to a constant" {
        try expectCSS("div{width:calc(10px + 5px)}", "div{width:15px}");
    }

    test "css: calc subtraction of same-unit values folds to a constant" {
        try expectCSS("div{width:calc(10px - 3px)}", "div{width:7px}");
    }

    test "css: calc multiplication by a unitless number folds to a constant" {
        try expectCSS("div{width:calc(100px * 2)}", "div{width:200px}");
    }

    test "css: calc multiplication with the unitless number first folds to a constant" {
        try expectCSS("div{width:calc(2 * 100px)}", "div{width:200px}");
    }

    test "css: calc division by a unitless number folds to a constant" {
        try expectCSS("div{width:calc(100px / 4)}", "div{width:25px}");
    }

    test "css: calc respects operator precedence when folding" {
        try expectCSS("div{width:calc(10px + 2px * 3)}", "div{width:16px}");
    }

    test "css: calc folds a parenthesized sub-expression" {
        try expectCSS("div{width:calc((10px + 2px) * 3)}", "div{width:36px}");
    }

    test "css: calc folds unitless-only arithmetic" {
        try expectCSS("div{z-index:calc(1 + 2)}", "div{z-index:3}");
    }

    test "css: calc folds percentage arithmetic" {
        try expectCSS("div{width:calc(50% * 2)}", "div{width:100%}");
    }

    test "css: calc folds a non-integer result to a trimmed decimal" {
        try expectCSS("div{width:calc(10px / 4)}", "div{width:2.5px}");
    }

    test "css: calc referencing a custom property is never folded" {
        try expectCSS("div{width:calc(var(--x) + 10px)}", "div{width:calc(var(--x) + 10px)}");
    }

    test "css: calc dividing by zero is never folded" {
        try expectCSS("div{width:calc(10px / 0)}", "div{width:calc(10px / 0)}");
    }

    test "css: calc multiplying two dimensioned values is never folded" {
        try expectCSS("div{width:calc(10px * 2px)}", "div{width:calc(10px * 2px)}");
    }

    test "css: a calc() nested inside min() is left for min() to resolve" {
        try expectCSS("div{width:min(calc(5px + 2px), 8px)}", "div{width:min(7px,8px)}");
    }

    test "css: an identifier ending in calc is not treated as the calc function" {
        try expectCSS("div{width:foo-calc(1px+2px)}", "div{width:foo-calc(1px+2px)}");
    }

    test "css: min spacing preserved" {
        try expectCSS("div{width:min(100% - 10px, 50vw)}", "div{width:min(100% - 10px,50vw)}");
    }

    test "css: max spacing preserved" {
        try expectCSS("div{width:max(100% - 10px, 50vw)}", "div{width:max(100% - 10px,50vw)}");
    }

    test "css: clamp spacing preserved" {
        try expectCSS("div{width:clamp(10px, 100% - 10px, 50vw)}", "div{width:clamp(10px,100% - 10px,50vw)}");
    }

    test "css: min/max/clamp match case-insensitively" {
        try expectCSS("div{width:MIN(100% - 10px, 50vw)}", "div{width:MIN(100% - 10px,50vw)}");
    }

    test "css: min nested inside calc" {
        try expectCSS("div{width:calc(10px + min(5px + 2px, 8px))}", "div{width:calc(10px + min(5px + 2px,8px))}");
    }

    test "css: function name ending in max/min/calc/clamp is not treated as one" {
        try expectCSS("div{width:foo-max(1px+2px)}", "div{width:foo-max(1px+2px)}");
    }

    test "css: media query keeps required space between and and (" {
        try expectCSS(
            "@media (min-width: 768px) and (max-width: 991px){a{color:red}}",
            "@media(min-width:768px) and (max-width:991px){a{color:red}}",
        );
    }

    test "css: supports query keeps required space between or/not and (" {
        try expectCSS(
            "@supports (display: flex) or (display: grid){a{color:red}}",
            "@supports(display:flex) or (display:grid){a{color:red}}",
        );
        try expectCSS(
            "@supports not (display: flex){a{color:red}}",
            "@supports not (display:flex){a{color:red}}",
        );
    }

    test "css: :not() with no source space stays collapsed" {
        try expectCSS("a:not(.foo){color:red}", "a:not(.foo){color:red}");
    }

    test "css: identifier merely ending in and/or/not keeps its space collapsed normally" {
        try expectCSS("div{content:grand (1)}", "div{content:grand(1)}");
    }

    test "css: 6-digit hex color shortens when digit pairs repeat" {
        try expectCSS("a{color:#ffffff}", "a{color:#fff}");
        try expectCSS("a{color:#AABBCC}", "a{color:#ABC}");
    }

    test "css: 8-digit hex color (with alpha) shortens when digit pairs repeat" {
        try expectCSS("a{color:#ffffffaa}", "a{color:#fffa}");
    }

    test "css: hex color is left alone when digit pairs don't repeat" {
        try expectCSS("a{color:#a1b2c3}", "a{color:#a1b2c3}");
    }

    test "css: 3/4-digit hex color is already short and left alone" {
        try expectCSS("a{color:#fff}", "a{color:#fff}");
        try expectCSS("a{color:#ffff}", "a{color:#ffff}");
    }

    test "css: 7-digit hex-shaped token is not touched (not a valid color length)" {
        try expectCSS("a{color:#aabbccd}", "a{color:#aabbccd}");
    }

    test "css: hex color inside a function argument still shortens" {
        try expectCSS("a{background:linear-gradient(#ffffff,#000000)}", "a{background:linear-gradient(#fff,#000)}");
    }

    test "css: rgb() still converts when nested two levels deep in a value" {
        try expectCSS(
            "a{background:linear-gradient(red,rgb(0,0,0))}",
            "a{background:linear-gradient(red,#000)}",
        );
    }

    test "css: hex color shortens after a sibling function call earlier in the same value" {
        try expectCSS(
            "a{background:url(foo.png),linear-gradient(red,#ffffff)}",
            "a{background:url(foo.png),linear-gradient(red,#fff)}",
        );
    }

    test "css: id selector with hex-shaped repeating-pair id is never shortened" {
        try expectCSS("#aabbcc{color:red}", "#aabbcc{color:red}");
        try expectCSS("a #aabbcc{color:red}", "a #aabbcc{color:red}");
    }

    test "css: hex-shaped id after a pseudo-class with no combinator is never shortened" {
        try expectCSS("a:hover#aabbcc{color:red}", "a:hover#aabbcc{color:red}");
    }

    test "css: hex-shaped fragment inside unquoted url() is never shortened" {
        try expectCSS("a{background:url(icon.svg#aabbcc)}", "a{background:url(icon.svg#aabbcc)}");
    }

    test "css: hex color still shortens inside a nested rule's declaration" {
        try expectCSS("a{&:hover{color:#ffffff}}", "a{&:hover{color:#fff}}");
    }

    test "css: rgb() with literal integers converts to the shortest color form" {
        try expectCSS("a{color:rgb(255,0,0)}", "a{color:red}");
    }

    test "css: rgb() with modern space syntax converts to the shortest color form" {
        try expectCSS("a{color:rgb(255 0 0)}", "a{color:red}");
    }

    test "css: rgba() with opaque alpha converts to the shortest color form" {
        try expectCSS("a{color:rgba(255,0,0,1)}", "a{color:red}");
    }

    test "css: rgba() with partial alpha converts to 4/8-digit hex" {
        try expectCSS("a{color:rgba(255,0,0,0.2)}", "a{color:#f003}");
    }

    test "css: hsl() with literal percentages converts to the shortest color form" {
        try expectCSS("a{color:hsl(0,100%,50%)}", "a{color:red}");
        try expectCSS("a{color:hsl(120,100%,50%)}", "a{color:#0f0}");
    }

    test "css: hsl() with deg unit on the hue converts to hex" {
        try expectCSS("a{color:hsl(120deg,100%,50%)}", "a{color:#0f0}");
        try expectCSS("a{color:hsl(120deg 100% 50%)}", "a{color:#0f0}");
    }

    test "css: hsl() with rad/grad/turn units on the hue converts to hex" {
        try expectCSS("a{color:hsl(2.0943951rad,100%,50%)}", "a{color:#0f0}");
        try expectCSS("a{color:hsl(133.333grad,100%,50%)}", "a{color:#0f0}");
        try expectCSS("a{color:hsl(0.3333turn,100%,50%)}", "a{color:#0f0}");
    }

    test "css: hsl() angle unit only applies to the hue argument" {
        // A bare identifier in the saturation/lightness slots is not a
        // literal number - must bail out, not misread it as an angle.
        try expectCSS("a{color:hsl(120deg,var(--s),50%)}", "a{color:hsl(120deg,var(--s),50%)}");
    }

    test "css: rgb() with percentage channels converts to the shortest color form" {
        try expectCSS("a{color:rgb(100%,0%,0%)}", "a{color:red}");
    }

    test "css: color function is left alone outside a color property" {
        try expectCSS("a{width:calc(1px + var(--x))}", "a{width:calc(1px + var(--x))}");
    }

    test "css: color function with var() argument is left untouched" {
        try expectCSS("a{color:rgb(var(--r),0,0)}", "a{color:rgb(var(--r),0,0)}");
    }

    test "css: named color shortens to hex only when hex is actually shorter" {
        try expectCSS("a{color:white}", "a{color:#fff}");
        try expectCSS("a{color:red}", "a{color:red}");
    }

    test "css: named color is only rewritten in a color-accepting property" {
        try expectCSS("a{font-family:white}", "a{font-family:white}");
        try expectCSS("a{animation-name:coral}", "a{animation-name:coral}");
    }

    test "css: a color name that is a substring of a longer identifier is not matched" {
        try expectCSS("a{color:mytan}", "a{color:mytan}");
        try expectCSS("a{color:tangelo}", "a{color:tangelo}");
    }

    test "css: whitesmoke converts to its shorter hex form" {
        try expectCSS("a{color:whitesmoke}", "a{color:#f5f5f5}");
    }

    test "css: transparent/currentcolor keywords are never rewritten" {
        try expectCSS("a{color:transparent}", "a{color:transparent}");
        try expectCSS("a{color:currentColor}", "a{color:currentColor}");
    }

    test "css: hex color shortens to a named color when the name is shorter" {
        try expectCSS("a{color:#ff0000}", "a{color:red}");
    }

    test "css: opaque 8-digit hex color with alpha=ff still compares against the alpha-preserving hex form" {
        // #0000ffff -> #00ff (4-digit alpha form, 5 chars) - "blue" (4
        // chars) only wins once the alpha digits are counted correctly;
        // against the RGB-only baseline (#00f, 4 chars) it would tie
        // and lose.
        try expectCSS("a{color:#0000ffff}", "a{color:blue}");
    }

    test "css: hex color with no matching name still shortens to its 3-digit hex form" {
        try expectCSS("a{color:#aabbcc}", "a{color:#abc}");
        try expectCSS("a{color:#112233}", "a{color:#123}");
    }

    test "css: hex-to-name shortening only applies in a color-accepting property" {
        try expectCSS("a{border-color:#ff0000}", "a{border-color:red}");
    }

    test "css: opaque rgb()/rgba() shortens to a named color when the name is shorter" {
        try expectCSS("a{color:rgb(255,0,0)}", "a{color:red}");
        try expectCSS("a{color:rgba(255,0,0,1)}", "a{color:red}");
    }

    test "css: opaque hsl() shortens to a named color when the name is shorter" {
        try expectCSS("a{color:hsl(0,100%,50%)}", "a{color:red}");
    }

    test "css: rgba() with partial alpha never becomes a named color (alpha isn't representable)" {
        try expectCSS("a{color:rgba(255,0,0,0.2)}", "a{color:#f003}");
    }

    test "css: unrelated function with plus/minus is not affected" {
        try expectCSS("div{content:counter(x - 1)}", "div{content:counter(x - 1)}");
    }

    test "css: custom property with url() containing colons and semicolons" {
        try expectCSS(
            "a{--icon:url(data:image/png;base64,AAAA)}",
            "a{--icon:url(data:image/png;base64,AAAA)}",
        );
    }

    test "css: custom property value whitespace collapses like any other" {
        try expectCSS(
            "a{--gap:  1px   2px  ;margin:var(--gap)}",
            "a{--gap:1px 2px;margin:var(--gap)}",
        );
    }

    test "css: custom property value with commas and nested parens" {
        try expectCSS(
            "a{--shadow:0 1px 2px rgba(0,0,0,.5), inset 0 0 0 1px red}",
            "a{--shadow:0 1px 2px rgba(0,0,0,.5),inset 0 0 0 1px red}",
        );
    }

    test "css: custom property value with a quoted string is preserved verbatim" {
        try expectCSS(
            "a{--label:\"hello  world\"}",
            "a{--label:\"hello  world\"}",
        );
    }

    test "css: custom property with negative number keeps no space after colon" {
        try expectCSS("a{--offset: -5px}", "a{--offset:-5px}");
    }

    test "css: no trailing semicolon before brace" {
        try expectCSS("a{color:red;}", "a{color:red}");
    }

    test "css: grid-template-areas collapses dot runs to a single dot" {
        try expectCSS(
            "div{grid-template-areas:\"a a\" \"..... b\"}",
            "div{grid-template-areas:\"a a\" \". b\"}",
        );
    }

    test "css: grid-template-areas collapses extra whitespace between cells" {
        try expectCSS(
            "div{grid-template-areas:\"header   header\" \"sidebar    main\"}",
            "div{grid-template-areas:\"header header\" \"sidebar main\"}",
        );
    }

    test "css: grid-template-areas trims leading/trailing whitespace in a row" {
        try expectCSS(
            "div{grid-template-areas:\"  a  b  \"}",
            "div{grid-template-areas:\"a b\"}",
        );
    }

    test "css: grid-template shorthand rows are also reformatted" {
        try expectCSS(
            "div{grid-template:\"a  a\" 1fr \"..  b\" 2fr / auto auto}",
            "div{grid-template:\"a a\" 1fr \". b\" 2fr / auto auto}",
        );
    }

    test "css: grid shorthand rows are also reformatted" {
        try expectCSS(
            "div{grid:\"a  a\" 1fr / auto auto}",
            "div{grid:\"a a\" 1fr / auto auto}",
        );
    }

    test "css: four padding longhands combine into padding shorthand" {
        try expectCSS(
            "div{padding-top:1px;padding-right:2px;padding-bottom:3px;padding-left:4px}",
            "div{padding:1px 2px 3px 4px}",
        );
    }

    test "css: four margin longhands combine into margin shorthand" {
        try expectCSS(
            "div{margin-top:1px;margin-right:2px;margin-bottom:3px;margin-left:4px}",
            "div{margin:1px 2px 3px 4px}",
        );
    }

    test "css: combined shorthand value drops repeated trailing sides" {
        try expectCSS(
            "div{margin-top:1px;margin-right:2px;margin-bottom:1px;margin-left:2px}",
            "div{margin:1px 2px}",
        );
    }

    test "css: combined shorthand value collapses to a single side" {
        try expectCSS(
            "div{margin-top:1px;margin-right:1px;margin-bottom:1px;margin-left:1px}",
            "div{margin:1px}",
        );
    }

    test "css: longhands only combine when contiguous" {
        try expectCSS(
            "div{margin-top:1px;color:red;margin-right:2px;margin-bottom:3px;margin-left:4px}",
            "div{margin-top:1px;color:red;margin-right:2px;margin-bottom:3px;margin-left:4px}",
        );
    }

    test "css: an incomplete run of longhands is left alone" {
        try expectCSS(
            "div{margin-top:1px;margin-right:2px;margin-bottom:3px}",
            "div{margin-top:1px;margin-right:2px;margin-bottom:3px}",
        );
    }

    test "css: a duplicated longhand breaks combining at that position, but a later complete run still combines" {
        try expectCSS(
            "div{margin-top:1px;margin-top:9px;margin-right:2px;margin-bottom:3px;margin-left:4px}",
            "div{margin-top:1px;margin:9px 2px 3px 4px}",
        );
    }

    test "css: a duplicated longhand within the only possible run is left alone" {
        try expectCSS(
            "div{margin-top:1px;margin-top:9px;margin-right:2px;margin-bottom:3px}",
            "div{margin-top:1px;margin-top:9px;margin-right:2px;margin-bottom:3px}",
        );
    }

    test "css: longhands only combine when !important matches on all four" {
        try expectCSS(
            "div{margin-top:1px!important;margin-right:2px;margin-bottom:3px;margin-left:4px}",
            "div{margin-top:1px!important;margin-right:2px;margin-bottom:3px;margin-left:4px}",
        );
    }

    test "css: combined shorthand keeps !important when all four longhands carry it" {
        try expectCSS(
            "div{margin-top:1px !important;margin-right:2px !important;margin-bottom:3px !important;margin-left:4px !important}",
            "div{margin:1px 2px 3px 4px!important}",
        );
    }

    test "css: other declarations around a combined run are preserved" {
        try expectCSS(
            "div{color:red;padding-top:1px;padding-right:2px;padding-bottom:3px;padding-left:4px;font-size:9px}",
            "div{color:red;padding:1px 2px 3px 4px;font-size:9px}",
        );
    }

    test "css: four border-width longhands combine into border-width shorthand" {
        try expectCSS(
            "div{border-top-width:1px;border-right-width:2px;border-bottom-width:3px;border-left-width:4px}",
            "div{border-width:1px 2px 3px 4px}",
        );
    }

    test "css: four border-style longhands combine into border-style shorthand" {
        try expectCSS(
            "div{border-top-style:solid;border-right-style:dashed;border-bottom-style:solid;border-left-style:dashed}",
            "div{border-style:solid dashed}",
        );
    }

    test "css: four border-color longhands combine into border-color shorthand" {
        try expectCSS(
            "div{border-top-color:red;border-right-color:red;border-bottom-color:red;border-left-color:red}",
            "div{border-color:red}",
        );
    }

    test "css: unrelated properties are never combined" {
        try expectCSS(
            "div{border-top:1px;border-right:2px;border-bottom:3px;border-left:4px}",
            "div{border-top:1px;border-right:2px;border-bottom:3px;border-left:4px}",
        );
    }

    test "css: shorthand combining does not cross nested rule blocks" {
        try expectCSS(
            "@media screen{div{margin-top:1px;margin-right:2px;margin-bottom:3px;margin-left:4px}}",
            "@media screen{div{margin:1px 2px 3px 4px}}",
        );
    }

    test "css: background-position drops a trailing default center" {
        try expectCSS(
            "div{background-position:left center}",
            "div{background-position:left}",
        );
    }

    test "css: background-position center center collapses to center" {
        try expectCSS(
            "div{background-position:center center}",
            "div{background-position:center}",
        );
    }

    test "css: background-position keyword pairs collapse regardless of order" {
        try expectCSS(
            "div{background-position:top center}",
            "div{background-position:top}",
        );
    }

    test "css: object-position and transform-origin also drop a trailing center" {
        try expectCSS(
            "div{object-position:right center;transform-origin:left center}",
            "div{object-position:right;transform-origin:left}",
        );
    }

    test "css: background-position is untouched when neither value is a redundant center" {
        try expectCSS(
            "div{background-position:left top}",
            "div{background-position:left top}",
        );
    }

    test "css: background-position with an offset before center is untouched" {
        try expectCSS(
            "div{background-position:right 20px center}",
            "div{background-position:right 20px center}",
        );
    }

    test "css: background-position leading center before a non-center value is untouched" {
        try expectCSS(
            "div{background-position:center top}",
            "div{background-position:center top}",
        );
    }

    test "css: multi-position background-position list is untouched" {
        try expectCSS(
            "div{background-position:0 0,center center}",
            "div{background-position:0 0,center center}",
        );
    }

    test "css: unrelated properties never get position-value treatment" {
        try expectCSS(
            "div{content:\"a center\"}",
            "div{content:\"a center\"}",
        );
    }

    test "css: a zero length drops its unit" {
        try expectCSS(
            "div{margin:0px}",
            "div{margin:0}",
        );
    }

    test "css: a zero angle drops its unit" {
        try expectCSS(
            "div{--x:0deg}",
            "div{--x:0}",
        );
    }

    test "css: every recognized length/angle unit drops from a zero value" {
        try expectCSS(
            "div{margin:0px 0em 0rem 0ex 0ch 0vw 0vh 0vmin 0vmax 0cm 0mm 0q 0in 0pt 0pc}",
            "div{margin:0 0 0 0 0 0 0 0 0 0 0 0 0 0 0}",
        );
    }

    test "css: negative and positive zero normalize to plain zero" {
        try expectCSS(
            "div{margin:-0px;padding:+0em}",
            "div{margin:0;padding:0}",
        );
    }

    test "css: a decimal zero drops its unit" {
        try expectCSS(
            "div{margin:0.0px}",
            "div{margin:0}",
        );
    }

    test "css: a zero percentage keeps its percent sign" {
        try expectCSS(
            "div{width:0%}",
            "div{width:0%}",
        );
    }

    test "css: negative zero percentage still normalizes" {
        try expectCSS(
            "div{width:-0%}",
            "div{width:0%}",
        );
    }

    test "css: a zero time value keeps its unit" {
        try expectCSS(
            "div{transition-duration:0s}",
            "div{transition-duration:0s}",
        );
    }

    test "css: a zero frequency or resolution value keeps its unit" {
        try expectCSS(
            "div{--f:0Hz;--r:0dpi}",
            "div{--f:0Hz;--r:0dpi}",
        );
    }

    test "css: a nonzero length is left untouched" {
        try expectCSS(
            "div{margin:10px}",
            "div{margin:10px}",
        );
    }

    test "css: a nonzero decimal length is left untouched" {
        try expectCSS(
            "div{margin:0.5px}",
            "div{margin:0.5px}",
        );
    }

    test "css: a zero value inside any function call is left untouched" {
        try expectCSS(
            "div{transform:translate(0px,0px);color:rgb(0px 0 0)}",
            "div{transform:translate(0px,0px);color:rgb(0px 0 0)}",
        );
    }

    test "css: only the zero tokens in a mixed-value declaration are rewritten" {
        try expectCSS(
            "div{border-width:0px 1px 0em 2px}",
            "div{border-width:0 1px 0 2px}",
        );
    }

    test "css: adjacent rules with identical declarations merge selectors" {
        try expectCSS(
            ".a{color:red}.b{color:red}",
            ".a,.b{color:red}",
        );
    }

    test "css: three adjacent rules with identical declarations all merge" {
        try expectCSS(
            ".a{color:red}.b{color:red}.c{color:red}",
            ".a,.b,.c{color:red}",
        );
    }

    test "css: an already-comma-separated selector list still merges with a matching neighbor" {
        try expectCSS(
            ".a,.b{color:red}.c{color:red}",
            ".a,.b,.c{color:red}",
        );
    }

    test "css: adjacent rules with an identical selector merge declarations" {
        try expectCSS(
            ".a{color:red}.a{margin:0}",
            ".a{color:red;margin:0}",
        );
    }

    test "css: a duplicate property across merged same-selector rules keeps source order" {
        try expectCSS(
            ".a{color:red}.a{color:blue}",
            ".a{color:red;color:blue}",
        );
    }

    test "css: a differing rule in between breaks the merge" {
        try expectCSS(
            ".a{color:red}.mid{x:y}.b{color:red}",
            ".a{color:red}.mid{x:y}.b{color:red}",
        );
    }

    test "css: rules with neither matching selector nor declarations are left alone" {
        try expectCSS(
            ".a{color:red}.b{margin:0}",
            ".a{color:red}.b{margin:0}",
        );
    }

    test "css: a single rule with no adjacent match is left alone" {
        try expectCSS(".a{color:red}", ".a{color:red}");
    }

    test "css: rule merging does not cross into or out of a nested rule block" {
        try expectCSS(
            "@media screen{.a{color:red}.b{color:red}}.c{color:red}",
            "@media screen{.a,.b{color:red}}.c{color:red}",
        );
    }

    test "css: an at-rule is never merged with a neighboring style rule" {
        try expectCSS(
            "@font-face{font-family:x}.a{font-family:x}",
            "@font-face{font-family:x}.a{font-family:x}",
        );
    }

    test "css: unrelated quoted string whitespace is left exactly alone" {
        try expectCSS(
            "div{content:\"a   b\"}",
            "div{content:\"a   b\"}",
        );
    }

    test "css: grid-template-areas matches case-insensitively" {
        try expectCSS(
            "div{GRID-TEMPLATE-AREAS:\"a   b\"}",
            "div{GRID-TEMPLATE-AREAS:\"a b\"}",
        );
    }

    test "html: collapses whitespace between tags" {
        try expectHTML("<div>\n  <p>hi</p>\n</div>", "<div><p>hi</p></div>", &.{});
    }

    test "html: comments stripped" {
        try expectHTML("<div><!-- comment -->text</div>", "<div>text</div>", &.{});
    }

    test "html: conditional comments preserved" {
        try expectHTML("<!--[if IE]><p>old</p><![endif]-->", "<!--[if IE]><p>old</p><![endif]-->", &.{});
    }

    test "html: doctype preserved" {
        try expectHTML("<!DOCTYPE html><html></html>", "<!DOCTYPE html><html></html>", &.{});
    }

    test "html: attributes preserve internal whitespace" {
        try expectHTML("<div  class=\"a   b\"   id='x'  >hi</div>", "<div class=\"a   b\" id='x'>hi</div>", &.{});
    }

    test "html: pre content untouched" {
        try expectHTML("<pre>  a\n   b  </pre>", "<pre>  a\n   b  </pre>", &.{});
    }

    test "html: style block minified" {
        try expectHTML("<style>\n  a { color: red; }\n</style>", "<style>a{color:red}</style>", &.{});
    }

    test "html: style attribute value is minified" {
        try expectHTML("<div style=\"  color:  red;  \">x</div>", "<div style=\"color:red\">x</div>", &.{});
    }

    test "html: single-quoted style attribute value is minified" {
        try expectHTML("<div style='  color:  red;  '>x</div>", "<div style='color:red'>x</div>", &.{});
    }

    test "html: unquoted style attribute value is minified and re-quoted" {
        try expectHTML("<div style=color:red>x</div>", "<div style=\"color:red\">x</div>", &.{});
    }

    test "html: empty style attribute value is left alone" {
        try expectHTML("<div style=\"\">x</div>", "<div style=\"\">x</div>", &.{});
    }

    test "html: script content is minified via js.zig" {
        try expectHTML("<script>  var x = 1;  </script>", "<script>var a=1</script>", &.{"mangle"});
    }

    test "html: script with no type attribute is treated as JS" {
        try expectHTML("<script>  var x = 1;  </script>", "<script>var a=1</script>", &.{"mangle"});
    }

    test "html: script type=text/javascript is minified" {
        try expectHTML("<script type=\"text/javascript\">  var x = 1;  </script>", "<script type=\"text/javascript\">var a=1</script>", &.{"mangle"});
    }

    test "html: script type=module is minified" {
        try expectHTML("<script type=\"module\">  var x = 1;  </script>", "<script type=\"module\">var a=1</script>", &.{"mangle"});
    }

    test "html: script type=application/json is left alone" {
        try expectHTML("<script type=\"application/json\">  { \"a\": 1 }  </script>", "<script type=\"application/json\">  { \"a\": 1 }  </script>", &.{});
    }

    test "html: script with unrecognized type is left alone" {
        try expectHTML("<script type=\"text/x-template\">  <div></div>  </script>", "<script type=\"text/x-template\">  <div></div>  </script>", &.{});
    }

    test "html: script with src attribute is left alone (no inline content used)" {
        try expectHTML("<script src=\"a.js\">  var x = 1;  </script>", "<script src=\"a.js\">  var x = 1;  </script>", &.{});
    }

    test "html: script type=\"\" is treated as JS" {
        try expectHTML("<script type=\"\">  var x = 1;  </script>", "<script type=\"\">var a=1</script>", &.{"mangle"});
    }

    test "html: onclick attribute JS is minified" {
        try expectHTML("<button onclick=\"  var x = 1;  \">Go</button>", "<button onclick=\"var a=1\">Go</button>", &.{"mangle"});
    }

    test "html: onclick is case-insensitively matched" {
        try expectHTML("<button OnClick=\"  var x = 1;  \">Go</button>", "<button OnClick=\"var a=1\">Go</button>", &.{"mangle"});
    }

    test "html: single-quoted event handler is minified" {
        try expectHTML("<button onclick='  var x = 1;  '>Go</button>", "<button onclick='var a=1'>Go</button>", &.{"mangle"});
    }

    test "html: multiple event handlers in one tag are all minified" {
        try expectHTML(
            "<input onfocus=\"  a( )  ;  \" onblur=\"  b( )  ;  \">",
            "<input onfocus=\"a()\" onblur=\"b()\">",
            &.{},
        );
    }

    test "html: non-event on-prefixed attribute is left alone" {
        try expectHTML("<div ontology=\"  a  b  \"></div>", "<div ontology=\"  a  b  \"></div>", &.{});
    }

    test "html: unquoted event handler value is minified and re-quoted" {
        try expectHTML("<button onclick=go()>Go</button>", "<button onclick=\"go()\">Go</button>", &.{});
    }

    test "html: empty event handler value is left alone" {
        try expectHTML("<button onclick=\"\">Go</button>", "<button onclick=\"\">Go</button>", &.{});
    }

    test "html: event handler entities are decoded then re-encoded" {
        try expectHTML(
            "<button onclick=\"if (a &gt; b) { c(&#39;x&#39;); }\">Go</button>",
            "<button onclick=\"if(a>b){c('x')}\">Go</button>",
            &.{},
        );
    }

    test "html: event handler with embedded double quote gets re-encoded" {
        try expectHTML(
            "<button onclick='  c(\"x\")  ;  '>Go</button>",
            "<button onclick='c(\"x\")'>Go</button>",
            &.{},
        );
    }

    test "html: event handler that would need an ampersand re-encoded" {
        try expectHTML(
            "<button onclick=\"  a = 1 &amp;&amp; b  ;  \">Go</button>",
            "<button onclick=\"a=1&amp;&amp;b\">Go</button>",
            &.{},
        );
    }

    test "html: event handler minification also applies under hypercrush" {
        try expectHTML("<button onclick=\"  var x = 1;  \">Go</button>", "<button onclick=\"var a=1\">Go</button>", &.{"mangle", "hypercrush"});
    }

    test "html: href javascript: url is minified" {
        try expectHTML(
            "<a href=\"  javascript:  var x = 1;  \">Go</a>",
            "<a href=\"javascript:var a=1\">Go</a>",
            &.{"mangle"},
        );
    }

    test "html: href javascript: scheme is case-insensitive" {
        try expectHTML(
            "<a href=\"JavaScript:  a( )  ;  \">Go</a>",
            "<a href=\"javascript:a()\">Go</a>",
            &.{},
        );
    }

    test "html: href javascript: url prefers single-quoted strings to avoid &quot;" {
        try expectHTML(
            "<a href=\"javascript:c('x')\">Go</a>",
            "<a href=\"javascript:c('x')\">Go</a>",
            &.{},
        );
    }

    test "html: unquoted event handler value is re-quoted with \" and prefers ' in its strings" {
        try expectHTML(
            "<button onclick=c('x')>Go</button>",
            "<button onclick=\"c('x')\">Go</button>",
            &.{},
        );
    }

    test "html: href without javascript: scheme is left alone" {
        try expectHTML("<a href=\"  /path  \">Go</a>", "<a href=\"  /path  \">Go</a>", &.{});
    }

    test "html: self-closing tag spacing" {
        try expectHTML("<br  />", "<br/>", &.{});
    }

    test "html: unrecognized args are ignored, not errors" {
        try expectHTML("<div></div>", "<div></div>", &.{"bogus"});
    }

    test "hypercrush: matches documented README example exactly" {
        try expectHTML(
            "<div id=\"myId\" class=\"big blue\" data-val=\"0.2\"> Some <em> \"text\" here </em> </div>",
            "<div id=myId class=\"big blue\"data-val=.2>Some <em>\"text\" here</em></div>",
            &.{"hypercrush"},
        );
    }

    test "hypercrush: whitespace-around-tags is directional, not symmetric" {
        // Verified against the real upstream implementation: only whitespace
        // immediately after an OPENING tag or immediately before a CLOSING
        // tag is dropped. Space before an opening tag, or after a closing
        // tag, is preserved either way.
        try expectHTML("a <b>x</b>", "a <b>x</b>", &.{"hypercrush"});
        try expectHTML("<b>x</b> a", "<b>x</b> a", &.{"hypercrush"});
        try expectHTML("<b> x</b>", "<b>x</b>", &.{"hypercrush"});
        try expectHTML("<b>x </b>", "<b>x</b>", &.{"hypercrush"});
        try expectHTML("<a><b>x</b> </a>", "<a><b>x</b></a>", &.{"hypercrush"});
    }

    test "hypercrush: self-close needs no space when nothing unquoted precedes it" {
        try expectHTML("<br/>", "<br/>", &.{"hypercrush"});
        try expectHTML("<br    />", "<br/>", &.{"hypercrush"});
    }

    test "hypercrush: unquotes safe attribute values" {
        try expectHTML("<div class=\"foo\">hi</div>", "<div class=foo>hi</div>", &.{"hypercrush"});
    }

    test "hypercrush: keeps quotes when value has whitespace" {
        try expectHTML("<div class=\"foo bar\">hi</div>", "<div class=\"foo bar\">hi</div>", &.{"hypercrush"});
    }

    test "hypercrush: unquotes safely even before self-close" {
        try expectHTML("<input value=\"foo\" />", "<input value=foo />", &.{"hypercrush"});
    }

    test "hypercrush: strips leading zero in decimal attr values" {
        try expectHTML("<div data-x=\"0.5\">hi</div>", "<div data-x=.5>hi</div>", &.{"hypercrush"});
        try expectHTML("<div data-x=\"-0.5\">hi</div>", "<div data-x=-.5>hi</div>", &.{"hypercrush"});
    }

    test "hypercrush: does not strip zero from non-decimal-only values" {
        try expectHTML("<a href=\"page-0.5.html\">x</a>", "<a href=page-0.5.html>x</a>", &.{"hypercrush"});
    }

    test "hypercrush: space dropped after any closing quote, even before a boolean attribute" {
        // A literal closing quote is an unambiguous attribute boundary per the
        // HTML tokenizer spec, verified against a real parser (jsdom) - this
        // is a real optimization the upstream JS regex misses.
        try expectHTML("<input value=\"a b\" disabled>", "<input value=\"a b\"disabled>", &.{"hypercrush"});
    }

    test "hypercrush: space dropped after quoted value before next quoted attribute" {
        try expectHTML(
            "<div class=\"a b\" data-x=\"foo bar\">",
            "<div class=\"a b\"data-x=\"foo bar\">",
            &.{"hypercrush"},
        );
    }

    test "hypercrush: space kept when previous value was unquoted" {
        try expectHTML("<div a=\"1\" class=\"a b\">", "<div a=1 class=\"a b\">", &.{"hypercrush"});
    }

    test "hypercrush: two boolean attributes stay separated" {
        try expectHTML("<div checked selected>", "<div checked selected>", &.{"hypercrush"});
    }

    test "html: embedded svg is minified at its max strip level" {
        try expectHTML(
            "<svg version=\"1.1\" baseProfile=\"full\" id=\"foo\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" viewBox=\"0 0 10 10\"></svg>",
            "<svg viewBox=\"0 0 10 10\"/>",
            &.{"svgDefault"},
        );
    }

    test "html: embedded svg strips an unreferenced id from descendant elements too" {
        try expectHTML(
            "<svg viewBox=\"0 0 10 10\"><path id=\"p1\" d=\"M0 0\"/></svg>",
            "<svg viewBox=\"0 0 10 10\"><path d=\"M0 0\"/></svg>",
            &.{"svgDefault"},
        );
    }

    test "html: embedded svg keeps an id that's actually referenced" {
        // "g1" must survive id-stripping since it's still referenced by
        // the rect's fill.
        try expectHTML(
            "<svg viewBox=\"0 0 10 10\"><defs><linearGradient id=\"g1\"></linearGradient></defs><rect fill=\"url(#g1)\"/></svg>",
            "<svg viewBox=\"0 0 10 10\"><defs><linearGradient id=g1 /></defs><rect fill=url(#g1) /></svg>",
            &.{"svgDefault"},
        );
    }

    test "html: non-svg elements keep their id, but still get default squeeze" {
        try expectHTML("<div id=\"keep\">hi</div>", "<div id=keep>hi</div>", &.{"hypercrush"});
    }

    test "html: hypercrush and embedded svg minification both apply in one call" {
        try expectHTML(
            "<div id=\"x\"><svg id=\"root\"><path id=\"p\" d=\"M0 0\"/></svg></div>",
            "<div id=x><svg><path d=\"M0 0\"/></svg></div>",
            &.{ "hypercrush", "svgDefault" },
        );
    }

    test "html: embedded svg is minified even without hypercrush" {
        try expectHTML(
            "<svg id=\"root\"><path id=\"p\" d=\"M0 0\"/></svg>",
            "<svg><path d=\"M0 0\"/></svg>",
            &.{"svgDefault"},
        );
    }

    test "html: embedded svg's on* event-handler attribute is minified via SVG's JS delegation" {
        try expectHTML(
            "<svg><rect onclick=\"  var x = 1;  \"/></svg>",
            "<svg><rect onclick=\"var a=1\"/></svg>",
            &.{"mangle"},
        );
    }

    test "html: a top-level name shared across two <script> tags keeps its spelling in both" {
        // `counter` is declared in the first script and read in the
        // second - mangling it in one place without the other would
        // break the page. Neither `counter` occurrence may be renamed.
        try expectHTML(
            "<script>var counter=1;</script><script>counter=counter+1;</script>",
            "<script>var counter=1</script><script>counter=counter+1</script>",
            &.{},
        );
    }

    test "html: a top-level name private to one <script> tag still gets mangled" {
        // `onlyHere` isn't referenced anywhere else on the page, so
        // there's nothing it could break by being renamed - this is
        // the actual improvement over disabling top-level mangling
        // everywhere: scripts that don't share names still shrink.
        try expectHTML(
            "<script>var onlyHere=1;</script><script>var alsoAlone=2;</script>",
            "<script>var a=1</script><script>var a=2</script>",
            &.{"mangle"},
        );
    }

    test "html: a name declared in <script> and used from an on*= handler keeps its spelling" {
        try expectHTML(
            "<script>function handleClick(){return 1;}</script><button onclick=\"handleClick()\">Go</button>",
            "<script>function handleClick(){return 1}</script><button onclick=\"handleClick()\">Go</button>",
            &.{},
        );
    }

    test "css: raw svg inside url() is minified" {
        try expectHTML(
            "<style>a{background:url('<svg>  <path   d=\"M0 0\"/>  </svg>')}</style>",
            "<style>a{background:url('<svg><path d=\"M0 0\"/></svg>')}</style>",
            &.{},
        );
    }

    test "css: raw svg with escaped quotes inside a double-quoted url() string" {
        try expectHTML(
            "<style>a{background:url(\"<svg>  <path   d=\\\"M0 0\\\"/>  </svg>\")}</style>",
            "<style>a{background:url(\"<svg><path d=\\\"M0 0\\\"/></svg>\")}</style>",
            &.{},
        );
    }

    test "css: base64 svg data uri inside url() is minified" {
        // base64 of: <svg>  <path   d="M0 0"/>  </svg>
        try expectHTML(
            "<style>a{background:url(\"data:image/svg+xml;base64,PHN2Zz4gIDxwYXRoICAgZD0iTTAgMCIvPiAgPC9zdmc+\")}</style>",
            "<style>a{background:url(\"data:image/svg+xml;base64,PHN2Zz48cGF0aCBkPSJNMCAwIi8+PC9zdmc+\")}</style>",
            &.{},
        );
    }

    test "css: non-svg url() is left untouched" {
        try expectHTML(
            "<style>a{background:url(\"images/foo.png\")}</style>",
            "<style>a{background:url(\"images/foo.png\")}</style>",
            &.{},
        );
    }

    test "css: malformed base64 svg data uri falls back to verbatim" {
        try expectHTML(
            "<style>a{background:url(\"data:image/svg+xml;base64,not-valid-base64!!!\")}</style>",
            "<style>a{background:url(\"data:image/svg+xml;base64,not-valid-base64!!!\")}</style>",
            &.{},
        );
    }

    test "css: unquoted base64 svg data uri inside url() is minified" {
        // base64 of: <svg>  <path   d="M0 0"/>  </svg>
        try expectHTML(
            "<style>a{background:url(data:image/svg+xml;base64,PHN2Zz4gIDxwYXRoICAgZD0iTTAgMCIvPiAgPC9zdmc+)}</style>",
            "<style>a{background:url(data:image/svg+xml;base64,PHN2Zz48cGF0aCBkPSJNMCAwIi8+PC9zdmc+)}</style>",
            &.{},
        );
    }

    test "css: unquoted base64 svg data uri tolerates surrounding whitespace" {
        try expectHTML(
            "<style>a{background:url(  data:image/svg+xml;base64,PHN2Zz4gIDxwYXRoICAgZD0iTTAgMCIvPiAgPC9zdmc+  )}</style>",
            "<style>a{background:url(data:image/svg+xml;base64,PHN2Zz48cGF0aCBkPSJNMCAwIi8+PC9zdmc+)}</style>",
            &.{},
        );
    }

    test "css: unquoted non-svg url() is left untouched" {
        try expectHTML(
            "<style>a{background:url(images/foo.png)}</style>",
            "<style>a{background:url(images/foo.png)}</style>",
            &.{},
        );
    }

    test "css: unquoted malformed base64 svg data uri falls back to verbatim" {
        try expectHTML(
            "<style>a{background:url(data:image/svg+xml;base64,not-valid-base64!!!)}</style>",
            "<style>a{background:url(data:image/svg+xml;base64,not-valid-base64!!!)}</style>",
            &.{},
        );
    }

    test "css: unquoted url() with a fragment identifier is left untouched" {
        try expectCSS("a{background:url(icon.svg#aabbcc)}", "a{background:url(icon.svg#aabbcc)}");
    }

    test "css: nesting with & compound selector" {
        try expectCSS(
            \\.card {
            \\  color: red;
            \\  & .title {
            \\    font-weight: bold;
            \\  }
            \\}
        ,
            ".card{color:red;& .title{font-weight:bold}}",
        );
    }

    test "css: nesting with & pseudo-class, no separating space" {
        try expectCSS(
            \\.btn {
            \\  &:hover {
            \\    color: blue;
            \\  }
            \\  &.active {
            \\    color: green;
            \\  }
            \\}
        ,
            ".btn{&:hover{color:blue} &.active{color:green}}",
        );
    }

    test "css: nesting three levels deep" {
        try expectCSS(
            \\.a {
            \\  & .b {
            \\    & .c {
            \\      color: red;
            \\    }
            \\  }
            \\}
        ,
            ".a{& .b{& .c{color:red}}}",
        );
    }

    test "css: nesting combined with @media" {
        try expectCSS(
            \\.a {
            \\  color: red;
            \\  @media (min-width: 600px) {
            \\    & .b {
            \\      color: blue;
            \\    }
            \\  }
            \\}
        ,
            ".a{color:red;@media(min-width:600px){& .b{color:blue}}}",
        );
    }

    test "css: nesting with multiple & in one selector" {
        try expectCSS(
            \\.a {
            \\  & > & {
            \\    color: red;
            \\  }
            \\}
        ,
            ".a{&>&{color:red}}",
        );
    }
};

const js_tokenizer_tests = struct {
    const testing = std.testing;
    const tok = @import("js_parser.zig");
    const JsTokenizer = tok.JsTokenizer;
    const JsTokenType = tok.JsTokenType;

    fn expectTags(source: []const u8, expected: []const JsTokenType) !void {
        var t = JsTokenizer.init(source);
        for (expected) |exp| {
            const got = t.next();
            try testing.expectEqual(exp, got.tag);
        }
    }

    fn tokenText(source: []const u8, index: usize) []const u8 {
        var t = JsTokenizer.init(source);
        var i: usize = 0;
        while (true) : (i += 1) {
            const got = t.next();
            if (i == index) return source[got.loc.start..got.loc.end];
            if (got.tag == .eof) return "";
        }
    }

    test "tokenizer: basic statement" {
        try expectTags(
            "const x = 42;",
            &[_]JsTokenType{ .identifier, .identifier, .assign, .number, .semicolon, .eof },
        );
    }

    test "tokenizer: division vs regex after identifier" {
        try expectTags("a / b", &[_]JsTokenType{ .identifier, .slash, .identifier, .eof });
    }

    test "tokenizer: regex after return" {
        try expectTags("return /abc/g;", &[_]JsTokenType{ .identifier, .regex, .semicolon, .eof });
    }

    test "tokenizer: regex after assign" {
        try expectTags("x = /abc/;", &[_]JsTokenType{ .identifier, .assign, .regex, .semicolon, .eof });
    }

    test "tokenizer: division after paren close" {
        try expectTags("(a) / b", &[_]JsTokenType{ .l_paren, .identifier, .r_paren, .slash, .identifier, .eof });
    }

    test "tokenizer: division after number" {
        try expectTags("6 / 2", &[_]JsTokenType{ .number, .slash, .number, .eof });
    }

    test "tokenizer: regex with escaped slash and char class" {
        try expectTags("/a\\/[b/]c/gi", &[_]JsTokenType{ .regex, .eof });
    }

    test "tokenizer: line comment skipped" {
        try expectTags("a // comment\nb", &[_]JsTokenType{ .identifier, .identifier, .eof });
    }

    test "tokenizer: block comment skipped, minimal form" {
        try expectTags("a/**/b", &[_]JsTokenType{ .identifier, .identifier, .eof });
    }

    test "tokenizer: block comment with asterisks inside" {
        try expectTags("a /* * ** *x* */ b", &[_]JsTokenType{ .identifier, .identifier, .eof });
    }

    test "tokenizer: string with escaped quote" {
        try expectTags("'a\\'b'", &[_]JsTokenType{ .string, .eof });
        try testing.expectEqualStrings("'a\\'b'", tokenText("'a\\'b'", 0));
    }

    test "tokenizer: template literal with interpolation" {
        try expectTags("`a${b}c`", &[_]JsTokenType{ .template, .eof });
        try testing.expectEqualStrings("`a${b}c`", tokenText("`a${b}c`", 0));
    }

    test "tokenizer: nested template interpolation braces" {
        try expectTags("`a${ {x:1} }b`", &[_]JsTokenType{ .template, .eof });
    }

    test "tokenizer: number forms" {
        try expectTags("1.5", &[_]JsTokenType{ .number, .eof });
        try expectTags("0x1F", &[_]JsTokenType{ .number, .eof });
        try expectTags("1e10", &[_]JsTokenType{ .number, .eof });
        try expectTags("1e+10", &[_]JsTokenType{ .number, .eof });
        try expectTags("10n", &[_]JsTokenType{ .number, .eof });
        try expectTags("1_000", &[_]JsTokenType{ .number, .eof });
    }

    test "tokenizer: number then property access" {
        try expectTags("1.5.toString()", &[_]JsTokenType{ .number, .dot, .identifier, .l_paren, .r_paren, .eof });
    }

    test "tokenizer: double dot number then property access" {
        try expectTags("1..toString()", &[_]JsTokenType{ .number, .dot, .identifier, .l_paren, .r_paren, .eof });
    }

    test "tokenizer: spread operator" {
        try expectTags("f(...args)", &[_]JsTokenType{ .identifier, .l_paren, .other_punct, .identifier, .r_paren, .eof });
    }

    test "tokenizer: multi-char operators tokenize as single tokens" {
        try expectTags("a === b", &[_]JsTokenType{ .identifier, .other_punct, .identifier, .eof });
        try expectTags("a ?? b", &[_]JsTokenType{ .identifier, .other_punct, .identifier, .eof });
        try expectTags("a ??= b", &[_]JsTokenType{ .identifier, .other_punct, .identifier, .eof });
        try expectTags("a => b", &[_]JsTokenType{ .identifier, .other_punct, .identifier, .eof });
        try expectTags("a >>> b", &[_]JsTokenType{ .identifier, .other_punct, .identifier, .eof });
        try expectTags("a >>>= b", &[_]JsTokenType{ .identifier, .other_punct, .identifier, .eof });
    }

    test "tokenizer: increment vs plus plus" {
        try expectTags("a++ +b", &[_]JsTokenType{ .identifier, .other_punct, .plus, .identifier, .eof });
    }

    test "tokenizer: newline_before flag set across line comment" {
        var t = JsTokenizer.init("a\nb");
        const first = t.next();
        try testing.expect(!first.newline_before);
        const second = t.next();
        try testing.expect(second.newline_before);
    }

    test "tokenizer: newline_before flag through block comment spanning lines" {
        var t = JsTokenizer.init("a /* \n */ b");
        _ = t.next();
        const second = t.next();
        try testing.expect(second.newline_before);
    }

    test "tokenizer: unterminated regex-looking slash falls back to division" {
        // A '/' that never finds a closing '/' before a newline is not a regex.
        try expectTags("a / \n b", &[_]JsTokenType{ .identifier, .slash, .identifier, .eof });
    }

    test "tokenizer: reserved words table rejects every ES keyword" {
        const words = [_][]const u8{
            "break", "case", "catch", "class", "const", "continue", "debugger",
            "default", "delete", "do", "else", "export", "extends", "false",
            "finally", "for", "function", "if", "import", "in", "instanceof",
            "new", "null", "return", "super", "switch", "this", "throw",
            "true", "try", "typeof", "var", "void", "while", "with",
            "let", "static", "yield", "arguments", "eval",
            "await",
            "enum",
            "implements", "interface", "package", "private", "protected", "public",
            "abstract", "boolean", "byte", "char", "double", "final", "float",
            "goto", "int", "long", "native", "short", "synchronized", "throws",
            "transient", "volatile",
        };
        for (words) |w| {
            try testing.expect(tok.jsIsReservedWord(w));
        }
    }

    test "tokenizer: reserved words table accepts ordinary identifiers" {
        const words = [_][]const u8{
            "x", "foo", "bar123", "_private", "$el", "myVariable",
        };
        for (words) |w| {
            try testing.expect(!tok.jsIsReservedWord(w));
        }
    }

    test "tokenizer: reserved words table accepts special-meaning-but-not-reserved identifiers" {
        // MDN explicitly lists these as never reserved - they must stay
        // available for the mangler to hand out or reuse freely.
        const words = [_][]const u8{ "async", "as", "from", "get", "of", "set" };
        for (words) |w| {
            try testing.expect(!tok.jsIsReservedWord(w));
        }
    }

    test "tokenizer: reserved word matching is case-sensitive and exact" {
        try testing.expect(!tok.jsIsReservedWord("Var"));
        try testing.expect(!tok.jsIsReservedWord("VAR"));
        try testing.expect(!tok.jsIsReservedWord("variable"));
        try testing.expect(!tok.jsIsReservedWord("va"));
        try testing.expect(tok.jsIsReservedWord("var"));
    }
};

const js_tests = struct {
    const testing = std.testing;
    const js = @import("js.zig").js;

    // Disable mangling so tests assert exact whitespace/comment stripping.
    const stripOnlyArgs = "{\"js\":{\"mangle\":{\"enabled\":false}}}";

    fn expectJS(input: []const u8, expected: []const u8) !void {
        const out = try js(testing.allocator, input, stripOnlyArgs);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(expected, out);
    }

    fn expectMangled(input: []const u8, args: []const []const u8, expected: []const u8) !void {
        var jsonArgs: ?[]const u8 = null;
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "mangle")) {
                jsonArgs = "{\"js\":{\"mangle\":{\"enabled\":true}}}";
            } else if (std.mem.eql(u8, arg, "mangle:{\"top\":false}")) {
                jsonArgs = "{\"js\":{\"mangle\":{\"enabled\":true,\"top\":false}}}";
            } else if (std.mem.eql(u8, arg, "mangle:{\"top\":false,\"reserved\":[\"a\"]}")) {
                jsonArgs = "{\"js\":{\"mangle\":{\"enabled\":true,\"top\":false,\"reserved\":[\"a\"]}}}";
            }
        }
        const out = try js(testing.allocator, input, jsonArgs);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(expected, out);
    }

    test "js: strips line comments" {
        try expectJS("const x = 1; // comment\nconst y = 2;", "const x=1;const y=2");
    }

    test "js: strips block comments" {
        try expectJS("const x = /* comment */ 1;", "const x=1");
    }

    test "js: collapses whitespace and indentation" {
        try expectJS("function f(  ) {\n    return   1;\n}", "function f(){return 1}");
    }

    test "js: keeps required space between identifiers/keywords" {
        try expectJS("typeof x", "typeof x");
        try expectJS("return x", "return x");
        try expectJS("var x", "var x");
    }

    test "js: no space needed around most punctuation" {
        try expectJS("a = b + c;", "a=b+c");
        try expectJS("if (a) { b(); }", "if(a){b()}");
    }

    test "js: preserves ++/-- boundary against following +/-" {
        try expectJS("a+ +b", "a+ +b");
        try expectJS("a - -b", "a- -b");
        try expectJS("a+b", "a+b");
        try expectJS("a+ ++b", "a+ ++b");
        try expectJS("a++ +b", "a++ +b");
    }

    test "js: double negation needs no separating space" {
        try expectJS("!!x", "!!x");
        try expectJS("!!!x", "!!!x");
    }

    test "js: adjacent punctuation only separated when it could re-lex as a real operator" {
        // '<' then '!' can't combine into any real operator - no space needed.
        try expectJS("a < !b", "a<!b");
    }

    test "js: preserves string contents exactly (quote character aside)" {
        // Content (spacing, letters, escapes other than the quote
        // itself) is untouched; only the delimiter and its escaping
        // change - see the quote-normalization tests below.
        try expectJS("const s = 'a  b\\'c';", "const s=\"a  b'c\"");
    }

    test "js: preserves regex literal exactly" {
        try expectJS("const r = /a b\\/c/gi;", "const r=/a b\\/c/gi");
    }

    test "js: division not mistaken for regex" {
        try expectJS("const x = a / b / c;", "const x=a/b/c");
    }

    test "js: regex allowed after return, and stays separated from the keyword" {
        try expectJS("return /abc/.test(x);", "return /abc/.test(x)");
    }

    test "js: template literal reprinted with its embedded expression minified" {
        try expectJS("const s = `a ${  b + c  } d`;", "const s=`a ${b+c} d`");
    }

    test "js: tagged template literal" {
        try expectJS("tag`a ${  b + c  } d`;", "tag`a ${b+c} d`");
    }

    test "js: tagged template on a member chain" {
        try expectJS("styled . div`color: ${c};`;", "styled.div`color: ${c};`");
    }

    test "js: tagged template does not fall back to strip" {
        try expectJS("const x = 1; tag`hi ${x}`;", "const x=1;tag`hi ${x}`");
    }

    test "js: a call continuing on the next line is not split by ASI" {
        // No semicolon in the source; `(c)` continues the call chain
        // regardless of the newline, so this is one statement, not two.
        try expectJS("a = b\n(c).d()", "a=b(c).d()");
    }

    test "js: a computed-member continuing on the next line is not split by ASI" {
        try expectJS("a = b\n[0] = 1", "a=b[0]=1");
    }

    test "js: prefix increment on the next line is its own statement" {
        // Postfix ++ requires no line break before it, so `b` can't
        // absorb the `++` here - ASI ends the first statement at `b`,
        // giving two expr_stmts that then join via the comma operator.
        try expectJS("a = b\n++c", "a=b,++c");
    }

    test "js: a binary operator on the next line still continues the expression" {
        // Unlike ++/--, a binary operator has no newline restriction, so
        // this parses as one statement: `a = b - c`.
        try expectJS("a = b\n-c", "a=b-c");
    }

    test "js: return with a newline before the value never captures it" {
        try expectJS("function f() {\nreturn\n{a:1};\n}", "function f(){return;{a:1}}");
    }

    test "js: break/continue/throw/yield never capture a value across a newline" {
        try expectJS("while(1){\nbreak\n}", "while(1){break}");
        // `yield` and `1` are separate expr_stmts after ASI, which
        // then join via the comma operator.
        try expectJS("function*g(){\nyield\n1;\n}", "function*g(){yield,1}");
    }

    test "js: adjacent statements on separate lines are still two statements after ASI" {
        // Renamed intent: ASI still splits these into two statements;
        // the join pass then combines them with the comma operator.
        try expectJS("a = 1\nb = 2", "a=1,b=2");
    }

    test "js: multi-char operators preserved as single tokens" {
        try expectJS("a === b", "a===b");
        try expectJS("a ?? b", "a??b");
        try expectJS("a => a + 1", "a=>a+1");
    }

    test "js: spread operator preserved" {
        try expectJS("f(...args)", "f(...args)");
    }

    test "js: numeric literal forms preserved" {
        try expectJS("const a = 0x1F;", "const a=0x1F");
        try expectJS("const a = 10n;", "const a=10n");
    }

    test "js: numeric separators are stripped as dead weight" {
        try expectJS("const a = 1_000;", "const a=1e3");
        try expectJS("const a = 1_234;", "const a=1234");
    }

    test "js: number literal shortened to the shortest equivalent form" {
        try expectJS("const a = 1000;", "const a=1e3");
        try expectJS("const a = 100000;", "const a=1e5");
        try expectJS("const a = 0.5;", "const a=.5");
        try expectJS("const a = 1.50;", "const a=1.5");
        try expectJS("const a = 1.0;", "const a=1");
        try expectJS("const a = 0.0;", "const a=0");
        try expectJS("const a = 1.5e3;", "const a=1500");
        try expectJS("const a = 123;", "const a=123");
        try expectJS("const a = 100;", "const a=100");
        try expectJS("const a = 0.001;", "const a=.001");
        try expectJS("const a = 0.0001;", "const a=1e-4");
    }

    test "js: shortened number literal stays correctly separated from adjacent tokens" {
        // A leading-dot literal directly after a member `.` would
        // otherwise misread as `a..5` - the shared dangerous-pair
        // logic must still keep these apart.
        try expectJS("const a = x.constructor(0.5);", "const a=x.constructor(.5)");
        // A number immediately followed by a member access needs a
        // space so `1.toFixed` isn't misread as `1.` then `toFixed`.
        try expectJS("(1000).toFixed(2);", "(1e3).toFixed(2)");
    }

    test "js: computed member access unquoted when safe" {
        try expectJS("f(a[\"bar\"]);", "f(a.bar)");
        try expectJS("f(a['bar']);", "f(a.bar)");
        try expectJS("f(a[\"bar\"][\"baz\"]);", "f(a.bar.baz)");
    }

    test "js: computed member access left alone when unsafe" {
        // Not a valid bare identifier.
        try expectJS("f(a[\"1bar\"]);", "f(a[\"1bar\"])");
        try expectJS("f(a[\"bar baz\"]);", "f(a[\"bar baz\"])");
        // A reserved word - left as bracket notation for simplicity.
        try expectJS("f(a[\"class\"]);", "f(a[\"class\"])");
        // Contains an escape - not decoded, left alone.
        try expectJS("f(a[\"\\x62ar\"]);", "f(a[\"\\x62ar\"])");
        // Optional chaining must keep bracket form.
        try expectJS("f(a?.[\"bar\"]);", "f(a?.[\"bar\"])");
        // A digit immediately before `.` would re-lex as a number.
        try expectJS("f(1[\"toString\"]);", "f(1[\"toString\"])");
    }

    test "js: computed object key unquoted when safe" {
        try expectJS("const o = {[\"bar\"]: 1};", "const o={bar:1}");
        // A reserved word isn't unquoted, but the brackets are still
        // droppable - a literal key never needs them, unlike a real
        // computed member expression.
        try expectJS("const o = {[\"class\"]: 1};", "const o={\"class\":1}");
    }

    test "js: undefined/Infinity shortened to void 0/1/0" {
        try expectJS("f(undefined);", "f(void 0)");
        try expectJS("f(Infinity);", "f(1/0)");
        try expectJS("const a = undefined;", "const a=void 0");
        try expectJS("const a = -Infinity;", "const a=-1/0");
    }

    test "js: undefined/Infinity left alone when shadowed by a local binding" {
        try expectJS("function f(undefined){return undefined;}", "function f(undefined){return undefined}");
        try expectJS("function f(Infinity){return Infinity;}", "function f(Infinity){return Infinity}");
    }

    test "js: undefined/Infinity substitution parenthesized as a member/call base" {
        try expectJS("undefined.toString();", "(void 0).toString()");
        try expectJS("Infinity.toString();", "(1/0).toString()");
        try expectJS("undefined[0];", "(void 0)[0]");
        try expectJS("undefined();", "(void 0)()");
        try expectJS("new undefined();", "new(void 0)()");
        try expectJS("undefined`x`;", "(void 0)`x`");
    }

    test "js: undefined/Infinity left as plain identifier in assignment-target position" {
        try expectJS("undefined = 5;", "undefined=5");
        try expectJS("Infinity++;", "Infinity++");
        try expectJS("for (undefined in x) {}", "for(undefined in x){}");
    }

    test "js: debugger statement removed" {
        try expectJS("debugger;", "");
        try expectJS("a();debugger;b();", "a();b()");
        try expectJS("function f(){debugger;return 1;}", "function f(){return 1}");
    }

    test "js: debugger statement as a lone block body still trims cleanly" {
        try expectJS("function f(){debugger;}", "function f(){}");
    }

    test "js: debugger statement as a solo branch/loop body keeps a placeholder" {
        // Not droppable here - it's the only body `if`/`for` has, same
        // as an explicit empty statement in the same position.
        try expectJS("if(a)debugger;", "if(a);");
        try expectJS("for(;;)debugger;", "for(;;);");
        try expectJS("while(a)debugger;", "while(a);");
        try expectJS("do debugger;while(a);", "do;while(a)");
        try expectJS("l:debugger;", "l:;");
        try expectJS("if(a)debugger;else debugger;", "if(a);else;");
    }

    test "js: true/false shortened to !0/!1" {
        try expectJS("const a = true;", "const a=!0");
        try expectJS("const a = false;", "const a=!1");
        try expectJS("f(true, false);", "f(!0,!1)");
        try expectJS("const a = true === b;", "const a=!0===b");
    }

    test "js: true/false shortened to bare 1/0 under loose equality only" {
        try expectJS("const a = x == true;", "const a=x==1");
        try expectJS("const a = x != false;", "const a=x!=0");
        try expectJS("const a = true == x;", "const a=1==x");
        // Strict equality must keep the boolean form - x===1 is not
        // the same check as x===true for every x.
        try expectJS("const a = x === true;", "const a=x===!0");
        try expectJS("const a = x !== false;", "const a=x!==!1");
    }

    test "js: typeof x === \"undefined\" shortened to x === void 0" {
        try expectJS("let a; if (typeof a === \"undefined\") {}", "let a;if(a===void 0){}");
        try expectJS("let a; if (typeof a !== \"undefined\") {}", "let a;if(a!==void 0){}");
        try expectJS("let a; if (typeof a == \"undefined\") {}", "let a;if(a==void 0){}");
        try expectJS("let a; if (typeof a != \"undefined\") {}", "let a;if(a!=void 0){}");
        // Operand order reversed.
        try expectJS("let a; if (\"undefined\" === typeof a) {}", "let a;if(void 0===a){}");
    }

    test "js: typeof undefined check left alone for an unresolved/global identifier" {
        // `a` here is never declared anywhere in this snippet - a
        // genuine global (or a typo). `typeof a` is safe on that; the
        // rewritten `a===void 0` would throw ReferenceError instead.
        try expectJS("if (typeof a === \"undefined\") {}", "if(typeof a===\"undefined\"){}");
    }

    test "js: typeof undefined check left alone for a non-identifier operand" {
        try expectJS("function f(o){return typeof o.x === \"undefined\";}", "function f(o){return typeof o.x===\"undefined\"}");
    }

    test "js: typeof undefined check left alone when compared to something other than the string undefined" {
        try expectJS("function f(a){return typeof a === \"number\";}", "function f(a){return typeof a===\"number\"}");
        try expectJS("function f(a){return typeof a === b;}", "function f(a){return typeof a===b}");
    }

    test "js: empty input" {
        try expectJS("", "");
    }

    test "js: comment-only input" {
        try expectJS("// just a comment", "");
    }

    test "mangle: no args behaves as mangle-on by default" {
        try expectMangled("function f(x) { return x + 1; }", &.{}, "function a(b){return b+1}");
    }

    test "mangle: local function parameter renamed to shortest name" {
        // top:false isolates the parameter rename from f's own name
        // also being mangled (which would otherwise claim "a" first and
        // push the parameter to "b" - see the dedicated top-level test
        // below for that interaction).
        try expectMangled(
            "function f(longName) { return longName + 1; }",
            &.{"mangle:{\"top\":false}"},
            "function f(a){return a+1}",
        );
    }

    test "mangle: block-scoped let renamed and every reference follows" {
        try expectMangled(
            "function f(){ let count = 0; count = count + 1; return count; }",
            &.{"mangle:{\"top\":false}"},
            "function f(){let a=0;a=a+1;return a}",
        );
    }

    test "mangle: unresolved global identifier left untouched" {
        try expectMangled(
            "function f(){ return window.location; }",
            &.{"mangle:{\"top\":false}"},
            "function f(){return window.location}",
        );
    }

    test "mangle: property names never renamed" {
        try expectMangled(
            "function f(obj){ return obj.value; }",
            &.{"mangle:{\"top\":false}"},
            "function f(a){return a.value}",
        );
    }

    test "mangle: top:false leaves top-level names alone but still mangles nested locals" {
        try expectMangled(
            "function outerName(){ let innerName = 1; return innerName; }",
            &.{"mangle:{\"top\":false}"},
            "function outerName(){let a=1;return a}",
        );
    }

    test "mangle: reserved list excludes a name from the short-name pool" {
        // With "a" reserved, the single parameter must skip straight to "b".
        try expectMangled(
            "function f(x) { return x; }",
            &.{"mangle:{\"top\":false,\"reserved\":[\"a\"]}"},
            "function f(b){return b}",
        );
    }

    test "mangle: sibling scopes reuse the same short names" {
        // top:false so f/g's own top-level names are untouched and
        // the test isolates just the parameter-renaming behavior.
        try expectMangled(
            "function f(longOne){ return longOne; } function g(otherOne){ return otherOne; }",
            &.{"mangle:{\"top\":false}"},
            "function f(a){return a}function g(a){return a}",
        );
    }

    test "mangle: with statement disables mangling only inside itself" {
        try expectMangled(
            "with (obj) { longName = 1; } function f(longName) { return longName; }",
            &.{"mangle"},
            "with(obj){longName=1}function a(b){return b}",
        );
    }

    test "mangle: name referenced from inside with is protected even if declared outside" {
        try expectMangled(
            "function f() { let longName = 1; with (obj) { longName = 2; } return longName; }",
            &.{"mangle"},
            "function a(){let longName=1;with(obj){longName=2}return longName}",
        );
    }

    test "mangle: malformed JSON in mangle arg falls back to defaults (mangle on)" {
        try expectMangled(
            "function f(longName) { return longName; }",
            &.{"mangle:{not valid json"},
            "function a(b){return b}",
        );
    }

    test "mangle: bare mangle with no JSON suffix uses default options" {
        try expectMangled("function outerName(){ return 1; }", &.{"mangle"}, "function a(){return 1}");
    }

    test "mangle: generated short name never collides with an unresolved global" {
        // "a" is referenced as a bare global (never declared anywhere in
        // this file) - the mangled parameter must skip past it and land
        // on "b" instead, even though nothing in `f`'s own scope chain
        // declares anything called "a".
        try expectMangled(
            "function f(longName) { return a + longName; }",
            &.{"mangle:{\"top\":false}"},
            "function f(b){return a+b}",
        );
    }

    test "mangle: most-referenced local gets the shortest name, not declaration order" {
        try expectMangled(
            "function f(){ var rare; var common; return common+common+common; }",
            &.{"mangle:{\"top\":false}"},
            "function f(){var b;var a;return a+a+a}",
        );
    }

    test "mangle: flat object destructuring keeps the property key and renames only the binding" {
        // longName/longTwo here are simultaneously the object's real
        // property names (must stay literal - renaming them would read a
        // different property) and the new local bindings (safe to
        // rename), so only the binding side changes, in the explicit
        // `key:binding` form.
        try expectMangled(
            "function f(obj){ const {longOne, longTwo} = obj; return longOne + longTwo; }",
            &.{"mangle:{\"top\":false}"},
            "function f(a){const{longOne:b,longTwo:c}=a;return b+c}",
        );
    }

    test "mangle: flat array destructuring names get mangled" {
        try expectMangled(
            "function f(arr){ const [longOne, longTwo] = arr; return longOne + longTwo; }",
            &.{"mangle:{\"top\":false}"},
            "function f(a){const[b,c]=a;return b+c}",
        );
    }

    test "mangle: nested destructuring pattern is mangled the same as any other binding" {
        try expectMangled(
            "function f(obj){ const {a: {longName}} = obj; return longName; }",
            &.{"mangle:{\"top\":false}"},
            "function f(a){const{a:{longName:b}}=a;return b}",
        );
    }

    const tok = @import("js_parser.zig");

    fn tagSequence(allocator: std.mem.Allocator, source: []const u8) ![]tok.JsTokenType {
        // Statement-terminating semicolons are optional before `}` or
        // eof (ASI): the minifier legitimately drops them, so raw
        // tokens are collected first and such semicolons filtered out
        // afterward, rather than compared as significant tokens.
        var raw: std.ArrayList(tok.JsTokenType) = .empty;
        defer raw.deinit(allocator);
        var t = tok.JsTokenizer.init(source);
        while (true) {
            const got = t.next();
            try raw.append(allocator, got.tag);
            if (got.tag == .eof) break;
        }

        var tags: std.ArrayList(tok.JsTokenType) = .empty;
        errdefer tags.deinit(allocator);
        for (raw.items, 0..) |tag, idx| {
            if (tag == .semicolon and idx + 1 < raw.items.len) {
                const next = raw.items[idx + 1];
                if (next == .r_brace or next == .eof) continue;
            }
            try tags.append(allocator, tag);
        }
        return tags.toOwnedSlice(allocator);
    }

    fn expectRoundTripTagsMatch(input: []const u8) !void {
        const minified = try js(testing.allocator, input, stripOnlyArgs);
        defer testing.allocator.free(minified);

        const originalTags = try tagSequence(testing.allocator, input);
        defer testing.allocator.free(originalTags);
        const minifiedTags = try tagSequence(testing.allocator, minified);
        defer testing.allocator.free(minifiedTags);

        try testing.expectEqualSlices(tok.JsTokenType, originalTags, minifiedTags);
    }

    test "round-trip: minified output re-tokenizes to the same tag sequence as the input" {
        try expectRoundTripTagsMatch(
            \\function f(a, b) {
            \\  // sum two numbers
            \\  const sum = a + b;
            \\  return sum;
            \\}
        );
    }

    test "round-trip: regex/division disambiguation survives minification" {
        try expectRoundTripTagsMatch("function f(x) { return x / 2; } return /abc/g;");
    }

    test "round-trip: template literals and destructuring survive minification" {
        try expectRoundTripTagsMatch(
            "const {a, b} = obj; const s = `${a}-${b}`; const [x, y] = arr;",
        );
    }

    test "round-trip: minifying twice is idempotent on the tag sequence" {
        const once = try js(testing.allocator, "function f( a , b ) { return a+b ; }", stripOnlyArgs);
        defer testing.allocator.free(once);
        const twice = try js(testing.allocator, once, stripOnlyArgs);
        defer testing.allocator.free(twice);

        const onceTags = try tagSequence(testing.allocator, once);
        defer testing.allocator.free(onceTags);
        const twiceTags = try tagSequence(testing.allocator, twice);
        defer testing.allocator.free(twiceTags);

        try testing.expectEqualSlices(tok.JsTokenType, onceTags, twiceTags);
    }

    test "js: joins two adjacent simple expression statements with the comma operator" {
        try expectJS("a=1;b=2;", "a=1,b=2");
    }

    test "js: joins three or more adjacent expression statements into one sequence" {
        try expectJS("a=1;b=2;c=3;", "a=1,b=2,c=3");
    }

    test "js: joins adjacent call-expression statements" {
        try expectJS("f();g();", "f(),g()");
    }

    test "js: does not join across a var_decl" {
        try expectJS("a=1;var b;c=2;", "a=1;var b;c=2");
    }

    test "js: does not join across an if statement" {
        try expectJS("a=1;if(x){y();}b=2;", "a=1;if(x){y()}b=2");
    }

    test "js: does not join a lone expression statement with nothing adjacent" {
        try expectJS("a=1;", "a=1");
    }

    test "js: joins only the adjacent run, leaving the rest of the block intact" {
        try expectJS(
            "function f(){a=1;b=2;if(x){y();}c=3;d=4;}",
            "function f(){a=1,b=2;if(x){y()}c=3,d=4}",
        );
    }

    test "js: joining inside a block still closes with the block's own brace" {
        try expectJS("if(x){a=1;b=2;}", "if(x){a=1,b=2}");
    }

    test "js: leading \"use strict\" directive is never folded into a sequence" {
        try expectJS("\"use strict\";a=1;b=2;", "\"use strict\";a=1,b=2");
    }

    test "js: leading directive prologue protects multiple leading string statements" {
        try expectJS("\"use strict\";\"use asm\";a=1;b=2;", "\"use strict\";\"use asm\";a=1,b=2");
    }

    test "js: a string literal statement is only treated as a directive at the very start" {
        try expectJS("a=1;\"just a string\";b=2;", "a=1,\"just a string\",b=2");
    }

    test "js: joining flattens rather than nesting an already-comma expression" {
        try expectJS("a=1,b=2;c=3;", "a=1,b=2,c=3");
    }

    test "js: switch case bodies join adjacent expression statements too" {
        try expectJS(
            "switch(x){case 1:a=1;b=2;break;}",
            "switch(x){case 1:a=1,b=2;break;}",
        );
    }

    test "js: joining survives identifier mangling" {
        try expectMangled(
            "function f(){var longName1=1;var longName2=2;longName1=3;longName2=4;}",
            &.{"mangle:{\"top\":false}"},
            "function f(){var a=1;var b=2;a=3,b=4}",
        );
    }

    test "round-trip: statement joining is idempotent on a second minify pass" {
        const once = try js(testing.allocator, "a=1;b=2;c=3;", stripOnlyArgs);
        defer testing.allocator.free(once);
        const twice = try js(testing.allocator, once, stripOnlyArgs);
        defer testing.allocator.free(twice);
        try testing.expectEqualStrings(once, twice);
    }

    test "js: quoted object-literal key unquoted when it's a safe identifier" {
        try expectJS("const o = {\"foo\": 1};", "const o={foo:1}");
    }

    test "js: quoted object-literal key stays quoted when not a safe identifier" {
        try expectJS("const o = {\"foo-bar\": 1};", "const o={\"foo-bar\":1}");
    }

    test "js: numeric object-literal key printed bare, no brackets" {
        try expectJS("const o = {0: 1, 1.5: 2};", "const o={0:1,1.5:2}");
    }

    test "js: bracket-computed object-literal key collapses the same way as a quoted one" {
        try expectJS("const o = {[\"foo\"]: 1};", "const o={foo:1}");
    }

    test "js: reserved-word string key left quoted rather than unquoted" {
        try expectJS("const o = {\"class\": 1};", "const o={\"class\":1}");
    }

    test "js: quoted method name on an object literal" {
        try expectJS("const o = {\"foo-bar\"(){return 1;}};", "const o={\"foo-bar\"(){return 1}}");
    }

    test "js: quoted key in destructuring requires the colon form" {
        try expectJS("const {\"foo\": bar} = obj;", "const{foo:bar}=obj");
    }

    test "js: quoted destructuring key stays quoted when unsafe as an identifier" {
        try expectJS("const {\"foo-bar\": baz} = obj;", "const{\"foo-bar\":baz}=obj");
    }

    test "js: quoted class field name" {
        try expectJS("class C { \"foo-bar\" = 1; }", "class C{\"foo-bar\"=1;}");
    }

    test "js: quoted class method name unquoted when safe" {
        try expectJS("class C { \"foo\"() { return 1; } }", "class C{foo(){return 1}}");
    }

    test "js: numeric class field name" {
        try expectJS("class C { 0 = 1; }", "class C{0=1;}");
    }

    test "js: string literal quote character normalized to fewer escapes" {
        try expectJS("const s = 'it\\'s';", "const s=\"it's\"");
    }

    test "js: string literal quote character normalized the other direction" {
        try expectJS("const s = \"say \\\"hi\\\"\";", "const s='say \"hi\"'");
    }

    test "js: string literal quote choice keeps original when already optimal" {
        try expectJS("const s = \"it's fine\";", "const s=\"it's fine\"");
    }

    test "js: string literal quote choice ties prefer double quotes" {
        try expectJS("const s = 'plain text';", "const s=\"plain text\"");
    }

    test "js: string literal with both quote characters picks the fewer-escape side" {
        try expectJS("const s = \"it's a \\\"test\\\"\";", "const s='it\\'s a \"test\"'");
    }

    test "js: string literal quote normalization leaves other escapes untouched" {
        try expectJS("const s = 'line\\n\\tend';", "const s=\"line\\n\\tend\"");
    }
};

const js_scope_tests = struct {
    const testing = std.testing;
    const parser = @import("js_parser.zig");
    const scope = @import("js.zig");
    const ast = @import("js_parser.zig");

    const Setup = struct {
        tree_: ast.JsAst,
        scopeTree: scope.JsScopeTree,

        fn deinit(self: *Setup) void {
            self.scopeTree.deinit();
            self.tree_.deinit();
        }
    };

    fn build(source: []const u8) !Setup {
        var tree_ = try parser.jsParse(testing.allocator, source);
        errdefer tree_.deinit();
        const scopeTree = try scope.jsScopeBuild(testing.allocator, &tree_.program);
        return .{ .tree_ = tree_, .scopeTree = scopeTree };
    }

    fn findDecl(s: *const Setup, scopeId: scope.JsScopeId, name: []const u8) ?scope.JsScopeDecl {
        for (s.scopeTree.scopes.items[scopeId].decls.items) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    fn firstRefResolution(s: *const Setup, name: []const u8) ?scope.JsScopeId {
        for (s.scopeTree.references.items) |r| {
            if (std.mem.eql(u8, r.name, name)) return r.resolvedScope;
        }
        return null;
    }

    fn refCount(s: *const Setup, name: []const u8) usize {
        var n: usize = 0;
        for (s.scopeTree.references.items) |r| {
            if (std.mem.eql(u8, r.name, name)) n += 1;
        }
        return n;
    }

    test "scope: top-level var declaration lands in global scope" {
        var s = try build("var x = 1;");
        defer s.deinit();
        try testing.expect(findDecl(&s, 0, "x") != null);
    }

    test "scope: var inside a block hoists to the enclosing function/global scope" {
        var s = try build("var x; { var y; }");
        defer s.deinit();
        try testing.expect(findDecl(&s, 0, "x") != null);
        try testing.expect(findDecl(&s, 0, "y") != null);
        try testing.expectEqual(@as(usize, 1), s.scopeTree.scopes.items[0].children.items.len);
        const blockId = s.scopeTree.scopes.items[0].children.items[0];
        try testing.expect(findDecl(&s, blockId, "y") == null);
    }

    test "scope: let inside a block stays in the block, not hoisted" {
        var s = try build("let x; { let y; }");
        defer s.deinit();
        try testing.expect(findDecl(&s, 0, "x") != null);
        try testing.expect(findDecl(&s, 0, "y") == null);
        const blockId = s.scopeTree.scopes.items[0].children.items[0];
        try testing.expect(findDecl(&s, blockId, "y") != null);
    }

    test "scope: var inside a function hoists only to that function, not past it" {
        var s = try build("function f() { var x; }");
        defer s.deinit();
        try testing.expect(findDecl(&s, 0, "x") == null);
        try testing.expect(findDecl(&s, 0, "f") != null);
    }

    test "scope: multiple comma-separated declarators are each recorded" {
        var s = try build("var a = 1, b = 2, c;");
        defer s.deinit();
        try testing.expect(findDecl(&s, 0, "a") != null);
        try testing.expect(findDecl(&s, 0, "b") != null);
        try testing.expect(findDecl(&s, 0, "c") != null);
    }

    test "scope: object destructuring declares each bound name" {
        var s = try build("const {a, b} = obj;");
        defer s.deinit();
        try testing.expect(findDecl(&s, 0, "a") != null);
        try testing.expect(findDecl(&s, 0, "b") != null);
    }

    test "scope: array destructuring declares each bound name" {
        var s = try build("let [a, b] = arr;");
        defer s.deinit();
        try testing.expect(findDecl(&s, 0, "a") != null);
        try testing.expect(findDecl(&s, 0, "b") != null);
    }

    test "scope: reference after destructuring resolves to the bound name" {
        var s = try build("const {a} = obj; a;");
        defer s.deinit();
        try testing.expectEqual(@as(usize, 1), refCount(&s, "a"));
        try testing.expect(firstRefResolution(&s, "a") != null);
    }

    test "scope: var destructuring inside a block still hoists to the enclosing function" {
        var s = try build("function f() { { var {a} = obj; } return a; }");
        defer s.deinit();
        const fScope = s.scopeTree.scopes.items[0].children.items[0];
        try testing.expect(findDecl(&s, fScope, "a") != null);
    }

    // This pass walks the parser's already-disambiguated JsAstPattern nodes,
    // so nested/renamed/defaulted/rest destructuring all resolve
    // correctly - not just a flat `{a, b}` pattern.
    test "scope: nested destructuring pattern declares the nested name" {
        var s = try build("const {a: {b}} = obj; b;");
        defer s.deinit();
        try testing.expect(findDecl(&s, 0, "a") == null); // "a" is a key, not a binding
        try testing.expect(findDecl(&s, 0, "b") != null);
        try testing.expect(firstRefResolution(&s, "b") != null);
    }

    test "scope: destructuring with a default value declares the target name" {
        var s = try build("const {a = 1} = obj; a;");
        defer s.deinit();
        try testing.expect(findDecl(&s, 0, "a") != null);
        try testing.expect(firstRefResolution(&s, "a") != null);
    }

    test "scope: rest destructuring declares the rest name" {
        var s = try build("const [a, ...rest] = arr; a; rest;");
        defer s.deinit();
        try testing.expect(findDecl(&s, 0, "a") != null);
        try testing.expect(findDecl(&s, 0, "rest") != null);
    }

    test "scope: renamed destructuring ({a: b}) declares the renamed target, not the key" {
        var s = try build("const {a: renamed} = obj; renamed;");
        defer s.deinit();
        try testing.expect(findDecl(&s, 0, "a") == null);
        try testing.expect(findDecl(&s, 0, "renamed") != null);
    }

    test "scope: empty destructuring pattern declares nothing and doesn't crash" {
        var s = try build("const {} = obj; const [] = arr;");
        defer s.deinit();
    }

    test "scope: function declaration name is recorded in the enclosing scope" {
        var s = try build("function f() {}");
        defer s.deinit();
        try testing.expect(findDecl(&s, 0, "f") != null);
        try testing.expectEqual(scope.JsScopeDeclKind.function, findDecl(&s, 0, "f").?.kind);
    }

    test "scope: function parameters are recorded and visible in the body" {
        var s = try build("function f(a, b) { return a + b; }");
        defer s.deinit();
        try testing.expect(firstRefResolution(&s, "a") != null);
        try testing.expect(firstRefResolution(&s, "b") != null);
    }

    test "scope: reference inside a function body resolves to its parameter" {
        var s = try build("function f(a) { return a; }");
        defer s.deinit();
        try testing.expectEqual(@as(usize, 1), refCount(&s, "a"));
        try testing.expect(firstRefResolution(&s, "a") != null);
    }

    test "scope: default parameter declares the target and its default is walked as an expression" {
        var s = try build("var d = 1; function f(a = d) { return a; }");
        defer s.deinit();
        try testing.expect(firstRefResolution(&s, "a") != null);
        try testing.expect(firstRefResolution(&s, "d") != null); // default value references outer `d`
    }

    test "scope: rest parameter declares the bound name" {
        var s = try build("function f(...rest) { return rest; }");
        defer s.deinit();
        try testing.expect(firstRefResolution(&s, "rest") != null);
    }

    test "scope: reference to an undeclared name is left unresolved" {
        var s = try build("f(x);");
        defer s.deinit();
        try testing.expect(firstRefResolution(&s, "f") == null);
        try testing.expect(firstRefResolution(&s, "x") == null);
    }

    test "scope: inner declaration shadows outer one for inner references" {
        var s = try build("var x = 1; function f() { var x = 2; return x; }");
        defer s.deinit();
        const fScope = s.scopeTree.scopes.items[0].children.items[0];
        var innerRefScope: ?scope.JsScopeId = null;
        for (s.scopeTree.references.items) |r| {
            if (std.mem.eql(u8, r.name, "x")) innerRefScope = r.resolvedScope;
        }
        try testing.expectEqual(fScope, innerRefScope.?);
    }

    test "scope: property access after a dot is not treated as a reference" {
        var s = try build("var obj = {}; obj.foo;");
        defer s.deinit();
        try testing.expectEqual(@as(usize, 0), refCount(&s, "foo"));
        try testing.expectEqual(@as(usize, 1), refCount(&s, "obj"));
    }

    test "scope: object literal key is not treated as a reference" {
        var s = try build("var x = { foo: 1 };");
        defer s.deinit();
        try testing.expectEqual(@as(usize, 0), refCount(&s, "foo"));
    }

    test "scope: catch parameter is visible inside the catch block" {
        var s = try build("try {} catch (e) { console.log(e); }");
        defer s.deinit();
        try testing.expect(firstRefResolution(&s, "e") != null);
    }

    test "scope: class name is recorded as a declaration" {
        var s = try build("class Foo {}");
        defer s.deinit();
        try testing.expect(findDecl(&s, 0, "Foo") != null);
        try testing.expectEqual(scope.JsScopeDeclKind.class, findDecl(&s, 0, "Foo").?.kind);
    }

    test "scope: class method parameter is visible in the method body" {
        var s = try build("class Foo { bar(a) { return a; } }");
        defer s.deinit();
        try testing.expect(firstRefResolution(&s, "a") != null);
    }

    test "scope: with statement marks its own scope unsafeToMangle" {
        var s = try build("with (obj) { x = 1; }");
        defer s.deinit();
        const withScope = s.scopeTree.scopes.items[0].children.items[0];
        try testing.expect(s.scopeTree.scopes.items[withScope].unsafeToMangle);
    }

    test "scope: no with statement leaves scopes safe to mangle" {
        var s = try build("var x = 1;");
        defer s.deinit();
        try testing.expect(!s.scopeTree.scopes.items[0].unsafeToMangle);
    }

    test "scope: with statement doesn't mark sibling scopes unsafe" {
        var s = try build("function f() {} with (obj) { x = 1; }");
        defer s.deinit();
        // Scope 0 is global; the function's own scope is a sibling of
        // the with-statement's scope, not a descendant of it.
        for (s.scopeTree.scopes.items[0].children.items) |childId| {
            const child = s.scopeTree.scopes.items[childId];
            if (child.kind == .function) {
                try testing.expect(!child.unsafeToMangle);
            }
        }
    }

    test "scope: arrow function with parens binds its parameter in the body" {
        var s = try build("const f = (a) => a + 1;");
        defer s.deinit();
        try testing.expect(firstRefResolution(&s, "a") != null);
    }

    test "scope: arrow function with bare parameter binds it in the body" {
        var s = try build("const f = a => a + 1;");
        defer s.deinit();
        try testing.expect(firstRefResolution(&s, "a") != null);
    }

    test "scope: arrow function with block body binds its parameter" {
        var s = try build("const f = (a) => { return a; };");
        defer s.deinit();
        try testing.expect(firstRefResolution(&s, "a") != null);
    }

    test "scope: break/continue label is not treated as a reference" {
        var s = try build("outer: for (;;) { break outer; }");
        defer s.deinit();
        try testing.expectEqual(@as(usize, 0), refCount(&s, "outer"));
    }

    test "scope: nested function scopes chain correctly for closures" {
        var s = try build("function outer() { var x = 1; function inner() { return x; } }");
        defer s.deinit();
        try testing.expect(firstRefResolution(&s, "x") != null);
    }

    test "scope: sibling blocks don't see each other's let declarations" {
        var s = try build("{ let x = 1; } { x; }");
        defer s.deinit();
        try testing.expect(firstRefResolution(&s, "x") == null);
    }

    test "scope: let in a classic for-init is scoped to the loop, not the enclosing block" {
        var s = try build("for (let i = 0; i < 1; i++) { i; } i;");
        defer s.deinit();
        // The last, top-level `i;` is a fresh unresolved reference; every
        // `i` inside the loop head/body should resolve to the loop's own
        // scope instead of leaking out.
        var resolvedCount: usize = 0;
        var unresolvedCount: usize = 0;
        for (s.scopeTree.references.items) |r| {
            if (!std.mem.eql(u8, r.name, "i")) continue;
            if (r.resolvedScope != null) resolvedCount += 1 else unresolvedCount += 1;
        }
        try testing.expectEqual(@as(usize, 1), unresolvedCount);
        try testing.expect(resolvedCount > 0);
    }

    test "scope: for-of with existing variable resolves the loop variable as a reference" {
        var s = try build("var x; for (x of arr) { x; }");
        defer s.deinit();
        try testing.expect(refCount(&s, "x") >= 2);
        for (s.scopeTree.references.items) |r| {
            if (std.mem.eql(u8, r.name, "x")) try testing.expect(r.resolvedScope != null);
        }
    }

    test "scope: named function expression's name is visible only inside its own body" {
        var s = try build("var f = function self() { return self; }; self;");
        defer s.deinit();
        // Exactly one resolved reference (inside the body) and one
        // unresolved reference (the trailing top-level `self;`, which
        // never sees the expression's own name).
        var resolved: usize = 0;
        var unresolved: usize = 0;
        for (s.scopeTree.references.items) |r| {
            if (!std.mem.eql(u8, r.name, "self")) continue;
            if (r.resolvedScope != null) resolved += 1 else unresolved += 1;
        }
        try testing.expectEqual(@as(usize, 1), resolved);
        try testing.expectEqual(@as(usize, 1), unresolved);
    }

    test "scope tree stays balanced across a file with many constructs" {
        var s = try build(
            \\function f(a, b = 1) {
            \\  if (a) {
            \\    try {
            \\      var x = 1;
            \\    } catch (e) {
            \\      console.log(e);
            \\    }
            \\  }
            \\  const g = (c) => {
            \\    class Inner {}
            \\    return c;
            \\  };
            \\  return g(a);
            \\}
            \\var top = f(1, 2);
        );
        defer s.deinit();
        try testing.expect(findDecl(&s, 0, "f") != null);
        try testing.expect(findDecl(&s, 0, "top") != null);
    }
};

const js_mangle_tests = struct {
    const testing = std.testing;
    const parser = @import("js_parser.zig");
    const scope = @import("js.zig");
    const mangle = @import("js.zig");
    const ast = @import("js_parser.zig");

    const Setup = struct {
        tree_: ast.JsAst,
        scopeTree: scope.JsScopeTree,

        fn deinit(self: *Setup) void {
            self.scopeTree.deinit();
            self.tree_.deinit();
        }
    };

    fn build(source: []const u8) !Setup {
        var tree_ = try parser.jsParse(testing.allocator, source);
        errdefer tree_.deinit();
        const scopeTree = try scope.jsScopeBuild(testing.allocator, &tree_.program);
        return .{ .tree_ = tree_, .scopeTree = scopeTree };
    }

    fn findDecl(s: *const Setup, scopeId: scope.JsScopeId, name: []const u8) ?scope.JsScopeDecl {
        for (s.scopeTree.scopes.items[scopeId].decls.items) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    // Frees every JsScopeDecl.shortName in the tree - used instead of manually
    // enumerating which decls got assigned a name in each test, since
    // that list is easy to get wrong (e.g. forgetting that a
    // `function f` declaration also adds `f` itself to the enclosing
    // scope, not just whatever's declared inside its body).
    fn freeAllShortNames(s: *const Setup) void {
        for (s.scopeTree.scopes.items) |sc| {
            for (sc.decls.items) |d| {
                if (d.shortName.len > 0) testing.allocator.free(d.shortName);
            }
        }
    }

    test "shortNames: first names are single ascii letters, collision-free within a scope" {
        var s = try build("var a; var b; var c;");
        defer s.deinit();
        try mangle.jsMangleAssignShortNames(testing.allocator, &s.scopeTree, &.{}, &.{}, null);
        defer freeAllShortNames(&s);

        const na = findDecl(&s, 0, "a").?.shortName;
        const nb = findDecl(&s, 0, "b").?.shortName;
        const nc = findDecl(&s, 0, "c").?.shortName;
        try testing.expect(!std.mem.eql(u8, na, nb));
        try testing.expect(!std.mem.eql(u8, na, nc));
        try testing.expect(!std.mem.eql(u8, nb, nc));
    }

    test "shortNames: never assigns a reserved word" {
        var s = try build("var a;");
        defer s.deinit();
        try mangle.jsMangleAssignShortNames(testing.allocator, &s.scopeTree, &.{}, &.{}, null);
        defer freeAllShortNames(&s);
        const name = findDecl(&s, 0, "a").?.shortName;
        try testing.expect(!std.mem.eql(u8, name, "in"));
        try testing.expect(!std.mem.eql(u8, name, "if"));
        try testing.expect(!std.mem.eql(u8, name, "do"));
    }

    test "shortNames: caller-supplied reserved list is also avoided" {
        var s = try build("var a;");
        defer s.deinit();
        try mangle.jsMangleAssignShortNames(testing.allocator, &s.scopeTree, &.{"a"}, &.{}, null);
        defer freeAllShortNames(&s);
        const name = findDecl(&s, 0, "a").?.shortName;
        try testing.expect(!std.mem.eql(u8, name, "a"));
    }

    test "shortNames: protected decl name is left unmangled" {
        var s = try build("var protectedName; var other;");
        defer s.deinit();
        try mangle.jsMangleAssignShortNames(testing.allocator, &s.scopeTree, &.{}, &.{"protectedName"}, null);
        defer freeAllShortNames(&s);
        try testing.expectEqual(@as(usize, 0), findDecl(&s, 0, "protectedName").?.shortName.len);
        try testing.expect(findDecl(&s, 0, "other").?.shortName.len > 0);
    }

    test "shortNames: an unresolved global reference is avoided, even from an unrelated inner scope" {
        // "a" is referenced here as a bare identifier but never declared
        // anywhere this pass can see - a real global. The unrelated
        // `longName` decl's generated short name must not collide with
        // it, even though "a" isn't itself a JsScopeDecl anywhere in the tree
        // (so collectVisibleNames alone would never catch this).
        var s = try build("function f(longName) { return a + longName; }");
        defer s.deinit();
        try mangle.jsMangleAssignShortNames(testing.allocator, &s.scopeTree, &.{}, &.{}, null);
        defer freeAllShortNames(&s);
        const fScope = s.scopeTree.scopes.items[0].children.items[0];
        const name = findDecl(&s, fScope, "longName").?.shortName;
        try testing.expect(!std.mem.eql(u8, name, "a"));
    }

    test "shortNames: most-referenced decl in a scope gets the shortest name" {
        // `rare` is declared but used once (its own declaration doesn't
        // count as a reference - see JsScopeReference vs JsScopeDecl); `common` is
        // referenced three times. `common` should claim "a" even though
        // `rare` was declared first.
        var s = try build("var rare; var common; common; common; common;");
        defer s.deinit();
        try mangle.jsMangleAssignShortNames(testing.allocator, &s.scopeTree, &.{}, &.{}, null);
        defer freeAllShortNames(&s);
        try testing.expectEqualStrings("a", findDecl(&s, 0, "common").?.shortName);
        try testing.expectEqualStrings("b", findDecl(&s, 0, "rare").?.shortName);
    }

    test "shortNames: equal reference counts keep original declaration order" {
        var s = try build("var first; var second;");
        defer s.deinit();
        try mangle.jsMangleAssignShortNames(testing.allocator, &s.scopeTree, &.{}, &.{}, null);
        defer freeAllShortNames(&s);
        try testing.expectEqualStrings("a", findDecl(&s, 0, "first").?.shortName);
        try testing.expectEqualStrings("b", findDecl(&s, 0, "second").?.shortName);
    }

    test "shortNames: child scope avoids parent scope's assigned names" {
        var s = try build("var a; function f() { var b; }");
        defer s.deinit();
        try mangle.jsMangleAssignShortNames(testing.allocator, &s.scopeTree, &.{}, &.{}, null);
        defer freeAllShortNames(&s);
        const nameA = findDecl(&s, 0, "a").?.shortName;
        const fScope = s.scopeTree.scopes.items[0].children.items[0];
        const nameB = findDecl(&s, fScope, "b").?.shortName;
        try testing.expect(!std.mem.eql(u8, nameA, nameB));
    }

    test "shortNames: sibling scopes may reuse the same short name" {
        // Using unnamed function expressions rather than named top-level
        // function declarations keeps `f`/`g`'s own names out of the
        // global scope's decls entirely, so the only names in play are
        // each inner scope's own `var a` - isolating exactly the
        // sibling-reuse property this test means to check, without also
        // exercising (and having to account for) collision avoidance
        // against two extra global-scope function names.
        var s = try build("(function () { var a; }), (function () { var a; });");
        defer s.deinit();
        try mangle.jsMangleAssignShortNames(testing.allocator, &s.scopeTree, &.{}, &.{}, null);
        defer freeAllShortNames(&s);
        const fScope = s.scopeTree.scopes.items[0].children.items[0];
        const gScope = s.scopeTree.scopes.items[0].children.items[1];
        const nameInF = findDecl(&s, fScope, "a").?.shortName;
        const nameInG = findDecl(&s, gScope, "a").?.shortName;
        // Not required to be equal, just permitted - both should at least
        // have gotten the shortest available name for their own scope,
        // which happens to be the same one here since neither scope's
        // ancestor chain (the empty global scope) used anything.
        try testing.expectEqualStrings("a", nameInF);
        try testing.expectEqualStrings("a", nameInG);
    }

    test "shortNames: skipScope is honored by skipping the global scope" {
        var s = try build("var a; function f() { var b; }");
        defer s.deinit();
        try mangle.jsMangleAssignShortNames(testing.allocator, &s.scopeTree, &.{}, &.{}, 0);
        defer freeAllShortNames(&s);
        try testing.expectEqual(@as(usize, 0), findDecl(&s, 0, "a").?.shortName.len);
        const fScope = s.scopeTree.scopes.items[0].children.items[0];
        try testing.expect(findDecl(&s, fScope, "b").?.shortName.len > 0);
    }

    test "shortNames: generated name sequence covers the expected boundary points" {
        // Directly exercises the bijective-numeration name generator via
        // jsMangleAssignShortNames on a scope with enough decls to cross from
        // single-character to double-character names (54 single-char
        // names in the alphabet: 26+26+2).
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(testing.allocator);
        var i: usize = 0;
        while (i < 60) : (i += 1) {
            try source.appendSlice(testing.allocator, "var v");
            try appendDecimal(&source, i);
            try source.appendSlice(testing.allocator, ";");
        }
        var s = try build(source.items);
        defer s.deinit();
        try mangle.jsMangleAssignShortNames(testing.allocator, &s.scopeTree, &.{}, &.{}, null);
        defer freeAllShortNames(&s);

        try testing.expectEqualStrings("a", findDecl(&s, 0, "v0").?.shortName);
        try testing.expectEqualStrings("_", findDecl(&s, 0, "v53").?.shortName);
        try testing.expectEqualStrings("aa", findDecl(&s, 0, "v54").?.shortName);
    }

    // Appends the decimal digits of `n` to `list` - avoids depending on
    // std.ArrayList(u8)'s writer/print API, whose exact shape on this Zig
    // snapshot hasn't been separately confirmed.
    fn appendDecimal(list: *std.ArrayList(u8), n: usize) !void {
        if (n == 0) {
            try list.append(testing.allocator, '0');
            return;
        }
        var buf: [20]u8 = undefined;
        var len: usize = 0;
        var v = n;
        while (v > 0) : (v /= 10) {
            buf[len] = @as(u8, @intCast(v % 10)) + '0';
            len += 1;
        }
        while (len > 0) {
            len -= 1;
            try list.append(testing.allocator, buf[len]);
        }
    }
};

const js_parser_tests = struct {
    const testing = std.testing;
    const parser = @import("js_parser.zig");
    const ast = @import("js_parser.zig");

    fn parseExpr(source: []const u8) !struct { tree: ast.JsAst, expr: *ast.JsAstNode } {
        // Wrap in a bare expression statement so parseStatement's
        // fallback path picks it up, then unwrap it back out.
        var tree = try parser.jsParse(testing.allocator, source);
        errdefer tree.deinit();
        try testing.expectEqual(@as(usize, 1), tree.program.body.len);
        const stmt = tree.program.body[0];
        const expr = switch (stmt.data) {
            .expr_stmt => |e| e,
            else => return error.TestUnexpectedResult,
        };
        return .{ .tree = tree, .expr = expr };
    }

    fn parseStmt(source: []const u8) !struct { tree: ast.JsAst, stmt: *ast.JsAstNode } {
        var tree = try parser.jsParse(testing.allocator, source);
        errdefer tree.deinit();
        try testing.expectEqual(@as(usize, 1), tree.program.body.len);
        return .{ .tree = tree, .stmt = tree.program.body[0] };
    }

    test "parser: number literal" {
        var r = try parseExpr("42;");
        defer r.tree.deinit();
        try testing.expectEqualStrings("42", r.expr.data.number_literal);
    }

    test "parser: string literal" {
        var r = try parseExpr("\"hi\";");
        defer r.tree.deinit();
        try testing.expectEqualStrings("\"hi\"", r.expr.data.string_literal);
    }

    test "parser: identifier" {
        var r = try parseExpr("foo;");
        defer r.tree.deinit();
        try testing.expectEqualStrings("foo", r.expr.data.identifier);
    }

    test "parser: true/false/null" {
        var r1 = try parseExpr("true;");
        defer r1.tree.deinit();
        try testing.expect(r1.expr.data.boolean_literal == true);

        var r2 = try parseExpr("false;");
        defer r2.tree.deinit();
        try testing.expect(r2.expr.data.boolean_literal == false);

        var r3 = try parseExpr("null;");
        defer r3.tree.deinit();
        try testing.expect(r3.expr.data == .null_literal);
    }

    test "parser: binary precedence - multiplication binds tighter than addition" {
        var r = try parseExpr("1 + 2 * 3;");
        defer r.tree.deinit();
        const bin = r.expr.data.binary;
        try testing.expectEqualStrings("+", bin.op);
        try testing.expectEqualStrings("1", bin.left.data.number_literal);
        const rhs = bin.right.data.binary;
        try testing.expectEqualStrings("*", rhs.op);
    }

    test "parser: binary left-associativity" {
        var r = try parseExpr("1 - 2 - 3;");
        defer r.tree.deinit();
        // (1 - 2) - 3: outer op's left side is itself a binary "-", not
        // a number.
        const outer = r.expr.data.binary;
        try testing.expectEqualStrings("-", outer.op);
        try testing.expect(outer.left.data == .binary);
        try testing.expect(outer.right.data == .number_literal);
    }

    test "parser: exponent right-associativity" {
        var r = try parseExpr("2 ** 3 ** 2;");
        defer r.tree.deinit();
        // 2 ** (3 ** 2): outer op's RIGHT side is itself "**", left is a
        // plain number.
        const outer = r.expr.data.binary;
        try testing.expectEqualStrings("**", outer.op);
        try testing.expect(outer.left.data == .number_literal);
        try testing.expect(outer.right.data == .binary);
        try testing.expectEqualStrings("**", outer.right.data.binary.op);
    }

    test "parser: logical operators produce .logical, not .binary" {
        var r = try parseExpr("a && b || c;");
        defer r.tree.deinit();
        try testing.expect(r.expr.data == .logical);
        try testing.expectEqualStrings("||", r.expr.data.logical.op);
        try testing.expect(r.expr.data.logical.left.data == .logical);
    }

    test "parser: ternary conditional" {
        var r = try parseExpr("a ? b : c;");
        defer r.tree.deinit();
        const cond = r.expr.data.conditional;
        try testing.expectEqualStrings("a", cond.test_.data.identifier);
        try testing.expectEqualStrings("b", cond.consequent.data.identifier);
        try testing.expectEqualStrings("c", cond.alternate.data.identifier);
    }

    test "parser: assignment is right-associative" {
        var r = try parseExpr("a = b = c;");
        defer r.tree.deinit();
        const outer = r.expr.data.assignment;
        try testing.expectEqualStrings("=", outer.op);
        try testing.expectEqualStrings("a", outer.left.data.identifier);
        try testing.expect(outer.right.data == .assignment);
    }

    test "parser: unary and postfix update" {
        var r1 = try parseExpr("!a;");
        defer r1.tree.deinit();
        try testing.expectEqualStrings("!", r1.expr.data.unary.op);

        var r2 = try parseExpr("a++;");
        defer r2.tree.deinit();
        try testing.expectEqualStrings("++", r2.expr.data.update.op);
    }

    test "parser: member and computed member chain" {
        var r = try parseExpr("a.b[c].d;");
        defer r.tree.deinit();
        // Outermost is .d
        try testing.expectEqualStrings("d", r.expr.data.member.property);
        const inner1 = r.expr.data.member.object; // a.b[c]
        try testing.expect(inner1.data == .computed_member);
        const inner2 = inner1.data.computed_member.object; // a.b
        try testing.expectEqualStrings("b", inner2.data.member.property);
    }

    test "parser: optional chaining" {
        var r = try parseExpr("a?.b?.();");
        defer r.tree.deinit();
        try testing.expect(r.expr.data == .call);
        try testing.expect(r.expr.data.call.optional);
        const callee = r.expr.data.call.callee;
        try testing.expect(callee.data == .member);
        try testing.expect(callee.data.member.optional);
    }

    test "parser: call with spread argument" {
        var r = try parseExpr("f(a, ...b);");
        defer r.tree.deinit();
        const call = r.expr.data.call;
        try testing.expectEqual(@as(usize, 2), call.arguments.len);
        try testing.expect(call.arguments[1].data == .spread);
    }

    test "parser: new expression with and without parens" {
        var r1 = try parseExpr("new Foo(1);");
        defer r1.tree.deinit();
        try testing.expect(r1.expr.data == .new_expr);
        try testing.expectEqual(@as(usize, 1), r1.expr.data.new_expr.arguments.len);

        var r2 = try parseExpr("new Foo;");
        defer r2.tree.deinit();
        try testing.expect(r2.expr.data == .new_expr);
        try testing.expectEqual(@as(usize, 0), r2.expr.data.new_expr.arguments.len);
    }

    test "parser: array literal with holes and spread" {
        var r = try parseExpr("[1, , ...b];");
        defer r.tree.deinit();
        const arr = r.expr.data.array_literal;
        try testing.expectEqual(@as(usize, 3), arr.len);
        try testing.expect(arr[0] != null);
        try testing.expect(arr[1] == null);
        try testing.expect(arr[2].?.data == .spread);
    }

    test "parser: object literal shorthand, method, and computed key" {
        var r = try parseExpr("({a, foo() {}, [k]: 1});");
        defer r.tree.deinit();
        const obj = r.expr.data.paren.data.object_literal;
        try testing.expectEqual(@as(usize, 3), obj.len);
        try testing.expect(obj[0].shorthand);
        try testing.expectEqualStrings("a", obj[0].key.?);
        try testing.expectEqual(ast.JsAstObjectPropertyKind.method, obj[1].kind);
        try testing.expect(obj[2].computed_key != null);
    }

    test "parser: arrow function, bare parameter" {
        var r = try parseExpr("a => a + 1;");
        defer r.tree.deinit();
        const arrow = r.expr.data.arrow_function;
        try testing.expectEqual(@as(usize, 1), arrow.params.len);
        try testing.expect(arrow.body.data == .binary);
    }

    test "parser: arrow function, parenthesized parameters and block body" {
        var r = try parseExpr("(a, b) => { return a + b; };");
        defer r.tree.deinit();
        const arrow = r.expr.data.arrow_function;
        try testing.expectEqual(@as(usize, 2), arrow.params.len);
        try testing.expect(arrow.body.data == .block);
    }

    test "parser: parenthesized expression is not mistaken for an arrow" {
        var r = try parseExpr("(a + b);");
        defer r.tree.deinit();
        try testing.expect(r.expr.data == .paren);
    }

    test "parser: destructuring assignment target from object literal shape" {
        var r = try parseExpr("({a, b: c} = obj);");
        defer r.tree.deinit();
        const assign = r.expr.data.paren.data.assignment;
        try testing.expectEqualStrings("=", assign.op);
        const pat = assign.left.data.pattern;
        try testing.expectEqual(ast.JsAstPatternKind.object, pat.kind);
        try testing.expectEqual(@as(usize, 2), pat.properties.len);
        try testing.expectEqualStrings("a", pat.properties[0].key.?);
        try testing.expectEqualStrings("b", pat.properties[1].key.?);
    }

    test "parser: destructuring assignment with default" {
        var r = try parseExpr("({a = 1} = obj);");
        defer r.tree.deinit();
        const assign = r.expr.data.paren.data.assignment;
        const pat = assign.left.data.pattern;
        try testing.expect(pat.properties[0].default != null);
        try testing.expectEqualStrings("1", pat.properties[0].default.?.data.number_literal);
    }

    test "parser: array destructuring assignment with rest" {
        var r = try parseExpr("([a, ...rest] = arr);");
        defer r.tree.deinit();
        const assign = r.expr.data.paren.data.assignment;
        const pat = assign.left.data.pattern;
        try testing.expectEqual(ast.JsAstPatternKind.array, pat.kind);
        try testing.expect(pat.rest != null);
        try testing.expectEqualStrings("rest", pat.rest.?.data.identifier);
    }

    test "parser: template literal with one substitution" {
        var r = try parseExpr("`a${b}c`;");
        defer r.tree.deinit();
        const tmpl = r.expr.data.template_literal;
        try testing.expectEqual(@as(usize, 2), tmpl.quasis.len);
        try testing.expectEqual(@as(usize, 1), tmpl.expressions.len);
        try testing.expectEqualStrings("b", tmpl.expressions[0].data.identifier);
    }

    test "parser: template literal with no substitutions" {
        var r = try parseExpr("`hello`;");
        defer r.tree.deinit();
        const tmpl = r.expr.data.template_literal;
        try testing.expectEqual(@as(usize, 1), tmpl.quasis.len);
        try testing.expectEqual(@as(usize, 0), tmpl.expressions.len);
    }

    test "parser: template literal substitution can contain a nested expression" {
        var r = try parseExpr("`sum: ${1 + 2}`;");
        defer r.tree.deinit();
        const tmpl = r.expr.data.template_literal;
        try testing.expectEqual(@as(usize, 1), tmpl.expressions.len);
        try testing.expect(tmpl.expressions[0].data == .binary);
    }

    test "parser: nested template literal inside a substitution" {
        var r = try parseExpr("`outer${`inner${1}`}`;");
        defer r.tree.deinit();
        const tmpl = r.expr.data.template_literal;
        try testing.expectEqual(@as(usize, 1), tmpl.expressions.len);
        try testing.expect(tmpl.expressions[0].data == .template_literal);
    }

    test "parser: var declaration with destructuring" {
        var tree = try parser.jsParse(testing.allocator, "const {a, b} = obj;");
        defer tree.deinit();
        try testing.expectEqual(@as(usize, 1), tree.program.body.len);
        const decl = tree.program.body[0].data.var_decl;
        try testing.expectEqual(ast.JsAstVarKind.@"const", decl.kind);
        try testing.expectEqual(@as(usize, 1), decl.declarators.len);
        try testing.expect(decl.declarators[0].id.data == .pattern);
    }

    test "parser: function declaration with default and rest parameters" {
        var tree = try parser.jsParse(testing.allocator, "function f(a, b = 1, ...rest) { return a; }");
        defer tree.deinit();
        const fn_ = tree.program.body[0].data.function_decl;
        try testing.expectEqualStrings("f", fn_.name.?);
        try testing.expectEqual(@as(usize, 3), fn_.params.len);
        try testing.expect(fn_.params[0].data == .identifier);
        try testing.expect(fn_.params[1].data == .assignment);
        try testing.expect(fn_.params[2].data == .spread);
    }

    test "parser: class declaration with method, getter, and field" {
        var tree = try parser.jsParse(testing.allocator,
            \\class Foo extends Bar {
            \\  x = 1;
            \\  method() { return this.x; }
            \\  get y() { return 2; }
            \\}
        );
        defer tree.deinit();
        const cls = tree.program.body[0].data.class_decl;
        try testing.expectEqualStrings("Foo", cls.name.?);
        try testing.expect(cls.super_class != null);
        try testing.expectEqual(@as(usize, 3), cls.members.len);
        try testing.expectEqual(ast.JsAstClassMemberKind.field, cls.members[0].kind);
        try testing.expectEqual(ast.JsAstClassMemberKind.method, cls.members[1].kind);
        try testing.expectEqual(ast.JsAstClassMemberKind.getter, cls.members[2].kind);
    }

    test "parser: private class field and private member access" {
        var tree = try parser.jsParse(testing.allocator,
            \\class Foo {
            \\  #secret = 1;
            \\  reveal() { return this.#secret; }
            \\}
        );
        defer tree.deinit();
        const cls = tree.program.body[0].data.class_decl;
        try testing.expect(cls.members[0].is_private);
        try testing.expectEqualStrings("secret", cls.members[0].key.?);
    }

    test "parser: if/else" {
        var r = try parseStmt("if (a) b; else c;");
        defer r.tree.deinit();
        const s = r.stmt.data.if_stmt;
        try testing.expectEqualStrings("a", s.test_.data.identifier);
        try testing.expect(s.alternate != null);
    }

    test "parser: if with no else" {
        var r = try parseStmt("if (a) b;");
        defer r.tree.deinit();
        try testing.expect(r.stmt.data.if_stmt.alternate == null);
    }

    test "parser: dangling else binds to the nearest if" {
        var r = try parseStmt("if (a) if (b) c; else d;");
        defer r.tree.deinit();
        const outer = r.stmt.data.if_stmt;
        try testing.expect(outer.alternate == null);
        const inner = outer.consequent.data.if_stmt;
        try testing.expect(inner.alternate != null);
    }

    test "parser: while loop" {
        var r = try parseStmt("while (a) b;");
        defer r.tree.deinit();
        try testing.expectEqualStrings("a", r.stmt.data.while_stmt.test_.data.identifier);
    }

    test "parser: do-while loop, semicolon optional" {
        var r1 = try parseStmt("do a; while (b);");
        defer r1.tree.deinit();
        try testing.expectEqualStrings("b", r1.stmt.data.do_while.test_.data.identifier);

        // No trailing semicolon at all - still valid, per do-while's own
        // special ASI exception.
        var tree2 = try parser.jsParse(testing.allocator, "do a; while (b)");
        defer tree2.deinit();
        try testing.expectEqual(@as(usize, 1), tree2.program.body.len);
    }

    test "parser: classic for loop, all clauses present" {
        var r = try parseStmt("for (let i = 0; i < 10; i++) x;");
        defer r.tree.deinit();
        const f = r.stmt.data.for_stmt;
        try testing.expect(f.init != null);
        try testing.expect(f.init.?.data == .var_decl);
        try testing.expect(f.test_ != null);
        try testing.expect(f.update != null);
    }

    test "parser: classic for loop, all clauses empty" {
        var r = try parseStmt("for (;;) x;");
        defer r.tree.deinit();
        const f = r.stmt.data.for_stmt;
        try testing.expect(f.init == null);
        try testing.expect(f.test_ == null);
        try testing.expect(f.update == null);
    }

    test "parser: for-in with declaration" {
        var r = try parseStmt("for (let x in obj) y;");
        defer r.tree.deinit();
        const f = r.stmt.data.for_in_of;
        try testing.expect(!f.is_of);
        try testing.expect(f.left.data == .var_decl);
        try testing.expectEqualStrings("obj", f.right.data.identifier);
    }

    test "parser: for-of with existing variable (no declaration)" {
        var r = try parseStmt("for (x of arr) y;");
        defer r.tree.deinit();
        const f = r.stmt.data.for_in_of;
        try testing.expect(f.is_of);
        try testing.expect(f.left.data == .identifier);
    }

    test "parser: for-await-of" {
        var r = try parseStmt("for await (const x of gen) y;");
        defer r.tree.deinit();
        const f = r.stmt.data.for_in_of;
        try testing.expect(f.is_of);
        try testing.expect(f.is_await);
    }

    test "parser: switch with case and default" {
        var r = try parseStmt(
            \\switch (a) {
            \\  case 1: b; break;
            \\  default: c;
            \\}
        );
        defer r.tree.deinit();
        const s = r.stmt.data.switch_stmt;
        try testing.expectEqual(@as(usize, 2), s.cases.len);
        try testing.expect(s.cases[0].test_ != null);
        try testing.expectEqual(@as(usize, 2), s.cases[0].body.len);
        try testing.expect(s.cases[1].test_ == null);
    }

    test "parser: try/catch/finally" {
        var r = try parseStmt("try { a; } catch (e) { b; } finally { c; }");
        defer r.tree.deinit();
        const t = r.stmt.data.try_stmt;
        try testing.expect(t.catch_param != null);
        try testing.expect(t.catch_body != null);
        try testing.expect(t.finally_body != null);
    }

    test "parser: catch with no binding parameter" {
        var r = try parseStmt("try { a; } catch { b; }");
        defer r.tree.deinit();
        const t = r.stmt.data.try_stmt;
        try testing.expect(t.catch_param == null);
        try testing.expect(t.catch_body != null);
    }

    test "parser: try/finally with no catch" {
        var r = try parseStmt("try { a; } finally { b; }");
        defer r.tree.deinit();
        const t = r.stmt.data.try_stmt;
        try testing.expect(t.catch_body == null);
        try testing.expect(t.finally_body != null);
    }

    test "parser: throw statement" {
        var r = try parseStmt("throw new Error(\"x\");");
        defer r.tree.deinit();
        try testing.expect(r.stmt.data.throw_stmt.data == .new_expr);
    }

    test "parser: labeled statement" {
        var r = try parseStmt("outer: while (a) b;");
        defer r.tree.deinit();
        const l = r.stmt.data.labeled_stmt;
        try testing.expectEqualStrings("outer", l.label);
        try testing.expect(l.body.data == .while_stmt);
    }

    test "parser: break and continue with and without labels" {
        var r1 = try parseStmt("break;");
        defer r1.tree.deinit();
        try testing.expect(r1.stmt.data.break_stmt == null);

        var r2 = try parseStmt("break outer;");
        defer r2.tree.deinit();
        try testing.expectEqualStrings("outer", r2.stmt.data.break_stmt.?);

        var r3 = try parseStmt("continue;");
        defer r3.tree.deinit();
        try testing.expect(r3.stmt.data.continue_stmt == null);
    }

    test "parser: with statement" {
        var r = try parseStmt("with (obj) a;");
        defer r.tree.deinit();
        try testing.expectEqualStrings("obj", r.stmt.data.with_stmt.object.data.identifier);
    }

    test "parser: nested control flow round-trips structurally" {
        var tree = try parser.jsParse(testing.allocator,
            \\function f(x) {
            \\  for (let i = 0; i < x; i++) {
            \\    if (i % 2 === 0) {
            \\      continue;
            \\    }
            \\    try {
            \\      doSomething(i);
            \\    } catch (e) {
            \\      throw e;
            \\    }
            \\  }
            \\  return x;
            \\}
        );
        defer tree.deinit();
        const fn_ = tree.program.body[0].data.function_decl;
        const body = fn_.body.data.block.body;
        try testing.expectEqual(@as(usize, 2), body.len);
        try testing.expect(body[0].data == .for_stmt);
        try testing.expect(body[1].data == .return_stmt);
    }
};

const js_printer_tests = struct {
    const testing = std.testing;
    const parser = @import("js_parser.zig");
    const scope = @import("js.zig");
    const mangle = @import("js.zig");
    const printer = @import("js.zig");

    // Parses `source`, optionally mangles (skipScope controls which scope
    // is left unmangled, same meaning as jsMangleAssignShortNames'), prints, and
    // compares against `expected`. Frees every allocation the pipeline
    // made along the way.
    fn expectPrinted(source: []const u8, expected: []const u8, mangleNames: bool, skipScope: ?scope.JsScopeId) !void {
        var tree_ = try parser.jsParse(testing.allocator, source);
        defer tree_.deinit();

        var scopeTree = try scope.jsScopeBuild(testing.allocator, &tree_.program);
        defer scopeTree.deinit();

        if (mangleNames) {
            try mangle.jsMangleAssignShortNames(testing.allocator, &scopeTree, &.{}, &.{}, skipScope);
        }
        defer if (mangleNames) {
            for (scopeTree.scopes.items) |s| {
                for (s.decls.items) |d| {
                    if (d.shortName.len > 0) testing.allocator.free(d.shortName);
                }
            }
        };

        const out = try printer.jsPrint(testing.allocator, &tree_.program, &scopeTree);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(expected, out);
    }

    fn expectStripped(source: []const u8, expected: []const u8) !void {
        try expectPrinted(source, expected, false, null);
    }

    fn expectMangled(source: []const u8, expected: []const u8) !void {
        try expectPrinted(source, expected, true, null);
    }

    test "printer: strips whitespace around a var declaration" {
        try expectStripped("var   x   =   1  ;", "var x=1");
    }

    test "printer: keeps a required space between two adjacent keywords/identifiers" {
        try expectStripped("return x;", "return x");
        try expectStripped("typeof x;", "typeof x");
        try expectStripped("var x;", "var x");
    }

    test "printer: no space needed around most punctuation" {
        try expectStripped("a = b + c;", "a=b+c");
        try expectStripped("if (a) { b(); }", "if(a){b()}");
    }

    test "printer: preserves ++/-- boundary against a following +/-" {
        try expectStripped("a++ + b;", "a++ +b");
        try expectStripped("a - -b;", "a- -b");
    }

    test "printer: double negation needs no separating space" {
        try expectStripped("!!x;", "!!x");
    }

    test "printer: function declaration round-trips" {
        try expectStripped("function f(a, b) { return a + b; }", "function f(a,b){return a+b}");
    }

    test "printer: arrow function round-trips" {
        try expectStripped("const f = (a, b) => a + b;", "const f=(a,b)=>a+b");
        try expectStripped("const f = () => { return 1; };", "const f=()=>{return 1}");
    }

    test "printer: a sole bare-identifier arrow param drops its parens" {
        try expectStripped("const f = (a) => a + 1;", "const f=a=>a+1");
        try expectStripped("const f = a => a + 1;", "const f=a=>a+1");
        try expectStripped("const f = async (a) => a + 1;", "const f=async a=>a+1");
    }

    test "printer: an arrow param that isn't a sole bare identifier keeps its parens" {
        try expectStripped("const f = () => 1;", "const f=()=>1");
        try expectStripped("const f = (a, b) => a + b;", "const f=(a,b)=>a+b");
        try expectStripped("const f = (a = 1) => a;", "const f=(a=1)=>a");
        try expectStripped("const f = ({a}) => a;", "const f=({a})=>a");
        try expectStripped("const f = ([a]) => a;", "const f=([a])=>a");
        try expectStripped("const f = (...a) => a;", "const f=(...a)=>a");
    }

    test "printer: a mangled sole arrow param still drops its parens" {
        // The renamed short name is still a plain identifier, so the
        // same paren-dropping rule applies after mangling too.
        try expectMangled("const outerName = (paramName) => paramName + 1;", "const a=b=>b+1");
    }

    test "printer: bare arrow param stays correctly separated as a call argument" {
        try expectStripped("arr.map((x) => x + 1);", "arr.map(x=>x+1)");
    }

    test "printer: if/else without blocks round-trips" {
        try expectStripped("if (a) b(); else c();", "if(a)b();else c()");
    }

    test "printer: for/while/do-while round-trip" {
        try expectStripped("for (var i = 0; i < 10; i++) { f(i); }", "for(var i=0;i<10;i++){f(i)}");
        try expectStripped("while (a) { b(); }", "while(a){b()}");
        try expectStripped("do { a(); } while (b);", "do{a()}while(b)");
    }

    test "printer: for-in/for-of round-trip with required keyword spacing" {
        try expectStripped("for (var x in y) { f(x); }", "for(var x in y){f(x)}");
        try expectStripped("for (const x of y) { f(x); }", "for(const x of y){f(x)}");
    }

    test "printer: template literal round-trips including embedded expressions" {
        try expectStripped("const s = `a${b}c`;", "const s=`a${b}c`");
    }

    test "printer: object literal with shorthand and computed keys round-trips" {
        try expectStripped("const o = { a, [b]: c, d: e };", "const o={a,[b]:c,d:e}");
    }

    test "printer: destructuring declarator round-trips" {
        try expectStripped("const { a, b: c, ...rest } = obj;", "const{a,b:c,...rest}=obj");
        try expectStripped("const [a, , b] = arr;", "const[a,,b]=arr");
    }

    test "printer: class with methods and fields round-trips" {
        try expectStripped(
            "class C extends B { x = 1; static y; #z; method(a) { return a; } get g() { return this.x; } }",
            "class C extends B{x=1;static y;#z;method(a){return a}get g(){return this.x}}",
        );
    }

    test "printer: try/catch/finally round-trips" {
        try expectStripped("try { a(); } catch (e) { b(e); } finally { c(); }", "try{a()}catch(e){b(e)}finally{c()}");
    }

    test "printer: switch round-trips" {
        try expectStripped("switch (a) { case 1: b(); break; default: c(); }", "switch(a){case 1:b();break;default:c();}");
    }

    test "printer: mangling substitutes both declaration and reference sites" {
        try expectMangled("var longName; longName = 1;", "var a;a=1");
    }

    test "printer: mangling substitutes a function declaration's own name" {
        try expectMangled("function longName() {} longName();", "function a(){}a()");
    }

    test "printer: mangling substitutes params and leaves an unresolved global alone" {
        try expectMangled("function f(longParam) { return longParam + unresolvedGlobal; }", "function a(b){return b+unresolvedGlobal}");
    }

    test "printer: mangling leaves object/member property names untouched" {
        try expectMangled("var longName = { longName: 1 }; longName.longName;", "var a={longName:1};a.longName");
    }

    test "printer: mangled shorthand property prints the expanded key:value form" {
        try expectMangled("var longName = 1; var o = { longName };", "var a=1;var b={longName:a}");
    }

    test "printer: mangled destructuring binding keeps the property key, only renames the binding" {
        // longName here is simultaneously the object's real property name
        // (must stay literal) and the new local binding (safe to rename) -
        // renaming the whole shorthand token the way a naive text
        // substitution would have made this read a different property.
        try expectMangled(
            "function f(obj){ const {longName} = obj; return longName; }",
            "function a(b){const{longName:c}=b;return c}",
        );
    }

    test "printer: skipScope leaves the global scope's own decls unmangled" {
        try expectPrinted("var longName; function f(longParam) { return longParam; }", "var longName;function f(a){return a}", true, 0);
    }
};

const svg_tests = struct {
    const svgmod = @import("svg.zig");
    const testing = std.testing;
    const svg = svgmod.svg;
    const SvgTree = svgmod.SvgTree;
    const SvgNodeKind = svgmod.SvgNodeKind;
    const svgParse = svgmod.svgParse;
    const svgCollectIdRefs = svgmod.svgCollectIdRefs;
    const svgSerialize = svgmod.svgSerialize;

    // No stripping, no hypercrush, no mangling - lets tests assert
    // specific SVG behavior in isolation.
    const conservativeArgs = "{\"js\":{\"mangle\":{\"enabled\":false}},\"svg\":{\"strip\":\"none\",\"hypercrush\":false}}";
    // Same as conservativeArgs but with mangling on - for tests that
    // specifically exercise js delegation's mangling behavior.
    const mangleArgs = "{\"js\":{\"mangle\":{\"enabled\":true}},\"svg\":{\"strip\":\"none\",\"hypercrush\":false}}";
    fn testParse(input: []const u8) !SvgTree {
        return svgParse(testing.allocator, input);
    }

    test "svg: parses a simple element with attributes" {
        var tree = try testParse("<svg viewBox=\"0 0 10 10\"><rect x=\"1\" y=\"2\"/></svg>");
        defer tree.deinit();

        const root = tree.root.?;
        try testing.expectEqualStrings("svg", root.tagName);
        try testing.expectEqualStrings("0 0 10 10", root.findAttr("viewBox").?);
        try testing.expectEqual(@as(usize, 1), root.children.items.len);

        const rect = root.children.items[0];
        try testing.expectEqualStrings("rect", rect.tagName);
        try testing.expectEqualStrings("1", rect.findAttr("x").?);
        try testing.expectEqualStrings("2", rect.findAttr("y").?);
    }

    test "svg: parses text content" {
        var tree = try testParse("<svg><text>hello</text></svg>");
        defer tree.deinit();

        const text = tree.root.?.children.items[0];
        try testing.expectEqual(@as(usize, 1), text.children.items.len);
        try testing.expectEqualStrings("hello", text.children.items[0].text);
    }

    test "svg: parses comments and preserves them as nodes" {
        var tree = try testParse("<svg><!-- a comment --><rect/></svg>");
        defer tree.deinit();

        const root = tree.root.?;
        try testing.expectEqual(@as(usize, 2), root.children.items.len);
        try testing.expectEqual(SvgNodeKind.comment, root.children.items[0].kind);
        try testing.expectEqualStrings(" a comment ", root.children.items[0].text);
    }

    test "svg: parses CDATA sections" {
        var tree = try testParse("<svg><style><![CDATA[.a{fill:red}]]></style></svg>");
        defer tree.deinit();

        const style = tree.root.?.children.items[0];
        const cdata = style.children.items[0];
        try testing.expectEqual(SvgNodeKind.cdata, cdata.kind);
        try testing.expectEqualStrings(".a{fill:red}", cdata.text);
    }

    test "svg: passes through xml prolog and doctype untouched" {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const input = try alloc.dupe(u8, "<?xml version=\"1.0\"?>\n<svg></svg>");
        var tree = try testParse(input);
        defer tree.deinit();

        try testing.expectEqualStrings("svg", tree.root.?.tagName);
    }

    test "svg: self-closing and explicit-close elements both parse" {
        var tree = try testParse("<svg><rect/><circle></circle></svg>");
        defer tree.deinit();

        const root = tree.root.?;
        try testing.expectEqual(@as(usize, 2), root.children.items.len);
        try testing.expectEqualStrings("rect", root.children.items[0].tagName);
        try testing.expectEqualStrings("circle", root.children.items[1].tagName);
    }

    test "svg: nested groups parse into a real tree" {
        var tree = try testParse("<svg><g><g><rect/></g></g></svg>");
        defer tree.deinit();

        const g1 = tree.root.?.children.items[0];
        const g2 = g1.children.items[0];
        const rect = g2.children.items[0];
        try testing.expectEqualStrings("g", g1.tagName);
        try testing.expectEqualStrings("g", g2.tagName);
        try testing.expectEqualStrings("rect", rect.tagName);
    }

    test "svg: parsed nodes have parent pointers set, root's is null" {
        var tree = try testParse("<svg><g><rect/></g></svg>");
        defer tree.deinit();

        const root = tree.root.?;
        const g = root.children.items[0];
        const rect = g.children.items[0];

        try testing.expect(root.parent == null);
        try testing.expectEqual(root, g.parent.?);
        try testing.expectEqual(g, rect.parent.?);
    }

    test "svg: round-trips a simple document" {
        var tree = try testParse("<svg viewBox=\"0 0 10 10\"><rect x=\"1\" y=\"2\"/></svg>");
        defer tree.deinit();

        const out = try svgSerialize(testing.allocator, tree.root.?, .{});
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("<svg viewBox=\"0 0 10 10\"><rect x=\"1\" y=\"2\"/></svg>", out);
    }

    test "svg: round-trips comments and CDATA" {
        var tree = try testParse("<svg><!--hi--><style><![CDATA[.a{}]]></style></svg>");
        defer tree.deinit();

        const out = try svgSerialize(testing.allocator, tree.root.?, .{});
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("<svg><!--hi--><style><![CDATA[.a{}]]></style></svg>", out);
    }

    test "svg: id ref set collects url() references, including inside style attr" {
        var tree = try testParse(
            \\<svg><defs><linearGradient id="g1"/></defs>
            \\<rect fill="url(#g1)"/>
            \\<circle style="fill:url(#g1)"/></svg>
        );
        defer tree.deinit();

        var refs = try svgCollectIdRefs(testing.allocator, tree.root.?);
        defer refs.deinit();

        try testing.expect(refs.contains("g1"));
        try testing.expect(!refs.contains("nonexistent"));
    }

    test "svg: id ref set collects href and xlink:href fragment references" {
        var tree = try testParse(
            \\<svg><path id="p1" d="M0 0"/>
            \\<use href="#p1"/>
            \\<use xlink:href="#p1"/></svg>
        );
        defer tree.deinit();

        var refs = try svgCollectIdRefs(testing.allocator, tree.root.?);
        defer refs.deinit();

        try testing.expect(refs.contains("p1"));
    }

    test "svg: id ref set ignores non-fragment href values" {
        var tree = try testParse("<svg><a href=\"https://example.com/#p1\"><rect/></a></svg>");
        defer tree.deinit();

        var refs = try svgCollectIdRefs(testing.allocator, tree.root.?);
        defer refs.deinit();

        // The href doesn't start with '#' (it's a full external URL), so no
        // fragment reference should be recorded.
        try testing.expectEqual(@as(usize, 0), refs.ids.count());
    }

    test "svg: id ref set collects SMIL begin/end syncbase references" {
        var tree = try testParse(
            \\<svg><rect id="r1"/>
            \\<animate begin="r1.click" attributeName="x"/>
            \\<animate end="2s"/></svg>
        );
        defer tree.deinit();

        var refs = try svgCollectIdRefs(testing.allocator, tree.root.?);
        defer refs.deinit();

        try testing.expect(refs.contains("r1"));
        // "2s" is a pure offset, not an id reference.
        try testing.expectEqual(@as(usize, 1), refs.ids.count());
    }

    test "svg: id ref set protects getElementById literal from script" {
        var tree = try testParse(
            \\<svg><rect id="r1"/>
            \\<script>document.getElementById('r1').setAttribute('x','1');</script></svg>
        );
        defer tree.deinit();

        var refs = try svgCollectIdRefs(testing.allocator, tree.root.?);
        defer refs.deinit();

        try testing.expect(refs.contains("r1"));
    }

    test "svg: id ref set protects getElementById literal from on* handler" {
        var tree = try testParse(
            \\<svg><rect id="r1" onclick="document.getElementById('r1').remove()"/></svg>
        );
        defer tree.deinit();

        var refs = try svgCollectIdRefs(testing.allocator, tree.root.?);
        defer refs.deinit();

        try testing.expect(refs.contains("r1"));
    }

    test "svg: id ref set ignores computed getElementById argument" {
        var tree = try testParse(
            \\<svg><rect id="r1"/>
            \\<script>var name='r'+'1';document.getElementById(name);</script></svg>
        );
        defer tree.deinit();

        var refs = try svgCollectIdRefs(testing.allocator, tree.root.?);
        defer refs.deinit();

        try testing.expect(!refs.contains("r1"));
    }

    test "svg: id ref set is empty when nothing references any id" {
        var tree = try testParse("<svg><rect id=\"unused\"/></svg>");
        defer tree.deinit();

        var refs = try svgCollectIdRefs(testing.allocator, tree.root.?);
        defer refs.deinit();

        try testing.expectEqual(@as(usize, 0), refs.ids.count());
    }

    test "svg: attribute value containing a literal quote is re-escaped on output" {
        var tree = try testParse("<svg><title>t</title></svg>");
        defer tree.deinit();
        // Simulate a stored value containing a raw quote (e.g. after an
        // optimization pass rewrote it) to exercise the serializer's escape.
        const root = tree.root.?;
        try root.attrs.append(tree.arena.allocator(), .{ .name = "data-x", .value = "a\"b" });

        const out = try svgSerialize(testing.allocator, root, .{});
        defer testing.allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "data-x=\"a&quot;b\"") != null);
    }

    test "svg: strip base level removes unreferenced id, keeps referenced id" {
        const out = try svg(testing.allocator,
            \\<svg><defs><linearGradient id="g1"/></defs>
            \\<rect id="unused" fill="url(#g1)"/></svg>
        , "{\"svg\":{\"strip\":\"base\",\"hypercrush\":false}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "id=\"g1\"") != null);
        try testing.expect(std.mem.indexOf(u8, out, "id=\"unused\"") == null);
    }

    test "svg: strip base level keeps id referenced only from a script" {
        const out = try svg(testing.allocator,
            \\<svg><rect id="target"/>
            \\<script>document.getElementById("target").remove();</script></svg>
        , "{\"svg\":{\"strip\":\"base\",\"hypercrush\":false}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "id=\"target\"") != null);
    }

    test "svg: strip base level keeps xmlns and baseProfile on root" {
        const out = try svg(testing.allocator, "<svg version=\"1.1\" baseProfile=\"full\" xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"></svg>", "{\"svg\":{\"strip\":\"base\"}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "baseProfile") != null);
        try testing.expect(std.mem.indexOf(u8, out, "xmlns=") != null);
        try testing.expect(std.mem.indexOf(u8, out, "version") == null);
    }

    test "svg: strip more level also removes baseProfile but keeps xmlns" {
        const out = try svg(testing.allocator, "<svg baseProfile=\"full\" xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"></svg>", "{\"svg\":{\"strip\":\"more\"}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "baseProfile") == null);
        try testing.expect(std.mem.indexOf(u8, out, "xmlns=") != null);
    }

    test "svg: strip all level removes both baseProfile and xmlns" {
        const out = try svg(testing.allocator, "<svg baseProfile=\"full\" xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"></svg>", "{\"svg\":{\"strip\":\"all\"}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "baseProfile") == null);
        try testing.expect(std.mem.indexOf(u8, out, "xmlns=") == null);
    }

    test "svg: strip level none leaves attributes untouched (still round-trips quoting)" {
        const out = try svg(testing.allocator, "<svg id=\"keep-me\" version=\"1.1\"></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        // Serialization always normalizes an empty-children element to
        // self-closing form regardless of how the source wrote it; the
        // point here is that no *attribute* was touched.
        try testing.expectEqualStrings("<svg id=\"keep-me\" version=\"1.1\"/>", out);
    }

    test "svg: root-only attrs on a non-root element are left alone" {
        const out = try svg(testing.allocator, "<svg><rect xmlns:custom=\"foo\"/></svg>", "{\"svg\":{\"strip\":\"all\"}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "xmlns:custom") != null);
    }

    test "svg: id referenced via xlink:href survives stripping, unreferenced descendant id does not" {
        const out = try svg(testing.allocator,
            \\<svg><path id="p1" d="M0 0"/>
            \\<use xlink:href="#p1"/>
            \\<path id="p2" d="M1 1"/></svg>
        , "{\"svg\":{\"strip\":\"base\",\"hypercrush\":false}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "id=\"p1\"") != null);
        try testing.expect(std.mem.indexOf(u8, out, "id=\"p2\"") == null);
    }

    test "svg: always-stripped attrs (xml:space, enable-background) removed on descendants too" {
        const out = try svg(testing.allocator, "<svg><rect xml:space=\"preserve\" enable-background=\"new\"/></svg>", "{\"svg\":{\"strip\":\"base\"}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "xml:space") == null);
        try testing.expect(std.mem.indexOf(u8, out, "enable-background") == null);
    }

    test "svg: elides a default-valued presentation attribute" {
        const out = try svg(testing.allocator, "<svg><rect stroke-width=\"1\"/></svg>", "{\"svg\":{\"strip\":\"base\"}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "stroke-width") == null);
    }

    test "svg: keeps a non-default-valued presentation attribute" {
        const out = try svg(testing.allocator, "<svg><rect stroke-width=\"2\"/></svg>", "{\"svg\":{\"strip\":\"base\",\"hypercrush\":false}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "stroke-width=\"2\"") != null);
    }

    test "svg: keeps a default-valued attribute that resets an ancestor's override" {
        const out = try svg(testing.allocator, "<svg><g fill=\"red\"><rect fill=\"black\"/></g></svg>", "{\"svg\":{\"strip\":\"base\",\"hypercrush\":false}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "fill=\"black\"") != null);
    }

    test "svg: elides a default-valued attribute whose ancestor already matches the default" {
        const out = try svg(testing.allocator, "<svg><g fill=\"black\"><rect fill=\"black\"/></g></svg>", "{\"svg\":{\"strip\":\"base\"}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "rect fill") == null);
    }

    test "svg: does not elide a presentation attribute on a node with a style attribute" {
        const out = try svg(testing.allocator, "<svg><rect stroke-width=\"1\" style=\"fill:red\"/></svg>", "{\"svg\":{\"strip\":\"base\"}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "stroke-width") != null);
    }

    test "svg: removes a childless g" {
        const out = try svg(testing.allocator, "<svg><g></g><rect/></svg>", "{\"svg\":{\"strip\":\"base\"}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "<g") == null);
        try testing.expect(std.mem.indexOf(u8, out, "<rect") != null);
    }

    test "svg: collapses a single-child g into its parent" {
        const out = try svg(testing.allocator, "<svg><g><rect/></g></svg>", "{\"svg\":{\"strip\":\"base\"}}");
        defer testing.allocator.free(out);

        try testing.expectEqualStrings("<svg><rect/></svg>", out);
    }

    test "svg: does not collapse a g with an attribute" {
        const out = try svg(testing.allocator, "<svg><g transform=\"translate(1 2)\"><rect/></g></svg>", "{\"svg\":{\"strip\":\"base\"}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "<g") != null);
    }

    test "svg: does not collapse a g with a referenced id" {
        const out = try svg(testing.allocator,
            "<svg><g id=\"grp\"><rect/></g><use href=\"#grp\"/></svg>",
            "{\"svg\":{\"strip\":\"base\",\"hypercrush\":false}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "id=\"grp\"") != null);
    }

    test "svg: does not collapse a g whose only child is text" {
        const out = try svg(testing.allocator, "<svg><g>hello</g></svg>", "{\"svg\":{\"strip\":\"base\"}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "<g>hello</g>") != null);
    }

    test "svg: collapsing an emptied g is considered in the same pass" {
        const out = try svg(testing.allocator, "<svg><g><g></g></g><rect/></svg>", "{\"svg\":{\"strip\":\"base\"}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "<g") == null);
    }

    test "svg: does not remove or collapse the svg root itself" {
        const out = try svg(testing.allocator, "<svg></svg>", "{\"svg\":{\"strip\":\"base\"}}");
        defer testing.allocator.free(out);

        try testing.expectEqualStrings("<svg/>", out);
    }

    test "svg: trims trailing zeros and float noise on single-number attrs" {
        const out = try svg(testing.allocator, "<svg><rect x=\"10.500\" y=\"3.00000001\" width=\"100\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "x=\"10.5\"") != null);
        try testing.expect(std.mem.indexOf(u8, out, "y=\"3\"") != null);
        try testing.expect(std.mem.indexOf(u8, out, "width=\"100\"") != null);
    }

    test "svg: drops redundant leading zero before decimal point" {
        const out = try svg(testing.allocator, "<svg><circle r=\"0.5\" cx=\"-0.25\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "r=\".5\"") != null);
        try testing.expect(std.mem.indexOf(u8, out, "cx=\"-.25\"") != null);
    }

    test "svg: preserves a non-numeric unit suffix like px or %" {
        const out = try svg(testing.allocator, "<svg><rect width=\"10.500px\"/><stop offset=\"50.000%\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "width=\"10.5px\"") != null);
        try testing.expect(std.mem.indexOf(u8, out, "offset=\"50%\"") != null);
    }

    test "svg: trims each number in a number-list attribute (viewBox)" {
        const out = try svg(testing.allocator, "<svg viewBox=\"0.000 0 100.50000 200\"></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "viewBox=\"0 0 100.5 200\"") != null);
    }

    test "svg: trims a comma-separated points list, normalizing separators to spaces" {
        const out = try svg(testing.allocator, "<svg><polygon points=\"0,0 10.000,5.500 20,0\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "points=\"0 0 10 5.5 20 0\"") != null);
    }

    test "svg: numeric trimming keeps at most 3 fractional digits" {
        const out = try svg(testing.allocator, "<svg><circle r=\"1.23456\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "r=\"1.235\"") != null);
    }

    test "svg: numeric trimming is on by default" {
        const out = try svg(testing.allocator, "<svg><rect x=\"10.500\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "x=\"10.5\"") != null);
    }

    test "svg: numeric trimming itself never touches a style attribute's value" {
        const out = try svg(testing.allocator, "<svg><rect style=\"stroke-width:1.50000\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "stroke-width:1.50000") != null);
    }

    test "svg: numeric trimming itself never descends into a <style> element's CSS text" {
        const out = try svg(testing.allocator, "<svg><style>.a{stroke-width:1.50000}</style><rect width=\"10.500\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "width=\"10.5\"") != null);
    }

    test "svg: css delegation minifies a style attribute's value via css.zig" {
        const out = try svg(testing.allocator, "<svg><rect style=\"fill:   red  ;  stroke-width : 1.5  \"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "style=\"fill:red;stroke-width:1.5\"") != null);
    }

    test "svg: css delegation minifies a <style> element's text via css.zig" {
        const out = try svg(testing.allocator, "<svg><style>.a  {  fill : red ;  }</style></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "<style>.a{fill:red}</style>") != null);
    }

    test "svg: css delegation minifies a <style> element's CDATA text via css.zig" {
        const out = try svg(testing.allocator, "<svg><style><![CDATA[.a  {  fill : red ;  }]]></style></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "<![CDATA[.a{fill:red}]]>") != null);
    }

    test "svg: css delegation preserves quoted string content inside a style attribute" {
        const out = try svg(testing.allocator, "<svg><text style=\"font-family:  'My   Font'  \">t</text></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "font-family:'My   Font'") != null);
    }

    test "svg: css delegation leaves a non-style, non-<style> element/attr untouched" {
        const out = try svg(testing.allocator, "<svg><rect fill=\"red\" data-note=\"a  {  b : c }\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "data-note=\"a  {  b : c }\"") != null);
    }

    test "svg: css delegation and numeric trimming can run together without interfering" {
        const out = try svg(testing.allocator, "<svg><rect width=\"10.500\" style=\"opacity:  0.500 ;\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "width=\"10.5\"") != null);
        try testing.expect(std.mem.indexOf(u8, out, "style=\"opacity:0.500\"") != null);
    }

    test "svg: js delegation minifies an on* event-handler attribute's value via js.zig" {
        const out = try svg(testing.allocator, "<svg><rect onclick=\"  var x = 1;  \"/></svg>", mangleArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "onclick=\"var a=1\"") != null);
    }

    test "svg: js delegation on an on* attribute mangles top-level names too, when safe" {
        const out = try svg(testing.allocator, "<svg><rect onclick=\"function f(longName){return longName+1}f(2)\"/></svg>", mangleArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "onclick=\"function a(b){return b+1}a(2)\"") != null);
    }

    test "svg: js delegation on an on* attribute prefers single-quoted strings to avoid &quot;" {
        // SVG attributes are always "-delimited (svgSerializeAttrValue),
        // so a tied string-quote choice must prefer ' here - if it
        // picked " like ordinary JS output does, the re-serialized
        // attribute would need &quot; instead of a raw '.
        const out = try svg(testing.allocator, "<svg><rect onclick=\"c('x')\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "onclick=\"c('x')\"") != null);
    }

    test "svg: js delegation leaves a non-event attribute with an on-like name untouched" {
        const out = try svg(testing.allocator, "<svg><rect once=\"  var x = 1;  \"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "once=\"  var x = 1;  \"") != null);
    }

    test "svg: js delegation minifies a <script> element's text via js.zig" {
        const out = try svg(testing.allocator, "<svg><script>  var x = 1;  </script></svg>", mangleArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "<script>var a=1</script>") != null);
    }

    test "svg: a name shared between a <script> and an on*= handler keeps its spelling" {
        const out = try svg(
            testing.allocator,
            "<svg><script>function paint(){return 1;}</script><rect onclick=\"paint()\"/></svg>",
            null,
        );
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "<script>function paint(){return 1}</script>") != null);
        try testing.expect(std.mem.indexOf(u8, out, "onclick=paint()") != null);
    }

    test "svg: id used only inside <script> text is not protected from stripping" {
        // getElementById references in script text aren't attribute
        // id-refs, so the id-ref scanner can't see them; the id gets
        // stripped even though the script depends on it at runtime.
        const out = try svg(testing.allocator,
            \\<svg><rect id="target"/>
            \\<script>document.getElementById("target");</script></svg>
        , "{\"svg\":{\"strip\":\"base\"}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "id=\"target\"") == null);
    }

    test "svg: script minification and attribute stripping both apply in one pass" {
        const out = try svg(testing.allocator,
            \\<svg><rect id="unused" fill="url(#g1)"/>
            \\<linearGradient id="g1"/>
            \\<script>  var y   =   2;  </script></svg>
        , "{\"svg\":{\"strip\":\"base\",\"hypercrush\":false}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "<script>var a=2</script>") != null);
        try testing.expect(std.mem.indexOf(u8, out, "id=\"g1\"") != null);
        try testing.expect(std.mem.indexOf(u8, out, "id=\"unused\"") == null);
    }

    test "svg: style element CSS with nested calc() is minified alongside attribute stripping" {
        const out = try svg(testing.allocator,
            \\<svg><rect id="unused"/>
            \\<style>rect { width: calc(  100% - calc(5px + 2px)  ); }</style></svg>
        , "{\"svg\":{\"strip\":\"base\"}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "width:calc(100% - calc(5px + 2px))") != null);
        try testing.expect(std.mem.indexOf(u8, out, "id=\"unused\"") == null);
    }

    test "svg: url(#id) inside <style> element text is NOT scanned, so the id gets stripped" {
        // The id-ref collector only walks element attributes, not text
        // content, so a `url(#g1)` written inside a <style> element's
        // CSS (as opposed to a style="..." attribute) is invisible to
        // it and won't protect the id.
        const out = try svg(testing.allocator,
            \\<svg><linearGradient id="g1"/>
            \\<style>rect { fill: url(#g1); }</style></svg>
        , "{\"svg\":{\"strip\":\"base\"}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "id=\"g1\"") == null);
    }

    test "svg: numeric trimming leaves non-numeric-attr values completely alone" {
        const out = try svg(testing.allocator, "<svg><rect fill=\"#ff0000\" id=\"box-1.5\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "fill=\"#ff0000\"") != null);
        try testing.expect(std.mem.indexOf(u8, out, "id=\"box-1.5\"") != null);
    }

    test "svg: malformed number list is left untouched rather than partially rewritten" {
        const out = try svg(testing.allocator, "<svg viewBox=\"0 0 notanumber 200\"></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "viewBox=\"0 0 notanumber 200\"") != null);
    }

    test "svg: trims path data numbers, normalizing spacing between args" {
        const out = try svg(testing.allocator, "<svg><path d=\"M10.500 20 L30.000 40.0000\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        // No space between "20" and "L" - a command letter is an
        // unambiguous boundary on its own, so a separating space there
        // would just be wasted bytes.
        try testing.expect(std.mem.indexOf(u8, out, "d=\"M10.5 20L30 40\"") != null);
    }

    test "svg: trims path data with no separators between numbers at all" {
        // ".5.5" is two numbers (.5 and .5); "-5-5" is two numbers (-5 and
        // -5) since the sign itself is an unambiguous boundary. Both are
        // legal, real-world-seen path-data shorthand.
        const out = try svg(testing.allocator, "<svg><path d=\"M.500.500L-5-5\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "d=\"M.5 .5L-5 -5\"") != null);
    }

    test "svg: trims path data with repeated implicit commands (no restated letter)" {
        const out = try svg(testing.allocator, "<svg><path d=\"L10.000 10 20.000 20\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "d=\"L10 10 20 20\"") != null);
    }

    test "svg: trims path data H and V commands (single-arg)" {
        const out = try svg(testing.allocator, "<svg><path d=\"M0 0H10.500V20.000\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "d=\"M0 0H10.5V20\"") != null);
    }

    test "svg: trims path data Z/z closepath with no args" {
        const out = try svg(testing.allocator, "<svg><path d=\"M0.000 0L10 10Z\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "d=\"M0 0L10 10Z\"") != null);
    }

    test "svg: trims path data cubic and quadratic curve commands" {
        const out = try svg(testing.allocator, "<svg><path d=\"M0 0C1.000 2 3 4.000 5 6Q7.000 8 9 10\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "d=\"M0 0C1 2 3 4 5 6Q7 8 9 10\"") != null);
    }

    test "svg: trims path data arc (A) command, treating flags as single digits" {
        // large-arc-flag and sweep-flag ("1","1") are glued together with
        // zero separator before "50" - reading them as plain numbers would
        // wrongly consume "11" as one number instead of two flags.
        const out = try svg(testing.allocator, "<svg><path d=\"M0 0A25.000,25.000,0,1,1,50.000,0\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "d=\"M0 0A25 25 0 1 1 50 0\"") != null);
    }

    test "svg: lowercase (relative) path commands are preserved as lowercase" {
        const out = try svg(testing.allocator, "<svg><path d=\"m0 0l10.000 10\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "d=\"m0 0l10 10\"") != null);
    }

    test "svg: malformed path data is left completely unchanged" {
        const out = try svg(testing.allocator, "<svg><path d=\"M0 0 notacommand\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "d=\"M0 0 notacommand\"") != null);
    }

    test "svg: trims transform function args, normalizing comma/space separators" {
        const out = try svg(testing.allocator, "<svg><rect transform=\"translate(10.500, 20) rotate(45.0000)\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "transform=\"translate(10.5 20) rotate(45)\"") != null);
    }

    test "svg: trims a matrix transform's six numeric args" {
        const out = try svg(testing.allocator, "<svg><rect transform=\"matrix(1.000 0 0 1.000 10.500 20.000)\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "transform=\"matrix(1 0 0 1 10.5 20)\"") != null);
    }

    test "svg: transform with a single function and no separator issues" {
        const out = try svg(testing.allocator, "<svg><rect transform=\"scale(0.500)\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "transform=\"scale(.5)\"") != null);
    }

    test "svg: malformed transform value is left completely unchanged" {
        const out = try svg(testing.allocator, "<svg><rect transform=\"translate(10\"/></svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "transform=\"translate(10\"") != null);
    }

    test "svg: hypercrush unquotes safe attribute values" {
        const out = try svg(testing.allocator, "<svg><rect fill=\"red\"/></svg>", "{\"svg\":{\"hypercrush\":true}}");
        defer testing.allocator.free(out);

        try testing.expectEqualStrings("<svg><rect fill=red /></svg>", out);
    }

    test "svg: hypercrush keeps quotes when value has whitespace" {
        const out = try svg(testing.allocator, "<svg viewBox=\"0 0 10 10\"/>", "{\"svg\":{\"hypercrush\":true}}");
        defer testing.allocator.free(out);

        try testing.expectEqualStrings("<svg viewBox=\"0 0 10 10\"/>", out);
    }

    test "svg: hypercrush strips leading zero in decimal attr values" {
        const out = try svg(testing.allocator, "<svg><circle r=\"0.5\"/></svg>", "{\"svg\":{\"hypercrush\":true}}");
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "r=.5") != null);
    }

    test "svg: whitespace between sibling elements never round-trips" {
        // Parsing (not hypercrush) is what discards this whitespace,
        // so the same output comes out with or without the option.
        const out = try svg(testing.allocator, "<svg>\n  <rect/>\n  <circle/>\n</svg>", conservativeArgs);
        defer testing.allocator.free(out);

        try testing.expectEqualStrings("<svg><rect/><circle/></svg>", out);
    }

    test "svg: hypercrush leaves significant text content untouched" {
        const out = try svg(testing.allocator, "<svg><text>hello world</text></svg>", "{\"svg\":{\"hypercrush\":true}}");
        defer testing.allocator.free(out);

        try testing.expectEqualStrings("<svg><text>hello world</text></svg>", out);
    }
};

const performance_tests = struct {
    const testing = std.testing;
    const cssMinify = @import("css.zig").css;
    const html = @import("html.zig").html;
    const js = @import("js.zig").js;
    const stripOnlyArgs = "{\"js\":{\"mangle\":{\"enabled\":false}}}";

    // ~2MB of repeated CSS rules with mixed selectors, comments, and
    // whitespace - large enough to exercise growable-buffer reallocation
    // many times over.
    fn genCss(allocator: std.mem.Allocator, ruleCount: usize) ![]u8 {
        // bufPrint into a fixed stack buffer, not allocPrint, so this
        // doesn't do one heap alloc/free per rule - with a debug/
        // leak-tracking allocator (as testing.allocator is), tens of
        // thousands of small tracked allocations made this hang for
        // minutes on its own, independent of anything in css.zig.
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        var scratch: [128]u8 = undefined;
        var i: usize = 0;
        while (i < ruleCount) : (i += 1) {
            const rule = try std.fmt.bufPrint(
                &scratch,
                "/* rule {d} */\n.class-{d}   ,   #id-{d}   {{\n  color  :  red  ;\n  margin : 0   10px  ;\n}}\n\n",
                .{ i, i, i },
            );
            try buf.appendSlice(allocator, rule);
        }
        return buf.toOwnedSlice(allocator);
    }

    fn genHtml(allocator: std.mem.Allocator, elemCount: usize) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, "<html>\n<body>\n");
        var scratch: [128]u8 = undefined;
        var i: usize = 0;
        while (i < elemCount) : (i += 1) {
            const elem = try std.fmt.bufPrint(
                &scratch,
                "  <div class=\"item-{d}\">   text {d}   <span>inner</span>   </div>\n",
                .{ i, i },
            );
            try buf.appendSlice(allocator, elem);
        }
        try buf.appendSlice(allocator, "</body>\n</html>");
        return buf.toOwnedSlice(allocator);
    }

    fn genJs(allocator: std.mem.Allocator, fnCount: usize) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        var scratch: [128]u8 = undefined;
        var i: usize = 0;
        while (i < fnCount) : (i += 1) {
            const fnText = try std.fmt.bufPrint(
                &scratch,
                "function fn{d}(a, b) {{\n  // adds two numbers\n  const sum = a + b;\n  return sum;\n}}\n\n",
                .{i},
            );
            try buf.appendSlice(allocator, fnText);
        }
        return buf.toOwnedSlice(allocator);
    }

    test "performance: large CSS input minifies without error" {
        // Kept at 2,000 (matching the HTML/JS sizes below), not
        // 20,000: under testing.allocator (std.heap.SafeAllocator,
        // not a plain DebugAllocator - confirmed by reading
        // testing.zig), each buffer-growth reallocation is expensive
        // enough that ~20,000 rules took over a minute despite ~10%
        // CPU and a few MB of RAM - i.e. real per-call overhead in
        // the allocator itself, not a css.zig bug or an infinite
        // loop. A plain page_allocator run of the same 1.8MB input
        // completed near-instantly, confirming this. 2,000 rules
        // (~180KB) still exercises real growable-buffer reallocation
        // without paying that cost.
        const input = try genCss(testing.allocator, 2_000);
        defer testing.allocator.free(input);
        try testing.expect(input.len > 100_000);

        const out = try cssMinify(testing.allocator, input, null);
        defer testing.allocator.free(out);

        try testing.expect(out.len > 0);
        try testing.expect(out.len < input.len);
        try testing.expect(std.mem.indexOf(u8, out, "/* rule") == null);
    }

    test "performance: large HTML input minifies without error" {
        const input = try genHtml(testing.allocator, 2_000);
        defer testing.allocator.free(input);
        try testing.expect(input.len > 100_000);

        const out = try html(testing.allocator, input, null);
        defer testing.allocator.free(out);

        try testing.expect(out.len > 0);
        try testing.expect(out.len < input.len);
    }

    test "performance: large JS input minifies without error" {
        const input = try genJs(testing.allocator, 2_000);
        defer testing.allocator.free(input);
        try testing.expect(input.len > 100_000);

        const out = try js(testing.allocator, input, null);
        defer testing.allocator.free(out);

        try testing.expect(out.len > 0);
        try testing.expect(out.len < input.len);
        try testing.expect(std.mem.indexOf(u8, out, "// adds") == null);
    }
};

test {
    std.testing.refAllDecls(css_html_tests);
    std.testing.refAllDecls(js_tokenizer_tests);
    std.testing.refAllDecls(js_tests);
    std.testing.refAllDecls(js_scope_tests);
    std.testing.refAllDecls(js_mangle_tests);
    std.testing.refAllDecls(js_parser_tests);
    std.testing.refAllDecls(js_printer_tests);
    std.testing.refAllDecls(svg_tests);
    std.testing.refAllDecls(performance_tests);
}
