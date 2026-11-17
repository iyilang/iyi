#!/usr/bin/env bash
# Compare hosted placement notes with the native non-Share witness sidecar.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if [ -z "$PY" ]; then echo 'a functional Python interpreter is required' >&2; exit 1; fi
IYI="${IYI_COMPILER:-$REPO/bin/iyi}"
REPO_NATIVE="$(native_path "$REPO")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
. "$REPO/bench/lib/mutation.sh"
corpus="$REPO/bench/fixtures/spawnshare_corpus.iyi"
branch="$REPO/bench/fixtures/spawnshare_dead_branch.iyi"
process="$REPO/bench/fixtures/spawnshare_process.iyi"

run_monitored() {
  if [ -n "${IYI_MEMORY_MONITOR:-}" ]; then
    "$IYI_MEMORY_MONITOR" "$@"
  else
    "$@"
  fi
}

native_probe() {
  local compiler="$1" source="$2" output="$3"
  run_monitored "$compiler" "$(native_path "$source")" -o "$(native_path "$output")" --pipeline typed --prelude --probe-phase --keep-going
}

build_compiler() {
  run_monitored "$IYI" build -o "$(native_path "$1")" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$2" 2>&1
}

compare_sites() {
  "$PY" - "$(native_path "$1")" "$(native_path "$2")" "$(native_path "$3")" "$4" <<'PY'
import pathlib, re, sys
source, hosted_path, native_path, kind = map(pathlib.Path, sys.argv[1:])
kind = str(kind)
lines = source.read_text().splitlines()
sites = {}
for number, line in enumerate(lines, 1):
    if re.search(r'\bg\.spawn\b', line):
        if kind in ('corpus', 'branch'):
            match = re.search(r'# hosted: (stays|parallel|none)(; gap: in-def macro)?', line)
            if not match:
                raise SystemExit(f'FAIL {source.name}:{number}: missing hosted annotation')
            sites[number] = (match.group(1), bool(match.group(2)))
        else:
            sites[number] = ('stays', False)
if not sites:
    raise SystemExit(f'FAIL {source}: no spawn sites found')
notes = {}
for line in hosted_path.read_text().splitlines():
    match = re.match(r'^(.*):(\d+):(\d+): note: spawn (.*)$', line)
    if (match and pathlib.Path(match.group(1)).name == source.name and
            (match.group(4).startswith("stays in its spawner's unit") or
             match.group(4).startswith('runs in parallel'))):
        notes.setdefault(int(match.group(2)), []).append(match.group(4))
verdicts = {}
for line in native_path.read_text().splitlines():
    cols = line.split('\t')
    if len(cols) < 5 or cols[0] != 'spawn':
        continue
    match = re.match(r'^(.*):(\d+):(\d+)$', cols[1])
    if match and pathlib.Path(match.group(1)).name == source.name:
        verdicts.setdefault(int(match.group(2)), []).append((cols[2], cols[4]))
for number, (expected, gap) in sites.items():
    host = notes.get(number, [])
    native = verdicts.get(number, [])
    if expected == 'none':
        if host or native:
            raise SystemExit(f'FAIL {source.name}:{number}: dead spawn was recorded: {host!r} {native!r}')
        print(f'{source.name}:{number}: hosted=none native=none')
        continue
    if not host or not native:
        raise SystemExit(f'FAIL {source.name}:{number}: missing hosted note or native verdict: {host!r} {native!r}')
    if expected == 'stays':
        if not all(note.startswith("stays in its spawner's unit") for note in host):
            raise SystemExit(f'FAIL {source.name}:{number}: hosted did not stay: {host!r}')
    elif not all(note.startswith('runs in parallel') for note in host):
        raise SystemExit(f'FAIL {source.name}:{number}: hosted did not run in parallel: {host!r}')
    wanted = 'unproven' if expected == 'parallel' or gap else 'as-written'
    for placement, reason in native:
        if placement != wanted:
            raise SystemExit(f'FAIL {source.name}:{number}: native {placement}, expected {wanted}: {reason}')
        if wanted == 'as-written':
            without_module = [re.sub(r' \(module `[^`]+`\)', '', note) for note in host]
            if not any(reason in note for note in without_module):
                raise SystemExit(f'FAIL {source.name}:{number}: native reason absent from hosted: {reason!r}, {host!r}')
            if kind == 'process' and 'the block captures `child : ' not in reason:
                raise SystemExit(f'FAIL {source.name}:{number}: expected child capture: {reason}')
    print(f'{source.name}:{number}: hosted={expected} native={wanted}' + (' (macro gap)' if gap else ''))
PY
}

check_fixture() {
  local fixture="$1" source="$2" label="$3"
  if ! run_monitored "$IYI" check --explain-spawn-std "$(native_path "$fixture")" > "$WORK/$label.hosted" 2>&1; then
    echo "FAIL: hosted check ($label)"; cat "$WORK/$label.hosted"; return 1
  fi
  native_probe "$WORK/compiler$EXE" "$fixture" "$WORK/$label" > "$WORK/$label.native" 2>&1
  local rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "FAIL: native probe crashed ($label, exit $rc)"
    cat "$WORK/$label.native"
    return 1
  fi
  # The keep-going compiler may refuse later lowering, but a completed table
  # writes both sidecars. A stream left by an interrupted run is not a table.
  if [ ! -f "$WORK/$label.names" ] || [ ! -f "$WORK/$label.refusals" ]; then
    echo "FAIL: native probe did not finish its sidecar ($label, exit $rc)"
    tail -n 30 "$WORK/$label.native"
    return 1
  fi
  if ! compare_sites "$source" "$WORK/$label.hosted" "$WORK/$label.refusals" "$label"; then
    echo "Hosted notes ($label):"; grep -F ': note: spawn ' "$WORK/$label.hosted" || :
    echo "Native spawn verdicts ($label):"; grep '^spawn' "$WORK/$label.refusals" || :
    return 1
  fi
}

# The sidecar's lowering row is the site the pool reach walk actually reports.
reach_is() {
  "$PY" - "$(native_path "$branch")" "$(native_path "$1")" "$2" <<'PY'
import pathlib, re, sys
source, sidecar = map(pathlib.Path, sys.argv[1:3])
label = sys.argv[3]
sites = [i for i, line in enumerate(source.read_text().splitlines(), 1)
         if re.search(r'; site: ' + re.escape(label) + r'\s*$', line)]
if len(sites) != 1:
    raise SystemExit(f'FAIL: expected one fixture site for {label}, got {sites}')
reached = []
for line in sidecar.read_text().splitlines():
    cols = line.split('\t')
    if (len(cols) >= 4 and cols[0] == 'lowering' and cols[2] == 'lowering core'
            and cols[3].startswith('spawn classification is not ported')):
        reached.append(cols[1])
if len(reached) != 1:
    raise SystemExit(f'FAIL: expected one pool-reach refusal, got {reached!r}')
match = re.match(r'^(.*):(\d+):(\d+)$', reached[0])
if not match or pathlib.Path(match.group(1)).name != source.name or int(match.group(2)) != sites[0]:
    raise SystemExit(f'FAIL: expected reached site {label} at {source.name}:{sites[0]}, got {reached[0]}')
print(f'pool reach: {label} at {source.name}:{sites[0]}')
PY
}

if ! build_compiler "$WORK/compiler$EXE" "$WORK/compiler.log"; then
  echo 'FAIL: native compiler tool did not build'; cat "$WORK/compiler.log"; exit 1
fi
check_fixture "$corpus" "$corpus" corpus || exit 1
check_fixture "$branch" "$branch" branch || exit 1
reach_is "$WORK/branch.refusals" live_else || exit 1

# A broken compiler build or interrupted probe is invalid, not a caught mutant.
# The check returns nonzero only after the mutant compiled and the exact Assign
# site's placement changed from the already-checked as-written to unproven.
check_assign_mutation() {
  if ! build_compiler "$WORK/mutant$EXE" "$WORK/mutant.build"; then
    echo 'INVALID: mutant compiler did not build'; cat "$WORK/mutant.build"; return 2
  fi
  local rc=0
  native_probe "$WORK/mutant$EXE" "$corpus" "$WORK/mutant-result" > "$WORK/mutant.log" 2>&1 || rc=$?
  if [ "$rc" -gt 1 ] || [ ! -f "$WORK/mutant-result.names" ] || [ ! -f "$WORK/mutant-result.refusals" ]; then
    echo 'INVALID: mutant crashed or did not produce a complete sidecar'; tail -n 30 "$WORK/mutant.log"; return 2
  fi
  if "$PY" - "$(native_path "$corpus")" "$(native_path "$WORK/mutant-result.refusals")" <<'PY'
import pathlib, re, sys
source, refusals = map(pathlib.Path, sys.argv[1:])
lines = source.read_text().splitlines()
sites = [i for i, line in enumerate(lines, 1) if 'g.spawn { assigned.n }' in line]
if len(sites) != 1:
    raise SystemExit(1)
found = []
for line in refusals.read_text().splitlines():
    cols = line.split('\t')
    if len(cols) < 5 or cols[0] != 'spawn':
        continue
    match = re.match(r'^(.*):(\d+):(\d+)$', cols[1])
    if match and pathlib.Path(match.group(1)).name == source.name and int(match.group(2)) == sites[0]:
        found.append(cols[2])
if not found or any(item != 'unproven' for item in found):
    raise SystemExit(1)
print('mutant compiled and changed the Assign witness to unproven')
PY
  then
    return 1
  fi
  echo 'INVALID: mutant did not change the Assign site as expected'
  return 0
}
prove_mutation 'instance assignment witness removed' "$REPO/src/compiler/semantic/share.iyi" \
  '    note(node.target)' '    # assignment witness deliberately omitted' -- check_assign_mutation || exit 1

# A control is caught only if its compiler builds, its sidecar completes, and
# the reported reach moves to the exact site predicted by that mutation.
check_reach_mutation() {
  local wanted="$1" tag="$2"
  if ! build_compiler "$WORK/$tag-compiler$EXE" "$WORK/$tag.build"; then
    echo "INVALID: $tag compiler did not build"; cat "$WORK/$tag.build"; return 2
  fi
  local rc=0
  native_probe "$WORK/$tag-compiler$EXE" "$branch" "$WORK/$tag" > "$WORK/$tag.log" 2>&1 || rc=$?
  if [ "$rc" -gt 1 ] || [ ! -f "$WORK/$tag.names" ] || [ ! -f "$WORK/$tag.refusals" ]; then
    echo "INVALID: $tag crashed or did not produce a complete sidecar"; tail -n 30 "$WORK/$tag.log"; return 2
  fi
  if reach_is "$WORK/$tag.refusals" "$wanted"; then
    echo "compiled $tag mutant moved reach to $wanted"
    return 1
  fi
  echo "INVALID: $tag did not move reach to $wanted"
  return 0
}

prove_mutation 'pool reach visits the Nil-dead then arm' "$REPO/src/compiler/semantic/spawn_placement.iyi" \
  '  def visit(node : If) : Bool
    node.cond.accept(self)
    truth = static_truthiness(@visitor, node.cond)
    node.then.accept(self) unless truth == -1
    node.else.accept(self) unless truth == 1
    false
  end

  def visit(node : Path)' \
  '  def visit(node : If) : Bool
    node.cond.accept(self)
    truth = literal_truthiness(node.cond)
    node.then.accept(self) unless truth == -1
    node.else.accept(self) unless truth == 1
    false
  end

  def visit(node : Path)' -- check_reach_mutation dead_then reach-dead || exit 1

prove_mutation 'pool reach drops the live else arm' "$REPO/src/compiler/semantic/spawn_placement.iyi" \
  '  def visit(node : If) : Bool
    node.cond.accept(self)
    truth = static_truthiness(@visitor, node.cond)
    node.then.accept(self) unless truth == -1
    node.else.accept(self) unless truth == 1
    false
  end

  def visit(node : Path)' \
  '  def visit(node : If) : Bool
    node.cond.accept(self)
    truth = static_truthiness(@visitor, node.cond)
    node.then.accept(self) unless truth == -1
    node.else.accept(self) unless truth != 0
    false
  end

  def visit(node : Path)' -- check_reach_mutation nilable_then reach-else || exit 1
check_fixture "$process" "$REPO/src/std/process.iyi" process || exit 1
printf '%s\n' 'spawn Share placement: hosted/native comparisons and mutation passed'
