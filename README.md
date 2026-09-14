# zecs

[![CI](https://github.com/pedronaugusto/zecs/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/zecs/actions/workflows/ci.yml)

zecs is a Zig binding for [flecs](https://github.com/SanderMertens/flecs), Sander
Mertens's entity component system. flecs 4.1.6 is vendored in `libs/flecs` and compiled
by this package's `build.zig`; what you import is a Zig API over it, with the C API
declared verbatim underneath.

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

    // Before the first world; afterwards it is an error. See "Allocators".
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

    // `progress` returns false once something has called `world.quit()`; a real host
    // loops on that.
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

[`examples/basic`](examples/basic) is a separate project with its own build graph that
depends on this one by path and does the same work through the typed query spec. CI
builds and runs it on Linux, macOS and Windows: nothing inside a package can prove the
package is usable from outside it.

## Install

```sh
zig fetch --save git+https://github.com/pedronaugusto/zecs
```

```zig
const zecs_dep = b.dependency("zecs", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zecs", zecs_dep.module("zecs"));
```

The package has no dependencies, and flecs is not fetched: `libs/flecs` is three files
copied byte for byte from upstream 4.1.6 with no patches, pinned by
[UPSTREAM.md](UPSTREAM.md) and checked against upstream by `ci/verify-vendor.sh` in CI.
Zig compiles them, so no C toolchain is needed beyond the one Zig ships.

`zig build docs` generates the API reference into `zig-out/docs` from the doc comments in
`src/`.

## The API

There are two layers and no wall between them.

`zecs.c` is flecs's C API declared verbatim — `ecs_world_t`, `ecs_entity_init`,
`EcsOnUpdate`, `ecs_query_desc_t`. Not renamed, not restructured, so C documentation, C
examples and C answers apply to it unchanged. The declarations are grouped one file per
area under `src/c/`, and the area is part of the path: `zecs.c.entity.ecs_new`,
`zecs.c.query.ecs_query_init`, `zecs.c.world.ecs_set_target_fps`.

`zecs.c` declares every symbol the vendored flecs 4.1.6 exports. The generated
`src/api_tiers.zig` splits them: 819 are flecs's documented C API, 99 are what a public
macro expands to (`ecs_id(T)` is `FLECS_ID<T>ID_`, and Zig has no macros, so that
spelling is the public one for the component-id globals), and 109 are flecs's internals,
which carry no stability contract across an upstream patch release. `src/abi_todo.zig`,
the list of exports nothing binds, is empty, and `zig build abi-manifest-check` with the
coverage sweep in `src/abi_check.zig` fail the build if it stops being. One export is
excepted and named there: `FLECS_IDEcsPipelineQueryID_` is declared in `flecs.h` and
defined nowhere in the amalgamation, so there is nothing to bind to.

The typed layer sits on top and is what you would normally use: `World`, `Component(T)`,
`Query`, `Iter`. It adds type checking, slices with the right length, errors where flecs
returns a zero id, and nothing else. It covers:

| | |
|---|---|
| world | lifecycle, frames, stages, threading, deferring, readonly mode, lookup scopes, exclusive access — each begin/end pair as a scope type with an idempotent `end` |
| entities | creation, the full component access set including `emplace` and `count`, singletons, per-component enable/disable, bulk operations, names and paths, pairs as typed component handles, prefabs and instantiation, lifecycle hooks derived from `@typeInfo(T)` |
| queries | descriptors, traversal, caching, term operators, ordering and grouping, iteration, change detection, and `QueryOf.each` for a typed per-entity body |
| systems | phases, intervals, multi-threading, custom pipelines, timers, modules as Zig types |
| storage | tables with typed column slices, records, read/write guards, refs, values |
| reflection | `zecs.meta` derives a flecs schema from a Zig type |
| serialisation | JSON both ways, doc strings, and `ecs_strbuf_t` as a `std.Io.Writer` |
| script | scripts, expressions, variables, diagnostics |
| observability | stats windows, metrics, alerts, the app loop, REST for the Explorer |

It is not a mirror of `zecs.c`. A wrapper exists only where it removes an untyped
parameter, turns a failure sentinel into a Zig error, owns a resource's lifetime,
replaces a C string with a Zig slice, or replaces a C callback with a comptime-generated
thunk; otherwise the raw declaration is the binding. What the typed layer skips is called
through `zecs.c` under flecs's own name, and what is not declared even there through
`@cImport` of the header this package installs — see
[docs/wrapper-rule.md](docs/wrapper-rule.md), which also carries the two extra lines
`@cImport` needs on `x86_64-windows-gnu`.

## Design

### Allocators

`setAllocator` routes flecs's allocations through a `std.mem.Allocator`, and the same
seam sends flecs's logging, its abort and its profiler markers to `setLogHandler`,
`setAbortHandler` and `setTraceHandler`. It is process-wide, because flecs's OS API is; I
surface that rather than hide it behind a per-world parameter that could not be honoured.

flecs accepts an allocator installed after it has started allocating, and then frees
older blocks through the new one. So `setAllocator` returns an error once a world exists,
and while flecs still holds a block — a world going away is not the end of flecs's
memory, because the strings it hands back are freed through the same callback. The
live-block count behind the second check is kept in every build, not only where
`-Dtrack_allocations` compiles the statistics in. The first also cross-checks flecs's
public allocation counters, which catches a world created outside this package through
the raw C API, and is gone in a build with `-Ddisable_counters=true`.

If you run systems on more than one thread, flecs allocates from those threads, so the
allocator you inject has to be thread-safe. [docs/allocators.md](docs/allocators.md) has
the failure modes in full, and the reason every block carries a 16-byte header.

### Iteration, and the shared-field trap

A term matched through `Up`, `Cascade` or a fixed source resolves to one value shared by
the whole table, not an array of them — the parent's transform, the prefab's material.
flecs signals this through `ecs_field_is_self`, and a binding that ignores it hands out a
slice of `count` elements over a single value; reads past the first entity are then out
of bounds, silently, on exactly the queries that use inheritance. So `Iter.field` asks,
and returns a slice of the right length. `Iter.fieldSelf` is for terms known to be
per-entity: one C call cheaper, with the assertion compiled out in ReleaseFast.
`Iter.fieldShared` is for the other side of it.

### Reflection

`zecs.meta.register(world, position)` derives flecs's schema from `@typeInfo(Position)` —
fields with their real `@offsetOf`, enums with their values, `packed struct(u32)` as a
bitmask, arrays, nested types registered once and memoised. The struct is then
introspectable by the Explorer, serialisable by the JSON API and editable over REST with
no hand-written schema. Zig reorders struct fields, so this uses flecs's `use_offset`
rather than recomputing layout. What cannot be derived is refused with a `@compileError`
naming the type and the reason: pointers, slices, optionals, unions, `@Vector`, and
non-standard integer widths.

### The ABI guard

`src/c/` is hand-written, and nothing in either compiler checks that it still agrees with
the header. `src/abi_check.zig` does: it `@cImport`s the real header in a test and
compares the two namespaces by reflection — struct fields by name and offset, functions
by arity and per-parameter width, constants by value. Drift is a build failure rather
than a memory-corruption bug, and `ci/mutate.sh` plants one deliberate defect at a time
and requires the build to fail for each. What the guard covers, what it cannot see, and
what it has caught: [docs/abi-guard.md](docs/abi-guard.md).

### Build options

Everything flecs exposes as a compile-time choice is a build option, and every option
that affects the ABI is mirrored into a Zig module that `zecs.c` reads its array sizes
from — one source, both sides, checked by the guard.

**Addons.** The default is the same set upstream enables when you define nothing, which
is everything except the four that are opt-in there too. To take only what you need:

```sh
zig build -Daddons=minimal -Daddon_system=true -Daddon_pipeline=true \
          -Daddon_meta=true -Daddon_log=true
```

flecs enables an addon's dependencies itself — asking for `pipeline` also compiles
`module`, `system` and `timer` — so `zecs.options` reports what was *requested*. For what
was actually compiled, `ecs_log_set_level(0)` before creating a world prints the list.

| option | default | effect |
|---|---|---|
| `-Ddebug_checks` | `auto` | flecs's sanitize-level checks in Debug, none in release. `none` also defines `NDEBUG`, so a release build pays nothing for the thousands of asserts inside flecs. |
| `-Dkeep_assert` | off | flecs's asserts on top of an optimized build. |
| `-Dsoft_assert` | off | a recoverable error instead of an abort. |
| `-Duse_os_alloc` | Debug | every small object to the injected allocator instead of flecs's block allocator. `-Dlow_footprint` implies it. |
| `-Dsanitize_c` | Debug | Zig's C undefined-behaviour sanitizer over flecs. |
| `-Dtrack_allocations` | Debug | the bytes and the allocation count handed to flecs, readable at runtime. |
| `-Ddebug_info` | off | flecs's annotations on its internal structures, which the natvis visualisers read. |
| `-Daccurate_counters` | off | global statistics counters exact under threading, at a cost. |
| `-Ddisable_counters` | off | no statistics counters, and with them no cross-check under [Allocators](#allocators). |
| `-Dno_always_inline` | off | drops flecs's `always_inline`: smaller binary, slower code. |
| `-Ddefault_to_uncached_queries` | off | a query is uncached unless it needs a cache: less memory per query, slower iteration, and `Query.cacheKind` reports differently. |

`-Dshared`, `-Dfloat_t`, `-Dftime_t` and the sizing constants (`-Dterm_count_max`,
`-Dhi_component_id`, `-Dentity_page_bits`, and the rest) are options too. `zig build -h`
lists every one with its default, generated from `build.zig`.

### Performance

`zig build bench -Doptimize=ReleaseFast` prints a provenance header and reports every
case as a multiple of a plain-slice floor measured in the same build. No numbers are
quoted in this repository; [docs/benchmarks.md](docs/benchmarks.md) says what the figures
do and do not control for.

## Scope

- flecs is vendored at 4.1.6, not fetched. There is no option to build against a
  different copy or a different version.
- The typed layer does not cover every flecs call; what it skips is reached through
  `zecs.c`.
- The vector, map, sparse-set and hashmap containers stay raw; Zig has slices,
  `ArrayList` and `AutoHashMap`.
- The threading, dynamic-library and filesystem halves of flecs's OS API stay raw; Zig
  has `std.Thread`, `std.DynLib` and `std.fs`.
- The meta cursor, the statistics record structs and most of the HTTP server have no
  typed wrapper.

## Platforms

| platform | suite executed by CI | compile-checked by CI |
|---|---|---|
| Linux | x86_64, glibc | aarch64 glibc, x86_64 and aarch64 musl |
| macOS | aarch64 | x86_64 |
| Windows | x86_64, gnu and MSVC ABI | aarch64 gnu |

On an executed platform the suite runs in four optimize modes, through both allocator
paths, and with the widest addon set. Compile-checked means `zig build test-compile
-Daddons=everything`: every Zig source analysed, the ABI guard run against the header as
preprocessed for that target, and both test binaries linked.

Every job in that matrix passed on run
[`34779606583`](https://github.com/pedronaugusto/zecs/actions/runs/34779606583).

## Testing

```sh
zig build test          # both suites
ci/run.sh               # the workflow's roster, on this machine
ci/run.sh --quick       # native Debug only, for the inner loop
ci/mutate.sh            # require the ABI guard to refuse planted drift
ci/install-hooks.sh     # run ci/run.sh before every push
```

The unit tests cover the ABI guard and the allocator bridge from inside the package. The
behaviour tests drive the public module as a consumer does, with no privileged imports,
across the entity, query, system, storage, reflection, serialisation, script and
observability surface listed above, including a four-thread pipeline that has to visit
every entity exactly once and give every byte back. `ci/run.sh` reports every failure
rather than stopping at the first, and `ci/check-mirror.sh` fails if its set of
build-option combinations has stopped matching the workflow's.
[docs/testing.md](docs/testing.md) has the full list and the roster's `--target` flag.

## Requirements

Zig 0.16.0. The package links libc and needs no C toolchain of its own.

## Contributing

Issues and pull requests are welcome. `libs/flecs` is vendored verbatim and must not be
edited: changes there are lost at the next re-vendor and `ci/verify-vendor.sh` fails. A
workaround for upstream goes in `src/` and is recorded in [UPSTREAM.md](UPSTREAM.md).
Run `ci/run.sh` before pushing, or `ci/install-hooks.sh` once and it runs itself.

## Licence

MIT, see [LICENSE](LICENSE), which covers this package's own code and not `libs/flecs`.

`libs/flecs` is a verbatim copy of flecs, vendored rather than fetched (see
[UPSTREAM.md](UPSTREAM.md)), and is distributed under its own MIT licence: copyright
Sander Mertens, with portions copyright Meta Platforms, Inc. and affiliates. The full
text ships with the package as `libs/flecs/LICENSE`. That second holder is why this
notice names two rather than one: flecs carries a contribution whose copyright is not its
author's, and a notice naming only him would be incomplete for the bytes in this
repository.
