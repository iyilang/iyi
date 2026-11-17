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
IYI="$REPO/bin/iyi"
. "$REPO/bench/lib/mutation.sh"
. "$REPO/bench/lib/pipeline_report.sh"
WORK="$(mktemp -d /tmp/iyi-pipeline.XXXXXX)"
ARTIFACT_DIR="${PIPELINE_ARTIFACT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/iyi-pipeline-artifacts.XXXXXX")}"
mkdir -p "$ARTIFACT_DIR"
echo "  table sidecars: $ARTIFACT_DIR"
trap 'rm -rf "$WORK"' EXIT
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
elif [ "$(uname -s)" = Darwin ]; then
  HOST_GB="$({ /usr/sbin/sysctl -n hw.memsize 2>/dev/null || sysctl -n hw.memsize; } | awk '{printf "%.0f", int($1 / 1073741824)}')"
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

# Builds the tool from the given source, with the hosted compiler, into $2.
build_tool() {
  "$IYI" build -o "$2" "$1" > "$2.build.log" 2>&1
}

echo "== 1. The tool builds from source with bin/iyi and links no LLVM"
if ! build_tool "$TOOL_SRC" "$WORK/tool"; then
  echo "  FAIL: the tool does not build (see $WORK/tool.build.log)"
  exit 1
fi
if otool -L "$WORK/tool" | awk '/LLVM|llvm/ { found = 1 } END { exit !found }'; then
  echo "  FAIL: the tool links LLVM"
  exit 1
fi
echo "  the tool builds and links no LLVM"

echo
echo "== 2. Each fixture: the typed pipeline against the hosted executable"
declare -A measured
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
  out="$WORK/$name"
  "$WORK/tool" "$fixture" -o "$out" --pipeline typed --probe-phase > "$WORK/$name.probe" 2> "$WORK/$name.err"
  ts=$?
  reached="$(probe_phase "$WORK/$name.probe")"
  if [ "$ts" -eq 0 ] && [ "$reached" = "link" ]; then
    prelude=empty
    hosted_path="$REPO/src"
    if [ "$name" = lowglob_cvar_lazy ] || [ "$name" = lowglob_cvar_lazy_aggregate ]; then
      prelude=iyi/prelude
      hosted_path="$REPO/bench/fixtures/lowglob_abi:$hosted_path"
    fi
    if ! IYI_PATH="$hosted_path" "$IYI" build --prelude "$prelude" -o "$WORK/$name.hosted" "$fixture" > "$WORK/$name.hosted.log" 2>&1; then
      echo "  $name: FAILED, the hosted compiler does not build the fixture"
      failed=$((failed + 1)); measured[$rel]="link"; continue
    fi
    if ! codesign -v --strict "$out" > /dev/null 2>&1; then
      echo "  $name: FAILED, native signature invalid"
      failed=$((failed + 1)); measured[$rel]="link"; continue
    fi
    timeout 30 "$out" > "$WORK/$name.typed.out" 2>&1; tstat=$?
    timeout 30 "$WORK/$name.hosted" > "$WORK/$name.hosted.out" 2>&1; hstat=$?
    if [ "$tstat" = "$hstat" ] && cmp -s "$WORK/$name.typed.out" "$WORK/$name.hosted.out"; then
      echo "  $name: run-equal (status $hstat, stdout identical)"
      run_equal=$((run_equal + 1)); measured[$rel]="run-equal"
    else
      echo "  $name: FAILED, the typed executable exits $tstat, the hosted $hstat, or the stdout differs"
      failed=$((failed + 1)); measured[$rel]="link"
    fi
  elif [ "$ts" -ne 0 ] && [ "$reached" != "link" ] && [ ! -e "$out" ]; then
    refusal="$(awk '/: fail: / { print; exit }' "$WORK/$name.probe" | cut -c1-140)"
    [ -z "$refusal" ] && refusal="$(awk 'NR==1' "$WORK/$name.err" | cut -c1-140)"
    echo "  $name: refused after $reached, exit $ts, no output: $refusal"
    refused=$((refused + 1)); measured[$rel]="$reached"
  else
    echo "  $name: FAILED, exit $ts, reached $reached, output file present: $([ -e "$out" ] && echo yes || echo no)"
    failed=$((failed + 1)); measured[$rel]="${reached:-none}"
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
  IYI_PATH="$REPO/src" "$WORK/tool" "$REPO/$root" -o "$WORK/$name.root" --pipeline typed --prelude --probe-phase > "$WORK/$name.root.probe" 2> "$WORK/$name.root.err"
  root_status=$?
  rphase="$(probe_phase "$WORK/$name.root.probe")"
  refusal="$(pipeline_first_refusal "$WORK/$name.root.probe")"
  [ -n "$refusal" ] || refusal="$(awk 'NR==1 { print; exit }' "$WORK/$name.root.err")"
  echo "  $name strict: reached ${rphase:-none}: ${refusal:-no refusal}"
  if [ "$root_status" -eq 0 ] && [ "$rphase" = "link" ] && [ -e "$WORK/$name.root" ]; then
    if ! IYI_PATH="$REPO/src" "$IYI" build -o "$WORK/$name.root.hosted" "$REPO/$root" > "$WORK/$name.root.hosted.log" 2>&1; then
      echo "  $root: FAILED, the hosted compiler does not build the root"
      failed=$((failed + 1))
    elif ! codesign -v --strict "$WORK/$name.root" > /dev/null 2>&1; then
      echo "  $root: FAILED, native signature invalid"
      failed=$((failed + 1))
    else
      timeout 30 "$WORK/$name.root" > "$WORK/$name.root.typed.out" 2>&1; tstat=$?
      timeout 30 "$WORK/$name.root.hosted" > "$WORK/$name.root.hosted.out" 2>&1; hstat=$?
      if pipeline_outputs_equal "$tstat" "$hstat" "$WORK/$name.root.typed.out" "$WORK/$name.root.hosted.out"; then
        rphase="run-equal"
        echo "  $root: run-equal (status $hstat, stdout identical)"
      else
        echo "  $root: FAILED, typed status $tstat, hosted status $hstat, or stdout differs"
        failed=$((failed + 1))
      fi
    fi
  elif [ "$root_status" -eq 0 ] || [ "$rphase" = "link" ] || [ -e "$WORK/$name.root" ]; then
    echo "  $root: FAILED, exit $root_status, reached ${rphase:-none}, or unexpected output"
    failed=$((failed + 1))
  fi
  measured[$rel]="${rphase:-none}"
done

echo
echo "== 4. The floor: no phase falls"
if [ "${SELFHOST_PIPELINE_RAISE:-0}" = "1" ]; then
  : > "$FLOOR.new"
  echo "# selfhost pipeline floor: <repo file> <phase reached>. A phase may only rise." >> "$FLOOR.new"
  echo "# Raise with SELFHOST_PIPELINE_RAISE=1 bash bench/selfhost_pipeline_exercise.sh (keeps the higher phase)." >> "$FLOOR.new"
  floor_keys=("${!measured[@]}")
  if [ "$SKIP_COMPILE_NATIVE" -eq 1 ] && awk -v root="$COMPILE_NATIVE_ROOT" '$1 == root {found=1} END {exit !found}' "$FLOOR"; then
    floor_keys+=("$COMPILE_NATIVE_ROOT")
  fi
  for k in $(printf '%s\n' "${floor_keys[@]}" | sort); do
    if [ "$SKIP_COMPILE_NATIVE" -eq 1 ] && [ "$k" = "$COMPILE_NATIVE_ROOT" ]; then
      awk -v root="$COMPILE_NATIVE_ROOT" '$1 == root {print}' "$FLOOR" >> "$FLOOR.new"
      continue
    fi
    keep="${measured[$k]}"
    prev="$(awk -v k="$k" '$1 == k { print $2 }' "$FLOOR" 2>/dev/null)"
    if [ -n "$prev" ] && [ "$(rank "$prev")" -gt "$(rank "$keep")" ]; then keep="$prev"; fi
    echo "$k $keep" >> "$FLOOR.new"
  done
  mv "$FLOOR.new" "$FLOOR"
  echo "  floor written: $(printf '%s\n' "${!measured[@]}" | wc -l | awk '{print $1}') rows"
fi
floor_bad=0
while read -r key phase; do
  case "$key" in ""|\#*) continue ;; esac
  if [ "$SKIP_COMPILE_NATIVE" -eq 1 ] && [ "$key" = "$COMPILE_NATIVE_ROOT" ]; then continue; fi
  want=$(rank "$phase")
  got_phase="${measured[$key]:-missing}"
  got=$(rank "$got_phase")
  if [ "$got" -lt "$want" ]; then
    echo "  $key: FALLS below the floor ($got_phase < $phase)"
    floor_bad=$((floor_bad + 1))
  fi
done < "$FLOOR"
if [ "$floor_bad" -gt 0 ]; then
  status=1
else
  echo "  every measured phase is at or above the floor"
fi
for k in "${!measured[@]}"; do
  if [ "$(rank "${measured[$k]}")" -ge 0 ] && ! awk -v k="$k" '$1 == k { found = 1 } END { exit !found }' "$FLOOR" 2>/dev/null; then
    echo "  $k: not in the floor (raise the floor with SELFHOST_PIPELINE_RAISE=1)"
    status=1
  fi
done
if [ "$failed" -gt 0 ] || [ "$run_equal" -eq 0 ]; then
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
  IYI_PATH="$REPO/src" "$WORK/tool" "$REPO/$root" -o "$WORK/$name.table" --pipeline typed --prelude --probe-phase --keep-going > "$WORK/$name.table.probe" 2> /dev/null
  for sidecar in names refusals; do [ ! -f "$WORK/$name.table.$sidecar" ] || cp "$WORK/$name.table.$sidecar" "$ARTIFACT_DIR/"; done
  if [ -f "$WORK/$name.table.refusals" ]; then
    awk -F '\t' -v name="$name" '
      ($1 == "body" || $1 == "lowering") {
        rows++
        if ($2 == "top level") { root++; owners[$3]++ } else { defs[$2] = 1 }
      }
      END {
        for (d in defs) ndefs++
        printf "  %s keep-going: %d rows in %d defs, %d root sites\n", name, rows, ndefs, root
        for (owner in owners) printf "    root owner=%s sites=%d\n", owner, owners[owner]
      }' "$WORK/$name.table.refusals"
  fi
  awk '/^table:/' "$WORK/$name.table.probe" | sed "s#$REPO/##g" >> "$WORK/table.lines"
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
imported_array_check() {
  local tool="$1"
  local fixture="$REPO/bench/fixtures/pipeline_unit_cvar_array.iyi"
  rm -f "$WORK/unit_array"
  IYI_PATH="$REPO/src" "$tool" "$fixture" -o "$WORK/unit_array" --pipeline typed --prelude --probe-phase > "$WORK/unit_array.log" 2>&1 || return 1
  codesign -v --strict "$WORK/unit_array" > /dev/null 2>&1 || return 1
  timeout 30 "$WORK/unit_array" > "$WORK/unit_array.out" 2>&1
}
if imported_array_check "$WORK/tool"; then
  echo "  imported array initializes and retains its contents"
else
  echo "  FAIL: imported class-variable array did not run"
  status=1
fi

virtual_ivar_check() {
  local tool="$1"
  local fixture="$REPO/bench/fixtures/pipeline_virtual_ivar.iyi"
  rm -f "$WORK/virtual_ivar"
  IYI_PATH="$REPO/src" "$tool" "$fixture" -o "$WORK/virtual_ivar" --pipeline typed --prelude --probe-phase > "$WORK/virtual_ivar.log" 2>&1 || return 1
  codesign -v --strict "$WORK/virtual_ivar" > /dev/null 2>&1 || return 1
  timeout 30 "$WORK/virtual_ivar" > "$WORK/virtual_ivar.out" 2>&1
}
if IYI_PATH="$REPO/src" "$IYI" run "$REPO/bench/fixtures/pipeline_virtual_ivar.iyi" > "$WORK/virtual_ivar.hosted" 2>&1 && virtual_ivar_check "$WORK/tool"; then
  echo "  virtual instance-variable declarations run on hosted and native"
else
  echo "  FAIL: virtual instance-variable declaration"
  status=1
fi

echo "== 4c. Imported digest's atomic class variable"
if IYI_PATH="$REPO/src" "$IYI" run "$REPO/bench/fixtures/pipeline_import_digest.iyi" > "$WORK/digest.hosted" 2>&1 &&
   IYI_PATH="$REPO/src" "$WORK/tool" "$REPO/bench/fixtures/pipeline_import_digest.iyi" -o "$WORK/digest" --pipeline typed --prelude --probe-phase > "$WORK/digest.log" 2>&1 &&
   codesign -v --strict "$WORK/digest" > /dev/null 2>&1 &&
   timeout 30 "$WORK/digest" > "$WORK/digest.out" 2>&1; then
  echo "  imported digest initializer runs on hosted and native"
else
  echo "  FAIL: imported digest initializer"
  status=1
fi

echo "== 4d. Nested imports preserve dependency initialization"
nested_import_check() {
  local tool="$1"
  rm -f "$WORK/nested_import"
  IYI_PATH="$REPO/src" "$tool" "$REPO/bench/fixtures/pipeline_import_nested.iyi" -o "$WORK/nested_import" --pipeline typed --prelude --probe-phase > "$WORK/nested_import.log" 2>&1 || return 1
  codesign -v --strict "$WORK/nested_import" > /dev/null 2>&1 || return 1
  timeout 30 "$WORK/nested_import" > "$WORK/nested_import.out" 2>&1
}
if IYI_PATH="$REPO/src" "$IYI" run "$REPO/bench/fixtures/pipeline_import_nested.iyi" > "$WORK/nested_import.hosted" 2>&1 && nested_import_check "$WORK/tool"; then
  echo "  nested class and module imports initialize their shared dependency"
else
  echo "  FAIL: nested import initializer"
  status=1
fi
for bad in pipeline_import_cycle pipeline_import_missing; do
  rm -f "$WORK/$bad"
  IYI_PATH="$REPO/src" "$IYI" run "$REPO/bench/fixtures/$bad.iyi" > "$WORK/$bad.hosted" 2>&1; hs=$?
  IYI_PATH="$REPO/src" "$WORK/tool" "$REPO/bench/fixtures/$bad.iyi" -o "$WORK/$bad" --pipeline typed --prelude --probe-phase > "$WORK/$bad.native" 2>&1; ns=$?
  if [ "$bad" = pipeline_import_cycle ]; then expected="import cycle"; else expected="can't find module 'pipeline_nonexistent_dependency'"; fi
  if [ "$hs" -eq 0 ] || [ "$ns" -eq 0 ] || [ -e "$WORK/$bad" ] || ! grep -Fq "$expected" "$WORK/$bad.hosted" || ! grep -Fq "$expected" "$WORK/$bad.native"; then
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
  if ! build_tool "$TOOL_SRC" "$WORK/mut_tool"; then return 1; fi
  local a="$REPO/bench/fixtures/lower_exit.iyi"
  local b="$REPO/bench/fixtures/lower_instance_sizeof.iyi"
  rm -f "$WORK/mut_a" "$WORK/mut_b"
  "$WORK/mut_tool" "$a" -o "$WORK/mut_a" --pipeline typed > /dev/null 2>&1; local sa=$?
  [ "$sa" -eq 0 ] || return 1
  codesign -v --strict "$WORK/mut_a" > /dev/null 2>&1 || { echo "  lower_exit: FAIL, native signature invalid"; [ "${_PM_ARMED:-0}" = 1 ] && return 0; return 1; }
  timeout 30 "$WORK/mut_a" > /dev/null 2>&1; [ "$?" -eq 42 ] || return 1
  "$WORK/mut_tool" "$b" -o "$WORK/mut_b" --pipeline typed > /dev/null 2>&1; local sb=$?
  [ "$sb" -ne 0 ] || return 1
  [ ! -e "$WORK/mut_b" ] || return 1
  return 0
}

imported_array_mutation_check() {
  build_tool "$TOOL_SRC" "$WORK/unit_array_tool" || { [ "${_PM_ARMED:-0}" = 1 ] && return 0; return 1; }
  imported_array_check "$WORK/unit_array_tool"
}
prove_mutation "an existing allocator declaration is defined a second time" "$LOWER_SRC" \
  'fn = declared_or_defined_fun(low, name, fun_def_type(low, rec, ret))' \
  'fn = low.module.define_function(name, fun_def_type(low, rec, ret))' -- imported_array_mutation_check || status=1
prove_mutation "a unit module wrapper does not type its class-variable initializer" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  $'    # semantic_visitor.cr:1811-1828 visits either resolved module body.\n    if t && t.is_a?(ModuleType)' \
  $'    # semantic_visitor.cr:1811-1828 visits either resolved module body.\n    if t && t.is_a?(ClassType)' -- imported_array_mutation_check || status=1

virtual_ivar_mutation_check() {
  build_tool "$TOOL_SRC" "$WORK/virtual_ivar_tool" || { [ "${_PM_ARMED:-0}" = 1 ] && return 0; return 1; }
  virtual_ivar_check "$WORK/virtual_ivar_tool"
}
prove_mutation "an initialized instance variable loses its virtual type" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  $'          # including its virtual type; visiting its initializer must retain it.\n          ivar = mod_type.instance_vars[ivar_node.name]?' \
  $'          # including its virtual type; visiting its initializer must retain it.\n          ivar = nil' -- virtual_ivar_mutation_check || status=1
prove_mutation "an uninitialized instance variable loses its virtual type" "$REPO/src/compiler/semantic/main_visitor.iyi" \
  $'          # Preserve the declaration pass\047s virtualized field type and metadata.\n          ivar = mod_type.instance_vars[ivar_node.name]?' \
  $'          # Preserve the declaration pass\047s virtualized field type and metadata.\n          ivar = nil' -- virtual_ivar_mutation_check || status=1

nested_import_mutation_check() {
  build_tool "$TOOL_SRC" "$WORK/nested_import_tool" || { [ "${_PM_ARMED:-0}" = 1 ] && return 0; return 1; }
  nested_import_check "$WORK/nested_import_tool"
}
prove_mutation "the loader omits class-scoped imports" "$REPO/src/compiler/loader.iyi" \
  'collect_import_paths(node.as(ClassDef).body, into, engine, filename, user_imports)' \
  'nil' -- nested_import_mutation_check || status=1
prove_mutation "the loader omits module-scoped imports" "$REPO/src/compiler/loader.iyi" \
  'collect_import_paths(node.as(ModuleDef).body, into, engine, filename, user_imports)' \
  'nil' -- nested_import_mutation_check || status=1
prove_mutation "a resolved import is refused during lowering" "$LOWER_SRC" \
  'if node.is_a?(ImportDecl)' 'if false && node.is_a?(ImportDecl)' -- nested_import_mutation_check || status=1

# The lowering table names and counts no Primitive-annotated def. The hosted compiler lowers a primitive at its call
# site, so a probe of such a def's body is a refusal row for a def that is never a function of its own. The hello
# root with its prelude reaches them; the table must name none. Prelude-free fixtures reach only the stand-in's
# binary operators (lower/program.iyi), so this check runs the root.
primitive_table_check() {
  if ! build_tool "$TOOL_SRC" "$WORK/prim_tool"; then return 1; fi
  IYI_PATH="$REPO/src" "$WORK/prim_tool" "$REPO/samples/iyi/hello.iyi" -o "$WORK/prim_hello" --pipeline typed --prelude --probe-phase --keep-going > "$WORK/prim_hello.probe" 2> /dev/null
  awk '/^table: hello defs-lowered-clean=/ { ok = 1 } END { exit !ok }' "$WORK/prim_hello.probe" || return 1
  awk '/^table: hello lowering .*visit\(Primitive/ { bad = 1 } END { exit bad }' "$WORK/prim_hello.probe"
}

# A yielding def without a captured block is inlined by the hosted compiler, not
# emitted as a standalone function. Its caller and ordinary defs remain probeable.
yield_table_check() {
  if ! build_tool "$TOOL_SRC" "$WORK/yield_tool"; then return 1; fi
  "$WORK/yield_tool" "$REPO/bench/fixtures/pipeline_yield_probe.iyi" -o "$WORK/yield_probe" --pipeline typed --probe-phase --keep-going > "$WORK/yield_probe.log" 2>&1
  [ -f "$WORK/yield_probe.refusals" ] || return 1
  awk -F '\t' '
    $1 == "reached" && $2 ~ /identity$/ { ordinary = 1 }
    $1 == "reached" && $2 ~ /emit_once$/ { yielding = 1 }
    END { exit !(ordinary && !yielding) }
  ' "$WORK/yield_probe.refusals"
}
echo "  the yielding-def table check passes on the unmutated code:"
if yield_table_check; then
  echo "    unmutated: pass"
else
  echo "    unmutated: FAIL"
  status=1
fi
prove_mutation "the table probes a noncapturing yielding def" "$PROGRAM_SRC" \
  'next if noncapturing_yield?(d)' 'next if false' -- yield_table_check || status=1

# The recorded origin is the function being emitted, not necessarily an inlined
# callee. A nested refusal must identify the emitted inner function, not the probe.
origin_table_check() {
  if ! build_tool "$TOOL_SRC" "$WORK/origin_tool"; then return 1; fi
  "$WORK/origin_tool" "$REPO/bench/fixtures/pipeline_refusal_origin.iyi" -o "$WORK/origin_probe" --pipeline typed --probe-phase --keep-going > "$WORK/origin_probe.log" 2>&1
  [ -f "$WORK/origin_probe.refusals" ] || return 1
  awk -F '\t' '$1 == "lowering" && $2 ~ /pipeline_outer$/ && $5 ~ /pipeline_inner/ { found = 1 } END { exit !found }' "$WORK/origin_probe.refusals"
}
echo "  the refusal-origin check passes on the unmutated code:"
if origin_table_check; then
  echo "    unmutated: pass"
else
  echo "    unmutated: FAIL"
  status=1
fi
prove_mutation "a refusal is attributed to the probe instead of the emitted function" "$PROGRAM_SRC" \
  'origin = ctx.fun.name' 'origin = lowering_example(d, inst.self_type)' -- origin_table_check || status=1

# Promote the prelude-free exit fixture to a root and compare the two actual
# executables through the same helper the root loop uses.
root_comparison_check() {
  if ! build_tool "$TOOL_SRC" "$WORK/root_tool"; then return 1; fi
  local fixture="$REPO/bench/fixtures/lower_exit.iyi"
  "$WORK/root_tool" "$fixture" -o "$WORK/root_test" --pipeline typed --probe-phase > "$WORK/root_test.log" 2>&1 || return 1
  [ "$(probe_phase "$WORK/root_test.log")" = "link" ] || return 1
  "$IYI" build --prelude empty -o "$WORK/root_hosted" "$fixture" > "$WORK/root_hosted.log" 2>&1 || return 1
  codesign -v --strict "$WORK/root_test" > /dev/null 2>&1 || { echo "  lower_exit root: FAIL, native signature invalid"; [ "${_PM_ARMED:-0}" = 1 ] && return 0; return 1; }
  "$WORK/root_test" > "$WORK/root_test.out" 2>&1; local ts=$?
  "$WORK/root_hosted" > "$WORK/root_hosted.out" 2>&1; local hs=$?
  bash -c '. "$1"; pipeline_outputs_equal "$2" "$3" "$4" "$5"' _ "$REPO/bench/lib/pipeline_report.sh" "$ts" "$hs" "$WORK/root_test.out" "$WORK/root_hosted.out" || return 1
  ! bash -c '. "$1"; pipeline_outputs_equal "$2" 43 "$3" "$4"' _ "$REPO/bench/lib/pipeline_report.sh" "$ts" "$WORK/root_test.out" "$WORK/root_hosted.out"
}
echo "  the linked-root comparison passes on the unmutated code:"
if root_comparison_check; then
  echo "    unmutated: pass"
else
  echo "    unmutated: FAIL"
  status=1
fi
prove_mutation "the linked-root comparison rejects equal statuses" "$REPO/bench/lib/pipeline_report.sh" \
  '[ "$typed_status" = "$hosted_status" ]' '[ "$typed_status" != "$hosted_status" ]' -- root_comparison_check || status=1

# The headline must carry the first real refusal, not a phase pass or a later line.
headline_check() {
  if ! build_tool "$TOOL_SRC" "$WORK/headline_tool"; then return 1; fi
  "$WORK/headline_tool" "$REPO/bench/fixtures/lower_instance_sizeof.iyi" -o "$WORK/headline_test" --pipeline typed --probe-phase > "$WORK/headline_test.log" 2>&1
  local line
  line="$(bash -c '. "$1"; pipeline_first_refusal "$2"' _ "$REPO/bench/lib/pipeline_report.sh" "$WORK/headline_test.log")"
  case "$line" in *"lower: fail:"*"InstanceSizeOf"*) return 0 ;; *) return 1 ;; esac
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
  if ! build_tool "$TOOL_SRC" "$WORK/entry_tool"; then return 1; fi
  "$WORK/entry_tool" "$REPO/bench/fixtures/lower_exit.iyi" -o "$WORK/entry_exit.ll" --pipeline typed --emit ir > /dev/null 2>&1 || return 1
  "$WORK/entry_tool" "$REPO/bench/fixtures/lower_fun_main.iyi" -o "$WORK/entry_fm.ll" --pipeline typed --emit ir > /dev/null 2>&1 || return 1
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
else
  echo "    unmutated: FAIL (the mutation check cannot prove anything)"
  status=1
fi
prove_mutation "a refusal exits 0 and writes nothing" "$COMPILER_SRC" \
  '@refusal = "#{phase}: #{message}"' '@refusal = nil' -- pipeline_check || status=1
prove_mutation "the program's top-level code is dropped" "$PROGRAM_SRC" \
  "top_level.each { |t| nodes << t }" "nodes << Nop.new" -- pipeline_check || status=1
prove_mutation "the tool falls back to the codegen pipeline when the typed one refuses" "$TOOL_SRC" \
  "fail(refusal.as(String))" "compiler.config.typed_pipeline = false; compiler.refusal = nil; compiler.compile(input)" -- pipeline_check || status=1
echo "  the table check passes on the unmutated code:"
if primitive_table_check; then
  echo "    unmutated: pass"
else
  echo "    unmutated: FAIL (the table check cannot prove anything)"
  status=1
fi
prove_mutation "the lowering table probes a Primitive-annotated def" "$PROGRAM_SRC" \
  $'next unless primitive_name(d.body).nil?\n    next if noncapturing_yield?(d)' $'next if false\n    next if noncapturing_yield?(d)' -- primitive_table_check || status=1
prove_mutation "a prelude-free program's top-level code is named __iyi_main" "$LOWER_SRC" \
  'return "__crystal_main"' 'return "__iyi_main"' -- entry_check || status=1
# The prelude branch of main_function_name has no proof yet: the prelude does not reach IR in the typed pipeline (strict
# mode raises at main_visitor.iyi:214 on the prelude's macro control, concurrency.iyi:1557), so no fixture can show its name.
prove_mutation "a program that defines its own main gets a second main" "$LOWER_SRC" \
  "unless root_defines_main(root)" "unless false" -- entry_check || status=1
prove_mutation "a program with no main of its own gets no main" "$LOWER_SRC" \
  "unless root_defines_main(root)" "if false" -- entry_check || status=1
echo "  the entry check passes on the unmutated code:"
if entry_check; then
  echo "    unmutated: pass"
else
  echo "    unmutated: FAIL (the entry check cannot prove anything)"
  status=1
fi

# A prelude-free program is Crystal's layout: the class id is field 0, and a string literal
# is the four-field struct. Forcing iyi layout (the old hard-coded true) fails this check.
layout_check() {
  if ! build_tool "$TOOL_SRC" "$WORK/layout_tool"; then return 1; fi
  "$WORK/layout_tool" "$REPO/bench/fixtures/lower_class_new.iyi" -o "$WORK/layout_box.ll" --pipeline typed --emit ir > /dev/null 2>&1 || return 1
  "$WORK/layout_tool" "$REPO/bench/fixtures/lower_string_fields.iyi" -o "$WORK/layout_str.ll" --pipeline typed --emit ir > /dev/null 2>&1 || return 1
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
  if ! "$IYI" build -o "$WORK/loader_if_drv" "$REPO/bench/selfhost_loader_if_exercise.iyi" > "$WORK/loader_if_drv.build" 2>&1; then
    return 1
  fi
  "$WORK/loader_if_drv" "$REPO/bench/fixtures/loader_if_entry.iyi" > "$WORK/loader_if.out" 2> "$WORK/loader_if.err" || return 1
  awk '/loader_if_b/ { b = 1 } /loader_if_a/ { a = 1 } END { exit !(b && !a) }' "$WORK/loader_if.out"
}
echo "  the loader if-require check passes on the unmutated code:"
if loader_if_check; then
  echo "    unmutated: pass"
else
  echo "    unmutated: FAIL (the loader if-require check cannot prove anything)"
  status=1
fi
prove_mutation "the loader reads the first branch of every {% if %}" "$LOADER_SRC" \
  'if report.failure.nil? && !report.skipped' 'if false' -- loader_if_check || status=1

# The same entry must run the selected branch through declarations, lowering and the linker.
pipeline_loader_if_check() {
  if ! build_tool "$TOOL_SRC" "$WORK/loader_pipeline_tool"; then return 1; fi
  "$WORK/loader_pipeline_tool" "$REPO/bench/fixtures/loader_if_entry.iyi" -o "$WORK/loader_entry" --pipeline typed > "$WORK/loader_entry.build" 2>&1 || return 1
  codesign -v --strict "$WORK/loader_entry" > /dev/null 2>&1 || { echo "  loader_entry: FAIL, native signature invalid"; [ "${_PM_ARMED:-0}" = 1 ] && return 0; return 1; }
  "$WORK/loader_entry" > "$WORK/loader_entry.out" 2>&1
  [ "$?" -eq 2 ] || return 1
  [ "$(awk '1' "$WORK/loader_entry.out")" = "b" ]
}
echo "  the selected loader branch runs through the typed pipeline:"
if pipeline_loader_if_check; then
  echo "    unmutated: pass"
else
  echo "    unmutated: FAIL"
  status=1
fi
prove_mutation "post-splice runtime code is dropped" "$COMPILER_SRC" \
  'top_level.concat(runtime_by_unit[mod_info.filename])' 'top_level.concat([] of ASTNode)' -- pipeline_loader_if_check || status=1

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL CHECKS PASSED"
else
  echo "== SOME CHECKS FAILED"
fi
exit "$status"
