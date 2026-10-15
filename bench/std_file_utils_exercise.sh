#!/usr/bin/env bash
# Exercises `std/file_utils`.
#
#     bash bench/std_file_utils_exercise.sh
#
# Proves the exercise holds plain and --release; that `cp_r` makes the
# tree Python's `shutil.copytree(symlinks=True)` makes - names, kinds,
# permission bits, link targets and bytes, and `filecmp.dircmp` finding
# nothing between the two - that `compare_file` answers what
# `filecmp.cmp(shallow=False)` answers, and that a move across devices
# leaves what `shutil.move` leaves; what the module refuses, by its exact
# sentence; and that the important checks fail on a broken copy of the
# module: a removal that follows a link, `link/` followed, a file read
# whole, permission bits dropped, a file copied onto itself, a tree copied
# into itself, a move across devices tried as a rename, a comparison that
# reads no bytes, and links to directories copied as directories.
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

# The oracle's trees hold a read-only directory, which `rm -rf` cannot
# empty until it is writable again; and the second device is cleaned of
# what this run put there.
SHM_WORK=""
cleanup() {
  chmod -R u+w "$WORK" 2>/dev/null
  rm -rf "$WORK"
  if [ -n "$SHM_WORK" ]; then
    chmod -R u+w "$SHM_WORK" 2>/dev/null
    rm -rf "$SHM_WORK"
  fi
}
trap cleanup EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

# A second device: /dev/shm where it is a tmpfs of its own, which on Linux
# it is; a move across devices is otherwise unmeasured, and said so.
OTHER=""
if [ -d /dev/shm ] && [ -w /dev/shm ] && [ "$(stat -c %d /dev/shm 2>/dev/null)" != "$(stat -c %d "$WORK" 2>/dev/null)" ]; then
  SHM_WORK="$(mktemp -d /dev/shm/iyi_file_utils.XXXXXX)"
  OTHER="$SHM_WORK"
fi

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_file_utils_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  # The refusals the exercise provokes on purpose print their panic on
  # stderr as they are caught; the checks' own words are on stdout.
  TEST_SANDBOX="$WORK/sandbox-$name" FILE_UTILS_OTHER_DEVICE="$OTHER" "$WORK/$name" >"$WORK/$name.out" 2>"$WORK/$name.err"
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    tail -4 "$WORK/$name.err" | sed 's/^/  /'
    status=1
    return 1
  fi
  return 0
}

echo "== the std/file_utils exercise, plain build"
build_and_run "plain" fu-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/fu-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every file_utils section reported"
for phrase in "== cp: bytes, permission bits, into a directory" \
              "== a 64 MiB copy in pieces" \
              "== compare_file" \
              "== cp_r: a tree, its links, its modes" \
              "== rm_r never follows a link" \
              "== mv: rename, into a directory, across devices"; do
  if ! grep -q "$phrase" "$WORK/fu-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" fu-release --release >/dev/null
if grep -q "ALL CHECKS PASSED" "$WORK/fu-release.out" 2>/dev/null; then
  echo "  release: ALL CHECKS PASSED"
else
  echo "release: missing pass sentinel"
  status=1
fi

# One program that runs each operation on its arguments, built once: the
# oracle and the refusals below call it many times.
cat >"$WORK/tool.iyi" <<'IYI'
module tool

import std/file_utils::{FileUtils}

args = Program.args
case args[0]
when "cp"      then FileUtils.cp(args[1], args[2])
when "cp_r"    then FileUtils.cp_r(args[1], args[2])
when "rm_r"    then FileUtils.rm_r(args[1])
when "rm_rf"   then FileUtils.rm_rf(args[1])
when "mv"      then FileUtils.mv(args[1], args[2])
when "compare" then puts FileUtils.compare_file(args[1], args[2])
else                raise "no such operation: #{args[0]}"
end
IYI
TOOL="$WORK/tool"
if ! "$IYI" build --release -o "$TOOL" "$WORK/tool.iyi" >"$WORK/tool.build.log" 2>&1; then
  echo "the tool did not build"
  tail -12 "$WORK/tool.build.log"
  status=1
fi

echo
echo "== cp_r against shutil.copytree, and filecmp"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the comparison is unmeasured"
elif ! "$PY" - "$WORK/oracle" "$TOOL" "$OTHER" <<'PY'
import filecmp, os, shutil, stat, subprocess, sys

root, tool, other = sys.argv[1], sys.argv[2], sys.argv[3]
src = os.path.join(root, "src")
outside = os.path.join(root, "outside")
os.makedirs(os.path.join(src, "a", "b", "c"))
os.makedirs(os.path.join(src, "empty"))
os.makedirs(os.path.join(src, "locked", "in"))
os.makedirs(outside)
with open(os.path.join(outside, "keep.txt"), "w") as f:
    f.write("not yours")
rng = __import__("random").Random(7)
sizes = {"zero": 0, "one": 1, "piece_less": 65535, "piece": 65536,
         "piece_more": 65537, "several": 300001}
for name, size in sizes.items():
    with open(os.path.join(src, "a", name + ".bin"), "wb") as f:
        f.write(bytes(rng.getrandbits(8) for _ in range(size)))
for rel, text, mode in [("top.txt", "top\n", 0o640), (".hidden", "dot", 0o600),
                        ("a/b/çay ğ.txt", "unicode", 0o644), ("a/b/c/run.sh", "#!/bin/sh\n", 0o755),
                        ("a/b/with space", "space", 0o444), ("locked/in/x", "x", 0o604)]:
    path = os.path.join(src, rel)
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)
os.symlink("../top.txt", os.path.join(src, "a", "up"))
os.symlink("b/c", os.path.join(src, "a", "to_dir"))
os.symlink(outside, os.path.join(src, "out"))
os.symlink("dangling-target", os.path.join(src, "dangling"))
os.chmod(os.path.join(src, "a", "b", "c"), 0o750)
os.chmod(os.path.join(src, "locked"), 0o555)

def walk(top):
    seen = {}
    for dirpath, dirnames, filenames in os.walk(top):
        for name in dirnames + filenames:
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, top)
            st = os.lstat(path)
            if stat.S_ISLNK(st.st_mode):
                # Windows' os.symlink writes a target's / as \, so Python's
                # copy holds b\c where cp_r kept the source's b/c: the same
                # place, compared as one.
                seen[rel] = ("link", os.readlink(path).replace(os.sep, "/"))
            elif stat.S_ISDIR(st.st_mode):
                seen[rel] = ("dir", oct(stat.S_IMODE(st.st_mode)))
            else:
                with open(path, "rb") as f:
                    seen[rel] = ("file", oct(stat.S_IMODE(st.st_mode)), f.read())
    return seen

def differences(left, right):
    a, b = walk(left), walk(right)
    bad = []
    for rel in sorted(set(a) | set(b)):
        if a.get(rel) != b.get(rel):
            show = lambda v: v if v is None or v[0] != "file" else v[:2] + (len(v[2]),)
            bad.append("%s: %r vs %r" % (rel, show(a.get(rel)), show(b.get(rel))))
    # dircmp follows links and compares the files it reaches; a dangling
    # link is "funny" on both sides alike.
    def deep(d, at=""):
        for kind, names in (("only in the iyi copy", d.left_only), ("only in python's", d.right_only),
                            ("different", d.diff_files)):
            for n in names:
                bad.append("dircmp: %s %s" % (kind, os.path.join(at, n)))
        for n, sub in d.subdirs.items():
            if not os.path.islink(os.path.join(d.left, n)):
                deep(sub, os.path.join(at, n))
    deep(filecmp.dircmp(left, right))
    return bad, len(a)

def run(*args):
    done = subprocess.run([tool] + list(args), capture_output=True, text=True)
    if done.returncode != 0:
        raise SystemExit("  %s refused: %s" % (" ".join(args[:1]), done.stderr.strip()))
    return done.stdout.strip()

failed = False
mine, theirs = os.path.join(root, "iyi_copy"), os.path.join(root, "py_copy")
run("cp_r", src, mine)
shutil.copytree(src, theirs, symlinks=True)
bad, count = differences(mine, theirs)
for line in bad:
    print("  " + line)
failed = failed or bool(bad)
if not bad:
    print("  cp_r and shutil.copytree(symlinks=True) agree on %d entries: names, kinds, bits, link targets, bytes" % count)

# Into a directory that is there: `cp -R`'s rule, which copytree has not;
# python is asked for the same place by name.
shelf = os.path.join(root, "shelf")
os.mkdir(shelf)
run("cp_r", src, shelf)
bad, _ = differences(os.path.join(shelf, "src"), theirs)
for line in bad:
    print("  into a directory: " + line)
failed = failed or bool(bad)
if not bad:
    print("  cp_r into a directory lands under the source's name, the same tree")

# rm_r of the copy: the link out of it is removed, what it named is not.
# The read-only directory is opened up first, as it is for `rm -r`: its
# entries are its to give, and it refuses (the refusals below show it).
os.chmod(os.path.join(mine, "locked"), 0o755)
run("rm_r", mine)
if os.path.lexists(mine):
    print("  rm_r left %s" % mine); failed = True
elif open(os.path.join(outside, "keep.txt")).read() != "not yours":
    print("  rm_r reached through the link to %s" % outside); failed = True
else:
    print("  rm_r removed the copy and left the directory its link named")

# compare_file against filecmp.cmp(shallow=False), pair by pair.
pairs = os.path.join(root, "pairs")
os.mkdir(pairs)
base = bytes(rng.getrandbits(8) for _ in range(200003))
cases = {"same": base, "short": base[:-1], "longer": base + b"x", "empty": b""}
for at in (0, 7, 8, 65535, 65536, 131071, 131072, 199999, 200002):
    changed = bytearray(base)
    changed[at] ^= 0x5A
    cases["at_%d" % at] = bytes(changed)
with open(os.path.join(pairs, "base"), "wb") as f:
    f.write(base)
with open(os.path.join(pairs, "empty2"), "wb") as f:
    pass
disagree = 0
checked = 0
for name, data in cases.items():
    path = os.path.join(pairs, name)
    with open(path, "wb") as f:
        f.write(data)
    for left, right in ((os.path.join(pairs, "base"), path), (path, os.path.join(pairs, "empty2"))):
        want = filecmp.cmp(left, right, shallow=False)
        got = run("compare", left, right) == "true"
        checked += 1
        if want != got:
            disagree += 1
            print("  compare_file(%s, %s) = %s, filecmp.cmp says %s" % (os.path.basename(left), os.path.basename(right), got, want))
failed = failed or disagree > 0
if disagree == 0:
    print("  compare_file and filecmp.cmp(shallow=False) agree on %d pairs" % checked)

# A move across devices against shutil.move, from two copies of the tree.
if other:
    # The read-only directory opened up in both: neither would move it,
    # `mv` refusing first and `shutil.move` stopping half way.
    for who in ("iyi", "py"):
        shutil.copytree(src, os.path.join(root, "moving_" + who), symlinks=True)
        os.chmod(os.path.join(root, "moving_" + who, "locked"), 0o755)
    run("mv", os.path.join(root, "moving_iyi"), os.path.join(other, "moved_iyi"))
    shutil.move(os.path.join(root, "moving_py"), os.path.join(other, "moved_py"))
    bad, count = differences(os.path.join(other, "moved_iyi"), os.path.join(other, "moved_py"))
    if os.path.lexists(os.path.join(root, "moving_iyi")):
        bad.append("the source is still there")
    for line in bad:
        print("  across devices: " + line)
    failed = failed or bool(bad)
    if not bad:
        print("  mv to %s and shutil.move agree on %d entries, source gone" % (other, count))
    for who in ("iyi", "py"):
        for dirpath, dirnames, _ in os.walk(os.path.join(other, "moved_" + who)):
            os.chmod(dirpath, 0o755)
        shutil.rmtree(os.path.join(other, "moved_" + who))
else:
    print("  no second device here (/dev/shm is not a tmpfs of its own), so mv against shutil.move is unmeasured")
sys.exit(1 if failed else 0)
PY
then
  status=1
fi

echo
echo "== what file_utils refuses"
R="$WORK/refusals"
mkdir -p "$R/dir/sub"
printf 'x' >"$R/file"
# refuses <label> <exact sentence> <operation and arguments...>: the tool
# must fail, and say exactly that.
refuses() {
  local label="$1" sentence="$2"
  shift 2
  if "$TOOL" "$@" >"$WORK/refusal.out" 2>&1; then
    echo "  $label: accepted"
    status=1
  elif ! grep -qF "$sentence" "$WORK/refusal.out"; then
    echo "  $label: refused without the sentence ($sentence)"
    sed 's/^/    /' "$WORK/refusal.out"
    status=1
  else
    echo "  $label: $sentence"
  fi
}
refuses "cp of nothing" "Cannot copy $R/none to $R/x: $R/none does not exist" cp "$R/none" "$R/x"
refuses "cp of a directory" "Cannot copy $R/dir to $R/x: $R/dir is a directory, which cp_r copies" cp "$R/dir" "$R/x"
refuses "cp onto itself" "Cannot copy $R/file to $R/file: they are the same file" cp "$R/file" "$R/file"
# The landing is `File.join`ed, which is `\` on Windows.
landing="$R/dir/sub/dir"
[ "$PSEP" = ';' ] && landing="$R/dir/sub\\dir"
refuses "cp_r into itself" "Cannot copy $R/dir to $landing: $landing is inside the tree being copied" cp_r "$R/dir" "$R/dir/sub"
refuses "cp_r under a missing directory" "Cannot copy $R/dir to $R/no/where: the directory $R/no does not exist" cp_r "$R/dir" "$R/no/where"
# Git's shell on Windows answers `mkfifo` with an MSYS emulation, an
# ordinary file to a native program: Windows has no FIFO to refuse.
if [ "$PSEP" = ';' ]; then
  echo "  cp_r of a FIFO: Windows has none, so unmeasured"
elif command -v mkfifo >/dev/null 2>&1 && mkfifo "$R/dir/pipe" 2>/dev/null; then
  refuses "cp_r of a FIFO" "Cannot copy $R/dir/pipe: it is a FIFO, not a file, a directory or a link" cp_r "$R/dir" "$R/copied"
  rm -f "$R/dir/pipe"
else
  echo "  cp_r of a FIFO: no mkfifo here, so unmeasured"
fi
refuses "rm_r of nothing" "Cannot remove $R/none: it does not exist" rm_r "$R/none"
# A directory the user may not write gives up none of its entries, as
# `rm -r` and `shutil.rmtree` find; root is not asked, and Windows has no
# such bit on a directory.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) ;;
  *)
    if [ "$(id -u)" != 0 ]; then
      mkdir -p "$R/ro/in"
      chmod 555 "$R/ro"
      refuses "rm_r under a read-only directory" "Cannot remove directory: $R/ro/in" rm_r "$R/ro"
      chmod 755 "$R/ro"
    fi
    ;;
esac
refuses "mv of nothing" "Cannot move $R/none to $R/x: $R/none does not exist" mv "$R/none" "$R/x"
refuses "mv under a missing directory" "Cannot move $R/file to $R/no/where: the directory $R/no does not exist" mv "$R/file" "$R/no/where"
refuses "compare_file of a directory" "Cannot compare $R/dir with $R/file: $R/dir is not a file" compare "$R/dir" "$R/file"
refuses "compare_file of nothing" "Cannot compare $R/file with $R/none: $R/none is not a file" compare "$R/file" "$R/none"
if "$TOOL" rm_rf "$R/none" >"$WORK/refusal.out" 2>&1; then
  echo "  rm_rf of nothing: accepted, as it should be"
else
  echo "  rm_rf of nothing was refused"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <old> <new>: the exercise, built against a
# copy of the module with <old> replaced, must fail at the check that
# names <phrase>, under a clock: a tree copied into itself is a walk that
# only the length of a path ends.
n=0
prove_broken() {
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $1 proof is unmeasured"
    return
  fi
  n=$((n + 1))
  local dir="$WORK/patched$n"
  mkdir -p "$dir/std"
  if ! OLD="$3" NEW="$4" "$PY" - "$REPO/src/std/file_utils.iyi" "$dir/std/file_utils.iyi" <<'PY'
import os, sys
src = open(sys.argv[1], encoding="utf-8").read()
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not unique")
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
    return
  fi
  if ! IYI_PATH="$dir${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$dir/program" "$REPO/bench/std_file_utils_exercise.iyi" >"$dir/build.log" 2>&1; then
    echo "  $1: the broken copy did not compile"
    sed -n '1,6p' "$dir/build.log" | sed 's/^/    /'
    status=1
    return
  fi
  TEST_SANDBOX="$dir/sandbox" FILE_UTILS_OTHER_DEVICE="$OTHER" timeout 300 "$dir/program" >"$dir/out" 2>&1
  local code=$?
  chmod -R u+w "$dir" 2>/dev/null
  rm -rf "$dir/sandbox"
  if [ "$code" -eq 0 ]; then
    echo "  the exercise PASSED on $1"
    status=1
  elif grep -qF "$2" "$dir/out"; then
    echo "  $1 is caught"
  else
    echo "  $1 failed, but not where it should have:"
    grep "ASSERTION\|panic" "$dir/out" | tail -2 | sed 's/^/    /'
    status=1
  fi
}
prove_broken "a removal that follows a link" "a link's target survives rm_r: the directory outside the tree" \
  '        child_info = File.info?(child, follow_symlinks: false)
        remove_entry(child, child_info) if child_info' \
  '        child_info = File.info?(child)
        remove_entry(child, child_info) if child_info'
# Windows' lstat of `link\` is the link, separator or none, and the bits
# a file keeps there are one: the exercise asks both only elsewhere.
if [ "$PSEP" = ';' ]; then
  echo "  a trailing separator and a file's mode bits are POSIX's questions, so those two proofs are unmeasured on Windows"
else
prove_broken "link/ followed to its directory" "a link's target survives rm_r of link/" \
  '    while n > 1 && separator?(bytes[n - 1])' '    while false && separator?(bytes[n - 1])'
fi
prove_broken "a file read whole" "a 64 MiB copy allocates" \
  '    buffer = Pointer(UInt8).malloc(PIECE.to_u64)' \
  '    whole = File.read(from)
    __iyi_file_write(sink, whole.to_unsafe.as(Void*), whole.bytesize.to_u64)
    __iyi_close(source)
    __iyi_close(sink)
    File.chmod(to, mode)
    return if mode >= 0
    buffer = Pointer(UInt8).malloc(PIECE.to_u64)'
if [ "$PSEP" != ';' ]; then
prove_broken "permission bits dropped" "cp onto a file gives it the source's bits" \
  '    __iyi_close(sink)
    File.chmod(to, mode)' '    __iyi_close(sink)'
fi
prove_broken "a file copied onto itself" "cp of a file onto itself is refused" \
  '    raise "Cannot copy #{s} to #{target}: they are the same file" if File.same?(s, target)
    copy_file' '    copy_file'
# Without the guard the copy lists each directory it has just made and
# copies it again, deeper, until the stack runs out.
prove_broken "a tree copied into itself" "stack overflow: the stack ran out" \
  '      if landing == root || landing.starts_with?(inside)' '      if false'
if [ -n "$OTHER" ]; then
  prove_broken "a move across devices tried as a rename" "mv across devices moves a file" \
    '    if info.dev == landing.dev || info.dev == 0_i64 || landing.dev == 0_i64' '    if true'
  # Root writes anywhere, so there the exercise has no read-only source
  # to be refused, and this proof nothing to show.
  if [ "$(id -u 2>/dev/null)" = 0 ]; then
    echo "  root writes every directory, so the proof that a read-only source is refused is unmeasured"
  else
    prove_broken "a source it cannot remove copied anyway" "mv across devices refuses a source it could not remove" \
      '      raise "Cannot move #{s} to #{target}: #{stuck} is read-only, so the source could not be removed after the copy" if stuck' ''
  fi
else
  echo "  no second device, so the cross-device move's proof is unmeasured"
fi
prove_broken "a comparison that reads no bytes" "compare_file sees a difference at byte" \
  '      same = got == had && equal?(mine, theirs, got)' '      same = got == had'
prove_broken "the bytes after the last word left uncompared" "compare_file sees a difference at byte" \
  '    while i < n
      return false' '    while false
      return false'
prove_broken "a link to a directory copied as a directory" "cp_r copies a link out of the tree as a link" \
  '    if info.symlink?
' '    info = File.info(from) if info.symlink? && Dir.exists?(from)
    if info.symlink?
'

echo
if [ "$status" -eq 0 ]; then
  echo "std/file_utils: all plain, release, oracle, refusal and mutation checks passed"
else
  echo "std/file_utils: exercise failed"
fi
exit $status
