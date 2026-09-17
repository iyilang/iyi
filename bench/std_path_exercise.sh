#!/usr/bin/env bash
# Exercises `std/path`: POSIX and Windows names, expand, relative_to.
#
#     bash bench/std_path_exercise.sh
#
# The expand checks read HOME and PWD from the environment; this script
# pins both so the answers are the same on every machine.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The gate runs the compiler the caller names; bin/iyi is a POSIX shell
# wrapper a Windows build cannot run.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

# The negative proofs are patched by python, and a machine can answer
# `python3` with a store stub that prints a refusal instead of running, so
# the interpreter is resolved once and proven to run before it is trusted.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"
export HOME=/home/gate
export PWD=/pwd/gate
# This shell rewrites an exported value that looks like a POSIX path before
# a native process reads it: the pinned PWD arrived as
# `C:/Program Files/Git/pwd/gate`, which the posix kind calls relative, and
# expand refused its own base. Both names are handed back to the gate.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) export MSYS2_ENV_CONV_EXCL="HOME;PWD" ;;
esac

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_path_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  grep -v '^oracle ' "$WORK/$name.out" | sed 's/^/  /'
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/path exercise, plain build"
build_and_run "plain" path-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/path-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every path section reported"
for phrase in "== normalize corpus" "== join" "== relative_to" "== expand" "== windows kind" "== path comparison"; do
  if ! grep -q "$phrase" "$WORK/path-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  normalize, join, relative_to, expand, windows and Comparable all reported"

echo
echo "== normalize and relpath against python3 posixpath"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so normalize and relpath were not compared with posixpath"
else
  "$PY" - "$WORK/path-plain.out" <<'PY'
import posixpath, sys
status = 0
for line in open(sys.argv[1]):
    if not line.startswith("oracle "):
        continue
    kind, *rest = line.rstrip("\n").split("\t")
    kind = kind.split()[1]
    if kind == "normpath":
        name, got = rest
        expect = posixpath.normpath(name)
        if got != expect:
            print(f"  FAIL normpath {name!r}: iyi {got!r} python {expect!r}")
            status = 1
    elif kind == "relpath":
        name, base, got = rest
        expect = posixpath.relpath(name, base)
        if got != expect:
            print(f"  FAIL relpath {name!r} {base!r}: iyi {got!r} python {expect!r}")
            status = 1
sys.exit(status)
PY
  if [ $? -ne 0 ]; then
    status=1
  else
    echo "  every oracle line agrees with posixpath"
  fi
fi

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" path-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/path-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when .. is not folded"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched_dot/std"
  "$PY" - <<PY
src = open("$REPO/src/std/path.iyi").read()
old = 'elsif seg == ".."'
# break only the first when ".." in normalize if present
if old not in src:
    raise SystemExit("patch site missing")
open("$WORK/patched_dot/std/path.iyi", "w").write(src.replace(old, 'elsif seg == "..x"', 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched_dot${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" HOME=/home/gate PWD=/pwd/gate "$IYI" run "$REPO/bench/std_path_exercise.iyi" >"$WORK/dot.out" 2>&1; then
    echo "  the exercise PASSED with .. not folded"
    status=1
  else
    echo "  a normalize that leaves .. is caught"
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/path exercise holds"
else
  echo "the std/path exercise did not hold"
fi
exit $status
