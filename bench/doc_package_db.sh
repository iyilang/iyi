#!/usr/bin/env bash
# Print a comparable hash of the same package's doc JSON on each host.
# The package gate remains offline; this separate probe fetches one pinned tag.
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    WORK="$(cygpath -m "$WORK")"
    PYTHON=python
    ;;
  *) PYTHON=python3 ;;
esac
trap 'rm -rf -- "$WORK"' EXIT

# Force the same checkout bytes even if the machine's git converts line endings.
git -c core.autocrlf=false -c core.eol=lf -c advice.detachedHead=false \
  clone --quiet --depth 1 --branch v0.5.0 https://github.com/iyilang/db.git "$WORK/db"
commit="$(git -C "$WORK/db" rev-parse HEAD)"
if [ "$commit" != 7eb102404dd9b005856b328d8cfba71a9009b19c ]; then
  echo "db v0.5.0 resolved to $commit, not the pinned commit" >&2
  exit 1
fi
"$IYI" doc --json "$WORK/db" > "$WORK/db-doc.json"
"$IYI" doc --json "$WORK/db" > "$WORK/db-doc-again.json"
"$PYTHON" - "$WORK/db-doc.json" "$WORK/db-doc-again.json" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

raw = Path(sys.argv[1]).read_bytes()
assert raw == Path(sys.argv[2]).read_bytes(), "db output changed between runs"
assert raw.endswith(b"\n") and b"\r" not in raw, "db JSON must use LF"
data = json.loads(raw)
assert set(data) == {"package", "compiler", "modules"}
assert data["package"] == "github.com/iyilang/db"
assert [item["module"] for item in data["modules"]] == [
    "db", "db/core", "db/errors", "db/pooling", "db/query_params",
    "db/serializable", "db/spec", "db/testing/dummy_driver", "db/value",
]

def doc_count(value):
    if isinstance(value, dict):
        return int(bool(value.get("doc"))) + sum(doc_count(v) for v in value.values())
    if isinstance(value, list):
        return sum(doc_count(v) for v in value)
    return 0

for item in data["modules"]:
    assert set(item) == {"module", "api"}
    assert item["api"]["module"] == item["module"]
    assert doc_count(item["api"]), "no doc comments in " + item["module"]
print("db v0.5.0 doc JSON compiler:", data["compiler"])
print("db v0.5.0 doc JSON sha256:", hashlib.sha256(raw).hexdigest())
PY
