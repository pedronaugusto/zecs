# What gets a wrapper

The raw layer is complete because completeness there is free and checkable: the header
says what exists, and the guard fails the build over anything missing. The typed layer is
neither free nor checkable, so it is written to a rule instead of to a coverage target.

The typed layer is the only code in this package that nothing verifies. The ABI guard
proves `src/c/` against the header; nothing proves a wrapper against `src/c/` except the
tests written for it. A mechanical 1:1 wrapper that adds no type information is therefore
pure unguarded surface — a second name for the same call, twice the documentation, twice
to keep in step, and a fresh place for a bug no guard can catch.

So a wrapper exists only when it does at least one of these:

1. removes an untyped parameter — `void*` plus a size becomes a typed slice or `*T`;
2. turns a failure sentinel (`0`, `NULL`) into a Zig error;
3. owns a resource whose lifetime Zig should manage;
4. replaces a C string with a Zig slice;
5. replaces a C callback with a comptime-generated thunk.

Otherwise the raw declaration *is* the binding: first-class, ABI-verified, and documented
as the way to call that function rather than as a fallback.

If you find a wrapper that fails all five tests, it is a bug.

## Adapters rather than mirrors

Where flecs offers something Zig already has, this package binds an adapter rather than a
mirror:

- `ecs_strbuf_*` becomes a `std.Io.Writer`.
- The vector, map, sparse-set and hashmap containers stay raw, because Zig has slices,
  `ArrayList` and `AutoHashMap`.
- The threading, dynamic-library and filesystem halves of the OS API stay raw, because
  Zig has `std.Thread`, `std.DynLib` and `std.fs`.
- The meta cursor, the statistics record structs and most of the HTTP server stay raw.

Each of those is named in the module that decided it, with the reason.

The OS API's other seams do get wrappers, because they are callbacks rather than
containers and a C function pointer is not something a Zig host can hand over as itself:
`setLogHandler`, `setAbortHandler` and `setTraceHandler` route flecs's logging, its abort
and its profiler markers into Zig alongside the allocator.

## Reaching what has no wrapper

Anything the typed layer skips is reachable as `zecs.c` under flecs's own name, and both
layers describe the same objects, so mixing them is normal rather than an escape:

```zig
const world = try zecs.World.init();
zecs.c.world.ecs_set_target_fps(world.raw, 60);
```

Behind that, the header is installed with the library, so a consumer can reach
declarations by `@cImport` even if this package had bound none:

```zig
exe.root_module.linkLibrary(zecs_dep.artifact("flecs"));
const flecs = @cImport(@cInclude("flecs.h"));
```

`linkLibrary` is on the *module* in Zig 0.16, not on the compile step. Both lines are
compiled and run by `examples/basic` on every arm of the matrix, because a snippet
nothing builds is a snippet that goes stale — this one had been wrong since 0.16 renamed
it.

On `x86_64-windows-gnu` in an optimized build that `@cImport` needs two extra lines:

```zig
const flecs = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("flecs.h");
});
```

Nothing to do with flecs. MinGW switches to its fortified `wcscat`/`wcscpy` when
`_FORTIFY_SOURCE` is set, which an optimized build sets, and Zig's translate-c emits
those two as unused local constants and then refuses its own output. Any `@cImport` of
any header that reaches `<string.h>` hits it. It affects only the declarations translate-c
reads, never the compiled library, so undefining it costs a consumer nothing. The example
does this, so the workaround is checked rather than remembered.
