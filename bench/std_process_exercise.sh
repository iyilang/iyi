#!/usr/bin/env bash
# Exercises `std/process`.
#
#     bash bench/std_process_exercise.sh
#
# Proves the exercise holds plain and --release, and that each of the
# module's promises is a check that fails when the promise is taken out of
# a copy of the module:
#   * the arguments: Windows' quoting of a `"` loses its backslash, or on
#     Linux and darwin every argument is the first one - the child hears
#     something else;
#   * the two streams drained together: stderr read only after stdout has
#     ended - a child with a megabyte for each fills the stderr pipe and
#     waits, the parent waits for stdout's end, and the watchdog ends it;
#   * the wait parks: the end awaited by a blocking call - a sibling that
#     ticks every 50 ms ticks fewer than 10 times while the child sleeps;
#   * a cancelled run ends its child: the kill taken out - the run answers
#     Cancelled only once its child has slept its 20 seconds out;
#   * on Linux and darwin, a write to a child that stopped reading answers
#     EPIPE: with SIGPIPE left alone, the signal ends this program (141);
#   * on Linux, the child holds its three streams and nothing else: with
#     close_range taken out it holds this program's open file and epoll;
#   * on Linux, a TERM sent to a child before its execve is the child's:
#     with this program's handlers left in place in the child, the
#     child's TERM wakes this program's Signal.wait;
#   * on Linux, a pipe that could not be made is its errno: answered
#     EACCES, a program out of descriptors is told "permission denied".
# And that a program importing std/process and std/bool builds: a bare
# `Bool` in the module named std/bool's module, and it did not.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
PLATFORM=posix
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';'; PLATFORM=windows ;;
  Darwin) PSEP=':'; PLATFORM=darwin ;;
  *) PSEP=':'; PLATFORM=linux ;;
esac

# The patches below are written in python, and windows answers `python3`
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
if [ "$PLATFORM" = windows ]; then
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
EXERCISE="$REPO/bench/std_process_exercise.iyi"

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

echo "== the std/process exercise, plain build"
build_and_run "plain" process-plain

echo
echo "== every section reported"
for phrase in "arguments came back as they went" \
              "bytes through the child and back" \
              "stdin had 0 bytes" \
              "1048576 bytes of stdout and 1048576 of stderr" \
              "exit 3 is 3, and a panic is 1" \
              "cannot run no-such-program-iyi-process: no such program" \
              "a missing directory: no such directory" \
              "the child found its own file" \
              "a variable set here arrives there: değer-日本" \
              "one variable given and one removed, for the child alone" \
              "none read, and this program carries on" \
              "written straight to the terminal" \
              "a sibling ticked all its ticks while the child slept" \
              "answered Cancelled, with its child ended"; do
  if ! grep -q "$phrase" "$WORK/process-plain.out" 2>/dev/null; then
    echo "  missing: $phrase"
    status=1
  fi
done
if [ "$PLATFORM" = windows ]; then
  grep -q "a batch file runs under cmd.exe" "$WORK/process-plain.out" || { echo "  missing: the batch file's refusal"; status=1; }
  grep -q "a working directory Windows will not take" "$WORK/process-plain.out" || { echo "  missing: the long working directory"; status=1; }
else
  grep -q "signal 9, exit code 137" "$WORK/process-plain.out" || { echo "  missing: the signalled child"; status=1; }
  grep -q "a name held twice is removed whole for the child" "$WORK/process-plain.out" || { echo "  missing: a name held twice, removed for the child"; status=1; }
  if [ "$PLATFORM" = linux ]; then
    for phrase in "none of this program's descriptors" \
                  "refused with EMFILE" \
                  "children started under a stream of TERMs"; do
      grep -q "$phrase" "$WORK/process-plain.out" || { echo "  missing: $phrase"; status=1; }
    done
  fi
fi
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" process-release --release >/dev/null

echo
echo "== std/process compiles beside std/bool"
# A bare `Bool` in std/process named std/bool's module once both were
# imported, and a program importing the two did not compile.
printf 'module beside_bool\nimport std/process::{Process}\nimport std/bool\nputs Process.executable.nil? ^ true\n' \
  >"$WORK/beside_bool.iyi"
if "$IYI" build -o "$WORK/beside_bool" "$WORK/beside_bool.iyi" >"$WORK/beside_bool.log" 2>&1; then
  echo "  built"
else
  echo "  std/process beside std/bool: build failed"
  tail -5 "$WORK/beside_bool.log" | sed 's/^/    /'
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
# patched <name> <old> <new> [<old> <new>...]: a copy of std with the pairs
# replaced, each exactly once.
patched() {
  local name="$1"
  shift
  mkdir -p "$WORK/$name-std/std"
  "$PY" - "$REPO/src/std/process.iyi" "$WORK/$name-std/std/process.iyi" "$@" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
pairs = sys.argv[3:]
for old, new in zip(pairs[0::2], pairs[1::2]):
    if src.count(old) != 1:
        raise SystemExit("patch site missing: " + old)
    src = src.replace(old, new, 1)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
}

# prove <name> <what it shows> <sentence the run must end on> <pairs...>
prove() {
  local name="$1" shows="$2" sentence="$3"
  shift 3
  if ! patched "$name" "$@"; then
    echo "  the patch for $name did not apply"
    status=1
    return
  fi
  build "$name" "$WORK/$name-std${PSEP}$IYI_PATH" || return
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  the exercise PASSED with $shows"
    status=1
  elif ! grep -q "$sentence" "$WORK/$name.out"; then
    echo "  with $shows the exercise failed (exit $code), but not on \"$sentence\":"
    tail -5 "$WORK/$name.out" | sed 's/^/    /'
    status=1
  else
    echo "  $shows: exit $code, \"$(grep -m1 "$sentence" "$WORK/$name.out" | cut -c1-110)\""
  fi
}

if [ -z "$PY" ]; then
  echo "  no python on this machine, so the broken-module proofs are unmeasured"
else
  if [ "$PLATFORM" = windows ]; then
    prove misquoted "a quote's backslash dropped" "the child heard" \
      "(slashes * 2 + 1).times { into << '\\\\' }" "slashes.times { into << '\\\\' }"
  else
    prove oneargument "every argument the first one" "the child heard" \
      "list[index + 1] = c_text(args[index])" "list[index + 1] = c_text(args[0])"
  fi

  prove sequential "stderr read after stdout's end" "did not finish within" \
    "errors = capture ? g.spawn { child.read_all(false).as(String | Cancelled) } : nil" \
    "errors = nil.as(IyiTask(String | Cancelled)?)" \
    "          stdout = got
" \
    "          stdout = got
          later = child.read_all(false)
          stderr = later if later.is_a?(String)
"

  case "$PLATFORM" in
    windows)
      prove blocking "the end awaited by WaitForSingleObject" "a sibling ticked" \
        "if LibKernel32.RegisterWaitForSingleObject(pointerof(registration), @process, callback, words.as(Void*), -1, 8) == 0" \
        "if true"
      ;;
    darwin)
      prove blocking "the end awaited by waitpid" "a sibling ticked" \
        "queue = ::LibC.kqueue" "queue = -1"
      ;;
    *)
      # A kernel before 5.3 has no pidfd, and the end is polled: with
      # pidfd_open answering nothing the exercise holds all the same. And
      # the poll made a plain wait4 again blocks the thread.
      if ! patched nopidfd \
           "pidfd = __iyi_conc_syscall3(SYS_PIDFD_OPEN, @pid.to_i64, 0_i64, 0_i64)" "pidfd = -1_i64"; then
        echo "  the patch for nopidfd did not apply"
        status=1
      elif build nopidfd "$WORK/nopidfd-std${PSEP}$IYI_PATH"; then
        if "$WORK/nopidfd" >"$WORK/nopidfd.out" 2>&1 && grep -q "ALL CHECKS PASSED" "$WORK/nopidfd.out"; then
          echo "  without a pidfd, as on a kernel before 5.3, every check holds: the end is polled"
        else
          echo "  without a pidfd the exercise failed:"
          grep -m3 FAIL "$WORK/nopidfd.out" | sed 's/^/    /'
          status=1
        fi
      fi
      prove blocking "the end awaited by a blocking wait4, as on a kernel before 5.3" "a sibling ticked" \
        "pidfd = __iyi_conc_syscall3(SYS_PIDFD_OPEN, @pid.to_i64, 0_i64, 0_i64)" "pidfd = -1_i64" \
        "WNOHANG        =   1_i64" "WNOHANG        =   0_i64"
      prove inheriting "the child's other descriptors left open" "the child held" \
        "        if __iyi_conc_syscall3(SYS_CLOSE_RANGE, 3_i64, 0xFFFFFFFF_i64, 4_i64) < 0_i64 # CLOSE_RANGE_CLOEXEC" \
        "        if false"
      prove handlers "this program's handlers left in place in the child" "heard a TERM sent to a child" \
        "            if actions[0] > 1_u64 # neither SIG_DFL (0) nor SIG_IGN (1)" "            if false"
      prove misnumbered "a pipe's failure answered EACCES" "not refused with EMFILE" \
        "              return ProcessError.new(command, made)
" \
        "              return ProcessError.new(command, EACCES)
"
      ;;
  esac

  prove unenvironed "env: ignored" "with env: the child read" \
    "    environment = ProcessChild.environment(env)" "    environment = nil.as(Array(String)?)"
  if [ "$PLATFORM" != windows ]; then
    # A removal that takes the first entry of a name and leaves the second,
    # which the child then reads.
    prove firstonly "a removal that leaves a name's second entry" "a name held twice and removed" \
      "          removed[at] = true if index != -1
" ""
  fi

  prove unkilled "the kill taken out" "the cancelled run took" \
    "        child.kill
" ""

  # SIGPIPE's default is the end of the program, which is the proof: the
  # run ends with 128 + 13 and says nothing after the deaf child. Started
  # with the signal's default put back, because an ignored signal is
  # inherited across exec: macOS's runner starts every step with SIGPIPE
  # ignored, and there the unguarded write answered EPIPE and passed.
  sigpipe() { # sigpipe <name> <what> <old> <new>
    local name="$1" shows="$2"
    shift 2
    if ! patched "$name" "$@"; then
      echo "  the patch for $name did not apply"
      status=1
      return
    fi
    build "$name" "$WORK/$name-std${PSEP}$IYI_PATH" || return
    "$PY" -c 'import os, signal, sys; signal.signal(signal.SIGPIPE, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])' \
      "$WORK/$name" >"$WORK/$name.out" 2>&1
    local code=$?
    if [ "$code" -ne 141 ]; then
      echo "  with $shows the exercise ended $code, not by SIGPIPE (141):"
      tail -3 "$WORK/$name.out" | sed 's/^/    /'
      status=1
    else
      echo "  $shows: SIGPIPE ends the program (exit $code)"
    fi
  }
  case "$PLATFORM" in
    linux)
      sigpipe unmasked "SIGPIPE left alone" \
        "        __iyi_conc_syscall6(SYS_RT_SIGPROCMASK, 0_i64, masks.address.to_i64, (masks + 1).address.to_i64, 8_i64, 0_i64, 0_i64)
" ""
      ;;
    darwin)
      sigpipe unmasked "F_SETNOSIGPIPE taken out" \
        "        LibC.fcntl(ours, 73, 1) unless ours_reads     # F_SETNOSIGPIPE
" ""
      ;;
  esac
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/process exercise holds"
else
  echo "the std/process exercise did not hold"
fi
exit $status
