#!/usr/bin/env bash
# The typed pipeline, one program at a time (SPEC 2.1, S3): the tool built from source with
# `--pipeline typed` (src/compiler/compiler.iyi `compile_typed`, src/compiler/lower/program.iyi),
# measured against the hosted compiler on the fixtures the four lowering gates read.
#
# For each fixture (bench/fixtures/lower_*, lowcall_*, lowprim_*, lowglob_*):
#   - the tool runs with --probe-phase and reaches a phase: parse, declarations, bodies, lower,
#     verify, native, link. A refusal names its phase on stdout and exits 1 with no output file.
#   - a fixture that reaches link is run; its stdout and exit status must equal the hosted
#     executable (built with --prelude empty, except lowglob_cvar_lazy which uses the
#     lowglob_abi prelude). That is run-equal.
#   - a fixture that reaches link and differs is a failure. A refused fixture must exit nonzero
#     and write no output.
# The floor (bench/selfhost_pipeline.floor) records the phase each fixture reaches. A phase may
# only rise; SELFHOST_PIPELINE_RAISE=1 writes the measured phases. The rows under ROOTS are the
# prelude programs and the compiler's own tools, measured with --prelude and the iyi prelude on
# IYI_PATH; they are recorded and must not fall.
#
# Mutation proofs patch the tool's own code (the typed branch, the program assembly, the tool's
# refusal path), rebuild the tool, and require the check to fail. prove_mutation refuses a patch
# that changes nothing.
#
#   bash bench/selfhost_pipeline_exercise.sh
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if [ -z "$PY" ]; then
  echo "  FAIL: a functional Python interpreter is required for fixture termination status" >&2
  exit 1
fi
REPO_NATIVE="$(native_path "$REPO")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
. "$REPO/bench/floor_base.sh" || exit 1
IYI="$REPO/bin/iyi"
. "$REPO/bench/lib/mutation.sh"
. "$REPO/bench/lib/pipeline_report.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/iyi-pipeline.XXXXXX")" || exit 1
ARTIFACT_DIR="${PIPELINE_ARTIFACT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/iyi-pipeline-artifacts.XXXXXX")}"
mkdir -p "$ARTIFACT_DIR"
echo "  table sidecars: $ARTIFACT_DIR"
trap 'rm -rf "$WORK"' EXIT
WORK_NATIVE="$(native_path "$WORK")" || exit 1
CAN_RUN_MACHO=0
if [ "$HOST_OS" = darwin ] && [ "$HOST_ARCH" = arm64 ]; then
  CAN_RUN_MACHO=1
else
  host_limited "selfhost_pipeline: arm64 Mach-O execution, signature checks, and run-equal floors require macOS arm64; cross-host emission and IR checks remain enabled"
fi
FLOOR="$REPO/bench/selfhost_pipeline.floor"
TOOL_SRC="$REPO/src/compiler/tools/compile_native.iyi"
PROGRAM_SRC="$REPO/src/compiler/lower/program.iyi"
LOWER_SRC="$REPO/src/compiler/lower/lower.iyi"
COMPILER_SRC="$REPO/src/compiler/compiler.iyi"
LOADER_SRC="$REPO/src/compiler/loader.iyi"
ROOTS="samples/iyi/hello.iyi src/compiler/tools/parse.iyi src/compiler/tools/compile_native.iyi"

# The compile_native closure reached 31,025 defs and exceeded 64 GB on 2026-11-15.
# Keep it on hosts with headroom; smaller CI runners still exercise hello and parse.
ROOT_MIN_GB="${SELFHOST_PIPELINE_ROOT_MIN_GB:-96}"
if [ -n "${SELFHOST_PIPELINE_HOST_GB:-}" ]; then
  HOST_GB="$SELFHOST_PIPELINE_HOST_GB"
elif [ "$HOST_OS" = darwin ]; then
  HOST_GB="$({ /usr/sbin/sysctl -n hw.memsize 2>/dev/null || sysctl -n hw.memsize; } | awk '{printf "%.0f", int($1 / 1073741824)}')"
elif [ "$HOST_OS" = windows ]; then
  HOST_GB="$(powershell.exe -NoProfile -NonInteractive -Command '[math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)' | tr -d '\r\n')"
else
  HOST_GB="$(awk '/^MemTotal:/ {printf "%.0f", int($2 / 1048576); found=1} END {if (!found) exit 1}' /proc/meminfo)"
fi
case "$HOST_GB:$ROOT_MIN_GB" in
  *[!0-9:]*|:*|*:) echo "FAIL: cannot determine valid host or required memory in GB" >&2; exit 1 ;;
esac
SKIP_COMPILE_NATIVE=0
[ "$HOST_GB" -lt "$ROOT_MIN_GB" ] && SKIP_COMPILE_NATIVE=1
COMPILE_NATIVE_ROOT="src/compiler/tools/compile_native.iyi"

rank() {
  case "$1" in
    none) echo 0 ;; parse) echo 1 ;; declarations) echo 2 ;; bodies) echo 3 ;; lower) echo 4 ;;
    verify) echo 5 ;; native) echo 6 ;; link) echo 7 ;; run-equal) echo 8 ;; *) echo -1 ;;
  esac
}

# The phase a tool probe reached: the last `reached:` line. A refusal that exits the process (refuse_port)
# prints no `reached:` line, so the last passed phase is read instead.
probe_phase() {
  awk '/^reached:/ { r = $2; found = 1 } /^\[phase\] [a-z]+: pass$/ { p = $2; sub(":", "", p) } END { if (found) print r; else print p }' "$1"
}

# Builds the host executable at $2$EXE. A failed hosted build is never a
# caught mutation; keep the actual compiler diagnostics.
build_tool() {
  if ! "$IYI" build -o "$(native_path "$2$EXE")" "$(native_path "$1")" > "$2.build.log" 2>&1; then
    echo "  INVALID: hosted build failed for $1" >&2
    cat "$2.build.log" >&2
    return 2
  fi
}

# A shell status alone cannot distinguish exit 145 from signal 17 or a
# deliberate exit 124 from timeout. Record the child termination separately.
run_fixture() {
  local executable="$1" stem="$2" seconds="${RUN_FIXTURE_TIMEOUT:-30}"
  shift 2
  RUN_KIND=error
  RUN_STATUS=
  if ! "$PY" - "$(native_path "$executable")" "$(native_path "$WORK/$stem")" "$seconds" "$@" <<'PY'
import os
import signal
import subprocess
import sys

executable, stem, seconds = sys.argv[1:4]
with open(stem + ".out", "wb") as out, open(stem + ".err", "wb") as err:
    try:
        child = subprocess.Popen([executable] + sys.argv[4:], stdout=out, stderr=err,
                                 start_new_session=(os.name != "nt"))
        try:
            rc = child.wait(timeout=float(seconds))
            result = f"exit {rc}" if rc >= 0 else f"signal {-rc}"
        except subprocess.TimeoutExpired:
            if os.name == "nt":
                child.kill()
            else:
                os.killpg(child.pid, signal.SIGKILL)
            child.wait()
            result = "timeout"
    except OSError as exc:
        result = f"error {exc}"
# newline="\n": Windows' text mode would end the line "\r\n", and `read` keeps the "\r" in the status.
with open(stem + ".status", "w", encoding="utf-8", newline="\n") as status_file:
    print(result, file=status_file)
PY
  then
    echo "  INVALID: fixture runner failed for $executable" >&2
    return 1
  fi
  read -r RUN_KIND RUN_STATUS <"$WORK/$stem.status"
  case "$RUN_KIND" in exit|signal|timeout) return 0 ;; esac
  echo "  INVALID: could not execute $executable: $(cat "$WORK/$stem.status")" >&2
  return 1
}

# Keep normal high statuses distinct from signals and timeouts in the runner
# itself, independently of any particular compiler fixture.
runner_python="$(command -v "$PY")"
for runner_exit in 124 127 145 230 255; do
  if ! run_fixture "$runner_python" "runner.exit.$runner_exit" -c \
      'import sys; sys.exit(int(sys.argv[1]))' "$runner_exit" ||
     [ "$RUN_KIND" != exit ] || [ "$RUN_STATUS" != "$runner_exit" ]; then
    echo "  FAIL: runner misclassified normal exit $runner_exit as $RUN_KIND $RUN_STATUS" >&2
    exit 1
  fi
done
if [ "$HOST_OS" != windows ]; then
  if ! run_fixture "$runner_python" runner.signal -c \
      'import os, signal; os.kill(os.getpid(), signal.SIGTERM)' ||
     [ "$RUN_KIND" != signal ] || [ "$RUN_STATUS" != 15 ]; then
    echo "  FAIL: runner did not identify SIGTERM ($RUN_KIND $RUN_STATUS)" >&2
    exit 1
  fi
fi
if ! RUN_FIXTURE_TIMEOUT=0.25 run_fixture "$runner_python" runner.timeout -c 'import time; time.sleep(5)' ||
   [ "$RUN_KIND" != timeout ]; then
  echo "  FAIL: runner did not identify timeout ($RUN_KIND $RUN_STATUS)" >&2
  exit 1
fi

echo "== 1. The tool builds from source with bin/iyi and links no LLVM"
if ! build_tool "$TOOL_SRC" "$WORK/tool"; then
  exit 1
fi
case "$HOST_OS" in
  darwin) otool -L "$WORK/tool$EXE" >"$WORK/dependencies.log" 2>&1 || { cat "$WORK/dependencies.log" >&2; exit 1; } ;;
  linux) readelf -d "$WORK/tool$EXE" >"$WORK/dependencies.log" 2>&1 || { cat "$WORK/dependencies.log" >&2; exit 1; } ;;
  windows)
    DUMPBIN="$(find_dumpbin || true)"
    [ -n "$DUMPBIN" ] || { echo "  FAIL: dumpbin is required for the dependency check" >&2; exit 1; }
    "$DUMPBIN" -nologo -dependents "$(native_path "$WORK/tool$EXE")" >"$WORK/dependencies.log" 2>&1 || { cat "$WORK/dependencies.log" >&2; exit 1; }
    ;;
esac
if grep -qi llvm "$WORK/dependencies.log"; then
  echo "  FAIL: the tool links LLVM"
  cat "$WORK/dependencies.log"
  exit 1
fi
echo "  the tool builds and links no LLVM"

echo
echo "== 2. Each fixture: the typed pipeline against the hosted executable"
: >"$WORK/measured"
record_phase() { printf '%s %s\n' "$1" "$2" >>"$WORK/measured"; }
measured_phase() {
  awk -v key="$1" '$1 == key { print $2; found=1; exit } END { if (!found) print "missing" }' "$WORK/measured"
}
run_equal=0
refused=0
failed=0
total=0
fixtures=""
for g in lower_ lowcall_ lowprim_ lowglob_; do
  for f in "$REPO"/bench/fixtures/${g}*.iyi; do
    [ "$(basename "$f")" = "lowglob_cvar_lazy_ir.iyi" ] && continue # Structural IR fixture, not a standalone program.
    [ -f "$f" ] && fixtures="$fixtures $f"
  done
done
for fixture in $fixtures; do
  name="$(basename "$fixture" .iyi)"
  rel="bench/fixtures/$name.iyi"
  total=$((total + 1))
  out="$WORK/$name$EXE"
  "$WORK/tool$EXE" "$(native_path "$fixture")" -o "$WORK_NATIVE/$name$EXE" --pipeline typed --probe-phase > "$WORK/$name.probe" 2> "$WORK/$name.err"
  ts=$?
  reached="$(probe_phase "$WORK/$name.probe")"
  if [ "$ts" -eq 0 ] && [ "$reached" = "link" ] && [ -f "$out" ]; then
    # A framework is a darwin link: another host's linker refuses `-framework`, so the hosted reference is built
    # where the typed executable runs. The typed pipeline's link above still counts on every host.
    if [ "$CAN_RUN_MACHO" -eq 0 ] && grep -q '^@\[Link(framework: ' "$fixture"; then
      host_limited "selfhost_pipeline: $name links a darwin framework; the hosted reference links on macOS arm64 only"
      echo "  $name: link (arm64 Mach-O execution not available on $HOST_ID)"
      record_phase "$rel" link; continue
    fi
    prelude=empty
    hosted_path="$REPO_NATIVE/src"
    if [ "$name" = lowglob_cvar_lazy ] || [ "$name" = lowglob_cvar_lazy_aggregate ]; then
      prelude=iyi/prelude
      path_sep=:
      [ "$HOST_OS" = windows ] && path_sep=';'
      hosted_path="$REPO_NATIVE/bench/fixtures/lowglob_abi$path_sep$hosted_path"
    fi
    if ! IYI_PATH="$hosted_path" "$IYI" build --prelude "$prelude" -o "$WORK_NATIVE/$name.hosted$EXE" "$(native_path "$fixture")" > "$WORK/$name.hosted.log" 2>&1; then
      echo "  $name: FAILED, the hosted compiler does not build the fixture"
      cat "$WORK/$name.hosted.log"
      failed=$((failed + 1)); record_phase "$rel" link; continue
    fi
    if [ "$CAN_RUN_MACHO" -eq 0 ]; then
      echo "  $name: link (arm64 Mach-O execution not available on $HOST_ID)"
      record_phase "$rel" link; continue
    fi
    if ! codesign -v --strict "$out" > /dev/null 2>&1; then
      echo "  $name: FAILED, native signature invalid"
      failed=$((failed + 1)); record_phase "$rel" link; continue
    fi
    run_fixture "$out" "$name.typed" || :
    tkind="$RUN_KIND"; tstat="$RUN_STATUS"
    run_fixture "$WORK/$name.hosted$EXE" "$name.hosted" || :
    hkind="$RUN_KIND"; hstat="$RUN_STATUS"
    if [ "$tkind" = exit ] && [ "$hkind" = exit ] &&
       pipeline_outputs_equal "$tstat" "$hstat" "$WORK/$name.typed.out" "$WORK/$name.hosted.out" &&
       cmp -s "$WORK/$name.typed.err" "$WORK/$name.hosted.err"; then
      echo "  $name: run-equal (status $hstat, stdout and stderr identical)"
      run_equal=$((run_equal + 1)); record_phase "$rel" run-equal
    else
      echo "  $name: FAILED, typed $tkind $tstat, hosted $hkind $hstat, or output differs"
      echo "  typed stdout/stderr:"; cat "$WORK/$name.typed.out" "$WORK/$name.typed.err"
      echo "  hosted stdout/stderr:"; cat "$WORK/$name.hosted.out" "$WORK/$name.hosted.err"
      failed=$((failed + 1)); record_phase "$rel" link
    fi
  elif [ "$ts" -eq 1 ] && [ "$reached" != "link" ] && [ ! -e "$out" ] &&
       { grep -q '^iyi-compile-native: ' "$WORK/$name.err" || port_refusal "$ts" "$WORK/$name.err"; }; then
    refusal="$(awk '/: fail: / { print; exit }' "$WORK/$name.probe" | cut -c1-140)"
    [ -z "$refusal" ] && refusal="$(awk 'NR==1' "$WORK/$name.err" | cut -c1-140)"
    echo "  $name: refused after $reached, exit $ts, no output: $refusal"
    refused=$((refused + 1)); record_phase "$rel" "${reached:-none}"
  else
    echo "  $name: FAILED, exit $ts, reached $reached, output file present: $([ -e "$out" ] && echo yes || echo no)"
    cat "$WORK/$name.probe" "$WORK/$name.err"
    failed=$((failed + 1)); record_phase "$rel" "${reached:-none}"
  fi
done
echo "  fixtures: $run_equal run-equal of $total, $refused refused with no output, $failed failed"

echo
echo "== 3. The prelude programs and the compiler's own tools: the phase each reaches"
for root in $ROOTS; do
  if [ "$SKIP_COMPILE_NATIVE" -eq 1 ] && [ "$root" = "$COMPILE_NATIVE_ROOT" ]; then
    echo "  SKIPPED by host: $root needs $ROOT_MIN_GB GB, this host has $HOST_GB GB"
    continue
  fi
  rel="$root"
  name="$(basename "$root" .iyi)"
  "$WORK/tool$EXE" "$REPO_NATIVE/$root" -o "$WORK_NATIVE/$name.root$EXE" --pipeline typed --prelude --probe-phase > "$WORK/$name.root.probe" 2> "$WORK/$name.root.err"
  root_status=$?
  rphase="$(probe_phase "$WORK/$name.root.probe")"
  refusal="$(pipeline_first_refusal "$WORK/$name.root.probe")"
  [ -n "$refusal" ] || refusal="$(awk 'NR==1 { print; exit }' "$WORK/$name.root.err")"
  echo "  $name strict: reached ${rphase:-none}: ${refusal:-no refusal}"
  if [ "$root_status" -eq 0 ] && [ "$rphase" = "link" ] && [ -e "$WORK/$name.root$EXE" ]; then
    if ! "$IYI" build -o "$WORK_NATIVE/$name.root.hosted$EXE" "$REPO_NATIVE/$root" > "$WORK/$name.root.hosted.log" 2>&1; then
      echo "  $root: FAILED, the hosted compiler does not build the root"
      cat "$WORK/$name.root.hosted.log"
      failed=$((failed + 1))
    elif [ "$CAN_RUN_MACHO" -eq 0 ]; then
      echo "  $root: link (arm64 Mach-O execution not available on $HOST_ID)"
    elif ! codesign -v --strict "$WORK/$name.root$EXE" > /dev/null 2>&1; then
      echo "  $root: FAILED, native signature invalid"
      failed=$((failed + 1))
    else
      run_fixture "$WORK/$name.root$EXE" "$name.root.typed" || :
      tkind="$RUN_KIND"; tstat="$RUN_STATUS"
      run_fixture "$WORK/$name.root.hosted$EXE" "$name.root.hosted" || :
      hkind="$RUN_KIND"; hstat="$RUN_STATUS"
      if [ "$tkind" = exit ] && [ "$hkind" = exit ] &&
         pipeline_outputs_equal "$tstat" "$hstat" "$WORK/$name.root.typed.out" "$WORK/$name.root.hosted.out" &&
         cmp -s "$WORK/$name.root.typed.err" "$WORK/$name.root.hosted.err"; then
        rphase="run-equal"
        echo "  $root: run-equal (status $hstat, stdout and stderr identical)"
      else
        echo "  $root: FAILED, typed $tkind $tstat, hosted $hkind $hstat, or output differs"
        echo "  typed stdout/stderr:"; cat "$WORK/$name.root.typed.out" "$WORK/$name.root.typed.err"
        echo "  hosted stdout/stderr:"; cat "$WORK/$name.root.hosted.out" "$WORK/$name.root.hosted.err"
        failed=$((failed + 1))
      fi
    fi
  elif [ "$root_status" -ne 1 ] || [ "$rphase" = "link" ] || [ -e "$WORK/$name.root$EXE" ] ||
       { ! grep -q '^iyi-compile-native: ' "$WORK/$name.root.err" && ! port_refusal "$root_status" "$WORK/$name.root.err"; }; then
    echo "  $root: FAILED, exit $root_status, reached ${rphase:-none}, or unexpected output"
    cat "$WORK/$name.root.probe" "$WORK/$name.root.err"
    failed=$((failed + 1))
  fi
  record_phase "$rel" "${rphase:-none}"
done

echo
echo "== 4. The floor: no phase falls"
if [ "${SELFHOST_PIPELINE_RAISE:-0}" = "1" ]; then
  : > "$FLOOR.new"
  echo "# selfhost pipeline floor: <repo file> <phase reached>. A phase may only rise." >> "$FLOOR.new"
  echo "# Raise with SELFHOST_PIPELINE_RAISE=1 bash bench/selfhost_pipeline_exercise.sh (keeps the higher phase)." >> "$FLOOR.new"
  cp "$WORK/measured" "$WORK/floor.rows"
  if [ "$SKIP_COMPILE_NATIVE" -eq 1 ]; then
    awk -v root="$COMPILE_NATIVE_ROOT" '$1 == root {print}' "$FLOOR" >>"$WORK/floor.rows"
  fi
  sort "$WORK/floor.rows" >"$WORK/floor.sorted"
  while read -r k keep; do
    prev="$(awk -v k="$k" '$1 == k { print $2 }' "$FLOOR" 2>/dev/null)"
    if [ -n "$prev" ] && [ "$(rank "$prev")" -gt "$(rank "$keep")" ]; then keep="$prev"; fi
    echo "$k $keep" >> "$FLOOR.new"
  done <"$WORK/floor.sorted"
  mv "$FLOOR.new" "$FLOOR"
  echo "  floor written: $(wc -l <"$WORK/measured" | awk '{print $1}') rows"
fi
floor_bad=0
while read -r key phase; do
  case "$key" in ""|\#*) continue ;; esac
  if [ "$SKIP_COMPILE_NATIVE" -eq 1 ] && [ "$key" = "$COMPILE_NATIVE_ROOT" ]; then continue; fi
  want=$(rank "$phase")
  # The recorded run-equal floor remains intact; on other kernels only its
  # link prerequisite is observable.
  if [ "$CAN_RUN_MACHO" -eq 0 ] && [ "$phase" = run-equal ]; then want=$(rank link); fi
  got_phase="$(measured_phase "$key")"
  got=$(rank "$got_phase")
  if [ "$got" -lt "$want" ]; then
    echo "  $key: FALLS below the floor ($got_phase < $phase)"
    floor_bad=$((floor_bad + 1))
  fi
done < "$FLOOR"
if [ "$floor_bad" -gt 0 ]; then
  status=1
else
  echo "  every host-applicable measured phase is at or above its floor"
fi
while read -r k measured_value; do
  if [ "$(rank "$measured_value")" -ge 0 ] && ! awk -v k="$k" '$1 == k { found = 1 } END { exit !found }' "$FLOOR" 2>/dev/null; then
    echo "  $k: not in the floor (raise the floor with SELFHOST_PIPELINE_RAISE=1)"
    status=1
  fi
done <"$WORK/measured"
# The rows the floor holds below what the program needs, each with the gap that stops it: an exact list. A listed
# file must measure exactly its listed phase, so one that rises fails until its row is removed here and its floor row
# raised (SELFHOST_PIPELINE_RAISE=1).
KNOWN="$REPO/bench/selfhost_pipeline.known"
while read -r key phase reason; do
  case "$key" in ""|\#*) continue ;; esac
  got_phase="$(measured_phase "$key")"
  if [ "$got_phase" != "$phase" ]; then
    echo "  $key: KNOWN AT $phase ($reason), now $got_phase: remove its row from bench/selfhost_pipeline.known and raise the floor"
    status=1
  fi
done < "$KNOWN"
if [ "$failed" -gt 0 ] || { [ "$CAN_RUN_MACHO" -eq 1 ] && [ "$run_equal" -eq 0 ]; }; then
  echo "  FAIL: $failed fixture(s) failed, $run_equal run-equal"
  status=1
fi

echo
echo "== 6. The refusal table: src/compiler/PIPELINE.md and its floor (SPEC 2.1, S3)"
TFLOOR="$REPO/bench/selfhost_pipeline_table.floor"
PIPE_MD="$REPO/src/compiler/PIPELINE.md"
# The count a table summary line carries under a key (defs-reached, defs-typed-clean), or nothing.
table_value() {
  awk -v n="$1" -v key="$2" '$1 == "table:" && $2 == n { for (i = 3; i <= NF; i++) if (index($i, key "=") == 1) { sub(key "=", "", $i); print $i } }' "$WORK/table.lines"
}
: > "$WORK/table.lines"
table_ok=1
for root in $ROOTS; do
  if [ "$SKIP_COMPILE_NATIVE" -eq 1 ] && [ "$root" = "$COMPILE_NATIVE_ROOT" ]; then
    echo "  SKIPPED by host: $root needs $ROOT_MIN_GB GB, this host has $HOST_GB GB"
    continue
  fi
  name="$(basename "$root" .iyi)"
  "$WORK/tool$EXE" "$REPO_NATIVE/$root" -o "$WORK_NATIVE/$name.table$EXE" --pipeline typed --prelude --probe-phase --keep-going > "$WORK/$name.table.probe" 2> "$WORK/$name.table.err"
  table_rc=$?
  if grep -q 'BUG:' "$WORK/$name.table.probe" "$WORK/$name.table.err" ||
     { [ "$table_rc" -eq 0 ] && [ ! -f "$WORK/$name.table$EXE" ]; } ||
     { [ "$table_rc" -eq 1 ] && { [ -e "$WORK/$name.table$EXE" ] || ! grep -q '^iyi-compile-native: ' "$WORK/$name.table.err"; }; } ||
     { [ "$table_rc" -ne 0 ] && [ "$table_rc" -ne 1 ]; }; then
    echo "  $root: invalid table probe (exit $table_rc)"
    cat "$WORK/$name.table.probe" "$WORK/$name.table.err"
    table_ok=0
  fi
  for sidecar in names refusals; do [ ! -f "$WORK/$name.table$EXE.$sidecar" ] || cp "$WORK/$name.table$EXE.$sidecar" "$ARTIFACT_DIR/"; done
  if [ -f "$WORK/$name.table$EXE.refusals" ]; then
    awk -F '\t' -v name="$name" '
      ($1 == "body" || $1 == "lowering") {
        rows++
        if ($2 == "top level") { root++; owners[$3]++ } else { defs[$2] = 1 }
      }
      END {
        for (d in defs) ndefs++
        printf "  %s keep-going: %d rows in %d defs, %d root sites\n", name, rows, ndefs, root
        for (owner in owners) printf "    root owner=%s sites=%d\n", owner, owners[owner]
      }' "$WORK/$name.table$EXE.refusals"
  fi
  awk '/^table:/' "$WORK/$name.table.probe" | sed "s#$REPO_NATIVE/##g" >> "$WORK/table.lines"
  if [ -z "$(table_value "$name" defs-reached)" ]; then
    echo "  $root: no table summary line (see $WORK/$name.table.probe)"
    table_ok=0
  fi
done
if [ "$SKIP_COMPILE_NATIVE" -eq 1 ]; then
  echo "  SKIPPED PIPELINE.md comparison and update: its table requires the full root run"
fi
if [ "$table_ok" -eq 1 ]; then
  if [ "$SKIP_COMPILE_NATIVE" -eq 1 ]; then
    :
  elif ! awk '/<!-- table:begin/ { b++ } END { exit b != 1 }' "$PIPE_MD"; then
    echo "  FAIL: src/compiler/PIPELINE.md has no single table block (markers missing)"
    status=1
  else
    {
      echo "<!-- table:begin: generated by bench/selfhost_pipeline_exercise.sh; do not edit by hand -->"
      echo '```text'
      awk '{ print }' "$WORK/table.lines"
      echo '```'
      echo "<!-- table:end -->"
    } > "$WORK/block.md"
    awk -v blk="$WORK/block.md" '
      /<!-- table:begin/ { while ((getline line < blk) > 0) print line; close(blk); skip = 1; next }
      /<!-- table:end -->/ { skip = 0; next }
      !skip { print }' "$PIPE_MD" > "$WORK/PIPELINE.new"
    if cmp -s "$WORK/PIPELINE.new" "$PIPE_MD"; then
      echo "  PIPELINE.md is current"
    elif [ "${SELFHOST_PIPELINE_RAISE:-0}" = "1" ]; then
      cp "$WORK/PIPELINE.new" "$PIPE_MD"
      echo "  PIPELINE.md written"
    else
      echo "  FAIL: src/compiler/PIPELINE.md is stale (SELFHOST_PIPELINE_RAISE=1 regenerates it)"
      status=1
    fi
  fi
  if [ "${SELFHOST_PIPELINE_RAISE:-0}" = "1" ]; then
    : > "$TFLOOR.new"
    echo "# selfhost pipeline table floor: <root> <defs reached by the body typer> <defs typed with no refusal> <defs lowered with no refusal>. A count may only rise. Raise with SELFHOST_PIPELINE_RAISE=1 bash bench/selfhost_pipeline_exercise.sh." >> "$TFLOOR.new"
    for root in $ROOTS; do
      if [ "$SKIP_COMPILE_NATIVE" -eq 1 ] && [ "$root" = "$COMPILE_NATIVE_ROOT" ]; then
        awk '$1 == "compile_native" {print}' "$TFLOOR" >> "$TFLOOR.new"
        continue
      fi
      name="$(basename "$root" .iyi)"
      r="$(table_value "$name" defs-reached)"
      c="$(table_value "$name" defs-typed-clean)"
      l="$(table_value "$name" defs-lowered-clean)"
      pr="$(awk -v n="$name" '$1 == n { print $2 }' "$TFLOOR" 2>/dev/null)"
      pc="$(awk -v n="$name" '$1 == n { print $3 }' "$TFLOOR" 2>/dev/null)"
      pl="$(awk -v n="$name" '$1 == n { print $4 }' "$TFLOOR" 2>/dev/null)"
      [ "${pr:-0}" -gt "$r" ] && r="$pr"
      [ "${pc:-0}" -gt "$c" ] && c="$pc"
      [ "${pl:-0}" -gt "${l:-0}" ] && l="$pl"
      echo "$name $r $c ${l:-0}" >> "$TFLOOR.new"
    done
    mv "$TFLOOR.new" "$TFLOOR"
    echo "  table floor written"
  fi
  tbad=0
  while read -r name fr fc fl; do
    case "$name" in ""|\#*) continue ;; esac
    if [ "$SKIP_COMPILE_NATIVE" -eq 1 ] && [ "$name" = compile_native ]; then continue; fi
    gr="$(table_value "$name" defs-reached)"
    gc="$(table_value "$name" defs-typed-clean)"
    gl="$(table_value "$name" defs-lowered-clean)"
    if [ "${gr:-0}" -lt "$fr" ] || [ "${gc:-0}" -lt "$fc" ] || [ "${gl:-0}" -lt "${fl:-0}" ]; then
      echo "  $name: table count FALLS below the floor (reached ${gr:-none} < $fr, clean ${gc:-none} < $fc or lowered ${gl:-none} < ${fl:-0})"
      tbad=$((tbad + 1))
    fi
  done < "$TFLOOR"
  if [ "$tbad" -gt 0 ]; then
    status=1
  else
    echo "  table counts are at or above the floor"
  fi
else
  echo "  FAIL: a root printed no table summary"
  status=1
fi
echo
echo "== 4b. Imported unit class-variable array"
target_fixture_check() {
  local tool="$1" fixture="$2" stem="$3" expected_site="${4:-}" expected_refusal_message="${5:-}" rc=0
  rm -f "$WORK/$stem$EXE"
  "$tool" "$REPO_NATIVE/bench/fixtures/$fixture.iyi" -o "$WORK_NATIVE/$stem$EXE" --pipeline typed --prelude --probe-phase >"$WORK/$stem.log" 2>"$WORK/$stem.build.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "${_PM_ARMED:-0}" = 1 ] && [ -n "$expected_site" ] && [ -n "$expected_refusal_message" ] && [ ! -e "$WORK/$stem$EXE" ] &&
       expected_refusal "$rc" "$WORK/$stem.build.err" "$expected_site" "$expected_refusal_message"; then
      echo "decisive: compiler produced the expected injected refusal"
      return 1
    fi
    echo "  INVALID: compiler could not build $fixture (exit $rc)" >&2
    cat "$WORK/$stem.log" "$WORK/$stem.build.err" >&2
    return 2
  fi
  if [ ! -f "$WORK/$stem$EXE" ]; then
    echo "  FAIL: $fixture reported success without an executable" >&2
    return 1
  fi
  [ "$CAN_RUN_MACHO" -eq 1 ] || return 0
  if ! codesign -v --strict "$WORK/$stem$EXE" >/dev/null 2>&1; then
    echo "  INVALID: $fixture has an invalid native signature" >&2
    return 2
  fi
  run_fixture "$WORK/$stem$EXE" "$stem.run" || return 2
  if [ "$RUN_KIND" != exit ]; then
    echo "  INVALID: $fixture terminated by $RUN_KIND $RUN_STATUS" >&2
    cat "$WORK/$stem.run.out" "$WORK/$stem.run.err" >&2
    return 2
  fi
  rc="$RUN_STATUS"
  [ "$rc" -eq 0 ] && return 0
  case "$stem:$rc" in
    unit_array:1|unit_array:2|unit_array:3)
      if [ ! -s "$WORK/$stem.run.out" ] && [ ! -s "$WORK/$stem.run.err" ]; then
        echo "decisive: imported array assertion exited $rc"
        return 1
      fi ;;
    virtual_ivar:*)
      if grep -Eq 'wrong constructor value|wrong initialized value' "$WORK/$stem.run.out" "$WORK/$stem.run.err"; then
        echo "decisive: virtual instance-variable assertion failed"
        return 1
      fi ;;
    nested_import:*)
      if grep -Fq 'wrong imported initializer' "$WORK/$stem.run.out" "$WORK/$stem.run.err"; then
        echo "decisive: nested import initializer assertion failed"
        return 1
      fi ;;
  esac
  echo "  INVALID: $fixture failed without its expected assertion (exit $rc)" >&2
  cat "$WORK/$stem.run.out" "$WORK/$stem.run.err" >&2
  return 2
}
imported_array_check() { target_fixture_check "$1" pipeline_unit_cvar_array unit_array "${2:-}" "${3:-}"; }
virtual_ivar_check() { target_fixture_check "$1" pipeline_virtual_ivar virtual_ivar "${2:-}" "${3:-}"; }
nested_import_check() { target_fixture_check "$1" pipeline_import_nested nested_import "${2:-}" "${3:-}"; }
array_baseline=0
virtual_baseline=0
nested_baseline=0

if imported_array_check "$WORK/tool$EXE"; then
  array_baseline=1
  if [ "$CAN_RUN_MACHO" -eq 1 ]; then echo "  imported array initializes and retains its contents"; else echo "  imported array emitted as arm64 Mach-O"; fi
else
  echo "  FAIL: imported class-variable array"
  status=1
fi

if "$IYI" run "$REPO_NATIVE/bench/fixtures/pipeline_virtual_ivar.iyi" > "$WORK/virtual_ivar.hosted" 2>&1 && virtual_ivar_check "$WORK/tool$EXE"; then
  virtual_baseline=1
  if [ "$CAN_RUN_MACHO" -eq 1 ]; then echo "  virtual instance-variable declarations run on hosted and native"; else echo "  hosted virtual instance variables run; native target emitted"; fi
else
  echo "  FAIL: virtual instance-variable declaration"
  cat "$WORK/virtual_ivar.hosted"
  status=1
fi

echo "== 4c. Imported digest's atomic class variable"
if "$IYI" run "$REPO_NATIVE/bench/fixtures/pipeline_import_digest.iyi" > "$WORK/digest.hosted" 2>&1 &&
   target_fixture_check "$WORK/tool$EXE" pipeline_import_digest digest; then
  if [ "$CAN_RUN_MACHO" -eq 1 ]; then echo "  imported digest initializer runs on hosted and native"; else echo "  hosted digest runs; native target emitted"; fi
else
  echo "  FAIL: imported digest initializer"
  cat "$WORK/digest.hosted"
  status=1
fi

echo "== 4d. Nested imports preserve dependency initialization"
if "$IYI" run "$REPO_NATIVE/bench/fixtures/pipeline_import_nested.iyi" > "$WORK/nested_import.hosted" 2>&1 && nested_import_check "$WORK/tool$EXE"; then
  nested_baseline=1
  if [ "$CAN_RUN_MACHO" -eq 1 ]; then echo "  nested class and module imports initialize their shared dependency"; else echo "  hosted nested imports run; native target emitted"; fi
else
  echo "  FAIL: nested import initializer"
  cat "$WORK/nested_import.hosted"
  status=1
fi
for bad in pipeline_import_cycle pipeline_import_missing; do
  rm -f "$WORK/$bad$EXE"
  "$IYI" run "$REPO_NATIVE/bench/fixtures/$bad.iyi" > "$WORK/$bad.hosted" 2>&1; hs=$?
  # Bounded, as every fixture run is: a loader that misses the cycle re-parses the import chain without end.
  if ! RUN_FIXTURE_TIMEOUT=300 run_fixture "$WORK/tool$EXE" "$bad.native-run" "$REPO_NATIVE/bench/fixtures/$bad.iyi" \
       -o "$WORK_NATIVE/$bad$EXE" --pipeline typed --prelude --probe-phase; then
    echo "  FAIL: $bad: the native tool could not be run"
    status=1; continue
  fi
  cat "$WORK/$bad.native-run.out" "$WORK/$bad.native-run.err" > "$WORK/$bad.native"
  if [ "$RUN_KIND" = timeout ]; then
    echo "  FAIL: $bad: the native tool did not finish within 300 s"
    status=1; continue
  fi
  ns=$RUN_STATUS
  [ "$RUN_KIND" = exit ] || ns=$((128 + RUN_STATUS))
  if [ "$bad" = pipeline_import_cycle ]; then expected="import cycle"; else expected="can't find module 'pipeline_nonexistent_dependency'"; fi
  if [ "$hs" -eq 0 ] || [ "$hs" -ge 126 ] || [ "$ns" -ne 1 ] || [ -e "$WORK/$bad$EXE" ] || ! grep -Fq "$expected" "$WORK/$bad.hosted" || ! grep -Fq "$expected" "$WORK/$bad.native"; then
    echo "  FAIL: $bad did not reject on both compilers"
    status=1
  else
    echo "  $bad rejected by hosted and native"
  fi
done

echo
echo "== 5. Mutation proofs: the gate must catch each patch"
# The check rebuilds the tool from the patched source and requires: one fixture that links and runs equal, a
# fixture that must exit nonzero and write nothing (the refusal), and the typed build of a program with its
# top-level code. It returns 0 only on the unmutated behaviour.
pipeline_check() {
  build_tool "$TOOL_SRC" "$WORK/mut_tool" || return 2
  local sa=0 sb=0 run_status=0 refusal expected
  rm -f "$WORK/mut_a$EXE" "$WORK/mut_b$EXE"
  "$WORK/mut_tool$EXE" "$REPO_NATIVE/bench/fixtures/lower_exit.iyi" -o "$WORK_NATIVE/mut_a$EXE" --pipeline typed --probe-phase >"$WORK/mut_a.log" 2>"$WORK/mut_a.err" || sa=$?
  if [ "$sa" -ne 0 ]; then
    echo "  INVALID: compiler failed to build lower_exit (exit $sa)" >&2
    cat "$WORK/mut_a.log" "$WORK/mut_a.err" >&2
    return 2
  fi
  if [ ! -f "$WORK/mut_a$EXE" ]; then
    echo "decisive: lower_exit reported success without an executable"
    return 1
  fi
  if [ "$CAN_RUN_MACHO" -eq 1 ]; then
    if ! codesign -v --strict "$WORK/mut_a$EXE" >/dev/null 2>&1; then
      echo "  INVALID: lower_exit has an invalid signature" >&2
      return 2
    fi
    run_fixture "$WORK/mut_a$EXE" mut_a.run || return 2
    if [ "$RUN_KIND" != exit ] || grep -Eqi 'panic|segmentation fault|abort trap' "$WORK/mut_a.run.out" "$WORK/mut_a.run.err"; then
      echo "  INVALID: lower_exit terminated by $RUN_KIND $RUN_STATUS or panicked" >&2
      cat "$WORK/mut_a.run.out" "$WORK/mut_a.run.err" >&2
      return 2
    fi
    run_status="$RUN_STATUS"
    if [ "$run_status" -ne 42 ]; then
      echo "decisive: lower_exit returned $run_status instead of 42"
      return 1
    fi
  fi
  "$WORK/mut_tool$EXE" "$REPO_NATIVE/bench/fixtures/lower_instance_sizeof.iyi" -o "$WORK_NATIVE/mut_b$EXE" --pipeline typed --probe-phase >"$WORK/mut_b.log" 2>"$WORK/mut_b.err" || sb=$?
  refusal="$(pipeline_first_refusal "$WORK/mut_b.log")"
  if [ "${_PM_ARMED:-0}" = 0 ]; then
    case "$refusal" in 'lower: fail: '*InstanceSizeOf*) ;; *) echo "  INVALID: baseline did not reach the expected InstanceSizeOf refusal" >&2; cat "$WORK/mut_b.log" "$WORK/mut_b.err" >&2; return 2 ;; esac
    expected="iyi-compile-native: lower: ${refusal#lower: fail: }"
    if [ "$sb" -ne 1 ] || [ -e "$WORK/mut_b$EXE" ] || ! grep -Fxq "$expected" "$WORK/mut_b.err"; then
      echo "  INVALID: baseline InstanceSizeOf refusal did not match its exact compiler diagnostic" >&2
      cat "$WORK/mut_b.log" "$WORK/mut_b.err" >&2
      return 2
    fi
    printf '%s\n' "$expected" >"$WORK/pipeline.expected-refusal"
    printf '%s\n' "$refusal" >"$WORK/pipeline.expected-phase"
    return 0
  fi
  [ -f "$WORK/pipeline.expected-refusal" ] || { echo "  INVALID: missing refusal baseline" >&2; return 2; }
  expected="$(cat "$WORK/pipeline.expected-refusal")"
  if [ "$sb" -eq 1 ] && [ ! -e "$WORK/mut_b$EXE" ] && grep -Fxq "$expected" "$WORK/mut_b.err"; then
    return 0
  fi
  if [ "$sb" -eq 0 ] && { [ -e "$WORK/mut_b$EXE" ] || [ "$refusal" = "$(cat "$WORK/pipeline.expected-phase")" ]; }; then
    echo "decisive: InstanceSizeOf refusal exited successfully or produced an executable"
    return 1
  fi
  echo "  INVALID: mutated refusal did not match the baseline (exit $sb)" >&2
  cat "$WORK/mut_b.log" "$WORK/mut_b.err" >&2
  return 2
}

imported_array_mutation_check() {
  build_tool "$TOOL_SRC" "$WORK/unit_array_tool" || return 2
  imported_array_check "$WORK/unit_array_tool$EXE" "${1:-}" "${2:-}"
}
virtual_ivar_mutation_check() {
  build_tool "$TOOL_SRC" "$WORK/virtual_ivar_tool" || return 2
  virtual_ivar_check "$WORK/virtual_ivar_tool$EXE" "${1:-}" "${2:-}"
}
nested_import_mutation_check() {
  build_tool "$TOOL_SRC" "$WORK/nested_import_tool" || return 2
  nested_import_check "$WORK/nested_import_tool$EXE" "${1:-}" "${2:-}"
}
if [ "$CAN_RUN_MACHO" -eq 1 ]; then
  if [ "$array_baseline" -eq 1 ]; then
    prove_mutation "an existing allocator declaration is defined a second time" "$LOWER_SRC" \
      'fn = declared_or_defined_fun(low, name, fun_def_type(low, rec, ret))' \
      'fn = low.module.define_function(name, fun_def_type(low, rec, ret))' -- imported_array_mutation_check \
      src/compiler/ir/module.iyi '^a function or global named __iyi_new already exists$' || status=1
    prove_mutation "a unit module wrapper does not type its class-variable initializer" "$REPO/src/compiler/semantic/main_visitor.iyi" \
      $'    # semantic_visitor.cr:1811-1828 visits either resolved module body.\n    if t && t.is_a?(ModuleType)' \
      $'    # semantic_visitor.cr:1811-1828 visits either resolved module body.\n    if t && t.is_a?(ClassType)' -- imported_array_mutation_check \
      src/compiler/lower/pending.iyi '^lower: visit\(ArrayLiteral\) \(hosted codegen\.cr\) is not ported yet$' || status=1
  else
    echo "  INVALID: imported array mutations have no passing baseline" >&2; status=1
  fi
  if [ "$virtual_baseline" -eq 1 ]; then
    prove_mutation "an initialized instance variable loses its virtual type" "$REPO/src/compiler/semantic/main_visitor.iyi" \
      $'          # including its virtual type; visiting its initializer must retain it.\n          ivar = mod_type.instance_vars[ivar_node.name]?' \
      $'          # including its virtual type; visiting its initializer must retain it.\n          ivar = nil' -- virtual_ivar_mutation_check \
      src/compiler/lower/pending.iyi '^lower: visit\(assign Circle to Shape \(hosted assign_distinct, not ported\)\) \(hosted codegen\.cr\) is not ported yet$' || status=1
    prove_mutation "an uninitialized instance variable loses its virtual type" "$REPO/src/compiler/semantic/main_visitor.iyi" \
      $'          # Preserve the declaration pass\047s virtualized field type and metadata.\n          ivar = mod_type.instance_vars[ivar_node.name]?' \
      $'          # Preserve the declaration pass\047s virtualized field type and metadata.\n          ivar = nil' -- virtual_ivar_mutation_check \
      src/compiler/lower/pending.iyi '^lower: visit\(assign Circle to Shape \(hosted assign_distinct, not ported\)\) \(hosted codegen\.cr\) is not ported yet$' || status=1
  else
    echo "  INVALID: virtual ivar mutations have no passing baseline" >&2; status=1
  fi
  if [ "$nested_baseline" -eq 1 ]; then
    prove_mutation "the loader omits class-scoped imports" "$REPO/src/compiler/loader.iyi" \
      'collect_import_paths(node.as(ClassDef).body, into, engine, filename, user_imports)' \
      'nil' -- nested_import_mutation_check \
      src/compiler/lower/pending.iyi '^lower: visit\(import pipeline_import_leaf_b without its resolved unit\) \(hosted codegen\.cr\) is not ported yet$' || status=1
    prove_mutation "the loader omits module-scoped imports" "$REPO/src/compiler/loader.iyi" \
      'collect_import_paths(node.as(ModuleDef).body, into, engine, filename, user_imports)' \
      'nil' -- nested_import_mutation_check \
      src/compiler/lower/pending.iyi '^lower: visit\(import pipeline_import_leaf without its resolved unit\) \(hosted codegen\.cr\) is not ported yet$' || status=1
  else
    echo "  INVALID: nested import mutations have no passing baseline" >&2; status=1
  fi
else
  host_limited "selfhost_pipeline: imported array, virtual ivar, and nested import runtime mutation assertions require macOS arm64"
fi
if [ "$nested_baseline" -eq 1 ]; then
  prove_mutation "a resolved import is refused during lowering" "$LOWER_SRC" \
    'if node.is_a?(ImportDecl)' 'if false && node.is_a?(ImportDecl)' -- nested_import_mutation_check \
    src/compiler/lower/pending.iyi '^lower: visit\(ImportDecl\) \(hosted codegen\.cr\) is not ported yet$' || status=1
else
  echo "  INVALID: import-refusal mutation has no passing baseline" >&2
  status=1
fi

# The lowering table names and counts no Primitive-annotated def. The hosted compiler lowers a primitive at its call
# site, so a probe of such a def's body is a refusal row for a def that is never a function of its own. The hello
# root with its prelude reaches them; the table must name none. Prelude-free fixtures reach only the stand-in's
# binary operators (lower/program.iyi), so this check runs the root.
# Table probes may end in the same named refusal after writing their table.
# A different failure or a crash is not a table comparison.
run_table_probe() {
  local tool="$1" input="$2" stem="$3" with_prelude="$4" rc=0
  rm -f "$WORK/$stem$EXE" "$WORK/$stem$EXE.refusals" "$WORK/$stem$EXE.names"
  if [ "$with_prelude" = yes ]; then
    "$tool" "$input" -o "$WORK_NATIVE/$stem$EXE" --pipeline typed --prelude --probe-phase --keep-going >"$WORK/$stem.log" 2>"$WORK/$stem.err" || rc=$?
  else
    "$tool" "$input" -o "$WORK_NATIVE/$stem$EXE" --pipeline typed --probe-phase --keep-going >"$WORK/$stem.log" 2>"$WORK/$stem.err" || rc=$?
  fi
  if grep -q 'BUG:' "$WORK/$stem.log" "$WORK/$stem.err"; then
    echo "  INVALID: $stem table probe reported a compiler BUG" >&2
    cat "$WORK/$stem.log" "$WORK/$stem.err" >&2
    return 2
  fi
  if [ "$rc" -eq 0 ] && [ -f "$WORK/$stem$EXE" ]; then
    return 0
  fi
  if [ "$rc" -eq 1 ] && [ ! -e "$WORK/$stem$EXE" ]; then
    awk '/^iyi-compile-native: / { print; exit }' "$WORK/$stem.err" >"$WORK/$stem.refusal"
    if [ -s "$WORK/$stem.refusal" ] && ! grep -Eq 'BUG:|iyi: panic:' "$WORK/$stem.refusal"; then
      if [ "${_PM_ARMED:-0}" = 0 ]; then
        cp "$WORK/$stem.refusal" "$WORK/$stem.baseline-refusal"
        return 0
      elif [ -f "$WORK/$stem.baseline-refusal" ] && cmp -s "$WORK/$stem.refusal" "$WORK/$stem.baseline-refusal"; then
        return 0
      fi
    fi
  fi
  echo "  INVALID: $stem table probe failed without the baseline refusal (exit $rc)" >&2
  cat "$WORK/$stem.log" "$WORK/$stem.err" >&2
  return 2
}
primitive_table_check() {
  build_tool "$TOOL_SRC" "$WORK/prim_tool" || return 2
  run_table_probe "$WORK/prim_tool$EXE" "$REPO_NATIVE/samples/iyi/hello.iyi" prim_hello yes || return 2
  if ! awk '/^table: hello defs-lowered-clean=/ { ok = 1 } END { exit !ok }' "$WORK/prim_hello.log"; then
    echo "  INVALID: primitive table probe emitted no summary" >&2
    cat "$WORK/prim_hello.log" "$WORK/prim_hello.err" >&2
    return 2
  fi
  awk '/^table: hello lowering .*visit\(Primitive/ { bad = 1 } END { exit bad }' "$WORK/prim_hello.log"
}

# A yielding def without a captured block is inlined by the hosted compiler, not
# emitted as a standalone function. Its caller and ordinary defs remain probeable.
yield_table_check() {
  build_tool "$TOOL_SRC" "$WORK/yield_tool" || return 2
  run_table_probe "$WORK/yield_tool$EXE" "$REPO_NATIVE/bench/fixtures/pipeline_yield_probe.iyi" yield_probe no || return 2
  if [ ! -f "$WORK/yield_probe$EXE.refusals" ]; then
    echo "  INVALID: yielding probe did not write its table" >&2
    return 2
  fi
  awk -F '\t' '
    $1 == "reached" && $2 ~ /identity$/ { ordinary = 1 }
    $1 == "reached" && $2 ~ /emit_once$/ { yielding = 1 }
    END { exit !(ordinary && !yielding) }
  ' "$WORK/yield_probe$EXE.refusals"
}
echo "  the yielding-def table check passes on the unmutated code:"
if yield_table_check; then
  echo "    unmutated: pass"
  prove_mutation "the table probes a noncapturing yielding def" "$PROGRAM_SRC" \
    'next if noncapturing_yield?(d)' 'next if false' -- yield_table_check || status=1
else
  echo "    unmutated: FAIL"
  status=1
fi

# The recorded origin is the function being emitted, not necessarily an inlined
# callee. A nested refusal must identify the emitted inner function, not the probe.
origin_table_check() {
  build_tool "$TOOL_SRC" "$WORK/origin_tool" || return 2
  run_table_probe "$WORK/origin_tool$EXE" "$REPO_NATIVE/bench/fixtures/pipeline_refusal_origin.iyi" origin_probe no || return 2
  if [ ! -f "$WORK/origin_probe$EXE.refusals" ]; then
    echo "  INVALID: origin probe did not write its table" >&2
    return 2
  fi
  awk -F '\t' '$1 == "lowering" && $2 ~ /pipeline_outer$/ && $5 ~ /pipeline_inner/ { found = 1 } END { exit !found }' "$WORK/origin_probe$EXE.refusals"
}
echo "  the refusal-origin check passes on the unmutated code:"
if origin_table_check; then
  echo "    unmutated: pass"
  prove_mutation "a refusal is attributed to the probe instead of the emitted function" "$PROGRAM_SRC" \
    'origin = ctx.fun.name' 'origin = lowering_example(d, inst.self_type)' -- origin_table_check || status=1
else
  echo "    unmutated: FAIL"
  status=1
fi

# Promote the prelude-free exit fixture to a root and compare the two actual
# executables through the same helper the root loop uses.
root_comparison_check() {
  local ts=0 hs=0
  build_tool "$TOOL_SRC" "$WORK/root_tool" || return 2
  if ! "$WORK/root_tool$EXE" "$REPO_NATIVE/bench/fixtures/lower_exit.iyi" -o "$WORK_NATIVE/root_test$EXE" --pipeline typed --probe-phase > "$WORK/root_test.log" 2>&1; then
    echo "  INVALID: native root did not build" >&2; cat "$WORK/root_test.log" >&2; return 2
  fi
  [ "$(probe_phase "$WORK/root_test.log")" = "link" ] || { echo "  INVALID: native root did not reach link" >&2; return 2; }
  if ! "$IYI" build --prelude empty -o "$WORK_NATIVE/root_hosted$EXE" "$REPO_NATIVE/bench/fixtures/lower_exit.iyi" > "$WORK/root_hosted.log" 2>&1; then
    echo "  INVALID: hosted root did not build" >&2; cat "$WORK/root_hosted.log" >&2; return 2
  fi
  if [ "$CAN_RUN_MACHO" -eq 1 ]; then
    codesign -v --strict "$WORK/root_test$EXE" > /dev/null 2>&1 || { echo "  INVALID: native signature" >&2; return 2; }
    run_fixture "$WORK/root_test$EXE" root_test.run || return 2
    local tkind="$RUN_KIND"
    ts="$RUN_STATUS"
    run_fixture "$WORK/root_hosted$EXE" root_hosted.run || return 2
    local hkind="$RUN_KIND"
    hs="$RUN_STATUS"
    if [ "$tkind" != exit ] || [ "$hkind" != exit ]; then
      echo "  INVALID: root execution terminated typed $tkind $ts, hosted $hkind $hs" >&2
      cat "$WORK/root_test.run.out" "$WORK/root_test.run.err" "$WORK/root_hosted.run.out" "$WORK/root_hosted.run.err" >&2
      return 2
    fi
    cp "$WORK/root_test.run.out" "$WORK/root_test.out"
    cp "$WORK/root_hosted.run.out" "$WORK/root_hosted.out"
    cmp -s "$WORK/root_test.run.err" "$WORK/root_hosted.run.err" || return 1
  else
    # lower_exit specifies exit 42 and no stdout. This checks only the helper,
    # not target execution or run-equal parity.
    ts=42; hs=42
    : >"$WORK/root_test.out"; : >"$WORK/root_hosted.out"
  fi
  local cmp_status=0
  bash -c '. "$1"; pipeline_outputs_equal "$2" "$3" "$4" "$5"' _ "$REPO/bench/lib/pipeline_report.sh" "$ts" "$hs" "$WORK/root_test.out" "$WORK/root_hosted.out" || cmp_status=$?
  [ "$cmp_status" -eq 1 ] && return 1
  [ "$cmp_status" -eq 0 ] || { echo "  INVALID: comparison helper exited $cmp_status" >&2; return 2; }
  cmp_status=0
  bash -c '. "$1"; pipeline_outputs_equal "$2" 43 "$3" "$4"' _ "$REPO/bench/lib/pipeline_report.sh" "$ts" "$WORK/root_test.out" "$WORK/root_hosted.out" || cmp_status=$?
  [ "$cmp_status" -eq 1 ] && return 0
  [ "$cmp_status" -eq 0 ] && return 1
  echo "  INVALID: comparison helper exited $cmp_status" >&2
  return 2
}
if [ "$CAN_RUN_MACHO" -eq 0 ]; then
  host_limited "selfhost_pipeline: root execution parity requires macOS arm64; the comparison helper is checked with lower_exit's specified result"
fi
echo "  the root comparison helper passes on the unmutated code:"
if root_comparison_check; then
  echo "    unmutated: pass"
  prove_mutation "the linked-root comparison rejects equal statuses" "$REPO/bench/lib/pipeline_report.sh" \
    '[ "$typed_status" = "$hosted_status" ]' '[ "$typed_status" != "$hosted_status" ]' -- root_comparison_check || status=1
else
  echo "    unmutated: FAIL"
  status=1
fi

# The headline must carry the first real refusal, not a phase pass or a later line.
headline_check() {
  local line actual rc=0 expected
  build_tool "$TOOL_SRC" "$WORK/headline_tool" || return 2
  rm -f "$WORK/headline_test$EXE"
  "$WORK/headline_tool$EXE" "$REPO_NATIVE/bench/fixtures/lower_instance_sizeof.iyi" -o "$WORK_NATIVE/headline_test$EXE" --pipeline typed --probe-phase >"$WORK/headline_test.log" 2>"$WORK/headline_test.err" || rc=$?
  actual="$(pipeline_first_refusal "$WORK/headline_test.log")"
  case "$actual" in 'lower: fail: '*InstanceSizeOf*) ;; *) echo "  INVALID: expected InstanceSizeOf refusal absent" >&2; cat "$WORK/headline_test.log" "$WORK/headline_test.err" >&2; return 2 ;; esac
  expected="iyi-compile-native: lower: ${actual#lower: fail: }"
  if [ "$rc" -ne 1 ] || [ -e "$WORK/headline_test$EXE" ] || ! grep -Fxq "$expected" "$WORK/headline_test.err"; then
    echo "  INVALID: headline probe did not produce its exact refusal" >&2
    cat "$WORK/headline_test.log" "$WORK/headline_test.err" >&2
    return 2
  fi
  line="$(bash -c '. "$1"; pipeline_first_refusal "$2"' _ "$REPO/bench/lib/pipeline_report.sh" "$WORK/headline_test.log")"
  [ "$line" = "$actual" ]
}
echo "  the refusal headline check passes on the unmutated code:"
if headline_check; then
  echo "    unmutated: pass"
else
  echo "    unmutated: FAIL"
  status=1
fi
prove_mutation "the headline reports a pass instead of a refusal" "$REPO/bench/lib/pipeline_report.sh" \
  '/: fail: /' '/: pass: /' -- headline_check || status=1

# The entry: a prelude-free program's top-level code is `__crystal_main` (lower.iyi main_function_name), and the C `main` is
# emitted once, by the pipeline only when the program has no `fun main` of its own. Checked on IR text from --emit ir, on two
# prelude-free fixtures (no main, and one with its own main). The check returns 0 only on the unmutated behaviour.
entry_check() {
  build_tool "$TOOL_SRC" "$WORK/entry_tool" || return 2
  rm -f "$WORK/entry_exit.ll" "$WORK/entry_fm.ll"
  if ! "$WORK/entry_tool$EXE" "$REPO_NATIVE/bench/fixtures/lower_exit.iyi" -o "$WORK_NATIVE/entry_exit.ll" --pipeline typed --emit ir >"$WORK/entry_exit.log" 2>&1; then
    echo "  INVALID: entry exit IR did not compile" >&2; cat "$WORK/entry_exit.log" >&2; return 2
  fi
  local rc=0
  "$WORK/entry_tool$EXE" "$REPO_NATIVE/bench/fixtures/lower_fun_main.iyi" -o "$WORK_NATIVE/entry_fm.ll" --pipeline typed --emit ir >"$WORK/entry_fm.log" 2>"$WORK/entry_fm.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "${_PM_ARMED:-0}" = 1 ] && [ ! -e "$WORK/entry_fm.ll" ] &&
       expected_refusal "$rc" "$WORK/entry_fm.err" src/compiler/ir/module.iyi '^a function or global named main already exists$'; then
      echo "decisive: defining another main was rejected"
      return 1
    fi
    echo "  INVALID: entry main IR did not compile" >&2
    cat "$WORK/entry_fm.log" "$WORK/entry_fm.err" >&2
    return 2
  fi
  [ -f "$WORK/entry_exit.ll" ] && [ -f "$WORK/entry_fm.ll" ] || { echo "  INVALID: entry IR was not written" >&2; return 2; }
  local f
  for f in "$WORK/entry_exit.ll" "$WORK/entry_fm.ll"; do
    awk '/^define .*@__crystal_main\(/ { m = 1 } END { exit !m }' "$f" || return 1
    awk '/^define .*@__iyi_main\(/ { bad = 1 } END { exit bad }' "$f" || return 1
    awk '/^define .*@main\(/ { n++ } END { exit n != 1 }' "$f" || return 1
  done
  return 0
}
echo "  the mutation check passes on the unmutated code:"
if pipeline_check; then
  echo "    unmutated: pass"
  prove_mutation "a refusal exits 0 and writes nothing" "$COMPILER_SRC" \
    '@refusal = "#{phase}: #{message}"' '@refusal = nil' -- pipeline_check || status=1
  if [ "$CAN_RUN_MACHO" -eq 1 ]; then
    prove_mutation "the program's top-level code is dropped" "$PROGRAM_SRC" \
      "top_level.each { |t| nodes << t }" "nodes << Nop.new" -- pipeline_check || status=1
  else
    host_limited "selfhost_pipeline: detecting dropped top-level runtime code requires macOS arm64"
  fi
  prove_mutation "the tool falls back to the codegen pipeline when the typed one refuses" "$TOOL_SRC" \
    "fail(refusal.as(String))" "compiler.config.typed_pipeline = false; compiler.refusal = nil; compiler.compile(input)" -- pipeline_check || status=1
else
  echo "    unmutated: FAIL (the mutation check cannot prove anything)"
  status=1
fi
echo "  the table check passes on the unmutated code:"
if primitive_table_check; then
  echo "    unmutated: pass"
  prove_mutation "the lowering table probes a Primitive-annotated def" "$PROGRAM_SRC" \
    $'next unless primitive_name(d.body).nil?\n    next if noncapturing_yield?(d)' $'next if false\n    next if noncapturing_yield?(d)' -- primitive_table_check || status=1
else
  echo "    unmutated: FAIL (the table check cannot prove anything)"
  status=1
fi
echo "  the entry check passes on the unmutated code:"
if entry_check; then
  echo "    unmutated: pass"
  prove_mutation "a prelude-free program's top-level code is named __iyi_main" "$LOWER_SRC" \
    'return "__crystal_main"' 'return "__iyi_main"' -- entry_check || status=1
  # The prelude branch cannot reach IR in the current typed pipeline.
  prove_mutation "a program that defines its own main gets a second main" "$LOWER_SRC" \
    "unless root_defines_main(root)" "unless false" -- entry_check || status=1
  prove_mutation "a program with no main of its own gets no main" "$LOWER_SRC" \
    "unless root_defines_main(root)" "if false" -- entry_check || status=1
else
  echo "    unmutated: FAIL (the entry check cannot prove anything)"
  status=1
fi

# A prelude-free program is Crystal's layout: the class id is field 0, and a string literal
# is the four-field struct. Forcing iyi layout (the old hard-coded true) fails this check.
layout_check() {
  build_tool "$TOOL_SRC" "$WORK/layout_tool" || return 2
  rm -f "$WORK/layout_box.ll" "$WORK/layout_str.ll"
  if ! "$WORK/layout_tool$EXE" "$REPO_NATIVE/bench/fixtures/lower_class_new.iyi" -o "$WORK_NATIVE/layout_box.ll" --pipeline typed --emit ir >"$WORK/layout_box.log" 2>&1; then
    echo "  INVALID: class layout IR did not compile" >&2; cat "$WORK/layout_box.log" >&2; return 2
  fi
  if ! "$WORK/layout_tool$EXE" "$REPO_NATIVE/bench/fixtures/lower_string_fields.iyi" -o "$WORK_NATIVE/layout_str.ll" --pipeline typed --emit ir >"$WORK/layout_str.log" 2>&1; then
    echo "  INVALID: string layout IR did not compile" >&2; cat "$WORK/layout_str.log" >&2; return 2
  fi
  [ -f "$WORK/layout_box.ll" ] && [ -f "$WORK/layout_str.ll" ] || { echo "  INVALID: layout IR was not written" >&2; return 2; }
  awk '/i64 -4/ { bad = 1 } /^%Tool = type \{ i32, i32 \}/ { shape = 1 } /getelementptr inbounds %Tool, ptr .*i32 0, i32 0/ { field = 1 } /load i32, ptr @"Tool:type_id"/ { id = 1 } /store i32 .*ptr/ { stored = 1 } END { exit !(shape && field && id && stored && !bad) }' "$WORK/layout_box.ll" || return 1
  awk '/private constant \{ i32,/ { hosted = 1 } /private constant \{ i64,/ { iyi = 1 } END { exit !(hosted && !iyi) }' "$WORK/layout_str.ll"
}
echo "  the layout check passes on the unmutated code:"
if layout_check; then
  echo "    unmutated: pass"
  prove_mutation "a prelude-free program uses iyi's object layout" "$PROGRAM_SRC" \
    'iyi_object_layout?(typed.prog)' \
    'true' -- layout_check || status=1
else
  echo "    unmutated: FAIL (the layout check cannot prove anything)"
  awk 'NR<=8' "$WORK/layout_box.ll" "$WORK/layout_str.ll"
  status=1
fi

# A top-level `{% if flag?(:no_such_flag) %}` require takes the else branch. The driver's
# output names loader_if_b and not loader_if_a. The mutation makes the loader read every
# `{% if %}`'s first branch, so the same output names a and the check fails.
loader_if_check() {
  local rc=0
  build_tool "$REPO/bench/selfhost_loader_if_exercise.iyi" "$WORK/loader_if_drv" || return 2
  "$WORK/loader_if_drv$EXE" "$REPO_NATIVE/bench/fixtures/loader_if_entry.iyi" > "$WORK/loader_if.out" 2> "$WORK/loader_if.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  INVALID: loader driver exited $rc" >&2
    cat "$WORK/loader_if.out" "$WORK/loader_if.err" >&2
    return 2
  fi
  awk '/loader_if_b/ { b = 1 } /loader_if_a/ { a = 1 } END { exit !(b && !a) }' "$WORK/loader_if.out"
}
echo "  the loader if-require check passes on the unmutated code:"
if loader_if_check; then
  echo "    unmutated: pass"
  prove_mutation "the loader reads the first branch of every {% if %}" "$LOADER_SRC" \
    'if report.failure.nil? && !report.skipped' 'if false' -- loader_if_check || status=1
else
  echo "    unmutated: FAIL (the loader if-require check cannot prove anything)"
  status=1
fi

# The same entry must run the selected branch through declarations, lowering and the linker.
pipeline_loader_if_check() {
  local rc=0
  build_tool "$TOOL_SRC" "$WORK/loader_pipeline_tool" || return 2
  rm -f "$WORK/loader_entry$EXE"
  if ! "$WORK/loader_pipeline_tool$EXE" "$REPO_NATIVE/bench/fixtures/loader_if_entry.iyi" -o "$WORK_NATIVE/loader_entry$EXE" --pipeline typed > "$WORK/loader_entry.build" 2>&1; then
    echo "  INVALID: loader entry did not compile" >&2
    cat "$WORK/loader_entry.build" >&2
    return 2
  fi
  [ -f "$WORK/loader_entry$EXE" ] || { echo "  INVALID: loader entry was not written" >&2; return 2; }
  [ "$CAN_RUN_MACHO" -eq 1 ] || return 0
  codesign -v --strict "$WORK/loader_entry$EXE" > /dev/null 2>&1 || { echo "  INVALID: loader entry signature" >&2; return 2; }
  run_fixture "$WORK/loader_entry$EXE" loader_entry.run || return 2
  if [ "$RUN_KIND" != exit ] || grep -Eqi 'panic|segmentation fault|abort trap' "$WORK/loader_entry.run.out" "$WORK/loader_entry.run.err"; then
    echo "  INVALID: loader entry terminated by $RUN_KIND $RUN_STATUS or panicked" >&2
    cat "$WORK/loader_entry.run.out" "$WORK/loader_entry.run.err" >&2
    return 2
  fi
  rc="$RUN_STATUS"
  [ "$rc" -eq 2 ] && [ "$(awk '1' "$WORK/loader_entry.run.out")" = "b" ]
}
echo "  the selected loader branch compiles through the typed pipeline:"
if pipeline_loader_if_check; then
  echo "    unmutated: pass"
  if [ "$CAN_RUN_MACHO" -eq 1 ]; then
    prove_mutation "post-splice runtime code is dropped" "$COMPILER_SRC" \
      'top_level.concat(runtime_by_unit[mod_info.filename])' 'top_level.concat([] of ASTNode)' -- pipeline_loader_if_check || status=1
  else
    host_limited "selfhost_pipeline: post-splice runtime mutation requires macOS arm64"
  fi
else
  echo "    unmutated: FAIL"
  status=1
fi

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL CHECKS PASSED"
else
  echo "== SOME CHECKS FAILED"
fi
exit "$status"
