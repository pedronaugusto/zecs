#!/usr/bin/env bash
#
# zecs — proof that the ABI guard actually refuses drift.
#
# A guard that passes is indistinguishable from a guard that checks nothing. This
# introduces one deliberate defect at a time into src/c.zig or src/abi_todo.zig, rebuilds,
# and asserts the build *fails* — then puts the file back. Each case is a mistake that
# has a real cost if it ships: a field swap silently reinterprets two values, a widened
# parameter corrupts the stack, a deleted declaration is API nobody can reach.
#
# Usage:
#   ci/mutate.sh
#
# Exits non-zero if any mutation survives, after running every case.

set -uo pipefail
cd "$(dirname "$0")/.."

if [ -t 1 ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
else
  RED=; GREEN=; DIM=; BOLD=; OFF=
fi

C=src/c
TODO_FILE=src/abi_todo.zig
BACKUP_C=$(mktemp)
BACKUP_TODO_FILE=$(mktemp)
# $C is a directory of declaration modules, so the backup is a directory too.
BACKUP_C=$(mktemp -d)
cp -R "$C"/. "$BACKUP_C"/
cp "$TODO_FILE" "$BACKUP_TODO_FILE"
BACKUP_REG=$(mktemp)
cp src/c.zig "$BACKUP_REG"

restore() { cp -R "$BACKUP_C"/. "$C"/; cp "$BACKUP_TODO_FILE" "$TODO_FILE"; cp "$BACKUP_REG" src/c.zig; }
cleanup() { restore; rm -rf "$BACKUP_C"; rm -f "$BACKUP_TODO_FILE" "$BACKUP_REG"; }
trap cleanup EXIT INT TERM

SURVIVED=0
KILLED=0
SURVIVORS=()

# Every mutation is checked against the widest configuration, where the guard's coverage
# assertions are exact rather than tolerant of a switched-off addon.
#
# Compiling the tests is enough, and running them is not a stronger check. The guard is a
# compile error by construction, so every defect below is visible the moment the test
# module is analysed — and a suite that failed to compile has nothing left to run.
# Seventeen full test runs took seventeen minutes; seventeen compiles take under two.
BUILD=(zig build test-compile -Daddons=everything)

# mutate <name> <file> <python-expression-file-rewrite>
#
# The rewrite is a python snippet with `s` bound to the file's text; it must reassign `s`
# and it must actually change it — a mutation that fails to apply would otherwise be
# scored as a pass.
# `file` may be one path or a directory of declaration modules. The declarations
# used to live in a single file and now live in `src/c/`, so a mutation names
# the text it changes rather than the file it changes it in, and this finds the
# file that text is in. A snippet matching nothing is a stale mutation and is
# reported as one.
mutate() {
  local name="$1" file="$2" script="$3"
  printf '  %-56s' "$name"

  local candidates=("$file")
  if [ -d "$file" ]; then candidates=("$file"/*.zig); fi

  local applied=""
  local candidate
  for candidate in "${candidates[@]}"; do
    if python3 - "$candidate" <<PY
import sys
p = sys.argv[1]
s = open(p).read()
before = s
$script
if s == before:
    sys.exit(3)
open(p, 'w').write(s)
PY
    then applied="$candidate"; break; fi
  done

  if [ -z "$applied" ]; then
    printf '%sNOT APPLIED%s %s(the mutation itself is stale — fix this script)%s\n' \
      "$RED" "$OFF" "$DIM" "$OFF"
    SURVIVED=$((SURVIVED + 1))
    SURVIVORS+=("$name (not applied)")
    restore
    return
  fi

  local output
  output=$("${BUILD[@]}" 2>&1)
  local status=$?

  if [ "$status" -eq 0 ]; then
    printf '%sSURVIVED%s\n' "$RED" "$OFF"
    SURVIVED=$((SURVIVED + 1))
    SURVIVORS+=("$name")
  elif printf '%s' "$output" | grep -q 'zecs ABI drift'; then
    # The build failed *and* the guard's own compile error is in the output — the
    # signal every one of these mutations exists to prove, rather than a build that
    # happened to fail for some other reason (a mutated declaration the wrapper also
    # references directly, say, which fails compilation on its own regardless of
    # whether the guard caught anything).
    printf '%scaught%s\n' "$GREEN" "$OFF"
    KILLED=$((KILLED + 1))
  else
    printf '%sWRONG FAILURE%s %s(build failed, but not from the ABI guard)%s\n' \
      "$RED" "$OFF" "$DIM" "$OFF"
    SURVIVED=$((SURVIVED + 1))
    SURVIVORS+=("$name (wrong failure)")
  fi
  restore
}

printf '%szecs ABI guard — mutation test%s  %s%s%s\n' "$BOLD" "$OFF" "$DIM" "$(zig version)" "$OFF"
printf '\n%sLayout%s\n' "$BOLD" "$OFF"

# Two same-sized adjacent fields swapping places leaves the *sequence* of offsets
# identical. Only pairing each name with its own offset catches it, which is why the
# guard compares by name rather than by position.
mutate 'struct: two same-sized fields swap places' "$C" '
s = s.replace("""    row: u32 = 0,
    dense: i32 = 0,""", """    dense: i32 = 0,
    row: u32 = 0,""")
'

mutate 'struct: a field changes signedness' "$C" '
s = s.replace("    row: u32 = 0,", "    row: i32 = 0,")
'

mutate 'struct: a field is added' "$C" '
s = s.replace("""    row: u32 = 0,
    dense: i32 = 0,""", """    row: u32 = 0,
    dense: i32 = 0,
    invented: i32 = 0,""")
'

mutate 'struct: a field is dropped' "$C" '
s = s.replace("    dense: i32 = 0,\n", "", 1)
'

mutate 'struct: a defined type is declared opaque' "$C" '
import re
s = re.sub(r"pub const ecs_record_t = extern struct \{.*?\n\};", "pub const ecs_record_t = opaque {};", s, count=1, flags=re.S)
'

printf '\n%sSignatures%s\n' "$BOLD" "$OFF"

mutate 'function: a parameter is dropped' "$C" '
s = s.replace("pub extern fn ecs_add_id(world: *ecs_world_t, entity: ecs_entity_t, id: ecs_id_t) void;",
              "pub extern fn ecs_add_id(world: *ecs_world_t, entity: ecs_entity_t) void;")
'

mutate 'function: a parameter widens' "$C" '
s = s.replace("pub extern fn ecs_field_is_set(it: *const ecs_iter_t, index: i8) bool;",
              "pub extern fn ecs_field_is_set(it: *const ecs_iter_t, index: i64) bool;")
'

mutate 'function: a return type narrows' "$C" '
s = s.replace("pub extern fn ecs_get_target(world: *const ecs_world_t, entity: ecs_entity_t, rel: ecs_entity_t, index: i32) ecs_entity_t;",
              "pub extern fn ecs_get_target(world: *const ecs_world_t, entity: ecs_entity_t, rel: ecs_entity_t, index: i32) u32;")
'

mutate 'callback: a parameter widens' "$C" '
s = s.replace("pub const ecs_ctx_free_t = ?*const fn (ctx: ?*anyopaque) callconv(.c) void;",
              "pub const ecs_ctx_free_t = ?*const fn (ctx: u32) callconv(.c) void;")
'

printf '\n%sConstants%s\n' "$BOLD" "$OFF"

mutate 'constant: a macro value is wrong' "$C" '
s = s.replace("pub const EcsUp: ecs_flags64_t = 1 << 62;", "pub const EcsUp: ecs_flags64_t = 1 << 61;")
'

mutate 'constant: a linked-in id is declared as a literal' "$C" '
s = s.replace("pub extern const EcsChildOf: ecs_entity_t;", "pub const EcsChildOf: ecs_entity_t = 25;")
'

printf '\n%sCoverage%s\n' "$BOLD" "$OFF"

mutate 'coverage: a bound function is deleted' "$C" '
s = s.replace("pub extern fn ecs_get_parent(world: *const ecs_world_t, entity: ecs_entity_t) ecs_entity_t;\n", "", 1)
'

mutate 'coverage: a bound variable is deleted' "$C" '
s = s.replace("pub extern const EcsWildcard: ecs_entity_t;\n", "", 1)
'

# The subtle one. flecs exports a function `ecs_id_is_pair` AND defines a macro
# `ECS_IS_PAIR`, and they are different predicates. Satisfying the coverage sweep with a
# Zig rewrite under the function name would leave the real symbol unbound behind a
# declaration that looks bound.
# The body is deliberately trivial. A lookalike that calls something has to be
# able to SEE it, and after the split the macro this one used to call lives in a
# different module — so the build failed on the missing name instead of on the
# guard, and this script said so rather than counting it. What is being tested
# is that a Zig function wearing an extern's name is refused, not what it does.
mutate 'coverage: an extern is replaced by a Zig lookalike' "$C" '
s = s.replace("pub extern fn ecs_id_is_pair(id: ecs_id_t) bool;",
              "pub inline fn ecs_id_is_pair(id: ecs_id_t) bool { _ = id; return false; }")
'

# The to-do list is empty now that every export is bound, which is what these three
# mutations have to work against: an entry that lies about something already bound, an
# entry out of order, and a repeated entry. All three would leave the guard measuring
# coverage against a list that is not what it says it is.
mutate 'coverage: the to-do list claims something already bound' "$TODO_FILE" '
s = s.replace("""pub const not_yet_declared = [_][]const u8{};""",
              """pub const not_yet_declared = [_][]const u8{
    "ecs_add_id",
};""", 1)
'

# The list is binary-searched, so an entry in the wrong place is an entry nothing checks
# — and it would be a silent hole, which is the worst kind.
mutate 'coverage: the to-do list falls out of order' "$TODO_FILE" '
s = s.replace("""pub const not_yet_declared = [_][]const u8{};""",
              """pub const not_yet_declared = [_][]const u8{
    "zzz_second",
    "zzz_first",
};""", 1)
'

mutate 'coverage: the to-do list repeats an entry' "$TODO_FILE" '
s = s.replace("""pub const not_yet_declared = [_][]const u8{};""",
              """pub const not_yet_declared = [_][]const u8{
    "zzz_same",
    "zzz_same",
};""", 1)
'

printf '\n'
if [ $SURVIVED -eq 0 ]; then
  printf '%s%d mutations, all caught%s\n' "$GREEN" "$KILLED" "$OFF"
  exit 0
fi

printf '%s%d caught, %d SURVIVED%s\n' "$RED" "$KILLED" "$SURVIVED" "$OFF"
for name in "${SURVIVORS[@]}"; do
  printf '  %s- %s%s\n' "$RED" "$name" "$OFF"
done
exit 1

# A module silently dropped from src/c.zig's list. Both guards discover what to
# check by walking that list, so a module missing from it is a module neither
# covers. That is the failure mode splitting the declarations introduced, and
# nothing else in this script would notice it.
mutate 'registry: a module is dropped from the module list' src/c.zig '
s = s.replace("    script,\n", "")
'
