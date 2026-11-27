#!/bin/bash
# Native source gate (SPEC 2.2, slice B3). Every compile_* and cg_* fixture is built FROM SOURCE by iyi-compile-native,
# which runs the compiler pipeline with the native backend: no LLVM is linked and no host tool runs (bench/lib/tripwire.sh
# logs and fails ld, cc, clang, gcc, codesign, dsymutil, llvm-config and as).
#
# Reference: the hosted compiler, ./bin/iyi build, of the same program. Each native executable that builds is run, and its
# stdout and exit status must equal the hosted compiler's build. The port+LLVM build (the port's own pipeline with the LLVM
# backend, built from tools/compile.iyi) is a second column, compared the same way and named as what it is.
#
# Every fixture lands in exactly one category:
#   N  run equal to the hosted compiler's build (native vs hosted)
#   G  port gap: the hosted compiler builds and runs it, and the port cannot compile it yet (its first error is shown)
#   R  refused by the native back end only: the hosted compiler and the port+LLVM build both accept it
#   S  refused by the hosted compiler too: a shared refusal, not parity with the port
#   F  failed: the native tool builds what the hosted compiler refuses, or its run differs from the hosted build
#
# Mutations are made to the SOURCE with bench/lib/mutation.sh, and each must be caught by a check that fails on it.
# A self-check of compare_run is labelled separately: it is not a compiler mutation.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
IYI="$REPO/bin/iyi"
TOOL_SRC="$REPO/src/compiler/tools/compile_native.iyi"
PORT_SRC="$REPO/src/compiler/tools/compile.iyi"
FIXTURES="$REPO/bench/fixtures"
. "$REPO/bench/lib/tripwire.sh"
. "$REPO/bench/lib/mutation.sh"
. "$REPO/bench/lib/native_signature.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/iyi-native-source.XXXXXX")" || exit 1
WORK_NATIVE="$(native_path "$WORK")" || exit 1
export NATIVE_SIGNATURE_FAILURE_FILE="$WORK/signature-failure"
trap 'rm -rf "$WORK"' EXIT

status=0

echo "== 1. build the tools from source"
mkdir -p "$WORK/bin" "$WORK/ref" "$WORK/port" "$WORK/nat"
tool="$WORK/bin/iyi-compile-native$EXE"
# build_failed LABEL LOG: the log is under $WORK, which is removed on exit, so what the build said is printed here.
build_failed() {
  echo "FAIL: $1 does not build; the build said:"
  grep -v '^ld: warning' "$2" | tail -n 25 | sed 's/^/    /'
  exit 1
}
if ! "$IYI" build -o "$WORK_NATIVE/bin/iyi-compile-native$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" >"$WORK/build.tool.log" 2>&1; then
  build_failed "iyi-compile-native" "$WORK/build.tool.log"
fi
echo "   built iyi-compile-native (native backend) from $TOOL_SRC"
port="$WORK/bin/iyi-compile-port-llvm$EXE"
if ! "$IYI" build "${LLVM_BRIDGE_ARGS[@]}" -o "$WORK_NATIVE/bin/iyi-compile-port-llvm$EXE" "$REPO_NATIVE/src/compiler/tools/compile.iyi" >"$WORK/build.port.log" 2>&1; then
  build_failed "the port+LLVM build" "$WORK/build.port.log"
fi
echo "   built iyi-compile-port-llvm (port pipeline, LLVM backend) from $PORT_SRC"

echo "== 2. the native tool links libSystem alone and carries no LLVM symbol"
if [ "$HOST_OS" = darwin ]; then
  tool_libs=$(otool -L "$tool" | awk 'NR > 1 { print $1 }')
  if [ "$tool_libs" = "/usr/lib/libSystem.B.dylib" ]; then
    echo "   only /usr/lib/libSystem.B.dylib"
  else
    echo "FAIL: the native tool links: $tool_libs"
    status=1
  fi
else
  host_limited "native source: the libSystem dependency assertion requires macOS otool"
fi
nm_tool="${NM:-nm}"
if [ "$HOST_OS" = windows ] && [ -z "${NM:-}" ]; then
  nm_tool=$(command -v llvm-nm 2>/dev/null || true)
  if [ -z "$nm_tool" ]; then
    for llvm_root in "${LLVM_PATH:-}" "${ProgramFiles:+$ProgramFiles/LLVM}" "/c/Program Files/LLVM"; do
      [ -n "$llvm_root" ] || continue
      case "$llvm_root" in [A-Za-z]:[\\/]*) llvm_root=$(cygpath -u "$llvm_root") || continue ;; esac
      if [ -x "$llvm_root/bin/llvm-nm.exe" ]; then nm_tool="$llvm_root/bin/llvm-nm.exe"; break; fi
    done
  fi
  if [ -z "$nm_tool" ]; then echo "FAIL: llvm-nm is required to inspect the Windows driver" >&2; exit 1; fi
fi
if ! "$nm_tool" "$(native_path "$tool")" >"$WORK/tool.symbols" 2>"$WORK/tool.nm.err"; then
  cat "$WORK/tool.nm.err"
  echo "FAIL: cannot inspect native tool symbols with $nm_tool"
  status=1
fi
llvm_syms=$(awk '/_?LLVM[A-Za-z]|LibLLVM|Compiler::Llvm/ { n++ } END { print n + 0 }' "$WORK/tool.symbols")
if [ "$llvm_syms" = "0" ]; then
  echo "   no LLVM C-API or Compiler::Llvm symbol in the native tool"
else
  echo "FAIL: the native tool carries $llvm_syms LLVM C-API or Compiler::Llvm symbols"
  status=1
fi

# Prints a numeric status only for a normal exit; a signal or timeout is distinct.
run_fixture() {
  local out="$1" err="$2"
  shift 2
  "$PY" - "$(native_path "$out")" "$(native_path "$err")" "$@" <<'PY'
import os, signal, subprocess, sys
out, err, *command = sys.argv[1:]
try:
    with open(out, "wb") as stdout, open(err, "wb") as stderr:
        proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
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

# compare_run REF EXE LABEL NAME: runs both executables. Requires identical stdout and exit status, and for the built
# executable a valid signature and libSystem alone. Prints one line naming what was compared. Returns 0 only on a match.
compare_run() {
  local ref="$1" exe="$2" label="$3" name="$4" ref_rc exe_rc problems libs
  ref_rc="$(run_fixture "$WORK/ref-run.out" "$WORK/ref-run.err" "$(native_path "$ref")")"
  if [ "$HOST_OS" = darwin ]; then native_signature_ok "${5:-$exe}" || return 1; fi
  if [ "$HOST_OS" = windows ] && { [ "$exe" = "$WORK/selfcheck_status" ] || [ "$exe" = "$WORK/selfcheck_stdout" ]; }; then
    exe_rc="$(run_fixture "$WORK/exe-run.out" "$WORK/exe-run.err" bash "$(native_path "$exe")")"
  else
    exe_rc="$(run_fixture "$WORK/exe-run.out" "$WORK/exe-run.err" "$(native_path "$exe")")"
  fi
  case "$ref_rc:$exe_rc" in
    *[!0-9:]*|:*|*:) echo "FAIL: $name: abnormal termination (hosted $ref_rc, $label $exe_rc)"; cat "$WORK/ref-run.err" "$WORK/exe-run.err"; return 1 ;;
  esac
  if ! cmp -s "$WORK/ref-run.out" "$WORK/exe-run.out" || [ "$ref_rc" != "$exe_rc" ]; then
    echo "FAIL: $name: $label run diverged from the hosted build (exit $exe_rc vs hosted $ref_rc)"
    return 1
  fi
  problems=""
  if [ "$HOST_OS" = darwin ]; then
    native_signature_ok "${5:-$exe}" || problems="$problems codesign;"
    libs=$(otool -L "$exe" | awk 'NR > 1 { print $1 }')
    if [ "$libs" != "/usr/lib/libSystem.B.dylib" ]; then problems="$problems libs=$libs;"; fi
  fi
  if [ -n "$problems" ]; then
    echo "FAIL: $name: $label executable:$problems"
    return 1
  fi
  echo "   $label run equal to hosted: $name (exit $exe_rc)"
  return 0
}

# check_ceiling MEASURED CEILING LABEL: a fixture the run finds that the ceiling does not name fails the gate. A name the
# ceiling lists that the run no longer finds may fall, so it is printed for removal by hand. Names are the first word of each line.
check_ceiling() {
  local measured="$1" ceiling="$2" label="$3" new ceiling_n measured_n
  if [ ! -f "$ceiling" ]; then echo "FAIL: $label: no ceiling at $ceiling"; return 1; fi
  new=$(awk 'NR == FNR { if (NF && $1 !~ /^#/) listed[$1] = 1; next } NF && !($1 in listed) { print "   NEW " $0 }' "$ceiling" "$measured")
  ceiling_n=$(awk '!/^#/ && NF' "$ceiling" | awk 'END { print NR }')
  measured_n=$(awk 'NF' "$measured" | awk 'END { print NR }')
  echo "  $label: $measured_n measured, $ceiling_n in $(basename "$ceiling")"
  if [ -n "$new" ]; then
    echo "$new"
    echo "  FAIL: $label: a fixture the ceiling does not name (above); the ceiling may only fall"
    return 1
  fi
  if [ "$HOST_ID" = darwin-arm64 ] || [ "$label" != P ]; then
    awk 'NR == FNR { if (NF) seen[$1] = 1; next } !/^#/ && NF && !($1 in seen) { print "   ratchet: " $1 " no longer occurs; remove it from " FILENAME }' "$measured" "$ceiling"
  fi
  return 0
}

echo "== 3. every fixture: the hosted reference, then the port+LLVM column and the native column"
tripwire_setup "$WORK/tripwire" "$WORK/tripwire.log" || { echo "FAIL: tripwire setup"; exit 1; }
FIX="${NATIVE_SOURCE_FIXTURES:-$FIXTURES}"
if [ "$HOST_ID" != darwin-arm64 ]; then
  host_limited "native source: Mach-O linking, signatures, execution and native-only classification require macOS arm64; verified source IR is still emitted"
fi
path_sep=:
if [ "$HOST_OS" = windows ]; then path_sep=';'; fi
total=0
marked_refs=0
n_equal=0
g_gaps=0
r_native_only=0
s_shared=0
p_accepts=0
f_failed=0
port_equal=0
port_refused=0
port_differs=0
: >"$WORK/p_measured.txt"
: >"$WORK/u_measured.txt"
# The hosted reference of a fixture the hosted source checker refuses for a C fun is built from a copy of EVERY fixture
# with the same @[Unsafe] header, so each sibling module the fixture imports is marked too. Only the header is added.
mkdir -p "$WORK/marked"
for g in "$FIX"/*.iyi; do
  { printf '@[Unsafe("fixture declares C functions for the runtime test")]\n'; cat "$g"; } >"$WORK/marked/$(basename "$g")"
done
cp -R "$FIX/compile_search_roots" "$WORK/marked/" 2>/dev/null || true
# The first refusal line of a build's log, with the checkout and the scratch copies written as <repo> and <marked>.
hosted_error() {
  awk '/^(Error|iyi-compile-native:)/ { print; exit }' "$1" | awk -v repo="$REPO" -v work="$WORK" '{ gsub(repo, "<repo>"); gsub(work "/marked", "<marked>"); print }'
}
for f in "$FIX"/compile_*.iyi "$FIX"/cg_*.iyi; do
  [ -f "$f" ] || continue
  n=$(basename "$f" .iyi)
  total=$((total + 1))
  ref="$WORK/ref/$n$EXE"
  pexe="$WORK/port/$n$EXE"
  nexe="$WORK/nat/$n"
  ref_how="as written"
  # A fixture that defines fun main replaces the runtime's start, so the owned collector's heap and its
  # statistics page are never set up and its first allocation faults. Its hosted reference takes
  # -Dgc_none, whose bump allocator needs no start.
  ref_gc=
  grep -q '^fun main' "$f" && ref_gc=-Dgc_none
  if "$IYI" build $ref_gc -o "$(native_path "$ref")" "$(native_path "$f")" >"$WORK/ref/$n.log" 2>&1; then
    ref_ok=1
  elif IYI_PATH="$REPO_NATIVE/src$path_sep$(native_path "$FIX")" "$IYI" build $ref_gc -o "$(native_path "$ref")" "$WORK_NATIVE/marked/$n.iyi" >"$WORK/ref/$n.marked.log" 2>&1; then
    ref_ok=1
    ref_how="copy with @[Unsafe] header"
    marked_refs=$((marked_refs + 1))
    echo "$n" >>"$WORK/u_measured.txt"
    echo "   U the hosted reference needs the @[Unsafe] header: $n"
  else
    ref_ok=0
  fi
  if "$port" "$(native_path "$f")" -o "$(native_path "$pexe")" >"$WORK/port/$n.log" 2>&1; then port_ok=1; else port_ok=0; fi
  if [ "$HOST_ID" = darwin-arm64 ]; then
    if PATH="$TRIPWIRE_PATH:$PATH" "$tool" "$(native_path "$f")" -o "$(native_path "$nexe")" >"$WORK/nat/$n.log" 2>&1; then nat_ok=1; else nat_ok=0; fi
  else
    nat_ok=0
    if "$tool" "$(native_path "$f")" -o "$WORK_NATIVE/nat/$n.ir" --emit ir >"$WORK/nat/$n.log" 2>&1 && [ -s "$WORK/nat/$n.ir" ]; then
      echo "   IR verified: $n"
    else
      echo "   IR refused: $n: $(hosted_error "$WORK/nat/$n.log")"
    fi
  fi

  if [ "$ref_ok" = 0 ]; then
    # The hosted compiler refuses this even with the header. A fixture the port or the native back end accepts is
    # P, named in bench/native_source.ceiling. A fixture that nothing accepts is S, a shared refusal.
    # The hosted compiler's first refusal. Its @[Unsafe] banner is not the program's refusal, so the marked copy's is used then.
    err=$(hosted_error "$WORK/ref/$n.log")
    case "$err" in *"does not check"*) err=$(hosted_error "$WORK/ref/$n.marked.log") ;; esac
    if [ "$port_ok" = 1 ] || [ "$nat_ok" = 1 ]; then
      p_accepts=$((p_accepts + 1))
      echo "$n $err" >>"$WORK/p_measured.txt"
      echo "   P port accepts what the hosted compiler refuses (port+LLVM $port_ok, native $nat_ok): $n: $err"
    else
      if [ "$HOST_ID" = darwin-arm64 ]; then
        s_shared=$((s_shared + 1))
        echo "   S refused by the hosted compiler, the port and the native back end: $n: $err"
      else
        echo "   hosted and port refused $n; native link acceptance is host-limited: $err"
      fi
    fi
    continue
  fi

  # The hosted compiler builds this program (with the header where it needs one) and runs it.
  if [ "$port_ok" = 1 ]; then
    if compare_run "$ref" "$pexe" "port+LLVM" "$n" >/dev/null; then
      port_equal=$((port_equal + 1))
    else
      port_differs=$((port_differs + 1))
      f_failed=$((f_failed + 1))
      echo "FAIL: $n: port+LLVM run differs from the hosted build ($ref_how)"
    fi
  else
    port_refused=$((port_refused + 1))
  fi
  if [ "$HOST_ID" != darwin-arm64 ]; then continue; fi
  if [ "$nat_ok" = 1 ]; then
    if compare_run "$ref" "$nexe" "native" "$n"; then
      n_equal=$((n_equal + 1))
    else
      f_failed=$((f_failed + 1))
    fi
  elif [ "$port_ok" = 1 ]; then
    r_native_only=$((r_native_only + 1))
    echo "   R refused by the native back end only (port+LLVM builds it): $n: $(hosted_error "$WORK/nat/$n.log")"
  else
    g_gaps=$((g_gaps + 1))
    echo "   G port gap (hosted builds and runs it; port+LLVM and native refuse): $n: $(hosted_error "$WORK/port/$n.log")"
  fi
done

if [ "$HOST_ID" != darwin-arm64 ]; then
  host_limited "native source tripwire: Mach-O fixture linking was not run; POSIX shims do not intercept native Windows launches"
elif tripwire_fired "$WORK/tripwire.log"; then
  echo "FAIL: a host tool started during a native build:"
  awk '{ print }' "$WORK/tripwire.log"
  status=1
fi
if [ "$f_failed" -ne 0 ]; then status=1; fi
echo "  port+LLVM column: $port_equal equal to hosted, $port_differs differ, $port_refused refused"
if [ "$HOST_ID" = darwin-arm64 ]; then
  echo "  Native source summary: $n_equal of $total run equal to the hosted compiler's build (native vs hosted); $g_gaps port gaps; $r_native_only refused by the native back end only; $s_shared refused by the hosted compiler too; $p_accepts port accepts what the hosted compiler refuses (P); $f_failed failed; $marked_refs need the @[Unsafe] header in the hosted reference (U)"
else
  echo "  Native source: $total fixtures processed; native execution and backend classifications are host-limited; $p_accepts observed port acceptances (P), $f_failed failed, $marked_refs need the @[Unsafe] header (U)"
fi

echo "== 3b. ceilings: a count may only fall (P: the port accepts what the hosted compiler refuses; U: the hosted reference needs the @[Unsafe] header)"
if [ "$HOST_ID" != darwin-arm64 ]; then
  host_limited "native source: P ceiling is checked for port acceptances; native-only acceptances require macOS arm64"
fi
check_ceiling "$WORK/p_measured.txt" "$REPO/bench/native_source.ceiling" "P" || status=1
check_ceiling "$WORK/u_measured.txt" "$REPO/bench/native_source_unsafe.ceiling" "U" || status=1
if [ -n "${NATIVE_SOURCE_NO_SELFCHECK:-}" ]; then exit "$status"; fi

echo "== 4. source mutations: each must be caught by a check that fails on the mutated source"
mut_run=0
mut_caught=0
mut_limited=0
ref_arith="$WORK/ref/compile_arith$EXE"
ref_arith_rc="$(run_fixture "$WORK/ref-arith.out" "$WORK/ref-arith.err" "$(native_path "$ref_arith")")"
if [ "$ref_arith_rc" = 26 ] && compare_run "$ref_arith" "$WORK/port/compile_arith$EXE" "port+LLVM" "compile_arith" >/dev/null; then
  : >"$WORK/ref-arith.ok"
else
  echo "FAIL: subtraction mutation baseline did not match the hosted exit 26 (exit $ref_arith_rc)"
  cat "$WORK/ref-arith.err"
  status=1
fi

# (a) the native backend hands linking to cc: a real build must trip the wire.
check_cc_in_native_build() {
  if ! "$IYI" build -o "$WORK_NATIVE/mut-a-tool$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" >"$WORK/mut-a.build.log" 2>&1; then
    cat "$WORK/mut-a.build.log"
    return 2
  fi
  : >"$WORK/tripwire.log"
  local args=()
  if [ "$HOST_ID" != darwin-arm64 ]; then args=(--emit ir); fi
  if ! PATH="$TRIPWIRE_PATH:$PATH" "$WORK/mut-a-tool$EXE" "$REPO_NATIVE/bench/fixtures/compile_arith.iyi" -o "$WORK_NATIVE/mut-a-exe" "${args[@]}" >"$WORK/mut-a.run.log" 2>&1; then
    cat "$WORK/mut-a.run.log"
    return 2
  fi
  if tripwire_fired "$WORK/tripwire.log"; then echo "decisive: native backend invoked cc"; return 1; fi
  return 0
}
if [ "$HOST_OS" != windows ]; then
mut_run=$((mut_run + 1))
if prove_mutation "backend hands linking to cc" \
  "$REPO/src/compiler/backend/native.iyi" \
  "module compiler/backend/native" \
  "@[Unsafe(\"mutation: calls the host C compiler\")]
module compiler/backend/native

lib LibC
  fun system(cmd : UInt8*) : Int32
end

LibC.system(\"cc -v >/dev/null 2>&1\")" \
  -- check_cc_in_native_build; then
  mut_caught=$((mut_caught + 1))
else
  status=1
fi
else
  mut_limited=$((mut_limited + 1))
  host_limited "native source: the cc tripwire mutation needs POSIX shell command lookup; native Windows uses cmd.exe"
fi

# (b) the subtraction operands swapped where codegen emits integer subtraction. Both subtractions in compile_arith go
# through that site: ops(5, 3) becomes (8) &* (3 &- 5) = -16 and main returns -16 &- 42 = -58, so the exit status moves
# from 26 to 198 (-58 as an unsigned byte): the status must change, and to exactly that.
check_subtraction_output() {
  local src="$REPO_NATIVE/src/compiler/tools/compile.iyi" rc
  local result="$WORK/mut-b-exe$EXE"
  [ -f "$WORK/ref-arith.ok" ] || { echo "INVALID: subtraction baseline did not pass"; return 2; }
  if ! "$IYI" build "${LLVM_BRIDGE_ARGS[@]}" -o "$WORK_NATIVE/mut-b-tool$EXE" "$src" >"$WORK/mut-b.build.log" 2>&1; then
    cat "$WORK/mut-b.build.log"; return 2
  fi
  if ! "$WORK/mut-b-tool$EXE" "$REPO_NATIVE/bench/fixtures/compile_arith.iyi" -o "$(native_path "$result")" >"$WORK/mut-b.run.log" 2>&1; then
    cat "$WORK/mut-b.run.log"; return 2
  fi
  if [ "$HOST_OS" = darwin ]; then native_signature_ok "$result" || return 2; fi
  rc="$(run_fixture "$WORK/mut-b.out" "$WORK/mut-b.err" "$(native_path "$result")")"
  case "$rc" in
    ''|*[!0-9]*) echo "INVALID: subtraction mutant terminated with $rc"; cat "$WORK/mut-b.err"; return 2 ;;
  esac
  if [ -s "$WORK/mut-b.err" ]; then
    echo "INVALID: subtraction mutant wrote to stderr"; cat "$WORK/mut-b.err"; return 2
  fi
  if cmp -s "$WORK/mut-b.out" "$WORK/ref-arith.out" && [ "$rc" = "$ref_arith_rc" ]; then return 0; fi
  if [ "$ref_arith_rc" = 26 ] && [ "$rc" = 198 ] && cmp -s "$WORK/mut-b.out" "$WORK/ref-arith.out"; then
    echo "decisive: subtraction exits 198 instead of 26"
    return 1
  fi
  echo "unexpected subtraction mutation result: exit $rc"
  return 2
}
mut_run=$((mut_run + 1))
if prove_mutation "codegen swaps subtraction operands" \
  "$REPO/src/compiler/codegen/codegen.iyi" \
  "@last = is_float ? @builder.fsub(lhs, rhs) : @builder.sub(lhs, rhs)" \
  "@last = is_float ? @builder.fsub(lhs, rhs) : @builder.sub(rhs, lhs)" \
  -- check_subtraction_output; then
  mut_caught=$((mut_caught + 1))
else
  status=1
fi

# (c) the native linker writes no code signature: codesign must reject the executable it builds.
check_unsigned_executable() {
  if ! "$IYI" build -o "$WORK_NATIVE/mut-c-tool$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" >"$WORK/mut-c.build.log" 2>&1; then cat "$WORK/mut-c.build.log"; return 2; fi
  if ! "$WORK/mut-c-tool$EXE" "$REPO_NATIVE/bench/fixtures/compile_arith.iyi" -o "$WORK_NATIVE/mut-c-exe" >"$WORK/mut-c.run.log" 2>&1; then cat "$WORK/mut-c.run.log"; return 2; fi
  if codesign -v --strict "$WORK/mut-c-exe" >/dev/null 2>&1; then return 0; fi
  return 1
}
if [ "$HOST_ID" = darwin-arm64 ]; then
mut_run=$((mut_run + 1))
if prove_mutation "native linker drops the code signature" \
  "$REPO/src/compiler/native/link/macho_exe.iyi" \
  "image[(sig_off + i.to_i64).to_i32] = sig[i]" \
  "image[(sig_off + i.to_i64).to_i32] = 0_u8" \
  -- check_unsigned_executable; then
  mut_caught=$((mut_caught + 1))
else
  status=1
fi
else
  mut_limited=$((mut_limited + 1))
  host_limited "native source: unsigned executable mutation requires macOS codesign and Mach-O linking"
fi

# (d) a patch that changes nothing is refused by name, with exit 3, and does not count.
( prove_mutation "a patch that changes nothing" \
    "$REPO/src/compiler/tools/compile_native.iyi" \
    "CompileNative.run" "CompileNative.run" -- true ) >"$WORK/noop.log" 2>&1
noop_rc=$?
if [ "$noop_rc" = 3 ]; then
  echo "    refused: a patch that changes nothing (exit 3)"
else
  status=1
  echo "FAIL: a patch that changes nothing was not refused (exit $noop_rc)"
fi

# Self-check of compare_run, not a compiler mutation: a native exit status off by one and extra stdout must diverge.
echo "  self-check of compare_run (not a compiler mutation):"
if [ "$HOST_ID" = darwin-arm64 ]; then
  sample_exe="$WORK/nat/compile_arith"
else
  sample_exe="$WORK/port/compile_arith$EXE"
fi
if ! compare_run "$ref_arith" "$sample_exe" "self-check baseline" "compile_arith" >/dev/null; then
  echo "FAIL: compare_run self-check baseline did not run equal"
  status=1
fi
"$sample_exe" >"$WORK/selfcheck_sample.out" 2>"$WORK/selfcheck_sample.err"
sample_rc=$?
printf '#!/bin/sh\n"%s"\nrc=$?\nexit $((rc + 1))\n' "$sample_exe" >"$WORK/selfcheck_status"
chmod +x "$WORK/selfcheck_status"
bash "$WORK/selfcheck_status" >"$WORK/selfcheck_status.out" 2>"$WORK/selfcheck_status.err"
wrapper_rc=$?
if [ "$wrapper_rc" -ne "$((sample_rc + 1))" ] || ! cmp -s "$WORK/selfcheck_status.out" "$WORK/selfcheck_sample.out"; then
  status=1
  echo "FAIL: exit self-check wrapper did not produce the intended difference"
elif compare_run "$ref_arith" "$WORK/selfcheck_status" "self-check" "exit off by one" "$sample_exe" >/dev/null 2>&1; then
  status=1
  echo "FAIL: compare_run accepted an exit status off by one"
else
  echo "   compare_run diverges on an exit status off by one"
fi
printf '#!/bin/sh\n"%s"\nrc=$?\necho extra-line\nexit $rc\n' "$sample_exe" >"$WORK/selfcheck_stdout"
chmod +x "$WORK/selfcheck_stdout"
{ cat "$WORK/selfcheck_sample.out"; printf 'extra-line\n'; } >"$WORK/selfcheck_expected.out"
bash "$WORK/selfcheck_stdout" >"$WORK/selfcheck_actual.out" 2>"$WORK/selfcheck_stdout.err"
wrapper_rc=$?
if [ "$wrapper_rc" -ne "$sample_rc" ] || ! cmp -s "$WORK/selfcheck_expected.out" "$WORK/selfcheck_actual.out"; then
  status=1
  echo "FAIL: stdout self-check wrapper did not produce the intended difference"
elif compare_run "$ref_arith" "$WORK/selfcheck_stdout" "self-check" "extra stdout" "$sample_exe" >/dev/null 2>&1; then
  status=1
  echo "FAIL: compare_run accepted extra stdout"
else
  echo "   compare_run diverges on extra stdout"
fi

echo "  Mutation summary: $mut_caught/$mut_run attempted caught; $mut_limited host-limited; no-op patch checked separately"
if [ "$mut_caught" -ne "$mut_run" ]; then status=1; fi

if [ -z "${NATIVE_SOURCE_NO_SELFCHECK:-}" ]; then
  echo "== 5. ceiling self-check: a fixture the hosted compiler refuses and the port accepts, not in the ceiling, fails the gate"
  mkdir -p "$WORK/mutfix"
  cp "$FIXTURES/cg_strings.iyi" "$WORK/mutfix/cg_mutant_unlisted.iyi"
  if NATIVE_SOURCE_FIXTURES="$WORK/mutfix" NATIVE_SOURCE_NO_SELFCHECK=1 bash "$0" >"$WORK/selfcheck.log" 2>&1; then
    echo "  FAIL: the gate exited 0 with an unlisted fixture"
    status=1
  elif awk '/NEW cg_mutant_unlisted/ { found = 1 } END { exit !found }' "$WORK/selfcheck.log"; then
    echo "  caught: the ceiling refused the unlisted fixture cg_mutant_unlisted"
  else
    echo "  FAIL: the gate failed, but not on the unlisted fixture"
    status=1
  fi
fi

if [ -e "$NATIVE_SIGNATURE_FAILURE_FILE" ]; then status=1; fi
echo
if [ "$status" -eq 0 ]; then
  echo "ALL NATIVE SOURCE CHECKS PASSED!"
else
  echo "SOME NATIVE SOURCE CHECKS FAILED"
  exit 1
fi
