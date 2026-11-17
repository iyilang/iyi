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
IYI="$REPO/bin/iyi"
TOOL_SRC="$REPO/src/compiler/tools/compile_native.iyi"
PORT_SRC="$REPO/src/compiler/tools/compile.iyi"
FIXTURES="$REPO/bench/fixtures"
. "$REPO/bench/lib/tripwire.sh"
. "$REPO/bench/lib/mutation.sh"
. "$REPO/bench/lib/native_signature.sh"

WORK="$(mktemp -d /tmp/iyi-native-source.XXXXXX)"
export NATIVE_SIGNATURE_FAILURE_FILE="$WORK/signature-failure"
trap 'rm -rf "$WORK"' EXIT

status=0

echo "== 1. build the tools from source"
mkdir -p "$WORK/bin" "$WORK/ref" "$WORK/port" "$WORK/nat"
tool="$WORK/bin/iyi-compile-native"
# build_failed LABEL LOG: the log is under $WORK, which is removed on exit, so what the build said is printed here.
build_failed() {
  echo "FAIL: $1 does not build; the build said:"
  grep -v '^ld: warning' "$2" | tail -n 25 | sed 's/^/    /'
  exit 1
}
if ! "$IYI" build -o "$tool" "$TOOL_SRC" >"$WORK/build.tool.log" 2>&1; then
  build_failed "iyi-compile-native" "$WORK/build.tool.log"
fi
echo "   built iyi-compile-native (native backend) from $TOOL_SRC"
port="$WORK/bin/iyi-compile-port-llvm"
if ! "$IYI" build -o "$port" "$PORT_SRC" >"$WORK/build.port.log" 2>&1; then
  build_failed "the port+LLVM build" "$WORK/build.port.log"
fi
echo "   built iyi-compile-port-llvm (port pipeline, LLVM backend) from $PORT_SRC"

echo "== 2. the native tool links libSystem alone and carries no LLVM symbol"
tool_libs=$(otool -L "$tool" | awk 'NR > 1 { print $1 }')
if [ "$tool_libs" = "/usr/lib/libSystem.B.dylib" ]; then
  echo "   only /usr/lib/libSystem.B.dylib"
else
  echo "FAIL: the native tool links: $tool_libs"
  status=1
fi
llvm_syms=$(nm "$tool" 2>/dev/null | awk '/ _LLVM[A-Za-z]|LibLLVM|Compiler::Llvm/ { n++ } END { print n + 0 }')
if [ "$llvm_syms" = "0" ]; then
  echo "   no LLVM C-API or Compiler::Llvm symbol in the native tool"
else
  echo "FAIL: the native tool carries $llvm_syms LLVM C-API or Compiler::Llvm symbols"
  status=1
fi

# compare_run REF EXE LABEL NAME: runs both executables. Requires identical stdout and exit status, and for the built
# executable a valid signature and libSystem alone. Prints one line naming what was compared. Returns 0 only on a match.
compare_run() {
  local ref="$1" exe="$2" label="$3" name="$4" ref_out exe_out ref_rc exe_rc problems libs
  ref_out=$(timeout 30 "$ref" </dev/null 2>/dev/null)
  ref_rc=$?
  native_signature_ok "${5:-$exe}" || return 1
  exe_out=$(timeout 30 "$exe" </dev/null 2>/dev/null)
  exe_rc=$?
  if [ "$ref_out" != "$exe_out" ] || [ "$ref_rc" != "$exe_rc" ]; then
    echo "FAIL: $name: $label run diverged from the hosted build (exit $exe_rc vs hosted $ref_rc)"
    return 1
  fi
  problems=""
  if [ "$(uname -s)" = Darwin ]; then
    native_signature_ok "${5:-$exe}" || problems="$problems codesign;"
  fi
  libs=$(otool -L "$exe" | awk 'NR > 1 { print $1 }')
  if [ "$libs" != "/usr/lib/libSystem.B.dylib" ]; then problems="$problems libs=$libs;"; fi
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
  awk 'NR == FNR { if (NF) seen[$1] = 1; next } !/^#/ && NF && !($1 in seen) { print "   ratchet: " $1 " no longer occurs; remove it from " FILENAME }' "$measured" "$ceiling"
  return 0
}

echo "== 3. every fixture: the hosted reference, then the port+LLVM column and the native column"
tripwire_setup "$WORK/tripwire" "$WORK/tripwire.log" || { echo "FAIL: tripwire setup"; exit 1; }
FIX="${NATIVE_SOURCE_FIXTURES:-$FIXTURES}"
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
  ref="$WORK/ref/$n"
  pexe="$WORK/port/$n"
  nexe="$WORK/nat/$n"
  ref_how="as written"
  if "$IYI" build -o "$ref" "$f" >"$WORK/ref/$n.log" 2>&1; then
    ref_ok=1
  elif IYI_PATH="$REPO/src:$FIX" "$IYI" build -o "$ref" "$WORK/marked/$n.iyi" >"$WORK/ref/$n.marked.log" 2>&1; then
    ref_ok=1
    ref_how="copy with @[Unsafe] header"
    marked_refs=$((marked_refs + 1))
    echo "$n" >>"$WORK/u_measured.txt"
    echo "   U the hosted reference needs the @[Unsafe] header: $n"
  else
    ref_ok=0
  fi
  if "$port" "$f" -o "$pexe" >"$WORK/port/$n.log" 2>&1; then port_ok=1; else port_ok=0; fi
  if PATH="$TRIPWIRE_PATH:$PATH" "$tool" "$f" -o "$nexe" >"$WORK/nat/$n.log" 2>&1; then nat_ok=1; else nat_ok=0; fi

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
      s_shared=$((s_shared + 1))
      echo "   S refused by the hosted compiler, the port and the native back end: $n: $err"
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

if tripwire_fired "$WORK/tripwire.log"; then
  echo "FAIL: a host tool started during a native build:"
  awk '{ print }' "$WORK/tripwire.log"
  status=1
fi
if [ "$f_failed" -ne 0 ]; then status=1; fi
echo "  port+LLVM column: $port_equal equal to hosted, $port_differs differ, $port_refused refused"
echo "  Native source summary: $n_equal of $total run equal to the hosted compiler's build (native vs hosted); $g_gaps port gaps; $r_native_only refused by the native back end only; $s_shared refused by the hosted compiler too; $p_accepts port accepts what the hosted compiler refuses (P); $f_failed failed; $marked_refs need the @[Unsafe] header in the hosted reference (U)"

echo "== 3b. ceilings: a count may only fall (P: the port accepts what the hosted compiler refuses; U: the hosted reference needs the @[Unsafe] header)"
check_ceiling "$WORK/p_measured.txt" "$REPO/bench/native_source.ceiling" "P" || status=1
check_ceiling "$WORK/u_measured.txt" "$REPO/bench/native_source_unsafe.ceiling" "U" || status=1
if [ -n "${NATIVE_SOURCE_NO_SELFCHECK:-}" ]; then exit "$status"; fi

echo "== 4. source mutations: each must be caught by a check that fails on the mutated source"
mut_run=0
mut_caught=0
ref_arith="$WORK/ref/compile_arith"
ref_arith_out=$(timeout 30 "$ref_arith" </dev/null 2>/dev/null)
ref_arith_rc=$?

# (a) the native backend hands linking to cc: a real build must trip the wire.
check_cc_in_native_build() {
  "$IYI" build -o "$WORK/mut-a-tool" "$TOOL_SRC" >/dev/null 2>&1 || return 0
  : >"$WORK/tripwire.log"
  PATH="$TRIPWIRE_PATH:$PATH" "$WORK/mut-a-tool" "$FIXTURES/compile_arith.iyi" -o "$WORK/mut-a-exe" >/dev/null 2>&1
  if tripwire_fired "$WORK/tripwire.log"; then return 1; fi
  return 0
}
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

# (b) the subtraction operands swapped where codegen emits integer subtraction. compile_arith exits with v1 &- v2 and
# ops(5, 3) = (8) &* (5 &- 3), so the exit status moves from 26 to 58 under the swap: the status must change.
check_subtraction_output() {
  "$IYI" build -o "$WORK/mut-b-tool" "$TOOL_SRC" >/dev/null 2>&1 || return 0
  "$WORK/mut-b-tool" "$FIXTURES/compile_arith.iyi" -o "$WORK/mut-b-exe" >/dev/null 2>&1 || return 0
  native_signature_ok "$WORK/mut-b-exe" || return 1
  local out rc
  out=$(timeout 30 "$WORK/mut-b-exe" </dev/null 2>/dev/null)
  rc=$?
  if [ "$out" != "$ref_arith_out" ] || [ "$rc" != "$ref_arith_rc" ]; then return 1; fi
  return 0
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
  "$IYI" build -o "$WORK/mut-c-tool" "$TOOL_SRC" >/dev/null 2>&1 || return 0
  "$WORK/mut-c-tool" "$FIXTURES/compile_arith.iyi" -o "$WORK/mut-c-exe" >/dev/null 2>&1 || return 0
  if codesign -v --strict "$WORK/mut-c-exe" >/dev/null 2>&1; then return 0; fi
  return 1
}
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

# (d) a patch that changes nothing is refused by name, with exit 3, and does not count.
mut_run=$((mut_run + 1))
( prove_mutation "a patch that changes nothing" \
    "$REPO/src/compiler/tools/compile_native.iyi" \
    "CompileNative.run" "CompileNative.run" -- true ) >"$WORK/noop.log" 2>&1
noop_rc=$?
if [ "$noop_rc" = 3 ]; then
  mut_caught=$((mut_caught + 1))
  echo "    refused: a patch that changes nothing (exit 3)"
else
  status=1
  echo "FAIL: a patch that changes nothing was not refused (exit $noop_rc)"
fi

# Self-check of compare_run, not a compiler mutation: a native exit status off by one and extra stdout must diverge.
echo "  self-check of compare_run (not a compiler mutation):"
sample_exe="$WORK/nat/compile_arith"
printf '#!/bin/sh\n"%s"\nrc=$?\nexit $((rc + 1))\n' "$sample_exe" >"$WORK/selfcheck_status"
chmod +x "$WORK/selfcheck_status"
if compare_run "$WORK/ref/compile_arith" "$WORK/selfcheck_status" "self-check" "exit off by one" "$sample_exe" >/dev/null 2>&1; then
  status=1
  echo "FAIL: compare_run accepted an exit status off by one"
else
  echo "   compare_run diverges on an exit status off by one"
fi
printf '#!/bin/sh\n"%s"\nrc=$?\necho extra-line\nexit $rc\n' "$sample_exe" >"$WORK/selfcheck_stdout"
chmod +x "$WORK/selfcheck_stdout"
if compare_run "$WORK/ref/compile_arith" "$WORK/selfcheck_stdout" "self-check" "extra stdout" "$sample_exe" >/dev/null 2>&1; then
  status=1
  echo "FAIL: compare_run accepted extra stdout"
else
  echo "   compare_run diverges on extra stdout"
fi

echo "  Mutation summary: $mut_caught/$mut_run source mutations caught (a: cc in native build, b: subtraction operands, c: unsigned executable, d: no-op patch refused)"
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
