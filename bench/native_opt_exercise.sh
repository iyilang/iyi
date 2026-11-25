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

# Return 1 only when the entry-frame behavior differs; 2 means the proof could
# not run, so a compiler failure cannot be counted as a caught mutation.
entry_chain_check() {
  local binary="$1" input="$2" output="$3"
  "$PY" - "$(native_path "$binary")" "$(native_path "$input")" "$(native_path "$output")" <<'PY'
import re, subprocess, sys
binary, source, output = sys.argv[1:]
try:
    result = subprocess.run([binary, 'run', '--verify-each', 'release', source],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
except (OSError, subprocess.TimeoutExpired) as exc:
    print('entry-chain proof unavailable:', exc, file=sys.stderr)
    sys.exit(2)
if result.returncode != 0:
    print('entry-chain optimizer failed:', result.stderr.decode('utf-8', 'replace'), file=sys.stderr)
    sys.exit(2)
try:
    lines = result.stdout.decode('utf-8').splitlines()
    with open(output, 'wb') as f:
        f.write(result.stdout)
except (OSError, UnicodeError) as exc:
    print('entry-chain output unavailable:', exc, file=sys.stderr)
    sys.exit(2)
functions = {}
name = None
for line in lines:
    if line.startswith('define '):
        match = re.search(r'@([A-Za-z_][A-Za-z0-9_.$]*)\(', line)
        name = match.group(1) if match else None
        if name:
            functions[name] = []
    elif line == '}':
        name = None
    elif name:
        functions[name].append(line)
def need(condition, reason):
    if not condition:
        print('FAIL: ' + reason, file=sys.stderr)
        sys.exit(1)
def has_call(body, target):
    return any(re.search(r'\bcall\b.*@' + re.escape(target) + r'\(', line) for line in body)
for required in ('main', '__iyi_enter', '__iyi_program', '__iyi_main', '__crystal_main', 'empty_entry', 'f'):
    need(required in functions, 'entry function @%s is missing' % required)
for caller, callee in (('main', '__iyi_enter'), ('__iyi_enter', '__iyi_program'),
                       ('__iyi_program', '__iyi_main'), ('empty_entry', '__crystal_main')):
    need(has_call(functions[caller], callee), '@%s no longer calls @%s' % (caller, callee))
top = functions['__iyi_main']
need(has_call(top, 'f'), 'the top-level non-loop call to @f was inlined')
need(not any(has_call(functions[caller], 'f') for caller in ('main', '__iyi_enter', '__iyi_program')),
     '@f moved into the entry chain')
need(not has_call(top, 'g'), 'the top-level loop call to @g was not inlined')
need(not has_call(top, 'force'), 'the alwaysinline callee was not inlined')
need(any(re.search(r'\bxor i64\b.*\b991\b', line) for line in top),
     'the alwaysinline callee body is absent')
blocks = {}
block = None
for line in top:
    match = re.match(r'^([A-Za-z_.$][A-Za-z0-9_.$]*):', line)
    if match:
        block = match.group(1)
        blocks[block] = []
    elif block:
        blocks[block].append(line)
successors = {block: [target for line in body for target in re.findall(r'label %([A-Za-z_.$][A-Za-z0-9_.$]*)', line)]
              for block, body in blocks.items()}
def cyclic(start):
    todo = list(successors[start])
    seen = set()
    while todo:
        current = todo.pop()
        if current == start:
            return True
        if current in seen:
            continue
        seen.add(current)
        todo.extend(successors.get(current, []))
    return False
need(any(cyclic(block) and any(re.search(r'\bxor i64\b.*\b777\b', line) for line in body)
         for block, body in blocks.items()), 'the inlined @g body is not inside a loop')
PY
}

entry_mutation_check() {
  local status="$WORK/ENTRY.status" rc=0
  printf '2\n' >"$status"
  if ! build_driver "$MUTANT"; then
    echo 'entry-frame mutant did not build' >&2; cat "$WORK/build.log" >&2; return 2
  fi
  entry_chain_check "$MUTANT" "$FIXTURES/release/entry_chain.ir" "$WORK/entry-mutant.ir" || rc=$?
  if [ "$rc" -eq 1 ]; then
    printf '1\n' >"$status"; return 1
  fi
  if [ "$rc" -ne 0 ]; then
    return 2
  fi
  printf '0\n' >"$status"
  return 0
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
for name in fields mixed_union single_union memset memcpy whole; do fixture_check sroa "$name" changed; done
for name in escaping dynamic volatile volatile_memset; do fixture_check sroa "$name" keep; done
for name in leaf_two returns bottom_up top_level runtime_marking; do fixture_check inline "$name" changed; done
for name in guards tls_keep always_runtime_keep; do fixture_check inline "$name" keep; done
fixture_check deadfn roots changed
fixture_check deadfn global_keep keep
fixture_check deadfn asm_keep keep

echo '== 3. default pipeline fixtures, determinism and idempotence'
echo '== 3a. preserve entry frames across release rounds'
if entry_chain_check "$DRV" "$FIXTURES/release/entry_chain.ir" "$WORK/entry-first.ir" && \
   entry_chain_check "$DRV" "$FIXTURES/release/entry_chain.ir" "$WORK/entry-second.ir" && \
   cmp -s "$WORK/entry-first.ir" "$WORK/entry-second.ir" && \
   entry_chain_check "$DRV" "$WORK/entry-first.ir" "$WORK/entry-again.ir" && \
   cmp -s "$WORK/entry-first.ir" "$WORK/entry-again.ir"; then
  echo '  ok: entry-chain semantics, determinism and idempotence'
else
  fail 'entry-chain release semantics, determinism or idempotence failed'
fi
fixture_check default locals_loop changed
fixture_check release full changed

echo '== 4. CLI contract'
printf 'cfg-simplify\tdefault,release\nmem2reg\tdefault,release\nsimplify\tdefault,release\ndce\tdefault,release\nsroa\trelease\ninline\trelease\ndeadfn\trelease\n' >"$WORK/passes.expected"
if ! "$DRV" passes >"$WORK/passes.actual" 2>"$WORK/cli.err" || ! cmp -s "$WORK/passes.expected" "$WORK/passes.actual"; then
  fail 'passes did not list the expected names and tiers'
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

echo '== 4b. alwaysinline overrides growth limits'
if ! "$PY" - "$(native_path "$DRV")" "$(native_path "$WORK")" <<'PY'
import os, subprocess, sys
binary, work = sys.argv[1:]
header = ('; iyi-ir 1\nsource_filename = "inline-budgets"\n'
          'target triple = "aarch64-apple-darwin"\n'
          'target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"\n')
def check(name, required_work, caller_work):
    path = os.path.join(work, name + '.ir')
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(header)
        f.write('define internal i64 @required(i64 %x) [alwaysinline] {\nentry:\n')
        value = '%x'
        for i in range(required_work):
            f.write('  %%r%d = add i64 %s, 1\n' % (i, value))
            value = '%%r%d' % i
        f.write('  ret i64 %s\n}\n' % value)
        f.write('define internal i64 @ordinary(i64 %x) {\nentry:\n  ret i64 %x\n}\n')
        f.write('define external i64 @caller(i64 %x) {\nentry:\n')
        f.write('  %forced = call i64 (i64) @required(i64 %x)\n')
        f.write('  %kept = call i64 (i64) @ordinary(i64 %forced)\n')
        value = '%kept'
        for i in range(caller_work):
            f.write('  %%v%d = add i64 %s, 1\n' % (i, value))
            value = '%%v%d' % i
        f.write('  ret i64 %s\n}\n' % value)
    try:
        result = subprocess.run([binary, 'run', '--verify-each', 'inline', path],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError('%s could not run: %s' % (name, exc))
    if result.returncode != 0:
        raise RuntimeError('%s failed (%d): %s' %
                           (name, result.returncode, result.stderr.decode('utf-8', 'replace')))
    output = result.stdout.decode('utf-8')
    if 'call i64 (i64) @required(' in output or 'call i64 (i64) @ordinary(' not in output:
        raise RuntimeError('%s did not inline the required call and retain the ordinary call' % name)
    print('  ok: %s' % name)
try:
    check('caller-over-3000', 0, 3001)
    check('mandatory-growth-exhausts-module-budget', 9, 0)
except RuntimeError as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(1)
PY
then
  fail 'alwaysinline growth contract failed'
fi

echo '== 5. diamond-chain scaling'
# One local belongs to one diamond: its stores and load do not span other
# diamonds. A verified smaller copy checks the generator outside the timing.
# Each size is run three times and the least figure is kept: the child's CPU
# time where the host reports it, so other jobs on the machine do not stretch
# it, and elapsed time elsewhere.
if ! "$PY" - "$(native_path "$DRV")" "$(native_path "$WORK")" "${NATIVE_OPT_SCALE_K:-2048}" "${NATIVE_OPT_RELEASE_SCALE_K:-4096}" <<'PY'
import os, subprocess, sys, time
try:
    import resource
except ImportError:
    resource = None
binary, work, text_k, text_release_k = sys.argv[1:]
try:
    k = int(text_k)
except ValueError:
    sys.exit('NATIVE_OPT_SCALE_K must be an integer')
if k < 64:
    sys.exit('NATIVE_OPT_SCALE_K must be at least 64')
try:
    release_k = int(text_release_k)
except ValueError:
    sys.exit('NATIVE_OPT_RELEASE_SCALE_K must be an integer')
if release_k < 64:
    sys.exit('NATIVE_OPT_RELEASE_SCALE_K must be at least 64')

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

def generate_release(n, path):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('; iyi-ir 1\nsource_filename = "call-chain"\n')
        f.write('target triple = "aarch64-apple-darwin"\n')
        f.write('target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"\n')
        for i in range(n):
            linkage = 'external' if i == 0 else 'internal'
            f.write('define %s i64 @f%d(i64 %%x) {\nentry:\n' % (linkage, i))
            if i + 1 < n:
                f.write('  %%v = call i64 (i64) @f%d(i64 %%x)\n' % (i + 1))
                f.write('  %next = add i64 %v, 1\n  ret i64 %next\n}\n')
            else:
                f.write('  ret i64 %x\n}\n')

def child_cpu():
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    return usage.ru_utime + usage.ru_stime

def run(n, verified, repeats=1, tier='default'):
    if tier == 'release':
        path = os.path.join(work, 'call-chain-%d.ir' % n)
        generate_release(n, path)
    else:
        path = os.path.join(work, 'scale-%d.ir' % n)
        generate(n, path)
    cmd = [binary, 'run', '--verify-each' if verified else '--no-verify', tier, path]
    least = None
    for _ in range(repeats):
        before = child_cpu() if resource else 0.0
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
        spent = child_cpu() - before if resource else elapsed
        if least is None or spent < least:
            least = spent
    return least
failed = False
try:
    run(max(8, k // 8), True)
    small = run(k, False, 3)
    large = run(2 * k, False, 3)
    ratio = large / small if small > 0 else float('inf')
    print('  K=%d %.3fs, 2K=%d %.3fs, ratio %.3f (%s, least of 3)' %
          (k, small, 2 * k, large, ratio, 'cpu' if resource else 'elapsed'))
    if large < 0.5:
        raise RuntimeError('2K run is under 0.5s; increase NATIVE_OPT_SCALE_K')
    if ratio > 3.0:
        raise RuntimeError('2K/K exceeds 3.0')
except RuntimeError as exc:
    print(str(exc), file=sys.stderr)
    failed = True
print('== 6. release call-chain scaling')
try:
    run(max(8, release_k // 8), True, tier='release')
    small = run(release_k, False, 3, 'release')
    large = run(2 * release_k, False, 3, 'release')
    ratio = large / small if small > 0 else float('inf')
    print('  release K=%d %.3fs, 2K=%d %.3fs, ratio %.3f (%s, least of 3)' %
          (release_k, small, 2 * release_k, large, ratio, 'cpu' if resource else 'elapsed'))
    if large < 0.5:
        raise RuntimeError('release 2K run is under 0.5s; increase NATIVE_OPT_RELEASE_SCALE_K')
    if ratio > 3.0:
        raise RuntimeError('release 2K/K exceeds 3.0')
except RuntimeError as exc:
    print(str(exc), file=sys.stderr)
    failed = True
sys.exit(1 if failed else 0)
PY
then
  fail 'optimizer scale contract failed'
fi


echo '== 7. mutation proofs, each rebuilding iyi-opt'
prove_mutation 'ENTRY: preserve entry-frame identities' src/compiler/ir/opt/inline.iyi \
  '  return false if top_level?(fn) || fn.name == "__iyi_program" || fn.name == "__iyi_enter" # mutation entry-frame: preserve entry identities' \
  '  return false if false # mutation entry-frame: preserve entry identities' \
  -- entry_mutation_check || fail 'ENTRY was not caught'
mutation_result ENTRY
prove_mutation 'M1: iterated phi frontier' src/compiler/ir/opt/mem2reg.iyi \
  '          work << y # iterate: phi blocks define the slot too' \
  '          work << y if false # iterate: phi blocks define the slot too' \
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
prove_mutation 'M6: argument mapping' src/compiler/ir/opt/inline.iyi \
  '    values[callee.params[k]] = call.args[k + 1] # mutation S6-arg: actual argument to parameter' \
  '    values[callee.params[k]] = call.args[callee.params.size - k] # mutation S6-arg: actual argument to parameter' \
  -- mutation_check M6 inline leaf_two || fail 'M6 was not caught'
mutation_result M6
prove_mutation 'M7: every return reaches the phi' src/compiler/ir/opt/inline.iyi \
  '      result.add_incoming(mapped_value(term.args[0], values), dest) # mutation S6-return: every return edge' \
  '      result.add_incoming(mapped_value(term.args[0], values), dest) if result.args.empty? # mutation S6-return: every return edge' \
  -- mutation_check M7 inline returns || fail 'M7 was not caught'
mutation_result M7
prove_mutation 'M8: actual field offset' src/compiler/ir/opt/sroa.iyi \
  '      offset = offset + mod.layout.offset_of(type, index) # mutation S6-offset: select the actual field' \
  '      offset = offset + mod.layout.offset_of(type, 0) # mutation S6-offset: select the actual field' \
  -- mutation_check M8 sroa fields || fail 'M8 was not caught'
mutation_result M8
prove_mutation 'M9: address-taken roots' src/compiler/ir/opt/deadfn.iyi \
  '            note_address(value, live, work, seen) # mutation S6-address: keep address-taken functions' \
  '            nil # mutation S6-address: keep address-taken functions' \
  -- mutation_check M9 deadfn roots || fail 'M9 was not caught'
mutation_result M9
prove_mutation 'M10: callees before callers' src/compiler/ir/opt/callgraph.iyi \
  '          pending[own] = pending[own] + 1 # mutation S6-order: caller waits for callee' \
  '          pending[own] = pending[own] + 0 # mutation S6-order: caller waits for callee' \
  -- mutation_check M10 inline bottom_up || fail 'M10 was not caught'
mutation_result M10

echo '== 8. verdict'
if [ "$failed" -eq 0 ]; then
  echo 'ALL NATIVE OPT CHECKS PASSED!'
  exit 0
fi
echo 'SOME NATIVE OPT CHECKS FAILED'
exit 1
