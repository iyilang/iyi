#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IYI=${IYI:-"$ROOT/bin/iyi"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/iyi-npm.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT"
os=$(node -p process.platform)
cpu=$(node -p process.arch)
"$IYI" build --release -o "$WORK/hello" samples/iyi/hello.iyi
native=$("$WORK/hello")
node samples/npm/assemble.mjs "$WORK/packages" "$os" "$cpu" "$WORK/hello"
mkdir "$WORK/tarballs" "$WORK/project"
(cd "$WORK/packages/hello" && npm pack --offline --pack-destination "$WORK/tarballs" >/dev/null)
(cd "$WORK/packages/hello-$os-$cpu" && npm pack --offline --pack-destination "$WORK/tarballs" >/dev/null)
cd "$WORK/project"
printf '{"name":"recipe-test","version":"1.0.0","private":true}\n' > package.json
npm install --offline --no-audit --no-fund "$WORK/tarballs/hello-1.0.0.tgz" "$WORK/tarballs/hello-$os-$cpu-1.0.0.tgz"
actual=$(npx --offline --no-install hello)
[ "$actual" = "$native" ] || { echo 'npm output differs from native' >&2; exit 1; }
printf 'native and npx: %s\n' "$actual"

mv "node_modules/hello-$os-$cpu" "$WORK/removed"
if node node_modules/hello/bin/hello.js >"$WORK/out" 2>&1; then echo 'missing-package control passed unexpectedly' >&2; exit 1; fi
if ! grep -F "missing platform package hello-$os-$cpu" "$WORK/out"; then cat "$WORK/out"; exit 1; fi
mv "$WORK/removed" "node_modules/hello-$os-$cpu"
if IYI_NPM_TEST_OS=unsupported node node_modules/hello/bin/hello.js >"$WORK/out" 2>&1; then echo 'unsupported-platform control passed unexpectedly' >&2; exit 1; fi
if ! grep -F "unsupported platform unsupported-$cpu" "$WORK/out"; then cat "$WORK/out"; exit 1; fi
node - "$WORK/project/node_modules/hello/bin/hello.js" <<'NODE'
const fs = require('fs');
const p = process.argv[2];
const source = fs.readFileSync(p, 'utf8');
const broken = source.replace('`hello-${target}`', '`wrong-${target}`');
if (source === broken) throw new Error('wrong-name mutation did not apply');
fs.writeFileSync(p, broken);
NODE
if npx --offline --no-install hello >"$WORK/out" 2>&1; then echo 'wrong-name control passed unexpectedly' >&2; exit 1; fi
if ! grep -F "missing platform package wrong-$os-$cpu" "$WORK/out"; then cat "$WORK/out"; exit 1; fi
ruby -ryaml -e '
  y = YAML.load_file(ARGV[0]); jobs = y.fetch("jobs");
  matrix = jobs.fetch("build").fetch("strategy").fetch("matrix").fetch("include");
  abort "missing matrix" unless matrix.map { |x| [x["os"], x["cpu"]] }.sort == [["darwin", "arm64"], ["linux", "x64"], ["win32", "x64"]];
  pub = jobs.fetch("publish");
  abort "missing OIDC" unless pub.fetch("permissions")["id-token"] == "write" && pub.fetch("environment") == "npm" && pub.fetch("steps").any? { |s| s["run"].to_s.include?("--provenance") };
  puts "release template: matrix and OIDC provenance present (publishing not exercised)"
' "$ROOT/samples/npm/release.yml"
echo 'npm recipe: ALL CHECKS PASSED'
