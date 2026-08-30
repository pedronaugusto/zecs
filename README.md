# zecs — flecs 4.1.6, in Zig

[![CI](https://github.com/pedronaugusto/zecs/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/zecs/actions/workflows/ci.yml)

> **What that badge does and does not say.** It reports the workflow in
> [`.github/workflows/ci.yml`](.github/workflows/ci.yml), which describes runs on Linux,
> macOS, Windows-gnu and Windows-MSVC. Executed by hand so far: the suite on Windows
> x86_64, both the gnu and the MSVC ABI, plus the example consumer on both. Every other
> configuration in the matrix has been cross-compiled and linked, and never run. Wherever
> this file says "CI runs", read it as "the workflow says", and read
> [Platform coverage](#platform-coverage) for what has actually happened.

This is [flecs](https://github.com/SanderMertens/flecs) — Sander Mertens's entity
component system, version 4.1.6, vendored byte for byte — with a Zig API over it and no
engine, no renderer and no asset system attached. The name is short; the library is
flecs, and nothing here is a reimplementation of it.

- Vendored, pinned upstream flecs 4.1.6. Three files, byte for byte, no patches. See
  [UPSTREAM.md](UPSTREAM.md), and `ci/verify-vendor.sh`, which proves it rather than
  claiming it.
- **Every symbol flecs exports is declared**, enforced by the compiler rather than
  asserted here: a function in the header that nothing binds fails the build. The count
  is not written down anywhere a human maintains — `src/api_tiers.zig` is generated from
  the sources and re-checked by `zig build api-tiers-check`, and that file carries the
  numbers.
- Every declaration is checked against the real header at compile time — struct fields by
  name and offset, functions by arity and per-parameter width, constants by value. Drift
  is a **build failure**, not a memory-corruption bug. `ci/mutate.sh` proves the check
  refuses each deliberate defect it plants, and scores a build that fails for any other
  reason as a survivor.
- Host allocator injection: every allocation flecs makes can go through your
  `std.mem.Allocator`, and the tests assert it all comes back. The rest of flecs's OS
  API — logging, abort, the profiler hooks — routes to Zig too.
- A typed layer written to a rule, not to a coverage target — see
  [What gets a wrapper](#what-gets-a-wrapper).

## Usage

```zig
const std = @import("std");
const zecs = @import("zecs");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

fn move(it: *zecs.Iter) void {
    const dt: f32 = @floatCast(it.deltaTime());
    for (it.fieldSelf(Position, 0), it.fieldSelf(Velocity, 1)) |*p, v| {
        p.x += v.x * dt;
        p.y += v.y * dt;
    }
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa_state.deinit() == .ok);

    // Before the first world. Afterwards it is an error, for a reason worth reading:
    // see "Allocator injection" below.
    try zecs.setAllocator(gpa_state.allocator());
    defer zecs.resetAllocator() catch {};

    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const velocity = try world.component(Velocity, .{});

    const e = world.newEntity();
    world.set(e, position, .{ .x = 0, .y = 0 });
    world.set(e, velocity, .{ .x = 1, .y = 2 });

    _ = try world.system(.{
        .name = "Move",
        .phase = zecs.Builtin.on_update.id(),
        .query = .{ .terms = &.{
            .{ .id = position.asId(), .inout = .read_write },
            .{ .id = velocity.asId(), .inout = .read },
        } },
        .callback = zecs.callback(move),
    });

    // `progress` returns false once something has called `world.quit()`. A real host
    // loops on that; ten frames is enough to show it working.
    for (0..10) |_| _ = world.progress(1.0 / 60.0);
}
```

Iterating a query directly, rather than through a system:

```zig
var query = try world.query(.{ .terms = &.{
    .{ .id = position.asId() },
    .{ .id = velocity.asId() },
} });
defer query.deinit();

var it = query.iter();
defer it.deinit();
while (it.next()) |row| {
    for (row.fieldSelf(Position, 0), row.entities()) |p, entity| {
        std.debug.print("{d}: {d},{d}\n", .{ entity, p.x, p.y });
    }
}
```

Add it as a dependency and link the module:

```zig
const zecs_dep = b.dependency("zecs", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zecs", zecs_dep.module("zecs"));
```

`zig build docs` generates the full API reference into `zig-out/docs` from the doc
comments in `src/`, so the reference and the code cannot drift apart.

A complete, runnable version of the above is in [`examples/basic`](examples/basic) — a
separate project with its own build graph that depends on this one by path. CI builds and
runs it on all three platforms, because nothing inside a package can prove the package is
usable from outside it.

## Design

### Two layers, and no wall between them

`zecs.c` is flecs's C API declared verbatim — `ecs_world_t`, `ecs_entity_init`,
`EcsOnUpdate`, `ecs_query_desc_t`. Not renamed, not restructured, so C documentation, C
examples and C answers apply to it unchanged.

The declarations are grouped by area, one file per area under `src/c/`, and the area is
part of the path: `zecs.c.core.ecs_entity_init`, `zecs.c.entity.ecs_new`,
`zecs.c.query.ecs_query_init`, `zecs.c.world.ecs_set_target_fps`. `src/c.zig` itself is
the index — a list of those modules, which is also what the ABI guard and the manifest
walk to discover what to check, so a module added there is covered without either being
told.

Not all of it is flecs's *API*. flecs exports its own internals — `flecs_balloc`,
`flecs_vasprintf` and about a hundred more — and they are declared here because the
manifest is generated from what the library exports, not from what upstream considers
public. `src/api_tiers.zig` is generated from the same sources and says which is which:
`public`, `macro_backed` (flecs spells it as a macro in C, and the underlying symbol is
the only spelling Zig has), and `internal` — no stability contract, may change in any
upstream patch release. `zig build api-tiers-check` fails if that file is stale, and it
also fails if the typed layer ever calls into the internal tier.

The typed layer sits on top and is what you would normally use: `World`, `Component(T)`,
`Query`, `Iter`. It adds type checking, slices with the right length, errors where flecs
returns a zero id, and nothing else. Both layers describe the same objects, so mixing
them is normal rather than an escape:

```zig
const world = try zecs.World.init();
zecs.c.world.ecs_set_target_fps(world.raw, 60); // whatever the wrapper has not covered
```

And behind that, the header itself is installed with the library, so a consumer can
reach declarations by `@cImport` even if this package had bound none:

```zig
exe.root_module.linkLibrary(zecs_dep.artifact("flecs"));
const flecs = @cImport(@cInclude("flecs.h"));
```

`linkLibrary` is on the *module* in Zig 0.16, not on the compile step. Both lines are
compiled and run by [`examples/basic`](examples/basic) on every arm of the matrix,
because a snippet nothing builds is a snippet that goes stale — this one had been wrong
since 0.16 renamed it.

On `x86_64-windows-gnu` in an optimized build, that `@cImport` needs two extra lines:

```zig
const flecs = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("flecs.h");
});
```

Nothing to do with flecs. MinGW switches to its fortified `wcscat`/`wcscpy` when
`_FORTIFY_SOURCE` is set, which an optimized build sets, and Zig's translate-c emits
those two as unused local constants and then refuses its own output. It affects only the
declarations translate-c reads, never the compiled library. The example does this, so
the workaround is checked rather than remembered.

That escape hatch is documented but is not the answer to anything: `zecs.c` declares
every symbol flecs exports, so there is nothing left for it to reach.

### What gets a wrapper

The raw layer is complete because completeness there is free and checkable. The typed
layer is neither, so it is written to a rule instead of to a coverage target.

**The typed layer is the only code in this package that nothing verifies.** The ABI guard
proves `src/c/` against the header; nothing proves a wrapper against `src/c/`
except the tests written for it. A mechanical 1:1 wrapper that adds no type information
is therefore pure unguarded surface — a second name for the same call, twice the
documentation, twice to keep in step, and a fresh place for a bug no guard can catch.

So a wrapper exists only when it does at least one of these:

1. removes an untyped parameter — `void*` plus a size becomes a typed slice or `*T`;
2. turns a failure sentinel (`0`, `NULL`) into a Zig error;
3. owns a resource whose lifetime Zig should manage;
4. replaces a C string with a Zig slice;
5. replaces a C callback with a comptime-generated thunk.

Otherwise the raw declaration **is** the binding: first-class, ABI-verified, and
documented as the way to call that function rather than as a fallback.

And where flecs offers something Zig already has, this package binds an adapter rather
than a mirror. `ecs_strbuf_*` becomes a `std.Io.Writer`; the vector, map and sparse-set
containers stay raw, because Zig has slices, `ArrayList` and `AutoHashMap` and they are
better here; the OS API beyond the allocator seam stays raw, because Zig has
`std.Thread`, `std.DynLib` and `std.fs`.

The rule is written down so the shape of the library is checkable rather than
incidental. If you find a wrapper that fails all five tests, it is a bug.

### Allocator injection

`setAllocator` routes flecs's allocations through a `std.mem.Allocator`. It is
process-wide, because flecs's OS API is — that is surfaced rather than hidden behind a
per-world parameter that could not be honoured.

The interesting part is not the bridge, it is the two ways flecs lets you get this wrong:

- **Patching the OS API without asking for its defaults first is a crash.** Setting the
  API latches it, and flecs then never installs the defaults, leaving the logging, abort,
  clock and threading callbacks null. It calls one of them during world creation. The
  binding always performs the full sequence, so this cannot happen through it.
- **Installing an allocator late is accepted, not refused.** `ecs_os_set_api` is a no-op
  once the API is initialized and reports nothing — and with the OS API implementation
  addon compiled in, which is the default, it is worse: the call *succeeds* and swaps the
  allocator while flecs holds live blocks from the previous one. Every later free of an
  older block then goes to the wrong allocator.

So `setAllocator` refuses once a world exists, and returns an error rather than
asserting. It also cross-checks flecs's public allocation counters, which catches a world
created outside this package entirely, through the raw C API. What it cannot catch is
that same case in a build with `-Ddisable_counters=true`; that is stated here rather than
glossed.

Two smaller details. Blocks carry a 16-byte header, because flecs frees with a bare
pointer and no size while Zig needs both, and 16 is the alignment C's `malloc` guarantees
— flecs stores component data in these blocks, and a component holding a SIMD vector has
to land aligned without asking. And if you run systems on more than one thread, flecs
allocates from those threads, so the allocator you inject has to be thread-safe. The
suite checks that path with a threaded pipeline.

### The ABI guard

`src/c/` hand-writes the flecs API: every `extern fn`, every `extern struct`, every
callback typedef, every constant. Nothing in either compiler checks that those
declarations still agree with the header, and a field reordered on one side is silent
corruption.

`src/abi_check.zig` closes that. It `@cImport`s the real header — in a test only, so the
shipped module never runs translate-c — with the same macros the library was compiled
with, and compares the two namespaces **by reflection, with no hand-written list of what
to check**:

- every struct field by *name*, with its own offset, size and alignment (by name, not by
  position: two same-sized fields swapping places leaves the sequence of offsets
  identical, and only a name-to-offset pairing catches it);
- every function by arity and by each parameter's size, alignment and signedness;
- every macro constant by value, and every `extern const` by type — flecs has both, and
  the two are told apart by asking whether the value is knowable at compile time;
- the handful of C macros rewritten here as Zig functions, by calling both sides on the
  same inputs, which is the only way to compare a function to a macro.

A declaration the check does not know how to categorise is a compile error rather than a
silent pass, so it cannot quietly stop covering something.

The other direction — a function flecs exports that nobody bound — is
`src/abi_manifest.zig`, generated from the header by `zig build abi-manifest` and
verified current by `zig build abi-manifest-check`. Anything in it that `src/c/` does
not declare fails the build unless it is named in `src/abi_todo.zig`, which is the list
of what is left to bind and can only get shorter. Coverage is therefore a fact the
compiler enforces rather than a number in a README.

This is not theoretical. Things it has caught in this package:

- `ecs_termset_t` is `ecs_flags<FLECS_TERM_COUNT_MAX>_t` — so `-Dterm_count_max=16`
  narrows four fields of `ecs_iter_t` and changes the struct's size. A binding that
  hardcodes the type keeps building and starts corrupting memory.
- `FLECS_SANITIZE` implies `FLECS_DEBUG`, and Zig defines `NDEBUG` for release C, which
  together make "a release build with checks on" a configuration that silently is not
  one.
- `ecs_query_t`, `ecs_observer_t`, `ecs_record_t` and `ecs_table_record_t` are defined in
  flecs's header, not opaque. Declaring them opaque compiles and reads nothing.
- A Zig rewrite of the macro `ECS_IS_PAIR` had been given the name of the *exported
  function* `ecs_id_is_pair`, which is a different predicate — one is two flag
  comparisons, the other a single bit test, and they disagree on
  `ECS_AUTO_OVERRIDE | ecs_pair(...)`. Both are now bound, under their own names.

What it does not catch, stated rather than left to be discovered: translate-c renders
every C pointer as `[*c]T`, which erases the pointee's *name*. The guard follows one
level of pointee and compares size, alignment and constness — a `*u32` where the header
says `*u64`, or a mutable parameter where the header promises `const`, are both build
failures — but two distinct structs of the same size and alignment still compare equal,
and it stops at the second level of indirection. The behaviour suite covers that residue
by driving the declarations and checking real answers.

And because a guard that passes looks exactly like a guard that checks nothing,
`ci/mutate.sh` introduces one deliberate defect at a time — a field swap, a widened
parameter, a deleted declaration, a to-do entry that lies — and asserts the build fails
each time. It runs as its own CI job. The first time it ran, one mutation survived: the
to-do list is binary-searched, and an entry inserted out of order was invisible to the
search. The precondition is now checked rather than assumed.

### Build options

Everything flecs exposes as a compile-time choice is a build option, and every option
that affects the ABI is mirrored into a Zig module that `zecs.c` reads its array sizes
from — one source, both sides, checked by the guard above.

**Addons.** The default is the same set upstream enables when you define nothing, which
is everything except the four that are opt-in there too. To take only what you need:

```sh
zig build -Daddons=minimal -Daddon_system=true -Daddon_pipeline=true \
          -Daddon_meta=true -Daddon_log=true
```

flecs enables an addon's dependencies itself — asking for `pipeline` also compiles
`module`, `system` and `timer` — so `zecs.options` reports what was *requested*. For what
was actually compiled, `ecs_log_set_level(0)` before creating a world prints the list.

**Checking level.** `-Ddebug_checks` is `auto` by default, which means flecs's
sanitize-level checks in Debug and none in release. `none` also defines `NDEBUG`, so
release builds pay nothing for the thousands of asserts inside flecs. `-Dkeep_assert`
brings them back on top of an optimized build.

**Allocator.** `-Duse_os_alloc` defaults to on in Debug and off in release; see below.

**Diagnostics.** `-Dsanitize_c` runs Zig's C undefined-behaviour sanitizer over flecs
(Debug only by default). `-Dtrack_allocations` makes the package count the bytes and
blocks it has handed flecs, readable at runtime (Debug only by default).
`-Ddebug_info` adds flecs's own annotations to its internal structures, which is what
the natvis visualisers read. `-Dsoft_assert` reports a recoverable error instead of
aborting.

**Performance shape.** `-Daccurate_counters` makes the global statistics counters exact
under threading, at a cost; `-Ddisable_counters` removes them entirely — and with them
the cross-check that catches a world created outside this package, which is why that is
called out under [Allocator injection](#allocator-injection). `-Dno_always_inline` drops
flecs's `always_inline` annotations for a smaller, slower binary.
`-Ddefault_to_uncached_queries` makes a query uncached unless it needs a cache: less
memory per query, slower iteration, and it changes what `Query.cacheKind` reports back.

**Everything else.** `-Dshared`, `-Dlow_footprint`, `-Dfloat_t`, `-Dftime_t`, and the
sizing constants (`-Dterm_count_max`, `-Dhi_component_id`, `-Dentity_page_bits`, and the
rest). `zig build -h` lists them all with their defaults, and that listing is generated
from `build.zig` rather than transcribed here.

### Iteration, and the shared-field trap

A term matched through `Up`, `Cascade` or a fixed source resolves to **one** value shared
by the whole table, not an array of them — the parent's transform, the prefab's material.
flecs signals this through `ecs_field_is_self`, and a binding that ignores it hands out a
slice of `count` elements over a single value. Reads past the first entity are then out of
bounds, silently, on exactly the queries that use inheritance.

So `Iter.field` asks, and returns a slice of the right length. `Iter.fieldSelf` is for
terms known to be per-entity: one C call cheaper, with the assertion compiled out in
ReleaseFast. `Iter.fieldShared` is for the other side of it.

### Performance

```sh
zig build bench -Doptimize=ReleaseFast
```

**No numbers are printed in this file.** A ns/op describes the machine that produced it,
and a table pasted into a README is a measurement with its provenance stripped off and
no way to notice when it stops being true. The benchmark prints its own header instead —
UTC date, zecs and flecs versions, compiler, target triple, CPU model, optimize mode,
every option that was set, and which allocator flecs was given — so a figure quoted from
it can be traced back to the run that made it.

Two things about how it is built, because they are what makes the output worth reading:

- **Every case is printed under a floor.** Each section opens with the same arithmetic
  over plain Zig slices, at the same entity count, in the same build, and every case
  after it reports its multiple of that floor. The floor is not a competitor — an ECS
  exists so the component set can vary per entity, which an array cannot do — it is the
  scale that turns a digit into a claim.
- **The header lists what the numbers do not control for**: an unpinned machine, one
  table, one shape of data, no comparison against any other ECS. Read that list before
  quoting anything.

The wrapper does not appear in the figures by design: `Iter` is one pointer, the
accessors are `inline`, component handles are values rather than a global keyed by type,
and the callback thunk is generated at compile time. What is measured is flecs.

**On `-Duse_os_alloc`.** `FLECS_USE_OS_ALLOC` turns off flecs's block allocator, so every
small object goes to the allocator you injected instead of coming from a pool. The
benchmark reports the allocator call count for the run, so the two configurations can be
compared directly on your machine — run it both ways rather than trusting a ratio
measured on someone else's.

Which is why the default depends on the build rather than being one answer. In Debug it
is on, so every allocation is individually visible to a leak checker. In release it is
off, so flecs's own pooling does the work it was written to do. Both are tested, in both
modes.

## Testing

```sh
zig build test
```

Two suites. The unit tests cover the ABI guard and the allocator bridge from inside the
package. The behaviour tests drive the public module exactly as a consumer does, with no
privileged imports — anything they need that is not exported is a gap in the API rather
than something to work around.

Between them they cover world lifecycle, component registration, the full
add/set/get/ensure/emplace/remove round-trip, tags, singletons, toggled components,
entity liveness and id recycling, naming and parenting, query iteration, optional and
negated terms, `Up` traversal into a parent, `Cascade` ordering down a hierarchy, early
exit from an iterator, a copied iterator being refused, observers firing on set, systems
running from the pipeline and by hand, deferred and readonly scopes leaving balanced,
bulk creation, prefabs and instantiation, ordering and grouping, a component handle from
the wrong world being refused, a failed module import leaving nothing behind, typed
column slices agreeing with entity-by-entity reads, a Zig struct round-tripping through
reflection to JSON and back, scripts creating what they describe and refusing what they
cannot parse, timers firing at their rate, alerts raising and clearing, and a four-thread
pipeline that has to visit every entity exactly once and give every byte back.

The test count is not written here. `zig build test` prints it, and it is right by
construction; a number in this paragraph would be right on the day it was typed.

```sh
zig build bench -Doptimize=ReleaseFast   # the numbers above
ci/mutate.sh                             # prove the ABI guard still refuses drift
ci/run.sh                                # the CI matrix, locally
ci/run.sh --quick                        # native Debug only, for the inner loop
ci/install-hooks.sh                      # run it automatically before every push
```

`ci/run.sh` reports every failure rather than stopping at the first.

### Continuous integration

The workflow runs the suite on **Linux, macOS and Windows** in four optimize modes,
through both allocator paths, plus the Windows MSVC ABI; builds a further set of option
configurations whose whole purpose is to move the structs the ABI test checks;
cross-compiles the target list below; regenerates `src/abi_manifest.zig` and
`src/api_tiers.zig` and fails if either is stale; compiles the benchmark; checks that
`build.zig.zon`'s `paths` ships the repository; and verifies the vendored copy against
upstream. See [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

### Platform coverage

| | Suite run by the workflow | Compile-checked by the workflow |
|---|---|---|
| Linux | x86_64 (glibc) | + aarch64, musl on both |
| macOS | aarch64 | + x86_64 |
| Windows | x86_64, both gnu and MSVC ABI | + aarch64 |

Compiling proves the sources and the build graph are portable; only an executed
configuration proves behaviour, which is why the two are separate jobs.

**That table describes the workflow, not a record of runs.** See the note under the badge
at the top of this file for what has actually been executed and where. A matrix nobody
has run is a plan.

## Scope

**The raw layer is complete.** Every symbol the vendored flecs exports is declared in
`zecs.c`, and the build fails if that stops being true. The counts live in the generated
`src/api_tiers.zig`, split into flecs's API and flecs's insides, and are re-derived by
`zig build api-tiers-check` rather than maintained by hand.

The typed layer covers, by the rule above:

| | |
|---|---|
| world | lifecycle, frames, stages, threading, deferring, readonly mode, lookup scopes, exclusive access — each begin/end pair as a scope type with an idempotent `end` |
| entities | creation, the full component access set including `emplace` and `count`, singletons, per-component enable/disable, bulk operations, names and paths, pairs as typed component handles, prefabs and instantiation, lifecycle hooks derived from `@typeInfo(T)` |
| queries | descriptors, traversal, caching, term operators, ordering and grouping, iteration, change detection, and `QueryOf.each` for a typed per-entity body |
| systems | phases, intervals, multi-threading, custom pipelines, timers, modules as Zig types |
| storage | tables with typed column slices, records, read/write guards, refs, values |
| reflection | `zecs.meta` derives a flecs schema from a Zig type — see below |
| serialisation | JSON both ways, doc strings, and `ecs_strbuf_t` as a `std.Io.Writer` |
| script | scripts, expressions, variables, diagnostics |
| observability | stats windows, metrics, alerts, the app loop, REST for the Explorer |

Left raw on purpose, because a wrapper would fail all five parts of the rule: the vector,
map, sparse-set and hashmap containers; the threading, dynamic-library and filesystem
halves of the OS API, where Zig already has `std.Thread`, `std.DynLib` and `std.fs`; the
meta cursor; the statistics record structs; most of the HTTP server. Each is named in the
module that decided it, with the reason.

The OS API's other seams do get wrappers, because they are callbacks rather than
containers and a C function pointer is not something a Zig host can hand over as itself:
`setLogHandler`, `setAbortHandler` and `setTraceHandler` route flecs's logging, its
abort and its profiler markers into Zig alongside the allocator.

### Reflection is the part worth reading

`zecs.meta.register(world, position)` derives flecs's schema from `@typeInfo(Position)` —
fields with their real `@offsetOf`, enums with their values, `packed struct(u32)` as a
bitmask, arrays, nested types registered once and memoised. A Zig struct becomes
introspectable by the Explorer, serialisable by the JSON API and editable over REST with
no hand-written schema.

Zig reorders struct fields, so this only works because it uses flecs's `use_offset` rather
than recomputing layout — the test proves it on a struct Zig demonstrably reorders. What
cannot be derived is refused with a `@compileError` naming the type and the reason, rather
than described wrongly: pointers, slices, optionals, unions, `@Vector`, and non-standard
integer widths.

Deliberately out of scope: a scene format, an asset system, or a game loop. Those belong
to a host, and keeping them out is what makes this package reusable.

## Contributing

Issues and pull requests are welcome. Two things to know before opening one:

- **`libs/flecs` is vendored verbatim and must not be edited.** Changes there are lost at
  the next re-vendor, and `ci/verify-vendor.sh` will fail. If upstream needs fixing, fix
  it upstream; if zecs needs to work around upstream, do it in `src/` and record it in
  [UPSTREAM.md](UPSTREAM.md).
- **Run `ci/run.sh` before pushing** — or `ci/install-hooks.sh` once, and it runs itself.
  It is the same set of steps the workflow runs, with one difference it states at the
  top: the workflow executes the suite on three operating systems, while `ci/run.sh`
  executes it on whichever host you are on and cross-compiles the rest.

## Licence

MIT, see [LICENSE](LICENSE). Vendored flecs is MIT, copyright Sander Mertens.
