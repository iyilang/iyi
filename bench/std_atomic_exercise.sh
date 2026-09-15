#!/usr/bin/env bash
# Exercises `std/atomic`: the weaker and bitwise verbs on `Atomic(T)`.
#
#     bash bench/std_atomic_exercise.sh
#
# Proves:
#   * bench/std_atomic_exercise.iyi passes plain and --release: every verb
#     on every admitted T, compare_and_set at each ordering, the bitwise
#     verbs signed and unsigned, four threads counting without loss, and a
#     release/acquire handoff.
#   * The instruction each verb emits, read off the LLVM IR: a relaxed add
#     is `atomicrmw add ... monotonic`, an acquire load is `load atomic ...
#     acquire`, a release store is `store atomic ... release`, the acq_rel
#     exchange is `cmpxchg ... acq_rel acquire`, and the four fences are
#     four `fence` instructions. No ordering is chosen at runtime.
#   * Negative proofs: copies of the module with `add_relaxed` subtracting,
#     with unsigned max made signed, and with a compare_and_set that never
#     exchanges each fail at the named check; a copy that strengthens every
#     relaxed verb to seq_cst fails the IR audit.
#
# Exits non-zero if any check fails.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src:$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2" source="$3"
  shift 3
  if ! "$IYI" build "$@" -o "$WORK/$name" "$source" >"$WORK/$name.build.log" 2>&1; then
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

echo "== the std/atomic exercise, plain build"
build_and_run "std_atomic" exercise-atomic "$REPO/bench/std_atomic_exercise.iyi"

echo
echo "== every atomic check reported"
for check in "single-thread verbs" "compare_and_set at each ordering" "bitwise verbs" "fences" "four threads counting" "nothing lost" "release publishes, acquire sees" "ALL CHECKS PASSED"; do
  if ! grep -q "$check" "$WORK/exercise-atomic.out" 2>/dev/null; then
    echo "  MISSING: $check"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  verbs, compare_and_set, bitwise, fences, four threads and the handoff all reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "std_atomic --release" exercise-atomic-release "$REPO/bench/std_atomic_exercise.iyi" --release >/dev/null
if grep -q "ALL CHECKS PASSED" "$WORK/exercise-atomic-release.out" 2>/dev/null; then
  echo "  every check holds under --release"
else
  echo "  release: missing pass sentinel"
  status=1
fi

# ---------------------------------------------------------------------------
# The instruction each verb emits
# ---------------------------------------------------------------------------

echo
echo "== the instruction each verb emits, read off the IR"
ir_audit() { # ir_audit <ir file> ; prints failures, returns 1 on any
  local ir="$1" ok=0
  local pattern
  for pattern in \
    'atomicrmw add ptr [^,]*, i64 [^ ]* monotonic' \
    'atomicrmw add ptr [^,]*, i64 [^ ]* acquire' \
    'atomicrmw add ptr [^,]*, i64 [^ ]* release' \
    'atomicrmw add ptr [^,]*, i64 [^ ]* acq_rel' \
    'atomicrmw sub ptr [^,]*, i8 [^ ]* monotonic' \
    'atomicrmw xchg ptr [^,]*, i32 [^ ]* acq_rel' \
    'load atomic i64, ptr [^ ]* monotonic' \
    'load atomic i64, ptr [^ ]* acquire' \
    'store atomic i64 [^,]*, ptr [^ ]* monotonic' \
    'store atomic i64 [^,]*, ptr [^ ]* release' \
    'cmpxchg ptr [^,]*, i64 [^,]*, i64 [^ ]* monotonic monotonic' \
    'cmpxchg ptr [^,]*, i64 [^,]*, i64 [^ ]* acquire acquire' \
    'cmpxchg ptr [^,]*, i64 [^,]*, i64 [^ ]* release monotonic' \
    'cmpxchg ptr [^,]*, i64 [^,]*, i64 [^ ]* acq_rel acquire' \
    '^  fence seq_cst' \
    '^  fence acquire' \
    '^  fence release' \
    '^  fence acq_rel'; do
    if ! grep -qE "$pattern" "$ir"; then
      echo "  not emitted: $pattern"
      ok=1
    fi
  done
  # The unsigned max/min compare unsigned; the signed ones signed.
  if ! grep -A12 'define.*Atomic(UInt64)@Atomic(T)#max<UInt64>' "$ir" | grep -qE 'icmp ugt|atomicrmw umax'; then
    echo "  UInt64#max did not emit an unsigned compare"
    ok=1
  fi
  if ! grep -A12 'define.*Atomic(Int64)@Atomic(T)#max<Int64>' "$ir" | grep -qE 'icmp sgt|atomicrmw max'; then
    echo "  Int64#max did not emit a signed compare"
    ok=1
  fi
  return $ok
}
if ! "$IYI" build --emit llvm-ir -o "$WORK/ir" "$REPO/bench/std_atomic_exercise.iyi" >"$WORK/ir.build.log" 2>&1 || [ ! -s "$WORK/ir.ll" ]; then
  echo "  could not emit IR"
  tail -5 "$WORK/ir.build.log"
  status=1
elif ir_audit "$WORK/ir.ll"; then
  echo "  relaxed/acquire/release/acq_rel adds, loads, stores and exchanges, four fences, signed and unsigned max: each is its own instruction"
else
  status=1
fi

# ---------------------------------------------------------------------------
# Negative failure proofs
# ---------------------------------------------------------------------------

echo
echo "== proving the checks can fail when the module is broken"
prove_fails() { # prove_fails <label> <dir> <phrase> <sed script>
  local label="$1" dir="$2" phrase="$3" script="$4"
  mkdir -p "$WORK/$dir/std"
  sed -e "$script" "$REPO/src/std/atomic.iyi" > "$WORK/$dir/std/atomic.iyi"
  if cmp -s "$REPO/src/std/atomic.iyi" "$WORK/$dir/std/atomic.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build -o "$WORK/$dir/program" "$REPO/bench/std_atomic_exercise.iyi" >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched module did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not at the expected check ('$phrase')"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
}

prove_fails "add_relaxed subtracts" add_subs "Int32 add_relaxed" \
  's/IyiAtomic.rmw(:add, pointerof(@value), value, {{ordering}}, false)/IyiAtomic.rmw(:sub, pointerof(@value), value, {{ordering}}, false)/'
prove_fails "unsigned max made signed" max_signed "UInt8 max is unsigned" \
  's/IyiAtomic.rmw(:umax,/IyiAtomic.rmw(:max,/'
prove_fails "compare_and_set_release never exchanges" cas_stuck "release: exchanged" \
  's/expected, desired, :release, :monotonic)/expected, expected, :release, :monotonic)/'

echo
echo "== proving the IR audit can fail: every relaxed verb strengthened to seq_cst"
mkdir -p "$WORK/strong/std"
sed -e 's/:monotonic/:sequentially_consistent/g' "$REPO/src/std/atomic.iyi" > "$WORK/strong/std/atomic.iyi"
if IYI_PATH="$WORK/strong:$REPO/src" "$IYI" build --emit llvm-ir -o "$WORK/strong/ir" "$REPO/bench/std_atomic_exercise.iyi" >"$WORK/strong/build.log" 2>&1 \
   && [ -s "$WORK/strong/ir.ll" ]; then
  if ir_audit "$WORK/strong/ir.ll" >"$WORK/strong/audit.out"; then
    echo "  the audit PASSED with every relaxed verb strengthened (it should have failed)"
    status=1
  else
    echo "  the audit caught it: $(grep -c 'not emitted' "$WORK/strong/audit.out") relaxed instructions missing"
  fi
else
  echo "  the strengthened module did not build"
  tail -5 "$WORK/strong/build.log"
  status=1
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/atomic exercise holds"
else
  echo "the std/atomic exercise did not hold"
fi
exit $status
