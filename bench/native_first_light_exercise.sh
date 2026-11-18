#!/usr/bin/env bash
# The native first-light gate (SPEC 2.2, 2.3, 3.7, 3.8; slice C6). One IR program goes in and a signed arm64 Mach-O
# executable comes out, built by the native backend and the native linker with no host tool taking part.
#
# 0. The runtime text the tool carries is generated from src/compiler/native/rt/builtins.ir.
# 1. iyi-compile-native builds from source. 2. It links only libSystem.
# 3. Every bench/fixtures/native_cg and bench/fixtures/native_first_light program that has an .iyi twin is built by the
#    tool under a tripwire (bench/lib/tripwire.sh: ld, cc, clang, gcc, codesign, dsymutil, llvm-config and as log and
#    fail), run, and compared with the hosted compiler's build of the twin on stdout and exit status. Each executable
#    must pass codesign -v --strict, link only libSystem, carry LC_BUILD_VERSION with zero tools, have no __stub_helper,
#    no dyld_stub_binder import, and build to identical bytes twice. A fixture that needs a C helper is listed by name
#    with its reason and is not counted as passing.
# 4. The tripwire log is empty.
# 5. Mutation proofs: each mutation is applied to a copy of its source, the check must catch it, and the source is
#    restored. A patch that changes nothing is refused by the proof helper.
#
#   bench/native_first_light_exercise.sh
#
# The native-darwin job runs every step. Needs a built compiler (`make`).
set -u

root="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$root" || exit 1
REPO="$root"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if [ -z "$PY" ]; then echo "a working Python interpreter is required" >&2; exit 1; fi
REPO_NATIVE="$(native_path "$REPO")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
if [ "$HOST_OS" = darwin ]; then
  export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"$PATH"
  export LIBRARY_PATH=${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}
fi
iyi="$REPO/bin/iyi"
FIX=bench/fixtures/native_cg
FL=bench/fixtures/native_first_light
TOOL_SRC=src/compiler/tools/compile_native.iyi
DRIVER_SRC=src/compiler/native/driver.iyi
LINK_SRC=src/compiler/native/link/link.iyi
RT_SRC=src/compiler/native/rt/builtins.ir

work="$(mktemp -d "${TMPDIR:-/tmp}/native_first_light.XXXXXX")" || exit 1
work_native="$(native_path "$work")" || exit 1
restore=""
backup=""
cleanup() {
  if [ -n "$restore" ] && [ -n "$backup" ]; then
    cp "$backup" "$restore"
  fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

# shellcheck source=bench/lib/tripwire.sh
. bench/lib/tripwire.sh
. bench/lib/native_signature.sh
export NATIVE_SIGNATURE_FAILURE_FILE="$work/signature-failure"

failures=0
mut_checked=0
mut_caught=0
mut_limited=0
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

echo "== 0. the runtime text the tool carries is generated from builtins.ir"
if "$PY" "$REPO_NATIVE/bench/lib/gen_runtime.py" --check; then
  echo "   builtins_text.iyi matches builtins.ir"
else
  fail "builtins_text.iyi is stale: run python3 bench/lib/gen_runtime.py"
fi

echo "== 1. build iyi-compile-native and the native driver from source"
mkdir -p "$work/bin"
tool="$work/bin/compile_native$EXE"
if ! "$iyi" build -o "$work_native/bin/compile_native$EXE" "$REPO_NATIVE/$TOOL_SRC" >"$work/build.tool.log" 2>&1; then
  echo "FAIL: iyi-compile-native does not build:"
  cat "$work/build.tool.log"
  exit 1
fi
echo "   built $TOOL_SRC"

echo "== 2. the tool links libSystem alone"
if [ "$HOST_OS" = darwin ]; then
  otool -L "$tool"
  libs=$(otool -L "$tool" | awk 'NR > 1 { print $1 }')
  if [ "$libs" = "/usr/lib/libSystem.B.dylib" ]; then
    echo "   only /usr/lib/libSystem.B.dylib"
  else
    fail "the tool links: $libs"
  fi
else
  host_limited "first-light: libSystem dependency inspection requires macOS otool"
fi
if [ "$HOST_ID" != darwin-arm64 ]; then
  cg="$work/bin/native_cg$EXE"
  if ! "$iyi" build -o "$work_native/bin/native_cg$EXE" "$REPO_NATIVE/src/compiler/tools/native_cg.iyi" >"$work/build.cg.log" 2>&1; then
    cat "$work/build.cg.log"
    exit 1
  fi
  host_limited "first-light: Mach-O linking, codesign, load commands, and native execution require macOS arm64"
fi

echo "== 3. every fixture with a twin: native build under the tripwire, run, equal to the hosted compiler's program"
tripwire_setup "$work/shims" "$work/tripwire.log" || { echo "FAIL: cannot set up the tripwire"; exit 1; }
mkdir -p "$work/hosted" "$work/native"
# Fixtures that need a C helper outside the native path: listed, not built, not counted.
excluded_reason() {
  case "$1" in
    tls_threads) echo "calls __fixture_run_on_thread, a pthread helper in rt_stub.c (C, outside the native path)" ;;
    narrow_argext|narrow_call|narrow_param|narrow_signext) echo "calls a C ABI probe helper in rt_stub.c (covered by native_codegen)" ;;
    *) echo "" ;;
  esac
}
table="$work/table.txt"
: >"$table"
passing=0
objects=0
for ir in "$FIX"/*.ir "$FL"/*.ir; do
  n=$(basename "$ir" .ir)
  dir=$(dirname "$ir")
  [ -f "$dir/$n.iyi" ] || continue
  reason=$(excluded_reason "$n")
  if [ -n "$reason" ]; then
    printf '%-18s EXCLUDED  %s\n' "$n" "$reason" >>"$table"
    continue
  fi
  if ! "$iyi" build -o "$work_native/hosted/$n$EXE" "$REPO_NATIVE/$dir/$n.iyi" >"$work/hosted-$n.log" 2>&1; then
    printf '%-18s FAIL      the hosted compiler does not build the twin\n' "$n" >>"$table"
    failures=$((failures + 1))
    continue
  fi
  hs=$(run_bounded "$work/hosted/$n$EXE" "$work/$n.h.out" "$work/$n.h.err")
  case "$hs" in
    ''|*[!0-9]*) printf '%-18s FAIL      hosted termination %s\n' "$n" "$hs" >>"$table"; failures=$((failures + 1)); continue ;;
  esac
  if [ "$HOST_ID" != darwin-arm64 ]; then
    if "$cg" obj "$REPO_NATIVE/$ir" "$work_native/native/$n.o" >"$work/$n.obj.log" 2>&1 \
        && [ -s "$work/native/$n.o" ] \
        && "$cg" bytes "$work_native/native/$n.o" >"$work/$n.bytes" 2>&1 \
        && grep -q '^section' "$work/$n.bytes"; then
      printf '%-18s OBJECT    emitted and inspected Darwin Mach-O object\n' "$n" >>"$table"
      objects=$((objects + 1))
    else
      cat "$work/$n.obj.log" "$work/$n.bytes" 2>/dev/null
      printf '%-18s FAIL      object emission or inspection failed\n' "$n" >>"$table"
      failures=$((failures + 1))
    fi
    continue
  fi
  native="$work/native/$n"
  if ! PATH="$TRIPWIRE_PATH:$PATH" "$tool" "$REPO_NATIVE/$ir" -o "$work_native/native/$n" >"$work/$n.tool.log" 2>&1; then
    printf '%-18s FAIL      %s\n' "$n" "$(head -n 1 "$work/$n.tool.log")" >>"$table"
    failures=$((failures + 1))
    continue
  fi
  problems=""
  nlibs=$(otool -L "$native" | awk 'NR > 1 { print $1 }')
  if [ "$nlibs" != "/usr/lib/libSystem.B.dylib" ]; then problems="$problems libs=$nlibs;"; fi
  ntools=$(otool -l "$native" | awk '/cmd LC_BUILD_VERSION/ { f = 1 } f && /ntools/ { print $2; exit }')
  if [ "$ntools" != "0" ]; then problems="$problems ntools=$ntools;"; fi
  if otool -l "$native" | grep -q __stub_helper; then problems="$problems __stub_helper;"; fi
  if nm -u "$native" | grep -q dyld_stub_binder; then problems="$problems dyld_stub_binder;"; fi
  mkdir -p "$work/again"
  PATH="$TRIPWIRE_PATH:$PATH" "$tool" "$REPO_NATIVE/$ir" -o "$work_native/again/$n" >/dev/null 2>&1 || problems="$problems relink;"
  if ! cmp -s "$native" "$work/again/$n"; then problems="$problems relink-bytes-differ;"; fi
  if ! native_signature_ok "$native"; then
    printf '%-18s FAIL      invalid native signature\n' "$n" >>"$table"
    failures=$((failures + 1))
    continue
  fi
  ns=$(run_bounded "$native" "$work/$n.n.out" "$work/$n.n.err")
  case "$ns" in
    ''|*[!0-9]*) printf '%-18s FAIL      native termination %s\n' "$n" "$ns" >>"$table"; cat "$work/$n.n.err"; failures=$((failures + 1)); continue ;;
  esac
  if [ -n "$problems" ]; then
    printf '%-18s FAIL      %s\n' "$n" "$problems" >>"$table"
    failures=$((failures + 1))
  elif [ "$hs" != "$ns" ] || ! cmp -s "$work/$n.h.out" "$work/$n.n.out"; then
    printf '%-18s FAIL      native status %s, hosted %s; stdout %s\n' "$n" "$ns" "$hs" \
      "$(cmp -s "$work/$n.h.out" "$work/$n.n.out" && echo same || echo differs)" >>"$table"
    failures=$((failures + 1))
  else
    printf '%-18s PASS      stdout and status equal the hosted program (status %s)\n' "$n" "$ns" >>"$table"
    passing=$((passing + 1))
  fi
done
cat "$table"
if [ "$HOST_ID" = darwin-arm64 ]; then
  echo "   $passing fixtures run end to end with no host tool"
else
  echo "   $objects fixture objects emitted and inspected; native executions are host-limited"
fi

echo "== 3b. the native backend refuses what it does not lower, and names what it refused"
for ir in bench/fixtures/native_refused/*.ir; do
  n=$(basename "$ir" .ir)
  want=$(sed -n 's/^; refused: //p' "$ir" | head -n 1)
  [ -n "$want" ] || { fail "$ir names no expected refusal"; continue; }
  if [ "$HOST_ID" != darwin-arm64 ] && [ "$n" = no_such_import ]; then
    host_limited "first-light: no_such_import is a Mach-O link refusal"
    continue
  fi
  if [ "$HOST_ID" = darwin-arm64 ]; then
    PATH="$TRIPWIRE_PATH:$PATH" "$tool" "$REPO_NATIVE/$ir" -o "$work_native/refused-$n" >"$work/refused-$n.log" 2>&1
  else
    "$cg" obj "$REPO_NATIVE/$ir" "$work_native/refused-$n.o" >"$work/refused-$n.log" 2>&1
  fi
  rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "$n was built, but the native backend does not lower it"
  elif [ "$rc" -eq 1 ] && grep -Fq "$want" "$work/refused-$n.log"; then
    echo "   refused by name: $n ($want)"
  else
    fail "$n was refused, but not for '$want': $(cat "$work/refused-$n.log")"
  fi
done

echo "== 4. the tripwire log is empty: no ld, cc, clang, gcc, codesign, dsymutil, llvm-config or as ran"
if [ "$HOST_ID" != darwin-arm64 ]; then
  host_limited "first-light tripwire: Darwin native linking was not run; Windows cannot intercept native launches with POSIX shims"
elif tripwire_fired "$work/tripwire.log"; then
  fail "the native build ran a host tool: $(cat "$work/tripwire.log")"
else
  echo "   the tripwire did not fire"
fi

# ---- 5. mutation proofs ------------------------------------------------------------------------------------------
# prove_mutation LABEL FILE CHECK -- OLD NEW [OLD NEW ...]: applies each replacement to FILE (each OLD must occur
# exactly once), runs CHECK, and requires it to return 1, the mutation caught. It returns 0 when CHECK passes, which is
# a miss, and 3 when CHECK could not build the mutated program. FILE is restored on every exit path.
prove_mutation() {
  label=$1
  file=$2
  check=$3
  shift 3
  [ "$1" = "--" ] && shift
  backup="$work/mutation-$RANDOM.bak"
  cp "$file" "$backup" || return 1
  restore="$file"
  "$PY" - "$(native_path "$file")" "$@" <<'PY'
import sys
path = sys.argv[1]
pairs = sys.argv[2:]
text = open(path, encoding="utf-8").read()
if len(pairs) % 2 != 0 or not pairs:
    sys.exit(4)
for old, new in zip(pairs[0::2], pairs[1::2]):
    if old == new:
        sys.exit(5)
    if text.count(old) != 1:
        sys.exit(3)
    text = text.replace(old, new, 1)
open(path, "w", encoding="utf-8").write(text)
PY
  applied=$?
  if [ "$applied" -eq 5 ]; then
    cp "$backup" "$file"
    restore=""
    echo "   refused: '$label' changes nothing, so it proves nothing"
    return 0
  fi
  if [ "$applied" -ne 0 ]; then
    cp "$backup" "$file"
    restore=""
    fail "could not apply '$label' (each old text must occur once in $file)"
    return 1
  fi
  mut_checked=$((mut_checked + 1))
  "$check" >"$work/mutation-check.log" 2>&1
  verdict=$?
  cp "$backup" "$file"
  restore=""
  if [ "$verdict" -eq 1 ]; then
    mut_caught=$((mut_caught + 1))
    echo "   caught: $label"
  elif [ "$verdict" -eq 0 ]; then
    fail "NOT caught: $label"
  else
    cat "$work/mutation-check.log"
    fail "invalid mutation proof for '$label' (exit $verdict)"
  fi
  return 0
}

check_tripwire() {
  b="$work/mut-tool$EXE"
  "$iyi" build -o "$(native_path "$b")" "$REPO_NATIVE/$TOOL_SRC" >"$work/mut-build.log" 2>&1 || { cat "$work/mut-build.log"; return 2; }
  mkdir -p "$work/mut-shims"
  tw="$work/mut-tripwire.log"
  tripwire_setup "$work/mut-shims" "$tw" || return 3
  PATH="$TRIPWIRE_PATH:$PATH" "$b" "$REPO_NATIVE/$FIX/arith.ir" -o "$work_native/mut-arith" >"$work/mut-run.log" 2>&1 || { cat "$work/mut-run.log"; return 2; }
  if tripwire_fired "$tw"; then return 1; fi
  return 0
}

check_mix() {
  b="$work/mut-tool$EXE"
  "$iyi" build -o "$(native_path "$b")" "$REPO_NATIVE/$TOOL_SRC" >"$work/mut-build.log" 2>&1 || { cat "$work/mut-build.log"; return 2; }
  out=$("$b" "$REPO_NATIVE/$FIX/arith.ir" -o "$work_native/mut-arith" 2>&1)
  status=$?
  if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q "produced by llvm"; then return 1; fi
  if [ "$status" -ne 0 ]; then echo "$out"; return 2; fi
  return 0
}

check_drop_helpers() {
  b="$work/mut-tool$EXE"
  "$iyi" build -o "$(native_path "$b")" "$REPO_NATIVE/$TOOL_SRC" >"$work/mut-build.log" 2>&1 || { cat "$work/mut-build.log"; return 2; }
  out=$("$b" "$REPO_NATIVE/$FIX/mem.ir" -o "$work_native/mut-mem" 2>&1)
  status=$?
  if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q "undefined symbol __iyi_native_"; then return 1; fi
  if [ "$status" -ne 0 ]; then echo "$out"; return 2; fi
  return 0
}

check_no_library() {
  local b="$work/mut-tool$EXE" baseline="$work/native/arith" baseline_bind mutant_bind
  if ! grep -Eq '^arith[[:space:]]+PASS[[:space:]]' "$table"; then
    echo "INVALID: arith did not pass the unmutated native run"; return 2
  fi
  if ! dyld_info -no_validate -imports "$baseline" >"$work/arith.bind" 2>&1; then
    cat "$work/arith.bind"; return 2
  fi
  baseline_bind="$(awk '$2 == "_printf" { line = $0; n++ } END { if (n == 1) print line; else exit 1 }' "$work/arith.bind")" || {
    echo "INVALID: baseline does not have exactly one _printf binding"; cat "$work/arith.bind"; return 2
  }
  case "$baseline_bind" in
    *"(from libSystem)") ;;
    *) echo "INVALID: baseline _printf is not bound to libSystem: $baseline_bind"; return 2 ;;
  esac
  "$iyi" build -o "$(native_path "$b")" "$REPO_NATIVE/$TOOL_SRC" >"$work/mut-build.log" 2>&1 || { cat "$work/mut-build.log"; return 2; }
  if ! "$b" "$REPO_NATIVE/$FIX/arith.ir" -o "$work_native/mut-arith" >"$work/mut-link.log" 2>&1; then
    cat "$work/mut-link.log"; return 2
  fi
  native_signature_ok "$work/mut-arith" || return 2
  if ! dyld_info -no_validate -imports "$work/mut-arith" >"$work/mut-arith.bind" 2>&1; then
    cat "$work/mut-arith.bind"; return 2
  fi
  mutant_bind="$(awk '$2 == "_printf" { line = $0; n++ } END { if (n == 1) print line; else exit 1 }' "$work/mut-arith.bind")" || {
    echo "INVALID: mutant does not have exactly one _printf binding"; cat "$work/mut-arith.bind"; return 2
  }
  case "$mutant_bind" in
    *"(from libSystem)") return 0 ;;
    *"(from "*) echo "decisive: _printf binding changed: $mutant_bind"; return 1 ;;
    *) echo "INVALID: unrecognized mutant _printf binding: $mutant_bind"; return 2 ;;
  esac
}

# A C import libSystem does not export must stop the link, by name. Unmutated, the tool refuses the fixture (the
# check passes, 0); with the question answered yes for every name, the tool builds it (caught, 1).
check_missing_import() {
  b="$work/mut-tool$EXE"
  "$iyi" build -o "$(native_path "$b")" "$REPO_NATIVE/$TOOL_SRC" >"$work/mut-build.log" 2>&1 || { cat "$work/mut-build.log"; return 2; }
  "$b" "$REPO_NATIVE/bench/fixtures/native_refused/no_such_import.ir" -o "$work_native/mut-noimport" >"$work/mut-noimport.log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$work/mut-noimport" ]; then return 1; fi
  if [ "$rc" -eq 1 ] && grep -Fq "this system's libSystem does not export it" "$work/mut-noimport.log"; then return 0; fi
  cat "$work/mut-noimport.log"
  return 2
}

check_helper_parity() {
  if ! grep -Eq '^rt_helpers[[:space:]]+PASS[[:space:]]' "$table"; then
    echo "INVALID: rt_helpers did not pass its unmutated run"; return 2
  fi
  drv="$work/native_cg$EXE"
  "$iyi" build -o "$(native_path "$drv")" "$REPO_NATIVE/src/compiler/tools/native_cg.iyi" >"$work/mut-ncg.log" 2>&1 || { cat "$work/mut-ncg.log"; return 2; }
  "$drv" obj "$REPO_NATIVE/$FL/rt_helpers.ir" "$work_native/mut-rth.o" >"$work/mut-rth.log" 2>&1 || { cat "$work/mut-rth.log"; return 2; }
  "$drv" obj "$REPO_NATIVE/$RT_SRC" "$work_native/mut-rt.o" >"$work/mut-rt.log" 2>&1 || { cat "$work/mut-rt.log"; return 2; }
  cc "$work/mut-rth.o" "$work/mut-rt.o" -o "$work/mut-rth" >"$work/mut-link.log" 2>&1 || { cat "$work/mut-link.log"; return 2; }
  native_signature_ok "$work/mut-rth" || return 2
  ms=$(run_bounded "$work/mut-rth" "$work/mut-rth.out" "$work/mut-rth.err")
  case "$ms" in ''|*[!0-9]*) echo "INVALID: helper fixture terminated with $ms"; cat "$work/mut-rth.err"; return 2 ;; esac
  if [ -s "$work/mut-rth.err" ]; then echo "INVALID: helper fixture wrote to stderr"; cat "$work/mut-rth.err"; return 2; fi
  if [ "$ms" = "0" ] && cmp -s "$work/rt_helpers.h.out" "$work/mut-rth.out"; then return 0; fi
  return 1
}

echo "== 5. mutation proofs"
if [ "$HOST_ID" = darwin-arm64 ]; then
prove_mutation "tripwire: the driver hands linking to cc" "$TOOL_SRC" check_tripwire -- \
  'import std/file' 'import std/file
import std/process::{Process}' \
  '    File.chmod(output, 493)' '    File.chmod(output, 493)
    Process.run("cc", ["--version"])'
prove_mutation "mix: an object marked with another producer" "$DRIVER_SRC" check_mix -- \
  '  objects = [program.as(ObjectFile), rt.as(ObjectFile)]' '  rt_obj = rt.as(ObjectFile)
  rt_obj.producer = "llvm"
  objects = [program.as(ObjectFile), rt_obj]'
prove_mutation "helpers: the runtime object is dropped from the link" "$DRIVER_SRC" check_drop_helpers -- \
  '  objects = [program.as(ObjectFile), rt.as(ObjectFile)]' '  objects = [program.as(ObjectFile)]'
prove_mutation "import: libSystem resolves to no library at all" "$LINK_SRC" check_no_library -- \
  '    if owner == ""
      return MachOLibs::LIBSYSTEM_ORDINAL' '    if owner == ""
      return 0_i64'
prove_mutation "import: a C name libSystem does not export is bound anyway" "$LINK_SRC" check_missing_import -- \
  '      if owner == "" && !libsystem_exports?(name)' '      if owner == "" && !libsystem_exports?(name) && false'
prove_mutation "helper: unsigned division subtracts when the remainder reaches the divisor, not when it exceeds it" \
  "$RT_SRC" check_helper_parity -- \
  '  %ge = icmp uge i128 %r1b, %b' '  %ge = icmp ugt i128 %r1b, %b'
else
  while IFS= read -r mutation; do
    mut_limited=$((mut_limited + 1))
    host_limited "first-light mutation: $mutation requires Darwin linking or execution"
  done <<'LIMITED'
tripwire: the driver hands linking to cc
mix: an object marked with another producer
helpers: the runtime object is dropped from the link
import: libSystem resolves to no library at all
import: a C name libSystem does not export is bound anyway
helper: unsigned division remainder equality
LIMITED
fi
prove_mutation "no-op: the same text on both sides" "$TOOL_SRC" check_tripwire -- \
  '  def self.fail(message : String) : Nil' '  def self.fail(message : String) : Nil'
echo "mutation summary: $mut_caught/$mut_checked attempted caught; $mut_limited host-limited"

echo
if [ "$failures" -eq 0 ]; then
  echo "== ALL NATIVE FIRST-LIGHT CHECKS PASSED"
  exit 0
fi
echo "== SOME NATIVE FIRST-LIGHT CHECKS FAILED ($failures)"
exit 1
