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
