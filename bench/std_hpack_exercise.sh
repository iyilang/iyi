#!/usr/bin/env bash
# Exercises `std/hpack`: RFC 7541 Header Compression for HTTP/2.
#
#     bash bench/std_hpack_exercise.sh
#
# Proves the exercise holds plain and --release, that RFC 7541 test vectors
# match byte-for-byte, that static and dynamic table lookups, insertions,
# evictions, and size updates behave per spec, that realistic request and
# response header sets round-trip cleanly, that broken codecs are caught by
# mutation, and that malformed or truncated inputs are refused.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_hpack_exercise.iyi" \
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

echo "== the std/hpack exercise, plain build"
build_and_run "plain" hpack-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/hpack-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every hpack section reported"
for phrase in "== RFC 7541 integer codec" \
              "== RFC 7541 Huffman codec" \
              "== RFC 7541 request and response vectors" \
              "== static table hits" \
              "== dynamic table eviction at capacity" \
              "== table size update" \
              "== realistic round trip" \
              "== decoder refusals on malformed and truncated wire" \
              "== overflow, two size updates, mid-block size, C.5"; do
  if ! grep -q "$phrase" "$WORK/hpack-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  all sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" hpack-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/hpack-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched/std"
  "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/hpack.iyi").read_text()
old = 'if val < prefix_max'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/hpack.iyi").write_text(src.replace(old, 'if false', 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_hpack_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on a broken module"
    status=1
  else
    echo "  a broken hpack is caught"
  fi
fi

if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched2/std"
  "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/hpack.iyi").read_text()
old = 'if @pending_min_table_size < @pending_table_size'
if old not in src:
    raise SystemExit("two-update patch site missing")
Path("$WORK/patched2/std/hpack.iyi").write_text(src.replace(old, 'if false', 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the two-update patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched2${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_hpack_exercise.iyi" >"$WORK/mut2.out" 2>&1; then
    echo "  the exercise PASSED without RFC 4.2 two size updates"
    status=1
  else
    echo "  a missing two-size-update is caught"
  fi
fi

echo
echo "== what integer encoding refuses"
refuses() { # refuses <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expr="$4"
  printf 'module main\n\nimport std/hpack::{Integer}\n\n%s\n' "$expr" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,10p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of refusing: $(cat "$WORK/$name.out")"
    status=1
    return
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase'"
    sed -n '1,3p' "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(sed -n '1p' "$WORK/$name.out" | sed 's/^iyi: panic: //')"
}
refuses "prefix_bits zero" prefix_zero "prefix_bits must be between 1 and 8" 'Integer.encode(10_u64, 0)'
refuses "prefix_bits nine" prefix_nine "prefix_bits must be between 1 and 8" 'Integer.encode(10_u64, 9)'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/hpack exercise holds"
else
  echo "the std/hpack exercise did not hold"
fi
exit $status
