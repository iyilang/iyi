#!/usr/bin/env bash
# Whole programs through the native back end (SPEC 2.2; the back half of stage 1). The hosted compiler types and
# lowers a program with the real prelude and writes its LLVM IR; iyi-ir imports that into the iyi IR; the native back
# end compiles and links it with no LLVM and no host tool. The program must then run as the hosted executable runs.
# This is the proof that the back end carries a real program (the allocator, fibers, IO, thread-locals), separate
# from whether the front end written in iyi can produce that IR yet.
#
# 1. iyi-compile-native and iyi-ir build from source. The first links libSystem alone. iyi-ir is the bridge that
#    reads LLVM IR and links LLVM by design; it is not part of the native build.
# 2. Every samples/iyi/*.iyi and bench/fixtures/native_whole/*.iyi: the hosted build (executable and IR), the
#    import, the native build under the tripwire (bench/lib/tripwire.sh), both executables run with no stdin for at
#    most 30 seconds, stdout and exit status compared. Each program reaches a phase: import (the import refused it),
#    native (the back end refused it), run (it ran and differs), run-equal. A program the hosted compiler does not
#    build is listed and not counted.
#    Floor: bench/native_whole_program.floor, "<program> <phase>". A phase may only rise; a program below its floor
#    or missing from it fails the gate. NATIVE_WHOLE_PROGRAM_RAISE=1 writes the floor from this run, keeping the
#    higher phase.
#    A program whose lib blocks link a framework has it named beside its IR (<p.ir>.imports, SPEC 2.3: bridged IR
#    carries no @[Link]; the names are read from the hosted link command). Its executable must load libSystem, those
#    frameworks and nothing else. 2b: a sidecar naming a library the native floor does not provide is refused by name.
# 3. The compiler builds itself in the back half: the tool's own IR is built by the tool (cn1, a compiler with no
#    LLVM in it), cn1 builds the same IR (cn2), and cn1 and cn2 must be the same bytes; cn2 builds hello to the
#    bytes the tool builds it to.
# 4. The tripwire log is empty.
# 5. Mutation proofs on the pieces a whole program needs that no small fixture did.
#
#   bench/native_whole_program_exercise.sh
#
# The native-darwin job runs it through bench/native_gates.sh. Needs a built compiler (`make`) and LLVM for iyi-ir.
set -u

root="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$root" || exit 1
REPO="$root"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
# The LLVM bridge takes its version, targets and link flags as build arguments (src/compiler/llvm/lib_llvm.iyi): read
# them for this host once, and pass them to every build of a program that imports the bridge.
LLVM_BRIDGE_ARGS=()
llvm_bridge_text=$(llvm_bridge_build_args) || { echo "FAILED: no LLVM build arguments for this host, see the sentence above"; exit 1; }
while IFS= read -r llvm_arg; do LLVM_BRIDGE_ARGS+=("$llvm_arg"); done <<< "$llvm_bridge_text"
if [ -z "$PY" ]; then echo "a working Python interpreter is required" >&2; exit 1; fi
REPO_NATIVE="$(native_path "$REPO")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
if [ "$HOST_OS" = darwin ]; then
  export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"$PATH"
  export LIBRARY_PATH=${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}
fi
iyi="$REPO/bin/iyi"
TOOL_SRC=src/compiler/tools/compile_native.iyi
BRIDGE_SRC=src/compiler/tools/ir.iyi
FLOOR=bench/native_whole_program.floor
FIX=bench/fixtures/native_whole

work="$(mktemp -d "${TMPDIR:-/tmp}/native_whole.XXXXXX")" || exit 1
work_native="$(native_path "$work")" || exit 1
trap 'rm -rf "$work"' EXIT

# shellcheck source=bench/lib/tripwire.sh
. bench/lib/tripwire.sh
# shellcheck source=bench/lib/mutation.sh
. bench/lib/mutation.sh
. bench/lib/native_signature.sh
export NATIVE_SIGNATURE_FAILURE_FILE="$work/signature-failure"

failures=0
fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

# Numeric output is a normal exit; signals, timeouts and launch errors stay distinct.
run_bounded() {
  "$PY" - "$(native_path "$1")" "$(native_path "$2")" "$(native_path "$3")" <<'PY'
import os, signal, subprocess, sys
exe, out, err = sys.argv[1:]
try:
    with open(out, "wb") as stdout, open(err, "wb") as stderr:
        proc = subprocess.Popen([exe], stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                                start_new_session=(os.name != "nt"))
        try:
            rc = proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            if os.name == "nt":
                proc.kill()
            else:
                os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            print("timeout")
        else:
            print(rc if 0 <= rc <= 255 else "signal:%s" % (-rc) if rc < 0 else "invalid-exit:%s" % rc)
except OSError as exc:
    print("launch-error:%s" % exc)
PY
}

rank_of() {
  case "$1" in
    none) echo 0 ;;
    import) echo 1 ;;
    native) echo 2 ;;
    run) echo 3 ;;
    run-equal) echo 4 ;;
    *) echo -1 ;;
  esac
}

# build_tools DIR: the tool and the bridge from the tree as it is now.
build_tools() {
  mkdir -p "$1"
  "$iyi" build -o "$(native_path "$1/compile_native$EXE")" "$REPO_NATIVE/$TOOL_SRC" >"$1/build.tool.log" 2>&1 || return 1
  "$iyi" build "${LLVM_BRIDGE_ARGS[@]}" -o "$(native_path "$1/iyi-ir$EXE")" "$REPO_NATIVE/$BRIDGE_SRC" >"$1/build.bridge.log" 2>&1 || return 1
  if [ "$HOST_ID" != darwin-arm64 ]; then
    "$iyi" build -o "$(native_path "$1/native_cg$EXE")" "$REPO_NATIVE/src/compiler/tools/native_cg.iyi" >"$1/build.cg.log" 2>&1 || return 1
    "$iyi" build -o "$(native_path "$1/ir_core$EXE")" "$REPO_NATIVE/src/compiler/tools/ir_core.iyi" >"$1/build.ir_core.log" 2>&1 || return 1
  fi
}

# hosted_of SRC DIR: the hosted executable DIR/hosted and its IR DIR/hosted.ll, with its run recorded, and the
# frameworks its link named in DIR/frameworks (one per line; the hosted link command is the only place bridged IR's
# @[Link] survives, so --verbose prints it and the names are read from there).
hosted_of() {
  mkdir -p "$2"
  if [ "$HOST_ID" = darwin-arm64 ]; then
    "$iyi" build --no-debug --verbose --emit llvm-ir -o "$(native_path "$2/hosted$EXE")" "$(native_path "$REPO/$1")" >"$2/hosted.log" 2>&1 || return 1
    [ -f "$2/hosted.ll" ] || return 1
    awk '{ for (i = 1; i < NF; i++) if ($i == "-framework") print $(i + 1) }' "$2/hosted.log" | sort -u >"$2/frameworks"
    run_bounded "$2/hosted$EXE" "$2/h.out" "$2/h.err" >"$2/h.status"
  else
    "$iyi" build --no-debug --cross-compile --target aarch64-apple-darwin --emit llvm-ir -o "$(native_path "$2/hosted")" "$(native_path "$REPO/$1")" >"$2/hosted.log" 2>&1 || return 1
    [ -f "$2/hosted.ll" ] || return 1
    : >"$2/frameworks"
  fi
}

# import_refusal ERR OUT: why the bridge refused. iyi-ir writes a failure to read the file to stderr and a refusal of
# the import to stdout (`refused: ...`), where the IR would have gone.
import_refusal() {
  local why
  why=$(head -n 1 "$1")
  [ -n "$why" ] || why=$(head -n 1 "$2")
  printf '%s' "$why"
}

# phase_of TOOLS DIR: imports DIR/hosted.ll, builds it natively and runs it; prints the phase reached and, after a
# tab, the first line of the refusal when there is one.
phase_of() {
  local tools="$1" dir="$2"
  if ! "$tools/iyi-ir$EXE" import "$(native_path "$dir/hosted.ll")" >"$dir/p.ir" 2>"$dir/import.err"; then
    printf 'import\t%s\n' "$(import_refusal "$dir/import.err" "$dir/p.ir")"
    return
  fi
  if [ "$HOST_ID" != darwin-arm64 ]; then
    if ! "$tools/ir_core$EXE" verify "$(native_path "$dir/p.ir")" >"$dir/verify.log" 2>&1; then
      printf 'native\tIR verification failed: %s\n' "$(head -n 1 "$dir/verify.log")"
      return
    fi
    if "$tools/native_cg$EXE" obj "$(native_path "$dir/p.ir")" "$(native_path "$dir/native.o")" >"$dir/native.log" 2>&1 && [ -s "$dir/native.o" ] \
        && "$tools/native_cg$EXE" bytes "$(native_path "$dir/native.o")" >"$dir/native.bytes" 2>&1 && grep -q '^section' "$dir/native.bytes"; then
      printf 'object\tDarwin Mach-O object emitted and inspected\n'
    else
      printf 'native\t%s\n' "$(head -n 1 "$dir/native.log")"
    fi
    return
  fi
  # The sidecar of bridged IR (SPEC 2.3): the libraries the program's lib blocks link, beside the IR.
  rm -f "$dir/p.ir.imports"
  [ -s "$dir/frameworks" ] && cp "$dir/frameworks" "$dir/p.ir.imports"
  PATH="$TRIPWIRE_PATH:$PATH" "$tools/compile_native$EXE" "$(native_path "$dir/p.ir")" -o "$(native_path "$dir/native")" >"$dir/native.out" 2>"$dir/native.err"
  local native_rc=$?
  cat "$dir/native.out" "$dir/native.err" >"$dir/native.log"
  printf '%s\n' "$native_rc" >"$dir/native.rc"
  if [ "$native_rc" -ne 0 ]; then
    printf 'native\t%s\n' "$(head -n 1 "$dir/native.log")"
    return
  fi
  # The executable loads libSystem and the frameworks the hosted link named that it calls, and nothing else.
  local libs extra
  libs=$(otool -L "$dir/native" | awk 'NR > 1 { print $1 }')
  extra=$(printf '%s\n' "$libs" | awk -v list="$dir/frameworks" '
    BEGIN { while ((getline name < list) > 0) allowed["/System/Library/Frameworks/" name ".framework/" name] = 1 }
    $0 != "/usr/lib/libSystem.B.dylib" && !($0 in allowed) { print }')
  if [ -n "$extra" ] || ! printf '%s\n' "$libs" | grep -qx '/usr/lib/libSystem.B.dylib'; then
    printf 'native\tthe executable links %s\n' "$(printf '%s' "$libs" | tr '\n' ' ')"
    return
  fi
  local ns
  if ! native_signature_ok "$dir/native"; then
    printf 'native\tinvalid executable signature\n'
    return
  fi
  ns=$(run_bounded "$dir/native" "$dir/n.out" "$dir/n.err")
  printf '%s\n' "$ns" >"$dir/n.status"
  case "$ns:$(cat "$dir/h.status")" in
    *[!0-9:]*|:*) printf 'invalid\tabnormal executable termination: native %s, hosted %s\n' "$ns" "$(cat "$dir/h.status")"; return ;;
  esac
  if [ "$ns" = "$(cat "$dir/h.status")" ] && cmp -s "$dir/h.out" "$dir/n.out"; then
    printf 'run-equal\t\n'
  else
    printf 'run\tstatus %s against the hosted %s; first differing line of stdout: %s\n' "$ns" "$(cat "$dir/h.status")" "$(diff "$dir/h.out" "$dir/n.out" | head -n 2 | tail -n 1)"
  fi
}

echo "== 1. build iyi-compile-native and the bridge from source"
tools="$work/tools"
if ! build_tools "$tools"; then
  echo "FAIL: the tools do not build (see $tools)"
  tail -n 20 "$tools"/build.*.log
  exit 1
fi
if [ "$HOST_OS" = darwin ]; then
  libs=$(otool -L "$tools/compile_native$EXE" | awk 'NR > 1 { print $1 }')
  if [ "$libs" = "/usr/lib/libSystem.B.dylib" ]; then
    echo "   iyi-compile-native links only /usr/lib/libSystem.B.dylib"
  else
    fail "iyi-compile-native links: $libs"
  fi
else
  host_limited "whole-program: libSystem inspection requires macOS otool"
fi
if [ "$HOST_ID" != darwin-arm64 ]; then
  host_limited "whole-program: Darwin Mach-O link, signature, runtime comparison and bootstrap execution require macOS arm64"
fi

echo "== 2. every program: hosted IR, import, native build under the tripwire, run, equal to the hosted run"
tripwire_setup "$work/shims" "$work/tripwire.log" || { echo "FAIL: cannot set up the tripwire"; exit 1; }
table="$work/table.txt"
: >"$table"
measured="$work/measured.floor"
: >"$measured"
total=0
equal=0
objects=0
for src in samples/iyi/*.iyi "$FIX"/*.iyi src/compiler/tools/parse.iyi; do
  [ -f "$src" ] || continue
  n=$(basename "$src" .iyi)
  dir="$work/p/$(dirname "$src" | tr '/' '_')_$n"
  if ! hosted_of "$src" "$dir"; then
    printf '  %-44s HOSTED    the hosted compiler does not build it, or wrote no IR\n' "$src" >>"$table"
    continue
  fi
  total=$((total + 1))
  result=$(phase_of "$tools" "$dir")
  if [ "${result%%$'\t'*}" = run-equal ]; then
    cp "$dir/n.err" "$dir/baseline-n.err"
    cp "$dir/n.status" "$dir/baseline-n.status"
  fi
  phase=${result%%$'\t'*}
  why=${result#*$'\t'}
  [ "$phase" = "run-equal" ] && equal=$((equal + 1))
  [ "$phase" = "object" ] && objects=$((objects + 1))
  printf '  %-44s %-10s %s\n' "$src" "$phase" "$(printf '%s' "$why" | cut -c1-160)" >>"$table"
  printf '%s %s\n' "$src" "$phase" >>"$measured"
done
cat "$table"
if [ "$HOST_ID" = darwin-arm64 ]; then
  echo "   $equal of $total programs run equal to the hosted executable"
else
  echo "   $objects of $total Darwin-target objects emitted and inspected; runtime comparisons are host-limited"
fi

echo "== 2c. parser and AST exercise over the source corpus"
parser="$work/p/src_compiler_tools_parse"
exercise="$work/p/parser_exercise"
required_phase=run-equal
if [ "$HOST_ID" != darwin-arm64 ]; then required_phase=object; fi
if ! awk -v phase="$required_phase" '$1 == "src/compiler/tools/parse.iyi" && $2 == phase { found = 1 } END { exit !found }' "$measured"; then
  fail "parser bridge did not reach $required_phase"
elif ! hosted_of bench/selfhost_parser_exercise.iyi "$exercise"; then
  fail "hosted parser exercise build failed"
else
  result=$(phase_of "$tools" "$exercise")
  if [ "${result%%$'\t'*}" != "$required_phase" ]; then
    fail "parser exercise did not reach $required_phase: $result"
  elif [ "$HOST_ID" != darwin-arm64 ]; then
    host_limited "whole-program: parser corpus comparisons require macOS arm64 Mach-O execution"
  else
    for pair in "$parser" "$exercise"; do
      if ! bash bench/lib/parse_corpus_diff.sh "$pair/hosted" "$pair/native" >"$pair/corpus.log" 2>&1; then
        grep -E '^(differ |summary:)' "$pair/corpus.log"
        fail "corpus differs for $pair"
      else
        tail -n 1 "$pair/corpus.log"
      fi
    done
  fi
fi

echo "== 2a. the floor"
below=0
if [ "${NATIVE_WHOLE_PROGRAM_RAISE:-0}" = "1" ] && [ "$HOST_ID" != darwin-arm64 ]; then
  fail "whole-program floors can only be raised on macOS arm64"
elif [ "${NATIVE_WHOLE_PROGRAM_RAISE:-0}" = "1" ]; then
  {
    echo "# whole programs through the native back end: <program> <phase reached>. A phase may only rise."
    echo "# Raise with NATIVE_WHOLE_PROGRAM_RAISE=1 bash bench/native_whole_program_exercise.sh (keeps the higher phase)."
    while read -r program phase; do
      old=$(awk -v p="$program" '$1 == p { print $2 }' "$FLOOR" 2>/dev/null)
      if [ -n "$old" ] && [ "$(rank_of "$old")" -gt "$(rank_of "$phase")" ]; then phase=$old; fi
      printf '%s %s\n' "$program" "$phase"
    done <"$measured"
  } >"$work/new.floor"
  cp "$work/new.floor" "$FLOOR"
  echo "   wrote $FLOOR"
fi
while read -r program phase; do
  floor=$(awk -v p="$program" '$1 == p { print $2 }' "$FLOOR" 2>/dev/null)
  if [ -z "$floor" ]; then
    echo "   NO FLOOR: $program reached $phase and has no row in $FLOOR"
    below=$((below + 1))
  elif [ "$HOST_ID" != darwin-arm64 ]; then
    if [ "$phase" != object ]; then
      echo "   BELOW OBJECT: $program reached $phase"
      below=$((below + 1))
    fi
  elif [ "$(rank_of "$phase")" -lt "$(rank_of "$floor")" ]; then
    echo "   BELOW: $program reached $phase, its floor is $floor"
    below=$((below + 1))
  elif [ "$(rank_of "$phase")" -gt "$(rank_of "$floor")" ]; then
    echo "   RAISE THE FLOOR: $program reached $phase, its floor is $floor"
    below=$((below + 1))
  fi
done <"$measured"
if [ -f "$FLOOR" ]; then
  while read -r program phase; do
    case "$program" in '#'* | '') continue ;; esac
    if ! awk -v p="$program" '$1 == p { found = 1 } END { exit !found }' "$measured"; then
      echo "   GONE: $program has a floor row and was not measured"
      below=$((below + 1))
    fi
  done <"$FLOOR"
fi
if [ "$below" -eq 0 ]; then
  if [ "$HOST_ID" = darwin-arm64 ]; then
    echo "   every program is at its floor"
  else
    host_limited "whole-program: floor rows reached inspected objects; run-equal floors require macOS arm64"
  fi
else
  fail "$below program(s) are off their floor"
fi

echo "== 2b. a library the native floor does not provide is refused by name"
hello_p="$work/p/samples_iyi_hello"
if [ "$HOST_ID" != darwin-arm64 ]; then
  host_limited "whole-program: Bogus framework sidecar refusal occurs at Mach-O link"
elif [ -f "$hello_p/p.ir" ]; then
  mkdir -p "$work/lib"
  cp "$hello_p/p.ir" "$work/lib/p.ir"
  printf 'Bogus\n' >"$work/lib/p.ir.imports"
  if "$tools/compile_native$EXE" "$(native_path "$work/lib/p.ir")" -o "$(native_path "$work/lib/exe")" >"$work/lib/log" 2>&1; then
    fail "a program whose sidecar names the library Bogus was built"
  elif grep -q 'does not provide the framework Bogus' "$work/lib/log" && [ ! -e "$work/lib/exe" ]; then
    echo "   refused: $(head -n 1 "$work/lib/log" | sed 's/^.*p\.ir: //')"
  else
    fail "the refusal does not name the library: $(head -n 1 "$work/lib/log")"
  fi
else
  fail "hello has no imported IR to try an unknown library on"
fi

echo "== 3. the compiler builds itself in the back half"
self="$work/self"
mkdir -p "$self/a" "$self/b" "$self/h1" "$self/h2"
hello_dir="$work/p/samples_iyi_hello"
if [ "$HOST_ID" != darwin-arm64 ]; then
  if ! hosted_of "$TOOL_SRC" "$self"; then
    cat "$self/hosted.log"
    fail "the hosted compiler wrote no Darwin IR for $TOOL_SRC"
  elif ! "$tools/iyi-ir$EXE" import "$(native_path "$self/hosted.ll")" >"$self/cn.ir" 2>"$self/import.err"; then
    fail "the tool's own IR is refused by the import: $(import_refusal "$self/import.err" "$self/cn.ir")"
  elif ! "$tools/ir_core$EXE" verify "$(native_path "$self/cn.ir")" >"$self/verify.log" 2>&1; then
    cat "$self/verify.log"
    fail "the tool's own imported IR failed verification"
  elif ! "$tools/native_cg$EXE" obj "$(native_path "$self/cn.ir")" "$(native_path "$self/cn.o")" >"$self/a.log" 2>&1 || [ ! -s "$self/cn.o" ]; then
    cat "$self/a.log"
    fail "the tool's own Darwin object was not emitted"
  elif ! "$tools/native_cg$EXE" bytes "$(native_path "$self/cn.o")" >"$self/cn.bytes" 2>&1 || ! grep -q '^section' "$self/cn.bytes"; then
    fail "the tool's Darwin object could not be inspected"
  else
    echo "   tool IR imported and its Darwin object inspected"
  fi
  host_limited "whole-program: cn1/cn2 execution and byte-identical bootstrap require macOS arm64"
elif ! "$iyi" build --no-debug --emit llvm-ir -o "$(native_path "$self/hosted")" "$REPO_NATIVE/$TOOL_SRC" >"$self/hosted.log" 2>&1 || [ ! -f "$self/hosted.ll" ]; then
  fail "the hosted compiler wrote no IR for $TOOL_SRC"
elif ! "$tools/iyi-ir$EXE" import "$(native_path "$self/hosted.ll")" >"$self/cn.ir" 2>"$self/import.err"; then
  fail "the tool's own IR is refused by the import: $(import_refusal "$self/import.err" "$self/cn.ir")"
elif ! PATH="$TRIPWIRE_PATH:$PATH" "$tools/compile_native$EXE" "$(native_path "$self/cn.ir")" -o "$(native_path "$self/a/cn")" >"$self/a.log" 2>&1; then
  fail "the tool does not build its own IR: $(head -n 1 "$self/a.log")"
elif ! native_signature_ok "$self/a/cn"; then
  fail "cn1 has an invalid signature"
elif ! PATH="$TRIPWIRE_PATH:$PATH" "$self/a/cn" "$self/cn.ir" -o "$self/b/cn" >"$self/b.log" 2>&1; then
  fail "the natively built tool does not build its own IR: $(head -n 1 "$self/b.log")"
else
  cn_libs=$(otool -L "$self/a/cn" | awk 'NR > 1 { print $1 }')
  [ "$cn_libs" = "/usr/lib/libSystem.B.dylib" ] || fail "the natively built tool links: $cn_libs"
  if cmp -s "$self/a/cn" "$self/b/cn"; then
    echo "   cn1 (built by the tool) and cn2 (built by cn1) are the same $(wc -c <"$self/a/cn" | tr -d ' ') bytes, with no LLVM linked"
  else
    fail "cn1 and cn2 differ: the natively built compiler does not compile as the hosted-built one does"
  fi
  if [ -f "$hello_dir/p.ir" ]; then
    "$tools/compile_native$EXE" "$(native_path "$hello_dir/p.ir")" -o "$(native_path "$self/h1/hello")" >/dev/null 2>&1
    if native_signature_ok "$self/b/cn"; then
      "$self/b/cn" "$(native_path "$hello_dir/p.ir")" -o "$(native_path "$self/h2/hello")" >/dev/null 2>&1
    else
      fail "cn2 has an invalid signature"
    fi
    if [ -x "$self/h2/hello" ] && cmp -s "$self/h1/hello" "$self/h2/hello"; then
      echo "   cn2 builds hello to the bytes the tool builds it to"
    else
      fail "cn2 does not build hello to the tool's bytes"
    fi
  else
    fail "hello's IR is missing, so cn2 was not exercised"
  fi
fi

echo "== 4. the tripwire"
if [ "$HOST_ID" != darwin-arm64 ]; then
  host_limited "whole-program tripwire: Mach-O linking was not run; POSIX shims do not intercept native Windows launches"
elif tripwire_fired "$work/tripwire.log"; then
  fail "a host tool was run during a native build: $(head -n 3 "$work/tripwire.log")"
else
  echo "   no host tool ran"
fi

echo "== 5. mutation proofs"
mut_checked=0
mut_caught=0
mut_limited=0
prove_whole_mutation() {
  mut_checked=$((mut_checked + 1))
  if prove_mutation "$@"; then
    mut_caught=$((mut_caught + 1))
    return 0
  fi
  return 1
}

# A direct TLS operand, imported from LLVM IR, avoids writing through the
# deliberately wrong address. The return code observes the loaded value.
prepare_tls_operand() {
  mkdir -p "$work/tls"
  cat >"$work/tls/hosted.ll" <<'IR'
target triple = "aarch64-apple-darwin"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
@probe = internal thread_local(localexec) global i64 42, align 8
define i32 @main() {
entry:
  %value = load i64, ptr @probe, align 8
  %wrong = icmp ne i64 %value, 42
  %result = zext i1 %wrong to i32
  ret i32 %result
}
IR
  if ! "$tools/iyi-ir$EXE" import "$work_native/tls/hosted.ll" >"$work/tls/p.ir" 2>"$work/tls/import.err"; then
    echo "INVALID: read-only TLS LLVM IR did not import"; cat "$work/tls/import.err"; return 2
  fi
  if ! PATH="$TRIPWIRE_PATH:$PATH" "$tools/compile_native$EXE" "$work_native/tls/p.ir" -o "$work_native/tls/baseline" >"$work/tls/build.out" 2>"$work/tls/build.err"; then
    echo "INVALID: read-only TLS baseline did not build"; cat "$work/tls/build.out" "$work/tls/build.err"; return 2
  fi
  native_signature_ok "$work/tls/baseline" || return 2
  local rc
  rc="$(run_bounded "$work/tls/baseline" "$work/tls/baseline.out" "$work/tls/baseline.err")"
  if [ "$rc" != 0 ] || [ -s "$work/tls/baseline.out" ] || [ -s "$work/tls/baseline.err" ]; then
    echo "INVALID: read-only TLS baseline exited $rc"; cat "$work/tls/baseline.out" "$work/tls/baseline.err"; return 2
  fi
  : >"$work/tls/baseline.ok"
}

check_tls_operand() {
  [ -f "$work/tls/baseline.ok" ] || { echo "INVALID: read-only TLS baseline did not pass"; return 2; }
  if ! "$iyi" build -o "$work_native/tls/mut-tool$EXE" "$REPO_NATIVE/$TOOL_SRC" >"$work/tls/mut-build.log" 2>&1; then
    echo "INVALID: TLS mutant compiler did not build"; cat "$work/tls/mut-build.log"; return 2
  fi
  if ! PATH="$TRIPWIRE_PATH:$PATH" "$work/tls/mut-tool$EXE" "$work_native/tls/p.ir" -o "$work_native/tls/mutant" >"$work/tls/mut.out" 2>"$work/tls/mut.err"; then
    echo "INVALID: TLS mutant fixture did not build"; cat "$work/tls/mut.out" "$work/tls/mut.err"; return 2
  fi
  native_signature_ok "$work/tls/mutant" || return 2
  local rc
  rc="$(run_bounded "$work/tls/mutant" "$work/tls/run.out" "$work/tls/run.err")"
  if [ -s "$work/tls/run.out" ] || [ -s "$work/tls/run.err" ]; then
    echo "INVALID: TLS mutant produced unexpected output"; cat "$work/tls/run.out" "$work/tls/run.err"; return 2
  fi
  case "$rc" in
    0) return 0 ;;
    1) echo "decisive: the read-only TLS operand no longer reads 42"; return 1 ;;
    *) echo "INVALID: TLS mutant terminated with $rc"; return 2 ;;
  esac
}

# still_runs TOOL PROGRAM: rebuilds the one tool the mutated file belongs to (native: iyi-compile-native; bridge:
# iyi-ir) from the tree as it is now, takes the other as step 1 built it, and requires PROGRAM to still run equal.
# Each mutation names the program that exercises the mutated piece: hello (thread-locals, naked functions, constant
# expressions, conventions, numbered parameters), a result wider than the result registers, a global whose name
# holds a quote, and cores (two frameworks named beside its IR). Step 2 is the check on the unmutated tree.
still_runs() {
  local which="$1" src="$2" t="$work/mut-tools" dir result
  rm -rf "$t"
  mkdir -p "$t"
  if [ "$which" = bridge ]; then
    cp "$tools/compile_native$EXE" "$t/compile_native$EXE"
    "$iyi" build "${LLVM_BRIDGE_ARGS[@]}" -o "$(native_path "$t/iyi-ir$EXE")" "$REPO_NATIVE/$BRIDGE_SRC" >"$t/build.bridge.log" 2>&1 || { cat "$t/build.bridge.log"; return 2; }
  else
    cp "$tools/iyi-ir$EXE" "$t/iyi-ir$EXE"
    "$iyi" build -o "$(native_path "$t/compile_native$EXE")" "$REPO_NATIVE/$TOOL_SRC" >"$t/build.tool.log" 2>&1 || { cat "$t/build.tool.log"; return 2; }
  fi
  dir="$work/p/$(dirname "$src" | tr '/' '_')_$(basename "$src" .iyi)"
  [ -f "$dir/hosted.ll" ] || { echo "INVALID: no hosted IR for $src ($dir/hosted.ll)"; return 2; }
  result=$(phase_of "$t" "$dir")
  case "${result%%$'\t'*}" in
    run-equal) return 0 ;;
    run)
      local rc baseline_panic
      rc=$(cat "$dir/n.status")
      case "$rc" in ''|*[!0-9]*) echo "INVALID: abnormal fixture termination: $rc"; cat "$dir/n.err"; return 2 ;; esac
      if grep -Eiq 'panic|segmentation|bus error|illegal instruction|abort' "$dir/n.err"; then
        baseline_panic="$(head -n 1 "$dir/baseline-n.err")"
        if [ "$src" != "$FIX/float_to_int.iyi" ] ||
           [ "$baseline_panic" != 'iyi: panic: arithmetic overflow' ] ||
           [ "$(head -n 1 "$dir/n.err")" != "$baseline_panic" ] ||
           [ "$rc" != "$(cat "$dir/baseline-n.status")" ] ||
           ! grep -Fq '*FloatToInt^FloatToInt::f64_i32<Float64>:Int32' "$dir/baseline-n.err" ||
           ! grep -Fq '*FloatToInt^FloatToInt::f64_i32<Float64>:Int32' "$dir/n.err" ||
           [ "$(awk 'END { print NR }' "$dir/h.out")" != "$(awk 'END { print NR }' "$dir/n.out")" ]; then
          echo "INVALID: fixture did not reach its baseline terminal panic"; cat "$dir/n.err"; return 2
        fi
      elif ! cmp -s "$dir/baseline-n.err" "$dir/n.err"; then
        echo "INVALID: fixture stderr differs from its passing baseline"; cat "$dir/n.err"; return 2
      fi
      echo "decisive: $result"
      return 1
      ;;
    native)
      local prefix="iyi-compile-native: $(native_path "$dir/p.ir"): " message line text symbol
      if [ "$(cat "$dir/native.rc" 2>/dev/null)" = 1 ] &&
         ! grep -Eiq '^iyi: panic:|segmentation|bus error|illegal instruction|abort' "$dir/native.log"; then
        case "$label" in
          "a def imported with the C convention")
            if grep -Fxq "${prefix}in function *IyiRoots::each_register_root<Proc(UInt64, Nil)>:Nil: @*IyiRoots::each_register_root<Proc(UInt64, Nil)>:Nil uses the C convention but takes %\"->\"" "$dir/native.err" &&
               grep -Fxq "${prefix}the IR is not well formed" "$dir/native.err" &&
               grep -Fq '*IyiRoots::each_register_root<Proc(UInt64, Nil)>:Nil' "$dir/p.ir"; then
              echo "decisive: hello's each_register_root rejects the C convention"; return 1
            fi ;;
          "a ret after a naked function's template is refused")
            if grep -Fq 'a ret is refused' "$dir/native.err"; then echo "decisive: expected naked return refusal"; return 1; fi ;;
          "wide unsigned division helper is absent")
            if grep -Fxq "${prefix}*UInt128#//<UInt128>:UInt128: symbol __iyi_native_udivti3 is not in the module's symbol table" "$dir/native.err" &&
               grep -Fq '*UInt128#//<UInt128>:UInt128' "$dir/p.ir"; then
              echo "decisive: wide_division's UInt128 division lacks __iyi_native_udivti3"; return 1
            fi ;;
          "a wide internal result is never passed in memory")
            if grep -Fxq "${prefix}__iyi_main: an internal result needs more than 8 integer registers" "$dir/native.err" &&
               grep -Fq '__iyi_main' "$dir/p.ir"; then
              echo "decisive: wide_result's __iyi_main needs more than 8 integer registers"; return 1
            fi ;;
          "a quote escaped in a name ends the name"|"a numbered parameter is taken as a name")
            message="$(grep -F "${prefix}line " "$dir/native.err" | head -n 1)"
            line="$(printf '%s\n' "$message" | awk 'match($0, /line [0-9]+:/) { s = substr($0, RSTART + 5, RLENGTH - 6); print s }')"
            text="$(awk -v n="$line" 'NR == n { print; exit }' "$dir/p.ir")"
            if [ "$label" = "a quote escaped in a name ends the name" ]; then
              if [ "$message" = "${prefix}line $line: expected \`,\` but found the end of the line" ] &&
                 printf '%s\n' "$text" | grep -Fq '@"' &&
                 printf '%s\n' "$text" | grep -Fq '\"'; then
                echo "decisive: quoted_name IR line $line contains the escaped global name"; return 1
              fi
            else
              symbol="$(printf '%s\n' "$message" | awk -F 'no unnamed value | in this function' '{print $2}')"
              case "$symbol" in
                %[0-9]*) if [ "$message" = "${prefix}line $line: no unnamed value $symbol in this function" ] &&
                             printf '%s\n' "$text" | grep -Fq -- "$symbol"; then
                  echo "decisive: hello IR line $line uses $symbol"; return 1
                fi ;;
              esac
            fi ;;
          "a library named beside the IR is not loaded")
            message="$(grep -F "${prefix}undefined symbol " "$dir/native.err" | head -n 1)"
            symbol="$(printf '%s\n' "$message" | awk -F 'undefined symbol |: no object defines it' '{print $2}')"
            if [ "$message" = "${prefix}undefined symbol $symbol: no object defines it, and this system's libSystem does not export it" ] &&
               grep -Fq "$symbol" "$dir/p.ir" &&
               { case "$symbol" in CF*|kCF*) grep -Fxq CoreFoundation "$dir/frameworks" ;; Sec*|kSec*) grep -Fxq Security "$dir/frameworks" ;; *) false ;; esac; }; then
              echo "decisive: cores' framework symbol $symbol is unavailable without its sidecar"; return 1
            fi ;;
        esac
      fi
      echo "INVALID: unexpected native refusal for $src"; cat "$dir/native.log"; return 2
      ;;
    *) echo "INVALID: unexpected mutation result for $src: $result"; cat "$dir/import.err"; return 2 ;;
  esac
}
unmutated=1
for src in samples/iyi/hello.iyi "$FIX/wide_result.iyi" "$FIX/wide_division.iyi" "$FIX/float_to_int.iyi" "$FIX/quoted_name.iyi" samples/iyi/cores.iyi; do
  awk -v p="$src" '$1 == p && $2 == "run-equal" { found = 1 } END { exit !found }' "$measured" || unmutated=0
done
if [ "$HOST_ID" != darwin-arm64 ]; then
  while IFS= read -r mutation; do
    mut_limited=$((mut_limited + 1))
    host_limited "whole-program mutation: $mutation requires Darwin runtime or native link"
  done <<'LIMITED'
a def imported with the C convention
a constant field address loses its offset
a thread-local operand takes the plain symbol address
a ret after a naked function's template is refused
wide unsigned division helper is absent
a wide internal result is never passed in memory
a quote escaped in a name ends the name
a numbered parameter is taken as a name
a library named beside the IR is not loaded
an i8 saturating conversion uses the i16 clamp
the unsigned 128-bit conversion calls the signed helper
the signed 128-bit helper saturates one exponent late
LIMITED
elif [ "$unmutated" -ne 1 ]; then
  fail "a program the mutation proofs read did not run equal on the unmutated tree, so no mutation was run"
else
  status=0
  prepare_tls_operand || status=1
  prove_whole_mutation "a def imported with the C convention" src/compiler/backend/llvm/import.iyi \
    'return CallConv::Iyi if name.starts_with?("*") || name.starts_with?("~")' \
    'return CallConv::C if name.starts_with?("*") || name.starts_with?("~")' -- still_runs bridge samples/iyi/hello.iyi || status=1
  prove_whole_mutation "a constant field address loses its offset" src/compiler/native/const_expr.iyi \
    'off = off + layout.offset_of(cur, n.to_i32)' 'off = off + 0_i64' -- still_runs native samples/iyi/hello.iyi || status=1
  prove_whole_mutation "a thread-local operand takes the plain symbol address" src/compiler/native/aarch64/isel.iyi \
    'return [thread_local_address(g)] if g.tls != TlsModel::None' \
    'return [symbol_address(g.name, false, false)] if g.tls != TlsModel::None' -- check_tls_operand || status=1
  prove_whole_mutation "a ret after a naked function's template is refused" src/compiler/native/aarch64/isel.iyi \
    '      if i.op == Op::Ret
        next
      end' '      if i.op == Op::Ret
        fail("a ret is refused")
        return @mf
      end' -- still_runs native samples/iyi/hello.iyi || status=1
  prove_whole_mutation "wide unsigned division helper is absent" src/compiler/native/driver.iyi \
    '"__iyi_native_udivti3", "__iyi_native_umodti3", "__iyi_native_divti3", "__iyi_native_modti3"].each do |helper|' \
    '"__iyi_native_umodti3", "__iyi_native_divti3", "__iyi_native_modti3"].each do |helper|' -- still_runs native "$FIX/wide_division.iyi" || status=1
  prove_whole_mutation "a wide internal result is never passed in memory" src/compiler/native/lower.iyi \
    'gprs > desc.integer_args.size || fprs > desc.fp_args.size' 'false' -- still_runs native "$FIX/wide_result.iyi" || status=1
  prove_whole_mutation "a quote escaped in a name ends the name" src/compiler/ir/parser.iyi \
    'stop = stop + (line.byte_at(stop) == 92_u8 && stop + 1 < line.bytesize ? 2 : 1)' 'stop = stop + 1' -- still_runs native "$FIX/quoted_name.iyi" || status=1
  prove_whole_mutation "a numbered parameter is taken as a name" src/compiler/ir/parser.iyi \
    'param_names << (written.numeric ? "" : written.text)' 'param_names << written.text' -- still_runs native samples/iyi/hello.iyi || status=1
  prove_whole_mutation "a library named beside the IR is not loaded" src/compiler/tools/compile_native.iyi \
    'names << name unless name.empty? || name.starts_with?("#")' \
    'nil' -- still_runs native samples/iyi/cores.iyi || status=1
  prove_whole_mutation "an i8 saturating conversion uses the i16 clamp" src/compiler/native/aarch64/isel.iyi \
    '    d = clamp_narrow(d, bits, signed) if clamp' '    d = clamp_narrow(d, 16, signed) if clamp' -- still_runs native "$FIX/float_to_int.iyi" || status=1
  prove_whole_mutation "the unsigned 128-bit conversion calls the signed helper" src/compiler/native/aarch64/isel.iyi \
    'call.sym = symbol_index(signed ? "__iyi_native_fptosi_sat_i128" : "__iyi_native_fptoui_sat_i128")' \
    'call.sym = symbol_index("__iyi_native_fptosi_sat_i128")' -- still_runs native "$FIX/float_to_int.iyi" || status=1
  prove_whole_mutation "the signed 128-bit helper saturates one exponent late" src/compiler/native/rt/builtins_text.iyi \
    '%past = icmp uge i64 %exp, 1150' '%past = icmp uge i64 %exp, 1151' -- still_runs native "$FIX/float_to_int.iyi" || status=1
  [ "$status" -eq 0 ] || fail "a mutation was not caught"
fi
echo "mutation summary: $mut_caught/$mut_checked attempted caught; $mut_limited host-limited"

[ ! -e "$NATIVE_SIGNATURE_FAILURE_FILE" ] || fail "a native executable failed signature verification"
echo
if [ "$failures" -eq 0 ]; then
  echo "== ALL NATIVE WHOLE PROGRAM CHECKS PASSED"
  exit 0
fi
echo "== SOME NATIVE WHOLE PROGRAM CHECKS FAILED ($failures)"
exit 1
