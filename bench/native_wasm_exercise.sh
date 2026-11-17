#!/usr/bin/env bash
# The wasm32-wasi back end gate (SPEC 2.2 wasm32-wasi row, 3.3; slice D5). The back end writes one module
# from an IR program and the native runtime's IR; no linker, no host tool takes part in writing it.
#
#   bench/native_wasm_exercise.sh
#
# Steps, in order:
#   1. the tools build with the hosted compiler, and the embedded runtime text is in sync with its source;
#   2. the module writer and the reader: a hand-built module validates and runs under wasmtime, and the reader
#      lists what the writer wrote;
#   3. every fixture under bench/fixtures/native_wasm/ compiles to a module the reader accepts (imports only
#      wasi_snapshot_preview1, no producers section), runs under wasmtime, and matches its .expected stdout and
#      its .exit status. On darwin the expected output is also recomputed from the aarch64-darwin native build
#      of the same IR (bench/native_wasm_darwin.py), so a stale .expected file is caught here;
#   4. the native_cg corpus under a wasm retarget: each program is built or refused, and every refusal is named;
#   5. mutations of the back end are each caught, and a patch that changes nothing is refused;
#   6. the identity floor.
#
# wasmtime runs the modules: found on PATH, or set WASMTIME. Without it steps 2 and 3 are reported as skipped,
# never passed. Steps that need darwin (the fresh oracle in step 3) are skipped on other hosts.
set -u
cd "$(dirname "$0")/.." || exit 1

WORK=$(mktemp -d "${TMPDIR:-/tmp}/native-wasm.XXXXXX")
CG=src/compiler/native/wasm/codegen.iyi
CG_BACKUP="$WORK/codegen.iyi.orig"
FIX=bench/fixtures/native_wasm
CG_FIX=bench/fixtures/native_cg
FIXTURES="arith control floats memory calls exit intrin smoke"

restore_codegen() {
  if [ -f "$CG_BACKUP" ]; then
    cp "$CG_BACKUP" "$CG"
  fi
  rm -rf "$WORK"
}
trap restore_codegen EXIT INT TERM

export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"$PATH"
export LIBRARY_PATH=${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}
. bench/lib/native_signature.sh

WASMTIME=${WASMTIME:-$(command -v wasmtime 2>/dev/null || true)}
if [ -z "$WASMTIME" ] && [ -x /Users/jwaldrip/.wasmtime/bin/wasmtime ]; then
  WASMTIME=/Users/jwaldrip/.wasmtime/bin/wasmtime
fi

failed=0
fail() { echo "FAIL: $*"; failed=1; }
passed_modules=0
passed_fixtures=0
mutations_caught=0
native_cg_built=0
native_cg_refused=0

# ---- 1. the tools and the runtime text -------------------------------------------------------------------
echo "== 1. the tools build, and the runtime text is in sync"
if ! ./bin/iyi build -o "$WORK/cn" src/compiler/tools/compile_native.iyi >"$WORK/build_cn.log" 2>&1; then
  tail -n 20 "$WORK/build_cn.log"
  echo "FAIL: iyi-compile-native does not build"
  exit 1
fi
./bin/iyi build -o "$WORK/hand_add" "$FIX/hand_add.iyi" >"$WORK/build_hand.log" 2>&1 || fail "hand_add does not build"
./bin/iyi build -o "$WORK/inspect" "$FIX/inspect.iyi" >"$WORK/build_inspect.log" 2>&1 || fail "inspect does not build"
python3 bench/native_wasm_gen.py --check || fail "the embedded runtime text is out of date"

# ---- 2. the writer and the reader ------------------------------------------------------------------------
echo "== 2. the module writer and reader"
if [ -z "$WASMTIME" ]; then
  echo "skipped: needs wasmtime (set WASMTIME or put it on PATH)"
else
  "$WORK/hand_add" "$WORK/hand.wasm" >/dev/null || fail "hand_add did not write its module"
  got=$("$WASMTIME" run --invoke add "$WORK/hand.wasm" 2 3 2>/dev/null)
  if [ "$got" = "5" ]; then
    passed_modules=$((passed_modules + 1))
    echo "hand-built add(2, 3) = 5 under wasmtime"
  else
    fail "hand-built add(2, 3) printed '$got', not 5"
  fi
  "$WORK/inspect" "$WORK/hand.wasm" >"$WORK/hand.inspect" || fail "the reader failed on the hand-built module"
  if grep -q '^export add kind=0 index=0$' "$WORK/hand.inspect" && grep -q '^export memory kind=2 index=0$' "$WORK/hand.inspect"; then
    echo "the reader lists the exports the writer wrote"
  else
    cat "$WORK/hand.inspect"
    fail "the reader does not list the hand-built exports"
  fi
fi

# ---- 3. the fixtures ----------------------------------------------------------------------------------------
echo "== 3. every fixture runs as its expected output says"
if [ -z "$WASMTIME" ]; then
  echo "skipped: needs wasmtime"
else
  for f in $FIXTURES; do
    if ! "$WORK/cn" "$FIX/$f.ir" -o "$WORK/$f.wasm" --target wasm32-wasi >"$WORK/$f.build" 2>&1; then
      cat "$WORK/$f.build"
      fail "$f does not compile to wasm"
      continue
    fi
    "$WORK/inspect" "$WORK/$f.wasm" >"$WORK/$f.inspect" 2>&1 || { fail "$f: the reader failed"; continue; }
    if grep -q '^ERROR' "$WORK/$f.inspect"; then
      fail "$f: the reader rejects the module"
      continue
    fi
    bad_imports=$(awk '/^import / && $2 != "wasi_snapshot_preview1" { n++ } END { print n + 0 }' "$WORK/$f.inspect")
    producers=$(awk '$1 == "section" && $2 == 0 && $3 != "name" { n++ } END { print n + 0 }' "$WORK/$f.inspect")
    if [ "$bad_imports" != "0" ] || [ "$producers" != "0" ]; then
      fail "$f: a non-wasi import ($bad_imports) or a custom section other than name ($producers)"
      continue
    fi
    timeout 30 "$WASMTIME" run "$WORK/$f.wasm" >"$WORK/$f.out" 2>"$WORK/$f.err"
    status=$?
    want_status=$(cat "$FIX/$f.exit")
    if [ "$status" != "$want_status" ]; then
      cat "$WORK/$f.err"
      fail "$f: wasmtime exited $status, expected $want_status"
      continue
    fi
    if ! cmp -s "$WORK/$f.out" "$FIX/$f.expected"; then
      diff "$FIX/$f.expected" "$WORK/$f.out" | head -n 10
      fail "$f: stdout differs from $FIX/$f.expected"
      continue
    fi
    if [ "$(uname -s)" = "Darwin" ]; then
      python3 bench/native_wasm_darwin.py "$FIX/$f.ir" "$WORK/$f.darwin.ir" || fail "$f: no darwin oracle"
      if ! "$WORK/cn" "$WORK/$f.darwin.ir" -o "$WORK/$f.bin" >"$WORK/$f.dbuild" 2>&1; then
        cat "$WORK/$f.dbuild"
        fail "$f: the darwin oracle does not build"
        continue
      fi
      if ! native_signature_ok "$WORK/$f.bin"; then
        fail "$f: invalid darwin oracle signature"
        continue
      fi
      "$WORK/$f.bin" >"$WORK/$f.dout" 2>/dev/null
      if ! cmp -s "$WORK/$f.dout" "$FIX/$f.expected"; then
        fail "$f: $FIX/$f.expected is stale against the darwin oracle"
        continue
      fi
    fi
    passed_modules=$((passed_modules + 1))
    passed_fixtures=$((passed_fixtures + 1))
    echo "$f: $(awk 'END { print NR }' "$WORK/$f.out") lines, exit $status, equal to its expected output"
  done
  echo "fixtures equal to expected: $passed_fixtures of $(echo $FIXTURES | wc -w | tr -d ' ')"
fi

# ---- 4. the native_cg corpus under a wasm retarget ---------------------------------------------------------
echo "== 4. the native_cg corpus, retargeted to wasm32-wasi"
python3 - "$CG_FIX" "$WORK/cg" <<'PY'
import pathlib, sys
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
dst.mkdir(parents=True, exist_ok=True)
for p in sorted(src.glob("*.ir")):
    out = []
    for line in p.read_text().splitlines():
        if line.startswith("target triple"):
            out.append('target triple = "wasm32-wasi"')
        elif line.startswith("target datalayout"):
            out.append('target datalayout = "e-m:e-p:32:32-p10:8:8-p20:8:8-i64:64-i128:128-n32:64-S128-ni:1:10:20"')
        else:
            out.append(line)
    (dst / p.name).write_text("\n".join(out) + "\n")
PY
cg_table="$WORK/cg_table.txt"
: >"$cg_table"
cg_equal=0
cg_differ=0
for f in "$WORK"/cg/*.ir; do
  name=$(basename "$f" .ir)
  if "$WORK/cn" "$f" -o "$WORK/cg/$name.wasm" --target wasm32-wasi >"$WORK/cg/$name.log" 2>&1; then
    native_cg_built=$((native_cg_built + 1))
    if [ "$(uname -s)" != "Darwin" ] || [ -z "$WASMTIME" ]; then
      echo "$name	built, not run (needs darwin and wasmtime)" >>"$cg_table"
      continue
    fi
    if ! "$WORK/cn" "$CG_FIX/$name.ir" -o "$WORK/cg/$name.bin" >"$WORK/cg/$name.dbuild" 2>&1; then
      echo "$name	built, but the darwin oracle does not build" >>"$cg_table"
      cg_differ=$((cg_differ + 1))
      continue
    fi
    if ! native_signature_ok "$WORK/cg/$name.bin"; then
      fail "$name: invalid darwin oracle signature"
      cg_differ=$((cg_differ + 1))
      continue
    fi
    timeout 30 "$WORK/cg/$name.bin" >"$WORK/cg/$name.dout" 2>/dev/null
    dstatus=$?
    timeout 30 "$WASMTIME" run "$WORK/cg/$name.wasm" >"$WORK/cg/$name.wout" 2>"$WORK/cg/$name.werr"
    wstatus=$?
    if [ "$dstatus" = "$wstatus" ] && cmp -s "$WORK/cg/$name.dout" "$WORK/cg/$name.wout"; then
      cg_equal=$((cg_equal + 1))
      echo "$name	built, runs equal to the darwin build (exit $wstatus)" >>"$cg_table"
    else
      cg_differ=$((cg_differ + 1))
      echo "$name	built, DIFFERS from the darwin build (darwin exit $dstatus, wasm exit $wstatus)" >>"$cg_table"
    fi
  else
    native_cg_refused=$((native_cg_refused + 1))
    reason=$(sed -n 's/.*: \(.*\)$/\1/p' "$WORK/cg/$name.log" | head -n 1)
    echo "$name	refused: $reason" >>"$cg_table"
  fi
done
awk -F'\t' '{ print }' "$cg_table"
echo "native_cg: $native_cg_built built and $native_cg_refused refused; of the built, $cg_equal run equal to the darwin build and $cg_differ differ or have no oracle"
if [ "$cg_differ" != "0" ]; then
  fail "a built native_cg program does not run equal to its darwin build"
fi

# ---- 5. mutations -----------------------------------------------------------------------------------------
echo "== 5. each mutation of the back end is caught"
if [ -z "$WASMTIME" ]; then
  echo "skipped: needs wasmtime"
else
  cp "$CG" "$CG_BACKUP"
  run_mutation() {
    local label=$1 old=$2 new=$3
    python3 bench/native_wasm_mutate.py "$CG" "$old" "$new"
    local rc=$?
    if [ $rc -eq 3 ]; then
      echo "$label: refused, the patch changes nothing"
      cp "$CG_BACKUP" "$CG"
      return
    fi
    if [ $rc -ne 0 ]; then
      cp "$CG_BACKUP" "$CG"
      fail "$label: the mutation cannot be applied as written"
      return
    fi
    if ! ./bin/iyi build -o "$WORK/cn_mut" src/compiler/tools/compile_native.iyi >"$WORK/mut.build" 2>&1; then
      mutations_caught=$((mutations_caught + 1))
      echo "$label: caught (the mutated tool does not build)"
      cp "$CG_BACKUP" "$CG"
      return
    fi
    caught=""
    for f in arith control memory; do
      if ! "$WORK/cn_mut" "$FIX/$f.ir" -o "$WORK/mut.wasm" --target wasm32-wasi >/dev/null 2>&1; then
        caught="$f does not compile"
        break
      fi
      timeout 30 "$WASMTIME" run "$WORK/mut.wasm" >"$WORK/mut.out" 2>/dev/null
      if [ $? -ne "$(cat "$FIX/$f.exit")" ] || ! cmp -s "$WORK/mut.out" "$FIX/$f.expected"; then
        caught="$f differs"
        break
      fi
    done
    cp "$CG_BACKUP" "$CG"
    if [ -n "$caught" ]; then
      mutations_caught=$((mutations_caught + 1))
      echo "$label: caught ($caught)"
    else
      fail "$label: no fixture notices the mutation"
    fi
  }
  run_mutation "unsigned division emitted as signed" \
    "byte(wide ? 128_u8 : 110_u8)" "byte(wide ? 127_u8 : 109_u8)"
  run_mutation "a branch depth off by one" \
    "uleb_i(@code, depth)" "uleb_i(@code, depth + 1)"
  run_mutation "a load and store with the wrong offset" \
    "uleb_i(@code, log2_of(a))
    uleb_i(@code, 0)" "uleb_i(@code, log2_of(a))
    uleb_i(@code, 4)"
  run_mutation "signed comparison without sign extension" \
    "sext_top(v.type.bits)" "nil"
  run_mutation "select with its arms swapped" \
    "push(i.args[1])
      push(i.args[2])
      push(i.args[0])
      byte(27_u8)" "push(i.args[2])
      push(i.args[1])
      push(i.args[0])
      byte(27_u8)"
  run_mutation "identity patch (must be refused)" \
    "sext_top(v.type.bits)" "sext_top(v.type.bits)"
  if cmp -s "$CG" "$CG_BACKUP"; then
    echo "codegen.iyi restored after the mutations"
  else
    fail "codegen.iyi was not restored after the mutations"
  fi
  echo "mutations caught: $mutations_caught of 5"
  if [ "$mutations_caught" != "5" ]; then
    fail "not every mutation is caught"
  fi
fi

# ---- 6. the identity floor -------------------------------------------------------------------------------
echo "== 6. the identity floor"
if python3 bench/identity_floor.py >"$WORK/identity.log" 2>&1; then
  echo "identity floor: ok"
else
  cat "$WORK/identity.log"
  fail "the identity floor fails"
fi

echo "== summary"
echo "modules validated and run under wasmtime: $passed_modules"
echo "fixtures equal to their expected output: $passed_fixtures"
echo "mutations caught: $mutations_caught"
if [ $failed -eq 0 ]; then
  echo "native_wasm_exercise: passed"
  exit 0
fi
echo "native_wasm_exercise: FAILED"
exit 1
