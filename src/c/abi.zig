//! What *this target's* C compiler makes of the two C constructs that have no single
//! answer across the ABIs this package supports.
//!
//! This is not a module of flecs declarations, so it is deliberately absent from
//! `src/c.zig`'s `modules` list: nothing here names a symbol flecs exports, and the
//! guards that walk that list pair every name in it with a header declaration of the
//! same name. What is here instead is the ABI vocabulary the flecs declarations are
//! *written in* — one home for the two facts that differ per target, so that neither
//! is spelled out at the twelve sites that need it and neither can be updated in one
//! place and missed in another.
//!
//! Both are checked, not asserted: `src/abi_check.zig` compares every declaration that
//! uses them against `@cImport`'s answer for the target being built, so a wrong branch
//! here is a compile error on the target it is wrong for.

const std = @import("std");
const builtin = @import("builtin");

/// The integer a C `enum` compiles to, for an enum whose enumerators are all
/// non-negative and fit in `int` — which every enum flecs declares is
/// [read-from-source: `ecs_inout_kind_t`, `ecs_oper_kind_t`,
/// `ecs_query_cache_kind_t`, `ecs_http_method_t`, `ecs_primitive_kind_t`,
/// `ecs_type_kind_t` and `ecs_meta_op_kind_t` in `libs/flecs/flecs.h`; the lowest
/// enumerator anywhere is 0].
///
/// MSVC gives every enum `int`. Clang and gcc follow the Itanium rule and pick
/// `unsigned int` when no enumerator is negative. Same width, opposite signedness —
/// so hard-coding either one is correct on one Windows ABI and wrong on the other,
/// which is exactly the drift the guard caught on `ecs_query_desc_t.cache_kind`.
///
/// The raw layer mirrors these as the integer rather than as a Zig `enum` on purpose:
/// flecs stores values in these fields that its own header does not enumerate, and a
/// Zig enum would make those illegal to represent. The real enums are one level up, in
/// `src/types.zig`, tagged with this same integer.
pub const c_enum = if (builtin.target.abi == .msvc) c_int else c_uint;

/// The type of a parameter declared `va_list` in C, for this target.
///
/// C's `va_list` names an *object* type, and the standard lets that object be an array
/// — in which case a parameter of that type decays to a pointer and the object type is
/// NOT what crosses the ABI. `std.builtin.VaList` names the object, so deriving the
/// parameter from it is a per-ABI question with three answers. Measured 2026-08-30 with
/// `zig translate-c` 0.16.0, one header per target, reading the type it gives a
/// `va_list` parameter:
///
/// | target                                   | parameter type                 |
/// |------------------------------------------|--------------------------------|
/// | x86_64 windows (gnu and msvc), uefi      | `[*c]u8`                       |
/// | aarch64 windows, aarch64 macOS           | `[*c]u8`                       |
/// | x86_64 System V — Linux gnu/musl, macOS  | `[*c]struct___va_list_tag`, 8 B|
/// | aarch64 Linux                            | a 32-byte struct, by value     |
///
/// The System V row is the one that has to be written down rather than derived:
/// `std.builtin.VaList` is the 24-byte `VaListX86_64` *object* there, so taking it
/// verbatim passes a struct by value where C passes a pointer. That is a real ABI
/// defect on Linux and x86_64 macOS, and this package shipped it — nothing compiled
/// the guard for a System V target.
///
/// Two of the four rows also cannot be reached through `std.builtin.VaList` at all: it
/// is `@compileError("disabled due to miscompilations")` for x86_64 Windows/UEFI (zig
/// 0.16.0, `lib/std/builtin.zig:1053`) and for aarch64 Linux (`:1041`) under the LLVM
/// backend. That refusal is about Zig *implementing* varargs; the six flecs entry
/// points taking one of these only hand an opaque object straight back to C, and the
/// per-architecture structs `std` exports — `VaListX86_64`, `VaListAarch64` — are not
/// behind the refusal and are what the tables above are built from.
///
/// Everything here is checked rather than trusted: `src/abi_check.zig` compares this
/// against the parameter type `@cImport` gives `ecs_strbuf_vappend` on the target being
/// built, so a wrong row is a compile error on the target it is wrong for — which is
/// how the System V row was found.
pub const va_list = switch (builtin.target.cpu.arch) {
    .x86_64 => switch (builtin.target.os.tag) {
        // `__builtin_va_list` is `char *`.
        .windows, .uefi => [*c]u8,
        // System V: an array of one register-save block, decayed by the call.
        else => [*c]std.builtin.VaListX86_64,
    },
    .aarch64, .aarch64_be => switch (builtin.target.os.tag) {
        .windows, .uefi, .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => [*c]u8,
        // AAPCS64: `struct __va_list`, passed by value.
        else => std.builtin.VaListAarch64,
    },
    // Every other architecture: `std`'s object type is also what is passed, as far as
    // any target this package is built for goes. The guard decides, not this comment —
    // a target where that is wrong fails to compile with both types named.
    else => std.builtin.VaList,
};
