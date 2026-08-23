#!/usr/bin/env bash
#
# zecs — the CI matrix, run locally.
#
# This mirrors .github/workflows/ci.yml so a failure can be reproduced and fixed on your
# own machine instead of in a pull request. Install it as a pre-push hook with
# ci/install-hooks.sh to catch problems before they are pushed at all.
#
# The one difference from the hosted run: CI executes the suite on Linux, macOS and
# Windows, whereas this executes it on whichever host you are on and cross-compiles the
# rest.
#
# Usage:
#   ci/run.sh            # the full matrix
#   ci/run.sh --quick    # native Debug only, for the inner loop
#
# ci/mutate.sh is part of the full run. It can also be run on its own while working on
# the ABI guard, which is the only time it usually needs to be.
#
# Exits non-zero if any step fails, after running every step — one failure should not
# hide the others.

set -uo pipefail
cd "$(dirname "$0")/.."

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

if [ -t 1 ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
else
  RED=; GREEN=; DIM=; BOLD=; OFF=
fi

PASSED=0
FAILED=0
FAILED_NAMES=()

run() {
  local name="$1"; shift
  printf '  %-52s' "$name"
  local start output status elapsed
  start=$(date +%s)
  output=$("$@" 2>&1)
  status=$?
  elapsed=$(( $(date +%s) - start ))

  if [ $status -eq 0 ]; then
    printf '%sok%s %s(%ds)%s\n' "$GREEN" "$OFF" "$DIM" "$elapsed" "$OFF"
    PASSED=$((PASSED + 1))
  else
    printf '%sFAILED%s %s(%ds)%s\n' "$RED" "$OFF" "$DIM" "$elapsed" "$OFF"
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("$name")
    printf '%s' "$output" | sed 's/^/      | /' | head -40
  fi
}

section() { printf '\n%s%s%s\n' "$BOLD" "$1" "$OFF"; }

printf '%szecs local CI%s  %s%s%s\n' "$BOLD" "$OFF" "$DIM" "$(zig version)" "$OFF"

#-----------------------------------------------------------------------------
section 'Hygiene'
#-----------------------------------------------------------------------------

# Our own sources only: libs/flecs is vendored verbatim, and reformatting it would make
# the next re-vendor an unreadable diff — and fail the vendor integrity check.
run 'zig fmt' zig fmt --check src tests bench tools examples build.zig

# src/abi_manifest.zig is generated from the vendored header. If it has gone stale the
# ABI guard is measuring coverage against a list of what flecs used to export, which is
# exactly the moment a re-vendor could add API nobody notices.
run 'abi manifest is current' zig build abi-manifest-check

# The published API reference is generated from the doc comments, so a doc comment that
# does not compile is a broken reference rather than a cosmetic problem.
run 'docs generate' zig build docs

#-----------------------------------------------------------------------------
section 'Tests — native'
#-----------------------------------------------------------------------------

# The default Debug configuration: flecs's own sanitize-level checks, Zig's C
# undefined-behaviour sanitizer, and every allocation routed through the injected
# allocator so the balance-to-zero assertion sees individual objects.
run 'Debug (sanitize, os_alloc)' zig build test

# The release-shaped allocator path, still with the checks on: flecs's block allocator
# serves small objects from pools, so the bridge sees a different pattern entirely.
run 'Debug (block allocator)' zig build test -Duse_os_alloc=false

if [ $QUICK -eq 0 ]; then
  run 'ReleaseSafe' zig build test -Doptimize=ReleaseSafe
  run 'ReleaseFast' zig build test -Doptimize=ReleaseFast
  run 'ReleaseSmall' zig build test -Doptimize=ReleaseSmall

  # A release build with the allocator routed through the OS API — the configuration a
  # host would use to account for flecs's memory in production.
  run 'ReleaseFast (os_alloc)' zig build test -Doptimize=ReleaseFast -Duse_os_alloc=true

  # Checks on in an optimized build. Worth its own run because the build has to undo
  # the NDEBUG that Zig defines for release C, and flecs warns if that goes wrong.
  run 'ReleaseFast (sanitize)' zig build test -Doptimize=ReleaseFast -Ddebug_checks=sanitize

#-----------------------------------------------------------------------------
section 'Tests — build options'
#-----------------------------------------------------------------------------

  # Two kinds of option, checked two ways.
  #
  # An option that changes *behaviour* — which allocator flecs uses, which addons exist,
  # how much it trades for a smaller footprint — gets the whole suite, because behaviour
  # is what changed.
  #
  # An option that only changes *layout* gets `test-unit`, which is the ABI guard and the
  # allocator bridge and nothing else. `-Dterm_count_max=16` moves four fields of
  # `ecs_iter_t`; whether that landed on both sides is a compile-time question, and the
  # guard answers it in three seconds. Re-running the behaviour suite afterwards re-proves
  # what the native section above already proved, at a minute each. Fifteen of those was
  # three quarters of this script's runtime.

  # A lean addon set that still supports the whole suite — and the configuration most
  # likely to be shipped, so it is the one where a test that forgot to gate itself on an
  # addon shows up. `minimal` alone does not catch that: it turns off systems too, so the
  # behaviour suite does not run at all.
  run 'addons: system+pipeline+meta+log' zig build test \
    -Daddons=minimal -Daddon_system=true -Daddon_pipeline=true \
    -Daddon_meta=true -Daddon_log=true

  # One addon off at a time, from a set that has everything else. Each is a configuration
  # where the typed layer must still compile and the tests that need the missing addon
  # must skip rather than fail to link — which is a behavioural claim, so the full suite.
  run 'addons: no json' zig build test -Daddon_json=false
  run 'addons: no doc' zig build test -Daddon_doc=false
  run 'addons: no meta' zig build test -Daddon_meta=false

  # No systems and no pipeline: the behaviour tests cannot run there, the ABI and
  # allocator tests still do.
  run 'addons: minimal' zig build test -Daddons=minimal

  # Every addon on. The only configuration whose header declares every symbol in the ABI
  # manifest, and therefore the only one where the guard's coverage assertions are exact.
  run 'addons: everything' zig build test -Daddons=everything

  # Behavioural: what flecs trades away, and what it stops counting.
  run 'low_footprint' zig build test -Dlow_footprint=true
  run 'disable_counters' zig build test -Ddisable_counters=true

  # Layout only. These move fields in public structs; the guard is what proves the Zig
  # side moved with them.
  run 'term_count_max=8' zig build test-unit -Dterm_count_max=8
  run 'term_count_max=16' zig build test-unit -Dterm_count_max=16
  run 'term_count_max=64' zig build test-unit -Dterm_count_max=64
  run 'event_desc_max=4' zig build test-unit -Devent_desc_max=4
  run 'id_desc_max=8' zig build test-unit -Did_desc_max=8
  run 'ftime_t=fp64' zig build test-unit -Dftime_t=fp64
  run 'float_t=fp64' zig build test-unit -Dfloat_t=fp64
  run 'ftime_t + float_t=fp64' zig build test-unit -Dftime_t=fp64 -Dfloat_t=fp64
  run 'debug_checks=none' zig build test-unit -Ddebug_checks=none
  run 'debug_checks=debug' zig build test-unit -Ddebug_checks=debug
  run 'sparse_page_bits=8' zig build test-unit -Dsparse_page_bits=8
  run 'entity_page_bits=8' zig build test-unit -Dentity_page_bits=8
  run 'term_arg_count_max=8' zig build test-unit -Dterm_arg_count_max=8
  run 'variable_count_max=8' zig build test-unit -Dvariable_count_max=8
  run 'query_variable_count_max=64' zig build test-unit -Dquery_variable_count_max=64
  run 'query_scope_nesting_max=4' zig build test-unit -Dquery_scope_nesting_max=4
  run 'dag_depth_max=16' zig build test-unit -Ddag_depth_max=16
  run 'hi_component_id=64' zig build test-unit -Dhi_component_id=64
  run 'hi_id_record_id=64' zig build test-unit -Dhi_id_record_id=64

  run 'shared library' zig build -Dshared=true

#-----------------------------------------------------------------------------
section 'Example consumer'
#-----------------------------------------------------------------------------

  # A separate project depending on this one by path. Nothing inside the package can
  # prove the package is usable from outside it; only a second build graph can.
  run 'example builds and runs' sh -c 'cd examples/basic && zig build run'
  run 'example, ReleaseFast' sh -c 'cd examples/basic && zig build run -Doptimize=ReleaseFast'

#-----------------------------------------------------------------------------
section 'ABI guard — mutation test'
#-----------------------------------------------------------------------------

  # A guard that passes is indistinguishable from a guard that checks nothing. This
  # introduces one deliberate defect at a time and asserts the build fails. It is the
  # slowest step here, and the only one that measures the tests rather than the code.
  run 'mutations are all caught' ci/mutate.sh

#-----------------------------------------------------------------------------
section 'Cross-compilation'
#-----------------------------------------------------------------------------

  # Compile-only. These prove the sources and the build graph are portable; the tests
  # above are what prove behaviour, on this host. CI executes the suite on Linux, macOS
  # and Windows as well.
  for target in \
    x86_64-linux-gnu \
    aarch64-linux-gnu \
    x86_64-linux-musl \
    aarch64-linux-musl \
    x86_64-windows-gnu \
    aarch64-windows-gnu \
    x86_64-macos \
    aarch64-macos
  do
    run "build $target" zig build -Dtarget="$target"
  done

  # x86_64-windows-msvc is absent here because it needs the Microsoft standard library,
  # which a non-Windows host does not have. CI covers it natively on a Windows runner.
fi

#-----------------------------------------------------------------------------
printf '\n'
if [ $FAILED -eq 0 ]; then
  printf '%s%d passed, 0 failed%s\n' "$GREEN" "$PASSED" "$OFF"
  exit 0
fi

printf '%s%d passed, %d FAILED%s\n' "$RED" "$PASSED" "$FAILED" "$OFF"
for name in "${FAILED_NAMES[@]}"; do
  printf '  %s- %s%s\n' "$RED" "$name" "$OFF"
done
exit 1
