#!/usr/bin/env bash
# Exercise census-only handling of a reached worker pool.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
REPO_NATIVE="$(native_path "$REPO")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
WORK="$(mktemp -d)"
WORK_NATIVE="$(native_path "$WORK")" || exit 1
trap 'rm -rf "$WORK"' EXIT
"$REPO/bin/iyi" build -o "$WORK_NATIVE/stage1$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" >"$WORK/build.log" 2>&1 || { cat "$WORK/build.log"; exit 1; }
if [ "$HOST_OS" = darwin ]; then
  codesign -v --strict "$WORK/stage1$EXE" || exit 1
else
  host_limited 'lowering census: Darwin codesign verification of the hosted-built driver requires macOS'
fi
fixture="$REPO_NATIVE/bench/fixtures/preempt_pool.iyi"
"$WORK/stage1$EXE" "$fixture" -o "$WORK_NATIVE/strict" --pipeline typed --probe-phase >"$WORK/strict.log" 2>&1
strict_status=$?
[ "$strict_status" -eq 1 ] || { cat "$WORK/strict.log"; exit 1; }
[ ! -e "$WORK/strict" ] || exit 1
grep -Fq 'lower: fail: lower: visit(loop back-edge preemption checks are not ported' "$WORK/strict.log" || exit 1
"$WORK/stage1$EXE" "$fixture" -o "$WORK_NATIVE/census" --pipeline typed --probe-phase --keep-going >"$WORK/census.log" 2>&1
census_status=$?
[ "$census_status" -eq 1 ] || { cat "$WORK/census.log"; exit 1; }
[ ! -e "$WORK/census" ] || exit 1
grep -Fq 'table: preempt_pool defs-lowered-clean=1 lowering-refusal-sites=1' "$WORK/census.log" || exit 1
grep -Fq 'lowering 1 owner=lowering core reason=a reached pool: loop back-edge preemption checks are not ported (hosted iyi_preempt_on?)' "$WORK/census.log" || exit 1
grep -Fq 'in IyiWorkers.start' "$WORK/census.log" || exit 1
grep -Fq 'lower: fail: lower: visit(loop back-edge preemption checks are not ported' "$WORK/census.log" || exit 1
echo 'PASS: census records one pool site and strict lowering refuses'
