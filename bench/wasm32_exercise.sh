#!/usr/bin/env bash
# GC_DESIGN.md Stage 10, driven. Runs the wasm32 collector exercise under
# wasmtime, verifies allocation, reclamation, rooted survival, and layout
# precision, and proves the exercise fails when mechanisms are broken.
#
#   bash bench/wasm32_exercise.sh
#
# Needs `make iyi`, wasi-sdk clang, and wasmtime. Exits non-zero if any check fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# `IYI`, overridable: the container that can build this compiler cannot run
# wasmtime, and the runner that runs wasmtime cannot build the compiler. The
# relocatable tarball crosses that line — `clean-room` proves it starts on a
# machine with nothing on it — so CI points this at the tarball's binary and
# the whole driver, proofs included, runs in one place.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0

# Locate wasi-sdk clang
WASI_CLANG=""
if [ -n "${WASI_SDK_PATH:-}" ] && [ -x "$WASI_SDK_PATH/bin/clang" ]; then
  WASI_CLANG="$WASI_SDK_PATH/bin/clang"
elif [ -x "/tmp/wasi-sdk-24.0-arm64-macos/bin/clang" ]; then
  WASI_CLANG="/tmp/wasi-sdk-24.0-arm64-macos/bin/clang"
elif [ -x "/opt/wasi-sdk/bin/clang" ]; then
  WASI_CLANG="/opt/wasi-sdk/bin/clang"
elif command -v clang >/dev/null 2>&1; then
  WASI_CLANG="$(command -v clang)"
fi

if [ -z "$WASI_CLANG" ]; then
  echo "wasi-sdk clang not found: set WASI_SDK_PATH or install to /opt/wasi-sdk"
  exit 1
fi

# Locate wasmtime
WASMTIME_BIN=""
if [ -n "${WASMTIME:-}" ] && [ -x "$WASMTIME" ]; then
  WASMTIME_BIN="$WASMTIME"
elif [ -x "$HOME/.wasmtime/bin/wasmtime" ]; then
  WASMTIME_BIN="$HOME/.wasmtime/bin/wasmtime"
elif command -v wasmtime >/dev/null 2>&1; then
  WASMTIME_BIN="$(command -v wasmtime)"
fi

if [ -z "$WASMTIME_BIN" ]; then
  echo "wasmtime not found: install to \$HOME/.wasmtime/bin/wasmtime or set WASMTIME"
  exit 1
fi

build_and_run() {
  local label="$1" name="$2"
  shift 2
  local link_cmd
  link_cmd="$("$IYI" build --cross-compile --target wasm32-wasi "$@" \
    -o "$WORK/$name" "$REPO/bench/wasm32_exercise.iyi" 2>"$WORK/$name.build.log")"
  local build_code=$?
  if [ "$build_code" -ne 0 ] || [ -z "$link_cmd" ]; then
    echo "$label: cross-compile failed"
    sed -n '1,15p' "$WORK/$name.build.log"
    status=1
    return 1
  fi

  # Replace 'cc' with wasi-sdk clang and link
  local actual_cmd
  actual_cmd="$(echo "$link_cmd" | sed -e "s|^cc |$WASI_CLANG |")"
  if ! eval "$actual_cmd -o $WORK/$name.linked" >"$WORK/$name.link.log" 2>&1; then
    echo "$label: link failed"
    cat "$WORK/$name.link.log"
    status=1
    return 1
  fi

  "$WASMTIME_BIN" "$WORK/$name.linked" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code under wasmtime"
    status=1
    return 1
  fi
  return 0
}

echo "== the wasm32 collector exercise, default build =="
build_and_run "the exercise" wasm32-ex

if ! grep -q "all wasm32 collector checks passed" "$WORK/wasm32-ex.out" 2>/dev/null; then
  echo "  MISSING: the exercise did not reach the end"
  status=1
fi

echo
echo "== every check reported =="
for check in "allocation:" "reclamation:" "survival:" "precision:" "realloc:"; do
  if ! grep -q "$check" "$WORK/wasm32-ex.out" 2>/dev/null; then
    echo "  MISSING: $check"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  allocation, reclamation, survival, precision, and realloc all reported"

echo
echo "== the same program with optimisation on (--release) =="
build_and_run "release" wasm32-ex-rel --release
if ! grep -q "all wasm32 collector checks passed" "$WORK/wasm32-ex-rel.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== the checks fail when collector mechanisms are broken =="
prove_fails() {
  local label="$1" dir="$2" phrase="$3" script="$4"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  awk "$script" "$REPO/src/iyi/prelude.iyi" > "$WORK/$dir/iyi/prelude.iyi"

  local link_cmd
  link_cmd="$(IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build --cross-compile --target wasm32-wasi \
    -o "$WORK/$dir/prog" "$REPO/bench/wasm32_exercise.iyi" 2>"$WORK/$dir/build.log")"
  local build_code=$?
  if [ "$build_code" -ne 0 ] || [ -z "$link_cmd" ]; then
    echo "  $label: cross-compile failed"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi

  local actual_cmd
  actual_cmd="$(echo "$link_cmd" | sed -e "s|^cc |$WASI_CLANG |")"
  if ! eval "$actual_cmd -o $WORK/$dir/prog.linked" >"$WORK/$dir/link.log" 2>&1; then
    echo "  $label: link failed"
    cat "$WORK/$dir/link.log"
    status=1
    return
  fi

  "$WASMTIME_BIN" "$WORK/$dir/prog.linked" >"$WORK/$dir/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not with expected phrase '$phrase'"
    cat "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: caught failure as expected (exits %s at "%s")\n' "$label" "$exit_code" \
    "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
}

# 1. Break reclamation: make sweep a no-op (comment out free list push)
prove_fails "reclamation failure" no_reclaim "reclamation:" \
  '{ if ($0 ~ /IyiHeap\.set_free_list\(class_idx, p_obj\)/) { sub(/IyiHeap\.set_free_list\(class_idx, p_obj\)/, "# no-op") } print }'

# 2. Break root discovery: comment out scan_stack so stack roots are missed
prove_fails "stack root failure" no_stack "survival:" \
  '{ if ($0 ~ /scan_stack\(visit\)/) { sub(/scan_stack\(visit\)/, "# no-op") } print }'

# 3. Break layout precision: disable layout_search so integer fields holding addresses are followed
prove_fails "layout precision failure" no_precision "precision:" \
  '{ if ($0 ~ /entry = has_table && type_id != 0_u64/) { sub(/entry = has_table && type_id != 0_u64 \? layout_search\(table, entry_count, type_id\) : 0_u64/, "entry = 0_u64") } print }'

echo
if [ "$status" -eq 0 ]; then
  echo "wasm32 collector: allocation, reclamation, survival, precision and negative proofs all hold"
else
  echo "wasm32 collector: one or more checks failed"
fi
exit "$status"
