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
const tiers = @import("api_tiers.zig");

const h = @cImport({
    // MinGW turns on its fortified `wcscat`/`wcscpy` when `_FORTIFY_SOURCE` is set and
    // the build is optimized, and Zig 0.16's translate-c renders those two bodies with
    // a local that nothing uses — an error, in a file this package does not write. It
    // reaches nothing about flecs: the fortified and plain declarations have the same
    // ABI, and the guard compares flecs's own symbols. Undefined first because Zig
    // passes `-D_FORTIFY_SOURCE` itself in release builds, and redefining it would be
    // its own diagnostic.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
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

/// Declarations whose header counterpart is a DIFFERENT type from the one that crosses
/// the ABI, so pairing the two by name would compare the wrong pair of things.
///
/// There is exactly one, and it is not a loophole: `va_list` names a C *object* type,
/// and on x86_64 System V that object is an array, which C decays to a pointer at every
/// call. Comparing our parameter type against the header's array type would fail on the
/// targets where the two agree about what is passed, and pass on none. So the pairing
/// moves to where the ABI actually is — the parameter — and the test named below does
/// it, on the same target, against the same `@cImport`.
///
/// Like `unrepresentable`, every entry must be reached: the test at the bottom checks
/// the count, so an entry that stops applying after a re-vendor is a failure rather than
/// a permanent hole.
const compared_by_use = [_]struct { name: []const u8, covered_by: []const u8 }{
    .{
        .name = "va_list",
        .covered_by = "the `a va_list crosses the ABI the way flecs.h passes one` test " ++
            "below, which compares this declaration against the parameter type " ++
            "@cImport gives `ecs_strbuf_vappend` for the target being built.",
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

fn isComparedByUse(comptime name: []const u8) bool {
    for (compared_by_use) |u| if (std.mem.eql(u8, u.name, name)) return true;
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

/// Signedness on top of width, and what a pointer points AT on top of both.
///
/// Width alone leaves a hole the size of every pointer in flecs: on a 64-bit target
/// `*T`, `*const T`, `?[*]u8` and `?*anyopaque` are all eight bytes with eight-byte
/// alignment, so a size-and-alignment comparison sees no difference between a parameter
/// this package promises not to write through and one it does. `checkPointer` closes the
/// part of that hole the two sides can actually be compared on.
///
/// **What is compared, and what is not.** translate-c renders every C pointer as `[*c]T`
/// — nullable, unbounded, unowned — because that is all C says. This package's externs
/// are deliberately narrower: `*ecs_world_t` where the world is never null, `[*:0]const u8`
/// for a C string, `?[*]ecs_id_t` for an array that may be absent. Insisting those match
/// would be insisting the bindings be as vague as the header. So the comparison is of the
/// two things C DOES say and Zig carries faithfully:
///
///   * `const` in the direction that can be wrong — `const T*` becomes `[*c]const T`,
///     and a hand-written `*T` against it is a promise this package is not entitled to
///     make. The other direction is allowed: declaring `*const T` where the header says
///     `T*` is the same kind of narrowing as declaring `*T` where it says `[*c]T`, and
///     `ecs_iter_t.trs` is a deliberate instance of it — flecs writes that array, and
///     nothing reading an iterator has any business doing so;
///   * what the pointee is, by width and signedness, one level down, with `anyopaque` on
///     either side treated as the wildcard it is and function pointees compared as
///     functions.
///
/// Deliberately NOT compared, and therefore the blind spots of this guard: nullability,
/// how many elements a pointer addresses, sentinels, and ownership. None of those exist
/// in the header to compare against.
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
    checkPointer(what, Ours, Theirs, 0);
}

/// What a pointer type carries, once `?` has been peeled off it. Null for anything that
/// is not a pointer.
fn Pointee(comptime T: type) ?std.builtin.Type.Pointer {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| ptr,
        .optional => |opt| switch (@typeInfo(opt.child)) {
            .pointer => |ptr| ptr,
            else => null,
        },
        else => null,
    };
}

/// Whether a type says nothing about what is behind it, so that comparing it would be
/// comparing this package's typing against C's silence.
fn isOpaqueish(comptime T: type) bool {
    return T == anyopaque or T == void or @typeInfo(T) == .@"opaque";
}

/// The pointer half of `sameScalar`. `depth` stops a function pointer whose parameters
/// are function pointers from recursing without end; two levels is past everything flecs
/// declares (`ecs_sort_table_action_t` takes an `ecs_order_by_action_t`).
fn checkPointer(
    comptime what: []const u8,
    comptime Ours: type,
    comptime Theirs: type,
    comptime depth: usize,
) void {
    if (depth > 2) return;

    const ours = Pointee(Ours);
    const them = Pointee(Theirs);
    if (ours == null and them == null) return;
    if (ours == null or them == null) {
        fail(what ++ " is " ++ @typeName(Ours) ++ " in src/c.zig but " ++
            @typeName(Theirs) ++ " in flecs.h: one is a pointer and the other is not");
    }

    if (them.?.is_const and !ours.?.is_const) {
        fail(what ++ " points at mutable data in src/c.zig and const data in flecs.h: " ++
            "the binding claims a write the header does not allow");
    }
    if (ours.?.is_volatile != them.?.is_volatile) {
        fail(what ++ " disagrees with flecs.h about `volatile`");
    }

    const OurChild = ours.?.child;
    const TheirChild = them.?.child;
    // `void*` is C saying nothing, and this package saying something is the point of it.
    if (isOpaqueish(OurChild) or isOpaqueish(TheirChild)) return;

    if (@typeInfo(OurChild) == .@"fn" or @typeInfo(TheirChild) == .@"fn") {
        if (@typeInfo(OurChild) != .@"fn" or @typeInfo(TheirChild) != .@"fn") {
            fail(what ++ " points at a function in one of src/c.zig and flecs.h and not " ++
                "the other");
        }
        checkFnType(what ++ " pointee", OurChild, TheirChild);
        return;
    }

    sameSizeAndAlign(what ++ " pointee", OurChild, TheirChild);
    const oc = @typeInfo(OurChild);
    const tc = @typeInfo(TheirChild);
    if (oc == .int and tc == .int and oc.int.signedness != tc.int.signedness) {
        fail(what ++ " points at " ++ @typeName(OurChild) ++ " in src/c.zig but " ++
            @typeName(TheirChild) ++ " in flecs.h");
    }
    checkPointer(what ++ " pointee", OurChild, TheirChild, depth + 1);
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
    /// Entries of `compared_by_use` that were actually reached.
    by_use: usize = 0,
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

            if (isComparedByUse(d.name)) {
                n.by_use += 1;
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
    /// Listed in `abi_todo.zig` as declared by the header and defined by nothing.
    not_defined: usize = 0,
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
        if (isNotDefined(name)) {
            fail("`" ++ name ++ "` is listed in src/abi_todo.zig as declared by flecs.h " ++
                "and defined by nothing, and src/c.zig declares it anyway. An extern " ++
                "with no definition links only for as long as nothing references it, " ++
                "and the link test below references every one.");
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
    if (isNotDefined(name)) {
        n.not_defined += 1;
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

/// Linear, because `declared_but_not_defined` holds single figures — see its own
/// comment for why it is not the sorted list next to it.
fn isNotDefined(comptime name: []const u8) bool {
    comptime {
        for (todo.declared_but_not_defined) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
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
    try std.testing.expectEqual(compared_by_use.len, ours.by_use);

    // With every addon on there is nothing the header can be missing, so a declaration
    // in `c.zig` that has no counterpart is a misspelling, not a configuration — and
    // the counts stop being floors and become the real shape of flecs.
    if (comptime every_addon) {
        try std.testing.expectEqual(@as(usize, 0), ours.addon_absent);
        // Floors again for the categories nothing else counts, set close enough to the
        // real shape of flecs that a sweep which stopped covering a whole category
        // fails here rather than passing quietly. The two categories that DO have an
        // independent count are checked exactly, just below.
        try std.testing.expect(ours.types >= 250);
        try std.testing.expect(ours.fields >= 880);

        // src/api_tiers.zig is generated by reading src/c/ as text, and text is not
        // what the compiler reads. This is where the two views are made to agree: the
        // three tiers together must account for every extern the sweep above saw, and
        // for no more. A declaration the scanner missed, or one it invented, fails
        // here — which is what makes the counts in that file, and everything the
        // README says about them, a measurement rather than the reach of a regex.
        try std.testing.expectEqual(
            tiers.public.len + tiers.macro_backed.len + tiers.internal.len,
            ours.functions + ours.variables,
        );

        // And every internal name is real. The list is what
        // forbids the typed layer to call, so a misspelling in it is a hole in that
        // refusal rather than a cosmetic problem.
        comptime {
            for (tiers.internal) |name| {
                var found = false;
                for (c.modules) |m| {
                    if (@hasDecl(m, name)) found = true;
                }
                if (!found) {
                    fail("src/api_tiers.zig lists `" ++ name ++ "` as an internal flecs " ++
                        "symbol, and no module in src/c/ declares it. Regenerate it with " ++
                        "`zig build api-tiers`.");
                }
            }
        }
    }
}

test "ABI: src/c.zig covers what flecs exports" {
    const coverage = comptime sweepTheirs();

    // Nothing may be lost: every name in the manifest is bound, absent because an addon
    // is off, or explicitly pending. There is no fourth outcome.
    try std.testing.expectEqual(
        manifest.functions.len + manifest.variables.len,
        coverage.declared + coverage.addon_absent + coverage.pending + coverage.not_defined,
    );

    // The claim this package makes about itself, stated as an assertion rather than a
    // sentence in a README: with every addon on, every symbol flecs exports is declared.
    if (comptime every_addon) {
        try std.testing.expectEqual(@as(usize, 0), coverage.addon_absent);
        try std.testing.expectEqual(@as(usize, 0), coverage.pending);
        // Every entry of the header-declares-it-and-nothing-defines-it list is reached,
        // so one that upstream fixes stops being a permanent exemption.
        try std.testing.expectEqual(todo.declared_but_not_defined.len, coverage.not_defined);
        try std.testing.expectEqual(
            manifest.functions.len + manifest.variables.len,
            coverage.declared + coverage.not_defined,
        );
    }
}

test "ABI: a va_list crosses the ABI the way flecs.h passes one" {
    // `va_list` is the one declaration this guard does not pair by name — see
    // `compared_by_use` — because C's `va_list` names an OBJECT type and the object is
    // an array on x86_64 System V, which decays at every call. The ABI is the
    // parameter, so the parameter is what is compared, on the target being built and
    // against the same `@cImport` as everything else.
    //
    // `ecs_strbuf_vappend` is flecs's string builder and no addon switches it off, so
    // this is unconditional: a header that stopped declaring it fails here rather than
    // quietly skipping the only check `va_list` has.
    comptime {
        if (!@hasDecl(h, "ecs_strbuf_vappend")) {
            fail("flecs.h no longer declares `ecs_strbuf_vappend`, which is where the " ++
                "shape of a `va_list` argument is pinned. Point this at another entry " ++
                "point that takes one.");
        }
        const their_fn = @typeInfo(@TypeOf(h.ecs_strbuf_vappend)).@"fn";
        if (their_fn.params.len != 3) {
            fail("flecs.h's `ecs_strbuf_vappend` no longer takes three parameters, so " ++
                "the third is no longer the `va_list` this compares.");
        }

        const what = "`va_list`, as a parameter";
        const Ours = c.core.va_list;
        const Theirs = their_fn.params[2].type orelse fail(what ++ " is untyped in flecs.h");

        sameSizeAndAlign(what, Ours, Theirs);

        const ours = @typeInfo(Ours);
        const them = @typeInfo(Theirs);
        if (std.meta.activeTag(ours) != std.meta.activeTag(them)) {
            fail(what ++ " is a " ++ @tagName(ours) ++ " in src/c.zig but a " ++
                @tagName(them) ++ " in flecs.h. An `.array` on this side is the decay " ++
                "that src/c/abi.zig exists to perform.");
        }
        switch (ours) {
            // Size and alignment alone would accept a pointer to the wrong thing, and
            // on System V the pointee is the register-save block varargs walks.
            .pointer => sameSizeAndAlign(
                what ++ "'s pointee",
                ours.pointer.child,
                them.pointer.child,
            ),
            // Passed by value. Compared field by POSITION rather than by name, which
            // is the one place in this file that is right: the C compiler's
            // `struct __va_list` has no member names translate-c can see, so it emits
            // `unnamed_0`… and there is nothing to pair a name with. Offsets, widths
            // and alignments are the whole content of the comparison here.
            .@"struct" => {
                const of = ours.@"struct".fields;
                const tf = them.@"struct".fields;
                if (of.len != tf.len) {
                    fail(what ++ " has " ++ num(of.len) ++ " fields in src/c.zig but " ++
                        num(tf.len) ++ " in flecs.h");
                }
                for (of, tf, 0..) |o, t, i| {
                    if (@offsetOf(Ours, o.name) != @offsetOf(Theirs, t.name)) {
                        fail(what ++ " field " ++ num(i) ++ " is at byte " ++
                            num(@offsetOf(Ours, o.name)) ++ " in src/c.zig but " ++
                            num(@offsetOf(Theirs, t.name)) ++ " in flecs.h");
                    }
                    sameScalar(what ++ " field " ++ num(i), o.type, t.type);
                }
            },
            else => fail(what ++ " is a " ++ @tagName(ours) ++ ", which this check does " ++
                "not know how to compare"),
        }
    }
}

test "ABI: every extern this package declares resolves in the compiled library" {
    // The two sweeps above compare `src/c.zig` against the *header*. A header can
    // declare a symbol the library never defines, and no amount of comparing two
    // declarations to each other will ever find that — flecs 4.1.6 does it once, and
    // the only reason it was found is that one linker refused it while the others
    // dropped the reference.
    //
    // What finds it deterministically is a relocation. This takes the address of every
    // extern function and every extern variable in the package, so the test binary
    // carries a reference to each and the linker has to resolve all of them or refuse
    // to produce it. `src/abi_todo.zig`'s `declared_but_not_defined` is the list of the
    // ones flecs's header promises and its source does not keep.
    //
    // Only with every addon on. A switched-off addon takes definitions out of the
    // library while `c.zig` goes on declaring them, and an unused extern emits no
    // relocation — which is precisely what makes a reduced addon set a legal
    // configuration rather than a link failure. Forcing the relocation there would
    // break that on purpose.
    if (comptime !every_addon) return error.SkipZigTest;
    @setEvalBranchQuota(2_000_000);

    var sink: usize = 0;
    var externs: usize = 0;
    inline for (c.modules, 0..) |m, mi| {
        inline for (@typeInfo(m).@"struct".decls) |d| {
            const earlier = comptime blk: {
                for (c.modules, 0..) |other, oi| {
                    if (oi < mi and @hasDecl(other, d.name)) break :blk true;
                }
                break :blk false;
            };
            if (!earlier) {
                const Decl = @TypeOf(@field(m, d.name));
                if (Decl != type) {
                    if (@typeInfo(Decl) == .@"fn") {
                        const cc = @typeInfo(Decl).@"fn".calling_convention;
                        if (cc != .@"inline" and cc != .auto) {
                            sink +%= @intFromPtr(&@field(m, d.name));
                            externs += 1;
                        }
                    } else if (!comptime isComptimeKnown(m, d.name)) {
                        sink +%= @intFromPtr(&@field(m, d.name));
                        externs += 1;
                    }
                }
            }
        }
    }

    // Reaching here means the link succeeded, which is the whole assertion. These two
    // are what stop a sweep that quietly stopped finding anything from looking the
    // same: flecs 4.1.6 exports 710 functions and 318 variables, so the floor is set
    // just under the sum.
    try std.testing.expect(externs >= 1000);
    try std.testing.expect(sink != 0);
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
