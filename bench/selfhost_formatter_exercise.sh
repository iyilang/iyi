#!/usr/bin/env bash
# Fails when the iyi selfhost formatter stops agreeing with the hosted formatter.
#
# For each file in an explicit corpus list, the port's output must match the
# hosted formatter's output byte for byte, and a second pass over the port's
# own output must change nothing (idempotency).
#
# The mutation proofs verify that the parity checks are load-bearing: each
# mutation modifies a key ported mechanism, proves the patch applied, runs
# the comparison to confirm it is caught, and reverts cleanly.
#
#   bash bench/selfhost_formatter_exercise.sh
set -u
status=0
diverged=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if ! command -v perl >/dev/null 2>&1; then
  echo "  FAILED: perl is required for the mutation proofs" >&2
  exit 1
fi
IYI="$REPO/bin/iyi"
. "$REPO/bench/lib/mutation.sh" || exit 1
FMT="$REPO/src/compiler/tools/formatter.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO_NATIVE="$(native_path "$REPO")" || exit 1
WORK_NATIVE="$(native_path "$WORK")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
cd "$REPO" || exit 1
# The mutation helper retains only a log tail; preserve full invalid-build logs.
exec 3>&1

# The corpus is an explicit list of files the port currently handles byte-for-byte.
# It grows deliberately as the formatter port reaches further constructs, and fails
# if any listed file regresses.
# Other .iyi files in the tree are not included in this corpus.
CORPUS=(
  "bench/fixtures/formatter_macro_if.iyi"
  "bench/fixtures/formatter_macro_if_def.iyi"
  "bench/fixtures/formatter_macro_if_branches.fixture"
  "bench/fixtures/formatter_macro_if_nested.iyi"
  "bench/fixtures/formatter_macro_expression.iyi"
  "samples/iyi/calc.iyi"
  "samples/iyi/collections.iyi"
  "samples/iyi/derive.iyi"
  "samples/iyi/files.iyi"
  "samples/iyi/format.iyi"
  "samples/iyi/formatting.iyi"
  "samples/iyi/generics.iyi"
  "samples/iyi/hello.iyi"
  "samples/iyi/immutable.iyi"
  "samples/iyi/init_order.iyi"
  "samples/iyi/io.iyi"
  "samples/iyi/modules.iyi"
  "samples/iyi/sessions.iyi"
  "samples/iyi/socket.iyi"
  "samples/iyi/std_iterator.iyi"
  "samples/iyi/std_text.iyi"
  "samples/iyi/std_time.iyi"
  "samples/iyi/webapp.iyi"
  "src/std/bool.iyi"
  "src/std/deque.iyi"
  "src/std/list.iyi"
  "src/std/steppable.iyi"
  "src/std/string_scanner.iyi"
  "src/std/enum.iyi"
  "src/std/uuid.iyi"
)

echo "== 1. Building the selfhost formatter exercise driver"
if ! "$IYI" build -o "$WORK_NATIVE/exercise$EXE" "$REPO_NATIVE/bench/selfhost_formatter_exercise.iyi"; then
  echo "FAILED: could not build bench/selfhost_formatter_exercise.iyi"
  exit 1
fi
echo "  built bench/selfhost_formatter_exercise.iyi successfully"

echo
echo "== 2. Parity comparison against the hosted formatter and idempotency check"

compare_corpus() {
  local driver="$1"
  local matched=0
  local total_bytes=0
  local total_files=${#CORPUS[@]}
  local rel src native_src native_pass1 bytes

  if ! native_pass1="$(native_path "$WORK/port_pass1.out")"; then
    echo "  FAILED: cannot resolve the native pass-1 path"
    return 2
  fi
  for rel in "${CORPUS[@]}"; do
    src="$REPO/$rel"
    if [ ! -f "$src" ]; then
      echo "  MISSING: $rel does not exist in repository"
      return 2
    fi
    if ! native_src="$(native_path "$src")"; then
      echo "  FAILED: cannot resolve the native path for $rel"
      return 2
    fi

    bytes=$(wc -c < "$src" | tr -d ' ')

    if ! "$IYI" tool format - < "$src" > "$WORK/hosted.out" 2>"$WORK/hosted.err"; then
      echo "  FAILED: hosted formatter failed on $rel"
      cat "$WORK/hosted.err"
      return 2
    fi

    if ! "$driver" "$native_src" > "$WORK/port_pass1.out" 2>"$WORK/port.err"; then
      echo "  FAILED: selfhost port crashed on $rel"
      cat "$WORK/port.err"
      return 1
    fi
    cmp -s "$WORK/hosted.out" "$WORK/port_pass1.out"
    case $? in
      0) ;;
      1) echo "  DIVERGED: selfhost output differs from hosted formatter on $rel"; return 1 ;;
      *) echo "  FAILED: cannot compare formatter output on $rel"; return 2 ;;
    esac

    if ! "$driver" "$native_pass1" > "$WORK/port_pass2.out" 2>"$WORK/port.err"; then
      echo "  FAILED: selfhost port crashed on the second pass of $rel"
      cat "$WORK/port.err"
      return 1
    fi
    cmp -s "$WORK/port_pass1.out" "$WORK/port_pass2.out"
    case $? in
      0) ;;
      1) echo "  NOT IDEMPOTENT: second pass changed output on $rel"; return 1 ;;
      *) echo "  FAILED: cannot compare formatter passes on $rel"; return 2 ;;
    esac

    matched=$((matched + 1))
    total_bytes=$((total_bytes + bytes))
  done

  echo "  Parity summary: $matched/$total_files files match byte-for-byte ($total_bytes total bytes)"
  echo "  Idempotency summary: $matched/$total_files files idempotent"
  return 0
}

if ! compare_corpus "$WORK/exercise$EXE"; then
  status=1
fi

echo
echo "== 3. Standalone iyi-format path and stdin comparison"
format_matched=0
format_total=${#CORPUS[@]}
if ! "$IYI" build -o "$WORK_NATIVE/iyi-format$EXE" "$REPO_NATIVE/src/compiler/tools/format.iyi" > "$WORK/format-build.log" 2>&1; then
  echo "  FAILED to build standalone iyi-format:"
  cat "$WORK/format-build.log"
  status=1
elif [ ! -x "$WORK/iyi-format$EXE" ]; then
  echo "  FAILED: standalone iyi-format executable is missing"
  cat "$WORK/format-build.log"
  status=1
else
  for rel in "${CORPUS[@]}"; do
    src="$REPO/$rel"
    if [ ! -f "$src" ]; then
      echo "  MISSING: $rel does not exist in repository"
      status=1
      continue
    fi
    if ! native_src="$(native_path "$src")"; then
      echo "  FAILED: cannot resolve the native path for $rel"
      status=1
      continue
    fi
    if ! "$IYI" tool format - < "$src" > "$WORK/hosted.out" 2>"$WORK/hosted.err"; then
      echo "  FAILED: hosted formatter failed on $rel"
      cat "$WORK/hosted.err"
      status=1
      continue
    fi

    format_file_ok=1
    if ! "$WORK/iyi-format$EXE" "$native_src" > "$WORK/format-path.out" 2>"$WORK/format-path.err"; then
      echo "  FAILED: iyi-format path input on $rel"
      cat "$WORK/format-path.err"
      format_file_ok=0
    elif ! cmp -s "$WORK/hosted.out" "$WORK/format-path.out"; then
      echo "  DIVERGED: iyi-format path input on $rel"
      format_file_ok=0
    fi
    if ! "$WORK/iyi-format$EXE" - < "$src" > "$WORK/format-stdin.out" 2>"$WORK/format-stdin.err"; then
      echo "  FAILED: iyi-format stdin input on $rel"
      cat "$WORK/format-stdin.err"
      format_file_ok=0
    elif ! cmp -s "$WORK/hosted.out" "$WORK/format-stdin.out"; then
      echo "  DIVERGED: iyi-format stdin input on $rel"
      format_file_ok=0
    fi
    if [ "$format_file_ok" -eq 1 ]; then
      format_matched=$((format_matched + 1))
    else
      status=1
    fi
  done
fi
echo "  iyi-format: $format_matched/$format_total files identical to the hosted formatter, through a path and through stdin"

echo
echo "== 4. Mutation proofs: each one must make the comparison above fail"

# Each check rebuilds the formatter with the mutation applied and compares it
# with the hosted formatter. A failed build or oracle is an invalid mutant.
check_formatter_parity() {
  local compare_rc
  rm -f "$WORK/mut-exercise$EXE"
  if ! "$IYI" build -o "$WORK_NATIVE/mut-exercise$EXE" "$REPO_NATIVE/bench/selfhost_formatter_exercise.iyi" > "$WORK/mut-build.log" 2>&1; then
    echo "INVALID MUTANT: formatter exercise failed to build" >&3
    cat "$WORK/mut-build.log" >&3
    echo "INVALID MUTANT: formatter exercise failed to build"
    return 0
  fi
  if [ ! -x "$WORK/mut-exercise$EXE" ]; then
    echo "INVALID MUTANT: formatter exercise executable is missing" >&3
    cat "$WORK/mut-build.log" >&3
    echo "INVALID MUTANT: formatter exercise executable is missing"
    return 0
  fi
  if compare_corpus "$WORK/mut-exercise$EXE" > "$WORK/mut-compare.log" 2>&1; then
    return 0
  else
    compare_rc=$?
  fi
  if [ "$compare_rc" -eq 2 ]; then
    echo "INVALID MUTANT: formatter comparison could not run" >&3
    cat "$WORK/mut-compare.log" >&3
    echo "INVALID MUTANT: formatter comparison could not run"
    return 0
  fi
  return 1
}
# Check a particular reduced input, not whichever corpus file fails first.
# Exit 1 means this fixture detected the mutant; exit 2 means the check could
# not run. The adapter below makes an invalid check fail the proof because the
# shared mutation helper treats any nonzero status as "caught".
check_formatter_fixture() {
  local rel="$1" src="$REPO/$1" native_src compare_rc=0 driver_rc=0
  if [ ! -f "$src" ] || ! native_src="$(native_path "$src")"; then
    echo "INVALID MUTANT: fixture unavailable: $rel" >&3
    return 2
  fi
  rm -f "$WORK/mut-exercise$EXE"
  if ! "$IYI" build -o "$WORK_NATIVE/mut-exercise$EXE" "$REPO_NATIVE/bench/selfhost_formatter_exercise.iyi" > "$WORK/mut-build.log" 2>&1; then
    echo "INVALID MUTANT: formatter exercise failed to build for $rel" >&3
    cat "$WORK/mut-build.log" >&3
    return 2
  fi
  if [ ! -x "$WORK/mut-exercise$EXE" ]; then
    echo "INVALID MUTANT: formatter exercise executable is missing for $rel" >&3
    return 2
  fi
  if ! "$IYI" tool format - < "$src" > "$WORK/hosted.out" 2>"$WORK/hosted.err"; then
    echo "INVALID MUTANT: hosted formatter failed on $rel" >&3
    cat "$WORK/hosted.err" >&3
    return 2
  fi
  "$WORK/mut-exercise$EXE" "$native_src" > "$WORK/port_pass1.out" 2>"$WORK/port.err" || driver_rc=$?
  if [ "$driver_rc" -ne 0 ]; then
    case "$driver_rc" in
      126|127|137|143)
        echo "INVALID MUTANT: formatter could not run on $rel (exit $driver_rc)" >&3
        return 2 ;;
      *)
        echo "  DETECTED: $rel: mutated formatter failed (exit $driver_rc)" >&3
        return 1 ;;
    esac
  fi
  cmp -s "$WORK/hosted.out" "$WORK/port_pass1.out" || compare_rc=$?
  case "$compare_rc" in
    0) return 0 ;;
    1) echo "  DETECTED: $rel: mutated output differs from hosted formatter" >&3; return 1 ;;
    *) echo "INVALID MUTANT: cannot compare output on $rel" >&3; return 2 ;;
  esac
}

check_fixture_mutation() {
  local check_rc=0
  check_formatter_fixture "$1" || check_rc=$?
  if [ "$check_rc" -eq 2 ]; then
    return 0
  fi
  return "$check_rc"
}

run_fixture_proof() {
  prove_mutation "$1" "$FMT" "$2" "$3" -- check_fixture_mutation "$4" || status=1
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
}


MUTATIONS_RUN=0
run_proof() {
  prove_mutation "$1" "$FMT" "$2" "$3" -- check_formatter_parity || status=1
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
}

run_proof "synthetic ivar assignment removal in def body bypassed" \
  "body = remove_to_skip(node.body, to_skip)" \
  "body = node.body"

run_proof "instance variable argument skipping disabled in Arg visitor" \
  "@last_arg_is_skip = at_skip?" \
  "@last_arg_is_skip = false"

run_proof "block argument bar leading space omitted in format_block" \
  "write_token(\" \", TokenKind::OP_BAR)" \
  "write_token(TokenKind::OP_BAR)"

run_proof "do block body formatting bypasses nested indentation and end" \
  "format_nested_with_end(block.body)" \
  "accept(block.body)"

run_proof "blank line preservation in consume_newlines disabled" \
  "if raw_newlines > 1 && !next_comes_end" \
  "if false && raw_newlines > 1"

run_proof "empty array literal bracket handling bypassed in ArrayLiteral visitor" \
  "if @token.type == TokenKind::OP_LSQUARE_RSQUARE" \
  "if false && @token.type == TokenKind::OP_LSQUARE_RSQUARE"

run_proof "method def receiver formatting bypassed in Def visitor" \
  "if receiver = node.receiver" \
  "if false && (receiver = node.receiver)"

run_proof "proc notation arrow omitted in ProcNotation visitor" \
  "write_token(TokenKind::OP_MINUS_GT)" \
  "# write_token(TokenKind::OP_MINUS_GT)"

run_fixture_proof "macro-if visitor bypassed" \
  "def visit(node : MacroIf) : Bool" \
  "def visit(node : MacroIf) : Bool
    return true" \
  "bench/fixtures/formatter_macro_if.iyi"

run_fixture_proof "macro-if literal body formatting bypassed" \
  'if @inside_macro == 0 && value && value.includes?("\n")' \
  'if false && value && value.includes?("\n")' \
  "bench/fixtures/formatter_macro_if_branches.fixture"

run_fixture_proof "macro-unless branch reversal bypassed" \
  "a_then = node.else" \
  "a_then = node.then" \
  "bench/fixtures/formatter_macro_if_branches.fixture"

run_fixture_proof "nested macro expression opening token mishandled" \
  "check(@inside_macro == 0 ? TokenKind::OP_LCURLY_LCURLY : TokenKind::MACRO_EXPRESSION_START)" \
  "check(TokenKind::OP_LCURLY_LCURLY)" \
  "bench/fixtures/formatter_macro_if_nested.iyi"

run_fixture_proof "macro expression opening spacing forced" \
  'write(" ") if has_space || !node.output' \
  'write(" ")' \
  "bench/fixtures/formatter_macro_expression.iyi"
echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST FORMATTER CHECKS PASSED"
else
  echo "== SELFHOST FORMATTER CHECKS FAILED"
fi
exit $status
