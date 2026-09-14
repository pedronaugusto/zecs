# Testing

```sh
zig build test                           # both suites
zig build test-unit                      # the ABI guard and the allocator bridge only
zig build test-compile                   # build and link the test binaries without running
ci/run.sh                                # the workflow's roster, on this machine
ci/run.sh --quick                        # native Debug only, for the inner loop
ci/run.sh --target x86_64-windows-msvc   # the whole roster on one ABI instead
ci/mutate.sh                             # require the ABI guard to refuse planted drift
ci/install-hooks.sh                      # run ci/run.sh before every push
```

## The two suites

The unit tests cover the ABI guard and the allocator bridge from inside the package.

The behaviour tests drive the public module exactly as a consumer does, with no
privileged imports: anything they need that is not exported is a gap in the API rather
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

The test count is not written down. `zig build test` prints it, and it is right by
construction; a number in a document would be right on the day it was typed.

## The local roster

`ci/run.sh` runs the same steps as `.github/workflows/ci.yml` so a failure can be
reproduced on the machine that caused it, and reports every failure rather than stopping
at the first. `ci/check-mirror.sh` holds that claim: it compares the set of build-option
combinations each file executes — every `-D` except `-Dtarget` and `-Doptimize`, read as
logical lines so a continued command counts once — and fails if they have drifted apart.
It runs in CI.

`--target` is there because "the suite passes" is a claim about an ABI rather than about
a machine. Windows has two, and they disagree about the width of a C enum — a difference
this package had wrong. Every build in the script carries the arm, so a step added later
cannot be one-ABI by omission:

```sh
ci/run.sh --target native-native-msvc
ci/mutate.sh -Dtarget=x86_64-windows-msvc
```

## What CI adds on top

The workflow builds a further set of option configurations whose purpose is to move the
structs the ABI test checks — addon subsets, the sizing constants, both float precisions,
each checking level, the shared library. It regenerates `src/abi_manifest.zig` and
`src/api_tiers.zig` and fails if either is stale, compiles the benchmark, generates the
docs, checks that `build.zig.zon`'s `paths` ships the repository, checks that every
committed script is executable, and verifies the vendored copy against upstream.
