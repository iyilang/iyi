#!/usr/bin/env bash
# Exercises `std/csv`.
#
#     bash bench/std_csv_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# the patches and oracles below are written in python, and windows answers
# `python3` with a store stub that prints and exits rather than running it, so
# the interpreter is measured here instead of assumed.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from `pwd` is `/c/...` and finds no prelude at all, and a
# scratch directory named `/tmp/tmp.X` is silently ignored on that path, so
# the patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_csv_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/csv exercise, plain build"
build_and_run "plain" csv-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/csv-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every csv section reported"
for phrase in "== parse" "== line ends and empty fields" "== reader over a string" \
  "== reader errors are values, with line and column" "== header access" "== writer" \
  "== written and read back" "== a 50 MB file, read with bounded memory"; do
  if ! grep -q "$phrase" "$WORK/csv-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" csv-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/csv-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

# The oracle: the reader and the writer driven from the command line, a
# row a line and a field `x` and its bytes in hex, so Python's rows and
# these are compared byte for byte, a row of no fields an empty line.
cat >"$WORK/oracle.iyi" <<'IYI'
module oracle

import std/csv::{CSVReader, CSVWriter, CSVError}
import std/file::{File}

def hex(field : String) : String
  digits = "0123456789abcdef"
  p = field.to_unsafe
  String.build do |io|
    io << 'x'
    i = 0
    while i < field.bytesize
      io << digits[(p[i] >> 4).to_i32]
      io << digits[(p[i] & 15_u8).to_i32]
      i = i + 1
    end
  end
end

def unhex(word : String) : String
  n = (word.bytesize - 1) // 2
  p = word.to_unsafe
  String.new(n) do |dst|
    i = 0
    while i < n
      hi = p[1 + 2 * i]
      lo = p[2 + 2 * i]
      dst[i] = (((hi > 57_u8 ? hi - 87_u8 : hi - 48_u8) << 4) | (lo > 57_u8 ? lo - 87_u8 : lo - 48_u8))
      i = i + 1
    end
  end
end

def char_of(name : String) : Char
  name == "tab" ? '\t' : name[0]
end

args = Program.args
sep = char_of(args[2])
quote = char_of(args[3])
if args[0] == "read"
  input = File.open(args[1])
  if args.size > 4
    reader = CSVReader.new(input, separator: sep, quote: quote, headers: true)
    names = reader.headers.or_panic
    puts names.map { |h| hex(h) }.join(" ")
    reader.each do |row|
      puts names.map { |h| (f = row[h]?) ? hex(f) : "-" }.join(" ")
    end.or_panic
  else
    reader = CSVReader.new(input, separator: sep, quote: quote)
    while row = reader.next_row.or_panic
      puts row.map { |f| hex(f) }.join(" ")
    end
  end
else
  sink = File.open(args[4], "w")
  ending = args[6] == "crlf" ? "\r\n" : (args[6] == "cr" ? "\r" : "\n")
  writer = CSVWriter.new(sink, separator: sep, quote: quote, quote_all: args[5] == "all", line_end: ending)
  # Each row's line is ended, so the text after the last is no row.
  lines = File.read(args[1]).split('\n')
  lines[0, lines.size - 1].each do |line|
    writer.row(line.empty? ? [] of String : line.split(' ').map { |w| unhex(w) })
  end
  sink.close
end
IYI

echo
echo "== Python's csv module, both ways"
# A corpus Python's `csv.writer` writes, read here; the same rows written
# here, read by Python's `csv.reader`. Fields are drawn from separators,
# both quotes, every line end, spaces, tabs and characters of two, three
# and four bytes; rows of none and of one empty field among them.
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the comparison with Python's csv is unmeasured"
elif ! "$IYI" build -o "$WORK/oracle" "$WORK/oracle.iyi" >"$WORK/oracle.build.log" 2>&1; then
  echo "  the oracle did not build"
  sed -n '1,8p' "$WORK/oracle.build.log"
  status=1
else
  for dialect in "comma dq minimal crlf" "semi sq all lf" "tab dq minimal cr"; do
    set -- $dialect
    "$PY" - "$WORK" "$@" <<'PY'
import csv, random, sys
work, sep, quote, quoting, ending = sys.argv[1:6]
sep = {"comma": ",", "semi": ";", "tab": "\t"}[sep]
quote = {"dq": '"', "sq": "'"}[quote]
ending = {"crlf": "\r\n", "lf": "\n", "cr": "\r"}[ending]
rng = random.Random(f"{sep}{quote}{quoting}")
pieces = ["a", "b", "Z", "0", " ", ",", ";", "\t", '"', "'", "\n", "\r\n", "\r", "ğ", "€", "😀", "é", "x y", "  "]
rows = []
for i in range(3000):
    k = rng.randrange(12)
    if k == 0:
        rows.append([])
    elif k == 1:
        rows.append([""])
    else:
        rows.append(["".join(rng.choice(pieces) for _ in range(rng.randrange(8))) for _ in range(rng.randrange(1, 7))])
def dump(rs):
    return "".join(" ".join("x" + f.encode().hex() for f in r) + "\n" for r in rs)
with open(f"{work}/py.csv", "w", newline="", encoding="utf-8") as f:
    csv.writer(f, delimiter=sep, quotechar=quote, lineterminator=ending,
               quoting=csv.QUOTE_ALL if quoting == "all" else csv.QUOTE_MINIMAL).writerows(rows)
with open(f"{work}/py.dump", "w", newline="", encoding="utf-8") as f:
    f.write(dump(rows))
PY
    names="sep=$1 quote=$2 $3 $4"
    # Assigned in a case, not read out of one in `$(...)`: macOS's bash 3.2
    # reads `;;` inside a command substitution as the end of the line.
    case $1 in comma) ch_sep="," ;; semi) ch_sep=";" ;; tab) ch_sep="tab" ;; esac
    case $2 in dq) ch_quote='"' ;; sq) ch_quote="'" ;; esac
    if ! "$WORK/oracle" read "$WORK/py.csv" "$ch_sep" "$ch_quote" >"$WORK/iyi.dump" 2>"$WORK/oracle.err"; then
      echo "  $names: Python's file was refused: $(head -1 "$WORK/oracle.err")"
      status=1
    elif ! cmp -s "$WORK/py.dump" "$WORK/iyi.dump"; then
      echo "  $names: Python's file read differently"
      diff "$WORK/py.dump" "$WORK/iyi.dump" | head -4
      status=1
    else
      echo "  $names: Python's $(wc -l <"$WORK/py.dump" | tr -d ' ') rows read as Python wrote them"
    fi
    if ! "$WORK/oracle" write "$WORK/py.dump" "$ch_sep" "$ch_quote" "$WORK/iyi.csv" "$3" "$4" 2>"$WORK/oracle.err"; then
      echo "  $names: the writer failed: $(head -1 "$WORK/oracle.err")"
      status=1
    elif ! "$PY" - "$WORK" "$ch_sep" "$ch_quote" <<'PY'
import csv, sys
work, sep, quote = sys.argv[1:4]
sep = "\t" if sep == "tab" else sep
with open(f"{work}/iyi.csv", newline="", encoding="utf-8") as f:
    rows = list(csv.reader(f, delimiter=sep, quotechar=quote, strict=True))
got = "".join(" ".join("x" + x.encode().hex() for x in r) + "\n" for r in rows)
want = open(f"{work}/py.dump", newline="", encoding="utf-8").read()
if got != want:
    raise SystemExit("python read the written rows differently")
PY
    then
      echo "  $names: the rows written here read differently in Python"
      status=1
    else
      echo "  $names: the same rows written here, read back by Python as they were"
    fi
  done
fi

echo
echo "== Python's DictReader against header access"
# A header with a repeated name, rows short and long, blank lines between:
# each row's field under each header name, or none, as `csv.DictReader`
# gives it.
if [ -z "$PY" ] || [ ! -x "$WORK/oracle" ]; then
  echo "  no python3 or no oracle, so the DictReader comparison is unmeasured"
else
  "$PY" - "$WORK" <<'PY'
import csv, random, sys
work = sys.argv[1]
rng = random.Random(4180)
pieces = ["a", "q", ",", '"', "\n", "\r\n", " ", "ğ", "😀"]
header = ["id", "name", "note", "name", "ünï", ""]
rows = [header]
for i in range(2000):
    k = rng.randrange(10)
    if k == 0:
        rows.append([])
    else:
        rows.append(["".join(rng.choice(pieces) for _ in range(rng.randrange(5))) for _ in range(rng.randrange(1, 9))])
with open(f"{work}/dict.csv", "w", newline="", encoding="utf-8") as f:
    csv.writer(f).writerows(rows)
with open(f"{work}/dict.csv", newline="", encoding="utf-8") as f:
    reader = csv.DictReader(f)
    out = [" ".join("x" + n.encode().hex() for n in reader.fieldnames)]
    for d in reader:
        out.append(" ".join("-" if d[n] is None else "x" + d[n].encode().hex() for n in reader.fieldnames))
with open(f"{work}/dict.dump", "w", newline="", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")
PY
  if ! "$WORK/oracle" read "$WORK/dict.csv" "," '"' headers >"$WORK/dict.iyi" 2>"$WORK/oracle.err"; then
    echo "  the header file was refused: $(head -1 "$WORK/oracle.err")"
    status=1
  elif ! cmp -s "$WORK/dict.dump" "$WORK/dict.iyi"; then
    echo "  rows by header name differ from DictReader's"
    diff "$WORK/dict.dump" "$WORK/dict.iyi" | head -4
    status=1
  else
    echo "  $(($(wc -l <"$WORK/dict.dump") - 1)) rows by header name, as DictReader gives them"
  fi
fi

echo
echo "== what the reader and writer refuse"
# The program's mistakes panic, each with its sentence; a document's are
# values, and `.or_panic` turns one into its message.
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/csv::{CSVReader, CSVWriter}
import std/io::{Memory}

case Program.args[0]
when "line-end-separator"
  CSVReader.new("a", separator: '\n')
when "wide-quote"
  CSVReader.new("a", quote: 'ğ')
when "same-separator-and-quote"
  CSVWriter.new(Memory.new, separator: '"')
when "bad-line-end"
  CSVWriter.new(Memory.new, line_end: "\n\n")
when "unknown-name"
  row = CSVReader.new("a,b\n1,2\n", headers: true).next.or_panic
  puts row["missing"] if row
when "no-header-row"
  CSVReader.new("a,b\n").headers
when "malformed-or-panic"
  CSVReader.new("a,b\nc\"d\n").each { |row| puts row.size }.or_panic
end
puts "accepted"
IYI
refuse() { # refuse <case> <phrase>
  if "$IYI" run "$WORK/refuse.iyi" -- "$1" >"$WORK/refuse.out" 2>&1; then
    echo "  $1 was accepted: $(tr -d '\r' <"$WORK/refuse.out" | tail -1)"
    status=1
  elif ! grep -qF -- "$2" "$WORK/refuse.out"; then
    echo "  $1 was refused without saying why: $(tr -d '\r' <"$WORK/refuse.out" | tail -1)"
    status=1
  else
    echo "  $1: $(tr -d '\r' <"$WORK/refuse.out" | grep -oF -- "$2" | head -1)"
  fi
}
refuse line-end-separator "CSVReader: the separator must be one ASCII character other than a line end, not '\\n'"
refuse wide-quote "CSVReader: the quote must be one ASCII character other than a line end, not 'ğ'"
refuse same-separator-and-quote "CSVWriter: the separator and the quote are both '\"'"
refuse bad-line-end "CSVWriter: a line ends with \"\\n\", \"\\r\\n\" or \"\\r\", not \"\\n\\n\""
refuse unknown-name "CSVRow: no column is named \"missing\"; the header is [\"a\", \"b\"]"
refuse no-header-row "CSVReader: there is no header row; the reader was made without headers: true"
refuse malformed-or-panic "csv: unexpected quote at line 2, column 2"

echo
echo "== proving the checks can fail when the module is broken"
mkdir -p "$WORK/patched/std"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the broken-module proof is unmeasured"
elif ! "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/csv.iyi").read_text()
old = 'row << take(field, flen)'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/csv.iyi").write_text(src.replace(old, 'row << ""', 1))
PY
then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_csv_exercise.iyi" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  a broken csv is caught"
fi

# Each fix undone in a copy: the exercise must fail at the check written
# for it - not at an earlier one, and not by failing to compile.
mutations=0
broken() { # broken <label> <old> <new> <phrase>
  # A binary of its own each: on Windows the last one's file can still be
  # held a moment after it ended, and the next link over it failed with
  # LNK1104.
  mutations=$((mutations + 1))
  local label="$1" phrase="$4"
  if [ -z "$PY" ]; then
    echo "  $label: no python3 on this machine, so the broken-module proof is unmeasured"
    return
  fi
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if ! OLD="$2" NEW="$3" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/csv.iyi").read_text()
old = os.environ["OLD"]
if src.count(old) != 1:
    raise SystemExit("patch site missing or not unique")
Path("$WORK/patched/std/csv.iyi").write_text(src.replace(old, os.environ["NEW"], 1))
PY
  then
    echo "  $label: the patch did not apply"
    status=1
  elif ! IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/mut-$mutations.bin" "$REPO/bench/std_csv_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the broken copy did not compile"
    sed -n '1,6p' "$WORK/mut.out"
    status=1
  elif "$WORK/mut-$mutations.bin" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  elif ! grep -qF -- "$phrase" "$WORK/mut.out"; then
    echo "  $label: failed, but not at '$phrase'"
    sed -n '1,4p' "$WORK/mut.out"
    status=1
  else
    echo "  $label: caught"
  fi
}
broken "a lone CR dropped again" 'elsif b == 10_u8 || b == 13_u8' 'elsif b == 10_u8' "ASSERTION FAILED: a lone CR ends the line"
broken "a blank line read as one empty field" 'row << take(field, flen) if row.size > 0 || flen > 0 || opened' 'row << take(field, flen)' "ASSERTION FAILED: a blank line is a row of no fields"
broken "a last quoted empty field dropped" 'if flen > 0 || row.size > 0 || opened' 'if flen > 0 || row.size > 0' "ASSERTION FAILED: a last line of one quoted empty field"
broken "a lone empty field written bare" 'io << "\"\"" if fields.size == 1 && fields[0].empty?' '' "ASSERTION FAILED: a row of one empty field is written quoted"
broken "a last row of no fields left unended" "io << '\\n' if rows.size > 0 && rows[rows.size - 1].empty?" '' "ASSERTION FAILED: a last row of no fields round trips"
broken "text after a closing quote kept" 'if i < n && src[i] != 44_u8 && src[i] != 10_u8 && src[i] != 13_u8' 'if false' "ASSERTION FAILED: text after a closing quote"
broken "a quote in an unquoted field kept" 'refuse(text, i, "unexpected quote")' 'field[flen] = b; flen = flen + 1; i = i + 1' "ASSERTION FAILED: a quote inside an unquoted field"
# The reader and the writer, each fix undone the same way.
broken "the LF of a CRLF read as a blank row" 'if b == 10_u8 && @prev_cr && fields.empty? && !touched' 'if false' "ASSERTION FAILED: a CRLF is one line end"
broken "a bare field's run carried past the separator" '(state == BARE && c == @sep)' 'false' "ASSERTION FAILED: a separator ends a bare field"
broken "the column counted in bytes" '@column = @column + 1 if (c & 0xC0_u8) != 0x80_u8' '@column = @column + 1' "ASSERTION FAILED: the column in characters, not bytes"
broken "a CRLF inside quotes counted twice" '@line = @line + 1 unless @prev_cr' '@line = @line + 1' "ASSERTION FAILED: lines inside quotes are counted, a CRLF once"
broken "a quote in a bare field kept by the reader" 'return fail(CSVError.new("csv: unexpected quote at line #{@line}, column #{@column}", @line, @column))' 'return too_long unless append(@buf + @pos, 1)' "ASSERTION FAILED: a quote inside an unquoted field is an error value"
broken "an unclosed quote read as a field" $'if state == QUOTED\n      return fail' $'if false\n      return fail' "ASSERTION FAILED: a quote still open at the end"
broken "a UTF-16 document read as UTF-8" 'if @limit >= 2 && ((p[0] == 0xFF_u8' 'if false && ((p[0] == 0xFF_u8' "ASSERTION FAILED: a UTF-16 document is an error"
broken "same_size not held" 'elsif got.size != @width' 'elsif false' "ASSERTION FAILED: same_size refuses a short row"
broken "the reader goes on after an error" $'if failed = @failed\n      return failed\n    end\n    return nil if @done\n    unless @begun' $'return nil if @done\n    unless @begun' "ASSERTION FAILED: after an error the reader answers it again"
broken "strip keeps trailing spaces" 'while n > 0 && space?(@field[n - 1])' 'while false && n > 0' "ASSERTION FAILED: strip drops trailing spaces"
broken "blank lines under a header made rows" 'next if got.empty? && @has_headers' 'next if false' "ASSERTION FAILED: rows by header name, blank lines passed over"
broken "a repeated header name answering its first column" '@index[head[i]] = i' '@index[head[i]] = i unless @index.has_key?(head[i])' "ASSERTION FAILED: a repeated header name answers its last column"
broken "the writer leaving a separator bare" 'return true if b == @sep || b == @quote' 'return true if b == @quote' "ASSERTION FAILED: a field holding the separator or a line break is quoted"
broken "the writer leaving a quote single" $'@io.write(p + from, i + 1 - from)\n        put(@quote)' '@io.write(p + from, i + 1 - from)' "ASSERTION FAILED: a quote is doubled inside quotes"
broken "the writer leaving a lone empty field bare" 'if @quote_all || lone || marked || needs_quotes?(f)' 'if @quote_all || marked || needs_quotes?(f)' "ASSERTION FAILED: the writer quotes a row of one empty field"
broken "the writer leaving end spaces bare" 'return true if p[0] == 32_u8 || p[0] == 9_u8 || p[n - 1] == 32_u8 || p[n - 1] == 9_u8' '' "ASSERTION FAILED: a field with spaces at its ends is quoted"
broken "the writer leaving a leading U+FEFF bare" "marked = @rows == 0 && i == 0 && f.starts_with?('\\uFEFF')" 'marked = false' "ASSERTION FAILED: the writer quotes only the first field for its U+FEFF"
broken "the whole stream held in memory" $'    more = io.read_bytes(CHUNK)\n    if more.bytesize == 0\n      @ended = true\n      if' $'    more = io.read_all\n    if more.bytesize == 0\n      @ended = true\n      if' "bytes alive, under 1 MiB"

echo
if [ "$status" -eq 0 ]; then
  echo "the std/csv exercise holds"
else
  echo "the std/csv exercise did not hold"
fi
exit $status
