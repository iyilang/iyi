#!/usr/bin/env bash
# Exercises `std/colorize`: ANSI SGR wrapping, gated by Colorize.enabled.
#
#     bash bench/std_colorize_exercise.sh
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

trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_colorize_exercise.iyi" \
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

echo "== the std/colorize exercise, plain build"
build_and_run "plain" colorize-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/colorize-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every colorize section reported"
for phrase in "== disabled" "== enabled"; do
  if ! grep -q "$phrase" "$WORK/colorize-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" colorize-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/colorize-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
mkdir -p "$WORK/patched/std"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the broken-module proof is unmeasured"
elif ! "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/colorize.iyi").read_text()
old = 'Red          = 31'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/colorize.iyi").write_text(src.replace(old, 'Red          = 32', 1))
PY
then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_colorize_exercise.iyi" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  a broken colorize is caught"
fi

# A terminal on standard output and a file on standard error: the answer
# is one for the program and text is painted before anyone knows which
# stream it goes to, so both must be terminals, as Crystal's
# `on_tty_only!` asks. With standard output alone asked, `prog 2> err.log`
# from a terminal wrote escapes into err.log. Measured on Windows, where
# Python can give a program a console of its own.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    echo
    echo "== a console on standard output, a file on standard error"
    printf 'module main\n\nimport std/colorize::{Colorize}\n\nputs "out".colorize.red.to_s\nSTDERR.puts "err".colorize.red.to_s\n' > "$WORK/split.iyi"
    if [ -z "$PY" ]; then
      echo "  no python3 on this machine, so the split is unmeasured"
    elif ! "$IYI" build -o "$WORK/split" "$WORK/split.iyi" > "$WORK/split.build" 2>&1; then
      echo "  the split program did not build"; sed -n '1,10p' "$WORK/split.build"; status=1
    else
      cat > "$WORK/split.py" <<'PY'
import os, subprocess, sys
program, err = sys.argv[1], sys.argv[2]
if os.environ.get("SPLIT_INNER") != "1":
    info = subprocess.STARTUPINFO(); info.dwFlags = 1; info.wShowWindow = 0
    env = dict(os.environ, SPLIT_INNER="1")
    env.pop("TERM", None); env.pop("NO_COLOR", None)
    subprocess.Popen([sys.executable, __file__] + sys.argv[1:], env=env, creationflags=0x10, startupinfo=info).wait(timeout=60)
    sys.exit(0)
with open(err, "wb") as f:
    subprocess.call([program], stderr=f)
PY
      "$PY" "$WORK/split.py" "$WORK/split.exe" "$WORK/split.err" > "$WORK/split.out" 2>&1
      if [ ! -s "$WORK/split.err" ]; then
        echo "  no console here, or the program wrote nothing, so the split is unmeasured"; cat "$WORK/split.out"
      elif grep -q $'\x1b' "$WORK/split.err"; then
        echo "  escapes were written into the file on standard error:"; od -c "$WORK/split.err" | sed -n '1,3p'; status=1
      else
        echo "  the file on standard error holds plain text: $(tr -d '\r' < "$WORK/split.err")"
      fi
    fi
    ;;
esac

echo
if [ "$status" -eq 0 ]; then
  echo "the std/colorize exercise holds"
else
  echo "the std/colorize exercise did not hold"
fi
exit $status
