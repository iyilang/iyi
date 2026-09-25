#!/usr/bin/env bash
# Drives bench/parallel_mark.iyi: the parallel marker, GC_DESIGN.md Stage 7.
#
#     bash bench/parallel_mark.sh
#
# Five steps, the last three failure proofs:
#   1. The program holds, release: a million-node tree survives five marks
#      alone and five with helpers, and the helpers blackened nodes; the
#      pool holds a handful of pieces after them; a worker's stack grew to
#      hold a 300,000-wide object marked alone.
#   2. The two pause means, printed: alone against with helpers.
#   3. Failure proof: the marker's donation of its stack's bottom removed
#      from a copy of the prelude; the helpers wake and find nothing, and
#      the program exits 1 saying so.
#   4. Failure proof: a batch taken is never freed; no batch is ever
#      handed out twice, and the pool check says so on any machine.
#   5. Failure proof: a stack that will not grow dies where it used to,
#      by name, on the wide object.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The gate runs whatever compiler the caller names; `bin/iyi` is a shell
# wrapper, and on Windows the caller has to point at the built exe itself.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` on it is silently ignored, so the patched
# copy is never read and the proof that a check can fail quietly stops
# proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac
cd "$WORK" || exit 1

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

step() { echo "== $1"; }

case "$(uname -s)" in
  Linux | Darwin | MINGW* | MSYS* | CYGWIN* | Windows_NT) ;;
  *) echo "parallel mark: measured on Linux, darwin and Windows; nothing to measure here"; exit 0 ;;
esac

# The cores this process may run on - `nproc` reads the affinity mask, so
# `taskset -c 0` is one core here - and not the machine's count.
CORES="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
export PARALLEL_MARK_CORES="$CORES"

step "the parallel marker, release build"
if ! "$IYI" build --release "$REPO/bench/parallel_mark.iyi" -o marks > build.log 2>&1; then
  cat build.log; exit 1
fi
if ! timeout -k 5 300 ./marks > answers.txt 2>&1; then
  cat answers.txt; exit 1
fi
grep -q 'every property held' answers.txt || { cat answers.txt; exit 1; }

step "the mark, alone and with helpers ($CORES cores here)"
grep -E '^(tree|mark|pool|stack):' answers.txt | sed 's/^/  /'

# $1 label, $2 awk program over the prelude, $3 the phrase the failing check
# prints, $4 the exit code expected.
prove_fails() {
  local label="$1" script="$2" phrase="$3" want="$4" dir="patched-$RANDOM"
  step "failure proof: $label"
  mkdir -p "$dir/iyi"
  cp "$REPO"/src/iyi/*.iyi "$dir/iyi/"
  awk "$script" "$REPO/src/iyi/prelude.iyi" > "$dir/iyi/prelude.iyi"
  cmp -s "$dir/iyi/prelude.iyi" "$REPO/src/iyi/prelude.iyi" && { echo "the awk found nothing to change"; exit 1; }
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/parallel_mark.iyi" -o "$dir/program" > "$dir/build.log" 2>&1; then
    cat "$dir/build.log"; exit 1
  fi
  timeout -k 5 300 "./$dir/program" > "$dir/out.txt" 2>&1
  local code=$?
  if [ "$code" -ne "$want" ] || ! grep -q "$phrase" "$dir/out.txt"; then
    echo "the check did not fire (exit $code, wanted $want at \"$phrase\"):"; tail -3 "$dir/out.txt"; exit 1
  fi
  printf '  exits %s at "%s"\n' "$code" "$(grep -m1 "$phrase" "$dir/out.txt")"
}

# On one core the helpers are never scheduled while the marker works, so
# the checks that need one - sharing, and recycling what was shared - are
# off, and there is nothing for their proofs to show.
if [ "$CORES" -gt 1 ]; then
  prove_fails "a marker that never shares its stack is refused" \
    '{ sub(/since >= DONATE_EVERY/, "false \\&\\& since >= DONATE_EVERY"); print }' "blackened nothing" 1
else
  step "failure proof: a marker that never shares its stack is refused"
  echo "  one core here: the sharing check needs a second, so it and its proof are off"
fi

# A taken batch's words never go back: every batch published is a fresh
# one, and the pool has reused none.
if [ "$CORES" -gt 1 ]; then
  prove_fails "a pool that never recycles a batch is refused" \
    '{ if ($0 ~ /^        free_batch\(batch\)$/) { print "        # removed"; next } print }' "pool:" 1
else
  step "failure proof: a pool that never recycles a batch is refused"
  echo "  one core here: no helper takes a batch, so recycling is not asked and not proved"
fi

# The stack never grows: the fatal it used to be, on the wide object.
prove_fails "a stack that will not grow dies by name" \
  '{ if ($0 ~ /^        return IyiHeap\.read64\(w \+ W_STACK\) if need <= cap$/) { print "        IyiRoots.fatal(\"iyi: a mark worker'"'"'s stack overflowed\\n\") if need > cap"; print; next } print }' "stack overflowed" 1

echo "workdir $WORK"
echo "parallel mark: every step held"
exit 0
