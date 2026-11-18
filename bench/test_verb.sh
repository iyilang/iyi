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
  *)
    # A test leads a process group of its own (`process_group: true`), and
    # the deadline ends the group: before it, only the test was killed and
    # its `sleep` held the output pipe open until it ended.
    printf 'module hang_child_test\n\nimport std/process::{Process}\n\nProcess.run("sleep", ["25"], capture: false)\n' > hang_child_test.iyi
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
# A changed file no import can name is in no closure either: a template a
# test renders through `Eiy.render`, and the prelude every test compiles.
# Both were "0 to run, 1 skipped: no test's imports reach the change", and
# `check --affected` on a template that no longer parses said "0
# consumer(s) checked, all compile", exit 0.
printf 'hello <%%= 1 + 1 %%>\n' > page.eiy
printf 'import std/eiy::{Eiy}\n\nassert Eiy.render("page.eiy") == "hello 2\\n", "rendered"\n' > page_test.iyi
"$IYI" test --affected page.eiy . > tmpl.txt 2>&1
grep -q 'page.eiy is not a module an import can name, so every test ran' tmpl.txt &&
  grep -qE '[0-9]+ passed, 0 failed$' tmpl.txt ||
  { echo "a changed template discounted the run:"; cat tmpl.txt; exit 1; }
"$IYI" test --json --affected "$REPO/src/iyi/prelude.iyi" . > prelude.json 2>&1
grep -q '"affected_not_imported":\[' prelude.json && grep -Eq '"skipped": ?0' prelude.json ||
  { echo "a changed prelude file discounted the run:"; cat prelude.json; exit 1; }
printf 'hello <%%= 1 + %%>\n)\n' > page.eiy
"$IYI" check --affected page.eiy > tmpl_check.txt 2>&1
[ $? -eq 1 ] && grep -q '^page_test.iyi: ' tmpl_check.txt ||
  { echo "a template that no longer parses broke no consumer:"; cat tmpl_check.txt; exit 1; }
rm page.eiy page_test.iyi

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

step "a run that answers from receipts takes no option that would run a test another way"
# `--cached` and what goes with it build and run each test one way: every
# named case, under the runner's own build. Taken with `--run` a receipt
# would stand for a test of which only some cases ran, and with `--release`
# for a build it was not made from, so each is refused by name.
for receipts in --cached --fresh --explain "--shard 1/2"; do
  for other in "--run adds" "-v" "--release" "-D probe"; do
    # shellcheck disable=SC2086
    "$IYI" test $receipts $other . > both.txt 2>&1
    [ $? -eq 1 ] && grep -q "cannot pass both ${other%% *}.* and ${receipts%% *}" both.txt ||
      { echo "$other was taken with $receipts:"; cat both.txt; exit 1; }
  done
done
# `-p` is not one of them: how many tests are checked at once changes no
# test's build or run, so a receipt run takes it. It was refused while the
# receipt runner checked one test at a time.
for receipts in --cached --fresh; do
  # shellcheck disable=SC2086
  "$IYI" test $receipts -p 2 . > paired.txt 2>&1
  [ $? -eq 0 ] && ! grep -q 'cannot pass both' paired.txt ||
    { echo "-p 2 was refused with $receipts:"; cat paired.txt; exit 1; }
done
# And without a receipt option the others are taken: the refusal is of the pair.
"$IYI" test -p 2 -v . > alone.txt 2>&1
grep -q 'cannot pass both' alone.txt &&
  { echo "-p and -v were refused without a receipt option:"; cat alone.txt; exit 1; }

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

step "a chaos seed is a decimal number, and a count of runs at least one"
# `--chaos=SEED` takes back what a failing run printed (SPEC.md III.4.17):
# a sign, a space, a letter or a number past 2^64 - 1 is a mistyped seed,
# refused by name rather than read as some other schedule (`to_u64?` alone
# took `+7` and ` 7`); and zero runs would be a chaos run that ran nothing
# and passed.
for seed in "" -1 +7 " 7" 7x 18446744073709551616; do
  "$IYI" test "--chaos=$seed" math_test.iyi > seed.txt 2>&1
  [ $? -eq 1 ] && grep -q -- "--chaos= takes a seed, a decimal number below 2^64, not '$seed'" seed.txt ||
    { echo "--chaos=$seed was taken as a seed:"; cat seed.txt; exit 1; }
done
for runs in 0 -3 many; do
  "$IYI" test --chaos-runs "$runs" math_test.iyi > runs.txt 2>&1
  [ $? -eq 1 ] && grep -q -- "--chaos-runs takes a number of runs, at least 1, not '$runs'" runs.txt ||
    { echo "--chaos-runs $runs was taken as a count:"; cat runs.txt; exit 1; }
done
"$IYI" test math_test.iyi --chaos-runs > runs.txt 2>&1
[ $? -eq 1 ] && grep -q -- "--chaos-runs takes a number of runs$" runs.txt ||
  { echo "--chaos-runs with nothing after it was taken:"; cat runs.txt; exit 1; }
# And a passing test under three seeds from 18446744073709551615, the last
# a seed can be, says which it ran: the seeds wrap past it as the
# runtime's reading of IYI_CHAOS does.
"$IYI" test --chaos=18446744073709551615 --chaos-runs 3 math_test.iyi > chaos.txt 2>&1 ||
  { echo "a passing test failed under --chaos:"; cat chaos.txt; exit 1; }
grep -q '1 passed, 0 failed — chaos seeds 18446744073709551615 to 1$' chaos.txt ||
  { echo "the chaos run did not name its seeds:"; cat chaos.txt; exit 1; }

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
printf '@[Unsafe("the test reads through a pointer to address 16 on purpose, the kill iyi test must count as a failure")]\nmodule wild_test\n\np = Pointer(Int32).new(16_u64)\nputs p.value\n' > wild_test.iyi
"$IYI" test wild_test.iyi > wild.txt 2>&1
[ $? -eq 1 ] || { echo "a test the kernel killed was not a failure:"; cat wild.txt; exit 1; }
grep -q 'memory fault' wild.txt || { echo "the kernel's kill is not the evidence:"; cat wild.txt; exit 1; }
rm wild_test.iyi

step "an assertion's failure is its evidence, and named cases keep going"
# `assert(a == b)` failed with "assertion failed" alone. The prelude's
# assertions name the values and the line, and that is what the verb
# shows under the file it names (`bench/assertions_exercise.sh` drives
# each assertion; this is the verb's side of the contract). Named cases
# run past a failure, and the program's exit is still the one verdict read.
printf 'module eq_test\n\nsum = 2 + 3\nassert_eq 4, sum, "the sum"\n' > eq_test.iyi
"$IYI" test eq_test.iyi > eq.txt 2>&1
[ $? -eq 1 ] || { echo "a failed assert_eq did not fail the run:"; cat eq.txt; exit 1; }
grep -q 'eq_test.iyi: fail' eq.txt && grep -q 'assert_eq failed: the sum' eq.txt &&
  grep -q 'expected: 4' eq.txt && grep -q 'actual: 5' eq.txt && grep -qE 'at .*eq_test.iyi:4$' eq.txt ||
  { echo "the failure does not name its values and its line:"; cat eq.txt; exit 1; }
rm eq_test.iyi
printf 'module cases_test\n\ntest "first" { assert_eq 1, 1 }\ntest "second" { assert_includes [1, 2], 3 }\ntest "third" { assert_nil nil }\n' > cases_test.iyi
"$IYI" test --json cases_test.iyi > cases.json 2>&1
[ $? -eq 1 ] || { echo "a failed named case did not fail the run:"; cat cases.json; exit 1; }
grep -q '"status":"fail"' cases.json && grep -q 'FAIL - second' cases.json && grep -q 'ok - third' cases.json &&
  grep -q '3 named tests: 2 passed, 1 failed' cases.json ||
  { echo "the named cases did not all run, or did not say so:"; cat cases.json; exit 1; }
printf 'module cases_test\n\ntest "first" { assert_eq 1, 1 }\ntest "second" { assert_ne 1, 2 }\n' > cases_test.iyi
"$IYI" test cases_test.iyi > cases.txt 2>&1 ||
  { echo "named cases that all pass failed the run:"; cat cases.txt; exit 1; }
rm cases_test.iyi

step "each named case is data, --run picks cases by name, and skip: is a verdict"
# The cases were lines in the output, which a harness had to scrape; the
# verdict of each is in the report now, with the panic's message or the
# reason to skip. And `--run` with a name no case has ran nothing and
# passed, which is a mistyped name reading as green.
printf 'module picked_test\n\ntest "alpha one" { assert_eq 1, 1 }\ntest "beta" { assert_eq 1, 2, "beta breaks" }\ntest "alpha two", skip: "not today" do\n  assert_eq 1, 2\nend\n' > picked_test.iyi
"$IYI" test --json picked_test.iyi > picked.json 2>&1
[ $? -eq 1 ] && grep -qF '{"name":"alpha one","status":"pass"}' picked.json &&
  grep -qF '{"name":"beta","status":"fail","message":"assert_eq failed: beta breaks' picked.json &&
  grep -qF '{"name":"alpha two","status":"skip","reason":"not today"}' picked.json ||
  { echo "the named cases are not data:"; cat picked.json; exit 1; }
"$IYI" test --json --run alpha picked_test.iyi > picked_run.json 2>&1
[ $? -eq 0 ] && grep -qF '{"name":"alpha one","status":"pass"}' picked_run.json && ! grep -q '"beta"' picked_run.json ||
  { echo "--run alpha ran another case, or failed:"; cat picked_run.json; exit 1; }
"$IYI" test --run nothing-is-named-this picked_test.iyi > picked_none.txt 2>&1
[ $? -eq 1 ] && grep -q "no named case's name holds 'nothing-is-named-this'" picked_none.txt ||
  { echo "a --run that matched no case passed:"; cat picked_none.txt; exit 1; }
rm picked_test.iyi

step "a program a test starts reports its own cases to nobody, and runs all of them"
# IYI_TEST_REPORT and IYI_TEST_RUN were in the environment a test's own
# children inherit: a child with named cases wrote them into the test's
# report, and ran only the cases the test's `--run` named.
printf 'module child_cases\n\ntest "child case" { assert_eq 1, 1 }\n' > child_cases.iyi
"$IYI" build child_cases.iyi -o child_cases > child_build.txt 2>&1 ||
  { echo "the child did not build:"; cat child_build.txt; exit 1; }
child="$WORK/child_cases"
[ -f "$child.exe" ] && child="$child.exe"
printf 'module parent_test\n\nimport std/process::{Process}\n\ntest "parent case" do\n  Process.run("%s", [] of String, capture: false)\nend\n' "$child" > parent_test.iyi
"$IYI" test --json parent_test.iyi > parent.json 2>&1
[ $? -eq 0 ] && grep -qF '{"name":"parent case","status":"pass"}' parent.json && ! grep -qF '"name":"child case"' parent.json ||
  { echo "the child's case is in the test's report:"; cat parent.json; exit 1; }
"$IYI" test -v --run parent parent_test.iyi > parent_run.txt 2>&1
[ $? -eq 0 ] && grep -q 'ok - child case' parent_run.txt ||
  { echo "the test's --run reached the child, which ran none of its cases:"; cat parent_run.txt; exit 1; }
rm -f child_cases.iyi child_cases child_cases.exe child_cases.pdb parent_test.iyi

step "a directory's walk leaves out lib, dot directories and other modules"
# The walk was a `**` glob, so a project's run ran the tests of every
# dependency installed under `lib` and failed on theirs.
mkdir -p lib/dep .cache other
printf 'raise "a dependency test ran"\n' > lib/dep/dep_test.iyi
printf 'raise "a dot directory test ran"\n' > .cache/dot_test.iyi
printf 'module example.test/other\n' > other/iyi.mod
printf 'raise "another module test ran"\n' > other/other_test.iyi
"$IYI" test --json . > walk.json 2>&1
[ $? -eq 0 ] && ! grep -qE 'dep_test|dot_test|other_test' walk.json ||
  { echo "the walk ran a test that is not this project's:"; cat walk.json; exit 1; }
"$IYI" test other > walk_other.txt 2>&1
[ $? -eq 1 ] && grep -q 'other_test.iyi' walk_other.txt ||
  { echo "a directory named on the command line was not walked:"; cat walk_other.txt; exit 1; }
rm -rf lib .cache other

step "a test is built with --release and -D as asked, and -v shows a pass's output"
# Every test was built as `build FILE -o BINARY` and nothing else, so a test
# of a flag-gated path or of the optimised program could not be written.
printf '{%% if flag?(:release) && flag?(:probe_flag) %%}\nputs "built as asked"\n{%% else %%}\nraise "built without the flags"\n{%% end %%}\n' > flags_test.iyi
"$IYI" test flags_test.iyi > flags_plain.txt 2>&1
[ $? -eq 1 ] && grep -q 'built without the flags' flags_plain.txt ||
  { echo "the flag-gated test passed without its flags:"; cat flags_plain.txt; exit 1; }
"$IYI" test --release -D probe_flag flags_test.iyi > flags.txt 2>&1
[ $? -eq 0 ] && ! grep -q 'built as asked' flags.txt ||
  { echo "--release -D probe_flag did not reach the build, or a pass printed its output:"; cat flags.txt; exit 1; }
"$IYI" test -v --release -Dprobe_flag flags_test.iyi > flags_v.txt 2>&1
[ $? -eq 0 ] && grep -q 'flags_test.iyi: pass' flags_v.txt && grep -q '  built as asked' flags_v.txt ||
  { echo "-v did not show the passing test's output:"; cat flags_v.txt; exit 1; }
"$IYI" test -D > flags_none.txt 2>&1
[ $? -eq 1 ] && grep -q -- '-D takes a flag to define' flags_none.txt ||
  { echo "-D with nothing after it was taken:"; cat flags_none.txt; exit 1; }
rm flags_test.iyi

step "a failed case's panic is between the verdicts around it, under load"
# Standard output and standard error were two pipes, copied by two fibers,
# and a test's panic landed above or below all of its stdout as the two
# copies happened to be scheduled: sixteen of these at once, on 12 cores,
# came back out of order in 8 of 16, and one at a time in none. One pipe
# keeps the program's own order however busy the machine is.
mkdir -p order
for i in $(seq 1 16); do
  printf 'module o%s_test\n\ntest "first" { assert_eq 1, 1 }\ntest "breaks" { assert_eq 1, 2, "the panic" }\ntest "after" { assert_eq 1, 1 }\n' "$i" > "order/o${i}_test.iyi"
done
"$IYI" test order > order.txt 2>&1
# Each failing file is a line naming it, then its output indented.
out_of_order=$(awk '
  function check() { if (file != "" && !(f && f < p && p < v && v < a)) bad++ }
  /^[^ ]/ { check(); file = $0; n = 0; f = p = v = a = 0; next }
  { n++ }
  /ok - first/ { f = n }
  /assert_eq failed: the panic/ { p = n }
  /FAIL - breaks/ { v = n }
  /ok - after/ { a = n }
  END { print bad + 0 }' order.txt)
[ "$(grep -c '_test.iyi: fail$' order.txt)" -eq 16 ] && [ "$out_of_order" -eq 0 ] ||
  { echo "$out_of_order of 16 tests printed out of order:"; cat order.txt; exit 1; }
rm -rf order

step "tests run at once, -p 1 runs them one at a time, and the report is in file order"
# Two tests that each wait for the other: together they pass, one at a
# time the first waits out its deadline. No clock is asked how long
# anything took.
printf 'File.write("left.flag", "")\nwhile !File.exists?("right.flag")\n  sleep 10\nend\n' > left_test.iyi
printf 'File.write("right.flag", "")\nwhile !File.exists?("left.flag")\n  sleep 10\nend\n' > right_test.iyi
"$IYI" test --json -p 2 --timeout 30 right_test.iyi left_test.iyi > both.json 2>&1
[ $? -eq 0 ] || { echo "two tests that wait for each other did not run at once:"; cat both.json; exit 1; }
[ "$(grep -oE '"file":"[^"]*"' both.json | tr '\n' ' ')" = '"file":"left_test.iyi" "file":"right_test.iyi" ' ] ||
  { echo "the report is not in file order:"; cat both.json; exit 1; }
rm -f left.flag right.flag
"$IYI" test -p 1 --timeout 3 left_test.iyi right_test.iyi > serial.txt 2>&1
[ $? -eq 1 ] && grep -q 'left_test.iyi: hung' serial.txt ||
  { echo "-p 1 ran two tests at once:"; cat serial.txt; exit 1; }
rm -f left.flag right.flag left_test.iyi right_test.iyi
for p in 0 -2 many; do
  "$IYI" test -p "$p" math_test.iyi > p.txt 2>&1
  [ $? -eq 1 ] && grep -q -- "-p takes a number of tests to run at once, at least 1, not '$p'" p.txt ||
    { echo "-p $p was taken as a count:"; cat p.txt; exit 1; }
done

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
