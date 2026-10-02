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
# The compiler, overridable: `bin/iyi` is a POSIX shell wrapper, and on
# Windows the caller is the only one who knows where the real binary is.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on the search path, so
# the patched copy is never read and the proof that a check can fail
# quietly stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

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
# And a test whose time runs out while a program it started runs: the
# test's output comes through a pipe, and the child held it open, so only
# the test was killed and the run waited out the child - `ping -n 25`
# answered "hung" after 25 seconds. The deadline ends the whole tree.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    printf 'module hang_child_test\n\nimport std/process::{Process}\n\nProcess.run("ping", ["-n", "25", "127.0.0.1"], capture: false)\n' > hang_child_test.iyi
    started=$(date +%s)
    timeout 60 "$IYI" test --timeout 3 . > hang_child.txt 2>&1
    status=$?
    took=$(( $(date +%s) - started ))
    [ $status -eq 1 ] && grep -q 'hang_child_test.iyi: hung' hang_child.txt ||
      { echo "a test hung on its child was not killed (exit $status):"; cat hang_child.txt; exit 1; }
    [ "$took" -lt 20 ] || { echo "a test hung on its child took ${took}s to be killed at 3"; exit 1; }
    rm hang_child_test.iyi
    ;;
esac

step "the discount says when it turns itself off"
# `--affected` is an exactness claim — "only the tests whose imports reach
# the change" — and a changed file that is gone turns it off, because a
# deleted import breaks whoever held it and the closure cannot see that.
# It used to turn off in silence, so a mistyped path produced a full run
# that read as a selective one.
mkdir -p calc
printf 'module calc/add\n\npub def add(a : Int32, b : Int32) : Int32\n  a + b\nend\n' > calc/add.iyi
printf 'module main\n\nimport calc/add::{add}\n\nraise "bad" if add(1, 2) != 3\n' > add_test.iyi
printf 'module main\n\nputs "lonely"\n' > lonely_test.iyi
"$IYI" test --affected calc/add.iyi . > sel.txt 2>&1
grep -qE '1 passed, 0 failed, [0-9]+ skipped' sel.txt ||
  { echo "the selection is not exact:"; cat sel.txt; exit 1; }
# The same file under another spelling, where the file system says it is
# one: in upper case, and on Windows with the drive letter an editor
# writes lower case. The closure compared strings, and both selected
# nothing - "0 to run, 1 skipped", a clean verdict about no tests.
if [ CALC/ADD.IYI -ef calc/add.iyi ]; then
  "$IYI" test --affected CALC/ADD.IYI . > sel_case.txt 2>&1
  grep -qE '1 passed, 0 failed, [0-9]+ skipped' sel_case.txt ||
    { echo "another case of the changed file selected otherwise:"; cat sel_case.txt; exit 1; }
fi
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    lower="$(echo "$WORK" | cut -c1 | tr 'A-Z' 'a-z')$(echo "$WORK" | cut -c2-)/calc/add.iyi"
    "$IYI" test --affected "$lower" . > sel_drive.txt 2>&1
    grep -qE '1 passed, 0 failed, [0-9]+ skipped' sel_drive.txt ||
      { echo "a lower-case drive letter selected otherwise:"; cat sel_drive.txt; exit 1; }
    # And the 8.3 short name, which a CI runner's temporary directory is
    # spelled in (`RUNNER~1`) while the working directory is the long one:
    # the lower-case drive above selected nothing there for that reason.
    short="$(cygpath -d "$WORK/calc/add.iyi")"
    "$IYI" test --affected "$short" . > sel_short.txt 2>&1
    grep -qE '1 passed, 0 failed, [0-9]+ skipped' sel_short.txt ||
      { echo "the 8.3 short name selected otherwise ($short):"; cat sel_short.txt; exit 1; }
    # And spelled verbatim, `\\?\C:\...` or `\\.\C:\...`, the form Rust's
    # `fs::canonicalize` hands over: the prefix stayed in the key, no
    # closure held `\\?\c:\...`, and it was "0 to run, 1 skipped".
    for prefix in '\\?\' '\\.\'; do
      "$IYI" test --affected "$prefix$(cygpath -w "$WORK/calc/add.iyi")" . > sel_verbatim.txt 2>&1
      grep -qE '1 passed, 0 failed, [0-9]+ skipped' sel_verbatim.txt ||
        { echo "the changed file spelled $prefix selected otherwise:"; cat sel_verbatim.txt; exit 1; }
    done
    ;;
esac
"$IYI" test --affected nope.iyi . > off.txt 2>&1
grep -q 'nope.iyi is not there, so every test ran' off.txt ||
  { echo "the discount turned off in silence:"; cat off.txt; exit 1; }
grep -qE '[0-9]+ passed, 0 failed$' off.txt ||
  { echo "the full run did not happen:"; cat off.txt; exit 1; }
"$IYI" test --json --affected nope.iyi . > off.json 2>&1
grep -q '"affected_not_found":\["nope.iyi"\]' off.json ||
  { echo "the data says nothing about it:"; cat off.json; exit 1; }

step "a test named more than once runs once"
# The list was made unique as strings, so a test the directory walk found
# and the caller named again in two more spellings was built and run three
# times and counted as three passes.
"$IYI" test --json . add_test.iyi "$WORK/add_test.iyi" > once.json 2>&1
"$IYI" test --json . > all.json 2>&1
passed() { grep -oE '"passed": ?[0-9]+' "$1" | grep -oE '[0-9]+$'; }
[ -n "$(passed all.json)" ] && [ "$(passed once.json)" = "$(passed all.json)" ] ||
  { echo "a test named again was counted again: $(passed once.json) passes where the directory has $(passed all.json)"; cat once.json; exit 1; }

step "a flag is a flag, and a directory is not a changed file"
"$IYI" test --nonesuch . > flag.txt 2>&1
[ $? -eq 1 ] && grep -q 'unknown flag --nonesuch' flag.txt ||
  { echo "an unknown flag was read as a path:"; cat flag.txt; exit 1; }
"$IYI" test --affected . . > dir.txt 2>&1
[ $? -eq 1 ] && grep -q 'is a directory, not a changed file' dir.txt ||
  { echo "a directory was accepted as a changed file:"; cat dir.txt; exit 1; }

step "a timeout is a wait, so zero, less and more than a clock holds are refused"
# `--timeout 0` and `--timeout -1` were taken, and every test came back
# "hung: killed at -1.0s" - a verdict about the flag, printed as one about
# the tests, and a run an agent computing its budget could produce. And
# one past what the clock counts went wrong after the test was built:
# `1e300` overflowed the span the wait becomes, "Arithmetic overflow
# (OverflowError)" and "you've found a bug", and `9.3e14` hung a run of
# tests that end at once past a minute on Windows, though not every time
# (hence the `timeout`).
for wait in 0 -1 inf nan 1e300 9.3e14; do
  timeout 120 "$IYI" test --timeout "$wait" . > wait.txt 2>&1
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

step "a test leaves nothing in the temporary directory"
# Each test is built to a temporary name and deleted after it runs. On
# Windows the name had no extension, the build appended `.exe`, and the
# delete asked for the name without it: every test left its program and
# its `.pdb` behind, and a developer's %TEMP% held hundreds of them.
mkdir -p scratch_tmp
scratch="$WORK/scratch_tmp"
TMPDIR="$scratch" TMP="$scratch" TEMP="$scratch" "$IYI" test math_test.iyi > tmp.txt 2>&1 ||
  { echo "the test did not pass:"; cat tmp.txt; exit 1; }
left="$(ls -A "$scratch")"
[ -z "$left" ] || { echo "a test left behind:"; echo "$left"; exit 1; }

echo "workdir $WORK"
echo "test verb gate: every step held"
exit 0
