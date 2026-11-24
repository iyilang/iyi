#!/usr/bin/env bash
# The native object gate (SPEC 3.4, slice C1).
#
# For every samples/iyi/*.iyi the Crystal-hosted compiler emits an arm64 Mach-O
# object with --cross-compile --target aarch64-apple-darwin. The native reader
# reads it, the native writer writes it back, and the reader must read the
# result equal to the first read. The driver prints the relocation kinds it
# saw, zero counts included.
#
# On macOS each rewritten object is linked with the link line the compiler
# printed for the original, and the program must match the original's exit
# status and stdout. A sample is excluded only when its original program
# gives different output on two runs, or when it needs the network or a
# server, and each exclusion is named below with its reason.
#
# Mutation proofs break one line of the reader or writer in a copy of the
# source, rebuild the driver, and require the check to fail. The helper
# requires the patch to change something: a patch whose text is absent fails
# the gate. The relinked-program proof needs cc and runs on macOS only.
#
# Needs a built compiler (`make`) and Python. Every host checks the corpus
# and the two round-trip mutants; macOS also links and runs Mach-O programs.

set -u

root="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$root" || exit 1

. "$root/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if [ -z "$PY" ]; then
  echo "native_obj: a working python3 or python is required" >&2
  exit 1
fi
. "$root/bench/floor_base.sh"

iyi=./bin/iyi
triple=aarch64-apple-darwin
tool_src=src/compiler/tools/obj_macho.iyi
macho_src=src/compiler/native/obj/macho.iyi

work="$(mktemp -d "${TMPDIR:-/tmp}/native_obj.XXXXXX")" || exit 1
tool_bin="$work/bin/obj_macho$EXE"
good_tool="$work/bin/obj_macho.good$EXE"
. bench/lib/native_signature.sh
export NATIVE_SIGNATURE_FAILURE_FILE="$work/signature-failure"
restore=""
backup=""
cleanup() {
  if [ -n "$restore" ] && [ -n "$backup" ]; then
    cp "$backup" "$restore"
  fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

failures=0
fail() {
  echo "   $*"
  failures=$((failures + 1))
}

# Samples that are not compared, each with its reason. Nothing else is excluded.
excluded_reason() {
  case "$1" in
    socket) echo "opens a network socket" ;;
    webapp) echo "serves HTTP until it is stopped" ;;
    *) echo "" ;;
  esac
}

# run_program EXE OUT: runs EXE from a scratch directory with no stdin for at most
# 30 seconds, writing stdout to OUT and printing the exit status.
run_program() {
  rundir="$work/run"
  mkdir -p "$rundir"
  (cd "$rundir" && perl -e 'alarm 30; exec @ARGV' "$1" </dev/null >"$2" 2>/dev/null)
  echo $?
}

# build_tool: builds the driver from the current source into $work/bin/.
build_tool() {
  mkdir -p "$work/bin" || return 1
  rm -f "$tool_bin" || return 1
  "$iyi" build -o "$(native_path "$tool_bin")" "$(native_path "$tool_src")" >"$work/build-tool.log" 2>&1 || return 1
  if [ ! -f "$tool_bin" ]; then
    echo "compiler returned success without producing $tool_bin" >>"$work/build-tool.log"
    return 1
  fi
}

# restore_driver: puts the saved unmodified driver back at $tool_bin as a new file.
# A copy over the file a mutant just ran from keeps that file's identity: macOS
# keeps the code signature it cached when the mutant ran, and kills the driver
# on its next run (SIGKILL, Code Signature Invalid).
restore_driver() {
  rm -f "$tool_bin" && cp "$good_tool" "$tool_bin"
}

# check_roundtrip NAME: the driver round-trips the corpus object for NAME.
check_roundtrip() {
  "$tool_bin" "$(native_path "$work/corpus/$1.o")" "$(native_path "$work/corpus/$1.rt.o")" >"$work/corpus/$1.rt.log" 2>&1
  status=$?
  grep -q "^ROUNDTRIP EQUAL" "$work/corpus/$1.rt.log" && [ "$status" -eq 0 ]
}

# check_relinked NAME: the round-tripped object for NAME links with the printed
# link line and runs with the original's exit status and stdout.
check_relinked() {
  name=$1
  line="$(tail -n 1 "$work/corpus/$name.link")"
  rt_obj="$work/corpus/$name.rt.o"
  rt_exe="$work/corpus/$name.rt"
  rt_line="${line//$work\/corpus\/$name.o/$rt_obj}"
  rt_line="${rt_line// -o $work\/corpus\/$name / -o $rt_exe }"
  rm -f "$rt_exe"
  sh -c "$rt_line" >"$work/corpus/$name.rt.link.log" 2>&1 || return 1
  native_signature_ok "$rt_exe" || return 1
  rt_status="$(run_program "$rt_exe" "$work/corpus/$name.rt.out")"
  orig_status="$(cat "$work/corpus/$name.status")"
  [ "$rt_status" = "$orig_status" ] && cmp -s "$work/corpus/$name.out" "$work/corpus/$name.rt.out"
}

# prove_mutation LABEL FILE OLD NEW CHECK...: replaces the first OLD in FILE with
# NEW, runs CHECK, and requires it to fail. Restores FILE on every exit path.
prove_mutation() {
  label=$1
  file=$2
  old=$3
  new=$4
  shift 4
  # A negative proof is meaningful only if the unmodified driver passes the
  # same check. The preceding mutant must not be left in place for this run.
  if ! restore_driver; then
    fail "could not restore the good driver before '$label'"
    return 1
  fi
  if ! "$@" >"$work/mutation-baseline.log" 2>&1; then
    fail "INVALID: '$label' baseline failed"
    tail -n 20 "$work/mutation-baseline.log"
    return 1
  fi
  backup="$work/mutation-$RANDOM.bak"
  if ! cp "$file" "$backup"; then
    fail "could not back up the source for '$label'"
    return 1
  fi
  restore="$file"
  "$PY" - "$(native_path "$file")" "$old" "$new" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
old, new = (value.encode("utf-8") for value in sys.argv[2:])
data = path.read_bytes()
if old not in data:
    sys.exit(3)
path.write_bytes(data.replace(old, new, 1))
PY
  patched=$?
  if [ "$patched" -eq 3 ]; then
    fail "PATCH CHANGED NOTHING: '$label' found no text to change"
  elif [ "$patched" -ne 0 ]; then
    fail "could not apply '$label'"
  elif ! build_tool; then
    fail "INVALID: '$label' mutant driver did not build"
    tail -n 20 "$work/build-tool.log"
  elif "$@" >"$work/mutation-check.log" 2>&1; then
    fail "NOT caught: $label"
  else
    echo "   caught: $label"
  fi
  if ! cp "$backup" "$file"; then
    fail "could not restore source after '$label'"
    exit 1
  fi
  restore=""
  return 0
}

echo "== 1. build the driver from the source"
if ! build_tool; then
  echo "   the driver does not build:"
  tail -n 20 "$work/build-tool.log"
  echo "== SOME NATIVE_OBJ CHECKS FAILED"
  exit 1
fi
if ! cp "$tool_bin" "$good_tool"; then
  echo "   could not save the unmodified driver" >&2
  exit 1
fi
echo "   driver dependency floor on $HOST_ID: $tool_bin"
case "$HOST_OS" in
  darwin)
    if ! otool -L "$tool_bin" >"$work/otool.log" 2>&1; then
      fail "otool could not inspect the driver"
      cat "$work/otool.log"
    else
      echo "   otool -L $(basename "$tool_bin"):"
      sed 's/^/     /' "$work/otool.log"
      libs="$(tail -n +2 "$work/otool.log" | wc -l | tr -d ' ')"
      if [ "$libs" != 1 ] || ! grep -q "/usr/lib/libSystem.B.dylib" "$work/otool.log"; then
        fail "the driver links more than libSystem.B.dylib"
      fi
    fi
    echo "   macOS undefined-symbol floor is unverified; the direct library floor is checked above"
    ;;
  linux)
    if ! command -v nm >/dev/null 2>&1 || ! command -v readelf >/dev/null 2>&1; then
      fail "nm and readelf are required to inspect the Linux driver floor"
    elif ! nm -u "$tool_bin" >"$work/nm.log" 2>&1; then
      fail "nm could not inspect the driver"
      cat "$work/nm.log"
    elif ! readelf -d "$tool_bin" >"$work/readelf.log" 2>&1; then
      fail "readelf could not inspect the driver"
      cat "$work/readelf.log"
    else
      symbols="$(sed -e 's/^ *//' -e 's/^U  *//' -e 's/@.*$//' "$work/nm.log" |
        awk '{ print $NF }' | sed -e 's/^_//' -e 's/^_environ$/environ/' | grep -v '^$' | sort -u)"
      libraries="$(sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' "$work/readelf.log" | sort -u)"
      extra_symbols=""
      for symbol in $symbols; do
        case " $FLOOR_BASE_LINUX environ " in
          *" $symbol "*) ;;
          *) extra_symbols="$extra_symbols $symbol" ;;
        esac
      done
      extra_libraries="$(extra_dlls "libc.so ld-linux libgcc_s" "$libraries")"
      printf '   undefined symbols: %s\n' "${symbols:-none}"
      printf '   direct libraries: %s\n' "${libraries:-none}"
      [ -z "$extra_symbols" ] || fail "Linux driver has symbols outside its runtime floor: $extra_symbols"
      [ -z "$extra_libraries" ] || fail "Linux driver has libraries outside its runtime floor: $extra_libraries"
    fi
    ;;
  windows)
    DUMPBIN="$(find_dumpbin || true)"
    if [ -z "$DUMPBIN" ]; then
      fail "dumpbin is required to inspect the Windows driver floor"
    elif ! "$DUMPBIN" -nologo -dependents "$(native_path "$tool_bin")" >"$work/dumpbin.log" 2>&1; then
      fail "dumpbin could not inspect the driver"
      cat "$work/dumpbin.log"
    else
      # dumpbin writes Windows line endings; normalize its text before the
      # shared DLL parser without changing any target-program output.
      real_dumpbin="$DUMPBIN"
      dumpbin_lf() { "$real_dumpbin" "$@" | tr -d '\r'; }
      DUMPBIN=dumpbin_lf
      dlls="$(pe_dlls "$(native_path "$tool_bin")")"
      DUMPBIN="$real_dumpbin"
      if [ -z "$dlls" ]; then
        fail "dumpbin read no DLL imports from the Windows driver"
        cat "$work/dumpbin.log"
      else
        printf '   direct DLLs: %s\n' "$dlls"
        # The driver is built with the prelude, which keys String#hash with
        # RtlGenRandom (advapi32.dll, #212). That is the one program DLL the
        # driver may carry; see FLOOR_DLLS_PROGRAM in bench/floor_base.sh.
        extra="$(extra_dlls "$FLOOR_DLLS_RUNTIME advapi32.dll" "$dlls")"
        [ -z "$extra" ] || fail "Windows driver has DLLs outside its runtime floor: $extra"
      fi
    fi
    echo "   Windows per-symbol import floor is unverified; the direct DLL floor is checked above"
    ;;
esac

echo "== 2. the oracle's arm64 Mach-O object for every samples/iyi program"
mkdir -p "$work/corpus"
: >"$work/coverage.txt"
names=""
sample_count=0
fixture_found=0
corpus_count=0
roundtrip_count=0
for src in samples/iyi/*.iyi bench/fixtures/native_obj/*.iyi; do
  if [ ! -f "$src" ]; then
    fail "corpus source is missing: $src"
    continue
  fi
  case "$src" in
    samples/iyi/*) sample_count=$((sample_count + 1)) ;;
    bench/fixtures/native_obj/extern_globals.iyi) fixture_found=1 ;;
  esac
  corpus_count=$((corpus_count + 1))
  name="$(basename "$src" .iyi)"
  obj="$work/corpus/$name.o"
  if ! "$iyi" build --cross-compile --target "$triple" -o "$(native_path "$obj")" "$(native_path "$src")" \
      >"$work/corpus/$name.link" 2>"$work/corpus/$name.err"; then
    fail "the oracle does not compile $src"
    continue
  fi
  names="$names $name"
  if ! check_roundtrip "$name"; then
    fail "round trip of $name is not equal:"
    sed 's/^/     /' "$work/corpus/$name.rt.log" | tail -n 5
    continue
  fi
  grep '^reloc ' "$work/corpus/$name.rt.log" >>"$work/coverage.txt"
  roundtrip_count=$((roundtrip_count + 1))
  echo "   $name: round trip equal"
done
[ "$sample_count" -ge 28 ] || fail "expected at least 28 sample sources, found $sample_count"
[ "$fixture_found" -eq 1 ] || fail "the external-globals fixture is missing"
echo "   $roundtrip_count/$corpus_count corpus round trips equal ($sample_count samples, external-globals fixture $fixture_found)"

echo "== 3. relocation coverage over the corpus (zero counts are listed)"
awk '{ count[$2] += $3 } END { for (k in count) print k, count[k] }' "$work/coverage.txt" | sort |
  while read -r kind total; do
    echo "   $kind $total"
  done

echo "== 4. each rewritten program matches the original (macOS only)"
relink_names=""
if [ "$HOST_OS" = darwin ]; then
  for name in $names; do
    why="$(excluded_reason "$name")"
    if [ -n "$why" ]; then
      echo "   $name: excluded, $why"
      continue
    fi
    exe="$work/corpus/$name"
    line="$(tail -n 1 "$work/corpus/$name.link")"
    if ! sh -c "$line" >"$work/corpus/$name.link-orig.log" 2>&1; then
      fail "the original does not link: $name"
      continue
    fi
    orig_status="$(run_program "$exe" "$work/corpus/$name.out")"
    echo "$orig_status" >"$work/corpus/$name.status"
    again_status="$(run_program "$exe" "$work/corpus/$name.again")"
    if [ "$again_status" != "$orig_status" ] || ! cmp -s "$work/corpus/$name.out" "$work/corpus/$name.again"; then
      echo "   $name: excluded, the original gives different output on two runs"
      continue
    fi
    relink_names="$relink_names $name"
    if check_relinked "$name"; then
      echo "   $name: relinked program matches (exit $orig_status)"
    else
      fail "relinked $name differs from the original (exit $orig_status)"
    fi
  done
else
  host_limited "Mach-O program linking, execution and signature verification require macOS"
fi

echo "== 5. mutation proofs"
check_drop_addend() {
  check_roundtrip hello
}
prove_mutation "drop the ADDEND records the writer emits" "$macho_src" \
  "elsif r.addend != 0_i64" "elsif false" \
  check_drop_addend
check_fold_without_zeroing() {
  check_roundtrip hello
}
prove_mutation "fold the in-place addend but leave the site non-zero" "$macho_src" \
  "bytes[(address + k).to_i32] = 0_u8" "bytes[(address + k).to_i32] = bytes[(address + k).to_i32]" \
  check_fold_without_zeroing
if [ "$HOST_OS" = darwin ]; then
  # The relinked program is the judge. The driver writes its output before it
  # reads that output back, so a writer or reader that drops an addend still
  # leaves an object to link, and the program must then fail to match.
  judge_by_relink() {
    [ -n "$relink_names" ] || return 1
    for name in $relink_names; do
      rm -f "$work/corpus/$name.rt.o"
      "$tool_bin" "$(native_path "$work/corpus/$name.o")" "$(native_path "$work/corpus/$name.rt.o")" >/dev/null 2>&1
      [ -f "$work/corpus/$name.rt.o" ] || return 1
      check_relinked "$name" || return 1
    done
    return 0
  }
  prove_mutation "stop folding the in-place addend on read" "$macho_src" \
    "addend + fold_in_place(h, bytes, address, width, target)" \
    "addend + 0_i64 * fold_in_place(h, bytes, address, width, target)" \
    judge_by_relink
  prove_mutation "stop writing the in-place addend back" "$macho_src" \
    "patch_site(start, plan, p)" \
    "patch_site(start, plan, p) if plan.size < 0_i64" \
    judge_by_relink
  prove_mutation "shift the PAGE21 pc-relative bit by one" "$macho_src" \
    "[MachO::R_PAGE21, 1_i64, 2_i64]" "[MachO::R_PAGE21, 0_i64, 2_i64]" \
    judge_by_relink
else
  host_limited "the three relinked-program mutants require macOS Mach-O linking and execution"
fi
# Restore the driver built from the unmutated source for the remaining checks.
restore_driver || fail "could not restore the good driver"

[ ! -e "$NATIVE_SIGNATURE_FAILURE_FILE" ] || fail "a native executable failed signature verification"
if [ "$failures" -eq 0 ]; then
  echo "== ALL NATIVE_OBJ CHECKS PASSED"
  exit 0
fi
echo "== SOME NATIVE_OBJ CHECKS FAILED"
exit 1
