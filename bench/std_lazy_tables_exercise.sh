#!/usr/bin/env bash
# std's decoded tables are built only by a program whose running code
# reads them.
#
#     bash bench/std_lazy_tables_exercise.sh
#
# Unicode's thirty tables, MIME's two maps, the digests' round constants
# and CRC tables, Keccak's, ML-KEM's zetas, Blowfish's initial state and
# the fixed-base tables of X25519, P-256 and ECDSA are constants whose
# initializers decode or work them out. A constant is initialised at its
# declaration only when code that runs reads it
# (`Program#iyi_mark_reached_constants`); definition-site typing, which
# types every def of every imported module under an `if false`, made each
# of them read, and so did the class variables they were before, whose
# initializers run as their module starts.
#
# The count is the collector's own, not a clock: a program importing all
# of those modules and std/http, and one importing std/gc alone, print the
# bytes allocated before their first statement (`GC.stats`), and the first
# may not be more than one slice (64 KiB, the step the count moves in)
# above the second. Then the first reads tables - a category, a script,
# the grapheme clusters and NFKC, more than two slices of them - and its
# count must grow by a slice, which shows it sees tables being built.
# Plain and --release.
#
# Broken copies, each of which must fail the first check: the compiler
# counting a definition probe's statements as code that runs
# (`IYI_SPAWN_BROKEN=probeused`), and std/unicode with a class variable
# whose initializer reads five of its tables as the module starts.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=';'
    ;;
  *) PSEP=':' ;;
esac

# The broken copy is patched by python, and a machine can answer
# `python3` with a store stub that prints a refusal instead of running.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

# The count's step: a cache reports its bytes a slice at a time
# (`IyiHeap::SLICE`).
SLICE=65536

cat >"$WORK/tables.iyi" <<'IYI'
module tables

import std/gc::{GC}
import std/unicode::{Unicode}
import std/mime::{MIME}
import std/digest::{SHA256}
import std/curve25519::{X25519}
import std/p256
import std/ecdsa
import std/mlkem
import std/password
import std/http::{Request, Response, Server}

stats = GC.stats
puts "#{stats.bytes_since_collection} #{stats.collections}"
if Program.args.size > 0
  text = "ﬁ Ǆ ½ ℌ x\u0301"
  puts Unicode.general_category('a')
  puts Unicode.script('a')
  puts text.graphemes.size
  puts Unicode.normalize(text, Unicode::NormalizationForm::NFKC).size
  stats = GC.stats
  puts "#{stats.bytes_since_collection} #{stats.collections}"
end
IYI

cat >"$WORK/plain.iyi" <<'IYI'
module plain

import std/gc::{GC}

stats = GC.stats
puts "#{stats.bytes_since_collection} #{stats.collections}"
IYI

# build NAME PROGRAM FLAGS...: builds $WORK/NAME, or says why not.
build() {
  local name="$1" program="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$WORK/$program.iyi" >"$WORK/$name.log" 2>&1; then
    echo "  $name: build failed"
    tail -12 "$WORK/$name.log" | sed 's/^/    /'
    return 1
  fi
}

# check LABEL TABLES PLAIN: each "BYTES COLLECTIONS"; the importing
# program's start at most a slice above the plain one's, with no
# collection run before either count.
check() {
  local label="$1" t_bytes t_cols p_bytes p_cols
  read -r t_bytes t_cols <<<"$2"
  read -r p_bytes p_cols <<<"$3"
  case "$t_bytes$t_cols$p_bytes$p_cols" in
    "" | *[!0-9]*)
      echo "  $label: no count read (tables: '$2', plain: '$3')"
      return 1
      ;;
  esac
  if [ "$t_cols" -ne 0 ] || [ "$p_cols" -ne 0 ]; then
    echo "  $label: a collection ran before the count ($t_cols, $p_cols), so the count is not the start's"
    return 1
  fi
  local said="the modules' start counted $((t_bytes - p_bytes)) bytes more than std/gc's alone ($t_bytes, $p_bytes; at most $SLICE)"
  if [ "$t_bytes" -gt $((p_bytes + SLICE)) ]; then
    echo "  $label: $said"
    return 1
  fi
  echo "  $label: $said"
}

for mode in plain release; do
  flags=()
  [ "$mode" = release ] && flags=(--release)
  echo "== $mode: the modules' start builds no table"
  if ! build "tables-$mode" tables "${flags[@]}" || ! build "plain-$mode" plain "${flags[@]}"; then
    status=1
    continue
  fi
  check "$mode" "$("$WORK/tables-$mode" 2>&1)" "$("$WORK/plain-$mode" 2>&1)" || status=1

  echo "== $mode: reading tables builds them, and the count sees it"
  out="$("$WORK/tables-$mode" read 2>&1)"
  read -r b_bytes b_cols <<<"$(echo "$out" | sed -n 1p)"
  read -r a_bytes a_cols <<<"$(echo "$out" | tail -1)"
  case "$b_bytes$b_cols$a_bytes$a_cols" in
    "" | *[!0-9]*)
      echo "  $mode: no count read: $out"
      status=1
      ;;
    *)
      if [ "$a_cols" -ne "$b_cols" ]; then
        echo "  $mode: a collection ran between the counts, so the growth is unmeasured"
        status=1
      elif [ "$a_bytes" -lt $((b_bytes + SLICE)) ]; then
        echo "  $mode: reading the tables grew the count by $((a_bytes - b_bytes)) bytes, under a slice: the count does not see them built"
        status=1
      else
        echo "  $mode: reading the tables grew the count by $((a_bytes - b_bytes)) bytes (at least $SLICE)"
      fi
      ;;
  esac
done

echo
echo "== proving the check fails when the tables are built at the start again"
# caught LABEL NAME: the build NAME of the importing program must fail the
# start's check.
caught() {
  local label="$1" name="$2"
  if check "$label" "$("$WORK/$name" 2>&1)" "$("$WORK/plain-plain" 2>&1)" >"$WORK/$name.out"; then
    echo "  $label: the check PASSED on tables built at the start"
    sed 's/^/  /' "$WORK/$name.out"
    status=1
  else
    echo "  $label caught:$(sed 's/^ *[^:]*://' "$WORK/$name.out")"
  fi
}

if IYI_SPAWN_BROKEN=probeused build eager-probe tables; then
  caught "a definition probe's reads counted as the program's (probeused)" eager-probe
else
  status=1
fi

if [ -z "$PY" ]; then
  echo "  std/unicode's start: skipped, no working python3 to make the broken copy with"
else
  mkdir -p "$WORK/eager/std"
  if ! SRC="$REPO/src/std/unicode.iyi" DST="$WORK/eager/std/unicode.iyi" "$PY" - <<'PY'
import os
from pathlib import Path
src = Path(os.environ["SRC"]).read_text(encoding="utf-8")
old = "  GRAPHEME_ROWS = decode(GRAPHEME)\n"
if src.count(old) != 1:
    raise SystemExit("patch site missing or not one: " + old)
new = old + ("  @@eager : Int32 = GENERAL_CATEGORY_ROWS.size + COMPATIBILITY_DECOMPOSITION_ROWS.size +"
             " CANONICAL_DECOMPOSITION_ROWS.size + GRAPHEME_ROWS.size + SCRIPT_ROWS.size\n")
Path(os.environ["DST"]).write_text(src.replace(old, new, 1), encoding="utf-8")
PY
  then
    echo "  std/unicode's start: the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/eager${PSEP}$IYI_PATH" build eager-unicode tables; then
    caught "std/unicode reading five tables as it starts" eager-unicode
  else
    status=1
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "std's tables are built only where code that runs reads them"
else
  echo "std's tables are not all built only where read"
fi
exit $status
