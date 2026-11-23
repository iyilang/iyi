#!/usr/bin/env bash
# What a release build tells LLVM about an array's memory, held to where it
# is true (src/compiler/iyi/codegen/array_tbaa.cr).
#
#     bash bench/array_tbaa.sh
#
# The code generator marks an `Array`'s own fields and its elements with two
# `!tbaa` tags LLVM takes for distinct memory, and a class element's read as
# an object (`!nonnull`, `!dereferenceable`, `!align`). A tag in the wrong
# place does not fail anything: LLVM moves a load past a store that changed
# it, and the program answers wrong where it happens to be optimised. So
# this reads the IR itself, and then runs the arrays that would answer
# wrong:
#
# 1. In a program's IR, the field tag is only on a load or store through a
#    field of an `Array` instance, the element tag only in `array_at` and
#    `array_put` and only on a scalar slot (never a struct's, so never a
#    `ReferenceStorage`'s object), and the object marks only on an element
#    whose type is one class: not on a nilable one, nor a struct.
# 2. A program of the cases a wrong tag would break - nilable class
#    elements, reads after a shrink to empty, struct elements written in place, a
#    product loop - answers right, plain and with --release.
# 3. The check of 1 is proved capable of failing: a prelude whose
#    `Pointer#[]` reads through `array_slot` puts the element tag on memory
#    that is not an array's, and the check must refuse it.
#
# Exits non-zero if any check fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler on Windows reads `C:/...` paths and `;` between them.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=';'
    ;;
  *) PSEP=':' ;;
esac
trap 'rm -rf "$WORK"' EXIT
status=0

cat > "$WORK/arrays.iyi" <<'IYI'
module main

class Leaf
  getter value : Int32

  def initialize(@value : Int32)
  end
end

struct Pair
  getter a : Int32
  getter b : Int32

  def initialize(@a : Int32, @b : Int32)
  end
end

def check(condition : Bool, what : String) : Nil
  raise "array_tbaa: #{what}" unless condition
end

# Nilable class elements: no element is taken for an object.
leaves = [Leaf.new(1), nil, Leaf.new(3)] of Leaf?
found = 0
nils = 0
leaves.each do |leaf|
  if leaf
    found += leaf.value
  else
    nils += 1
  end
end
check(found == 4 && nils == 1, "nilable class elements")

# Class elements, read in a loop beside stores into another array.
objects = Array.new(50) { |i| Leaf.new(i) }
values = Array.new(50) { 0 }
(0...50).each { |i| values[i] = objects[i].value * 2 }
check(values.sum == 2450, "class elements beside stores")

# Reads after a shrink: the size is read again, not kept.
shrunk = [1, 2, 3, 4]
shrunk.pop
shrunk.pop
check(shrunk[2]?.nil? && shrunk[1]? == 2, "reads after pop")
shrunk.pop
shrunk.pop
check(shrunk[0]?.nil? && shrunk.size == 0, "reads after emptying")
shrunk << 7
check(shrunk[0] == 7 && shrunk[-1] == 7, "reads after a push into an emptied array")

# Struct elements written in place, then read.
pairs = Array.new(20) { |i| Pair.new(i, i * 3) }
(0...20).each { |i| pairs[i] = Pair.new(pairs[i].b, pairs[i].a) }
total = 0
pairs.each { |pair| total += pair.a - pair.b }
check(total == 380, "struct elements written in place")

# The loop the tags were for, with a row that is its own source.
rows = Array.new(8) { |i| Array.new(8) { |j| 1.0 * (i + j) } }
(0...8).each do |k|
  rk = rows[k]
  (0...8).each { |i| row = rows[i]; (0...8).each { |j| row[j] += 0.5 * rk[j] } }
end
check(rows[7][7] > 0.0, "the product loop")

puts "array tag checks passed"
IYI

# The IR check: every tagged access where its tag is true.
check_ir() { # check_ir <ll file> -> prints problems, exit 1 if any
  python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
meta = dict(re.findall(r'^(![0-9]+) = (.*)$', text, re.M))
def tag(name):
    scalar = [k for k, v in meta.items() if v.startswith('!{!"%s"' % name)]
    return {k for k, v in meta.items() for s in scalar if v == "!{%s, %s, i64 0}" % (s, s)}
field, element = tag("Array field"), tag("Array element")
problems = []
if not field or not element:
    problems.append("no array tags in the IR at all")
fn = None
arrays = set()
for line in text.split("\n"):
    if line.startswith("define"):
        fn = line
        arrays = set()
        continue
    m = re.match(r'\s*(%\S+) = getelementptr inbounds %"Array\(', line)
    if m:
        arrays.add(m.group(1))
    t = re.search(r'!tbaa (![0-9]+)', line)
    if t:
        access = re.match(r'\s*(?:%\S+ = load (%"[^"]*"|[^\s,]+), ptr (%[^\s,]+)|store (%"[^"]*"|[^\s,]+) [^,]+, ptr (%[^\s,]+))', line)
        if not access:
            continue
        type_ = access.group(1) or access.group(3)
        pointer = access.group(2) or access.group(4)
        if t.group(1) in field and pointer not in arrays:
            problems.append("field tag off an Array field: %s | %s" % (fn[:110], line.strip()[:100]))
        if t.group(1) in element:
            if "^Pointer(T)#array_" not in fn:
                problems.append("element tag outside array_at/array_put: %s | %s" % (fn[:110], line.strip()[:100]))
            if type_.startswith('%') or type_.startswith('{') or type_.startswith('['):
                problems.append("element tag on an aggregate: %s | %s" % (fn[:110], line.strip()[:100]))
    if "!nonnull" in line or "!dereferenceable" in line:
        if "^Pointer(T)#array_" in (fn or "") and (" | Nil)" in fn or "Pointer(Main::Pair)" in fn):
            problems.append("object marks on a nilable or struct element: %s" % fn[:110])
for p in problems[:20]:
    print("  " + p)
sys.exit(1 if problems else 0)
PY
}

ir_case() { # ir_case <label> <search path or empty>
  local label="$1" search="$2"
  if ! env ${search:+IYI_PATH="$search"} "$IYI" build --single-module --no-debug --emit llvm-ir \
       -o "$WORK/ir" "$WORK/arrays.iyi" > "$WORK/ir.build" 2>&1; then
    echo "  $label: did not build"
    sed -n '1,10p' "$WORK/ir.build"
    return 2
  fi
  check_ir "$WORK/ir.ll"
}

echo "== where the tags are, in the IR of a program of arrays"
if ir_case "the prelude" "${IYI_PATH:-}"; then
  echo "  every array tag is on an array's field or a scalar element, and no nilable or struct element is taken for an object"
else
  status=1
fi

echo
echo "== the arrays a wrong tag would break"
for flags in "" "--release"; do
  label="${flags:-plain}"
  if "$IYI" build $flags -o "$WORK/arrays" "$WORK/arrays.iyi" > "$WORK/arrays.build" 2>&1 &&
     "$WORK/arrays" > "$WORK/arrays.out" 2>&1 && grep -q "array tag checks passed" "$WORK/arrays.out"; then
    echo "  $label: every check held"
  else
    echo "  $label: failed"
    tail -n 3 "$WORK/arrays.build" "$WORK/arrays.out"
    status=1
  fi
done

echo
echo "== proving the IR check can fail: Pointer#[] reading through array_slot"
mkdir -p "$WORK/broken/iyi"
cp -R "$REPO/src/iyi/." "$WORK/broken/iyi/"
sed -e 's/^    (self + offset.to_i64).value$/    (self + offset.to_i64).array_slot/' \
  "$REPO/src/iyi/prelude.iyi" > "$WORK/broken/iyi/prelude.iyi"
if cmp -s "$REPO/src/iyi/prelude.iyi" "$WORK/broken/iyi/prelude.iyi"; then
  echo "  the patch changed nothing, so this proves nothing"
  status=1
else
  ir_case "the broken prelude" "$WORK/broken${PSEP}$REPO/src" > "$WORK/broken.out"
  code=$?
  if [ "$code" -eq 1 ]; then
    echo "  refused: $(sed -n '1p' "$WORK/broken.out" | cut -c1-140)"
  else
    echo "  the check passed a tag on memory that is not an array's (exit $code)"
    cat "$WORK/broken.out"
    status=1
  fi
fi

exit $status
