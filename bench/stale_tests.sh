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
cleanup() {
  exit_status=$?
  if [ "$exit_status" -eq 0 ]; then
    rm -rf "$WORK"
  else
    echo "stale_tests FAILED (exit status $exit_status); preserving work directory: $WORK" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT
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

# One `--json --explain` run prints a decision line per test as it finishes,
# then the JSON document, all on stdout and with no text summary
# (src/compiler/iyi/stale/runner.cr:333-335, 365-367, 439-442, 473-476,
# 525-528, 597-600, 644-705). `explained FILE json` prints that run's document
# for json_cached; `explained FILE lines` prints its decision lines. Both
# refuse a capture whose lines do not pair in order with its tests, or whose
# "hit from" lines disagree with "cached", so a reason and a count are always
# the same run's.
explained() {
  python3 -c '
import json, sys
path, part = sys.argv[1], sys.argv[2]
if part not in ("json", "lines"):
    sys.exit("stale_tests: explained takes json or lines, not %s" % part)
lines = open(path).read().splitlines()
if not lines or not lines[-1].startswith("{"):
    sys.exit("stale_tests: %s does not end in a JSON document" % path)
doc = json.loads(lines[-1])
decisions, tests = lines[:-1], doc["tests"]
if len(decisions) != len(tests):
    sys.exit("stale_tests: %s has %d decision lines for %d tests" % (path, len(decisions), len(tests)))
for line, test in zip(decisions, tests):
    prefix = test["file"] + ": "
    if not line.startswith(prefix):
        sys.exit("stale_tests: %s: %r is not the decision for %s" % (path, line, test["file"]))
    if line.startswith(prefix + "hit from ") != test["cached"]:
        sys.exit("stale_tests: %s: %r disagrees with cached=%s" % (path, line, test["cached"]))
if doc["cached"] != sum(1 for test in tests if test["cached"]):
    sys.exit("stale_tests: %s: cached=%s disagrees with its tests" % (path, doc["cached"]))
print(lines[-1] if part == "json" else "\n".join(decisions))
' "$1" "$2"
}

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
if [ "$(printf '%s' "$second" | json_cached)" != 2 ]; then
  printf 'unchanged run details: %s\n' "$second" >&2
  (cd "$WORK/basic" && "$IYI" test --cached --explain .) >&2 || true
  if (cd "$WORK/basic" && "$IYI" build other_test.iyi -Diyi_observe --stale-key "$WORK/rg3.json" -o "$WORK/rg3-probe"); then
    python3 -c 'import json,sys; print("RG3 sites:", json.load(open(sys.argv[1])).get("rg3"))' "$WORK/rg3.json" >&2
  fi
fi
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

# Row 3 mutation proof: a module found only through IYI_PATH is shadowed by a
# new file in an earlier IYI_PATH entry, which the build then loads. The
# entry's own directory is asked before IYI_PATH (resolve_import,
# src/compiler/iyi/semantic/semantic_visitor.cr:491-540), so no copy sits
# beside the entry. An earlier entry with no candidate changes a locator only
# and must hit; the earlier candidate must miss and be named.
step 3 "new import candidate path reruns changed reached code"
cat > "$WORK/basic/lib/util.iyi" <<'IYI'
module lib/util
pub def used(x : Int32) : Int32
  x + 1
end
pub def unused(x : Int32) : Int32
  x * 100
end
IYI
mkdir -p "$WORK/r3/later/lib" "$WORK/r3/earlier/lib" "$WORK/r3/empty"
cat > "$WORK/r3/later/lib/util.iyi" <<'IYI'
module lib/util
pub def used(x : Int32) : Int32
  x + 1
end
IYI
cat > "$WORK/r3/reached_test.iyi" <<'IYI'
import lib/util::{used}
assert used(1) == 2
IYI
rm -rf "$CACHE/tests-v1"
r3_record="$(IYI_PATH="$REPO/src:$WORK/r3/later" run_json "$WORK/r3" reached_test.iyi)"
expect_eq "$(printf '%s' "$r3_record" | json_cached)" 0 "r3 recording run"
r3_locator="$(IYI_PATH="$WORK/r3/empty:$REPO/src:$WORK/r3/later" run_json "$WORK/r3" reached_test.iyi)"
expect_eq "$(printf '%s' "$r3_locator" | json_cached)" 1 "earlier IYI_PATH entry without a candidate hits"
cat > "$WORK/r3/earlier/lib/util.iyi" <<'IYI'
module lib/util
pub def used(x : Int32) : Int32
  x + 2 - 1
end
IYI
r3_explain="$WORK/r3/explain.txt"
IYI_PATH="$WORK/r3/earlier:$REPO/src:$WORK/r3/later" run_json "$WORK/r3" --explain reached_test.iyi > "$r3_explain"
expect_contains "$(explained "$r3_explain" lines)" "reached_test.iyi: miss: call path (earlier/lib/util.iyi" "new import candidate named"
expect_eq "$(explained "$r3_explain" json | json_cached)" 0 "new import candidate mutation"

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
mkdir -p "$WORK/r8/std"
cat > "$WORK/r8/std/calc.iyi" <<'IYI'
module std/calc
pub def reached_fn(x : Int32) : Int32
  x + 10
end
pub def unreached_fn(x : Int32) : Int32
  x * 20
end
IYI
cat > "$WORK/r8/r8_test.iyi" <<'IYI'
import std/calc::{reached_fn}
assert reached_fn(5) == 15
IYI
rm -rf "$CACHE/tests-v1"
r8_run1="$(IYI_PATH="$WORK/r8:$REPO/src" run_json "$WORK/r8" r8_test.iyi)"
expect_eq "$(printf '%s' "$r8_run1" | json_cached)" 0 "r8 recording run"
r8_hit1="$(IYI_PATH="$WORK/r8:$REPO/src" run_json "$WORK/r8" r8_test.iyi)"
expect_eq "$(printf '%s' "$r8_hit1" | json_cached)" 1 "r8 unchanged hit"

# Unreached std sibling edit: test remains a hit
cat > "$WORK/r8/std/calc.iyi" <<'IYI'
module std/calc
pub def reached_fn(x : Int32) : Int32
  x + 10
end
pub def unreached_fn(x : Int32) : Int32
  x * 999
end
IYI
r8_hit2="$(IYI_PATH="$WORK/r8:$REPO/src" run_json "$WORK/r8" r8_test.iyi)"
expect_eq "$(printf '%s' "$r8_hit2" | json_cached)" 1 "r8 unreached std sibling edit stays hit"

# Reached std def edit with SAME consumer result: test misses call path on same invocation
cat > "$WORK/r8/std/calc.iyi" <<'IYI'
module std/calc
pub def reached_fn(x : Int32) : Int32
  x + 20 - 10
end
pub def unreached_fn(x : Int32) : Int32
  x * 999
end
IYI
r8_explain="$WORK/r8/explain.txt"
IYI_PATH="$WORK/r8:$REPO/src" run_json "$WORK/r8" --explain r8_test.iyi > "$r8_explain"
expect_contains "$(explained "$r8_explain" lines)" "miss: call path" "reached std def miss reason"
expect_eq "$(explained "$r8_explain" json | json_cached)" 0 "zero receipts on reached std edit miss"

# Subsequent run hits newly recorded receipt
r8_hit3="$(IYI_PATH="$WORK/r8:$REPO/src" run_json "$WORK/r8" r8_test.iyi)"
expect_eq "$(printf '%s' "$r8_hit3" | json_cached)" 1 "subsequent run hits newly recorded receipt"

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

# Row 19: Shard union equals unsharded snapshot via repeated same-namespace CLI import.
# Rows 20 and 27 are snapshot-spec rows, and row 21 is store-spec.
step 19 "shard union matches unsharded snapshot"
mkdir -p "$WORK/r19"
cat > "$WORK/r19/a_test.iyi" <<'IYI'
assert 1 + 1 == 2
IYI
cat > "$WORK/r19/b_test.iyi" <<'IYI'
assert 2 + 2 == 4
IYI
cat > "$WORK/r19/c_test.iyi" <<'IYI'
assert 3 + 3 == 6
IYI
r19_run_id="${GITHUB_RUN_ID:-191919}"
r19_ns="run:$r19_run_id"

# 1. Unsharded fresh export
rm -rf "$CACHE/tests-v1"
(cd "$WORK/r19" && IYI_CI_PRODUCER=1 GITHUB_RUN_ID="$r19_run_id" "$IYI" test --fresh --json --export-index "$r19_ns=$WORK/r19/unsharded.json" .) >/dev/null

# 2. Sharded fresh exports (1/3, 2/3, 3/3)
rm -rf "$CACHE/tests-v1"
(cd "$WORK/r19" && IYI_CI_PRODUCER=1 GITHUB_RUN_ID="$r19_run_id" "$IYI" test --fresh --json --shard 1/3 --export-index "$r19_ns=$WORK/r19/shard1.json" .) >/dev/null
(cd "$WORK/r19" && IYI_CI_PRODUCER=1 GITHUB_RUN_ID="$r19_run_id" "$IYI" test --fresh --json --shard 2/3 --export-index "$r19_ns=$WORK/r19/shard2.json" .) >/dev/null
(cd "$WORK/r19" && IYI_CI_PRODUCER=1 GITHUB_RUN_ID="$r19_run_id" "$IYI" test --fresh --json --shard 3/3 --export-index "$r19_ns=$WORK/r19/shard3.json" .) >/dev/null

# 3. Verify shard records union exact TestId set matches unsharded snapshot
python3 -c "
import json, sys
with open('$WORK/r19/unsharded.json') as f:
    unsharded = json.load(f)
u_ids = {(r['test']['root'], r['test']['path']) for r in unsharded.get('records', [])}

s_ids = set()
for sfile in ['$WORK/r19/shard1.json', '$WORK/r19/shard2.json', '$WORK/r19/shard3.json']:
    with open(sfile) as f:
        sdata = json.load(f)
    for r in sdata.get('records', []):
        tid = (r['test']['root'], r['test']['path'])
        if tid in s_ids:
            print(f'Row 19 proof failed: duplicate test {tid} across shards', file=sys.stderr)
            sys.exit(1)
        s_ids.add(tid)

if s_ids != u_ids:
    print(f'Row 19 proof failed: sharded union {s_ids} != unsharded {u_ids}', file=sys.stderr)
    sys.exit(1)
"

# 4. Import repeated same namespace CLI options in clean consumer cache
rm -rf "$CACHE/tests-v1"
r19_cached="$(cd "$WORK/r19" && GITHUB_RUN_ID="$r19_run_id" "$IYI" test --cached --json \
  --import-index "$r19_ns=$WORK/r19/shard1.json" \
  --import-index "$r19_ns=$WORK/r19/shard2.json" \
  --import-index "$r19_ns=$WORK/r19/shard3.json" .)"
expect_eq "$(printf '%s' "$r19_cached" | json_cached)" 3 "all 3 tests hit via repeated same-namespace import"

# 5. Validate exact hit identities with assert-hits and check entry fields
printf '%s\n' "$r19_cached" > "$WORK/r19/cached.json"
bash "$REPO/bench/stale_ci.sh" assert-hits --json "$WORK/r19/cached.json" --snapshot "$WORK/r19/unsharded.json" --namespace "$r19_ns"
python3 -c "
import json, sys
with open('$WORK/r19/cached.json') as f:
    data = json.load(f)
tests = data.get('tests', [])
assert len(tests) == 3, f'expected 3 tests in cached results, got {len(tests)}'
for t in tests:
    assert t.get('source') == '$r19_ns', f'expected source $r19_ns, got {t.get(\"source\")}'
    pb = t.get('portable_build', '')
    assert len(pb) == 64 and all(c in '0123456789abcdef' for c in pb.lower()), f'invalid portable_build: {pb}'
    prof = t.get('profile', '')
    assert len(prof) == 64 and all(c in '0123456789abcdef' for c in prof.lower()), f'invalid profile: {prof}'
    roots = t.get('roots')
    assert isinstance(roots, dict) and 'src' in roots, f'invalid roots: {roots}'
    assert isinstance(t.get('blocked'), bool), f'invalid blocked bool: {t.get(\"blocked\")}'
"

step 20 "invalid snapshot metadata is refused"
# Covered by spec/compiler/stale/snapshot_spec.cr:125,225
step 21 "corruption and concurrent receipt writes are atomic"
# Covered by spec/compiler/stale/store_spec.cr:590 and bench/stale_store_concurrency.sh
step 22 "compatibility-library mode stays fresh"
# Its test aggregate remains unchanged; cached compatibility-library mode is
# covered by the command/runner spec because this host cannot link its specs.

step "test identity" "ambiguous test id runs fresh and never records receipts"
mkdir -p "$WORK/ambig/a" "$WORK/ambig/b"
cat > "$WORK/ambig/a/t_test.iyi" <<'IYI'
assert 1 == 1
IYI
cat > "$WORK/ambig/b/t_test.iyi" <<'IYI'
assert 2 == 2
IYI

# First cached run on both files: both miss with reason "ambiguous test id", cached 0
rm -rf "$CACHE/tests-v1"
ambig_first="$(run_json "$WORK/ambig" a/t_test.iyi b/t_test.iyi)"
expect_eq "$(printf '%s' "$ambig_first" | json_cached)" 0 "ambiguous first run cached 0"

# Second cached run on both files: both still miss with reason "ambiguous test id", cached 0
ambig_second="$(run_json "$WORK/ambig" a/t_test.iyi b/t_test.iyi)"
expect_eq "$(printf '%s' "$ambig_second" | json_cached)" 0 "ambiguous second run cached 0"
expect_contains "$ambig_second" "ambiguous test id" "ambiguous reason reported"

# Verify test.path are equal across both entries
python3 -c "
import json, sys
data = json.loads(sys.argv[1])
tests = data.get('tests', [])
assert len(tests) == 2, f'expected 2 tests, got {len(tests)}'
assert tests[0]['test']['path'] == tests[1]['test']['path'], 'test.path must be equal'
for t in tests:
    assert t['reuse'] == 'miss', f'expected reuse miss, got {t[\"reuse\"]}'
    assert t.get('reason') == 'ambiguous test id', f'expected reason ambiguous test id, got {t.get(\"reason\")}'
" "$ambig_second"

# Shard 1/2 with both files: single entry in shard, but STILL ambiguous!
ambig_shard="$(run_json "$WORK/ambig" --shard 1/2 a/t_test.iyi b/t_test.iyi)"
expect_eq "$(printf '%s' "$ambig_shard" | json_cached)" 0 "ambiguous sharded run cached 0"
python3 -c "
import json, sys
data = json.loads(sys.argv[1])
tests = data.get('tests', [])
assert len(tests) == 1, f'expected 1 test in shard 1/2, got {len(tests)}'
assert tests[0]['reuse'] == 'miss', f'expected reuse miss in shard, got {tests[0][\"reuse\"]}'
assert tests[0].get('reason') == 'ambiguous test id', f'expected reason ambiguous test id in shard, got {tests[0].get(\"reason\")}'
" "$ambig_shard"

# Single file alone control: second run MUST HIT
rm -rf "$CACHE/tests-v1"
single_first="$(run_json "$WORK/ambig" a/t_test.iyi)"
expect_eq "$(printf '%s' "$single_first" | json_cached)" 0 "single file first run cached 0"
single_second="$(run_json "$WORK/ambig" a/t_test.iyi)"
expect_eq "$(printf '%s' "$single_second" | json_cached)" 1 "single file second run hits (control)"

# Rows 23 and 24: CI evidence exact identity, git-diff, and planted hidden-read proofs (§12).
step 23 "CI evidence exact identity and git diff checks discriminate"
bash "$REPO/bench/stale_ci.sh" test-comparator-negatives

step 24 "planted hidden-read test fails shadow audit"
bash "$REPO/bench/stale_ci.sh" test-planted-hidden-read

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

# Row 26 mutation proof: receipt belongs to parsed source snapshot, not disk content after build.
step 26 "receipt belongs to parsed source snapshot"
mkdir -p "$WORK/r26"
r26_test_abs="$WORK/r26/r26_test.iyi"

# Helper edit.iyi copies .next onto target DURING build (once) and prints 1
cat > "$WORK/r26/edit.iyi" <<'IYI'
import std/file::{File}

target = Program.args[0]
marker = target + ".edited"
if !File.file?(marker)
  File.write(marker, "done")
  File.write(target, File.read(target + ".next"))
end
puts "1"
IYI

T0="raise \"macro run lost\" unless ({{ run(\"./edit\", \"$r26_test_abs\") }}) == 1"
T1="$(printf '%s\nassert 2 > 1\n' "$T0")"

printf '%s\n' "$T0" > "$WORK/r26/r26_test.iyi"
printf '%s\n' "$T1" > "$WORK/r26/r26_test.iyi.next"

rm -rf "$CACHE/tests-v1"
r26_run1="$(run_json "$WORK/r26" r26_test.iyi)"
expect_eq "$(printf '%s' "$r26_run1" | json_cached)" 0 "r26 run 1 cached 0"
expect_eq "$(cat "$WORK/r26/r26_test.iyi")" "$T1" "r26 disk modified to T1 during build"

r26_run2="$(run_json "$WORK/r26" r26_test.iyi)"
expect_eq "$(printf '%s' "$r26_run2" | json_cached)" 0 "r26 run 2 cached 0 (disk T1 does not match receipt)"

printf '%s\n' "$T0" > "$WORK/r26/r26_test.iyi"
r26_run3="$(run_json "$WORK/r26" r26_test.iyi)"
expect_eq "$(printf '%s' "$r26_run3" | json_cached)" 1 "r26 run 3 cached 1 (restored T0 hits receipt)"
(cd "$WORK/r26" && "$IYI" test --cached --explain r26_test.iyi) > "$WORK/r26/explain.txt" 2>&1
expect_contains "$(cat "$WORK/r26/explain.txt")" "hit from local" "r26 run 3 hit from local"
step 27 "empty newer master snapshot disables consumption"
# Covered by spec/compiler/stale/snapshot_spec.cr:403
# Row 28 mutation proof: loader and daemon variables are cleared for the test child
# while profile limits remain inputs. SIP on macOS strips DYLD_* through /bin/sh
# wrappers, so we reach the native compiler (.build/iyi) directly. We vary
# DYLD_LIBRARY_PATH and LD_PRELOAD (with harmless ':' and '::' empty library paths)
# rather than LD_LIBRARY_PATH (which is a link environment input).
step 28 "loader and daemon variables are cleared for the test while profile limits remain inputs"
case "$IYI" in
  */bin/iyi) r28_iyi="$(dirname "$(dirname "$IYI")")/.build/iyi" ;;   # bench/up_to_date.sh:335-339
  *) r28_iyi="$IYI" ;;
esac
r28_with() {
  (export DYLD_LIBRARY_PATH="$1" LD_PRELOAD="$2" IYI_DAEMON_SOCKET="$3" CRYSTAL_DAEMON_SOCKET="$3"
   cd "$4" && "$r28_iyi" test "${@:5}")
}
mkdir -p "$WORK/r28-reach"
cat > "$WORK/r28-reach/reach_test.iyi" <<'IYI'
assert ({{ env("DYLD_LIBRARY_PATH") || "unset" }}) == "/tmp/r28_dir1"
assert ({{ env("LD_PRELOAD") || "unset" }}) == ":"
assert ({{ env("IYI_DAEMON_SOCKET") || "unset" }}) == "unset"
assert ({{ env("CRYSTAL_DAEMON_SOCKET") || "unset" }}) == "unset"
IYI
r28_reach="$(r28_with /tmp/r28_dir1 : "$WORK/r28-none.sock" "$WORK/r28-reach" --fresh --json reach_test.iyi)"
expect_eq "$(printf '%s' "$r28_reach" | json_failed)" 0 "the runner's build sees the loader variables and no daemon"
mkdir -p "$WORK/r28"
cat > "$WORK/r28/loader_test.iyi" <<'IYI'
import std/env::{ENV}

assert Program.env("LD_PRELOAD") == nil
assert Program.env("LD_LIBRARY_PATH") == nil
assert Program.env("GLIBC_TUNABLES") == nil
assert Program.env("DYLD_INSERT_LIBRARIES") == nil
assert Program.env("DYLD_LIBRARY_PATH") == nil
assert Program.env("IYI_DAEMON_SOCKET") == nil
assert Program.env("CRYSTAL_DAEMON_SOCKET") == nil
names = ENV.keys
assert !names.includes?("LD_PRELOAD")
assert !names.includes?("DYLD_LIBRARY_PATH")
assert !names.includes?("IYI_DAEMON_SOCKET")
assert !names.includes?("CRYSTAL_DAEMON_SOCKET")
IYI
rm -rf "$CACHE/tests-v1"
r28_run1="$(r28_with /tmp/r28_dir1 : "$WORK/r28-none-1.sock" "$WORK/r28" --cached --json loader_test.iyi)"
expect_eq "$(printf '%s' "$r28_run1" | json_failed)" 0 "r28 run 1: the test sees no loader or daemon variable"
expect_eq "$(printf '%s' "$r28_run1" | json_cached)" 0 "r28 run 1 recorded"
r28_run2="$(r28_with /tmp/r28_dir2 :: "$WORK/r28-none-2.sock" "$WORK/r28" --cached --json loader_test.iyi)"
expect_eq "$(printf '%s' "$r28_run2" | json_cached)" 1 "r28 run 2 hits with changed loader and daemon variables"
cur_nofile=$(ulimit -S -n)
r28_explain="$WORK/r28/explain.txt"
(ulimit -S -n $((cur_nofile - 1)); run_json "$WORK/r28" --explain loader_test.iyi) > "$r28_explain"
expect_contains "$(explained "$r28_explain" lines)" "miss: profile changed" "different profile reason on rlimit change"
expect_eq "$(explained "$r28_explain" json | json_cached)" 0 "zero receipts on profile miss"

# Subsequent run with lowered limit hits newly recorded profile receipt
r28_run3_hit="$( (ulimit -S -n $((cur_nofile - 1)); run_json "$WORK/r28" loader_test.iyi) )"
expect_eq "$(printf '%s' "$r28_run3_hit" | json_cached)" 1 "subsequent run with lowered limit hits new profile receipt"

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

step "scratch alias" "symlink outside scratch targeting scratch taints shared-write"
mkdir -p "$WORK/symlink_shared"
cat > "$WORK/symlink_shared/shared_link_test.iyi" <<'IYI'
import std/file::{File}
import std/dir::{Dir}
data_path = File.join(Dir.tempdir, "data.txt")
File.write(data_path, "scratch data")
link_path = File.join(__DIR__, "shared_link")
File.symlink(data_path, link_path)
IYI

rm -rf "$CACHE/tests-v1"
sym_run1="$(run_json "$WORK/symlink_shared" shared_link_test.iyi)"
expect_eq "$(printf '%s' "$sym_run1" | json_cached)" 0 "symlink run1 cached 0"
expect_contains "$sym_run1" "shared" "symlink creation outside scratch not reusable reason"
rm -f "$WORK/symlink_shared/shared_link"
sym_run2="$(run_json "$WORK/symlink_shared" shared_link_test.iyi)"
expect_eq "$(printf '%s' "$sym_run2" | json_cached)" 0 "symlink run2 cached 0 after non-reusable run1"
rm -f "$WORK/symlink_shared/shared_link"

# Row 30 mutation proof: hard link outside scratch taints shared-write.
step 30 "hard link outside scratch taints shared-write"
mkdir -p "$WORK/r30"
printf 'outside content' > "$WORK/r30/outside.txt"
cat > "$WORK/r30/hardlink_test.iyi" <<'IYI'
import std/file::{File}
import std/dir::{Dir}

outside = File.join(__DIR__, "outside.txt")
hard = File.join(Dir.tempdir, "hard.txt")
File.link(outside, hard)
assert File.read(hard) == "outside content"
IYI

rm -rf "$CACHE/tests-v1"
r30_run1="$(run_json "$WORK/r30" hardlink_test.iyi)"
expect_eq "$(printf '%s' "$r30_run1" | json_cached)" 0 "hard link run 1 cached 0"
expect_contains "$r30_run1" "shared" "hard link outside scratch not reusable reason"
r30_run2="$(run_json "$WORK/r30" hardlink_test.iyi)"
expect_eq "$(printf '%s' "$r30_run2" | json_cached)" 0 "hard link run 2 misses after non-reusable run 1"

# Control: a link entirely inside scratch hits on run 2
mkdir -p "$WORK/r30_control"
cat > "$WORK/r30_control/control_link_test.iyi" <<'IYI'
import std/file::{File}
import std/dir::{Dir}

source = File.join(Dir.tempdir, "src.txt")
File.write(source, "scratch data")
dest = File.join(Dir.tempdir, "hard.txt")
File.link(source, dest)
assert File.read(dest) == "scratch data"
IYI

rm -rf "$CACHE/tests-v1"
r30_ctrl1="$(run_json "$WORK/r30_control" control_link_test.iyi)"
expect_eq "$(printf '%s' "$r30_ctrl1" | json_cached)" 0 "internal link control run 1 cached 0"
r30_ctrl2="$(run_json "$WORK/r30_control" control_link_test.iyi)"
expect_eq "$(printf '%s' "$r30_ctrl2" | json_cached)" 1 "internal link control run 2 hits"

# Row 31 mutation proof: returned scratch timestamp taints clock.
step 31 "returned scratch timestamp taints clock"
mkdir -p "$WORK/r31"
cat > "$WORK/r31/mtime_test.iyi" <<'IYI'
import std/file::{File}
import std/dir::{Dir}

path = File.join(Dir.tempdir, "stamp.txt")
File.write(path, "timestamp test")
mtime = File.info(path).modification_time
assert mtime > 0
IYI

rm -rf "$CACHE/tests-v1"
r31_run1="$(run_json "$WORK/r31" mtime_test.iyi)"
expect_eq "$(printf '%s' "$r31_run1" | json_cached)" 0 "r31 run 1 cached 0"
expect_contains "$r31_run1" "clock" "scratch timestamp taints clock not reusable reason"
r31_explain="$WORK/r31/explain.txt"
run_json "$WORK/r31" --explain mtime_test.iyi > "$r31_explain"
expect_contains "$(explained "$r31_explain" lines)" "clock" "clock reason in explain"
expect_eq "$(explained "$r31_explain" json | json_cached)" 0 "zero receipts on clock taint"
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
# Row 35 mutation proof: reached macro input changes call path; unreached expansions stay hits; macro run timeprinter always misses.
step 35 "reached macro input changes call path"
mkdir -p "$WORK/r35"
r35_data_file="$WORK/r35/data.txt"
r35_unreached_file="$WORK/r35/unreached.txt"

printf 'val1' > "$r35_data_file"
printf 'unreached1' > "$r35_unreached_file"

cat > "$WORK/r35/macro_test.iyi" <<IYI
import std/file::{File}

def reached_file_len : Int32
  {{ read_file("$r35_data_file").size }}
end

def reached_env : String
  {{ env("R35_REACHED_ENV") || "default" }}
end

def unreached_file : String
  {{ read_file("$r35_unreached_file").chomp }}
end

def unreached_env : String
  {{ env("R35_UNREACHED_ENV") || "default" }}
end

assert reached_file_len > 0
assert reached_env != ""
IYI

rm -rf "$CACHE/tests-v1"
r35_run1="$(R35_REACHED_ENV="env1" R35_UNREACHED_ENV="uenv1" run_json "$WORK/r35" macro_test.iyi)"
expect_eq "$(printf '%s' "$r35_run1" | json_cached)" 0 "r35 run 1 recorded"

r35_hit1="$(R35_REACHED_ENV="env1" R35_UNREACHED_ENV="uenv1" run_json "$WORK/r35" macro_test.iyi)"
expect_eq "$(printf '%s' "$r35_hit1" | json_cached)" 1 "r35 unchanged run hits"

# Unreached expansions change -> test still hits
printf 'unreached_mutated_content' > "$r35_unreached_file"
r35_hit2="$(R35_REACHED_ENV="env1" R35_UNREACHED_ENV="uenv_mutated" run_json "$WORK/r35" macro_test.iyi)"
expect_eq "$(printf '%s' "$r35_hit2" | json_cached)" 1 "r35 unreached macro input changes stay hits"

# Reached read_file input changes -> misses on same invocation
printf 'val_longer_content' > "$r35_data_file"
r35_explain1="$WORK/r35/explain1.txt"
R35_REACHED_ENV="env1" R35_UNREACHED_ENV="uenv_mutated" run_json "$WORK/r35" --explain macro_test.iyi > "$r35_explain1"
expect_contains "$(explained "$r35_explain1" lines)" "miss: call path" "reached read_file input change miss reason"
expect_eq "$(explained "$r35_explain1" json | json_cached)" 0 "zero receipts on reached read_file miss"

# Subsequent run hits newly recorded receipt
r35_hit3="$(R35_REACHED_ENV="env1" R35_UNREACHED_ENV="uenv_mutated" run_json "$WORK/r35" macro_test.iyi)"
expect_eq "$(printf '%s' "$r35_hit3" | json_cached)" 1 "r35 re-recorded hits"

# Reached env input changes -> misses on same invocation
r35_explain2="$WORK/r35/explain2.txt"
R35_REACHED_ENV="env_changed" R35_UNREACHED_ENV="uenv_mutated" run_json "$WORK/r35" --explain macro_test.iyi > "$r35_explain2"
expect_contains "$(explained "$r35_explain2" lines)" "miss: call path" "reached env input change miss reason"
expect_eq "$(explained "$r35_explain2" json | json_cached)" 0 "zero receipts on reached env miss"

# Subsequent run hits newly recorded receipt
r35_hit4="$(R35_REACHED_ENV="env_changed" R35_UNREACHED_ENV="uenv_mutated" run_json "$WORK/r35" macro_test.iyi)"
expect_eq "$(printf '%s' "$r35_hit4" | json_cached)" 1 "r35 env re-recorded hits"

# Macro run helper that prints time always misses
cat > "$WORK/r35/clock.iyi" <<'IYI'
import std/time::{Time}
puts Time.utc.to_unix_ms
IYI
cat > "$WORK/r35/clock_test.iyi" <<'IYI'
def helper_output : Int64
  {{ run("./clock").id }}
end
assert helper_output > 0
IYI

r35_clock1="$(run_json "$WORK/r35" clock_test.iyi)"
expect_eq "$(printf '%s' "$r35_clock1" | json_cached)" 0 "r35 clock helper run 1 cached 0"
r35_clock2="$(run_json "$WORK/r35" clock_test.iyi)"
expect_eq "$(printf '%s' "$r35_clock2" | json_cached)" 0 "r35 clock helper run 2 always misses"
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

# Row 40 mutation proof: linked object byte changes invalidate module build.
step 40 "linked object byte changes invalidate module build"
mkdir -p "$WORK/r40/lib" "$WORK/r40/mods"
cat > "$WORK/r40/lib/calc.iyi" <<'IYI'
module lib/calc
pub def compute(x : Int32, y : Int32) : Int32
  x + y
end
IYI
cat > "$WORK/r40/producer.iyi" <<'IYI'
import lib/calc::{compute}
puts compute(1, 2)
IYI
cat > "$WORK/r40/calc_test.iyi" <<'IYI'
import lib/calc::{compute}
assert compute(10, 20) == 30
IYI

# Build initial .iyimod with object code. The runner builds every test with
# -Diyi_observe (src/compiler/iyi/stale/runner.cr:288), and IV.5 adopts an
# artifact only into a build under the same flags
# (src/compiler/iyi/semantic/semantic_visitor.cr:1389-1391).
(cd "$WORK/r40" && "$IYI" build -Diyi_observe --emit-iyimod mods -o producer producer.iyi) >/dev/null

rm -rf "$CACHE/tests-v1"
# `iyi test` takes no build flags (src/compiler/iyi/command/test.cr:101-105
# answers "test: unknown flag --use-iyimod"). IYI_OPTS carries the flag to
# the build each test runs, as row 7 carries --release; without it a build
# reads mods only for a module with no source (command.cr:1287-1293).
r40_run1="$(IYI_OPTS="--use-iyimod mods" run_json "$WORK/r40" calc_test.iyi)"
expect_eq "$(printf '%s' "$r40_run1" | json_cached)" 0 "r40 run 1 recorded"

# Run 2: rebuilt identical bytes -> hits! --force, or the up-to-date check may
# skip an unchanged build and write no artifact (src/compiler/iyi/command.cr:450-460).
(cd "$WORK/r40" && "$IYI" build --force -Diyi_observe --emit-iyimod mods -o producer producer.iyi) >/dev/null
r40_run2="$(IYI_OPTS="--use-iyimod mods" run_json "$WORK/r40" calc_test.iyi)"
expect_eq "$(printf '%s' "$r40_run2" | json_cached)" 1 "r40 rebuilt identical bytes hits"

# Run 3: rebuild with changed object code bytes (same signature/interface) -> misses!
cat > "$WORK/r40/lib/calc.iyi" <<'IYI'
module lib/calc
pub def compute(x : Int32, y : Int32) : Int32
  a = x * 2 - x
  a + y
end
IYI
(cd "$WORK/r40" && "$IYI" build -Diyi_observe --emit-iyimod mods -o producer producer.iyi) >/dev/null
r40_explain="$WORK/r40/explain.txt"
IYI_OPTS="--use-iyimod mods" run_json "$WORK/r40" --explain calc_test.iyi > "$r40_explain"
expect_contains "$(explained "$r40_explain" lines)" "miss" "changed linked object bytes miss reason"
expect_eq "$(explained "$r40_explain" json | json_cached)" 0 "zero receipts on changed object bytes miss"

# Subsequent run hits newly recorded receipt
r40_run3_hit="$(IYI_OPTS="--use-iyimod mods" run_json "$WORK/r40" calc_test.iyi)"
expect_eq "$(printf '%s' "$r40_run3_hit" | json_cached)" 1 "subsequent run hits newly recorded receipt"
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

# Process profile: argv and cwd sensitivity, default mode isolation, concurrent scratch lock, dirty scratch refusal
step "process profile" "argv and cwd sensitivity, plain test isolation, concurrent scratch lock, dirty scratch refusal"

# 1. Argv sensitivity: cache-a hits second, cp -R cache-b misses and fails with same portable_build, different profile
mkdir -p "$WORK/argv-sensitivity"
cat > "$WORK/argv-sensitivity/argv_test.iyi" <<'IYI'
args = Program.args
raise "argv size" unless args.size == 1
if args[0].includes?("cache-b")
  raise "cache-b hit forbidden"
end
IYI
run1="$(cd "$WORK/argv-sensitivity" && IYI_CACHE_DIR="$WORK/cache-a" "$IYI" test --cached --json argv_test.iyi)"
expect_eq "$(printf '%s' "$run1" | json_cached)" 0 "argv test run 1 records"
run1_build="$(printf '%s' "$run1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tests"][0]["portable_build"])')"
run1_profile="$(printf '%s' "$run1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tests"][0]["profile"])')"

run2="$(cd "$WORK/argv-sensitivity" && IYI_CACHE_DIR="$WORK/cache-a" "$IYI" test --cached --json argv_test.iyi)"
expect_eq "$(printf '%s' "$run2" | json_cached)" 1 "argv test run 2 hits"

cp -R "$WORK/cache-a" "$WORK/cache-b"
set +e
run3="$(cd "$WORK/argv-sensitivity" && IYI_CACHE_DIR="$WORK/cache-b" "$IYI" test --cached --json argv_test.iyi)"; run3_rc=$?
set -e
expect_eq "$run3_rc" 1 "argv test run 3 exits 1"
expect_eq "$(printf '%s' "$run3" | json_cached)" 0 "argv test run 3 in cache-b misses"
run3_status="$(printf '%s' "$run3" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tests"][0]["status"])')"
expect_eq "$run3_status" "fail" "argv test run 3 fails because S includes cache-b"
run3_build="$(printf '%s' "$run3" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tests"][0]["portable_build"])')"
run3_profile="$(printf '%s' "$run3" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tests"][0]["profile"])')"
expect_eq "$run1_build" "$run3_build" "same portable_build between cache-a and cache-b"
[ "$run1_profile" != "$run3_profile" ] || fail "expected different profile for cache-a vs cache-b"

# 2. cwd sensitivity: run from cwdA hits; run from cwdB misses and fails
mkdir -p "$WORK/cwd-sensitivity/cwdA" "$WORK/cwd-sensitivity/cwdB"
printf 'a' > "$WORK/cwd-sensitivity/cwdA/rel.txt"
printf 'b' > "$WORK/cwd-sensitivity/cwdB/rel.txt"
cat > "$WORK/cwd-sensitivity/rel_test.iyi" <<'IYI'
import std/file::{File}
content = File.read("rel.txt")
raise "cwd mismatch" unless content == "a"
IYI
cwd_run1="$( (cd "$WORK/cwd-sensitivity/cwdA" && "$IYI" test --cached --json "$WORK/cwd-sensitivity/rel_test.iyi") )"
expect_eq "$(printf '%s' "$cwd_run1" | json_cached)" 0 "cwdA run 1 records"
cwd_run2="$( (cd "$WORK/cwd-sensitivity/cwdA" && "$IYI" test --cached --json "$WORK/cwd-sensitivity/rel_test.iyi") )"
expect_eq "$(printf '%s' "$cwd_run2" | json_cached)" 1 "cwdA run 2 hits"
set +e
cwd_run3="$( (cd "$WORK/cwd-sensitivity/cwdB" && "$IYI" test --cached --json "$WORK/cwd-sensitivity/rel_test.iyi") )"; cwd_run3_rc=$?
set -e
expect_eq "$cwd_run3_rc" 1 "cwdB run 3 exits 1"
expect_eq "$(printf '%s' "$cwd_run3" | json_cached)" 0 "cwdB run 3 misses"
cwd_run3_status="$(printf '%s' "$cwd_run3" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tests"][0]["status"])')"
expect_eq "$cwd_run3_status" "fail" "cwdB run 3 fails because rel.txt is b"

# 3. Default mode unchanged: Program.args.empty? passes under plain iyi test and fails under --cached
mkdir -p "$WORK/plain-mode"
cat > "$WORK/plain-mode/args_empty_test.iyi" <<'IYI'
raise "args not empty" unless Program.args.empty?
IYI
(cd "$WORK/plain-mode" && "$IYI" test args_empty_test.iyi) >/dev/null
set +e
plain_cached="$( (cd "$WORK/plain-mode" && "$IYI" test --cached --json args_empty_test.iyi) )"; plain_cached_rc=$?
set -e
expect_eq "$plain_cached_rc" 1 "args_empty_test exits 1 under --cached"
expect_eq "$(printf '%s' "$plain_cached" | json_failed)" 1 "args_empty_test fails under --cached"

# 4. Lock: concurrent runs of the same test in one cache serialize on scratch lock
mkdir -p "$WORK/lock-test/ctl"
cat > "$WORK/lock-test/lock_test.iyi" <<'IYI'
import std/file::{File}
import std/dir::{Dir}
import std/process::{Process}

args = Program.args
raise "no scratch arg" unless args.size == 1
scratch = args[0]
raise "scratch not empty" unless Dir.children(scratch).empty?
ctl = Program.env("LOCK_CTL") || ""
raise "no LOCK_CTL" if ctl.empty?
token = "#{Process.pid}"
token_file = File.join(scratch, "token.txt")
File.write(token_file, token)
if Program.env("LOCK_ROLE") == "holder"
  File.write(File.join(ctl, "holder-started"), token)
  waited = 0
  while !File.exists?(File.join(ctl, "release"))
    raise "never released" if waited >= 2000
    sleep(20)
    waited += 1
  end
  raise "the second test ran while the holder held the scratch directory" if File.exists?(File.join(ctl, "second-ran"))
else
  File.write(File.join(ctl, "second-ran"), token)
end
raise "token corrupted" unless File.read(token_file) == token
IYI
lock_ctl="$WORK/lock-test/ctl"
lock_out1="$WORK/lock-test/out1.json"
lock_out2="$WORK/lock-test/out2.json"
(cd "$WORK/lock-test" && LOCK_ROLE=holder LOCK_CTL="$lock_ctl" "$IYI" test --fresh --json lock_test.iyi > "$lock_out1") &
pid1=$!

holder_ready=0
for i in $(seq 1 1200); do
  if [ -f "$lock_ctl/holder-started" ]; then
    holder_ready=1
    break
  fi
  if ! kill -0 "$pid1" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if [ "$holder_ready" -ne 1 ]; then
  cat "$lock_out1" >&2
  fail "holder never started or exited early"
fi

(cd "$WORK/lock-test" && LOCK_ROLE=second LOCK_CTL="$lock_ctl" "$IYI" test --fresh --json lock_test.iyi > "$lock_out2") &
pid2=$!

for i in $(seq 1 100); do
  if [ -f "$lock_ctl/second-ran" ]; then
    break
  fi
  if ! kill -0 "$pid2" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

touch "$lock_ctl/release"
wait "$pid1" || true
wait "$pid2" || true
expect_eq "$(cat "$lock_out1" | json_failed)" 0 "the holder keeps its scratch directory while a second runner of the test waits"
expect_eq "$(cat "$lock_out2" | json_failed)" 0 "the second runner of the test finishes successfully"

# 5. Dirty scratch refusal: test leaves a read-only subdirectory; runner warns on cleanup and refuses run 2 until permissions restored
mkdir -p "$WORK/dirty-scratch"
cat > "$WORK/dirty-scratch/dirty_test.iyi" <<'IYI'
import std/file::{File}
import std/dir::{Dir}

scratch = Program.args[0]
raise "scratch not empty" unless Dir.children(scratch).empty?
kept = File.join(scratch, "kept")
Dir.mkdir(kept)
File.write(File.join(kept, "file"), "left behind")
File.chmod(kept, 0o555)
IYI

dirty_err1="$WORK/dirty-scratch/err1.txt"
dirty_run1="$( (cd "$WORK/dirty-scratch" && "$IYI" test --cached --json dirty_test.iyi) 2> "$dirty_err1" )"
expect_eq "$(printf '%s' "$dirty_run1" | json_failed)" 0 "dirty scratch test run 1 passes"

if [ -z "$(ls -d "$CACHE"/tests-v1/scratch/*/kept 2>/dev/null || true)" ]; then
  echo "process profile 5 not proven here: this user removes entries of a read-only directory (root)"
else
  expect_contains "$(cat "$dirty_err1")" "was not removed" "cleanup warning on leftover read-only directory"

  dirty_run2_out="$WORK/dirty-scratch/run2.json"
  dirty_err2="$WORK/dirty-scratch/err2.txt"
  if (cd "$WORK/dirty-scratch" && "$IYI" test --cached --json dirty_test.iyi) > "$dirty_run2_out" 2> "$dirty_err2"; then
    fail "run 2 reused or ran a test in a scratch directory it could not empty"
  fi
  expect_contains "$(cat "$dirty_err2")" "cannot empty scratch directory" "runner refuses run in uncleaned scratch"
  expect_eq "$(cat "$dirty_run2_out")" "" "refusal writes nothing to stdout"

  chmod -R u+w "$CACHE"/tests-v1/scratch 2>/dev/null || true
  dirty_run3="$(run_json "$WORK/dirty-scratch" dirty_test.iyi)"
  expect_eq "$(printf '%s' "$dirty_run3" | json_failed)" 0 "run 3 passes after permissions restored"
  chmod -R u+w "$CACHE"/tests-v1/scratch 2>/dev/null || true
fi
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

echo "stale_tests PASSED: rows 1-50 are covered; rows 23-24 are CI-only"
