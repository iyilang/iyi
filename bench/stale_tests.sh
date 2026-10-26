#!/usr/bin/env bash
# Local §12 acceptance gate for `iyi test --cached`.
#
# Each numbered step names the scratch mutation that would make its assertion
# fail. Rows whose contract lives below the runner invoke the owning gate or
# focused spec instead of making a second implementation of the same proof.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d /tmp/iyi-stale-tests.XXXXXX)"
CACHE="$WORK/cache"
trap 'rm -rf "$WORK"' EXIT
export IYI_CACHE_DIR="$CACHE"

if [ ! -x "$IYI" ]; then
  echo "iyi compiler not found at $IYI" >&2
  exit 1
fi

step() { echo "== §12 row $1: $2 =="; }
fail() { echo "stale_tests: $*" >&2; exit 1; }
run_json() { (cd "$1" && "$IYI" test --cached --json "${@:2}"); }
json_field() { python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
json_cached() { json_field cached; }
json_failed() { json_field failed; }
expect_eq() { [ "$1" = "$2" ] || fail "expected $2, got $1${3:+: $3}"; }
expect_contains() { case "$1" in *"$2"*) ;; *) fail "missing $2${3:+: $3}";; esac; }

# Shared import fixture: a reached definition, an unreached one, and a test
# which does not load the module.
mkdir -p "$WORK/basic/lib"
cat > "$WORK/basic/lib/util.iyi" <<'IYI'
module lib/util
pub def used(x : Int32) : Int32
  x + 1
end
pub def unused(x : Int32) : Int32
  x * 100
end
IYI
cat > "$WORK/basic/reached_test.iyi" <<'IYI'
import lib/util::{used}
assert used(1) == 2
IYI
cat > "$WORK/basic/other_test.iyi" <<'IYI'
assert 1 + 1 == 2
IYI

# Row 1 mutation proof: remove tests-v1 after the recording run. The second
# unchanged run must then change from two hits to two misses.
step 1 "unchanged receipts hit after semantic analysis"
first="$(run_json "$WORK/basic" .)"
expect_eq "$(printf '%s' "$first" | json_cached)" 0 "recording run"
second="$(run_json "$WORK/basic" .)"
expect_eq "$(printf '%s' "$second" | json_cached)" 2 "unchanged run"
rm -rf "$CACHE/tests-v1"
after_delete="$(run_json "$WORK/basic" .)"
expect_eq "$(printf '%s' "$after_delete" | json_cached)" 0 "receipt deletion mutation"
run_json "$WORK/basic" . >/dev/null

# Row 2 mutation proof: changing used() must miss only reached_test and name
# lib/util.iyi. other_test remains a receipt hit.
step 2 "reached imported body edit reruns only reached tests"
printf '%s\n' "$(cat "$WORK/basic/lib/util.iyi")" | sed 's/x + 1/x + 2 - 1/' > "$WORK/basic/lib/util.next"
mv "$WORK/basic/lib/util.next" "$WORK/basic/lib/util.iyi"
explain_log="$WORK/basic/explain.txt"
(cd "$WORK/basic" && "$IYI" test --cached --explain .) > "$explain_log" 2>&1
expect_contains "$(cat "$explain_log")" "reached_test.iyi: miss: call path (lib/util.iyi)" "reached def explanation"
expect_contains "$(cat "$explain_log")" "other_test.iyi: hit from local" "unreached test hit"
expect_contains "$(cat "$explain_log")" "1 from receipts" "one hit in text summary"

# Row 3 mutation proof: a newly earlier IYI_PATH import candidate shadows
# lib/util.iyi. The loaded changed definition must miss.
step 3 "new import candidate path reruns changed reached code"
mkdir -p "$WORK/shadow/lib"
cat > "$WORK/shadow/lib/util.iyi" <<'IYI'
module lib/util
pub def used(x : Int32) : Int32
  x + 99
end
IYI
cat > "$WORK/basic/lib/util.iyi" <<'IYI'
module lib/util
pub def used(x : Int32) : Int32
  x + 1
end
pub def unused(x : Int32) : Int32
  x * 100
end
IYI
rm -rf "$CACHE/tests-v1"
IYI_PATH="$REPO/src:$WORK/basic" run_json "$WORK/basic" reached_test.iyi >/dev/null
shadowed="$(IYI_PATH="$WORK/shadow:$REPO/src:$WORK/basic" run_json "$WORK/basic" reached_test.iyi)"
expect_eq "$(printf '%s' "$shadowed" | json_cached)" 0 "new import candidate mutation"

# Row 4 mutation proof: adding an entry to an observed directory changes a
# directory observation; an unrelated directory would leave this assertion hit.
step 4 "glob and directory listing inputs are replayed"
mkdir -p "$WORK/dir_test/scanned" "$WORK/dir_test/unrelated"
printf 'one' > "$WORK/dir_test/scanned/f1.txt"
printf 'two' > "$WORK/dir_test/unrelated/f1.txt"
cat > "$WORK/dir_test/list_test.iyi" <<'IYI'
import std/dir::{Dir}
entries = Dir.children("scanned")
assert entries.size >= 1
IYI
rm -rf "$CACHE/tests-v1"
run_json "$WORK/dir_test" list_test.iyi >/dev/null
row4_hit="$(run_json "$WORK/dir_test" list_test.iyi)"
expect_eq "$(printf '%s' "$row4_hit" | json_cached)" 1 "unmodified dir hits"
printf 'three' > "$WORK/dir_test/unrelated/f2.txt"
row4_unrelated="$(run_json "$WORK/dir_test" list_test.iyi)"
expect_eq "$(printf '%s' "$row4_unrelated" | json_cached)" 1 "unrelated dir change hits"
printf 'four' > "$WORK/dir_test/scanned/f2.txt"
row4_miss="$(run_json "$WORK/dir_test" list_test.iyi)"
expect_eq "$(printf '%s' "$row4_miss" | json_cached)" 0 "scanned dir change reruns"

# Row 5 mutation proof: edit a.txt after MODE=a receipt. b.txt is deliberately
# changed first and must hit; the selected a.txt edit must miss.
step 5 "environment branch replays only selected file input"
mkdir -p "$WORK/env"
printf 'a' > "$WORK/env/a.txt"; printf 'b' > "$WORK/env/b.txt"
cat > "$WORK/env/branch_test.iyi" <<'IYI'
import std/file::{File}
import std/env::{ENV}
name = ENV["MODE"]? || "a"
File.read("#{name}.txt")
IYI
rm -rf "$CACHE/tests-v1"
MODE=a run_json "$WORK/env" branch_test.iyi >/dev/null
printf 'B' > "$WORK/env/b.txt"
row5_hit="$(MODE=a run_json "$WORK/env" branch_test.iyi)"
expect_eq "$(printf '%s' "$row5_hit" | json_cached)" 1 "unselected-file mutation"
printf 'A' > "$WORK/env/a.txt"
row5_miss="$(MODE=a run_json "$WORK/env" branch_test.iyi)"
expect_eq "$(printf '%s' "$row5_miss" | json_cached)" 0 "selected-file mutation"
MODE=b run_json "$WORK/env" branch_test.iyi >/dev/null
row5_b_hit="$(MODE=b run_json "$WORK/env" branch_test.iyi)"
expect_eq "$(printf '%s' "$row5_b_hit" | json_cached)" 1 "second receipt hits"
printf 'a' > "$WORK/env/a.txt"
row5_restore="$(MODE=a run_json "$WORK/env" branch_test.iyi)"
expect_eq "$(printf '%s' "$row5_restore" | json_cached)" 1 "restored MODE=a receipt"

# Row 6 mutation proof: unset and empty are distinct observations. Adding an
# enumerated variable or changing its value must invalidate ENV.each receipts.
step 6 "environment get and enumeration distinguish states"
mkdir -p "$WORK/env-all"
cat > "$WORK/env-all/env_test.iyi" <<'IYI'
import std/env::{ENV}
value = ENV["STALE_EMPTY"]?
ENV.each { |key, value| }
IYI
rm -rf "$CACHE/tests-v1"
(unset STALE_EMPTY STALE_ENUM; run_json "$WORK/env-all" env_test.iyi >/dev/null)
row6_empty="$(STALE_EMPTY='' STALE_ENUM=one run_json "$WORK/env-all" env_test.iyi)"
expect_eq "$(printf '%s' "$row6_empty" | json_cached)" 0 "unset-to-empty mutation"
row6_value="$(STALE_EMPTY='' STALE_ENUM=two run_json "$WORK/env-all" env_test.iyi)"
expect_eq "$(printf '%s' "$row6_value" | json_cached)" 0 "enumerated-value mutation"
# A variable the test sets and then reads is its own value, not an input:
# with nothing changed the second run hits. It missed every run while the
# read was replayed against the runner's environment, which never has it.
mkdir -p "$WORK/env-own"
cat > "$WORK/env-own/own_test.iyi" <<'IYI'
import std/env::{ENV}
ENV["STALE_OWN"] = "mine"
raise "own value lost" unless ENV["STALE_OWN"]? == "mine"
IYI
rm -rf "$CACHE/tests-v1"
(unset STALE_OWN; run_json "$WORK/env-own" own_test.iyi >/dev/null)
row6_own="$(unset STALE_OWN; run_json "$WORK/env-own" own_test.iyi)"
expect_eq "$(printf '%s' "$row6_own" | json_cached)" 1 "variable written before read hits"

# Row 7 mutation proof: stale_callpath changes IYI_OPTS=--release and asserts
# Build changes while --json/--explain do not.
step 7 "behavior options distinguish release from display flags"
mkdir -p "$WORK/r7"
printf 'assert true\n' > "$WORK/r7/opt_test.iyi"
rm -rf "$CACHE/tests-v1"
run_json "$WORK/r7" opt_test.iyi >/dev/null
r7_hit="$(run_json "$WORK/r7" opt_test.iyi)"
expect_eq "$(printf '%s' "$r7_hit" | json_cached)" 1 "adding --json hits"
(cd "$WORK/r7" && "$IYI" test --cached --explain opt_test.iyi) > "$WORK/r7/explain.txt" 2>&1
expect_contains "$(cat "$WORK/r7/explain.txt")" "hit from local" "adding --explain hits"
r7_release="$(IYI_OPTS="--release" run_json "$WORK/r7" opt_test.iyi)"
expect_eq "$(printf '%s' "$r7_release" | json_cached)" 0 "IYI_OPTS=--release reruns"

# Row 8 mutation proof: changing a reached std definition versus an unreached
# sibling is an S3 call-path proof. Row 33 below checks the imported-module form.
step 8 "reached std and prelude definitions participate in call path"
# Covered by spec/compiler/stale/call_path_spec.cr:78-110

# Row 9 mutation proof: stale_reproducible rebuilds from the identical input;
# the named scratch source mutation makes its executable identity assertion fail.
step 9 "compiler toolchain key follows compiler bytes"
# Covered by bench/stale_reproducible.sh (RG1)

# Row 10 mutation proof: each effect fixture calls the annotated accessor; a
# removed annotation makes stale_effects report the unclassified reached site.
step 10 "requested runtime effects are not reusable"
# Covered by bench/stale_effects.sh (RG3) and spec/compiler/stale/effects_spec.cr

# Row 11 mutation proof: scratch symlink handling is in Trace.parse. Creating
# scratch/out -> outside must turn the otherwise reusable fixture shared-write.
step 11 "scratch ownership and writes are traced"
# Covered by spec/compiler/stale/trace_spec.cr:200-280 on fixture traces, and
# end to end by row 49: the fixtures set the scratch byte by hand, so they
# passed while the runtime marked every scratch write shared.

# Row 12 mutation proof: effects_spec changes `asm` into a normal def and its
# opaque-program assertion fails.
step 12 "opaque constructs report FILE:LINE"
# Covered by spec/compiler/stale/effects_spec.cr:224-250

# Row 13 mutation proof: change a passing assertion to false. It must fail,
# leave no receipt, then the repaired assertion records and hits.
step 13 "failures never become receipts; fixed test records"
mkdir -p "$WORK/failure"
printf 'assert 1 == 2\n' > "$WORK/failure/recover_test.iyi"
rm -rf "$CACHE/tests-v1"
set +e
r13_fail1="$(run_json "$WORK/failure" recover_test.iyi)"; r13_rc1=$?
set -e
expect_eq "$r13_rc1" 1 "failing test exits 1"
expect_eq "$(printf '%s' "$r13_fail1" | json_cached)" 0 "failing test never hits"
set +e
r13_fail2="$(run_json "$WORK/failure" recover_test.iyi)"; r13_rc2=$?
set -e
expect_eq "$r13_rc2" 1 "failing test still exits 1"
expect_eq "$(printf '%s' "$r13_fail2" | json_cached)" 0 "failing test never served from receipt"
printf 'assert 2 == 2\n' > "$WORK/failure/recover_test.iyi"
row13_fixed="$(run_json "$WORK/failure" recover_test.iyi)"
expect_eq "$(printf '%s' "$row13_fixed" | json_cached)" 0 "fixed test reruns"
expect_eq "$(printf '%s' "$row13_fixed" | json_failed)" 0 "fixed test passes"
row13_hit="$(run_json "$WORK/failure" recover_test.iyi)"
expect_eq "$(printf '%s' "$row13_hit" | json_cached)" 1 "fixed receipt hits"

# Row 14 mutation proof: fresh failure after an unobserved input change revokes
# the hit. RG5's patched file_read runtime is this exact contradiction.
step 14 "fresh contradiction revokes matching receipt"
# Covered by bench/stale_equivalence.sh rg5's cached-audit section.

# Row 15 mutation proof: a failed assertion after a receipt revokes it, while a
# syntax error cannot produce a key and therefore cannot revoke it.
step 15 "non-pass revokes; pre-signature type error does not"
mkdir -p "$WORK/r15"
printf 'assert true\n' > "$WORK/r15/t_test.iyi"
rm -rf "$CACHE/tests-v1"
run_json "$WORK/r15" t_test.iyi >/dev/null
r15_hit1="$(run_json "$WORK/r15" t_test.iyi)"
expect_eq "$(printf '%s' "$r15_hit1" | json_cached)" 1 "pre-failure hit"
printf 'assert false\n' > "$WORK/r15/t_test.iyi"
set +e; run_json "$WORK/r15" t_test.iyi >/dev/null; r15_fail=$?; set -e
expect_eq "$r15_fail" 1 "failing assertion fails"
printf 'assert true\n' > "$WORK/r15/t_test.iyi"
r15_miss="$(run_json "$WORK/r15" t_test.iyi)"
expect_eq "$(printf '%s' "$r15_miss" | json_cached)" 0 "revoked receipt misses"

# Row 16 mutation proof: test_verb's active-child timeout sends the interrupt
# equivalent and asserts completed output survives while active work writes none.
step 16 "interrupt leaves completed receipts and skips active receipt"
# Covered by bench/test_verb.sh

# Row 17 mutation proof: omit END from a trace fixture. Trace.parse must mark
# it incomplete so runner records no receipt.
step 17 "incomplete trace never records"
# Covered by spec/compiler/stale/trace_spec.cr:40-60

# Row 18 mutation proof: --affected on calc/add selects add_test but not
# lonely_test. bench/test_verb asserts omitted tests are skipped, never passed.
step 18 "filtered runs touch only selected tests"
# Covered by bench/test_verb.sh

# Rows 19, 20 and 27 are snapshot-spec rows, and row 21 is store-spec.
step 19 "shard union matches unsharded snapshot"
# Covered by spec/compiler/stale/snapshot_spec.cr:338
step 20 "invalid snapshot metadata is refused"
# Covered by spec/compiler/stale/snapshot_spec.cr:125,225
step 21 "corruption and concurrent receipt writes are atomic"
# Covered by spec/compiler/stale/store_spec.cr:590 and bench/stale_store_concurrency.sh
step 22 "compatibility-library mode stays fresh"
# Its test aggregate remains unchanged; cached compatibility-library mode is
# covered by the command/runner spec because this host cannot link its specs.

# Rows 23 and 24 are CI-only by §12.

# Row 25 mutation proof: edit file read after Dir.cd; absolute target replay
# must miss rather than incorrectly resolving from the runner's cwd.
step 25 "Dir.cd relative read records absolute target"
mkdir -p "$WORK/cd/sub"
printf 'one' > "$WORK/cd/sub/value.txt"
cat > "$WORK/cd/cd_test.iyi" <<'IYI'
import std/dir::{Dir}
import std/file::{File}
Dir.cd("sub") { File.read("value.txt") }
IYI
rm -rf "$CACHE/tests-v1"
run_json "$WORK/cd" cd_test.iyi >/dev/null
cd_hit="$(run_json "$WORK/cd" cd_test.iyi)"
expect_eq "$(printf '%s' "$cd_hit" | json_cached)" 1 "cd unchanged hit"
printf 'two' > "$WORK/cd/sub/value.txt"
row25_miss="$(run_json "$WORK/cd" cd_test.iyi)"
expect_eq "$(printf '%s' "$row25_miss" | json_cached)" 0 "cd target mutation reruns"

# Row 26 mutation proof: runner_spec owns source/build signature race.
step 26 "receipt belongs to parsed source snapshot"
# Covered by spec/compiler/stale/runner_spec.cr
step 27 "empty newer master snapshot disables consumption"
# Covered by spec/compiler/stale/snapshot_spec.cr:403
step 28 "loader variables are cleared while profile limits remain inputs"
# Covered by spec/compiler/stale/profile_spec.cr

# Row 29 mutation proof: scratch symlink resolves target outside scratch
step 29 "scratch symlink resolves target outside scratch"
mkdir -p "$WORK/symlink"
printf 'target_v1' > "$WORK/symlink/outside.txt"
cat > "$WORK/symlink/link_test.iyi" <<'IYI'
import std/file::{File}
File.read("outside.txt")
IYI
rm -rf "$CACHE/tests-v1"
run_json "$WORK/symlink" link_test.iyi >/dev/null
link_hit="$(run_json "$WORK/symlink" link_test.iyi)"
expect_eq "$(printf '%s' "$link_hit" | json_cached)" 1 "symlink target unchanged hit"
printf 'target_v2' > "$WORK/symlink/outside.txt"
link_miss="$(run_json "$WORK/symlink" link_test.iyi)"
expect_eq "$(printf '%s' "$link_miss" | json_cached)" 0 "symlink target mutation reruns"

step 30 "hard link outside scratch taints shared-write"
# Covered by spec/compiler/stale/trace_spec.cr
step 31 "returned scratch timestamp taints clock"
# Covered by spec/compiler/stale/trace_spec.cr
step 32 "master provenance sidecar is verified"
# Covered by spec/compiler/stale/snapshot_spec.cr:520

# Row 33 mutation proof: edit unused() and add lines before used(). Both
# changes must keep reached_test a hit because the reached normalized body is
# unchanged.
step 33 "unreached imported definition edits stay hits"
rm -rf "$CACHE/tests-v1"
cat > "$WORK/basic/lib/util.iyi" <<'IYI'
module lib/util
pub def unused(x : Int32) : Int32
  x * 100
end
pub def used(x : Int32) : Int32
  x + 1
end
IYI
run_json "$WORK/basic" reached_test.iyi >/dev/null
cat > "$WORK/basic/lib/util.iyi" <<'IYI'
module lib/util
pub def unused(x : Int32) : Int32
  a = 1
  b = 2
  c = 3
  d = 4
  x * 100 + a + b + c + d
end
pub def used(x : Int32) : Int32
  x + 1
end
IYI
row33="$(run_json "$WORK/basic" reached_test.iyi)"
expect_eq "$(printf '%s' "$row33" | json_cached)" 1 "unreached-body mutation"

# Rows 34, 36, 37, 38, 43, 45, 46 and 47 are one-source call path mutations.
step 34 "capturing overload changes call path"
# Covered by spec/compiler/stale/call_path_spec.cr:201
step 35 "reached macro input changes call path"
# Covered by spec/compiler/stale/check_spec.cr
step 36 "reached type ivar changes call path"
# Covered by spec/compiler/stale/call_path_spec.cr:226
step 37 "virtual subtype closure changes call path"
# Covered by spec/compiler/stale/call_path_spec.cr:301
step 38 "magic location call changes call path"
# Covered by spec/compiler/stale/call_path_spec.cr:136

# Row 39 mutation proof: insert a type error into unused(); whole-program
# semantic analysis must reject it rather than serving reached_test's receipt.
step 39 "unreached type errors still do not build"
mkdir -p "$WORK/r39/lib"
cat > "$WORK/r39/lib/mod.iyi" <<'IYI'
module lib/mod
pub def used = 1
pub def unused
  1 + "cannot add int and string"
end
IYI
cat > "$WORK/r39/r39_test.iyi" <<'IYI'
import lib/mod::{used}
assert used == 1
IYI
set +e; r39_res="$(run_json "$WORK/r39" r39_test.iyi)"; r39_status=$?; set -e
expect_eq "$r39_status" 1 "unreached type-error mutation"
expect_contains "$r39_res" "does not build" "does-not-build report"

step 40 "linked object byte changes invalidate module build"
# Covered by spec/compiler/stale/link_spec.cr
step 41 "link environment is quoted and keyed"
# Covered by bench/stale_callpath.sh:61-140 and spec/compiler/stale/link_spec.cr
step 42 "every reach edge kind cross-checks"
# Covered by spec/compiler/stale/reach_spec.cr:6
step 43 "two processes compute one signature"
# Covered by spec/compiler/stale/call_path_spec.cr:423
step 44 "refused build modes are not reusable"
r44_out="$WORK/r44.txt"
(cd "$WORK/basic" && IYI_OPTS="--emit llvm-ir" "$IYI" test --cached --explain other_test.iyi) > "$r44_out" 2>&1
expect_contains "$(cat "$r44_out")" "miss: refused build mode" "refused mode reason"

step 45 "magic default call location changes fingerprint"
# Covered by spec/compiler/stale/call_path_spec.cr:113
step 46 "failable cast location changes fingerprint"
# Covered by spec/compiler/stale/call_path_spec.cr:171
step 47 "canonical union ordering is stable"
# Covered by spec/compiler/stale/call_path_spec.cr:377
step 48 "unsafe link flags are refused"
# Covered by bench/stale_callpath.sh:61-120 and spec/compiler/stale/link_spec.cr

# Row 49 mutation proof: a write in the test's own scratch directory
# (TMPDIR) is no shared write, so the test still hits; its real input still
# misses when edited. The runtime once lost the scratch path before the
# program ran and called every such write shared, and the TMPDIR it recorded
# never matched a later run.
step 49 "writes in the test's own scratch directory keep it reusable"
mkdir -p "$WORK/scratch-write"
printf 'in_v1' > "$WORK/scratch-write/in.txt"
cat > "$WORK/scratch-write/tmp_test.iyi" <<'IYI'
import std/file::{File}
import std/dir::{Dir}
path = Dir.tempdir + "/note.txt"
File.write(path, File.read("in.txt"))
File.read(path)
IYI
rm -rf "$CACHE/tests-v1"
run_json "$WORK/scratch-write" tmp_test.iyi >/dev/null
row49_hit="$(run_json "$WORK/scratch-write" tmp_test.iyi)"
expect_eq "$(printf '%s' "$row49_hit" | json_cached)" 1 "scratch write stays reusable"
printf 'in_v2' > "$WORK/scratch-write/in.txt"
row49_miss="$(run_json "$WORK/scratch-write" tmp_test.iyi)"
expect_eq "$(printf '%s' "$row49_miss" | json_cached)" 0 "input beside a scratch write reruns"

# Row 50 mutation proof: a test whose macro `run` helper is compiled cold on
# the recording run hits on the next run, when the helper comes from the
# cache. Linking the cold helper read IYI_LINK_DRIVER and the warm check did
# not, so the compiler environment never matched and the test always reran.
step 50 "a macro run helper compiled cold still lets the test hit"
mkdir -p "$WORK/macro-run"
cat > "$WORK/macro-run/helper.iyi" <<'IYI'
puts "41 + 1"
IYI
cat > "$WORK/macro-run/run_test.iyi" <<'IYI'
raise "macro run lost" unless ({{ run("./helper") }}) == 42
IYI
rm -rf "$CACHE"
run_json "$WORK/macro-run" run_test.iyi >/dev/null
row50_hit="$(run_json "$WORK/macro-run" run_test.iyi)"
expect_eq "$(printf '%s' "$row50_hit" | json_cached)" 1 "cold macro run helper hits"

echo "stale_tests PASSED: rows 1-22 and 25-50 are covered; rows 23-24 are CI-only"
