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
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src:$REPO/samples/iyi"
export IYI_FILE_SANDBOX="$WORK/sandbox"
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
echo "== proving the checks can fail when the module is broken"
mkdir -p "$WORK/patched/std"
python3 - <<PY
from pathlib import Path
src = Path("$REPO/src/std/file.iyi").read_text()
old = '    info(path).size\n  end'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/file.iyi").write_text(src.replace(old, '    info(path).size + 1_i64\n  end', 1))
PY
if [ $? -ne 0 ]; then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_file_exercise.iyi" -- "$WORK/sandbox" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  a broken file is caught"
fi

echo
echo "== proving a truncating touch is caught"
mkdir -p "$WORK/patched_touch/std"
python3 - <<PY
from pathlib import Path
src = Path("$REPO/src/std/file.iyi").read_text()
old = '    File.write(p, "") unless File.exists?(p)'
if old not in src:
    raise SystemExit("touch patch site missing")
Path("$WORK/patched_touch/std/file.iyi").write_text(src.replace(old, '    File.write(p, "")', 1))
PY
if [ $? -ne 0 ]; then
  echo "  the touch patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched_touch:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_file_exercise.iyi" -- "$WORK/sandbox" >"$WORK/mut_touch.out" 2>&1; then
  echo "  the exercise PASSED on a truncating touch"
  status=1
else
  echo "  a truncating touch is caught"
fi

echo
echo "== what file refuses"
refuses() { # refuses <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expr="$4"
  printf 'module main\n\nimport std/file\nusing std/file::{File}\n\n%s\n' "$expr" > "$WORK/$name.iyi"
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
