#!/usr/bin/env bash
# Exercises `std/json`: parse, Any, PullParser, Builder, to_json / from_json.
#
#     bash bench/std_json_exercise.sh
#
# Proves the exercise holds plain and --release, the compact corpus round-trips
# through python3's json, what the reader refuses is refused in the program,
# what the pull parser, the builder and from_json refuse by panic is refused
# in a small program each, and a copy that stops treating a repeated object
# key as a mistake is caught, in the parser and in the pull parser.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The gate runs the compiler the caller names; bin/iyi is a POSIX shell
# wrapper a Windows build cannot run.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on that path, so the
# patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# The negative proofs are patched by python, and a machine can answer
# `python3` with a store stub that prints a refusal instead of running, so
# the interpreter is resolved once and proven to run before it is trusted.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_json_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  grep -av '^[{["0-9tfn-]' "$WORK/$name.out" | grep -av '^  ' | sed 's/^/  /' || true
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    tail -8 "$WORK/$name.out"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/json exercise, plain build"
build_and_run "plain" json-plain
if ! grep -aq "ALL CHECKS PASSED" "$WORK/json-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every json section reported"
for phrase in "== parse corpus" "== to_json and to_pretty_json" "== pull parser walk" "== builder" "== equality and hash" "== to_json and from_json" "== what the reader refuses" "== differential corpus"; do
  if ! grep -aq "$phrase" "$WORK/json-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  parse, print, pull, builder, hash, from_json, refusals and the corpus all reported"

echo
echo "== compact corpus against python3 json"
grep -a '^oracle json' "$WORK/json-plain.out" | cut -f2- > "$WORK/compact.iyi.txt"
if [ "$(wc -l < "$WORK/compact.iyi.txt")" -lt 20 ]; then
  echo "  the corpus shrank ($(wc -l < "$WORK/compact.iyi.txt") compact lines)"
  status=1
elif [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the compact corpus was not read back as JSON"
else
  "$PY" - "$WORK/compact.iyi.txt" <<'PY'
import json, sys
n = 0
for i, line in enumerate(open(sys.argv[1]), 1):
    line = line.rstrip("\n")
    if not line:
        continue
    try:
        json.loads(line)
    except Exception as e:
        print(f"  line {i} is not JSON python3 accepts: {e}")
        print(f"    {line[:120]}")
        sys.exit(1)
    n += 1
print(f"  {n} compact documents are JSON python3 accepts")
PY
  if [ $? -ne 0 ]; then
    status=1
  fi
fi

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" json-release --release >/dev/null
if ! grep -aq "ALL CHECKS PASSED" "$WORK/json-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== what the pull parser, the builder and from_json refuse, by name"
refuses() { # refuses <label> <name> <phrase> <statements>
  local label="$1" name="$2" phrase="$3" statements="$4"
  printf 'module main\n\nimport std/json::{JSON, Any, PullParser, Builder}\n\n\n%s\n' \
    "$statements" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,8p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of refusing"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase'"
    tail -2 "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" \
    "$(grep -m1 -o "$phrase.*" "$WORK/$name.out")"
}
refuses "one past UInt64 max" u64_over "integer 18446744073709551616 out of UInt64 range" \
  'puts JSON.from_json("18446744073709551616", UInt64)'
refuses "a negative integer past Int64 into UInt64" u64_neg_big "integer -9223372036854775809 out of UInt64 range" \
  'puts JSON.from_json("-9223372036854775809", UInt64)'
refuses "a negative integer into UInt64" u64_neg "integer -1 out of UInt64 range" \
  'puts JSON.from_json("-1", UInt64)'
refuses "a fraction into UInt64" u64_frac "expected int, got Float at line 1, column 1" \
  'puts JSON.from_json("1.5", UInt64)'
refuses "an exponent into UInt64" u64_exp "expected int, got Float at line 1, column 1" \
  'puts JSON.from_json("1e3", UInt64)'
refuses "a repeated key in read_object" pull_dup "duplicate key 'a' at line 1, column 8" \
  'p = PullParser.new("{\"a\":1,\"a\":2}"); p.read_object { |k| p.skip }; puts p.kind'
refuses "a repeated key in on_key" onkey_dup "duplicate key 'a' at line 1, column 8" \
  'p = PullParser.new("{\"a\":1,\"a\":2}"); p.on_key("b") { p.skip }; puts p.kind'
refuses "a repeated key skipped over" skip_dup "duplicate key 'a' at line 1, column 10" \
  'p = PullParser.new("[{\"a\":{},\"a\":2}]"); p.skip; puts p.kind'
refuses "a repeated key into a Hash" hash_dup "duplicate key 'a' at line 1, column 8" \
  'puts JSON.from_json("{\"a\":1,\"a\":2}", Hash(String, Int32)).size'
refuses "to_s with an array still open" open_array "to_s with an array still open" \
  'b = Builder.new; b.start_array; b.number(1); puts b.to_s'
refuses "to_s with an object still open" open_object "to_s with an object still open" \
  'b = Builder.new; b.start_object; b.field("k"); puts b.to_s'
refuses "to_s with no value written" no_value "to_s with no value written" \
  'puts Builder.new.to_s'
refuses "a build that wrote nothing" build_empty "build wrote no value" \
  'puts JSON.build { |b| }'
refuses "a build that left an array open" build_open "to_s with an array still open" \
  'puts JSON.build { |b| b.start_array }'

echo
echo "== proving the checks can fail when a repeated key is accepted"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched_dup/std"
  "$PY" - <<PY
src = open("$REPO/src/std/json.iyi").read()
old = 'return fail("duplicate key \\'#{key}\\'")'
new = 'return fail("duplicate key \\'#{key}\\'") if false'
if old not in src:
    raise SystemExit("patch site missing")
open("$WORK/patched_dup/std/json.iyi", "w").write(src.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched_dup${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_json_exercise.iyi" >"$WORK/dup.out" 2>&1; then
    echo "  the exercise PASSED with duplicate keys accepted"
    status=1
  elif ! grep -aq "duplicate key" "$WORK/dup.out"; then
    echo "  failed, but not at the duplicate-key check:"
    grep -am1 panic "$WORK/dup.out" || sed -n '1,8p' "$WORK/dup.out"
    status=1
  else
    echo "  a repeated object key is caught"
  fi
fi

echo
echo "== proving the pull parser's own check is what refuses a repeated key"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched_pull/std"
  "$PY" - <<PY
src = open("$REPO/src/std/json.iyi").read()
old = "parse_error(\\"duplicate key '#{@string_value}'\\") if @kind == Kind::String && seen.has_key?(@string_value)"
new = "parse_error(\\"duplicate key '#{@string_value}'\\") if false"
if old not in src:
    raise SystemExit("patch site missing")
open("$WORK/patched_pull/std/json.iyi", "w").write(src.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  elif ! IYI_PATH="$WORK/patched_pull${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$WORK/pull_dup.iyi" >"$WORK/pull_dup.patched.out" 2>&1; then
    echo "  read_object still refused the repeated key with its check removed:"
    grep -m1 panic "$WORK/pull_dup.patched.out" || sed -n '1,4p' "$WORK/pull_dup.patched.out"
    status=1
  else
    echo "  with the check removed read_object yields the repeated key, so the check is what refuses it"
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/json exercise holds"
else
  echo "the std/json exercise did not hold"
fi
exit $status
