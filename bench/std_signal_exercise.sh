#!/usr/bin/env bash
# Exercises `std/signal`.
#
#     bash bench/std_signal_exercise.sh
#
# Proves the exercise holds plain and --release; that on Linux and darwin a
# TERM sent from outside reaches the waiting fiber and the process ends on
# its own last line, where without the module the same TERM kills it; that
# a second fiber waiting beside the first is refused by name; that an
# ignored signal leaves the process alive and a reset one ends it again;
# and that a broken module is caught: a wait that never takes an arrival,
# a handler never installed, a `Signal.each` that never runs its block, an
# arrival an ignore did not drop, an ignore that keeps the default, and a
# reset that keeps the signal ignored.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
WINDOWS=0
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';'; WINDOWS=1 ;;
  *) PSEP=':' ;;
esac

# the patches below are written in python, and windows answers `python3`
# with a store stub that prints and exits rather than running it, so the
# interpreter is measured here instead of assumed.
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
if [ "$WINDOWS" -eq 1 ]; then
  REPO="$(cygpath -m "$REPO")"
  WORK="$(cygpath -m "$WORK")"
fi

ORIG_IYI_PATH="${IYI_PATH:-}"
cleanup() {
  rm -rf "$WORK"
  if [ -n "$ORIG_IYI_PATH" ]; then
    export IYI_PATH="$ORIG_IYI_PATH"
  else
    unset IYI_PATH
  fi
}
trap cleanup EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"
EXERCISE="$REPO/bench/std_signal_exercise.iyi"

build() { # build <name> <search path> [flags...]
  local name="$1" path="$2"
  shift 2
  if ! IYI_PATH="$path" "$IYI" build "$@" -o "$WORK/$name" "$EXERCISE" >"$WORK/$name.build.log" 2>&1; then
    echo "  $name: build failed"
    tail -12 "$WORK/$name.build.log" | sed 's/^/    /'
    status=1
    return 1
  fi
}

build_and_run() { # build_and_run <label> <name> [flags...]
  local label="$1" name="$2"
  shift 2
  build "$name" "$IYI_PATH" "$@" || return 1
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
}

echo "== the std/signal exercise, plain build"
build_and_run "plain" signal-plain

echo
echo "== every section reported"
for phrase in "Signal.wait answered INT, and the process lived" \
              "the next wait answered at once" \
              "two arrivals nobody waited for are one" \
              "one request served, the listener closed, the group joined" \
              "ran its block for" \
              "an arrival kept before the ignore was dropped" \
              "left the process alive" \
              "the waiter left with Cancelled"; do
  if ! grep -q "$phrase" "$WORK/signal-plain.out" 2>/dev/null; then
    echo "  missing: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" signal-release --release >/dev/null

# Starts `<binary> external`, sends TERM once it says it is waiting, and
# answers the exit status; the output is left in <name>.out.
external() { # external <name>
  local name="$1" pid tries=0
  "$WORK/$name" external >"$WORK/$name.out" 2>&1 &
  pid=$!
  while ! grep -q "ready" "$WORK/$name.out" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -gt 100 ]; then
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      echo "  $name never said ready"
      return 125
    fi
    sleep 0.1
  done
  kill -TERM "$pid"
  # A process that caught TERM and never finishes is a hang, not a pass:
  # given ten seconds, then killed. Watched from this shell and not from a
  # `( sleep 10; kill ) &` beside it - that subshell was killed a moment
  # after it forked, before bash had reset the traps it inherited, and ran
  # this script's EXIT trap: `rm -rf "$WORK"` under the step still reading
  # it. One run in four under load lost its output file that way.
  local waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -KILL "$pid" 2>/dev/null
  wait "$pid"
  return $?
}

# Windows' TERM is its console being closed, and a person closes it: the
# window's close button is WM_CLOSE to the console window, and Windows turns
# that into CTRL_CLOSE_EVENT for every process attached to it. So the program
# is started in a console of its own, hidden, and once it says it is waiting
# this attaches to that console long enough to find its window and posts
# the close. Prints the program's exit status as Windows spells it and
# answers 0 when that was 0; a program still there ten seconds after the
# close - Windows' own deadline for one is five - is killed and answers 124.
console_close() { # console_close <name>
  "$PY" - "$WORK/$1.exe" "$WORK/$1.out" <<'PY'
import ctypes, subprocess, sys, time
from ctypes import wintypes
exe, out = sys.argv[1], sys.argv[2]
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
u32 = ctypes.WinDLL("user32", use_last_error=True)
k32.GetConsoleWindow.restype = wintypes.HWND
u32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
si = subprocess.STARTUPINFO()
si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
si.wShowWindow = 0
with open(out, "w") as f:
    p = subprocess.Popen([exe, "external"], stdout=f, stderr=subprocess.STDOUT,
                         creationflags=subprocess.CREATE_NEW_CONSOLE, startupinfo=si)
deadline = time.time() + 10
while time.time() < deadline and "ready" not in open(out).read():
    time.sleep(0.1)
if "ready" not in open(out).read():
    p.kill(); print("  never said ready"); sys.exit(125)
k32.FreeConsole()
attached = k32.AttachConsole(p.pid)
hwnd = k32.GetConsoleWindow() if attached else None
k32.FreeConsole()
if not hwnd:
    p.kill(); print("  no window for the program's console (attach %s, error %d)" % (bool(attached), ctypes.get_last_error())); sys.exit(125)
u32.PostMessageW(hwnd, 0x0010, 0, 0)
try:
    code = p.wait(timeout=10) & 0xFFFFFFFF
except subprocess.TimeoutExpired:
    p.kill(); print("  still running ten seconds after the close"); sys.exit(124)
print("  exit status 0x%08x" % code)
sys.exit(0 if code == 0 else 1)
PY
}

echo
echo "== a TERM from outside"
if [ "$WINDOWS" -eq 1 ] && [ -z "$PY" ]; then
  echo "  no python on this machine to close the program's console, so TERM from outside is unmeasured"
else
  if [ "$WINDOWS" -eq 1 ]; then
    said="$(console_close signal-plain)"
  else
    external signal-plain
  fi
  code=$?
  if [ "$code" -ne 0 ]; then
    echo "  exited $code"
    [ "$WINDOWS" -eq 1 ] && echo "$said"
    status=1
  elif ! grep -q "stopped on TERM" "$WORK/signal-plain.out"; then
    echo "  exited 0 without saying why:"
    sed 's/^/    /' "$WORK/signal-plain.out"
    status=1
  elif [ "$WINDOWS" -eq 1 ]; then
    echo "  its console closed, the waiting fiber took TERM and the process ended on its last line"
  else
    echo "  the waiting fiber took TERM and the process ended on its last line"
  fi
fi

# An ignored signal leaves the process alive, and after `Signal.reset` the
# same signal ends it: TERM on Linux and darwin, which ends it as 143, and
# on Windows a Ctrl-Break into its own console.
echo
echo "== a reset gives the signal its default back"
reset_run() { # reset_run <name>: runs <name> reset; 0 when it held
  # Not under `timeout`, which reports a child killed by TERM as 15; the
  # run ends by itself 200 ms after the reset signal either way. In a
  # subshell that waits for it, so bash's "Terminated" goes to the file.
  ("$WORK/$1" reset; exit $?) >"$WORK/$1.reset.out" 2>&1
  local code=$?
  if ! grep -q "left the process alive" "$WORK/$1.reset.out"; then
    echo "  the ignored signal ended it (exit $code)"
    return 1
  elif grep -q "outlived" "$WORK/$1.reset.out" || [ "$code" -eq 0 ]; then
    echo "  the process outlived the reset signal (exit $code)"
    return 1
  elif [ "$WINDOWS" -eq 0 ] && [ "$code" -ne 143 ]; then
    echo "  after the reset it ended $code, not by TERM (143)"
    return 1
  fi
  echo "  an ignored signal left it alive, and after the reset the signal ended it (exit $code)"
}
reset_run signal-plain || { sed 's/^/    /' "$WORK/signal-plain.reset.out"; status=1; }

# And a signal the program did not name keeps its default: waiting for TERM
# alone, a Ctrl-Break still ends the process, as it ends one that waits for
# nothing. The one console handler answered every event, and TERM's wait
# swallowed Ctrl-C and Ctrl-Break. The program makes a console of its own
# (`own_console`), so the break is sent in there, the way `console_close`
# finds its window, by a Python that ignores the break itself.
if [ "$WINDOWS" -eq 1 ] && [ -n "$PY" ]; then
  echo
  echo "== a Ctrl-Break nobody waits for"
  said="$("$PY" - "$WORK/signal-plain.exe" "$WORK/break.out" <<'PY'
import ctypes, subprocess, sys, time
from ctypes import wintypes
exe, out = sys.argv[1], sys.argv[2]
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
with open(out, "w") as f:
    p = subprocess.Popen([exe, "external"], stdout=f, stderr=subprocess.STDOUT)
deadline = time.time() + 10
while time.time() < deadline and "ready" not in open(out).read():
    time.sleep(0.1)
if "ready" not in open(out).read():
    p.kill(); print("never said ready"); sys.exit(0)
ignore = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.DWORD)(lambda event: True)
k32.FreeConsole()
if not k32.AttachConsole(p.pid):
    p.kill(); print("could not attach to its console (%d)" % ctypes.get_last_error()); sys.exit(0)
k32.SetConsoleCtrlHandler(ignore, True)
k32.GenerateConsoleCtrlEvent(1, 0)
time.sleep(0.2)
k32.FreeConsole()
try:
    print("0x%08x" % (p.wait(timeout=10) & 0xFFFFFFFF))
except subprocess.TimeoutExpired:
    p.kill(); print("still running ten seconds after the break")
PY
)"
  if [ "$said" = "0xc000013a" ]; then
    echo "  waiting for TERM, the program was ended by a Ctrl-Break, as Windows ends it"
  else
    echo "  waiting for TERM, a Ctrl-Break answered: $said (0xc000013a is Windows' own end)"
    sed 's/^/    /' "$WORK/break.out"
    status=1
  fi
fi

# One fiber waits at a time, on every platform: Linux and darwin refuse a
# second reader of the pipe in the poller, and Windows refuses a second
# park on the one overlapped slot the console handler posts to. Windows
# let the second park write its slot over the first's, and the first never
# woke, not even on the next Ctrl-Break. In a child of its own, because
# the refusal is a panic and the exercise must not print one.
echo
echo "== two fibers waiting at once are refused"
cat > "$WORK/waiters.iyi" <<'IYI'
module main

import std/signal::{Signal}

group do |g|
  g.spawn { Signal.wait(Signal::INT); 0 }
  g.spawn { Signal.wait(Signal::INT); 0 }
  0
end
puts "two waiters were let in"
IYI
if ! "$IYI" build -o "$WORK/waiters" "$WORK/waiters.iyi" >"$WORK/waiters.build.log" 2>&1; then
  echo "  waiters: build failed"
  tail -12 "$WORK/waiters.build.log" | sed 's/^/    /'
  status=1
elif timeout -k 5 30 "$WORK/waiters" >"$WORK/waiters.out" 2>&1; then
  echo "  two waiters were let in"; status=1
elif ! grep -q "two fibers reading one fd" "$WORK/waiters.out"; then
  echo "  two waiters were refused, but not by name (or hung, and were killed):"
  sed 's/^/    /' "$WORK/waiters.out"; status=1
else
  echo "  two waiters: exits 1 at \"$(grep -m1 'two fibers' "$WORK/waiters.out" | sed 's/^iyi: panic: //')\""
fi

echo
echo "== proving the checks can fail when the module is broken"
patched() { # patched <name> <old> <new>: a copy of std with one line changed
  local name="$1" old="$2" new="$3"
  mkdir -p "$WORK/$name-std/std"
  OLD="$old" NEW="$new" "$PY" - "$REPO/src/std/signal.iyi" "$WORK/$name-std/std/signal.iyi" <<'PY'
import os, sys
src = open(sys.argv[1], encoding="utf-8").read()
old, new = os.environ["OLD"], os.environ["NEW"]
if src.count(old) != 1:
    raise SystemExit("patch site missing: " + old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
}
if [ -z "$PY" ]; then
  echo "  no python on this machine, so the broken-module proof is unmeasured"
else
  # An arrival that is recorded and never taken: every wait parks forever,
  # and the watchdog beside it is what ends the program.
  if ! patched untaken 'if @@pending & bit != 0_u64' 'if false'; then
    echo "  the patch did not apply"
    status=1
  elif build untaken "$WORK/untaken-std${PSEP}$IYI_PATH"; then
    if "$WORK/untaken" >"$WORK/untaken.out" 2>&1; then
      echo "  the exercise PASSED with a wait that takes nothing"
      status=1
    elif ! grep -q "a signal did not arrive within five seconds" "$WORK/untaken.out"; then
      echo "  a wait that takes nothing failed, but not on the watchdog:"
      sed 's/^/    /' "$WORK/untaken.out"
      status=1
    else
      echo "  a wait that takes nothing is caught by the watchdog"
    fi
  fi
  # No handler: TERM keeps its default, and ends the process mid-wait.
  if [ "$WINDOWS" -eq 0 ]; then
    if ! patched uninstalled '          handle(signal)' '          nil'; then
      echo "  the patch did not apply"
      status=1
    elif build uninstalled "$WORK/uninstalled-std${PSEP}$IYI_PATH"; then
      external uninstalled
      code=$?
      # 128 + 15: ended by the signal itself, and nothing else.
      if [ "$code" -ne 143 ]; then
        echo "  with no handler installed the external TERM answered $code, not death by TERM (143)"
        status=1
      else
        echo "  with no handler, TERM kills the process (exit $code)"
      fi
    fi
  else
    # A close read as INT: the waiter for TERM never wakes, the handler
    # holds the close as it must, and Windows ends the process at its
    # deadline with STATUS_CONTROL_C_EXIT rather than the program's 0.
    if ! patched closeasint 'signal = event <= 1 ? 2 : 15' 'signal = 2'; then
      echo "  the patch did not apply"
      status=1
    elif build closeasint "$WORK/closeasint-std${PSEP}$IYI_PATH"; then
      said="$(console_close closeasint)"
      code=$?
      if [ "$code" -eq 0 ] || grep -q "stopped on TERM" "$WORK/closeasint.out"; then
        echo "  the program took TERM from a close that it read as INT"
        status=1
      elif ! printf '%s\n' "$said" | grep -q "exit status 0xc000013a"; then
        echo "  a close read as INT ended some other way than at Windows' deadline:"
        echo "$said"
        status=1
      else
        echo "  a close read as INT is never TERM: Windows ended the process at its deadline (STATUS_CONTROL_C_EXIT)"
      fi
    fi
  fi

  # The exercise has watchdogs; a limit, where `timeout` exists, is the
  # backstop for a broken copy that hangs anyway.
  LIMIT=""
  command -v timeout >/dev/null 2>&1 && LIMIT="timeout -k 5 60"
  # broken <name> <label> <old> <new> <said> [absent]: the exercise built
  # on a copy with <old> replaced fails, says <said>, and never <absent>.
  broken() {
    local name="$1" label="$2" old="$3" new="$4" said="$5" absent="${6:-}"
    if ! patched "$name" "$old" "$new"; then
      echo "  the $label patch did not apply"
      status=1
      return
    fi
    build "$name" "$WORK/$name-std${PSEP}$IYI_PATH" || return
    $LIMIT "$WORK/$name" >"$WORK/$name.out" 2>&1
    local code=$?
    if [ "$code" -eq 0 ]; then
      echo "  the exercise PASSED with $label"
      status=1
    elif ! grep -q "$said" "$WORK/$name.out" || { [ -n "$absent" ] && grep -q "$absent" "$WORK/$name.out"; }; then
      echo "  $label failed, but not where it should have (exit $code):"
      tail -3 "$WORK/$name.out" | sed 's/^/    /'
      status=1
    else
      echo "  $label is caught (exit $code)"
    fi
  }
  broken neverhandled "a Signal.each that never runs its block" \
    '      block.call(got)' '      nil' "FAIL: the handler saw"
  if [ "$WINDOWS" -eq 0 ]; then
    # The pipe not drained: the byte that arrived before the ignore is read
    # by the next wait, which answers at once.
    broken undropped "an arrival an ignore did not drop" \
      '      drain if @@read_fd >= 0' '      nil' "FAIL: an arrival kept before the ignore"
    broken unignored "an ignore that keeps the default" \
      'disposition(signal.value, ignored ? 1_u64 : 0_u64)' 'disposition(signal.value, 0_u64)' \
      "an arrival kept before the ignore was dropped" "left the process alive"
    reset_old='disposition(signal.value, ignored ? 1_u64 : 0_u64)'
    reset_new='disposition(signal.value, 1_u64)'
  else
    broken undropped "an arrival an ignore did not drop" \
      '        break if seen & bit == 0_u64 || @@arrived.compare_and_set(seen, seen & (0xFFFFFFFFFFFFFFFF_u64 ^ bit))[1]' \
      '        break' "FAIL: an arrival kept before the ignore"
    broken unignored "an ignore that keeps the default" \
      '      return 1 if @@ignored.get & bit != 0_u64' '      nil' \
      "an arrival kept before the ignore was dropped" "left the process alive"
    reset_old='@@ignored.set(ignored ? @@ignored.get | bit : @@ignored.get & (0xFFFFFFFFFFFFFFFF_u64 ^ bit))'
    reset_new='@@ignored.set(@@ignored.get | bit)'
  fi
  # A reset that leaves the signal ignored: the process outlives it.
  if ! patched stillignored "$reset_old" "$reset_new"; then
    echo "  the patch did not apply"
    status=1
  elif build stillignored "$WORK/stillignored-std${PSEP}$IYI_PATH"; then
    said="$(reset_run stillignored)"
    if printf '%s\n' "$said" | grep -q "outlived the reset"; then
      echo "  a reset that keeps the signal ignored is caught: the process outlived it"
    else
      echo "  a reset that keeps the signal ignored was not caught:"
      printf '%s\n' "$said" | sed 's/^/  /'
      status=1
    fi
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/signal exercise holds"
else
  echo "the std/signal exercise did not hold"
fi
exit $status
