#!/usr/bin/env bash
# LLVM-free IR optimizer fixtures, scaling, and mutation proofs.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd -P)
. "$REPO/bench/lib/host.sh" || exit 1
. "$REPO/bench/lib/mutation.sh" || exit 1
require_test_host || exit 1
[ -n "$PY" ] || { echo 'FAIL: a working Python interpreter is required' >&2; exit 1; }
export IYI_PATH="$(native_path "$REPO/src")"
unset IYI_VERIFY_PASSES IYI_TIME_PASSES

WORK=$(mktemp -d "${TMPDIR:-/tmp}/native-opt.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
failed=0
fail() { echo "FAIL: $*" >&2; failed=1; }
DRV="$WORK/iyi-opt$EXE"
MUTANT="$WORK/mutant$EXE"
FIXTURES="$REPO/bench/fixtures/opt"

build_driver() {
  ./bin/iyi build -o "$(native_path "$1")" src/compiler/tools/ir_opt.iyi >"$WORK/build.log" 2>&1
}

# A missing .out.ir means the canonical input is expected unchanged.
fixture_check() {
  local pass="$1" name="$2" changed="$3" file expected
  file="$FIXTURES/$pass/$name.ir"
  expected="$FIXTURES/$pass/$name.out.ir"
  if [ ! -f "$file" ]; then fail "missing fixture $pass/$name.ir"; return; fi
  if [ "$changed" = changed ] && [ ! -f "$expected" ]; then
    fail "missing changed-output golden $pass/$name.out.ir"; return
  fi
  if [ "$changed" = keep ] && [ -f "$expected" ]; then
    fail "keep fixture unexpectedly has an output golden: $pass/$name"; return
  fi
  [ -f "$expected" ] || expected="$file"
  if ! "$DRV" print "$(native_path "$expected")" >"$WORK/expected.ir" 2>"$WORK/expected.err"; then
    fail "cannot parse golden $pass/$name"; cat "$WORK/expected.err" >&2; return
  fi
  if ! "$DRV" run --verify-each "$pass" "$(native_path "$file")" >"$WORK/actual.ir" 2>"$WORK/actual.err"; then
    fail "$pass/$name failed to run or verify"; cat "$WORK/actual.err" >&2; return
  fi
  if ! cmp -s "$WORK/expected.ir" "$WORK/actual.ir"; then
    fail "$pass/$name differs from its golden"
    diff -u "$WORK/expected.ir" "$WORK/actual.ir" >&2 || true
    return
  fi
  if ! "$DRV" run --verify-each "$pass" "$(native_path "$file")" >"$WORK/second.ir" 2>"$WORK/second.err"; then
    fail "$pass/$name determinism run failed"; cat "$WORK/second.err" >&2; return
  fi
  if ! cmp -s "$WORK/actual.ir" "$WORK/second.ir"; then
    fail "$pass/$name is nondeterministic"; return
  fi
  if ! "$DRV" run --verify-each "$pass" "$(native_path "$WORK/actual.ir")" >"$WORK/again.ir" 2>"$WORK/again.err"; then
    fail "$pass/$name idempotence run failed"; cat "$WORK/again.err" >&2; return
  fi
  if ! cmp -s "$WORK/actual.ir" "$WORK/again.ir"; then
    fail "$pass/$name is not idempotent"
    diff -u "$WORK/actual.ir" "$WORK/again.ir" >&2 || true
    return
  fi
  echo "  ok: $pass/$name"
}

# The status is written before doing work, and changed only once the mutant's
# behavior is observed. Older mutation.sh counts every nonzero as caught, so
# the caller separately requires status 1, never a build/runtime failure (2).
mutation_check() {
  local label="$1" pass="$2" name="$3" status="$WORK/$1.status" rc=0 expected
  printf '2\n' >"$status"
  if ! build_driver "$MUTANT"; then
    echo "mutant $label did not build" >&2; cat "$WORK/build.log" >&2; return 2
  fi
  expected="$FIXTURES/$pass/$name.out.ir"
  [ -f "$expected" ] || expected="$FIXTURES/$pass/$name.ir"
  if ! "$DRV" print "$(native_path "$expected")" >"$WORK/mut-expected.ir" 2>"$WORK/mut-expected.err"; then
    echo "cannot print golden for $label" >&2; return 2
  fi
  "$PY" - "$(native_path "$MUTANT")" "$pass" "$(native_path "$FIXTURES/$pass/$name.ir")" \
    "$(native_path "$WORK/mut-actual.ir")" "$(native_path "$WORK/mut-actual.err")" <<'PY' || rc=$?
import subprocess, sys
binary, name, source, output, error = sys.argv[1:]
try:
    with open(output, 'wb') as out, open(error, 'wb') as err:
        result = subprocess.run([binary, 'run', '--no-verify', name, source],
                                stdout=out, stderr=err, timeout=60)
except (OSError, subprocess.TimeoutExpired) as exc:
    print('mutant execution unavailable:', exc, file=sys.stderr)
    sys.exit(2)
sys.exit(result.returncode if result.returncode in (0, 1, 2) else 2)
PY
  if [ "$rc" -ne 0 ]; then
    if [ "$label" = M3 ] && grep -Fq 'BUG: erase of a used value' "$WORK/mut-actual.err"; then
      printf '1\n' >"$status"; return 1
    fi
    echo "mutant $label could not be run (status $rc)" >&2
    cat "$WORK/mut-actual.err" >&2
    return 2
  fi
  if cmp -s "$WORK/mut-expected.ir" "$WORK/mut-actual.ir"; then
    printf '0\n' >"$status"
    return 0
  fi
  printf '1\n' >"$status"
  return 1
}

mutation_result() {
  local label="$1" result
  result=$(cat "$WORK/$label.status" 2>/dev/null || printf '2')
  if [ "$result" != 1 ]; then
    fail "$label did not produce a detected behavioral difference (check status $result)"
  fi
}

expect_status() {
  local expected="$1" label="$2" rc=0
  shift 2
  "$@" >"$WORK/cli.out" 2>"$WORK/cli.err" || rc=$?
  if [ "$rc" -ne "$expected" ]; then
    fail "$label: expected status $expected, got $rc"; cat "$WORK/cli.err" >&2; return 1
  fi
  if [ "$expected" -ne 0 ] && ! grep -q '^iyi-opt: ' "$WORK/cli.err"; then
    fail "$label: diagnostic lacks the iyi-opt prefix"; return 1
  fi
  return 0
}

echo '== 1. build iyi-opt'
if ! build_driver "$DRV"; then
  cat "$WORK/build.log" >&2
  fail 'iyi-opt did not build'
  echo '== SOME NATIVE OPT CHECKS FAILED'
  exit 1
fi

echo '== 2. individual pass fixtures, determinism and idempotence'
for name in unreachable_block merge_chain forward_empty condbr_same_targets; do fixture_check cfg-simplify "$name" changed; done
fixture_check cfg-simplify forward_blocked_by_phi_conflict keep
for name in straight_line diamond loop nested_loops uninitialized_read pointer_slot i1_slot null_uninitialized unreachable_predecessor; do fixture_check mem2reg "$name" changed; done
for name in escaping_slot volatile_slot aggregate_slot atomic_slot tls_slot stored_address unreachable_slot_use; do fixture_check mem2reg "$name" keep; done
for name in fold_int fold_icmp_signed identities trivial_phi condbr_const overflow_flag_unused fold_double power_of_two switch_const expect_const fold_cast fold_divrem fold_double_ops trivial_self_phi; do fixture_check simplify "$name" changed; done
for name in float32_keep div_by_zero_keep fold_safety_keep ptrtoint_mul_keep; do fixture_check simplify "$name" keep; done
for name in dead_arith dead_phi_cycle dead_plain_load; do fixture_check dce "$name" changed; done
for name in keep_store keep_call keep_volatile_load keep_marking_load_used keep_call_unreachable keep_atomic; do fixture_check dce "$name" keep; done

echo '== 3. default pipeline fixtures, determinism and idempotence'
fixture_check default locals_loop changed

echo '== 4. CLI contract'
printf 'cfg-simplify\tdefault,release\nmem2reg\tdefault,release\nsimplify\tdefault,release\ndce\tdefault,release\n' >"$WORK/passes.expected"
if ! "$DRV" passes >"$WORK/passes.actual" 2>"$WORK/cli.err" || ! cmp -s "$WORK/passes.expected" "$WORK/passes.actual"; then
  fail 'passes did not list exactly the four named passes and tiers'
fi
expect_status 2 'missing arguments' "$DRV" run || true
expect_status 2 'extra arguments' "$DRV" passes extra || true
expect_status 2 'unknown pass' "$DRV" run nosuch "$(native_path "$FIXTURES/dce/keep_store.ir")" || true
expect_status 2 'empty pass name' "$DRV" run 'dce,,simplify' "$(native_path "$FIXTURES/dce/keep_store.ir")" || true
expect_status 2 'unreadable input' "$DRV" print "$(native_path "$WORK/no-such-file.ir")" || true
expect_status 2 'directory input' "$DRV" print "$(native_path "$WORK")" || true
printf 'not ir\n' >"$WORK/invalid.ir"
expect_status 2 'invalid IR text' "$DRV" run dce "$(native_path "$WORK/invalid.ir")" || true
BAD="$(native_path "$REPO/bench/fixtures/ir/bad/types.ir")"
expect_status 2 'input verification' "$DRV" run dce "$BAD" || true
expect_status 2 'mutually exclusive verification flags' "$DRV" run --verify-each --no-verify dce "$BAD" || true
expect_status 0 'no-verify skips input verification' "$DRV" run --no-verify dce "$BAD" || true
expect_status 0 'stats skips input verification' "$DRV" stats dce "$BAD" || true
expect_status 0 'print parses without verification' "$DRV" print "$BAD" || true
cat >"$WORK/invalid-after-change.ir" <<'IR'
; iyi-ir 1
source_filename = "invalid-after-change"
target triple = "aarch64-apple-darwin"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
define internal i32 @bad() {
entry:
  %dead = add i32 1, 2
  ret i64 0
}
IR
BAD_CHANGED="$(native_path "$WORK/invalid-after-change.ir")"
expect_status 2 'changed invalid input verifies normally' "$DRV" run dce "$BAD_CHANGED" || true
expect_status 0 'no-verify overrides verifier environment' env IYI_VERIFY_PASSES=1 "$DRV" run --no-verify dce "$BAD_CHANGED" || true
expect_status 0 'stats overrides verifier environment' env IYI_VERIFY_PASSES=1 "$DRV" stats dce "$BAD_CHANGED" || true
if ! "$DRV" run simplify "$(native_path "$FIXTURES/simplify/fold_int.ir")" >"$WORK/once.ir" 2>"$WORK/cli.err" || \
   ! "$DRV" run simplify,simplify "$(native_path "$FIXTURES/simplify/fold_int.ir")" >"$WORK/repeated.ir" 2>"$WORK/cli.err" || \
   ! cmp -s "$WORK/once.ir" "$WORK/repeated.ir"; then
  fail 'repeated pass names did not run correctly'
fi
printf 'straight_line\t5\t2\t1\t1\n' >"$WORK/stats.expected"
if ! "$DRV" stats mem2reg "$(native_path "$FIXTURES/mem2reg/straight_line.ir")" >"$WORK/stats.actual" 2>"$WORK/cli.err" || \
   ! cmp -s "$WORK/stats.expected" "$WORK/stats.actual"; then
  fail 'stats did not report instruction and block counts'; cat "$WORK/cli.err" >&2
fi
if ! IYI_TIME_PASSES=1 "$DRV" run mem2reg "$(native_path "$FIXTURES/mem2reg/straight_line.ir")" >"$WORK/timed.ir" 2>"$WORK/timed.err" || \
   ! grep -q "$(printf '^opt-time\tmem2reg\t')" "$WORK/timed.err"; then
  fail 'IYI_TIME_PASSES did not report the pass timing'
fi
if ! IYI_TIME_PASSES=1 "$DRV" run --no-verify mem2reg "$(native_path "$FIXTURES/mem2reg/straight_line.ir")" >"$WORK/timed.ir" 2>"$WORK/timed.err" || \
   ! grep -q "$(printf '^opt-time\tmem2reg\t')" "$WORK/timed.err"; then
  fail 'no-verify did not retain IYI_TIME_PASSES'
fi

echo '== 5. diamond-chain scaling'
# One local belongs to one diamond: its stores and load do not span other
# diamonds. A verified smaller copy checks the generator outside the timing.
if ! "$PY" - "$(native_path "$DRV")" "$(native_path "$WORK")" "${NATIVE_OPT_SCALE_K:-2048}" <<'PY'
import os, subprocess, sys, time
binary, work, text_k = sys.argv[1:]
try:
    k = int(text_k)
except ValueError:
    sys.exit('NATIVE_OPT_SCALE_K must be an integer')
if k < 64:
    sys.exit('NATIVE_OPT_SCALE_K must be at least 64')

def generate(n, path):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('; iyi-ir 1\nsource_filename = "scale"\n')
        f.write('target triple = "aarch64-apple-darwin"\n')
        f.write('target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"\n')
        f.write('define internal i64 @scale(i1 %c, i64 %start) {\nentry:\n')
        for i in range(n):
            f.write('  %%slot%d = alloca i64, align 8\n' % i)
        f.write('  br label %head0\n')
        for i in range(n):
            f.write('head%d:\n  br i1 %%c, label %%left%d, label %%right%d\n' % (i, i, i))
            f.write('left%d:\n  store i64 %d, ptr %%slot%d, align 8\n  br label %%join%d\n' % (i, i, i, i))
            f.write('right%d:\n  store i64 %d, ptr %%slot%d, align 8\n  br label %%join%d\n' % (i, i + 1, i, i))
            f.write('join%d:\n  %%value%d = load i64, ptr %%slot%d, align 8\n' % (i, i, i))
            previous = '%start' if i == 0 else '%%sum%d' % (i - 1)
            f.write('  %%sum%d = add i64 %s, %%value%d\n' % (i, previous, i))
            if i + 1 < n:
                f.write('  br label %%head%d\n' % (i + 1))
            else:
                f.write('  ret i64 %%sum%d\n' % i)
        f.write('}\n')

def run(n, verified):
    path = os.path.join(work, 'scale-%d.ir' % n)
    generate(n, path)
    cmd = [binary, 'run', '--verify-each' if verified else '--no-verify', 'default', path]
    start = time.monotonic()
    try:
        completed = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                   timeout=180)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError('scale run could not complete: %s' % exc)
    elapsed = time.monotonic() - start
    if completed.returncode != 0:
        raise RuntimeError('scale run failed (%d): %s' %
                           (completed.returncode, completed.stderr.decode('utf-8', 'replace')))
    return elapsed
try:
    run(max(8, k // 8), True)
    small = run(k, False)
    large = run(2 * k, False)
    ratio = large / small if small > 0 else float('inf')
    print('  K=%d %.3fs, 2K=%d %.3fs, ratio %.3f' % (k, small, 2 * k, large, ratio))
    if large < 0.5:
        raise RuntimeError('2K run is under 0.5s; increase NATIVE_OPT_SCALE_K')
    if ratio > 3.0:
        raise RuntimeError('2K/K exceeds 3.0')
except RuntimeError as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(1)
PY
then
  fail 'optimizer scale contract failed'
fi

echo '== 6. mutation proofs, each rebuilding iyi-opt'
prove_mutation 'M1: iterated phi frontier' src/compiler/ir/opt/mem2reg.iyi \
  '        work << y # iterate: phi blocks define the slot too' \
  '        work << y if false # iterate: phi blocks define the slot too' \
  -- mutation_check M1 mem2reg nested_loops || fail 'M1 was not caught'
mutation_result M1
prove_mutation 'M2: stores have side effects' src/compiler/ir/opt/effects.iyi \
  '  return true if i.op == Op::Store # mutation M2: stores have side effects' \
  '  return false if i.op == Op::Store # mutation M2: stores have side effects' \
  -- mutation_check M2 dce keep_store || fail 'M2 was not caught'
mutation_result M2
prove_mutation 'M3: replace phi uses' src/compiler/ir/opt/edit.iyi \
  '      set_operand(use.user, use.index, value) # mutation M3: phi uses too' \
  '      set_operand(use.user, use.index, value) unless use.user.op == Op::Phi # mutation M3: phi uses too' \
  -- mutation_check M3 mem2reg loop || fail 'M3 was not caught'
mutation_result M3
prove_mutation 'M4: intersect advances first finger' src/compiler/ir/opt/analysis.iyi \
  '        a = @idom[a] # mutation M4: advance the first finger' \
  '        a = @idom[b] # mutation M4: advance the first finger' \
  -- mutation_check M4 mem2reg diamond || fail 'M4 was not caught'
mutation_result M4
prove_mutation 'M5: signed integer comparison' src/compiler/ir/opt/fold.iyi \
  '    return lhs_value < rhs_value # mutation M5: signed comparison' \
  '    return lhs_value.unsafe_to_u64 < rhs_value.unsafe_to_u64 # mutation M5: signed comparison' \
  -- mutation_check M5 simplify fold_icmp_signed || fail 'M5 was not caught'
mutation_result M5

echo '== 7. verdict'
if [ "$failed" -eq 0 ]; then
  echo 'ALL NATIVE OPT CHECKS PASSED!'
  exit 0
fi
echo 'SOME NATIVE OPT CHECKS FAILED'
exit 1
