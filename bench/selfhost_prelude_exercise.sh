#!/usr/bin/env bash
# Proves that the pure iyi self-host compiler tool (iyi-compile) compiles
# the real prelude files (src/iyi/*.iyi), measures the compilation phase
# reached by each file (parse, semantic, codegen, object, link), enforces
# a committed floor per file to prevent regressions, and proves the gate can
# fail under guarded mutation.
#
#   bash bench/selfhost_prelude_exercise.sh
#
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export LIBRARY_PATH="/opt/homebrew/opt/bdw-gc/lib:${LIBRARY_PATH:-}"
export CRYSTAL_CACHE_DIR="${CRYSTAL_CACHE_DIR:-/tmp/iyi-pdr-cache}"

echo "== 1. Building self-host compile tool"
cd "$REPO"
rm -f "$REPO/.build/iyi-compile"
make iyi-compile

if [ ! -x "$REPO/.build/iyi-compile" ]; then
  echo "  ERROR: .build/iyi-compile was not built"
  exit 1
fi
echo "  built .build/iyi-compile successfully"

echo
echo "== 2. Measuring prelude compilation phases against committed floor"

# Committed floor per prelude file: measured real state, not assumed.
# 0 = none, 1 = parse, 2 = semantic, 3 = codegen, 4 = object, 5 = link
file_floor() {
  case "$1" in
    "array.iyi")       echo "object" ;;
    "atomic.iyi")      echo "object" ;;
    "concurrency.iyi") echo "codegen" ;;
    "enum.iyi")        echo "object" ;;
    "file.iyi")        echo "object" ;;
    "float.iyi")       echo "codegen" ;;
    "hash.iyi")        echo "object" ;;
    "io.iyi")          echo "object" ;;
    "macros.iyi")      echo "object" ;;
    "number.iyi")      echo "object" ;;
    "object.iyi")      echo "object" ;;
    "prelude.iyi")     echo "object" ;;
    "primitives.iyi")  echo "link" ;;
    "range.iyi")       echo "object" ;;
    "set.iyi")         echo "object" ;;
    "string.iyi")      echo "object" ;;
    "thread.iyi")      echo "link" ;;
    *)                 echo "none" ;;
  esac
}

phase_rank() {
  case "$1" in
    none)     echo 0 ;;
    parse)    echo 1 ;;
    semantic) echo 2 ;;
    codegen)  echo 3 ;;
    object)   echo 4 ;;
    link)     echo 5 ;;
    *)        echo -1 ;;
  esac
}

probe_one_file() {
  local target="$1"
  local base
  base="$(basename "$target")"
  local log="$WORK/probe_${base}.log"
  set +e
  "$REPO/.build/iyi-compile" --probe-phase "$target" > "$log" 2>&1
  set -e
  if grep -qF "[phase] link: pass" "$log"; then
    echo "link"
  elif grep -qF "[phase] object: pass" "$log"; then
    echo "object"
  elif grep -qF "[phase] codegen: pass" "$log"; then
    echo "codegen"
  elif grep -qF "[phase] semantic: pass" "$log"; then
    echo "semantic"
  elif grep -qF "[phase] parse: pass" "$log"; then
    echo "parse"
  else
    echo "none"
  fi
}

printf "  %-18s %-6s %-10s %-10s %s\n" "File" "Lines" "Floor" "Measured" "Status"
printf "  %-18s %-6s %-10s %-10s %s\n" "----------------" "-----" "----------" "----------" "------"

matched=0
total=0
regressions=0

for file_path in "$REPO"/src/iyi/*.iyi; do
  [ -f "$file_path" ] || continue
  total=$((total + 1))
  base="$(basename "$file_path")"
  lines="$(wc -l < "$file_path" | tr -d ' ')"
  floor="$(file_floor "$base")"
  floor_rank="$(phase_rank "$floor")"
  measured="$(probe_one_file "$file_path")"
  measured_rank="$(phase_rank "$measured")"

  if [ "$measured_rank" -lt "$floor_rank" ]; then
    printf "  %-18s %-6s %-10s %-10s %s\n" "$base" "$lines" "$floor" "$measured" "REGRESSION"
    regressions=$((regressions + 1))
    status=1
  elif [ "$measured_rank" -gt "$floor_rank" ]; then
    printf "  %-18s %-6s %-10s %-10s %s\n" "$base" "$lines" "$floor" "$measured" "IMPROVED"
    matched=$((matched + 1))
  else
    printf "  %-18s %-6s %-10s %-10s %s\n" "$base" "$lines" "$floor" "$measured" "matched"
    matched=$((matched + 1))
  fi
done

echo "  Phase summary: $matched/$total prelude files match or exceed committed floor ($regressions regressions)"

echo
echo "== 3. Guarded mutation proofs: verifying the gate goes red when a file regresses"

mutations_caught=0
mutations_run=0

prove_fails() {
  local label="$1"
  local file="$2"
  local script="$3"
  local expected_floor="${4:-codegen}"

  mutations_run=$((mutations_run + 1))
  echo "  [$label]"
  # Need to reference $REPO/src/iyi/. so mutation_anchors.py discovers roots
  mkdir -p "$WORK/backup_iyi"
  cp -R "$REPO/src/iyi/." "$WORK/backup_iyi/"
  sed -e "$script" "$REPO/src/iyi/$file" > "$WORK/mutated_$file"
  if cmp -s "$REPO/src/iyi/$file" "$WORK/mutated_$file"; then
    echo "    FAIL: patch did not change file: $label"
    status=1
    return
  fi

  # Apply mutation to real file
  cp "$WORK/mutated_$file" "$REPO/src/iyi/$file"
  local mut_phase
  mut_phase="$(probe_one_file "$REPO/src/iyi/$file")"
  local mut_rank
  mut_rank="$(phase_rank "$mut_phase")"
  local floor_rank
  floor_rank="$(phase_rank "$expected_floor")"

  # Always restore immediately
  cp "$WORK/backup_iyi/$file" "$REPO/src/iyi/$file"

  if [ "$mut_rank" -lt "$floor_rank" ]; then
    echo "    caught: mutation caused regression ($expected_floor -> $mut_phase) as expected"
    mutations_caught=$((mutations_caught + 1))
  else
    echo "    FAIL: mutation did not cause regression ($mut_phase >= $expected_floor)"
    status=1
  fi
}

prove_fails "syntax corruption in set regresses below codegen floor" \
  "set.iyi" \
  's/class Set/class %%%/' \
  "codegen"

prove_fails "semantic corruption in set regresses below codegen floor" \
  "set.iyi" \
  's/@entries : Hash(T, Bool)/@entries : UndefinedType12345/' \
  "codegen"

prove_fails "syntax corruption in hash regresses below object floor" \
  "hash.iyi" \
  's/class Hash/class %%%/' \
  "object"

prove_fails "syntax corruption in range regresses below object floor" \
  "range.iyi" \
  's/struct Range/struct %%%/' \
  "object"

prove_fails "syntax corruption in enum regresses below codegen floor" \
  "enum.iyi" \
  's/struct Enum/struct %%%/' \
  "codegen"

prove_fails "syntax corruption in primitives regresses below link floor" \
  "primitives.iyi" \
  's/struct Symbol/struct %%%/' \
  "link"
prove_fails "syntax corruption in atomic regresses below object floor" \
  "atomic.iyi" \
  's/struct Atomic/struct %%%/' \
  "object"

prove_fails "syntax corruption in prelude regresses below object floor" \
  "prelude.iyi" \
  's|require "./primitives"|require %%%|' \
  "object"

prove_fails "semantic corruption in prelude regresses below object floor" \
  "prelude.iyi" \
  's/@proc : Proc(Nil)/@proc : UndefinedType9876/' \
  "object"

echo "  Mutation summary: $mutations_caught/$mutations_run regressions caught"

echo
if [ "$status" -eq 0 ]; then
  echo "ALL SELFHOST PRELUDE CHECKS PASSED!"
else
  echo "SOME SELFHOST PRELUDE CHECKS FAILED"
  exit 1
fi
