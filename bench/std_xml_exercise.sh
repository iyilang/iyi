#!/usr/bin/env bash
# Exercises `std/xml`: parser, tree, serializer, references, refusals, and
# XPath 1.0, checked against libxml2 - the engine under the other
# library's XPath - wherever there is one to load.
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
for phrase in "== round trip" "== escaping" "== refusals" "== limits" "== xpath" "== xpath oracle cases"; do
  if ! grep -q "$phrase" "$WORK/xml-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  round trip, escaping, refusals, limits, xpath and its oracle cases all reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" xml-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/xml-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi
if ! diff <(grep '^oracle ' "$WORK/xml-plain.out") <(grep '^oracle ' "$WORK/xml-release.out") >/dev/null 2>&1; then
  echo "  release build printed different oracle lines than the plain build"
  status=1
fi

echo
echo "== XPath against libxml2"
# Every `oracle xp:` line evaluated again by libxml2, through ctypes: the
# document parsed with entities expanded and CDATA as text (XPath's own
# model, section 5.7), the expression evaluated at the document, position
# 1 of 1, with p, q, d and p2 bound; the type compared, a number bit for
# bit, a node-set node by node, each by its place in a walk of libxml2's
# tree. `oracle xpnum:` and `oracle xpread:` are number() and string()
# held to section 4's text directly, where libxml2 does not follow it.
cat > "$WORK/xpath_oracle.py" << 'EOF'
import ctypes, ctypes.util, math, re, struct, sys
from decimal import Decimal

# libxml2, the engine under the other library's XPath, through ctypes.
name = ctypes.util.find_library("xml2")
candidates = [name] if name else []
candidates += ["libxml2.so.16", "libxml2.so.2", "libxml2.2.dylib", "/usr/lib/libxml2.2.dylib"]
lib = None
for candidate in candidates:
    try:
        lib = ctypes.CDLL(candidate)
        break
    except OSError:
        continue
if lib is None:
    print("  no libxml2 to load: the XPath oracle cannot run")
    sys.exit(2)

class Node(ctypes.Structure):
    pass

Node._fields_ = [
    ("_private", ctypes.c_void_p), ("type", ctypes.c_int), ("name", ctypes.c_char_p),
    ("children", ctypes.c_void_p), ("last", ctypes.c_void_p), ("parent", ctypes.c_void_p),
    ("next", ctypes.c_void_p), ("prev", ctypes.c_void_p), ("doc", ctypes.c_void_p),
    ("ns", ctypes.c_void_p), ("content", ctypes.c_void_p), ("properties", ctypes.c_void_p),
]

class Ns(ctypes.Structure):
    _fields_ = [("next", ctypes.c_void_p), ("type", ctypes.c_int),
                ("href", ctypes.c_char_p), ("prefix", ctypes.c_char_p)]

class NodeSet(ctypes.Structure):
    _fields_ = [("nodeNr", ctypes.c_int), ("nodeMax", ctypes.c_int),
                ("nodeTab", ctypes.POINTER(ctypes.c_void_p))]

class XObj(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("nodesetval", ctypes.POINTER(NodeSet)),
                ("boolval", ctypes.c_int), ("floatval", ctypes.c_double),
                ("stringval", ctypes.c_char_p)]

# The head of xmlXPathContext, as far as the context node, size and
# position: an expression is evaluated at the document, position 1 of 1,
# as std/xml evaluates one; libxml2 leaves the node unset and both -1.
class Context(ctypes.Structure):
    _fields_ = [("doc", ctypes.c_void_p), ("node", ctypes.c_void_p),
                ("nb_variables_unused", ctypes.c_int), ("max_variables_unused", ctypes.c_int),
                ("varHash", ctypes.c_void_p), ("nb_types", ctypes.c_int), ("max_types", ctypes.c_int),
                ("types", ctypes.c_void_p), ("nb_funcs_unused", ctypes.c_int), ("max_funcs_unused", ctypes.c_int),
                ("funcHash", ctypes.c_void_p), ("nb_axis", ctypes.c_int), ("max_axis", ctypes.c_int),
                ("axis", ctypes.c_void_p), ("namespaces", ctypes.c_void_p), ("nsNr", ctypes.c_int),
                ("user", ctypes.c_void_p), ("contextSize", ctypes.c_int), ("proximityPosition", ctypes.c_int)]

ERRFUNC = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_char_p)
quiet = ERRFUNC(lambda ctx, msg: None)
lib.xmlSetGenericErrorFunc.argtypes = [ctypes.c_void_p, ERRFUNC]
lib.xmlSetGenericErrorFunc(None, quiet)
lib.xmlSetStructuredErrorFunc.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
lib.xmlSetStructuredErrorFunc(None, ctypes.cast(ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p)(lambda a, b: None), ctypes.c_void_p))
lib.xmlReadMemory.restype = ctypes.c_void_p
lib.xmlReadMemory.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
lib.xmlXPathNewContext.restype = ctypes.c_void_p
lib.xmlXPathNewContext.argtypes = [ctypes.c_void_p]
lib.xmlXPathRegisterNs.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
lib.xmlXPathEvalExpression.restype = ctypes.POINTER(XObj)
lib.xmlXPathEvalExpression.argtypes = [ctypes.c_char_p, ctypes.c_void_p]
lib.xmlXPathFreeObject.argtypes = [ctypes.POINTER(XObj)]

XML_PARSE_NOENT, XML_PARSE_NOCDATA, XML_PARSE_NONET = 2, 16384, 2048
DTD, NAMESPACE_DECL, ATTRIBUTE = 14, 18, 2
NAMESPACES = {"p": "urn:p", "q": "urn:q", "d": "urn:d", "p2": "urn:p2"}

def node(address):
    return ctypes.cast(address, ctypes.POINTER(Node)).contents

class Document:
    def __init__(self, text):
        raw = text.encode()
        self.doc = lib.xmlReadMemory(raw, len(raw), None, None, XML_PARSE_NOENT | XML_PARSE_NOCDATA | XML_PARSE_NONET)
        if not self.doc:
            raise ValueError("libxml2 refused the document")
        self.places, self.attributes = {}, {}
        self.walk(self.doc)
        self.ctx = lib.xmlXPathNewContext(self.doc)
        head = ctypes.cast(self.ctx, ctypes.POINTER(Context)).contents
        if head.doc != self.doc or head.contextSize != -1 or head.proximityPosition != -1:
            raise SystemExit("  libxml2's xmlXPathContext is not laid out as this oracle reads it")
        head.node, head.contextSize, head.proximityPosition = self.doc, 1, 1
        for prefix, uri in NAMESPACES.items():
            lib.xmlXPathRegisterNs(self.ctx, prefix.encode(), uri.encode())

    def walk(self, address):
        self.places[address] = len(self.places)
        n = node(address)
        if n.type == 1:
            attr, i = n.properties, 0
            while attr:
                self.attributes[attr] = (address, i)
                attr, i = node(attr).next, i + 1
        child = n.children
        while child:
            if node(child).type != DTD:
                self.walk(child)
            child = node(child).next

    # Each node as the exercise names it, and the order it sorts in.
    def identity(self, address):
        n = node(address)
        if n.type == NAMESPACE_DECL:
            ns = ctypes.cast(address, ctypes.POINTER(Ns)).contents
            owner = self.places[ns.next]
            prefix = (ns.prefix or b"").decode()
            return (owner, 1, prefix, 0), f"{owner}~{prefix}"
        if n.type == ATTRIBUTE:
            owner, index = self.attributes[address]
            place = self.places[owner]
            return (place, 2, "", index), f"{place}@{index}"
        place = self.places[address]
        return (place, 0, "", 0), str(place)

    def evaluate(self, expression):
        result = lib.xmlXPathEvalExpression(expression.encode(), self.ctx)
        if not result:
            return ("error", "")
        o = result.contents
        try:
            if o.type == 1:
                found = []
                if o.nodesetval:
                    s = o.nodesetval.contents
                    found = [self.identity(s.nodeTab[i]) for i in range(s.nodeNr)]
                found.sort()
                return ("nodes", " ".join(name for _, name in found))
            if o.type == 2:
                return ("bool", "true" if o.boolval else "false")
            if o.type == 3:
                return ("num", o.floatval)
            if o.type == 4:
                return ("str", (o.stringval or b"").decode())
            return ("type %d" % o.type, "")
        finally:
            lib.xmlXPathFreeObject(result)

# XPath 1.0, section 4.2: the fewest digits that read back, no exponent.
def number_string(x):
    if math.isnan(x):
        return "NaN"
    if math.isinf(x):
        return "Infinity" if x > 0 else "-Infinity"
    if x == 0:
        return "0"
    text = format(Decimal(repr(x)), "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text

# Section 4.4: white space, an optional minus, digits and one point.
NUMERAL = re.compile(r"[ \t\r\n]*(-?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+))[ \t\r\n]*\Z")

def string_number(s):
    m = NUMERAL.match(s)
    return float(m.group(1)) if m else float("nan")

def same_double(a, b):
    if math.isnan(a) or math.isnan(b):
        return math.isnan(a) and math.isnan(b)
    return struct.pack("<d", a) == struct.pack("<d", b)

documents, counts, failures = {}, {"xp": 0, "xpnum": 0, "xpread": 0}, 0

def disagree(kind, subject, got, want):
    global failures
    failures += 1
    if failures <= 25:
        print(f"  oracle disagrees: {kind} {subject}: std/xml said {got!r}, the oracle {want!r}")

for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("oracle xpdoc: "):
        number, text = line[len("oracle xpdoc: "):].split("\t", 1)
        documents[number] = Document(text)
    elif line.startswith("oracle xp: "):
        number, expression, kind, value = line[len("oracle xp: "):].split("\t", 3)
        counts["xp"] += 1
        want_kind, want = documents[number].evaluate(expression)
        if want_kind != kind:
            disagree("xp", f"doc {number} {expression}", f"{kind} {value}", f"{want_kind} {want}")
        elif kind == "num":
            if not same_double(float(value), want):
                disagree("xp", f"doc {number} {expression}", value, repr(want))
        elif value != want:
            disagree("xp", f"doc {number} {expression}", value, want)
    elif line.startswith("oracle xpnum: "):
        shown, written = line[len("oracle xpnum: "):].split("\t", 1)
        counts["xpnum"] += 1
        want = number_string(float(shown))
        if written != want:
            disagree("xpnum", shown, written, want)
    elif line.startswith("oracle xpread: "):
        text, read = line[len("oracle xpread: "):].split("\t", 1)
        counts["xpread"] += 1
        if not same_double(float(read), string_number(text)):
            disagree("xpread", repr(text), read, repr(string_number(text)))

print(f"  oracle lines checked: {counts}")
for kind, need in (("xp", 4000), ("xpnum", 1500), ("xpread", 1500)):
    if counts[kind] < need:
        print(f"  too few {kind} oracle lines: {counts[kind]} < {need}")
        failures += 1
sys.exit(1 if failures else 0)
EOF
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the XPath oracle is unmeasured"
else
  "$PY" "$WORK/xpath_oracle.py" < "$WORK/xml-plain.out"
  oracle_status=$?
  if [ "$oracle_status" -eq 2 ]; then
    case "$(uname -s)" in
      MINGW* | MSYS* | CYGWIN* | Windows_NT)
        echo "  Windows has no libxml2: the oracle is measured on Linux and darwin" ;;
      *)
        echo "  and libxml2 is part of every Linux and darwin runner this gate trusts"
        status=1 ;;
    esac
  elif [ "$oracle_status" -ne 0 ]; then
    status=1
  else
    # The oracle itself has to be able to disagree: on a node-set out of
    # document order, a number one ulp off, a string one letter off.
    oracle_rejects() { # oracle_rejects <label> <python that rewrites one line>
      local label="$1" rewrite="$2"
      REWRITE="$rewrite" "$PY" - "$WORK/xml-plain.out" > "$WORK/broken-oracle.out" <<'PY'
import os, sys
rewrite = eval(os.environ["REWRITE"])
done = False
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.rstrip("\n")
    if not done and line.startswith("oracle xp: "):
        changed = rewrite(line)
        if changed is not None:
            line, done = changed, True
    print(line)
if not done:
    raise SystemExit("no line to rewrite")
PY
      if [ $? -ne 0 ]; then
        echo "  $label: no line to make it from"
        status=1
      elif "$PY" "$WORK/xpath_oracle.py" < "$WORK/broken-oracle.out" > "$WORK/broken-verdict" 2>&1; then
        echo "  the oracle accepted $label, so it checks nothing there"
        status=1
      else
        echo "  the oracle rejects $label"
      fi
    }
    oracle_rejects "a node-set out of document order" \
      'lambda l: (lambda f: "\t".join(f[:3] + [" ".join(f[3].split()[::-1])]) if f[2] == "nodes" and len(f[3].split()) > 1 else None)(l.split("\t"))'
    oracle_rejects "a number one ulp off" \
      'lambda l: (lambda f: "\t".join(f[:3] + [repr(__import__("math").nextafter(float(f[3]), 1e308))]) if f[2] == "num" and float(f[3]) == float(f[3]) and abs(float(f[3])) < 1e300 else None)(l.split("\t"))'
    oracle_rejects "a string one letter off" \
      'lambda l: (lambda f: "\t".join(f[:3] + [f[3] + "x"]) if f[2] == "str" else None)(l.split("\t"))'
  fi
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
# XPath, each mechanism taken out of a copy that compiles and caught at the
# named check that holds it.
mutate "a reverse axis answered in reverse document order" \
  '        current = found.reversed' '        current = found' 'got "chapter doc"'
mutate "a small number's exponent read as positive" \
  '      exponent = 0 - exponent if minus' '      nil' 'xpath 0.000001 (expected'
mutate "text and CDATA side by side as two text nodes" \
  '    return false if i > 0 && XPathRun.text_like?(parent.children[i - 1])' '    nil' 'xpath /r/text() (expected'
mutate "an empty run of text a text node" \
  '      return true unless parent.children[j].text.empty?' '      return true' 'xpath /r/text() (expected'
mutate "text beside the root element a node" \
  '    return false if parent.node_type.document?' '    nil' 'expected "r", got'
mutate "an unprefixed name test taking the default namespace" \
  'n.namespace_uri == (step.prefix.empty? ? "" : @resolved[step.prefix])' \
  '(step.prefix.empty? || n.namespace_uri == @resolved[step.prefix])' 'xpath //r (expected'
mutate "a node-set on the right compared as if on the left" \
  '      flipped ? XPathRun.relate(op, target, x) : XPathRun.relate(op, x, target)' \
  '      XPathRun.relate(op, x, target)' 'xpath 3 < //n'
mutate "lang() matching a prefix without its hyphen" \
  'have.to_unsafe[want.bytesize] == 45_u8' 'true' "lang('e')"
mutate "an xml:id not an ID" \
  '(a.local_name == "id" && a.namespace_uri == XML_NAMESPACE) || ' '' "id('x1')"
mutate "round() dropping a zero's sign" \
  '    return value * 0.0 if value >= -0.5 && value < 0.5' '    return 0.0 if value >= -0.5 && value < 0.5' 'round(-0.4)'
mutate "mod taking the divisor's sign" \
  '    a < 0.0 ? x * -1.0 : x' '    x' 'xpath -5 mod 2'
mutate "a * after an operand read as a name test" \
  '        kind = operator_next ? XPathTokenKind::Multiply : XPathTokenKind::Star' \
  '        kind = XPathTokenKind::Star' 'XPath "count('
mutate "a node twice in a union" \
  '      into << n if key != last' '      into << n' 'xpath count(//title | //title'
mutate "an attribute's following axis without its element's children" \
  '      descendants(step, node, into) unless tree' '      nil' 'xpath //@x/following::node() (expected'
mutate "a default namespace undeclared still in scope" \
  '      scope << Namespace.new(prefix, uri) unless uri.empty?' '      scope << Namespace.new(prefix, uri)' 'xpath //c/namespace::'
mutate "translate() taking a character's last place" \
  '      replacement[cp] = i < to_chars.size ? to_chars[i] : "" unless replacement.has_key?(cp)' \
  '      replacement[cp] = i < to_chars.size ? to_chars[i] : ""' "translate('şeker'"
mutate "a number read past what is not a digit" \
  '    return 0.0 / 0.0 if at != stop || whole_digits + fraction_digits == 0' \
  '    return 0.0 / 0.0 if whole_digits + fraction_digits == 0' "number('1e3')"

echo
if [ "$status" -eq 0 ]; then
  echo "the std/xml exercise holds"
else
  echo "the std/xml exercise did not hold"
fi
exit $status
