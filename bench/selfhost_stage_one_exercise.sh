#!/usr/bin/env bash
# Proves stage one exists as its own executable: the whole compiler source
# under src/compiler, built by the bootstrap compiler (bin/iyi) into
# .build/iyi-stage1, dispatched through the ported command driver.
#
# The heap boundary finding (STAGE_ONE.md) killed the in-process wiring
# frame: a Crystal method cannot dispatch on an ast.iyi node, so stage one
# is a separate executable and the wiring is a process boundary.
#
# This gate measures the phase the stage-one binary reaches, holds it
# against a committed floor, and proves the gate goes red under a guarded
# mutation confirmed to change the file.
#
#   bash bench/selfhost_stage_one_exercise.sh
#
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BOOTSTRAP="$REPO/bin/iyi"
ENTRY="$REPO/src/compiler/stage1.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export LIBRARY_PATH="/opt/homebrew/opt/bdw-gc/lib:${LIBRARY_PATH:-}"
export CRYSTAL_CACHE_DIR="${CRYSTAL_CACHE_DIR:-/tmp/iyi-s1e-cache}"

echo "== 1. Building the stage-one executable from src/compiler/stage1.iyi"
cd "$REPO"
rm -f "$REPO/.build/iyi-stage1"
if ! "$BOOTSTRAP" build -o "$REPO/.build/iyi-stage1" "$ENTRY" > "$WORK/build.log" 2>&1; then
  echo "  stage-one build failed:"
  sed -n '1,20p' "$WORK/build.log"
  exit 1
fi
if [ ! -x "$REPO/.build/iyi-stage1" ]; then
  echo "  ERROR: .build/iyi-stage1 was not built"
  exit 1
fi
echo "  built .build/iyi-stage1 successfully"

echo
echo "== 2. Dependency floor on the stage-one binary itself"
libs="$(otool -L "$REPO/.build/iyi-stage1" 2>/dev/null | awk 'NR>2 {print $1}' | grep -v '^$')"
echo "$libs" | sed 's/^/    /'
if echo "$libs" | grep -qv '/usr/lib/libSystem.B.dylib'; then
  echo "  FLOOR BROKEN: the stage-one binary links more than the platform libc"
  status=1
else
  echo "  stage-one binary links only the platform libc"
fi

echo
echo "== 3. Measuring the stage-one phase against the committed floor"
# Phases: none < link < dispatch.
#   link      the binary exists, executes, and links only the platform libc
#   dispatch  version, help, tool usage, and the unknown-command refusal
#             all answer through the ported command driver
#
# Measured real state (2026-09-14): dispatch. Every command the ported
# driver serves is dispatched for real; the build verb parses its options
# and returns without producing a binary, which the driver's own design
# records as unported pipeline execution (STAGE_ONE.md 5).
STAGE1_FLOOR="dispatch"

phase_rank() {
  case "$1" in
    none)     echo 0 ;;
    link)     echo 1 ;;
    dispatch) echo 2 ;;
    *)        echo -1 ;;
  esac
}

probe_stage1() {
  local out="$WORK/probe.out"
  local ok=1
  # version answers
  "$REPO/.build/iyi-stage1" version > "$out" 2>&1 || ok=0
  grep -q "Crystal 1.22.0-dev" "$out" || ok=0
  # help answers with the command banner
  "$REPO/.build/iyi-stage1" help > "$out" 2>&1 || ok=0
  grep -q "Usage: crystal \[command\]" "$out" || ok=0
  # tool usage answers
  "$REPO/.build/iyi-stage1" tool > "$out" 2>&1 || ok=0
  grep -q "Usage: crystal tool" "$out" || ok=0
  # unknown command is refused with exit 1
  "$REPO/.build/iyi-stage1" definitely_not_a_command > "$out" 2>&1
  [ "$?" -eq 1 ] || ok=0
  grep -q "unknown command: definitely_not_a_command" "$out" || ok=0
  if [ "$ok" -eq 1 ]; then
    echo "dispatch"
  else
    echo "link"
  fi
}

measured_phase="$(probe_stage1)"
measured_rank="$(phase_rank "$measured_phase")"
floor_rank="$(phase_rank "$STAGE1_FLOOR")"

matched=0
total=1
regressions=0

if [ "$measured_rank" -ge "$floor_rank" ]; then
  printf "  %-22s %-10s %-10s %s\n" "Unit" "Floor" "Measured" "Status"
  printf "  %-22s %-10s %-10s %s\n" "stage-one exe" "$STAGE1_FLOOR" "$measured_phase" "matched"
  matched=$((matched + 1))
else
  printf "  %-22s %-10s %-10s %s\n" "stage-one exe" "$STAGE1_FLOOR" "$measured_phase" "REGRESSION"
  regressions=$((regressions + 1))
  status=1
fi
echo "  Phase summary: $matched/$total stage-one targets match or exceed committed floor ($regressions regressions)"

echo
echo "== 4. Guarded mutation proof: the gate must go red when dispatch regresses"
mutations_caught=0
mutations_run=0

mutations_run=$((mutations_run + 1))
echo "  [version banner severed from the driver]"
mkdir -p "$WORK/backup"
cp "$ENTRY" "$WORK/backup/stage1.iyi"
sed -e 's|puts CommandDriver.version_description|puts "mutated"|' \
  "$REPO/src/compiler/stage1.iyi" > "$WORK/mutated_stage1.iyi"
if cmp -s "$REPO/src/compiler/stage1.iyi" "$WORK/mutated_stage1.iyi"; then
  echo "    FAIL: patch did not change the file"
  status=1
else
  cp "$WORK/mutated_stage1.iyi" "$REPO/src/compiler/stage1.iyi"
  "$BOOTSTRAP" build -o "$REPO/.build/iyi-stage1" "$ENTRY" > "$WORK/mut_build.log" 2>&1 || true
  mut_phase="$(probe_stage1)"
  cp "$WORK/backup/stage1.iyi" "$REPO/src/compiler/stage1.iyi"
  "$BOOTSTRAP" build -o "$REPO/.build/iyi-stage1" "$ENTRY" > /dev/null 2>&1 || true
  mut_rank="$(phase_rank "$mut_phase")"
  if [ "$mut_rank" -lt "$floor_rank" ]; then
    echo "    caught: mutation caused regression ($STAGE1_FLOOR -> $mut_phase) as expected"
    mutations_caught=$((mutations_caught + 1))
  else
    echo "    FAIL: mutation did not cause regression ($mut_phase >= $STAGE1_FLOOR)"
    status=1
  fi
fi

echo "  Mutation summary: $mutations_caught/$mutations_run regressions caught"

echo
if [ "$status" -eq 0 ]; then
  echo "ALL SELFHOST STAGE ONE CHECKS PASSED"
else
  echo "SELFHOST STAGE ONE CHECKS FAILED"
fi
exit $status
