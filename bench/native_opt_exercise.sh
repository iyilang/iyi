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
  local pass="$1" name="$2" changed="$3" folder="${4:-$1}" file expected
  file="$FIXTURES/$folder/$name.ir"
  expected="$FIXTURES/$folder/$name.out.ir"
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

# Record each new fixture both after its individual pass and after the full
# release tier. The stats command reports instructions and blocks before/after.
fixture_stats() {
  local pass="$1" file="$2"
  echo "  stats $pass/$(basename "$file") pass"
  "$DRV" stats "$pass" "$(native_path "$file")" || fail "stats failed for $pass/$file"
  echo "  stats $pass/$(basename "$file") release"
  "$DRV" stats release "$(native_path "$file")" || fail "release stats failed for $pass/$file"
}

# The status is written before doing work, and changed only once the mutant's
# behavior is observed. Older mutation.sh counts every nonzero as caught, so
# the caller separately requires status 1, never a build/runtime failure (2).
mutation_check() {
  local label="$1" pass="$2" name="$3" folder="${4:-$2}" option="${5:-}" status="$WORK/$1.status" rc=0 expected
  printf '2\n' >"$status"
  if ! build_driver "$MUTANT"; then
    echo "mutant $label did not build" >&2; cat "$WORK/build.log" >&2; return 2
  fi
  expected="$FIXTURES/$folder/$name.out.ir"
  [ -f "$expected" ] || expected="$FIXTURES/$folder/$name.ir"
  if ! "$DRV" print "$(native_path "$expected")" >"$WORK/mut-expected.ir" 2>"$WORK/mut-expected.err"; then
    echo "cannot print golden for $label" >&2; return 2
  fi
  "$PY" - "$(native_path "$MUTANT")" "$pass" "$(native_path "$FIXTURES/$folder/$name.ir")" \
    "$(native_path "$WORK/mut-actual.ir")" "$(native_path "$WORK/mut-actual.err")" "$option" <<'PY' || rc=$?
import subprocess, sys
binary, name, source, output, error, option = sys.argv[1:]
try:
    with open(output, 'wb') as out, open(error, 'wb') as err:
        result = subprocess.run([binary, 'run', '--no-verify'] + ([option] if option else []) + [name, source],
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

# These fixtures are generated under WORK so the guard exercises large or
# specially ordered control flow without adding generated files to the tree.
generated_mutation_check() {
  local FIXTURES="$WORK/s6p-fixtures"
  mutation_check "$@"
}

# A build or execution failure is not a caught graph-complexity mutation.
call_graph_mutation_check() {
  local label="$1" status="$WORK/$1.status" rc=0
  printf '2\n' >"$status"
  if ! build_driver "$MUTANT"; then
    echo "mutant $label did not build" >&2; cat "$WORK/build.log" >&2; return 2
  fi
  "$PY" - "$(native_path "$MUTANT")" "$(native_path "$WORK/call-edges-mut-small.ir")" \
    "$(native_path "$WORK/call-edges-mut-large.ir")" "$(native_path "$WORK/$label.ratio")" <<'PY' || rc=$?
import subprocess, sys
binary, small_path, large_path, result_path = sys.argv[1:]
counts = []
for path in (small_path, large_path):
    try:
        result = subprocess.run([binary, 'call-edges', path], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=180)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.decode('utf-8', 'replace'))
        count = int(result.stdout.strip())
        if count <= 0:
            raise ValueError('edge count must be positive')
        counts.append(count)
    except (OSError, subprocess.TimeoutExpired, ValueError, RuntimeError) as exc:
        print('graph mutation could not be measured:', exc, file=sys.stderr)
        sys.exit(2)
ratio = counts[1] / counts[0]
with open(result_path, 'w', encoding='utf-8') as result:
    result.write('  %s: %d -> %d edges, ratio %.3f (bound 3.0)\n' %
                 (result_path.rsplit('/', 1)[-1].split('.')[0], counts[0], counts[1], ratio))
sys.exit(1 if ratio > 3.0 else 0)
PY
  if [ "$rc" -eq 1 ]; then
    printf '1\n' >"$status"; return 1
  fi
  if [ "$rc" -ne 0 ]; then
    return 2
  fi
  printf '0\n' >"$status"
  return 0
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
for name in fold_int fold_icmp_signed identities trivial_phi condbr_const overflow_flag_unused fold_double power_of_two switch_const expect_const fold_cast fold_divrem fold_double_ops trivial_self_phi constant_global; do fixture_check simplify "$name" changed; done
for name in float32_keep div_by_zero_keep fold_safety_keep ptrtoint_mul_keep constant_global_keep; do fixture_check simplify "$name" keep; done
for name in dead_arith dead_phi_cycle dead_plain_load; do fixture_check dce "$name" changed; done
for name in keep_store keep_call keep_volatile_load keep_marking_load_used keep_call_unreachable keep_atomic; do fixture_check dce "$name" keep; done
for name in fields mixed_union single_union memset memcpy whole; do fixture_check sroa "$name" changed; done
for name in escaping dynamic volatile volatile_memset; do fixture_check sroa "$name" keep; done
for name in leaf_two returns bottom_up top_level runtime_marking; do fixture_check inline "$name" changed; done
for name in guards tls_keep always_runtime_keep; do fixture_check inline "$name" keep; done
fixture_check deadfn roots changed
fixture_check deadfn global_keep keep
fixture_check deadfn asm_keep keep
fixture_check deadfn asm_names changed

echo '== 2e. inliner chain decisions and callee cache invalidation'
if ! "$PY" - "$(native_path "$DRV")" "$(native_path "$WORK")" <<'PY'
import os, subprocess, sys
binary, work = sys.argv[1:]
root = os.path.join(work, 's6p-fixtures')
os.makedirs(os.path.join(root, 'inline'), exist_ok=True)
os.makedirs(os.path.join(root, 'release'), exist_ok=True)
layout = ('target triple = "aarch64-apple-darwin"\n'
          'target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"\n')

def execute(command, path):
    try:
        result = subprocess.run([binary] + command + [path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError('%s could not run: %s' % (path, exc))
    if result.returncode != 0:
        raise RuntimeError('%s failed (%d): %s' % (path, result.returncode, result.stderr.decode('utf-8', 'replace')))
    return result.stdout

def dispatch(name, count, cycle, expected_calls):
    path = os.path.join(root, 'inline', name + '.ir')
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('; iyi-ir 1\nsource_filename = "dispatch"\n' + layout)
        f.write('declare external void @sink()\ndefine internal void @leaf() {\nentry:\n  call void () @sink()\n  ret void\n}\n')
        f.write('define external void @caller(i1 %c) {\nentry:\n  br label %c0\n')
        for i in range(count):
            target = ('c%d' % (i + 1)) if i + 1 < count else ('c0' if cycle else 'end')
            f.write('c%d:\n  br i1 %%c, label %%arm%d, label %%%s\n' % (i, i, target))
        for i in range(count):
            f.write('arm%d:\n  call void () @leaf()\n  br label %%join\n' % i)
        f.write('end:\n  unreachable\njoin:\n  ret void\n}\n')
        f.write('define external i64 @padding(i64 %x) {\nentry:\n')
        for i in range(100):
            f.write('  %%p%d = add i64 %%x, %d\n' % (i, i))
        f.write('  ret i64 %x\n}\n')
    output = execute(['run', '--verify-each', 'inline'], path)
    found = output.count(b'call void () @leaf()')
    if found != expected_calls:
        raise RuntimeError('%s retained %d leaf calls, expected %d' % (name, found, expected_calls))
    print('  ok: %s' % name)

def cache_cleanup():
    path = os.path.join(root, 'release', 'cache_cleanup.ir')
    expected = os.path.join(root, 'release', 'cache_cleanup.out.ir')
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('''; iyi-ir 1
source_filename = "cache-cleanup"
'''+layout+'''declare external void @sink()
define external i64 @early(i1 %c, i64 %x) {
entry:
  %chosen = select i1 %c, ptr @callee, ptr @callee
  %r = call i64 (i64) %chosen(i64 %x)
  ret i64 %r
}
define internal i64 @callee(i64 %x) {
entry:
  br i1 true, label %good, label %cold
good:
  ret i64 %x
cold:
  call void () @sink()
  call void () @sink()
  call void () @sink()
  call void () @sink()
  call void () @sink()
  ret i64 %x
}
define external i64 @late(i64 %x) {
entry:
  %a = call i64 (i64) @callee(i64 %x)
  %b = call i64 (i64) @callee(i64 %a)
  ret i64 %b
}
define external i64 @padding(i64 %x) {
entry:
''')
        for i in range(100):
            f.write('  %%p%d = add i64 %%x, %d\n' % (i, i))
        f.write('  ret i64 %x\n}\n')
    with open(expected, 'w', encoding='utf-8', newline='\n') as f:
        f.write('''; iyi-ir 1
source_filename = "cache-cleanup"
'''+layout+'''declare external void @sink()
define external i64 @early(i1 %c, i64 %x) {
entry:
  %r = call i64 (i64) @callee(i64 %x)
  ret i64 %r
}
define internal i64 @callee(i64 %x) {
entry:
  ret i64 %x
}
define external i64 @late(i64 %x) {
entry:
  ret i64 %x
}
define external i64 @padding(i64 %x) {
entry:
  ret i64 %x
}
''')
    actual = execute(['run', '--verify-each', 'release'], path)
    golden = execute(['print'], expected)
    if actual != golden:
        raise RuntimeError('callee cost was not invalidated after its cleanup')
    print('  ok: cache_cleanup')

try:
    dispatch('dispatch4', 4, False, 0)
    dispatch('dispatch5', 5, False, 5)
    dispatch('dispatch_cycle', 5, True, 0)
    cache_cleanup()
except RuntimeError as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(1)
PY
then
  fail 'inliner chain or cache regression check failed'
fi

echo '== 2a. common subexpression elimination'
for file in "$FIXTURES/cse/"*.ir; do
  case "$file" in *.out.ir) continue ;; esac
  name=$(basename "$file" .ir)
  if [ -f "$FIXTURES/cse/$name.out.ir" ]; then fixture_check cse "$name" changed; else fixture_check cse "$name" keep; fi
  fixture_stats cse "$file"
done

echo '== 2b. range proof'
for file in "$FIXTURES/prove/"*.ir; do
  case "$file" in *.out.ir) continue ;; esac
  name=$(basename "$file" .ir)
  if [ -f "$FIXTURES/prove/$name.out.ir" ]; then fixture_check prove "$name" changed; else fixture_check prove "$name" keep; fi
  fixture_stats prove "$file"
done

echo '== 2c. loop-invariant code motion'
for file in "$FIXTURES/licm/"*.ir; do
  case "$file" in *.out.ir) continue ;; esac
  name=$(basename "$file" .ir)
  if [ -f "$FIXTURES/licm/$name.out.ir" ]; then fixture_check licm "$name" changed; else fixture_check licm "$name" keep; fi
  fixture_stats licm "$file"
done

echo '== 2d. block layout'
for file in "$FIXTURES/layout/"*.ir; do
  case "$file" in *.out.ir) continue ;; esac
  name=$(basename "$file" .ir)
  if [ -f "$FIXTURES/layout/$name.out.ir" ]; then fixture_check layout "$name" changed; else fixture_check layout "$name" keep; fi
  fixture_stats layout "$file"
done
fixture_stats simplify "$FIXTURES/simplify/constant_global.ir"
fixture_stats simplify "$FIXTURES/simplify/constant_global_keep.ir"


echo '== 2g. allocation escape'
for file in "$FIXTURES/escape/"*.ir; do
  case "$file" in *.out.ir) continue ;; esac
  name=$(basename "$file" .ir)
  if [ -f "$FIXTURES/escape/$name.out.ir" ]; then fixture_check escape "$name" changed; else fixture_check escape "$name" keep; fi
  fixture_stats escape "$file"
done

echo '== 2h. write barriers'
for file in "$FIXTURES/barrier/"*.ir; do
  case "$file" in *.out.ir|*/stack_mode_heap_keep.ir) continue ;; esac
  name=$(basename "$file" .ir)
  if [ -f "$FIXTURES/barrier/$name.out.ir" ]; then fixture_check barrier "$name" changed; else fixture_check barrier "$name" keep; fi
  fixture_stats barrier "$file"
done
fixture_check barrier-stack stack_mode_heap_keep keep barrier
for pass in escape barrier barrier-stack; do
  fixture_check "$pass" partition_asm_keep keep release
done

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
fixture_check release scalar_slot changed
fixture_check release frame_cap changed
fixture_check release returns_twice changed
fixture_check release nested_objects changed
if ! "$DRV" print "$(native_path "$FIXTURES/licm/invariant_arith.out.ir")" >"$WORK/licm-release-expected.ir" 2>"$WORK/licm-release.err" || \
   ! "$DRV" run --verify-each release "$(native_path "$FIXTURES/licm/invariant_arith.ir")" >"$WORK/licm-release-actual.ir" 2>"$WORK/licm-release.err" || \
   ! cmp -s "$WORK/licm-release-expected.ir" "$WORK/licm-release-actual.ir"; then
  fail 'release tier did not hoist live invariant arithmetic'
  diff -u "$WORK/licm-release-expected.ir" "$WORK/licm-release-actual.ir" >&2 || true
else
  echo '  ok: release/live invariant arithmetic'
fi

echo '== 4. CLI contract'
printf 'cfg-simplify\tdefault,release\nmem2reg\tdefault,release\nsimplify\tdefault,release\ndce\tdefault,release\nsroa\trelease\ninline\trelease\ndeadfn\trelease\ncse\trelease\nprove\trelease\nlicm\trelease\nlayout\trelease\nescape\trelease\nbarrier\trelease\nbarrier-stack\trelease\n' >"$WORK/passes.expected"
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
if ! "$PY" - "$(native_path "$DRV")" "$(native_path "$WORK")" "${NATIVE_OPT_SCALE_K:-2048}" "${NATIVE_OPT_RELEASE_SCALE_K:-4096}" "${NATIVE_OPT_LOOP_SCALE_K:-2048}" "${NATIVE_OPT_ALLOC_SCALE_K:-2048}" "${NATIVE_OPT_INDEGREE_SCALE_K:-2048}" "${NATIVE_OPT_CALLBACK_SCALE_K:-2048}" <<'PY'
import os, subprocess, sys, time
try:
    import resource
except ImportError:
    resource = None
binary, work, text_k, text_release_k, text_loop_k, text_alloc_k, text_indegree_k, text_callback_k = sys.argv[1:]
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
try:
    loop_k = int(text_loop_k)
except ValueError:
    sys.exit('NATIVE_OPT_LOOP_SCALE_K must be an integer')
if loop_k < 64:
    sys.exit('NATIVE_OPT_LOOP_SCALE_K must be at least 64')
try:
    alloc_k = int(text_alloc_k)
except ValueError:
    sys.exit('NATIVE_OPT_ALLOC_SCALE_K must be an integer')
if alloc_k < 64:
    sys.exit('NATIVE_OPT_ALLOC_SCALE_K must be at least 64')
try:
    indegree_k = int(text_indegree_k)
except ValueError:
    sys.exit('NATIVE_OPT_INDEGREE_SCALE_K must be an integer')
if indegree_k < 64:
    sys.exit('NATIVE_OPT_INDEGREE_SCALE_K must be at least 64')
try:
    callback_k = int(text_callback_k)
except ValueError:
    sys.exit('NATIVE_OPT_CALLBACK_SCALE_K must be an integer')
if callback_k < 64:
    sys.exit('NATIVE_OPT_CALLBACK_SCALE_K must be at least 64')

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

def generate_loops(n, path, nested):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('; iyi-ir 1\nsource_filename = "loop-scale"\n')
        f.write('target triple = "aarch64-apple-darwin"\n')
        f.write('target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"\n')
        if nested:
            f.write('declare external void @consume(i64)\n')
        f.write('define external i64 @loops(i64 %limit, i64 %seed) {\nentry:\n  br label %head0\n')
        for i in range(n):
            prev = 'entry' if i == 0 else 'head%d' % (i - 1)
            f.write('head%d:\n' % i)
            f.write('  %%iv%d = phi i64 [ 0, label %%%s ], [ %%next%d, label %%latch%d ]\n' % (i, prev, i, i))
            if not nested:
                previous = '%seed' if i == 0 else '%%acc%d' % (i - 1)
                f.write('  %%acc%d = phi i64 [ %s, label %%%s ], [ %%sum%d, label %%latch%d ]\n' % (i, previous, prev, i, i))
            f.write('  %%cond%d = icmp slt i64 %%iv%d, %%limit\n' % (i, i))
            if nested:
                inside = 'head%d' % (i + 1) if i + 1 < n else 'body'
                outside = 'done' if i == 0 else 'latch%d' % (i - 1)
            else:
                inside = 'latch%d' % i
                outside = 'head%d' % (i + 1) if i + 1 < n else 'done'
            f.write('  br i1 %%cond%d, label %%%s, label %%%s\n' % (i, inside, outside))
        if nested:
            f.write('body:\n  call void (i64) @consume(i64 %%iv%d)\n  br label %%latch%d\n' % (n - 1, n - 1))
        for i in range(n):
            f.write('latch%d:\n' % i)
            if not nested:
                f.write('  %%sum%d = add i64 %%acc%d, %%iv%d\n' % (i, i, i))
            f.write('  %%next%d = add i64 %%iv%d, 1\n  br label %%head%d\n' % (i, i, i))
        result = '%seed' if nested else '%%acc%d' % (n - 1)
        f.write('done:\n  ret i64 %s\n}\n' % result)

def generate_allocations(n, path):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('; iyi-ir 1\nsource_filename = "allocation-scale"\n')
        f.write('target triple = "aarch64-apple-darwin"\n')
        f.write('target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"\n')
        f.write('declare external void @consume_allocation(ptr)\n')
        f.write('define internal ptr @__iyi_new(i64 %size, i64 %type, i64 %flags) {\nentry:\n  ret ptr null\n}\n')
        # Local sites sit in a helper that reaches no declaration; the escaping sites call the
        # declared sink, which the rule treats as a possible callback into the external root.
        f.write('define internal void @local_sites() {\nentry:\n')
        for i in range(0, n, 2):
            f.write('  %%p%d = call ptr (i64, i64, i64) @__iyi_new(i64 8, i64 1, i64 2)\n' % i)
            f.write('  store i64 %d, ptr %%p%d, align 8\n' % (i, i))
        f.write('  ret void\n}\n')
        f.write('define internal void @escaping_sites() {\nentry:\n')
        for i in range(1, n, 2):
            f.write('  %%p%d = call ptr (i64, i64, i64) @__iyi_new(i64 8, i64 1, i64 2)\n' % i)
            f.write('  call void (ptr) @consume_allocation(ptr %%p%d)\n' % i)
        f.write('  ret void\n}\n')
        f.write('define external void @allocations() {\nentry:\n  call void () @local_sites()\n  call void () @escaping_sites()\n  ret void\n}\n')

def generate_indegree(n, path):
    # Both N indirect callers and N declarations can reach N address-taken
    # callbacks. The recursion hub must represent that relation in O(N) edges.
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('; iyi-ir 1\nsource_filename = "high-indegree"\n')
        f.write('target triple = "aarch64-apple-darwin"\n')
        f.write('target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"\n')
        f.write('declare external void @register(ptr)\n')
        for i in range(n):
            f.write('declare external void @decl%d()\n' % i)
        for i in range(n):
            f.write('define internal void @cb%d() [noinline] {\nentry:\n  ret void\n}\n' % i)
            f.write('define internal void @caller%d(ptr %%next) [noinline] {\nentry:\n' % i)
            f.write('  call void () %%next()\n  call void () @decl%d()\n  ret void\n}\n' % i)
        f.write('define external void @drive() {\nentry:\n')
        for i in range(n):
            f.write('  call void (ptr) @register(ptr @cb%d)\n' % i)
            f.write('  call void (ptr) @caller%d(ptr @cb%d)\n' % (i, i))
        f.write('  ret void\n}\n')

def generate_callbacks(n, path):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('; iyi-ir 1\nsource_filename = "callback-scale"\n')
        f.write('target triple = "aarch64-apple-darwin"\n')
        f.write('target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"\n')
        f.write('declare external void @register(ptr)\n')
        f.write('define internal ptr @__iyi_new(i64 %size, i64 %type, i64 %flags) {\nentry:\n  ret ptr null\n}\n')
        f.write('define internal void @consume(i64 %v) {\nentry:\n  ret void\n}\n')
        for i in range(n):
            f.write('define internal i64 @cb%d(ptr %%next, i64 %%d) [noinline] {\nentry:\n' % i)
            f.write('  %p = call ptr (i64, i64, i64) @__iyi_new(i64 8, i64 1, i64 2)\n')
            f.write('  %r = call i64 (ptr, i64) %next(ptr %next, i64 %d)\n')
            f.write('  %v = load i64, ptr %p, align 8\n  %sum = add i64 %v, %r\n  ret i64 %sum\n}\n')
            f.write('define internal i64 @leaf%d(i64 %%d) [noinline] {\nentry:\n' % i)
            f.write('  %p = call ptr (i64, i64, i64) @__iyi_new(i64 8, i64 1, i64 2)\n')
            f.write('  %v = load i64, ptr %p, align 8\n  call void (i64) @consume(i64 %v)\n  ret i64 %v\n}\n')
        f.write('define external i64 @drive(i64 %d) {\nentry:\n')
        for i in range(n):
            f.write('  call void (ptr) @register(ptr @cb%d)\n' % i)
            f.write('  %%v%d = call i64 (i64) @leaf%d(i64 %%d)\n' % (i, i))
            f.write('  %%sum%d = add i64 %s, %%v%d\n' % (i, '%d' if i == 0 else '%%sum%d' % (i - 1), i))
        f.write('  ret i64 %%sum%d\n}\n' % (n - 1))

def child_cpu():
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    return usage.ru_utime + usage.ru_stime

def run(n, verified, repeats=1, tier='default', shape='calls'):
    if tier == 'release':
        path = os.path.join(work, '%s-%d.ir' % (shape, n))
        if shape == 'calls':
            generate_release(n, path)
        elif shape == 'allocations':
            generate_allocations(n, path)
        elif shape == 'high-indegree':
            generate_indegree(n, path)
        elif shape == 'callbacks':
            generate_callbacks(n, path)
        else:
            generate_loops(n, path, shape == 'nested-loops')
    else:
        path = os.path.join(work, 'scale-%d.ir' % n)
        generate(n, path)
    cmd = [binary, 'run', '--verify-each' if verified else '--no-verify', tier, path]
    least = None
    for _ in range(repeats):
        before = child_cpu() if resource else 0.0
        start = time.monotonic()
        try:
            output = subprocess.PIPE if verified and shape != 'calls' and tier == 'release' else subprocess.DEVNULL
            completed = subprocess.run(cmd, stdout=output, stderr=subprocess.PIPE, timeout=180)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise RuntimeError('scale run could not complete: %s' % exc)
        elapsed = time.monotonic() - start
        if completed.returncode != 0:
            raise RuntimeError('scale run failed (%d): %s' %
                               (completed.returncode, completed.stderr.decode('utf-8', 'replace')))
        if verified and tier == 'release' and shape in ('sequential-loops', 'nested-loops'):
            if completed.stdout.count(b' = phi ') < n:
                raise RuntimeError('%s scale input lost loop headers' % shape)
        if verified and tier == 'release' and shape == 'allocations':
            kept = sum(1 for line in completed.stdout.splitlines()
                       if b'call ' in line and b'@__iyi_new(' in line)
            if kept < n // 2 or kept >= n:
                raise RuntimeError('allocation scale must retain escaping sites and promote local sites: %d/%d kept' % (kept, n))
        if verified and tier == 'release' and shape == 'high-indegree':
            if b'@caller0(' not in completed.stdout or b'@cb0(' not in completed.stdout:
                raise RuntimeError('high-indegree scale lost caller or callback functions')
        if verified and tier == 'release' and shape == 'callbacks':
            kept = sum(1 for line in completed.stdout.splitlines()
                       if b'call ' in line and b'@__iyi_new(' in line)
            if kept != n:
                raise RuntimeError('callback scale must keep callbacks and promote leaves: %d/%d kept' % (kept, n))
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
for shape in ('sequential-loops', 'nested-loops'):
    print('== 6. release %s scaling' % shape)
    try:
        run(max(8, loop_k // 8), True, tier='release', shape=shape)
        small = run(loop_k, False, 3, 'release', shape)
        large = run(2 * loop_k, False, 3, 'release', shape)
        ratio = large / small if small > 0 else float('inf')
        print('  %s K=%d %.3fs, 2K=%d %.3fs, ratio %.3f (%s, least of 3)' %
              (shape, loop_k, small, 2 * loop_k, large, ratio,
               'cpu' if resource else 'elapsed'))
        if large < 0.5:
            raise RuntimeError('%s 2K run is under 0.5s; increase NATIVE_OPT_LOOP_SCALE_K' % shape)
        if ratio > 3.0:
            raise RuntimeError('%s 2K/K exceeds 3.0' % shape)
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        failed = True
print('== 6. release allocation-site scaling')
try:
    run(max(8, alloc_k // 8), True, tier='release', shape='allocations')
    small = run(alloc_k, False, 3, 'release', 'allocations')
    large = run(2 * alloc_k, False, 3, 'release', 'allocations')
    ratio = large / small if small > 0 else float('inf')
    print('  allocations K=%d %.3fs, 2K=%d %.3fs, ratio %.3f (%s, least of 3)' %
          (alloc_k, small, 2 * alloc_k, large, ratio,
           'cpu' if resource else 'elapsed'))
    if large < 0.5:
        raise RuntimeError('allocation 2K run is under 0.5s; increase NATIVE_OPT_ALLOC_SCALE_K')
    if ratio > 3.0:
        raise RuntimeError('allocation 2K/K exceeds 3.0')
except RuntimeError as exc:
    print(str(exc), file=sys.stderr)
    failed = True
print('== 6. release high-indegree scaling')
try:
    run(8, True, tier='release', shape='high-indegree')
    small_path = os.path.join(work, 'call-edges-small.ir')
    large_path = os.path.join(work, 'call-edges-large.ir')
    generate_indegree(indegree_k, small_path)
    generate_indegree(2 * indegree_k, large_path)
    mutation_k = max(64, indegree_k // 16)
    generate_indegree(mutation_k, os.path.join(work, 'call-edges-mut-small.ir'))
    generate_indegree(2 * mutation_k, os.path.join(work, 'call-edges-mut-large.ir'))

    def edge_count(path):
        try:
            result = subprocess.run([binary, 'call-edges', path], stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, timeout=180)
            if result.returncode != 0:
                raise RuntimeError(result.stderr.decode('utf-8', 'replace'))
            count = int(result.stdout.strip())
            if count <= 0:
                raise ValueError('edge count must be positive')
            return count
        except (OSError, subprocess.TimeoutExpired, ValueError) as exc:
            raise RuntimeError('call-graph edge count failed: %s' % exc)

    for measurement in range(1, 4):
        small = edge_count(small_path)
        large = edge_count(large_path)
        ratio = large / small
        print('  high-indegree run %d: K=%d %d edges, 2K=%d %d edges, ratio %.6f' %
              (measurement, indegree_k, small, 2 * indegree_k, large, ratio))
        if ratio > 3.0:
            raise RuntimeError('high-indegree 2K/K exceeds 3.0')
        if small != 6 * indegree_k + 2 or large != 12 * indegree_k + 2:
            raise RuntimeError('high-indegree graph has an unexpected edge count')
except RuntimeError as exc:
    print(str(exc), file=sys.stderr)
    failed = True
print('== 6. release callback scaling')
try:
    run(max(8, callback_k // 8), True, tier='release', shape='callbacks')
    small = run(callback_k, False, 3, 'release', 'callbacks')
    large = run(2 * callback_k, False, 3, 'release', 'callbacks')
    ratio = large / small if small > 0 else float('inf')
    print('  callbacks K=%d %.3fs, 2K=%d %.3fs, ratio %.3f (%s, least of 3)' %
          (callback_k, small, 2 * callback_k, large, ratio, 'cpu' if resource else 'elapsed'))
    if large < 0.5:
        raise RuntimeError('callback 2K run is under 0.5s; increase NATIVE_OPT_CALLBACK_SCALE_K')
    if ratio > 3.0:
        raise RuntimeError('callback 2K/K exceeds 3.0')
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
prove_mutation 'M11: mutable globals are not constants' src/compiler/ir/opt/simplify.iyi \
  '    return nil unless global.constant # mutation S8-global: only immutable globals fold' \
  '    return nil if false # mutation S8-global: only immutable globals fold' \
  -- mutation_check M11 simplify constant_global_keep || fail 'M11 was not caught'
mutation_result M11
prove_mutation 'M12: stores invalidate earlier loads' src/compiler/ir/opt/cse.iyi \
  '        version = @boundaries[inst] # mutation CSE-store: invalidate loads at each store' \
  '        version = @entry_version[block] # mutation CSE-store: invalidate loads at each store' \
  -- mutation_check M12 cse store_clobber_keep || fail 'M12 was not caught'
mutation_result M12
prove_mutation 'M13: opaque accesses cannot be merged' src/compiler/ir/opt/cse.iyi \
  '      if opaque?(inst) || marking_read?(inst) # mutation CSE-opaque: preserve opaque operations' \
  '      if false # mutation CSE-opaque: preserve opaque operations' \
  -- mutation_check M13 cse opaque_keep || fail 'M13 was not caught'
mutation_result M13
prove_mutation 'M14: a fact belongs only to its own successor' src/compiler/ir/opt/prove.iyi \
  '        truth = @cfg.index(term.targets[0]) == block # mutation M14: opposite successor fact' \
  '        truth = @cfg.index(term.targets[0]) != block # mutation M14: opposite successor fact' \
  -- mutation_check M14 prove edge_relation || fail 'M14 was not caught'
mutation_result M14
prove_mutation 'M15: induction bound is not one too wide' src/compiler/ir/opt/prove.iyi \
  '        return upper + step if add_fits?(upper, step, lo, hi) # mutation M15: widen induction range' \
  '        return upper + step + 1_i64 if add_fits?(upper, step, lo, hi - 1_i64) # mutation M15: widen induction range' \
  -- mutation_check M15 prove bounded_exit || fail 'M15 was not caught'
mutation_result M15
prove_mutation 'M16: trapping division stays in the loop' src/compiler/ir/opt/licm.iyi \
  '  return false if inst.op == Op::SDiv || inst.op == Op::UDiv || inst.op == Op::SRem || inst.op == Op::URem # mutation M16: never speculate integer division' \
  '  return false if inst.op == Op::UDiv || inst.op == Op::SRem || inst.op == Op::URem # mutation M16: never speculate integer division' \
  -- mutation_check M16 licm div_keep || fail 'M16 was not caught'
mutation_result M16
prove_mutation 'M17: hoisted operands dominate the preheader' src/compiler/ir/opt/licm.iyi \
  '    return false unless @dom.dominates?(location, preheader) # mutation M17: the operand must dominate the preheader' \
  '    return false if false # mutation M17: the operand must dominate the preheader' \
  -- mutation_check M17 licm dominance_keep || fail 'M17 was not caught'
mutation_result M17
prove_mutation 'M18: expect false chooses its unlikely successor' src/compiler/ir/opt/layout.iyi \
  '    return @cfg.index(term.targets[0]) if expected.aux_int == 0_i64 # mutation M18: cold false edge' \
  '    return @cfg.index(term.targets[1]) if expected.aux_int == 0_i64 # mutation M18: cold false edge' \
  -- mutation_check M18 layout cold_last || fail 'M18 was not caught'
mutation_result M18
prove_mutation 'M20: preserve every block during layout' src/compiler/ir/opt/layout.iyi \
  '    @fn.blocks[0, @fn.blocks.size] = ordered # mutation M20: preserve every block' \
  '    @fn.blocks[0, @fn.blocks.size] = ordered[0, ordered.size - 1] # mutation M20: preserve every block' \
  -- mutation_check M20 layout unreachable_phi || fail 'M20 was not caught'
mutation_result M20
prove_mutation 'S6P1: forward five-arm dispatch limit' src/compiler/ir/opt/inline.iyi \
  '    return true if suffix > 4 # mutation S6P1: a five-arm chain exceeds the limit' \
  '    return true if suffix > 5 # mutation S6P1: a five-arm chain exceeds the limit' \
  -- generated_mutation_check S6P1 inline dispatch5 || fail 'S6P1 was not caught'
mutation_result S6P1
prove_mutation 'S6P2: invalidate callee after cleanup' src/compiler/ir/opt/pipeline.iyi \
  '            inline_budget.invalidate(fn) # mutation S6P2: invalidate after function cleanup' \
  '            nil # mutation S6P2: invalidate after function cleanup' \
  -- generated_mutation_check S6P2 release cache_cleanup || fail 'S6P2 was not caught'
mutation_result S6P2
prove_mutation 'S6P3: count earlier dispatch starts' src/compiler/ir/opt/inline.iyi \
  '        return true if length + 1 > 4 # mutation S6P3: earlier chain starts also count' \
  '        return true if length + 1 > 5 # mutation S6P3: earlier chain starts also count' \
  -- generated_mutation_check S6P3 inline dispatch5 || fail 'S6P3 was not caught'
mutation_result S6P3
prove_mutation 'S9B2: early barrier never removes a heap destination' src/compiler/ir/opt/barrier.iyi \
  '    return stack if stack_only # mutation S9B2: early pass must not remove a heap barrier' \
  '    return true if stack_only # mutation S9B2: early pass must not remove a heap barrier' \
  -- mutation_check S9B2 barrier-stack stack_mode_heap_keep barrier || fail 'S9B2 was not caught'
mutation_result S9B2
prove_mutation 'S9B1: heap pointer stores retain their barriers' src/compiler/ir/opt/barrier.iyi \
  '        return false unless constant_nonpointer?(store.args[0]) # mutation S9B1: only pointer-free stored values' \
  '        return false unless true # mutation S9B1: only pointer-free stored values' \
  -- mutation_check S9B1 barrier heap_keep || fail 'S9B1 was not caught'
mutation_result S9B1
prove_mutation 'S9B3: merged stores preexist the bracket' src/compiler/ir/opt/barrier.iyi \
  '      return false if forbidden.has_key?(store.args[0]) # mutation S9B3: values must be live at a stop before the bracket' \
  '      return false if false # mutation S9B3: values must be live at a stop before the bracket' \
  -- mutation_check S9B3 barrier merge_value_between_keep || fail 'S9B3 was not caught'
mutation_result S9B3
prove_mutation 'S9B4: partition publication keeps barriers' src/compiler/ir/opt/barrier.iyi \
  '  return false if partitioned # mutation S9B4: partition publication needs the untouched barrier' \
  '  return false if false # mutation S9B4: partition publication needs the untouched barrier' \
  -- mutation_check S9B4 barrier partition_publish_call_keep || fail 'S9B4 was not caught'
mutation_result S9B4
prove_mutation 'S9B5: merged barriers shade the full range' src/compiler/ir/opt/barrier.iyi \
  'union_words = (upper - lower) // 8_i64 # mutation S9B5: shade the union' \
  'union_words = 1_i64 # mutation S9B5: shade the union' \
  -- mutation_check S9B5 barrier merge_fields || fail 'S9B5 was not caught'
mutation_result S9B5
prove_mutation 'S9E1: stored object pointers escape' src/compiler/ir/opt/escape.iyi \
  '            safe = false # mutation S9-store: change false to true' \
  '            safe = true # mutation S9-store: change false to true' \
  -- mutation_check S9E1 escape stored_global || fail 'S9E1 was not caught'
mutation_result S9E1
prove_mutation 'S9E2: ordinary call arguments escape' src/compiler/ir/opt/escape.iyi \
  '            safe = barrier_use?(inst, index) && bounded_barrier?(inst, candidate, offsets) && argument_attributes_safe?(inst, index, candidate, offsets) # mutation S9-call: change to true' \
  '            safe = true # mutation S9-call: change to true' \
  -- mutation_check S9E2 escape passed_call || fail 'S9E2 was not caught'
mutation_result S9E2
prove_mutation 'S9E3: loop-carried objects escape' src/compiler/ir/opt/escape.iyi \
  '              safe = false if cyclic_phi[inst] # mutation S9-loop: change false to true' \
  '              safe = true if cyclic_phi[inst] # mutation S9-loop: change false to true' \
  -- mutation_check S9E3 escape loop_carried || fail 'S9E3 was not caught'
mutation_result S9E3
prove_mutation 'S9E4: program-lifetime frames are excluded' src/compiler/ir/opt/escape.iyi \
  '  return false if fn.declaration? || frames.protects?(fn) # mutation S9-top-call: remove top-level exclusion' \
  '  return false if fn.declaration? # mutation S9-top-call: remove top-level exclusion' \
  -- mutation_check S9E4 escape entry_chain || fail 'S9E4 was not caught'
mutation_result S9E4
prove_mutation 'S9E5: each loop iteration clears its object' src/compiler/ir/opt/escape.iyi \
  '    zero_site = site # mutation S9-zero: change site to entry_anchor' \
  '    zero_site = entry_anchor # mutation S9-zero: change site to entry_anchor' \
  -- mutation_check S9E5 escape loop_local || fail 'S9E5 was not caught'
mutation_result S9E5
prove_mutation 'S9E6: headed objects receive a header store' src/compiler/ir/opt/escape.iyi \
  '      add_before(insertions, site, header_store) # mutation S9-header: remove this line' \
  '      nil # mutation S9-header: remove this line' \
  -- mutation_check S9E6 escape headed || fail 'S9E6 was not caught'
mutation_result S9E6
prove_mutation 'S9E7: partition entry uses disable promotion' src/compiler/ir/opt/escape.iyi \
  '      return true if value.name == "__iyi_new_shared" || value.name == "__iyi_publish" # mutation S9-partition: return false here' \
  '      return false if value.name == "__iyi_new_shared" || value.name == "__iyi_publish" # mutation S9-partition: return false here' \
  -- mutation_check S9E7 escape partition_shared_call || fail 'S9E7 was not caught'
mutation_result S9E7
prove_mutation 'S9E8: heap pointer slots remain aligned on stack' src/compiler/ir/opt/escape.iyi \
  '          candidate.bad = true unless shape && shape.aligned # mutation S9-layout: ignore unaligned pointer slots' \
  '          candidate.bad = true unless shape # mutation S9-layout: ignore unaligned pointer slots' \
  -- mutation_check S9E8 escape packed_partial_store || fail 'S9E8 was not caught'
mutation_result S9E8
prove_mutation 'S9E9: direct entry frames are excluded' src/compiler/ir/opt/escape.iyi \
  '  fn.name == "__iyi_main" || fn.name == "__crystal_main" || fn.name == "__iyi_program" || fn.name == "__iyi_enter" || fn.name == "main" # mutation S9-top: return false' \
  '  false # mutation S9-top: return false' \
  -- mutation_check S9E9 escape top_level || fail 'S9E9 was not caught'
mutation_result S9E9
prove_mutation 'S9E10: recursive functions are excluded' src/compiler/ir/opt/escape.iyi \
  '  return false if cycles.recursive?(fn)' \
  '  nil' \
  -- mutation_check S9E10 escape recursive || fail 'S9E10 was not caught'
mutation_result S9E10
prove_mutation 'S9E11: typed pointer slots remain aligned' src/compiler/ir/opt/escape.iyi \
  '  aligned_span?(span, 0_i64, 8_i64) # mutation S9-slot: accept an unaligned pointer word' \
  '  true # mutation S9-slot: accept an unaligned pointer word' \
  -- mutation_check S9E11 escape unaligned_pointer_hint || fail 'S9E11 was not caught'
mutation_result S9E11
prove_mutation 'S9E12: indirect calls may recurse' src/compiler/ir/opt/escape.iyi \
  '      edges[k] << hub if indirect' \
  '      nil if indirect' \
  -- mutation_check S9E12 escape indirect_recursion || fail 'S9E12 was not caught'
mutation_result S9E12
prove_mutation 'S9E13: declarations may call back' src/compiler/ir/opt/escape.iyi \
  '      edges[k] << hub if fn.declaration? # mutation S9-declaration: a declaration may call back' \
  '      nil if fn.declaration? # mutation S9-declaration: a declaration may call back' \
  -- mutation_check S9E13 escape declaration_callback || fail 'S9E13 was not caught'
mutation_result S9E13
prove_mutation 'S9E-scale-indirect: indirect callers must not expand the callback product' src/compiler/ir/opt/escape.iyi \
  '      edges[k] << hub if indirect' \
  '      if indirect
        t = 0
        while t < mod.functions.size
          candidate = mod.functions[t]
          if addresses.has_key?(candidate) || (!candidate.declaration? && candidate.linkage != Linkage::Internal && candidate.linkage != Linkage::Private)
            edges[k] << t
          end
          t = t + 1
        end
      end' \
  -- call_graph_mutation_check S9E-scale-indirect || fail 'S9E-scale-indirect was not caught'
mutation_result S9E-scale-indirect
test ! -f "$WORK/S9E-scale-indirect.ratio" || cat "$WORK/S9E-scale-indirect.ratio"
prove_mutation 'S9E-scale-declaration: declarations must not expand the callback product' src/compiler/ir/opt/escape.iyi \
  '      edges[k] << hub if fn.declaration? # mutation S9-declaration: a declaration may call back' \
  '      if fn.declaration?
        t = 0
        while t < mod.functions.size
          candidate = mod.functions[t]
          if addresses.has_key?(candidate) || (!candidate.declaration? && candidate.linkage != Linkage::Internal && candidate.linkage != Linkage::Private)
            edges[k] << t
          end
          t = t + 1
        end
      end' \
  -- call_graph_mutation_check S9E-scale-declaration || fail 'S9E-scale-declaration was not caught'
mutation_result S9E-scale-declaration
test ! -f "$WORK/S9E-scale-declaration.ratio" || cat "$WORK/S9E-scale-declaration.ratio"
prove_mutation 'S9E14: every function is a callback target' src/compiler/ir/opt/escape.iyi \
  '      edges[hub] << k if addresses.has_key?(fn) ||' \
  '      edges[hub] << k if true ||' \
  -- mutation_check S9E14 escape indirect_nonrecursive || fail 'S9E14 was not caught'
mutation_result S9E14
prove_mutation 'S9E15: persist frame-cap rejection' src/compiler/ir/opt/escape.iyi \
  '      mark_capped(insertions, replacements, candidate.call) # mutation S9-cap-mark: preserve a cap rejection' \
  '      nil # mutation S9-cap-mark: preserve a cap rejection' \
  -- mutation_check S9E15 escape frame_cap || fail 'S9E15 was not caught'
mutation_result S9E15
prove_mutation 'S9E16: do not promote a marked call' src/compiler/ir/opt/escape.iyi \
  '  return nil if frame_capped?(inst) # mutation S9-capped: a marked call stays on the heap' \
  '  nil # mutation S9-capped: a marked call stays on the heap' \
  -- mutation_check S9E16 escape frame_cap_marked || fail 'S9E16 was not caught'
mutation_result S9E16
prove_mutation 'S9E17: preserve the object size cap' src/compiler/ir/opt/escape.iyi \
  '  return nil unless size && flags && size > 0_i64 && size <= 512_i64 && flags >= 0_i64 && flags <= 3_i64 # mutation S9-size-cap: cap individual objects' \
  '  return nil unless size && flags && size > 0_i64 && size <= 1024_i64 && flags >= 0_i64 && flags <= 3_i64 # mutation S9-size-cap: cap individual objects' \
  -- mutation_check S9E17 escape oversize || fail 'S9E17 was not caught'
mutation_result S9E17
prove_mutation 'S9E31: an empty allocation stays on the heap' src/compiler/ir/opt/escape.iyi \
  '  return nil unless size && flags && size > 0_i64 && size <= 512_i64 && flags >= 0_i64 && flags <= 3_i64 # mutation S9-size-cap: cap individual objects' \
  '  return nil unless size && flags && size >= 0_i64 && size <= 512_i64 && flags >= 0_i64 && flags <= 3_i64 # mutation S9-size-cap: cap individual objects' \
  -- mutation_check S9E31 escape unsupported_allocations || fail 'S9E31 was not caught'
mutation_result S9E31
prove_mutation 'S9E32: unknown allocation flags stay on the heap' src/compiler/ir/opt/escape.iyi \
  '  return nil unless size && flags && size > 0_i64 && size <= 512_i64 && flags >= 0_i64 && flags <= 3_i64 # mutation S9-size-cap: cap individual objects' \
  '  return nil unless size && flags && size > 0_i64 && size <= 512_i64 && flags >= 0_i64 && flags <= 7_i64 # mutation S9-size-cap: cap individual objects' \
  -- mutation_check S9E32 escape unsupported_allocations || fail 'S9E32 was not caught'
mutation_result S9E32
prove_mutation 'S9E18: preserve the function frame cap' src/compiler/ir/opt/escape.iyi \
  '    if frame + bytes > 2048_i64' \
  '    if frame + bytes > 4096_i64' \
  -- mutation_check S9E18 escape frame_cap || fail 'S9E18 was not caught'
mutation_result S9E18
prove_mutation 'S9E19: pointerful promotion requires a layout hint' src/compiler/ir/opt/escape.iyi \
  '          candidate.bad = true if (candidate.flags & 2_i64) == 0_i64 # mutation S9-hint: pointerful objects need a layout hint' \
  '          nil # mutation S9-hint: pointerful objects need a layout hint' \
  -- mutation_check S9E19 escape packed_partial_literal || fail 'S9E19 was not caught'
mutation_result S9E19
prove_mutation 'S9E20: alien aliases poison a candidate' src/compiler/ir/opt/escape.iyi \
  '    candidate.bad = true unless alias_instruction?(value) # mutation S9-alias: alien pointers poison the candidate' \
  '    nil # mutation S9-alias: alien pointers poison the candidate' \
  -- mutation_check S9E20 escape mixed_unused_keep || fail 'S9E20 was not caught'
mutation_result S9E20
prove_mutation 'S9E21: address-taken entry excludes all frames' src/compiler/ir/opt/escape.iyi \
  '      @uncertain = true if @addresses.has_key?(fn)' \
  '      nil if @addresses.has_key?(fn)' \
  -- mutation_check S9E21 escape entry_address_taken || fail 'S9E21 was not caught'
mutation_result S9E21
prove_mutation 'S9E22: atomic accesses stay on the heap' src/compiler/ir/opt/escape.iyi \
  '  !mem.volatile && mem.ordering == Ordering::NotAtomic # mutation S9-atomic: only ordinary accesses may promote' \
  '  true # mutation S9-atomic: only ordinary accesses may promote' \
  -- mutation_check S9E22 escape atomic || fail 'S9E22 was not caught'
mutation_result S9E22
prove_mutation 'S9E23: low header bits stay on the heap' src/compiler/ir/opt/escape.iyi \
  '    return false unless inst.op == Op::Load && candidate.headed? && span.low >= -4_i64 && span.high < 0_i64 && info.store <= -span.high # mutation S9-header-low: reject low header bits' \
  '    return false unless inst.op == Op::Load && candidate.headed? && span.low >= -8_i64 && span.high < 0_i64 && info.store <= -span.high # mutation S9-header-low: reject low header bits' \
  -- mutation_check S9E23 escape header_low_bits || fail 'S9E23 was not caught'
mutation_result S9E23
prove_mutation 'S9E24: barrier words stay within object' src/compiler/ir/opt/escape.iyi \
  '  words <= (candidate.size - span.high) // 8_i64 # mutation S9-barrier-bound: shade stays within object' \
  '  true # mutation S9-barrier-bound: shade stays within object' \
  -- mutation_check S9E24 escape barrier_bounds_keep || fail 'S9E24 was not caught'
mutation_result S9E24
prove_mutation 'S9E25: bulk copy source must be stack or same object' src/compiler/ir/opt/escape.iyi \
  '  return false unless origin.is_a?(Inst) && origin.as(Inst).op == Op::Alloca && origin.as(Inst).aux.is_a?(GepAux) # mutation S9-bulk-source: source must be stack or same object' \
  '  return true unless origin.is_a?(Inst) && origin.as(Inst).op == Op::Alloca && origin.as(Inst).aux.is_a?(GepAux) # mutation S9-bulk-source: source must be stack or same object' \
  -- mutation_check S9E25 escape bulk_source_keep || fail 'S9E25 was not caught'
mutation_result S9E25
prove_mutation 'S9E26: bulk copy preserves pointer alignment' src/compiler/ir/opt/escape.iyi \
  '  return false unless aligned_span?(target, 0_i64, 8_i64) && aligned_span?(source_span, 0_i64, 8_i64) # mutation S9-bulk-align: do not shift pointer words' \
  '  nil # mutation S9-bulk-align: do not shift pointer words' \
  -- mutation_check S9E26 escape bulk_align_keep || fail 'S9E26 was not caught'
mutation_result S9E26
prove_mutation 'S9E30: bulk copy length covers whole words' src/compiler/ir/opt/escape.iyi \
  '  return false unless source_span && length % 8_i64 == 0_i64' \
  '  return false unless source_span' \
  -- mutation_check S9E30 escape bulk_partial_word_keep || fail 'S9E30 was not caught'
mutation_result S9E30
prove_mutation 'S9E27: barrier call alignment is honored' src/compiler/ir/opt/escape.iyi \
  '      return false unless aligned_pointer?(candidate, inst.args[index], attr.int_value.to_i64, offsets) # mutation S9-call-offset-align: honor actual pointer offset' \
  '      nil # mutation S9-call-offset-align: honor actual pointer offset' \
  -- mutation_check S9E27 escape barrier_align_keep || fail 'S9E27 was not caught'
mutation_result S9E27
prove_mutation 'S9E28: object pointer compares are permitted' src/compiler/ir/opt/escape.iyi \
  '          elsif harmless_compare?(inst, index, sets) # mutation S9-compare: compare only null or same object' \
  '          elsif false # mutation S9-compare: compare only null or same object' \
  -- mutation_check S9E28 escape pointer_compare || fail 'S9E28 was not caught'
mutation_result S9E28
prove_mutation 'S9E29: zero each loop allocation before a read' src/compiler/ir/opt/escape.iyi \
  '    zero_site = site # mutation S9-zero: change site to entry_anchor' \
  '    zero_site = entry_anchor # mutation S9-zero: change site to entry_anchor' \
  -- mutation_check S9E29 escape loop_read_zero || fail 'S9E29 was not caught'
mutation_result S9E29
for pass in escape barrier barrier-stack; do
  label="S9ASM-$pass"
  prove_mutation "$label: assembly partition use disables $pass" src/compiler/ir/opt/escape.iyi \
    '        return true if template.includes?("__iyi_new_shared") || template.includes?("__iyi_publish")' \
    '        nil if template.includes?("__iyi_new_shared") || template.includes?("__iyi_publish")' \
    -- mutation_check "$label" "$pass" partition_asm_keep release || fail "$label was not caught"
  mutation_result "$label"
done
prove_mutation 'S9B6: canonical narrow GEP index' src/compiler/ir/opt/barrier.iyi \
  '    first = int_value(inst.args[1]) # mutation S9-canonical-gep: sign-extend narrow indices' \
  '    first = inst.args[1].as(Inst).aux_int # mutation S9-canonical-gep: sign-extend narrow indices' \
  -- mutation_check S9B6 barrier merge_narrow_gep_keep || fail 'S9B6 was not caught'
mutation_result S9B6
prove_mutation 'S9B7: canonical nested GEP index' src/compiler/ir/opt/barrier.iyi \
  '      n = int_value(inst.args[index]) # mutation S9-canonical-gep-nested: sign-extend narrow indices' \
  '      n = inst.args[index].as(Inst).aux_int # mutation S9-canonical-gep-nested: sign-extend narrow indices' \
  -- mutation_check S9B7 barrier merge_narrow_nested_keep || fail 'S9B7 was not caught'
mutation_result S9B7
prove_mutation 'S9B8: sign extend i1 GEP index' src/compiler/ir/opt/barrier.iyi \
  '    first = -1_i64 if inst.args[1].type.bits == 1 && first == 1_i64 # mutation S9-gep-i1-first: sign-extend i1' \
  '    nil if inst.args[1].type.bits == 1 && first == 1_i64 # mutation S9-gep-i1-first: sign-extend i1' \
  -- mutation_check S9B8 barrier merge_narrow_gep_keep || fail 'S9B8 was not caught'
mutation_result S9B8
prove_mutation 'S9B9: sign extend nested i1 GEP index' src/compiler/ir/opt/barrier.iyi \
  '      n = -1_i64 if inst.args[index].type.bits == 1 && n == 1_i64 # mutation S9-gep-i1-nested: sign-extend i1' \
  '      nil if inst.args[index].type.bits == 1 && n == 1_i64 # mutation S9-gep-i1-nested: sign-extend i1' \
  -- mutation_check S9B9 barrier merge_narrow_gep_keep || fail 'S9B9 was not caught'
mutation_result S9B9
prove_mutation 'S9B10: all selected destinations must be stack' src/compiler/ir/opt/barrier.iyi \
  '      return nil unless span # mutation S9-stack-all: every incoming operand must be stack-backed' \
  '      next unless span # mutation S9-stack-all: every incoming operand must be stack-backed' \
  -- mutation_check S9B10 barrier ambiguous_stack_keep || fail 'S9B10 was not caught'
mutation_result S9B10
prove_mutation 'S9B11: barrier begin call is direct' src/compiler/ir/opt/barrier.iyi \
  '    return nil unless direct_call?(begin_block.insts[0], @begin_fn, 0) # mutation S9-sequence-shape: begin must be direct' \
  '    return nil if false # mutation S9-sequence-shape: begin must be direct' \
  -- mutation_check S9B11 barrier incomplete_indirect_keep || fail 'S9B11 was not caught'
mutation_result S9B11
prove_mutation 'S9B12: constant stores must be tight' src/compiler/ir/opt/barrier.iyi \
  '        return false unless type && type.tight # mutation S9-constant-tight: padding is not a constant store' \
  '        return false unless type # mutation S9-constant-tight: padding is not a constant store' \
  -- mutation_check S9B12 barrier constant_padding_keep || fail 'S9B12 was not caught'
mutation_result S9B12
prove_mutation 'S9B13: memset removal only for zero bytes' src/compiler/ir/opt/barrier.iyi \
  '        return false unless store.aux.as(IntrinsicAux).id == IntrinsicId::Memset && int_value(store.args[1]) == 0_i64 # mutation S9-memset-byte: only zero fill is pointer-free' \
  '        return false unless store.aux.as(IntrinsicAux).id == IntrinsicId::Memset # mutation S9-memset-byte: only zero fill is pointer-free' \
  -- mutation_check S9B13 barrier memset_nonzero_keep || fail 'S9B13 was not caught'
mutation_result S9B13
prove_mutation 'S9B14: constant coverage uses shade base' src/compiler/ir/opt/barrier.iyi \
  '      return false unless length > 0_i64 && dest && dest.base == shade.base' \
  '      return false unless length > 0_i64 && dest' \
  -- mutation_check S9B14 barrier constant_outside_keep || fail 'S9B14 was not caught'
mutation_result S9B14
prove_mutation 'S9B15: constant stores stay in shade' src/compiler/ir/opt/barrier.iyi \
  '      return false unless dest.offset >= shade.offset && dest.offset <= finish && length <= finish - dest.offset # mutation S9-constant-contained: stores stay within the shade' \
  '      return false if false # mutation S9-constant-contained: stores stay within the shade' \
  -- mutation_check S9B15 barrier constant_outside_keep || fail 'S9B15 was not caught'
mutation_result S9B15
prove_mutation 'S9B16: constant coverage cannot skip bytes' src/compiler/ir/opt/barrier.iyi \
  '      return false if range.first > cursor # mutation S9-constant-gap: coverage cannot skip bytes' \
  '      return false if false # mutation S9-constant-gap: coverage cannot skip bytes' \
  -- mutation_check S9B16 barrier constant_gap_keep || fail 'S9B16 was not caught'
mutation_result S9B16
prove_mutation 'S9B17: constant coverage reaches shade end' src/compiler/ir/opt/barrier.iyi \
  '    cursor == finish # mutation S9-constant-full: coverage must reach the end of the shade' \
  '    true # mutation S9-constant-full: coverage must reach the end of the shade' \
  -- mutation_check S9B17 barrier nonpointer_uncertain_keep || fail 'S9B17 was not caught'
mutation_result S9B17
prove_mutation 'S9B18: never merge across an observer call' src/compiler/ir/opt/barrier.iyi \
  '      return false unless inst.op == Op::Gep || inst.op == Op::BitCast # mutation S9-merge-call: no calls between brackets' \
  '      return false unless inst.op == Op::Gep || inst.op == Op::BitCast || inst.op == Op::Call # mutation S9-merge-call: no calls between brackets' \
  -- mutation_check S9B18 barrier merge_call_keep || fail 'S9B18 was not caught'
mutation_result S9B18
prove_mutation 'S9B19: merged shades share a base' src/compiler/ir/opt/barrier.iyi \
  '          break unless next_address && next_address.base == first_address.base && covered?(following, next_address) # mutation S9-merge-base: both shades share a base' \
  '          break unless next_address && covered?(following, next_address) # mutation S9-merge-base: both shades share a base' \
  -- mutation_check S9B19 barrier merge_other_object_keep || fail 'S9B19 was not caught'
mutation_result S9B19
prove_mutation 'S9B20: merged shades have no gap' src/compiler/ir/opt/barrier.iyi \
  '          break if next_lower > upper || next_upper < lower' \
  '          break if false' \
  -- mutation_check S9B20 barrier merge_gap_keep || fail 'S9B20 was not caught'
mutation_result S9B20
prove_mutation 'S9B21: first merge address must be inbounds' src/compiler/ir/opt/barrier.iyi \
  '          break if next_lower != lower && (!same_object || !next_address.inbounds) # mutation S9-merge-inbounds: differing addresses must stay in one object' \
  '          break if next_lower != lower && !next_address.inbounds # mutation S9-merge-inbounds: differing addresses must stay in one object' \
  -- mutation_check S9B21 barrier merge_non_inbounds_keep || fail 'S9B21 was not caught'
mutation_result S9B21
prove_mutation 'S9B22: second merge address must be inbounds' src/compiler/ir/opt/barrier.iyi \
  '          break if next_lower != lower && (!same_object || !next_address.inbounds) # mutation S9-merge-inbounds: differing addresses must stay in one object' \
  '          break if next_lower != lower && !same_object # mutation S9-merge-inbounds: differing addresses must stay in one object' \
  -- mutation_check S9B22 barrier merge_non_inbounds_keep || fail 'S9B22 was not caught'
mutation_result S9B22

prove_mutation 'S9R1: promotion is refused in a function that can return twice' src/compiler/ir/opt/escape.iyi \
  '  return false if function_returns_twice?(fn)' \
  '  nil if function_returns_twice?(fn)' \
  -- mutation_check S9R1 release returns_twice || fail 'S9R1 was not caught'
mutation_result S9R1
prove_mutation 'S9R2: the selective escape group repeats to a fixed point' src/compiler/ir/opt/pipeline.iyi \
  '&& gate_changed # mutation S9-escape-fixed-point' \
  '&& false # mutation S9-escape-fixed-point' \
  -- mutation_check S9R2 release nested_objects || fail 'S9R2 was not caught'
mutation_result S9R2
prove_mutation 'S9R3a: externally visible definitions are callback targets' src/compiler/ir/opt/escape.iyi \
  ' || (!fn.declaration? && fn.linkage != Linkage::Internal && fn.linkage != Linkage::Private) # mutation S9-hub' \
  ' || false # mutation S9-hub' \
  -- mutation_check S9R3a escape external_callback || fail 'S9R3a was not caught'
mutation_result S9R3a
prove_mutation 'S9R3b: assembly-named functions are address taken' src/compiler/ir/opt/escape.iyi \
  '@addresses[fn] = true # mutation S9-asm-address: assembly can name a function' \
  'nil # mutation S9-asm-address: assembly can name a function' \
  -- mutation_check S9R3b escape asm_callback || fail 'S9R3b was not caught'
mutation_result S9R3b
prove_mutation 'S9R8: an asm template names a function only as a whole symbol' src/compiler/ir/opt/effects.iyi \
  '      if whole_symbol_in?(templates[k], fn.name) || whole_symbol_in?(templates[k], "_" + fn.name)' \
  '      if templates[k].includes?(fn.name)' \
  -- mutation_check S9R8 escape asm_substring_promote || fail 'S9R8 was not caught'
mutation_result S9R8
prove_mutation 'S9R8d: deadfn keeps only whole-symbol asm names' src/compiler/ir/opt/effects.iyi \
  '      if whole_symbol_in?(templates[k], fn.name) || whole_symbol_in?(templates[k], "_" + fn.name)' \
  '      if templates[k].includes?(fn.name)' \
  -- mutation_check S9R8d deadfn asm_names || fail 'S9R8d was not caught'
mutation_result S9R8d
prove_mutation 'S9R4a: a first GEP index of i1 true is sign-extended' src/compiler/ir/opt/escape.iyi \
  '    first = gep_index(inst.args[1]) # mutation S9-escape-gep-i1-first: sign-extend i1' \
  '    first = int_value(inst.args[1]) # mutation S9-escape-gep-i1-first: sign-extend i1' \
  -- mutation_check S9R4a escape header_i1_keep || fail 'S9R4a was not caught'
mutation_result S9R4a
prove_mutation 'S9R4b: a nested GEP index of i1 true is sign-extended' src/compiler/ir/opt/escape.iyi \
  '      index = gep_index(inst.args[k]) # mutation S9-escape-gep-i1-nested: sign-extend i1' \
  '      index = int_value(inst.args[k]) # mutation S9-escape-gep-i1-nested: sign-extend i1' \
  -- mutation_check S9R4b escape nested_i1_keep || fail 'S9R4b was not caught'
mutation_result S9R4b
prove_mutation 'S9R4c: a sizeof GEP index of i1 true is sign-extended' src/compiler/ir/opt/escape.iyi \
  '  return nil unless gep_index(gep.args[1]) == 1_i64 # mutation S9-sizeof-i1: GEP indices are signed' \
  '  return nil unless int_value(gep.args[1]) == 1_i64 # mutation S9-sizeof-i1: GEP indices are signed' \
  -- mutation_check S9R4c escape sizeof_i1_keep || fail 'S9R4c was not caught'
mutation_result S9R4c
prove_mutation 'S9R5a: a memset stays within the object' src/compiler/ir/opt/escape.iyi \
  '  return false unless target.low >= 0_i64 && target.high <= candidate.size && length >= 0_i64 && length <= candidate.size - target.high' \
  '  return false unless target.low >= 0_i64 # mutation S9-bulk-bound: the extent check is dropped' \
  -- mutation_check S9R5a escape memset_oversize_keep || fail 'S9R5a was not caught'
mutation_result S9R5a
prove_mutation 'S9R5b: a memcpy stays within the object' src/compiler/ir/opt/escape.iyi \
  '  return false unless target.low >= 0_i64 && target.high <= candidate.size && length >= 0_i64 && length <= candidate.size - target.high' \
  '  return false unless target.low >= 0_i64 # mutation S9-bulk-bound: the extent check is dropped' \
  -- mutation_check S9R5b escape memcpy_oversize_keep || fail 'S9R5b was not caught'
mutation_result S9R5b
prove_mutation 'S9R5c: a dereferenceable parameter stays within the object' src/compiler/ir/opt/escape.iyi \
  '      return false if attr.int_value > (candidate.size - span.high).to_u64' \
  '      nil if attr.int_value > (candidate.size - span.high).to_u64' \
  -- mutation_check S9R5c escape dereferenceable_oversize_keep || fail 'S9R5c was not caught'
mutation_result S9R5c
prove_mutation 'S9R5d: a store stays within the object' src/compiler/ir/opt/escape.iyi \
  '    return false if span.high > candidate.size || info.store > candidate.size - span.high' \
  '    nil if span.high > candidate.size || info.store > candidate.size - span.high' \
  -- mutation_check S9R5d escape out_of_bounds_store || fail 'S9R5d was not caught'
mutation_result S9R5d
prove_mutation 'S9R5e: a load stays within the object' src/compiler/ir/opt/escape.iyi \
  '    return false if span.high > candidate.size || info.store > candidate.size - span.high' \
  '    nil if span.high > candidate.size || info.store > candidate.size - span.high' \
  -- mutation_check S9R5e escape out_of_bounds_load || fail 'S9R5e was not caught'
mutation_result S9R5e
prove_mutation 'S9R5f: existing allocas count against the frame budget' src/compiler/ir/opt/escape.iyi \
  '    next unless inst.op == Op::Alloca' \
  '    next # mutation S9-frame-existing: existing allocas do not count' \
  -- mutation_check S9R5f escape existing_frame || fail 'S9R5f was not caught'
mutation_result S9R5f
prove_mutation 'S9R5g: a second candidate in a shared set poisons the first' src/compiler/ir/opt/escape.iyi \
  '      previous.bad = true' \
  '      nil # mutation S9-poison-previous: the first candidate of a shared set stays promotable' \
  -- mutation_check S9R5g escape mixed_candidates_unused_keep || fail 'S9R5g was not caught'
mutation_result S9R5g
prove_mutation 'S9R5h: a second candidate in a shared set is poisoned' src/compiler/ir/opt/escape.iyi \
  '      previous.bad = true
      candidate.bad = true' \
  '      previous.bad = true
      nil # mutation S9-poison-candidate: the second candidate of a shared set stays promotable' \
  -- mutation_check S9R5h escape mixed_candidates || fail 'S9R5h was not caught'
mutation_result S9R5h
echo '== 8. verdict'
if [ "$failed" -eq 0 ]; then
  echo 'ALL NATIVE OPT CHECKS PASSED!'
  exit 0
fi
echo 'SOME NATIVE OPT CHECKS FAILED'
exit 1
