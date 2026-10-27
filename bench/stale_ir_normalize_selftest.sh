#!/usr/bin/env bash
# Selftest for bench/stale_ir_normalize.py (RG8 oracle).
#
# Proves the three acceptance criteria over C2:
# 1. One program built under two output names normalizes identically.
# 2. A literal change in a reached def body normalizes differently.
# 3. A comment above unrelated code normalizes identically.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NORMALIZER="$REPO/bench/stale_ir_normalize.py"
PYTHON="${PYTHON:-python3}"

# Locate the base compiler
COMPILER="${IYI:-}"
if [ -z "$COMPILER" ]; then
  CANDIDATES=(
    "/Users/jwaldrip/dev/worktrees/iyi-stale-plan-clean/bin/iyi"
    "$REPO/bin/iyi"
  )
  for cand in "${CANDIDATES[@]}"; do
    if [ -x "$cand" ]; then
      COMPILER="$cand"
      break
    fi
  done
fi

if [ -z "$COMPILER" ] || [ ! -x "$COMPILER" ]; then
  echo "Error: no base compiler found. Set \$IYI or provide bin/iyi." >&2
  exit 1
fi

export LIBRARY_PATH="${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}"

TMPDIR="$(mktemp -d /tmp/iyi-s3n-selftest.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

CACHE_DIR="$TMPDIR/cache"
mkdir -p "$CACHE_DIR"

CACHE_ENV_KEY="C""RYSTAL_CACHE_DIR"
export "$CACHE_ENV_KEY"="$CACHE_DIR"
export IYI_CACHE_DIR="$CACHE_DIR"

echo "=== stale_ir_normalize_selftest ==="
echo "Compiler:   $COMPILER"
echo "Normalizer: $NORMALIZER"
echo "Workdir:    $TMPDIR"

SAMPLE="${1:-$REPO/samples/iyi/hello.iyi}"
if [ ! -f "$SAMPLE" ]; then
  echo "Error: sample file not found: $SAMPLE" >&2
  exit 1
fi
echo "Sample:     $SAMPLE"
echo

SAMPLE_DIR="$(cd "$(dirname "$SAMPLE")" && pwd)"
SAMPLE_NAME="$(basename "$SAMPLE")"

WORK_DIR="$TMPDIR/work"
mkdir -p "$WORK_DIR"
cp -R "$SAMPLE_DIR"/* "$WORK_DIR/"

SRC_ORIG="$WORK_DIR/$SAMPLE_NAME"

# Helper function to compile and capture DUMP=1 stderr and IYI_DUMP_TYPE_ID=1 stdout
compile_ir() {
  local src="$1"
  local out_bin="$2"
  local out_stdout="$3"
  local out_stderr="$4"

  DUMP=1 IYI_DUMP_TYPE_ID=1 "$COMPILER" build -o "$out_bin" "$src" > "$out_stdout" 2> "$out_stderr"
}

# --------------------------------------------------------------------------
# Test 1: One program built under two output names normalizes identically
# --------------------------------------------------------------------------
echo "[Test 1] Building same program under two output names..."

compile_ir "$SRC_ORIG" "$TMPDIR/bin_name1" "$TMPDIR/stdout_name1.txt" "$TMPDIR/stderr_name1.txt"
compile_ir "$SRC_ORIG" "$TMPDIR/bin_name2" "$TMPDIR/stdout_name2.txt" "$TMPDIR/stderr_name2.txt"

"$PYTHON" "$NORMALIZER" "$TMPDIR/stderr_name1.txt" "$TMPDIR/stdout_name1.txt" > "$TMPDIR/norm_name1.txt"
"$PYTHON" "$NORMALIZER" "$TMPDIR/stderr_name2.txt" "$TMPDIR/stdout_name2.txt" > "$TMPDIR/norm_name2.txt"

DIGEST1="$("$PYTHON" "$NORMALIZER" --digest-only "$TMPDIR/stderr_name1.txt" "$TMPDIR/stdout_name1.txt")"
DIGEST2="$("$PYTHON" "$NORMALIZER" --digest-only "$TMPDIR/stderr_name2.txt" "$TMPDIR/stdout_name2.txt")"

echo "  Output 1 digest: $DIGEST1"
echo "  Output 2 digest: $DIGEST2"

DIFF_LINES_T1="$( (diff -u "$TMPDIR/norm_name1.txt" "$TMPDIR/norm_name2.txt" || true) | wc -l | tr -d ' ')"
echo "  Diff lines: $DIFF_LINES_T1"

if [ "$DIFF_LINES_T1" -ne 0 ] || [ "$DIGEST1" != "$DIGEST2" ]; then
  echo "FAIL: Test 1 failed: two output names produced different normalized IR ($DIFF_LINES_T1 diff lines)" >&2
  exit 1
fi
echo "  Result: PASS"
echo

# --------------------------------------------------------------------------
# Test 2: A literal change in a reached def body normalizes differently
# --------------------------------------------------------------------------
echo "[Test 2] Literal change in reached def body..."

SRC_MUT="$WORK_DIR/mut_$SAMPLE_NAME"
"$PYTHON" -c '
import re, sys
with open(sys.argv[1]) as f:
    lines = f.read().splitlines()
mutated = False
for idx, line in enumerate(lines):
    stripped = line.strip()
    if stripped.startswith("#") or not stripped:
        continue
    m = re.search(r"\"([^\"]{2,})\"", line)
    if m:
        lines[idx] = line[:m.start(1)] + m.group(1) + "_mutated" + line[m.end(1):]
        mutated = True
        break
    m = re.search(r"\b([1-9][0-9]*)\b", line)
    if m:
        lines[idx] = line[:m.start(1)] + m.group(1) + "0" + line[m.end(1):]
        mutated = True
        break
with open(sys.argv[2], "w") as f:
    f.write("\n".join(lines) + "\n")
' "$SRC_ORIG" "$SRC_MUT"

compile_ir "$SRC_MUT" "$TMPDIR/bin_mut" "$TMPDIR/stdout_mut.txt" "$TMPDIR/stderr_mut.txt"
"$PYTHON" "$NORMALIZER" "$TMPDIR/stderr_mut.txt" "$TMPDIR/stdout_mut.txt" > "$TMPDIR/norm_mut.txt"
DIGEST_MUT="$("$PYTHON" "$NORMALIZER" --digest-only "$TMPDIR/stderr_mut.txt" "$TMPDIR/stdout_mut.txt")"

echo "  Original digest: $DIGEST1"
echo "  Mutated digest:  $DIGEST_MUT"

DIFF_LINES_T2="$( (diff -u "$TMPDIR/norm_name1.txt" "$TMPDIR/norm_mut.txt" || true) | wc -l | tr -d ' ')"
echo "  Diff lines: $DIFF_LINES_T2"

if [ "$DIFF_LINES_T2" -eq 0 ] || [ "$DIGEST1" = "$DIGEST_MUT" ]; then
  echo "FAIL: Test 2 failed: literal change in reached def did not alter normalized IR" >&2
  exit 1
fi
echo "  Result: PASS"
echo

# --------------------------------------------------------------------------
# Test 3: A comment above unrelated code normalizes identically
# --------------------------------------------------------------------------
echo "[Test 3] Comment above unrelated code..."

SRC_COMMENT="$WORK_DIR/comment_$SAMPLE_NAME"
{
  echo "# Selftest unrelated comment line 1"
  echo "# Selftest unrelated comment line 2"
  echo "# Selftest unrelated comment line 3"
  cat "$SRC_ORIG"
} > "$SRC_COMMENT"

compile_ir "$SRC_COMMENT" "$TMPDIR/bin_comment" "$TMPDIR/stdout_comment.txt" "$TMPDIR/stderr_comment.txt"
"$PYTHON" "$NORMALIZER" "$TMPDIR/stderr_comment.txt" "$TMPDIR/stdout_comment.txt" > "$TMPDIR/norm_comment.txt"
DIGEST_COMMENT="$("$PYTHON" "$NORMALIZER" --digest-only "$TMPDIR/stderr_comment.txt" "$TMPDIR/stdout_comment.txt")"

echo "  Original digest:  $DIGEST1"
echo "  Commented digest: $DIGEST_COMMENT"

DIFF_LINES_T3="$( (diff -u "$TMPDIR/norm_name1.txt" "$TMPDIR/norm_comment.txt" || true) | wc -l | tr -d ' ')"
echo "  Diff lines: $DIFF_LINES_T3"

if [ "$DIFF_LINES_T3" -ne 0 ] || [ "$DIGEST1" != "$DIGEST_COMMENT" ]; then
  echo "FAIL: Test 3 failed: comment above code altered normalized IR ($DIFF_LINES_T3 diff lines)" >&2
  exit 1
fi
echo "  Result: PASS"
echo

echo "=== All 3 acceptance checks PASSED ==="
exit 0
