#!/usr/bin/env bash
# Exercises `std/shared_proc`: a proc any thread may call.
#
#     bash bench/std_shared_proc_exercise.sh
#
# The run (`bench/std_shared_proc_exercise.iyi`) calls SharedProcs from
# parallel tasks, plain and --release. What makes the type sound is what
# the compiler refuses, so the refusals are here: a block that captures a
# value that is not Share, a captured local assigned after the block was
# given, a SharedProc made from a proc nobody checked, and a proc forwarded
# to a parallel boundary as `&work`. Copies of the module that take away
# what refuses the first and the third must let them through.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_shared_proc_exercise.iyi" \
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
  if ! grep -q "ALL CHECKS PASSED" "$WORK/$name.out"; then
    echo "$label: missing pass sentinel"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/shared_proc exercise, plain build"
build_and_run "plain" shared-plain

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" shared-release --release >/dev/null && echo "  ALL CHECKS PASSED"

# refused <label> <file> <expected text>: `iyi build` of *file* must fail,
# saying *expected text*.
refused() {
  local label="$1" file="$2" expected="$3"
  if "$IYI" build --no-codegen "$WORK/$file" >"$WORK/$file.log" 2>&1; then
    echo "  FAIL $label: it built"
    status=1
  elif grep -qF -- "$expected" "$WORK/$file.log"; then
    echo "  $label: refused"
  else
    echo "  FAIL $label: refused, but not for this: $(grep -m1 'Error' "$WORK/$file.log")"
    status=1
  fi
}

cat >"$WORK/array.iyi" <<'IYI'
module main

import std/shared_proc::{SharedProc}

seen = [] of Int32
p = SharedProc(Int32, Int32).of { |n| seen << n; n }
puts p.call(1)
IYI
cat >"$WORK/after.iyi" <<'IYI'
module main

import std/shared_proc::{SharedProc}

factor = 3
p = SharedProc(Int32, Int32).of { |n| n * factor }
factor = 4
puts p.call(1)
IYI
cat >"$WORK/new.iyi" <<'IYI'
module main

import std/shared_proc::{SharedProc}

p = SharedProc(Int32, Int32).new(->(n : Int32) { n })
puts p.call(1)
IYI
cat >"$WORK/forward.iyi" <<'IYI'
module main

seen = [] of Int32
work = -> { seen << 1; nil }
group do |g|
  g.spawn_parallel(&work)
end
puts seen.size
IYI

echo
echo "== what the compiler refuses"
refused "a block capturing an Array" array.iyi "captures \`seen : Array(Int32)\`, which is not Share"
refused "a captured local assigned after the block was given" after.iyi "is assigned here, after the block was given"
refused "a SharedProc made from an unchecked proc" new.iyi "private method 'new'"
refused "a proc forwarded to spawn_parallel" forward.iyi "is given a proc, \`&work\`"

echo
echo "== proving the checks can fail when the module is broken"
# broken <label> <file that must then build> <python: old> <python: new>...:
# a copy of the module with each old text made new, ahead of src on the
# search path; *file*, refused above, must build against it.
broken() {
  local label="$1" file="$2"
  shift 2
  rm -rf "$WORK/patched" && mkdir -p "$WORK/patched/std"
  if ! "$PY" - "$REPO/src/std/shared_proc.iyi" "$WORK/patched/std/shared_proc.iyi" "$@" <<'PY'
import sys
src, dst, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
text = open(src).read()
for old, new in zip(pairs[::2], pairs[1::2]):
    old, new = old.replace("\\n", "\n"), new.replace("\\n", "\n")
    if text.count(old) != 1:
        sys.exit(f"patch site missing: {old!r}")
    text = text.replace(old, new, 1)
open(dst, "w", newline="\n").write(text)
PY
  then
    echo "  FAIL $label: the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build --no-codegen "$WORK/$file" >"$WORK/mut.log" 2>&1; then
    echo "  $label: caught"
  else
    echo "  FAIL $label: $file was still refused: $(grep -m1 'Error' "$WORK/mut.log")"
    status=1
  fi
}
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the broken-module proofs are unmeasured"
else
  # Either annotation alone refuses the Array: `of` checks its block, and a
  # type that owns what it holds checks the block that builds it. Both gone,
  # it is taken.
  broken "a SharedProc whose block nothing checks" array.iyi \
    "@[Share(owns: true)]\npub struct" "pub struct" \
    "  @[Share]\n  def self.of(" "  def self.of("
  broken "a SharedProc any proc can make" new.iyi \
    "  private def initialize(" "  def initialize("
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/shared_proc exercise holds"
else
  echo "the std/shared_proc exercise did not hold"
fi
exit $status
