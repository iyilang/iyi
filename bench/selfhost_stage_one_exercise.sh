#!/usr/bin/env bash
# Proves stage one exists as its own executable: the whole compiler source
# under src/compiler, built by the bootstrap compiler (bin/iyi) into
# .build/iyi-stage1, dispatched through the ported command driver.
#
# The heap boundary finding (STAGE_ONE.md) killed the in-process wiring
# frame: a Crystal method cannot dispatch on an ast.iyi node, so stage one
# is a separate executable and the wiring is a process boundary.
#
# This gate measures the phase the stage-one binary reaches, holds it
# against a committed floor, and proves the gate goes red under a guarded
# mutation confirmed to change the file.
#
#   bash bench/selfhost_stage_one_exercise.sh
#
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
. "$REPO/bench/floor_base.sh" || exit 1
REPO_NATIVE="$(native_path "$REPO")" || exit 1
BOOTSTRAP="$REPO/bin/iyi"
ENTRY="$REPO/src/compiler/stage1.iyi"
MUT_TARGET="$REPO/src/compiler/command/driver.iyi"
WORK="$(mktemp -d)"
WORK_NATIVE="$(native_path "$WORK")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
. "$REPO/bench/lib/mutation.sh"
. "$REPO/bench/lib/tripwire.sh"
. "$REPO/bench/lib/native_signature.sh"
STAGE1="$REPO/.build/iyi-stage1$EXE"
MUT_BINARY="$REPO/.build/iyi-stage1-mut-$$$EXE"
ORIGINAL_PATH="$PATH"
mkdir -p "$WORK/tmp" "$WORK/out" "$WORK/out2" "$WORK/dir"
tripwire_setup "$WORK/tripwire" "$WORK/tripwire.log" || exit 1

run_stage1() {
  local arg
  local -a native_args=()
  for arg in "$@"; do
    case "$arg" in
      "$REPO"/*|"$WORK"/*) arg="$(native_path "$arg")" || return 2 ;;
    esac
    native_args+=("$arg")
  done
  env -u IYI_PATH -u CRYSTAL_PATH -u IYI_OPTS \
    TMPDIR="$WORK_NATIVE/tmp" PATH="$TRIPWIRE_PATH:$ORIGINAL_PATH" "$STAGE1" "${native_args[@]}"
}

invoke_stage1() {
  run_stage1 "$@" >"$WORK/stdout" 2>"$WORK/stderr"
  RC=$?
}

show_failure() {
  echo "  FAIL: $1"
  [ ! -s "$WORK/stdout" ] || { echo "    stdout:"; cat "$WORK/stdout"; }
  [ ! -s "$WORK/stderr" ] || { echo "    stderr:"; cat "$WORK/stderr"; }
  return 1
}

check_native() {
  local file="$1" libs
  [ -x "$file" ] || { echo "  FAIL: no executable at $file"; return 1; }
  native_signature_ok "$file" || return 1
  libs="$(/usr/bin/otool -L "$file" 2>/dev/null | awk 'NR>1 {print $1}' | grep -v '^$')"
  if [ -z "$libs" ] || echo "$libs" | grep -qv '^/usr/lib/libSystem.B.dylib$'; then
    echo "  FAIL: $file has non-libSystem dependencies: $libs"
    return 1
  fi
}

execute_native() {
  check_native "$1" || return 1
  "$1" >"$WORK/native.stdout" 2>"$WORK/native.stderr"
  NATIVE_RC=$?
  return 0
}

empty_tmp() {
  [ -z "$(ls -A "$WORK/tmp")" ] || { echo "  FAIL: run left files in $WORK/tmp"; ls -A "$WORK/tmp"; return 1; }
}
cleanup() {
  rm -rf "$WORK"
  rm -f "$MUT_BINARY"
}
trap cleanup EXIT
if [ "$HOST_OS" = darwin ] && command -v brew >/dev/null 2>&1; then LIBRARY_PATH="$(brew --prefix bdw-gc)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"; export LIBRARY_PATH; fi
export IYI_CACHE_DIR="${IYI_CACHE_DIR:-$WORK_NATIVE/cache}"

echo "== 1. Building the stage-one executable from src/compiler/stage1.iyi"
cd "$REPO"
rm -f "$STAGE1"
if ! LLVM_CONFIG="$(native_path "$TRIPWIRE_PATH/llvm-config")" "$BOOTSTRAP" build -o "$(native_path "$STAGE1")" "$(native_path "$ENTRY")" > "$WORK/build.log" 2>&1; then
  echo "  stage-one build failed:"
  cat "$WORK/build.log"
  exit 1
fi
if [ ! -x "$STAGE1" ]; then
  echo "  ERROR: .build/iyi-stage1$EXE was not built"
  exit 1
fi
echo "  built .build/iyi-stage1$EXE successfully"

echo
echo "== 2. Dependency floor on the stage-one binary itself"
# Inspect the host executable's dependency floor with the native platform tool.
case "$HOST_OS" in
  darwin)
    if ! command -v otool >/dev/null 2>&1; then
      echo "  ERROR: otool not found; the Darwin dependency floor needs otool -L"
      exit 1
    fi
    libs="$(otool -L "$STAGE1" 2>/dev/null | awk 'NR>1 {print $1}' | grep -v '^$')"
    echo "$libs" | sed 's/^/    /'
    if [ -z "$libs" ] || echo "$libs" | grep -qv '/usr/lib/libSystem.B.dylib'; then
      echo "  FLOOR BROKEN: the stage-one binary links more than the platform libc"
      status=1
    else
      echo "  stage-one binary links only the platform libc"
    fi
    ;;
  linux)
    if ! command -v readelf >/dev/null 2>&1; then
      echo "  ERROR: readelf not found; the Linux dependency floor needs readelf -d"
      exit 1
    fi
    # NEEDED entries print as "Shared library: [name]" in readelf -d output.
    libs="$(readelf -d "$STAGE1" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | sort -u)"
    echo "$libs" | sed 's/^/    /'
    bad="$(echo "$libs" | grep -v -E '^(libc\.so|ld-linux|libgcc_s)' || true)"
    if [ -z "$libs" ] || [ -n "$bad" ]; then
      echo "  FLOOR BROKEN: the stage-one binary links more than the platform libc"
      status=1
    else
      echo "  stage-one binary links only the platform libc"
    fi
    ;;
  windows)
    DUMPBIN="$(find_dumpbin || true)"
    if [ -z "$DUMPBIN" ] || ! "$DUMPBIN" -nologo -dependents "$(native_path "$STAGE1")" >"$WORK/stage1.dlls" 2>&1; then
      echo "  ERROR: dumpbin could not inspect the stage-one dependency floor"
      [ ! -f "$WORK/stage1.dlls" ] || cat "$WORK/stage1.dlls"
      exit 1
    fi
    real_dumpbin="$DUMPBIN"
    dumpbin_lf() { tr -d '\r' <"$WORK/stage1.dlls"; }
    DUMPBIN=dumpbin_lf
    libs="$(pe_dlls "$(native_path "$STAGE1")")"
    DUMPBIN="$real_dumpbin"
    bad="$(extra_dlls "$FLOOR_DLLS_RUNTIME" "$libs")"
    printf '    %s\n' "$libs"
    if [ -z "$libs" ] || [ -n "$bad" ]; then
      echo "  FLOOR BROKEN: the stage-one binary has unexpected DLL dependencies: $bad"
      status=1
    else
      echo "  stage-one binary links only the platform runtime"
    fi
    ;;
esac
if [ "$HOST_OS" = darwin ] && ! check_native "$STAGE1"; then
  echo "  ERROR: refusing to execute an invalid stage-one binary"
  exit 1
fi

echo
echo "== 3. Measuring the stage-one phase against the committed floor"
# Phases: none < link < dispatch < build < run.
# Native build and run are available on Darwin arm64. Other hosts must
# dispatch and refuse both verbs without writing an output.
STAGE1_FLOOR="dispatch"
if [ "$HOST_ID" = darwin-arm64 ]; then
  STAGE1_FLOOR="run"
fi

phase_rank() {
  case "$1" in
    none)     echo 0 ;;
    link)     echo 1 ;;
    dispatch) echo 2 ;;
    build)    echo 3 ;;
    run)      echo 4 ;;
    *)        echo -1 ;;
  esac
}

probe_stage1() {
  local out="$WORK/probe.out"
  local ok=1
  # version answers
  run_stage1 version > "$out" 2>&1 || ok=0
  expected_version="iyi $(tr -d ' \r\n' < "$REPO/src/IYI_VERSION")"
  grep -qF "$expected_version" "$out" || ok=0
  local expected_target="${IYI_CONFIG_TARGET:-}"
  if [ -z "$expected_target" ]; then
    case "$HOST_ID" in
      darwin-arm64) expected_target=aarch64-apple-darwin ;;
      darwin-x86_64) expected_target=x86_64-apple-darwin ;;
      linux-arm64) expected_target=aarch64-unknown-linux-gnu ;;
      linux-x86_64) expected_target=x86_64-unknown-linux-gnu ;;
      windows-x86_64) expected_target=x86_64-pc-windows-msvc ;;
      *) echo "unsupported stage-one target: $HOST_ID" >&2; return 1 ;;
    esac
  fi
  case "$expected_target" in arm64-*) expected_target="aarch64-${expected_target#arm64-}" ;; esac
  grep -Fq "Default target: $expected_target" "$out" || ok=0
  if grep -q '^LLVM:' "$out"; then ok=0; fi
  # help answers with the command banner
  run_stage1 help > "$out" 2>&1 || ok=0
  grep -q "Usage: iyi \[command\]" "$out" || ok=0
  # tool usage answers
  run_stage1 tool > "$out" 2>&1 || ok=0
  grep -q "Usage: iyi tool" "$out" || ok=0
  # unknown command is refused with exit 1
  run_stage1 definitely_not_a_command > "$out" 2>&1
  [ "$?" -eq 1 ] || ok=0
  grep -q "unknown command: definitely_not_a_command" "$out" || ok=0
  if [ "$ok" -eq 1 ]; then
    echo "dispatch"
  else
    echo "link"
  fi
}

case_run() {
  local name="$1"
  shift
  if "$@"; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name"
    status=1
  fi
}

check_hello_build() {
  local hello="$REPO/samples/iyi/hello.iyi"
  "$BOOTSTRAP" run "$hello" >"$WORK/hello.expected" 2>"$WORK/hello.hosted.stderr"
  local expected_rc=$?
  if [ "$expected_rc" -ne 0 ]; then
    echo "  FAIL: hosted hello exited $expected_rc"; cat "$WORK/hello.hosted.stderr"; return 1
  fi
  rm -f "$WORK/out/hello"
  invoke_stage1 build "$hello" -o "$WORK/out/hello"
  [ "$RC" -eq 0 ] && [ ! -s "$WORK/stdout" ] && [ ! -s "$WORK/stderr" ] ||
    { show_failure "stage-one hello build exited $RC"; return 1; }
  execute_native "$WORK/out/hello" || return 1
  [ "$NATIVE_RC" -eq "$expected_rc" ] && [ ! -s "$WORK/native.stderr" ] &&
    cmp -s "$WORK/hello.expected" "$WORK/native.stdout" ||
    { echo "  FAIL: stage-one hello differs from the hosted output or status"; return 1; }
}

check_hello_paths() {
  local old_pwd="$PWD" before after
  cd "$WORK" || return 1
  invoke_stage1 build "$REPO/samples/iyi/hello.iyi" -o out2/hello
  cd "$old_pwd" || return 1
  [ "$RC" -eq 0 ] && [ ! -s "$WORK/stdout" ] && [ ! -s "$WORK/stderr" ] ||
    { show_failure "build from another directory exited $RC"; return 1; }
  execute_native "$WORK/out2/hello" && [ "$NATIVE_RC" -eq 0 ] &&
    cmp -s "$WORK/hello.expected" "$WORK/native.stdout" || return 1
  invoke_stage1 build "$REPO/samples/iyi/hello.iyi" -o "$WORK/dir/"
  [ "$RC" -eq 0 ] && [ ! -s "$WORK/stdout" ] && [ ! -s "$WORK/stderr" ] ||
    { show_failure "directory output exited $RC"; return 1; }
  execute_native "$WORK/dir/hello" && [ "$NATIVE_RC" -eq 0 ] &&
    cmp -s "$WORK/hello.expected" "$WORK/native.stdout" || return 1
  before="$(stat -f %i "$WORK/out/hello")"
  invoke_stage1 build "$REPO/samples/iyi/hello.iyi" -o "$WORK/out/hello"
  [ "$RC" -eq 0 ] && [ ! -s "$WORK/stdout" ] && [ ! -s "$WORK/stderr" ] ||
    { show_failure "rebuild exited $RC"; return 1; }
  after="$(stat -f %i "$WORK/out/hello")"
  [ "$before" != "$after" ] || { echo "  FAIL: rebuild reused executable inode $before"; return 1; }
  execute_native "$WORK/out/hello" && [ "$NATIVE_RC" -eq 0 ] &&
    cmp -s "$WORK/hello.expected" "$WORK/native.stdout"
}

check_invalid_sources() {
  printf 'def broken(\n' >"$WORK/parse_error.iyi"
  printf 'unknown_stage_one_name_xyz\n' >"$WORK/name_error.iyi"
  local source
  for source in "$WORK/parse_error.iyi" "$WORK/name_error.iyi" "$WORK/missing.iyi"; do
    rm -f "$WORK/out/invalid"
    invoke_stage1 build "$source" -o "$WORK/out/invalid"
    [ "$RC" -eq 1 ] && [ ! -e "$WORK/out/invalid" ] &&
      grep -q '^Error:' "$WORK/stderr" ||
      { show_failure "invalid source $source exited $RC"; return 1; }
    if [ "$source" = "$WORK/missing.iyi" ]; then
      grep -Fq "Error: no such file: $source" "$WORK/stderr" ||
        { show_failure "missing source had the wrong refusal"; return 1; }
    fi
  done
}

check_run_path() {
  printf 'puts Program.args.join(",")\nexit 3\n' >"$WORK/probe.iyi"
  printf 'alpha,beta\n' >"$WORK/probe.expected"
  printf 'alpha\n' >"$WORK/single.expected"
  printf 'def broken(\n' >"$WORK/parse_error.iyi"
  # The explicit-output form lets us inspect a probe executable before a run.
  rm -f "$WORK/out/probe"
  invoke_stage1 run -o "$WORK/out/probe" "$WORK/probe.iyi"
  [ "$RC" -eq 0 ] && [ ! -s "$WORK/stdout" ] && [ ! -s "$WORK/stderr" ] ||
    { show_failure "run -o exited $RC"; return 1; }
  check_native "$WORK/out/probe" && empty_tmp || return 1
  invoke_stage1 run "$WORK/probe.iyi" -- alpha beta
  [ "$RC" -eq 3 ] && [ ! -s "$WORK/stderr" ] &&
    cmp -s "$WORK/probe.expected" "$WORK/stdout" && empty_tmp ||
    { show_failure "run did not forward arguments and exit 3 (got $RC)"; return 1; }
  invoke_stage1 "$WORK/probe.iyi" alpha
  [ "$RC" -eq 3 ] && [ ! -s "$WORK/stderr" ] &&
    cmp -s "$WORK/single.expected" "$WORK/stdout" && empty_tmp ||
    { show_failure "script form did not forward its argument and exit 3 (got $RC)"; return 1; }
  invoke_stage1 run "$WORK/parse_error.iyi"
  [ "$RC" -eq 1 ] && grep -q '^Error:' "$WORK/stderr" && empty_tmp ||
    { show_failure "run accepted an invalid source (status $RC)"; return 1; }
}

check_unsupported_verb() {
  invoke_stage1 check "$REPO/samples/iyi/hello.iyi"
  [ "$RC" -eq 1 ] && grep -Fq 'check' "$WORK/stderr" ||
    { show_failure "check did not refuse by name"; return 1; }
  invoke_stage1 run --sandbox "$REPO/samples/iyi/hello.iyi"
  [ "$RC" -eq 1 ] && grep -Fq 'run --sandbox' "$WORK/stderr" ||
    { show_failure "run --sandbox did not refuse by name"; return 1; }
  invoke_stage1 build --not-a-real-option
  [ "$RC" -eq 1 ] && grep -Fq -- '--not-a-real-option' "$WORK/stderr" ||
    { show_failure "unknown build option did not refuse by name"; return 1; }
  invoke_stage1 build
  [ "$RC" -eq 1 ] && grep -Fq 'Usage: iyi build' "$WORK/stderr" ||
    { show_failure "missing source did not print build usage"; return 1; }
}

refuse_build() {
  local named="$1"
  shift
  rm -f "$WORK/out/refused" "$WORK/out/refused.o"
  invoke_stage1 build -o "$WORK/out/refused" "$@" "$REPO/samples/iyi/hello.iyi"
  [ "$RC" -eq 1 ] && [ ! -e "$WORK/out/refused" ] && [ ! -e "$WORK/out/refused.o" ] &&
    grep -Fq -- "$named" "$WORK/stderr" ||
    { show_failure "refusal for $named exited $RC"; return 1; }
}

check_unsupported_options() {
  local failed=0
  refuse_build 'multiple source' "$REPO/samples/iyi/hello.iyi" || failed=1
  invoke_stage1 build -o "$WORK/out/refused" --stdin-filename stdin.iyi
  [ "$RC" -eq 1 ] && [ ! -e "$WORK/out/refused" ] && grep -Fq -- '--stdin-filename' "$WORK/stderr" ||
    { show_failure '--stdin-filename'; failed=1; }
  refuse_build --crystal --crystal || failed=1
  refuse_build --prelude --prelude prelude || failed=1
  refuse_build --prelude --prelude other || failed=1
  refuse_build --target --target x86_64-unknown-linux-gnu || failed=1
  refuse_build --cross-compile --cross-compile || failed=1
  refuse_build --emit --emit llvm-ir || failed=1
  refuse_build --emit --emit llvm-bc || failed=1
  refuse_build --emit --emit obj || failed=1
  refuse_build --emit --emit asm || failed=1
  refuse_build --ll --ll || failed=1
  refuse_build --x86-asm-syntax --x86-asm-syntax intel || failed=1
  refuse_build --debug --debug || failed=1
  refuse_build --release --release || failed=1
  refuse_build -O -O 2 || failed=1
  refuse_build -D -D CUSTOM || failed=1
  refuse_build --mcpu --mcpu generic || failed=1
  refuse_build --mattr --mattr +test || failed=1
  refuse_build --mcmodel --mcmodel small || failed=1
  refuse_build --link-flags --link-flags -ltest || failed=1
  refuse_build --static --static || failed=1
  refuse_build --no-codegen --no-codegen || failed=1
  refuse_build '-f json' -f json || failed=1
  refuse_build --error-on-warnings --error-on-warnings || failed=1
  refuse_build --exclude-warnings --exclude-warnings test || failed=1
  refuse_build --stats --stats || failed=1
  refuse_build --progress --progress || failed=1
  refuse_build --time --time || failed=1
  refuse_build --iyi-keep --iyi-keep Test || failed=1
  refuse_build --emit-bind --emit-bind "$WORK/bind" || failed=1
  refuse_build --emit-iyimod --emit-iyimod "$WORK/mods-out" || failed=1
  refuse_build --use-iyimod --use-iyimod "$WORK/mods-in" || failed=1
  printf 'puts 1\n' >"$WORK/foreign.cr"
  invoke_stage1 build -o "$WORK/out/refused" "$WORK/foreign.cr"
  [ "$RC" -eq 1 ] && [ ! -e "$WORK/out/refused" ] && grep -Fq 'foreign.cr' "$WORK/stderr" ||
    { show_failure '.cr boundary'; failed=1; }
  mkdir -p "$WORK/workspace/mods"
  printf 'puts 1\n' >"$WORK/workspace/main.iyi"
  invoke_stage1 build -o "$WORK/out/refused" "$WORK/workspace/main.iyi"
  [ "$RC" -eq 1 ] && [ ! -e "$WORK/out/refused" ] && grep -Fq 'workspace mods' "$WORK/stderr" ||
    { show_failure 'workspace mods'; failed=1; }
  env -u IYI_PATH -u CRYSTAL_PATH TMPDIR="$WORK/tmp" PATH="$TRIPWIRE_PATH:$ORIGINAL_PATH" \
    IYI_OPTS=--release "$STAGE1" build -o "$WORK/out/refused" "$REPO/samples/iyi/hello.iyi" \
    >"$WORK/stdout" 2>"$WORK/stderr"
  RC=$?
  [ "$RC" -eq 1 ] && [ ! -e "$WORK/out/refused" ] && grep -Fq IYI_OPTS "$WORK/stderr" ||
    { show_failure 'IYI_OPTS'; failed=1; }
  [ "$failed" -eq 0 ]
}

check_accepted_options() {
  invoke_stage1 build -o "$WORK/out/accepted" --no-debug --frame-pointers always \
    --single-module --threads 2 --no-color --error-trace --force --verbose \
    -O 0 --warnings none -f text --target aarch64-apple-darwin "$REPO/samples/iyi/hello.iyi"
  [ "$RC" -eq 0 ] && [ ! -s "$WORK/stdout" ] && [ ! -s "$WORK/stderr" ] ||
    { show_failure "accepted options exited $RC"; return 1; }
  execute_native "$WORK/out/accepted" && [ "$NATIVE_RC" -eq 0 ] &&
    cmp -s "$WORK/hello.expected" "$WORK/native.stdout" || return 1
  local fixture="$REPO/bench/fixtures/lowprim_tuple_metaclass.iyi"
  IYI_PATH="$REPO/src" "$BOOTSTRAP" build --prelude empty -o "$WORK/out/empty.hosted" "$fixture" \
    >"$WORK/hosted-empty.log" 2>&1 || { cat "$WORK/hosted-empty.log"; return 1; }
  "$WORK/out/empty.hosted" >"$WORK/empty.expected" 2>"$WORK/empty.hosted.stderr"
  local expected_rc=$?
  invoke_stage1 build --prelude empty -o "$WORK/out/empty" "$fixture"
  [ "$RC" -eq 0 ] && [ ! -s "$WORK/stdout" ] && [ ! -s "$WORK/stderr" ] ||
    { show_failure "empty-prelude fixture exited $RC"; return 1; }
  execute_native "$WORK/out/empty" && [ "$NATIVE_RC" -eq "$expected_rc" ] &&
    cmp -s "$WORK/empty.expected" "$WORK/native.stdout"
}

check_link_annotation() {
  cat >"$WORK/library.iyi" <<'IYI'
@[Link("z")]
lib LibZ
  fun zlibVersion : UInt8*
end
1
IYI
  rm -f "$WORK/out/library"
  invoke_stage1 build --prelude empty -o "$WORK/out/library" "$WORK/library.iyi"
  [ "$RC" -eq 1 ] && [ ! -e "$WORK/out/library" ] && grep -Fq 'library z' "$WORK/stderr" ||
    { show_failure 'library annotation was not refused by the linker'; return 1; }
}

check_source_protection() {
  mkdir -p "$WORK/src/safe"
  cat >"$WORK/src/safe/main.iyi" <<'IYI'
module safe/main
import safe/helper::{answer}
answer
IYI
  cat >"$WORK/src/safe/helper.iyi" <<'IYI'
module safe/helper
pub def answer : Int32
  42
end
IYI
  cat "$WORK/src/safe/main.iyi" >"$WORK/main.original"
  cat "$WORK/src/safe/helper.iyi" >"$WORK/helper.original"
  ln "$WORK/src/safe/main.iyi" "$WORK/root-hardlink"
  ln "$WORK/src/safe/helper.iyi" "$WORK/import-hardlink"
  ln -s "$WORK/src/safe/helper.iyi" "$WORK/import-symlink"
  local verb output
  for verb in build run; do
    for output in "$WORK/src/safe/main.iyi" "$WORK/root-hardlink" \
                  "$WORK/src/safe/helper.iyi" "$WORK/import-hardlink" "$WORK/import-symlink"; do
      invoke_stage1 "$verb" --prelude empty -o "$output" "$WORK/src/safe/main.iyi"
      [ "$RC" -eq 1 ] && grep -Fq 'source' "$WORK/stderr" &&
        cmp -s "$WORK/main.original" "$WORK/src/safe/main.iyi" &&
        cmp -s "$WORK/helper.original" "$WORK/src/safe/helper.iyi" ||
        { show_failure "$verb failed to protect source alias $output"; return 1; }
    done
  done
}

check_other_host() {
  local verb
  for verb in build run; do
    rm -f "$WORK/out/other$EXE"
    invoke_stage1 "$verb" -o "$WORK/out/other$EXE" "$REPO/samples/iyi/hello.iyi"
    [ "$RC" -eq 1 ] && [ ! -e "$WORK/out/other$EXE" ] &&
      grep -Fq 'this host is not one' "$WORK/stderr" ||
      { show_failure "$verb did not refuse on this host"; return 1; }
  done
}

measured_phase="$(probe_stage1)"
primary_ok=0
run_ok=0
if [ "$STAGE1_FLOOR" = run ]; then
  if check_hello_build; then
    echo "  PASS: stage-one builds and runs hello"
    primary_ok=1
    [ "$measured_phase" != dispatch ] || measured_phase=build
  else
    echo "  FAIL: stage-one builds and runs hello"
    status=1
  fi
  if check_run_path; then
    echo "  PASS: stage-one run forwards arguments and status"
    run_ok=1
    [ "$measured_phase" != build ] || measured_phase=run
  else
    echo "  FAIL: stage-one run forwards arguments and status"
    status=1
  fi
  if [ "$primary_ok" -eq 1 ]; then
    case_run "output directories and new-inode rebuild" check_hello_paths
    case_run "accepted options and empty prelude" check_accepted_options
  else
    echo "  NOT PROVEN: output paths, rebuild and accepted-options execution need a working hello build"
  fi
  case_run "invalid and missing sources" check_invalid_sources
  case_run "unsupported options" check_unsupported_options
  case_run "resolved source identity protection" check_source_protection
  case_run "library annotations" check_link_annotation
else
  host_limited 'stage-one native builds, runs, and build/run mutation probes require the Darwin arm64 kernel'
  case_run "build and run refuse this host" check_other_host
fi
case_run "unsupported commands" check_unsupported_verb
if tripwire_fired "$WORK/tripwire.log"; then
  echo "  FAIL: an LLVM or external tool was invoked:"
  cat "$WORK/tripwire.log"
  status=1
elif [ "$HOST_OS" = windows ]; then
  host_limited 'stage-one external-tool tripwire uses POSIX shell shims and cannot establish interception of native Windows process launches'
else
  echo "  PASS: no LLVM or external build tool was invoked"
fi
measured_rank="$(phase_rank "$measured_phase")"
floor_rank="$(phase_rank "$STAGE1_FLOOR")"

matched=0
total=1
regressions=0

if [ "$measured_rank" -ge "$floor_rank" ]; then
  printf "  %-22s %-10s %-10s %s\n" "Unit" "Floor" "Measured" "Status"
  printf "  %-22s %-10s %-10s %s\n" "stage-one exe" "$STAGE1_FLOOR" "$measured_phase" "matched"
  matched=$((matched + 1))
else
  printf "  %-22s %-10s %-10s %s\n" "stage-one exe" "$STAGE1_FLOOR" "$measured_phase" "REGRESSION"
  regressions=$((regressions + 1))
  status=1
fi
echo "  Phase summary: $matched/$total stage-one targets match or exceed committed floor ($regressions regressions)"

echo
echo "== 4. Guarded mutation proof: compile each mutant before probing it"
mutations_caught=0
mutations_run=0

build_mutant() {
  rm -f "$MUT_BINARY"
  if ! LLVM_CONFIG="$(native_path "$TRIPWIRE_PATH/llvm-config")" "$BOOTSTRAP" build -o "$(native_path "$MUT_BINARY")" "$(native_path "$ENTRY")" >"$WORK/mut_build.log" 2>&1; then
    echo "  mutant did not compile; it cannot count as caught"
    cat "$WORK/mut_build.log"
    return 2
  fi
  if [ "$HOST_OS" = darwin ]; then
    check_native "$MUT_BINARY" || return 2
  fi
  STAGE1="$MUT_BINARY"
}

# A failed mutant compilation is not a caught regression. Each check returns
# nonzero only for the particular wrong behaviour the mutation introduces.
check_dispatch_regresses() {
  build_mutant || return 2
  [ "$(phase_rank "$measured_phase")" -ge 2 ] || return 2
  invoke_stage1 version
  if [ "$RC" -eq 0 ] && grep -qx 'mutated' "$WORK/stdout"; then return 1; fi
  return 0
}

check_build_regresses() {
  build_mutant || return 2
  [ "$primary_ok" -eq 1 ] || { echo "  hello baseline failed; mutation detection is unproven"; return 2; }
  rm -f "$WORK/out/mut-build"
  invoke_stage1 build "$REPO/samples/iyi/hello.iyi" -o "$WORK/out/mut-build"
  if [ "$RC" -eq 0 ] && [ ! -e "$WORK/out/mut-build" ]; then return 1; fi
  return 0
}

check_run_regresses() {
  build_mutant || return 2
  [ "$run_ok" -eq 1 ] || { echo "  run baseline failed; mutation detection is unproven"; return 2; }
  invoke_stage1 run "$WORK/probe.iyi" -- alpha beta
  if [ "$RC" -eq 0 ] && cmp -s "$WORK/probe.expected" "$WORK/stdout"; then return 1; fi
  return 0
}

mutations_run=$((mutations_run + 1))
if prove_mutation "version banner severed from the driver" "$MUT_TARGET" \
  "puts CommandDriver.version_description" 'puts "mutated"' \
  -- check_dispatch_regresses; then
  mutations_caught=$((mutations_caught + 1))
else
  status=1
fi
if [ "$STAGE1_FLOOR" = run ]; then
  mutations_run=$((mutations_run + 1))
  if prove_mutation "build returns without compiling" "$REPO/src/compiler/command/execute.iyi" \
    '    compile(opts, opts.output_filename.as(String))' '    0' \
    -- check_build_regresses; then
    mutations_caught=$((mutations_caught + 1))
  else
    status=1
  fi
  mutations_run=$((mutations_run + 1))
  if prove_mutation "run drops the child exit status" "$REPO/src/compiler/command/execute.iyi" \
    '      return child.exit_code' '      return 0' \
    -- check_run_regresses; then
    mutations_caught=$((mutations_caught + 1))
  else
    status=1
  fi
fi
if tripwire_fired "$WORK/tripwire.log"; then
  echo "  FAIL: an LLVM or external tool was invoked during mutation checks"
  cat "$WORK/tripwire.log"
  status=1
fi

echo "  Mutation summary: $mutations_caught/$mutations_run regressions caught"

echo
if [ "$status" -eq 0 ]; then
  echo "ALL SELFHOST STAGE ONE CHECKS PASSED"
else
  echo "SELFHOST STAGE ONE CHECKS FAILED"
fi
exit $status
