#!/usr/bin/env bash
# Prove refusal rows reach the sidecar while body typing is still running.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo 'SKIP: the native executable is a Darwin arm64 Mach-O'
  exit 0
fi
cd "$REPO"
export IYI_PATH="$REPO/src"
unset IYI_TEST_RECORD_FLUSH IYI_TEST_RECORD_BARRIER
IYI="${IYI_COMPILER:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
child=""
stop_child() {
  if [ -n "$child" ]; then
    kill "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    child=""
  fi
}
cleanup() {
  stop_child
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
. "$REPO/bench/lib/mutation.sh"
fixture="$REPO/bench/fixtures/pipeline_streamed_refusal.iyi"

build_compiler() {
  local output="$1" log="$2"
  if ! "$IYI" build -o "$output" "$REPO/src/compiler/tools/compile_native.iyi" >"$log" 2>&1; then
    echo 'native compiler build failed' >&2
    cat "$log" >&2
    return 1
  fi
  if [ "$(uname -s)" = Darwin ]; then
    codesign -v --strict "$output" || return 1
  fi
}

if [ -n "${STREAM_COMPILER:-}" ]; then
  compiler="$STREAM_COMPILER"
  codesign -v --strict "$compiler"
else
  compiler="$WORK/compile_native"
  build_compiler "$compiler" "$WORK/compiler-build.log"
fi
if [ -n "${STREAM_BASELINE:-}" ]; then
  baseline="$STREAM_BASELINE"
  baseline_off=0
  codesign -v --strict "$baseline"
else
  baseline="$compiler"
  baseline_off=1
fi

# Exit 1 only for different final sidecars; exit 2 for an invalid comparison.
compare_completed() {
  local current="$1" reference="$2" reference_off="$3" prefix="$4"
  local kind bin stream_off
  for kind in baseline current; do
    bin="$reference"
    stream_off="$reference_off"
    if [ "$kind" = current ]; then bin="$current"; stream_off=0; fi
    env IYI_NO_REFUSAL_STREAM="$stream_off" "$bin" "$fixture" -o "$prefix.$kind" \
      --pipeline typed --prelude --probe-phase --keep-going >"$prefix.$kind.log" 2>&1 || true
    awk '/^table: / {print}' "$prefix.$kind.log" >"$prefix.$kind.table"
    if ! grep -q '^\[phase\] bodies: pass$' "$prefix.$kind.log" ||
       [ ! -s "$prefix.$kind.table" ] || [ ! -s "$prefix.$kind.refusals" ] ||
       ! grep -q '[^[:space:]]' "$prefix.$kind.refusals"; then
      echo "invalid $kind comparison: missing completed bodies, table, or nonempty sidecar" >&2
      cat "$prefix.$kind.log" >&2
      return 2
    fi
  done
  if grep -q '^record[[:space:]]' "$prefix.baseline.refusals"; then
    echo 'baseline sidecar still contains live stream events' >&2
    return 2
  fi
  if ! cmp -s "$prefix.baseline.table" "$prefix.current.table"; then
    echo 'completed tables differ' >&2
    return 2
  fi
  if ! cmp -s "$prefix.baseline.refusals" "$prefix.current.refusals"; then
    echo 'completed refusal sidecars differ' >&2
    return 1
  fi
}

make_tail() {
  local directory="$1" count="$2" i
  mkdir -p "$directory"
  {
    cat "$fixture"
    for ((i=0; i<count; i++)); do printf 'value_%d = %d\n' "$i" "$i"; done
  } >"$directory/stream_tail.iyi"
}

# Return 1 for a missing live record after completed typing or the deadline;
# return 2 for a compiler failure or an invalid observation.
check_stream() {
  local bin="$1" directory="$2" deadline="$3" started elapsed rc
  local output="$directory/stream"
  rm -f "$output.refusals" "$output.log" "$directory/snapshot"
  started=$SECONDS
  env IYI_NO_REFUSAL_STREAM=0 "$bin" "$directory/stream_tail.iyi" -o "$output" \
    --pipeline typed --prelude --probe-phase --keep-going >"$output.log" 2>&1 &
  child=$!
  while [ "$((SECONDS - started))" -lt "$deadline" ]; do
    if [ -s "$output.refusals" ] &&
       grep -q '^record[[:space:]]' "$output.refusals" &&
       grep -q 'missing_streamed_method' "$output.refusals" &&
       grep -q 'streaming_example' "$output.refusals" &&
       grep -q 'stream_tail.iyi:2:' "$output.refusals"; then
      cat "$output.refusals" >"$directory/snapshot"
      if grep -q '^record[[:space:]]' "$directory/snapshot" &&
         grep -q 'missing_streamed_method' "$directory/snapshot" &&
         grep -q 'streaming_example' "$directory/snapshot" &&
         grep -q 'stream_tail.iyi:2:' "$directory/snapshot"; then
        if ! kill -0 "$child" 2>/dev/null || grep -q '^\[phase\] bodies: pass$' "$output.log"; then
          echo 'stream was observed only after typing or process exit' >&2
          stop_child
          return 1
        fi
        elapsed=$((SECONDS - started))
        stop_child
        echo "streamed refusal visible while typing after ${elapsed}s"
        return 0
      fi
    fi
    if ! kill -0 "$child" 2>/dev/null; then
      # Recheck after exit: a refusal can arrive between the first read and kill -0.
      if [ -s "$output.refusals" ] && grep -q 'missing_streamed_method' "$output.refusals"; then
        echo 'compiler exited before a live refusal could be observed' >&2
      else
        echo 'compiler exited before the first streamed refusal' >&2
      fi
      rc=2
      if grep -q '^\[phase\] bodies: pass$' "$output.log"; then rc=1; fi
      stop_child
      [ "$rc" -eq 1 ] || cat "$output.log" >&2
      return "$rc"
    fi
    sleep 0.05
  done
  echo "streamed refusal did not arrive within ${deadline}s" >&2
  rc=2
  if kill -0 "$child" 2>/dev/null &&
     grep -q '^\[phase\] bodies: start$' "$output.log" &&
     ! grep -q '^\[phase\] bodies: pass$' "$output.log"; then rc=1; fi
  stop_child
  [ "$rc" -eq 1 ] || cat "$output.log" >&2
  return "$rc"
}

compare_completed "$compiler" "$baseline" "$baseline_off" "$WORK/completed"
echo 'completed tables and nonempty refusal sidecars match'
make_tail "$WORK/full" 12000
check_stream "$compiler" "$WORK/full" 900

# At the mutant's checkpoint, the compiler has buffered the target record and
# blocks opening a FIFO. The same binary is run once with the flush enabled and
# once without it, so a later rollback or buffer overflow cannot mask the loss.
check_flush_checkpoint() {
  local bin="$1" directory="$2" flush="$3" started rc
  local output="$directory/stream"
  make_tail "$directory" 0 || return 2
  mkfifo "$directory/checkpoint" || return 2
  started=$SECONDS
  env IYI_NO_REFUSAL_STREAM=0 IYI_TEST_RECORD_FLUSH="$flush" \
    IYI_TEST_RECORD_BARRIER="$directory/checkpoint" "$bin" "$directory/stream_tail.iyi" \
    -o "$output" --pipeline typed --prelude --probe-phase --keep-going >"$output.log" 2>&1 &
  child=$!
  while [ "$((SECONDS - started))" -lt 900 ]; do
    if grep -Fq "MUTATION_STREAM_RECORD_BUFFERED	$directory/stream_tail.iyi:2:3" "$output.log"; then
      if ! kill -0 "$child" 2>/dev/null ||
         ! grep -q '^\[phase\] bodies: start$' "$output.log" ||
         grep -q '^\[phase\] bodies: pass$' "$output.log"; then
        echo 'invalid record-flush checkpoint' >&2
        stop_child
        return 2
      fi
      rc=1
      if [ -s "$output.refusals" ] &&
         grep -q '^record[[:space:]]' "$output.refusals" &&
         grep -q 'missing_streamed_method' "$output.refusals" &&
         grep -q 'streaming_example' "$output.refusals" &&
         grep -q 'stream_tail.iyi:2:' "$output.refusals"; then rc=0; fi
      stop_child
      return "$rc"
    fi
    if ! kill -0 "$child" 2>/dev/null; then
      echo 'compiler exited before the record-flush checkpoint' >&2
      stop_child
      cat "$output.log" >&2
      return 2
    fi
    sleep 0.05
  done
  echo 'record-flush checkpoint did not arrive' >&2
  stop_child
  cat "$output.log" >&2
  return 2
}

check_missing_flush_mutation() {
  local rc
  if ! build_compiler "$WORK/mutant-flush" "$WORK/mutant-flush.build.log" ||
     ! compare_completed "$WORK/mutant-flush" "$WORK/mutant-flush" 1 "$WORK/mutant-flush.completed"; then
    return 0
  fi
  if ! check_flush_checkpoint "$WORK/mutant-flush" "$WORK/flush-control" 1; then
    echo 'the flush-enabled checkpoint did not expose the record' >&2
    return 0
  fi
  if check_flush_checkpoint "$WORK/mutant-flush" "$WORK/flush-removed" 0; then
    echo 'the unflushed record was unexpectedly visible' >&2
    return 0
  else
    rc=$?
  fi
  if [ "$rc" -eq 1 ]; then return 1; fi
  echo 'mutation did not reach a valid missing-flush observation' >&2
  return 0
}

check_final_sidecar_mutation() {
  local rc
  if ! build_compiler "$WORK/mutant-sidecar" "$WORK/mutant-sidecar.build.log"; then
    return 0
  fi
  if compare_completed "$WORK/mutant-sidecar" "$WORK/mutant-sidecar" 1 "$WORK/mutant-sidecar.completed"; then
    return 0
  else
    rc=$?
  fi
  if [ "$rc" -eq 1 ] &&
     grep -q '^record[[:space:]]' "$WORK/mutant-sidecar.completed.current.refusals"; then
    return 1
  fi
  echo 'mutation did not reach a valid final-sidecar comparison' >&2
  return 0
}

prove_mutation 'record flush makes refusals visible during typing' "$REPO/src/compiler/semantic/main_visitor.iyi" \
  '#{node.node_id}")
      stream.flush
    end
    @refusals <<' \
  '#{node.node_id}")
      if ENV["IYI_TEST_RECORD_FLUSH"]? == "1"
        stream.flush
      end
      if checkpoint = ENV["IYI_TEST_RECORD_BARRIER"]?
        STDERR.puts("MUTATION_STREAM_RECORD_BUFFERED\t#{site}")
        STDERR.flush
        File.read(checkpoint)
      end
    end
    @refusals <<' -- check_missing_flush_mutation
echo 'checkpoint: flush-enabled record visible; unflushed record buffered'
prove_mutation 'final sidecar replaces the live event stream' "$REPO/src/compiler/compiler.iyi" \
  '      File.write(@config.output_filename + ".refusals", refused.join("\n") + "\n")' \
  '      File.write(@config.output_filename + ".refusals", refused.join("\n") + "\n") unless stream' \
  -- check_final_sidecar_mutation
