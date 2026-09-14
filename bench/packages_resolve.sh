#!/usr/bin/env bash
# Drives SPEC.md III.7 step 1: `iyi.mod`, minimal version selection, and a
# git fetcher — source only, no registry, no network. The registry-shaped
# half of III.7 (artifacts, signatures, the index) is later steps and is
# not exercised here.
#
#     bash bench/packages_resolve.sh
#
# Everything runs against `IYI_MOD_MIRROR`, the offline hook: a directory
# whose layout is the module path and whose entries are bare git repos, so
# the fetch is real git against a fixture this script builds. Five steps,
# two of them failure proofs:
#
#   1. MVS picks the highest minimum: the app asks for liba v1.0.0, its
#      other dependency asks for v1.1.0, and the program must print v1.1.0
#      and never v1.0.0.
#   2. The second build resolves from the cache: the mirror is deleted and
#      the build must still succeed, because a checkout, once fetched, is
#      read rather than refetched.
#   3. A dotted import with no manifest is refused naming `iyi.mod`.
#   4. A require whose tag does not exist is refused naming the tag.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
export IYI_CACHE_DIR="$WORK/cache"
export IYI_MOD_MIRROR="$WORK/mirror"

cd "$WORK" || exit 1

step() { echo "== $1"; }
mkrepo() { git init -q "$1" && git -C "$1" config user.email t@t && git -C "$1" config user.name t; }

# ── The fixture: two packages, three versions, one raise ─────────────────
mkrepo work/liba
printf 'module example.test/user/liba\n' > work/liba/iyi.mod
printf 'module liba\n\npub def greeting : String\n  "hello from liba v1.0.0"\nend\n' > work/liba/liba.iyi
printf 'module colors\n\npub def favourite : String\n  "green"\nend\n' > work/liba/colors.iyi
git -C work/liba add -A && git -C work/liba commit -qm one && git -C work/liba tag v1.0.0
# `-i.bak` + rm: BSD sed demands the suffix GNU makes optional, and the bare
# form silently mangled this edit on darwin — no tag, and the gate lied red.
sed -i.bak 's/v1.0.0/v1.1.0/' work/liba/liba.iyi && rm -f work/liba/liba.iyi.bak
git -C work/liba commit -qam two && git -C work/liba tag v1.1.0

mkrepo work/libb
printf 'module example.test/user/libb\nrequire example.test/user/liba v1.1.0\n' > work/libb/iyi.mod
printf 'module libb\n\nimport example.test/user/liba\nusing example.test/user/liba::{greeting}\n\npub def doubled : String\n  greeting + " / " + greeting\nend\n' > work/libb/libb.iyi
git -C work/libb add -A && git -C work/libb commit -qm one && git -C work/libb tag v1.0.0

mkdir -p mirror/example.test/user
git clone -q --bare work/liba mirror/example.test/user/liba
git clone -q --bare work/libb mirror/example.test/user/libb

mkdir -p app
printf 'module example.test/user/app\nrequire example.test/user/liba v1.0.0\nrequire example.test/user/libb v1.0.0\n' > app/iyi.mod
cat > app/main.iyi <<'IYI'
import example.test/user/liba
import example.test/user/liba/colors
import example.test/user/libb
using example.test/user/liba::{greeting}
using example.test/user/liba/colors::{favourite}
using example.test/user/libb::{doubled}

puts greeting
puts favourite
puts doubled
IYI

# ── 1. MVS: the highest of the minimums, observably ──────────────────────
step "MVS picks the raised version"
if ! (cd app && "$IYI" build main.iyi -o app) > build.log 2>&1; then
  echo "build failed:"
  tail -8 build.log
  exit 1
fi
./app/app > answers.txt 2>&1
grep -q 'hello from liba v1.1.0' answers.txt || { echo "v1.1.0 never ran:"; cat answers.txt; exit 1; }
grep -q 'v1.0.0' answers.txt && { echo "the version MVS discarded still ran:"; cat answers.txt; exit 1; }
grep -q 'green' answers.txt || { echo "the sub-module import lost:"; cat answers.txt; exit 1; }

# ── 2. The cache is the second build's source ────────────────────────────
step "a fetched checkout is read, not refetched"
rm -rf mirror app/app
if ! (cd app && "$IYI" build main.iyi -o app) > build2.log 2>&1; then
  echo "the second build refetched, and there was nothing to fetch from:"
  tail -8 build2.log
  exit 1
fi
./app/app | grep -q 'v1.1.0' || { echo "cache-built program answered differently"; exit 1; }

# ── 3. Failure proof: a package import needs a manifest ──────────────────
step "failure proof: a dotted import without iyi.mod names the manifest"
mkdir -p bare
printf 'import example.test/user/liba\nputs 1\n' > bare/main.iyi
(cd bare && "$IYI" build main.iyi -o bare) > bare.log 2>&1
if [ $? -eq 0 ] || ! grep -q 'iyi.mod' bare.log; then
  echo "the refusal did not name the manifest:"
  tail -6 bare.log
  exit 1
fi

# ── 4. Failure proof: a version is a tag that must exist ─────────────────
step "failure proof: a missing tag is refused by name"
mkdir -p wrong
printf 'module example.test/user/wrong\nrequire example.test/user/libb v9.9.9\n' > wrong/iyi.mod
printf 'import example.test/user/libb\nputs 1\n' > wrong/main.iyi
mkdir -p mirror/example.test/user
git clone -q --bare work/libb mirror/example.test/user/libb
(cd wrong && "$IYI" build main.iyi -o wrong) > wrong.log 2>&1
if [ $? -eq 0 ] || ! grep -q 'v9.9.9' wrong.log; then
  echo "the refusal did not name the tag:"
  tail -6 wrong.log
  exit 1
fi

# ── 5. iyi.sum: fact, written by the tool, defended by it ────────────────
step "iyi.sum is written, and a tampered entry is a refusal"
grep -q 'example.test/user/liba v1.1.0 s1:' app/iyi.sum || { echo "no sum entry for liba:"; cat app/iyi.sum; exit 1; }
grep -q 'example.test/user/libb v1.0.0 s1:' app/iyi.sum || { echo "no sum entry for libb:"; cat app/iyi.sum; exit 1; }
cp app/iyi.sum app/iyi.sum.good
sed -i.bak 's/s1:....../s1:dead00/' app/iyi.sum && rm -f app/iyi.sum.bak
rm -f app/app
(cd app && "$IYI" build main.iyi -o app) > tamper.log 2>&1
if [ $? -eq 0 ] || ! grep -q 'is not what it was' tamper.log; then
  echo "a tampered sum was accepted:"
  tail -6 tamper.log
  exit 1
fi
mv app/iyi.sum.good app/iyi.sum

# ── 6. The context pack: surfaces, no bodies ──────────────────────────────
step "mod context prints every import's exact surface"
(cd app && "$IYI" mod context main.iyi) > context.txt 2>&1 || { cat context.txt; exit 1; }
grep -q 'pub def greeting : String' context.txt || { echo "liba's surface is missing:"; cat context.txt; exit 1; }
grep -q 'pub def favourite : String' context.txt || { echo "colors' surface is missing:"; cat context.txt; exit 1; }
grep -q 'pub def doubled : String' context.txt || { echo "libb's surface is missing:"; cat context.txt; exit 1; }
grep -q 'hello from liba' context.txt && { echo "a body leaked into the pack"; exit 1; }

step "mod context --json carries hashes and rendered signatures"
(cd app && "$IYI" mod context --json main.iyi) > context.json 2>&1 || { cat context.json; exit 1; }
grep -q '"interface_hash"' context.json || { echo "no interface hash:"; head -20 context.json; exit 1; }
grep -Eq '"rendered": ?"def doubled : String' context.json || { echo "no rendered signature:"; head -40 context.json; exit 1; }

# ── 7. Errors as data: `-f json` carries the SPEC sections it cites ──────
step "a json error cites its SPEC sections as data"
printf 'def f : Int32\n  3\nend\nf!\n' > refs.iyi
"$IYI" build -f json refs.iyi -o refs > refs.log 2>&1
grep -q '"spec":\["III.1"\]' refs.log || { echo "no spec reference in the json error:"; cat refs.log; exit 1; }

# ── 8. Docs travel, and a doc edit moves no hash ──────────────────────────
#
# The `Docs` half of III.7's asset: the doc comment above a `pub` rides the
# artifact, `mod context` and `--json` serve it — and IV.3's doctrine holds:
# a doc is surface for a reader, not for the type checker, so editing one
# must not move the interface hash a dependent's validity hangs on.
step "a doc comment reaches the context pack"
mkdir -p docs
printf 'module docd\n\n# Answers the one question.\npub def answer : Int32\n  42\nend\n' > docs/docd.iyi
printf 'import docd\nusing docd::{answer}\nputs answer\n' > docs/main.iyi
(cd docs && "$IYI" mod context --json main.iyi) > docs.json 2>&1 || { cat docs.json; exit 1; }
grep -Eq '"doc": ?"Answers the one question."' docs.json || { echo "the doc did not travel:"; cat docs.json; exit 1; }

step "a doc-only edit leaves the interface hash alone"
hash_before=$(grep -oE '"interface_hash": ?"[a-f0-9]*"' docs.json | head -1)
sed -i.bak 's/# Answers the one question./# Answers the only question./' docs/docd.iyi && rm -f docs/docd.iyi.bak
(cd docs && "$IYI" mod context --json main.iyi) > docs2.json 2>&1 || { cat docs2.json; exit 1; }
hash_after=$(grep -oE '"interface_hash": ?"[a-f0-9]*"' docs2.json | head -1)
if [ "$hash_before" != "$hash_after" ]; then
  echo "a doc edit moved the interface hash: $hash_before -> $hash_after"
  exit 1
fi
grep -Eq '"doc": ?"Answers the only question."' docs2.json || { echo "the edited doc did not travel"; exit 1; }
# The signature moves AND the body follows it: definition-site typing
# now types `answer` without a caller, and the first version of this
# edit — signature to Int64, body still the Int32 literal — was a
# dormant type lie this gate carried for a release. The rule's first
# catch was its own harness.
sed -i.bak 's/pub def answer : Int32/pub def answer : Int64/; s/^  42$/  42_i64/' docs/docd.iyi && rm -f docs/docd.iyi.bak
(cd docs && "$IYI" mod context --json main.iyi) > docs3.json 2>&1 || { cat docs3.json; exit 1; }
hash_signature=$(grep -oE '"interface_hash": ?"[a-f0-9]*"' docs3.json | head -1)
if [ "$hash_before" = "$hash_signature" ]; then
  echo "a signature edit did not move the interface hash, so the hash checks nothing"
  exit 1
fi

# ── 9. `iyi doc`: the surface, for a person this time ─────────────────────
step "iyi doc prints the surface from source and from the artifact"
"$IYI" doc docs/docd.iyi > doc.txt 2>&1 || { cat doc.txt; exit 1; }
grep -q '# Answers the only question.' doc.txt || { echo "the doc comment is missing:"; cat doc.txt; exit 1; }
grep -q 'pub def answer : Int64' doc.txt || { echo "the signature is missing:"; cat doc.txt; exit 1; }
grep -q '42' doc.txt && { echo "a body leaked into the doc"; exit 1; }

# ── 10. `iyi doc String`: a type of the prelude, the same way ─────────────
step "iyi doc prints a prelude type's surface"
"$IYI" doc String > prelude-doc.txt 2>&1 || { cat prelude-doc.txt; exit 1; }
grep -q '^class String' prelude-doc.txt || { echo "the type header is missing:"; head -5 prelude-doc.txt; exit 1; }
grep -q '  def to_i : Int32' prelude-doc.txt || { echo "a method is missing:"; cat prelude-doc.txt; exit 1; }
grep -q '  def size : Int32' prelude-doc.txt || { echo "size is missing"; exit 1; }
grep -q 'allocate' prelude-doc.txt && { echo "the compiler's own method leaked into the doc"; exit 1; }
# The primitives the prelude declares are the type's own surface: `iyi doc
# Int32` answered with `abs` and `times` and no `+`, no `<`, no `to_i64`,
# because every primitive was filtered as if it were `allocate`.
"$IYI" doc Int32 > int-doc.txt 2>&1 || { cat int-doc.txt; exit 1; }
grep -q '  def +(other : Int32) : self' int-doc.txt || { echo "Int32's + is missing:"; head -20 int-doc.txt; exit 1; }
grep -q '  def <(other : Int32) : Bool' int-doc.txt || { echo "Int32's < is missing"; exit 1; }
grep -q '  def to_i64 : Int64' int-doc.txt || { echo "Int32's to_i64 is missing"; exit 1; }
grep -q '^  def \(allocate\|crystal_type_id\|crystal_instance_type_id\)' int-doc.txt && { echo "the compiler's own method leaked into Int32's doc"; exit 1; }
"$IYI" doc Proc > proc-doc.txt 2>&1 || { cat proc-doc.txt; exit 1; }
grep -q '  def call(\*args : \*T) : R' proc-doc.txt || { echo "Proc's call is missing:"; cat proc-doc.txt; exit 1; }
"$IYI" doc Nope > nope.txt 2>&1 && { echo "an unknown type was documented"; exit 1; }
grep -q 'the prelude has no type Nope' nope.txt || { echo "the unknown type was not named:"; cat nope.txt; exit 1; }
"$IYI" doc prelude > index.txt 2>&1 || { cat index.txt; exit 1; }
grep -q '^class String' index.txt || { echo "the index lacks String:"; cat index.txt; exit 1; }
grep -q '^class Hash(K, V)' index.txt || { echo "the index lacks Hash(K, V):"; cat index.txt; exit 1; }
grep -q 'Regex\|Int128\|IyiHeap' index.txt && { echo "the index lists what the prelude does not offer:"; cat index.txt; exit 1; }

echo "workdir $WORK"
echo "packages gate: every step held"
exit 0
