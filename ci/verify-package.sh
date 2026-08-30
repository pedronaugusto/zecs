#!/usr/bin/env bash
#
# zecs — proof that what the package SHIPS is what the repository HAS.
#
# `build.zig.zon`'s `paths` is the list of things a consumer receives. It is written by
# hand, it is checked by nothing at build time, and a missing entry is invisible from
# inside the repository: every local build, every test and every example still works,
# because they read the working tree rather than the package. The failure only appears
# for someone who depends on the package by URL and hash — at which point the fix is a
# new release.
#
# That is not hypothetical here. `examples/` was left out while README pointed at it as
# the way to see the package used, so the one directory a new consumer was told to read
# was the one the package did not contain.
#
# So both directions are checked:
#
#   * everything git tracks at the top level is named in `paths`, except the entries
#     below, which are git's own bookkeeping and mean nothing to a consumer;
#   * everything `paths` names exists.
#
# Usage:
#   ci/verify-package.sh
#
# Exits non-zero if either direction has a gap, after reporting all of them.

set -uo pipefail
cd "$(dirname "$0")/.."

if [ -t 1 ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; OFF=$'\033[0m'
else
  RED=; GREEN=; OFF=
fi

# Tracked, and deliberately not shipped. `.gitignore` describes how to work IN this
# repository, not how to build against it.
NOT_SHIPPED=(.gitignore)

zon=build.zig.zon
[ -f "$zon" ] || { echo "ci/verify-package.sh: no $zon here" >&2; exit 2; }

# The quoted entries inside the `.paths = .{ … }` block, in order.
paths=$(
  awk '
    /^[[:space:]]*\.paths[[:space:]]*=/ { inside = 1; next }
    inside && /^[[:space:]]*\}/         { inside = 0 }
    inside                              { print }
  ' "$zon" | grep -oE '"[^"]+"' | tr -d '"'
)

if [ -z "$paths" ]; then
  printf '%sci/verify-package.sh: found no .paths entries in %s%s\n' "$RED" "$zon" "$OFF" >&2
  exit 2
fi

failures=0

printf 'shipped entries that do not exist\n'
while IFS= read -r p; do
  [ -z "$p" ] && continue
  if [ ! -e "$p" ]; then
    printf '  %smissing:%s %s\n' "$RED" "$OFF" "$p"
    failures=$((failures + 1))
  fi
done <<EOF
$paths
EOF

printf 'tracked entries that are not shipped\n'
while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  for skip in "${NOT_SHIPPED[@]}"; do
    [ "$entry" = "$skip" ] && continue 2
  done
  if ! printf '%s\n' "$paths" | grep -qxF "$entry"; then
    printf '  %sunshipped:%s %s\n' "$RED" "$OFF" "$entry"
    failures=$((failures + 1))
  fi
done < <(git ls-tree --name-only HEAD)

printf '\n'
if [ "$failures" -eq 0 ]; then
  printf '%sbuild.zig.zon ships the repository%s\n' "$GREEN" "$OFF"
  exit 0
fi

printf '%s%d discrepancies between build.zig.zon and the repository%s\n' "$RED" "$failures" "$OFF"
printf 'Add the entry to .paths, or — if it genuinely should not ship — to NOT_SHIPPED\n'
printf 'in this script, where the reason has to be written down.\n'
exit 1
