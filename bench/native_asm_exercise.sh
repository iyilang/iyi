#!/usr/bin/env bash
# The inline asm gate (SPEC 2.2, slice C4).
#
# Usage: bash bench/native_asm_exercise.sh [aarch64]
#
# 1. Builds the driver and line B's parse tool from the source.
# 2. Runs line B's parser over every tracked iyi file under src/. Its verdict
#    goes into the report the inventory reads. A file that holds asm( is read
#    by the inventory's scanner whatever the parser said: the parser does not
#    read asm expressions.
# 3. Inventories every asm(...) expression per target flag set, and reconciles
#    the count with git grep: each line that names asm( is an expression or a
#    named non-expression (a comment, a string, or an identifier such as
#    inline_asm(). No row may come from a file that fails to scan.
# 4. For every aarch64 template, on darwin and on Linux, the assembler's bytes
#    and relocations equal the oracle's. The oracle is the same template in a
#    naked function, built by ./bin/iyi build --cross-compile for that triple.
#    Mach-O is read by C1's reader, ELF by the driver's own reader. The twelve
#    templates with no adrp are compared on both triples (step 4b); the four
#    adrp templates use a page relocation one format spells, so each is compared
#    on the triple that spells it.
# 5. A template or constraint outside the supported set is refused by name.
# 6. otool -L on the driver shows /usr/lib/libSystem.B.dylib alone (macOS).
# 7. Mutation proofs: each must be caught. A patch whose text is absent, or that
#    leaves the text unchanged, is refused, and the proof fails.
#
# Both AArch64 cross-targets run on each host. Only otool needs Darwin.
# Needs a built compiler (`make`), line B's parser and Python.

set -u

arch="${1:-aarch64}"
if [ "$#" -gt 1 ] || [ "$arch" != aarch64 ]; then
  echo "usage: $0 [aarch64]" >&2
  exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
cd "$root" || exit 1
. "$root/bench/lib/host.sh" || {
  echo "host-limited: native asm gate requires a supported test host" >&2
  exit 1
}
require_test_host || exit 1
if [ -z "$PY" ]; then
  host_limited "Python is unavailable; asm mutation proofs cannot run"
  exit 1
fi
if [ "$HOST_OS" = windows ] && ! command -v cygpath >/dev/null 2>&1; then
  host_limited "cygpath is unavailable; native Windows paths cannot be supplied"
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/native_asm.XXXXXX")" || exit 1
REPO_NATIVE="$(native_path "$root")" || exit 1
WORK_NATIVE="$(native_path "$work")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
iyi="$root/bin/iyi"
src_driver="$REPO_NATIVE/src/compiler/tools/native_asm.iyi"
src_asm="$root/src/compiler/native/aarch64/asm.iyi"
parse_src="$REPO_NATIVE/src/compiler/tools/parse.iyi"
fixtures="$root/bench/fixtures/native_asm"
tool="$work/bin/native_asm$EXE"
good_tool="$work/bin/native_asm.good$EXE"
parse_tool="$work/bin/parse-tool$EXE"
restore=""
backup=""
cleanup() {
  if [ -n "$restore" ] && [ -n "$backup" ] && ! cp "$backup" "$restore"; then
    echo "could not restore $restore; backup retained at $backup" >&2
    trap - EXIT
    exit 1
  fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

failures=0
fail() {
  echo "   $*"
  failures=$((failures + 1))
}

# build_driver: builds native_asm from the current source into $work/bin.
build_driver() {
  mkdir -p "$work/bin" || return 1
  rm -f "$tool" || return 1
  "$iyi" build -o "$WORK_NATIVE/bin/native_asm$EXE" "$src_driver" >"$work/build-driver.log" 2>&1 || return 1
  if [ ! -f "$tool" ]; then
    echo "compiler succeeded without producing $tool" >>"$work/build-driver.log"
    return 1
  fi
}

# restore_driver: puts the saved unmodified driver back at $tool as a new file.
# A copy over the file a mutant just ran from keeps that file's identity: macOS
# keeps the code signature it cached when the mutant ran, and kills the driver
# on its next run (SIGKILL, Code Signature Invalid).
restore_driver() {
  rm -f "$tool" && cp "$good_tool" "$tool"
}

echo "== 1. build the driver and line B's parse tool from the source"
if ! build_driver; then
  tail -n 20 "$work/build-driver.log"
  fail "the driver does not build"
  echo "== SOME NATIVE_ASM CHECKS FAILED"
  exit 1
fi
if ! cp "$tool" "$good_tool"; then
  fail "could not save the unmodified driver"
  exit 1
fi
if ! "$iyi" build -o "$WORK_NATIVE/bin/parse-tool$EXE" "$parse_src" >"$work/build-parse.log" 2>&1 || [ ! -f "$parse_tool" ]; then
  tail -n 20 "$work/build-parse.log"
  fail "the parse tool does not build"
  echo "== SOME NATIVE_ASM CHECKS FAILED"
  exit 1
fi

echo "== 2. line B's parser over every tracked iyi file under src"
if ! git ls-files 'src/*.iyi' 'src/**/*.iyi' >"$work/files.unsorted"; then
  fail "could not list the source corpus"
  exit 1
fi
sort -u "$work/files.unsorted" >"$work/files.txt"
if [ ! -s "$work/files.txt" ]; then
  fail "the source corpus is empty"
  exit 1
fi
: >"$work/parse-report.tsv"
parsed_count=0
scanned_count=0
while IFS= read -r file; do
  out="$("$parse_tool" "$REPO_NATIVE/$file" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ]; then
    parsed_count=$((parsed_count + 1))
    printf '%s\tparsed\n' "$file" >>"$work/parse-report.tsv"
  elif [ "$status" -eq 126 ] || [ "$status" -eq 127 ]; then
    fail "the parse tool could not be launched: $out"
    exit 1
  else
    scanned_count=$((scanned_count + 1))
    reason="$(printf '%s\n' "$out" | grep -m 1 -E 'Syntax error|panic' | tr '\t' ' ')"
    [ -n "$reason" ] || reason="exit $status"
    printf '%s\tscanned\t%s\n' "$file" "$reason" >>"$work/parse-report.tsv"
  fi
done <"$work/files.txt"
echo "   files: $(wc -l <"$work/files.txt" | tr -d ' ')"
echo "   parsed by line B: $parsed_count"
echo "   refused by line B: $scanned_count"
if [ "$parsed_count" -eq 0 ]; then
  fail "the parser did not successfully parse any source file"
  exit 1
fi

echo "== 3. inventory: every asm(...) expression per target, against git grep"
if ! "$tool" inventory "$WORK_NATIVE/parse-report.tsv" >"$work/inventory.txt" 2>"$work/inventory.err"; then
  tail -n 3 "$work/inventory.err"
  fail "the inventory failed"
  exit 1
fi
grep -E '^(SUMMARY|MNEMONICS|CENSUS)' "$work/inventory.txt"
echo "   scanned files (asm text present):"
grep '^SCANNED' "$work/inventory.txt" | awk -F'\t' '{print "     " $2 "  " $3}' | sort -u
echo "   refused by a {% raise %}: $(grep -c '^REFUSED' "$work/inventory.txt")"
echo "   errors: $(grep -c '^ERROR' "$work/inventory.txt")"
if grep -q '^ERROR' "$work/inventory.txt"; then
  grep '^ERROR' "$work/inventory.txt" | head -n 5
  fail "the inventory reports errors"
fi
echo "   non-expression asm( lines:"
grep '^NOT_EXPRESSION' "$work/inventory.txt" | awk -F'\t' '{print "     " $2 "  " $3}'

gg_lines="$(git grep -n 'asm(' -- 'src/*.iyi' 'src/**/*.iyi' | wc -l | tr -d ' ')"
substring_lines="$(awk -F '\t' '$1 == "CENSUS" { for (i = 2; i <= NF; i++) if ($i ~ /^substring_lines=/) { sub(/^substring_lines=/, "", $i); print $i } }' "$work/inventory.txt")"
expressions="$(awk -F '\t' '$1 == "SUMMARY" { for (i = 2; i <= NF; i++) if ($i ~ /^expressions=/) { sub(/^expressions=/, "", $i); print $i }; exit }' "$work/inventory.txt")"
not_expressions="$(grep -c '^NOT_EXPRESSION' "$work/inventory.txt")"
case "$gg_lines:$substring_lines:$expressions:$not_expressions" in
  *[!0-9:]*|:*|*::*|*:)
    fail "the inventory census did not contain numeric counts"
    exit 1
    ;;
esac
echo "   git grep asm( lines under src/*.iyi: $gg_lines"
echo "   inventory substring lines: $substring_lines"
echo "   expression lines: $expressions, non-expression lines: $not_expressions"
if [ "$substring_lines" != "$gg_lines" ]; then
  fail "the inventory counts $substring_lines asm( lines, git grep finds $gg_lines"
fi
if [ $((expressions + not_expressions)) != "$gg_lines" ]; then
  fail "expressions and non-expressions do not account for every line"
fi

echo "== 4. aarch64 templates: bytes and relocations equal the oracle's"
for pair in "macho aarch64-apple-darwin oracle-macho" "elf aarch64-linux-gnu oracle-elf"; do
  set -- $pair
  fmt=$1
  triple=$2
  dump=$3
  if ! "$tool" oracle-source "$WORK_NATIVE/inventory.txt" "$triple" >"$work/oracle-$fmt.iyi" 2>"$work/oracle-$fmt.src.err"; then
    fail "the oracle source fails for $triple"
    continue
  fi
  if ! "$iyi" build --cross-compile --target "$triple" -o "$WORK_NATIVE/oracle-$fmt.o" "$WORK_NATIVE/oracle-$fmt.iyi" >"$work/oracle-$fmt.build.log" 2>&1; then
    grep -v 'ld: warning' "$work/oracle-$fmt.build.log" | tail -n 8
    fail "the oracle does not build for $triple"
    continue
  fi
  if ! "$tool" "$dump" "$WORK_NATIVE/oracle-$fmt.o" >"$work/oracle-$fmt.txt" 2>"$work/oracle-$fmt.dump.err"; then
    fail "the oracle reader fails on $triple"
    continue
  fi
  if ! "$tool" cases "$WORK_NATIVE/inventory.txt" "$triple" >"$work/cases-$fmt.txt" 2>"$work/cases-$fmt.err"; then
    fail "the assembler fails for $triple"
    continue
  fi
  if grep -q '^REFUSED' "$work/cases-$fmt.txt"; then
    grep '^REFUSED' "$work/cases-$fmt.txt"
    fail "a $triple template is refused by the assembler"
  fi
  sort "$work/oracle-$fmt.txt" >"$work/oracle-$fmt.sorted"
  sort "$work/cases-$fmt.txt" >"$work/cases-$fmt.sorted"
  funcs="$(grep -c '^FUNC' "$work/oracle-$fmt.sorted")"
  relocs="$(grep -c '^RELOC' "$work/oracle-$fmt.sorted")"
  if [ "$funcs" -eq 0 ]; then
    fail "the oracle produced no functions for $triple"
  elif cmp -s "$work/oracle-$fmt.sorted" "$work/cases-$fmt.sorted"; then
    echo "   $triple: $funcs functions and $relocs relocations equal the oracle's"
  else
    diff "$work/oracle-$fmt.sorted" "$work/cases-$fmt.sorted" | head -n 12
    fail "the assembler's output differs from the oracle for $triple"
  fi
done
echo "== 4b. the templates both formats accept: each equals the oracle on both triples"
shared_ok=1
if ! "$tool" oracle-source "$WORK_NATIVE/inventory.txt" shared >"$work/shared.iyi" 2>"$work/shared.src.err"; then
  fail "the shared oracle source fails"
  shared_ok=0
fi
if ! "$tool" cases "$WORK_NATIVE/inventory.txt" shared >"$work/shared-cases.txt" 2>"$work/shared.cases.err"; then
  fail "the assembler fails on the shared templates"
  shared_ok=0
fi
if [ "$shared_ok" -eq 1 ]; then
  sort "$work/shared-cases.txt" >"$work/shared-cases.sorted"
  for pair in "macho aarch64-apple-darwin oracle-macho" "elf aarch64-linux-gnu oracle-elf"; do
    set -- $pair
    fmt=$1
    triple=$2
    dump=$3
    if ! "$iyi" build --cross-compile --target "$triple" -o "$WORK_NATIVE/shared-$fmt.o" "$WORK_NATIVE/shared.iyi" >"$work/shared-$fmt.build.log" 2>&1; then
      grep -v 'ld: warning' "$work/shared-$fmt.build.log" | tail -n 8
      fail "the shared oracle does not build for $triple"
      continue
    fi
    if ! "$tool" "$dump" "$WORK_NATIVE/shared-$fmt.o" >"$work/shared-$fmt.txt" 2>"$work/shared-$fmt.dump.err"; then
      fail "the oracle reader fails on the shared set for $triple"
      continue
    fi
    sort "$work/shared-$fmt.txt" >"$work/shared-$fmt.sorted"
    funcs="$(grep -c '^FUNC' "$work/shared-$fmt.sorted")"
    if [ "$funcs" -eq 0 ]; then
      fail "the shared oracle produced no functions for $triple"
    elif cmp -s "$work/shared-$fmt.sorted" "$work/shared-cases.sorted"; then
      echo "   $triple: $funcs shared functions and $(grep -c '^RELOC' "$work/shared-$fmt.sorted") relocations equal the oracle's"
    else
      diff "$work/shared-$fmt.sorted" "$work/shared-cases.sorted" | head -n 12
      fail "the shared templates differ from the oracle on $triple"
    fi
  done
fi

echo "== 5. refusals: outside the supported set, refused by name"
# The fixtures end in .tmpl, not .s: the tree ignores *.s, and an ignored
# fixture is on one machine only.
fixture_count=0
for fixture in "$fixtures"/refuse/*.tmpl; do
  if [ ! -f "$fixture" ]; then
    fail "no refusal templates found"
    break
  fi
  fixture_count=$((fixture_count + 1))
  name="$(basename "$fixture")"
  expect="$(awk -F'\t' -v f="$name" '$1 == f { print $2 }' "$fixtures/refuse/EXPECT.tsv")"
  # Git may check out TSV files with CRLF on Windows; this is fixture input,
  # not a normalization of either oracle or assembler output.
  expect="${expect%$'\r'}"
  if [ -z "$expect" ]; then
    fail "$name: no expected refusal"
    continue
  fi
  if ! got="$("$tool" refuse "$REPO_NATIVE/bench/fixtures/native_asm/refuse/$name" 2>&1)"; then
    fail "$name: refusal command failed: $got"
    continue
  fi
  case "$got" in
    REFUSED*"$expect"*) echo "   refused: $name" ;;
    *) fail "$name: expected a refusal containing '$expect', got: $got" ;;
  esac
done
expected_fixtures="$(awk 'NF { n++ } END { print n+0 }' "$fixtures/refuse/EXPECT.tsv")"
if [ "$fixture_count" -ne "$expected_fixtures" ]; then
  fail "refusal templates ($fixture_count) and expectations ($expected_fixtures) do not match"
fi
if ! "$tool" constraints "$REPO_NATIVE/bench/fixtures/native_asm/constraints.tsv" >"$work/constraints.out" 2>"$work/constraints.err"; then
  fail "the constraint fixtures fail to run"
else
  tab="$(printf '\t')"
  n=0
  while IFS="$tab" read -r kind item expect || [ -n "$kind$item$expect" ]; do
    case "$kind" in ""|\#*) continue ;; esac
    expect="${expect%$'\r'}"
    n=$((n + 1))
    actual="$(sed -n "${n}p" "$work/constraints.out")"
    case "$expect" in
      ACCEPTED)
        case "$actual" in
          "ACCEPTED${tab}${item}") ;;
          *) fail "constraint $kind $item: expected ACCEPTED, got: $actual" ;;
        esac
        ;;
      REFUSED:*)
        sub="${expect#REFUSED:}"
        case "$actual" in
          "REFUSED${tab}${item}${tab}"*"$sub"*) ;;
          *) fail "constraint $kind $item: expected a refusal containing '$sub', got: $actual" ;;
        esac
        ;;
      *) fail "constraint $kind $item: unknown expectation '$expect'" ;;
    esac
  done <"$fixtures/constraints.tsv"
  actual_constraints="$(wc -l <"$work/constraints.out" | tr -d ' ')"
  if [ "$n" -eq 0 ] || [ "$n" -ne "$actual_constraints" ]; then
    fail "constraint fixtures ($n) and output rows ($actual_constraints) do not match"
  fi
  echo "   constraint fixtures checked: $n"
fi

echo "== 6. the driver links libSystem alone (macOS)"
if [ "$HOST_OS" != darwin ]; then
  host_limited "otool -L dependency inspection requires macOS"
elif ! command -v otool >/dev/null 2>&1; then
  host_limited "otool is unavailable on $HOST_ID"
  fail "the driver dependencies could not be inspected"
elif ! otool -L "$tool" >"$work/otool.log" 2>&1; then
  fail "otool could not inspect the driver"
  cat "$work/otool.log"
else
  deps="$(tail -n +2 "$work/otool.log" | awk '{ print $1 }')"
  echo "   $deps"
  if [ "$deps" != "/usr/lib/libSystem.B.dylib" ]; then
    fail "the driver links more than libSystem: $deps"
  fi
fi

apply_patch() {
  "$PY" - "$(native_path "$1")" "$2" "$3" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
old, new = (value.encode("utf-8") for value in sys.argv[2:])
data = path.read_bytes()
if old not in data or old == new:
    sys.exit(3)
path.write_bytes(data.replace(old, new, 1))
PY
}

# prove_mutation LABEL FILE OLD NEW CHECK...: replaces the first OLD in FILE with
# NEW, runs CHECK, and requires it to fail. A patch whose OLD is absent, or whose
# NEW leaves the text unchanged, changes nothing and is refused. Restores FILE
# on every exit path.
prove_mutation() {
  local label="$1" file="$2" old="$3" new="$4" patched proof_rc
  shift 4
  if [ "${MUTATION_SKIP:-0}" = 1 ]; then
    fail "NOT RUN (MUTATION_SKIP=1): $label"
    return 1
  fi
  if ! restore_driver; then
    fail "could not restore the driver before '$label'"
    return 1
  fi
  if ! "$@" >"$work/mutation-baseline.log" 2>&1; then
    fail "INVALID BASELINE: '$label' did not match the oracle"
    tail -n 20 "$work/mutation-baseline.log"
    return 1
  fi
  backup="$work/mutation-$RANDOM.bak"
  if ! cp "$file" "$backup"; then
    fail "could not back up the source for '$label'"
    return 1
  fi
  restore="$file"
  apply_patch "$file" "$old" "$new"
  patched=$?
  if [ "$patched" -eq 3 ]; then
    fail "PATCH CHANGED NOTHING: '$label' found no text to change"
  elif [ "$patched" -ne 0 ]; then
    fail "could not apply '$label'"
  elif ! build_driver; then
    fail "INVALID MUTANT: '$label' driver did not build"
    tail -n 20 "$work/build-driver.log"
  else
    proof_rc=0
    "$@" >"$work/mutation-check.log" 2>&1 || proof_rc=$?
    case "$proof_rc" in
      0) fail "NOT caught: $label" ;;
      1) echo "   caught: $label" ;;
      *)
        fail "INVALID MUTANT: '$label' could not be compared"
        tail -n 20 "$work/mutation-check.log"
        ;;
    esac
  fi
  if ! cp "$backup" "$file"; then
    fail "could not restore source after '$label'"
    exit 1
  fi
  restore=""
}

# expect_refused_patch LABEL FILE OLD NEW: a patch that changes nothing must be
# refused by the helper. Passes when the helper refuses it, and leaves FILE as it was.
expect_refused_patch() {
  local label="$1" file="$2" old="$3" new="$4" patch_rc
  backup="$work/refusal-$RANDOM.bak"
  if ! cp "$file" "$backup"; then
    fail "could not back up the source for '$label'"
    return 1
  fi
  restore="$file"
  apply_patch "$file" "$old" "$new"
  patch_rc=$?
  if [ "$patch_rc" -eq 3 ] && cmp -s "$backup" "$file"; then
    echo "   refused: $label"
  else
    fail "a patch that changes nothing was not refused: $label"
  fi
  if ! cmp -s "$backup" "$file" && ! cp "$backup" "$file"; then
    fail "could not restore source after '$label'"
    exit 1
  fi
  restore=""
}

# check_bytes returns 1 for a real difference and 2 when no comparison ran.
check_bytes() {
  local pair fmt triple cmp_rc
  for pair in "macho aarch64-apple-darwin" "elf aarch64-linux-gnu"; do
    set -- $pair
    fmt=$1
    triple=$2
    if [ ! -s "$work/oracle-$fmt.sorted" ]; then
      echo "missing $triple oracle"
      return 2
    fi
    if ! "$tool" cases "$WORK_NATIVE/inventory.txt" "$triple" >"$work/mut-$fmt.raw" 2>"$work/mut-$fmt.err"; then
      echo "driver failed on $triple"
      cat "$work/mut-$fmt.err"
      return 2
    fi
    if ! sort "$work/mut-$fmt.raw" >"$work/mut-$fmt.txt"; then
      echo "could not sort $triple cases"
      return 2
    fi
    cmp -s "$work/mut-$fmt.txt" "$work/oracle-$fmt.sorted"
    cmp_rc=$?
    case "$cmp_rc" in
      0) ;;
      1) return 1 ;;
      *) echo "could not compare $triple cases"; return 2 ;;
    esac
  done
  return 0
}

echo "== 7. mutation proofs"
prove_mutation "the @PAGE relocation given the @PAGEOFF kind" "$src_asm" \
  "RelocKind::A64AdrpPage21" "RelocKind::A64AddLo12" check_bytes
prove_mutation "the @PAGEOFF relocation given the @PAGE kind" "$src_asm" \
  "RelocKind::A64AddLo12" "RelocKind::A64AdrpPage21" check_bytes
prove_mutation "the Rn field shifted one place too far in the encoder" "$src_asm" \
  "reg.to_i64 * 32_i64" "reg.to_i64 * 64_i64" check_bytes
expect_refused_patch "a patch whose text is absent" "$src_asm" \
  "NO_SUCH_TEXT_IN_THE_ASSEMBLER" "x"
expect_refused_patch "a patch that leaves the text unchanged" "$src_asm" \
  "reg.to_i64 * 32_i64" "reg.to_i64 * 32_i64"

# The driver built from the unmutated source serves the rest of the run.
if ! restore_driver; then
  fail "could not restore the unmodified driver"
fi

if [ "$failures" -eq 0 ]; then
  echo "== ALL NATIVE_ASM CHECKS PASSED"
  exit 0
fi
echo "== SOME NATIVE_ASM CHECKS FAILED"
exit 1
