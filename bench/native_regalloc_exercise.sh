#!/usr/bin/env bash
# The register allocation gate (SPEC 2.2 step 4, SPEC 3.5; slice C3c).
# Every host emits the native_cg and native_regalloc fixtures under pin and
# linear, compares repeated linear objects, and reports per-fixture spills.
# macOS arm64 additionally links and runs both allocators against hosted twins,
# checks the libSystem floor and signatures, and exercises runtime mutations.
# Both collector-constraint refusal mutations run on every host.
#
#   bench/native_regalloc_exercise.sh
#
# The selfhost Linux x86_64, macOS arm64 and Windows x86_64 jobs run this gate.
set -u
cd "$(dirname "$0")/.." || exit 1
. bench/lib/host.sh || exit 1
require_test_host || exit 1
if [ -z "$PY" ]; then
  echo "a functional Python interpreter is required" >&2
  exit 1
fi
if [ "$HOST_OS" = darwin ]; then
  export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"$PATH"
  export LIBRARY_PATH=${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}
fi
head=$(git rev-parse HEAD) || exit 1
printf 'checked-out HEAD: %s\nPython: %s\n' "$head" "$(command -v "$PY")"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/native-regalloc.XXXXXX") || exit 1
RESTORE_FILE=""
RESTORE_BACKUP=""
restore_source() {
  if [ -n "$RESTORE_FILE" ]; then
    if ! cp "$RESTORE_BACKUP" "$RESTORE_FILE"; then
      echo "FAIL: could not restore $RESTORE_FILE; backup kept at $RESTORE_BACKUP" >&2
      return 1
    fi
    RESTORE_FILE=""
    RESTORE_BACKUP=""
  fi
}
cleanup() {
  restore_source || return 1
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

failed=0
fail() { echo "FAIL: $*"; failed=1; }
. bench/lib/native_signature.sh
export NATIVE_SIGNATURE_FAILURE_FILE="$WORK/signature-failure"

FIX_CG=bench/fixtures/native_cg
FIX_RA=bench/fixtures/native_regalloc
DRV="$WORK/native_cg$EXE"
build_driver() {
  ./bin/iyi build -o "$(native_path "$1")" "$(native_path src/compiler/tools/native_cg.iyi)" \
    >"$WORK/build.$(basename "$1").log" 2>&1
}

echo "== 1. build the driver with the hosted compiler"
if ! build_driver "$DRV"; then
  cat "$WORK/build.$(basename "$DRV").log"
  fail "the driver does not build"
  echo "== SOME REGISTER ALLOCATION CHECKS FAILED"
  exit 1
fi
printf 'driver: %s\n' "$(native_path "$DRV")"
if [ "$HOST_OS" = darwin ]; then
  file "$DRV" || fail "could not identify the driver executable"
fi

echo "== 2. the driver links only libSystem on Darwin"
if [ "$HOST_OS" = darwin ]; then
  if libs=$(otool -L "$DRV"); then
    libs=$(printf '%s\n' "$libs" | sed -n '2,$p' | sed 's/^[[:space:]]*//; s/ (.*//')
    bad=$(printf '%s\n' "$libs" | grep -v '^/usr/lib/libSystem.B.dylib$' | grep -v '^$' || true)
    if [ -z "$libs" ] || [ -n "$bad" ]; then
      printf '%s\n' "$libs"
      fail "the driver's Darwin dependencies are not limited to libSystem"
    else
      echo "links: $(printf '%s' "$libs" | tr '\n' ' ')"
    fi
  else
    fail "could not inspect the driver's Darwin dependencies"
  fi
else
  host_limited "the libSystem floor is a Darwin property; the codegen gate inspects this driver's native platform floor"
fi

# A nonzero driver exit is a refusal (1); missing input or output is invalid (2).
emit_obj() {
  local drv=$1 alloc=$2 ir=$3 obj=$4 log=$5 native_ir native_obj
  [ -f "$ir" ] && [ -x "$drv" ] || return 2
  native_ir=$(native_path "$ir") || return 2
  native_obj=$(native_path "$obj") || return 2
  rm -f "$obj" || return 2
  if IYI_NATIVE_REGALLOC=$alloc "$drv" obj "$native_ir" "$native_obj" >"$log" 2>&1; then
    :
  else
    case $? in
      126|127) echo "driver could not be executed" >>"$log"; return 2 ;;
      *) return 1 ;;
    esac
  fi
  if [ ! -s "$obj" ]; then
    echo "driver succeeded without producing a nonempty object: $obj" >>"$log"
    return 2
  fi
}

fixture_key() {
  printf '%s.%s\n' "$(basename "$(dirname "$1")")" "$(basename "$1" .ir)"
}

# Keep the Perl alarm while distinguishing a killed process from one that
# legitimately exits 142. Return 1 for an alarm and 2 for a launch/wait error.
bounded_run() {
  local exe=$1 prefix=$2 status
  rm -f "$prefix.timeout" "$prefix.exec-error" "$prefix.done" || return 2
  perl -e '
    my ($timeout, $error, $done, $exe) = @ARGV;
    my $pid = fork();
    defined($pid) or die "fork: $!";
    if ($pid == 0) {
      alarm 20;
      exec { $exe } $exe;
      open my $fh, ">", $error or die "exec and error marker failed: $!";
      print $fh "exec failed: $!\n";
      close $fh or die "error marker: $!";
      exit 127;
    }
    my $waited = waitpid($pid, 0);
    my $status = $?;
    $waited == $pid or die "waitpid: $!";
    if (($status & 127) == 14) {
      open my $fh, ">", $timeout or die "timeout marker: $!";
      close $fh or die "timeout marker: $!";
    }
    open my $fh, ">", $done or die "completion marker: $!";
    close $fh or die "completion marker: $!";
    exit (($status & 127) ? 128 + ($status & 127) : $status >> 8);
  ' "$prefix.timeout" "$prefix.exec-error" "$prefix.done" "$exe" </dev/null >"$prefix.out" 2>/dev/null
  status=$?
  echo "$status" >"$prefix.status" || return 2
  [ -e "$prefix.done" ] && [ ! -e "$prefix.exec-error" ] || return 2
  [ ! -e "$prefix.timeout" ] || return 1
  return 0
}

# Link and run an emitted object on macOS arm64. Link and signature errors
# have distinct statuses so they cannot be credited as mutation detections.
run_obj() {
  local obj=$1 prefix=$2 result
  [ -s "$obj" ] || return 2
  cc "$obj" bench/fixtures/native_cg/rt_stub.c -o "$prefix.bin" >"$prefix.link.log" 2>&1 || return 3
  native_signature_ok "$prefix.bin" || return 4
  bounded_run "$prefix.bin" "$prefix"
  result=$?
  case "$result" in
    0) return 0 ;;
    1) echo "native execution timed out: $prefix"; return 5 ;;
    *) echo "native execution could not start or be observed: $prefix"; return 6 ;;
  esac
}

native_run() {
  local drv=$1 alloc=$2 ir=$3 prefix=$4 result
  emit_obj "$drv" "$alloc" "$ir" "$prefix.o" "$prefix.obj.log"
  result=$?
  [ "$result" -eq 0 ] || return "$result"
  run_obj "$prefix.o" "$prefix"
}

echo "== 3. emit every fixture under pin and linear"
fixture_count=0
emitted=0
for dir in "$FIX_CG" "$FIX_RA"; do
  dir_count=0
  for ir in "$dir"/*.ir; do
    [ -f "$ir" ] || continue
    dir_count=$((dir_count + 1))
    fixture_count=$((fixture_count + 1))
    key=$(fixture_key "$ir")
    for alloc in pin linear; do
      prefix="$WORK/$key.$alloc"
      if emit_obj "$DRV" "$alloc" "$ir" "$prefix.o" "$prefix.obj.log"; then
        emitted=$((emitted + 1))
        echo "emitted: $key $alloc"
      else
        cat "$prefix.obj.log" 2>/dev/null || true
        fail "$key: $alloc did not emit a nonempty object"
      fi
    done
  done
  [ "$dir_count" -gt 0 ] || fail "no fixtures found in $dir"
done
echo "emission totals: $emitted/$((fixture_count * 2)) objects from $fixture_count fixtures"

echo "== 3b. compare macOS arm64 execution with hosted twins"
executed=0
if [ "$HOST_ID" = darwin-arm64 ]; then
  for tool in cc perl file; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      fail "required runtime tool is missing: $tool"
      exit 1
    fi
  done
  for dir in "$FIX_CG" "$FIX_RA"; do
    for ir in "$dir"/*.ir; do
      [ -f "$ir" ] || continue
      base=$(basename "$ir" .ir)
      key=$(fixture_key "$ir")
      iy="$dir/$base.iyi"
      hosted="$WORK/$key.hosted$EXE"
      if [ ! -f "$iy" ]; then
        fail "$ir has no equivalent $iy"
        continue
      fi
      if ! ./bin/iyi build -o "$(native_path "$hosted")" "$(native_path "$iy")" >"$WORK/$key.hosted.log" 2>&1; then
        cat "$WORK/$key.hosted.log"
        fail "$key: the hosted compiler does not build the twin"
        continue
      fi
      file "$hosted" || fail "$key: could not identify the hosted executable"
      if ! bounded_run "$hosted" "$WORK/expect.$key"; then
        rm -f "$WORK/expect.$key.out" "$WORK/expect.$key.status"
        fail "$key: hosted execution timed out or could not be observed"
        continue
      fi
      printf 'hosted %s stdout (status %s):\n' "$key" "$(cat "$WORK/expect.$key.status")"
      cat "$WORK/expect.$key.out"
      printf '\n'
      for alloc in pin linear; do
        prefix="$WORK/$key.$alloc"
        if ! run_obj "$prefix.o" "$prefix"; then
          cat "$prefix.link.log" 2>/dev/null || true
          fail "$key: $alloc object could not be linked, signed, or run"
          continue
        fi
        file "$prefix.bin" || fail "$key: could not identify the $alloc executable"
        printf '%s %s stdout (status %s; strict signature passed):\n' "$key" "$alloc" "$(cat "$prefix.status")"
        cat "$prefix.out"
        printf '\n'
        if cmp -s "$prefix.out" "$WORK/expect.$key.out" &&
           cmp -s "$prefix.status" "$WORK/expect.$key.status"; then
          executed=$((executed + 1))
          echo "matched: $key $alloc"
        else
          fail "$key: the $alloc program differs from the hosted twin"
        fi
      done
    done
  done
  echo "execution totals: $executed/$((fixture_count * 2)) native comparisons"
else
  host_limited "Darwin objects are emitted but not linked or executed on $HOST_ID"
  echo "execution totals: 0/$((fixture_count * 2)) native comparisons (macOS arm64 only)"
fi

# Both independently emitted objects must exist before their bytes are compared.
echo "== 4. the linear allocator is deterministic"
det_fixtures=0
det_equal=0
for ir in "$FIX_RA"/*.ir; do
  [ -f "$ir" ] || continue
  det_fixtures=$((det_fixtures + 1))
  base=$(basename "$ir" .ir)
  first=0
  second=0
  if emit_obj "$DRV" linear "$ir" "$WORK/det1.$base.o" "$WORK/det1.$base.log"; then
    first=1
  else
    cat "$WORK/det1.$base.log" 2>/dev/null || true
  fi
  if emit_obj "$DRV" linear "$ir" "$WORK/det2.$base.o" "$WORK/det2.$base.log"; then
    second=1
  else
    cat "$WORK/det2.$base.log" 2>/dev/null || true
  fi
  if [ "$first" -eq 1 ] && [ "$second" -eq 1 ] &&
     cmp -s "$WORK/det1.$base.o" "$WORK/det2.$base.o"; then
    det_equal=$((det_equal + 1))
    echo "deterministic: $base"
  else
    fail "$base: two successful nonempty linear objects did not match"
  fi
done
[ "$det_fixtures" -gt 0 ] || fail "no register fixtures for determinism"
echo "determinism totals: $det_equal/$det_fixtures register fixtures"

echo "== 5. spill slots per fixture: the linear allocator uses no more than the reference"
# Prints the reference comparison and writes one "<fixture> <function> <slots>" row per linear function to $2.
# Returns 1 when linear spills more than the reference, 2 when a fixture cannot be measured.
spill_report() {
  local drv=$1 counts=$2 native_drv native_fixtures native_counts
  native_drv=$(native_path "$drv") || return 2
  native_fixtures=$(native_path "$FIX_RA") || return 2
  native_counts=$(native_path "$counts") || return 2
  "$PY" - "$native_drv" "$native_fixtures" "$native_counts" <<'PY'
import os
import re
import subprocess
import sys

drv, fixdir, counts_path = sys.argv[1], sys.argv[2], sys.argv[3]
names = sorted(name for name in os.listdir(fixdir)
               if name.endswith(".ir") and os.path.isfile(os.path.join(fixdir, name)))
bad = []
errors = []
strictly_fewer = 0
reported = 0
reference_total = 0
linear_total = 0
rows = []
if not names:
    errors.append(f"no register fixtures in {fixdir}")
for name in names:
    path = os.path.join(fixdir, name)
    base = name[:-3]
    with open(path, encoding="utf-8") as source:
        funcs = re.findall(r"^define [^@\n]*@([^\s(]+)\(", source.read(), re.M)
    if not funcs:
        errors.append(f"{name}: no functions found")
        print(f"{base}: spill slots INVALID")
        continue
    totals = {}
    per_function = {}
    for alloc in ("pin", "linear"):
        total = 0
        valid = True
        per_function[alloc] = []
        for fn in funcs:
            env = dict(os.environ, IYI_NATIVE_REGALLOC=alloc)
            try:
                out = subprocess.run([drv, "mir", path, fn], env=env,
                                     capture_output=True, text=True)
            except OSError as exc:
                errors.append(f"{name} {alloc} {fn}: could not run {drv}: {exc}")
                valid = False
                continue
            if out.returncode != 0:
                errors.append(f"{name} {alloc} {fn}: driver exited {out.returncode}: {out.stderr.strip()}")
                valid = False
                continue
            matches = re.findall(r"\bslots=(\d+)\b", out.stdout)
            if len(matches) != 1:
                errors.append(f"{name} {alloc} {fn}: expected one slots= value, found {len(matches)}")
                valid = False
                continue
            total += int(matches[0])
            per_function[alloc].append((fn, int(matches[0])))
        if valid:
            totals[alloc] = total
    if len(totals) != 2:
        print(f"{base}: spill slots INVALID")
        continue
    pin, lin = totals["pin"], totals["linear"]
    reported += 1
    reference_total += pin
    linear_total += lin
    rows.extend(f"{base} {fn} {count}" for fn, count in per_function["linear"])
    if lin < pin:
        strictly_fewer += 1
        verdict = "fewer"
    elif lin == pin:
        verdict = "NOT FEWER (equal; reason: the reference already spills nothing here)" if pin == 0 else "NOT FEWER (equal; reason: no interval fits a register it could not already reach)"
    else:
        verdict = "MORE"
        bad.append(base)
    print(f"{base}: spill slots reference={pin} linear={lin} ({verdict})")
print(f"spill totals: {reported}/{len(names)} fixtures; strictly fewer on {strictly_fewer}")
print(f"spill slot totals: reference={reference_total} linear={linear_total}")
with open(counts_path, "w", encoding="utf-8") as counts:
    for row in rows:
        counts.write(row + "\n")
for error in errors:
    print("INVALID: " + error)
if errors:
    sys.exit(2)
if bad:
    print("MORE SPILLS: " + " ".join(bad))
    sys.exit(1)
PY
}

# The table is exact: every measured function has one row with its count, and every row names a measured function.
check_slot_table() {
  "$PY" - "$(native_path "$1")" "$(native_path "$2")" <<'PY'
import re
import sys
from pathlib import Path


def rows(path, label):
    result = {}
    for number, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        fields = line.split()
        if len(fields) != 3 or not re.fullmatch(r"[0-9]+", fields[2]):
            raise ValueError(f"{label} line {number} is not '<fixture> <function> <slots>'")
        key = (fields[0], fields[1])
        if key in result:
            raise ValueError(f"{label} line {number} repeats {fields[0]} {fields[1]}")
        result[key] = int(fields[2])
    return result


try:
    measured = rows(sys.argv[1], "measured")
    table = rows(sys.argv[2], "table")
except (OSError, UnicodeError, ValueError) as exc:
    print(f"INVALID SLOT TABLE: {exc}")
    sys.exit(2)
bad = False
for fixture, fn in sorted(measured.keys() - table.keys()):
    print(f"MISSING ROW: {fixture} {fn} has no row in the table")
    bad = True
for fixture, fn in sorted(table.keys() - measured.keys()):
    print(f"STALE ROW: {fixture} {fn} names no measured function")
    bad = True
for fixture, fn in sorted(measured.keys() & table.keys()):
    spills, allowed = measured[(fixture, fn)], table[(fixture, fn)]
    if spills > allowed:
        print(f"MORE SLOTS: {fixture} {fn} spills {spills}, the table allows {allowed}")
        bad = True
    elif spills < allowed:
        print(f"LOWER THE CEILING: {fixture} {fn} spills {spills}, the table has {allowed}")
        bad = True
if bad:
    sys.exit(1)
print(f"slot table: {len(measured)} functions match the table exactly")
PY
}

slot_counts="$WORK/linear-slots.txt"
slot_report=$(spill_report "$DRV" "$slot_counts")
slot_status=$?
echo "$slot_report"
[ "$slot_status" -eq 0 ] || fail "spill report is invalid or linear spills more than pin"
echo "== 5b. the linear spill table is exact: every function, at its measured count"
check_slot_table "$slot_counts" "$FIX_RA/linear_slots.ceiling" || fail "the linear spill table does not match the measured spills"

# Each direction of the table is proven on a temporary copy, so no compiler change is needed to see it reject.
prove_table_case() {
  local name=$1 table=$2 expected=$3 log status
  log="$WORK/table-proof.$RANDOM.log"
  check_slot_table "$slot_counts" "$table" >"$log" 2>&1
  status=$?
  if [ "$status" -ne 1 ]; then
    cat "$log"
    fail "table proof '$name' was not rejected"
    return
  fi
  if grep -Fq "$expected" "$log"; then
    grep -F "$expected" "$log"
    echo "decisive: table proof '$name'"
  else
    cat "$log"
    fail "table proof '$name' was rejected for another reason"
  fi
}
awk 'BEGIN { done = 0 } !done && $3 > 0 { $3 = $3 - 1; done = 1 } { print }' "$FIX_RA/linear_slots.ceiling" >"$WORK/table-lowered.txt" || fail "could not write a table copy"
prove_table_case "lowered row" "$WORK/table-lowered.txt" "MORE SLOTS:"
awk 'NR == 1 { $3 = $3 + 1 } { print }' "$FIX_RA/linear_slots.ceiling" >"$WORK/table-raised.txt" || fail "could not write a table copy"
prove_table_case "raised row" "$WORK/table-raised.txt" "LOWER THE CEILING:"
awk 'NR > 1 { print }' "$FIX_RA/linear_slots.ceiling" >"$WORK/table-missing.txt" || fail "could not write a table copy"
prove_table_case "missing row" "$WORK/table-missing.txt" "MISSING ROW:"
{ cat "$FIX_RA/linear_slots.ceiling"; echo "stale_fixture stale_function 0"; } >"$WORK/table-stale.txt" || fail "could not write a table copy"
prove_table_case "stale row" "$WORK/table-stale.txt" "STALE ROW:"

# A mutant that still spills fewer than the reference passes the reference comparison, so the table alone judges it.
check_slot_mutant() {
  local drv=$1 counts="$WORK/mutant-slots.txt" report status
  report=$(spill_report "$drv" "$counts")
  status=$?
  echo "$report"
  case "$status" in
    0) ;;
    1) echo "decisive: the reference comparison already rejects this mutant"; return 1 ;;
    *) return 2 ;;
  esac
  echo "decisive: the reference comparison passes this mutant"
  check_slot_table "$counts" "$FIX_RA/linear_slots.ceiling"
  status=$?
  case "$status" in
    0) return 0 ;;
    1) echo "decisive: the exact table rejects this mutant"; return 1 ;;
    *) return 2 ;;
  esac
}

# A check returns 0 for a passing driver, 1 for a detected mutation, and 2 for
# invalid setup. Each pristine predicate must pass before its mutant is built.
mutate() {
  local source=$1 destination=$2
  shift 2
  "$PY" - "$(native_path "$source")" "$(native_path "$destination")" "$@" <<'PY'
import sys
from pathlib import Path

path, out = sys.argv[1], sys.argv[2]
pairs = sys.argv[3:]
if not pairs or len(pairs) % 2:
    print("mutation requires OLD NEW pairs")
    sys.exit(2)
data = Path(path).read_bytes()
for old, new in zip(pairs[0::2], pairs[1::2]):
    old_bytes, new_bytes = old.encode("utf-8"), new.encode("utf-8")
    hits = data.count(old_bytes)
    if hits != 1:
        print(f"the text must occur exactly once (found {hits}): {old[:70]!r}")
        sys.exit(2)
    if old_bytes == new_bytes:
        print("PATCH CHANGED NOTHING")
        sys.exit(3)
    data = data.replace(old_bytes, new_bytes, 1)
Path(out).write_bytes(data)
PY
}

mutation_total=0
mutation_caught=0
prove_mutation() {
  # prove_mutation NAME FILE CHECK OLD NEW [OLD NEW ...]
  local name=$1 file=$2 check=$3 backup mut log result
  shift 3
  mutation_total=$((mutation_total + 1))
  log="$WORK/mutation.$mutation_total.log"
  if [ -e "$NATIVE_SIGNATURE_FAILURE_FILE" ]; then
    fail "mutation $name: a prior native signature check failed"
    return
  fi
  if ! "$check" "$DRV" >"$log" 2>&1; then
    cat "$log"
    fail "mutation $name: pristine driver did not pass its predicate"
    return
  fi
  backup="$WORK/backup.$mutation_total"
  if ! cp "$file" "$backup"; then
    fail "mutation $name: could not back up the original source"
    return
  fi
  RESTORE_FILE="$file"
  RESTORE_BACKUP="$backup"
  if ! mutate "$file" "$WORK/mutated.src" "$@"; then
    fail "mutation $name: the mutation could not be applied"
    restore_source || exit 1
    return
  fi
  if ! cp "$WORK/mutated.src" "$file"; then
    fail "mutation $name: could not install the mutant"
    restore_source || exit 1
    return
  fi
  mut="$WORK/mutant.$RANDOM$EXE"
  if ! build_driver "$mut"; then
    cat "$WORK/build.$(basename "$mut").log"
    fail "mutation $name: the mutant does not build, so it proves nothing"
    restore_source || exit 1
    return
  fi
  if ! "$mut" forms >"$WORK/mutant.$mutation_total.forms" 2>&1 ||
     [ ! -s "$WORK/mutant.$mutation_total.forms" ]; then
    cat "$WORK/mutant.$mutation_total.forms"
    fail "mutation $name: the mutant driver cannot run its independent forms command"
    restore_source || exit 1
    return
  fi
  "$check" "$mut" >"$log" 2>&1
  result=$?
  restore_source || exit 1
  if [ -e "$NATIVE_SIGNATURE_FAILURE_FILE" ]; then
    cat "$log"
    fail "mutation $name: a native executable failed signature verification"
  elif [ "$result" -eq 1 ]; then
    cat "$log"
    mutation_caught=$((mutation_caught + 1))
    echo "caught: $name"
  elif [ "$result" -eq 0 ]; then
    fail "mutation $name: NOT caught"
  else
    cat "$log"
    fail "mutation $name: invalid predicate or setup"
  fi
}

check_fixture_output() {
  local drv=$1 ir=$2 key prefix result
  [ -f "$ir" ] || { echo "missing fixture: $ir"; return 2; }
  key=$(fixture_key "$ir")
  prefix="$WORK/mut.$key"
  if [ ! -f "$WORK/expect.$key.out" ] || [ ! -f "$WORK/expect.$key.status" ]; then
    echo "missing hosted result for $key"
    return 2
  fi
  native_run "$drv" linear "$ir" "$prefix"
  result=$?
  case "$result" in
    0) ;;
    1) echo "native backend refused $key"; cat "$prefix.obj.log"; return 1 ;;
    5) echo "native execution timed out for $key"; return 1 ;;
    *) echo "invalid native execution for $key (status $result)"; cat "$prefix.link.log" 2>/dev/null || true; return 2 ;;
  esac
  for result in out status; do
    cmp -s "$prefix.$result" "$WORK/expect.$key.$result"
    case $? in
      0) ;;
      1) return 1 ;;
      *) echo "could not compare $result for $key"; return 2 ;;
    esac
  done
  return 0
}

# Preserve the complete combined corpus and both original pointer predicates.
check_linear_outputs() {
  local drv=$1 dir ir seen=0 result
  for dir in "$FIX_CG" "$FIX_RA"; do
    for ir in "$dir"/*.ir; do
      [ -f "$ir" ] || continue
      seen=$((seen + 1))
      check_fixture_output "$drv" "$ir"
      result=$?
      [ "$result" -eq 0 ] || return "$result"
    done
  done
  [ "$seen" -gt 0 ] || return 2
}
check_pointer_output() {
  check_fixture_output "$1" "$FIX_RA/pointer_fp_call.ir"
}
check_pointer_flag_output() {
  check_fixture_output "$1" "$FIX_RA/pointer_flag_fp.ir"
}

# A collector mutant is caught only by the named refusal, not by an unrelated
# driver or setup error. On macOS retain the original pointer predicate too.
check_collector() {
  local drv=$1 ir=$2 pointer_check=$3 prefix result pointer_result
  prefix="$WORK/collector.$(basename "$ir" .ir)"
  emit_obj "$drv" linear "$ir" "$prefix.o" "$prefix.obj.log"
  result=$?
  if [ "$result" -eq 0 ]; then
    if [ "$HOST_ID" = darwin-arm64 ]; then
      "$pointer_check" "$drv" || return 2
    fi
    return 0
  fi
  if [ "$result" -ne 1 ] ||
     ! grep -Fq "regalloc: collector constraint: a pointer-carrying value" "$prefix.obj.log"; then
    echo "collector check failed without the collector-constraint refusal"
    cat "$prefix.obj.log" 2>/dev/null || true
    return 2
  fi
  if [ "$HOST_ID" = darwin-arm64 ]; then
    "$pointer_check" "$drv"
    pointer_result=$?
    if [ "$pointer_result" -ne 1 ] ||
       ! grep -Fq "regalloc: collector constraint: a pointer-carrying value" "$WORK/mut.$(fixture_key "$ir").obj.log"; then
      echo "original pointer predicate did not observe the collector refusal"
      return 2
    fi
  fi
  grep -F "regalloc: collector constraint: a pointer-carrying value" "$prefix.obj.log"
  return 1
}
check_pointer_collector() {
  check_collector "$1" "$FIX_RA/pointer_fp_call.ir" check_pointer_output
}
check_pointer_flag_collector() {
  check_collector "$1" "$FIX_RA/pointer_flag_fp.ir" check_pointer_flag_output
}

# Require a dying arithmetic source to share its result, a predecessor's
# phi copy to disappear, and no identity copies to reach the encoder.
check_coalescing() {
  local drv=$1 out="$WORK/coalescing.mir"
  [ -x "$drv" ] || return 2
  if ! "$drv" mir "$FIX_RA/diamond.ir" pick >"$out" 2>&1; then
    echo "could not emit the coalescing fixture"
    return 2
  fi
  "$PY" - "$out" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
if not text.startswith("function pick\n"):
    print("invalid MIR for coalescing")
    sys.exit(2)
identity = re.search(r"^  (?:Mov|FMov)/64f? (x\d+|d\d+), \1$", text, re.M)
shared = re.search(r"^  AddImm/64 (x\d+), \1 #imm=1$", text, re.M)
then = re.search(r"^block 1 then\n(.*?)(?=^block )", text, re.M | re.S)
join = re.search(r"^block 3 join\n(.*)", text, re.M | re.S)
if then is None or join is None:
    print("invalid diamond MIR blocks")
    sys.exit(2)
phi = re.search(r"^  Eor/64 (x\d+),[^\n]*\n  B/64", then.group(1), re.M)
merged = re.search(r"^  Add/64 (x\d+), (x\d+),", join.group(1), re.M)
if identity or not shared or not phi or not merged or phi.group(1) != merged.group(2):
    print("coalescing or identity removal is missing")
    sys.exit(1)
print("coalescing: dying source and phi copy share a register; no identity moves")
PY
}

# This direct MIR fixture has a lower-numbered free register at the copy. Only
# the copy preference gives the result its source's register.
check_copy_hint() {
  local ignored=$1 exe="$WORK/copy-hint-$RANDOM$EXE" line
  if ! ./bin/iyi build -o "$(native_path "$exe")" "$(native_path "$FIX_RA/copy_hint.iyi")" >"$WORK/copy-hint.log" 2>&1; then
    cat "$WORK/copy-hint.log"
    return 2
  fi
  if ! line=$("$exe"); then
    echo "copy hint fixture could not run"
    return 2
  fi
  "$PY" - "$line" <<'PY'
import sys
try:
    source, dest, count = map(int, sys.argv[1].split())
except ValueError:
    print("invalid copy hint fixture output")
    sys.exit(2)
if source < 0 or source != dest or count != 4:
    print("copy preference did not coalesce the source and destination")
    sys.exit(1)
print("copy preference: source and destination share a register")
PY
}

# The fall-through edge keeps v live through carry. The selector ends every block it emits for a reachable IR block
# with a terminator, so no IR fixture reaches the edge. This hand-built MIR does: carry falls into use, which reads v.
# Without the edge, w takes v's register inside carry.
check_fallthrough_liveness() {
  local ignored=$1 exe="$WORK/fallthrough-liveness-$RANDOM$EXE"
  if ! ./bin/iyi build -o "$(native_path "$exe")" "$(native_path "$FIX_RA/fallthrough_liveness.iyi")" \
       >"$WORK/fallthrough-liveness.log" 2>&1; then
    cat "$WORK/fallthrough-liveness.log"
    return 2
  fi
  if ! "$exe" >"$WORK/fallthrough-liveness.mir" 2>&1; then
    cat "$WORK/fallthrough-liveness.mir"
    echo "the fall-through liveness fixture could not run"
    return 2
  fi
  "$PY" - "$(native_path "$WORK/fallthrough-liveness.mir")" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
if not text.startswith("function fallthrough\n"):
    print("INVALID: not the fall-through fixture's MIR")
    sys.exit(2)
blocks = {}
number = None
for line in text.splitlines():
    match = re.match(r"^block (\d+) (\S+)$", line)
    if match:
        number = int(match.group(1))
        blocks[number] = (match.group(2), [])
    elif number is not None and line.startswith("  "):
        blocks[number][1].append(line.strip())
if [blocks.get(i, ("", []))[0] for i in range(4)] != ["entry", "carry", "use", "definer"]:
    print("INVALID: the fall-through fixture's blocks changed")
    sys.exit(2)
carry, reader, definer = blocks[1][1], blocks[2][1], blocks[3][1]
terminators = ("B/", "Bcond/", "Cbz/", "Cbnz/", "Tbz/", "Tbnz/", "Ret/", "BrTable/", "Brk/")
made = re.match(r"^MovImm/64 (x\d+) #imm=9$", carry[0]) if carry else None
written = re.match(r"^MovImm/64 (x\d+) #imm=7$", definer[0]) if definer else None
read = re.match(r"^AddImm/64 x\d+, (x\d+) #imm=1$", reader[0]) if reader else None
if (not (made and written and read) or carry[-1].startswith(terminators)
        or not reader[-1].startswith("Ret/") or definer[-1] != "B/64 target=1"):
    print("INVALID: the fall-through fixture lost its shape")
    sys.exit(2)
w, v = made.group(1), read.group(1)
if written.group(1) != v:
    print(f"decisive: v has two homes, {written.group(1)} in definer and {v} in use")
    sys.exit(1)
if w == v:
    print(f"decisive: w and v share {v}; v is live through carry only by the fall-through edge")
    sys.exit(1)
print(f"fall-through liveness: v is {v} in definer and use; w is {w} in carry")
PY
}

check_fpr_frame() {
  local ignored=$1 exe="$WORK/fpr-frame-$RANDOM$EXE" values
  if ! ./bin/iyi build -o "$(native_path "$exe")" "$(native_path "$FIX_RA/fpr_frame_probe.iyi")" >"$WORK/fpr-frame.log" 2>&1; then
    cat "$WORK/fpr-frame.log"
    return 2
  fi
  if ! values=$("$exe" "$(native_path "$FIX_RA/fp_callee_saved.ir")"); then
    echo "invalid FPR frame probe"
    return 2
  fi
  "$PY" - "$values" <<'PY'
import sys
try:
    expected, saved, missing, returns, asm_d9, frame = map(int, sys.argv[1].split())
except ValueError:
    print("invalid FPR frame probe output")
    sys.exit(2)
if not expected & 2 or not asm_d9 or returns < 2 or frame % 16:
    print("FPR fixture lacks an asm d9 definition, aligned frame, or two returns")
    sys.exit(2)
if expected & ~saved or missing:
    print("a physically defined callee-saved FPR is missing a save or restore")
    sys.exit(1)
print("FPR frame: all physical definitions saved and restored")
PY
}

check_fpr_output() {
  check_fixture_output "$1" "$FIX_RA/fp_callee_saved.ir"
}

check_typed_float_load() {
  local drv=$1 out="$WORK/fp-load-call.mir"
  if ! "$drv" mir "$FIX_RA/fp_load_call.ir" loaded >"$out" 2>&1; then
    echo "invalid typed floating-load MIR"
    return 2
  fi
  "$PY" - "$out" <<'PY'
import re
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
if not text.startswith("function loaded\n") or "  Bl/" not in text:
    print("invalid loaded-double fixture")
    sys.exit(2)
before, after = text.split("  Bl/", 1)
load = re.search(r"^  Ldr/64f (d(?:8|9|1[0-5])),", before, re.M)
if (not load or re.search(r"^  (?:StrFrame|LdrFrame)/64f", text, re.M)
        or not re.search(r"^  FAdd/64f \w+, " + load.group(1) + r",", after, re.M)):
    print("typed floating load was not kept in a callee-saved FPR")
    sys.exit(1)
print("typed floating load stays in a callee-saved FPR across the call")
PY
}

check_typed_abi_fprs() {
  local drv=$1 param="$WORK/fp-param-call.mir" result="$WORK/fp-result-call.mir"
  if ! "$drv" mir "$FIX_RA/fp_param_call.ir" parameter >"$param" 2>&1 ||
     ! "$drv" mir "$FIX_RA/fp_result_call.ir" result >"$result" 2>&1; then
    echo "invalid typed ABI FPR MIR"
    return 2
  fi
  "$PY" - "$param" "$result" <<'PY'
import re
import sys
from pathlib import Path
for path, name, before_calls in ((sys.argv[1], "parameter", 0), (sys.argv[2], "result", 1)):
    text = Path(path).read_text()
    if not text.startswith("function " + name + "\n"):
        print("invalid typed ABI FPR fixture")
        sys.exit(2)
    pieces = text.split("  Bl/")
    if len(pieces) <= before_calls + 1:
        print("missing required call")
        sys.exit(2)
    copy = re.search(r"^  FMov/64f (d(?:8|9|1[0-5])), d0$", pieces[before_calls], re.M)
    if (not copy or re.search(r"^  (?:StrFrame|LdrFrame)/64f", text, re.M)
            or not re.search(r"^  Fcvtzs/64f \w+, " + copy.group(1), pieces[before_calls + 1], re.M)):
        print(name + " did not retain its typed FPR across the call")
        sys.exit(1)
print("typed FPR parameter and call result stay in callee-saved registers")
PY
}

check_typed_fpr_provenance() {
  local ignored=$1 exe="$WORK/typed-provenance-$RANDOM$EXE" values
  if ! ./bin/iyi build -o "$(native_path "$exe")" "$(native_path "$FIX_RA/fpr_typed_provenance.iyi")" >"$WORK/typed-provenance.log" 2>&1; then
    cat "$WORK/typed-provenance.log"
    return 2
  fi
  values=$("$exe") || return 2
  "$PY" - "$values" <<'PY'
import sys
try:
    pointer, select, phi, arithmetic, load, constant, conversion = map(int, sys.argv[1].split())
except ValueError:
    print("invalid typed provenance fixture output")
    sys.exit(2)
if (pointer, select, phi) != (-1, -1, -1) or any(not 40 <= r <= 47 for r in (arithmetic, load, constant, conversion)):
    print("typed floating provenance did not distinguish bit copies from numeric values")
    sys.exit(1)
print("pointer copies and selects spill; typed float results keep callee-saved FPRs")
PY
}

check_asm_callee_saved() {
  local drv=$1 prefix="$WORK/asm-callee" result
  [ -f "$WORK/expect.native_cg.asm_clobber.out" ] || return 2
  native_run "$drv" linear "$FIX_CG/asm_clobber.ir" "$prefix"
  result=$?
  [ "$result" -eq 0 ] || return 2
  cmp -s "$prefix.status" "$WORK/expect.native_cg.asm_clobber.status" || return 2
  if ! cmp -s "$prefix.out" "$WORK/expect.native_cg.asm_clobber.out"; then
    echo "callee clobber changed the caller's output"
    return 1
  fi
  echo "callee-saved asm clobber preserves the caller's output"
}

check_pointer_boundary() {
  local drv=$1 name=$2 boundary=$3 out="$WORK/$2.boundary.mir"
  if ! "$drv" mir "$FIX_RA/$name.ir" hold >"$out" 2>&1; then
    echo "invalid pointer boundary MIR"
    return 2
  fi
  "$PY" - "$out" "$boundary" <<'PY'
import re
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
if not text.startswith("function hold\n"):
    print("invalid pointer boundary function")
    sys.exit(2)
lines = text.splitlines()
marker = "  Bl/" if sys.argv[2] == "call" else "  InlineAsm/"
where = next((i for i, line in enumerate(lines) if line.startswith(marker)), None)
if where is None:
    print("missing collector boundary")
    sys.exit(2)
before, after = "\n".join(lines[:where]), "\n".join(lines[where + 1:])
pattern = r"FMov/64f (d\d+), d0" if sys.argv[2] == "call" else r"FMovToFp/64 (d\d+),"
source = re.search(pattern, before)
store = re.search(r"StrFrame/64f (d\d+), (slot\d+\+0)", before)
if (not source or not store or source.group(1) != store.group(1)
        or not re.search(r"LdrFrame/64f \w+, " + re.escape(store.group(2)), after)
        or source.group(1) in {f"d{x}" for x in range(8, 16)}):
    print("possible pointer was not spilled across the collector boundary")
    sys.exit(1)
print("possible pointer spilled across collector boundary")
PY
}
check_fixed_pointer() {
  check_pointer_boundary "$1" pointer_fixed_asm call
}
check_asm_boundary() {
  check_pointer_boundary "$1" asm_collector_boundary asm
}

check_fixed_staging() {
  local drv=$1 prefix="$WORK/staged-pin" result
  [ -f "$WORK/expect.native_regalloc.fixed_staging.out" ] || return 2
  native_run "$drv" pin "$FIX_RA/fixed_staging.ir" "$prefix"
  result=$?
  [ "$result" -eq 0 ] || return 2
  cmp -s "$prefix.status" "$WORK/expect.native_regalloc.fixed_staging.status" || return 2
  if ! cmp -s "$prefix.out" "$WORK/expect.native_regalloc.fixed_staging.out"; then
    echo "staged physical operands were clobbered"
    return 1
  fi
  echo "staged physical operands retain both inputs"
}

check_dead_spills() {
  local ignored=$1 exe="$WORK/dead-spills-$RANDOM$EXE" result
  if ! ./bin/iyi build -o "$(native_path "$exe")" "$(native_path "$FIX_RA/dead_spills.iyi")" >"$WORK/dead-spills.log" 2>&1; then
    cat "$WORK/dead-spills.log"
    return 2
  fi
  result=$("$exe") || return 2
  case "$result" in
    0) echo "unused definitions have no spill stores"; return 0 ;;
    *[!0-9]*|'') echo "invalid dead-spill count"; return 2 ;;
    *) echo "unused definitions emitted $result spill stores"; return 1 ;;
  esac
}

check_odd_fpr_frame() {
  local ignored=$1 exe="$WORK/fpr-odd-$RANDOM$EXE" result
  if ! ./bin/iyi build -o "$(native_path "$exe")" "$(native_path "$FIX_RA/fpr_odd_frame.iyi")" >"$WORK/fpr-odd.log" 2>&1; then
    cat "$WORK/fpr-odd.log"
    return 2
  fi
  result=$("$exe") || return 2
  case "$result" in
    "16 1 1") echo "one saved FPR retains a 16-byte aligned frame"; return 0 ;;
    *[!0-9\ ]*|'') echo "invalid odd-FPR frame result"; return 2 ;;
    *) echo "odd-FPR frame is unaligned or lacks save/restore"; return 1 ;;
  esac
}

check_spill_weights() {
  local ignored=$1 exe="$WORK/spill-weights-$RANDOM$EXE" values
  if ! ./bin/iyi build -o "$(native_path "$exe")" "$(native_path "$FIX_RA/spill_weights.iyi")" >"$WORK/spill-weights.log" 2>&1; then
    cat "$WORK/spill-weights.log"
    return 2
  fi
  if ! values=$("$exe"); then
    echo "spill weight fixture could not run"
    return 2
  fi
  "$PY" - "$values" <<'PY'
import sys
try:
    hot, cold, nested_hot, warm, cycle_hot, cycle_cold = map(int, sys.argv[1].split())
except ValueError:
    print("invalid spill weight fixture output")
    sys.exit(2)
if hot < 0 or cold != -1 or nested_hot < 0 or warm != -1 or cycle_hot < 0 or cycle_cold != -1:
    print("a hotter interval spilled instead of a colder one")
    sys.exit(1)
print("spill weights: hot and inner-loop values stay in registers")
PY
}

check_reload_reuse() {
  local ignored=$1 exe="$WORK/reload-reuse-$RANDOM$EXE" values
  if ! ./bin/iyi build -o "$(native_path "$exe")" "$(native_path "$FIX_RA/reload_reuse.iyi")" >"$WORK/reload-reuse.log" 2>&1; then
    cat "$WORK/reload-reuse.log"
    return 2
  fi
  if ! values=$("$exe"); then
    echo "reload reuse fixture could not run"
    return 2
  fi
  "$PY" - "$values" <<'PY'
import sys
try:
    gpr_loads, defined, used, fpr_loads, copies_loads, reset_loads, asm_loads = map(int, sys.argv[1].split())
except ValueError:
    print("invalid reload reuse fixture output")
    sys.exit(2)
if (gpr_loads, fpr_loads, copies_loads, reset_loads, asm_loads) != (3, 3, 2, 1, 4) or defined != used:
    print("reload reuse or invalidation is incorrect")
    sys.exit(1)
print("reload reuse: GPR and FPR caches respect redefinitions and clobbers")
PY
}

echo "== 6. mutation proofs"
prove_mutation "floating ABI: flag typed parameters and call results" \
  src/compiler/native/regalloc_linear.iyi check_typed_abi_fprs \
  '                if @fn.vreg_classes[v] == RegClass::Fpr && is_role?(@fn.isa, inst, Role::Copy) && src.reg >= 32 && src.reg < 64 && (typed_fixed & (1_u64 << src.reg)) != 0_u64 # typed-fixed-fpr' \
  '                if false && @fn.vreg_classes[v] == RegClass::Fpr && is_role?(@fn.isa, inst, Role::Copy) && src.reg >= 32 && src.reg < 64 && (typed_fixed & (1_u64 << src.reg)) != 0_u64 # typed-fixed-fpr'
prove_mutation "floating arithmetic: flag numeric results as possible pointers" \
  src/compiler/native/target.iyi check_typed_fpr_provenance \
  '    return op == MOp::FAdd || op == MOp::FSub || op == MOp::FMul || op == MOp::FDiv ||' \
  '    return false if op == MOp::FAdd
    return op == MOp::FAdd || op == MOp::FSub || op == MOp::FMul || op == MOp::FDiv ||'
prove_mutation "collector: lose pointer provenance through integer selects" \
  src/compiler/native/regalloc_linear.iyi check_typed_fpr_provenance \
  '                     (@fn.vreg_classes[v] == RegClass::Gpr && bitwise_gpr_value?(@fn.isa, inst))' \
  '                     false' \
  '          elsif !unknown && ((@fn.vreg_classes[v] == RegClass::Fpr && typed_fpr_value?(@fn.isa, inst)) || integer_literal?(@fn.isa, inst))' \
  '          elsif !unknown && ((@fn.vreg_classes[v] == RegClass::Fpr && typed_fpr_value?(@fn.isa, inst)) || @fn.vreg_classes[v] == RegClass::Gpr)'
prove_mutation "floating load: flag typed memory values as possible pointers" \
  src/compiler/native/target.iyi check_typed_float_load \
  '    return true if op == MOp::Ldr || op == MOp::LdrFrame # typed-fpr-load' \
  '    return false if op == MOp::Ldr || op == MOp::LdrFrame # typed-fpr-load'
prove_mutation "reload reuse: retain GPR scratch across inline asm" \
  src/compiler/native/regalloc_linear.iyi check_reload_reuse \
  '      gprs.each { |r| cache[r] = -1 } # asm-clears-scratch-cache' \
  '      gprs.each { |r| cache[r] = cache[r] } # asm-clears-scratch-cache'
prove_mutation "reload reuse: retain FPR scratch across inline asm" \
  src/compiler/native/regalloc_linear.iyi check_reload_reuse \
  '      fprs.each { |r| cache[r] = -1 }' \
  '      fprs.each { |r| cache[r] = cache[r] }'
prove_mutation "collector: trust an unknown fixed FPR source" \
  src/compiler/native/regalloc_linear.iyi check_fixed_pointer \
  '                unknown = true # fixed-fpr-provenance-unknown' \
  '                safe_roots << v # fixed-fpr-provenance-unknown'
prove_mutation "collector: ignore inline asm as a collector boundary" \
  src/compiler/native/regalloc_linear.iyi check_asm_boundary \
  '        @call_prefix[p + 1] = @call_prefix[p] + (inst.call || !inst.asm.nil? ? 1 : 0) # collector-boundary' \
  '        @call_prefix[p + 1] = @call_prefix[p] + (inst.call ? 1 : 0) # collector-boundary'
prove_mutation "spill: store values with no virtual uses" \
  src/compiler/native/regalloc_linear.iyi check_dead_spills \
  '        stores << slot_access(fn.isa, false, reg, fn.vreg_slot[v], fp) if has_use[v] # skip-unused-spill-store' \
  '        stores << slot_access(fn.isa, false, reg, fn.vreg_slot[v], fp) # skip-unused-spill-store'
prove_mutation "reload reuse: retain scratch cache across blocks" \
  src/compiler/native/regalloc_linear.iyi check_reload_reuse \
  '  fn.blocks.each do |block|
    rewrite_block(fn, block, has_use)' \
  '  cache = int_row(64, -1)
  fn.blocks.each do |block|
    rewrite_block(fn, block, has_use, cache)' \
  'def rewrite_block(fn : MFunction, block : MBlock, has_use : Array(Bool)) : Nil' \
  'def rewrite_block(fn : MFunction, block : MBlock, has_use : Array(Bool), cache : Array(Int32)) : Nil' \
  '  cache = int_row(64, -1)
  gprs = scratch_gprs' \
  '  gprs = scratch_gprs'
prove_mutation "floating-point frame: remove one matched d9 save and restore" \
  src/compiler/native/frame.iyi check_fpr_frame \
  '    acc << m
    i = i + 1' \
  '    acc << m unless m.fp && f.callee_saved[i] == 41
    i = i + 1' \
  '        acc << m
        i = i + 1' \
  '        acc << m unless m.fp && f.callee_saved[i] == 41
        i = i + 1'
prove_mutation "floating-point frame: restore FPRs from the wrong offsets" \
  src/compiler/native/frame.iyi check_fpr_frame \
  '        m.imm = f.saves_offset + 8_i64 * i.to_i64' \
  '        m.imm = f.saves_offset + 8_i64 * i.to_i64 + 8_i64'
prove_mutation "floating-point frame: omit alignment for an odd save" \
  src/compiler/native/frame.iyi check_odd_fpr_frame \
  '  f.frame_size = round_up(offset, stack_align)' \
  '  f.frame_size = offset'
if [ "$HOST_ID" = darwin-arm64 ]; then
  prove_mutation "asm: do not save the caller's x19 before a callee clobbers it" \
    src/compiler/native/frame.iyi check_asm_callee_saved \
    '    acc << m
    i = i + 1' \
    '    acc << m unless fn.name == "clobbered" && f.callee_saved[i] == 19
    i = i + 1'
  prove_mutation "spill reload: overwrite a staged physical operand" \
    src/compiler/native/regalloc_linear.iyi check_fixed_staging \
    '    blocked = fixed[index] # protect-staged-physical' \
    '    blocked = 0_u64 # protect-staged-physical'
else
  host_limited "runtime mutation: staged physical operands (macOS arm64)"
fi
prove_mutation "reload reuse: reload each use instead of reusing a scratch register" \
  src/compiler/native/regalloc_linear.iyi check_reload_reuse \
  '    return r if cache[r] == v && (blocked & mask) == 0_u64' \
  '    return r if false && cache[r] == v && (blocked & mask) == 0_u64'
prove_mutation "reload reuse: ignore explicit physical definitions" \
  src/compiler/native/regalloc_linear.iyi check_reload_reuse \
  '        cache[op.reg] = -1 # physical-def-invalidates-reload' \
  '        cache[op.reg] = cache[op.reg] # physical-def-invalidates-reload'
prove_mutation "reload reuse: ignore call clobbers" \
  src/compiler/native/regalloc_linear.iyi check_reload_reuse \
  '      cache[reg] = -1 if reg >= 0 && reg < 64 # call-clobber-invalidates-reload' \
  '      cache[reg] = cache[reg] if reg >= 0 && reg < 64 # call-clobber-invalidates-reload'
prove_mutation "reload reuse: discard unrelated cached values after a redefinition" \
  src/compiler/native/regalloc_linear.iyi check_reload_reuse \
  '          cache[r] = -1 if r != reg && cache[r] == v' \
  '          cache[r] = -1 if r != reg'
prove_mutation "spill weights: evict by furthest end instead of weight" \
  src/compiler/native/regalloc_linear.iyi check_spill_weights \
  '      cheaper = @weights[a] < @weights[iv] || (@weights[a] == @weights[iv] && @ends[a] > @ends[iv])' \
  '      cheaper = @ends[a] > @ends[iv]'
prove_mutation "spill weights: discard nesting depth" \
  src/compiler/native/regalloc_linear.iyi check_spill_weights \
  '    depth[v] = (owner[v] >= 0 ? depth[owner[v]] : 0) + (header[v] ? 1 : 0)' \
  '    depth[v] = header[v] || owner[v] >= 0 ? 1 : 0'
prove_mutation "spill weights: mistake irreducible edges for natural backedges" \
  src/compiler/native/regalloc_linear.iyi check_spill_weights \
  '      if dfs_ancestor?(number, last, s, b) && dfs_ancestor?(dom[0], dom[1], s, b)' \
  '      if dfs_ancestor?(number, last, s, b)'
prove_mutation "linear: liveness drops the fall-through successor" \
  src/compiler/native/regalloc_linear.iyi check_fallthrough_liveness \
  '  if falls && b + 1 < fn.blocks.size' \
  '  if false && falls && b + 1 < fn.blocks.size'
prove_mutation "linear slots: keep uses live through every definition (more spills than the table allows)" \
  src/compiler/native/regalloc_linear.iyi check_slot_mutant \
  '        use_end = distinct_inputs_and_defs?(@fn.isa, inst) ? pos + 1 : pos' \
  '        use_end = pos + 1'
prove_mutation "floating-point frame: omit callee-saved FPR stores" \
  src/compiler/native/frame.iyi check_fpr_frame \
  '    acc << m
    i = i + 1' \
  '    acc << m unless m.fp
    i = i + 1'
prove_mutation "floating-point frame: omit the FPR restore on the early return" \
  src/compiler/native/frame.iyi check_fpr_frame \
  '        acc << m
        i = i + 1' \
  '        acc << m unless m.fp && block.name == "negative"
        i = i + 1'
prove_mutation "coalescing: ignore virtual-register copy hints" \
  src/compiler/native/regalloc_linear.iyi check_copy_hint \
  '    preferred = @homes[other] if other >= 0 && @homes[other] >= 0' \
  '    preferred = -1 if other >= 0 && @homes[other] >= 0'
prove_mutation "coalescing: keep uses live through every definition" \
  src/compiler/native/regalloc_linear.iyi check_coalescing \
  '        use_end = distinct_inputs_and_defs?(@fn.isa, inst) ? pos + 1 : pos' \
  '        use_end = pos + 1'
prove_mutation "coalescing: retain identity copies" \
  src/compiler/native/regalloc_linear.iyi check_coalescing \
  '    acc << inst unless identity' \
  '    acc << inst'
if [ "$HOST_ID" = darwin-arm64 ]; then
  prove_mutation "linear: a register is given to an interval that overlaps an active one" \
    src/compiler/native/regalloc_linear.iyi check_linear_outputs \
    '      return reg unless held?(reg) || reserved?(reg, @starts[iv], @ends[iv])' \
    '      return reg unless reserved?(reg, @starts[iv], @ends[iv])'
  prove_mutation "rewrite: a spilled operand is read without its reload" \
    src/compiler/native/regalloc_linear.iyi check_linear_outputs \
    '          reloads << slot_access(fn.isa, true, reg, fn.vreg_slot[v], fp)' \
    '        # the reload is dropped'
  prove_mutation "linear: a value that crosses a call may take a caller-saved register" \
    src/compiler/native/regalloc_linear.iyi check_linear_outputs \
    '      return @callee_pool' \
    '      return @caller_pool + @callee_pool'
  prove_mutation "floating-point call: assign a caller-saved register across the call" \
    src/compiler/native/regalloc_linear.iyi check_fpr_output \
    '        return @callee_fpr_pool' \
    '        return @fpr_pool'
  prove_mutation "collector: a floating-point value across a call may take an fp register, and the assertion is off" \
    src/compiler/native/regalloc_linear.iyi check_pointer_output \
    '        return [] of Int32 if @pointer[iv]' \
    '        return @fpr_pool if @pointer[iv]' \
    '        if fp && @crossing[v] && @pointer[v]' \
    '        if false && fp && @crossing[v] && @pointer[v]'
else
  host_limited "runtime mutation: overlapping active intervals share a register (macOS arm64)"
  host_limited "runtime mutation: a spilled operand's reload is dropped (macOS arm64)"
  host_limited "runtime mutation: a call-crossing value takes a caller-saved register (macOS arm64)"
  host_limited "runtime mutation: a floating-point pointer crosses a call with the assertion disabled (macOS arm64)"
fi
prove_mutation "collector: a floating-point value across a call may take an fp register; the assertion catches it" \
  src/compiler/native/regalloc_linear.iyi check_pointer_collector \
  '        return [] of Int32 if @pointer[iv]' \
  '        return @callee_fpr_pool if @pointer[iv]'
prove_mutation "collector: a flagged value may take a floating-point register across a call; the assertion catches it" \
  src/compiler/native/regalloc_linear.iyi check_pointer_flag_collector \
  '        return [] of Int32 if @pointer[iv]' \
  '        return @callee_fpr_pool if @pointer[iv]'
if [ "$HOST_ID" = darwin-arm64 ]; then
  prove_mutation "linear: a value live into a block that starts with a call is not counted as crossing it" \
    src/compiler/native/regalloc_linear.iyi check_linear_outputs \
    '        cross = @call_prefix[@ends[v]] - @call_prefix[@starts[v]] > 0' \
    '        cross = @call_prefix[@ends[v]] - @call_prefix[@starts[v] + 1] > 0'
else
  host_limited "runtime mutation: a value live into a call-headed block is not counted as crossing (macOS arm64)"
fi
echo "mutation totals: $mutation_caught/$mutation_total detected"
echo "a mutation that changes nothing is refused by the proof helper:"
[ ! -e "$NATIVE_SIGNATURE_FAILURE_FILE" ] || fail "a native executable failed signature verification"
mutate src/compiler/native/regalloc_linear.iyi "$WORK/noop.src" \
  'def member?(list : Array(Int32), x : Int32) : Bool' 'def member?(list : Array(Int32), x : Int32) : Bool' >"$WORK/noop.log" 2>&1
noop_result=$?
if [ "$noop_result" -eq 3 ] && grep -Fq 'PATCH CHANGED NOTHING' "$WORK/noop.log"; then
  echo "refused: the same text on both sides"
else
  cat "$WORK/noop.log"
  fail "the proof helper did not specifically reject the no-op mutation"
fi

echo
if [ "$failed" -eq 0 ]; then
  echo "== ALL REGISTER ALLOCATION CHECKS PASSED"
  exit 0
fi
echo "== SOME REGISTER ALLOCATION CHECKS FAILED"
exit 1
