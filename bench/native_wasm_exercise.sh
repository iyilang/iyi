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
REPO="$(pwd -P)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if [ -z "$PY" ]; then echo "a working Python interpreter is required" >&2; exit 1; fi
REPO_NATIVE="$(native_path "$REPO")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/native-wasm.XXXXXX")
WORK_NATIVE="$(native_path "$WORK")" || exit 1
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

if [ "$HOST_OS" = darwin ]; then
  export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"$PATH"
  export LIBRARY_PATH=${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}
fi
. bench/lib/native_signature.sh

WASMTIME=${WASMTIME:-$(command -v wasmtime 2>/dev/null || true)}
if [ -z "$WASMTIME" ] && [ -x "$HOME/.wasmtime/bin/wasmtime$EXE" ]; then
  WASMTIME="$HOME/.wasmtime/bin/wasmtime$EXE"
fi

failed=0
fail() { echo "FAIL: $*"; failed=1; }
passed_modules=0
passed_fixtures=0
mutations_caught=0
mutations_checked=0
mutations_limited=0

# A numeric status denotes a normal exit, including statuses 124 through 255.
run_bounded() {
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
native_cg_built=0
native_cg_refused=0

# ---- 1. the tools and the runtime text -------------------------------------------------------------------
echo "== 1. the tools build, and the runtime text is in sync"
if ! ./bin/iyi build -o "$WORK_NATIVE/cn$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" >"$WORK/build_cn.log" 2>&1; then
  tail -n 20 "$WORK/build_cn.log"
  echo "FAIL: iyi-compile-native does not build"
  exit 1
fi
./bin/iyi build -o "$WORK_NATIVE/hand_add$EXE" "$REPO_NATIVE/$FIX/hand_add.iyi" >"$WORK/build_hand.log" 2>&1 || { cat "$WORK/build_hand.log"; fail "hand_add does not build"; }
./bin/iyi build -o "$WORK_NATIVE/inspect$EXE" "$REPO_NATIVE/$FIX/inspect.iyi" >"$WORK/build_inspect.log" 2>&1 || { cat "$WORK/build_inspect.log"; fail "inspect does not build"; }
"$PY" "$REPO_NATIVE/bench/native_wasm_gen.py" --check || fail "the embedded runtime text is out of date"

# ---- 2. the writer and the reader ------------------------------------------------------------------------
echo "== 2. the module writer and reader"
"$WORK/hand_add$EXE" "$WORK_NATIVE/hand.wasm" >/dev/null || fail "hand_add did not write its module"
"$WORK/inspect$EXE" "$WORK_NATIVE/hand.wasm" >"$WORK/hand.inspect" || fail "the reader failed on the hand-built module"
if grep -q '^export add kind=0 index=0$' "$WORK/hand.inspect" && grep -q '^export memory kind=2 index=0$' "$WORK/hand.inspect"; then
  echo "the reader lists the exports the writer wrote"
else
  cat "$WORK/hand.inspect"
  fail "the reader does not list the hand-built exports"
fi
if [ -z "$WASMTIME" ]; then
  host_limited "wasm hand-built module execution requires wasmtime"
else
  got=$("$WASMTIME" run --invoke add "$WORK_NATIVE/hand.wasm" 2 3 2>/dev/null)
  if [ "$got" = "5" ]; then
    passed_modules=$((passed_modules + 1))
    echo "hand-built add(2, 3) = 5 under wasmtime"
  else
    fail "hand-built add(2, 3) printed '$got', not 5"
  fi
fi

# ---- 3. the fixtures ----------------------------------------------------------------------------------------
echo "== 3. every fixture runs as its expected output says"
if [ -z "$WASMTIME" ]; then
  host_limited "wasm fixture output and exit checks require wasmtime"
fi
if [ "$HOST_ID" != darwin-arm64 ]; then
  host_limited "wasm fixtures: fresh Darwin oracle execution requires macOS arm64"
fi
for f in $FIXTURES; do
    if ! "$WORK/cn$EXE" "$REPO_NATIVE/$FIX/$f.ir" -o "$WORK_NATIVE/$f.wasm" --target wasm32-wasi >"$WORK/$f.build" 2>&1; then
      cat "$WORK/$f.build"
      fail "$f does not compile to wasm"
      continue
    fi
    "$WORK/inspect$EXE" "$WORK_NATIVE/$f.wasm" >"$WORK/$f.inspect" 2>&1 || { fail "$f: the reader failed"; continue; }
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
    if [ -z "$WASMTIME" ]; then
      echo "$f: emitted and inspected; runtime unavailable"
      continue
    fi
    status="$(run_bounded "$WORK/$f.out" "$WORK/$f.err" "$(native_path "$WASMTIME")" run "$WORK_NATIVE/$f.wasm")"
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
    if [ "$HOST_ID" = darwin-arm64 ]; then
      "$PY" "$REPO_NATIVE/bench/native_wasm_darwin.py" "$REPO_NATIVE/$FIX/$f.ir" "$WORK_NATIVE/$f.darwin.ir" || { fail "$f: no darwin oracle"; continue; }
      if ! "$WORK/cn$EXE" "$WORK_NATIVE/$f.darwin.ir" -o "$WORK_NATIVE/$f.bin" >"$WORK/$f.dbuild" 2>&1; then
        cat "$WORK/$f.dbuild"
        fail "$f: the darwin oracle does not build"
        continue
      fi
      if ! native_signature_ok "$WORK/$f.bin"; then
        fail "$f: invalid darwin oracle signature"
        continue
      fi
      dstatus="$(run_bounded "$WORK/$f.dout" "$WORK/$f.derr" "$(native_path "$WORK/$f.bin")")"
      if [ "$dstatus" != "$want_status" ] || ! cmp -s "$WORK/$f.dout" "$FIX/$f.expected"; then
        cat "$WORK/$f.derr"
        fail "$f: expected output or exit is stale against the darwin oracle (exit $dstatus)"
        continue
      fi
    fi
    : >"$WORK/$f.baseline"
    passed_modules=$((passed_modules + 1))
    passed_fixtures=$((passed_fixtures + 1))
    echo "$f: $(awk 'END { print NR }' "$WORK/$f.out") lines, exit $status, equal to its expected output"
done
echo "fixtures equal to expected: $passed_fixtures of $(echo $FIXTURES | wc -w | tr -d ' ')"

# ---- 4. the native_cg corpus under a wasm retarget ---------------------------------------------------------
echo "== 4. the native_cg corpus, retargeted to wasm32-wasi"
"$PY" - "$REPO_NATIVE/$CG_FIX" "$WORK_NATIVE/cg" <<'PY'
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
cg_limited=0
for f in "$WORK"/cg/*.ir; do
  name=$(basename "$f" .ir)
  if "$WORK/cn$EXE" "$(native_path "$f")" -o "$WORK_NATIVE/cg/$name.wasm" --target wasm32-wasi >"$WORK/cg/$name.log" 2>&1; then
    native_cg_built=$((native_cg_built + 1))
    if ! "$WORK/inspect$EXE" "$WORK_NATIVE/cg/$name.wasm" >"$WORK/cg/$name.inspect" 2>&1 || grep -q '^ERROR' "$WORK/cg/$name.inspect"; then
      fail "$name: generated wasm fails inspection"
      continue
    fi
    if [ "$HOST_ID" != darwin-arm64 ] || [ -z "$WASMTIME" ]; then
      cg_limited=$((cg_limited + 1))
      echo "$name	built and inspected; Darwin comparison needs macOS arm64 and wasmtime" >>"$cg_table"
      continue
    fi
    if ! "$WORK/cn$EXE" "$REPO_NATIVE/$CG_FIX/$name.ir" -o "$WORK_NATIVE/cg/$name.bin" >"$WORK/cg/$name.dbuild" 2>&1; then
      echo "$name	built, but the darwin oracle does not build" >>"$cg_table"
      cg_differ=$((cg_differ + 1))
      continue
    fi
    if ! native_signature_ok "$WORK/cg/$name.bin"; then
      fail "$name: invalid darwin oracle signature"
      cg_differ=$((cg_differ + 1))
      continue
    fi
    dstatus="$(run_bounded "$WORK/cg/$name.dout" "$WORK/cg/$name.derr" "$(native_path "$WORK/cg/$name.bin")")"
    wstatus="$(run_bounded "$WORK/cg/$name.wout" "$WORK/cg/$name.werr" "$(native_path "$WASMTIME")" run "$WORK_NATIVE/cg/$name.wasm")"
    case "$dstatus:$wstatus" in
      *[!0-9:]*|:*|*:) cg_differ=$((cg_differ + 1)); echo "$name	abnormal termination (darwin $dstatus, wasm $wstatus)" >>"$cg_table"; continue ;;
    esac
    if [ "$dstatus" = "$wstatus" ] && [ ! -s "$WORK/cg/$name.werr" ] && cmp -s "$WORK/cg/$name.dout" "$WORK/cg/$name.wout"; then
      cg_equal=$((cg_equal + 1))
      echo "$name	built, runs equal to the darwin build (exit $wstatus)" >>"$cg_table"
    else
      cg_differ=$((cg_differ + 1))
      echo "$name	built, DIFFERS from the darwin build (darwin exit $dstatus, wasm exit $wstatus)" >>"$cg_table"
    fi
  else
    rc=$?
    if [ "$rc" -ne 1 ] || ! grep -q '^iyi-compile-native: ' "$WORK/cg/$name.log"; then
      cat "$WORK/cg/$name.log"
      fail "$name: compiler crashed or failed without a native refusal (exit $rc)"
      continue
    fi
    native_cg_refused=$((native_cg_refused + 1))
    reason=$(sed -n 's/.*: \(.*\)$/\1/p' "$WORK/cg/$name.log" | head -n 1)
    echo "$name	refused: $reason" >>"$cg_table"
  fi
done
awk -F'\t' '{ print }' "$cg_table"
echo "native_cg: $native_cg_built built, $native_cg_refused refused; $cg_equal equal to Darwin, $cg_differ differ or lack a runnable oracle, $cg_limited host-limited"
if [ "$cg_differ" != "0" ]; then
  fail "a built native_cg program does not run equal to its darwin build"
fi

# ---- 5. mutations -----------------------------------------------------------------------------------------
echo "== 5. each mutation of the back end is caught"
if [ -z "$WASMTIME" ]; then
  while IFS= read -r mutation; do
    mutations_limited=$((mutations_limited + 1))
    host_limited "wasm mutation: $mutation requires wasmtime"
  done <<'LIMITED'
unsigned division emitted as signed
a branch depth off by one
a load and store with the wrong offset
signed comparison without sign extension
select with its arms swapped
LIMITED
elif [ ! -f "$WORK/arith.baseline" ] || [ ! -f "$WORK/control.baseline" ] || [ ! -f "$WORK/memory.baseline" ]; then
  fail "wasm mutation proofs require passing arith, control, and memory baselines"
else
  cp "$CG" "$CG_BACKUP"
  run_mutation() {
    local label=$1 old=$2 new=$3
    mutations_checked=$((mutations_checked + 1))
    "$PY" "$REPO_NATIVE/bench/native_wasm_mutate.py" "$REPO_NATIVE/$CG" "$old" "$new"
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
    if ! ./bin/iyi build -o "$WORK_NATIVE/cn_mut$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" >"$WORK/mut.build" 2>&1; then
      cat "$WORK/mut.build"
      fail "$label: mutated tool failed to build; mutation is unproven"
      cp "$CG_BACKUP" "$CG"
      return
    fi
    caught=""
    for f in arith control memory; do
      if ! "$WORK/cn_mut$EXE" "$REPO_NATIVE/$FIX/$f.ir" -o "$WORK_NATIVE/mut.wasm" --target wasm32-wasi >"$WORK/mut.compile" 2>&1; then
        cat "$WORK/mut.compile"
        fail "$label: mutated fixture failed to compile; mutation is unproven"
        caught=invalid
        break
      fi
      rc="$(run_bounded "$WORK/mut.out" "$WORK/mut.err" "$(native_path "$WASMTIME")" run "$WORK_NATIVE/mut.wasm")"
      case "$rc" in ''|*[!0-9]*) caught=invalid ;; esac
      if [ "$caught" = invalid ] || [ -s "$WORK/mut.err" ]; then
        cat "$WORK/mut.err"
        fail "$label: mutated wasm crashed or was rejected; mutation is unproven"
        caught=invalid
        break
      fi
      if [ "$rc" -ne "$(cat "$FIX/$f.exit")" ] || ! cmp -s "$WORK/mut.out" "$FIX/$f.expected"; then
        caught="$f differs"
        break
      fi
    done
    cp "$CG_BACKUP" "$CG"
    if [ "$caught" = invalid ]; then
      return
    elif [ -n "$caught" ]; then
      mutations_caught=$((mutations_caught + 1))
      echo "$label: caught ($caught)"
    else
      fail "$label: no fixture notices the mutation"
    fi
  }
  run_mutation "unsigned division emitted as signed" \
    "byte(wide ? 128_u8 : 110_u8)" "byte(wide ? 127_u8 : 109_u8)"
  run_mutation "a branch depth off by one" \
    "uleb_i(@code, depth)" "uleb_i(@code, depth > 0 ? depth - 1 : depth)"
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
  if cmp -s "$CG" "$CG_BACKUP"; then
    echo "codegen.iyi restored after the mutations"
  else
    fail "codegen.iyi was not restored after the mutations"
  fi
  if [ "$mutations_caught" != "5" ]; then
    fail "not every mutation is caught"
  fi
fi
"$PY" "$REPO_NATIVE/bench/native_wasm_mutate.py" "$REPO_NATIVE/$CG" \
  "sext_top(v.type.bits)" "sext_top(v.type.bits)" >"$WORK/noop.log" 2>&1
noop_rc=$?
if [ "$noop_rc" -eq 3 ]; then
  echo "identity patch refused"
else
  cat "$WORK/noop.log"
  fail "identity patch was not refused (exit $noop_rc)"
fi

# ---- 6. the identity floor -------------------------------------------------------------------------------
echo "== 6. the identity floor"
if "$PY" "$REPO_NATIVE/bench/identity_floor.py" >"$WORK/identity.log" 2>&1; then
  echo "identity floor: ok"
else
  cat "$WORK/identity.log"
  fail "the identity floor fails"
fi

echo "== summary"
echo "modules validated and run under wasmtime: $passed_modules"
echo "fixtures equal to their expected output: $passed_fixtures"
echo "mutations: $mutations_caught/$mutations_checked attempted caught; $mutations_limited host-limited; identity patch checked separately"
if [ $failed -eq 0 ]; then
  echo "native_wasm_exercise: passed"
  exit 0
fi
echo "native_wasm_exercise: FAILED"
exit 1
