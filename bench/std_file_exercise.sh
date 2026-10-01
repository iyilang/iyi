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
    # Linux's O_EXCL dropped, and Windows' CREATE_NEW made OPEN_ALWAYS (4),
    # which opens what is at the name - through a symlink - and answers it.
    old = "      fd = __iyi_openat(sys_path(path), 1 | 64 | 128 | 0x80000, 384)"
    assert src.count(old) == 1
    src = src.replace(old, "      fd = __iyi_openat(sys_path(path), 1 | 64 | 0x80000, 384)", 1)
    old = "        Pointer(Void).new(0_u64), 1, 0x80, Pointer(Void).new(0_u64))"
    assert src.count(old) == 1
    src = src.replace(old, "        Pointer(Void).new(0_u64), 4, 0x80, Pointer(Void).new(0_u64))", 1)
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
# File.match?'s pattern language, each mechanism broken in a copy that
# compiles: the check that names it has to fail.
match_broken() { # match_broken <label> <dir> <old> <new> <phrase>
  if [ -z "$PY" ]; then
    echo "  $1: no python3 on this machine, so the proof is unmeasured"
    return
  fi
  mkdir -p "$WORK/$2/std" "$WORK/$2-sandbox"
  if ! OLD="$3" NEW="$4" "$PY" - "$REPO/src/std/file.iyi" "$WORK/$2/std/file.iyi" <<'PY'
import os, sys
src = open(sys.argv[1]).read()
assert src.count(os.environ["OLD"]) == 1
open(sys.argv[2], "w").write(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  $1: the patch did not apply"
    status=1
  elif TMPDIR="$WORK/$2-sandbox" IYI_PATH="$WORK/$2${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" \
       "$IYI" run "$REPO/bench/std_file_exercise.iyi" -- "$WORK/$2-sandbox" >"$WORK/$2.out" 2>&1; then
    echo "  $1: the exercise PASSED on a broken module"
    status=1
  elif grep -q "$5" "$WORK/$2.out"; then
    echo "  $1: caught"
  else
    echo "  $1: failed, but not at its check"
    tail -3 "$WORK/$2.out" | sed 's/^/    /'
    status=1
  fi
}
match_broken "a star that crosses a separator" star_sep '          if !in_globstar && pi < sn && glob_sep?(s[pi])' '          if false' "a star stays inside a segment"
match_broken "? as one byte" q_byte '            pi = glob_char(s, sn, pi)[1]' '            pi = pi + 1' "? is one character"
match_broken "braces read as text" brace_text '        elsif c == 123_u8' '        elsif c == 0_u8' "braces choose a branch"
match_broken "a negated class read plain" class_neg '            negated = true' '            negated = false' "a class and its negation"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) ;;
  *) match_broken "a backslash read as itself" no_escape '      if c == 92_u8
        raise "File.match?: a pattern ends' '      if false
        raise "File.match?: a pattern ends' "a backslash escapes" ;;
esac
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    # The exercise asks Windows whether this account may make a symlink
    # (an administrator or Developer Mode), and says so when it may not.
    if grep -q "symlink checks skipped" "$WORK/file-plain.out"; then
      echo "  a planted symlink: not measured here, this account may not make a symlink (not an administrator, no Developer Mode)"
    else
      tempfile_broken "a predictable temporary name" predictable "a hundred fresh names were all taken" yes
      tempfile_broken "a predictable name, tested then written" follows "tempfile never answers a planted symlink" no
    fi ;;
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

# each_line that reads the whole file into its lines first, as it did.
mkdir -p "$WORK/patched_lines/std"
cp -R "$REPO/src/std/." "$WORK/patched_lines/std/"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the each_line proof is unmeasured"
elif ! "$PY" - <<PY
from pathlib import Path
path = Path("$WORK/patched_lines/std/file.iyi")
src = path.read_text()
old = "    while line = io.read_line(chomp: true)\n      yield line\n    end\n"
if old not in src:
    raise SystemExit(f"each_line patch site missing: {old!r}")
path.write_text(src.replace(old, "    io.close\n    read_lines(path).each { |line| yield line }\n", 1))
PY
then
  echo "  the each_line patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched_lines${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_file_exercise.iyi" -- "$WORK/sandbox" >"$WORK/mut_lines.out" 2>&1; then
  echo "  the exercise PASSED on an each_line that reads the whole file first"
  status=1
elif grep -q "each_line streams" "$WORK/mut_lines.out"; then
  echo "  an each_line that reads the whole file first is caught"
else
  echo "  it failed, but not at the streaming check:"
  tail -3 "$WORK/mut_lines.out" | sed 's/^/    /'
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
refuses "each_line of a path that does not exist" each_line_nonexistent "cannot read " \
  'File.each_line("'"$WORK"'/does_not_exist.txt") { |l| puts l }'
refuses "each_line of a directory" each_line_dir "it is a directory, or the read failed" \
  'File.each_line("'"$WORK"'") { |l| puts l }'
refuses "unsupported append open mode" append_mode "unsupported mode: a" \
  'File.open("'"$WORK"'/foo.txt", "a")'
refuses "info on a path that does not exist" info_nonexistent "File not found: " \
  'File.info("'"$WORK"'/does_not_exist.txt")'
refuses "real_path of an empty path" realpath_empty "Cannot resolve realpath for " \
  'File.real_path("")'

# What Windows cannot hold, refused by name. A second past what a FILETIME
# holds overflowed its tick count - "arithmetic overflow", after the file
# was made - and the second before 1601 is the count 0, which Windows reads
# as "leave the time alone": that touch answered and changed nothing.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    refuses "touch at a second past a Windows file time" touch_late "is not a second a Windows file time holds" \
      'File.touch("'"$WORK"'/touch_late.txt", 910692730086_i64)'
    refuses "touch at the second before one" touch_early "is not a second a Windows file time holds" \
      'File.touch("'"$WORK"'/touch_early.txt", -11644473600_i64)'
    if [ -e "$WORK/touch_late.txt" ] || [ -e "$WORK/touch_early.txt" ]; then
      echo "  a refused touch made its file"
      status=1
    fi
    ;;
esac

# A byte range another process has locked. Windows fails the read with
# ERROR_LOCK_VIOLATION, and `File.read` answered "" with no word - the
# failure spelled as an empty file. And a write that fails raised from
# `flush` and again from the `close` its `defer` ran, which flushed the
# same bytes again: two panics for one failure. POSIX has no mandatory
# lock to hold a range with, so this is Windows' alone.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    if [ -z "$PY" ]; then
      echo "  no python3 on this machine, so the locked-range reads are unmeasured"
    else
      locked="$WORK/locked.txt"
      printf 'module main\n\nputs File.read(Program.args[0]).bytesize\n' > "$WORK/locked_read.iyi"
      printf 'module main\n\nFile.write(Program.args[0], "replaced")\n' > "$WORK/locked_write.iyi"
      if ! "$IYI" build -o "$WORK/locked_read" "$WORK/locked_read.iyi" > "$WORK/locked_read.build" 2>&1 ||
         ! "$IYI" build -o "$WORK/locked_write" "$WORK/locked_write.iyi" > "$WORK/locked_write.build" 2>&1; then
        echo "  the locked-range programs did not build"
        sed -n '1,10p' "$WORK/locked_read.build" "$WORK/locked_write.build"
        status=1
      elif ! "$PY" - "$locked" "$WORK/locked_read.exe" "$WORK/locked_write.exe" > "$WORK/locked.out" 2>&1 <<'PY'
import msvcrt, subprocess, sys
path, reader, writer = sys.argv[1:4]
with open(path, "wb") as f:
    f.write(b"a locked range\n" * 3)
held = open(path, "r+b")
msvcrt.locking(held.fileno(), msvcrt.LK_NBLCK, 10)
bad = 0
read = subprocess.run([reader, path], capture_output=True, text=True)
if read.returncode == 0 or "the read failed" not in read.stderr + read.stdout:
    print(f"  a read of a locked range answered {read.returncode}: {(read.stdout + read.stderr).strip()!r}")
    bad += 1
else:
    print("  a read of a locked range refuses: the read failed")
write = subprocess.run([writer, path], capture_output=True, text=True)
panics = (write.stdout + write.stderr).count("iyi: panic:")
if write.returncode == 0 or panics != 1:
    print(f"  a write into a locked range exited {write.returncode} with {panics} panic(s)")
    bad += 1
else:
    print("  a write into a locked range refuses once")
held.seek(0)
msvcrt.locking(held.fileno(), msvcrt.LK_UNLCK, 10)
held.close()
sys.exit(1 if bad else 0)
PY
      then
        cat "$WORK/locked.out"
        status=1
      else
        cat "$WORK/locked.out"
      fi
    fi
    # Two files Windows will not open for their identity - here, a denied
    # SYNCHRONIZE right - are two files still. `info` falls back to the
    # attributes, whose identity is 0, and `same?` read 0 and 0 as one
    # file: two sizes, two contents, `same? true`.
    printf 'one' > "$WORK/deny_a.txt"
    printf 'second' > "$WORK/deny_b.txt"
    printf 'module main\n\nimport std/file::{File}\n\nputs File.same?(Program.args[0], Program.args[1])\n' > "$WORK/deny_same.iyi"
    if ! "$IYI" build -o "$WORK/deny_same" "$WORK/deny_same.iyi" > "$WORK/deny_same.build" 2>&1; then
      echo "  the unopenable-files program did not build"; sed -n '1,10p' "$WORK/deny_same.build"; status=1
    else
      for f in deny_a deny_b; do MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" icacls "$(cygpath -w "$WORK/$f.txt")" /deny "$USERNAME:(S)" > /dev/null; done
      answer="$("$WORK/deny_same" "$WORK/deny_a.txt" "$WORK/deny_b.txt" 2>&1)"
      for f in deny_a deny_b; do MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" icacls "$(cygpath -w "$WORK/$f.txt")" /remove:d "$USERNAME" > /dev/null; done
      if [ "$answer" = "false" ]; then
        echo "  two files Windows will not open are not one file"
      else
        echo "  two files Windows will not open answered same? $answer"
        status=1
      fi
    fi
    # A junction, which any user may make: a link to a directory. POSIX
    # `unlink` removes a link whatever it names, and `File.symlink?` said
    # this was one - but `File.delete` asked `DeleteFileW`, which refuses a
    # directory, and panicked "cannot delete".
    mkdir -p "$WORK/junction_target"
    printf 'kept' > "$WORK/junction_target/inside.txt"
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" cmd /c mklink /J "$(cygpath -w "$WORK/junction")" "$(cygpath -w "$WORK/junction_target")" > /dev/null
    printf 'module main\n\nimport std/file::{File}\n\nputs File.symlink?(Program.args[0])\nFile.delete(Program.args[0])\nputs File.exists?(Program.args[0])\n' > "$WORK/junction_delete.iyi"
    if [ ! -d "$WORK/junction" ]; then
      echo "  mklink /J made no junction, so its delete is unmeasured"
    elif ! "$IYI" build -o "$WORK/junction_delete" "$WORK/junction_delete.iyi" > "$WORK/junction_delete.build" 2>&1; then
      echo "  the junction program did not build"; sed -n '1,10p' "$WORK/junction_delete.build"; status=1
    else
      answer="$("$WORK/junction_delete" "$WORK/junction" 2>&1 | tr '\n' ' ')"
      if [ "$answer" = "true false " ] && [ -f "$WORK/junction_target/inside.txt" ]; then
        echo "  File.delete of a junction removes the link and leaves the directory"
      else
        echo "  File.delete of a junction: $answer"
        status=1
      fi
    fi
    # A hidden file, and a system one, is rewritten like any other: a
    # create that replaces refuses them on Windows unless it asks for the
    # same attributes, and `File.write` panicked "cannot write" about a
    # file it could read. The attribute stays.
    printf 'module main\n\nFile.write(Program.args[0], "rewritten")\nputs File.read(Program.args[0])\n' > "$WORK/hidden_write.iyi"
    if ! "$IYI" build -o "$WORK/hidden_write" "$WORK/hidden_write.iyi" > "$WORK/hidden_write.build" 2>&1; then
      echo "  the hidden-file program did not build"; sed -n '1,10p' "$WORK/hidden_write.build"; status=1
    else
      for mark in h s; do
        printf 'before' > "$WORK/marked_$mark.txt"
        MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" attrib +$mark "$(cygpath -w "$WORK/marked_$mark.txt")" > /dev/null
        answer="$("$WORK/hidden_write" "$WORK/marked_$mark.txt" 2>&1)"
        kept="$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" attrib "$(cygpath -w "$WORK/marked_$mark.txt")" | cut -c1-12 | tr -d ' ' | tr 'A-Z' 'a-z')"
        MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" attrib -$mark "$(cygpath -w "$WORK/marked_$mark.txt")" > /dev/null
        if [ "$answer" = "rewritten" ] && echo "$kept" | grep -q "$mark"; then
          echo "  a file marked +$mark is rewritten and stays marked"
        else
          echo "  a file marked +$mark: wrote '$answer', attributes '$kept'"
          status=1
        fi
      done
    fi
    # What `access` answers on POSIX, asked of Windows: a file this user is
    # denied reading is not readable, one denied writing is not writable,
    # and `cmd.exe` is executable. The made-up mode answered true, true
    # and false.
    printf 'module main\n\nimport std/file::{File}\n\nputs "#{File.readable?(Program.args[0])} #{File.writable?(Program.args[0])} #{File.executable?(Program.args[0])}"\n' > "$WORK/access.iyi"
    if ! "$IYI" build -o "$WORK/access" "$WORK/access.iyi" > "$WORK/access.build" 2>&1; then
      echo "  the access program did not build"; sed -n '1,10p' "$WORK/access.build"; status=1
    else
      printf 'x' > "$WORK/no_read.txt"; printf 'x' > "$WORK/no_write.txt"
      MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" icacls "$(cygpath -w "$WORK/no_read.txt")" /deny "$USERNAME:(RD)" > /dev/null
      MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" icacls "$(cygpath -w "$WORK/no_write.txt")" /deny "$USERNAME:(WD)" > /dev/null
      no_read="$("$WORK/access" "$WORK/no_read.txt" 2>&1)"
      no_write="$("$WORK/access" "$WORK/no_write.txt" 2>&1)"
      shell="$("$WORK/access" "$(cygpath -m "$SYSTEMROOT")/System32/cmd.exe" 2>&1)"
      for f in no_read no_write; do
        MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" icacls "$(cygpath -w "$WORK/$f.txt")" /remove:d "$USERNAME" > /dev/null
      done
      if [ "$no_read" = "false true false" ] && [ "$no_write" = "true false false" ] && [ "$shell" = "true false true" ]; then
        echo "  readable?, writable? and executable? answer as Windows would let them"
      else
        echo "  readable?/writable?/executable?: denied read '$no_read', denied write '$no_write', cmd.exe '$shell'"
        status=1
      fi
    fi
    # A file the system holds without sharing refuses every attribute call
    # - an ordinary exclusive open does not; the paging file does - and
    # `File.exists?` said false and `File.info` "File not found" about a
    # file `dir` lists. Asked of the paging file of whichever drive has one.
    printf 'module main\n\nimport std/file::{File}\n\nputs "#{File.exists?(Program.args[0])} #{File.file?(Program.args[0])} #{File.size(Program.args[0]) > 0}"\n' > "$WORK/held.iyi"
    paging=""
    for drive in C D E; do
      [ -e "/$(echo $drive | tr 'A-Z' 'a-z')/pagefile.sys" ] && { paging="$drive:/pagefile.sys"; break; }
    done
    if [ -z "$paging" ]; then
      echo "  no paging file on C:, D: or E:, so a file the system holds is unmeasured"
    elif ! "$IYI" build -o "$WORK/held" "$WORK/held.iyi" > "$WORK/held.build" 2>&1; then
      echo "  the held-file program did not build"; sed -n '1,10p' "$WORK/held.build"; status=1
    else
      answer="$("$WORK/held" "$paging" 2>&1)"
      if [ "$answer" = "true true true" ]; then
        echo "  $paging, held by the system, exists, is a file, and has a size"
      else
        echo "  $paging, held by the system, answered exists?/file?/size: $answer"
        status=1
      fi
    fi
    # A reparse point is a link only by its tag. Every one was `Symlink`,
    # so an app execution alias - what `WindowsApps` holds - and a cloud
    # placeholder answered `file? false`; and a junction whose directory is
    # gone answered a followed `info?` with the link itself, where POSIX
    # `stat` of a dangling link is an error.
    printf 'module main\n\nimport std/file::{File}\n\nputs "#{File.file?(Program.args[0])} #{File.symlink?(Program.args[0])} #{File.executable?(Program.args[0])} #{File.real_path(Program.args[0]).downcase.ends_with?(File.basename(Program.args[0]).downcase)}"\n' > "$WORK/reparse_kind.iyi"
    printf 'module main\n\nimport std/file::{File}\nimport std/dir::{Dir}\n\nputs "#{File.symlink?(Program.args[0])} #{File.info?(Program.args[0]).nil?} #{File.exists?(Program.args[0])} #{Dir.exists?(Program.args[0])}"\n' > "$WORK/dangling.iyi"
    if ! "$IYI" build -o "$WORK/reparse_kind" "$WORK/reparse_kind.iyi" > "$WORK/reparse_kind.build" 2>&1 ||
       ! "$IYI" build -o "$WORK/dangling" "$WORK/dangling.iyi" > "$WORK/dangling.build" 2>&1; then
      echo "  the reparse programs did not build"; sed -n '1,10p' "$WORK/reparse_kind.build" "$WORK/dangling.build"; status=1
    else
      alias_exe=""
      apps="$(cygpath -u "$LOCALAPPDATA")/Microsoft/WindowsApps"
      for candidate in "$apps"/*.exe; do
        [ -e "$candidate" ] && { alias_exe="$(cygpath -m "$candidate")"; break; }
      done
      if [ -z "$alias_exe" ]; then
        echo "  no app execution alias on this machine, so their kind is unmeasured"
      else
        answer="$("$WORK/reparse_kind" "$alias_exe" 2>&1)"
        # And the program it is: `executable?` said false of what
        # `Process.run` runs, and `real_path` panicked - the alias does
        # not open as data (ERROR_CANT_ACCESS_FILE, 1920).
        if [ "$answer" = "true false true true" ]; then
          echo "  an app execution alias is a file, not a link, is executable, and is its own real path"
        else
          echo "  an app execution alias ($alias_exe) answered file?/symlink?/executable?/real_path $answer"
          status=1
        fi
      fi
      mkdir -p "$WORK/gone_target"
      MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" cmd /c mklink /J "$(cygpath -w "$WORK/dangling_junction")" "$(cygpath -w "$WORK/gone_target")" > /dev/null
      rmdir "$WORK/gone_target"
      answer="$("$WORK/dangling" "$WORK/dangling_junction" 2>&1)"
      # And it does not exist, as POSIX `stat` of a dangling link fails:
      # `File.exists?` and `Dir.exists?` said true while `File.directory?`
      # said false and `Dir.children` panicked.
      if [ "$answer" = "true true false false" ]; then
        echo "  a junction to nothing is a link, following it answers nothing, and it does not exist"
      else
        echo "  a junction to nothing answered symlink?/info?.nil?/exists?/Dir.exists? $answer"
        status=1
      fi
      # A junction to a volume's GUID path reads back as one: the NT prefix
      # came off whatever followed it, and `Volume{...}\x` is a relative
      # path to nowhere.
      printf 'module main\n\nimport std/file::{File}\n\nputs File.readlink(Program.args[0])\n' > "$WORK/readlink.iyi"
      volume="$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" mountvol "$(cygpath -w "$WORK" | cut -c1-3)" /L 2>/dev/null | tr -d ' \r' | head -1)"
      if [ -z "$volume" ]; then
        echo "  mountvol names no volume here, so a junction to one is unmeasured"
      elif ! "$IYI" build -o "$WORK/readlink" "$WORK/readlink.iyi" > "$WORK/readlink.build" 2>&1; then
        echo "  the readlink program did not build"; sed -n '1,5p' "$WORK/readlink.build"; status=1
      else
        mkdir -p "$WORK/by_volume"
        target="${volume}$(cygpath -w "$WORK/by_volume" | cut -c4-)"
        MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" cmd /c mklink /J "$(cygpath -w "$WORK/volume_junction")" "$target" > /dev/null
        read_back="$("$WORK/readlink" "$WORK/volume_junction" 2>&1 | tr -d '\r')"
        if [ "$read_back" = "$target" ]; then
          echo "  a junction to a volume's GUID path reads back as that path"
        else
          echo "  a junction to $target read back as $read_back"
          status=1
        fi
      fi
    fi
    # A tempfile name that is not UTF-8 is refused as one: it was refused
    # "Windows error 3: The system cannot find the path specified".
    refuses "a tempfile name that is not UTF-8" tempfile_bad "the path is not valid UTF-8" \
      'File.tempfile("bad\xFF")'
    ;;
esac

echo
if [ "$status" -eq 0 ]; then
  echo "the std/file exercise holds"
else
  echo "the std/file exercise did not hold"
fi
exit $status
