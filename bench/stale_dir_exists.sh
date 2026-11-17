#!/usr/bin/env bash
# A file replaced by a directory must invalidate Dir.exists?'s receipt.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    IYI="${IYI:-$REPO/.build/iyi.exe}"
    case "$IYI" in /*) IYI="$(cygpath -m "$IYI")" ;; esac
    ;;
  *) IYI="${IYI:-$REPO/bin/iyi}" ;;
esac

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done
if [ -z "$PY" ]; then
  echo "python3 required for the Dir.exists? cache regression" >&2
  exit 1
fi

"$PY" - "$REPO" "$IYI" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
iyi = sys.argv[2]
with tempfile.TemporaryDirectory(prefix="iyi-stale-dir-exists-") as temporary:
    work = Path(temporary)
    project = work / "project"
    project.mkdir()
    test = project / "dir_exists_test.iyi"
    test.write_text('import std/dir::{Dir}\nfound = Dir.exists?("entry")\nassert found || !found\n')
    entry = project / "entry"
    entry.write_text("file")
    env = os.environ.copy()
    env["IYI_CACHE_DIR"] = str(work / "cache")
    env.setdefault("IYI_PATH", os.pathsep.join((str(repo / "src"), str(repo / "samples" / "iyi"))))
    env["IYI_LIBRARY_PATH"] = str(repo / "lib")

    def run(label):
        result = subprocess.run([iyi, "test", "--cached", "--json", str(test)], cwd=project,
                                env=env, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(f"{label}: exit {result.returncode}\n{result.stdout}\n{result.stderr}")
        return json.loads(result.stdout)

    first = run("recording")
    unchanged = run("unchanged")
    if first["cached"] != 0 or unchanged["cached"] != 1:
        raise AssertionError(f"expected recording miss then unchanged hit: {first}\n{unchanged}")
    entry.unlink()
    entry.mkdir()
    changed = run("file replaced by directory")
    if changed["cached"] != 0:
        raise AssertionError(f"file replaced by directory reused its old receipt: {changed}")
    print("Dir.exists? cache regression: recording miss, unchanged hit, file-to-directory miss")
PY
