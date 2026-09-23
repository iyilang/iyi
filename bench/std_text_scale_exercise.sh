#!/usr/bin/env bash
# The library's text building is linear. Runs bench/std_text_scale_exercise.iyi - eight
# megabytes through join, reverse, tr, gsub, delete, squeeze, Regex#replace,
# each_line and String.build, each checked - plain and optimised, under a
# clock sixty times what it needs, and proves the clock catches a builder
# that grows by a fixed step rather than doubling: every method above then
# copies what it has written on each write, which is the `result = result +
# piece` shape they all had, and the run does not end.
#
#     bash bench/std_text_scale_exercise.sh
#
# Needs `make` first. Exits non-zero if any step fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
PSEP=":"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=";"
    ;;
esac
trap 'rm -rf "$WORK"' EXIT

status=0
DONE="each checked"

run_case() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_text_scale_exercise.iyi" >"$WORK/$name.build" 2>&1; then
    echo "  FAIL: $label: build failed"
    sed -n '1,12p' "$WORK/$name.build"
    status=1
    return
  fi
  timeout 60 "$WORK/$name" >"$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -ne 0 ] || ! grep -q "$DONE" "$WORK/$name.out"; then
    echo "  FAIL: $label exited $code:"
    tail -3 "$WORK/$name.out" | sed 's/^/    /'
    status=1
    return
  fi
  echo "  ok   $label: $(cat "$WORK/$name.out")"
}

echo "== eight megabytes, plain and optimised"
run_case "default" plain
run_case "release" optimised --release

echo
echo "== the clock catches a builder that does not double"
mkdir -p "$WORK/stepped/iyi"
cp -R "$REPO/src/iyi/." "$WORK/stepped/iyi/"
sed -e 's/^      capacity = capacity \* 2$/      capacity = capacity + 16/' \
  "$REPO/src/iyi/string.iyi" > "$WORK/stepped/iyi/string.iyi"
if cmp -s "$REPO/src/iyi/string.iyi" "$WORK/stepped/iyi/string.iyi"; then
  echo "  FAIL: the patch changed nothing; the doubling line is not where it was"
  status=1
elif ! IYI_PATH="$WORK/stepped${PSEP}$REPO/src" "$IYI" build --release \
       -o "$WORK/stepped/program" "$REPO/bench/std_text_scale_exercise.iyi" >"$WORK/stepped/build" 2>&1; then
  echo "  FAIL: the patched prelude did not build"
  sed -n '1,12p' "$WORK/stepped/build"
  status=1
else
  timeout 20 "$WORK/stepped/program" >"$WORK/stepped/out" 2>&1
  code=$?
  if [ "$code" -eq 124 ]; then
    echo "  caught: twenty seconds and it had not finished"
  else
    echo "  FAIL: the stepped builder exited $code within the clock, so the clock proves nothing"
    status=1
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "text scale gate: every step held"
else
  echo "text scale gate: FAILED"
fi
exit "$status"
