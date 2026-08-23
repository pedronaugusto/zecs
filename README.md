# zecs

[![CI](https://github.com/pedronaugusto/zecs/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/zecs/actions/workflows/ci.yml)

Zig bindings for [flecs](https://github.com/SanderMertens/flecs) — an entity component
system, in a package with no engine, no renderer and no asset system attached.

- Vendored, pinned upstream flecs (4.1.6). Three files, byte for byte, no patches. See
  [UPSTREAM.md](UPSTREAM.md), and `ci/verify-vendor.sh`, which proves it rather than
  claiming it.
- **All 1028 symbols flecs exports are declared**, and that is enforced by the compiler
  rather than asserted here: a function in the header that nothing binds fails the build.
- Every declaration is checked against the real header at compile time — struct fields by
  name and offset, functions by arity and per-parameter width, constants by value. Drift
  is a **build failure**, not a memory-corruption bug. `ci/mutate.sh` proves the check
  refuses seventeen kinds of deliberate defect.
- Host allocator injection: every allocation flecs makes can go through your
  `std.mem.Allocator`, and the tests assert it all comes back.
- A typed layer written to a rule, not to a coverage target — see
  [What gets a wrapper](#what-gets-a-wrapper).

## Usage

```zig
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
    // Before the first world. Afterwards it is an error, for a reason worth reading:
    // see "Allocator injection" below.
    try zecs.setAllocator(gpa);

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

    while (world.progress(0)) {}
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

The typed layer sits on top and is what you would normally use: `World`, `Component(T)`,
`Query`, `Iter`. It adds type checking, slices with the right length, errors where flecs
returns a zero id, and nothing else. Both layers describe the same objects, so mixing
them is normal rather than an escape:

```zig
const world = try zecs.World.init();
zecs.c.ecs_set_target_fps(world.raw, 60); // whatever the wrapper has not covered
```

And for anything not declared even in `zecs.c` — flecs has a large surface, and this
package mirrors what it uses — the header is installed with the library:

```zig
exe.linkLibrary(zecs_dep.artifact("flecs"));
const flecs = @cImport(@cInclude("flecs.h"));
```

That escape hatch is still documented, but it is no longer the answer to anything:
`zecs.c` declares every symbol flecs exports, so there is nothing left for it to reach.

### What gets a wrapper

The raw layer is complete because completeness there is free and checkable. The typed
layer is neither, so it is written to a rule instead of to a coverage target.

**The typed layer is the only code in this package that nothing verifies.** The ABI guard
proves `src/c.zig` against the header; nothing proves a wrapper against `src/c.zig`
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

`src/c.zig` hand-writes the flecs API: every `extern fn`, every `extern struct`, every
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
verified current by `zig build abi-manifest-check`. Anything in it that `src/c.zig` does
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

What it does not catch: translate-c renders every C pointer as `[*c]T`, so pointee types
are compared by size and alignment only. The behaviour suite covers that residue by
driving the declarations and checking real answers.

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

**Everything else.** `-Dshared`, `-Dlow_footprint`, `-Dsoft_assert`, `-Ddisable_counters`,
`-Dfloat_t`, `-Dftime_t`, and the sizing constants (`-Dterm_count_max`,
`-Dhi_component_id`, `-Dentity_page_bits`, and the rest). `zig build -h` lists them all.

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

Numbers below are from `zig build bench -Doptimize=ReleaseFast`, best of five runs per
case, on an Apple M3 Max. They describe this machine and this benchmark; run it on yours.

```
create entity with one component                16.6 ns/op         60.3 M/s
set a component by entity                        9.2 ns/op        108.4 M/s
get a component by entity                        1.9 ns/op        518.1 M/s
add a tag (moves the entity's table)            24.6 ns/op         40.6 M/s
remove a tag (moves it back)                    24.2 ns/op         41.4 M/s
query iteration, cached                          0.5 ns/op       1861.3 M/s
query iteration, uncached                        0.5 ns/op       1921.5 M/s
progress, single threaded                        0.5 ns/op       1928.1 M/s
progress, 4 threads                              0.3 ns/op       3625.1 M/s
```

The wrapper does not appear in these figures by design: `Iter` is one pointer, the
accessors are `inline`, component handles are values rather than a global keyed by type,
and the callback thunk is generated at compile time. What is measured is flecs.

**On `-Duse_os_alloc`.** `FLECS_USE_OS_ALLOC` turns off flecs's block allocator, so every
small object goes to the allocator you injected instead of coming from a pool. Measured
over the run above, that is **1 325 250 allocator calls instead of 292 345** — 4.5× the
traffic. The time cost is smaller than that ratio suggests: entity creation goes from
16 ns to 21 ns, and iteration does not change at all, because iteration allocates nothing
either way.

Which is why the default depends on the build rather than being one answer. In Debug it
is on, so every allocation is individually visible to a leak checker. In release it is
off, so flecs's own pooling does the work it was written to do. Both are tested, in CI,
in both modes.

## Testing

```sh
zig build test
```

Two suites. The unit tests cover the ABI guard and the allocator bridge from inside the
package. The behaviour tests drive the public module exactly as a consumer does, with no
privileged imports — anything they need that is not exported is a gap in the API rather
than something to work around.

Between them, 127 tests: world lifecycle, component registration, the full
add/set/get/ensure/remove round-trip, tags, entity liveness and id recycling, naming and
parenting, query iteration, optional and negated terms, `Up` traversal into a parent,
`Cascade` ordering down a hierarchy, early exit from an iterator, observers firing on set,
systems running from the pipeline and by hand, deferred and readonly scopes leaving
balanced, bulk creation, typed column slices agreeing with entity-by-entity reads, a Zig
struct round-tripping through reflection to JSON and back, scripts creating what they
describe and refusing what they cannot parse, timers firing at their rate, alerts raising
and clearing, and a four-thread pipeline that has to visit every entity exactly once and
give every byte back.

```sh
zig build bench -Doptimize=ReleaseFast   # the numbers above
ci/mutate.sh                             # prove the ABI guard still refuses drift
ci/run.sh                                # the CI matrix, locally
ci/run.sh --quick                        # native Debug only, for the inner loop
ci/install-hooks.sh                      # run it automatically before every push
```

`ci/run.sh` reports every failure rather than stopping at the first.

### Continuous integration

CI runs the suite on **Linux, macOS and Windows** in four optimize modes, through both
allocator paths, plus the Windows MSVC ABI; builds eleven further option configurations
whose whole purpose is to move the structs the ABI test checks; cross-compiles eight
targets; and verifies the vendored copy against upstream. See
[`.github/workflows/ci.yml`](.github/workflows/ci.yml).

### Platform coverage

| | Suite executed by CI | Compile-checked by CI |
|---|---|---|
| Linux | x86_64 (glibc) | + aarch64, musl on both |
| macOS | aarch64 | + x86_64 |
| Windows | x86_64, both gnu and MSVC ABI | + aarch64 |

Compiling proves the sources and the build graph are portable; only an executed
configuration proves behaviour, which is why the two are separate jobs.

That table describes the matrix, not a promise: **the badge at the top of this file is the
authority on whether those runs have actually happened and passed.** At the time of
writing the suite has been executed by hand on macOS/aarch64 only — everything else in it
has been cross-compiled but never run.

## Scope

**The raw layer is complete.** Every symbol the vendored flecs exports — 1028 of them — is
declared in `zecs.c`, and the build fails if that stops being true.

The typed layer covers, by the rule above:

| | |
|---|---|
| world | lifecycle, frames, stages, threading, deferring, readonly mode, lookup scopes, exclusive access — each begin/end pair as a scope type with an idempotent `end` |
| entities | creation, the full component access set, bulk operations, names and paths, pairs as typed component handles, lifecycle hooks derived from `@typeInfo(T)` |
| queries | descriptors, traversal, caching, term operators, `each`, iteration, change detection |
| systems | phases, intervals, multi-threading, custom pipelines, timers, modules as Zig types |
| storage | tables with typed column slices, records, read/write guards, refs, values |
| reflection | `zecs.meta` derives a flecs schema from a Zig type — see below |
| serialisation | JSON both ways, doc strings, and `ecs_strbuf_t` as a `std.Io.Writer` |
| script | scripts, expressions, variables, diagnostics |
| observability | stats windows, metrics, alerts, the app loop, REST for the Explorer |

Left raw on purpose, because a wrapper would fail all five parts of the rule: the vector,
map, sparse-set and hashmap containers; the OS API beyond the allocator seam; the meta
cursor; the statistics record structs; most of the HTTP server. Each is named in the
module that decided it, with the reason.

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
  It is the same matrix CI runs.

## Licence

MIT, see [LICENSE](LICENSE). Vendored flecs is MIT, copyright Sander Mertens.
