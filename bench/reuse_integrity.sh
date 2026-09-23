#!/usr/bin/env bash
# A chunk the collector hands out is nobody else's while its object lives.
# Runs bench/reuse_integrity.iyi plain and optimised, three times each - the
# break it catches is timing-shaped, and a repeated run makes a flake a
# failure - and proves the check fails with the release of a listed chunk's
# first words put back.
#
#   bash bench/reuse_integrity.sh
#
# Needs `make` first. Exits non-zero if any step fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
PSEP=":"
# A native compiler cannot read this shell's path mapping, and a patched
# prelude it cannot find is a proof that quietly stops proving.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=";"
    ;;
esac
trap 'rm -rf "$WORK"' EXIT

status=0
DONE="every key spells its value, the startup constant intact"

run_case() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/reuse_integrity.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    sed -n '1,12p' "$WORK/$name.build.log"
    status=1
    return
  fi
  local again
  for again in 1 2 3; do
    "$WORK/$name" >"$WORK/$name.out" 2>&1
    local exit_code=$?
    if [ "$exit_code" -ne 0 ] || ! grep -q "$DONE" "$WORK/$name.out"; then
      echo "  FAIL: $label, run $again, exited $exit_code:"
      sed 's/^/    /' "$WORK/$name.out" | tail -3
      status=1
      return
    fi
  done
  echo "  ok   $label, three runs: $(sed 's/^reuse integrity: //' "$WORK/$name.out")"
}

echo "== the exercise, the default allocator"
run_case "default" plain
run_case "release" optimised --release

echo
echo "== the check fails when a released page takes a listed chunk's words"
# The break is a zeroed word, and only Linux zeroes a released page at once
# (`MADV_DONTNEED`). darwin's `MADV_FREE_REUSABLE` and Windows' `MEM_RESET`
# leave the bytes where they were until the kernel wants the memory, so
# there the same bug waited for memory pressure and a run cannot be made to
# show it. The checks above run everywhere; the proof runs where it can.
case "$(uname -s)" in
  Linux) ;;
  *)
    echo "  not here: $(uname -s) keeps a released page's bytes until it needs the memory, so the break cannot be shown on demand; Linux runs this proof"
    echo
    if [ "$status" -eq 0 ]; then
      echo "reuse integrity gate: every step held"
    else
      echo "reuse integrity gate: FAILED"
    fi
    exit "$status"
    ;;
esac
# The straddler's page released with the rest, as it was: the lowest chunk
# of a cold run keeps its place on the list with its slot word zeroed.
mkdir -p "$WORK/broken/iyi"
cp -R "$REPO/src/iyi/." "$WORK/broken/iyi/"
awk '{ if ($0 ~ /^        cold_low = cold_low \+ IyiHeap::PAGE if straddler >= low && /) { print "        # removed"; found = 1; next } print }
     END { if (!found) exit 3 }' \
  "$REPO/src/iyi/prelude.iyi" > "$WORK/broken/iyi/prelude.iyi"
if [ $? -ne 0 ]; then
  echo "  the line this proof removes is not in the prelude any more; update the proof"
  status=1
elif ! IYI_PATH="$WORK/broken${PSEP}$REPO/src" "$IYI" build --release \
       -o "$WORK/broken/program" "$REPO/bench/reuse_integrity.iyi" \
       >"$WORK/broken/build.log" 2>&1; then
  echo "  the patched prelude did not build"
  sed -n '1,12p' "$WORK/broken/build.log"
  status=1
else
  caught=0
  for again in 1 2 3; do
    ("$WORK/broken/program" >"$WORK/broken/out" 2>&1)
    exit_code=$?
    if [ "$exit_code" -ne 0 ] && ! grep -q "$DONE" "$WORK/broken/out"; then
      caught=1
      break
    fi
  done
  if [ "$caught" -eq 1 ]; then
    if [ "$exit_code" -ge 128 ]; then
      echo "  caught on run $again: the program died on signal $((exit_code - 128)) before it could report"
    else
      echo "  caught on run $again: $(grep -m1 "reuse integrity" "$WORK/broken/out" | sed 's/^iyi: panic: //' | cut -c1-150)"
    fi
  else
    echo "  FAIL: three runs with the words released and the exercise passed every time"
    status=1
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "reuse integrity gate: every step held"
else
  echo "reuse integrity gate: FAILED"
fi
exit "$status"
