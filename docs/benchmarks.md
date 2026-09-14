# Benchmarks

```sh
zig build bench -Doptimize=ReleaseFast
```

No numbers are printed in this file or in the README. A ns/op describes the machine that
produced it, and a table pasted into a document is a measurement with its provenance
stripped off and no way to notice when it stops being true. The benchmark prints its own
header instead — UTC date, zecs and flecs versions, compiler, target triple, CPU model,
optimize mode, every option that was set, and which allocator flecs was given — so a
figure quoted from it can be traced back to the run that made it.

Two things about how it is built:

- Every case is printed under a floor. Each section opens with the same arithmetic over
  plain Zig slices, at the same entity count, in the same build, and every case after it
  reports its multiple of that floor. The floor is not a competitor — an ECS exists so
  the component set can vary per entity, which an array cannot do — it is the scale that
  turns a digit into a claim.
- The header lists what the numbers do not control for: an unpinned machine, one table,
  one shape of data, no comparison against any other ECS. Read that list before quoting
  anything.

The wrapper does not appear in the figures by design: `Iter` is one pointer, the
accessors are `inline`, component handles are values rather than a global keyed by type,
and the callback thunk is generated at compile time. What is measured is flecs.

## `-Duse_os_alloc`

`FLECS_USE_OS_ALLOC` turns off flecs's block allocator, so every small object goes to the
allocator you injected instead of coming from a pool. The benchmark reports the allocator
call count for the run, so the two configurations can be compared directly on your
machine — run it both ways rather than trusting a ratio measured on someone else's.

That is why the default depends on the build rather than being one answer. In Debug it is
on, so every allocation is individually visible to a leak checker. In release it is off,
so flecs's own pooling does the work it was written to do. Both are tested, in both
modes.
