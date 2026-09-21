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
# The gate runs whatever compiler the caller names; `bin/iyi` is a shell
# wrapper, and on Windows the caller has to point at the built exe itself.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a cache or
# mirror named `/tmp/tmp.X` is a directory the compiler cannot open.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac
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

# And the direction that is the threat rather than the typo: the sum file
# is honest and the *checkout* is not. That is what a compromised cache, a
# moved tag or a backup restored from the wrong day looks like, and it is
# the one thing III.7 says this file exists to notice. The step above
# proves the comparison happens; this one proves what it compares — the
# hash is recomputed from the tree on every build, so a dependency that
# changed under the program is a refusal naming both hashes.
step "a mutated checkout is refused while iyi.sum is honest"
# The checkout `iyi.sum` pins, read out of the sum file rather than
# searched for or written down twice. The cache holds v1.0.0 as well, and
# `find | head -1` picked whichever the directory happened to list first —
# v1.1.0 on Linux and v1.0.0 on darwin, where mutating a checkout no entry
# pins proved nothing and the step failed with the program printing its
# ordinary answer. Asking the sum file ties the tree this mutates to the
# entry this expects the refusal about, whatever MVS chose. The layout is
# the fetcher's: `<cache>/mod/<path>@v<version>`.
pinned="$(awk '$1 == "example.test/user/liba" { print $2 }' app/iyi.sum)"
[ -n "$pinned" ] || { echo "iyi.sum pins no version for liba:"; cat app/iyi.sum; exit 1; }
checkout="$(find "$IYI_CACHE_DIR" -path "*liba@$pinned*" -name liba.iyi | head -1)"
[ -n "$checkout" ] || { echo "no liba@$pinned checkout under $IYI_CACHE_DIR"; exit 1; }
grep -q 'hello from liba' "$checkout" || {
  echo "$checkout does not contain the string this step mutates:"
  cat "$checkout"
  exit 1
}
cp "$checkout" "$WORK/liba.iyi.good"
# A change a program would notice, in the one file it calls into.
sed -i.bak 's/hello from liba/hello from somebody else/' "$checkout" && rm -f "$checkout.bak"
# And the mutation is asserted rather than assumed: a `sed` that edited
# nothing would leave this step proving that an unchanged tree builds.
grep -q 'hello from somebody else' "$checkout" || {
  echo "the mutation did not take in $checkout"
  exit 1
}
rm -f app/app
(cd app && "$IYI" build main.iyi -o app) > mutated.log 2>&1
mutated_status=$?
cp "$WORK/liba.iyi.good" "$checkout"
if [ "$mutated_status" -eq 0 ]; then
  echo "a mutated checkout built anyway:"
  ./app/app 2>&1 | sed 's/^/  /'
  exit 1
fi
grep -q 'is not what it was' mutated.log || {
  echo "a mutated checkout was refused for some other reason:"
  tail -6 mutated.log
  exit 1
}
grep -q 'the checkout hashes to' mutated.log || {
  echo "the refusal did not name what the tree hashes to now:"
  tail -6 mutated.log
  exit 1
}

# ── 5b. A package's tree may contain a symbolic link ─────────────────────
# The hash is over the checkout's files, and a walk that asks the *target*
# whether it is a directory walks through a link — into the package's own
# parent, or around a cycle. `inner/loop -> ..` ended a build with the
# walker's accident: `Too many levels of symbolic links`, about a path
# forty levels deep, in place of any sentence about the dependency. A link
# is hashed as the link now, which is git's own model — the target text is
# what a repository stores for one — so the cycle is an entry rather than a
# descent, and retargeting the link is a change the sum notices.
step "a package with a symbolic link is hashed, cycle and all"
mkrepo work/linked
printf 'module example.test/user/linked
' > work/linked/iyi.mod
printf 'module linked

pub def linked_greeting : String
  "hello from linked"
end
' > work/linked/linked.iyi
mkdir -p work/linked/inner
ln -s .. work/linked/inner/loop
ln -s ../linked.iyi work/linked/inner/alias.iyi
git -C work/linked add -A && git -C work/linked commit -qm one && git -C work/linked tag v1.0.0
git -C work/linked ls-files -s | grep -q '^120000' || { echo "git did not store a symlink, so this step proves nothing:"; git -C work/linked ls-files -s; exit 1; }
git clone -q --bare work/linked mirror/example.test/user/linked
mkdir -p linked_app
printf 'module example.test/user/linked_app
require example.test/user/linked v1.0.0
' > linked_app/iyi.mod
cat > linked_app/main.iyi <<'IYI'
import example.test/user/linked
using example.test/user/linked::{linked_greeting}

puts linked_greeting
IYI
if ! (cd linked_app && "$IYI" build main.iyi -o app) > linked.log 2>&1; then
  echo "a package with a symbolic link did not build:"
  tail -4 linked.log
  exit 1
fi
./linked_app/app | grep -q 'hello from linked' || { echo "the linked package answered:"; ./linked_app/app; exit 1; }
grep -q 'example.test/user/linked v1.0.0 s1:' linked_app/iyi.sum || { echo "no sum entry for linked:"; cat linked_app/iyi.sum; exit 1; }

step "retargeting a link inside the checkout is a change"
linked_checkout="$(find "$IYI_CACHE_DIR" -type d -name 'linked@v1.0.0' | head -1)"
[ -n "$linked_checkout" ] || { echo "no linked@v1.0.0 checkout under $IYI_CACHE_DIR"; exit 1; }
ln -sfn ../iyi.mod "$linked_checkout/inner/alias.iyi"
rm -f linked_app/app
(cd linked_app && "$IYI" build main.iyi -o app) > retarget.log 2>&1
retarget_status=$?
ln -sfn ../linked.iyi "$linked_checkout/inner/alias.iyi"
if [ "$retarget_status" -eq 0 ]; then
  echo "a retargeted link went unnoticed, so the link's target is not in the hash"
  exit 1
fi
grep -q 'is not what it was' retarget.log || {
  echo "the retargeted link was refused for some other reason:"
  tail -5 retarget.log
  exit 1
}

# ── 5c. What `--emit-iyimod` writes, and what it leaves to the sum ────────
# An artifact carries what the consuming build reached, so the one this
# would write for a *package* is hollow: the exports collector keys on the
# in-package type name and a canonical dotted path reaches nothing. A
# package's artifact is III.7 step 5's story — signatures, signing, a
# registry — so a build writes artifacts for the modules it reads from
# source and leaves the packages to `iyi.sum` and the cache, which is where
# the next build finds them. The help line used to promise one per imported
# module, which is every module either way.
step "--emit-iyimod writes this workspace's modules, not its packages'"
printf 'module helper

pub def shout(s : String) : String
  s + "!"
end
' > app/helper.iyi
cat > app/emitted.iyi <<'IYI'
import example.test/user/liba
import helper
using example.test/user/liba::{greeting}
using helper::{shout}

puts shout(greeting)
IYI
rm -rf app/emitted_mods
(cd app && "$IYI" build --emit-iyimod emitted_mods emitted.iyi -o emitted) > emit.log 2>&1 || {
  echo "the emitting build failed:"; tail -4 emit.log; exit 1;
}
[ -f app/emitted_mods/helper.iyimod ] || {
  echo "no artifact for the workspace's own module:"; find app/emitted_mods -type f; exit 1;
}
dotted="$(find app/emitted_mods -name '*.iyimod' | grep '\.' | grep -v '^app/emitted_mods/helper.iyimod$' | head -1)"
if [ -n "$dotted" ]; then
  echo "a package module was written as an artifact, which this build cannot fill: $dotted"
  exit 1
fi
# And the consumer still builds from those artifacts: the package comes from
# the cache the sum pins, the workspace's module from the file just written.
(cd app && "$IYI" build --use-iyimod emitted_mods emitted.iyi -o emitted_from_mods) > emit_use.log 2>&1 || {
  echo "building against the emitted artifacts failed:"; tail -4 emit_use.log; exit 1;
}
./app/emitted_from_mods | grep -q 'hello from liba' || {
  echo "the artifact build answered:"; ./app/emitted_from_mods; exit 1;
}

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
