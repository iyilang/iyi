#!/usr/bin/env bash
# Gate for S2: RG1 (reproducible compiler build) and RG7 (deterministic parallel codegen).
#
#     bash bench/stale_reproducible.sh [all|rg1|rg7]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) WINDOWS=1; PSEP=';'; REPO="$(cygpath -m "$REPO")" ;;
  *) WINDOWS=0; PSEP=':' ;;
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

if [ "$WINDOWS" -eq 1 ]; then
  IYI="${IYI:-$REPO/.build/iyi.exe}"
  IYI="$(cygpath -m "$IYI")"
else
  IYI="${IYI:-$REPO/bin/iyi}"
fi
if [ ! -x "$IYI" ]; then
  if [ "$WINDOWS" -eq 1 ]; then
    echo "iyi compiler not found at $IYI; build .build/iyi.exe first" >&2
    exit 1
  fi
  echo "iyi compiler not found at $IYI. Building..." >&2
  if [ "$(uname -s)" = Darwin ]; then
    export LIBRARY_PATH="${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}"
  fi
  make -C "$REPO" -j8 iyi
fi

MODE="${1:-all}"

export ZERO_AR_DATE=1
export SOURCE_DATE_EPOCH="$(git -C "$REPO" show -s --format=%ct HEAD 2>/dev/null || cat "$REPO/src/SOURCE_DATE_EPOCH" 2>/dev/null || echo 0)"
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"
export IYI_LIBRARY_PATH="$REPO/lib"
WORK="$(mktemp -d /tmp/stale-repro-work.XXXXXX)"
[ "$WINDOWS" -eq 0 ] || WORK="$(cygpath -m "$WORK")"
CACHE="$WORK/cache"
mkdir -p "$CACHE"
export IYI_CACHE_DIR="$CACHE"

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

# A build over an image that is still there is not the build of a clean
# directory on Windows: link.exe finds the debug database beside the image
# and counts a rebuild of it (the CodeView entry's age, 1 and then 2), and
# /Brepro derives the PE timestamp and the entry's signature from the bytes,
# so the second build of one program at one -o differed from the first in
# that one byte and the fields hashed from it (cmp -l: 1 byte, job
# 139201230070; 69 bytes in bench/stale_callpath.sh's measurement). Both
# gates here build to one -o twice, so each build starts from no image and no
# database.
fresh_image() {
  rm -f "$1" "${1%.exe}.pdb"
}

run_rg7() {
  echo "== Running RG7: parallel codegen determinism (--threads 1 vs 8) =="
  local mismatches=0
  local total=0

  for prog in "$REPO"/samples/iyi/*.iyi; do
    [ -f "$prog" ] || continue
    name="$(basename "$prog")"
    out="$WORK/prog_out"
    [ "$WINDOWS" -eq 0 ] || out="$out.exe"
    saved="$WORK/prog_t1"

    rm -rf "$CACHE"/*
    fresh_image "$out"
    "$IYI" build --threads 1 -o "$out" "$prog"
    cp "$out" "$saved"

    rm -rf "$CACHE"/*
    fresh_image "$out"
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
  local rg1_dir="$WORK/rg1"
  mkdir -p "$rg1_dir"

  echo "  copying source tree to $rg1_dir..."
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude='.git' --exclude='.build' "$REPO/" "$rg1_dir/"
  elif [ "$WINDOWS" -eq 1 ]; then
    # Git's tar cannot make the tree's symlinks here (`Cannot create symlink
    # to 'x86_64-windows-msvc'`, exit 2): the lib_c aliases of other targets
    # are not part of a native build, so the copy leaves every symlink out.
    (cd "$REPO" && find . \( -name .git -o -name .build \) -prune -o ! -type l ! -type d -print0 | tar --null -T - -cf -) | (cd "$rg1_dir" && tar -xf -)
  else
    (cd "$REPO" && tar --exclude='.git' --exclude='.build' -cf - .) | (cd "$rg1_dir" && tar -xf -)
  fi

  # Apply any extra build flags for mutation testing if requested
  local extra_flags="${RG1_EXTRA_FLAGS:-}"

  echo "  computing build-input digests..."
  local llvm_cfg
  llvm_cfg="$("$REPO/src/llvm/ext/find-llvm-config.sh" 2>/dev/null || true)"
  local llvm_ver="${LLVM_VERSION:-}"
  if [ -n "$llvm_cfg" ] && command -v "$llvm_cfg" >/dev/null 2>&1; then
    llvm_ver="$("$llvm_cfg" --version 2>/dev/null || true)"
  fi
  local bootstrap_compiler_ver
  bootstrap_compiler_ver="$(bash "$REPO/bench/stale_store_concurrency.sh" --crystal env CRYSTAL_VERSION 2>/dev/null || true)"
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
  if [ "$(uname -s)" = Darwin ]; then
    export LIBRARY_PATH="${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}"
  fi
  export IYI_CACHE_DIR="$rg1_dir/cache"
  # The commit compiler 1 carries, not HEAD: `make` does not rebuild the
  # compiler for a commit that touches no compiler source, so after one its
  # stamp is older than HEAD, and every program differed by the stamp alone.
  local commit
  commit="$("$IYI" --version 2>/dev/null | sed -n 's/.*\[\([0-9a-f]*\)\].*/\1/p' | head -1)"
  [ -n "$commit" ] || commit="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo "")"
  # The stamp's date too: it is the day of SOURCE_DATE_EPOCH when compiler 1
  # was built, which an incremental rebuild does not renew, so a compiler built
  # yesterday stamps yesterday whatever HEAD's commit time says now.
  local stamp_date stamp_epoch
  stamp_date="$("$IYI" --version 2>/dev/null | sed -n 's/.*(\([0-9][0-9-]*\)).*/\1/p' | head -1)"
  if [ -n "$stamp_date" ]; then
    stamp_epoch="$("$PY" -c 'import sys,datetime; print(int(datetime.datetime.strptime(sys.argv[1], "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc).timestamp()))' "$stamp_date" 2>/dev/null || true)"
    [ -z "$stamp_epoch" ] || SOURCE_DATE_EPOCH="$stamp_epoch"
  fi
  local c2_iyi="$rg1_dir/.build/iyi"
  if [ "$WINDOWS" -eq 1 ]; then
    mkdir -p "$rg1_dir/.build"
    cp "$REPO/.build/crystal.exe" "$REPO/.build/LLVM-C.dll" "$rg1_dir/.build/"
    make -C "$rg1_dir" -f Makefile.win iyi FLAGS="$extra_flags" IYI_CONFIG_BUILD_COMMIT="$commit" SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH"
    c2_iyi="$c2_iyi.exe"
  else
    make -C "$rg1_dir" -j8 iyi FLAGS="$extra_flags" IYI_CONFIG_BUILD_COMMIT="$commit" SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH"
  fi
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
    [ "$WINDOWS" -eq 0 ] || out="$out.exe"
    saved="$WORK/prog_c1"

    rm -rf "$CACHE"/*
    fresh_image "$out"
    "$IYI" build -o "$out" "$prog"
    cp "$out" "$saved"

    rm -rf "$CACHE"/*
    fresh_image "$out"
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
