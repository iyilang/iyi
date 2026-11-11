#!/usr/bin/env bash
# heap22's compiler side (S3), driven: bench/heap_codegen.iyi built with
# partitions, the verifier and the chaos scheduler, plain and optimised,
# every check passing and the verifier silent; the pin notes in the
# build's output; then one broken copy of the compiler per mechanism, each
# turned off by `IYI_SPAWN_BROKEN` at build time, and each caught twice:
# by the verifier, and by the check of its mechanism.
#
#   bash bench/heap_codegen.sh
#
# Needs `make` first. `FLAGS` replaces the build flags (default
# `-Dheap_partitions -Dheap_verify -Diyi_chaos`); `FLAGS=` runs the
# flag-off control alone, every check passing and no copy built. Every run
# has a fixed chaos seed (`SEED`, default 1) and `IYI_HEAP_STRESS=1`, as
# bench/heap_verify.sh's do. Exits non-zero if any step fails.
#
# A copy is caught when every one of `RUNS` (default 2) runs with
# `HEAP22_PRINT_ONLY=1` - the program's failed checks print their `FAIL:`
# line and the run goes on - exits 86 with the same `iyi: heap_verify:`
# report: its partition, what the slot named, the holder's and the
# target's type, size and field, with addresses masked; the count of
# checks run before it (which bench/heap_verify.sh's comparison leaves
# out too), which the pool's threads move by one or two run to run, and
# the holder's own holders, which a search of what is still live finds
# or not, are masked and left out;
# and when the run without it stops at its check's `FAIL:` line, read
# before any collection. A copy whose loss no verifier sees is listed
# apart (`OWN_ONLY`), with why, and caught by its `FAIL:` line alone.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
FLAGS="${FLAGS--Dheap_partitions -Dheap_verify -Diyi_chaos}"
SEED="${SEED:-1}"
RUNS="${RUNS:-2}"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac
trap 'rm -rf "$WORK"' EXIT

# The copies whose loss the verifier cannot see, and why: none. A
# function, not an associative array, for macOS's bash 3.2.
own_only() { # copy
  case "$1" in
    *) echo "" ;;
  esac
}

status=0

build() { # name compiler-env extra-flags
  local name="$1" compiler_env="$2" extra="$3"
  # shellcheck disable=SC2086
  env "$compiler_env" "$IYI" build $FLAGS $extra -o "$WORK/$name" "$REPO/bench/heap_codegen.iyi" \
    >"$WORK/$name.build.log" 2>&1
}

verified() { # program tag print-only args...
  local program="$1" tag="$2" print="$3"
  shift 3
  env IYI_CHAOS="$SEED" IYI_HEAP_STRESS=1 ${print:+HEAP22_PRINT_ONLY=1} \
    timeout 300 "$WORK/$program" "$@" >"$WORK/$tag.out" 2>"$WORK/$tag.err"
  echo $? >"$WORK/$tag.code"
}

run_case() { # label name extra-flags
  local label="$1" name="$2" extra="$3"
  if ! build "$name" IYI_SPAWN_BROKEN= "$extra"; then
    echo "$label: build failed"
    sed -n '1,12p' "$WORK/$name.build.log"
    status=1
    return
  fi
  verified "$name" "$name" ""
  local code
  code="$(cat "$WORK/$name.code")"
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$code" -ne 0 ] || grep -q "^iyi: heap_verify: " "$WORK/$name.err"; then
    echo "$label: exit $code"
    sed -n '1,8p' "$WORK/$name.err" | sed 's/^/  /'
    status=1
  fi
}

echo "== the compiler's mechanisms, plain ($FLAGS, IYI_CHAOS=$SEED IYI_HEAP_STRESS=1)"
run_case "plain" plain ""
echo "== the compiler's mechanisms, optimised"
run_case "release" release "--release"

case "$FLAGS" in
  *heap_partitions*) ;;
  *)
    if grep -q "runs in the shared heap" "$WORK/plain.build.log"; then
      echo "flag-off: a pin note was printed without partitions"
      status=1
    fi
    echo
    [ "$status" -eq 0 ] && echo "heap_codegen: the flag-off control holds."
    exit "$status"
    ;;
esac

echo
echo "== the pin notes"
# The spawn reaching `Pool` is pinned, and says so; the one reaching only
# `LentPool` is not.
pins="$(grep -c "this spawn runs in the shared heap because it captures \`pool\`" "$WORK/plain.build.log")"
lent="$(grep -c "captures \`lent\`" "$WORK/plain.build.log")"
if [ "$pins" -ge 1 ] && [ "$lent" -eq 0 ]; then
  echo "  the spawn capturing \`pool\` is noted pinned; the one capturing \`lent\` is not"
else
  echo "  pin notes: $pins for \`pool\` (want 1+), $lent for \`lent\` (want 0)"
  sed -n '1,20p' "$WORK/plain.build.log"
  status=1
fi

TABLE="$WORK/table.md"
: >"$TABLE"

# The copy's verifier runs: each exits 86 with a report, the same in every
# run once addresses and the count of checks are masked and the holder's
# own holders (`held by`, found by a search of whatever is still live)
# left out. Prints the report's first line and what it found, or nothing
# when a run missed.
verifier_caught() { # copy check
  local copy="$1" check="$2" k=1 first="" report line code
  while [ "$k" -le "$RUNS" ]; do
    verified "broken-$copy" "broken-$copy.v$k" 1 "$check"
    code="$(cat "$WORK/broken-$copy.v$k.code")"
    report="$(sed -n '/^iyi: heap_verify: partition [0-9]*, /,/^iyi: heap_verify: aborting/p' "$WORK/broken-$copy.v$k.err" |
      sed -E '/^    held by /d; /^    field \+[0-9]+$/d; s/0x[0-9a-f]{6,}/0x…/g; s/, check [0-9]+$/, check …/')"
    if [ "$code" != 86 ] || [ -z "$report" ]; then
      echo "run $k: exit $code, $( [ -n "$report" ] && echo "report" || echo "no report")" >"$WORK/broken-$copy.missed"
      return
    fi
    if [ -z "$first" ]; then
      first="$report"
    elif [ "$report" != "$first" ]; then
      echo "run $k reported another word: $(echo "$report" | sed -n '1,2p' | tr -s ' ' | tr '\n' ' ')" >"$WORK/broken-$copy.missed"
      return
    fi
    k=$((k + 1))
  done
  line="$(echo "$first" | sed -n 1p)"
  echo "$line -$(echo "$first" | sed -n 2p | tr -s ' ')"
}

prove_caught() { # label copy check
  local label="$1" copy="$2" check="$3"
  if ! build "broken-$copy" "IYI_SPAWN_BROKEN=$copy" ""; then
    echo "  $label: the build did not finish"
    sed -n '1,12p' "$WORK/broken-$copy.build.log"
    printf '| %s (`%s`) | **the build did not finish** | |\n' "$label" "$copy" >>"$TABLE"
    status=1
    return
  fi
  # The program's own check, read before any collection.
  verified "broken-$copy" "broken-$copy.own" "" "$check"
  local code own
  code="$(cat "$WORK/broken-$copy.own.code")"
  own="$(grep -m1 "^FAIL: " "$WORK/broken-$copy.own.out" | sed 's/^FAIL: //')"
  if [ "$code" -eq 0 ] || [ -z "$own" ]; then
    echo "  $label: the check '$check' did not fail (exit $code)"
    own="**missed** (exit $code)"
    status=1
  fi
  local verifier reason
  verifier="$(verifier_caught "$copy" "$check")"
  reason="$(own_only "$copy")"
  if [ -n "$reason" ]; then
    if [ -n "$verifier" ]; then
      echo "  $label: listed as own check only, but the verifier caught it: drop it from own_only"
      status=1
    fi
    verifier="own check only: $reason"
  elif [ -z "$verifier" ]; then
    echo "  $label: the verifier missed it ($(cat "$WORK/broken-$copy.missed"))"
    sed -n '1,6p' "$WORK/broken-$copy.v1.out" | sed 's/^/    /'
    verifier="**missed** ($(cat "$WORK/broken-$copy.missed"))"
    status=1
  fi
  printf '| %s (`%s`) | %s | %s |\n' "$label" "$copy" "$verifier" "$own" >>"$TABLE"
}

echo
echo "== each mechanism turned off in the compiler, caught"
prove_caught "C1 typed crossing context" c1 c1
prove_caught "class-variable store publish" classvar-publish classvar
prove_caught "trusted types born shared" new-shared born_shared
prove_caught "pin (forced off)" pin pin
prove_caught "union holes written as zero" holes holes

echo
echo "Seed $SEED (IYI_CHAOS), IYI_HEAP_STRESS=1, $RUNS verifier runs each with HEAP22_PRINT_ONLY=1."
echo
echo "| copy | caught by the verifier (exit 86) | the program's own check (FAIL, before any collection) |"
echo "|---|---|---|"
cat "$TABLE"

echo
[ "$status" -eq 0 ] && echo "heap_codegen: every mechanism holds, and every copy is caught."
exit "$status"
