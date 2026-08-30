# Changelog

All notable changes to this package. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this package uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

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
