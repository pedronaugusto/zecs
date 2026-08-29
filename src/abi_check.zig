//! Comptime cross-check: the hand-written externs in `c.zig` against the real flecs
//! header.
//!
//! `c.zig` is written by hand so the wrapper gets exactly the types it wants and the
//! shipped module never runs translate-c. The cost of hand-writing is drift, and
//! nothing in either compiler notices when this file's twin stops matching
//! `libs/flecs/flecs.h`.
//!
//! This closes that by `@cImport`-ing the header — in a test only, so the shipped
//! module stays translate-c-free — and comparing the two namespaces declaration by
//! declaration. There is **no hand-written list of what to check**: every public
//! declaration in `c.zig` is discovered by reflection and compared with the header
//! declaration of the same name. A declaration that fits no category is a compile error
//! rather than a silent pass, so the check cannot quietly stop covering something.
//!
//! Pairing is by identity, because the raw layer's names are flecs's own: `ecs_iter_t`
//! is `ecs_iter_t` on both sides. (Sibling packages in this family need a name mangler
//! here; zecs needs none, which is one fewer thing to get wrong.)
//!
//! ## The other direction
//!
//! A function the header exports that `c.zig` never declared is invisible to a sweep
//! that only walks `c.zig`. Sweeping the *imported header* instead does not work:
//! translate-c renders unrepresentable macros as `@compileError` declarations, and
//! asking whether a declaration is usable means evaluating it. `src/abi_manifest.zig`
//! is generated from translate-c's output for that reason — see the header of
//! `tools/gen_abi_manifest.zig` — and is read here with `@hasDecl`, which evaluates
//! nothing. `src/abi_todo.zig` holds what is not bound yet; it is empty, which is what
//! makes "every symbol flecs exports is declared" a statement the compiler checks rather
//! than a sentence in a README — and it is what stops a re-vendor from adding API nobody
//! noticed.
//!
//! ## What it does not catch
//!
//! translate-c renders every C pointer as `[*c]T`, while `c.zig` writes the pointer it
//! means (`*T`, `?*const T`, `[*]T`). Pointee types are therefore compared only by size
//! and alignment: a `float *` declared here as `*i32` passes. `tests/behaviour.zig`
//! covers that residue by driving the declarations and checking real answers.
//!
//! It also compares this build's externs against this build's *header*, not against the
//! *library*. In this package those cannot disagree: one `build.zig` compiles the C and
//! hands the very same macro list to the module this file lives in.
//!
//! And a check that always passes is worth nothing, so `ci/mutate.sh` introduces one
//! deliberate defect at a time — a field swap, a widened parameter, a deleted
//! declaration — and asserts the build fails each time. It runs in CI.

const std = @import("std");
const options = @import("zecs_options");

const c = @import("c.zig");
const manifest = @import("abi_manifest.zig");
const todo = @import("abi_todo.zig");

const h = @cImport({
    @cInclude("flecs.h");
});

//=============================================================================
// Exceptions, each with its reason and its replacement
//=============================================================================

/// Declarations in `c.zig` whose header counterpart translate-c cannot render, so
/// nothing can be compared against. Every entry names what covers it instead — an
/// exception with no replacement check is a hole, not an exception.
const unrepresentable = [_]struct { name: []const u8, covered_by: []const u8 }{
    // flecs forward-declares these four and never defines them, so `struct ecs_query_op_t`
    // has no typedef and translate-c names the anonymous forward declaration itself. There
    // is no counterpart to pair with — and nothing to pair, since an incomplete type has
    // no layout on either side. Declaring them here rather than spelling the fields that
    // point at them `?*anyopaque` is what keeps those fields saying which type they mean.
    .{
        .name = "ecs_query_op_t",
        .covered_by = "opaque on both sides; the fields that point at it are compared by " ++
            "pointer size, which is all an incomplete type has.",
    },
    .{
        .name = "ecs_query_var_t",
        .covered_by = "opaque on both sides; see ecs_query_op_t.",
    },
    .{
        .name = "ecs_query_op_ctx_t",
        .covered_by = "opaque on both sides; see ecs_query_op_t.",
    },
    .{
        .name = "ecs_event_id_record_t",
        .covered_by = "opaque on both sides; see ecs_query_op_t.",
    },
    .{
        .name = "ecs_termset_t",
        .covered_by = "flecs.h builds this type's name by pasting FLECS_TERM_COUNT_MAX " ++
            "into `ecs_flags<N>_t`, which translate-c leaves as a call to a macro it " ++
            "could not translate. The width is checked where it actually matters: it " ++
            "sizes four fields of ecs_iter_t, and that struct is compared field by field.",
    },
};

/// Declarations flecs replaces with a same-named *macro* when an addon is switched off.
///
/// There is no symbol behind a macro to compare a signature against, and — the reason
/// this is a list rather than a rule — translate-c cannot always render one either.
/// `ecs_deprecated_` becomes `#define ecs_deprecated_(file, line, msg)` with an empty
/// body that translate-c gives up on, so the guard must not so much as *touch* the
/// header's version of it. Detecting that from Zig is impossible: asking what a
/// declaration is means evaluating it.
///
/// Each entry names the option that decides which of the two this build has.
const macro_when_disabled = [_]struct { name: []const u8, enabled: bool }{
    .{ .name = "ecs_deprecated_", .enabled = options.addon_log },
    .{ .name = "ecs_log_push_", .enabled = options.addon_log },
    .{ .name = "ecs_log_pop_", .enabled = options.addon_log },
    .{ .name = "ecs_should_log", .enabled = options.addon_log },
    .{ .name = "ecs_strerror", .enabled = options.addon_log },
    .{ .name = "flecs_check_exclusive_world_access_read", .enabled = options.addon_exclusive_access },
    .{ .name = "flecs_check_exclusive_world_access_write", .enabled = options.addon_exclusive_access },
};

fn isMacroInThisBuild(comptime name: []const u8) bool {
    for (macro_when_disabled) |m| {
        if (std.mem.eql(u8, m.name, name)) return !m.enabled;
    }
    return false;
}

fn isUnrepresentable(comptime name: []const u8) bool {
    for (unrepresentable) |u| if (std.mem.eql(u8, u.name, name)) return true;
    return false;
}

/// True when the build asked for every addon, which is the only configuration whose
/// header declares every symbol in the manifest. The coverage assertions are exact
/// there and necessarily loose everywhere else.
const every_addon = blk: {
    var all = true;
    for (@typeInfo(options).@"struct".decls) |d| {
        if (!std.mem.startsWith(u8, d.name, "addon_")) continue;
        if (!@field(options, d.name)) all = false;
    }
    break :blk all;
};

//=============================================================================
// Comparison primitives
//
// Every failure is a compile error naming both sides, because a build that cannot say
// which declaration drifted is a guard that costs more to read than the drift it found.
//=============================================================================

fn fail(comptime msg: []const u8) noreturn {
    @compileError("zecs ABI drift: " ++ msg);
}

fn num(comptime v: anytype) []const u8 {
    return std.fmt.comptimePrint("{d}", .{v});
}

fn theirs(comptime name: []const u8, comptime because: []const u8) type {
    if (!@hasDecl(h, name)) {
        fail("`" ++ because ++ "` in src/c.zig expects `" ++ name ++
            "` in flecs.h, which does not declare it");
    }
    return @TypeOf(@field(h, name));
}

fn sameSizeAndAlign(
    comptime what: []const u8,
    comptime Ours: type,
    comptime Theirs: type,
) void {
    if (@sizeOf(Ours) != @sizeOf(Theirs)) {
        fail(what ++ " is " ++ num(@sizeOf(Ours)) ++ " bytes in src/c.zig but " ++
            num(@sizeOf(Theirs)) ++ " in flecs.h");
    }
    if (@alignOf(Ours) != @alignOf(Theirs)) {
        fail(what ++ " has alignment " ++ num(@alignOf(Ours)) ++ " in src/c.zig but " ++
            num(@alignOf(Theirs)) ++ " in flecs.h");
    }
}

/// Signedness on top of width. An `i32` declared where the header has `u32` has the
/// same size and alignment and a different meaning at every comparison and cast.
fn sameScalar(comptime what: []const u8, comptime Ours: type, comptime Theirs: type) void {
    sameSizeAndAlign(what, Ours, Theirs);
    const ours = @typeInfo(Ours);
    const them = @typeInfo(Theirs);
    if (ours == .int and them == .int and ours.int.signedness != them.int.signedness) {
        fail(what ++ " is " ++ @typeName(Ours) ++ " in src/c.zig but " ++
            @typeName(Theirs) ++ " in flecs.h");
    }
    if ((ours == .float) != (them == .float)) {
        fail(what ++ " is " ++ @typeName(Ours) ++ " in src/c.zig but " ++
            @typeName(Theirs) ++ " in flecs.h");
    }
}

/// Compares two function types by the only things translate-c preserves: how many
/// parameters there are and how each one is passed.
fn checkFnType(comptime what: []const u8, comptime Ours: type, comptime Theirs: type) void {
    const ours = @typeInfo(Ours).@"fn";
    const them = switch (@typeInfo(Theirs)) {
        .@"fn" => |f| f,
        else => fail(what ++ " is a function in src/c.zig but not in flecs.h"),
    };

    if (ours.params.len != them.params.len) {
        fail(what ++ " takes " ++ num(ours.params.len) ++ " parameters in src/c.zig but " ++
            num(them.params.len) ++ " in flecs.h");
    }
    if (ours.is_var_args != them.is_var_args) {
        fail(what ++ " disagrees with flecs.h about being variadic");
    }

    inline for (ours.params, them.params, 0..) |op, tp, i| {
        const OP = op.type orelse fail(what ++ " has an untyped parameter in src/c.zig");
        const TP = tp.type orelse fail(what ++ " has an untyped parameter in flecs.h");
        sameScalar(what ++ " parameter " ++ num(i), OP, TP);
    }

    const OR = ours.return_type orelse fail(what ++ " has no return type in src/c.zig");
    const TR = them.return_type orelse fail(what ++ " has no return type in flecs.h");
    sameScalar(what ++ " return value", OR, TR);
}

/// Struct layout, compared field by NAME rather than by position.
///
/// This is the distinction that makes the check worth having. Two same-sized adjacent
/// fields swapping places leaves the *sequence* of offsets identical, so a positional
/// comparison — or a digest folded over offsets alone — passes a swap that silently
/// reinterprets both fields. Pairing each name with its own offset is what catches it.
fn checkStructLayout(
    comptime what: []const u8,
    comptime Ours: type,
    comptime Theirs: type,
) usize {
    sameSizeAndAlign(what, Ours, Theirs);

    const ours = @typeInfo(Ours).@"struct";
    const them = switch (@typeInfo(Theirs)) {
        .@"struct" => |s| s,
        else => fail(what ++ " is a struct in src/c.zig but not in flecs.h"),
    };

    if (ours.fields.len != them.fields.len) {
        fail(what ++ " has " ++ num(ours.fields.len) ++ " fields in src/c.zig but " ++
            num(them.fields.len) ++ " in flecs.h");
    }

    inline for (ours.fields) |f| {
        if (!@hasField(Theirs, f.name)) {
            fail(what ++ " has field `" ++ f.name ++ "` in src/c.zig, which flecs.h does not");
        }
        if (@offsetOf(Ours, f.name) != @offsetOf(Theirs, f.name)) {
            fail(what ++ "." ++ f.name ++ " is at byte " ++ num(@offsetOf(Ours, f.name)) ++
                " in src/c.zig but " ++ num(@offsetOf(Theirs, f.name)) ++ " in flecs.h");
        }
        sameScalar(what ++ "." ++ f.name, f.type, @FieldType(Theirs, f.name));
    }
    return ours.fields.len;
}

/// Union layout. Every member starts at zero, so there are no offsets to compare; what
/// is left is the overall size and alignment and each member's own width.
fn checkUnionLayout(
    comptime what: []const u8,
    comptime Ours: type,
    comptime Theirs: type,
) usize {
    sameSizeAndAlign(what, Ours, Theirs);

    const ours = @typeInfo(Ours).@"union";
    const them = switch (@typeInfo(Theirs)) {
        .@"union" => |u| u,
        else => fail(what ++ " is a union in src/c.zig but not in flecs.h"),
    };

    if (ours.fields.len != them.fields.len) {
        fail(what ++ " has " ++ num(ours.fields.len) ++ " members in src/c.zig but " ++
            num(them.fields.len) ++ " in flecs.h");
    }

    inline for (ours.fields) |f| {
        if (!@hasField(Theirs, f.name)) {
            fail(what ++ " has member `" ++ f.name ++ "` in src/c.zig, which flecs.h does not");
        }
        sameScalar(what ++ "." ++ f.name, f.type, @FieldType(Theirs, f.name));
    }
    return ours.fields.len;
}

/// Whether a declaration's value is known at compile time.
///
/// This separates the two kinds of constant that look identical through reflection: a
/// C macro, which translate-c turns into a comptime value that can be compared exactly,
/// and an `extern const`, whose value only exists once the program is linked and which
/// can therefore only be compared by type. flecs has many of both — `EcsSelf` is a
/// macro, `EcsChildOf` is a linked-in entity id — and treating one as the other either
/// fails to compile or silently checks nothing.
fn isComptimeKnown(comptime namespace: type, comptime name: []const u8) bool {
    return @typeInfo(@TypeOf(.{@field(namespace, name)})).@"struct".fields[0].is_comptime;
}

//=============================================================================
// The forward sweep: everything src/c.zig declares
//=============================================================================

const Counts = struct {
    types: usize = 0,
    functions: usize = 0,
    /// Macro constants, compared by value.
    constants: usize = 0,
    /// `extern const`/`extern var`, compared by type.
    variables: usize = 0,
    fields: usize = 0,
    /// Zig reimplementations of C macros. Compared by the parity tests below, which is
    /// the only way to compare a function against a macro.
    helpers: usize = 0,
    /// Declarations the header does not have because an addon is switched off.
    addon_absent: usize = 0,
    /// Entries of `unrepresentable` that were actually reached.
    excepted: usize = 0,
};

fn sweepOurs() Counts {
    @setEvalBranchQuota(200_000_000);
    comptime {
        var n = Counts{};

        // One pass per module in `c.zig`'s list. A name an EARLIER module already
        // declared is a re-export — every module re-exports the shared
        // declarations it takes so its own callers see one namespace — and it is
        // checked once, where it is declared. A module missing from that list is
        // a module this check does not cover, so the list is the thing
        // adding a module edits.
        for (c.modules, 0..) |m, mi| for (@typeInfo(m).@"struct".decls) |d| {
            var earlier = false;
            for (c.modules, 0..) |other, oi| {
                if (oi < mi and @hasDecl(other, d.name)) earlier = true;
            }
            if (earlier) continue;

            if (isUnrepresentable(d.name)) {
                n.excepted += 1;
                continue;
            }

            const Decl = @TypeOf(@field(m, d.name));
            const what = "`" ++ d.name ++ "`";

            // An addon that is switched off takes its declarations out of the header
            // while `c.zig` keeps declaring them: an unused extern emits no relocation,
            // so it still links, and a consumer that reaches for it gets a link error
            // naming the addon rather than a missing name in Zig. There is nothing to
            // compare against, so it is counted and skipped — and the test below
            // insists the count is zero when every addon is on, which is what keeps a
            // misspelling in `c.zig` from disappearing down this path.
            if (!@hasDecl(h, d.name) or isMacroInThisBuild(d.name)) {
                n.addon_absent += 1;
                continue;
            }

            // ---- types -----------------------------------------------------
            if (Decl == type) {
                const Ours = @field(m, d.name);
                if (theirs(d.name, d.name) != type) {
                    fail(what ++ " is a type in src/c.zig but a value in flecs.h");
                }
                const Theirs = @field(h, d.name);
                n.types += 1;

                switch (@typeInfo(Ours)) {
                    // An opaque handle has no layout on either side, which is the point
                    // of it. Existence and opacity are all there is to agree on.
                    .@"opaque" => if (@typeInfo(Theirs) != .@"opaque") {
                        fail(what ++ " is opaque in src/c.zig but not in flecs.h");
                    },
                    .@"struct" => |s| switch (s.layout) {
                        .@"extern" => n.fields += checkStructLayout(what, Ours, Theirs),
                        .@"packed" => fail(what ++ " is a packed struct. The raw layer " ++
                            "mirrors C types, and C has no packed struct; declare the " ++
                            "integer flecs declares and put the bit names one level up."),
                        .auto => fail(what ++ " has automatic layout, so it has no " ++
                            "defined ABI; declare it extern"),
                    },
                    .@"union" => |u| switch (u.layout) {
                        .@"extern" => n.fields += checkUnionLayout(what, Ours, Theirs),
                        else => fail(what ++ " is a union without extern layout, so it " ++
                            "has no defined ABI"),
                    },
                    .int, .float, .bool => sameScalar(what, Ours, Theirs),
                    // A callback typedef. flecs spells these as pointer-to-function
                    // typedefs, and translate-c makes every C function pointer optional,
                    // so both sides are `?*const fn`.
                    .optional => |o| {
                        sameSizeAndAlign(what, Ours, Theirs);
                        const OursPtr = @typeInfo(o.child);
                        if (OursPtr != .pointer or @typeInfo(OursPtr.pointer.child) != .@"fn") {
                            fail(what ++ " is an optional that is not a function pointer, " ++
                                "which this check does not know how to compare");
                        }
                        const TheirsInfo = @typeInfo(Theirs);
                        const TheirsPtr = if (TheirsInfo == .optional)
                            TheirsInfo.optional.child
                        else
                            Theirs;
                        checkFnType(what, OursPtr.pointer.child, @typeInfo(TheirsPtr).pointer.child);
                    },
                    .pointer => |p| {
                        sameSizeAndAlign(what, Ours, Theirs);
                        if (@typeInfo(p.child) == .@"fn") {
                            const TheirsInfo = @typeInfo(Theirs);
                            const TheirsPtr = if (TheirsInfo == .optional)
                                TheirsInfo.optional.child
                            else
                                Theirs;
                            checkFnType(what, p.child, @typeInfo(TheirsPtr).pointer.child);
                        }
                    },
                    .@"enum" => fail(what ++ " is a Zig enum. The raw layer mirrors a C " ++
                        "enum as the integer type it is compiled to, plus one constant " ++
                        "per enumerator, so that a value flecs invents at runtime is " ++
                        "representable; the real Zig enum belongs one level up."),
                    else => fail(what ++ " is a " ++ @tagName(@typeInfo(Ours)) ++
                        ", which this check does not know how to compare against the header"),
                }
                continue;
            }

            // ---- functions -------------------------------------------------
            if (@typeInfo(Decl) == .@"fn") {
                const cc = @typeInfo(Decl).@"fn".calling_convention;
                if (cc == .@"inline" or cc == .auto) {
                    // A Zig reimplementation of a C macro. Reflection cannot compare a
                    // function against a macro, so these are covered by the parity
                    // tests at the bottom of this file instead.
                    n.helpers += 1;
                    continue;
                }
                const Theirs = theirs(d.name, d.name);
                // When an addon is switched off, flecs sometimes replaces the function
                // with a same-named macro that expands to nothing — the exclusive-access
                // checks do exactly that. translate-c renders those as `inline fn`s
                // taking `anytype`, and there is no symbol behind them to compare a
                // signature against. Count it with the other addon-absent declarations.
                if (@typeInfo(Theirs).@"fn".calling_convention == .@"inline") {
                    n.addon_absent += 1;
                    continue;
                }
                checkFnType("function " ++ d.name, Decl, Theirs);
                n.functions += 1;
                continue;
            }

            // ---- values ----------------------------------------------------
            if (isComptimeKnown(m, d.name)) {
                if (!isComptimeKnown(h, d.name)) {
                    fail(what ++ " is a compile-time constant in src/c.zig but a linked-in " ++
                        "symbol in flecs.h. Declare it `extern const`: its value is not " ++
                        "knowable until the program is linked.");
                }
                const ours: i128 = @field(m, d.name);
                const them: i128 = @field(h, d.name);
                if (ours != them) {
                    fail("constant " ++ d.name ++ " is " ++ num(ours) ++ " in src/c.zig but " ++
                        num(them) ++ " in flecs.h");
                }
                n.constants += 1;
                continue;
            }

            if (isComptimeKnown(h, d.name)) {
                fail(what ++ " is declared extern in src/c.zig but flecs.h defines it as a " ++
                    "macro, so no such symbol is linked. Declare it `pub const`.");
            }
            sameScalar("variable " ++ d.name, Decl, theirs(d.name, d.name));
            n.variables += 1;
        };

        return n;
    }
}

//=============================================================================
// The reverse sweep: everything flecs exports
//=============================================================================

const Coverage = struct {
    declared: usize = 0,
    /// Not in this build's header because an addon is switched off.
    addon_absent: usize = 0,
    /// Listed in `abi_todo.zig`: exported, not bound yet.
    pending: usize = 0,
};

const Kind = enum { function, variable };

fn sweepTheirs() Coverage {
    @setEvalBranchQuota(200_000_000);
    comptime {
        var n = Coverage{};
        for (manifest.functions) |name| coverOne(.function, name, &n);
        for (manifest.variables) |name| coverOne(.variable, name, &n);
        return n;
    }
}

fn coverOne(comptime kind: Kind, comptime name: []const u8, n: *Coverage) void {
    // Which module declares it, if any. Searching the list rather than one file
    // is what keeps this sweep honest after the split: a name is bound if some
    // module binds it, and a module missing from `c.modules` is a module this
    // does not see.
    comptime var found = false;
    inline for (c.modules) |m| {
        if (@hasDecl(m, name)) found = true;
    }
    if (found) {
        const c_home = comptime blk: {
            for (c.modules) |m| {
                if (@hasDecl(m, name)) break :blk m;
            }
            unreachable;
        };
        if (isPending(name)) {
            fail("`" ++ name ++ "` is listed in src/abi_todo.zig but src/c.zig declares " ++
                "it. Delete the line: that list is what is left to bind, and an entry " ++
                "that is already done makes it lie about how much is.");
        }
        // The name existing is not enough. flecs exports a function called
        // `ecs_id_is_pair` *and* defines a macro called `ECS_IS_PAIR`, and it would be
        // easy to satisfy this sweep with a Zig rewrite of the macro under the
        // function's name — leaving the real symbol unbound behind a declaration that
        // looks like it. So the kind is checked too.
        const Decl = @TypeOf(@field(c_home, name));
        switch (kind) {
            .function => {
                if (@typeInfo(Decl) != .@"fn") {
                    fail("flecs.h exports `" ++ name ++ "` as a function, but src/c.zig " ++
                        "declares that name as something else");
                }
                const cc = @typeInfo(Decl).@"fn".calling_convention;
                if (cc == .@"inline" or cc == .auto) {
                    fail("`" ++ name ++ "` is a Zig function in src/c.zig, but flecs " ++
                        "exports a symbol of that name. Declare the extern; if a macro " ++
                        "of a similar name also needs rewriting, give it the macro's " ++
                        "own name.");
                }
            },
            .variable => {
                if (@typeInfo(Decl) == .@"fn" or Decl == type) {
                    fail("flecs.h exports `" ++ name ++ "` as a variable, but src/c.zig " ++
                        "declares that name as something else");
                }
                if (isComptimeKnown(c_home, name)) {
                    fail("`" ++ name ++ "` is a compile-time constant in src/c.zig, but " ++
                        "flecs links a symbol of that name whose value it decides at " ++
                        "runtime. Declare it `extern const`.");
                }
            },
        }
        n.declared += 1;
        return;
    }
    if (!@hasDecl(h, name)) {
        n.addon_absent += 1;
        return;
    }
    if (isPending(name)) {
        n.pending += 1;
        return;
    }
    fail("flecs.h exports `" ++ name ++ "` and src/c.zig does not declare it. Bind it, " ++
        "or — if it is genuinely not wanted — say so by adding it to src/abi_todo.zig.");
}

// `abi_todo.zig` is sorted, which `isPending` depends on. Checking the precondition
// rather than trusting it is not pedantry: an entry inserted out of order is invisible
// to a binary search, and an invisible to-do entry is exactly the state where the guard
// stops noticing that something is unbound.
comptime {
    @setEvalBranchQuota(2_000_000);
    for (todo.not_yet_declared, 0..) |name, i| {
        if (i == 0) continue;
        switch (std.mem.order(u8, todo.not_yet_declared[i - 1], name)) {
            .lt => {},
            .eq => fail("src/abi_todo.zig lists `" ++ name ++ "` twice"),
            .gt => fail("src/abi_todo.zig is out of order at `" ++ name ++ "`, which " ++
                "follows `" ++ todo.not_yet_declared[i - 1] ++ "`. It is binary-searched, " ++
                "so an entry in the wrong place is an entry nothing checks. Sort it " ++
                "byte-wise — uppercase before lowercase."),
        }
    }
}

/// `abi_todo.zig` is sorted, so this is a binary search: the list starts out nearly as
/// long as the manifest, and a linear scan per name is a million comptime comparisons.
fn isPending(comptime name: []const u8) bool {
    comptime {
        var lo: usize = 0;
        var hi: usize = todo.not_yet_declared.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, todo.not_yet_declared[mid], name)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return true,
            }
        }
        return false;
    }
}

//=============================================================================
// The tests
//
// The comparisons above are compile errors, so reaching these bodies at all means they
// passed. What is left to assert is that they actually ran: a sweep that silently
// matched nothing would be indistinguishable from a sweep that matched everything.
//=============================================================================

test "ABI: src/c.zig agrees with flecs.h" {
    const ours = comptime sweepOurs();

    // Floors rather than exact counts, because a build with addons switched off has
    // fewer of everything and this test runs in all of them. They are set close enough
    // to the real numbers that a sweep which quietly stopped matching would trip them.
    try std.testing.expect(ours.types >= 30);
    try std.testing.expect(ours.functions >= 100);
    try std.testing.expect(ours.constants >= 30);
    try std.testing.expect(ours.variables >= 20);
    try std.testing.expect(ours.fields >= 400);
    try std.testing.expect(ours.helpers >= 11);

    // Every exception is reached, so one that stops applying after a re-vendor is
    // noticed rather than left as a permanent hole.
    try std.testing.expectEqual(unrepresentable.len, ours.excepted);

    // With every addon on there is nothing the header can be missing, so a declaration
    // in `c.zig` that has no counterpart is a misspelling, not a configuration — and
    // the counts stop being floors and become the real shape of flecs.
    if (comptime every_addon) {
        try std.testing.expectEqual(@as(usize, 0), ours.addon_absent);
        // Set just under what flecs 4.1.6 actually has — 267 types, 710 functions, 318
        // variables and 902 compared fields — so that a sweep which stopped covering a
        // whole category fails here rather than passing quietly.
        try std.testing.expect(ours.types >= 250);
        try std.testing.expect(ours.functions >= 700);
        try std.testing.expect(ours.variables >= 310);
        try std.testing.expect(ours.fields >= 880);
    }
}

test "ABI: src/c.zig covers what flecs exports" {
    const coverage = comptime sweepTheirs();

    // Nothing may be lost: every name in the manifest is bound, absent because an addon
    // is off, or explicitly pending. There is no fourth outcome.
    try std.testing.expectEqual(
        manifest.functions.len + manifest.variables.len,
        coverage.declared + coverage.addon_absent + coverage.pending,
    );

    // The claim this package makes about itself, stated as an assertion rather than a
    // sentence in a README: with every addon on, every symbol flecs exports is declared.
    if (comptime every_addon) {
        try std.testing.expectEqual(@as(usize, 0), coverage.addon_absent);
        try std.testing.expectEqual(@as(usize, 0), coverage.pending);
        try std.testing.expectEqual(
            manifest.functions.len + manifest.variables.len,
            coverage.declared,
        );
    }
}

test "ABI: the vendored flecs is the version UPSTREAM.md pins" {
    // Read out of the header the library was compiled from, so the pin recorded in
    // UPSTREAM.md and the code that actually compiled cannot drift apart. Bumping the
    // vendored copy without updating the docs fails here.
    try std.testing.expectEqual(@as(c_int, 4), h.FLECS_VERSION_MAJOR);
    try std.testing.expectEqual(@as(c_int, 1), h.FLECS_VERSION_MINOR);
    try std.testing.expectEqual(@as(c_int, 6), h.FLECS_VERSION_PATCH);
}

test "ABI: the header was preprocessed with the same checking level as the library" {
    // `build.zig` cannot undefine NDEBUG for this module, so a release build that asked
    // for flecs checks reads a header with NDEBUG still set. That is deliberate and
    // documented there; what has to hold is that the two macros every conditional field
    // in flecs.h is guarded by came out the same on both sides. Asserting it here is
    // what makes the argument checkable rather than a claim in a comment.
    switch (options.debug_checks) {
        .auto => unreachable, // resolved in build.zig
        .none => {
            try std.testing.expect(@hasDecl(h, "FLECS_NDEBUG"));
            try std.testing.expect(!@hasDecl(h, "FLECS_DEBUG"));
            try std.testing.expect(!@hasDecl(h, "FLECS_SANITIZE"));
        },
        .debug => {
            try std.testing.expect(@hasDecl(h, "FLECS_DEBUG"));
            try std.testing.expect(!@hasDecl(h, "FLECS_SANITIZE"));
        },
        .sanitize => {
            try std.testing.expect(@hasDecl(h, "FLECS_DEBUG"));
            try std.testing.expect(@hasDecl(h, "FLECS_SANITIZE"));
        },
    }
}

//=============================================================================
// Macro parity
//
// The handful of C macros `c.zig` rewrites as Zig functions are the one thing
// reflection cannot check: there is no signature to compare a function against. These
// call both sides on the same inputs instead. translate-c renders these particular
// macros as `inline fn`s, which is what makes the comparison possible at all.
//=============================================================================

test "ABI: the rewritten macros agree with the header's" {
    // Ids chosen to exercise the edges the arithmetic actually has: the low half at
    // full width, a value wide enough to reach the flag bits (where flecs's own macros
    // lose information, so agreement is the only correct assertion), and a generation
    // at its maximum, where the increment wraps.
    const ids = [_]c.core.ecs_entity_t{
        0,
        1,
        0xFFFF_FFFF,
        0x1234_5678,
        0x0000_FFFF_0000_0001,
        0x0FFF_FFFF_FFFF_FFFF,
        0xFFFF_FFFF_FFFF_FFFF,
    };

    for (ids) |a| {
        try std.testing.expectEqual(h.ecs_entity_t_lo(a), c.core.ecs_entity_t_lo(a));
        try std.testing.expectEqual(h.ecs_entity_t_hi(a), c.core.ecs_entity_t_hi(a));
        try std.testing.expectEqual(h.ECS_GENERATION(a), c.core.ECS_GENERATION(a));

        // ECS_GENERATION_INC is the one macro here with no comparable counterpart:
        // translate-c renders it as an expression mixing `c_int` and `u64`, which does
        // not compile in Zig at all. Its contract is small enough to assert directly —
        // bump bits 32..47, wrapping, and leave every other bit alone — which is what
        // the header's `(e & ~MASK) | ((0xFFFF & (GEN(e) + 1)) << 32)` says.
        {
            const bumped = c.core.ECS_GENERATION_INC(a);
            try std.testing.expectEqual(a & ~c.core.ECS_GENERATION_MASK, bumped & ~c.core.ECS_GENERATION_MASK);
            try std.testing.expectEqual(
                (c.core.ECS_GENERATION(a) +% 1) & 0xFFFF,
                c.core.ECS_GENERATION(bumped),
            );
        }
        try std.testing.expectEqual(h.ECS_IS_VALUE_PAIR(a), c.core.ECS_IS_VALUE_PAIR(a));
        try std.testing.expectEqual(@as(u64, h.ECS_PAIR_FIRST(a)), c.core.ECS_PAIR_FIRST(a));
        try std.testing.expectEqual(@as(u64, h.ECS_PAIR_SECOND(a)), c.core.ECS_PAIR_SECOND(a));

        // ECS_IS_PAIR is the second macro with no comparable counterpart: translate-c
        // renders its `||` as `bool or comptime_int`, which does not compile. Its two
        // comparisons are written out here instead, straight from flecs.h line 1026.
        try std.testing.expectEqual(
            (a & c.core.ECS_ID_FLAGS_MASK) == c.core.ECS_PAIR or (a & c.core.ECS_ID_FLAGS_MASK) == c.core.ECS_VALUE_PAIR,
            c.core.ECS_IS_PAIR(a),
        );

        // Not the same predicate, and worth pinning down because the names suggest it
        // is: the library's `ecs_id_is_pair` is `id & ECS_PAIR`, a single bit test, so
        // it answers yes for `ECS_AUTO_OVERRIDE | ecs_pair(...)` where the macro
        // answers no. Both are bound, under their own names, doing their own thing.
        try std.testing.expectEqual((a & c.core.ECS_PAIR) != 0, c.world.ecs_id_is_pair(a));

        for (ids) |b| {
            try std.testing.expectEqual(h.ecs_entity_t_comb(a, b), c.core.ecs_entity_t_comb(a, b));
            try std.testing.expectEqual(h.ecs_pair(a, b), c.core.ecs_pair(a, b));
            try std.testing.expectEqual(h.ecs_value_pair(a, b), c.core.ecs_value_pair(a, b));
        }
    }

    // And the round trip flecs itself relies on, on ids inside the domain the pair
    // encoding can actually represent.
    const first: c.core.ecs_entity_t = 0x0123_4567;
    const second: c.core.ecs_entity_t = 0x89AB_CDEF;
    const pair = c.core.ecs_pair(first, second);
    try std.testing.expect(c.core.ECS_IS_PAIR(pair));
    try std.testing.expect(!c.core.ECS_IS_VALUE_PAIR(pair));
    try std.testing.expectEqual(first, c.core.ECS_PAIR_FIRST(pair));
    try std.testing.expectEqual(second, c.core.ECS_PAIR_SECOND(pair));

    const value_pair = c.core.ecs_value_pair(first, second);
    try std.testing.expect(c.core.ECS_IS_VALUE_PAIR(value_pair));
    try std.testing.expect(c.core.ECS_IS_PAIR(value_pair));

    // The library agrees with both, which is what makes this more than two
    // reimplementations of the same misreading.
    try std.testing.expectEqual(pair, c.world.ecs_make_pair(first, second));
    try std.testing.expect(c.world.ecs_id_is_pair(pair));
    try std.testing.expect(c.world.ecs_id_is_pair(value_pair));
    try std.testing.expect(!c.core.ECS_IS_PAIR(c.core.ECS_AUTO_OVERRIDE | pair));
    try std.testing.expect(c.world.ecs_id_is_pair(c.core.ECS_AUTO_OVERRIDE | pair));
}

test "ABI: the id masks match the header's" {
    try std.testing.expectEqual(@as(c.core.ecs_id_t, h.ECS_ID_FLAGS_MASK), c.core.ECS_ID_FLAGS_MASK);
    try std.testing.expectEqual(@as(c.core.ecs_id_t, h.ECS_ENTITY_MASK), c.core.ECS_ENTITY_MASK);
    try std.testing.expectEqual(@as(c.core.ecs_id_t, h.ECS_GENERATION_MASK), c.core.ECS_GENERATION_MASK);
    try std.testing.expectEqual(@as(c.core.ecs_id_t, h.ECS_COMPONENT_MASK), c.core.ECS_COMPONENT_MASK);
}
