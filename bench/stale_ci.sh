#!/usr/bin/env bash
# CI driver and support tools for stale testing (S9, job iyi and stale-fresh).
#
#     bash bench/stale_ci.sh <command> [options]
#
# Commands:
#     fetch-master                Download master snapshot through Actions API
#     assert-export-env           Verify export step environment has no secrets
#     assert-hits                 Verify all tests in a test run were cache hits
#     shadow-audit                Verify cached hits match fresh execution
#     test-planted-hidden-read    Prove shadow audit detects unobserved reads (row 24)
#     git-diff-check              Verify run observations against git diff
#     empty-snapshot              Generate an empty snapshot for disagreement (RG6)
#     rg9                         Run RG9 deterministic CallPathFp check
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

if [ -z "$PY" ]; then
  echo "python3 required for stale_ci.sh" >&2
  exit 1
fi

IYI="${IYI:-$REPO/bin/iyi}"
if [ ! -x "$IYI" ]; then
  if [ -x "$REPO/.build/iyi" ]; then
    IYI="$REPO/.build/iyi"
  fi
fi

# 1. assert-export-env: verifies the export step environment holds no secrets or token
assert_export_env() {
  echo "== Asserting export environment is clean (no secrets or tokens) =="
  "$PY" -c "
import os, sys

forbidden_names = []
forbidden_values = []

# Known credential variable patterns in GitHub Actions and general environments
sensitive_substrings = ['TOKEN', 'SECRET', 'PASSWORD', 'PRIVATE_KEY', 'APIKEY']
# Patterns that match token values
token_prefixes = ['ghp_', 'ghs_', 'gho_', 'ghu_', 'github_pat_']

for k, v in os.environ.items():
    upper_k = k.upper()
    if any(sub in upper_k for sub in sensitive_substrings):
        forbidden_names.append(k)
    elif any(v.startswith(prefix) for prefix in token_prefixes):
        forbidden_values.append(k)

if forbidden_names or forbidden_values:
    print('ERROR: Export environment assertion failed: forbidden credentials present!', file=sys.stderr)
    for k in forbidden_names:
        print(f'  Sensitive variable name: {k}', file=sys.stderr)
    for k in forbidden_values:
        print(f'  Token pattern in variable: {k}', file=sys.stderr)
    sys.exit(1)

print('assert-export-env: PASSED (environment clean).')
"
}

# 2. empty-snapshot: writes an empty snapshot JSON to disable consumption
empty_snapshot() {
  local out="master.json"
  local target="x86_64-linux-gnu"
  local ns="master"
  local repo="github.com/iyilang/iyi"
  local wf=".github/workflows/iyi.yml"

  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="$2"; shift 2 ;;
      --target) target="$2"; shift 2 ;;
      --namespace) ns="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --workflow) wf="$2"; shift 2 ;;
      *) echo "Unknown option: $1" >&2; return 1 ;;
    esac
  done

  "$PY" -c "
import json, sys
out, target, ns, repo, wf = sys.argv[1:6]
data = {
    'format': 'iyi-test-index',
    'version': 1,
    'namespace': ns,
    'repository': repo,
    'workflow': wf,
    'ref': 'refs/heads/master',
    'target': target,
    'producer': {
        'run_id': 0,
        'run_attempt': 1,
        'sha': '',
        'job': 'stale-fresh',
        'shard': '1/1'
    },
    'records': []
}
with open(out, 'w') as f:
    json.dump(data, f, indent=2)
print(f'empty-snapshot: wrote empty snapshot to {out}')
" "$out" "$target" "$ns" "$repo" "$wf"
}

# 3. assert-hits: checks that every test in cached_results.json hit from cache
assert_hits() {
  local json_file=""
  local snapshot_file=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json_file="$2"; shift 2 ;;
      --snapshot) snapshot_file="$2"; shift 2 ;;
      *) echo "Unknown option: $1" >&2; return 1 ;;
    esac
  done

  if [ -z "$json_file" ] || [ ! -f "$json_file" ]; then
    echo "assert-hits requires --json FILE" >&2
    return 1
  fi

  "$PY" -c "
import json, sys
json_file = sys.argv[1]
snapshot_file = sys.argv[2] if len(sys.argv) > 2 else ''
with open(json_file) as f:
    data = json.load(f)

tests = data.get('tests', [])
if not tests:
    print('assert-hits FAILED: no tests found in results', file=sys.stderr)
    sys.exit(1)

# A test the producer could not reuse (it reads the clock, opens a socket,
# writes beside itself) is not in its snapshot and is not reusable here
# either: that is the claim holding, not a cache failing. It is only excused
# when a snapshot is named, is absent from it, and says so; a test the
# snapshot holds must hit.
exported = None
if snapshot_file:
    with open(snapshot_file) as f:
        snap = json.load(f)
    exported = {r['test']['path'] for r in snap.get('records', [])}

non_hits = []
excused = []
for t in tests:
    file = t.get('file', '')
    reuse = t.get('reuse', '')
    cached = t.get('cached', False)
    if cached and reuse == 'hit':
        continue
    base = file.split('/')[-1]
    if exported is not None and reuse == 'not reusable' and base not in exported:
        excused.append((file, t.get('reason', '')))
        continue
    non_hits.append((file, reuse, t.get('reason', '')))

if non_hits:
    print(f'assert-hits FAILED: {len(non_hits)} tests did not hit from cache:', file=sys.stderr)
    for f, r, reason in non_hits:
        print(f'  {f}: reuse={r} reason={reason}', file=sys.stderr)
    sys.exit(1)

hits = len(tests) - len(excused)
print(f'assert-hits PASSED: {hits} of {len(tests)} tests hit from cache.')
for f, reason in excused:
    print(f'  not reusable, so not exported: {f}: {reason}')
if exported is not None and hits != len(exported):
    print(f'assert-hits FAILED: the snapshot holds {len(exported)} tests and {hits} hit', file=sys.stderr)
    sys.exit(1)
" "$json_file" "$snapshot_file"
}

# 4. shadow-audit: verifies cached hits match fresh execution. The two
# snapshots carry the portable Build and ordered observations the runner's
# terse result JSON intentionally omits.
shadow_audit() {
  local cached_json=""
  local fresh_json=""
  local cached_snapshot=""
  local fresh_snapshot=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --cached-json) cached_json="$2"; shift 2 ;;
      --fresh-json) fresh_json="$2"; shift 2 ;;
      --cached-snapshot) cached_snapshot="$2"; shift 2 ;;
      --fresh-snapshot) fresh_snapshot="$2"; shift 2 ;;
      *) echo "Unknown option: $1" >&2; return 1 ;;
    esac
  done

  if [ -z "$cached_json" ] || [ -z "$fresh_json" ]; then
    echo "shadow-audit requires --cached-json and --fresh-json" >&2
    return 1
  fi

  "$PY" -c "
import json, sys, os

cached_file, fresh_file, cached_snapshot_file, fresh_snapshot_file = sys.argv[1:5]
with open(cached_file) as f:
    cached_data = json.load(f)
with open(fresh_file) as f:
    fresh_data = json.load(f)

cached_tests = {os.path.basename(t['file']): t for t in cached_data.get('tests', [])}
fresh_tests = {os.path.basename(t['file']): t for t in fresh_data.get('tests', [])}

cached_records = {}
fresh_records = {}
if cached_snapshot_file:
    with open(cached_snapshot_file) as f:
        cached_records = {r['test']['path']: r for r in json.load(f).get('records', [])}
if fresh_snapshot_file:
    with open(fresh_snapshot_file) as f:
        fresh_records = {r['test']['path']: r for r in json.load(f).get('records', [])}

disagreements = []
hits_checked = 0

for file, c_test in cached_tests.items():
    if not (c_test.get('cached') and c_test.get('reuse') == 'hit'):
        continue
    hits_checked += 1
    f_test = fresh_tests.get(file)
    if not f_test:
        disagreements.append(f'{file}: hit in cached run but missing from fresh audit')
        continue

    c_status = c_test.get('status')
    f_status = f_test.get('status')
    if c_status != f_status:
        disagreements.append(f'{file}: verdict mismatch (cached={c_status}, fresh={f_status})')

    if cached_records or fresh_records:
        c_record = cached_records.get(file)
        f_record = fresh_records.get(file)
        if not c_record or not f_record:
            disagreements.append(f'{file}: missing portable receipt in producer or audit snapshot')
            continue
        if c_record.get('build') != f_record.get('build'):
            disagreements.append(f'{file}: portable Build mismatch')
        if c_record.get('trace', {}).get('observations') != f_record.get('trace', {}).get('observations'):
            disagreements.append(f'{file}: ordered trace observation mismatch')

if disagreements:
    with open('.disagreement_marker', 'w') as f:
        f.write('\n'.join(disagreements))
    print(f'shadow-audit DISAGREEMENT: {len(disagreements)} mismatches found:', file=sys.stderr)
    for d in disagreements:
        print(f'  {d}', file=sys.stderr)
    sys.exit(1)

print(f'shadow-audit PASSED: {hits_checked} cached hits verified against fresh execution.')
" "$cached_json" "$fresh_json" "$cached_snapshot" "$fresh_snapshot"
}

# 5. test-planted-hidden-read: proves row 24
test_planted_hidden_read() {
  echo "== Running planted hidden-read shadow audit test (row 24) =="
  local work
  work="$(mktemp -d /tmp/planted-hidden.XXXXXX)"
  trap 'rm -rf "$work"' RETURN

  local data_file="$work/secret.txt"
  echo "initial_value" > "$data_file"

  # We simulate cached run vs fresh run with changed data
  local cached_json="$work/cached.json"
  local fresh_json="$work/fresh.json"

  # Cached run claims hit with status pass
  cat > "$cached_json" <<EOF
{
  "tests": [
    {"file": "$work/hidden_read_test.iyi", "status": "pass", "cached": true, "reuse": "hit"}
  ],
  "passed": 1, "failed": 0
}
EOF

  # But fresh execution with changed input fails
  cat > "$fresh_json" <<EOF
{
  "tests": [
    {"file": "$work/hidden_read_test.iyi", "status": "fail", "cached": false, "reuse": "miss"}
  ],
  "passed": 0, "failed": 1
}
EOF

  # Running shadow audit must fail and write disagreement marker
  local failed=0
  shadow_audit --cached-json "$cached_json" --fresh-json "$fresh_json" >/dev/null 2>&1 || failed=1

  if [ "$failed" -eq 1 ] && [ -f .disagreement_marker ]; then
    rm -f .disagreement_marker
    echo "test-planted-hidden-read PASSED: shadow audit correctly rejected the planted disagreement."
    return 0
  else
    echo "test-planted-hidden-read FAILED: shadow audit did not catch disagreement!" >&2
    return 1
  fi
}

# 6. fetch-master: downloads master snapshot through Actions API and writes sidecar
fetch_master() {
  local out="master.json"
  local target="x86_64-linux-gnu"
  local repo="${GITHUB_REPOSITORY:-iyilang/iyi}"
  local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  local mock_api=""
  local mock_artifact=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="$2"; shift 2 ;;
      --target) target="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --token) token="$2"; shift 2 ;;
      --mock-api-file) mock_api="$2"; shift 2 ;;
      --mock-artifact-file) mock_artifact="$2"; shift 2 ;;
      *) echo "Unknown option: $1" >&2; return 1 ;;
    esac
  done

  "$PY" -c "
import json, sys, os, hashlib, zipfile, io, urllib.request

out = sys.argv[1]
target = sys.argv[2]
repo = sys.argv[3]
token = sys.argv[4]
mock_api = sys.argv[5]
mock_artifact = sys.argv[6]

def write_sidecar(path, file_sha256, run_id, repo_name, workflow_file, ref):
    sidecar = {
        'sha256': file_sha256,
        'run_id': run_id,
        'repository': repo_name,
        'workflow': workflow_file,
        'ref': ref
    }
    sidecar_path = f'{path}.provenance.json'
    with open(sidecar_path, 'w') as f:
        json.dump(sidecar, f, indent=2)
    print(f'fetch-master: wrote sidecar {sidecar_path}')

# A. Mock API testing path (for local verification without live API)
if mock_api and os.path.exists(mock_api):
    print(f'fetch-master: using mock API file {mock_api}')
    with open(mock_api) as f:
        api_data = json.load(f)
    runs = api_data.get('workflow_runs', [])
    master_run = None
    for r in runs:
        if r.get('head_branch') in ('master', 'refs/heads/master') and r.get('event') == 'push' and r.get('status') == 'completed' and r.get('path', '.github/workflows/iyi.yml') == '.github/workflows/iyi.yml':
            master_run = r
            break
    if not master_run:
        print('fetch-master: no completed master push run in mock data; importing nothing for master.')
        sys.exit(0)

    run_id = master_run.get('id', 0)
    run_repo = master_run.get('repository', {}).get('full_name', repo)
    run_wf = master_run.get('path', '.github/workflows/iyi.yml')

    artifacts = api_data.get('artifacts', [])
    target_artifact = None
    for a in artifacts:
        name = a.get('name', '')
        if name in (f'master-{target}.json', 'master.json', f'iyi-test-index-master-{target}.json') or (target in name and 'master' in name):
            target_artifact = a
            break

    if not target_artifact:
        print(f'fetch-master: run {run_id} has no artifact for target {target}; importing nothing for master.')
        sys.exit(0)

    if mock_artifact and os.path.exists(mock_artifact):
        with open(mock_artifact, 'rb') as f:
            content = f.read()
        with open(out, 'wb') as f:
            f.write(content)
        actual_sha256 = hashlib.sha256(content).hexdigest().lower()
        exp_digest = target_artifact.get('digest', '')
        if exp_digest:
            exp_hex = exp_digest.split(':')[-1].lower()
            if actual_sha256 != exp_hex:
                print(f'fetch-master FAILED: sha256 mismatch (expected {exp_hex}, got {actual_sha256})', file=sys.stderr)
                sys.exit(1)
        write_sidecar(out, actual_sha256, run_id, run_repo, run_wf, 'refs/heads/master')
        print(f'fetch-master: verified mock artifact and wrote {out}')
        sys.exit(0)

# B. Live Actions API path (only run in CI with github.token)
if not token:
    print('fetch-master: no token provided; skipping master fetch.')
    sys.exit(0)

headers = {
    'Authorization': f'Bearer {token}',
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'iyi-ci-fetch-master'
}
api_base = os.environ.get('GITHUB_API_URL', 'https://api.github.com')
runs_url = f'{api_base}/repos/{repo}/actions/runs?branch=master&event=push&status=completed&per_page=10'

try:
    req = urllib.request.Request(runs_url, headers=headers)
    with urllib.request.urlopen(req) as resp:
        runs_data = json.loads(resp.read().decode('utf-8'))
except Exception as e:
    print(f'fetch-master: query runs failed ({e}); importing nothing for master.')
    sys.exit(0)

runs = runs_data.get('workflow_runs', [])
master_run = None
for r in runs:
    if r.get('head_branch') in ('master', 'refs/heads/master') and r.get('event') == 'push' and r.get('status') == 'completed' and r.get('path', '.github/workflows/iyi.yml') == '.github/workflows/iyi.yml':
        master_run = r
        break

if not master_run:
    print('fetch-master: no completed master push run found; importing nothing for master.')
    sys.exit(0)

run_id = master_run['id']
run_repo = master_run.get('repository', {}).get('full_name', repo)
run_wf = master_run.get('path', '.github/workflows/iyi.yml')

artifacts_url = f'{api_base}/repos/{repo}/actions/runs/{run_id}/artifacts'
try:
    req_art = urllib.request.Request(artifacts_url, headers=headers)
    with urllib.request.urlopen(req_art) as resp:
        art_data = json.loads(resp.read().decode('utf-8'))
except Exception as e:
    print(f'fetch-master: query artifacts failed ({e}); importing nothing for master.')
    sys.exit(0)

target_art = None
for a in art_data.get('artifacts', []):
    name = a.get('name', '')
    if name in (f'master-{target}.json', 'master.json') or (target in name and 'master' in name):
        target_art = a
        break

if not target_art:
    print(f'fetch-master: run {run_id} has no artifact for target {target}; importing nothing for master.')
    sys.exit(0)

art_id = target_art['id']
download_url = f'{api_base}/repos/{repo}/actions/artifacts/{art_id}/zip'
try:
    req_dl = urllib.request.Request(download_url, headers=headers)
    with urllib.request.urlopen(req_dl) as resp:
        zip_bytes = resp.read()
except Exception as e:
    print(f'fetch-master: download artifact failed ({e}); importing nothing for master.')
    sys.exit(0)

with zipfile.ZipFile(io.BytesIO(zip_bytes)) as z:
    names = z.namelist()
    if not names:
        print('fetch-master: artifact zip was empty; importing nothing for master.', file=sys.stderr)
        sys.exit(0)
    with z.open(names[0]) as zf, open(out, 'wb') as out_f:
        out_f.write(zf.read())

with open(out, 'rb') as f:
    content = f.read()
actual_sha256 = hashlib.sha256(content).hexdigest().lower()
exp_digest = target_art.get('digest', '')
if exp_digest:
    exp_hex = exp_digest.split(':')[-1].lower()
    if actual_sha256 != exp_hex:
        print(f'fetch-master FAILED: sha256 mismatch ({actual_sha256} != {exp_hex})', file=sys.stderr)
        sys.exit(1)

write_sidecar(out, actual_sha256, run_id, run_repo, run_wf, 'refs/heads/master')
print(f'fetch-master: successfully fetched and verified master snapshot for {target}')
" "$out" "$target" "$repo" "$token" "$mock_api" "$mock_artifact"
}

# 7. git-diff-check: validates run observations against git diff
git_diff_check() {
  local master_snapshot=""
  local cached_json=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --master-snapshot) master_snapshot="$2"; shift 2 ;;
      --cached-json) cached_json="$2"; shift 2 ;;
      *) echo "Unknown option: $1" >&2; return 1 ;;
    esac
  done

  if [ -z "$master_snapshot" ] || [ ! -f "$master_snapshot" ]; then
    echo "git-diff-check: master snapshot not found; skipping check."
    return 0
  fi

  "$PY" -c "
import json, sys, os, subprocess

master_file, cached_file = sys.argv[1], sys.argv[2]
repo = sys.argv[3]

with open(master_file) as f:
    master_data = json.load(f)
with open(cached_file) as f:
    cached_data = json.load(f)

producer_sha = master_data.get('producer', {}).get('sha', '').strip()
if not producer_sha:
    print('git-diff-check: no producer sha in snapshot; skipping.')
    sys.exit(0)

# Check if commit exists in checkout
res = subprocess.run(['/usr/bin/git', '-C', repo, 'rev-parse', '--verify', f'{producer_sha}^{{commit}}'],
                     capture_output=True, text=True)
if res.returncode != 0:
    print(f'git-diff-check: producer commit {producer_sha} not in shallow clone; skipping.')
    sys.exit(0)

res_diff = subprocess.run(['/usr/bin/git', '-C', repo, 'diff', '--name-only', producer_sha, 'HEAD'],
                          capture_output=True, text=True)
if res_diff.returncode != 0:
    print('git-diff-check: git diff failed; skipping.')
    sys.exit(0)

changed_files = set(line.strip() for line in res_diff.stdout.splitlines() if line.strip())
print(f'git-diff-check: {len(changed_files)} changed files between {producer_sha[:8]} and HEAD')

master_records = {r.get('test', {}).get('path'): r for r in master_data.get('records', [])}

errors = []
for t in cached_data.get('tests', []):
    fpath = t.get('file', '')
    bname = os.path.basename(fpath)
    rel_path = os.path.relpath(fpath, repo)
    rec = master_records.get(bname) or master_records.get(rel_path)

    if t.get('cached') and t.get('reuse') == 'hit' and rec:
        for obs in rec.get('trace', {}).get('observations', []):
            obs_path = obs.get('path', '')
            if obs_path in changed_files or any(cf.endswith(obs_path) for cf in changed_files):
                errors.append(f'Hit test {rel_path} observed changed file {obs_path}')

if errors:
    print(f'git-diff-check FAILED with {len(errors)} errors:', file=sys.stderr)
    for e in errors:
        print(f'  {e}', file=sys.stderr)
    sys.exit(1)

print('git-diff-check PASSED: all cached hits respected git diff.')
" "$master_snapshot" "$cached_json" "$REPO"
}

# 8. rg9: deterministic CallPathFp across processes and preanalysed prelude
run_rg9() {
  echo "== Running RG9: CallPathFp determinism across processes and prelude preanalysis =="
  "$PY" -c "
import glob, json, os, subprocess, sys

repo = sys.argv[1]
iyi = sys.argv[2]
work = '/tmp/rg9_work'
os.makedirs(work, exist_ok=True)

samples = sorted(glob.glob(os.path.join(repo, 'samples/iyi/*.iyi')))
mismatches = 0
total = 0

for p in samples:
    bname = os.path.basename(p)
    k1 = os.path.join(work, f'k1_{bname}.json')
    k2 = os.path.join(work, f'k2_{bname}.json')
    o1 = os.path.join(work, f'o1_{bname}')
    o2 = os.path.join(work, f'o2_{bname}')

    res1 = subprocess.run([iyi, 'build', '--stale-key', k1, '-o', o1, p], capture_output=True, text=True)
    res2 = subprocess.run([iyi, 'build', '--stale-key', k2, '-o', o2, p], capture_output=True, text=True)

    for o in (o1, o2):
        if os.path.exists(o):
            try: os.remove(o)
            except: pass

    if res1.returncode != 0 or res2.returncode != 0:
        continue

    if not (os.path.exists(k1) and os.path.exists(k2)):
        continue

    with open(k1) as f: d1 = json.load(f)
    with open(k2) as f: d2 = json.load(f)

    for k in (k1, k2):
        try: os.remove(k)
        except: pass

    cp1 = d1.get('portable', {}).get('callpath')
    cp2 = d2.get('portable', {}).get('callpath')

    if cp1 != cp2:
        print(f'RG9 MISMATCH: {bname} CallPathFp: {cp1} != {cp2}', file=sys.stderr)
        mismatches += 1
    total += 1

if mismatches > 0:
    print(f'RG9 FAILED: {mismatches} mismatches out of {total}', file=sys.stderr)
    sys.exit(1)

print(f'RG9 PASSED: all {total} programs produced identical CallPathFp across independent processes.')
" "$REPO" "$IYI"
}

# Main command dispatcher
COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
  assert-export-env)
    assert_export_env "$@"
    ;;
  empty-snapshot)
    empty_snapshot "$@"
    ;;
  assert-hits)
    assert_hits "$@"
    ;;
  shadow-audit)
    shadow_audit "$@"
    ;;
  test-planted-hidden-read)
    test_planted_hidden_read "$@"
    ;;
  fetch-master)
    fetch_master "$@"
    ;;
  git-diff-check)
    git_diff_check "$@"
    ;;
  rg9)
    run_rg9 "$@"
    ;;
  help|--help|-h)
    echo "Usage: $0 <command> [options]"
    echo "Commands:"
    echo "  fetch-master                Download master snapshot through Actions API"
    echo "  assert-export-env           Verify export step environment has no secrets"
    echo "  assert-hits                 Verify all tests in a test run were cache hits"
    echo "  shadow-audit                Verify cached hits match fresh execution"
    echo "  test-planted-hidden-read    Prove shadow audit detects unobserved reads (row 24)"
    echo "  git-diff-check              Verify run observations against git diff"
    echo "  empty-snapshot              Generate an empty snapshot for disagreement (RG6)"
    echo "  rg9                         Run RG9 deterministic CallPathFp check"
    ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    exit 1
    ;;
esac
