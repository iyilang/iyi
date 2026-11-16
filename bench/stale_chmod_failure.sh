#!/usr/bin/env bash
# A caught chmod failure outside scratch must still record the attempted write.
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
  echo "python3 required for the caught chmod failure regression" >&2
  exit 1
fi

"$PY" - "$REPO" "$IYI" <<'PY'
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
iyi = sys.argv[2]
with tempfile.TemporaryDirectory(prefix="iyi-stale-chmod-failure-") as temporary:
    work = Path(temporary)
    project = work / "project"
    project.mkdir()
    scratch = work / "scratch"
    scratch.mkdir()
    # Catching a panic starts the scheduler, whose pre-existing process
    # taint suppresses every later trace record. Silence only that taint in
    # this observer copy so the write at the caught failure is measurable.
    overlay = work / "overlay"
    observer = overlay / "std" / "observe.iyi"
    observer.parent.mkdir(parents=True)
    original = (repo / "src" / "std" / "observe.iyi").read_text(encoding="utf-8")
    before = 'pub def __iyi_observe_process(site : String) : Nil\n  not_reusable(36_u8, site)\nend'
    scheduler = (repo / "src" / "iyi" / "concurrency.iyi").read_text(encoding="utf-8").splitlines()
    matches = [line for line, text in enumerate(scheduler, 1) if "def self.resolved : Int32" in text]
    if len(matches) != 1:
        raise AssertionError("scheduler resolved fixture no longer applies")
    site = f"iyi/concurrency.iyi:{matches[0]}"
    after = ('pub def __iyi_observe_process(site : String) : Nil\n'
             f'  not_reusable(36_u8, site) unless site.includes?("{site}")\nend')
    if original.count(before) != 1:
        raise AssertionError("scheduler process observer fixture no longer applies")
    observer.write_text(original.replace(before, after), encoding="utf-8")
    prelude = overlay / "iyi" / "prelude.iyi"
    prelude.parent.mkdir(parents=True)
    prelude_source = (repo / "src" / "iyi" / "prelude.iyi").read_text(encoding="utf-8")
    if prelude_source.count('require "../std/observe"') != 1:
        raise AssertionError("observer prelude fixture no longer applies")
    runtime_path = os.path.relpath(repo / "src" / "iyi", prelude.parent).replace("\\", "/")
    prelude_source = prelude_source.replace('require "./', f'require "{runtime_path}/')
    prelude.write_text(prelude_source, encoding="utf-8")
    target = project / "absent"
    test = project / "chmod_failure_test.iyi"
    test.write_text('''import std/file::{File}
path = Program.env("IYI_CHMOD_FAILURE_PATH") || raise "missing path"
group do |g|
  task = g.spawn do
    File.chmod(path, 0o600)
    0
  end
  assert task.value.is_a?(Panicked)
end
''', encoding="utf-8")
    # Exercise the real cache/guard/keep path on POSIX too: enable only the
    # Windows keep branch and replace its OS ACL call with a forced failure.
    autocert_path = overlay / "std" / "autocert.iyi"
    autocert = (repo / "src" / "std" / "autocert.iyi").read_text(encoding="utf-8")
    entry = '  def self.keep(dir : String) : Nil\n    {% if flag?(:win32) %}'
    helpers = '  {% if flag?(:win32) %}\n    # Effect wrappers record on return.'
    if autocert.count(entry) != 1 or autocert.count(helpers) != 1:
        raise AssertionError("autocert ACL fixture no longer applies")
    autocert = autocert.replace(entry, entry.replace('flag?(:win32)', 'flag?(:win32) || flag?(:linux) || flag?(:darwin)'))
    autocert = autocert.replace(helpers, helpers.replace('flag?(:win32)', 'flag?(:win32) || flag?(:linux) || flag?(:darwin)'))
    if os.environ.get("IYI_STALE_ACL_DROP_MARKER") == "1":
        marker = "      record_acl_attempt(dir)\n"
        if autocert.count(marker) != 1:
            raise AssertionError("autocert ACL marker mutation no longer applies")
        autocert = autocert.replace(marker, "")
    helper = '    @[Effect(:file_write, :chmod)]; private def self.keep_windows(dir : String) : Nil'
    if autocert.count(helper) != 1:
        raise AssertionError("autocert ACL helper fixture no longer applies")
    start = autocert.index(helper) + len(helper)
    end = autocert.index('\n    end\n  {% end %}\nend', start)
    autocert = autocert[:start] + '\n      raise "simulated ACL refusal"' + autocert[end:]
    autocert_path.write_text(autocert, encoding="utf-8")
    acl_target = project / "acl-directory"
    acl_target.mkdir()
    acl_test = project / "acl_failure_test.iyi"
    acl_test.write_text('''import std/autocert::{AutocertDirCache, AutocertError}
path = Program.env("IYI_CHMOD_FAILURE_PATH") || raise "missing path"
cache = AutocertDirCache.new(path)
assert cache.put("example", "data").is_a?(AutocertError)
''', encoding="utf-8")
    env = os.environ.copy()
    env["IYI_CACHE_DIR"] = str(work / "cache")
    base_path = env.get("IYI_PATH") or os.pathsep.join((str(repo / "src"), str(repo / "samples" / "iyi")))
    env["IYI_PATH"] = os.pathsep.join((str(overlay), base_path))
    env["IYI_LIBRARY_PATH"] = str(repo / "lib")

    def run(label, args, extra_env=None):
        print(f"== {label}", flush=True)
        result = subprocess.run([iyi, *args], cwd=project, env=extra_env or env,
                                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180)
        if result.returncode:
            raise RuntimeError(f"{label}: exit {result.returncode}\n{result.stdout}\n{result.stderr}")
        return result.stdout

    def probe(label, test_path, target_path):
        case_env = env.copy()
        case_env["IYI_CHMOD_FAILURE_PATH"] = str(target_path)
        executable = work / (f"{label}.exe" if os.name == "nt" else label)
        run(f"{label} observed build", ["build", "-Diyi_observe", "-o", str(executable), str(test_path)], case_env)
        trace_path = work / f"{label}.trace"
        observed_env = case_env.copy()
        observed_env.update({"TMPDIR": str(scratch), "TEMP": str(scratch), "TMP": str(scratch),
                             "IYI_OBSERVE": str(trace_path)})
        print(f"== {label} observed run", flush=True)
        observed = subprocess.run([str(executable)], cwd=project, env=observed_env,
                                  capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180)
        if observed.returncode:
            raise RuntimeError(f"{label}: exit {observed.returncode}\n{observed.stdout}\n{observed.stderr}")
        trace = trace_path.read_bytes()
        records = []
        position = 0
        while position < len(trace):
            if position + 4 > len(trace):
                raise AssertionError("truncated trace length")
            size, = struct.unpack_from("<I", trace, position)
            position += 4
            record = trace[position:position + size]
            if len(record) != size or size < 9:
                raise AssertionError("truncated trace record")
            records.append((record[0], record[9:]))
            position += size
        if not records or records[-1][0] != 0x7f or struct.unpack_from("<i", records[-1][1])[0] != 0:
            raise AssertionError(f"{label}: observed run did not finish with END(0)")
        writes = []
        for kind, body in records:
            if kind != 7:
                continue
            op = body[0]
            length, = struct.unpack_from("<I", body, 1)
            path = body[5:5 + length].decode("utf-8")
            offset = 5 + length
            target_length, = struct.unpack_from("<I", body, offset)
            offset += 4 + target_length
            writes.append((op, os.path.normcase(os.path.realpath(path)), body[offset]))
        expected = (8, os.path.normcase(os.path.realpath(target_path)), 0)
        first = json.loads(run(f"{label} recording run", ["test", "--cached", "--json", str(test_path)], case_env))
        second = json.loads(run(f"{label} repeat run", ["test", "--cached", "--json", str(test_path)], case_env))
        if expected not in writes or first["cached"] != 0 or second["cached"] != 0:
            raise AssertionError(f"{label}: writes={writes}, first={first}, repeat={second}")
        print(f"{label}: external chmod recorded with scheduler taint suppressed in the test observer; no receipt hit")
        print(f"recording reason: {first['tests'][0].get('reason')}; repeat reason: {second['tests'][0].get('reason')}")

    probe("chmod", test, target)
    probe("autocert-acl", acl_test, acl_target)
PY
