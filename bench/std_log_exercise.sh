#!/usr/bin/env bash
# Exercises `std/log`: MemoryBackend records Log.info.
#
#     bash bench/std_log_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The gate runs the compiler the caller names; bin/iyi is a POSIX shell
# wrapper a Windows build cannot run.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on that path, so the
# patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# The negative proofs are patched by python, and a machine can answer
# `python3` with a store stub that prints a refusal instead of running, so
# the interpreter is resolved once and proven to run before it is trusted.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_log_exercise.iyi" \
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

echo "== the std/log exercise, plain build"
build_and_run "plain" log-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/log-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every log section reported"
for phrase in "== info" "== child" "== empty segments" "== data and context" "== the level from LOG_LEVEL" "== written by a thread of its own"; do
  if ! grep -q "$phrase" "$WORK/log-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" log-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/log-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched/std"
  "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/log.iyi").read_text()
old = '@entries << entry'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/log.iyi").write_text(src.replace(old, '# @entries << entry', 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_log_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on a broken module"
    status=1
  else
    echo "  a broken log is caught"
  fi

  # A child's source dropped its dot whenever the parent's source was
  # empty, which a child named "" has too: `Log.for(".db")` answered "db".
  mkdir -p "$WORK/rootdot/std"
  "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/log.iyi").read_text()
old = 'child_source = @parent.nil? && @source.empty? ? name'
if src.count(old) != 1:
    raise SystemExit("patch site missing")
Path("$WORK/rootdot/std/log.iyi").write_text(src.replace(old, 'child_source = @source.empty? ? name', 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the empty-segment patch did not apply"
    status=1
  elif IYI_PATH="$WORK/rootdot${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_log_exercise.iyi" >"$WORK/rootdot.out" 2>&1; then
    echo "  the exercise PASSED with a leading dot dropped from the source"
    status=1
  elif ! grep -q "ASSERTION FAILED: leading dot" "$WORK/rootdot.out"; then
    echo "  a dropped leading dot failed somewhere else:"
    sed 's/^/    /' "$WORK/rootdot.out"
    status=1
  else
    echo "  a source that drops a leading dot is caught"
  fi

  # Data and context, each mechanism taken out of a copy that compiles:
  # the exercise must stop at the check written for it - an assertion's
  # message, or with a sixth argument, that text as it is said.
  caught_at() { # caught_at <dir> <label> <old> <new> <check> [said]
    local dir="$1" label="$2"
    mkdir -p "$WORK/$dir/std"
    OLD="$3" NEW="$4" DEST="$WORK/$dir/std/log.iyi" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/log.iyi").read_text()
old, new = os.environ["OLD"], os.environ["NEW"]
if src.count(old) != 1:
    raise SystemExit("patch site missing or not unique")
Path(os.environ["DEST"]).write_text(src.replace(old, new, 1))
PY
    if [ $? -ne 0 ]; then
      echo "  the $label patch did not apply"
      status=1
    elif IYI_PATH="$WORK/$dir${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_log_exercise.iyi" >"$WORK/$dir.out" 2>&1; then
      echo "  the exercise PASSED with $label"
      status=1
    elif grep -qF -- "${6:-ASSERTION FAILED: $5}" "$WORK/$dir.out"; then
      echo "  $label is caught"
    else
      echo "  $label failed, but not at \"$5\""
      tail -3 "$WORK/$dir.out" | sed 's/^/    /'
      status=1
    fi
  }
  caught_at unbound "a bound logger that forgets its data" \
    '    Logger.new(@source, nil, nil, self, node)' '    Logger.new(@source, nil, nil, self, nil)' \
    "a bound logger's data, then the call's"
  caught_at contextless "an entry without the task's context" \
    '    found = Log.context
' '    found = {} of String => String
' \
    "a context's data on every entry in its block"
  caught_at unrestored "a context left open after its block" \
    '    defer restore(id, own)
' '' \
    "the inner context closes with its block"
  caught_at orphaned "a task that does not look to its starter" \
    '        fiber = group.owner' '        return nil' \
    "a task finds its starter's context"
  caught_at unquoted "a value written without its quotes" \
    '    plain ? value : value.inspect' '    value' \
    "a value with a space, a quote or = in it, or none, quoted"
  caught_at envless "a level that never reads LOG_LEVEL" \
    '        level = Severity.parse?(name.strip) || raise' '        level = default_level || raise' \
    "LOG_LEVEL sets the level"
  # The writer thread's lines, each without its end: one line of them all.
  caught_at endless "an async entry queued without its newline" \
    '    line = @formatter.format(entry) + "\n"' '    line = @formatter.format(entry)' \
    "every entry, in order, written by the thread"
  caught_at late "an async entry taken after close" \
    '    raise "AsyncBackend: an entry written after close" if @closed
' '' \
    "the write after close" "actual: the block ended without one"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/log exercise holds"
else
  echo "the std/log exercise did not hold"
fi
exit $status
