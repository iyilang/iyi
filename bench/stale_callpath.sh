#!/usr/bin/env bash
# Gate for S3: stale callpath, reach walk, link-once, LinkFp, and RG4.
# Usage:
#     bash bench/stale_callpath.sh [all|link|rg4|reach]
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
  echo "python3 required for stale_callpath gate" >&2
  exit 1
fi

IYI="${IYI:-$REPO/bin/iyi}"
if [ ! -x "$IYI" ]; then
  echo "iyi compiler not found at $IYI. Building..." >&2
  export LIBRARY_PATH="${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}"
  export IYI_CACHE_DIR="${IYI_CACHE_DIR:-/tmp/iyi-stale-s3d-cache}"
  make -C "$REPO" -j8 iyi
fi

MODE="${1:-all}"

export ZERO_AR_DATE=1
export SOURCE_DATE_EPOCH="$(/usr/bin/git -C "$REPO" show -s --format=%ct HEAD 2>/dev/null || cat "$REPO/src/SOURCE_DATE_EPOCH" 2>/dev/null || echo 0)"
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"
export IYI_LIBRARY_PATH="$REPO/lib"

WORK="$(mktemp -d /tmp/stale-callpath-work.XXXXXX)"
CACHE="$WORK/cache"
mkdir -p "$CACHE"
export IYI_CACHE_DIR="$CACHE"

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

# 5 C2 sample programs from samples/iyi
C2_SAMPLES=(
  "$REPO/samples/iyi/hello.iyi"
  "$REPO/samples/iyi/calc.iyi"
  "$REPO/samples/iyi/collections.iyi"
  "$REPO/samples/iyi/format.iyi"
  "$REPO/samples/iyi/shapes.iyi"
)

run_link() {
  echo "== Running S3d: Link section (link-once, no-shell link, LinkFp, refusal) =="

  local mismatches=0
  local total=0

  # 1. Compare normal build vs stale build on five C2 programs at the same -o
  echo "  comparing normal vs stale builds on five C2 programs..."
  for prog in "${C2_SAMPLES[@]}"; do
    [ -f "$prog" ] || continue
    name="$(basename "$prog")"
    out="$WORK/prog_out"
    saved="$WORK/prog_saved"

    rm -rf "$CACHE"/*
    "$IYI" build -o "$out" "$prog"
    cp "$out" "$saved"

    rm -rf "$CACHE"/*
    "$IYI" build --stale-key "$WORK/stale.key" -o "$out" "$prog"

    if cmp "$saved" "$out" >/dev/null 2>&1; then
      echo "  Link cmp OK: $name"
    else
      echo "  Link cmp MISMATCH: $name" >&2
      mismatches=$((mismatches + 1))
    fi
    total=$((total + 1))
  done

  # 2. Compare normal vs stale on quoted ldflags fixture: @[Link(ldflags: "-L'/tmp/a b' -lm")]
  echo "  comparing normal vs stale build on quoted ldflags fixture..."
  local quoted_dir="/tmp/a b"
  mkdir -p "$quoted_dir"
  local fixture="$WORK/quoted_ldflags.iyi"
  "$PY" -c "
with open('$fixture', 'w') as f:
    f.write('''@[Link(ldflags: \"-L\\'/tmp/a b\\' -lm\")]
lib LibTest
  fun cos(x : Float64) : Float64
end

print LibTest.cos(0.0)
''')
"
  out="$WORK/prog_out"
  saved="$WORK/prog_saved"

  rm -rf "$CACHE"/*
  "$IYI" build -o "$out" "$fixture"
  cp "$out" "$saved"

  rm -rf "$CACHE"/*
  "$IYI" build --stale-key "$WORK/stale.key" -o "$out" "$fixture"

  if cmp "$saved" "$out" >/dev/null 2>&1; then
    echo "  Link cmp OK: quoted ldflags fixture"
  else
    echo "  Link cmp MISMATCH: quoted ldflags fixture" >&2
    mismatches=$((mismatches + 1))
  fi
  total=$((total + 1))
  rm -rf "$quoted_dir"

  if [ "$mismatches" -gt 0 ]; then
    echo "Link verification FAILED: $mismatches mismatches out of $total" >&2
    return 1
  fi
  echo "Link cmp PASSED: all $total programs (5 C2 + quoted fixture) matched byte-for-byte at same -o"

  # 3. Pkg-config shim: verify exactly one invocation per stale build
  echo "  testing pkg-config shim invocation count..."
  local shim_dir="$WORK/pkg_shim"
  local shim_log="$WORK/pkg_shim.log"
  mkdir -p "$shim_dir"
  local real_pkg="$(command -v pkg-config || echo "")"
  "$PY" -c "
import os
shim_path = '$shim_dir/pkg-config'
with open(shim_path, 'w') as f:
    f.write('''#!/bin/sh
echo \"invoked: \$*\" >> '$shim_log'
if [ -n \"$real_pkg\" ] && [ -x \"$real_pkg\" ]; then
  exec \"$real_pkg\" \"\$@\"
else
  exit 1
fi
''')
os.chmod(shim_path, 0o755)
"
  local pkg_prog="$WORK/pkg_test.iyi"
  "$PY" -c "
with open('$pkg_prog', 'w') as f:
    f.write('''@[Link(\"m\")]
lib LibM
  fun cos(x : Float64) : Float64
end

print LibM.cos(0.0)
''')
"
  rm -rf "$CACHE"/*
  PATH="$shim_dir:$PATH" "$IYI" build --stale-key "$WORK/stale.key" -o "$WORK/pkg_out" "$pkg_prog"

  local count=0
  if [ -f "$shim_log" ]; then
    count="$(wc -l < "$shim_log" | tr -d ' ')"
  fi
  if [ "$count" -eq 1 ]; then
    echo "  pkg-config shim OK: exactly 1 invocation logged (count=$count)"
  else
    echo "  pkg-config shim FAILED: expected 1 invocation, got $count" >&2
    [ -f "$shim_log" ] && cat "$shim_log" >&2
    return 1
  fi

  # 4. Each refused character yields refusal
  echo "  testing refusal for shell characters (\` \$ * ? [ ~)..."
  local refused_chars=('`' '$' '*' '?' '[' '~')
  for ch in "${refused_chars[@]}"; do
    local res
    res="$("$PY" -c "
import subprocess
out = subprocess.check_output(['./bin/crystal', 'eval', '''
require \"compiler/iyi/stale/link\"
r = Iyi::Stale::Link.refusal(\"-L/opt/$ch/lib\", nil)
puts r || \"nil\"
'''], cwd='$REPO').decode().strip()
print(out)
")"
    if [[ "$res" == *"refused link flag"* && "$res" == *"$ch"* ]]; then
      echo "  refused char '$ch' OK: '$res'"
    else
      echo "  refused char '$ch' FAILED: got '$res'" >&2
      return 1
    fi
  done

  # 5. LinkFp changes with LIBRARY_PATH and shim answer
  echo "  testing LinkFp changes with LIBRARY_PATH and shim answer..."
  local fp_check
  fp_check="$("$PY" -c "
import subprocess
out = subprocess.check_output(['./bin/crystal', 'eval', '''
require \"compiler/iyi/stale/link\"
require \"compiler/iyi/stale/encoding\"

# LIBRARY_PATH change
fp1 = Iyi::Stale::Link.fp(\"-lm\", nil, false, {\"LIBRARY_PATH\" => \"/lib1\"})
fp2 = Iyi::Stale::Link.fp(\"-lm\", nil, false, {\"LIBRARY_PATH\" => \"/lib2\"})
raise \"LIBRARY_PATH did not change LinkFp\" if fp1 == fp2

# Shim answer change in lib_flags
fp3 = Iyi::Stale::Link.fp(\"-lfoo\", nil, false, Hash(String, String?).new)
fp4 = Iyi::Stale::Link.fp(\"-lbar\", nil, false, Hash(String, String?).new)
raise \"shim answer did not change LinkFp\" if fp3 == fp4

puts \"OK\"
'''], cwd='$REPO').decode().strip()
print(out)
")"
  if [ "$fp_check" = "OK" ]; then
    echo "  LinkFp sensitivity OK: changes with LIBRARY_PATH and shim answer"
  else
    echo "  LinkFp sensitivity FAILED: $fp_check" >&2
    return 1
  fi

  echo "Link section PASSED"
}

run_rg4() {
  echo "== Running RG4: linking under randomized non-CHILD_ENV variables =="

  # 1. Inspect CHILD_ENV in build_inputs.cr
  echo "  verifying CHILD_ENV contains all documented driver-read variables..."
  local missing_var
  missing_var="$("$PY" -c "
import re, sys
with open('$REPO/src/compiler/iyi/build_inputs.cr') as f:
    text = f.read()
m = re.search(r'CHILD_ENV\s*=\s*%w\((.*?)\)', text, re.DOTALL)
if not m:
    sys.exit('CHILD_ENV not found in build_inputs.cr')
child_env = set(m.group(1).split())

# Documented driver/linker-read variables that MUST be in CHILD_ENV
driver_vars = [
    'PATH', 'CC', 'LIBRARY_PATH', 'LD_LIBRARY_PATH', 'LD_RUN_PATH',
    'COMPILER_PATH', 'GCC_EXEC_PREFIX', 'SDKROOT', 'MACOSX_DEPLOYMENT_TARGET',
    'LIB', 'LIBPATH', 'LINK', '_LINK_'
]
missing = [v for v in driver_vars if v not in child_env]
if missing:
    print('MISSING: ' + ' '.join(missing))
else:
    print('OK')
")"
  if [[ "$missing_var" == MISSING* ]]; then
    echo "RG4 FAILED: driver-read variable missing from CHILD_ENV: $missing_var" >&2
    return 1
  fi
  echo "  CHILD_ENV completeness OK: covers all documented driver-read variables"

  # 2. Test linking under randomized values of variables outside CHILD_ENV
  echo "  linking programs under randomized non-CHILD_ENV variables..."
  local mismatches=0
  local total=0

  # Quoted ldflags fixture
  local quoted_dir="/tmp/a b"
  mkdir -p "$quoted_dir"
  local fixture="$WORK/rg4_fixture.iyi"
  "$PY" -c "
with open('$fixture', 'w') as f:
    f.write('''@[Link(ldflags: \"-L\\'/tmp/a b\\' -lm\")]
lib LibTest
  fun cos(x : Float64) : Float64
end

print LibTest.cos(0.0)
''')
"
  local all_test_progs=("${C2_SAMPLES[@]}" "$fixture")

  for prog in "${all_test_progs[@]}"; do
    [ -f "$prog" ] || continue
    name="$(basename "$prog")"
    out="$WORK/prog_out"
    saved="$WORK/prog_saved"

    # Baseline stale link
    rm -rf "$CACHE"/*
    "$IYI" build --stale-key "$WORK/stale.key" -o "$out" "$prog"
    cp "$out" "$saved"

    # Stale link with randomized non-CHILD_ENV variables
    rm -rf "$CACHE"/*
    NON_CHILD_RANDOM_1="rand_val_${RANDOM}_${$}" \
    NON_CHILD_RANDOM_2="seed_$(date +%s%N 2>/dev/null || echo 12345)" \
    BUILD_EXTRA_TAG="build_tag_${RANDOM}" \
    TEST_NON_CHILD_ENV="arbitrary_value_${RANDOM}" \
    USER_NOTE="user_note_${$}" \
    "$IYI" build --stale-key "$WORK/stale.key" -o "$out" "$prog"

    if cmp "$saved" "$out" >/dev/null 2>&1; then
      echo "  RG4 cmp OK: $name"
    else
      echo "  RG4 cmp MISMATCH: $name" >&2
      mismatches=$((mismatches + 1))
    fi
    total=$((total + 1))
  done

  rm -rf "$quoted_dir"

  if [ "$mismatches" -gt 0 ]; then
    echo "RG4 FAILED: $mismatches mismatches out of $total" >&2
    return 1
  fi

  echo "RG4 PASSED: all $total programs linked byte-identical under randomized non-CHILD_ENV variables"
}

run_reach() {
  echo "== Running S3e: Reach section (reach walk vs codegen recording cross-check) =="
  "$PY" -c "
import os, sys, glob, subprocess, json

repo = sys.argv[1]
iyi = sys.argv[2]
work = sys.argv[3]

samples = sorted(glob.glob(os.path.join(repo, 'samples/iyi/*.iyi')))
bench = sorted(glob.glob(os.path.join(repo, 'bench/std_*_exercise.iyi')))
all_progs = samples + bench

mismatches = 0
for prog in all_progs:
    name = os.path.relpath(prog, repo)
    key_file = os.path.join(work, 'reach.key')
    out_file = os.path.join(work, 'prog.bin')
    if os.path.exists(key_file):
        os.remove(key_file)
    res = subprocess.run([iyi, 'build', '--stale-key', key_file, '-o', out_file, prog],
                         capture_output=True, text=True)
    if res.returncode != 0:
        print(f'  Reach build FAILED: {name} (exit {res.returncode})', file=sys.stderr)
        mismatches += 1
        continue
    if not os.path.exists(key_file):
        print(f'  Reach key missing: {name}', file=sys.stderr)
        mismatches += 1
        continue
    try:
        with open(key_file) as f:
            data = json.load(f)
        mm = data.get('reach', {}).get('mismatch', [])
        if mm:
            print(f'  Reach MISMATCH in {name}: {mm}', file=sys.stderr)
            mismatches += 1
    except Exception as e:
        print(f'  Reach JSON error {name}: {e}', file=sys.stderr)
        mismatches += 1

print(f'Reach checked {len(all_progs)} programs: {len(all_progs) - mismatches} OK, {mismatches} mismatches')
if mismatches > 0:
    sys.exit(1)
" "$REPO" "$IYI" "$WORK"
}

case "$MODE" in
  link)
    run_link
    ;;
  rg4)
    run_rg4
    ;;
  reach)
    run_reach
    ;;
  all)
    run_link
    run_rg4
    run_reach
    ;;
  *)
    echo "Unknown mode: $MODE (expected: all, link, rg4, reach)" >&2
    exit 1
    ;;
esac
