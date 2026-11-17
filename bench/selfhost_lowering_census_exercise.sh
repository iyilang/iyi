#!/usr/bin/env bash
# Exercise census-only handling of a reached worker pool.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
"$REPO/bin/iyi" build -o "$WORK/stage1" "$REPO/src/compiler/tools/compile_native.iyi" >"$WORK/build.log" 2>&1 || { cat "$WORK/build.log"; exit 1; }
if [ "$(uname -s)" = Darwin ]; then
  codesign -v --strict "$WORK/stage1" || exit 1
fi
fixture="$REPO/bench/fixtures/preempt_pool.iyi"
"$WORK/stage1" "$fixture" -o "$WORK/strict" --pipeline typed --probe-phase >"$WORK/strict.log" 2>&1 && exit 1
[ ! -e "$WORK/strict" ] || exit 1
grep -Fq 'lower: fail: lower: visit(loop back-edge preemption checks are not ported' "$WORK/strict.log" || exit 1
"$WORK/stage1" "$fixture" -o "$WORK/census" --pipeline typed --probe-phase --keep-going >"$WORK/census.log" 2>&1 && exit 1
[ ! -e "$WORK/census" ] || exit 1
grep -Fq 'table: preempt_pool defs-lowered-clean=1 lowering-refusal-sites=1' "$WORK/census.log" || exit 1
grep -Fq 'lowering 1 owner=lowering core reason=a reached pool: loop back-edge preemption checks are not ported (hosted iyi_preempt_on?)' "$WORK/census.log" || exit 1
grep -Fq 'in IyiWorkers.start' "$WORK/census.log" || exit 1
grep -Fq 'lower: fail: lower: visit(loop back-edge preemption checks are not ported' "$WORK/census.log" || exit 1
echo 'PASS: census records one pool site and strict lowering refuses'
