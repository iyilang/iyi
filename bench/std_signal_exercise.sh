#!/usr/bin/env bash
# Exercises `std/signal`.
#
#     bash bench/std_signal_exercise.sh
#
# Proves the exercise holds plain and --release; that on Linux and darwin a
# TERM sent from outside reaches the waiting fiber and the process ends on
# its own last line, where without the module the same TERM kills it; and
# that a broken module is caught both ways: a wait that never takes an
# arrival, and a handler never installed.
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
              "one request served, the listener closed, the group joined" \
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
  # A process that caught TERM and never finishes is a hang, not a pass.
  ( sleep 10; kill -KILL "$pid" 2>/dev/null ) &
  local killer=$!
  wait "$pid"
  local code=$?
  kill "$killer" 2>/dev/null
  wait "$killer" 2>/dev/null
  return "$code"
}

echo
echo "== a TERM from outside"
if [ "$WINDOWS" -eq 1 ]; then
  # A console control event is not something one process sends another
  # from a shell; the exercise's own Ctrl-Break above is Windows' proof.
  echo "  unmeasured on Windows: TERM is its console's close event"
else
  external signal-plain
  code=$?
  if [ "$code" -ne 0 ]; then
    echo "  exited $code"
    status=1
  elif ! grep -q "stopped on TERM" "$WORK/signal-plain.out"; then
    echo "  exited 0 without saying why:"
    sed 's/^/    /' "$WORK/signal-plain.out"
    status=1
  else
    echo "  the waiting fiber took TERM and the process ended on its last line"
  fi
fi

echo
echo "== proving the checks can fail when the module is broken"
patched() { # patched <name> <old> <new>: a copy of std with one line changed
  local name="$1" old="$2" new="$3"
  mkdir -p "$WORK/$name-std/std"
  OLD="$old" NEW="$new" "$PY" - "$REPO/src/std/signal.iyi" "$WORK/$name-std/std/signal.iyi" <<'PY'
import os, sys
src = open(sys.argv[1]).read()
old, new = os.environ["OLD"], os.environ["NEW"]
if src.count(old) != 1:
    raise SystemExit("patch site missing: " + old)
open(sys.argv[2], "w").write(src.replace(old, new, 1))
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
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/signal exercise holds"
else
  echo "the std/signal exercise did not hold"
fi
exit $status
