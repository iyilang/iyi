#!/usr/bin/env bash
# std's decoded tables are built at the first call that reads them, and a
# program's own constant only definition-site typing reads is not built
# at all.
#
#     bash bench/std_lazy_tables_exercise.sh
#
# Unicode's thirty tables, MIME's two maps, the digests' round constants
# and CRC tables, Keccak's, ML-KEM's zetas, Blowfish's initial state and
# the fixed-base tables of X25519, P-256 and ECDSA are kept by first-call
# accessors (std/lazy). As constants they were built at their
# declarations in every program whose running code may read them
# (SPEC.md III.5), so a server whose handlers may sign or fold built
# them before its first line; as class variables' initializers, in every
# program importing their modules. And a constant definition-site typing
# alone reads, which types every def of every imported module under an
# `if false`, is not built at its declaration
# (`Program#iyi_mark_reached_constants`).
#
# The count is the collector's own, not a clock: each program prints the
# bytes allocated before its first statement (`GC.stats`), and may not be
# more than one slice (64 KiB, the step the count moves in) above a
# program importing std/gc alone.
# - tables: imports every one of those modules, std/http, and a module
#   of its own whose 400 KB constant only a def nothing calls reads; its
#   running code reads tables - a category, a script, the grapheme
#   clusters, NFKC, a MIME type, a digest, a key - only when given an
#   argument, and then its count must grow by a slice, which shows the
#   count sees tables built.
# - web_start: bench/web_cores.iyi without its in-process requests, a server
#   with TLS, Bcrypt and JSON that answers nothing when not asked to
#   listen: what a real program pays to start.
# Plain and --release.
#
# Broken copies, each of which must fail its start's check: the compiler
# counting a definition probe's statements as code that runs
# (`IYI_SPAWN_BROKEN=probeused`, tables); std/unicode with a class
# variable whose initializer reads five of its tables as the module
# starts (tables); and X25519's fixed-base table an eager constant
# again, which the server's TLS handshakes may read (web_start).
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

# The server and the broken copies are made by python, and a machine can
# answer `python3` with a store stub that prints a refusal instead of
# running.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done
if [ -z "$PY" ]; then
  echo "no working python3 to make the server program and the broken copies with"
  exit 1
fi

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi${PSEP}$WORK"

# The count's step: a cache reports its bytes a slice at a time
# (`IyiHeap::SLICE`).
SLICE=65536

mkdir -p "$WORK/dep"
cat >"$WORK/dep/rare.iyi" <<'IYI'
module dep/rare

pub struct Rare
  ROWS = Array(Int32).new(100_000) { |i| i }

  def self.total : Int32
    ROWS.size
  end
end
IYI

cat >"$WORK/tables.iyi" <<'IYI'
@[Unsafe("reads a P-256 key's bytes, as the module it calls does")]
module tables

import std/gc::{GC}
import std/unicode::{Unicode}
import std/mime::{MIME}
import std/digest::{SHA256}
import std/curve25519::{X25519, Ed25519}
import std/p256::{P256PrivateKey}
import std/ecdsa
import std/mlkem
import std/password
import std/http::{Request, Response, Server}
import dep/rare::{Rare}

stats = GC.stats
puts "#{stats.bytes_since_collection} #{stats.collections}"
if Program.args.size > 0
  text = "ﬁ Ǆ ½ ℌ x\u0301"
  puts Unicode.general_category('a')
  puts Unicode.script('a')
  puts text.graphemes.size
  puts Unicode.normalize(text, Unicode::NormalizationForm::NFKC).size
  puts MIME.from_extension("html")
  puts SHA256.hexdigest("abc").size
  puts Ed25519.public_key(Array(UInt8).new(32, 7_u8)).bytesize
  key = P256PrivateKey.from_bytes(Array(UInt8).new(32, 7_u8))
  puts key.is_a?(P256PrivateKey)
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

# The server: web_cores up to its in-process requests, which read tables
# at the start on purpose, with the count printed first.
if ! SRC="$REPO/bench/web_cores.iyi" DST="$WORK/web_start.iyi" "$PY" - <<'PY'
import os, re
from pathlib import Path
src = Path(os.environ["SRC"]).read_text(encoding="utf-8")
cut = src.find("\ndef asked(")
module = re.search(r"^module bench/web_cores$", src, re.M)
imports = list(re.finditer(r"^import [^\n]*\n", src, re.M))
if cut < 0 or not module or not imports:
    raise SystemExit("bench/web_cores.iyi no longer has its module line, imports and `def asked(`")
end = imports[-1].end()
count = ('import std/gc::{GC}\n\nstats = GC.stats\n'
         'puts "#{stats.bytes_since_collection} #{stats.collections}"\n')
out = src[:module.start()] + "module web_start" + src[module.end():end] + count + src[end:cut] + "\n"
Path(os.environ["DST"]).write_text(out, encoding="utf-8")
PY
then
  echo "the server program could not be made from bench/web_cores.iyi"
  exit 1
fi

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

# check LABEL COUNT PLAIN: each "BYTES COLLECTIONS"; the program's start
# at most a slice above the plain one's, with no collection run before
# either count.
check() {
  local label="$1" t_bytes t_cols p_bytes p_cols
  read -r t_bytes t_cols <<<"$2"
  read -r p_bytes p_cols <<<"$3"
  case "$t_bytes$t_cols$p_bytes$p_cols" in
    "" | *[!0-9]*)
      echo "  $label: no count read ('$2', plain: '$3')"
      return 1
      ;;
  esac
  if [ "$t_cols" -ne 0 ] || [ "$p_cols" -ne 0 ]; then
    echo "  $label: a collection ran before the count ($t_cols, $p_cols), so the count is not the start's"
    return 1
  fi
  local said="the start counted $((t_bytes - p_bytes)) bytes more than std/gc's alone ($t_bytes, $p_bytes; at most $SLICE)"
  if [ "$t_bytes" -gt $((p_bytes + SLICE)) ]; then
    echo "  $label: $said"
    return 1
  fi
  echo "  $label: $said"
}

for mode in plain release; do
  flags=()
  [ "$mode" = release ] && flags=(--release)
  echo "== $mode: no module's start builds a table"
  if ! build "plain-$mode" plain "${flags[@]}"; then
    status=1
    continue
  fi
  plain_count="$("$WORK/plain-$mode" 2>&1)"
  for program in tables web_start; do
    if build "$program-$mode" "$program" "${flags[@]}"; then
      check "$mode $program" "$("$WORK/$program-$mode" 2>&1)" "$plain_count" || status=1
    else
      status=1
    fi
  done
  [ -x "$WORK/tables-$mode" ] || continue

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
echo "== proving the check fails when a table is built at the start again"
# caught LABEL NAME: the build NAME must fail the start's check.
caught() {
  local label="$1" name="$2"
  if check "$label" "$("$WORK/$name" 2>&1)" "$("$WORK/plain-plain" 2>&1)" >"$WORK/$name.out"; then
    echo "  $label: the check PASSED on a table built at the start"
    sed 's/^/  /' "$WORK/$name.out"
    status=1
  else
    echo "  $label caught:$(sed 's/^ *[^:]*://' "$WORK/$name.out")"
  fi
}

# patch NAME FILE OLD NEW...: std's FILE with each OLD replaced by its
# NEW, in $WORK/NAME/std/FILE.
patch() {
  local name="$1" file="$2"
  shift 2
  mkdir -p "$WORK/$name/std"
  SRC="$REPO/src/std/$file" DST="$WORK/$name/std/$file" "$PY" - "$@" <<'PY'
import os, sys
from pathlib import Path
src = Path(os.environ["SRC"]).read_text(encoding="utf-8")
pairs = sys.argv[1:]
for old, new in zip(pairs[0::2], pairs[1::2]):
    if src.count(old) != 1:
        raise SystemExit("patch site missing or not one: " + old)
    src = src.replace(old, new, 1)
Path(os.environ["DST"]).write_text(src, encoding="utf-8")
PY
}

if IYI_SPAWN_BROKEN=probeused build eager-probe tables; then
  caught "a definition probe's reads counted as the program's (probeused)" eager-probe
else
  status=1
fi

if ! patch eager-start unicode.iyi "  @@grapheme_rows = Lazy(Array(Int32)).new
" "  @@grapheme_rows = Lazy(Array(Int32)).new
  @@eager : Int32 = general_category_rows.size + compatibility_decomposition_rows.size + canonical_decomposition_rows.size + grapheme_rows.size + script_rows.size
"; then
  echo "  std/unicode's start: the patch did not apply"
  status=1
elif IYI_PATH="$WORK/eager-start${PSEP}$IYI_PATH" build eager-start-tables tables; then
  caught "std/unicode reading five tables as it starts" eager-start-tables
else
  status=1
fi

if ! patch eager-constant curve25519.iyi "  @@table = Lazy(Pointer(CurvePrecomp)).new
" "  TABLE = build
" "    @@table.get { build }
" "    TABLE
"; then
  echo "  std/curve25519's eager constant: the patch did not apply"
  status=1
elif IYI_PATH="$WORK/eager-constant${PSEP}$IYI_PATH" build eager-constant-server web_start; then
  caught "the server with X25519's base table an eager constant" eager-constant-server
else
  status=1
fi

echo
if [ "$status" -eq 0 ]; then
  echo "std's tables are built at their first read, and no module's start builds one"
else
  echo "a table is built where nothing read it"
fi
exit $status
