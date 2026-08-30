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

/// The type of a parameter declared `va_list` in C.
///
/// C's `va_list` names an *object* type, and the standard allows that object to be an
/// array — in which case a parameter of that type decays to a pointer, and the object
/// type is NOT what crosses the ABI. There are three shapes among the targets this
/// package builds for [measured 2026-08-30, `zig translate-c` 0.16.0, one header per
/// target]:
///
/// * `[*c]u8` — every Windows ABI (both architectures, gnu and msvc) and
///   aarch64-macOS, where `__builtin_va_list` is `char *`.
/// * an array of one register-save descriptor, decayed — x86_64 System V (Linux gnu
///   and musl, x86_64-macOS): the parameter is `[*c]struct___va_list_tag`, eight
///   bytes, while `std.builtin.VaList` names the twenty-four-byte array.
/// * a struct passed by value — aarch64-Linux and the other ABIs `std` spells out.
///
/// Deriving the parameter type from the object type is therefore a decay, not a copy:
/// the middle case is a real ABI defect if it is taken verbatim, and it was — the
/// package declared `std.builtin.VaList` and nothing on a System V target ever
/// compiled the guard that would have said so.
///
/// The first case also has to be spelled out rather than derived, because
/// `std.builtin.VaList` is not a type there at all: on x86_64 Windows and UEFI with
/// the LLVM backend it is `@compileError("disabled due to miscompilations")` — zig
/// 0.16.0, `lib/std/builtin.zig:1053`. That refusal is about Zig *implementing*
/// varargs; it says nothing about handing an opaque `char *` straight back to C, which
/// is all any of the six flecs entry points taking one of these does. Naming the
/// pointer directly is the whole fix, and it is the same pointer `@cImport` produces.
pub const va_list = if (is_char_pointer_va_list)
    [*c]u8
else switch (@typeInfo(std.builtin.VaList)) {
    // The array case. C decays it at the call; so does this.
    .array => |a| [*c]a.child,
    else => std.builtin.VaList,
};

/// Targets whose `__builtin_va_list` is `char *`. Written out rather than derived
/// because `std.builtin.VaList` cannot be *looked at* on the x86_64 half of it.
const is_char_pointer_va_list = switch (builtin.target.cpu.arch) {
    .x86_64 => switch (builtin.target.os.tag) {
        .windows, .uefi => true,
        else => false,
    },
    else => false,
};
