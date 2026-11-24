#!/usr/bin/env bash
# AArch64 code generation gate. Every host emits and inspects Darwin Mach-O
# objects, compares the naked bodies with the hosted LLVM oracle, and encodes
# Linux variants in memory. Only macOS arm64 links and executes the objects.
set -u
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd -P)
source "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if [ -z "$PY" ]; then
  echo "a working python3 or python is required" >&2
  exit 1
fi
source "$REPO/bench/floor_base.sh" || exit 1
if [ "$HOST_OS" = darwin ]; then
  export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"$PATH"
  export LIBRARY_PATH=${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}
fi
if [ "$HOST_OS" = windows ]; then
  host_limited "Windows runs a hosted-built PE driver; this gate does not produce LLVM-free PE/COFF output"
fi

# Match the x86_64 gate's explicit path, PATH, and Windows LLVM lookup order.
resolve_llvm_tool() {
  local requested=$1 default_name=$2 found="" candidate root
  if [ "$HOST_OS" = windows ]; then
    case "$requested" in
      [A-Za-z]:[\\/]*) requested=$(cygpath -u "$requested") || return 1 ;;
    esac
  fi
  found=$(command -v "$requested" 2>/dev/null || true)
  if [ -z "$found" ] && [ "$HOST_OS" = windows ] && [ "$requested" = "$default_name" ]; then
    for root in "${LLVM_PATH:-}" "${ProgramFiles:+$ProgramFiles/LLVM}" "/c/Program Files/LLVM"; do
      [ -n "$root" ] || continue
      case "$root" in
        [A-Za-z]:[\\/]*) root=$(cygpath -u "$root") || continue ;;
      esac
      candidate="$root/bin/$default_name.exe"
      if [ -x "$candidate" ]; then found=$candidate; break; fi
    done
  fi
  if [ -z "$found" ]; then
    echo "required LLVM tool not found: $requested" >&2
    return 1
  fi
  if [ "$HOST_OS" = windows ] && [ -f "$found.exe" ]; then found="$found.exe"; fi
  case "$found" in
    /*) ;;
    *) found="$(cd "$(dirname "$found")" && pwd -P)/$(basename "$found")" ;;
  esac
  printf '%s\n' "$found"
}
LLVM_OBJDUMP=$(resolve_llvm_tool "${LLVM_OBJDUMP:-llvm-objdump}" llvm-objdump) || exit 1
printf 'LLVM objdump: %s\n' "$(native_path "$LLVM_OBJDUMP")"
"$LLVM_OBJDUMP" --version || exit 1
printf 'Python: %s\n' "$(command -v "$PY")"
"$PY" --version || exit 1

WORK=$(mktemp -d "${TMPDIR:-/tmp}/native-codegen.XXXXXX") || exit 1
RESTORE_FILE=""
RESTORE_BACKUP=""
restore_all() {
  if [ -n "$RESTORE_FILE" ] && ! cp "$RESTORE_BACKUP" "$RESTORE_FILE"; then
    echo "could not restore $RESTORE_FILE; backup kept at $RESTORE_BACKUP" >&2
    return 1
  fi
  rm -rf "$WORK"
}
trap restore_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

failed=0
fail() { echo "FAIL: $*"; failed=1; }
FIX="$REPO/bench/fixtures/native_cg"
IYI="$REPO/bin/iyi"
if [ -x "$REPO/.build/iyi.exe" ]; then
  IYI_BINARY="$REPO/.build/iyi.exe"
elif [ -x "$REPO/.build/iyi" ]; then
  IYI_BINARY="$REPO/.build/iyi"
else
  echo "the hosted compiler is not built in .build" >&2
  exit 1
fi
DRV="$WORK/native_cg$EXE"
revision=$(git rev-parse HEAD) || exit 1
printf 'revision: %s\nhosted compiler launcher: %s\nhosted compiler binary: %s\n' \
  "$revision" "$(native_path "$IYI")" "$(native_path "$IYI_BINARY")"
if ! "$PY" - "$(native_path "$IYI_BINARY")" <<'PY'
import hashlib, sys
from pathlib import Path
print(f"hosted compiler sha256: {hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest()}")
PY
then
  echo "cannot identify the hosted compiler" >&2
  exit 1
fi

build_driver() {
  local output=$1
  "$IYI" build -o "$(native_path "$output")" "$(native_path "$REPO/src/compiler/tools/native_cg.iyi")" >"$WORK/build.$(basename "$output").log" 2>&1 \
    && [ -f "$output" ]
}

echo "== 1. build the driver with the hosted compiler"
if ! build_driver "$DRV"; then
  tail -20 "$WORK/build.$(basename "$DRV").log"
  fail "the driver does not build"
  exit 1
fi

echo "== 2. native driver dependency floor on $HOST_ID: $(native_path "$DRV")"
case "$HOST_OS" in
  darwin)
    if ! otool -L "$DRV" >"$WORK/otool.log" 2>&1; then
      cat "$WORK/otool.log"
      fail "otool could not inspect the driver"
    else
      cat "$WORK/otool.log"
      if [ "$(tail -n +2 "$WORK/otool.log" | wc -l | tr -d ' ')" != 1 ] || ! grep -q '/usr/lib/libSystem.B.dylib' "$WORK/otool.log"; then
        fail "the driver links more than libSystem"
      fi
    fi
    ;;
  linux)
    if ! command -v nm >/dev/null 2>&1 || ! command -v readelf >/dev/null 2>&1; then
      fail "nm and readelf are required to inspect the Linux driver floor"
    elif ! nm -u "$DRV" >"$WORK/nm.log" 2>&1 || ! readelf -d "$DRV" >"$WORK/readelf.log" 2>&1; then
      cat "$WORK/nm.log" "$WORK/readelf.log" 2>/dev/null
      fail "nm or readelf could not inspect the driver"
    else
      symbols="$(sed -e 's/^ *//' -e 's/^U  *//' -e 's/@.*$//' "$WORK/nm.log" |
        awk '{ print $NF }' | sed -e 's/^_//' -e 's/^_environ$/environ/' | grep -v '^$' | sort -u)"
      libraries="$(sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' "$WORK/readelf.log" | sort -u)"
      extra_symbols=""
      # LibC.exit makes program_calls_c? true, so the collector's helpers use
      # IyiThread.start_by_libc rather than raw clone (src/iyi/thread.iyi).
      for symbol in $symbols; do
        case " $FLOOR_BASE_LINUX environ exit pthread_attr_destroy pthread_attr_init pthread_attr_setstack pthread_create " in
          *" $symbol "*) ;;
          *) extra_symbols="$extra_symbols $symbol" ;;
        esac
      done
      extra_libraries="$(extra_dlls "libc.so ld-linux libgcc_s" "$libraries")"
      printf 'undefined symbols: %s\ndirect libraries: %s\n' "${symbols:-none}" "${libraries:-none}"
      [ -z "$extra_symbols" ] || fail "Linux driver has symbols outside its runtime floor:$extra_symbols"
      [ -z "$extra_libraries" ] || fail "Linux driver has libraries outside its runtime floor: $extra_libraries"
    fi
    ;;
  windows)
    DUMPBIN="$(find_dumpbin || true)"
    if [ -z "$DUMPBIN" ]; then
      fail "dumpbin is required to inspect the Windows driver floor"
    elif ! "$DUMPBIN" -nologo -dependents "$(native_path "$DRV")" >"$WORK/dumpbin.log" 2>&1; then
      cat "$WORK/dumpbin.log"
      fail "dumpbin could not inspect the driver"
    else
      real_dumpbin="$DUMPBIN"
      dumpbin_lf() { tr -d '\r' <"$WORK/dumpbin.log"; }
      DUMPBIN=dumpbin_lf
      dlls="$(pe_dlls "$(native_path "$DRV")")"
      DUMPBIN="$real_dumpbin"
      if [ -z "$dlls" ]; then
        cat "$WORK/dumpbin.log"
        fail "dumpbin read no DLL imports from the Windows driver"
      else
        printf 'direct DLLs: %s\n' "$dlls"
        # The driver is built with the prelude, which keys String#hash with
        # RtlGenRandom (advapi32.dll, #212). That is the one program DLL the
        # driver may carry; see FLOOR_DLLS_PROGRAM in bench/floor_base.sh.
        extra="$(extra_dlls "$FLOOR_DLLS_RUNTIME advapi32.dll" "$dlls")"
        [ -z "$extra" ] || fail "Windows driver has DLLs outside its runtime floor: $extra"
      fi
    fi
    echo "Windows per-symbol import floor is unverified"
    ;;
esac

# Record the actual arm64 executable and reject signature or inspection errors.
record_executable() {
  local executable=$1 arch
  if ! codesign -v --strict "$executable" 2>"$executable.signature.log"; then
    cat "$executable.signature.log" >&2
    return 125
  fi
  arch=$(lipo -archs "$executable") || return 124
  case " $arch " in *" arm64 "*) ;; *) echo "not arm64: $arch" >&2; return 124 ;; esac
  printf 'signed executable: %s; architectures: %s\n' "$executable" "$arch"
  file "$executable" || return 124
  shasum -a 256 "$executable" || return 124
}

# Emit the complete corpus before any runtime-only branch.
echo "== 3. emit every Darwin-target fixture"
for base in narrow_signext narrow_argext narrow_asm narrow_cmpxchg narrow_switch narrow_call narrow_i1 narrow_param; do
  [ -f "$FIX/$base.ir" ] && [ -f "$FIX/$base.iyi" ] || fail "$base: required fixture pair is missing"
done
fixture_total=0
emitted=0
for ir in "$FIX"/*.ir; do
  [ -f "$ir" ] || continue
  fixture_total=$((fixture_total + 1))
  base=$(basename "$ir" .ir)
  [ -f "$FIX/$base.iyi" ] || fail "$base.ir has no equivalent $base.iyi"
  if "$DRV" obj "$(native_path "$ir")" "$(native_path "$WORK/$base.o")" >"$WORK/$base.obj.log" 2>&1 \
      && [ -s "$WORK/$base.o" ]; then
    emitted=$((emitted + 1))
  else
    cat "$WORK/$base.obj.log"
    fail "$base: the native backend did not emit an object"
  fi
done
[ "$fixture_total" -gt 0 ] || fail "no codegen fixtures found"
[ "$emitted" -eq "$fixture_total" ] || fail "not every fixture produced a Darwin object"
echo "emitted $emitted of $fixture_total Darwin-target fixture objects"

RTF="$REPO/bench/fixtures/native_first_light"
if ! "$DRV" obj "$(native_path "$REPO/bench/fixtures/native_tp/threadpointer.ir")" "$(native_path "$WORK/tp.o")" >"$WORK/tp.obj.log" 2>&1 \
    || [ ! -s "$WORK/tp.o" ]; then
  cat "$WORK/tp.obj.log"
  fail "threadpointer: the native backend did not emit an object"
fi
for pair in "$RTF/rt_helpers.ir:rth" "$REPO/src/compiler/native/rt/builtins.ir:rt_native"; do
  ir=${pair%:*}
  base=${pair##*:}
  if ! "$DRV" obj "$(native_path "$ir")" "$(native_path "$WORK/$base.o")" >"$WORK/$base.obj.log" 2>&1 \
      || [ ! -s "$WORK/$base.o" ]; then
    cat "$WORK/$base.obj.log"
    fail "$base: the native backend did not emit an object"
  fi
done

if [ "$HOST_ID" = darwin-arm64 ]; then
  echo "== 3a. compare every native fixture with its hosted twin"
  count=0
  for ir in "$FIX"/*.ir; do
    [ -f "$ir" ] || continue
    base=$(basename "$ir" .ir)
    iy="$FIX/$base.iyi"
    if [ ! -s "$WORK/$base.o" ] || [ ! -f "$iy" ]; then
      fail "$base: missing emitted object or hosted fixture"
      continue
    fi
    if ! cc "$WORK/$base.o" "$FIX/rt_stub.c" -o "$WORK/$base.native" >"$WORK/$base.link.log" 2>&1; then
      cat "$WORK/$base.link.log"
      fail "$base: cc did not link the native object"
      continue
    fi
    if ! record_executable "$WORK/$base.native"; then
      fail "$base: native signature or executable identity failed"
      continue
    fi
    "$WORK/$base.native" >"$WORK/$base.native.out" 2>"$WORK/$base.native.err"
    echo $? >"$WORK/$base.native.status"
    if ! "$IYI" build -o "$(native_path "$WORK/$base.hosted$EXE")" "$(native_path "$iy")" >"$WORK/$base.hosted.log" 2>&1; then
      tail -20 "$WORK/$base.hosted.log"
      fail "$base: the hosted compiler does not build $base.iyi"
      continue
    fi
    "$WORK/$base.hosted$EXE" >"$WORK/$base.hosted.out" 2>"$WORK/$base.hosted.err"
    echo $? >"$WORK/$base.hosted.status"
    printf '%s native stdout:\n' "$base"; cat "$WORK/$base.native.out"
    printf '%s native stderr:\n' "$base"; cat "$WORK/$base.native.err"
    printf '%s hosted stderr:\n' "$base"; cat "$WORK/$base.hosted.err"
    if cmp -s "$WORK/$base.native.out" "$WORK/$base.hosted.out" && cmp -s "$WORK/$base.native.status" "$WORK/$base.hosted.status"; then
      echo "$base: stdout and status equal ($(cat "$WORK/$base.native.status") exit)"
      count=$((count + 1))
    else
      printf '%s hosted stdout:\n' "$base"; cat "$WORK/$base.hosted.out"
      printf '%s native/hosted statuses: %s / %s\n' "$base" "$(cat "$WORK/$base.native.status")" "$(cat "$WORK/$base.hosted.status")"
      fail "$base: the native program differs from the hosted compiler's"
    fi
  done
  [ "$count" -eq "$fixture_total" ] || fail "not every fixture matched its hosted twin"
  echo "compared $count of $fixture_total fixtures against the hosted compiler"

  echo "== 3c. thread pointer is non-zero, aligned and stable"
  if [ ! -s "$WORK/tp.o" ] || ! cc "$WORK/tp.o" "$REPO/bench/fixtures/native_tp/tp_main.c" -o "$WORK/tp.bin" >"$WORK/tp.link.log" 2>&1; then
    fail "threadpointer: cc did not link the native object"
  elif ! record_executable "$WORK/tp.bin"; then
    fail "threadpointer: native signature or executable identity failed"
  elif ! "$WORK/tp.bin" >"$WORK/tp.out" 2>"$WORK/tp.err"; then
    cat "$WORK/tp.out" "$WORK/tp.err"
    fail "threadpointer: the masked thread pointer is zero, unaligned, or differs between reads"
  else
    cat "$WORK/tp.out" "$WORK/tp.err"
    echo "threadpointer: non-zero, 8-aligned and equal on both reads"
  fi
else
  host_limited "Darwin Mach-O fixture execution and hosted-twin comparisons require macOS arm64; objects were not executed"
  host_limited "Darwin threadpointer runtime requires macOS arm64"
fi
# ---- 3b. naked bodies: the function's bytes and relocations equal the hosted compiler's naked function --------
# The hosted compiler's LLVM may append a return to a naked body, so the oracle may hold the native body followed by one
# trailing `ret`, and nothing else. Relocations are compared by offset within the body and by kind.
echo "== 3b. each naked fixture's body equals the hosted compiler's naked function, bytes and relocations"
naked_count=0
naked_total=0
for pair in asm_naked_const:const42 asm_naked_addimm:addimm asm_naked_pair:pair; do
  naked_total=$((naked_total + 1))
  base=${pair%%:*}
  fn=${pair#*:}
  if [ ! -s "$WORK/$base.o" ]; then
    fail "$base: the native naked fixture object is missing"
    continue
  fi
  if ! "$IYI" build --cross-compile --target aarch64-apple-darwin -o "$(native_path "$WORK/$base.oracle.o")" "$(native_path "$FIX/$base.iyi")" >"$WORK/$base.oracle.log" 2>&1; then
    cat "$WORK/$base.oracle.log"
    fail "$base: the hosted compiler does not build the oracle"
    continue
  fi
  if ! "$DRV" bytes "$(native_path "$WORK/$base.o")" >"$WORK/$base.nat.bytes" 2>"$WORK/$base.nat.bytes.err" \
      || ! "$DRV" bytes "$(native_path "$WORK/$base.oracle.o")" >"$WORK/$base.oracle.bytes" 2>"$WORK/$base.oracle.bytes.err"; then
    cat "$WORK/$base.nat.bytes.err" "$WORK/$base.oracle.bytes.err" 2>/dev/null
    fail "$base: object inspection failed"
    continue
  fi
  if "$PY" - "$(native_path "$WORK/$base.nat.bytes")" "$(native_path "$WORK/$base.oracle.bytes")" "$fn" <<'PY'
import sys
RET = bytes.fromhex("c0035fd6")
def load(path):
    secs, syms, relocs = {}, {}, {}
    for line in open(path):
        f = line.rstrip("\n").split("\t")
        if f[0] == "section":
            secs[int(f[1])] = bytes.fromhex(f[2])
        elif f[0] == "reloc":
            relocs.setdefault(int(f[1]), []).append((int(f[2]), f[3]))
        elif f[0] == "sym":
            syms[bytes.fromhex(f[1]).decode()] = (int(f[2]), int(f[3]))
    return secs, syms, relocs
def body(path, name):
    secs, syms, relocs = load(path)
    if name not in syms:
        return None
    si, start = syms[name]
    if si not in secs:
        return None
    text = secs[si]
    later = [v for (s, v) in syms.values() if s == si and v > start]
    end = min(later) if later else len(text)
    rel = sorted((off - start, kind) for (off, kind) in relocs.get(si, []) if start <= off < end)
    return text[start:end], rel
native = body(sys.argv[1], sys.argv[3])
oracle = body(sys.argv[2], sys.argv[3])
if native is None or oracle is None or not native[0]:
    print("the function is missing from one of the objects")
    sys.exit(1)
nb, nr = native
ob, orl = oracle
if nr != orl:
    print(f"relocations differ: native {nr} oracle {orl}")
    sys.exit(1)
if ob != nb and ob != nb + RET:
    print(f"bytes differ: native {nb.hex()} oracle {ob.hex()}")
    sys.exit(1)
print(f"{sys.argv[3]}: {len(nb)} bytes, {len(nr)} relocations, equal to the hosted compiler's naked function")
PY
  then
    naked_count=$((naked_count + 1))
  else
    fail "$base: the naked body differs from the hosted compiler's"
  fi
done
echo "compared $naked_count of $naked_total naked bodies"

# The helper objects were emitted on every host above. Execution needs macOS.
if [ "$HOST_ID" = darwin-arm64 ]; then
  echo "== 3d. native runtime, C stand-ins and hosted helper agree"
  if [ -s "$WORK/rth.o" ] && [ -s "$WORK/rt_native.o" ] \
     && cc "$WORK/rth.o" "$WORK/rt_native.o" -o "$WORK/rth_native" >"$WORK/rth_native.link.log" 2>&1 \
     && cc -c "$FIX/rt_stub.c" -o "$WORK/rt_stub.o" >"$WORK/rt_stub.log" 2>&1 \
     && cc "$WORK/rth.o" "$WORK/rt_stub.o" -o "$WORK/rth_stub" >"$WORK/rth_stub.link.log" 2>&1 \
     && "$IYI" build -o "$(native_path "$WORK/rth_hosted$EXE")" "$(native_path "$RTF/rt_helpers.iyi")" >"$WORK/rth_hosted.log" 2>&1 \
     && record_executable "$WORK/rth_native" && record_executable "$WORK/rth_stub"; then
    "$WORK/rth_native" >"$WORK/rth_native.out" 2>"$WORK/rth_native.err"; s1=$?
    "$WORK/rth_stub" >"$WORK/rth_stub.out" 2>"$WORK/rth_stub.err"; s2=$?
    "$WORK/rth_hosted$EXE" >"$WORK/rth_hosted.out" 2>"$WORK/rth_hosted.err"; s3=$?
    printf 'rt_helpers native stdout:\n'; cat "$WORK/rth_native.out"
    for variant in native stub hosted; do
      printf 'rt_helpers %s stderr:\n' "$variant"
      cat "$WORK/rth_$variant.err"
    done
    if [ "$s1" -ne 0 ] || [ "$s2" -ne 0 ] || [ "$s3" -ne 0 ]; then
      fail "rt_helpers: exit statuses $s1 $s2 $s3 (native, stub, hosted)"
    elif ! cmp -s "$WORK/rth_native.out" "$WORK/rth_stub.out"; then
      cat "$WORK/rth_stub.out"
      fail "rt_helpers: the native runtime prints differently from rt_stub.c"
    elif ! cmp -s "$WORK/rth_native.out" "$WORK/rth_hosted.out"; then
      cat "$WORK/rth_hosted.out"
      fail "rt_helpers: the native runtime prints differently from the hosted twin"
    else
      echo "rt_helpers: statuses $s1 $s2 $s3; $(wc -l <"$WORK/rth_native.out" | tr -d ' ') lines identical"
    fi
  else
    cat "$WORK/rth_native.link.log" "$WORK/rt_stub.log" "$WORK/rth_stub.link.log" "$WORK/rth_hosted.log" 2>/dev/null
    fail "rt_helpers: parity build, signature, or executable identity failed"
  fi
else
  host_limited "Darwin runtime-helper, C stand-in and hosted three-way execution requires macOS arm64"
fi

# ---- 4. the 64 KiB frame: the MIR dump shows the probe page by page ----------------------------
echo "== 4. the 64 KiB frame is entered page by page"
if "$DRV" mir "$(native_path "$FIX/frame64k.ir")" big >"$WORK/frame64k.mir" 2>"$WORK/frame64k.mir.err" && [ -s "$WORK/frame64k.mir" ]; then
  probes=$(grep -c 'ZeroSp' "$WORK/frame64k.mir" || true)
  if [ "$probes" -ge 16 ]; then
    echo "probes in the dump: $probes"
  else
    fail "the frame dump shows $probes probes; a 65 KiB frame needs 16"
  fi
else
  cat "$WORK/frame64k.mir.err"
  fail "the frame MIR could not be produced"
fi

# ---- 4b. each ordering selects its own exclusive pair: acquire on the load for acquire and seq_cst, release on
# the store for release and seq_cst, and the plain pair for monotonic (LLVM's AArch64 mapping) -----------------
# expect_ord <function> <load op> <store op>: the function's MIR holds that pair and not the other forms.
expect_ord() {
  local fn=$1 load=$2 store=$3 mir oload=Ldaxr ostore=Stlxr
  [ "$load" = Ldaxr ] && oload=Ldxr
  [ "$store" = Stlxr ] && ostore=Stxr
  if ! mir=$("$DRV" mir "$(native_path "$FIX/rmw.ir")" "$fn"); then
    fail "$fn: could not produce MIR"
    return
  fi
  mir=$(printf '%s\n' "$mir" | tail -n +2)
  if echo "$mir" | grep -qw "$load" && echo "$mir" | grep -qw "$store" && ! echo "$mir" | grep -qw "$oload" && ! echo "$mir" | grep -qw "$ostore"; then
    echo "$fn: $load and $store"
  else
    fail "$fn: its exclusive pair is not $load and $store"
  fi
}
echo "== 4b. each atomicrmw and cmpxchg ordering selects its own exclusive pair"
expect_ord ord_mono Ldxr Stxr
expect_ord ord_acq Ldaxr Stxr
expect_ord ord_rel Ldxr Stlxr
expect_ord ord_seq Ldaxr Stlxr
expect_ord ord_cas_mono Ldxr Stxr
expect_ord ord_cas_acq Ldaxr Stxr
expect_ord ord_cas_rel Ldxr Stlxr
expect_ord ord_cas_seq Ldaxr Stlxr

# ---- 4c. switch forms: a dense switch indexes a jump table, a sparse one and one with no cases keep the compare
# chain. The MIR dump names each table with its entry count and lowest case. ----------------------------------
expect_table() {
  local mir
  mir=$("$DRV" mir "$(native_path "$FIX/$1.ir")" "$2") || return 1
  [ -n "$mir" ] && printf '%s\n' "$mir" | grep -qF "jump table 0 entries=$3 low=$4 " || return 1
  echo "$1/$2: jump table has $3 entries at $4"
}
expect_chain() {
  local mir
  mir=$("$DRV" mir "$(native_path "$FIX/$1.ir")" "$2") || return 1
  [ -n "$mir" ] && ! printf '%s\n' "$mir" | grep -qE 'jump table|BrTable' || return 1
  echo "$1/$2: compare chain, no jump table"
}
echo "== 4c. dense switches take a jump table; sparse and empty switches keep the compare chain"
expect_table jump_dense dense 10 0 || fail "jump_dense: dense is not a 10-entry table at 0"
expect_table jump_holes holes 11 0 || fail "jump_holes: holes is not an 11-entry table at 0"
expect_table jump_widths neg8 10 -5 || fail "jump_widths: neg8 is not a 10-entry table at -5"
expect_table jump_widths neg16 10 -4 || fail "jump_widths: neg16 is not a 10-entry table at -4"
expect_table jump_widths far64 6 8589934592 || fail "jump_widths: far64 is not a 6-entry table at 2^33"
expect_table jump_widths neg32 10 -3 || fail "jump_widths: neg32 is not a 10-entry table at -3"
expect_table jump_loop run 6 0 || fail "jump_loop: run is not a 6-entry table at 0"
expect_chain jump_sparse sparse || fail "jump_sparse: a sparse switch took a table"
expect_chain jump_sparse none || fail "jump_sparse: a switch with no cases took a table"

# ---- 4d. thread-local access: the descriptor sequence, the Linux local-exec form, and the sections' flags and
# placement, as the oracle's object has them -------------------------------------------------------------------
echo "== 4d. thread-local access lowers as the oracle's sequences; section flags and placement match its object"
if tls_mir=$("$DRV" mir "$(native_path "$FIX/tls_loop.ir")" main) && [ -n "$tls_mir" ]; then
  descs=$(printf '%s\n' "$tls_mir" | grep -c 'LoadTlvp/64' || true)
  thunks=$(printf '%s\n' "$tls_mir" | grep -c 'Blr/64 .*clobbers=x0,x16,x17,x30' || true)
  if [ "$descs" -eq 2 ] && [ "$thunks" -eq 2 ]; then
    echo "tls_loop main: $descs descriptor loads, each followed by a thunk call that clobbers x0,x16,x17,x30"
  else
    fail "tls_loop main: $descs descriptor loads and $thunks thunk calls, expected 2 and 2"
  fi
else
  fail "tls_loop main: could not produce MIR"
fi
sed -e 's/^target triple = .*/target triple = "aarch64-unknown-linux-gnu"/' \
    -e 's/^target datalayout = .*/target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32"/' \
    "$FIX/tls_loop.ir" >"$WORK/tls_loop.linux.ir"
if linux_mir=$("$DRV" mir "$(native_path "$WORK/tls_loop.linux.ir")" bump) && [ -n "$linux_mir" ] \
    && printf '%s\n' "$linux_mir" | grep -q 'Mrs/64 x[0-9]*$' && printf '%s\n' "$linux_mir" | grep -q 'AddTprelHi/64' \
    && printf '%s\n' "$linux_mir" | grep -q 'AddTprelLo/64' && ! printf '%s\n' "$linux_mir" | grep -q 'Blr'; then
  echo "linux bump: mrs tpidr_el0, then the two local-exec adds, and no thunk call"
else
  fail "linux bump: MIR failed or the local-exec sequence is not as expected"
fi
section_flags() {
  local object=$1 section=$2 headers raw
  if [ "$HOST_OS" = darwin ]; then
    headers=$(otool -l "$object") || return 1
  else
    headers=$("$LLVM_OBJDUMP" --macho --private-headers --non-verbose "$(native_path "$object")") || return 1
  fi
  # Only tool metadata is normalized; executable output remains byte-exact.
  raw=$(printf '%s\n' "$headers" | tr -d '\r' | awk -v s="$section" '
    $1=="sectname" {n=$2}
    $1=="flags" && n==s {value=$2; count++}
    END {if (count!=1) exit 1; print value}
  ') || return 1
  [[ "$raw" =~ ^0x[0-9a-fA-F]+$ ]] || return 1
  printf '0x%02x\n' "$((raw))"
}
section_size() {
  local object=$1 section=$2 headers
  headers=$("$LLVM_OBJDUMP" --macho --section-headers "$(native_path "$object")") || return 1
  printf '%s\n' "$headers" | tr -d '\r' | awk -v s="$section" '
    $2==s {value=$3; count++}
    END {if (count!=1 || value !~ /^[0-9a-fA-F]+$/) exit 1; print value}
  '
}
ti="$WORK/tls_init.o"
tz="$WORK/tls_zero.o"
if data_flags=$(section_flags "$ti" __thread_data) && bss_flags=$(section_flags "$ti" __thread_bss) \
    && vars_flags=$(section_flags "$ti" __thread_vars) \
    && [ "$data_flags" = 0x11 ] && [ "$bss_flags" = 0x12 ] && [ "$vars_flags" = 0x13 ]; then
  echo "sections: __thread_data $data_flags, __thread_bss $bss_flags and __thread_vars $vars_flags"
else
  fail "sections: missing, undecodable, or incorrect thread-local section flags"
fi
if zero_bss=$(section_size "$tz" __thread_bss) && zero_data=$(section_size "$tz" __thread_data) \
    && init_data=$(section_size "$ti" __thread_data) \
    && [ "$zero_bss" = 00000008 ] && [ "$zero_data" = 00000000 ] && [ "$init_data" = 00000008 ]; then
  echo "placement: zero __thread_bss=$zero_bss, zero __thread_data=$zero_data, initialised __thread_data=$init_data"
else
  fail "placement: missing, undecodable, or incorrect thread-local section sizes"
fi
if "$LLVM_OBJDUMP" --macho --reloc "$(native_path "$ti")" >"$WORK/tls_init.relocs" 2>"$WORK/tls_init.relocs.err" \
    && grep -q 'TLVLDP  ' "$WORK/tls_init.relocs" && grep -q 'TLVLDPOFF' "$WORK/tls_init.relocs"; then
  echo "relocations: the descriptor is reached through TLVLDP and TLVLDPOFF, as in the oracle's object"
else
  cat "$WORK/tls_init.relocs.err"
  fail "relocations: missing, undecodable, or incorrect TLVP relocations"
fi
# A thread-local model other than local-exec is refused on Linux by name; a plain global is refused on any target.
lin_general="$WORK/tls_general.linux.ir"
sed -e 's/^target triple = .*/target triple = "aarch64-unknown-linux-gnu"/' \
    -e 's/^target datalayout = .*/target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32"/' \
    -e 's/thread_local(localexec)/thread_local(generaldynamic)/' "$FIX/tls_init.ir" >"$lin_general"
if "$DRV" obj "$(native_path "$lin_general")" "$(native_path "$WORK/tls_general.o")" >"$WORK/tls_general.log" 2>&1; then
  fail "refusal: a generaldynamic thread-local on Linux was lowered"
elif grep -q 'Linux lowers only the local-exec model' "$WORK/tls_general.log"; then
  echo "refusal: a generaldynamic thread-local on Linux is refused by name"
else
  fail "refusal: the generaldynamic refusal is not the named one"
fi
plain="$WORK/tls_plain.ir"
sed -e 's/internal thread_local(localexec) global/internal global/' "$FIX/tls_init.ir" >"$plain"
if "$DRV" obj "$(native_path "$plain")" "$(native_path "$WORK/tls_plain.o")" >"$WORK/tls_plain.log" 2>&1; then
  fail "refusal: threadlocaladdr of a plain global was lowered"
elif grep -q 'is not a thread-local global' "$WORK/tls_plain.log"; then
  echo "refusal: threadlocaladdr of a plain global is refused by name"
else
  fail "refusal: the plain-global refusal is not the named one"
fi


# Linux target encoding is in memory only. No ELF object is written or run.
echo "== 5. aarch64-linux-gnu variant of each fixture encodes in memory"
linux_count=0
for ir in "$FIX"/*.ir; do
  [ -f "$ir" ] || continue
  base=$(basename "$ir" .ir)
  sed -e 's/^target triple = .*/target triple = "aarch64-unknown-linux-gnu"/' \
      -e 's/^target datalayout = .*/target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32"/' \
      "$ir" >"$WORK/$base.linux.ir"
  if "$DRV" obj "$(native_path "$WORK/$base.linux.ir")" "$(native_path "$WORK/$base.linux.o")" >"$WORK/$base.linux.log" 2>&1 \
      && grep -q 'not written: the ELF writer is a later slice' "$WORK/$base.linux.log" \
      && [ ! -e "$WORK/$base.linux.o" ]; then
    linux_count=$((linux_count + 1))
  else
    cat "$WORK/$base.linux.log"
    fail "$base: the Linux variant did not encode in memory as expected"
  fi
done
[ "$linux_count" -eq "$fixture_total" ] || fail "not every Linux variant encoded in memory"
echo "encoded $linux_count of $fixture_total Linux variants in memory; no ELF file was written or executed"

# A detector returns 0 for a match, 1 for a real mismatch, 124 for an
# invalid setup or inspection, and 125 for a failed executable signature.
mutation_total=0
mutation_checked=0
mutation_caught=0
mutation_limited=0
prove_mutation() {
  local name=$1 file="$REPO/$2" old=$3 new=$4 check=$5
  local backup mut patch_status check_status
  if [ "$old" = "$new" ]; then
    echo "PATCH CHANGED NOTHING: this proves nothing"
    return 2
  fi
  mutation_total=$((mutation_total + 1))
  case "$check" in
    check_probe|check_mono_pair|check_tlvp_kind|check_tls_clobbers|check_tbss_placed|check_tp_mask) ;;
    *)
      if [ "$HOST_ID" != darwin-arm64 ]; then
        host_limited "mutation $name: its original runtime detector requires macOS arm64"
        mutation_limited=$((mutation_limited + 1))
        return 0
      fi
      ;;
  esac
  mutation_checked=$((mutation_checked + 1))
  "$check" "$DRV" >"$WORK/mutation-baseline.log" 2>&1
  check_status=$?
  if [ "$check_status" -ne 0 ]; then
    cat "$WORK/mutation-baseline.log"
    fail "mutation $name: INVALID pristine detector (status $check_status)"
    return 1
  fi
  echo "pristine predicate passed: $name"
  backup="$WORK/backup.$mutation_total.$RANDOM"
  if ! cp "$file" "$backup"; then
    fail "mutation $name: cannot back up $file"
    return 1
  fi
  RESTORE_FILE=$file
  RESTORE_BACKUP=$backup
  "$PY" - "$(native_path "$file")" "$old" "$new" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
old, new = (value.encode("utf-8") for value in sys.argv[2:])
data = path.read_bytes()
count = data.count(old)
if count != 1:
    print(f"mutation text must occur exactly once, found {count}", file=sys.stderr)
    sys.exit(3)
if old == new:
    print("PATCH CHANGED NOTHING", file=sys.stderr)
    sys.exit(4)
path.write_bytes(data.replace(old, new, 1))
PY
  patch_status=$?
  mut="$WORK/mutant.$mutation_total.$RANDOM$EXE"
  if [ "$patch_status" -ne 0 ]; then
    fail "mutation $name: INVALID patch (status $patch_status)"
  elif ! build_driver "$mut"; then
    tail -20 "$WORK/build.$(basename "$mut").log"
    fail "mutation $name: INVALID mutant driver build"
  else
    "$check" "$mut" >"$WORK/mutation-check.log" 2>&1
    check_status=$?
    case "$check_status" in
      0) fail "mutation $name: NOT caught" ;;
      1)
        mutation_caught=$((mutation_caught + 1))
        echo "caught: $name"
        cat "$WORK/mutation-check.log"
        ;;
      125)
        cat "$WORK/mutation-check.log"
        fail "mutation $name: INVALID native executable signature"
        ;;
      *)
        cat "$WORK/mutation-check.log"
        fail "mutation $name: INVALID detector setup or inspection (status $check_status)"
        ;;
    esac
  fi
  if ! cp "$RESTORE_BACKUP" "$RESTORE_FILE"; then
    echo "could not restore $RESTORE_FILE; backup kept at $RESTORE_BACKUP" >&2
    exit 1
  fi
  RESTORE_FILE=""
  RESTORE_BACKUP=""
}

# Compare only a successfully emitted, linked and signed program.
check_fixture() {
  local drv=$1 base=$2 status expected identity_status
  [ -f "$FIX/$base.ir" ] && [ -f "$FIX/$base.iyi" ] \
    && [ -f "$WORK/$base.hosted.out" ] && [ -f "$WORK/$base.hosted.status" ] || return 124
  rm -f "$WORK/m.$base.o" "$WORK/m.$base.bin" || return 124
  if ! "$drv" obj "$(native_path "$FIX/$base.ir")" "$(native_path "$WORK/m.$base.o")" \
      >"$WORK/m.$base.obj.log" 2>&1 || [ ! -s "$WORK/m.$base.o" ]; then
    cat "$WORK/m.$base.obj.log"
    return 124
  fi
  if ! cc "$WORK/m.$base.o" "$FIX/rt_stub.c" -o "$WORK/m.$base.bin" >"$WORK/m.$base.link.log" 2>&1; then
    cat "$WORK/m.$base.link.log"
    return 124
  fi
  record_executable "$WORK/m.$base.bin"
  identity_status=$?
  [ "$identity_status" -eq 0 ] || return "$identity_status"
  "$WORK/m.$base.bin" >"$WORK/m.$base.out" 2>"$WORK/m.$base.err"
  status=$?
  expected=$(cat "$WORK/$base.hosted.status") || return 124
  printf '%s detector status %s, hosted status %s; stdout:\n' "$base" "$status" "$expected"
  cat "$WORK/m.$base.out"
  printf '%s detector stderr:\n' "$base"
  cat "$WORK/m.$base.err"
  cmp -s "$WORK/m.$base.out" "$WORK/$base.hosted.out" && [ "$status" = "$expected" ]
}
check_arith() { check_fixture "$1" arith; }
check_recursion() { check_fixture "$1" control; }
check_iyiagg() { check_fixture "$1" iyiagg; }
check_byval() { check_fixture "$1" byval; }
check_rmw() { check_fixture "$1" rmw; }
check_mem() { check_fixture "$1" mem; }
check_wide() { check_fixture "$1" wide; }
check_mono_pair() {
  local mir
  mir=$("$1" mir "$(native_path "$FIX/rmw.ir")" ord_mono) || return 124
  [ -n "$mir" ] || return 124
  printf '%s\n' "$mir" | grep -qw Ldxr
}
check_jump_dense() { check_fixture "$1" jump_dense; }
# This mutation is specific to linear-scan control-flow successors.
check_jump_loop() { IYI_NATIVE_REGALLOC=linear check_fixture "$1" jump_loop; }
check_probe() {
  local mir n
  mir=$("$1" mir "$(native_path "$FIX/frame64k.ir")" big) || return 124
  [ -n "$mir" ] || return 124
  n=$(printf '%s\n' "$mir" | grep -c 'ZeroSp' || true)
  echo "stack probes: $n"
  [ "$n" -ge 16 ]
}
check_tls_init() { check_fixture "$1" tls_init; }
check_constmul() { check_fixture "$1" constexpr_mul; }
check_tlvp_kind() {
  rm -f "$WORK/m.kind.o" || return 124
  "$1" obj "$(native_path "$FIX/tls_init.ir")" "$(native_path "$WORK/m.kind.o")" || return 124
  [ -s "$WORK/m.kind.o" ] || return 124
  "$LLVM_OBJDUMP" --macho --reloc "$(native_path "$WORK/m.kind.o")" >"$WORK/m.kind.relocs" || return 124
  grep -q 'TLVLDPOFF' "$WORK/m.kind.relocs" || return 124
  cat "$WORK/m.kind.relocs"
  grep -q 'TLVLDP  ' "$WORK/m.kind.relocs"
}
check_tls_clobbers() {
  local mir
  mir=$("$1" mir "$(native_path "$FIX/tls_loop.ir")" bump) || return 124
  [ -n "$mir" ] || return 124
  printf '%s\n' "$mir" | grep -q 'clobbers=x0,x16,x17,x30'
}
check_tbss_placed() {
  local size
  rm -f "$WORK/m.tbss.o" || return 124
  "$1" obj "$(native_path "$FIX/tls_zero.ir")" "$(native_path "$WORK/m.tbss.o")" || return 124
  [ -s "$WORK/m.tbss.o" ] || return 124
  size=$(section_size "$WORK/m.tbss.o" __thread_bss) || return 124
  echo "__thread_bss size: $size"
  [ "$size" = 00000008 ]
}
check_tp_mask() {
  local mir
  mir=$("$1" mir "$(native_path "$REPO/bench/fixtures/native_tp/threadpointer.ir")" tp_word) || return 124
  [ -n "$mir" ] || return 124
  printf '%s\n' "$mir" | grep -q 'AndImm/64 .*#imm=-8'
}

check_naked() { check_fixture "$1" asm_naked_const; }
check_bind() { check_fixture "$1" asm_addone; }
# An ignored clobber shows only where a value is kept in the clobbered register across the template, which linear
# scan does and the pin allocator never does, so this check always runs linear, whatever the gate was started with.
check_clobber() { IYI_NATIVE_REGALLOC=linear check_fixture "$1" asm_clobber; }
check_reloc() { check_fixture "$1" asm_reloc; }
check_narrow_cmpxchg() { check_fixture "$1" narrow_cmpxchg; }
check_narrow_switch() { check_fixture "$1" narrow_switch; }
check_narrow_call() { check_fixture "$1" narrow_call; }
check_narrow_i1() { check_fixture "$1" narrow_i1; }
check_narrow_param() { check_fixture "$1" narrow_param; }
check_narrow_asm() { check_fixture "$1" narrow_asm; }
check_narrow_argext() { check_fixture "$1" narrow_argext; }
check_narrow_signext() { check_fixture "$1" narrow_signext; }

echo "== 6. mutations are each caught"
prove_mutation "call: do not sign-extend an attributed i1 argument" \
  src/compiler/native/aarch64/isel.iyi \
  '            vals[j] = signed_value(vals[j], loc.leaf_type)' \
  '            vals[j] = signed_value(vals[j], loc.leaf_type) if false' \
  check_narrow_signext
prove_mutation "call: do not zero-extend an attributed narrow argument" \
  src/compiler/native/aarch64/isel.iyi \
  '            vals[j] = zext(vals[j], loc.leaf_type)' \
  '            vals[j] = zext(vals[j], loc.leaf_type) if false' \
  check_narrow_argext
prove_mutation "asm: leave a narrow result uncanonicalised" \
  src/compiler/native/aarch64/isel.iyi \
  '      out_regs[k] = canon(out_regs[k], out_types[k])' \
  '      out_regs[k] = out_regs[k]' \
  check_narrow_asm
prove_mutation "cmpxchg: compare the zero-extended exclusive load" \
  src/compiler/native/aarch64/isel.iyi \
  'compare(canon(old, value_type), expected)' \
  'compare(old, expected)' \
  check_narrow_cmpxchg
prove_mutation "switch: retain the raw narrow case key" \
  src/compiler/native/aarch64/isel.iyi \
  'key = key - span if key >= span // 2_i64' \
  'key = key - span if false' \
  check_narrow_switch
prove_mutation "call: leave a narrow result uncanonicalised" \
  src/compiler/native/aarch64/isel.iyi \
  'regs << canon(d, loc.leaf_type)' \
  'regs << d' \
  check_narrow_call
prove_mutation "signed i1: interpret one as positive" \
  src/compiler/native/aarch64/isel.iyi \
  '  def signed_value(v : Int32, t : IrType) : Int32
    return v unless t.int? && t.bits == 1' \
  '  def signed_value(v : Int32, t : IrType) : Int32
    return v' \
  check_narrow_i1
prove_mutation "parameter: leave a narrow incoming value uncanonicalised" \
  src/compiler/native/aarch64/isel.iyi \
  '          regs[k] = canon(dst, loc.leaf_type)' \
  '          regs[k] = dst' \
  check_narrow_param
prove_mutation "isel: the subtraction's operands swap" \
  src/compiler/native/aarch64/isel.iyi \
  'bind_result(i, [canon(binop(kind, a, b), t)])' \
  'bind_result(i, [canon(binop(kind, b, a), t)])' \
  check_arith
prove_mutation "frame: callee-saved registers are not saved in the prologue" \
  src/compiler/native/frame.iyi \
  '    m = new_inst(fn.isa, Role::SaveReg)' \
  '    m = MInst.new(MOp::Label.value.to_i32)' \
  check_recursion
prove_mutation "frame: the stack probe is dropped" \
  src/compiler/native/frame.iyi \
  '    acc << new_inst(fn.isa, Role::Probe)' \
  '    acc << MInst.new(MOp::Label.value.to_i32)' \
  check_probe
prove_mutation "iyi convention: the second leaf of a split aggregate takes the wrong register" \
  src/compiler/native/lower.iyi \
  'locs << LeafLoc.new(0, desc.integer_args[gpr_next], -1_i64, bits, false, leaf)' \
  'locs << LeafLoc.new(0, desc.integer_args[gpr_next + k], -1_i64, bits, false, leaf)' \
  check_iyiagg
prove_mutation "byval: the caller passes its own object instead of a copy" \
  src/compiler/native/aarch64/isel.iyi \
  '    [dst]
  end

  # Copies' \
  '    [source]
  end

  # Copies' \
  check_byval
prove_mutation "atomicrmw max: the keep branch selects the smaller value" \
  src/compiler/native/aarch64/isel.iyi \
  'cond = signed ? cond_gt : cond_hi' \
  'cond = signed ? cond_lt : cond_hi' \
  check_rmw
prove_mutation "memmove: a large move calls the copy helper" \
  src/compiler/native/aarch64/isel.iyi \
  'overlap ? "__iyi_native_memmove" : "__iyi_native_memcpy"' \
  '"__iyi_native_memcpy"' \
  check_mem
prove_mutation "i128 add: the two halves of the sum are bound in reverse" \
  src/compiler/native/aarch64/isel.iyi \
  'bind_result(i, [lo, binop(MOp::Adc, a[1], b[1])])' \
  'bind_result(i, [binop(MOp::Adc, a[1], b[1]), lo])' \
  check_wide
prove_mutation "i128 add: the carry into the high half is dropped" \
  src/compiler/native/aarch64/isel.iyi \
  'bind_result(i, [lo, binop(MOp::Adc, a[1], b[1])])' \
  'bind_result(i, [lo, binop(MOp::Add, a[1], b[1])])' \
  check_wide
prove_mutation "i128 argument: the high half is passed in the low half's register" \
  src/compiler/native/lower.iyi \
  'LeafLoc.new(0, desc.integer_args[gpr_next + 1], -1_i64, 64, false, leaves[1][1])' \
  'LeafLoc.new(0, desc.integer_args[gpr_next], -1_i64, 64, false, leaves[1][1])' \
  check_wide
prove_mutation "atomicrmw monotonic: the load takes the acquire form" \
  src/compiler/native/aarch64/isel.iyi \
  'acquire ? MOp::Ldaxr : MOp::Ldxr' \
  'MOp::Ldaxr' \
  check_mono_pair

prove_mutation "jump table: the index is one too high, so every case reads the next entry" \
  src/compiler/native/aarch64/isel.iyi \
  'index = binop(MOp::Sub, v, const_gpr(plan.low))' \
  'index = binop(MOp::Sub, v, const_gpr(plan.low - 1_i64))' \
  check_jump_dense
prove_mutation "jump table: the range check is dropped, so an out-of-range value indexes past the table" \
  src/compiler/native/aarch64/isel.iyi \
  '    emit(range_check)' \
  '    emit(mop(MOp::Label))' \
  check_jump_dense
prove_mutation "jump table: the case-0 block is missing from the branch's successors, so a value live into it is clobbered" \
  src/compiler/native/regalloc_linear.iyi \
  '      table_targets.each do |t|
        acc << t' \
  '      table_targets.each do |t|
        acc << t unless t == table_targets[0]' \
  check_jump_loop
prove_mutation "thread-local: the thunk call is skipped, so the descriptor's address is taken for the variable" \
  src/compiler/native/aarch64/isel.iyi \
  '    m.clobbers = tlv_clobbers
    emit(m)' \
  '    m.clobbers = tlv_clobbers' \
  check_tls_init
prove_mutation "thread-local: the TLV page is reached through the GOT's relocation kind" \
  src/compiler/native/aarch64/encode.iyi \
  'reloc(RelocKind::A64TlvpPage21, inst.sym)' \
  'reloc(RelocKind::A64GotPage21, inst.sym)' \
  check_tlvp_kind
prove_mutation "thread-local: the thunk's clobbers lose x16 and x17" \
  src/compiler/native/aarch64/isel.iyi \
  '    [0, 16, 17, 30]' \
  '    [0, 30]' \
  check_tls_clobbers
prove_mutation "thread-local: a zero initialiser is placed in __thread_data, not __thread_bss" \
  src/compiler/native/thread_locals.iyi \
  '    zero = w.relocs.empty?' \
  '    zero = false' \
  check_tbss_placed
prove_mutation "threadpointer: the darwin read drops the low-bit mask" \
  src/compiler/native/aarch64/isel.iyi \
  '      m.imm = -8_i64' \
  '      m.imm = 0xf0_i64' \
  check_tp_mask
prove_mutation "asm: each output's register is read from the input operands" \
  src/compiler/native/aarch64/encode.iyi \
  '      names << reg_name(inst.defs[k].reg)' \
  '      names << reg_name(inst.uses[k].reg)' \
  check_bind
prove_mutation "asm: a naked body is given a prologue and epilogue" \
  src/compiler/native/driver.iyi \
  '  if mf.naked' \
  '  if false' \
  check_naked
prove_mutation "asm: a register clobber is ignored" \
  src/compiler/native/aarch64/isel.iyi \
  '      defs << pop(reg)
      note_callee_saved(reg) unless @mf.naked' \
  '      note_callee_saved(reg) unless @mf.naked' \
  check_clobber
prove_mutation "asm: a relocation names the wrong symbol" \
  src/compiler/native/aarch64/encode.iyi \
  '      index = body.syms[r.name]?' \
  '      index = body.syms["eight"]?' \
  check_reloc
prove_mutation "constant expression: a product is reduced as a sum" \
  src/compiler/native/const_expr.iyi \
  '    return ConstAddress.new(nil, wrap_to_bits(a.offset * b.offset, i.type.int? ? i.type.bits : 64))' \
  '    return ConstAddress.new(nil, wrap_to_bits(a.offset + b.offset, i.type.int? ? i.type.bits : 64))' \
  check_constmul
echo "a mutation that changes nothing is refused by the proof helper:"
noop_output=$(prove_mutation "no-op: the same text on both sides" \
    src/compiler/native/frame.iyi \
    '    m = new_inst(fn.isa, Role::SaveReg)' \
    '    m = new_inst(fn.isa, Role::SaveReg)' \
    check_probe 2>&1)
noop_status=$?
if [ "$noop_status" -ne 0 ] && printf '%s\n' "$noop_output" | grep -q 'PATCH CHANGED NOTHING'; then
  echo "refused: the no-op proof does not pass"
else
  fail "the proof helper accepted a mutation that changes nothing"
fi
if [ "$HOST_ID" = darwin-arm64 ]; then
  expected_checked=32
  expected_limited=0
else
  expected_checked=6
  expected_limited=26
fi
printf 'mutations: %s total, %s checked, %s caught, %s host-limited\n' \
  "$mutation_total" "$mutation_checked" "$mutation_caught" "$mutation_limited"
[ "$mutation_total" -eq 32 ] || fail "the mutation inventory is not 32"
[ "$mutation_checked" -eq "$expected_checked" ] || fail "the expected mutations were not all checked"
[ "$mutation_caught" -eq "$expected_checked" ] || fail "not every checked mutation was caught"
[ "$mutation_limited" -eq "$expected_limited" ] || fail "the host-limited mutation inventory is incomplete"

echo
if [ "$failed" -eq 0 ]; then
  echo "== THE NATIVE CODEGEN CHECKS PASS"
  exit 0
fi
echo "== SOME NATIVE CODEGEN CHECKS FAILED"
exit 1
