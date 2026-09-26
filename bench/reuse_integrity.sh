#!/usr/bin/env bash
# A chunk the collector hands out is nobody else's while its object lives,
# and it is new: a field its constructor never set reads nil. Runs
# bench/reuse_integrity.iyi plain and optimised, three times each - the
# break the first check catches is timing-shaped, and a repeated run makes
# a flake a failure - and proves each check fails with its fix taken out:
# the release of a listed chunk's first words put back, and a release that
# leaves a page's bytes where they were.
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
FRESH="every unset field nil"
# darwin's release is `MADV_FREE_REUSABLE`, which keeps a page's bytes
# until the kernel wants the memory, exactly as Windows' `MEM_RESET` did:
# the fresh-object check would fail there, and does not run. That is an
# open defect (CHANGELOG, Unreleased), said here rather than passed.
case "$(uname -s)" in
  Darwin) FRESH="" ;;
esac

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
    if [ "$exit_code" -ne 0 ] || ! grep -q "$DONE" "$WORK/$name.out" ||
       { [ -n "$FRESH" ] && ! grep -q "$FRESH" "$WORK/$name.out"; }; then
      echo "  FAIL: $label, run $again, exited $exit_code:"
      sed 's/^/    /' "$WORK/$name.out" | tail -3
      status=1
      return
    fi
  done
  echo "  ok   $label, three runs:"
  sed 's/^reuse integrity: /         /' "$WORK/$name.out"
}

# A copy of the library with one edit to the prelude, built and run three
# times; the proof holds when a run fails without the sentence the working
# program prints. `$1` names the proof, `$2` is the awk that makes the
# edit and exits 3 when the line it edits is not there, `$3` the sentence
# a passing run prints.
prove_breaks() {
  local name="$1" edit="$2" sentence="$3"
  mkdir -p "$WORK/$name/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$name/iyi/"
  awk "$edit" "$REPO/src/iyi/prelude.iyi" > "$WORK/$name/iyi/prelude.iyi"
  if [ $? -ne 0 ]; then
    echo "  the line this proof edits is not in the prelude any more; update the proof"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$name${PSEP}$REPO/src" "$IYI" build --release \
       -o "$WORK/$name/program" "$REPO/bench/reuse_integrity.iyi" \
       >"$WORK/$name/build.log" 2>&1; then
    echo "  the patched prelude did not build"
    sed -n '1,12p' "$WORK/$name/build.log"
    status=1
    return
  fi
  local caught=0 again exit_code=0
  for again in 1 2 3; do
    ("$WORK/$name/program" >"$WORK/$name/out" 2>&1)
    exit_code=$?
    if [ "$exit_code" -ne 0 ] && ! grep -q "$sentence" "$WORK/$name/out"; then
      caught=1
      break
    fi
  done
  if [ "$caught" -eq 1 ]; then
    if [ "$exit_code" -ge 128 ]; then
      echo "  caught on run $again: the program died on signal $((exit_code - 128)) before it could report"
    else
      echo "  caught on run $again: $(grep -m1 "panic: \|memory fault" "$WORK/$name/out" | sed 's/^iyi: panic: //' | cut -c1-150)"
    fi
  else
    echo "  FAIL: three runs with the fix taken out and the exercise passed every time"
    status=1
  fi
}

echo "== the exercise, the default allocator"
run_case "default" plain
run_case "release" optimised --release

# Both proofs need a release that zeroes a page at once, which is what
# the first one's break is (a zeroed word) and what the second one takes
# away. Linux's `MADV_DONTNEED` does, and Windows' decommit and commit
# does; darwin's release does not (above), so neither proof can be shown
# on demand there.
case "$(uname -s)" in
  Darwin)
    echo
    echo "== the proofs"
    echo "  not here: darwin keeps a released page's bytes until it needs the memory, so neither break can be shown on demand; Linux and Windows run both"
    echo
    if [ "$status" -eq 0 ]; then
      echo "reuse integrity gate: every step held"
    else
      echo "reuse integrity gate: FAILED"
    fi
    exit "$status"
    ;;
esac

echo
echo "== the check fails when a released page takes a listed chunk's words"
# The straddler's page released with the rest, as it was: the lowest chunk
# of a cold run keeps its place on the list with its slot word zeroed.
# Linux and Windows, which sweep with helper threads, show the break in
# the exercise: on Windows the exercise failed 20 runs of 20 with the line
# taken out once its helpers swept, and passed 20 of 20 while its lazy
# sweep was the allocator's alone.
prove_breaks straddler \
  '{ if ($0 ~ /^        cold_low = cold_low \+ IyiHeap::PAGE if straddler >= low && /) { print "        # removed"; found = 1; next } print }
   END { if (!found) exit 3 }' \
  "$DONE"

echo
echo "== the check fails when a released page keeps its bytes"
# The release as advice again: `MADV_FREE` on Linux and `MEM_RESET` on
# Windows, each of which leaves a page's bytes in place until the kernel
# is short of memory - so a fresh object carved on the page reads what
# lived there. Only the platform's own arm of `__iyi_release_pages` is
# compiled, and the edit makes both; it has to find the one it knows.
prove_breaks advice \
  '/^      fun __iyi_release_pages\(address : UInt64, length : UInt64\) : Nil$/ { inside = 1 }
   inside && /^      end$/ { inside = 0 }
   inside && $0 == "        __iyi_madvise(address, length, 4_i64)" { print "        __iyi_madvise(address, length, 8_i64)"; found = found + 1; next }
   inside && $0 == "        LibC.VirtualFree(Pointer(Void).new(address), length, 0x4000_i32)" { print "        LibC.VirtualAlloc(Pointer(Void).new(address), length, 0x80000_i32, 4_i32)"; found = found + 1; next }
   inside && $0 == "        LibC.VirtualAlloc(Pointer(Void).new(address), length, 0x1000_i32, 4_i32)" { next }
   { print }
   END { if (found != 2) exit 3 }' \
  "$FRESH"

echo
if [ "$status" -eq 0 ]; then
  echo "reuse integrity gate: every step held"
else
  echo "reuse integrity gate: FAILED"
fi
exit "$status"
