#!/usr/bin/env bash
# Drives `iyi test` — the verify loop with no framework (AI_FIRST.md §2 #4).
#
#     bash bench/test_verb.sh
#
# A test is a plain iyi program that exits non-zero to fail. Four steps,
# and every one is a failure proof of a different kind, because a test
# runner's whole job is telling the four verdicts apart:
#
#   1. Passing tests: exit 0, and `--json` reports them as data.
#   2. A failing test: exit 1, the file named, its own output shown.
#   3. A test that does not build: a failure that says so, not a crash.
#   4. A test that hangs: killed at the deadline and named, because a
#      harness that can hang is not a harness.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"

cd "$WORK" || exit 1
step() { echo "== $1"; }

cat > math_test.iyi <<'IYI'
def check(name : String, ok : Bool) : Nil
  return if ok
  puts "FAIL: #{name}"
  __iyi_exit(1)
end

check("adds", 2 + 2 == 4)
check("concats", "a" + "b" == "ab")
IYI

step "passing tests exit 0, and --json is data"
"$IYI" test --json . > run.json 2>&1 || { cat run.json; exit 1; }
grep -Eq '"status": ?"pass"' run.json || { echo "no pass in the report:"; cat run.json; exit 1; }
grep -Eq '"failed": ?0' run.json || { echo "a passing run reported failures:"; cat run.json; exit 1; }

step "a failing test names itself and its evidence"
printf 'puts "the evidence line"\n__iyi_exit(1)\n' > broken_test.iyi
"$IYI" test . > run.txt 2>&1
[ $? -eq 1 ] || { echo "a failing test did not fail the run:"; cat run.txt; exit 1; }
grep -q 'broken_test.iyi: fail' run.txt || { echo "the failing file is unnamed:"; cat run.txt; exit 1; }
grep -q 'the evidence line' run.txt || { echo "the test's own output is missing:"; cat run.txt; exit 1; }
rm broken_test.iyi

step "a test that does not build is a verdict, not a crash"
printf 'this is not iyi\n' > syntax_test.iyi
"$IYI" test . > build.txt 2>&1
[ $? -eq 1 ] || { echo "an unbuildable test passed:"; cat build.txt; exit 1; }
grep -q 'syntax_test.iyi: does not build' build.txt || { echo "the verdict is wrong:"; cat build.txt; exit 1; }
rm syntax_test.iyi

step "a hanging test is killed at the deadline"
printf 'while true\nend\n' > hang_test.iyi
timeout 30 "$IYI" test --timeout 2 . > hang.txt 2>&1
status=$?
[ $status -eq 1 ] || { echo "the hang was not a failure (exit $status, 124 is the harness hanging):"; cat hang.txt; exit 1; }
grep -q 'hang_test.iyi: hung' hang.txt || { echo "the hang is unnamed:"; cat hang.txt; exit 1; }
rm hang_test.iyi

step "the discount says when it turns itself off"
# `--affected` is an exactness claim — "only the tests whose imports reach
# the change" — and a changed file that is gone turns it off, because a
# deleted import breaks whoever held it and the closure cannot see that.
# It used to turn off in silence, so a mistyped path produced a full run
# that read as a selective one.
mkdir -p calc
printf 'module calc/add\n\npub def add(a : Int32, b : Int32) : Int32\n  a + b\nend\n' > calc/add.iyi
printf 'module main\n\nimport calc/add\nusing calc/add::{add}\n\nraise "bad" if add(1, 2) != 3\n' > add_test.iyi
printf 'module main\n\nputs "lonely"\n' > lonely_test.iyi
"$IYI" test --affected calc/add.iyi . > sel.txt 2>&1
grep -qE '1 passed, 0 failed, [0-9]+ skipped' sel.txt ||
  { echo "the selection is not exact:"; cat sel.txt; exit 1; }
"$IYI" test --affected nope.iyi . > off.txt 2>&1
grep -q 'nope.iyi is not there, so every test ran' off.txt ||
  { echo "the discount turned off in silence:"; cat off.txt; exit 1; }
grep -qE '[0-9]+ passed, 0 failed$' off.txt ||
  { echo "the full run did not happen:"; cat off.txt; exit 1; }
"$IYI" test --json --affected nope.iyi . > off.json 2>&1
grep -q '"affected_not_found":\["nope.iyi"\]' off.json ||
  { echo "the data says nothing about it:"; cat off.json; exit 1; }

step "a flag is a flag, and a directory is not a changed file"
"$IYI" test --nonesuch . > flag.txt 2>&1
[ $? -eq 1 ] && grep -q 'unknown flag --nonesuch' flag.txt ||
  { echo "an unknown flag was read as a path:"; cat flag.txt; exit 1; }
"$IYI" test --affected . . > dir.txt 2>&1
[ $? -eq 1 ] && grep -q 'is a directory, not a changed file' dir.txt ||
  { echo "a directory was accepted as a changed file:"; cat dir.txt; exit 1; }

step "a timeout is a wait, so zero and less are refused"
# `--timeout 0` and `--timeout -1` were taken, and every test came back
# "hung: killed at -1.0s" - a verdict about the flag, printed as one about
# the tests, and a run an agent computing its budget could produce.
for wait in 0 -1 inf nan; do
  "$IYI" test --timeout "$wait" . > wait.txt 2>&1
  [ $? -eq 1 ] && grep -q -- "$wait is not a wait" wait.txt ||
    { echo "--timeout $wait was taken as a deadline:"; cat wait.txt; exit 1; }
done
grep -q 'hung' wait.txt && { echo "the refusal ran a test first:"; cat wait.txt; exit 1; }

step "a test that died says what killed it"
# An infinite recursion was "fail" with nothing under it - the one failure
# that printed no evidence, from the verb whose contract is that a failure
# prints its own. The program says `stack overflow` itself now, and a
# death the kernel still owns - a `Pointer` at nothing - is named by the
# verb as the evidence.
printf 'module deep_test\n\ndef down(n : Int32) : Int32\n  down(n + 1) + 1\nend\n\nputs down(0)\n' > deep_test.iyi
"$IYI" test deep_test.iyi > deep.txt 2>&1
[ $? -eq 1 ] || { echo "a test that died was not a failure:"; cat deep.txt; exit 1; }
grep -q 'deep_test.iyi: fail' deep.txt || { echo "the dead test is unnamed:"; cat deep.txt; exit 1; }
grep -q 'stack overflow' deep.txt || { echo "the death is not the evidence:"; cat deep.txt; exit 1; }
"$IYI" test --json deep_test.iyi > deep.json 2>&1
grep -q '"status":"fail"' deep.json && grep -q 'stack overflow' deep.json ||
  { echo "the data says nothing about the death:"; cat deep.json; exit 1; }
rm deep_test.iyi
printf 'module wild_test\n\np = Pointer(Int32).new(16_u64)\nputs p.value\n' > wild_test.iyi
"$IYI" test wild_test.iyi > wild.txt 2>&1
[ $? -eq 1 ] || { echo "a test the kernel killed was not a failure:"; cat wild.txt; exit 1; }
grep -q 'memory fault' wild.txt || { echo "the kernel's kill is not the evidence:"; cat wild.txt; exit 1; }
rm wild_test.iyi

echo "workdir $WORK"
echo "test verb gate: every step held"
exit 0
