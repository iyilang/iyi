#!/usr/bin/env bash
# Stage 10 Windows exercise driver: the collector on Windows x86_64.
#
#   bash bench/windows_exercise.sh
#
# Verifies clean cross-compilation for Windows x86_64, runs the exercise
# on the host, and proves the exercise checks can fail when the collector is broken.
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
