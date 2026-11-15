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
# A package module that uses the standard library: `std/file` is iyi's,
# found where every program finds it, and never the consuming project's
# module of the same name (the app below has one that panics).
printf 'module colors\n\nimport std/file\n\npub def favourite : String\n  File.basename("/paint/green.txt", ".txt")\nend\n' > work/liba/colors.iyi
git -C work/liba add -A && git -C work/liba commit -qm one && git -C work/liba tag v1.0.0
# `-i.bak` + rm: BSD sed demands the suffix GNU makes optional, and the bare
# form silently mangled this edit on darwin — no tag, and the gate lied red.
sed -i.bak 's/v1.0.0/v1.1.0/' work/liba/liba.iyi && rm -f work/liba/liba.iyi.bak
git -C work/liba commit -qam two && git -C work/liba tag v1.1.0

mkrepo work/libb
printf 'module example.test/user/libb\nrequire example.test/user/liba v1.1.0\n' > work/libb/iyi.mod
printf 'module libb\n\nimport example.test/user/liba::{greeting}\n\npub def doubled : String\n  greeting + " / " + greeting\nend\n' > work/libb/libb.iyi
git -C work/libb add -A && git -C work/libb commit -qm one && git -C work/libb tag v1.0.0

mkdir -p mirror/example.test/user
git clone -q --bare work/liba mirror/example.test/user/liba
git clone -q --bare work/libb mirror/example.test/user/libb

mkdir -p app/std
printf 'module std/file\n\nraise "the consuming project'"'"'s std/file was loaded for a package"\n' > app/std/file.iyi
printf 'module example.test/user/app\nrequire example.test/user/liba v1.0.0\nrequire example.test/user/libb v1.0.0\n' > app/iyi.mod
cat > app/main.iyi <<'IYI'
import example.test/user/liba::{greeting}
import example.test/user/liba/colors::{favourite}
import example.test/user/libb::{doubled}

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
# The require line it names is the repository's: the whole path first, for
# the package's root module. It used to drop the last segment and answer
# `require example.test/user v1.2.3`, the organisation.
step "failure proof: a dotted import without iyi.mod names the manifest"
mkdir -p bare
printf 'import example.test/user/liba\nputs 1\n' > bare/main.iyi
(cd bare && "$IYI" build main.iyi -o bare) > bare.log 2>&1
if [ $? -eq 0 ] || ! grep -q 'iyi.mod' bare.log; then
  echo "the refusal did not name the manifest:"
  tail -6 bare.log
  exit 1
fi
if ! grep -qF 'as `require example.test/user/liba v1.2.3`' bare.log; then
  echo "the refusal did not name the repository's require line:"
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
grep -q 'example.test/user/liba v1.1.0 h2:' app/iyi.sum || { echo "no sum entry for liba:"; cat app/iyi.sum; exit 1; }
grep -q 'example.test/user/libb v1.0.0 h2:' app/iyi.sum || { echo "no sum entry for libb:"; cat app/iyi.sum; exit 1; }
cp app/iyi.sum app/iyi.sum.good
sed -i.bak 's/h2:....../h2:dead00/' app/iyi.sum && rm -f app/iyi.sum.bak
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

# ── 5a. What the hash is of: each file, and where it ends ────────────────
# `iyi.sum` held `s1:` first: SHA-1 over `<path>\0<bytes>\0` for every
# file in path order, with no lengths. A file's bytes may hold a zero byte
# and a file name, so the stream did not say where one file ended: a data
# file could carry, after a zero byte, the name of the source file beside
# it and another body for it. A tag moved to the tree in which those bytes
# had changed places - the other body in the source file, the first one in
# a data file after it - made the same stream and the same line, and the
# build that fetched it ran the other body without a word. `h2:` digests
# each file on its own and hashes the list of digests, kinds and paths, so
# the two trees are two lines. The control is the step above: a plain
# change was always refused; this is the change that was not.
step "a tag moved to a tree whose bytes crossed a file's edge is refused"
reviewed='module libf

pub def framed : String
  "the body that was reviewed"
end
'
swapped='module libf

pub def framed : String
  "the body the moved tag carries"
end
'
mkrepo work/libf
# Byte for byte: the trick is in the bytes, and a git that rewrites line
# ends on commit would be testing some other two trees.
git -C work/libf config core.autocrlf false
printf 'module example.test/user/libf\n' > work/libf/iyi.mod
printf '%s' "$reviewed" > work/libf/libf.iyi
{ printf 'DATA\0libf.iyi\0'; printf '%s' "$swapped"; printf '\0libf.iyz\0JUNK'; } > work/libf/libf.dat
git -C work/libf add -A && git -C work/libf commit -qm reviewed && git -C work/libf tag v1.0.0
mkdir -p mirror/example.test/user
git clone -q --bare work/libf mirror/example.test/user/libf
mkdir -p framed_app
printf 'module example.test/user/framed_app\nrequire example.test/user/libf v1.0.0\n' > framed_app/iyi.mod
printf 'import example.test/user/libf::{framed}\n\nputs framed\n' > framed_app/main.iyi
if ! (cd framed_app && "$IYI" build main.iyi -o app) > framed.log 2>&1; then
  echo "the reviewed tree did not build:"
  tail -6 framed.log
  exit 1
fi
./framed_app/app | grep -q 'the body that was reviewed' || { echo "the reviewed tree answered:"; ./framed_app/app; exit 1; }
grep -q 'example.test/user/libf v1.0.0 h2:' framed_app/iyi.sum || { echo "no sum entry for libf:"; cat framed_app/iyi.sum; exit 1; }
cp framed_app/iyi.sum framed_app/iyi.sum.reviewed
# The same bytes in the same order, cut at other places.
printf '%s' "$swapped" > work/libf/libf.iyi
printf 'DATA' > work/libf/libf.dat
{ printf 'JUNK\0libf.iyi\0'; printf '%s' "$reviewed"; } > work/libf/libf.iyz
git -C work/libf add -A && git -C work/libf commit -qm moved
# Asserted rather than assumed: the two trees are the pair `s1:` could not
# tell apart, or this step proves only that a changed file is noticed.
unframed() {
  for f in $(git -C work/libf ls-tree -r --name-only "$1" | LC_ALL=C sort); do
    printf '%s\0' "$f"; git -C work/libf show "$1:$f"; printf '\0'
  done
}
unframed v1.0.0 > unframed.reviewed
unframed HEAD > unframed.moved
cmp -s unframed.reviewed unframed.moved || {
  echo "the two trees are not one stream of paths and bytes, so this step proves nothing"
  exit 1
}
git -C work/libf tag -f v1.0.0 > /dev/null
git -C work/libf push -q -f "$WORK/mirror/example.test/user/libf" refs/tags/v1.0.0
# A machine that never fetched it: the checkout goes, the sum stays.
framed_checkout="$(find "$IYI_CACHE_DIR" -type d -name 'libf@v1.0.0' | head -1)"
[ -n "$framed_checkout" ] || { echo "no libf@v1.0.0 checkout under $IYI_CACHE_DIR"; exit 1; }
rm -rf "$framed_checkout" framed_app/app framed_app/app.exe
(cd framed_app && "$IYI" build main.iyi -o app) > framed_moved.log 2>&1
if [ $? -eq 0 ]; then
  echo "a tag moved to another tree built under the line the first tree wrote:"
  ./framed_app/app 2>&1 | sed 's/^/  /'
  exit 1
fi
grep -q 'example.test/user/libf v1.0.0 is not what it was' framed_moved.log || {
  echo "the moved tag was refused for some other reason:"
  tail -6 framed_moved.log
  exit 1
}
cmp -s framed_app/iyi.sum framed_app/iyi.sum.reviewed || { echo "a refused build rewrote iyi.sum:"; cat framed_app/iyi.sum; exit 1; }

# An `s1:` line is one this compiler's predecessors wrote. It is not left
# in the file, and it is not dropped unread: the checkout is hashed the
# old way once more, a checkout that differs is refused as it always was,
# and one that matches has its line written again as `h2:`, said once on
# stderr. Rewritten unread, the first build after an upgrade would pin
# whatever it found checked out - a moved tag among them.
step "an s1: line its checkout matches is written again as h2:, and one it does not is refused"
if command -v sha1sum > /dev/null 2>&1; then
  sha1() { sha1sum | cut -c1-40; }
else
  sha1() { shasum -a 1 | cut -c1-40; }
fi
# What `s1:` was, from the checkout's own files: `<path>\0<bytes>\0` for
# each in path order, under SHA-1.
s1_of() {
  (cd "$1" && find . -type f | sed 's#^\./##' | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s\0' "$f"; cat "$f"; printf '\0'
  done) | sha1
}
cp app/iyi.sum app/iyi.sum.good
: > app/iyi.sum.s1
while read -r path version _; do
  tree="$IYI_CACHE_DIR/mod/$path@$version"
  [ -f "$tree/iyi.mod" ] || { echo "no checkout at $tree for the line $path $version"; exit 1; }
  printf '%s %s s1:%s\n' "$path" "$version" "$(s1_of "$tree")" >> app/iyi.sum.s1
done < app/iyi.sum.good
cp app/iyi.sum.s1 app/iyi.sum
if grep -q ' h2:' app/iyi.sum || [ "$(grep -c ' s1:[0-9a-f]\{40\}$' app/iyi.sum)" -ne 2 ]; then
  echo "the fixture's sum was not turned into two s1: lines:"
  cat app/iyi.sum
  exit 1
fi
rm -f app/app
if ! (cd app && "$IYI" build main.iyi -o app) > restated.log 2>&1; then
  echo "a build under s1: lines its checkouts match did not build:"
  tail -6 restated.log
  mv app/iyi.sum.good app/iyi.sum
  exit 1
fi
cmp -s app/iyi.sum app/iyi.sum.good || {
  echo "the s1: lines were not written again as what the checkouts hash to:"
  cat app/iyi.sum
  mv app/iyi.sum.good app/iyi.sum
  exit 1
}
grep -q '2 entries said `s1:`' restated.log || {
  echo "the build did not say it restated the s1: lines:"
  tail -6 restated.log
  exit 1
}
(cd app && "$IYI" build main.iyi -o app) > restated2.log 2>&1
if [ $? -ne 0 ] || grep -q 's1:' restated2.log; then
  echo "the build after it said so again, or failed:"
  tail -6 restated2.log
  exit 1
fi
# And the line a checkout does not match: liba's, with one digit moved.
liba_s1="$(awk '$1 == "example.test/user/liba" { print $3 }' app/iyi.sum.s1)"
case "$liba_s1" in
  s1:0*) wrong_s1="s1:1${liba_s1#s1:0}" ;;
  *) wrong_s1="s1:0${liba_s1#s1:?}" ;;
esac
sed "s/$liba_s1/$wrong_s1/" app/iyi.sum.s1 > app/iyi.sum
cp app/iyi.sum app/iyi.sum.wrong
rm -f app/app
(cd app && "$IYI" build main.iyi -o app) > unmatched.log 2>&1
unmatched_status=$?
cmp -s app/iyi.sum app/iyi.sum.wrong
unmatched_written=$?
mv app/iyi.sum.good app/iyi.sum
rm -f app/iyi.sum.s1 app/iyi.sum.wrong
if [ "$unmatched_status" -eq 0 ]; then
  echo "an s1: line its checkout does not match built, and was taken for an upgrade"
  exit 1
fi
grep -q "says $wrong_s1, the checkout hashes to $liba_s1" unmatched.log || {
  echo "the unmatched s1: line was not refused naming both s1: hashes:"
  tail -6 unmatched.log
  exit 1
}
[ "$unmatched_written" -eq 0 ] || { echo "a refused build rewrote iyi.sum"; exit 1; }

# The same line where it cannot be written again: a dependency's own
# `iyi.sum`, read by a build inside its cached checkout. Nothing is
# written under the cache's `mod/`, and for a while nothing was compared
# there either - an `s1:` line of any forty digits passed. The file is
# put into the cached libb for this step and taken back out, because the
# app's sum pins that tree without it.
step "an s1: line in a cached dependency's own iyi.sum is held to its checkout, and stays s1:"
libb_cached="$IYI_CACHE_DIR/mod/example.test/user/libb@v1.0.0"
[ -f "$libb_cached/libb.iyi" ] || { echo "no cached libb at $libb_cached"; exit 1; }
printf 'example.test/user/liba v1.1.0 %s\n' "$wrong_s1" > "$libb_cached/iyi.sum"
(cd "$libb_cached" && "$IYI" check libb.iyi) > cached_wrong.log 2>&1
cached_wrong_status=$?
printf 'example.test/user/liba v1.1.0 %s\n' "$liba_s1" > "$libb_cached/iyi.sum"
cp "$libb_cached/iyi.sum" cached.sum
(cd "$libb_cached" && "$IYI" check libb.iyi) > cached_right.log 2>&1
cached_right_status=$?
cmp -s "$libb_cached/iyi.sum" cached.sum
cached_written=$?
rm -f "$libb_cached/iyi.sum" cached.sum
if [ "$cached_wrong_status" -eq 0 ]; then
  echo "inside the module cache an s1: line its checkout does not match was compared with nothing"
  exit 1
fi
grep -q "says $wrong_s1, the checkout hashes to $liba_s1" cached_wrong.log || {
  echo "the cached libb's unmatched s1: line was not refused naming both s1: hashes:"
  tail -6 cached_wrong.log
  exit 1
}
if [ "$cached_right_status" -ne 0 ]; then
  echo "inside the module cache an s1: line its checkout matches was refused:"
  tail -6 cached_right.log
  exit 1
fi
[ "$cached_written" -eq 0 ] || { echo "a check inside the module cache rewrote the cached libb's iyi.sum"; exit 1; }

# ── 5b. A package's tree may contain a symbolic link ─────────────────────
# What a repository stores for a link is its target text, and what a
# checkout makes of that depended on the machine: a link where the file
# system and the account allow one, and on Windows - Git for Windows sets
# `core.symlinks=false` - a plain file holding the text. `h2:` writes each
# entry's kind into what it hashes, so the same tag was `l` on Linux and
# `f` on Windows, and an `iyi.sum` made on one was refused on the other.
# The fetcher now checks out with `core.symlinks=false` everywhere: a link
# in a fetched package is a file holding its target's path, on every
# platform, and one tag is one hash. The hash below is that tree's, worked
# out apart from the compiler (SHA-256 of `<sha256> f <path>\n` for the
# four files in path order), and it is the same number on every runner.
#
# The entries are written into the index as git stores a link - mode
# 120000 over a blob that is the target text - and not with `ln -s`: Git
# Bash's needs Developer Mode or an administrator, the entry is the same
# either way, and so this step runs on Windows too.
step "a symbolic link in a package is fetched as a file holding its target, and hashes one way"
mkrepo work/linked
printf 'module example.test/user/linked
' > work/linked/iyi.mod
printf 'module linked

pub def linked_greeting : String
  "hello from linked"
end
' > work/linked/linked.iyi
git -C work/linked add -A
link_entry() { # link_entry <path in the package> <target text>
  link_blob="$(printf '%s' "$2" | git -C work/linked hash-object -w --no-filters --stdin)" &&
    git -C work/linked update-index --add --cacheinfo "120000,$link_blob,$1"
}
# `inner/loop -> ..` is the link a walk that followed links never came
# back from; `inner/alias.iyi` names a source file.
link_entry inner/loop .. && link_entry inner/alias.iyi ../linked.iyi || { echo "could not write the link entries"; exit 1; }
git -C work/linked commit -qm one && git -C work/linked tag v1.0.0
[ "$(git -C work/linked ls-files -s | grep -c '^120000')" -eq 2 ] || { echo "git did not store two symlinks, so this step proves nothing:"; git -C work/linked ls-files -s; exit 1; }
git clone -q --bare work/linked mirror/example.test/user/linked
mkdir -p linked_app
printf 'module example.test/user/linked_app
require example.test/user/linked v1.0.0
' > linked_app/iyi.mod
cat > linked_app/main.iyi <<'IYI'
import example.test/user/linked::{linked_greeting}

puts linked_greeting
IYI
if ! (cd linked_app && "$IYI" build main.iyi -o app) > linked.log 2>&1; then
  echo "a package with a symbolic link did not build:"
  tail -4 linked.log
  exit 1
fi
./linked_app/app | grep -q 'hello from linked' || { echo "the linked package answered:"; ./linked_app/app; exit 1; }
linked_checkout="$IYI_CACHE_DIR/mod/example.test/user/linked@v1.0.0"
[ -f "$linked_checkout/iyi.mod" ] || { echo "no linked@v1.0.0 checkout at $linked_checkout"; exit 1; }
for entry in inner/loop inner/alias.iyi; do
  if [ -L "$linked_checkout/$entry" ] || [ ! -f "$linked_checkout/$entry" ]; then
    echo "$entry was not checked out as a plain file:"
    ls -l "$linked_checkout/inner"
    exit 1
  fi
done
if [ "$(cat "$linked_checkout/inner/loop")" != ".." ] || [ "$(cat "$linked_checkout/inner/alias.iyi")" != "../linked.iyi" ]; then
  echo "the files checked out for the links do not hold their targets' paths:"
  head "$linked_checkout/inner/loop" "$linked_checkout/inner/alias.iyi"
  exit 1
fi
linked_h2="h2:b6b774d98f25e99124dcefc5643d092249ff0f3ad3fc9014a7c84f19abd0f122"
grep -q "^example.test/user/linked v1.0.0 $linked_h2\$" linked_app/iyi.sum || {
  echo "the linked package did not hash to $linked_h2, the hash of its four files on every platform:"
  cat linked_app/iyi.sum
  exit 1
}

# The kind is still in the hash, for the tree the fetcher did not make: a
# real link put where the fetched file was holds the same text and is not
# the same entry, so it cannot stand in for the file under the file's
# hash. And it is an entry, not a way in: `inner/loop -> ..` as a real
# link is hashed as a link, where following it never ended.
# Not on Windows, where this shell cannot make a link. Said, not skipped
# in silence.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    step "a real link put where a fetched file was: not on this platform (ln -s cannot make one here)"
    ;;
  *)
    step "a real link put where a fetched file was is refused, cycle and all"
    rm -f "$linked_checkout/inner/loop" "$linked_checkout/inner/alias.iyi"
    ln -s .. "$linked_checkout/inner/loop"
    ln -s ../linked.iyi "$linked_checkout/inner/alias.iyi"
    rm -f linked_app/app
    (cd linked_app && "$IYI" build main.iyi -o app) > relinked.log 2>&1
    relinked_status=$?
    rm -f "$linked_checkout/inner/loop" "$linked_checkout/inner/alias.iyi"
    printf '%s' '..' > "$linked_checkout/inner/loop"
    printf '%s' '../linked.iyi' > "$linked_checkout/inner/alias.iyi"
    if [ "$relinked_status" -eq 0 ]; then
      echo "links stood in for the files the package was fetched with, under the same hash"
      exit 1
    fi
    grep -q 'is not what it was' relinked.log || {
      echo "the links were refused for some other reason:"
      tail -5 relinked.log
      exit 1
    }
    if ! (cd linked_app && "$IYI" build main.iyi -o app) > unlinked.log 2>&1; then
      echo "the checkout put back as it was fetched did not build:"
      tail -5 unlinked.log
      exit 1
    fi
    ;;
esac

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
import example.test/user/liba::{greeting}
import helper::{shout}

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

# ── 5d. A requirement that moved is a change to every module ─────────────
# `--affected` selects by import closure, and a manifest is not a module:
# no closure holds `iyi.mod`, so bumping a dependency — the largest change
# a workspace can make, since every `import example.test/user/liba`
# resolves through the requirement it names — selected nothing. `iyi test
# --affected iyi.mod` answered "0 to run, 1 skipped: no test's imports
# reach the change", which is an agent bumping a version and being told
# there is nothing to run.
step "a changed requirement reaches every test and every consumer"
cat > app/pkg_test.iyi <<'IYI'
import example.test/user/liba::{greeting}

raise "greeting" unless greeting.starts_with?("hello from liba")
puts "ok"
IYI
(cd app && "$IYI" test --affected iyi.mod .) > affected_mod.log 2>&1 || {
  echo "the tests did not run for a changed manifest:"; tail -4 affected_mod.log; exit 1;
}
grep -q 'iyi.mod changed, so every test ran' affected_mod.log || {
  echo "a changed manifest did not turn the discount off:"; tail -3 affected_mod.log; exit 1;
}
grep -q '1 passed' affected_mod.log || {
  echo "the manifest run did not run the test:"; tail -3 affected_mod.log; exit 1;
}
(cd app && "$IYI" check --affected iyi.mod) > affected_check.log 2>&1 || {
  echo "check --affected iyi.mod failed:"; tail -4 affected_check.log; exit 1;
}
grep -q 'every module is a consumer' affected_check.log || {
  echo "a changed manifest named no consumers:"; tail -3 affected_check.log; exit 1;
}
# And the discount is still a discount: an ordinary file that exists and
# that no test imports selects nothing.
printf 'module untouched\n\npub def unused : Int32\n  1\nend\n' > app/untouched.iyi
(cd app && "$IYI" test --affected untouched.iyi .) > affected_file.log 2>&1
grep -q "no test's imports reach the change" affected_file.log || {
  echo "an ordinary changed file no longer narrows the run:"; tail -3 affected_file.log; exit 1;
}
rm -f app/pkg_test.iyi app/untouched.iyi

# ── 5e. A package's module has one name in its own build and a consumer's ─
# A consumer's build puts a package's modules under the package's name;
# the package's own build put them at the root, so `codec.iyi` of
# `iyi-web` was `::Codec` there and `::IyiWeb::Codec` here, and a `pub
# macro` - which expands in the caller's file and so names the module
# absolutely - had no spelling that built in both (#132). Both builds name
# it `::IyiWeb::Codec` now, from source and from an artifact. The old
# spelling still builds the package, with a warning that names the new
# one, and `iyi fix` makes the edit where the source writes it.
step "a package's module is one name in its own build and a consumer's"
mkdir -p onename/lib onename/app
printf 'module example.test/user/iyi-web\n' > onename/lib/iyi.mod
printf 'module codec\n\npub def shout(s : String) : String\n  s.upcase\nend\n' > onename/lib/codec.iyi
loud() { printf 'module dsl\n\npub import codec\n\npub macro loud(x)\n  %s.shout({{ x }})\nend\n' "$1" > onename/lib/dsl.iyi; }
loud ::IyiWeb::Codec
printf 'module inside\n\nimport dsl::*\n\nputs loud("inside")\n' > onename/lib/inside.iyi
printf 'module app\n\nrequire example.test/user/iyi-web v0.1.0 as web\n\nreplace example.test/user/iyi-web => ../lib\n' > onename/app/iyi.mod
printf 'module app\n\nimport web/dsl::*\n\nputs loud("consumer")\n' > onename/app/app.iyi
(cd onename/lib && "$IYI" run inside.iyi) > onename_inside.log 2>&1
grep -qx INSIDE onename_inside.log || { echo "::IyiWeb::Codec did not build in the package's own file:"; cat onename_inside.log; exit 1; }
(cd onename/app && "$IYI" run app.iyi) > onename_app.log 2>&1
grep -qx CONSUMER onename_app.log || { echo "::IyiWeb::Codec did not build in the consumer:"; cat onename_app.log; exit 1; }
(cd onename/lib && "$IYI" build --emit-iyimod mods inside.iyi -o inside) > onename_emit.log 2>&1 || {
  echo "the package's own emitting build failed:"; tail -4 onename_emit.log; exit 1;
}
"$IYI" mod dump onename/lib/mods/codec.iyimod | grep -q '^package *iyi_web$' || {
  echo "codec's artifact does not say the package name it was written under:"; "$IYI" mod dump onename/lib/mods/codec.iyimod | head -4; exit 1;
}
(cd onename/lib && "$IYI" run --use-iyimod mods inside.iyi) > onename_mods.log 2>&1
grep -qx INSIDE onename_mods.log || { echo "::IyiWeb::Codec did not build from the artifacts:"; cat onename_mods.log; exit 1; }
# The name the package's own build had: it still builds there, and warns.
loud ::Codec
(cd onename/lib && "$IYI" run inside.iyi) > onename_old.log 2>&1
grep -qx INSIDE onename_old.log || { echo "::Codec no longer builds the package:"; cat onename_old.log; exit 1; }
grep -q 'Warning: `::Codec` is `::IyiWeb::Codec`' onename_old.log || { echo "::Codec built without a warning:"; cat onename_old.log; exit 1; }
(cd onename/app && "$IYI" run app.iyi) > onename_old_app.log 2>&1 && { echo "::Codec built in a consumer"; exit 1; }
grep -q "Did you mean '::IyiWeb::Codec'" onename_old_app.log || { echo "the consumer's refusal does not name ::IyiWeb::Codec:"; cat onename_old_app.log; exit 1; }
printf 'import codec\n\nputs ::Codec.shout("fixed")\n' > onename/lib/direct.iyi
(cd onename/lib && "$IYI" fix direct.iyi) > onename_fix.log 2>&1 || { echo "iyi fix did not end clean:"; cat onename_fix.log; exit 1; }
grep -q '^puts ::IyiWeb::Codec.shout("fixed")$' onename/lib/direct.iyi || { echo "iyi fix did not write ::IyiWeb::Codec:"; cat onename/lib/direct.iyi; exit 1; }
echo "  ::IyiWeb::Codec in both builds and from artifacts; ::Codec warns in the package, is refused in the consumer, and iyi fix rewrites it"

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
printf 'import docd::{answer}\nputs answer\n' > docs/main.iyi
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
# The type's doc comment heads it, and String's sits above the file's
# `@[Unsafe("...")]` mark, which is above `class String` (SPEC.md III.13):
# the mark took the comment with it, and `iyi doc String` began at `class
# String` (bench/agent_loop.py step 72, windows-native in CI run
# 42472342266).
head -1 prelude-doc.txt | grep -q '^# Text' || { echo "String's doc comment does not head it, past the file's unsafe mark:"; head -3 prelude-doc.txt; exit 1; }
# A generic type's header carries its parameters once, as it is declared:
# the list was printed after a name that already held it, `class
# Array(T)(T)` and `tuple Tuple(*T)(T) < Value`.
"$IYI" doc Array > array-doc.txt 2>&1 || { cat array-doc.txt; exit 1; }
grep -qx 'class Array(T)' array-doc.txt || { echo "Array's header is not \`class Array(T)\`:"; grep -m1 '^class' array-doc.txt; exit 1; }
"$IYI" doc Tuple > tuple-doc.txt 2>&1 || { cat tuple-doc.txt; exit 1; }
grep -qx 'tuple Tuple(\*T) < Value' tuple-doc.txt || { echo "Tuple's header is not \`tuple Tuple(*T) < Value\`:"; grep -m1 '^tuple' tuple-doc.txt; exit 1; }
# A method, as the Int32 check below reads it: the doc carries the type's
# comments too, and the word in `String.new`'s ("the byte was allocated
# for that") failed the old `grep allocate` with no method in sight.
grep -q '^  def \(allocate\|crystal_type_id\|crystal_instance_type_id\)' prelude-doc.txt && { echo "the compiler's own method leaked into the doc"; exit 1; }
# The primitives the prelude declares are the type's own surface: `iyi doc
# Int32` answered with `abs` and `times` and no `+`, no `<`, no `to_i64`,
# because every primitive was filtered as if it were `allocate`.
"$IYI" doc Int32 > int-doc.txt 2>&1 || { cat int-doc.txt; exit 1; }
grep -q '  def +(other : Int32) : self' int-doc.txt || { echo "Int32's + is missing:"; head -20 int-doc.txt; exit 1; }
grep -q '  def <(other : Int32) : Bool' int-doc.txt || { echo "Int32's < is missing"; exit 1; }
grep -q '  def to_i64 : Int64' int-doc.txt || { echo "Int32's to_i64 is missing"; exit 1; }
grep -q '^  def \(allocate\|crystal_type_id\|crystal_instance_type_id\)' int-doc.txt && { echo "the compiler's own method leaked into Int32's doc"; exit 1; }
# An integer the prelude lists little of names the module that gives it the
# rest: `iyi doc UInt32` was an empty struct, read as "no arithmetic".
"$IYI" doc UInt32 > u32-doc.txt 2>&1 || { cat u32-doc.txt; exit 1; }
grep -q 'import std/int. gives UInt32' u32-doc.txt || { echo "UInt32's doc does not name std/int:"; cat u32-doc.txt; exit 1; }
"$IYI" doc Proc > proc-doc.txt 2>&1 || { cat proc-doc.txt; exit 1; }
grep -q '  def call(\*args : \*T) : R' proc-doc.txt || { echo "Proc's call is missing:"; cat proc-doc.txt; exit 1; }
"$IYI" doc Nope > nope.txt 2>&1 && { echo "an unknown type was documented"; exit 1; }
grep -q 'the prelude has no type Nope' nope.txt || { echo "the unknown type was not named:"; cat nope.txt; exit 1; }
"$IYI" doc prelude > index.txt 2>&1 || { cat index.txt; exit 1; }
grep -q '^class String' index.txt || { echo "the index lacks String:"; cat index.txt; exit 1; }
grep -q '^class Hash(K, V)' index.txt || { echo "the index lacks Hash(K, V):"; cat index.txt; exit 1; }
grep -q 'Regex\|Int128\|IyiHeap' index.txt && { echo "the index lists what the prelude does not offer:"; cat index.txt; exit 1; }
# An alias is its target's other name, and documents as the target does:
# `iyi doc IO` printed `alias IO` and `end`, with neither `IyiIO` nor one
# thing an IO can do.
"$IYI" doc IO > io-doc.txt 2>&1 || { cat io-doc.txt; exit 1; }
grep -qx 'alias IO = IyiIO' io-doc.txt || { echo "IO's target is not named:"; cat io-doc.txt; exit 1; }
grep -q '^  def flush' io-doc.txt || { echo "IO's surface is missing:"; cat io-doc.txt; exit 1; }

# ── 10b. `iyi doc app/greeter`: the spelling the language is built on ─────
# A module's path *is* its file's path (R-1, IV.6), and it is what
# `import` takes, what `mod context` prints as a header and what every
# error about a module names — but `iyi doc` took only a file path, so
# `iyi doc docs/docd` was a usage error about a module this same binary
# will ground an edit against.
step "iyi doc takes a module path, not only a file"
"$IYI" doc docs/docd > modpath-doc.txt 2>&1 || { cat modpath-doc.txt; exit 1; }
diff -u doc.txt modpath-doc.txt > modpath-diff.txt 2>&1 || {
  echo "the module path and the file answered differently:"
  head -10 modpath-diff.txt
  exit 1
}
# A subject spelled as a module path and found nowhere is a missing module,
# named, with where it was looked for: it was told to give "a module path
# (`iyi doc app/greeter`)", which is what it had given.
"$IYI" doc docs/nosuch > missing-mod.txt 2>&1 && { echo "a module that is not there was documented"; exit 1; }
grep -q "can't find module 'docs/nosuch'. .*docs/nosuch.iyi.* looked for under" missing-mod.txt || {
  echo "the refusal does not name the missing module:"; cat missing-mod.txt; exit 1; }
# And one subject a run: `iyi doc docs/docd extra junk` printed docd's
# surface at exit 0 and dropped the rest without a word.
"$IYI" doc docs/docd extra junk > extra-doc.txt 2>&1 && { echo "a second subject was dropped, exit 0"; exit 1; }
grep -q "'extra' is a second" extra-doc.txt || {
  echo "the second subject is not named:"; cat extra-doc.txt; exit 1; }
# A module whose source is not there and whose artifact is, in the
# workspace's `mods`, documents from the artifact, as every other verb
# reads it: with only `mods/app/twice.iyimod`, `iyi doc app/twice` was told
# to give "a module path".
mkdir -p docmods/app
printf 'module app/twice\n\n# Doubles it.\npub def twice(n : Int32) : Int32\n  n * 2\nend\n' > docmods/app/twice.iyi
printf 'import app/twice\n' > docmods/main.iyi
(cd docmods && "$IYI" doc app/twice) > twice-doc.txt 2>&1 || { cat twice-doc.txt; exit 1; }
(cd docmods && "$IYI" build --no-codegen --emit-iyimod mods main.iyi) > emit-mods.txt 2>&1 || { cat emit-mods.txt; exit 1; }
rm docmods/app/twice.iyi
(cd docmods && "$IYI" doc app/twice) > mods-doc.txt 2>&1 || {
  echo "the module in mods was not documented:"; cat mods-doc.txt; exit 1; }
diff -u twice-doc.txt mods-doc.txt > mods-diff.txt 2>&1 || {
  echo "the artifact in mods and the source answered differently:"; head -10 mods-diff.txt; exit 1; }

echo "workdir $WORK"
echo "packages gate: every step held"
exit 0
