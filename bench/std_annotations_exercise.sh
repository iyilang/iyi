#!/usr/bin/env bash
# Exercises `std/annotations`.
#
#     bash bench/std_annotations_exercise.sh
#
# Proves the exercise holds plain and --release, that an unexported annotation
# is caught by using, that dummy annotation types (not the compiler's) fail
# the identity checks, and what the annotations refuse after `using`:
# non-string messages for Deprecated and Experimental, unrecognized named
# arguments for TargetFeature, empty Link, a missing library name actually
# passed to the linker, and a deprecation warning on a call.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# the patches and oracles below are written in python, and windows answers
# `python3` with a store stub that prints and exits rather than running it, so
# the interpreter is measured here instead of assumed.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from `pwd` is `/c/...` and finds no prelude at all, and a
# scratch directory named `/tmp/tmp.X` is silently ignored on that path, so
# the patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_annotations_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/annotations exercise, plain build"
build_and_run "plain" annotations-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/annotations-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every annotations section reported"
for phrase in "== identity" "== flags" "== deprecated" "== experimental" "== target_feature" "== link"; do
  if ! grep -q "$phrase" "$WORK/annotations-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" annotations-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/annotations-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
mkdir -p "$WORK/patched/std"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the broken-module proof is unmeasured"
elif ! "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/annotations.iyi").read_text()
old = 'pub alias Flags = ::Flags'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/annotations.iyi").write_text(src.replace(old, 'alias Flags = ::Flags', 1))
PY
then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_annotations_exercise.iyi" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  an unexported annotation is caught"
fi

echo
echo "== dummy annotation types fail the identity checks"
mkdir -p "$WORK/dummy/std"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the dummy-annotation proof is unmeasured"
elif ! "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/annotations.iyi").read_text()
for name in ("Deprecated", "Flags", "Link", "Experimental", "TargetFeature"):
    old = f"pub alias {name} = ::{name}"
    if old not in src:
        raise SystemExit(f"dummy patch site missing: {name}")
    src = src.replace(old, f"pub annotation {name}\nend", 1)
Path("$WORK/dummy/std/annotations.iyi").write_text(src)
PY
then
  echo "  the dummy patch did not apply"
  status=1
elif IYI_PATH="$WORK/dummy${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_annotations_exercise.iyi" >"$WORK/dummy.out" 2>&1; then
  echo "  the exercise PASSED on dummy annotation types"
  status=1
else
  echo "  dummy types are caught by identity"
fi

echo
echo "== what annotations refuse"
refuses() { # refuses <label> <name> <phrase> <code_snippet>
  local label="$1" name="$2" phrase="$3" snippet="$4"
  printf 'module %s\nimport std/annotations\nusing std/annotations::{Deprecated, Experimental, TargetFeature, Link}\n%s\n' "$name" "$snippet" > "$WORK/$name.iyi"
  if "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build.log" 2>&1; then
    echo "  $label: unexpectedly succeeded"
    status=1
    return 1
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name.build.log"; then
    echo "  $label: failed without expected error ($phrase)"
    sed -n '1,6p' "$WORK/$name.build.log" | sed 's/^/    /'
    status=1
    return 1
  fi
  printf '  %s: refused with "%s"\n' "$label" "$phrase"
}

refuses "non-string Deprecated message" bad_dep "first argument must be a String" \
  $'@[Deprecated(123)]\ndef bad_dep\nend'
refuses "non-string Experimental message" bad_exp "first argument must be a String" \
  $'@[Experimental(456)]\ndef bad_exp\nend'
refuses "invalid TargetFeature named argument" bad_tf "no argument named 'invalid', expected 'cpu'" \
  $'class Simd\n  @[TargetFeature(invalid: "cpu")]\n  def bad_tf\n  end\nend'
refuses "empty Link" bad_link "missing link arguments: must at least specify a library name" \
  $'@[Link]\nlib LibEmpty\nend'
# What this arm is about is that a library named and not present is refused by
# that name. The posix linker says so with `-lnosuchlib...`; the windows link
# step says it cannot locate the `.lib`, so the wording asked for is the
# platform's own and neither spelling is pinned on the other.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    missing_library="Cannot locate the .lib files for the following libraries: nosuchlib_annotations_probe"
    ;;
  *) missing_library="-lnosuchlib_annotations_probe" ;;
esac
refuses "bogus Link library" bad_lib "$missing_library" \
  $'@[Link("nosuchlib_annotations_probe")]\nlib LibMissing\n  fun nosuch_annotations_probe_sym : Int32\nend\nputs LibMissing.nosuch_annotations_probe_sym'

echo
echo "== deprecation warning after using"
printf '%s\n' \
  'module dep_warn' \
  'import std/annotations' \
  'using std/annotations::{Deprecated}' \
  'class G' \
  '  @[Deprecated("use hi")]' \
  '  def old_hi : String' \
  '    "old"' \
  '  end' \
  'end' \
  'puts G.new.old_hi' \
  > "$WORK/dep_warn.iyi"
if ! "$IYI" build -o "$WORK/dep_warn" "$WORK/dep_warn.iyi" > "$WORK/dep_warn.build.log" 2>&1; then
  echo "  dep_warn: build failed"
  sed -n '1,8p' "$WORK/dep_warn.build.log" | sed 's/^/    /'
  status=1
elif ! grep -q "Warning: Deprecated" "$WORK/dep_warn.build.log"; then
  echo "  dep_warn: compiled without a deprecation warning"
  status=1
else
  echo "  calling a @[Deprecated] method warns"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/annotations exercise holds"
else
  echo "the std/annotations exercise did not hold"
fi
exit $status
