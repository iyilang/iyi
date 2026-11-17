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
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"$PATH"
export LIBRARY_PATH=${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}

iyi=./bin/iyi
TOOL_SRC=src/compiler/tools/compile_native.iyi
BRIDGE_SRC=src/compiler/tools/ir.iyi
FLOOR=bench/native_whole_program.floor
FIX=bench/fixtures/native_whole

work="$(mktemp -d "${TMPDIR:-/tmp}/native_whole.XXXXXX")" || exit 1
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

run_bounded() {
  perl -e 'alarm 30; exec @ARGV or exit 127' -- "$1" >"$2" 2>"$3" </dev/null
  echo $?
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
  "$iyi" build -o "$1/compile_native" "$TOOL_SRC" >"$1/build.tool.log" 2>&1 || return 1
  "$iyi" build -o "$1/iyi-ir" "$BRIDGE_SRC" >"$1/build.bridge.log" 2>&1 || return 1
}

# hosted_of SRC DIR: the hosted executable DIR/hosted and its IR DIR/hosted.ll, with its run recorded, and the
# frameworks its link named in DIR/frameworks (one per line; the hosted link command is the only place bridged IR's
# @[Link] survives, so --verbose prints it and the names are read from there).
hosted_of() {
  mkdir -p "$2"
  "$iyi" build --no-debug --verbose --emit llvm-ir -o "$2/hosted" "$1" >"$2/hosted.log" 2>&1 || return 1
  [ -f "$2/hosted.ll" ] || return 1
  awk '{ for (i = 1; i < NF; i++) if ($i == "-framework") print $(i + 1) }' "$2/hosted.log" | sort -u >"$2/frameworks"
  run_bounded "$2/hosted" "$2/h.out" "$2/h.err" >"$2/h.status"
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
  if ! "$tools/iyi-ir" import "$dir/hosted.ll" >"$dir/p.ir" 2>"$dir/import.err"; then
    printf 'import\t%s\n' "$(import_refusal "$dir/import.err" "$dir/p.ir")"
    return
  fi
  # The sidecar of bridged IR (SPEC 2.3): the libraries the program's lib blocks link, beside the IR.
  rm -f "$dir/p.ir.imports"
  [ -s "$dir/frameworks" ] && cp "$dir/frameworks" "$dir/p.ir.imports"
  if ! PATH="$TRIPWIRE_PATH:$PATH" "$tools/compile_native" "$dir/p.ir" -o "$dir/native" >"$dir/native.log" 2>&1; then
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
libs=$(otool -L "$tools/compile_native" | awk 'NR > 1 { print $1 }')
if [ "$libs" = "/usr/lib/libSystem.B.dylib" ]; then
  echo "   iyi-compile-native links only /usr/lib/libSystem.B.dylib"
else
  fail "iyi-compile-native links: $libs"
fi

echo "== 2. every program: hosted IR, import, native build under the tripwire, run, equal to the hosted run"
tripwire_setup "$work/shims" "$work/tripwire.log" || { echo "FAIL: cannot set up the tripwire"; exit 1; }
table="$work/table.txt"
: >"$table"
measured="$work/measured.floor"
: >"$measured"
total=0
equal=0
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
  phase=${result%%$'\t'*}
  why=${result#*$'\t'}
  [ "$phase" = "run-equal" ] && equal=$((equal + 1))
  printf '  %-44s %-10s %s\n' "$src" "$phase" "$(printf '%s' "$why" | cut -c1-160)" >>"$table"
  printf '%s %s\n' "$src" "$phase" >>"$measured"
done
cat "$table"
echo "   $equal of $total programs run equal to the hosted executable"

echo "== 2c. parser and AST exercise over the source corpus"
parser="$work/p/src_compiler_tools_parse"
exercise="$work/p/parser_exercise"
if ! awk '$1 == "src/compiler/tools/parse.iyi" && $2 == "run-equal" { found = 1 } END { exit !found }' "$measured"; then
  fail "parser bridge executable did not run equal"
elif ! hosted_of bench/selfhost_parser_exercise.iyi "$exercise"; then
  fail "hosted parser exercise build failed"
else
  result=$(phase_of "$tools" "$exercise")
  if [ "${result%%$'\t'*}" != "run-equal" ]; then
    fail "parser exercise did not run equal: $result"
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
if [ "${NATIVE_WHOLE_PROGRAM_RAISE:-0}" = "1" ]; then
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
  echo "   every program is at its floor"
else
  fail "$below program(s) are off their floor"
fi

echo "== 2b. a library the native floor does not provide is refused by name"
hello_p="$work/p/samples_iyi_hello"
if [ -f "$hello_p/p.ir" ]; then
  mkdir -p "$work/lib"
  cp "$hello_p/p.ir" "$work/lib/p.ir"
  printf 'Bogus\n' >"$work/lib/p.ir.imports"
  if "$tools/compile_native" "$work/lib/p.ir" -o "$work/lib/exe" >"$work/lib/log" 2>&1; then
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
if ! "$iyi" build --no-debug --emit llvm-ir -o "$self/hosted" "$TOOL_SRC" >"$self/hosted.log" 2>&1 || [ ! -f "$self/hosted.ll" ]; then
  fail "the hosted compiler wrote no IR for $TOOL_SRC"
elif ! "$tools/iyi-ir" import "$self/hosted.ll" >"$self/cn.ir" 2>"$self/import.err"; then
  fail "the tool's own IR is refused by the import: $(import_refusal "$self/import.err" "$self/cn.ir")"
elif ! PATH="$TRIPWIRE_PATH:$PATH" "$tools/compile_native" "$self/cn.ir" -o "$self/a/cn" >"$self/a.log" 2>&1; then
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
    "$tools/compile_native" "$hello_dir/p.ir" -o "$self/h1/hello" >/dev/null 2>&1
    if native_signature_ok "$self/b/cn"; then
      "$self/b/cn" "$hello_dir/p.ir" -o "$self/h2/hello" >/dev/null 2>&1
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
if tripwire_fired "$work/tripwire.log"; then
  fail "a host tool was run during a native build: $(head -n 3 "$work/tripwire.log")"
else
  echo "   no host tool ran"
fi

echo "== 5. mutation proofs"
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
    cp "$tools/compile_native" "$t/compile_native"
    "$iyi" build -o "$t/iyi-ir" "$BRIDGE_SRC" >"$t/build.bridge.log" 2>&1 || { printf '%s\n' "${label:-bridge}" >> "$work/mutation-build-failed"; cat "$t/build.bridge.log" >> "$work/mutation-build-failed"; return 1; }
  else
    cp "$tools/iyi-ir" "$t/iyi-ir"
    "$iyi" build -o "$t/compile_native" "$TOOL_SRC" >"$t/build.tool.log" 2>&1 || { printf '%s\n' "${label:-native}" >> "$work/mutation-build-failed"; cat "$t/build.tool.log" >> "$work/mutation-build-failed"; return 1; }
  fi
  dir="$work/p/$(dirname "$src" | tr '/' '_')_$(basename "$src" .iyi)"
  [ -f "$dir/hosted.ll" ] || return 1
  result=$(phase_of "$t" "$dir")
  [ "${result%%$'\t'*}" = "run-equal" ]
}
unmutated=1
for src in samples/iyi/hello.iyi "$FIX/wide_result.iyi" "$FIX/wide_division.iyi" "$FIX/float_to_int.iyi" "$FIX/quoted_name.iyi" samples/iyi/cores.iyi; do
  awk -v p="$src" '$1 == p && $2 == "run-equal" { found = 1 } END { exit !found }' "$measured" || unmutated=0
done
if [ "$unmutated" -ne 1 ]; then
  fail "a program the mutation proofs read did not run equal on the unmutated tree, so no mutation was run"
else
  status=0
  prove_mutation "a def imported with the C convention" src/compiler/backend/llvm/import.iyi \
    'return CallConv::Iyi if name.starts_with?("*") || name.starts_with?("~")' \
    'return CallConv::C if name.starts_with?("*") || name.starts_with?("~")' -- still_runs bridge samples/iyi/hello.iyi || status=1
  prove_mutation "a constant field address loses its offset" src/compiler/native/const_expr.iyi \
    'off = off + layout.offset_of(cur, n.to_i32)' 'off = off + 0_i64' -- still_runs native samples/iyi/hello.iyi || status=1
  prove_mutation "a thread-local operand takes the plain symbol address" src/compiler/native/aarch64/isel.iyi \
    'return [thread_local_address(g)] if g.tls != TlsModel::None' \
    'return [symbol_address(g.name, false, false)] if g.tls != TlsModel::None' -- still_runs native samples/iyi/hello.iyi || status=1
  prove_mutation "a ret after a naked function's template is refused" src/compiler/native/aarch64/isel.iyi \
    '      if i.op == Op::Ret
        next
      end' '      if i.op == Op::Ret
        fail("a ret is refused")
        return @mf
      end' -- still_runs native samples/iyi/hello.iyi || status=1
  prove_mutation "wide unsigned division helper is absent" src/compiler/native/driver.iyi \
    '"__iyi_native_udivti3", "__iyi_native_umodti3", "__iyi_native_divti3", "__iyi_native_modti3"].each do |helper|' \
    '"__iyi_native_umodti3", "__iyi_native_divti3", "__iyi_native_modti3"].each do |helper|' -- still_runs native "$FIX/wide_division.iyi" || status=1
  prove_mutation "a wide internal result is never passed in memory" src/compiler/native/lower.iyi \
    'gprs > desc.integer_args.size || fprs > desc.fp_args.size' 'false' -- still_runs native "$FIX/wide_result.iyi" || status=1
  prove_mutation "a quote escaped in a name ends the name" src/compiler/ir/parser.iyi \
    'stop = stop + (line.byte_at(stop) == 92_u8 && stop + 1 < line.bytesize ? 2 : 1)' 'stop = stop + 1' -- still_runs native "$FIX/quoted_name.iyi" || status=1
  prove_mutation "a numbered parameter is taken as a name" src/compiler/ir/parser.iyi \
    'param_names << (written.numeric ? "" : written.text)' 'param_names << written.text' -- still_runs native samples/iyi/hello.iyi || status=1
  prove_mutation "a library named beside the IR is not loaded" src/compiler/tools/compile_native.iyi \
    'names << name unless name.empty? || name.starts_with?("#")' \
    'names << name if name.empty?' -- still_runs native samples/iyi/cores.iyi || status=1
  prove_mutation "an i8 saturating conversion uses the i16 clamp" src/compiler/native/aarch64/isel.iyi \
    '    d = clamp_narrow(d, bits, signed) if clamp' '    d = clamp_narrow(d, 16, signed) if clamp' -- still_runs native "$FIX/float_to_int.iyi" || status=1
  prove_mutation "the unsigned 128-bit conversion calls the signed helper" src/compiler/native/aarch64/isel.iyi \
    'call.sym = symbol_index(signed ? "__iyi_native_fptosi_sat_i128" : "__iyi_native_fptoui_sat_i128")' \
    'call.sym = symbol_index("__iyi_native_fptosi_sat_i128")' -- still_runs native "$FIX/float_to_int.iyi" || status=1
  prove_mutation "the signed 128-bit helper saturates one exponent late" src/compiler/native/rt/builtins_text.iyi \
    '%past = icmp uge i64 %exp, 1150' '%past = icmp uge i64 %exp, 1151' -- still_runs native "$FIX/float_to_int.iyi" || status=1
  if [ -e "$work/mutation-build-failed" ]; then
    echo "NOT PROVEN: a mutation tool failed to build:"
    cat "$work/mutation-build-failed"
    fail "a mutation tool failed to build; its behavior is not proven"
  fi
  [ "$status" -eq 0 ] || fail "a mutation was not caught"
fi

[ ! -e "$NATIVE_SIGNATURE_FAILURE_FILE" ] || fail "a native executable failed signature verification"
echo
if [ "$failures" -eq 0 ]; then
  echo "== ALL NATIVE WHOLE PROGRAM CHECKS PASSED"
  exit 0
fi
echo "== SOME NATIVE WHOLE PROGRAM CHECKS FAILED ($failures)"
exit 1
