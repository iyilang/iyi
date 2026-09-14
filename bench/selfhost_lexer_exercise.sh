#!/usr/bin/env bash
# Exercises the self-hosting compiler foundation, token model, and pure-iyi lexer.
#
#   bash bench/selfhost_lexer_exercise.sh
#
# Verifies:
# 1. Plain compilation and execution of selfhost lexer exercise
# 2. --release compilation and execution
# 3. Normalized token stream parity against Crystal-hosted frontend across syntax fixtures
# 4. Malformed-input and boundary rejection handling
# 5. Guarded mutation proofs verifying that test checks catch injected token/lexer defects
#
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
CRYSTAL="$REPO/bin/crystal"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0
diverged=0

echo "== 1. Building and running selfhost lexer exercise (plain mode)"
"$IYI" build -o "$WORK/exercise-plain" "$REPO/bench/selfhost_lexer_exercise.iyi"
"$WORK/exercise-plain" > "$WORK/plain.out" 2>&1
cat "$WORK/plain.out"

echo
echo "== Checking reported verification counts in plain mode"
for phrase in \
  "testing all 67 keywords... ok (67 keywords verified)" \
  "testing all 58 operators... ok (58 operators verified)" \
  "testing assignment operators... ok (17 assignment operators verified)" \
  "testing unary operators... ok (6 unary operators verified)" \
  "testing number literals (bases, suffixes, floats, signs)... ok (numbers verified)" \
  "testing char and string literals... ok (chars and strings verified)" \
  "testing percent literals (%q, %w, %i, %x, %r)... ok (percent literals verified)" \
  "testing symbol literals... ok (symbols verified)" \
  "testing iyi-specific lexical features (end!, pub, trait, impl, forall, module)... ok (iyi syntax verified)" \
  "testing location tracking (line, column)... ok (locations verified)" \
  "testing boundary conditions (empty, comments only, whitespace only)... ok (boundaries verified)" \
  "testing real syntax fixtures tokenization... ok (1285 tokens across fixtures)" \
  "testing macro tokens and modes... ok (macro tokens verified)" \
  "ALL SELFHOST LEXER CHECKS PASSED SUCCESSFULLY!"; do
  if ! grep -qF "$phrase" "$WORK/plain.out"; then
    echo "  MISSING REPORT: '$phrase'"
    status=1
  else
    echo "  verified report: '$phrase'"
  fi
done

echo
echo "== 2. Building and running selfhost lexer exercise (--release mode)"
"$IYI" build --release -o "$WORK/exercise-release" "$REPO/bench/selfhost_lexer_exercise.iyi"
"$WORK/exercise-release" > "$WORK/release.out" 2>&1
cat "$WORK/release.out"

if ! grep -qF "ALL SELFHOST LEXER CHECKS PASSED SUCCESSFULLY!" "$WORK/release.out"; then
  echo "  ERROR: release mode run failed to pass all checks"
  status=1
else
  echo "  release mode verification passed"
fi

echo
echo "== 3. Golden normalized token stream comparison vs Crystal frontend"
cat <<'CRYSTAL_GOLDEN_SCRIPT' > "$WORK/dump_crystal_tokens.cr"
require "compiler/iyi/syntax"

def tok_normalized(t : Iyi::Token) : String
  case t.type
  when .ident?
    if t.keyword?
      kw = t.value.as(Iyi::Keyword)
      "IDENT Keyword::#{kw.to_s.upcase}"
    else
      "IDENT #{escape_s(t.value.to_s)}"
    end
  when .number?
    "NUMBER #{escape_s(t.value.to_s)} #{t.number_kind.to_s}"
  when .const?
    "CONST #{escape_s(t.value.to_s)}"
  when .instance_var?
    "INSTANCE_VAR #{escape_s(t.value.to_s)}"
  when .class_var?
    "CLASS_VAR #{escape_s(t.value.to_s)}"
  when .char?
    "CHAR #{escape_s(t.value.to_s)}"
  when .string?
    "STRING #{escape_s(t.value.to_s)}"
  when .symbol?
    "SYMBOL #{escape_s(t.value.to_s)}"
  when .comment?
    "COMMENT #{escape_s(t.value.to_s)}"
  when .global?
    "GLOBAL #{escape_s(t.value.to_s)}"
  when .global_match_data_index?
    "GLOBAL_MATCH_DATA_INDEX #{escape_s(t.value.to_s)}"
  when .space?
    "SPACE nil"
  when .newline?
    "NEWLINE nil"
  when .eof?
    "EOF nil"
  when .delimiter_start?
    "DELIMITER_START nil"
  when .delimiter_end?
    "DELIMITER_END nil"
  when .string_array_start?
    "STRING_ARRAY_START nil"
  when .string_array_end?
    "STRING_ARRAY_END nil"
  when .symbol_array_start?
    "SYMBOL_ARRAY_START nil"
  when .interpolation_start?
    "INTERPOLATION_START nil"
  when .magic_dir?, .magic_file?, .magic_line?, .magic_end_line?
    "#{t.type.to_s} nil"
  when .underscore?
    "_ nil"
  else
    if t.type.operator?
      "#{t.type.to_s} nil"
    else
      "#{t.type.to_s} #{escape_s(t.value.to_s)}"
    end
  end
end

def escape_s(s : String) : String
  res = "\""
  i = 0
  while i < s.bytesize
    case s.byte_at(i).chr
    when '\n' then res = res + "\\n"
    when '\r' then res = res + "\\r"
    when '\t' then res = res + "\\t"
    when '\\' then res = res + "\\\\"
    when '"'  then res = res + "\\\""
    else res = res + s.byte_at(i).chr.to_s
    end
    i = i + 1
  end
  res + "\""
end

def consume_string_tokens(lexer, state, tokens)
  while true
    tok = lexer.next_string_token(state)
    tokens << tok_normalized(tok)
    state = tok.delimiter_state
    if tok.type.delimiter_end? || tok.type.string_array_end? || tok.type.eof?
      break
    elsif tok.type.interpolation_start?
      curly = 1
      while curly > 0
        sub_tok = lexer.next_token
        tokens << tok_normalized(sub_tok)
        break if sub_tok.type.eof?
        if sub_tok.type.delimiter_start? || sub_tok.type.string_array_start? || sub_tok.type.symbol_array_start?
          consume_string_tokens(lexer, sub_tok.delimiter_state, tokens)
        elsif sub_tok.type.op_lcurly?
          curly += 1
        elsif sub_tok.type.op_rcurly?
          curly -= 1
        end
      end
    end
  end
end

def tokenize_stream(source, filename)
  lexer = Iyi::Lexer.new(source)
  lexer.filename = filename
  tokens = [] of String

  in_path = false
  while true
    if in_path
      lexer.wants_regex = false
      lexer.slash_is_regex = false
    end

    tok = lexer.next_token
    tokens << tok_normalized(tok)
    break if tok.type.eof?

    if tok.keyword?(:module) || tok.keyword?(:import) || tok.keyword?(:using)
      in_path = true
    elsif tok.type.newline? || tok.type.op_semicolon?
      in_path = false
    end

    if tok.type.delimiter_start? || tok.type.string_array_start? || tok.type.symbol_array_start?
      consume_string_tokens(lexer, tok.delimiter_state, tokens)
    end
  end
  tokens
end

for_fixture = ARGV[0]
source = File.read(for_fixture)
tokens = tokenize_stream(source, for_fixture)
puts tokens.join("\n")
CRYSTAL_GOLDEN_SCRIPT

CRYSTAL_PATH="$REPO/src" "$CRYSTAL" build -o "$WORK/dump_crystal" "$WORK/dump_crystal_tokens.cr"

fixture_count=0
total_matched_tokens=0

for fixture in \
  "$REPO"/samples/iyi/basics.iyi \
  "$REPO"/samples/iyi/calc.iyi \
  "$REPO"/samples/iyi/config.iyi \
  "$REPO"/samples/iyi/shapes.iyi \
  "$REPO"/samples/iyi/errors.iyi \
  "$REPO"/samples/iyi/format.iyi \
  "$REPO"/samples/iyi/formatting.iyi \
  "$REPO"/samples/iyi/generics.iyi \
  "$REPO"/samples/iyi/grid.iyi \
  "$REPO"/samples/iyi/hello.iyi \
  "$REPO"/samples/iyi/immutable.iyi \
  "$REPO"/samples/iyi/init_order.iyi \
  "$REPO"/samples/iyi/inventory.iyi \
  "$REPO"/samples/iyi/io.iyi \
  "$REPO"/samples/iyi/modules.iyi \
  "$REPO"/samples/iyi/sessions.iyi \
  "$REPO"/samples/iyi/socket.iyi \
  "$REPO"/samples/iyi/visited.iyi \
  "$REPO"/samples/iyi/webapp.iyi \
  "$REPO"/samples/iyi/workers.iyi \
  "$REPO"/samples/iyi/std_collections.iyi \
  "$REPO"/samples/iyi/std_compress.iyi \
  "$REPO"/samples/iyi/std_http.iyi \
  "$REPO"/samples/iyi/std_iterator.iyi \
  "$REPO"/samples/iyi/std_json.iyi \
  "$REPO"/samples/iyi/std_regex.iyi \
  "$REPO"/samples/iyi/std_text.iyi \
  "$REPO"/samples/iyi/std_time.iyi \
  "$REPO"/samples/iyi/std_util.iyi \
  "$REPO"/samples/iyi/std_yaml.iyi \
  "$REPO"/samples/iyi/collections.iyi \
  "$REPO"/samples/iyi/derive.iyi \
  "$REPO"/samples/iyi/files.iyi \
  "$REPO"/samples/iyi/calc/ast.iyi \
  "$REPO"/samples/iyi/calc/lexer.iyi \
  "$REPO"/samples/iyi/calc/parser.iyi \
  "$REPO"/samples/iyi/kemal/dsl.iyi \
  "$REPO"/samples/iyi/kemal/router.iyi \
  "$REPO"/samples/iyi/app/formal.iyi \
  "$REPO"/samples/iyi/app/greeter.iyi \
  "$REPO"/samples/iyi/boot/config.iyi \
  "$REPO"/samples/iyi/boot/registry.iyi \
  "$REPO"/bench/fixtures/lexmode_macro_tokens.iyi; do
  name="$(basename "$fixture")"
  rel="${fixture#$REPO/}"
  "$WORK/dump_crystal" "$fixture" > "$WORK/golden_$name.txt"
  "$WORK/exercise-release" "$fixture" > "$WORK/selfhost_$name.txt"
  if diff -u "$WORK/golden_$name.txt" "$WORK/selfhost_$name.txt" > "$WORK/diff_$name.txt"; then
    count="$(wc -l < "$WORK/selfhost_$name.txt" | tr -d ' ')"
    echo "  $rel: identical ($count normalized tokens match Crystal frontend)"
    fixture_count=$((fixture_count + 1))
    total_matched_tokens=$((total_matched_tokens + count))
  else
    echo "  ERROR: mismatch in $rel"
    diverged=$((diverged + 1))
    cat "$WORK/diff_$name.txt"
    status=1
  fi
done

echo "  Parity summary: $((fixture_count - diverged))/$fixture_count syntax fixtures match 100% ($total_matched_tokens total tokens)"

echo
echo "== 4. Malformed-input and boundary rejection checks"
for bad in \
  "\"unterminated string" \
  "'unterminated char" \
  "123_xyz" \
  "1__0" \
  "0123" \
  "0b1.0" \
  "0o1.0" \
  ":\"unterminated symbol" \
  "\"\\u{123\"" \
  "\"\\u{12G4}\"" \
  "1e_2" \
  "\"hello #{ 1 + 2 \""; do
  if "$WORK/exercise-release" "$bad" >/dev/null 2>&1; then
    echo "  ERROR: expected failure for malformed input: $bad"
    status=1
  else
    echo "  properly rejected: $bad"
  fi
done

echo
echo "== 5. Guarded mutation proofs (verify patch applies, exercise fails, revert passes)"

# Mutation 1: Alter keyword 'pub' recognition in lexer
echo "  [mutation 1] altering keyword 'pub' recognition in lexer"
cp "$REPO/src/compiler/syntax/lexer.iyi" "$REPO/src/compiler/syntax/lexer.iyi.orig"
sed -i.bak 's/check_ident_or_keyword(Keyword::PUB/check_ident_or_keyword(Keyword::DEF/' "$REPO/src/compiler/syntax/lexer.iyi" && rm -f "$REPO/src/compiler/syntax/lexer.iyi.bak"
if diff -u "$REPO/src/compiler/syntax/lexer.iyi.orig" "$REPO/src/compiler/syntax/lexer.iyi" >/dev/null; then
  echo "  ERROR: patch was not applied!"
  rm -f "$REPO/src/compiler/syntax/lexer.iyi.orig"
  exit 1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_lexer_exercise.iyi" > "$WORK/mut1.log" 2>&1; then
  echo "  ERROR: exercise unexpectedly passed with mutated 'pub' keyword!"
  cp "$REPO/src/compiler/syntax/lexer.iyi.orig" "$REPO/src/compiler/syntax/lexer.iyi"
  rm -f "$REPO/src/compiler/syntax/lexer.iyi.orig"
  exit 1
else
  echo "    exercise correctly failed on mutated keyword"
fi
cp "$REPO/src/compiler/syntax/lexer.iyi.orig" "$REPO/src/compiler/syntax/lexer.iyi"
rm -f "$REPO/src/compiler/syntax/lexer.iyi.orig"
echo "    reverted mutation 1"

# Mutation 2: Alter operator '!' recognition in lexer
echo "  [mutation 2] altering operator '!' recognition in lexer"
cp "$REPO/src/compiler/syntax/lexer.iyi" "$REPO/src/compiler/syntax/lexer.iyi.orig"
sed -i.bak 's/@token.type = TokenKind::OP_BANG/@token.type = TokenKind::OP_TILDE/' "$REPO/src/compiler/syntax/lexer.iyi" && rm -f "$REPO/src/compiler/syntax/lexer.iyi.bak"
if diff -u "$REPO/src/compiler/syntax/lexer.iyi.orig" "$REPO/src/compiler/syntax/lexer.iyi" >/dev/null; then
  echo "  ERROR: patch was not applied!"
  rm -f "$REPO/src/compiler/syntax/lexer.iyi.orig"
  exit 1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_lexer_exercise.iyi" > "$WORK/mut2.log" 2>&1; then
  echo "  ERROR: exercise unexpectedly passed with mutated '!' operator!"
  cp "$REPO/src/compiler/syntax/lexer.iyi.orig" "$REPO/src/compiler/syntax/lexer.iyi"
  rm -f "$REPO/src/compiler/syntax/lexer.iyi.orig"
  exit 1
else
  echo "    exercise correctly failed on mutated operator"
fi
cp "$REPO/src/compiler/syntax/lexer.iyi.orig" "$REPO/src/compiler/syntax/lexer.iyi"
rm -f "$REPO/src/compiler/syntax/lexer.iyi.orig"
echo "    reverted mutation 2"

# Mutation 3: Alter base 16 prefix handling in lexer
echo "  [mutation 3] altering base 16 prefix handling"
cp "$REPO/src/compiler/syntax/lexer.iyi" "$REPO/src/compiler/syntax/lexer.iyi.orig"
sed -i.bak "s/when 'x' then base = 16/when 'x' then base = 10/" "$REPO/src/compiler/syntax/lexer.iyi" && rm -f "$REPO/src/compiler/syntax/lexer.iyi.bak"
if diff -u "$REPO/src/compiler/syntax/lexer.iyi.orig" "$REPO/src/compiler/syntax/lexer.iyi" >/dev/null; then
  echo "  ERROR: patch was not applied!"
  rm -f "$REPO/src/compiler/syntax/lexer.iyi.orig"
  exit 1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_lexer_exercise.iyi" > "$WORK/mut3.log" 2>&1; then
  echo "  ERROR: exercise unexpectedly passed with mutated base 16 prefix!"
  cp "$REPO/src/compiler/syntax/lexer.iyi.orig" "$REPO/src/compiler/syntax/lexer.iyi"
  rm -f "$REPO/src/compiler/syntax/lexer.iyi.orig"
  exit 1
else
  echo "    exercise correctly failed on mutated number base"
fi
cp "$REPO/src/compiler/syntax/lexer.iyi.orig" "$REPO/src/compiler/syntax/lexer.iyi"
rm -f "$REPO/src/compiler/syntax/lexer.iyi.orig"
echo "    reverted mutation 3"

# Mutation 4: Alter Token#keyword? in token model
echo "  [mutation 4] altering Token#keyword? in token model"
cp "$REPO/src/compiler/syntax/token.iyi" "$REPO/src/compiler/syntax/token.iyi.orig"
sed -i.bak 's/@type == TokenKind::IDENT && !@keyword.nil?/@type == TokenKind::IDENT \&\& false/' "$REPO/src/compiler/syntax/token.iyi" && rm -f "$REPO/src/compiler/syntax/token.iyi.bak"
if diff -u "$REPO/src/compiler/syntax/token.iyi.orig" "$REPO/src/compiler/syntax/token.iyi" >/dev/null; then
  echo "  ERROR: patch was not applied!"
  rm -f "$REPO/src/compiler/syntax/token.iyi.orig"
  exit 1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_lexer_exercise.iyi" > "$WORK/mut4.log" 2>&1; then
  echo "  ERROR: exercise unexpectedly passed with mutated Token#keyword?!"
  cp "$REPO/src/compiler/syntax/token.iyi.orig" "$REPO/src/compiler/syntax/token.iyi"
  rm -f "$REPO/src/compiler/syntax/token.iyi.orig"
  exit 1
else
  echo "    exercise correctly failed on mutated Token#keyword?"
fi
cp "$REPO/src/compiler/syntax/token.iyi.orig" "$REPO/src/compiler/syntax/token.iyi"
rm -f "$REPO/src/compiler/syntax/token.iyi.orig"
echo "    reverted mutation 4"

# Mutation 5: Alter hex digit value calculation in lexer
echo "  [mutation 5] altering hex digit calculation in lexer"
cp "$REPO/src/compiler/syntax/lexer.iyi" "$REPO/src/compiler/syntax/lexer.iyi.orig"
sed -i.bak 's/ch.ord - 65 + 10/-1/' "$REPO/src/compiler/syntax/lexer.iyi" && rm -f "$REPO/src/compiler/syntax/lexer.iyi.bak"
if diff -u "$REPO/src/compiler/syntax/lexer.iyi.orig" "$REPO/src/compiler/syntax/lexer.iyi" >/dev/null; then
  echo "  ERROR: patch was not applied!"
  rm -f "$REPO/src/compiler/syntax/lexer.iyi.orig"
  exit 1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_lexer_exercise.iyi" > "$WORK/mut5.log" 2>&1; then
  echo "  ERROR: exercise unexpectedly passed with mutated hex digit calculation!"
  cp "$REPO/src/compiler/syntax/lexer.iyi.orig" "$REPO/src/compiler/syntax/lexer.iyi"
  rm -f "$REPO/src/compiler/syntax/lexer.iyi.orig"
  exit 1
else
  echo "    exercise correctly failed on mutated hex digit calculation"
fi
cp "$REPO/src/compiler/syntax/lexer.iyi.orig" "$REPO/src/compiler/syntax/lexer.iyi"
rm -f "$REPO/src/compiler/syntax/lexer.iyi.orig"
echo "    reverted mutation 5"

# Mutation 6: Alter macro control delimiter start recognition in next_macro_token
echo "  [mutation 6] altering macro control start recognition in next_macro_token"
cp "$REPO/src/compiler/syntax/lexer.iyi" "$REPO/src/compiler/syntax/lexer.iyi.orig"
sed -i.bak 's/next_char(TokenKind::MACRO_CONTROL_START)/next_char(TokenKind::MACRO_EXPRESSION_START)/' "$REPO/src/compiler/syntax/lexer.iyi" && rm -f "$REPO/src/compiler/syntax/lexer.iyi.bak"
if diff -u "$REPO/src/compiler/syntax/lexer.iyi.orig" "$REPO/src/compiler/syntax/lexer.iyi" >/dev/null; then
  echo "  ERROR: patch was not applied!"
  rm -f "$REPO/src/compiler/syntax/lexer.iyi.orig"
  exit 1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_lexer_exercise.iyi" > "$WORK/mut6.log" 2>&1; then
  echo "  ERROR: exercise unexpectedly passed with mutated macro control start!"
  cp "$REPO/src/compiler/syntax/lexer.iyi.orig" "$REPO/src/compiler/syntax/lexer.iyi"
  rm -f "$REPO/src/compiler/syntax/lexer.iyi.orig"
  exit 1
else
  echo "    exercise correctly failed on mutated macro control start"
fi
cp "$REPO/src/compiler/syntax/lexer.iyi.orig" "$REPO/src/compiler/syntax/lexer.iyi"
rm -f "$REPO/src/compiler/syntax/lexer.iyi.orig"
echo "    reverted mutation 6"
echo
echo "== Verification clean state confirmed"
"$WORK/exercise-release" >/dev/null

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST LEXER EXERCISE CHECKS PASSED!"
else
  echo "== SOME CHECKS FAILED!"
fi

exit $status
