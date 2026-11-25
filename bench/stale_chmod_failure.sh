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
# The overlay's prelude reaches the runtime by a relative path, and a relative
# path does not exist between two drives (the Windows runner's temp is on C: and
# the checkout on D:). Put the work directory on the checkout's drive then.
temp_parent = None
if os.path.splitdrive(str(repo))[0].lower() != os.path.splitdrive(tempfile.gettempdir())[0].lower():
    temp_parent = str(repo.parent)
with tempfile.TemporaryDirectory(prefix="iyi-stale-chmod-failure-", dir=temp_parent) as temporary:
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
failure = cache.put("example", "data")
if failure.is_a?(AutocertError)
  assert failure.message.includes?("simulated ACL refusal")
else
  raise "ACL test expected the simulated refusal"
end
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

    def diagnose_chmod_stack(case_env, observed_env, executable):
        # Run the same compiled program without observation, then compile the
        # same program with a larger task stack. Neither replaces the failed
        # acceptance run; both help identify where the overflow occurs.
        unobserved_env = observed_env.copy()
        unobserved_env.pop("IYI_OBSERVE", None)
        unobserved = subprocess.run([str(executable)], cwd=project, env=unobserved_env,
                                    capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180)
        source = test.read_text(encoding="utf-8")
        anchor = "group do |g|"
        if source.count(anchor) != 1:
            raise AssertionError("chmod stack diagnostic fixture no longer applies")
        larger_source = project / "chmod_large_stack.iyi"
        larger_source.write_text(source.replace(anchor, "IyiFiber.stack_bytes = 1048576_u64\n" + anchor), encoding="utf-8")
        larger_exe = work / "chmod-large-stack.exe"
        run("chmod larger-stack diagnostic build", ["build", "-Diyi_observe", "-o", str(larger_exe), str(larger_source)], case_env)
        larger_env = observed_env.copy()
        larger_env["IYI_OBSERVE"] = str(work / "chmod-large-stack.trace")
        larger = subprocess.run([str(larger_exe)], cwd=project, env=larger_env,
                                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180)
        return (f"unobserved exit {unobserved.returncode}\n{unobserved.stdout}\n{unobserved.stderr}"
                f"\nlarger-stack observed exit {larger.returncode}\n{larger.stdout}\n{larger.stderr}")

    def diagnose_chmod_fault(case_env, observed_env):
        # Preserve the ordinary observer and file implementations. Only the
        # fault handler is labelled, so a false guard-page classification can
        # be distinguished from actual Windows stack exhaustion.
        original_prelude = prelude.read_text(encoding="utf-8")
        diagnostic = original_prelude
        def marker(label, indent):
            return (f'{indent}message = "CHMOD_STACK_FAULT {label}\\n"\n'
                    f'{indent}LibC.WriteFile(handle, message.to_unsafe.as(Void*), message.bytesize, pointerof(written), nil)\n')
        overflow = "    if code == IYI_WIN_STACK_OVERFLOW\n"
        guard = "        if IyiScheduler.fiber_guard_hit?(faulting)\n"
        if diagnostic.count(overflow) != 1 or diagnostic.count(guard) != 2:
            raise AssertionError("Windows fault handler diagnostic anchors changed")
        diagnostic = diagnostic.replace(overflow, overflow + marker("overflow", "      "), 1)
        diagnostic = diagnostic.replace(guard, guard + marker("guard", "          "), 1)
        position = diagnostic.index(guard, diagnostic.index(guard) + len(guard))
        diagnostic = diagnostic[:position] + diagnostic[position:].replace(
            guard, guard + marker("access", "          "), 1)
        diagnostic_exe = work / "chmod-fault-diagnostic.exe"
        try:
            prelude.write_text(diagnostic, encoding="utf-8")
            run("chmod fault diagnostic build", ["build", "-Diyi_observe", "-o", str(diagnostic_exe), str(test)], case_env)
            fault_env = observed_env.copy()
            fault_env["IYI_OBSERVE"] = str(work / "chmod-fault-diagnostic.trace")
            result = subprocess.run([str(diagnostic_exe)], cwd=project, env=fault_env,
                                    capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180)
            return f"fault diagnostic exit {result.returncode}\n{result.stdout}\n{result.stderr}"
        finally:
            prelude.write_text(original_prelude, encoding="utf-8")

    def diagnose_chmod(case_env, observed_env):
        # Only a failed Windows run takes this path. The normal proof stays
        # uninstrumented; the second build names the recursive boundary.
        original_observer = observer.read_text(encoding="utf-8")
        diagnostic = original_observer
        entries = (
            ('pub def __iyi_observe_file_write(op : UInt8 | ::Symbol | String, path : String, target : String? = nil) : Nil',
             'observe_file_write'),
            ('pub def file_write(op : UInt8 | ::Symbol | String, path : String, target : String? = nil) : Nil',
             'file_write'),
            ('pub def safe_real_path(path : String) : String', 'safe_real_path'),
            ('private def normalize_path(path : String) : String', 'normalize_path'),
            ('private def windows_real_path(path : String) : {String?, Int32}', 'windows_real_path'),
            ('private def windows_identity(path : String) : { {UInt64, UInt64, UInt64}?, Int32 }', 'windows_identity'),
            ('private def is_under_scratch?(real : String) : ::Bool', 'is_under_scratch'),
        )
        for anchor, label in entries:
            if diagnostic.count(anchor) != 1:
                raise AssertionError(f"chmod diagnostic anchor changed: {label}")
            diagnostic = diagnostic.replace(anchor, anchor + f'\n  __iyi_chmod_diag("CHMOD_DIAG {label}\\n")', 1)
        # Bypass the observed stdio wrappers: using puts here re-enters the
        # observer and can crash before it names the original failure.
        helper = '''@[Effect(:observation_channel)]
pub def __iyi_chmod_diag(message : String) : Nil
  {% if flag?(:win32) %}
    written = 0_i32
    LibC.WriteFile(LibC.GetStdHandle(-12), message.to_unsafe.as(Void*), message.bytesize,
      pointerof(written), Pointer(Void).new(0_u64))
  {% elsif flag?(:darwin) %}
    LibC.write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
  {% end %}
end

'''
        anchor = 'pub def file_write(op : UInt8 | ::Symbol | String, path : String, target : String? = nil) : Nil'
        diagnostic = diagnostic.replace(anchor, helper + anchor, 1)
        observer.write_text(diagnostic, encoding="utf-8")
        diagnostic_file = overlay / "std" / "file.iyi"
        file_source = (repo / "src" / "std" / "file.iyi").read_text(encoding="utf-8")
        for anchor, marker in (
            ('    record_chmod_attempt(path)', 'after_attempt'),
            ('    chmod_after_attempt(path, mode)', 'after_chmod'),
            ('      attrs = __iyi_path_attributes(sys_path(p))', 'after_attributes'),
        ):
            if file_source.count(anchor) != 1:
                raise AssertionError(f"chmod diagnostic file anchor changed: {marker}")
            indent = anchor[:len(anchor) - len(anchor.lstrip())]
            file_source = file_source.replace(anchor, f'{anchor}\n{indent}Std::Observe.__iyi_chmod_diag("CHMOD_DIAG {marker}\\n")', 1)
        diagnostic_file.write_text(file_source, encoding="utf-8")
        diagnostic_test = project / "chmod_diagnostic.iyi"
        diagnostic_source = test.read_text(encoding="utf-8")
        for anchor, marker in (
            ('group do |g|', 'before_group'),
            ('  task = g.spawn do', 'before_spawn'),
            ('    File.chmod(path, 0o600)', 'before_chmod'),
            ('  assert task.value.is_a?(Panicked)', 'before_await'),
        ):
            if diagnostic_source.count(anchor) != 1:
                raise AssertionError(f"chmod diagnostic fixture changed: {marker}")
            indent = anchor[:len(anchor) - len(anchor.lstrip())]
            diagnostic_source = diagnostic_source.replace(anchor, f'{indent}Std::Observe.__iyi_chmod_diag("CHMOD_DIAG {marker}\\n")\n{anchor}', 1)
        diagnostic_test.write_text(diagnostic_source, encoding="utf-8")
        diagnostic_exe = work / "chmod-diagnostic.exe"
        run("chmod diagnostic build", ["build", "-Diyi_observe", "-o", str(diagnostic_exe), str(diagnostic_test)], case_env)
        result = subprocess.run([str(diagnostic_exe)], cwd=project, env=observed_env,
                                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180)
        def clipped(output):
            if len(output) > 16000:
                return output[:8000] + "\n... diagnostic output omitted ...\n" + output[-8000:]
            return output
        return f"diagnostic exit {result.returncode}\n{clipped(result.stdout)}\n{clipped(result.stderr)}"

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
            detail = ""
            if label == "chmod" and os.name == "nt":
                for name, diagnosis in (
                    ("stack", lambda: diagnose_chmod_stack(case_env, observed_env, executable)),
                    ("fault", lambda: diagnose_chmod_fault(case_env, observed_env)),
                    ("observer", lambda: diagnose_chmod(case_env, observed_env)),
                ):
                    try:
                        detail += "\n" + diagnosis()
                    except Exception as exc:
                        detail += f"\nchmod {name} diagnostic failed: {exc}"
            raise RuntimeError(f"{label}: exit {observed.returncode}\n{observed.stdout}\n{observed.stderr}{detail}")
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
