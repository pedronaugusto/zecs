# Allocators

`zecs.setAllocator` routes flecs's allocations through a `std.mem.Allocator`. It is
process-wide, because flecs's OS API is: one struct of function pointers for the whole
program, latched on first use. I surface that rather than hide it behind a per-world
parameter that could not be honoured.

The same seam carries the rest of what flecs reaches the outside world through.
`setLogHandler`, `setAbortHandler` and `setTraceHandler` route its logging, its abort and
its profiler markers into Zig. The threading, dynamic-library and filesystem halves are
left to flecs's own implementation; `src/os.zig` says which fields are routed and why.

## The two ways flecs lets you get this wrong

**Patching the OS API without asking for its defaults first is a crash.** Setting the API
latches it, and flecs then never installs the defaults, leaving the logging, abort, clock
and threading callbacks null. It calls one of them during world creation. The binding
always performs the full sequence — read the defaults, overwrite the fields it owns,
install the result — so this cannot happen through it.

**Installing an allocator late is accepted, not refused.** `ecs_os_set_api` is a no-op
once the API is initialized and reports nothing. With the OS API implementation addon
compiled in, which is the default, it is worse: the call *succeeds* and swaps the
allocator while flecs holds live blocks from the previous one. Every later free of an
older block then goes to the wrong allocator.

## What the binding does about it

`setAllocator` refuses once a world exists, and returns an error rather than asserting.
It also cross-checks flecs's public allocation counters, which catches a world created
outside this package entirely, through the raw C API. What it cannot catch is that same
case in a build with `-Ddisable_counters=true`.

A world going away is not the end of flecs's memory either — the strings it hands back
are freed through the same callback, whether that is a `zecs.Str`, a path, a string from
the json or the doc module, or anything a `zecs.strbuf.Owned` still holds. So a swap is
refused while flecs still holds a block. That live-block count is kept in every build, at
the cost of one relaxed read-modify-write on each side of an allocation that reached the
OS API at all; `-Dtrack_allocations` governs only the numbers `zecs.allocationStats`
reports.

## Two details of the bridge

Blocks carry a 16-byte header, because flecs frees with a bare pointer and no size while
Zig needs both, and 16 is the alignment C's `malloc` guarantees. flecs stores component
data in these blocks, and a component holding a SIMD vector has to land aligned without
asking.

If you run systems on more than one thread, flecs allocates from those threads, so the
allocator you inject has to be thread-safe. The suite checks that path with a threaded
pipeline.
