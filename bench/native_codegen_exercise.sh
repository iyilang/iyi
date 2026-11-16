#!/usr/bin/env bash
# The aarch64 code generation gate (SPEC 2.2, 3.3, 3.5; slice C3). Each IR fixture under
# bench/fixtures/native_cg/ is compiled by the native backend to an object, linked with cc on this
# machine, and run; its exit status and stdout must equal those of the equivalent .iyi program built by the
# hosted compiler. Also checked: the driver links only libSystem, the 64 KiB frame's MIR dump shows
# page-by-page probes, the Linux variant of every fixture encodes (not executed here), and mutations of the
# backend are each caught.
#
#   bench/native_codegen_exercise.sh
#
# Jobs: native-darwin runs every step. The Linux variant is encoded on every host and is never executed by
# this gate; the native-linux job runs the encoder gate (bench/native_encode_exercise.sh) instead.
set -u
cd "$(dirname "$0")/.." || exit 1

WORK=$(mktemp -d "${TMPDIR:-/tmp}/native-codegen.XXXXXX")
RESTORE=()
restore_all() {
  for entry in "${RESTORE[@]+"${RESTORE[@]}"}"; do
    cp "${entry%%|*}" "${entry#*|}" 2>/dev/null
  done
  rm -rf "$WORK"
}
trap restore_all EXIT INT TERM

failed=0
fail() { echo "FAIL: $*"; failed=1; }

export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"$PATH"
export LIBRARY_PATH=${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}

FIX=bench/fixtures/native_cg
DRV="$WORK/native_cg"

build_driver() { ./bin/iyi build -o "$1" src/compiler/tools/native_cg.iyi >"$WORK/build.$(basename "$1").log" 2>&1; }

# ---- 1. the driver -----------------------------------------------------------------------------
echo "== 1. build the driver with the hosted compiler"
if ! build_driver "$DRV"; then
  grep -v 'ld: warning' "$WORK/build.native_cg.log" | tail -20
  fail "the driver does not build"
  exit 1
fi

# ---- 2. the linkage floor ----------------------------------------------------------------------
echo "== 2. the driver links only libSystem"
if [ "$(uname -s)" = "Darwin" ]; then
  if [ "$(otool -L "$DRV" | tail -n +2 | wc -l | tr -d ' ')" = "1" ] && otool -L "$DRV" | grep -q '/usr/lib/libSystem.B.dylib'; then
    echo "libSystem only"
  else
    otool -L "$DRV"
    fail "the driver links more than libSystem"
  fi
else
  echo "skipped: not darwin"
fi

# ---- 3. fixtures: native object, linked with cc and run, equal to the hosted compiler's program ---
echo "== 3. every fixture runs as the hosted compiler's program does"
count=0
for ir in "$FIX"/*.ir; do
  base=$(basename "$ir" .ir)
  iy="$FIX/$base.iyi"
  if [ ! -f "$iy" ]; then
    fail "$base.ir has no equivalent $base.iyi"
    continue
  fi
  if ! "$DRV" obj "$ir" "$WORK/$base.o" >"$WORK/$base.obj.log" 2>&1; then
    cat "$WORK/$base.obj.log"
    fail "$base: the native backend refused the fixture"
    continue
  fi
  if ! cc "$WORK/$base.o" "$FIX/rt_stub.c" -o "$WORK/$base.native" >"$WORK/$base.link.log" 2>&1; then
    fail "$base: cc did not link the native object"
    continue
  fi
  if ! codesign -v --strict "$WORK/$base.native"; then
    fail "$base: native executable failed codesign"
    continue
  fi
  "$WORK/$base.native" >"$WORK/$base.native.out" 2>/dev/null
  echo $? >"$WORK/$base.native.status"
  if ! ./bin/iyi build -o "$WORK/$base.hosted" "$iy" >"$WORK/$base.hosted.log" 2>&1; then
    grep -v 'ld: warning' "$WORK/$base.hosted.log" | tail -5
    fail "$base: the hosted compiler does not build $base.iyi"
    continue
  fi
  "$WORK/$base.hosted" >"$WORK/$base.hosted.out" 2>/dev/null
  echo $? >"$WORK/$base.hosted.status"
  if cmp -s "$WORK/$base.native.out" "$WORK/$base.hosted.out" && cmp -s "$WORK/$base.native.status" "$WORK/$base.hosted.status"; then
    echo "$base: stdout and status equal ($(tr -d '\n' <"$WORK/$base.native.status") exit)"
    count=$((count + 1))
  else
    echo "--- native $base"; cat "$WORK/$base.native.out"; echo "--- hosted $base"; cat "$WORK/$base.hosted.out"
    fail "$base: the native program differs from the hosted compiler's"
  fi
done
[ "$count" -gt 0 ] || fail "no fixture ran"
echo "ran $count fixtures against the hosted compiler"

# ---- 3c. the thread pointer: the masked tpidrro_el0 read is non-zero, 8-aligned and the same on each read -----
echo "== 3c. the thread pointer read on this thread is non-zero, 8-aligned and stable"
if ! "$DRV" obj bench/fixtures/native_tp/threadpointer.ir "$WORK/tp.o" >"$WORK/tp.obj.log" 2>&1; then
  cat "$WORK/tp.obj.log"
  fail "threadpointer: the native backend refused the fixture"
elif ! cc "$WORK/tp.o" bench/fixtures/native_tp/tp_main.c -o "$WORK/tp.bin" >"$WORK/tp.link.log" 2>&1; then
  fail "threadpointer: cc did not link the native object"
elif ! codesign -v --strict "$WORK/tp.bin"; then
  fail "threadpointer: native executable failed codesign"
elif ! "$WORK/tp.bin"; then
  fail "threadpointer: the masked thread pointer is zero, unaligned, or differs between reads"
else
  echo "threadpointer: non-zero, 8-aligned and equal on both reads"
fi
# ---- 3b. naked bodies: the function's bytes and relocations equal the hosted compiler's naked function --------
# The hosted compiler's LLVM may append a return to a naked body, so the oracle may hold the native body followed by one
# trailing `ret`, and nothing else. Relocations are compared by offset within the body and by kind.
echo "== 3b. each naked fixture's body equals the hosted compiler's naked function, bytes and relocations"
for pair in asm_naked_const:const42 asm_naked_addimm:addimm asm_naked_pair:pair; do
  base=${pair%%:*}
  fn=${pair#*:}
  if ! "$DRV" obj "$FIX/$base.ir" "$WORK/$base.nat.o" >"$WORK/$base.nat.log" 2>&1; then
    fail "$base: the native backend refused the naked fixture"
    continue
  fi
  if ! ./bin/iyi build --cross-compile --target aarch64-apple-darwin -o "$WORK/$base.oracle.o" "$FIX/$base.iyi" >"$WORK/$base.oracle.log" 2>&1; then
    fail "$base: the hosted compiler does not build the oracle"
    continue
  fi
  "$DRV" bytes "$WORK/$base.nat.o" >"$WORK/$base.nat.bytes" 2>/dev/null
  "$DRV" bytes "$WORK/$base.oracle.o" >"$WORK/$base.oracle.bytes" 2>/dev/null
  if python3 - "$WORK/$base.nat.bytes" "$WORK/$base.oracle.bytes" "$fn" <<'PY'
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
    :
  else
    fail "$base: the naked body differs from the hosted compiler's"
  fi
done

# ---- 3d. runtime helpers: builtins.ir compiled natively links and behaves as the C stand-ins and the hosted twin --
# The fixture calls every helper over boundary values (zero lengths, overlapping moves both ways, the signed minimum,
# powers of two, maximum values, division by one and by minus one). Linked with the native runtime, with rt_stub.c, and
# built by the hosted compiler, the three print the same output and exit 0.
echo "== 3d. the runtime helpers, compiled natively from builtins.ir, match the C stand-ins and the hosted twin"
RTF=bench/fixtures/native_first_light
if "$DRV" obj "$RTF/rt_helpers.ir" "$WORK/rth.o" >"$WORK/rth.obj.log" 2>&1 \
   && "$DRV" obj src/compiler/native/rt/builtins.ir "$WORK/rt_native.o" >"$WORK/rt_native.log" 2>&1 \
   && cc "$WORK/rth.o" "$WORK/rt_native.o" -o "$WORK/rth_native" \
   && cc -c "$FIX/rt_stub.c" -o "$WORK/rt_stub.o" \
   && cc "$WORK/rth.o" "$WORK/rt_stub.o" -o "$WORK/rth_stub" \
   && ./bin/iyi build -o "$WORK/rth_hosted" "$RTF/rt_helpers.iyi" >"$WORK/rth_hosted.log" 2>&1 \
   && codesign -v --strict "$WORK/rth_native" && codesign -v --strict "$WORK/rth_stub"; then
  "$WORK/rth_native" >"$WORK/rth_native.out"; s1=$?
  "$WORK/rth_stub" >"$WORK/rth_stub.out"; s2=$?
  "$WORK/rth_hosted" >"$WORK/rth_hosted.out"; s3=$?
  if [ "$s1" -ne 0 ] || [ "$s2" -ne 0 ] || [ "$s3" -ne 0 ]; then
    fail "rt_helpers: exit statuses $s1 $s2 $s3 (native, stub, hosted)"
  elif ! cmp -s "$WORK/rth_native.out" "$WORK/rth_stub.out"; then
    fail "rt_helpers: the native runtime prints differently from rt_stub.c"
  elif ! cmp -s "$WORK/rth_native.out" "$WORK/rth_hosted.out"; then
    fail "rt_helpers: the native runtime prints differently from the hosted twin"
  else
    echo "   $(wc -l <"$WORK/rth_native.out" | tr -d ' ') lines identical across native runtime, rt_stub.c and the hosted twin"
  fi
else
  fail "rt_helpers: the parity build failed (see $WORK/rth.obj.log, $WORK/rt_native.log, $WORK/rth_hosted.log)"
fi

# ---- 4. the 64 KiB frame: the MIR dump shows the probe page by page ----------------------------
echo "== 4. the 64 KiB frame is entered page by page"
probes=$("$DRV" mir "$FIX/frame64k.ir" big | grep -c 'ZeroSp')
if [ "$probes" -ge 16 ]; then
  echo "probes in the dump: $probes"
else
  fail "the frame dump shows $probes probes; a 65 KiB frame needs 16"
fi

# ---- 4b. each ordering selects its own exclusive pair: acquire on the load for acquire and seq_cst, release on
# the store for release and seq_cst, and the plain pair for monotonic (LLVM's AArch64 mapping) -----------------
# expect_ord <function> <load op> <store op>: the function's MIR holds that pair and not the other forms.
expect_ord() {
  local fn=$1 load=$2 store=$3 mir oload=Ldaxr ostore=Stlxr
  [ "$load" = Ldaxr ] && oload=Ldxr
  [ "$store" = Stlxr ] && ostore=Stxr
  mir=$("$DRV" mir "$FIX/rmw.ir" "$fn" | tail -n +2)
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
expect_table() { "$DRV" mir "$FIX/$1.ir" "$2" | grep -qF "jump table 0 entries=$3 low=$4 "; }
expect_chain() { ! "$DRV" mir "$FIX/$1.ir" "$2" | grep -qE 'jump table|BrTable'; }
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
tls_mir=$("$DRV" mir "$FIX/tls_loop.ir" main)
descs=$(printf '%s\n' "$tls_mir" | grep -c 'LoadTlvp/64')
thunks=$(printf '%s\n' "$tls_mir" | grep -c 'Blr/64 .*clobbers=x0,x16,x17,x30')
if [ "$descs" -eq 2 ] && [ "$thunks" -eq 2 ]; then
  echo "tls_loop main: $descs descriptor loads, each followed by a thunk call that clobbers x0,x16,x17,x30"
else
  fail "tls_loop main: $descs descriptor loads and $thunks thunk calls, expected 2 and 2"
fi
sed -e 's/^target triple = .*/target triple = "aarch64-unknown-linux-gnu"/' \
    -e 's/^target datalayout = .*/target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32"/' \
    "$FIX/tls_loop.ir" >"$WORK/tls_loop.linux.ir"
linux_mir=$("$DRV" mir "$WORK/tls_loop.linux.ir" bump)
if printf '%s\n' "$linux_mir" | grep -q 'Mrs/64 x[0-9]*$' && printf '%s\n' "$linux_mir" | grep -q 'AddTprelHi/64' \
    && printf '%s\n' "$linux_mir" | grep -q 'AddTprelLo/64' && ! printf '%s\n' "$linux_mir" | grep -q 'Blr'; then
  echo "linux bump: mrs tpidr_el0, then the two local-exec adds, and no thunk call"
else
  fail "linux bump: the local-exec sequence is not as expected"
fi
section_flags() {
  otool -l "$1" | awk -v s="$2" '$1=="sectname" {n=$2} $1=="flags" && n==s {print $2; exit}'
}
section_size() {
  llvm-objdump --macho --section-headers "$1" | awk -v s="$2" '$2==s {print $3}'
}
ti="$WORK/tls_init.o"
tz="$WORK/tls_zero.o"
if [ "$(section_flags "$ti" __thread_data)" = 0x00000011 ] && [ "$(section_flags "$ti" __thread_bss)" = 0x00000012 ] \
    && [ "$(section_flags "$ti" __thread_vars)" = 0x00000013 ]; then
  echo "sections: __thread_data 0x11, __thread_bss 0x12 and __thread_vars 0x13, as the oracle's object has them"
else
  fail "sections: the thread-local section flags differ from the oracle's object"
fi
if [ "$(section_size "$tz" __thread_bss)" = 00000008 ] && [ "$(section_size "$tz" __thread_data)" = 00000000 ] \
    && [ "$(section_size "$ti" __thread_data)" = 00000008 ]; then
  echo "placement: a zero initialiser is in __thread_bss, an initialised one in __thread_data"
else
  fail "placement: zero and initialised thread-locals are not in __thread_bss and __thread_data"
fi
if llvm-objdump --macho --reloc "$ti" | grep -q 'TLVLDP  ' && llvm-objdump --macho --reloc "$ti" | grep -q 'TLVLDPOFF'; then
  echo "relocations: the descriptor is reached through TLVLDP and TLVLDPOFF, as in the oracle's object"
else
  fail "relocations: the descriptor is not reached through the TLVP relocations"
fi
# A thread-local model other than local-exec is refused on Linux by name; a plain global is refused on any target.
lin_general="$WORK/tls_general.linux.ir"
sed -e 's/^target triple = .*/target triple = "aarch64-unknown-linux-gnu"/' \
    -e 's/^target datalayout = .*/target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32"/' \
    -e 's/thread_local(localexec)/thread_local(generaldynamic)/' "$FIX/tls_init.ir" >"$lin_general"
if "$DRV" obj "$lin_general" "$WORK/tls_general.o" >"$WORK/tls_general.log" 2>&1; then
  fail "refusal: a generaldynamic thread-local on Linux was lowered"
elif grep -q 'Linux lowers only the local-exec model' "$WORK/tls_general.log"; then
  echo "refusal: a generaldynamic thread-local on Linux is refused by name"
else
  fail "refusal: the generaldynamic refusal is not the named one"
fi
plain="$WORK/tls_plain.ir"
sed -e 's/internal thread_local(localexec) global/internal global/' "$FIX/tls_init.ir" >"$plain"
if "$DRV" obj "$plain" "$WORK/tls_plain.o" >"$WORK/tls_plain.log" 2>&1; then
  fail "refusal: threadlocaladdr of a plain global was lowered"
elif grep -q 'is not a thread-local global' "$WORK/tls_plain.log"; then
  echo "refusal: threadlocaladdr of a plain global is refused by name"
else
  fail "refusal: the plain-global refusal is not the named one"
fi


# ---- 5. the Linux variant encodes; it is not executed here -------------------------------------
echo "== 5. aarch64-linux-gnu variant of each fixture encodes (not executed)"
linux_count=0
for ir in "$FIX"/*.ir; do
  base=$(basename "$ir" .ir)
  sed -e 's/^target triple = .*/target triple = "aarch64-unknown-linux-gnu"/' \
      -e 's/^target datalayout = .*/target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32"/' \
      "$ir" >"$WORK/$base.linux.ir"
  if "$DRV" obj "$WORK/$base.linux.ir" "$WORK/$base.linux.o" >"$WORK/$base.linux.log" 2>&1; then
    linux_count=$((linux_count + 1))
  else
    cat "$WORK/$base.linux.log"
    fail "$base: the Linux variant does not encode"
  fi
done
echo "encoded $linux_count Linux variants; ELF writing is a later slice, so none was written or executed"

# ---- 6. mutation proofs ------------------------------------------------------------------------
# Applies one mutation to `file`, builds the driver from the mutated source, runs the check that must then
# fail, and restores the file. The text must occur exactly once, and the mutation must change it.
prove_mutation() {
  local name=$1 file=$2 old=$3 new=$4 check=$5
  local hits
  hits=$(python3 -c 'import sys; print(open(sys.argv[1]).read().count(sys.argv[2]))' "$file" "$old")
  if [ "$hits" != "1" ]; then
    fail "mutation $name: the text must occur exactly once (found $hits)"
    return
  fi
  if [ "$old" = "$new" ]; then
    echo "PATCH CHANGED NOTHING: this proves nothing"
    fail "mutation $name: the mutation changes nothing"
    return
  fi
  local backup="$WORK/backup.$RANDOM"
  cp "$file" "$backup"
  RESTORE+=("$file|$backup")
  python3 -c 'import sys; p,o,n=sys.argv[1:4]; s=open(p).read(); open(p,"w").write(s.replace(o,n,1))' "$file" "$old" "$new"
  local mut="$WORK/mutant.$RANDOM"
  if ! build_driver "$mut"; then
    cp "$backup" "$file"
    fail "mutation $name: the mutant does not build, so it proves nothing"
    return
  fi
  "$check" "$mut" >/dev/null 2>&1
  local check_status=$?
  cp "$backup" "$file"
  if [ "$check_status" -eq 125 ]; then
    fail "mutation $name: native executable failed codesign"
  elif [ "$check_status" -eq 0 ]; then
    fail "mutation $name: NOT caught"
  else
    echo "caught: $name"
  fi
}

# Checks against the expected outputs from step 3. Each returns non-zero when the driver's output differs.
check_fixture() {
  local drv=$1 base=$2
  "$drv" obj "$FIX/$base.ir" "$WORK/m.$base.o" >/dev/null 2>&1 || return 1
  cc "$WORK/m.$base.o" "$FIX/rt_stub.c" -o "$WORK/m.$base.bin" >/dev/null 2>&1 || return 1
  codesign -v --strict "$WORK/m.$base.bin" || return 125
  "$WORK/m.$base.bin" >"$WORK/m.$base.out" 2>/dev/null
  local status=$?
  cmp -s "$WORK/m.$base.out" "$WORK/$base.hosted.out" && [ "$status" = "$(tr -d '\n' <"$WORK/$base.hosted.status")" ]
}
check_arith() { check_fixture "$1" arith; }
check_recursion() { check_fixture "$1" control; }
check_iyiagg() { check_fixture "$1" iyiagg; }
check_byval() { check_fixture "$1" byval; }
check_rmw() { check_fixture "$1" rmw; }
check_mem() { check_fixture "$1" mem; }
check_wide() { check_fixture "$1" wide; }
check_mono_pair() { "$1" mir "$FIX/rmw.ir" ord_mono | grep -qw Ldxr; }
check_jump_dense() { check_fixture "$1" jump_dense; }
# The successor mutation exists only in linear scan, which is the one that reads the control-flow graph, so its check
# always runs linear, whatever allocator the gate was started with.
check_jump_loop() { IYI_NATIVE_REGALLOC=linear check_fixture "$1" jump_loop; }
check_probe() {
  local n
  n=$("$1" mir "$FIX/frame64k.ir" big | grep -c 'ZeroSp')
  [ "$n" -ge 16 ]
}
check_tls_init() { check_fixture "$1" tls_init; }
check_constmul() { check_fixture "$1" constexpr_mul; }
check_tlvp_kind() {
  "$1" obj "$FIX/tls_init.ir" "$WORK/m.kind.o" >/dev/null 2>&1 || return 1
  llvm-objdump --macho --reloc "$WORK/m.kind.o" | grep -q 'TLVLDP  '
}
check_tls_clobbers() { "$1" mir "$FIX/tls_loop.ir" bump | grep -q 'clobbers=x0,x16,x17,x30'; }
check_tbss_placed() {
  "$1" obj "$FIX/tls_zero.ir" "$WORK/m.tbss.o" >/dev/null 2>&1 || return 1
  [ "$(section_size "$WORK/m.tbss.o" __thread_bss)" = 00000008 ]
}
check_tp_mask() { "$1" mir bench/fixtures/native_tp/threadpointer.ir tp_word | grep -q 'AndImm/64 .*#imm=-8'; }

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
if prove_mutation "no-op: the same text on both sides" \
    src/compiler/native/frame.iyi \
    '    m = new_inst(fn.isa, Role::SaveReg)' \
    '    m = new_inst(fn.isa, Role::SaveReg)' \
    check_probe | grep -q 'PATCH CHANGED NOTHING'; then
  echo "refused: the no-op proof does not pass"
else
  fail "the proof helper accepted a mutation that changes nothing"
fi

echo
if [ "$failed" -eq 0 ]; then
  echo "== THE NATIVE CODEGEN CHECKS PASS"
  exit 0
fi
echo "== SOME NATIVE CODEGEN CHECKS FAILED"
exit 1
