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
