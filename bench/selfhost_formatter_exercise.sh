#!/usr/bin/env bash
# Fails when the iyi selfhost formatter stops agreeing with the shipped formatter.
#
# For each file in an explicit corpus list, the port's output must match the
# shipped formatter's output byte for byte, and a second pass over the port's
# own output must change nothing (idempotency).
#
# The mutation proofs verify that the parity checks are load-bearing: each
# mutation modifies a key ported mechanism, proves the patch applied, runs
# the comparison to confirm it is caught, and reverts cleanly.
#
#   bash bench/selfhost_formatter_exercise.sh
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
FMT="$REPO/src/compiler/tools/formatter.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The corpus is an explicit list of files the port currently handles byte-for-byte.
# It grows deliberately as the formatter port reaches further constructs, and fails
# if any listed file regresses.
# 136 .iyi files in the tree (19 in samples/iyi, 17 in src/iyi, 100 in src/std) are not yet in this list.
CORPUS=(
  "samples/iyi/calc.iyi"
  "samples/iyi/derive.iyi"
  "samples/iyi/files.iyi"
  "samples/iyi/format.iyi"
  "samples/iyi/hello.iyi"
  "samples/iyi/init_order.iyi"
  "samples/iyi/io.iyi"
  "samples/iyi/modules.iyi"
  "samples/iyi/socket.iyi"
  "samples/iyi/std_collections.iyi"
  "samples/iyi/std_regex.iyi"
  "samples/iyi/std_text.iyi"
  "samples/iyi/std_time.iyi"
  "samples/iyi/std_yaml.iyi"
  "samples/iyi/webapp.iyi"
  "src/std/bool.iyi"
  "src/std/iterable.iyi"
)

echo "== 1. Building the selfhost formatter exercise driver"
if ! "$IYI" build -o "$WORK/exercise" "$REPO/bench/selfhost_formatter_exercise.iyi"; then
  echo "FAILED: could not build bench/selfhost_formatter_exercise.iyi"
  exit 1
fi
echo "  built bench/selfhost_formatter_exercise.iyi successfully"

echo
echo "== 2. Parity comparison against the shipped formatter and idempotency check"

compare_corpus() {
  local driver="$1"
  local matched=0
  local total_bytes=0
  local total_files=${#CORPUS[@]}

  for rel in "${CORPUS[@]}"; do
    local src="$REPO/$rel"
    if [ ! -f "$src" ]; then
      echo "  MISSING: $rel does not exist in repository"
      return 1
    fi

    local bytes
    bytes=$(wc -c < "$src" | tr -d ' ')

    # Format with shipped formatter
    "$IYI" tool format - < "$src" > "$WORK/shipped.out" 2>/dev/null
    local shipped_rc=$?
    if [ "$shipped_rc" -ne 0 ]; then
      echo "  FAILED: shipped formatter failed on $rel"
      return 1
    fi

    # Format with selfhost port
    "$driver" "$src" > "$WORK/port_pass1.out" 2>/dev/null
    local port_rc=$?
    if [ "$port_rc" -ne 0 ]; then
      echo "  FAILED: selfhost port crashed on $rel"
      return 1
    fi

    # Parity check: port output == shipped formatter output
    if ! cmp -s "$WORK/shipped.out" "$WORK/port_pass1.out"; then
      echo "  DIVERGED: selfhost output differs from shipped formatter on $rel"
      return 1
    fi

    # Idempotency check: second pass over port output changes nothing
    "$driver" "$WORK/port_pass1.out" > "$WORK/port_pass2.out" 2>/dev/null
    local pass2_rc=$?
    if [ "$pass2_rc" -ne 0 ] || ! cmp -s "$WORK/port_pass1.out" "$WORK/port_pass2.out"; then
      echo "  NOT IDEMPOTENT: second pass changed output on $rel"
      return 1
    fi

    matched=$((matched + 1))
    total_bytes=$((total_bytes + bytes))
  done

  echo "  Parity summary: $matched/$total_files files match byte-for-byte ($total_bytes total bytes)"
  echo "  Idempotency summary: $matched/$total_files files idempotent"
  return 0
}

if ! compare_corpus "$WORK/exercise"; then
  status=1
fi

echo
echo "== 3. Mutation proofs: each one must make the comparison above fail"

prove_mutation() {
  local label="$1"
  local old="$2"
  local new="$3"
  echo "  [$label]"
  cp "$FMT" "$FMT.orig"
  python3 - "$FMT" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(path).read()
if old not in t:
    sys.exit(3)
open(path, "w").write(t.replace(old, new, 1))
PY
  local rc=$?
  if [ "$rc" -eq 3 ] || diff -q "$FMT.orig" "$FMT" >/dev/null; then
    echo "    PATCH CHANGED NOTHING: this proves nothing"
    status=1
    cp "$FMT.orig" "$FMT"; rm -f "$FMT.orig"
    return
  fi
  if "$IYI" build -o "$WORK/mut-exercise" "$REPO/bench/selfhost_formatter_exercise.iyi" >/dev/null 2>&1; then
    if compare_corpus "$WORK/mut-exercise" >/dev/null 2>&1; then
      echo "    FAILED: the comparison still passed with the mutation applied"
      status=1
    else
      echo "    caught: the formatted output diverged on corpus, as it must"
    fi
  else
    echo "    caught: the mutated formatter did not build"
  fi
  cp "$FMT.orig" "$FMT"; rm -f "$FMT.orig"
  echo "    reverted"
}

MUTATIONS_RUN=0
run_proof() {
  prove_mutation "$1" "$2" "$3"
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

echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST FORMATTER CHECKS PASSED"
else
  echo "== SELFHOST FORMATTER CHECKS FAILED"
fi
exit $status
