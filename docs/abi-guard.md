# The ABI guard

`src/c/` hand-writes the flecs API: every `extern fn`, every `extern struct`, every
callback typedef, every constant. Neither compiler checks that those declarations still
agree with the header, and a field reordered on one side is silent corruption. This is
how that gap is closed.

## What `src/abi_check.zig` compares

It `@cImport`s the real header — in a test only, so the shipped module never runs
translate-c — with the same macros the library was compiled with, and compares the two
namespaces by reflection, with no hand-written list of what to check:

- every struct field by *name*, with its own offset, size and alignment. By name, not by
  position: two same-sized fields swapping places leaves the sequence of offsets
  identical, and only a name-to-offset pairing catches it.
- every function by arity and by each parameter's size, alignment and signedness;
- every macro constant by value, and every `extern const` by type. flecs has both, and
  the two are told apart by asking whether the value is knowable at compile time.
- the handful of C macros rewritten here as Zig functions, by calling both sides on the
  same inputs, which is the only way to compare a function to a macro.

A declaration the check does not know how to categorise is a compile error rather than a
silent pass, so it cannot quietly stop covering something.

It also takes the address of every extern this package declares, so the linker has to
resolve each one.

## The other direction

A function flecs exports that nobody bound is `src/abi_manifest.zig`, generated from the
header by `zig build abi-manifest` and verified current by `zig build
abi-manifest-check`. Anything in it that `src/c/` does not declare fails the build unless
it is named in `src/abi_todo.zig`.

`abi_todo.not_yet_declared` is empty. An entry there for something `c.zig` already
declares fails the build, and so does an entry out of order or repeated, because the
guard binary-searches the list and checks that it is sorted.

`abi_todo.declared_but_not_defined` holds one name. `ecs_id(EcsPipelineQuery)` is
declared at `libs/flecs/flecs.h:6606` and appears nowhere else in the vendored
amalgamation, so there is nothing to bind to; declaring it produces a package that fails
to link the moment anything references it. That is how it was found, on x86_64-linux,
where the reference lived only in debug info and lld refused it while every other linker
dropped it. Upstream's defect, and this package does not patch `libs/`.

## What it has caught

- `ecs_termset_t` is `ecs_flags<FLECS_TERM_COUNT_MAX>_t`, so `-Dterm_count_max=16`
  narrows four fields of `ecs_iter_t` and changes the struct's size. A binding that
  hardcodes the type keeps building and starts corrupting memory.
- `FLECS_SANITIZE` implies `FLECS_DEBUG`, and Zig defines `NDEBUG` for release C, which
  together make "a release build with checks on" a configuration that silently is not
  one.
- `ecs_query_t`, `ecs_observer_t`, `ecs_record_t` and `ecs_table_record_t` are defined in
  flecs's header, not opaque. Declaring them opaque compiles and reads nothing.
- A Zig rewrite of the macro `ECS_IS_PAIR` had been given the name of the exported
  function `ecs_id_is_pair`, which is a different predicate — one is two flag
  comparisons, the other a single bit test, and they disagree on
  `ECS_AUTO_OVERRIDE | ecs_pair(...)`. Both are now bound, under their own names.
- Under the MSVC ABI a C enum is `int` rather than `unsigned int`, which showed up in a
  field of `ecs_query_desc_t`.

## What it does not catch

translate-c renders every C pointer as `[*c]T`, which erases the pointee's name. The
guard follows one level of pointee and compares size, alignment and constness — a `*u32`
where the header says `*u64`, or a mutable parameter where the header promises `const`,
are both build failures — but two distinct structs of the same size and alignment still
compare equal, and it stops at the second level of indirection. The behaviour suite
covers that residue by driving the declarations and checking real answers.

## Proving the guard fires

A guard that passes looks exactly like a guard that checks nothing. `ci/mutate.sh`
introduces one deliberate defect at a time — a field swap, a widened parameter, a deleted
declaration, a to-do entry that lies, a call into an addon-gated entry point with the
addon switched off — and asserts the build fails each time, scoring a build that fails
for any other reason as a survivor. It runs as its own CI job, twice: once on the gnu ABI
and once on MSVC's, because a guard proved to fire under one is not proved to fire under
the other.

The first time it ran, one mutation survived: the to-do list is binary-searched, and an
entry inserted out of order was invisible to the search. The precondition is now checked
rather than assumed.

## Tiers

`src/api_tiers.zig` partitions what this package binds into `public`, `macro_backed` and
`internal`. `zig build api-tiers-check` fails if that partition is stale, and also fails
if anything above the raw layer has started calling an internal — a dependency no ABI
comparison can see, because a renamed internal moves on both sides at once.
