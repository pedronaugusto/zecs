# Changelog

All notable changes to this package. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this package uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## 0.2.0

A correctness release. Everything below was found by reviewing the package against its
own claims; each one is a defect the previous release shipped.

### Fixed — the package did not build, or built wrongly

- **`va_list` was bound as `std.builtin.VaList`.** That is the object type, not the type
  the ABI passes. On every target where the two differ, the four `*_v` logging and
  formatting functions took the wrong argument. The declarations now use the ABI type.
- **A C enum is `int` on MSVC and `unsigned int` elsewhere**, and the Zig side had one
  answer for both. Every enum-typed parameter and field is now sized for the target's
  ABI, and both Windows ABIs are built and run.
- **The cross-compilation tier compiled no Zig at all.** `zig build -Dtarget=…` builds
  the C library and creates the module; a module analyses nothing until something links
  it, so a target where `src/` did not compile passed. Each cross target now also builds
  the test binaries, which links them.
- **The ABI oracle would not compile in any optimized build on Windows-gnu.** MinGW's
  fortified `wcscat`/`wcscpy` become unused local constants in translate-c's output,
  which then refuses its own output. Undefined at the `@cImport`.
- **A test compared a struct's padding byte**, which Zig promises nothing about. It
  passed in Debug and failed in ReleaseFast. It compares fields now.
- **The ABI guard named every declaration before asking whether this build had one.**
  Zig emits an extern it has analysed into `.debug_info` whether or not any code calls
  it; a COFF or Mach-O linker drops that reference and an ELF linker refuses it. So with
  an addon switched off — including in the default set, where upstream itself leaves
  journal and script math out — the test binary referenced symbols the library does not
  define, and `zig build test` failed to link on Linux while passing on Windows and
  macOS. The guard now settles what this build has before it touches anything: what the
  header declares, less the names it replaces with macros, less the seven symbols flecs
  declares unconditionally and defines only under an addon.

### Fixed — silent wrong answers

- **A component handle from one world was accepted by another.** flecs hands out ids in
  registration order, so two worlds routinely give different components the same number:
  `Component(T)` now records the world that minted it and every typed operation checks
  it. `World.minted` exposes the predicate, because an assertion cannot be caught.
- **An iteration in progress was a value anyone could copy.** An `ecs_iter_t` holds a
  cursor into the stage's iterator stack; a copy is two owners of one iteration. The
  iterator now pins its own address on first use and asserts against a copy or a move.
- **A failed module import left the module entity behind**, and importing is a lookup
  once the entity exists — so a retry after a failure returned the id of a half-built
  module and re-ran nothing. The entity is deleted on the way out.
- **The per-module import failure slot was process-wide**, so two threads setting up two
  worlds could overwrite each other's error. It is thread-local.
- **A query could return the right entities in an order nothing chose.** Ordering is now
  part of the descriptor, with grouping alongside it.
- **The term list and the field indices were two lists nothing compared.**
- **`Query.cacheKind` reported what was requested, not what flecs built.**
- **A component whose alignment flecs cannot represent was stored crooked.** It is
  refused at registration.
- **Two owners of one allocation**: a component that owns memory and has not said how to
  copy it was memcpy'd by `ecs_clone` and by prefab instantiation. Registration records
  what the type can do; both operations ask.
- **`world.lookup(@typeName(T))` never found what `world.component(T, …)` registered**,
  because one half created a literal name and the other read it as a path.
- **`worlds_alive` was a plain `usize`** guarded by nothing.

### Fixed — guards that were not guarding

- **The ABI guard compared every pointer as eight bytes**, so a `const` dropped from a
  parameter or a pointee of the wrong width was invisible. It now follows one level of
  pointee and compares size, alignment and constness. What it still cannot see is stated
  in the README rather than left to be found.
- **The eighteenth mutation in `ci/mutate.sh` sat below the script's exit** — dead code,
  and the one regression its own comment said nothing else catches. The harness also
  understood only one kind of expected signal, so a case needing a different build could
  not be written.
- **Four of flecs's forty OS-API callbacks were routed.** Logging, abort and the
  profiler markers now have Zig handlers too, and `src/memory.zig` is `src/os.zig`,
  named for what it owns.
- **`build.zig.zon`'s `paths` did not ship `examples/`**, which the README tells a reader
  to open. `ci/verify-package.sh` now compares `paths` against the repository in both
  directions.
- **Every symbol flecs exports is not the same thing as flecs's API.** Roughly a hundred
  of the bound declarations are flecs internals with no stability contract.
  `src/api_tiers.zig` is generated from the sources and splits them into `public`,
  `macro_backed` and `internal`; `zig build api-tiers-check` fails if it is stale, and
  also fails if the typed layer calls into the internal tier.
- **Nothing compiled the benchmark.** A rename in `QueryDesc` left it broken for several
  commits. `zig build bench-compile` runs in CI.
- **The MSVC ABI was three steps of the local matrix out of forty.** "The suite passes"
  is a claim about an ABI, not about a machine, and the two Windows ABIs disagree about
  the width of a C enum — a difference this package had wrong. The arm is now a
  parameter of the whole roster, `ci/run.sh --target <triple>`, so a step added later
  cannot be gnu-only by omission; `ci/mutate.sh` takes the same target, and the mutation
  proof runs on both ABIs in CI.

### Added

- **A typed query layer.** `World.queryOf` and `QueryOf(Tuple)` take the terms as a Zig
  tuple type and hand back a row whose fields are already the right slices, so the term
  order and the field indices are one list instead of two. `zecs.in`, `out`, `optional`,
  `without`, `withId`, `withoutId` and `term` mark a term; `RowOf`, `SpecOf` and
  `TermOptions` are the types behind them; `QueryOf.each` runs a body per entity.
- **Ordering and grouping.** `QueryOptions` carries `order_by` and `group_by` — with
  `types.OrderBy`, `types.GroupBy`, `zecs.orderBy`, `orderByEntity`, `orderByEntityId`
  and `groupBy` to build them — plus `Query.iterGroup` and `Query.groupInfo`.
  `QueryDesc`'s `cache_kind`, `flags`, `entity` and `ctx` moved into `.options`.
- **Prefabs and inheritance, typed.** `World.prefab`, `World.isA`, `World.clone`,
  `World.inheritOnInstantiate`, `World.overrideOnInstantiate` and
  `World.dontInheritOnInstantiate`, with `World.notDuplicable` and
  `zecs.duplicable`/`componentIsStorable`/`max_component_alignment` for what a component
  can and cannot survive.
- `World.emplace`/`emplaceId`, `World.count`/`countId`, `World.enable` for an entity,
  `World.enableComponent`/`enableComponentId` and `World.isEnabled`/`isEnabledId` for one
  component on one entity, and the singleton family — `singletonAdd`, `singletonRemove`,
  `singletonHas`, `singletonGet`, `singletonGetMut`, `singletonSet`, `singletonEnsure`,
  `singletonEmplace`, `singletonModified`.
- `ComponentDesc.can_toggle` and `ComponentDesc.singleton`, without which the two
  operations above could not be used correctly — flecs refuses to toggle a component
  that was not registered for it.
- `zecs.setLogHandler`, `setAbortHandler`, `setTraceHandler`, and the `LogLevel`,
  `LogHandler`, `AbortHandler` and `TraceHandler` types.
- `World.minted`, `Iterator.atHome`, `types.Builtin.can_toggle` and
  `types.Builtin.singleton`.
- `Version.parse`, and `zecs.version` is now derived from `build.zig.zon` rather than
  restated in `src/zecs.zig`.

### Changed

- `World.setThreads` and `World.setTaskThreads` take `threads` and `task_threads`;
  `World.bulkNew` and `World.bulkNewId` take `n`. Parameter names only — Zig forbids a
  parameter that shadows a declaration, and `World.count` is the declaration.
- `Component(T)` gained a `world` field. Code that built one by hand rather than through
  `World.component` keeps working: a null world means "not any world's to mint" and is
  not checked.
- The benchmark prints a provenance header and a floor for every case, and the README
  quotes no numbers from it.

### Documentation

The README no longer asserts CI runs that have not happened, no longer carries counts
that nothing recomputes, and no longer describes `src/c.zig` as the file holding every
extern when it is the index of the modules that do. The `@cImport` escape hatch it
documents is compiled and run by `examples/basic` on every arm of the matrix.

## 0.1.0

First release. Zig bindings for flecs, with the library vendored unmodified and the
boundary between the two checked by the compiler rather than trusted.

### The raw layer is complete

`zecs.c` declares every symbol the vendored flecs exports — every function, variable,
struct, union, opaque type and callback typedef — grouped one module per area under
`src/c/`, with `src/c.zig` as the index the guards walk. Completeness is not a claim in
this file: `src/abi_manifest.zig` is generated from the header, and the build fails for
any export nothing binds.

### Every declaration is checked against the real header

`src/abi_check.zig` `@cImport`s flecs.h — in a test only, so the shipped module never runs
translate-c — and compares the two namespaces by reflection with no hand-written list:
struct fields by name and offset, functions by arity and per-parameter size and
signedness, macro constants by value, `extern const`s by type. A declaration it cannot
categorise is a compile error rather than a silent pass.

`ci/mutate.sh` proves the check refuses each kind of deliberate drift it plants — a field
swap, a widened parameter, a deleted declaration, a to-do list that lies — and scores a
build that fails for any other reason as a survivor. A guard that passes is otherwise
indistinguishable from a guard that checks nothing.

### The typed layer is written to a rule

A wrapper exists only when it removes an untyped parameter, turns a failure sentinel into
a Zig error, owns a resource lifetime, replaces a C string with a slice, or replaces a C
callback with a comptime thunk. Otherwise the raw declaration is the binding. The rule is
in the README so the shape of the library is checkable rather than incidental.

Nineteen modules: worlds, entities, components, queries, iteration, systems, observers,
tables with typed column slices, values, reflection derived from `@typeInfo`, JSON, doc
strings, `ecs_strbuf_t` as a `std.Io.Writer`, script, pipelines, timers, modules, stats,
alerts, and the app loop.

### Reflection derived from the type system

`zecs.meta.register` builds a flecs schema from `@typeInfo(T)` — fields with their real
`@offsetOf`, enums with their values, `packed struct(u32)` as a bitmask, arrays, nested
types memoised. A Zig struct becomes introspectable by the Explorer, serialisable by the
JSON API and editable over REST with no hand-written schema. What cannot be derived is
refused with a `@compileError` naming the type, rather than described wrongly.

### Host allocator injection

`setAllocator` routes every allocation flecs makes through a `std.mem.Allocator`, and
refuses when it cannot do so safely — flecs accepts a late allocator swap without
complaint while holding live blocks from the previous one. The suite asserts a world's
allocations balance to exactly zero after it is destroyed, on both allocator paths and
from four threads.

### Verified rather than asserted

`ci/verify-vendor.sh` fetches the pinned upstream commit and compares it, so "unmodified
upstream" is checked. `examples/basic` is a separate project depending on this one by
path, built and run by the workflow on three platforms, because nothing inside a package
can prove the package is usable from outside it. The workflow runs the suite in four
optimize modes through both allocator paths, across the addon presets and one addon off
at a time, and cross-compiles the target list in the README.

`UPSTREAM.md` records the upstream flecs behaviours found while binding the whole API, so
a re-vendor can check whether any have been fixed and the workarounds are not mistaken
for arbitrary defensiveness.
