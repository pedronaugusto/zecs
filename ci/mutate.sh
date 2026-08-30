#!/usr/bin/env bash
#
# zecs — proof that the ABI guard actually refuses drift.
#
# A guard that passes is indistinguishable from a guard that checks nothing. This
# introduces one deliberate defect at a time into src/, rebuilds, and asserts the build
# *fails with the guard's own message* — then puts the tree back. Each case is a mistake
# that has a real cost if it ships: a field swap silently reinterprets two values, a
# widened parameter corrupts the stack, a deleted declaration is API nobody can reach, an
# over-aligned component is stored at an address it may not legally live at.
#
# Not every refusal in this package is the ABI guard's, so each case names the message it
# expects. A build that fails for some other reason is scored as a survivor: a mutation
# that trips a different error has proved nothing about the guard it was aimed at.
#
# Requires: zig, python3 (the rewrites are python snippets), and a POSIX shell.
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

command -v python3 >/dev/null 2>&1 || {
  echo "ci/mutate.sh needs python3: the rewrites below are python snippets." >&2
  exit 2
}

C=src/c
TODO_FILE=src/abi_todo.zig
ABI_FILE=src/c/abi.zig
COMPONENT_FILE=src/component.zig
WORLD_FILE=src/world.zig

# One backup of the whole of src/. The mutations reach past the declaration modules now
# — a refusal in the typed layer is proved by planting the thing it refuses — and three
# separate backups was already one too many to keep in step. Nothing here adds a file,
# so copying the tree back is a complete restore. The stray `mktemp` that used to sit
# above the `mktemp -d` leaked a file per run.
BACKUP=$(mktemp -d)
cp -R src/. "$BACKUP"/

restore() { cp -R "$BACKUP"/. src/; }
cleanup() { restore; rm -rf "$BACKUP"; }
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

# apply <path-or-directory> <python-expression-file-rewrite>
#
# The rewrite is a python snippet with `s` bound to the file's text; it must reassign `s`
# and it must actually change it — a mutation that fails to apply would otherwise be
# scored as a pass. A directory is searched file by file until one snippet applies: the
# declarations used to live in a single file and now live in `src/c/`, so a mutation
# names the text it changes rather than the file it changes it in.
#
# Echoes the path it changed, or nothing.
apply() {
  local file="$1" script="$2"
  local candidates=("$file")
  if [ -d "$file" ]; then candidates=("$file"/*.zig); fi

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
    then printf '%s' "$candidate"; return 0; fi
  done
  return 1
}

# mutate <name> <file> <script> [expected-signal] [second-file] [second-script]
#
# `expected-signal` is text the build's own diagnostic must contain. It defaults to the
# ABI guard's prefix, because most of these are aimed at the guard; the refusals in the
# typed layer and the link failure have messages of their own, and scoring those against
# the guard's prefix would count a real catch as a wrong failure.
#
# The optional second edit exists for the one defect that takes two: re-binding a symbol
# flecs's header declares and its source never defines means both declaring it and taking
# it off the list that says nobody may.
mutate() {
  local name="$1" file="$2" script="$3"
  local signal="${4:-zecs ABI drift}"
  local file2="${5:-}" script2="${6:-}"
  printf '  %-56s' "$name"

  local applied
  applied=$(apply "$file" "$script")

  if [ -z "$applied" ]; then
    printf '%sNOT APPLIED%s %s(the mutation itself is stale — fix this script)%s\n' "$RED" "$OFF" "$DIM" "$OFF"
    SURVIVED=$((SURVIVED + 1))
    SURVIVORS+=("$name (not applied)")
    restore
    return
  fi

  if [ -n "$file2" ]; then
    if ! apply "$file2" "$script2" >/dev/null; then
      printf '%sNOT APPLIED%s %s(the second edit is stale — fix this script)%s\n' "$RED" "$OFF" "$DIM" "$OFF"
      SURVIVED=$((SURVIVED + 1))
      SURVIVORS+=("$name (second edit not applied)")
      restore
      return
    fi
  fi

  local output
  output=$("${BUILD[@]}" 2>&1)
  local status=$?

  if [ "$status" -eq 0 ]; then
    printf '%sSURVIVED%s\n' "$RED" "$OFF"
    SURVIVED=$((SURVIVED + 1))
    SURVIVORS+=("$name")
  elif printf '%s' "$output" | grep -qF "$signal"; then
    # The build failed *and* the diagnostic this case exists to provoke is in the
    # output — rather than a build that happened to fail for some other reason (a
    # mutated declaration the wrapper also references directly, say, which fails
    # compilation on its own regardless of whether any guard caught anything).
    printf '%scaught%s\n' "$GREEN" "$OFF"
    KILLED=$((KILLED + 1))
  else
    printf '%sWRONG FAILURE%s %s(failed, but not with: %s)%s\n' "$RED" "$OFF" "$DIM" "$signal" "$OFF"
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

# A module silently dropped from src/c.zig's list. Both guards discover what to check by
# walking that list, so a module missing from it is a module neither covers. That is the
# failure mode splitting the declarations introduced, and nothing else here would notice
# it — which it did not, for as long as this case sat below the `exit` that ends the
# script. It was written, committed, described in its own comment as the one regression
# nothing else catches, and never once executed.
mutate 'registry: a module is dropped from the module list' src/c.zig '
s = s.replace("    script,\n", "")
'

printf '\n%sThe ABI vocabulary%s\n' "$BOLD" "$OFF"

# `abi.c_enum` is the integer a C enum compiles to, and it differs between the two
# Windows ABIs: MSVC gives every enum `int`, clang and gcc give an all-non-negative one
# `unsigned int`. Inverting the rule is wrong on BOTH, which is what makes this case
# portable — hard-coding either half passes on the ABI it happens to match, and that is
# exactly how the wrong half shipped.
mutate 'abi: the C enum rule is inverted' "$ABI_FILE" '
s = s.replace("if (builtin.target.abi == .msvc) c_int else c_uint",
              "if (builtin.target.abi == .msvc) c_uint else c_int")
'

# `va_list` is compared by what it POINTS AT as well as by width, because every shape it
# takes is eight bytes wide on the targets where it is a pointer at all. Widening the
# pointee is the mistake that width alone would miss.
mutate 'abi: the va_list pointee is the wrong type' "$ABI_FILE" '
s = s.replace(".windows, .uefi => [*c]u8,", ".windows, .uefi => [*c]u64,", 1)
'

printf '\n%sRefusals in the typed layer%s\n' "$BOLD" "$OFF"

# flecs allocates a component column with a plain `ecs_os_malloc`, so 16 bytes is the
# strongest alignment it can give one. Resolving `Component(T)` is what refuses more, and
# this plants a type needing 32 to prove the refusal is reached rather than merely
# written: a `@compileError` cannot be caught, so from inside the language a refusal wired
# up wrongly and a refusal that never fires are the same thing.
mutate 'refusal: an over-aligned component is registered' "$COMPONENT_FILE" '
s = s.replace("""test "a zero-sized type is a tag" {""",
              """test "a zero-sized type is a tag" {
    _ = Component(struct { v: f32 align(32) });""", 1)
' 'zecs cannot store'

# A `deinit` that also wants an allocator cannot be called from a flecs hook, which is
# handed nothing but the pointer. Same shape of proof.
mutate 'refusal: a deinit that needs more than the value' "$WORLD_FILE" '
s = s.replace("""fn hasDeinit(comptime T: type) bool {""",
              """test "planted: a deinit taking an allocator is refused" {
    _ = typeHooks(struct {
        x: u8 = 0,
        pub fn deinit(self: *@This(), _: u8) void {
            _ = self;
        }
    });
}

fn hasDeinit(comptime T: type) bool {""", 1)
' 'zecs cannot derive a destructor'

printf '\n%sThe link%s\n' "$BOLD" "$OFF"

# flecs 4.1.6 declares `ecs_id(EcsPipelineQuery)` in its header and defines it nowhere in
# its source. Binding it produces a package that cannot be linked — which is invisible to
# any comparison of two declarations, and visible to a linker only once something takes
# the address. This re-binds it and takes it off the list that records why nobody may,
# and expects the link to refuse. It is the proof for the test that references every
# extern the package declares.
mutate 'link: a symbol nothing defines is bound again' "$TODO_FILE" '
s = s.replace("""    "FLECS_IDEcsPipelineQueryID_",\n""", "", 1)
' 'undefined symbol' "$C" '
s = s.replace("""pub extern const EcsWildcard: ecs_entity_t;""",
              """pub extern const EcsWildcard: ecs_entity_t;
pub extern const FLECS_IDEcsPipelineQueryID_: ecs_entity_t;""", 1)
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

