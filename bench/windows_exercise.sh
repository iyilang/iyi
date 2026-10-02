#!/usr/bin/env bash
# Stage 10 Windows exercise driver: the collector on Windows x86_64.
#
#   bash bench/windows_exercise.sh
#
# Verifies clean cross-compilation for Windows x86_64, reads the stopped
# thread's register spill out of the object, runs the exercise on the host,
# and proves the checks can fail when the collector is broken.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The compiler, overridable: `bin/iyi` is a POSIX shell wrapper, and on
# Windows the caller is the only one who knows where the real binary is.
IYI="${IYI:-$REPO/bin/iyi}"
# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on the search path, so
# the patched copy is never read and the proof that a check can fail
# quietly stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac
trap 'rm -rf "$WORK"' EXIT

# The disassembler for the cross-compiled object: GNU objdump reads COFF
# x86-64 on a Linux host, llvm-objdump anywhere LLVM is.
DISASM=""
for tool in objdump llvm-objdump; do
  if command -v "$tool" > /dev/null 2>&1; then DISASM="$tool"; break; fi
done

# Whether a Windows object's `IyiThread.stop_here` stores rdi and rsi into
# the stopped thread's spill: Windows x64 preserves both across a call, so
# a value held there across a stop deferred to the allocator's exit is a
# root only if the spill has it. The destination is pinned to rcx, the
# first slot after rbx and rbp.
stop_here_spills() {
  local body
  body="$("$DISASM" -d "$1" | awk '/<[^>]*stop_here[^>]*>:$/{f=1; next} f && /^$/{exit} f' | tr -d ' \t')"
  [ -n "$body" ] && grep -q '%rdi,0x10(%rcx)' <<< "$body" && grep -q '%rsi,0x18(%rcx)' <<< "$body"
}

status=0

echo "== Stage 10: Windows x86_64 Collector Verification =="

# 1. Host Native Run
echo
echo "== Host Run (Native) =="
if "$IYI" run "$REPO/bench/windows_exercise.iyi" > "$WORK/host.out" 2>&1; then
  echo "  host run succeeded"
else
  echo "  host run failed"
  cat "$WORK/host.out"
  status=1
fi

for check in "allocation:" "strings:" "stack:" "globals:" "registers:" "survival:" "sweep:" "reuse:" "windows exercise: every check passed"; do
  if grep -q "$check" "$WORK/host.out"; then
    echo "  verified: $check"
  else
    echo "  MISSING: $check"
    status=1
  fi
done

# 2. Windows x86_64 Cross-Compilation Verification
echo
echo "== Windows x86_64 Cross-Compilation Verification =="
if "$IYI" build --cross-compile --target x86_64-windows-msvc "$REPO/bench/windows_exercise.iyi" -o "$WORK/windows_exercise.obj" > "$WORK/win_build.log" 2>&1; then
  echo "  cross-compilation to x86_64-windows-msvc succeeded"
  echo "  object file size: $(wc -c < "$WORK/windows_exercise.obj" | tr -d ' ') bytes"
else
  echo "  cross-compilation to x86_64-windows-msvc failed"
  cat "$WORK/win_build.log"
  status=1
fi

# 2, continued. A thread stopped where the allocator defers it spills Windows'
# callee-saved set, rsi and rdi included, and a copy of the runtime whose
# spill leaves rsi out is refused by the same check.
echo
echo "== A stopped thread spills Windows' callee-saved registers =="
if [ -z "$DISASM" ]; then
  echo "  no objdump or llvm-objdump here to read the object with"
  status=1
elif [ ! -f "$WORK/windows_exercise.obj" ]; then
  echo "  no object to read: the cross-compilation above failed"
  status=1
elif stop_here_spills "$WORK/windows_exercise.obj"; then
  echo "  stop_here stores rdi and rsi into the spill"
  mkdir -p "$WORK/norsi/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/norsi/iyi/"
  awk '{ if ($0 ~ /^ +movq %rsi, 24\(\$0\)$/ && !done) { done = 1; next } print }' \
    "$REPO/src/iyi/thread.iyi" > "$WORK/norsi/iyi/thread.iyi"
  if cmp -s "$WORK/norsi/iyi/thread.iyi" "$REPO/src/iyi/thread.iyi"; then
    echo "  the proof's awk found no rsi store to remove"
    status=1
  elif ! IYI_PATH="$WORK/norsi${PSEP}$REPO/src" "$IYI" build --cross-compile --target x86_64-windows-msvc \
       "$REPO/bench/windows_exercise.iyi" -o "$WORK/norsi/program.obj" > "$WORK/norsi/build.log" 2>&1; then
    echo "  the copy without the rsi store did not build"
    sed -n '1,12p' "$WORK/norsi/build.log"
    status=1
  elif stop_here_spills "$WORK/norsi/program.obj"; then
    echo "  a stop_here without the rsi store still passed, so the check does not test it"
    status=1
  else
    echo "  failure proof: a stop_here that leaves rsi out is refused"
  fi
else
  echo "  stop_here does not store both rdi and rsi into the spill"
  status=1
fi

# 2a. What the program was told: an argument and an environment variable
# that the active code page has no letters for. The C runtime's `argv` and
# `environ` are the ANSI ones — measured, `ünïcode-çğış` arrived as
# `ünïcode-çgis` and `日本` as `??` — so `Program.args` reads
# `GetCommandLineW` and splits it itself, and the variable is read from
# Windows' own block. Only on Windows: everywhere else the bytes are the
# bytes and there is nothing to lose.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    echo
    echo "== A non-ASCII argument and variable survive =="
    cat > "$WORK/told.iyi" <<'EOF'
module told

n = 0
while n < Program.args.size
  a = Program.args[n]
  puts "arg " + n.to_s + ": " + a + " " + a.bytesize.to_s
  n = n + 1
end
v = Program.env("IYI_TOLD")
puts "env: " + (v ? v : "(none)") + " " + (v ? v.bytesize.to_s : "0")
EOF
    if ! "$IYI" build -o "$WORK/told.exe" "$WORK/told.iyi" > "$WORK/told.log" 2>&1; then
      echo "  the argument probe did not build"
      tail -5 "$WORK/told.log"
      status=1
    else
      # The value travels as UTF-8 from this shell; `printf` keeps the
      # bytes, and a `.bat` would not — cmd reads its own file in the OEM
      # code page and would mangle the literal before the program ran.
      told="$(printf 'de\xc4\x9fer-\xe6\x97\xa5\xe6\x9c\xac')"
      arg="$(printf '\xc3\xbcn\xc3\xafcode-\xc3\xa7\xc4\x9f\xc4\xb1\xc5\x9f')"
      IYI_TOLD="$told" "$WORK/told.exe" "$arg" > "$WORK/told.out" 2>&1 || true
      if grep -q "arg 0: $arg 18" "$WORK/told.out"; then
        echo "  the argument arrived whole, 18 bytes"
      else
        echo "  the argument did not arrive whole:"
        sed -n '1,3p' "$WORK/told.out"
        status=1
      fi
      if grep -q "env: $told 13" "$WORK/told.out"; then
        echo "  the variable arrived whole, 13 bytes"
      else
        echo "  the variable did not arrive whole:"
        grep "^env:" "$WORK/told.out" || true
        status=1
      fi
      # And the splitting, on command lines no shell writes, handed over
      # as they are by Python: a line that starts with a space has an
      # empty program name, as the C runtime reads it, and `first` was
      # taken for the name and lost; after an even run of backslashes the
      # doubled quote inside quotes is a quote, and it was dropped.
      PY=""
      for candidate in python3 python; do
        if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
          PY="$candidate"
          break
        fi
      done
      if [ -z "$PY" ]; then
        echo "  the raw command lines: skipped, no python to hand them over"
      else
        raw() {
          "$PY" -c 'import subprocess, sys; sys.stdout.write(subprocess.run(sys.argv[2], executable=sys.argv[1], capture_output=True, text=True, encoding="utf-8").stdout)' "$(cygpath -w "$WORK/told.exe")" "$1" | tr -d '\r' | grep '^arg' | tr '\n' '|'
        }
        spaced="$(raw ' first second')"
        doubled="$(raw 'told "a\\""b" c')"
        if [ "$spaced" = "arg 0: first 5|arg 1: second 6|" ] && [ "$doubled" = 'arg 0: a\"b 4|arg 1: c 1|' ]; then
          echo "  a leading space and a doubled quote after backslashes split as the C runtime splits them"
        else
          echo "  the raw command lines split otherwise: [$spaced] [$doubled]"
          status=1
        fi
        # A program started without standard streams - detached, as a
        # service or a GUI program starts one - writes into nothing and
        # goes on: its first `puts` panicked "write failed" and ended it.
        cat > "$WORK/detached.iyi" <<'EOF'
module detached

import std/file::{File}

puts "into nothing"
STDERR.puts "and nothing"
File.write(Program.args[0], "went on\n")
EOF
        if ! "$IYI" build -o "$WORK/detached.exe" "$WORK/detached.iyi" > "$WORK/detached.log" 2>&1; then
          echo "  the detached probe did not build"; tail -5 "$WORK/detached.log"; status=1
        else
          code="$("$PY" -c 'import subprocess, sys; print(subprocess.run([sys.argv[1], sys.argv[2]], creationflags=subprocess.DETACHED_PROCESS).returncode)' "$(cygpath -w "$WORK/detached.exe")" "$(cygpath -w "$WORK/detached.txt")")"
          if [ "$code" = "0" ] && [ "$(tr -d '\r' < "$WORK/detached.txt" 2>/dev/null)" = "went on" ]; then
            echo "  a program started detached writes into nothing and goes on"
          else
            echo "  a program started detached exited $code, and wrote '$(cat "$WORK/detached.txt" 2>/dev/null)'"
            status=1
          fi
        fi
      fi
    fi

    # 2a'. What a parked task costs. Windows charges committed memory to the
    # commit limit whether it is touched or not, and every task's 256 KiB
    # stack was committed whole: ten thousand parked tasks held 2,627 MB,
    # and at forty thousand the commit ran out and each new task panicked.
    # A stack is committed from the top as the fiber reaches it now, as a
    # thread's is. Ten thousand tasks, measured from outside by PowerShell,
    # must stay under 1,200 MB; the committed-whole stacks were over twice
    # that.
    echo
    echo "== Ten thousand parked tasks =="
    cat > "$WORK/parked.iyi" <<'EOF'
module parked

group do |g|
  10000.times do
    g.spawn do
      sleep(2500)
      0
    end
  end
end
puts "parked and done"
EOF
    if ! "$IYI" build -o "$WORK/parked.exe" "$WORK/parked.iyi" > "$WORK/parked.log" 2>&1; then
      echo "  the parked-task probe did not build"
      tail -5 "$WORK/parked.log"
      status=1
    else
      peak="$(powershell -NoProfile -Command "\$p = Start-Process -FilePath '$(cygpath -w "$WORK/parked.exe")' -PassThru -NoNewWindow -RedirectStandardOutput '$(cygpath -w "$WORK/parked.out")'; \$max = 0; while (-not \$p.HasExited) { try { \$p.Refresh(); if (\$p.PrivateMemorySize64 -gt \$max) { \$max = \$p.PrivateMemorySize64 } } catch {}; Start-Sleep -Milliseconds 100 }; [int](\$max / 1MB)" | tr -d '\r')"
      if [ -n "$peak" ] && [ "$peak" -lt 1200 ] && grep -q "parked and done" "$WORK/parked.out"; then
        echo "  ten thousand parked tasks committed ${peak} MB"
      else
        echo "  ten thousand parked tasks committed ${peak:-?} MB, over the 1,200 MB bar, or did not finish:"
        sed -n '1,3p' "$WORK/parked.out"
        status=1
      fi
    fi

    # 2a''. A program past its job's memory limit ends. A failed arena
    # commit was retried whatever its error, and the reservation before it
    # still succeeds once the commit charge is spent: under a 300 MB job
    # limit, a program filling arenas spun at 100% CPU and never ended. It
    # says "iyi: out of memory" and exits 1 now; only ERROR_INVALID_ADDRESS,
    # another thread taking the freed range first, is retried. Python makes
    # the job and starts the program suspended in it, so nothing is
    # allocated before the limit holds, and kills it after 60 seconds.
    echo
    echo "== A program past its job's memory limit ends =="
    JOBPY=""
    for candidate in python3 python; do
      if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
        JOBPY="$candidate"
        break
      fi
    done
    cat > "$WORK/job.py" <<'PY'
import ctypes, subprocess, sys
from ctypes import wintypes
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
ntdll = ctypes.WinDLL("ntdll")
k32.CreateJobObjectW.restype = wintypes.HANDLE
k32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
ntdll.NtResumeProcess.argtypes = [wintypes.HANDLE]
class BASIC(ctypes.Structure):
    _fields_ = [("user", ctypes.c_int64), ("job_user", ctypes.c_int64), ("flags", wintypes.DWORD),
                ("ws_min", ctypes.c_size_t), ("ws_max", ctypes.c_size_t), ("processes", wintypes.DWORD),
                ("affinity", ctypes.c_size_t), ("priority", wintypes.DWORD), ("scheduling", wintypes.DWORD)]
class EXTENDED(ctypes.Structure):
    _fields_ = [("basic", BASIC), ("io", ctypes.c_uint64 * 6), ("process_memory", ctypes.c_size_t),
                ("job_memory", ctypes.c_size_t), ("peak_process", ctypes.c_size_t), ("peak_job", ctypes.c_size_t)]
job = k32.CreateJobObjectW(None, None)
info = EXTENDED()
# JOB_OBJECT_LIMIT_PROCESS_MEMORY | JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
info.basic.flags = 0x100 | 0x2000
info.process_memory = int(sys.argv[1]) << 20
k32.SetInformationJobObject(job, 9, ctypes.byref(info), ctypes.sizeof(info))
child = subprocess.Popen(sys.argv[2:], stdout=subprocess.PIPE, stderr=subprocess.PIPE, creationflags=0x4)
k32.AssignProcessToJobObject(job, int(child._handle))
ntdll.NtResumeProcess(int(child._handle))
try:
    out, err = child.communicate(timeout=60)
    print(f"exit {child.returncode}")
except subprocess.TimeoutExpired:
    child.kill()
    out, err = child.communicate()
    print("TIMEOUT")
print("stdout: " + out.decode("utf-8", "replace").replace("\r", "").replace("\n", "|"))
print("stderr: " + err.decode("utf-8", "replace").replace("\r", "").replace("\n", "|"))
PY
    cat > "$WORK/filler.iyi" <<'EOF'
module filler

puts "filling"
keep = [] of Array(Int32)
while true
  keep << Array(Int32).new(64) { |k| k }
end
EOF
    if [ -z "$JOBPY" ]; then
      echo "  no python to make a job with, so the limit is unmeasured"
    elif ! "$IYI" build -o "$WORK/filler.exe" "$WORK/filler.iyi" > "$WORK/filler.log" 2>&1; then
      echo "  the filling probe did not build"
      tail -5 "$WORK/filler.log"
      status=1
    else
      "$JOBPY" "$WORK/job.py" 300 "$(cygpath -w "$WORK/filler.exe")" > "$WORK/filler.out" 2>&1 || true
      if grep -qx "exit 1" "$WORK/filler.out" && grep -q "iyi: out of memory" "$WORK/filler.out"; then
        echo "  filling arenas past a 300 MB job limit exits 1 with 'iyi: out of memory'"
      else
        echo "  filling arenas past a 300 MB job limit did not end with 'iyi: out of memory':"
        sed -n '1,3p' "$WORK/filler.out"
        status=1
      fi
    fi

    # 2a'''. A small program fits a small job. An arena was committed whole,
    # 16 MiB of charge from its first object, one per size class per
    # thread: eight threads keeping thirty strings each, one per class,
    # committed 995 MB with a few kilobytes live, and under a 200 MB job
    # limit died "iyi: out of memory". An arena is committed as it is
    # carved now, its tables and a slab at a time; the program finishes
    # under the same limit.
    echo
    echo "== A small program fits a 200 MB job =="
    cat > "$WORK/classes.iyi" <<'EOF'
module classes

threads = [] of IyiThread
8.times do
  threads << IyiThread.start do
    keep = [] of String
    30.times { |i| keep << "x" * (8 + i * 24) }
    nil
  end
end
threads.each(&.join)
puts "eight threads, thirty classes each"
EOF
    if [ -z "$JOBPY" ]; then
      echo "  no python to make a job with, so the limit is unmeasured"
    elif ! "$IYI" build -o "$WORK/classes.exe" "$WORK/classes.iyi" > "$WORK/classes.log" 2>&1; then
      echo "  the size-class probe did not build"
      tail -5 "$WORK/classes.log"
      status=1
    else
      "$JOBPY" "$WORK/job.py" 200 "$(cygpath -w "$WORK/classes.exe")" > "$WORK/classes.out" 2>&1 || true
      if grep -qx "exit 0" "$WORK/classes.out" && grep -q "eight threads, thirty classes each" "$WORK/classes.out"; then
        echo "  eight threads in thirty size classes each finish under a 200 MB job limit"
      else
        echo "  eight threads in thirty size classes each did not finish under a 200 MB job limit:"
        sed -n '1,3p' "$WORK/classes.out"
        status=1
      fi
    fi

    # 2b. What a short sleep costs. Windows rounds a millisecond timeout
    # up to the system timer tick, so the poller's own wait woke 15.6 ms
    # after a `sleep 1` and a hundred of them took 1,577 ms; with the
    # deadline on a high-resolution waitable timer the same hundred take
    # 156 ms. The bar is 800 ms — far under the tick-rounded floor and
    # five times over the measurement, so a loaded runner still passes.
    # It can only fail short: another process on the machine may have
    # raised the global timer resolution, and then even a poller without
    # the timer would come in under the bar.
    echo
    echo "== A hundred one-millisecond sleeps =="
    cat > "$WORK/naps.iyi" <<'EOF'
module naps

start = __iyi_monotonic_ns
100.times { sleep(1) }
puts "took " + ((__iyi_monotonic_ns - start) // 1000000_i64).to_s + " ms"
EOF
    if ! "$IYI" build -o "$WORK/naps.exe" "$WORK/naps.iyi" > "$WORK/naps.log" 2>&1; then
      echo "  the sleep probe did not build"
      tail -5 "$WORK/naps.log"
      status=1
    else
      "$WORK/naps.exe" > "$WORK/naps.out" 2>&1 || true
      took="$(sed -n 's/^took \([0-9]*\) ms$/\1/p' "$WORK/naps.out")"
      if [ -n "$took" ] && [ "$took" -lt 800 ]; then
        echo "  a hundred one-millisecond sleeps took ${took} ms"
      else
        echo "  a hundred one-millisecond sleeps did not come in under 800 ms:"
        sed -n '1,3p' "$WORK/naps.out"
        status=1
      fi
    fi

    # 2c. The other half of that wait: a completion arriving while the
    # deadline is armed. The poller waits on the port *and* the timer,
    # because a high-resolution timer takes no completion routine to
    # wake an alertable port wait with. A fiber parks on a read with no
    # data, another writes fifty milliseconds later, and a third holds a
    # one-second deadline open. Measured: 52 ms with the port in the
    # wait, 150 with it taken out — the read then waits for whichever
    # deadline comes next, which is the shape of the bug this would be.
    echo
    echo "== A completion under an armed deadline =="
    cat > "$WORK/late.iyi" <<'EOF'
module late

import std/socket::{IyiSocket}

server = IyiSocket.listen(0)
port = server.local_port

group do |g|
  g.spawn do
    sleep(1000)
  end

  g.spawn do
    conn = server.accept.or_panic
    start = __iyi_monotonic_ns
    conn.read(1024).or_panic
    puts "read after " + ((__iyi_monotonic_ns - start) // 1000000_i64).to_s + " ms"
    conn.close
  end

  g.spawn do
    client = IyiSocket.connect("127.0.0.1", port).or_panic
    sleep(50)
    client.write("late\n")
    sleep(100)
    client.close
  end
end

server.close
EOF
    if ! "$IYI" build -o "$WORK/late.exe" "$WORK/late.iyi" > "$WORK/late.log" 2>&1; then
      echo "  the completion probe did not build"
      tail -5 "$WORK/late.log"
      status=1
    else
      "$WORK/late.exe" > "$WORK/late.out" 2>&1 || true
      after="$(sed -n 's/^read after \([0-9]*\) ms$/\1/p' "$WORK/late.out")"
      if [ -n "$after" ] && [ "$after" -lt 100 ]; then
        echo "  the read came back after ${after} ms, not at the next deadline"
      else
        echo "  the read did not come back before the next deadline:"
        sed -n '1,3p' "$WORK/late.out"
        status=1
      fi
    fi

    # 2d. The two variables a Windows shell does not set. `PWD` is a
    # POSIX shell's bookkeeping — cmd and PowerShell keep none — and
    # `expand` read it for the base of a relative path, so measured from
    # cmd every such call panicked with "no base given and PWD is not
    # set". `TEMP` and `TMP` are usually there, and when they are not
    # the last resort was the literal `C:\Windows\Temp`, which a
    # standard user may not write to. Both answers come from the
    # platform now: the process's own directory, and `GetTempPathW`.
    echo
    echo "== Without the variables a POSIX shell sets =="
    cat > "$WORK/bare.iyi" <<'EOF'
module bare

import std/dir::{Dir}
import std/file::{File}
import std/path::{Path}

puts "expanded " + Path["relative.txt"].expand.to_s
scratch = Dir.tempdir + "\\iyi_windows_exercise_scratch"
written = File.write(scratch, "scratch")
if written.is_a?(Error)
  puts "tempdir refused " + scratch + ": " + written.message
else
  puts "wrote under " + Dir.tempdir
  File.delete(scratch)
end
EOF
    if ! "$IYI" build -o "$WORK/bare.exe" "$WORK/bare.iyi" > "$WORK/bare.log" 2>&1; then
      echo "  the bare-environment probe did not build"
      tail -5 "$WORK/bare.log"
      status=1
    else
      ( cd "$WORK" && env -u PWD -u TMPDIR -u TEMP -u TMP "$WORK/bare.exe" ) \
        > "$WORK/bare.out" 2>&1 || true
      if grep -q "^expanded .*relative.txt$" "$WORK/bare.out" &&
         grep -q "^wrote under " "$WORK/bare.out"; then
        sed -n 's/^/  /p' "$WORK/bare.out"
      else
        echo "  a program without PWD, TEMP and TMP did not get platform answers:"
        sed -n '1,4p' "$WORK/bare.out"
        status=1
      fi
    fi

    # 2e. What a killed `iyi run` leaves behind. On POSIX the runner
    # traps SIGTERM and passes it on; Windows delivers nothing to trap
    # and `TerminateProcess` — which is what an editor, a CI step and
    # `taskkill /F` use — runs no code in the runner at all. Measured
    # before the job object: killing the runner left the program alive
    # and its port LISTENING, and the next build of the same program
    # failed to link, because the orphan holds its own exe open. The
    # runner puts the program in a job with
    # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE now, so the kernel ends it.
    echo
    echo "== A killed runner takes its program with it =="
    cat > "$WORK/holds.iyi" <<'EOF'
module holds

import std/socket::{IyiSocket}

server = IyiSocket.listen(0)
puts "listening on " + server.local_port.to_s
slept = 0
while slept < 600
  sleep(100)
  slept = slept + 1
end
server.close
EOF
    "$IYI" run "$WORK/holds.iyi" > "$WORK/holds.out" 2>&1 &
    runner=$!
    held=""
    for _ in $(seq 1 90); do
      held="$(sed -n 's/^listening on \([0-9]*\)$/\1/p' "$WORK/holds.out")"
      [ -n "$held" ] && break
      sleep 1
    done
    if [ -z "$held" ]; then
      echo "  the program never came up under the runner"
      sed -n '1,5p' "$WORK/holds.out"
      status=1
    else
      # `kill -9` from this shell is TerminateProcess on a native
      # process: the unblockable kill, which is the whole point.
      kill -9 "$runner" 2>/dev/null || true
      wait "$runner" 2>/dev/null || true
      sleep 3
      if netstat -ano | grep "LISTENING" | grep -q ":$held "; then
        echo "  the program outlived its runner and still holds port $held"
        status=1
      else
        echo "  the runner was killed and port $held came back"
      fi
    fi

    # 2f. A DOS device that is not there does not exist. Windows answers
    # the attributes of every DOS device name with 0x20, whether the
    # device is there or not, and `File.exists?` said true for `COM9` and
    # `LPT7` on a machine with neither, where Python's `os.path.exists`
    # says False. Such a name is opened now: an absent device is not
    # found, and `NUL`, which opens, exists. No gate machine has a ninth
    # serial port or a seventh printer port.
    echo
    echo "== A DOS device that is not there does not exist =="
    printf 'module devices\n\nputs "COM9 " + File.exists?("COM9").to_s\nputs "LPT7 " + File.exists?("LPT7").to_s\nputs "NUL " + File.exists?("NUL").to_s\n' > "$WORK/devices.iyi"
    if ! "$IYI" build -o "$WORK/devices.exe" "$WORK/devices.iyi" > "$WORK/devices.log" 2>&1; then
      echo "  the device probe did not build"
      tail -5 "$WORK/devices.log"
      status=1
    else
      "$WORK/devices.exe" > "$WORK/devices.out" 2>&1 || true
      if [ "$(tr -d '\r' < "$WORK/devices.out" | tr '\n' '|')" = "COM9 false|LPT7 false|NUL true|" ]; then
        echo "  COM9 and LPT7 do not exist, NUL does"
      else
        echo "  the device names answered otherwise:"
        sed -n '1,4p' "$WORK/devices.out"
        status=1
      fi
    fi

    # 2g. Where the runtime's fatal sentences go: standard error, as a
    # panic's do. They were `__iyi_write(1, ...)`, and are
    # `__iyi_write(2, ...)` now: `prog > out` past a memory limit left "iyi:
    # out of memory" in `out` among the program's own lines, and standard
    # error empty. Both ways a program runs out under the 300 MB job of
    # 2a'': a mapping larger than the limit, and arenas filled to it.
    echo
    echo "== The runtime's fatal sentences go to standard error =="
    printf 'module bigmap\n\nputs "mapping"\nbig = Array(UInt8).new(400_000_000, 1_u8)\nputs big.size\n' > "$WORK/bigmap.iyi"
    if [ -z "$JOBPY" ]; then
      echo "  no python to make a job with, so the streams are unmeasured"
    elif ! "$IYI" build -o "$WORK/bigmap.exe" "$WORK/bigmap.iyi" > "$WORK/bigmap.log" 2>&1; then
      echo "  the mapping probe did not build"
      tail -5 "$WORK/bigmap.log"
      status=1
    else
      for probe in bigmap filler; do
        "$JOBPY" "$WORK/job.py" 300 "$(cygpath -w "$WORK/$probe.exe")" > "$WORK/$probe.streams" 2>&1 || true
        if grep -qx "exit 1" "$WORK/$probe.streams" && grep -qx "stderr: iyi: out of memory|" "$WORK/$probe.streams" &&
           ! grep -q "^stdout: .*out of memory" "$WORK/$probe.streams"; then
          echo "  $probe: 'iyi: out of memory' on standard error, and none of it on standard output"
        else
          echo "  $probe: the sentence is not on standard error alone:"
          sed -n '1,3p' "$WORK/$probe.streams"
          status=1
        fi
      done
    fi
    ;;
esac

# 3. Proving Checks Can Fail (Patched copy trick)
echo
echo "== Proving Checks Can Fail =="

prove_fails_host() {
  local label="$1"
  local dir="$2"
  local phrase="$3"
  local script="$4"

  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  awk "$script" "$REPO/src/iyi/prelude.iyi" > "$WORK/$dir/iyi/prelude.iyi"
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/windows_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched prelude did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  set +e
  "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local exit_code=$?
  set -e
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  if grep -q "$phrase" "$WORK/$dir/out"; then
    printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" \
      "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
    return
  fi
  # A break can also be too severe to narrate. Since the prelude allocates its
  # own IO buffers from this heap, a sweep that reclaims globals or hands out
  # live chunks corrupts the machinery `puts` needs, and the program dies
  # before any check can report. That is the break being caught, not missed,
  # so it counts only under conditions that cannot be satisfied by a working
  # collector: the process failed, and it never reached the line that says it passed.
  if [ "$exit_code" -ne 0 ] && ! grep -q "windows exercise: every check passed" "$WORK/$dir/out"; then
    printf '  %s: dies (exit %s) before it can report, and never passes\n' \
      "$label" "$exit_code"
    return
  fi
  echo "  $label: failed, but not at the expected check"
  sed -n '$p' "$WORK/$dir/out"
  status=1
}

# Failure test 1: Break sweep reclamation
prove_fails_host "sweep failure check" nosweep "sweep: nothing reclaimed" \
  '{ if ($0 ~ /def self\.swept/) { print; print "  0_u64"; getline; next } print }'

# Failure test 2: Break global root preservation
prove_fails_host "global root check" noglobals "survival: global root" \
  '{ if ($0 ~ /each_global_root\(visit\)/) { print "  # removed"; next } print }'

# Failure test 3: Break register spill
prove_fails_host "register spill check" nospill "registers: hidden value not found in register spill" \
  '{ if ($0 ~ /def self\.spill_registers/) { print; print "  return"; getline; next } print }'

echo
if [ "$status" -eq 0 ]; then
  echo "Windows collector verification: all checks passed and checks proven to fail."
else
  echo "Windows collector verification: failures detected."
fi
exit "$status"
