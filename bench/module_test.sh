# The driver of a std module whose program is a test, `bench/std_<m>_test.iyi`,
# run by `iyi test`. Sourced by `bench/std_<m>_exercise.sh` once it has set
# MODULE, which is everything those drivers had in common, written once:
#
#     MODULE=heap
#     . "$(cd "$(dirname "$0")" && pwd)/module_test.sh"
#     module_test_holds 1 "min-heap pop order"
#     module_test_breaks 'old text' 'new text' "min-heap pop order"
#     module_test_end
#
# Four drivers carried every line of this, the same but for the module's
# name, and a fix to one was a fix to four.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The compiler, overridable: `bin/iyi` is a POSIX shell wrapper, and on
# Windows the caller is the only one who knows where the real binary is.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on that path, so the
# patched copy is never read and the proof that a check can fail quietly
# stops proving it. And the search path's separator is the platform's:
# `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=';'
    ;;
  *) PSEP=':' ;;
esac
trap 'rm -rf "$WORK"' EXIT

# The broken copy is patched by python, and a machine can answer `python3`
# with a store stub that prints a refusal instead of running, so the
# interpreter is proven to run before it is trusted.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"
TEST="$REPO/bench/std_${MODULE}_test.iyi"

# module_test_holds <count> <case>...
#
# `iyi test --json` passes, and every case named passed by name: one that
# did not pass, or did not run at all, is named. Then the same program built
# with --release says all <count> of its named cases passed.
module_test_holds() {
  local count="$1" case_name
  shift
  echo "== the std/$MODULE test, through iyi test"
  "$IYI" test --json "$TEST" >"$WORK/plain.json" 2>&1
  local plain_status=$? missing=0
  for case_name in "$@"; do
    if ! grep -qF "{\"name\":\"$case_name\",\"status\":\"pass\"}" "$WORK/plain.json"; then
      echo "  the case '$case_name' did not pass"
      missing=1
    fi
  done
  if [ "$plain_status" -ne 0 ] || [ "$missing" -ne 0 ]; then
    echo "plain: iyi test exited $plain_status"
    cat "$WORK/plain.json"
    status=1
  else
    echo "  every named case passed"
  fi

  echo
  echo "== the same program with optimisation on (--release)"
  if ! "$IYI" test --release --json "$TEST" >"$WORK/release.json" 2>&1; then
    echo "release: the named cases did not all pass"
    cat "$WORK/release.json"
    status=1
  elif [ "$(grep -o '"status":"pass"' "$WORK/release.json" | wc -l | tr -d ' ')" -ne $((count + 1)) ]; then
    # Each case's pass and the file's own.
    echo "release: not all $count named cases reported a pass"
    cat "$WORK/release.json"
    status=1
  else
    echo "  every named case passed"
  fi
}

# module_test_breaks <old> <new> <case>
#
# A copy of `src/std/$MODULE.iyi` with <old> replaced by <new>, ahead of the
# real one on the search path, fails the case <case> by name: a test that
# failed elsewhere, or a copy that does not build, proves nothing about it.
module_test_breaks() {
  local old="$1" new="$2" case_name="$3"
  echo
  echo "== proving the checks can fail when the module is broken"
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the broken-module proof is unmeasured"
    return
  fi
  mkdir -p "$WORK/patched/std"
  if ! OLD="$old" NEW="$new" "$PY" - "$REPO/src/std/$MODULE.iyi" "$WORK/patched/std/$MODULE.iyi" <<'PY'
import os, sys
from pathlib import Path
src = Path(sys.argv[1]).read_text()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing")
Path(sys.argv[2]).write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the patch did not apply"
    status=1
    return
  fi
  IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" test --json "$TEST" >"$WORK/mut.json" 2>&1
  local mut_status=$?
  if [ "$mut_status" -ne 1 ]; then
    echo "  the test did not fail on a broken module (exit $mut_status)"
    cat "$WORK/mut.json"
    status=1
  elif ! grep -qF "{\"name\":\"$case_name\",\"status\":\"fail\"" "$WORK/mut.json"; then
    echo "  the test failed, but not at the case '$case_name'"
    cat "$WORK/mut.json"
    status=1
  else
    echo "  a broken $MODULE fails the case '$case_name'"
  fi
}

module_test_end() {
  echo
  if [ "$status" -eq 0 ]; then
    echo "the std/$MODULE exercise holds"
  else
    echo "the std/$MODULE exercise did not hold"
  fi
  exit "$status"
}
