//! Generates `src/api_tiers.zig`: which of the symbols this package binds are flecs's
//! public API and which are its insides.
//!
//! ## Why this exists
//!
//! zecs binds every symbol the vendored header exports, and the ABI guard fails the
//! build on the first one that is missing. That completeness is the package's whole
//! argument — but stated on its own it is misleading, because flecs's header exports
//! more than flecs's API. A hundred-odd of those symbols are the block allocator, the
//! sparse set, the hashmap and the poly machinery: real linked symbols, no stability
//! contract, renamed and reshaped between patch releases. A consumer reading "every
//! symbol flecs exports" has no way to tell which ones are safe to call.
//!
//! So the surface is partitioned, and the partition is *derived* rather than written
//! down. Three tiers, by the shape of the name — which is the only thing that carries
//! the distinction, because flecs marks every one of them `FLECS_API` alike:
//!
//!   * **public** — `ecs_*`, `Ecs*`, `Flecs*Import`: flecs's documented C API.
//!   * **macro-backed** — a name ending in `_`. In C nobody writes these: they are what
//!     a public macro expands to. `ecs_abort_` is the body of `ecs_abort`, and
//!     `FLECS_ID<T>ID_` is what `ecs_id(T)` expands to — `#define ecs_id(T)
//!     FLECS_ID##T##ID_`, libs/flecs/flecs.h:1039. Zig has no macros, so for the
//!     component-id globals this spelling IS the public spelling, and the typed layer
//!     uses them. They are as stable as the macro is.
//!   * **internal** — `flecs_*`. Bound because the guard requires every exported symbol
//!     to be bound or listed as deliberately unbound, and for no other reason. Nothing
//!     above the raw layer may call one, which is the check below.
//!
//! ## What this checks, beyond generating a list
//!
//! Every file in `src/` outside `src/c/` is scanned for a reference to an internal
//! name. One would mean the typed layer — the part with a stability contract of its
//! own — is standing on flecs's implementation, where a re-vendor can move the ground
//! without any signal at all. The scan runs in both modes, so the generated file cannot
//! record a claim that has stopped being true.
//!
//! ## Blind spots
//!
//! The declarations are found by reading `src/c/*.zig` as text, one line at a time: a
//! line beginning `pub extern fn`, `pub extern const` or `pub extern var`. A declaration
//! written any other way is invisible here — which is why `src/abi_check.zig` asserts,
//! against the compiler's own view of those modules, that the three lists account for
//! every extern it sees. The two disagreeing is a build failure.
//!
//! The usage scan reads code only: comments, string literals, character literals and
//! multi-line string literals are skipped, so that prose naming an internal function is
//! not a violation. The cost is the mirror image — a name reached through a string,
//! `@field(c.core, "flecs_balloc")`, is invisible to it, as is any other indirection.
//! Nothing in the package does that, and it is not something a text scan can be made to
//! catch.
//!
//! ## Usage
//!
//!     gen-api-tiers <src-dir> <out.zig>
//!     gen-api-tiers <src-dir> --check <existing.zig>
//!
//! `zig build api-tiers` does the first, `zig build api-tiers-check` the second.

const std = @import("std");
const process = std.process;

/// Which contract a bound name comes with. See the module doc for what decides.
const Tier = enum { public, macro_backed, internal };

fn tierOf(name: []const u8) Tier {
    if (std.mem.startsWith(u8, name, "flecs_")) return .internal;
    if (std.mem.endsWith(u8, name, "_")) return .macro_backed;
    return .public;
}

/// Files under `src/` that are part of the raw layer rather than above it: `c.zig` is
/// the index of the declaration modules, and `api_tiers.zig` is this tool's own output.
/// Everything else in `src/` is scanned, the ABI guard and the generated manifest
/// included — they name internal symbols only inside string literals, which the scan
/// skips, so nothing has to be excused to keep them quiet.
const raw_layer = [_][]const u8{
    "api_tiers.zig",
    "c.zig",
};

pub fn main(init: process.Init.Minimal) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const args = try init.args.toSlice(arena);
    if (args.len != 3 and args.len != 4) return usage();

    const src_dir = args[1];
    const checking = std.mem.eql(u8, args[2], "--check");
    if (args.len == 4 and !checking) return usage();
    const target_path = if (checking) args[3] else args[2];

    const cwd: std.Io.Dir = .cwd();

    var tiers: [3]std.ArrayList([]const u8) = .{ .empty, .empty, .empty };
    const raw_dir = try std.fs.path.join(arena, &.{ src_dir, "c" });
    for (try listZig(arena, io, cwd, raw_dir)) |name| {
        const path = try std.fs.path.join(arena, &.{ raw_dir, name });
        const text = try cwd.readFileAlloc(io, path, arena, .limited(16 << 20));
        try collect(arena, text, &tiers);
    }
    for (&tiers) |*list| std.mem.sort([]const u8, list.items, {}, lessThan);

    try refuseInternalUse(arena, io, cwd, src_dir, tiers[@intFromEnum(Tier.internal)].items);

    var out: std.ArrayList(u8) = .empty;
    try render(arena, &out, tiers);

    if (!checking) {
        try cwd.writeFile(io, .{ .sub_path = target_path, .data = out.items });
        return;
    }

    const existing = cwd.readFileAlloc(io, target_path, arena, .limited(16 << 20)) catch |err| {
        std.debug.print(
            "gen-api-tiers: cannot read {s}: {s}\nRun `zig build api-tiers`.\n",
            .{ target_path, @errorName(err) },
        );
        process.exit(1);
    };
    if (!std.mem.eql(u8, existing, out.items)) {
        std.debug.print(
            \\gen-api-tiers: {s} is stale.
            \\
            \\It no longer matches what src/c/ declares. Run `zig build api-tiers` to
            \\regenerate it. Anything that moved between tiers is worth reading twice:
            \\a name that became internal is one the typed layer may no longer call.
            \\
        , .{target_path});
        process.exit(1);
    }
}

fn usage() error{BadUsage} {
    std.debug.print(
        \\usage: gen-api-tiers <src-dir> <out.zig>
        \\       gen-api-tiers <src-dir> --check <existing.zig>
        \\
    , .{});
    return error.BadUsage;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The `.zig` files directly inside `dir`, sorted, so that the generated file does not
/// depend on the order a filesystem happens to hand them back in.
fn listZig(
    arena: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    dir: []const u8,
) ![]const []const u8 {
    var handle = try cwd.openDir(io, dir, .{ .iterate = true });
    defer handle.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = handle.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}

/// Every `pub extern` declaration in one raw-layer module, sorted into its tier.
fn collect(
    arena: std.mem.Allocator,
    text: []const u8,
    tiers: *[3]std.ArrayList([]const u8),
) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const rest = stripPrefix(line, "pub extern ") orelse continue;
        const decl = stripPrefix(rest, "fn ") orelse
            stripPrefix(rest, "const ") orelse
            stripPrefix(rest, "threadlocal var ") orelse
            stripPrefix(rest, "var ") orelse continue;
        const name = identifier(decl) orelse continue;
        try tiers[@intFromEnum(tierOf(name))].append(arena, name);
    }
}

/// The gate this tool exists for. `src/c/` is where an internal symbol may be named;
/// anywhere else in `src/` it means the typed layer has taken a dependency on flecs's
/// implementation, and a re-vendor can move that without a word.
fn refuseInternalUse(
    arena: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    src_dir: []const u8,
    internal: []const []const u8,
) !void {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (internal) |n| try names.put(arena, n, {});

    var found: usize = 0;
    for (try listZig(arena, io, cwd, src_dir)) |name| {
        for (raw_layer) |skip| {
            if (std.mem.eql(u8, name, skip)) break;
        } else {
            const path = try std.fs.path.join(arena, &.{ src_dir, name });
            const text = try cwd.readFileAlloc(io, path, arena, .limited(16 << 20));
            // Relative, because the absolute path is where this tree happens to sit
            // today and says nothing about the defect.
            const display = try std.fmt.allocPrint(arena, "src/{s}", .{name});
            found += scanForNames(text, display, names);
        }
    }
    if (found == 0) return;

    std.debug.print(
        \\
        \\gen-api-tiers: the typed layer calls {d} of flecs's internal symbols.
        \\
        \\Those carry no stability contract: they are flecs's own allocators, containers
        \\and poly machinery, and a re-vendor can rename or reshape one without a note.
        \\A typed API standing on them is one whose next upstream bump breaks somewhere
        \\the ABI guard cannot see. Reach the same result through the public API, or —
        \\if flecs genuinely exposes no other way — say so where it is called and add the
        \\name to the exception this message will need.
        \\
    , .{found});
    process.exit(1);
}

/// Every whole-word occurrence of one of `names` in `text`, in code: comments, string
/// literals and character literals are skipped, so that prose naming an internal
/// function — or the ABI guard's own list of exceptions, which names two of them as
/// data — is not read as a call. Prints each; returns how many there were.
fn scanForNames(
    text: []const u8,
    display: []const u8,
    names: std.StringHashMapUnmanaged(void),
) usize {
    var found: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "\\\\")) continue;

        var i: usize = 0;
        while (i < line.len) {
            const ch = line[i];
            if (ch == '/' and i + 1 < line.len and line[i + 1] == '/') break;
            if (ch == '"' or ch == '\'') {
                i = endOfLiteral(line, i);
                continue;
            }
            if (!isWordChar(ch)) {
                i += 1;
                continue;
            }
            const start = i;
            while (i < line.len and isWordChar(line[i])) i += 1;
            const word = line[start..i];
            if (names.contains(word)) {
                std.debug.print("  {s}:{d}: {s}\n", .{ display, line_no, word });
                found += 1;
            }
        }
    }
    return found;
}

/// One past the closing quote of the literal starting at `start`, or the end of the
/// line if it does not close on this one.
fn endOfLiteral(line: []const u8, start: usize) usize {
    const quote = line[start];
    var i = start + 1;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == quote) return i + 1;
    }
    return line.len;
}

fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn stripPrefix(text: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    return text[prefix.len..];
}

fn identifier(text: []const u8) ?[]const u8 {
    var end: usize = 0;
    while (end < text.len and isWordChar(text[end])) end += 1;
    if (end == 0) return null;
    return text[0..end];
}

fn render(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tiers: [3]std.ArrayList([]const u8),
) !void {
    const public = tiers[@intFromEnum(Tier.public)].items;
    const macro_backed = tiers[@intFromEnum(Tier.macro_backed)].items;
    const internal = tiers[@intFromEnum(Tier.internal)].items;

    try out.print(arena,
        \\//! Which of the symbols zecs binds are flecs's API, and which are its insides.
        \\//!
        \\//! GENERATED FILE — do not edit. Regenerate with `zig build api-tiers`;
        \\//! `zig build api-tiers-check` fails if it has gone stale, and CI runs it.
        \\//!
        \\//! zecs binds every symbol the vendored header exports. flecs's header exports
        \\//! more than flecs's API, and marks all of it `FLECS_API` alike, so the tier is
        \\//! read off the shape of the name — see `tools/gen_api_tiers.zig` for the rule,
        \\//! what it is derived from, and what it cannot see.
        \\//!
        \\//! | tier | count | what it is |
        \\//! |---|---|---|
        \\//! | `public` | {d} | flecs's documented C API. |
        \\//! | `macro_backed` | {d} | what a public macro expands to. `ecs_id(T)` is `FLECS_ID<T>ID_`, and Zig has no macros, so for the component-id globals this spelling is the public one. |
        \\//! | `internal` | {d} | flecs's own implementation. No stability contract. Bound for completeness; `zig build api-tiers-check` fails if anything outside `src/c/` calls one. |
        \\//!
        \\//! `src/abi_check.zig` asserts these lists account for every extern the compiler
        \\//! sees in `src/c/`, which is what makes the counts above measurements rather
        \\//! than the reach of a text scan.
        \\
        \\
    , .{ public.len, macro_backed.len, internal.len });

    try renderList(arena, out, "public", "flecs's documented C API.", public);
    try out.appendSlice(arena, "\n");
    try renderList(
        arena,
        out,
        "macro_backed",
        "Symbols a public macro expands to, which in Zig must be named directly.",
        macro_backed,
    );
    try out.appendSlice(arena, "\n");
    try renderList(
        arena,
        out,
        "internal",
        "flecs's implementation. No stability contract; nothing outside `src/c/` may call one.",
        internal,
    );
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
