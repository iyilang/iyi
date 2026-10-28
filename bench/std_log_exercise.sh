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
old = 'entries << entry'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/log.iyi").write_text(src.replace(old, '# entries << entry', 1))
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
old = '@parent.nil? && @source.empty? ? name'
if src.count(old) != 1:
    raise SystemExit("patch site missing")
Path("$WORK/rootdot/std/log.iyi").write_text(src.replace(old, '@source.empty? ? name', 1))
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
    '    raise "AsyncBackend: an entry written after close" if @closed.get != 0_u8
' '' \
    "the write after close" "actual: the block ended without one"
fi

# A logger is Share, and twelve workers log through one constant at once,
# to one file through one IOBackend: every line must come out whole - its
# timestamp, its level and source, its worker and number, and a tail of x
# as long as the number says - and every line once. The broken copy is
# the backend with its lock taken out, claiming Share: every worker writes
# the one IO's buffer at once. And the constant, reached from the parallel
# block through a call, is not warned about; its broken copy is a logger
# whose level field is named for its setter `level=`, the shape that made
# the warning, which std/log's own locks then refuse.
echo
echo "== twelve workers logging through one constant"
cat > "$WORK/whole.iyi" <<'IYI'
module whole_lines

import std/log::{Log, IOBackend, Severity}
import std/file::{File}

LOG = Log.for("gate")

PER     = 4000
WORKERS = 12

def burst(k : Int32) : Int32
  i = 0
  while i < PER
    LOG.info("worker #{k} line #{i} #{"x" * (i % 89)}.")
    i = i + 1
  end
  i
end

# The line's worker and number when it is whole, or nil.
def read_line(line : String) : {Int32, Int32}?
  mark = " INFO - gate: worker "
  return nil unless line.bytesize > 27 + mark.bytesize && line.byte_index(mark) == 27 && line[26, 1] == "Z"
  parts = line[27 + mark.bytesize, line.bytesize - 27 - mark.bytesize].split(' ')
  return nil unless parts.size == 4 && parts[1] == "line"
  k = parts[0].to_i?
  i = parts[2].to_i?
  return nil unless k.is_a?(Int32) && i.is_a?(Int32) && k >= 0 && k < WORKERS && i >= 0 && i < PER
  return nil unless parts[3] == "x" * (i % 89) + "."
  {k, i}
end

IyiWorkers.count = WORKERS
path = Program.args[0]
file = File.open(path, "w")
Log.setup(Severity::Info, IOBackend.new(file))
# Read inside the group, so a worker that panicked - which the broken
# copy's can, its IO's buffer torn - is counted here and not the group's
# own panic.
died = 0
group do |g|
  handles = [] of IyiTask(Int32)
  WORKERS.times do |k|
    handles << g.spawn_parallel { burst(k) }
  end
  handles.each { |handle| died = died + 1 unless handle.value == PER }
end
file.close
seen = Array(Int32).new(WORKERS * PER, 0)
torn = 0
File.read(path).split('\n').each do |line|
  next if line.empty?
  got = read_line(line)
  if got
    seen[got[0] * PER + got[1]] += 1
  else
    torn = torn + 1
  end
end
missing = 0
seen.each { |n| missing = missing + 1 if n != 1 }
if torn > 0 || missing > 0 || died > 0
  puts "FAIL: #{torn} lines were not whole, #{missing} of #{WORKERS * PER} were not written exactly once, and #{died} of #{WORKERS} workers died"
  exit(1)
end
puts "#{WORKERS * PER} lines from #{WORKERS} workers, each whole and each once"
IYI
# copy_log <dir> <old> <new> [<old> <new>]...: src/std/log.iyi with each
# old text, which must be there once, replaced, into <dir>/std.
copy_log() {
  local dir="$1"
  shift
  mkdir -p "$WORK/$dir/std"
  DEST="$WORK/$dir/std/log.iyi" "$PY" - "$@" <<PY
import os, sys
from pathlib import Path
src = Path("$REPO/src/std/log.iyi").read_text()
pairs = sys.argv[1:]
for old, new in zip(pairs[0::2], pairs[1::2]):
    if src.count(old) != 1:
        raise SystemExit("patch site missing or not unique: " + old)
    src = src.replace(old, new, 1)
Path(os.environ["DEST"]).write_text(src)
PY
}
if ! "$IYI" build -o "$WORK/whole" "$WORK/whole.iyi" > "$WORK/whole.build" 2>&1; then
  echo "  FAIL: the twelve-worker program did not build"
  tail -12 "$WORK/whole.build"
  status=1
elif ! "$WORK/whole" "$WORK/whole.log" > "$WORK/whole.out" 2>&1; then
  echo "  FAIL: $(cat "$WORK/whole.out")"
  status=1
else
  echo "  $(cat "$WORK/whole.out")"
fi
if "$IYI" check --error-on-warnings "$WORK/whole.iyi" > "$WORK/whole.check" 2>&1; then
  echo "  LOG, a constant Logger reached from the parallel block, checks under --error-on-warnings"
else
  echo "  FAIL: the constant logger was warned about or refused:"
  sed 's/^/    /' "$WORK/whole.check" | head -12
  status=1
fi
if [ -z "$PY" ]; then
  echo "  skipped the broken copies: no working python3"
else
  # The race the copy makes can end some other way than by name - a
  # fault, a torn buffer the run dies of - so a run that does not exit 1
  # at the sentence is run again, up to five times.
  if ! copy_log unlocked \
       '  @out : Mutex(IyiIO)' '  @out : IyiIO' \
       '    @out = Mutex.new { IyiIO.new(handle) }' '    @out = IyiIO.new(handle)' \
       '      return unless @out.lock { |io| IOBackend.put(io, line) }.is_a?(Cancelled)' '      return IOBackend.put(@out, line)' \
       'pub class IOBackend < Backend' '@[Share]
pub class IOBackend < Backend'; then
    echo "  the unlocked patch did not apply"
    status=1
  elif ! IYI_PATH="$WORK/unlocked${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/whole-unlocked" "$WORK/whole.iyi" > "$WORK/unlocked.build" 2>&1; then
    echo "  the unlocked copy did not build:"
    tail -12 "$WORK/unlocked.build"
    status=1
  else
    for attempt in 1 2 3 4 5; do
      "$WORK/whole-unlocked" "$WORK/unlocked.log" > "$WORK/unlocked.out" 2>&1
      code=$?
      [ "$code" -eq 1 ] && grep -q "^FAIL: " "$WORK/unlocked.out" && break
    done
    if [ "$code" -eq 1 ] && grep -q "^FAIL: " "$WORK/unlocked.out"; then
      echo "  a backend without its lock is caught: $(grep -m1 '^FAIL: ' "$WORK/unlocked.out" | sed 's/^FAIL: //')"
    else
      echo "  a backend without its lock was not caught (exit $code):"
      tail -3 "$WORK/unlocked.out" | sed 's/^/    /'
      status=1
    fi
  fi
  if ! copy_log setter '  @own_level : Atomic(Int32)' '  @level : Atomic(Int32)' \
       '    @own_level = Atomic(Int32).new(level ? level.value : INHERIT)' '    @level = Atomic(Int32).new(level ? level.value : INHERIT)' \
       '    @own_level.get
' '    @level.get
' \
       '    @own_level.set(lvl ? lvl.value : INHERIT)' '    @level.set(lvl ? lvl.value : INHERIT)' \
       '    own = @own_level.get' '    own = @level.get'; then
    echo "  the setter patch did not apply"
    status=1
  elif IYI_PATH="$WORK/setter${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" check --error-on-warnings "$WORK/whole.iyi" > "$WORK/setter.check" 2>&1; then
    echo "  a logger with a field its setter names PASSED the check"
    status=1
  elif ! grep -qF 'Std::Log::Logger'"'"'s field @level is given a setter `level=`' "$WORK/setter.check"; then
    echo "  a logger with a field its setter names failed the check, but not by name:"
    head -6 "$WORK/setter.check" | sed 's/^/    /'
    status=1
  else
    echo "  a logger whose level field its setter names is caught: not Share"
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/log exercise holds"
else
  echo "the std/log exercise did not hold"
fi
exit $status
