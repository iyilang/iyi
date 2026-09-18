#!/usr/bin/env bash
# Exercises IyiIO: flush, short reads, buffer boundaries, and EOF.
#
#     bash bench/io_exercise.sh
#
# Follows the house style: exercises the stream abstraction plain and with
# --release, and proves each check can fail by breaking the mechanism in a
# patched copy of the library.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The gate runs whatever compiler the caller names; `bin/iyi` is a shell
# wrapper, and on Windows the caller has to point at the built exe itself.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` on it is silently ignored, so the patched
# copy is never read and the proof that a check can fail quietly stops
# proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac
trap 'rm -rf "$WORK"' EXIT

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

status=0

run_case() {
  local label="$1" name="$2"
  shift 2
  echo "== $label"
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/io_exercise.iyi" >"$WORK/$name.build.log" 2>&1; then
    echo "  $label: build failed"
    sed -n '1,12p' "$WORK/$name.build.log"
    status=1
    return
  fi
  # From the scratch directory, because the program writes its two files
  # into the working one: run from the repository they landed in the
  # repository, and two of them were committed before anybody noticed.
  (cd "$WORK" && "$WORK/$name") </dev/null >"$WORK/$name.out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    echo "  $label: failed with exit code $exit_code"
    sed -n '$p' "$WORK/$name.out"
    status=1
    return
  fi
  if ! grep -q "all io checks passed" "$WORK/$name.out"; then
    echo "  $label: did not reach all io checks passed"
    status=1
    return
  fi
  echo "  $label: all io checks passed"
}

run_case "the exercise, plain build" io-plain
echo
run_case "the same program with optimisation on" io-release --release

echo
echo "== the checks fail when the mechanism is broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" script="$4"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  awk "$script" "$REPO/src/iyi/io.iyi" > "$WORK/$dir/iyi/io.iyi"
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/io_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched library did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  (cd "$WORK/$dir" && "$WORK/$dir/program") </dev/null >"$WORK/$dir/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  if ! tr -d '\0' < "$WORK/$dir/out" | grep -q "$phrase"; then
    echo "  $label: failed, but not at the expected check ($phrase)"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" \
    "$(tr -d '\0' < "$WORK/$dir/out" | grep -m1 "$phrase" | sed 's/^iyi: panic: //')"
}

# 1. Flush broken: flush is a no-op so unflushed write never reaches disk
prove_fails "flush check fails" noflush "flush:" \
  '{ sub(/def flush : Nil/, "def flush : Nil\n    return"); print }'

# 2. Short reads broken: bytes in read_bytes corrupted
prove_fails "short reads fail" noshort "short_reads:" \
  '{ sub(/target\.copy_from\(result_buf, total_read\)/, "target[0] = 63_u8"); print }'

# 3. Buffer boundary broken: take count in multi-buffer read_line corrupted
prove_fails "read across buffer boundary fails" noboundary "buffer_boundary:" \
  '{ if ($0 ~ /take = found_idx - @read_pos \+ 1/) { print "take = 1"; next } print }'

# 4. EOF check broken: eof? always returns false
prove_fails "eof check fails" noeof "eof:" \
  '{ sub(/def eof\? : Bool/, "def eof? : Bool\n    return false"); print }'

echo
if [ "$status" -eq 0 ]; then
  echo "all io exercise checks and failure proofs passed"
fi
exit $status
