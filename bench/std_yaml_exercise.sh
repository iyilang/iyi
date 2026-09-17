#!/usr/bin/env bash
# Exercises `std/yaml`: YAML 1.2 core schema, dump, anchors, merge, refusals.
#
#     bash bench/std_yaml_exercise.sh
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

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_yaml_exercise.iyi" \
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

echo "== the std/yaml exercise, plain build"
build_and_run "plain" yaml-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/yaml-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every yaml section reported"
for phrase in "== scalars and collections" "== dump round trip" "== anchors, aliases, merge" "== streams and typed keys" "== what the reader refuses"; do
  if ! grep -q "$phrase" "$WORK/yaml-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  scalars, dump, anchors, streams and refusals all reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" yaml-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/yaml-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when a repeated key is accepted"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched_dup/std"
  SRC="$REPO/src/std/yaml.iyi" DST="$WORK/patched_dup/std/yaml.iyi" "$PY" - <<'PY'
import os
from pathlib import Path
src = Path(os.environ["SRC"]).read_text()
old = "if !merge && spelled.has_key?(key)"
new = "if !merge && spelled.has_key?(key) && false"
if old not in src:
    raise SystemExit("patch site missing")
Path(os.environ["DST"]).parent.mkdir(parents=True, exist_ok=True)
Path(os.environ["DST"]).write_text(src.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched_dup${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_yaml_exercise.iyi" >"$WORK/dup.out" 2>&1; then
    echo "  the exercise PASSED with duplicate keys accepted"
    status=1
  else
    echo "  a repeated mapping key is caught"
  fi
fi

echo
echo "== proving the checks can fail when alias expansion is unbounded"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched_alias/std"
  SRC="$REPO/src/std/yaml.iyi" DST="$WORK/patched_alias/std/yaml.iyi" "$PY" - <<'PY'
import os
from pathlib import Path
src = Path(os.environ["SRC"]).read_text()
old = "if @expanded > ALIAS_NODE_LIMIT"
new = "if @expanded > ALIAS_NODE_LIMIT && false"
if old not in src:
    raise SystemExit("patch site missing")
Path(os.environ["DST"]).parent.mkdir(parents=True, exist_ok=True)
Path(os.environ["DST"]).write_text(src.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched_alias${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" timeout 60 "$IYI" run "$REPO/bench/std_yaml_exercise.iyi" >"$WORK/alias.out" 2>&1; then
    echo "  the exercise PASSED with alias expansion unbounded"
    status=1
  else
    echo "  unbounded alias expansion is caught"
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/yaml exercise holds"
else
  echo "the std/yaml exercise did not hold"
fi
exit $status
