#!/usr/bin/env bash
#
# zecs — prove libs/flecs is really unmodified upstream.
#
# UPSTREAM.md says the vendored files are a pristine copy of a specific commit. On its
# own that is a claim in a markdown file: nothing stops an edit to libs/ from landing
# while the documentation still says otherwise. This script turns the claim into a check
# by fetching that exact commit and comparing byte for byte.
#
# It is also the reason a git submodule is not used here. A submodule would have git
# record the upstream commit, which is genuinely useful — but Zig's package manager
# fetches a source archive and never resolves submodules, so consumers would receive an
# empty libs/ and a build that cannot work. This gets the guarantee without the breakage.
#
# Needs network, so it is a separate CI job rather than part of ci/run.sh.
#
# Usage: ci/verify-vendor.sh

set -euo pipefail
cd "$(dirname "$0")/.."

# Kept in step with UPSTREAM.md by the check below, so the two cannot drift.
UPSTREAM_URL="https://github.com/SanderMertens/flecs.git"
UPSTREAM_TAG="v4.1.6"
UPSTREAM_COMMIT="fb55f3c25660425cfe1bc4cf5e6bff8b3f18a9b8"

# Vendored file -> path within the upstream tree it was copied from.
VENDORED=(
  "flecs.c:distr/flecs.c"
  "flecs.h:distr/flecs.h"
  "LICENSE:LICENSE"
)

if [ -t 1 ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; OFF=$'\033[0m'
else
  RED=; GREEN=; DIM=; OFF=
fi

fail() { printf '%s%s%s\n' "$RED" "$1" "$OFF" >&2; exit 1; }

# The pin must appear in UPSTREAM.md verbatim. If someone bumps one and not the other,
# that is exactly the drift this script exists to catch.
grep -q "$UPSTREAM_COMMIT" UPSTREAM.md ||
  fail "UPSTREAM.md does not mention $UPSTREAM_COMMIT — the pin has drifted."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

printf '%sfetching %s at %s%s\n' "$DIM" "$UPSTREAM_URL" "$UPSTREAM_TAG" "$OFF"
git clone --quiet --depth 1 --branch "$UPSTREAM_TAG" "$UPSTREAM_URL" \
  "$work/upstream" 2>/dev/null || fail "clone failed"

# A tag can be moved; the commit cannot. Check the SHA, not the label.
actual=$(git -C "$work/upstream" rev-parse HEAD)
[ "$actual" = "$UPSTREAM_COMMIT" ] ||
  fail "tag $UPSTREAM_TAG is $actual, expected $UPSTREAM_COMMIT"
printf '%scommit %s confirmed%s\n' "$DIM" "$UPSTREAM_COMMIT" "$OFF"

status=0
for entry in "${VENDORED[@]}"; do
  local_name=${entry%%:*}
  upstream_path=${entry#*:}

  if [ ! -e "libs/flecs/$local_name" ]; then
    printf '  %-12s %sMISSING locally%s\n' "$local_name" "$RED" "$OFF"
    status=1
    continue
  fi

  if cmp -s "$work/upstream/$upstream_path" "libs/flecs/$local_name"; then
    printf '  %-12s %sidentical%s %s(%s)%s\n' \
      "$local_name" "$GREEN" "$OFF" "$DIM" "$upstream_path" "$OFF"
  else
    printf '  %-12s %sDIFFERS%s %s(%s)%s\n' \
      "$local_name" "$RED" "$OFF" "$DIM" "$upstream_path" "$OFF"
    diff "$work/upstream/$upstream_path" "libs/flecs/$local_name" | head -20 |
      sed 's/^/      /'
    status=1
  fi
done

# Nothing else may live under libs/. A stray file is not covered by the comparison
# above, so it would otherwise be an unnoticed local addition to a "pristine" tree.
unexpected=$(find libs -type f ! -name flecs.c ! -name flecs.h ! -name LICENSE)
if [ -n "$unexpected" ]; then
  printf '  %sunexpected files under libs/:%s\n' "$RED" "$OFF"
  printf '%s\n' "$unexpected" | sed 's/^/      /'
  status=1
fi

if [ $status -ne 0 ]; then
  printf '\n%slibs/flecs is not a pristine copy of %s.%s\n' \
    "$RED" "$UPSTREAM_COMMIT" "$OFF" >&2
  printf 'Either revert the local change, or — if the divergence is intended —\n' >&2
  printf 'record it in UPSTREAM.md and teach this script about it.\n' >&2
  exit 1
fi

printf '\n%slibs/flecs matches upstream %s exactly%s\n' \
  "$GREEN" "$UPSTREAM_COMMIT" "$OFF"
