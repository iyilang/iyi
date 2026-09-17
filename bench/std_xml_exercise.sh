#!/usr/bin/env bash
# Exercises `std/xml`: parser, tree, serializer, references, refusals.
#
#     bash bench/std_xml_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_xml_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  grep -E '^== |^  |ALL CHECKS' "$WORK/$name.out" | sed 's/^/  /' || true
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    tail -8 "$WORK/$name.out"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/xml exercise, plain build"
build_and_run "plain" xml-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/xml-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every xml section reported"
for phrase in "== round trip" "== escaping" "== refusals" "== limits"; do
  if ! grep -q "$phrase" "$WORK/xml-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  round trip, escaping, refusals and limits all reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" xml-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/xml-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo "== what a node refuses when it is made or its text set"
refuses() { # refuses <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nimport std/xml\n\nusing std/xml::{Document, Node, NodeType}\n\nputs (%s).to_s\n' \
    "$expression" > "$WORK/$name.iyi"
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
refuses "a comment made with --" comment_dashes "'--' is not allowed inside a comment" \
  'Node.new_comment("a--b").to_xml'
refuses "a comment ending in -" comment_tail "a comment cannot end with '-'" \
  'Node.new_comment("a-").to_xml'
refuses "a comment given -- by text=" comment_set "'--' is not allowed inside a comment" \
  '(n = Node.new_comment("a"); n.text = "--"; n).to_xml'
refuses "a processing instruction made with ?>" pi_closer "'?>' is not allowed inside a processing instruction" \
  'Node.new_pi("p", "a?>b").to_xml'
refuses "a processing instruction given ?> by text=" pi_set "'?>' is not allowed inside a processing instruction" \
  '(n = Node.new_pi("p", "a"); n.text = "?>"; n).to_xml'
refuses "text= on a document" document_text "a document has no text of its own" \
  '(d = Document.new; d.text = "x"; d).to_xml'

echo
echo "== proving the checks can fail when the module is broken"
mutate() { # mutate <label> <old> <new> <phrase>
  local label="$1" old="$2" new="$3" phrase="$4"
  if [ -z "$PY" ]; then
    echo "  $label: skipped, no working python3 to make the broken copy with"
    return 0
  fi
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  OLD="$old" NEW="$new" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/xml.iyi").read_text()
old = os.environ["OLD"]
if old not in src:
    raise SystemExit("patch site missing: " + old)
Path("$WORK/patched/std/xml.iyi").write_text(src.replace(old, os.environ["NEW"], 1))
PY
  if [ $? -ne 0 ]; then
    echo "  $label: the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_xml_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  elif ! grep -q "$phrase" "$WORK/mut.out"; then
    echo "  $label: failed, but not at its own check:"
    grep -m1 panic "$WORK/mut.out" || sed -n '1,8p' "$WORK/mut.out"
    status=1
  else
    echo "  $label: caught"
  fi
}
mutate "a repeated attribute accepted" \
  '        fail_at(attr_line, attr_col, "attribute '"'"'#{attr_name}'"'"' given twice on <#{name}>")' \
  '        # duplicate attributes accepted' 'given twice'
mutate "one attribute through two prefixes accepted" \
  '        if !first.nil?' '        if false' 'given twice'
mutate "a name with two colons accepted" \
  '    return true if colons == 0' '    return true' '<x:b:c/>'
mutate "the xmlns prefix declared" \
  '        elsif ns_prefix == "xmlns"' '        elsif false' 'accepted .*xmlns:xmlns'
mutate "CDATA written whole" \
  '      serialize_cdata_body(buf)' '      buf << @content' 'splits the section'
mutate "text= dropped on an element" \
  '      add_child(Node.new_text(value))' '      nil' 'text= replaces'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/xml exercise holds"
else
  echo "the std/xml exercise did not hold"
fi
exit $status
