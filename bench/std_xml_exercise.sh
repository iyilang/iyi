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
  printf 'module main\n\nimport std/xml::{Document, Node, NodeType}\n\n\nputs (%s).to_s\n' \
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
# A name, a comment and a processing instruction have no character
# references, so in a document declared US-ASCII one holding a character
# past U+007F is refused at to_xml; it was written as UTF-8, which the
# module's own parser then refused as "not US-ASCII".
refuses "a comment past ASCII in a US-ASCII document" ascii_comment "U+00E9 cannot be written in a comment of a document declared US-ASCII" \
  '(d = Document.new(encoding: "US-ASCII"); d.add_child(Node.new_comment("caf\u{E9}")); d).to_xml'
refuses "a processing instruction past ASCII in a US-ASCII document" ascii_pi "U+00E9 cannot be written in a processing instruction of a document declared US-ASCII" \
  '(d = Document.new(encoding: "US-ASCII"); d.add_child(Node.new_pi("p", "caf\u{E9}")); d).to_xml'
refuses "an element name past ASCII in a US-ASCII document" ascii_element "cannot be written in a document declared US-ASCII" \
  '(d = Document.new(encoding: "US-ASCII"); d.add_child(Node.new_element("caf\u{E9}")); d).to_xml'
refuses "an attribute name past ASCII in a US-ASCII document" ascii_attribute "cannot be written in a document declared US-ASCII" \
  '(d = Document.new(encoding: "US-ASCII"); e = Node.new_element("r"); e.set_attribute("\u{E9}", "1"); d.add_child(e); d).to_xml'

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
  '      serialize_cdata_body(buf, ascii)' '      buf << @content' 'splits the section'
mutate "a character past U+007F written raw in the CDATA of a US-ASCII document" \
  '      elsif ascii && ptr[i] >= 0x80_u8' '      elsif false' 'in the CDATA of a US-ASCII document'
mutate "text= dropped on an element" \
  '      add_child(Node.new_text(value))' '      nil' 'text= replaces'
mutate "an entity's '<' read as text in an attribute value" \
  '    if value.includes?("<")' '    if false' 'accepted .*&#60;.*a b='
mutate "an entity's ']]>' read as text" \
  '    if !in_attribute && value.includes?("]]>")' '    if false' 'accepted .*]]&#62;'
mutate "an entity's tabs kept in an attribute value" \
  '    return (in_attribute ? Parser.attribute_spaces(value) : value) unless value.includes?("&")' \
  '    return value unless value.includes?("&")' 'tabs and newlines are spaces in an attribute value'
mutate "a prefix bound to the xmlns uri" \
  '        elsif attr_val == XMLNS_NAMESPACE' '        elsif false' 'accepted .*xmlns:p=.*2000/xmlns/'
mutate "the default namespace bound to the xml uri" \
  '        if attr_val == XML_NAMESPACE || attr_val == XMLNS_NAMESPACE' '        if false' 'accepted .*xmlns=.*XML/1998/namespace'
mutate "a character that is not an XML character read" \
  '    if @pos == @bad_at' '    if false' 'accepted "<a>.*</a>"'
mutate "UTF-8 read in a US-ASCII document" \
  '        if lowered == "us-ascii" || lowered == "ascii"' '        if false' 'accepted .*US-ASCII.*caf'
mutate "an XML declaration without a version" \
  '        fail_at(start_line, start_col, "the XML declaration has no version") if stage == 0' '        nil' 'accepted "<?xml ?>'
mutate "XML declaration attributes in any order" \
  '      if !in_place && (attr_name == "version"' '      if false && (attr_name == "version"' 'accepted .*standalone=.*version='
mutate "any text as a version" \
  '        if !Parser.version_number?(attr_val)' '        if false' 'accepted .*1<0'
mutate "a declaration running into the next" \
  '      fail("expected '"'"'>'"'"' to end the #{what}")' '      nil' 'accepted .*ELEMENT a ANY'
mutate "a content model group joined by both , and |" \
  '          if groups.last != 0_u8 && groups.last != b' '          if false' 'accepted .*(a,b|c)'
mutate "an attribute-list default not given" \
  '    defaults = @attribute_defaults[name]?' '    defaults = @attribute_defaults["\n"]?' 'attribute default is given to the element'
mutate "a value of a type other than CDATA kept as written" \
  '      attr_val = Parser.collapse_spaces(attr_val) if tokenized?(name, attr_name)' '      nil' 'written NMTOKENS value'
mutate "a parameter entity reference kept as text in an entity value" \
  '      elsif b == 37_u8' '      elsif false' 'accepted .*%p;'
mutate "no space after the % of a parameter entity" \
  '    if parameter && !skip_whitespace' '    if parameter && !skip_whitespace && false' 'accepted .*ENTITY %p'
mutate "a colon in a processing instruction target" \
  '    if target.includes?(":")' '    if false' 'accepted .*x:y'
mutate "a colon in an entity name" \
  '    if name.includes?(":")' '    if false' 'accepted .*ENTITY a:b'
mutate "a local part that cannot start a name" \
  ' && Parser.name_start?(code_point_at(ptr, len, colon_at + 1))' '' 'accepted .*p:-a'
mutate "a code point past 0x7F taken to start and continue a name" \
  '    return cp != 0xD7 && cp != 0xF7 if cp <= 0x2FF' '    return true if cp <= 0x2FF' 'accepted "<a.*b/>"'
mutate "no space after <!DOCTYPE" \
  '    if !skip_whitespace
      fail("expected whitespace after <!DOCTYPE")' '    if !skip_whitespace && false
      fail("expected whitespace after <!DOCTYPE")' 'accepted .*DOCTYPEa'
mutate "a reference in an entity value that is not a name" \
  '    if !Parser.name_shaped?(ref)' '    if false' 'accepted .*a]b'
mutate "no byte budget on entity expansion" \
  '    if @expanded_bytes > @max_expanded_bytes' '    if false' 'thousand times is refused'
mutate "a US-ASCII document written as UTF-8" \
  '    serialize_node(buf, lowered == "us-ascii" || lowered == "ascii")' '    serialize_node(buf)' 'every other character as a reference'
mutate "a carriage return kept raw in CDATA" \
  '      elsif ptr[i] == 13_u8' '      elsif false' 'carriage return in CDATA'
mutate "a name that is not an XML name written" \
  '    raise "'"'"'#{name}'"'"' is not an XML name, so the #{what} cannot be written" unless Parser.name_shaped?(name)' '    nil' \
  'to_xml refuses what does not read back: is not an XML name'
mutate "a control character written raw" \
  '        raise "control character U+#{Parser.hex4(b.to_i32)} cannot be written: XML has no way to hold it"' '        nil' \
  'to_xml refuses what does not read back: control character U+0001'
mutate "a reserved processing instruction target written" \
  '      if @name.downcase == "xml" || @name.includes?(":")' '      if false' \
  'to_xml refuses what does not read back: so the processing instruction target'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/xml exercise holds"
else
  echo "the std/xml exercise did not hold"
fi
exit $status
