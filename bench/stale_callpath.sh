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
import os, sys, glob, subprocess, json, time
from concurrent.futures import ThreadPoolExecutor

repo = sys.argv[1]
iyi = sys.argv[2]
work = sys.argv[3]

samples = sorted(glob.glob(os.path.join(repo, 'samples/iyi/*.iyi')))
bench = sorted(glob.glob(os.path.join(repo, 'bench/std_*_exercise.iyi')))
all_progs = samples + bench

def check_prog(prog):
    name = os.path.relpath(prog, repo)
    pid = os.getpid()
    t_ns = time.time_ns()
    base = os.path.basename(prog)
    key_file = os.path.join(work, f'reach_{base}_{pid}_{t_ns}.key')
    out_file = os.path.join(work, f'prog_{base}_{pid}_{t_ns}.bin')
    extra_flags = os.environ.get('IYI_BUILD_FLAGS', '').split()
    cmd = [iyi, 'build'] + extra_flags + ['--stale-key', key_file, '-o', out_file, prog]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(f'  Reach build FAILED: {name} (exit {res.returncode})', file=sys.stderr)
        return False
    if not os.path.exists(key_file):
        print(f'  Reach key missing: {name}', file=sys.stderr)
        return False
    ok = True
    try:
        with open(key_file) as f:
            data = json.load(f)
        mm = data.get('reach', {}).get('mismatch', [])
        if mm:
            print(f'  Reach MISMATCH in {name}: {mm}', file=sys.stderr)
            ok = False
    except Exception as e:
        print(f'  Reach JSON error {name}: {e}', file=sys.stderr)
        ok = False
    finally:
        if os.path.exists(key_file): os.remove(key_file)
        if os.path.exists(out_file): os.remove(out_file)
    return ok

workers = min(8, os.cpu_count() or 4)
with ThreadPoolExecutor(max_workers=workers) as ex:
    results = list(ex.map(check_prog, all_progs))

mismatches = sum(1 for r in results if not r)
print(f'Reach checked {len(all_progs)} programs: {len(all_progs) - mismatches} OK, {mismatches} mismatches')
if mismatches > 0:
    sys.exit(1)
" "$REPO" "$IYI" "$WORK"
}

run_check() {
  echo "== Running S3g: Check section (fingerprints, Build, accept/block, hit/linked phases) =="
  "$PY" -c "
import os, sys, glob, subprocess, json, time, shutil

repo = sys.argv[1]
iyi = sys.argv[2]
work = sys.argv[3]

sample = os.path.join(repo, 'samples/iyi/shapes.iyi')
if not os.path.exists(sample):
    sample = sorted(glob.glob(os.path.join(repo, 'samples/iyi/*.iyi')))[0]

build_cache = os.path.join(work, 'cache')
os.makedirs(build_cache, exist_ok=True)
env_base = os.environ.copy()
env_base['IYI_CACHE_DIR'] = build_cache

# 1. First build: linked phase, outputs produced
key1 = os.path.join(work, 'run1.key')
bin1 = os.path.join(work, 'run1.bin')
if os.path.exists(key1): os.remove(key1)
if os.path.exists(bin1): os.remove(bin1)

res1 = subprocess.run([iyi, 'build', '--stale-key', key1, '-o', bin1, sample],
                      env=env_base, capture_output=True, text=True)
assert res1.returncode == 0, f'First build failed: {res1.stderr}'
assert os.path.exists(bin1), 'First build output binary missing'
assert os.path.exists(key1), 'First build key file missing'

with open(key1) as f:
    d1 = json.load(f)
assert d1['format'] == 'iyi-stale-key', f'Bad format: {d1.get(\"format\")}'
assert d1['version'] == 1
assert d1['phase'] == 'linked', f'Expected phase linked, got {d1[\"phase\"]}'
local_build = d1['local']['build']
portable_build = d1['portable']['build']
assert len(local_build) == 64
assert len(portable_build) == 64
assert d1['blocked'] is False
assert d1['hit'] is None
print('  First build: phase linked OK')

# 2. Second build with --stale-accept local Build: hit phase, no output binary, no newer cache files, no stdout/stderr
marker = os.path.join(build_cache, 'marker.tmp')
with open(marker, 'w') as f:
    f.write('marker')
marker_mtime = os.path.getmtime(marker)
time.sleep(0.02)

accept_local = os.path.join(work, 'accept_local.json')
with open(accept_local, 'w') as f:
    json.dump([{'mode': 'local', 'build': local_build}], f)

key2 = os.path.join(work, 'run2.key')
bin2 = os.path.join(work, 'run2.bin')
if os.path.exists(key2): os.remove(key2)
if os.path.exists(bin2): os.remove(bin2)

res2 = subprocess.run([iyi, 'build', '--stale-key', key2, '--stale-accept', accept_local, '-o', bin2, sample],
                      env=env_base, capture_output=True, text=True)
assert res2.returncode == 0, f'Second build failed: {res2.stderr}'
assert not os.path.exists(bin2), 'Hit build should write no output file'
assert res2.stdout == '', f'Hit build should print nothing on stdout, got: {res2.stdout}'
assert res2.stderr == '', f'Hit build should print nothing on stderr, got: {res2.stderr}'

with open(key2) as f:
    d2 = json.load(f)
assert d2['phase'] == 'hit', f'Expected phase hit, got {d2[\"phase\"]}'
assert d2['hit'] == {'mode': 'local', 'build': local_build}, f'Bad hit: {d2.get(\"hit\")}'
assert d2['blocked'] is False

# Verify no file newer than marker in cache dir
newer_cache_files = []
for root, _, files in os.walk(build_cache):
    for fn in files:
        if fn == 'marker.tmp': continue
        fp = os.path.join(root, fn)
        if os.path.getmtime(fp) > marker_mtime:
            newer_cache_files.append(fp)
assert not newer_cache_files, f'Cache dir has modified files on hit: {newer_cache_files}'
print('  Second build local accept: phase hit, no output, clean cache, silent OK')

# 3. Portable accept hits similarly
accept_portable = os.path.join(work, 'accept_portable.json')
with open(accept_portable, 'w') as f:
    json.dump([{'mode': 'portable', 'build': portable_build}], f)

key3 = os.path.join(work, 'run3.key')
bin3 = os.path.join(work, 'run3.bin')
if os.path.exists(key3): os.remove(key3)
if os.path.exists(bin3): os.remove(bin3)

res3 = subprocess.run([iyi, 'build', '--stale-key', key3, '--stale-accept', accept_portable, '-o', bin3, sample],
                      env=env_base, capture_output=True, text=True)
assert res3.returncode == 0
assert not os.path.exists(bin3)
assert res3.stdout == ''
assert res3.stderr == ''

with open(key3) as f:
    d3 = json.load(f)
assert d3['phase'] == 'hit'
assert d3['hit'] == {'mode': 'portable', 'build': portable_build}
print('  Second build portable accept: phase hit, silent OK')

# 4. Matching block entry wins: blocked: true, phase linked
block_file = os.path.join(work, 'block.json')
with open(block_file, 'w') as f:
    json.dump([{'mode': 'local', 'build': local_build}], f)

key4 = os.path.join(work, 'run4.key')
bin4 = os.path.join(work, 'run4.bin')
if os.path.exists(key4): os.remove(key4)
if os.path.exists(bin4): os.remove(bin4)

res4 = subprocess.run([iyi, 'build', '--stale-key', key4, '--stale-accept', accept_local, '--stale-block', block_file, '-o', bin4, sample],
                      env=env_base, capture_output=True, text=True)
assert res4.returncode == 0
assert os.path.exists(bin4)
with open(key4) as f:
    d4 = json.load(f)
assert d4['phase'] == 'linked', f'Expected phase linked when blocked, got {d4[\"phase\"]}'
assert d4['blocked'] is True
assert d4['hit'] is None
print('  Matching block entry wins: blocked: true, phase linked OK')

# 5. -s, --verbose and different OUT paths keep Build; IYI_OPTS=--release changes it (row 7)
key_disp = os.path.join(work, 'disp.key')
bin_disp = os.path.join(work, 'disp.bin')
res_disp = subprocess.run([iyi, 'build', '-s', '--verbose', '--stale-key', key_disp, '-o', bin_disp, sample],
                          env=env_base, capture_output=True, text=True)
with open(key_disp) as f:
    d_disp = json.load(f)
assert d_disp['local']['build'] == local_build, 'Display flags altered Build'

key_rel = os.path.join(work, 'rel.key')
bin_rel = os.path.join(work, 'rel.bin')
env_rel = env_base.copy()
env_rel['IYI_OPTS'] = '--release'
res_rel = subprocess.run([iyi, 'build', '--stale-key', key_rel, '-o', bin_rel, sample],
                         env=env_rel, capture_output=True, text=True)
with open(key_rel) as f:
    d_rel = json.load(f)
assert d_rel['local']['build'] != local_build, 'IYI_OPTS=--release should change Build'
print('  Flag sensitivity: -s/--verbose/OUT keep Build, --release changes it OK')

# 6. A refused mode refuses and never hits (44). --emit llvm-ir is a refused
# mode the build verb accepts and still links; --no-cleanup stays a
# no-codegen tooling flag (an unclean tree cannot be generated), and its
# refusal is covered in-process by spec/compiler/stale/check_spec.cr.
key_nc = os.path.join(work, 'nc.key')
bin_nc = os.path.join(work, 'nc.bin')
env_nc = env_base.copy()
env_nc['IYI_OPTS'] = '--emit llvm-ir'
res_nc = subprocess.run([iyi, 'build', '--stale-key', key_nc, '--stale-accept', accept_local, '-o', bin_nc, sample],
                        env=env_nc, capture_output=True, text=True, cwd=work)
assert res_nc.returncode == 0, f'--emit build failed: {res_nc.stderr[-500:]}'
with open(key_nc) as f:
    d_nc = json.load(f)
assert d_nc['phase'] != 'hit', '--emit should never hit'
nc_reasons = [r['reason'] for r in d_nc.get('not_reusable', []) if r.get('category') == 'refused build mode']
assert any('--emit' in r for r in nc_reasons), f'Missing --emit refusal: {d_nc.get(\"not_reusable\")}'
print('  --emit: refuses and never hits OK')

# 7. IYI_OPTS=--crystal gives the crystal reason
key_cr = os.path.join(work, 'cr.key')
bin_cr = os.path.join(work, 'cr.bin')
env_cr = env_base.copy()
env_cr['IYI_OPTS'] = '--crystal'
res_cr = subprocess.run([iyi, 'build', '--stale-key', key_cr, '-o', bin_cr, sample],
                        env=env_cr, capture_output=True, text=True)
with open(key_cr) as f:
    d_cr = json.load(f)
cr_reasons = [r['reason'] for r in d_cr.get('not_reusable', []) if r.get('category') == 'crystal']
assert any('Crystal library effects are not classified' in r for r in cr_reasons), f'Missing crystal reason: {d_cr.get(\"not_reusable\")}'
print('  --crystal: gives crystal reason OK')

# 8. Type error writes no OUT and exits nonzero
bad_src = os.path.join(work, 'type_error.iyi')
with open(bad_src, 'w') as f:
    f.write('a = 1 + \"foo\"\n')
key_err = os.path.join(work, 'type_error.key')
bin_err = os.path.join(work, 'type_error.bin')
if os.path.exists(key_err): os.remove(key_err)
res_err = subprocess.run([iyi, 'build', '--stale-key', key_err, '-o', bin_err, bad_src],
                         env=env_base, capture_output=True, text=True)
assert res_err.returncode != 0, 'Type error should exit nonzero'
assert not os.path.exists(key_err), 'Type error should write no OUT key file'
print('  Type error: writes no OUT and exits nonzero OK')

# 9. Link failure after check leaves phase checked with Build
link_bad = os.path.join(work, 'link_bad.iyi')
with open(link_bad, 'w') as f:
    f.write('lib BadLib; fun non_existent_fn_49392 : Void; end; BadLib.non_existent_fn_49392\n')
key_lfail = os.path.join(work, 'link_fail.key')
bin_lfail = os.path.join(work, 'link_fail.bin')
if os.path.exists(key_lfail): os.remove(key_lfail)
res_lfail = subprocess.run([iyi, 'build', '--stale-key', key_lfail, '-o', bin_lfail, link_bad],
                           env=env_base, capture_output=True, text=True)
assert res_lfail.returncode != 0, 'Link failure should exit nonzero'
assert os.path.exists(key_lfail), 'Key file should exist after check even on link failure'
with open(key_lfail) as f:
    d_lfail = json.load(f)
assert d_lfail['phase'] == 'checked', f'Expected phase checked on link failure, got {d_lfail[\"phase\"]}'
assert len(d_lfail['local']['build']) == 64
print('  Link failure: leaves phase checked with Build OK')

# 10. Changed CHILD_ENV changes Build, changed display var does not (41)
env_child = env_base.copy()
env_child['LIBRARY_PATH'] = '/opt/different_path'
key_cenv = os.path.join(work, 'cenv.key')
bin_cenv = os.path.join(work, 'cenv.bin')
res_cenv = subprocess.run([iyi, 'build', '--stale-key', key_cenv, '-o', bin_cenv, sample],
                          env=env_child, capture_output=True, text=True)
with open(key_cenv) as f:
    d_cenv = json.load(f)
assert d_cenv['local']['build'] != local_build, 'Changed CHILD_ENV (LIBRARY_PATH) should change Build'

env_disp = env_base.copy()
env_disp['DUMP'] = '1'
env_disp['NO_COLOR'] = '1'
key_disp2 = os.path.join(work, 'disp2.key')
bin_disp2 = os.path.join(work, 'disp2.bin')
res_disp2 = subprocess.run([iyi, 'build', '--stale-key', key_disp2, '-o', bin_disp2, sample],
                           env=env_disp, capture_output=True, text=True)
with open(key_disp2) as f:
    d_disp2 = json.load(f)
assert d_disp2['local']['build'] == local_build, 'Changed display var (DUMP/NO_COLOR) should not change Build'
print('  CHILD_ENV sensitivity vs display var invariance OK')

print('S3g check gate: ALL ACCEPTANCE TESTS PASSED')
" "$REPO" "$IYI" "$WORK"
}

run_rg8() {
  echo "== Running RG8: normalized IR versus CallPathFp mutations =="
  "$PY" "$REPO/bench/stale_rg8.py" --repo "$REPO" --compiler "$IYI" --work "$WORK/rg8"

  echo "  proving the def-body encoder field is load-bearing..."
  local dropped="$WORK/iyi-rg8-drop-def-body"
  "$REPO/bin/crystal" build -D rg8_drop_def_body -o "$dropped" "$REPO/src/compiler/iyi.cr"
  "$PY" "$REPO/bench/stale_rg8.py" --repo "$REPO" --compiler "$dropped" \
    --work "$WORK/rg8-drop-def-body" --program "$REPO/samples/iyi/calc.iyi" \
    --kind body --expect-failure-kind body
  echo "RG8 def-body mutation proof PASSED"
}

run_rg9() {
  echo "== Running RG9: CallPathFp process and warm-prelude determinism =="
  "$PY" "$REPO/bench/stale_rg9.py" --repo "$REPO" --compiler "$IYI" --work "$WORK/rg9"
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
  check)
    run_check
    ;;
  rg8)
    run_rg8
    ;;
  rg9)
    run_rg9
    ;;
  all)
    run_link
    run_rg4
    run_reach
    run_check
    run_rg8
    run_rg9
    ;;
  *)
    echo "Unknown mode: $MODE (expected: all, link, rg4, reach, check, rg8, rg9)" >&2
    exit 1
    ;;
esac
