//! Generates `src/abi_manifest.zig`: the list of every symbol the vendored flecs
//! header exports.
//!
//! ## Why this exists
//!
//! `src/abi_check.zig` compares the hand-written externs in `src/c.zig` against a
//! `@cImport` of the real header, declaration by declaration. That catches drift in
//! anything `c.zig` declares — but it cannot, on its own, catch an *omission*: a
//! function flecs exports that nobody ever bound is invisible to a sweep that only
//! walks `c.zig`.
//!
//! The obvious fix is to sweep the imported header in the other direction. It does not
//! work. translate-c renders unrepresentable macros as `@compileError` declarations,
//! and there is no way to ask "is this declaration usable?" without evaluating it —
//! `@typeInfo(@TypeOf(@field(h, name)))` on one of those fails the build for a reason
//! that has nothing to do with zecs. Worse, the failure is not confined to declarations
//! that are themselves `@compileError`: `FLECS_VERSION` is a perfectly ordinary
//! constant whose initializer reaches one, and `ecs_os_thread_self` is an `inline fn`
//! whose *return type expression* does not compile. A skip list chasing those is a list
//! of everything translate-c happens to fail at this month.
//!
//! So the direction is inverted once more: this tool reads translate-c's output — where
//! an exported symbol is always, unambiguously, a line beginning `pub extern fn`,
//! `pub extern const` or `pub extern var` — and writes the names into a Zig file that
//! `abi_check.zig` iterates with `@hasDecl`, which evaluates nothing.
//!
//! ## Usage
//!
//!     gen-abi-manifest <translated.zig> <out.zig>
//!     gen-abi-manifest <translated.zig> --check <existing.zig>
//!
//! `zig build abi-manifest` does the first, `zig build abi-manifest-check` the second.

const std = @import("std");
const process = std.process;

/// Symbols with any of these prefixes belong to flecs. Everything else in the
/// translated header came from libc.
///
/// `Flecs` without an underscore is the module-import entry points (`FlecsMetaImport`
/// and friends), which `ECS_IMPORT` calls; `FLECS_` is almost entirely macros, but the
/// component-id globals `FLECS_ID<name>ID_` that `ecs_id(T)` expands to are real
/// exported variables and belong here.
const flecs_prefixes = [_][]const u8{ "ecs_", "flecs_", "Ecs", "ECS_", "FLECS_", "Flecs" };

pub fn main(init: process.Init.Minimal) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const args = try init.args.toSlice(arena);
    if (args.len != 3 and args.len != 4) return usage();

    const translated_path = args[1];
    const checking = std.mem.eql(u8, args[2], "--check");
    if (args.len == 4 and !checking) return usage();
    const target_path = if (checking) args[3] else args[2];

    const cwd: std.Io.Dir = .cwd();
    const translated = try cwd.readFileAlloc(io, translated_path, arena, .limited(64 << 20));

    var functions: std.ArrayList([]const u8) = .empty;
    var variables: std.ArrayList([]const u8) = .empty;
    try collect(arena, translated, &functions, &variables);

    std.mem.sort([]const u8, functions.items, {}, lessThan);
    std.mem.sort([]const u8, variables.items, {}, lessThan);

    var out: std.ArrayList(u8) = .empty;
    try render(arena, &out, functions.items, variables.items);

    if (!checking) {
        try cwd.writeFile(io, .{ .sub_path = target_path, .data = out.items });
        return;
    }

    const existing = cwd.readFileAlloc(io, target_path, arena, .limited(64 << 20)) catch |err| {
        std.debug.print(
            "gen-abi-manifest: cannot read {s}: {s}\nRun `zig build abi-manifest`.\n",
            .{ target_path, @errorName(err) },
        );
        process.exit(1);
    };
    if (!std.mem.eql(u8, existing, out.items)) {
        std.debug.print(
            \\gen-abi-manifest: {s} is stale.
            \\
            \\It no longer matches what the vendored header exports, which normally means
            \\flecs was re-vendored. Run `zig build abi-manifest` to regenerate it, then
            \\declare whatever appeared in src/c.zig — the ABI guard will name each one.
            \\
        , .{target_path});
        process.exit(1);
    }
}

fn usage() error{BadUsage} {
    std.debug.print(
        \\usage: gen-abi-manifest <translated.zig> <out.zig>
        \\       gen-abi-manifest <translated.zig> --check <existing.zig>
        \\
    , .{});
    return error.BadUsage;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn collect(
    arena: std.mem.Allocator,
    translated: []const u8,
    functions: *std.ArrayList([]const u8),
    variables: *std.ArrayList([]const u8),
) !void {
    var lines = std.mem.splitScalar(u8, translated, '\n');
    while (lines.next()) |line| {
        const rest = stripPrefix(line, "pub extern ") orelse continue;
        const is_fn = std.mem.startsWith(u8, rest, "fn ");
        const decl = stripPrefix(rest, "fn ") orelse
            stripPrefix(rest, "const ") orelse
            stripPrefix(rest, "var ") orelse continue;

        const name = identifier(decl) orelse continue;
        if (!isFlecs(name)) continue;
        try (if (is_fn) functions else variables).append(arena, name);
    }
}

fn stripPrefix(haystack: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, haystack, prefix)) return null;
    return haystack[prefix.len..];
}

fn identifier(text: []const u8) ?[]const u8 {
    var end: usize = 0;
    while (end < text.len) : (end += 1) {
        const ch = text[end];
        const ok = std.ascii.isAlphanumeric(ch) or ch == '_';
        if (!ok) break;
    }
    if (end == 0) return null;
    return text[0..end];
}

fn isFlecs(name: []const u8) bool {
    for (flecs_prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

fn render(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    functions: []const []const u8,
    variables: []const []const u8,
) !void {
    try out.appendSlice(arena,
        \\//! Every symbol the vendored flecs header exports.
        \\//!
        \\//! GENERATED FILE — do not edit. Regenerate with `zig build abi-manifest`;
        \\//! `zig build abi-manifest-check` fails if it has gone stale, and CI runs it.
        \\//!
        \\//! Generated from `libs/flecs/flecs.h` with every addon enabled, which is the only
        \\//! configuration whose preprocessor output contains them all. A build with a
        \\//! narrower addon set therefore declares a subset, and `src/abi_check.zig` skips
        \\//! any entry the current build's header does not have — that is what makes
        \\//! `-Daddons=minimal` a legal configuration rather than a wall of failures.
        \\//!
        \\//! `src/abi_check.zig` reads these names with `@hasDecl`, which evaluates nothing.
        \\//! That is the whole point: sweeping the imported header directly means touching
        \\//! declarations translate-c could not render, and failing the build over a macro
        \\//! nobody was ever going to bind.
        \\
        \\
    );

    try renderList(arena, out, "functions", "Exported functions.", functions);
    try out.appendSlice(arena, "\n");
    try renderList(arena, out, "variables", "Exported variables: the built-in entity ids, the id flags, the allocation " ++
        "counters, and the `ecs_id(T)` globals for flecs's own components.", variables);
}

fn renderList(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    doc: []const u8,
    items: []const []const u8,
) !void {
    try out.print(arena, "/// {s}\npub const {s} = [_][]const u8{{\n", .{ doc, name });
    for (items) |item| try out.print(arena, "    \"{s}\",\n", .{item});
    try out.appendSlice(arena, "};\n");
}
