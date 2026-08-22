//! Build script for the minify.zig project.
//!
//! `zig build` (compile),
//! `zig build run` (compile and run),
//! `zig build test` (run unit tests),
//! `zig build zip` (zip the source files with powershell).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("minify.zig", .{
        .root_source_file = b.path("src/minify.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = mod;

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    {
        // Zip the source files with Powershell `zig build zip`.
        const zip_output_name = "minifyzig.zip";
        const zip_includes = [_][]const u8{
            "build.zig",
            "build.zig.zon",
            "*.md",
            "src",
        };
        var includes_literal: std.ArrayList(u8) = .empty;
        includes_literal.appendSlice(b.allocator, "@(") catch @panic("OOM");
        for (zip_includes, 0..) |item, i| {
            if (i != 0) includes_literal.appendSlice(b.allocator, ",") catch @panic("OOM");
            includes_literal.appendSlice(b.allocator, "\"") catch @panic("OOM");
            includes_literal.appendSlice(b.allocator, item) catch @panic("OOM");
            includes_literal.appendSlice(b.allocator, "\"") catch @panic("OOM");
        }
        includes_literal.appendSlice(b.allocator, ")") catch @panic("OOM");
        const ps_script = b.fmt(
            \\$ErrorActionPreference = "Stop"; $OutputZip = "{s}"; $Include = {s}; $resolvedPaths = @()
            \\foreach ($pattern in $Include) {{
            \\  if ($pattern -match '[\*\?]') {{
            \\    $matches = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue
            \\    if (-not $matches -or $matches.Count -eq 0) {{ throw "Include pattern '$pattern' matched no files or folders." }}
            \\    $resolvedPaths += $matches.FullName
            \\  }} else {{
            \\    if (-not (Test-Path -Path $pattern)) {{ throw "Include entry '$pattern' does not exist." }}
            \\    $resolvedPaths += (Resolve-Path -Path $pattern).Path
            \\  }}
            \\}}
            \\$resolvedPaths = $resolvedPaths | Select-Object -Unique
            \\Write-Host "Packaging $($resolvedPaths.Count) item(s) into $OutputZip"; foreach ($p in $resolvedPaths) {{ Write-Host "  - $p" }}
            \\if (Test-Path -Path $OutputZip) {{ Remove-Item -Path $OutputZip -Force }}
            \\Compress-Archive -Path $resolvedPaths -DestinationPath $OutputZip -Force; Write-Host "Wrote $OutputZip"
        , .{ zip_output_name, includes_literal.items });

        const zip_cmd = b.addSystemCommand(&.{
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            ps_script,
        });
        zip_cmd.setCwd(b.path("."));
        const zip_step = b.step("zip", "Package project files into " ++ zip_output_name);
        zip_step.dependOn(&zip_cmd.step);
    }

}