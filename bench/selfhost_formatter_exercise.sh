#!/usr/bin/env bash
# Compare the port with the hosted formatter on inputs that select its CI job.
#
# A short corpus also checks idempotency and the standalone path and stdin
# driver. The wider comparison pins matches and divergent output for .iyi
# files and the .fixture input selected by the self-host CI path rule.
# Mutation proofs verify that the existing parity checks are load-bearing.
#
#   bash bench/selfhost_formatter_exercise.sh
set -u
status=0
diverged=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if ! command -v perl >/dev/null 2>&1; then
  echo "  FAILED: perl is required for the mutation proofs" >&2
  exit 1
fi
IYI="$REPO/bin/iyi"
. "$REPO/bench/lib/mutation.sh" || exit 1
FMT="$REPO/src/compiler/tools/formatter.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO_NATIVE="$(native_path "$REPO")" || exit 1
WORK_NATIVE="$(native_path "$WORK")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
cd "$REPO" || exit 1
# The mutation helper retains only a log tail; preserve full invalid-build logs.
exec 3>&1

# This short corpus carries the existing idempotency, standalone-driver, and
# mutation checks. The planner-selected comparison below is measured separately.
CORPUS=(
  "bench/fixtures/formatter_branch_comment.iyi"
  "bench/fixtures/formatter_tuple_type.iyi"
  "bench/fixtures/formatter_macro_if.iyi"
  "bench/fixtures/formatter_macro_if_def.iyi"
  "bench/fixtures/formatter_macro_if_branches.fixture"
  "bench/fixtures/formatter_macro_if_nested.iyi"
  "bench/fixtures/formatter_macro_expression.iyi"
  "samples/iyi/calc.iyi"
  "samples/iyi/collections.iyi"
  "samples/iyi/derive.iyi"
  "samples/iyi/files.iyi"
  "samples/iyi/format.iyi"
  "samples/iyi/formatting.iyi"
  "samples/iyi/generics.iyi"
  "samples/iyi/hello.iyi"
  "samples/iyi/immutable.iyi"
  "samples/iyi/init_order.iyi"
  "samples/iyi/io.iyi"
  "samples/iyi/modules.iyi"
  "samples/iyi/sessions.iyi"
  "samples/iyi/socket.iyi"
  "samples/iyi/std_iterator.iyi"
  "samples/iyi/std_text.iyi"
  "samples/iyi/std_time.iyi"
  "samples/iyi/webapp.iyi"
  "src/std/bool.iyi"
  "src/std/deque.iyi"
  "src/std/list.iyi"
  "src/std/steppable.iyi"
  "src/std/string_scanner.iyi"
  "src/std/enum.iyi"
  "src/std/uuid.iyi"
)

echo "== 1. Building the selfhost formatter exercise driver"
if ! "$IYI" build -o "$WORK_NATIVE/exercise$EXE" "$REPO_NATIVE/bench/selfhost_formatter_exercise.iyi"; then
  echo "FAILED: could not build bench/selfhost_formatter_exercise.iyi"
  exit 1
fi
echo "  built bench/selfhost_formatter_exercise.iyi successfully"

echo
echo "== 2. Parity comparison against the hosted formatter and idempotency check"

compare_corpus() {
  local driver="$1"
  local matched=0
  local total_bytes=0
  local total_files=${#CORPUS[@]}
  local rel src native_src native_pass1 bytes

  if ! native_pass1="$(native_path "$WORK/port_pass1.out")"; then
    echo "  FAILED: cannot resolve the native pass-1 path"
    return 2
  fi
  for rel in "${CORPUS[@]}"; do
    src="$REPO/$rel"
    if [ ! -f "$src" ]; then
      echo "  MISSING: $rel does not exist in repository"
      return 2
    fi
    if ! native_src="$(native_path "$src")"; then
      echo "  FAILED: cannot resolve the native path for $rel"
      return 2
    fi

    bytes=$(wc -c < "$src" | tr -d ' ')

    if ! "$IYI" tool format - < "$src" > "$WORK/hosted.out" 2>"$WORK/hosted.err"; then
      echo "  FAILED: hosted formatter failed on $rel"
      cat "$WORK/hosted.err"
      return 2
    fi

    if ! "$driver" "$native_src" > "$WORK/port_pass1.out" 2>"$WORK/port.err"; then
      echo "  FAILED: selfhost port crashed on $rel"
      cat "$WORK/port.err"
      return 1
    fi
    cmp -s "$WORK/hosted.out" "$WORK/port_pass1.out"
    case $? in
      0) ;;
      1) echo "  DIVERGED: selfhost output differs from hosted formatter on $rel"; return 1 ;;
      *) echo "  FAILED: cannot compare formatter output on $rel"; return 2 ;;
    esac

    if ! "$driver" "$native_pass1" > "$WORK/port_pass2.out" 2>"$WORK/port.err"; then
      echo "  FAILED: selfhost port crashed on the second pass of $rel"
      cat "$WORK/port.err"
      return 1
    fi
    cmp -s "$WORK/port_pass1.out" "$WORK/port_pass2.out"
    case $? in
      0) ;;
      1) echo "  NOT IDEMPOTENT: second pass changed output on $rel"; return 1 ;;
      *) echo "  FAILED: cannot compare formatter passes on $rel"; return 2 ;;
    esac

    matched=$((matched + 1))
    total_bytes=$((total_bytes + bytes))
  done

  echo "  Parity summary: $matched/$total_files files match byte-for-byte ($total_bytes total bytes)"
  echo "  Idempotency summary: $matched/$total_files files idempotent"
  return 0
}

if ! compare_corpus "$WORK/exercise$EXE"; then
  status=1
fi

echo
# Newly identical files are notices, and become protected once added to the
# floor. The divergent-output ceiling must continue to list every difference.
echo "== 3. Planner-selected parity floor and divergent-output ceiling"
if [ -z "$PY" ]; then
  echo "  FAILED: Python is required for the planner-selected comparison"
  status=1
else
  cat > "$WORK/whole_tree.py" <<'PY'
import collections
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys


def read_pins(path):
    rows = [line for line in Path(path).read_text(encoding="utf-8").splitlines()
            if line and not line.startswith("#")]
    if rows != sorted(set(rows)):
        raise ValueError(f"{path}: paths must be unique and sorted")
    return set(rows)


def check_pins(results_path, floor_path, ceiling_path):
    rows = json.loads(Path(results_path).read_text(encoding="utf-8"))
    actual_identical = {path for path, verdict, _ in rows if verdict == "identical"}
    actual_differs = {path for path, verdict, _ in rows if verdict == "differs"}
    floor = read_pins(floor_path)
    ceiling = read_pins(ceiling_path)
    issues = [
        ("BELOW FLOOR", floor - actual_identical),
        ("NOW DIFFERS", actual_differs - ceiling),
        ("LOWER THE CEILING", ceiling - actual_differs),
    ]
    for path in sorted(actual_identical - floor):
        print(f"  could raise the floor: {path}")
    failed = False
    for label, paths in issues:
        for path in sorted(paths):
            print(f"  {label}: {path}")
            failed = True
    return 1 if failed else 0


def load_planner(root):
    spec = importlib.util.spec_from_file_location("formatter_ci_plan", root / "scripts/ci_plan.py")
    planner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(planner)
    return planner


def check_plan(root, rel):
    root = Path(root)
    if not (root / rel).is_file():
        print(f"  planner probe file is missing: {rel}")
        return 2
    planner = load_planner(root)
    env = os.environ.copy()
    env.pop("GITHUB_OUTPUT", None)
    result = subprocess.run([sys.executable, str(root / "scripts/ci_plan.py"),
                             "--event", "pull_request", "--files", rel],
                            cwd=root, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    if result.returncode:
        print(f"  planner failed for {rel} (exit {result.returncode}):\n{result.stdout}")
        return 2
    selected = {line.strip() for line in result.stdout.splitlines() if line.startswith("  ")}
    missing = sorted(set(planner.SELFHOST) - selected)
    if missing:
        print(f"  planner does not select self-host jobs for {rel}: {', '.join(missing)}")
        return 1
    print(f"  planner selects self-host jobs for {rel}")
    return 0


if sys.argv[1] == "plan-check":
    sys.exit(check_plan(*sys.argv[2:]))


if sys.argv[1] == "check":
    sys.exit(check_pins(*sys.argv[2:]))

root, driver, hosted, work = map(Path, sys.argv[2:6])
floor_path, ceiling_path = map(Path, sys.argv[6:8])
planner = load_planner(root)
probes = (
    "src/compiler/syntax/parser.iyi",
    "bench/selfhost_formatter_exercise.sh",
    "bench/native_obj_exercise.sh",
    "bench/macro_sites.py",
    "bench/fixtures/formatter_macro_if.iyi",
)
for rel in probes:
    result = subprocess.run([sys.executable, __file__, "plan-check", str(root), rel],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print(result.stdout, end="")
    if result.returncode:
        print(f"  FAILED: planner scope probe for {rel} (exit {result.returncode})")
        sys.exit(1)
outside = "README.md"
if planner.is_selfhost(outside):
    print(f"  FAILED: planner proof input is no longer outside the self-host path rule: {outside}")
    sys.exit(1)
result = subprocess.run([sys.executable, __file__, "plan-check", str(root), outside],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
if result.returncode != 1 or "planner does not select self-host jobs" not in result.stdout:
    print(f"  FAILED: planner check did not reject {outside} (exit {result.returncode})")
    print(result.stdout, end="")
    sys.exit(1)
print(f"  out-of-scope planner probe: caught ({outside}, exit 1)")
timeout = 10
excluded_root_dirs = {".git", ".build", ".iyi", ".direnv", ".junit",
                      "coverage", "docs", "man", "tmp"}
sources = []
for directory, dirs, names in os.walk(root):
    relative = Path(directory).relative_to(root)
    if relative == Path("."):
        dirs[:] = [name for name in dirs if name not in excluded_root_dirs]
    dirs[:] = [name for name in dirs if name not in {"__pycache__", "node_modules"}]
    if relative.as_posix() == "samples/crystal/kemal":
        dirs[:] = [name for name in dirs if name not in {"lib", "mods"}]
        names = [name for name in names if name != "app_artifact.iyi"]
    sources.extend((relative / name).as_posix() for name in names if name.endswith(".iyi"))
sources.append("bench/fixtures/formatter_macro_if_branches.fixture")
sources = sorted(rel for rel in sources if planner.is_selfhost(rel))


def first_line(result):
    lines = (result.stderr or result.stdout).decode("utf-8", errors="replace").splitlines()
    return lines[0] if lines else f"exit {result.returncode}"


def measure(rel):
    source = root / rel
    try:
        reference = subprocess.run([str(hosted), "tool", "format", "-"], input=source.read_bytes(),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        return rel, "host_timeout", f"hosted formatter exceeded {timeout}s"
    if reference.returncode:
        return rel, "host_refused", first_line(reference)
    try:
        port = subprocess.run([str(driver), str(source)], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        return rel, "port_timeout", f"port exceeded {timeout}s"
    if port.returncode:
        return rel, "port_refused", first_line(port)
    return rel, "identical" if reference.stdout == port.stdout else "differs", ""


with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    rows = list(pool.map(measure, sources))
results = work / "whole_tree_results.json"
results.write_text(json.dumps(rows, ensure_ascii=True), encoding="utf-8")
counts = collections.Counter(verdict for _, verdict, _ in rows)
print(f"  identical {counts['identical']} of {len(rows)}")
for verdict, label in (("differs", "differs"), ("port_refused", "port refused"),
                       ("port_timeout", "port timed out"), ("host_refused", "hosted refused"),
                       ("host_timeout", "hosted timed out")):
    print(f"  {label}: {counts[verdict]}")
for rel, verdict, message in rows:
    if verdict in {"port_refused", "port_timeout", "host_refused", "host_timeout"}:
        print(f"  {verdict}: {rel}: {message}")


def run_check(floor, ceiling):
    return subprocess.run([sys.executable, __file__, "check", str(results),
                           str(floor), str(ceiling)], stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True)


baseline = run_check(floor_path, ceiling_path)
print(baseline.stdout, end="")
if baseline.returncode not in (0, 1):
    print(f"  FAILED: pin check could not run (exit {baseline.returncode})")
    sys.exit(1)
failed = baseline.returncode != 0
floor = read_pins(floor_path)
ceiling = read_pins(ceiling_path)
identical = sorted(path for path, verdict, _ in rows if verdict == "identical")
differs = sorted(path for path, verdict, _ in rows if verdict == "differs")
if not identical or not differs:
    print("  FAILED: need a matching file and a differing file for the pin proofs")
    sys.exit(1)

proofs_run = 0


def proof(name, mutant_floor, mutant_ceiling, expected, target):
    global failed, proofs_run
    proofs_run += 1
    floor_copy = work / "proof.floor"
    ceiling_copy = work / "proof.ceiling"
    floor_copy.write_text("".join(path + "\n" for path in sorted(mutant_floor)), encoding="utf-8")
    ceiling_copy.write_text("".join(path + "\n" for path in sorted(mutant_ceiling)), encoding="utf-8")
    result = run_check(floor_copy, ceiling_copy)
    if result.returncode == 1 and f"{expected}: {target}" in result.stdout:
        print(f"  {name}: caught ({expected}: {target}, exit 1)")
    else:
        print(f"  {name}: NOT CAUGHT (exit {result.returncode})")
        print(result.stdout, end="")
        failed = True


pinned_matches = sorted(floor.intersection(identical))
if pinned_matches:
    target = pinned_matches[0]
    notice_floor = work / "notice.floor"
    notice_floor.write_text("".join(path + "\n" for path in sorted(floor - {target})), encoding="utf-8")
    result = run_check(notice_floor, ceiling_path)
    if result.returncode == 0 and f"could raise the floor: {target}" in result.stdout:
        print(f"  unlisted match notice: reported without failure ({target}, exit 0)")
    else:
        print(f"  unlisted match notice: NOT CAUGHT (exit {result.returncode})")
        print(result.stdout, end="")
        failed = True
else:
    print("  FAILED: need a pinned matching file for the notice proof")
    failed = True
proof("differing file added to floor", floor | {differs[0]}, ceiling, "BELOW FLOOR", differs[0])
proof("ceiling row removed", floor, ceiling - {differs[0]}, "NOW DIFFERS", differs[0])
proof("matching file added to ceiling", floor, ceiling | {identical[0]}, "LOWER THE CEILING", identical[0])
print(f"  {proofs_run} blocking pin proofs run")
sys.exit(1 if failed else 0)
PY
  if ! "$PY" "$(native_path "$WORK/whole_tree.py")" measure "$REPO_NATIVE" \
    "$WORK_NATIVE/exercise$EXE" "$(native_path "$REPO/.build/iyi$EXE")" "$WORK_NATIVE" \
    "$(native_path "$REPO/bench/selfhost_formatter_parity.floor")" \
    "$(native_path "$REPO/bench/selfhost_formatter_differs.ceiling")"; then
    status=1
  fi
fi

echo
echo "== 4. Standalone iyi-format path and stdin comparison"
format_matched=0
format_total=${#CORPUS[@]}
if ! "$IYI" build -o "$WORK_NATIVE/iyi-format$EXE" "$REPO_NATIVE/src/compiler/tools/format.iyi" > "$WORK/format-build.log" 2>&1; then
  echo "  FAILED to build standalone iyi-format:"
  cat "$WORK/format-build.log"
  status=1
elif [ ! -x "$WORK/iyi-format$EXE" ]; then
  echo "  FAILED: standalone iyi-format executable is missing"
  cat "$WORK/format-build.log"
  status=1
else
  for rel in "${CORPUS[@]}"; do
    src="$REPO/$rel"
    if [ ! -f "$src" ]; then
      echo "  MISSING: $rel does not exist in repository"
      status=1
      continue
    fi
    if ! native_src="$(native_path "$src")"; then
      echo "  FAILED: cannot resolve the native path for $rel"
      status=1
      continue
    fi
    if ! "$IYI" tool format - < "$src" > "$WORK/hosted.out" 2>"$WORK/hosted.err"; then
      echo "  FAILED: hosted formatter failed on $rel"
      cat "$WORK/hosted.err"
      status=1
      continue
    fi

    format_file_ok=1
    if ! "$WORK/iyi-format$EXE" "$native_src" > "$WORK/format-path.out" 2>"$WORK/format-path.err"; then
      echo "  FAILED: iyi-format path input on $rel"
      cat "$WORK/format-path.err"
      format_file_ok=0
    elif ! cmp -s "$WORK/hosted.out" "$WORK/format-path.out"; then
      echo "  DIVERGED: iyi-format path input on $rel"
      format_file_ok=0
    fi
    if ! "$WORK/iyi-format$EXE" - < "$src" > "$WORK/format-stdin.out" 2>"$WORK/format-stdin.err"; then
      echo "  FAILED: iyi-format stdin input on $rel"
      cat "$WORK/format-stdin.err"
      format_file_ok=0
    elif ! cmp -s "$WORK/hosted.out" "$WORK/format-stdin.out"; then
      echo "  DIVERGED: iyi-format stdin input on $rel"
      format_file_ok=0
    fi
    if [ "$format_file_ok" -eq 1 ]; then
      format_matched=$((format_matched + 1))
    else
      status=1
    fi
  done
fi
echo "  iyi-format: $format_matched/$format_total files identical to the hosted formatter, through a path and through stdin"

echo
echo "== 5. Mutation proofs: each one must make the comparison above fail"

# Each check rebuilds the formatter with the mutation applied and compares it
# with the hosted formatter. A failed build or oracle is an invalid mutant.
check_formatter_parity() {
  local compare_rc
  rm -f "$WORK/mut-exercise$EXE"
  if ! "$IYI" build -o "$WORK_NATIVE/mut-exercise$EXE" "$REPO_NATIVE/bench/selfhost_formatter_exercise.iyi" > "$WORK/mut-build.log" 2>&1; then
    echo "INVALID MUTANT: formatter exercise failed to build" >&3
    cat "$WORK/mut-build.log" >&3
    echo "INVALID MUTANT: formatter exercise failed to build"
    return 0
  fi
  if [ ! -x "$WORK/mut-exercise$EXE" ]; then
    echo "INVALID MUTANT: formatter exercise executable is missing" >&3
    cat "$WORK/mut-build.log" >&3
    echo "INVALID MUTANT: formatter exercise executable is missing"
    return 0
  fi
  if compare_corpus "$WORK/mut-exercise$EXE" > "$WORK/mut-compare.log" 2>&1; then
    return 0
  else
    compare_rc=$?
  fi
  if [ "$compare_rc" -eq 2 ]; then
    echo "INVALID MUTANT: formatter comparison could not run" >&3
    cat "$WORK/mut-compare.log" >&3
    echo "INVALID MUTANT: formatter comparison could not run"
    return 0
  fi
  return 1
}
# Check a particular reduced input, not whichever corpus file fails first.
# Exit 1 means this fixture detected the mutant; exit 2 means the check could
# not run. The adapter below makes an invalid check fail the proof because the
# shared mutation helper treats any nonzero status as "caught".
check_formatter_fixture() {
  local rel="$1" src="$REPO/$1" native_src compare_rc=0 driver_rc=0
  if [ ! -f "$src" ] || ! native_src="$(native_path "$src")"; then
    echo "INVALID MUTANT: fixture unavailable: $rel" >&3
    return 2
  fi
  rm -f "$WORK/mut-exercise$EXE"
  if ! "$IYI" build -o "$WORK_NATIVE/mut-exercise$EXE" "$REPO_NATIVE/bench/selfhost_formatter_exercise.iyi" > "$WORK/mut-build.log" 2>&1; then
    echo "INVALID MUTANT: formatter exercise failed to build for $rel" >&3
    cat "$WORK/mut-build.log" >&3
    return 2
  fi
  if [ ! -x "$WORK/mut-exercise$EXE" ]; then
    echo "INVALID MUTANT: formatter exercise executable is missing for $rel" >&3
    return 2
  fi
  if ! "$IYI" tool format - < "$src" > "$WORK/hosted.out" 2>"$WORK/hosted.err"; then
    echo "INVALID MUTANT: hosted formatter failed on $rel" >&3
    cat "$WORK/hosted.err" >&3
    return 2
  fi
  "$WORK/mut-exercise$EXE" "$native_src" > "$WORK/port_pass1.out" 2>"$WORK/port.err" || driver_rc=$?
  if [ "$driver_rc" -ne 0 ]; then
    case "$driver_rc" in
      126|127|137|143)
        echo "INVALID MUTANT: formatter could not run on $rel (exit $driver_rc)" >&3
        return 2 ;;
      *)
        echo "  DETECTED: $rel: mutated formatter failed (exit $driver_rc)" >&3
        return 1 ;;
    esac
  fi
  cmp -s "$WORK/hosted.out" "$WORK/port_pass1.out" || compare_rc=$?
  case "$compare_rc" in
    0) return 0 ;;
    1) echo "  DETECTED: $rel: mutated output differs from hosted formatter" >&3; return 1 ;;
    *) echo "INVALID MUTANT: cannot compare output on $rel" >&3; return 2 ;;
  esac
}

check_fixture_mutation() {
  local check_rc=0
  check_formatter_fixture "$1" || check_rc=$?
  if [ "$check_rc" -eq 2 ]; then
    return 0
  fi
  return "$check_rc"
}

run_fixture_proof() {
  prove_mutation "$1" "$FMT" "$2" "$3" -- check_fixture_mutation "$4" || status=1
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
}


MUTATIONS_RUN=0
run_proof() {
  prove_mutation "$1" "$FMT" "$2" "$3" -- check_formatter_parity || status=1
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
}

run_proof "synthetic ivar assignment removal in def body bypassed" \
  "body = remove_to_skip(node.body, to_skip)" \
  "body = node.body"

run_proof "instance variable argument skipping disabled in Arg visitor" \
  "@last_arg_is_skip = at_skip?" \
  "@last_arg_is_skip = false"

run_proof "block argument bar leading space omitted in format_block" \
  "write_token(\" \", TokenKind::OP_BAR)" \
  "write_token(TokenKind::OP_BAR)"

run_proof "do block body formatting bypasses nested indentation and end" \
  "format_nested_with_end(block.body)" \
  "accept(block.body)"

run_proof "blank line preservation in consume_newlines disabled" \
  "if raw_newlines > 1 && !next_comes_end" \
  "if false && raw_newlines > 1"

run_proof "empty array literal bracket handling bypassed in ArrayLiteral visitor" \
  "if @token.type == TokenKind::OP_LSQUARE_RSQUARE" \
  "if false && @token.type == TokenKind::OP_LSQUARE_RSQUARE"

run_proof "method def receiver formatting bypassed in Def visitor" \
  "if receiver = node.receiver" \
  "if false && (receiver = node.receiver)"

run_proof "proc notation arrow omitted in ProcNotation visitor" \
  "write_token(TokenKind::OP_MINUS_GT)" \
  "# write_token(TokenKind::OP_MINUS_GT)"

run_fixture_proof "tuple type syntax branch bypassed" \
  'if name.names[0] == "Tuple"' \
  'if false && name.names[0] == "Tuple"' \
  "bench/fixtures/formatter_tuple_type.iyi"

run_fixture_proof "named tuple type syntax branch bypassed" \
  'elsif name.names[0] == "NamedTuple"' \
  'elsif false && name.names[0] == "NamedTuple"' \
  "bench/fixtures/formatter_tuple_type.iyi"

run_fixture_proof "empty branch comment indentation bypassed" \
  'skip_space_or_newline(@indent + 2, last: true)' \
  'skip_space_or_newline(last: true)' \
  "bench/fixtures/formatter_branch_comment.iyi"

run_fixture_proof "if condition comment indentation bypassed" \
  '    skip_space(@indent + 2)
    format_nested(a_then)' \
  '    skip_space
    format_nested(a_then)' \
  "bench/fixtures/formatter_branch_comment.iyi"

run_fixture_proof "else header comment indentation bypassed" \
  '      skip_space(@indent + 2)
      format_nested(a_else)' \
  '      skip_space
      format_nested(a_else)' \
  "bench/fixtures/formatter_branch_comment.iyi"

run_fixture_proof "macro-if visitor bypassed" \
  "def visit(node : MacroIf) : Bool" \
  "def visit(node : MacroIf) : Bool
    return true" \
  "bench/fixtures/formatter_macro_if.iyi"

run_fixture_proof "macro-if literal body formatting bypassed" \
  'if @inside_macro == 0 && value && value.includes?("\n")' \
  'if false && value && value.includes?("\n")' \
  "bench/fixtures/formatter_macro_if_branches.fixture"

run_fixture_proof "macro-unless branch reversal bypassed" \
  "a_then = node.else" \
  "a_then = node.then" \
  "bench/fixtures/formatter_macro_if_branches.fixture"

run_fixture_proof "nested macro expression opening token mishandled" \
  "check(@inside_macro == 0 ? TokenKind::OP_LCURLY_LCURLY : TokenKind::MACRO_EXPRESSION_START)" \
  "check(TokenKind::OP_LCURLY_LCURLY)" \
  "bench/fixtures/formatter_macro_if_nested.iyi"

run_fixture_proof "macro expression opening spacing forced" \
  'write(" ") if has_space || !node.output' \
  'write(" ")' \
  "bench/fixtures/formatter_macro_expression.iyi"
echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST FORMATTER CHECKS PASSED"
else
  echo "== SELFHOST FORMATTER CHECKS FAILED"
fi
exit $status
