#!/usr/bin/env bash
# Line A's corpora through line B's lexer, parser and declaration tools.
#
# Line A (upstream PR #104) measured its own lexer, parser and declaration
# tools on the samples, the prelude, std, the parser's own source and its
# fixtures. This gate runs line B's tools on the same corpora and prints agree
# and differ counts beside line A's measured figures. Agreement is per file:
# the tool's standard output is byte-identical to the hosted front end's
# output for that file, and the tool exits 0.
#
# The golden dumpers are the inline scripts the existing gates
# already use (bench/selfhost_lexer_exercise.sh, bench/selfhost_parser_exercise.sh
# and bench/selfhost_semantic_exercise.sh). They are extracted from those gates,
# not copied, so the comparison cannot drift from the gates' own oracles.
#
# A file is agree (byte-identical output), refused (the hosted front end and line
# B refuse it with the same normalised message and exit status, counted as
# agreement in its own column), or differ (its first difference is printed with
# the oracle's node kind or message). The gate fails only when a corpus agrees on
# fewer files (agree plus refused) than its committed floor (the FLOOR table
# below). A corpus that gets better is reported so the floor can be raised; it
# does not fail.
#
#   bash bench/selfhost_linea_corpus_exercise.sh
#
# Environment (for the mutation proof only):
#   LINEA_FLOOR_BUMP=1   add one to every floor, so a healthy run must fail
#
# Output: "== N. <step>" lines, the agreement table, then
# "== ALL LINE A CORPUS CHECKS PASSED" or "== SOME LINE A CORPUS CHECKS FAILED".
# Exit status 0 or 1.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
cd "$REPO" || exit 1
IYI="$REPO/bin/iyi"
HOSTED_COMPILER="$REPO/bin/crystal"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM
REPO_NATIVE="$(native_path "$REPO")"
WORK_NATIVE="$(native_path "$WORK")"
LC_ALL=C
export LC_ALL
export IYI_CACHE_DIR="$WORK_NATIVE/cache" IYI_PATH="$REPO_NATIVE/src"
status=0
RESULTS="$WORK/results.tsv"
: > "$RESULTS"

# The committed floors: files that agree per (tool, corpus). Raise them when the
# table shows a corpus getting better; never lower one.
floor_of() {
  case "$1:$2" in
    lexer:samples)         echo 28 ;;
    lexer:prelude)         echo 20 ;;
    lexer:std)             echo 126 ;;
    lexer:self)            echo 54 ;;
    lexer:fixtures)        echo 15 ;;
    parser:samples)        echo 28 ;;
    parser:prelude)        echo 20 ;;
    parser:std)            echo 126 ;;
    parser:self)           echo 54 ;;
    parser:fixtures)       echo 15 ;;
    declarations:samples)  echo 5 ;;
    declarations:prelude)  echo 10 ;;
    declarations:std)      echo 2 ;;
    declarations:self)     echo 1 ;;
    declarations:fixtures) echo 12 ;;
    *)                     echo 0 ;;
  esac
}

# Line A's measured figures from upstream PR #104 (their denominators where the
# PR states them; "n/a" where it did not measure the cell).
linea_figure() {
  case "$1:$2" in
    parser:samples)        echo "27 of 27" ;;
    parser:prelude)        echo "17 of 17" ;;
    parser:std)            echo "67 of 67" ;;
    parser:self)           echo "identical" ;;
    lexer:samples)         echo "6 agree (denominator not stated)" ;;
    declarations:samples)  echo "23 agree (denominator not stated)" ;;
    declarations:prelude)  echo "14 of 15" ;;
    declarations:std)      echo "31 of 35" ;;
    *)                     echo "n/a" ;;
  esac
}

extract_golden() {
  sed -n "/^cat <<'[A-Z_]*GOLDEN_SCRIPT'/,/^[A-Z_]*GOLDEN_SCRIPT\$/p" "$1" | sed '1d;$d' > "$2"
}

echo "== 1. Building line B's lexer, parser and declaration tools and their golden dumpers"
extract_golden "$REPO/bench/selfhost_lexer_exercise.sh" "$WORK/dump_lexer.cr"
extract_golden "$REPO/bench/selfhost_parser_exercise.sh" "$WORK/dump_parser.cr"
extract_golden "$REPO/bench/selfhost_semantic_exercise.sh" "$WORK/dump_decls.cr"
for pair in "$WORK/dump_lexer.cr" "$WORK/dump_parser.cr" "$WORK/dump_decls.cr"; do
  if [ ! -s "$pair" ]; then
    echo "  FAILED to extract a Crystal golden dumper from its gate: $pair"
    exit 1
  fi
done
"$IYI" build -o "$WORK_NATIVE/lexer$EXE" "$REPO_NATIVE/bench/selfhost_lexer_exercise.iyi" > "$WORK/lexer_build.log" 2>&1 \
  || { cat "$WORK/lexer_build.log"; echo "  FAILED to build the lexer tool"; exit 1; }
"$IYI" build -o "$WORK_NATIVE/parser$EXE" "$REPO_NATIVE/bench/selfhost_parser_exercise.iyi" > "$WORK/parser_build.log" 2>&1 \
  || { cat "$WORK/parser_build.log"; echo "  FAILED to build the parser tool"; exit 1; }
"$IYI" build -o "$WORK_NATIVE/decls$EXE" "$REPO_NATIVE/bench/selfhost_semantic_exercise.iyi" > "$WORK/decls_build.log" 2>&1 \
  || { cat "$WORK/decls_build.log"; echo "  FAILED to build the declaration tool"; exit 1; }
CRYSTAL_PATH="$REPO_NATIVE/src" "$HOSTED_COMPILER" build -o "$WORK_NATIVE/golden_lexer$EXE" "$WORK_NATIVE/dump_lexer.cr" > "$WORK/golden_lexer.log" 2>&1 \
  || { cat "$WORK/golden_lexer.log"; echo "  FAILED to build the lexer golden dumper"; exit 1; }
CRYSTAL_PATH="$REPO_NATIVE/src" "$HOSTED_COMPILER" build -o "$WORK_NATIVE/golden_parser$EXE" "$WORK_NATIVE/dump_parser.cr" > "$WORK/golden_parser.log" 2>&1 \
  || { cat "$WORK/golden_parser.log"; echo "  FAILED to build the parser golden dumper"; exit 1; }
LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" CRYSTAL_PATH="$REPO_NATIVE/src" \
  "$HOSTED_COMPILER" build -Di_know_what_im_doing -o "$WORK_NATIVE/golden_decls$EXE" "$WORK_NATIVE/dump_decls.cr" > "$WORK/golden_decls.log" 2>&1 \
  || { cat "$WORK/golden_decls.log"; echo "  FAILED to build the declaration golden dumper"; exit 1; }
echo "  built: lexer, parser and declaration tools; three golden dumpers"

# The message a refusal ends with, normalised so that the port's diagnostic and
# the oracle's exception read as one text. The port prints
# `iyi: panic: Syntax error in <file>:<line>:<col>: <message>` and the oracle prints
# the bare `<message>` or `Error: <message>`; the location, the panic prefix, the
# error prefix and the exception class suffix are removed.
refusal_message() {
  awk 'NF && /[Ee]rror|xception|panic/ { print; found = 1; exit } NF && first == "" { first = $0 } END { if (!found) print first }' "$1" \
    | sed -e 's/^.*Syntax error in [^:]*:[0-9]*:[0-9]*: //' -e 's/^.*panic: //' -e 's/^.*[Ee]rror: //' \
          -e 's/^Unhandled exception: //' -e 's/ ([A-Za-z:_]*)[[:space:]]*$//' -e 's/[[:space:]]*$//'
}

# One file: run line B's tool and the golden dumper, then record one of
# agree (both succeed with byte-identical output), refused (both refuse with the
# same normalised message and the same exit status: the same refusal, counted as
# agreement in its own column), or differ. A differing file records its first
# difference: the oracle's line (its node kind or message) beside line B's.
compare() {
  tool="$1"
  corpus="$2"
  rel="$3"
  case "$tool" in
    lexer)        mine="$WORK/lexer$EXE";  golden="$WORK/golden_lexer$EXE" ;;
    parser)       mine="$WORK/parser$EXE"; golden="$WORK/golden_parser$EXE" ;;
    declarations) mine="$WORK/decls$EXE";  golden="$WORK/golden_decls$EXE" ;;
  esac
  "$mine" "$rel" > "$WORK/mine.out" 2> "$WORK/mine.err"; mine_rc=$?
  IYI_PATH="$REPO_NATIVE/src" "$golden" "$rel" > "$WORK/golden.out" 2> "$WORK/golden.err"; golden_rc=$?
  detail=""
  if [ "$mine_rc" -eq 0 ] && [ "$golden_rc" -eq 0 ] && cmp -s "$WORK/mine.out" "$WORK/golden.out"; then
    verdict=agree
  elif [ "$mine_rc" -ne 0 ] && [ "$golden_rc" -ne 0 ] && [ "$mine_rc" -eq "$golden_rc" ] \
       && [ "$(refusal_message "$WORK/mine.err")" = "$(refusal_message "$WORK/golden.err")" ]; then
    verdict=refused
  else
    verdict=differ
    if [ "$mine_rc" -ne 0 ] || [ "$golden_rc" -ne 0 ]; then
      detail="port exit $mine_rc: $(refusal_message "$WORK/mine.err") | oracle exit $golden_rc: $(refusal_message "$WORK/golden.err")"
    else
      line=$(cmp "$WORK/mine.out" "$WORK/golden.out" 2>/dev/null | sed -n 's/.*line \([0-9][0-9]*\).*/\1/p')
      if [ -n "$line" ]; then
        detail="line $line: oracle [$(sed -n "${line}p" "$WORK/golden.out")] | port [$(sed -n "${line}p" "$WORK/mine.out")]"
      else
        detail="output length differs: port $(wc -l < "$WORK/mine.out" | tr -d ' ') lines, oracle $(wc -l < "$WORK/golden.out" | tr -d ' ') lines"
      fi
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$tool" "$corpus" "$rel" "$verdict" "$detail" >> "$RESULTS"
}

echo
echo "== 2. Running every tool over every corpus, file by file"
corpora() {
  for f in samples/iyi/*.iyi; do printf 'samples\t%s\n' "$f"; done
  for f in src/iyi/*.iyi; do printf 'prelude\t%s\n' "$f"; done
  for f in src/std/*.iyi; do printf 'std\t%s\n' "$f"; done
  find src/compiler -name '*.iyi' | sort | while IFS= read -r f; do printf 'self\t%s\n' "$f"; done
  for f in bench/fixtures/linea/parser/*.iyi bench/fixtures/linea/semantic/*.iyi; do printf 'fixtures\t%s\n' "$f"; done
}
corpora > "$WORK/corpora.tsv"
while IFS="$(printf '\t')" read -r corpus rel; do
  for tool in lexer parser declarations; do
    compare "$tool" "$corpus" "$rel"
  done
done < "$WORK/corpora.tsv"
echo "  $(wc -l < "$RESULTS" | tr -d ' ') tool-file runs"

echo
echo "== 3. Agreement per tool and corpus, beside line A's measured figures (PR #104)"
echo "  agreeing = agree + refused (the same refusal on both sides); the floor applies to agreeing"
printf '  %-13s %-9s %6s %6s %8s %6s %6s  %-6s  %s\n' tool corpus files agree refused differ floor verdict "line A (PR #104)"
fails=0
for tool in lexer parser declarations; do
  for corpus in samples prelude std self fixtures; do
    total=$(awk -F'\t' -v t="$tool" -v c="$corpus" '$1 == t && $2 == c' "$RESULTS" | wc -l | tr -d ' ')
    agree=$(awk -F'\t' -v t="$tool" -v c="$corpus" '$1 == t && $2 == c && $4 == "agree"' "$RESULTS" | wc -l | tr -d ' ')
    refused=$(awk -F'\t' -v t="$tool" -v c="$corpus" '$1 == t && $2 == c && $4 == "refused"' "$RESULTS" | wc -l | tr -d ' ')
    differ=$((total - agree - refused))
    agreeing=$((agree + refused))
    floor=$(floor_of "$tool" "$corpus")
    if [ "${LINEA_FLOOR_BUMP:-0}" = 1 ]; then
      floor=$((floor + 1))
    fi
    if [ "$total" -eq 0 ]; then
      verdict="empty"
    elif [ "$agreeing" -lt "$floor" ]; then
      verdict="BELOW"
      fails=$((fails + 1))
    elif [ "$agreeing" -gt "$floor" ]; then
      verdict="better"
    else
      verdict="ok"
    fi
    printf '  %-13s %-9s %6s %6s %8s %6s %6s  %-6s  %s\n' "$tool" "$corpus" "$total" "$agree" "$refused" "$differ" "$floor" "$verdict" "$(linea_figure "$tool" "$corpus")"
  done
done

echo
echo "== 4. Files that differ, by tool: the oracle's node kind or message at the first difference"
awk -F'\t' '$4 == "differ" { printf "  %s %s %s\n      %s\n", $1, $2, $3, $5 }' "$RESULTS"

echo
echo "== 5. Floor check"
if [ "$fails" -gt 0 ]; then
  echo "  $fails corpus cell(s) agree on fewer files than their committed floor"
  status=1
else
  echo "  every corpus meets its committed floor"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL LINE A CORPUS CHECKS PASSED"
else
  echo "== SOME LINE A CORPUS CHECKS FAILED"
fi
exit "$status"
