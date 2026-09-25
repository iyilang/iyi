#!/usr/bin/env bash
# Exercises `std/file`.
#
#     bash bench/std_file_exercise.sh
#
# Proves:
#   * The exercise holds plain and --release: write/read, append, exists/size,
#     line-wise reading, truncation/overwrite, permissions, directory queries,
#     hard and symbolic links, rename, path helpers, and delete.
#   * Negative proof: a patched copy of the module that corrupts File.size
#     is caught and fails the exercise.
#   * What the module refuses: reading a path that does not exist, reading a
#     directory passed where a file is expected, unsupported open modes,
#     and info on a nonexistent path.
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
export IYI_FILE_SANDBOX="$WORK/sandbox"
# `File.tempfile` reads TMPDIR first, so the symlink the exercise plants is
# in the directory the temporary file is made in.
export TMPDIR="$WORK/sandbox"
mkdir -p "$WORK/sandbox"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_file_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" "$WORK/sandbox" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/file exercise, plain build"
build_and_run "plain" file-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/file-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every file section reported"
for phrase in "== write, read, and append" \
              "== exists, size, and empty" \
              "== line-wise reading" \
              "== truncation and overwrite" \
              "== metadata and permissions" \
              "== directory and file queries" \
              "== paths, links, and content comparison" \
              "== delete"; do
  if ! grep -q "$phrase" "$WORK/file-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" file-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/file-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== the platform's temporary directory, written as darwin writes it"
# No sandbox argument and no IYI_FILE_SANDBOX, so the exercise works in
# `Dir.tempdir`, and TMPDIR ends with a separator the way darwin's does.
# `Dir.tempdir` answered it as it was, every path joined onto it had two
# separators, and `dirname` did not answer the directory the file was in -
# which the darwin runner found and nothing here could.
mkdir -p "$WORK/trailing"
if env -u IYI_FILE_SANDBOX TMPDIR="$WORK/trailing/" "$WORK/file-plain" > "$WORK/trailing.out" 2>&1 \
   && grep -q "ALL CHECKS PASSED" "$WORK/trailing.out"; then
  echo "  a TMPDIR ending in a separator is the directory without it"
else
  echo "  a TMPDIR ending in a separator broke the exercise:"
  grep -m3 -E "panic|expected|got" "$WORK/trailing.out" | sed 's/^/    /'
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
# The temporary name made predictable for the exercise's `plant` prefix -
# all zeros, the name it plants a symlink at - is refused by the exclusive create a hundred times
# and fails by name; with the create made the old test-then-write as well,
# the upload goes through the symlink.
tempfile_broken() { # tempfile_broken <label> <dir> <phrase> <exclusive: yes|no>
  local label="$1" dir="$2" phrase="$3" exclusive="$4"
  if [ -z "$PY" ]; then
    echo "  $label: no python3 on this machine, so the proof is unmeasured"
    return
  fi
  mkdir -p "$WORK/$dir/std"
  if ! EXCLUSIVE="$exclusive" "$PY" - "$REPO/src/std/file.iyi" "$WORK/$dir/std/file.iyi" <<'PY'
import os, sys
src = open(sys.argv[1]).read()
old = '      path = tmpdir + File::SEPARATOR_STRING + prefix + "_" + temp_token + suffix'
assert src.count(old) == 1
src = src.replace(old, old.replace("temp_token", '(prefix == "plant" ? "0000000000000000" : temp_token)'), 1)
if os.environ["EXCLUSIVE"] == "no":
    old = "      fd = __iyi_openat(sys_path(path), 1 | 64 | 128 | 0x80000, 384)"
    assert src.count(old) == 1
    src = src.replace(old, "      fd = __iyi_openat(sys_path(path), 1 | 64 | 0x80000, 384)", 1)
open(sys.argv[2], "w").write(src)
PY
  then
    echo "  $label: the patch did not apply"
    status=1
  elif mkdir -p "$WORK/$dir-sandbox" &&
       TMPDIR="$WORK/$dir-sandbox" IYI_PATH="$WORK/$dir${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" \
       "$IYI" run "$REPO/bench/std_file_exercise.iyi" -- "$WORK/$dir-sandbox" >"$WORK/$dir.out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  elif grep -q "$phrase" "$WORK/$dir.out"; then
    echo "  $label: caught at \"$phrase\""
  else
    echo "  $label: failed, but not at \"$phrase\""
    tail -3 "$WORK/$dir.out" | sed 's/^/    /'
    status=1
  fi
}
# The read-ahead kept across a seek: the next read answers the bytes after
# the old place.
seek_broken() {
  if [ -z "$PY" ]; then
    echo "  a seek that keeps the read-ahead: no python3 on this machine, so the proof is unmeasured"
    return
  fi
  mkdir -p "$WORK/stale/std" "$WORK/stale-sandbox"
  if ! "$PY" - "$REPO/src/std/file.iyi" "$WORK/stale/std/file.iyi" <<'PY'
import sys
src = open(sys.argv[1]).read()
old = "    @read_pos = 0\n    @read_limit = 0\n    @eof = false\n    moved\n"
assert src.count(old) == 1
src = src.replace(old, "    moved\n", 1)
open(sys.argv[2], "w").write(src)
PY
  then
    echo "  a seek that keeps the read-ahead: the patch did not apply"
    status=1
  elif TMPDIR="$WORK/stale-sandbox" IYI_PATH="$WORK/stale${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" \
       "$IYI" run "$REPO/bench/std_file_exercise.iyi" -- "$WORK/stale-sandbox" >"$WORK/stale.out" 2>&1; then
    echo "  a seek that keeps the read-ahead: the exercise PASSED on a broken module"
    status=1
  elif grep -q "seek: from the start, past the read-ahead" "$WORK/stale.out"; then
    echo "  a seek that keeps the read-ahead: caught"
  else
    echo "  a seek that keeps the read-ahead: failed, but not at the seek"
    tail -3 "$WORK/stale.out" | sed 's/^/    /'
    status=1
  fi
}
seek_broken
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    echo "  a planted symlink: not measured here, the exercise plants none on Windows" ;;
  Linux)
    tempfile_broken "a predictable temporary name" predictable "a hundred fresh names were all taken" yes
    tempfile_broken "a predictable name, tested then written" follows "tempfile never answers a planted symlink" no ;;
  *)
    tempfile_broken "a predictable temporary name" predictable "a hundred fresh names were all taken" yes ;;
esac
mkdir -p "$WORK/patched/std"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the broken-module proof is unmeasured"
elif ! "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/file.iyi").read_text()
old = '    info(path).size\n  end'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/file.iyi").write_text(src.replace(old, '    info(path).size + 1_i64\n  end', 1))
PY
then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_file_exercise.iyi" -- "$WORK/sandbox" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  a broken file is caught"
fi

echo
echo "== proving a truncating touch is caught"
mkdir -p "$WORK/patched_touch/std"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the broken-module proof is unmeasured"
elif ! "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/file.iyi").read_text()
old = '    File.write(p, "") unless File.exists?(p)'
if old not in src:
    raise SystemExit("touch patch site missing")
Path("$WORK/patched_touch/std/file.iyi").write_text(src.replace(old, '    File.write(p, "")', 1))
PY
then
  echo "  the touch patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched_touch${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_file_exercise.iyi" -- "$WORK/sandbox" >"$WORK/mut_touch.out" 2>&1; then
  echo "  the exercise PASSED on a truncating touch"
  status=1
else
  echo "  a truncating touch is caught"
fi

echo
echo "== proving a touch that ignores the time it is given is caught"
# The branch the host compiles, because that is the only one this run can
# reach: darwin writes a `timeval` pair through `utimes`, Linux a
# `timespec` pair through `utimensat`, and Windows a FILETIME tick count
# through `SetFileTime`. The darwin branch passed a null `times`, which
# means "now", so `touch(path, 1)` set the clock's time there and the epoch
# second on Linux — and nothing here said so, because the Linux copy is what
# the proofs had always patched. Windows fell to the darwin site in turn: the
# patch applied to a branch that host never compiles, the touch it built was
# whole, and the exercise passed.
# The *mtime* slot, which is what `File.info#modification_time` reads: the
# pair is atime then mtime, and a patch to the first one moves a field
# nothing here asks about. Windows hands one tick count to both slots, so
# its patch is to that count, which zeroed is the epoch second the other
# patches write.
case "$(uname -s)" in
  Linux) touch_site='        ts[2] = sec' ;;
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
         touch_site='        ticks = time * 10000000_i64 + 116444736000000000_i64' ;;
  *)     touch_site='        tv[2] = time' ;;
esac
mkdir -p "$WORK/patched_time/std"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the broken-module proof is unmeasured"
elif ! TOUCH_SITE="$touch_site" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/file.iyi").read_text()
old = os.environ["TOUCH_SITE"]
if old not in src:
    raise SystemExit(f"touch time patch site missing: {old!r}")
Path("$WORK/patched_time/std/file.iyi").write_text(src.replace(old, old.replace("time", "0_i64").replace("sec", "0_i64"), 1))
PY
then
  echo "  the touch time patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched_time${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_file_exercise.iyi" -- "$WORK/sandbox" >"$WORK/mut_time.out" 2>&1; then
  echo "  the exercise PASSED on a touch that ignores its argument"
  status=1
elif grep -q "touch sets the given unix time" "$WORK/mut_time.out"; then
  echo "  a touch that ignores its argument is caught"
else
  echo "  it failed, but not at the time check:"
  tail -3 "$WORK/mut_time.out" | sed 's/^/    /'
  status=1
fi

echo
echo "== what file refuses"
refuses() { # refuses <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expr="$4"
  printf 'module main\n\nimport std/file::{File}\n\n%s\n' "$expr" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,10p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of refusing: $(cat "$WORK/$name.out")"
    status=1
    return
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase'"
    sed -n '1,3p' "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(sed -n '1p' "$WORK/$name.out" | sed 's/^iyi: panic: //')"
}

refuses "read of a path that does not exist" read_nonexistent "cannot read " \
  'File.read("'"$WORK"'/does_not_exist.txt")'
refuses "read of a directory passed where a file is expected" read_dir "it is a directory, or the read failed" \
  'File.read("'"$WORK"'")'
refuses "unsupported append open mode" append_mode "unsupported mode: a" \
  'File.open("'"$WORK"'/foo.txt", "a")'
refuses "info on a path that does not exist" info_nonexistent "File not found: " \
  'File.info("'"$WORK"'/does_not_exist.txt")'
refuses "real_path of an empty path" realpath_empty "Cannot resolve realpath for " \
  'File.real_path("")'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/file exercise holds"
else
  echo "the std/file exercise did not hold"
fi
exit $status
