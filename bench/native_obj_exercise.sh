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
# Needs a built compiler (`make`). The selfhost job runs the round trip and
# drop-ADDEND proof; selfhost-darwin runs every step.

set -u

root="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$root" || exit 1

iyi=./bin/iyi
triple=aarch64-apple-darwin
tool_src=src/compiler/tools/obj_macho.iyi
macho_src=src/compiler/native/obj/macho.iyi

work="$(mktemp -d "${TMPDIR:-/tmp}/native_obj.XXXXXX")" || exit 1
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
  mkdir -p "$work/bin"
  "$iyi" build -o "$work/bin/obj_macho" "$tool_src" >"$work/build-tool.log" 2>&1
}

# check_roundtrip NAME: the driver round-trips the corpus object for NAME.
check_roundtrip() {
  "$work/bin/obj_macho" "$work/corpus/$1.o" "$work/corpus/$1.rt.o" >"$work/corpus/$1.rt.log" 2>&1
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
  backup="$work/mutation-$RANDOM.bak"
  cp "$file" "$backup" || return 1
  restore="$file"
  python3 - "$file" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
if old not in text:
    sys.exit(3)
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
  patched=$?
  if [ "$patched" -eq 3 ]; then
    cp "$backup" "$file"
    restore=""
    fail "PATCH CHANGED NOTHING: '$label' found no text to change"
    return 1
  fi
  if [ "$patched" -ne 0 ]; then
    cp "$backup" "$file"
    restore=""
    fail "could not apply '$label'"
    return 1
  fi
  if "$@" >"$work/mutation-check.log" 2>&1; then
    fail "NOT caught: $label"
  else
    echo "   caught: $label"
  fi
  cp "$backup" "$file"
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
cp "$work/bin/obj_macho" "$work/bin/obj_macho.good"
otool -L "$work/bin/obj_macho" >"$work/otool.log" 2>/dev/null
if [ "$(uname -s)" = Darwin ]; then
  echo "   otool -L $(basename "$work/bin/obj_macho"):"
  sed 's/^/     /' "$work/otool.log"
  libs="$(tail -n +2 "$work/otool.log" | wc -l | tr -d ' ')"
  if [ "$libs" != 1 ] || ! grep -q "/usr/lib/libSystem.B.dylib" "$work/otool.log"; then
    fail "the driver links more than libSystem.B.dylib"
  fi
fi

echo "== 2. the oracle's arm64 Mach-O object for every samples/iyi program"
mkdir -p "$work/corpus"
: >"$work/coverage.txt"
names=""
for src in samples/iyi/*.iyi bench/fixtures/native_obj/*.iyi; do
  name="$(basename "$src" .iyi)"
  obj="$work/corpus/$name.o"
  if ! "$iyi" build --cross-compile --target "$triple" -o "$obj" "$src" \
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
  echo "   $name: round trip equal"
done

echo "== 3. relocation coverage over the corpus (zero counts are listed)"
awk '{ count[$2] += $3 } END { for (k in count) print k, count[k] }' "$work/coverage.txt" | sort |
  while read -r kind total; do
    echo "   $kind $total"
  done

echo "== 4. each rewritten program matches the original (macOS only)"
if [ "$(uname -s)" = Darwin ]; then
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
    if check_relinked "$name"; then
      echo "   $name: relinked program matches (exit $orig_status)"
    else
      fail "relinked $name differs from the original (exit $orig_status)"
    fi
  done
else
  echo "   not run on $(uname -s): the native-darwin job links and runs the corpus"
fi

echo "== 5. mutation proofs"
check_drop_addend() {
  build_tool && check_roundtrip hello
}
prove_mutation "drop the ADDEND records the writer emits" "$macho_src" \
  "elsif r.addend != 0_i64" "elsif false" \
  check_drop_addend
check_fold_without_zeroing() {
  build_tool && check_roundtrip hello
}
prove_mutation "fold the in-place addend but leave the site non-zero" "$macho_src" \
  "bytes[(address + k).to_i32] = 0_u8" "bytes[(address + k).to_i32] = bytes[(address + k).to_i32]" \
  check_fold_without_zeroing
if [ "$(uname -s)" = Darwin ]; then
  # The relinked program is the judge. The driver writes its output before it
  # reads that output back, so a writer or reader that drops an addend still
  # leaves an object to link, and the program must then fail to match.
  judge_by_relink() {
    build_tool || return 1
    for name in $names; do
      if [ -n "$(excluded_reason "$name")" ]; then
        continue
      fi
      rm -f "$work/corpus/$name.rt.o"
      "$work/bin/obj_macho" "$work/corpus/$name.o" "$work/corpus/$name.rt.o" >/dev/null 2>&1
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
  echo "   the relinked-program proofs need cc: the native-darwin job runs them"
fi
# Restore the driver built from the unmutated source for the remaining checks.
cp "$work/bin/obj_macho.good" "$work/bin/obj_macho"

[ ! -e "$NATIVE_SIGNATURE_FAILURE_FILE" ] || fail "a native executable failed signature verification"
if [ "$failures" -eq 0 ]; then
  echo "== ALL NATIVE_OBJ CHECKS PASSED"
  exit 0
fi
echo "== SOME NATIVE_OBJ CHECKS FAILED"
exit 1
