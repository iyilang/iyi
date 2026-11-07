#!/usr/bin/env bash
# The prelude's assertions: `assert_eq`, `assert_ne`, `assert_nil`,
# `assert_in_delta`, `assert_includes`, `assert_error`, `assert_ok`,
# `assert_panics` and named `test` cases (src/iyi/testing.iyi).
#
#     bash bench/assertions_exercise.sh
#
# `bench/assertions_exercise.iyi` is the program, run plain and optimised:
# every assertion holding, and failing with the message it documents. Then
# what a program cannot see of itself is driven here - the site a failure
# names, which `raise` prints beside the message, and the exit status
# named cases leave, which is the one thing `iyi test` reads. Then each
# check is proved capable of failing by patching a *copy of the prelude*
# and building against it through `IYI_PATH`. A check that cannot fail is
# not a check.
#
# What this gate was written for: `assert(a == b)` said "assertion failed"
# and nothing else, so the first thing a failing test asked of its reader
# was a `puts` and another run.
#
# Exits non-zero if any check fails or if any patch leaves the checks green.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The wrapper in bin is a posix shell script, so a caller that already has a
# compiler of its own names it through the environment.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"

# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on that path, so the
# patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

trap 'rm -rf "$WORK"' EXIT

status=0
# The library a build reads: the repository's, or a patched copy ahead of it.
LIBRARY="${IYI_PATH:-$REPO/src}"

SECTIONS=("assert_eq and assert_ne" "assert_nil" "assert_in_delta" "assert_includes"
  "assert_error and assert_ok" "assert_panics" "assert")

run_case() { # run_case <label> <name> [build flags...]
  local label="$1" name="$2"
  shift 2
  if ! IYI_PATH="$LIBRARY" "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/assertions_exercise.iyi" \
       > "$WORK/$name.build" 2>&1; then
    echo "  $label: the exercise did not build"
    sed -n '1,12p' "$WORK/$name.build"
    status=1
    return
  fi
  # The failures the exercise provokes print their panics on the error
  # stream as they happen; what it checks is on the output.
  if ! "$WORK/$name" > "$WORK/$name.out" 2> "$WORK/$name.err"; then
    echo "  $label: the exercise failed"
    tail -3 "$WORK/$name.out"
    status=1
    return
  fi
  local section
  for section in "${SECTIONS[@]}"; do
    if ! grep -qxF "  $section: held" "$WORK/$name.out"; then
      echo "  $label: the section '$section' was never reported"
      status=1
      return
    fi
  done
  if ! grep -q "all assertion checks passed" "$WORK/$name.out"; then
    echo "  $label: the exercise ended without passing"
    tail -3 "$WORK/$name.out"
    status=1
    return
  fi
  echo "  $label: every check held"
}

echo "== the assertions, plain"
run_case "plain" plain

echo
echo "== and with optimisation on (--release)"
run_case "release" release --release

# A program written to WORK, built against LIBRARY and run; its output and
# error stream in one file, as `iyi test` reads them. Answers the exit.
run_program() { # run_program <name> <source>
  local name="$1"
  printf '%b' "$2" > "$WORK/$name.iyi"
  if ! IYI_PATH="$LIBRARY" "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $name: the program did not build"
    sed -n '1,10p' "$WORK/$name.build"
    return 99
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
}

# Every line asked for is in the output, as a whole line.
has_lines() { # has_lines <name> <line>...
  local name="$1" line
  shift
  for line in "$@"; do
    if ! grep -qxF -- "$line" "$WORK/$name.out"; then
      echo "  $name: no line '$line' in:"
      sed 's/^/    /' "$WORK/$name.out"
      return 1
    fi
  done
}

# The site line names the program's own file at the line asked for. By its
# name and not the whole path: how a path is spelled is the platform's - a
# Windows build may write the directory's separator its own way - while the
# file and the line are the claim.
has_site() { # has_site <name> <line number>
  if ! grep -qE "^  at .*[/\\\\]$1\\.iyi:$2\$" "$WORK/$1.out"; then
    echo "  $1: no line '  at .../$1.iyi:$2' in:"
    sed 's/^/    /' "$WORK/$1.out"
    return 1
  fi
}

# The checks a program cannot make of itself. Each answers non-zero with a
# sentence, so a proof below can run the same check against a broken copy.
site_check() {
  run_program site 'module main\n\nsum = 2 + 3\nassert_eq 4, sum, "the sum"\nputs "after the failure"\n'
  local code=$?
  [ "$code" -eq 1 ] || { echo "  site: a failing assert_eq exited $code, not 1"; return 1; }
  has_lines site "iyi: panic: assert_eq failed: the sum" "  expected: 4" "    actual: 5" || return 1
  has_site site 4 || return 1
  if grep -q "after the failure" "$WORK/site.out"; then
    echo "  site: the program went on past a failed assertion"
    return 1
  fi
}

error_site_check() {
  run_program error_site 'module main\n\nstruct Gone\n  def initialize\n  end\nend\n\nimpl Error for Gone\n  def message : String\n    "gone"\n  end\nend\n\ndef fetch : Int32 | Gone\n  Gone.new\nend\n\nvalue = assert_ok { fetch }\nputs value\n'
  local code=$?
  [ "$code" -eq 1 ] || { echo "  error site: a failing assert_ok exited $code, not 1"; return 1; }
  has_lines error_site "iyi: panic: assert_ok failed" "    actual: Main::Gone (an error: \"gone\")" || return 1
  has_site error_site 18 || return 1
}

cases_check() {
  run_program cases 'module main\n\ntest "first" { assert_eq 1, 1 }\ntest "second" do\n  assert_eq [1, 2], [2, 1], "order"\nend\ntest "third" { assert_includes "abc", "b" }\n'
  local code=$?
  [ "$code" -eq 1 ] || { echo "  cases: a program with a failed named case exited $code, not 1"; return 1; }
  has_lines cases "ok - first" "iyi: panic: assert_eq failed: order" "  expected: [1, 2]" "    actual: [2, 1]" \
    "FAIL - second" "ok - third" "3 named tests: 2 passed, 1 failed" || return 1
  has_site cases 5 || return 1
}

passing_cases_check() {
  run_program passing_cases 'module main\n\ntest "one" { assert_eq 1, 1 }\ntest "two" { assert_nil nil }\n'
  local code=$?
  [ "$code" -eq 0 ] || { echo "  passing cases: every named case passed and the program exited $code"; return 1; }
  has_lines passing_cases "ok - one" "ok - two" "2 named tests: 2 passed, 0 failed" || return 1
}

no_cases_check() {
  run_program no_cases 'module main\n\nputs "plain"\n'
  local code=$?
  [ "$code" -eq 0 ] || { echo "  no cases: a program with no named case exited $code"; return 1; }
  if grep -q "named tests" "$WORK/no_cases.out"; then
    echo "  no cases: a program with no named case printed a summary of them"
    return 1
  fi
}

echo
echo "== what a program cannot see of itself: the site, and the exit"
site_check && echo "  a failed assert_eq: exits 1 and names expected, actual and the line"
[ $? -eq 0 ] || status=1
error_site_check && echo "  a failed assert_ok: exits 1 and names the error and the line"
[ $? -eq 0 ] || status=1
cases_check && echo "  named cases: a failure is reported, the cases after it run, and the program exits 1"
[ $? -eq 0 ] || status=1
passing_cases_check && echo "  named cases that all pass: exit 0"
[ $? -eq 0 ] || status=1
no_cases_check && echo "  a program with no named case: exit 0 and no summary"
[ $? -eq 0 ] || status=1

echo
echo "== proving the checks can fail, one broken assertion at a time"

# A copy of the whole prelude with one assertion patched, on `IYI_PATH` ahead
# of the real one. The patch has to change the file - a sed that matched
# nothing would otherwise read as a pass - and then the exercise has to fail
# at the check that names the assertion, or the driver's own check has to.
patch_prelude() { # patch_prelude <dir> <sed script>
  local dir="$1" script="$2"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  sed -e "$script" "$REPO/src/iyi/testing.iyi" > "$WORK/$dir/iyi/testing.iyi"
  if cmp -s "$REPO/src/iyi/testing.iyi" "$WORK/$dir/iyi/testing.iyi"; then
    echo "  $dir: the patch changed nothing, so this proves nothing"
    return 1
  fi
}

prove_fails() { # prove_fails <label> <dir> <phrase> <sed script>
  local label="$1" dir="$2" phrase="$3" script="$4"
  patch_prelude "$dir" "$script" || { status=1; return; }
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/assertions_exercise.iyi" \
       > "$WORK/$dir/build" 2>&1; then
    echo "  $label: the patched prelude did not build"
    sed -n '1,10p' "$WORK/$dir/build"
    status=1
    return
  fi
  timeout 60 "$WORK/$dir/program" > "$WORK/$dir/out" 2> /dev/null
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  if ! grep -q "check failed: $phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not at the expected check (wanted '$phrase')"
    tail -2 "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$phrase"
}

prove_driver_fails() { # prove_driver_fails <label> <dir> <check> <sed script>
  local label="$1" dir="$2" check="$3" script="$4"
  patch_prelude "$dir" "$script" || { status=1; return; }
  if LIBRARY="$WORK/$dir${PSEP}$REPO/src" "$check" > "$WORK/$dir/said" 2>&1; then
    echo "  $label: $check still held, so it does not test this"
    status=1
    return
  fi
  printf '  %s: %s fails, "%s"\n' "$label" "$check" "$(head -1 "$WORK/$dir/said" | sed 's/^ *//')"
}

prove_fails "assert_eq that never fails" eq_holds "assert_eq: unequal values panic" \
  's/^  return if expected == actual$/  return/'
prove_fails "assert_eq without the line diff" no_diff "assert_eq: two texts of lines" \
  's/^    evidence = evidence + __iyi_first_difference(expected, actual)$/    evidence = evidence + ""/'
prove_fails "assert_ne that never fails" ne_holds "assert_ne: equal values panic" \
  's/^  return unless unexpected == actual$/  return/'
prove_fails "assert_nil that takes anything" nil_holds "assert_nil: a value panics" \
  's/^  return if value.is_a?(Nil)$/  return/'
prove_fails "assert_in_delta that always holds" delta_holds "assert_in_delta: a distance past delta" \
  's/^  return if off <= within$/  return if off <= within || off == off/'
prove_fails "assert_in_delta that takes a negative delta" delta_negative "assert_in_delta: a negative distance" \
  's/^  unless within >= 0.0$/  unless within >= 0.0 || within < 0.0/'
prove_fails "assert_includes that never fails" includes_holds "assert_includes: a missing element" \
  's/^  return if collection.includes?(item)$/  return/'
prove_fails "assert_error that hides what came" error_mute "assert_error: a value where an error was due" \
  's/"\\n    actual: " + __iyi_describe_outcome(value), file, line)$/"", file, line)/'
prove_fails "an error described without its message" error_unsaid "assert_error: an error of another type" \
  's/^    value.class.to_s + " (an error: " + value.message.inspect + ")"$/    value.class.to_s/'
prove_fails "assert_panics that sees no panic" panics_blind "assert_panics: a panicking block passes it" \
  '/^  def assert_panics/,/^  end$/s/^      said = outcome.message if outcome.is_a?(Panicked)$/      said = nil/'
prove_fails "assert_panics that ignores the words" panics_wordless "assert_panics: a panic with other words" \
  's/^      if containing.is_a?(String) \&\& !said.includes?(containing)$/      if false/'

prove_driver_fails "a failure that names the library's line" no_site site_check \
  's/^  raise(headline + "\\n" + evidence, file, line)$/  raise(headline + "\\n" + evidence)/'
prove_driver_fails "named cases that count no failure" uncounted cases_check \
  's/^    @@failed = @@failed + 1 unless passed$/    @@failed = @@failed + 0/'
prove_driver_fails "a named case that ends the program" no_task cases_check \
  '/^  def test(name/,/^  end$/s/^        block.call$/        block.call; __iyi_exit(1)/'
prove_driver_fails "named cases that exit 1 with none failed" always_fails passing_cases_check \
  's/^    @@failed == 0 ? 0 : 1$/    1/'
prove_driver_fails "a summary when no case ran" always_summary no_cases_check \
  's/^    return 0 if @@ran == 0$/    puts "0 named tests"; return 0 if @@ran == 0/'

echo
if [ "$status" -eq 0 ]; then
  echo "assertions exercise: every check held, and every check can fail"
else
  echo "assertions exercise: FAILED"
fi
exit "$status"
