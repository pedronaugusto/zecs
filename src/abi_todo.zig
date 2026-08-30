//! What is left to bind. It is empty, and that is the point.
//!
//! `src/abi_manifest.zig` lists every symbol the vendored flecs exports. The ABI guard
//! fails the build for any of them that `src/c.zig` does not declare — unless the name
//! appears here. So this file is the difference between the two, and it is the one number
//! in this package that cannot be overstated: an empty list means every export is bound,
//! checked by the compiler rather than counted by hand.
//!
//! It is not a suppression list. An entry here for something `c.zig` already declares
//! fails the build, and so does an entry out of order or repeated, because the guard
//! binary-searches it. The only thing it can legitimately hold is API that a re-vendor of
//! flecs has just added and nobody has bound yet — and holding it there is a deliberate,
//! visible act, not a default.
//!
//! Kept sorted, because the guard binary-searches it — and checks that it is sorted,
//! because a binary search over an unsorted list silently finds nothing.

pub const not_yet_declared = [_][]const u8{};

/// Names flecs's HEADER exports and its SOURCE never defines.
///
/// This is a different fact from `not_yet_declared`, and putting it in that list would
/// have said the opposite of the truth: the symbol is not waiting to be bound, it
/// cannot be bound, because there is nothing to bind to. Declaring it produces a
/// package that fails to LINK the moment anything references it — which is how it was
/// found, on x86_64-linux, where the reference lived only in debug info and lld
/// refused it while every other linker dropped it.
///
/// `ecs_id(EcsPipelineQuery)` is declared at `libs/flecs/flecs.h:6606` and appears
/// nowhere else in the vendored amalgamation [measured: `grep -rn PipelineQuery libs/`
/// returns that one line, flecs 4.1.6]. Upstream's defect, so upstream's to fix — this
/// package does not patch `libs/`.
///
/// The gate is not this list. It is the `every extern this package declares resolves in
/// the compiled library` test in `src/abi_check.zig`, which takes the address of every
/// extern so the linker has to resolve each one; this list is what that test's failure
/// is resolved INTO, and the coverage sweep refuses an entry here that `src/c.zig` also
/// declares.
///
/// Scanned linearly rather than binary-searched: unlike `not_yet_declared` it is
/// expected to hold single figures, and a linear scan needs no sortedness invariant to
/// go wrong.
pub const declared_but_not_defined = [_][]const u8{
    "FLECS_IDEcsPipelineQueryID_",
};
