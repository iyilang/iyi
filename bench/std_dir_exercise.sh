#!/usr/bin/env bash
# Exercises `std/dir`.
#
#     bash bench/std_dir_exercise.sh
#
# Proves the exercise holds plain and --release, that broken dot-entry filtering
# and a dead glob matcher are caught, and what directory operations refuse:
# opening non-existent paths or files, deleting non-empty or non-existent
# directories, creating existing directories, mkdir_p through a file, and
# operating on closed directory handles.
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
WORK="$(cd "$WORK" && pwd -P)"
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
export TEST_SANDBOX="$WORK/sandbox"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_dir_exercise.iyi" \
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

echo "== the std/dir exercise, plain build"
build_and_run "plain" dir-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/dir-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every dir section reported"
for phrase in "== create, exists and file paths" \
              "== nested creation with mkdir_p" \
              "== list entries and dot entries policy" \
              "== glob star, recursive, hidden, and no-match" \
              "== current working directory and cd" \
              "== delete empty and non-empty directories" \
              "== a directory read across a collection"; do
  if ! grep -q "$phrase" "$WORK/dir-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    if ! grep -q "== windows roots, drives" "$WORK/dir-plain.out" 2>/dev/null; then
      echo "  missing section: == windows roots, drives"
      status=1
    fi
    ;;
esac
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" dir-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/dir-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
mkdir -p "$WORK/patched/std"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the broken-module proof is unmeasured"
elif ! "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/dir.iyi").read_text()
old = 'if entry != "." && entry != ".."'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/dir.iyi").write_text(src.replace(old, 'if true', 1))
PY
then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_dir_exercise.iyi" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  broken dot entry filtering is caught"
fi

echo
echo "== proving glob is caught when the matcher is dead"
mkdir -p "$WORK/patched_glob/std"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the broken-module proof is unmeasured"
elif ! "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/dir.iyi").read_text()
old = "next unless File.match?(name, seg)"
if old not in src:
    raise SystemExit("glob patch site missing")
Path("$WORK/patched_glob/std/dir.iyi").write_text(src.replace(old, "next", 1))
PY
then
  echo "  the glob patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched_glob${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_dir_exercise.iyi" >"$WORK/mut_glob.out" 2>&1; then
  echo "  the exercise PASSED on a dead glob matcher"
  status=1
else
  echo "  dead glob matcher is caught"
fi

echo
echo "== proving the other glob and walk checks can fail"
# dir_broken <label> <name> <old> <new> <phrase>: the exercise built against
# a copy with one change, under a clock - a freed directory buffer is a
# walk that never ends - and it must fail at the check that names it, or,
# for the walk, not finish.
dir_broken() {
  if [ -z "$PY" ]; then
    echo "  $1: no python3 on this machine, so the proof is unmeasured"
    return
  fi
  mkdir -p "$WORK/$2/std"
  if ! OLD="$3" NEW="$4" "$PY" - "$REPO/src/std/dir.iyi" "$WORK/$2/std/dir.iyi" <<'PY'
import os, sys
src = open(sys.argv[1]).read()
assert src.count(os.environ["OLD"]) == 1
open(sys.argv[2], "w").write(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  $1: the patch did not apply"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$2${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/$2/program" "$REPO/bench/std_dir_exercise.iyi" >"$WORK/$2/build.log" 2>&1; then
    echo "  $1: the broken copy did not compile"
    sed -n '1,6p' "$WORK/$2/build.log" | sed 's/^/    /'
    status=1
    return
  fi
  timeout 120 "$WORK/$2/program" >"$WORK/$2/out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $1: the exercise PASSED on a broken module"
    status=1
  elif [ "$code" -eq 124 ] || grep -q "$5" "$WORK/$2/out"; then
    echo "  $1: caught"
  else
    echo "  $1: failed, but not at its check"
    tail -3 "$WORK/$2/out" | sed 's/^/    /'
    status=1
  fi
}
dir_broken "braces left unexpanded" no_braces '      elsif c == 123_u8' '      elsif c == 0_u8' "glob: braces choose among names"
dir_broken "a trailing separator ignored" no_tail '      tail = glob_sep?(bytes[n - 1]) ? sep : nil' '      tail = nil' "glob: a trailing separator answers directories"
dir_broken "** into hidden directories" hidden_walk '      yield name unless name.starts_with?('"'"'.'"'"')' '      yield name' "glob \* skips hidden names"
# Linux only. On Windows a freed find buffer is rewritten by FindNextFileW
# right before every name is read out of it, so the names stay right and
# the damage lands on whatever the block was handed to next: the walk check
# passed on a broken copy there.
case "$(uname -s)" in
  Linux)
    dir_broken "a directory buffer the collector does not scan" stream_atomic '      stream = Pointer(Pointer(UInt8)).malloc(4_u64).as(Pointer(Int64))' '      stream = Pointer(Int64).malloc(4_u64)' "a walk across collections reads its own" ;;
esac

echo
echo "== what dir operations refuse"
refuses() { # refuses <label> <name> <phrase> <code>
  local label="$1" name="$2" phrase="$3"
  shift 3
  cat > "$WORK/$name.iyi" <<EOF
import std/dir::{Dir}
$*
EOF
  if IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$WORK/$name.iyi" >"$WORK/$name.out" 2>&1; then
    echo "  $label: accepted invalid input"
    status=1
  elif ! grep -q "$phrase" "$WORK/$name.out"; then
    echo "  $label: failed without the expected diagnostic ($phrase)"
    sed 's/^/    /' "$WORK/$name.out"
    status=1
  else
    echo "  $label refuses with $phrase"
  fi
}

refuses "open a missing directory" open_missing "Cannot open directory" \
  'Dir.open("'"$WORK"'/missing_dir_refusal")'

refuses "open a regular file as a directory" open_file "Cannot open directory" \
  'File.write("'"$WORK"'/file_refusal.txt", "data"); Dir.open("'"$WORK"'/file_refusal.txt")'

refuses "delete a non-empty directory" delete_non_empty "Cannot remove directory" \
  'Dir.mkdir("'"$WORK"'/non_empty_refusal"); File.write("'"$WORK"'/non_empty_refusal/a.txt", "x"); Dir.delete("'"$WORK"'/non_empty_refusal")'

refuses "delete a missing directory" delete_missing "Cannot remove directory" \
  'Dir.delete("'"$WORK"'/missing_dir_to_delete")'

refuses "mkdir an existing directory" mkdir_existing "Cannot create directory" \
  'Dir.mkdir("'"$WORK"'/already_created"); Dir.mkdir("'"$WORK"'/already_created")'

refuses "mkdir_p through a regular file" mkdir_p_file "Cannot create directory" \
  'File.write("'"$WORK"'/mkdir_p_blocker", "x"); Dir.mkdir_p("'"$WORK"'/mkdir_p_blocker/child")'

refuses "open a path containing a NUL byte" open_nul "path contains a NUL byte" \
  'Dir.open("'"$WORK"'" + "/abc\u0000def")'

refuses "cd to a missing directory" cd_missing "Cannot change directory to" \
  'Dir.cd("'"$WORK"'/missing_target_cwd")'

refuses "read from a closed directory handle" read_closed "Cannot read from closed Dir" \
  'd = Dir.new("'"$WORK"'"); d.close; d.read'

refuses "rewind on a closed directory handle" rewind_closed "Cannot rewind closed Dir" \
  'd = Dir.new("'"$WORK"'"); d.close; d.rewind'

echo
if [ "$status" -eq 0 ]; then
  echo "std/dir: all plain, release, mutation, and refusal checks passed"
else
  echo "std/dir: exercise failed"
fi
exit $status
