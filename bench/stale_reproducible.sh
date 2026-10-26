#!/usr/bin/env bash
# Gate for S2: RG1 (reproducible compiler build) and RG7 (deterministic parallel codegen).
#
#     bash bench/stale_reproducible.sh [all|rg1|rg7]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

if [ -z "$PY" ]; then
  echo "python3 required for reproducible check" >&2
  exit 1
fi

IYI="${IYI:-$REPO/bin/iyi}"
if [ ! -x "$IYI" ]; then
  echo "iyi compiler not found at $IYI. Building..." >&2
  export LIBRARY_PATH="${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}"
  export IYI_CACHE_DIR="${IYI_CACHE_DIR:-/tmp/iyi-stale-s2-cache}"
  make -C "$REPO" -j8 iyi
fi

MODE="${1:-all}"

export ZERO_AR_DATE=1
export SOURCE_DATE_EPOCH="$(/usr/bin/git -C "$REPO" show -s --format=%ct HEAD 2>/dev/null || cat "$REPO/src/SOURCE_DATE_EPOCH" 2>/dev/null || echo 0)"
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"
export IYI_LIBRARY_PATH="$REPO/lib"
WORK="$(mktemp -d /tmp/stale-repro-work.XXXXXX)"
CACHE="$WORK/cache"
mkdir -p "$CACHE"
export IYI_CACHE_DIR="$CACHE"

cleanup() {
  rm -rf "$WORK"
  rm -rf /tmp/iyi-stale-s2-rg1
}
trap cleanup EXIT

run_rg7() {
  echo "== Running RG7: parallel codegen determinism (--threads 1 vs 8) =="
  local mismatches=0
  local total=0

  for prog in "$REPO"/samples/iyi/*.iyi; do
    [ -f "$prog" ] || continue
    name="$(basename "$prog")"
    out="$WORK/prog_out"
    saved="$WORK/prog_t1"

    rm -rf "$CACHE"/*
    "$IYI" build --threads 1 -o "$out" "$prog"
    cp "$out" "$saved"

    rm -rf "$CACHE"/*
    "$IYI" build --threads 8 -o "$out" "$prog"

    if cmp "$saved" "$out" >/dev/null 2>&1; then
      echo "  RG7 OK: $name"
    else
      echo "  RG7 MISMATCH: $name" >&2
      mismatches=$((mismatches + 1))
    fi
    total=$((total + 1))
  done

  if [ "$mismatches" -gt 0 ]; then
    echo "RG7 FAILED: $mismatches mismatches out of $total" >&2
    return 1
  fi
  echo "RG7 PASSED: all $total C2 programs matched byte-for-byte across --threads 1 and 8"
}

run_rg1() {
  echo "== Running RG1: reproducible compiler build =="
  local rg1_dir="/tmp/iyi-stale-s2-rg1"
  rm -rf "$rg1_dir"
  mkdir -p "$rg1_dir"

  echo "  copying source tree to $rg1_dir..."
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude='.git' --exclude='.build' "$REPO/" "$rg1_dir/"
  else
    (cd "$REPO" && tar --exclude='.git' --exclude='.build' -cf - .) | (cd "$rg1_dir" && tar -xf -)
  fi

  # Apply any extra build flags for mutation testing if requested
  local extra_flags="${RG1_EXTRA_FLAGS:-}"

  echo "  computing build-input digests..."
  local llvm_cfg
  llvm_cfg="$("$REPO/src/llvm/ext/find-llvm-config.sh" 2>/dev/null || true)"
  local llvm_ver=""
  if [ -n "$llvm_cfg" ] && command -v "$llvm_cfg" >/dev/null 2>&1; then
    llvm_ver="$("$llvm_cfg" --version 2>/dev/null || true)"
  fi
  local bootstrap_compiler_ver
  bootstrap_compiler_ver="$("$REPO/bin/crystal" env CRYSTAL_VERSION 2>/dev/null || true)"
  local c1_flags="-D strict_multi_assign -D preview_overload_order -Dwithout_openssl -Dwithout_zlib -Dwithout_iconv -Dgc_none"
  local c2_flags="$c1_flags"
  if [ -n "$extra_flags" ]; then
    c2_flags="$c2_flags $extra_flags"
  fi

  digest1="$("$PY" "$REPO/scripts/build_inputs.py" --root "$REPO" --llvm-version "$llvm_ver" --crystal-version "$bootstrap_compiler_ver" --flags "$c1_flags")"
  digest2="$("$PY" "$rg1_dir/scripts/build_inputs.py" --root "$rg1_dir" --llvm-version "$llvm_ver" --crystal-version "$bootstrap_compiler_ver" --flags "$c2_flags")"

  echo "  compiler 1 build-inputs: $digest1"
  echo "  compiler 2 build-inputs: $digest2"

  if [ "$digest1" != "$digest2" ]; then
    echo "RG1 FAILED: build-input digests differ! $digest1 != $digest2" >&2
    return 1
  fi

  echo "  building second compiler at $rg1_dir..."
  export LIBRARY_PATH="${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}"
  export IYI_CACHE_DIR="$rg1_dir/cache"
  # The commit compiler 1 carries, not HEAD: `make` does not rebuild the
  # compiler for a commit that touches no compiler source, so after one its
  # stamp is older than HEAD, and every program differed by the stamp alone.
  local commit
  commit="$("$IYI" --version 2>/dev/null | sed -n 's/.*\[\([0-9a-f]*\)\].*/\1/p' | head -1)"
  [ -n "$commit" ] || commit="$(/usr/bin/git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo "")"
  make -C "$rg1_dir" -j8 iyi FLAGS="$extra_flags" IYI_CONFIG_BUILD_COMMIT="$commit" SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH"

  local c2_iyi="$rg1_dir/.build/iyi"
  if [ ! -x "$c2_iyi" ]; then
    echo "RG1 FAILED: second compiler binary not found at $c2_iyi" >&2
    return 1
  fi

  echo "  comparing C2 program outputs between compiler 1 and compiler 2..."
  local mismatches=0
  local total=0

  for prog in "$REPO"/samples/iyi/*.iyi; do
    [ -f "$prog" ] || continue
    name="$(basename "$prog")"
    out="$WORK/prog_out"
    saved="$WORK/prog_c1"

    rm -rf "$CACHE"/*
    "$IYI" build -o "$out" "$prog"
    cp "$out" "$saved"

    rm -rf "$CACHE"/*
    "$c2_iyi" build -o "$out" "$prog"

    if cmp "$saved" "$out" >/dev/null 2>&1; then
      echo "  RG1 OK: $name"
    else
      echo "  RG1 MISMATCH: $name" >&2
      mismatches=$((mismatches + 1))
    fi
    total=$((total + 1))
  done

  # Clean up second compiler immediately to save disk
  rm -rf "$rg1_dir"

  if [ "$mismatches" -gt 0 ]; then
    echo "RG1 FAILED: $mismatches mismatches out of $total" >&2
    return 1
  fi
  echo "RG1 PASSED: all $total C2 programs matched byte-for-byte across both compilers"
}

case "$MODE" in
  rg1)
    run_rg1
    ;;
  rg7)
    run_rg7
    ;;
  all)
    run_rg7
    run_rg1
    ;;
  *)
    echo "Usage: $0 [all|rg1|rg7]" >&2
    exit 1
    ;;
esac
