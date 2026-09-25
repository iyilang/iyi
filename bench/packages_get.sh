#!/usr/bin/env bash
# `iyi get`: a requirement added, moved, or brought up to date (SPEC.md
# III.7), against a mirror of bare repositories so the network is not a
# dependency of the gate.
#
#     bash bench/packages_get.sh
#
# Proves, in order: a path alone gets the latest *release* and not a later
# pre-release; the manifest is edited in place - its comments stay, one
# line per requirement; a downgrade is a downgrade and says so; a module
# another one outbids is named; `-u` finds a tag published after the first
# `get`, and the program builds against it; and every refusal - no
# manifest, a version that is not there, a path that is not a repository,
# a version spelled without `v`, the module itself - leaves `iyi.mod` as it
# was, byte for byte.
#
# Then `replace`: a required module built from a directory beside the
# project - directly and through another module's requirement - whose
# edits are built without `iyi.sum` refusing them, which the sum never
# records; one in a dependency's own manifest is ignored; and a target
# that is not there, not the module, or not spelled as a directory is
# refused by name.
#
# Then `iyi mod tidy`: a package imported without a `require` gets one -
# at the version the graph already builds when it has it; a `require`
# nothing imports is removed, unless it raises a version another module
# pulls in; `iyi.sum` loses the versions nothing builds; `--check` writes
# nothing and exits 1; and an import no repository provides is refused.
#
# Then short names: `require <path> <version> as <name>` - written by
# `get --as`, kept by `get -u`, counted by `tidy` - lets a file write
# `import web::*` for the package, and that line alone loads it and brings
# its names into scope.
# A package's own short names are its files', whatever its consumer calls
# the same word; a short name that is also the project's own directory,
# or is not a word, or is `std`, is refused by name.
#
# Then reach: `get` names what a new module touches outside the language
# and what a moved one reaches now or no longer does - a std module that
# calls C through another std module it imports, C declared inside a
# platform's `{% if %}`, a linked library - while a pure std import, and
# what the package's tests import, are not reach; `mod reach` lists the
# whole build's.
#
# Then commits no tag names: a repository with no version tag is got at
# its default branch as `v0.0.0-<time>-<hash>`, and `-u` follows the
# branch; `@main` after a tag is the pseudo-version above it, which `-u`
# does not take back down to the tag; `@<commit>` of a tagged commit is
# the tag; and a pseudo-version whose time or hash is not its commit's, or
# a ref that is not there, is refused.
#
# Then `iyi mod release`: a package's surface at HEAD against its last
# tag. A new def is a minor and a patch that says less is refused; a def
# gone is a major, at the path `/v2`, and the manifest has to say it first;
# before v1 a break is a minor. An example program beside the library is
# nobody's surface, a release written with `using` is still read, and a
# version already tagged is refused.
#
# Then what a move changes in what the project uses: an export whose
# signature moved is "changed" with the lines that write it - a comment
# that names it is not one - an export gone that nothing here writes says
# so, and a requirement the project's files do not import says nothing.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a cache
# or mirror named `/tmp/tmp.X` is a directory it cannot open.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac
trap 'rm -rf "$WORK"' EXIT
export IYI_CACHE_DIR="$WORK/cache"
export IYI_MOD_MIRROR="$WORK/mirror"
cd "$WORK" || exit 1

status=0
fail() { echo "  FAIL: $1"; status=1; }
step() { echo "== $1"; }
mkrepo() { git init -q "$1" && git -C "$1" config user.email t@t && git -C "$1" config user.name t; }
# A tag, published to the mirror the way a push would be.
publish() { # publish <repo> <tag>
  git -C "work/$1" tag "$2"
  git -C "mirror/example.test/user/$1" fetch -q "$WORK/work/$1" "refs/tags/$2:refs/tags/$2"
}

# ── The fixture ─────────────────────────────────────────────────────────
mkrepo work/liba
printf 'module example.test/user/liba\n' > work/liba/iyi.mod
printf 'module liba\n\npub def greeting : String\n  "liba 1.0.0"\nend\n' > work/liba/liba.iyi
git -C work/liba add -A && git -C work/liba commit -qm one
mkrepo work/libb
printf 'module example.test/user/libb\nrequire example.test/user/liba v1.1.0\n' > work/libb/iyi.mod
printf 'module libb\n\npub def number : Int32\n  7\nend\n' > work/libb/libb.iyi
git -C work/libb add -A && git -C work/libb commit -qm one
mkdir -p mirror/example.test/user
git init -q --bare mirror/example.test/user/liba
git init -q --bare mirror/example.test/user/libb
publish liba v1.0.0
sed -i.bak 's/1.0.0/1.1.0/' work/liba/liba.iyi && rm -f work/liba/liba.iyi.bak
git -C work/liba commit -qam two && publish liba v1.1.0
sed -i.bak 's/1.1.0/1.2.0-rc.1/' work/liba/liba.iyi && rm -f work/liba/liba.iyi.bak
git -C work/liba commit -qam three && publish liba v1.2.0-rc.1
publish libb v1.0.0

"$IYI" init example.test/user/app app > init.log 2>&1 || { echo "init failed:"; cat init.log; exit 1; }
cd app || exit 1
cp iyi.mod iyi.mod.init
printf 'import example.test/user/liba::{greeting}\nputs greeting\n' > use.iyi

# requires <path>: the version iyi.mod requires it at, or nothing.
requires() { awk -v p="$1" '$1 == "require" && $2 == p { print $3 }' iyi.mod; }
# refused <label> <phrase> <args...>: a refusal that names <phrase> and
# leaves iyi.mod exactly as it was.
refused() {
  local label="$1" phrase="$2"
  shift 2
  cp iyi.mod iyi.mod.before
  "$IYI" get "$@" > refused.log 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    fail "$label: get answered 0"
  elif ! grep -qF -- "$phrase" refused.log; then
    fail "$label: refused without '$phrase':"
    sed 's/^/    /' refused.log
  elif ! cmp -s iyi.mod iyi.mod.before; then
    fail "$label: refused, and iyi.mod changed anyway"
  else
    echo "  $label: refused, iyi.mod untouched"
  fi
}

step "a path alone is its latest release, not a later pre-release"
"$IYI" get example.test/user/liba > get1.log 2>&1 || { fail "get failed"; cat get1.log; }
[ "$(requires example.test/user/liba)" = "v1.1.0" ] || fail "iyi.mod requires liba at '$(requires example.test/user/liba)', not v1.1.0"
grep -q "added example.test/user/liba v1.1.0" get1.log || fail "the addition was not said: $(cat get1.log)"
grep -q "example.test/user/liba v1.1.0 s1:" iyi.sum 2>/dev/null || fail "iyi.sum has no entry for liba v1.1.0"
# Everything init wrote is still there, byte for byte, with the one line
# after it. Bytes rather than lines: init ends its manifest without a
# newline, which `wc -l` counts one short.
head -c "$(wc -c < iyi.mod.init | tr -d ' ')" iyi.mod | cmp -s - iyi.mod.init || fail "the manifest's own lines moved"
[ "$status" -eq 0 ] && echo "  liba v1.1.0 required, the manifest's comments kept, iyi.sum written"

step "a version moves the one line, down as well as up"
"$IYI" get example.test/user/liba@v1.0.0 > get2.log 2>&1 || { fail "get @v1.0.0 failed"; cat get2.log; }
[ "$(grep -c 'example.test/user/liba' iyi.mod | tr -d ' ')" = "1" ] || fail "liba has more than one line now"
[ "$(requires example.test/user/liba)" = "v1.0.0" ] || fail "liba is at '$(requires example.test/user/liba)'"
grep -q "downgraded example.test/user/liba v1.1.0 -> v1.0.0" get2.log || fail "the downgrade was not said: $(cat get2.log)"

step "a module another one outbids is named"
"$IYI" get example.test/user/libb > get3.log 2>&1 || { fail "get libb failed"; cat get3.log; }
[ "$(requires example.test/user/libb)" = "v1.0.0" ] || fail "libb is at '$(requires example.test/user/libb)'"
grep -q "example.test/user/liba builds at v1.1.0: iyi.mod names v1.0.0" get3.log || fail "the raise was not said: $(cat get3.log)"
"$IYI" run use.iyi > run1.log 2>&1 || { fail "the program did not build"; cat run1.log; }
grep -q "liba 1.1.0" run1.log || fail "the program ran liba '$(cat run1.log)', not what MVS selected"

step "-u finds a tag published since, and the program builds against it"
# First asked with --check: the new tag is found from the tags alone, said,
# and nothing is written until the same `get` runs without it.
sed -i.bak 's/1.2.0-rc.1/1.3.0/' "$WORK/work/liba/liba.iyi" && rm -f "$WORK/work/liba/liba.iyi.bak"
git -C "$WORK/work/liba" commit -qam four && (cd "$WORK" && publish liba v1.3.0)
cp iyi.mod iyi.mod.before
"$IYI" get -u --check > check.log 2>&1
check_code=$?
[ "$check_code" -eq 1 ] || fail "get -u --check answered $check_code with liba behind"
grep -q "would upgrade example.test/user/liba v1.0.0 -> v1.3.0" check.log || fail "--check did not list liba: $(cat check.log)"
grep -q "example.test/user/libb is at v1.0.0, its latest" check.log || fail "--check did not say libb is current: $(cat check.log)"
cmp -s iyi.mod iyi.mod.before || fail "get --check wrote iyi.mod"
"$IYI" get -u > get4.log 2>&1 || { fail "get -u failed"; cat get4.log; }
"$IYI" get -u --check > check2.log 2>&1 || fail "get -u --check found something behind after -u: $(cat check2.log)"
[ "$(requires example.test/user/liba)" = "v1.3.0" ] || fail "-u left liba at '$(requires example.test/user/liba)'"
grep -q "upgraded example.test/user/liba v1.0.0 -> v1.3.0" get4.log || fail "the upgrade was not said: $(cat get4.log)"
grep -q "example.test/user/libb is already at v1.0.0" get4.log || fail "libb's standing was not said: $(cat get4.log)"
"$IYI" run use.iyi > run2.log 2>&1 || { fail "the program did not build after -u"; cat run2.log; }
grep -q "liba 1.3.0" run2.log || fail "after -u the program ran '$(cat run2.log)'"

step "a major version past 1 is the same repository under a /vN path"
# liba's repository publishes v2.0.0, whose manifest names the module
# `example.test/user/liba/v2`. The plain path must not cross into it, the
# suffixed one is fetched from the same repository, and a line that pairs
# a path with another major's version is refused naming the right path.
printf 'module example.test/user/liba/v2\n' > "$WORK/work/liba/iyi.mod"
sed -i.bak 's/1.3.0/2.0.0/' "$WORK/work/liba/liba.iyi" && rm -f "$WORK/work/liba/liba.iyi.bak"
git -C "$WORK/work/liba" commit -qam five && (cd "$WORK" && publish liba v2.0.0)
"$IYI" get -u --check > major-check.log 2>&1 || fail "the plain path saw v2.0.0 as its own: $(cat major-check.log)"
mkdir -p "$WORK/vapp"
printf 'module example.test/user/vapp\n' > "$WORK/vapp/iyi.mod"
printf 'import example.test/user/liba/v2::{greeting}\nputs greeting\n' > "$WORK/vapp/main.iyi"
(cd "$WORK/vapp" && "$IYI" get example.test/user/liba/v2) > major.log 2>&1 || { fail "get of the /v2 path failed"; cat major.log; }
grep -q "added example.test/user/liba/v2 v2.0.0" major.log || fail "the /v2 path got: $(cat major.log)"
(cd "$WORK/vapp" && "$IYI" run main.iyi) > major-run.log 2>&1 || { fail "the /v2 program did not build"; cat major-run.log; }
grep -q "liba 2.0.0" major-run.log || fail "the /v2 program ran '$(cat major-run.log)'"
refused "a plain path at a v2 version" "is example.test/user/liba/v2: a major version past 1 is its own module path" \
  example.test/user/liba@v2.0.0
printf 'module example.test/user/wapp\nrequire example.test/user/liba/v2 v1.1.0\n' > "$WORK/vapp/iyi.mod"
(cd "$WORK/vapp" && "$IYI" run main.iyi) > major-bad.log 2>&1
if [ $? -eq 0 ] || ! grep -q "is major version 2, and v1.1.0 is not; v1.1.0 is example.test/user/liba's" major-bad.log; then
  fail "a /v2 line at a v1 version was not refused by name: $(cat major-bad.log)"
fi
[ "$status" -eq 0 ] && echo "  the plain path stays on v1; /v2 fetched from liba's repository at v2.0.0; mismatched lines refused"

step "what get refuses leaves iyi.mod as it was"
refused "a version that is not a tag" "has no v1.9.9; its versions are v1.0.0, v1.1.0, v1.2.0-rc.1, v1.3.0" \
  example.test/user/liba@v1.9.9
refused "a path that is no repository" "cannot list the versions of example.test/user/nope" \
  example.test/user/nope
refused "a version without its v" "does not start with \`v\`" example.test/user/liba@1.0.0
refused "the module itself" "is this module" example.test/user/app
refused "a path that is not a module path" "is not a module path" Example.test/User/liba
refused "-u beside a path" "takes no path" -u example.test/user/liba
(cd "$WORK" && "$IYI" get example.test/user/liba) > nomanifest.log 2>&1
if [ $? -eq 0 ] || ! grep -q "there is no iyi.mod" nomanifest.log; then
  fail "a directory without iyi.mod was not named"
else
  echo "  no iyi.mod here: refused, and init named"
fi

step "a manifest written with CRLF keeps CRLF"
mkdir -p "$WORK/crlf"
printf 'module example.test/user/crlf\r\n\r\nrequire example.test/user/libb v1.0.0\r\n' > "$WORK/crlf/iyi.mod"
(cd "$WORK/crlf" && "$IYI" get example.test/user/liba@v1.1.0) > crlf.log 2>&1 || { fail "get on a CRLF manifest failed"; cat crlf.log; }
if [ "$(grep -c $'\r$' "$WORK/crlf/iyi.mod")" != "$(wc -l < "$WORK/crlf/iyi.mod" | tr -d ' ')" ]; then
  fail "a line lost its CR:"; od -c "$WORK/crlf/iyi.mod" | tail -4
else
  echo "  every line ends CRLF, the new one too"
fi

step "replace builds a required module from a directory"
mkdir -p "$WORK/liba-local" "$WORK/rapp"
printf 'module example.test/user/liba\n' > "$WORK/liba-local/iyi.mod"
printf 'module liba\n\npub def greeting : String\n  "liba from beside the app"\nend\n' > "$WORK/liba-local/liba.iyi"
# liba is required through libb as well as directly: the replacement is
# the module, wherever the graph reaches it.
printf 'module example.test/user/rapp\n\nrequire example.test/user/libb v1.0.0\nrequire example.test/user/liba v1.0.0\n\nreplace example.test/user/liba => ../liba-local\n' > "$WORK/rapp/iyi.mod"
cp use.iyi "$WORK/rapp/use.iyi"
(cd "$WORK/rapp" && "$IYI" run use.iyi) > replace1.log 2>&1 || { fail "the replaced build failed"; cat replace1.log; }
grep -q "liba from beside the app" replace1.log || fail "the replacement did not build: $(cat replace1.log)"
grep -q "example.test/user/liba" "$WORK/rapp/iyi.sum" 2>/dev/null && fail "iyi.sum recorded the replaced module"
grep -q "example.test/user/libb v1.0.0 s1:" "$WORK/rapp/iyi.sum" 2>/dev/null || fail "iyi.sum lost the fetched module"
sed -i.bak 's/beside the app/beside the app, edited/' "$WORK/liba-local/liba.iyi" && rm -f "$WORK/liba-local/liba.iyi.bak"
(cd "$WORK/rapp" && "$IYI" run use.iyi) > replace2.log 2>&1 || { fail "an edit in the replacement was refused"; cat replace2.log; }
grep -q "beside the app, edited" replace2.log || fail "the edit did not build: $(cat replace2.log)"
(cd "$WORK/rapp" && "$IYI" get example.test/user/liba@v1.1.0) > replace3.log 2>&1 || { fail "get on a replaced module failed"; cat replace3.log; }
grep -q "example.test/user/liba builds from ../liba-local, which replaces it" replace3.log || fail "get did not say the line moves nothing: $(cat replace3.log)"
[ "$status" -eq 0 ] && echo "  built from ../liba-local, directly and through libb; edits build; iyi.sum never records it"

step "a dependency's own replace is ignored"
mkrepo "$WORK/work/libc"
printf 'module example.test/user/libc\nrequire example.test/user/liba v1.1.0\nreplace example.test/user/liba => ../elsewhere\n' > "$WORK/work/libc/iyi.mod"
printf 'module libc\n\npub def c : Int32\n  3\nend\n' > "$WORK/work/libc/libc.iyi"
git -C "$WORK/work/libc" add -A && git -C "$WORK/work/libc" commit -qm one
git init -q --bare "$WORK/mirror/example.test/user/libc"
(cd "$WORK" && publish libc v1.0.0)
mkdir -p "$WORK/capp"
printf 'module example.test/user/capp\nrequire example.test/user/libc v1.0.0\n' > "$WORK/capp/iyi.mod"
cp use.iyi "$WORK/capp/use.iyi"
(cd "$WORK/capp" && "$IYI" run use.iyi) > replace4.log 2>&1 || { fail "a dependency's replace redirected the build"; cat replace4.log; }
grep -q "liba 1.1.0" replace4.log || fail "the program ran '$(cat replace4.log)', not liba's tag"
[ "$status" -eq 0 ] && echo "  libc's replace of liba is libc's business: the build fetched liba v1.1.0"

step "a replacement that is not the module is refused by name"
bad_replace() { # bad_replace <label> <target> <phrase>
  printf 'module example.test/user/rapp\n\nrequire example.test/user/liba v1.0.0\n\nreplace example.test/user/liba => %s\n' "$2" > "$WORK/rapp/iyi.mod"
  (cd "$WORK/rapp" && "$IYI" run use.iyi) > bad.log 2>&1
  if [ $? -eq 0 ] || ! grep -qF -- "$3" bad.log; then
    fail "$1: not refused with '$3':"; sed 's/^/    /' bad.log
  else
    echo "  $1: refused"
  fi
}
bad_replace "a directory that is not there" ../nowhere "does not exist"
mkdir -p "$WORK/nomod"
bad_replace "a directory with no iyi.mod" ../nomod "has no iyi.mod"
mkdir -p "$WORK/othermod" && printf 'module example.test/user/other\n' > "$WORK/othermod/iyi.mod"
bad_replace "a directory holding another module" ../othermod "says it is 'example.test/user/other'"
bad_replace "a target spelled like a module path" liba-local "is not a directory"

step "mod tidy says what the source imports"
mkdir -p "$WORK/tapp"
cd "$WORK/tapp" || exit 1
printf 'module example.test/user/tapp\n\nrequire example.test/user/liba v1.3.0\nrequire example.test/user/libb v1.0.0\n' > iyi.mod
cp "$WORK/app/use.iyi" main.iyi
# Another module beside it, with a manifest of its own, is not this one's
# source: what it imports is not a requirement here.
mkdir -p nested && printf 'module example.test/user/nested\n' > nested/iyi.mod
printf 'import example.test/user/libc\nputs 1\n' > nested/main.iyi
"$IYI" build main.iyi -o main > tidy-build.log 2>&1 || { fail "the tidy fixture did not build"; cat tidy-build.log; }
printf 'example.test/user/liba v1.0.0 s1:0000000000000000000000000000000000000000\n' >> iyi.sum
cp iyi.mod iyi.mod.before && cp iyi.sum iyi.sum.before
"$IYI" mod tidy --check > tidy-check.log 2>&1
check_status=$?
[ "$check_status" -eq 1 ] || fail "--check answered $check_status with a change due"
grep -q "would remove example.test/user/libb v1.0.0: nothing imports it" tidy-check.log || fail "--check did not name the unused line: $(cat tidy-check.log)"
# Two: the version nothing builds, and libb's, which goes with its line.
grep -q "would drop 2 iyi.sum entries" tidy-check.log || fail "--check did not name the stale sums: $(cat tidy-check.log)"
cmp -s iyi.mod iyi.mod.before && cmp -s iyi.sum iyi.sum.before || fail "--check wrote something"
"$IYI" mod tidy > tidy1.log 2>&1 || { fail "tidy failed"; cat tidy1.log; }
[ -z "$(requires example.test/user/libb)" ] || fail "libb is still required"
[ "$(requires example.test/user/liba)" = "v1.3.0" ] || fail "liba moved to '$(requires example.test/user/liba)'"
[ -z "$(requires example.test/user/libc)" ] || fail "the nested module's import was taken for this one's"
grep -q "v1.0.0" iyi.sum && fail "the stale sum entry is still there"
grep -q "example.test/user/liba v1.3.0 s1:" iyi.sum || fail "the sum lost what builds"
"$IYI" mod tidy --check > tidy-clean.log 2>&1 || fail "a tidy manifest was not clean: $(cat tidy-clean.log)"
grep -q "say what the source imports" tidy-clean.log || fail "a clean tidy did not say so"
[ "$status" -eq 0 ] && echo "  libb removed, liba kept, the stale sum dropped; --check wrote nothing, then found nothing"

step "mod tidy adds an import's module at the version that builds, and keeps a raising line"
printf 'import example.test/user/libb::{number}\nputs number\n' > b_test.iyi
rm main.iyi
"$IYI" mod tidy > tidy2.log 2>&1 || { fail "tidy failed"; cat tidy2.log; }
[ "$(requires example.test/user/libb)" = "v1.0.0" ] || fail "the imported libb was not added: $(cat tidy2.log)"
# liba is imported by nothing now, and libb asks for v1.1.0: the line
# naming v1.3.0 is what builds v1.3.0, so it stays and is said.
[ "$(requires example.test/user/liba)" = "v1.3.0" ] || fail "the raising line was removed"
grep -q "kept example.test/user/liba v1.3.0: nothing imports it, but without the line another module's requirement would build v1.1.0" tidy2.log \
  || fail "the kept line was not explained: $(cat tidy2.log)"
mkdir -p "$WORK/t2" && cd "$WORK/t2" || exit 1
printf 'module example.test/user/t2\nrequire example.test/user/libb v1.0.0\n' > iyi.mod
printf 'import example.test/user/liba\nputs 1\n' > main.iyi
"$IYI" mod tidy > tidy3.log 2>&1 || { fail "tidy failed"; cat tidy3.log; }
[ "$(requires example.test/user/liba)" = "v1.1.0" ] || fail "liba was added at '$(requires example.test/user/liba)', not the v1.1.0 the graph builds"
[ -z "$(requires example.test/user/libb)" ] || fail "libb stayed, imported by nothing"
[ "$status" -eq 0 ] && echo "  libb added; liba's raising line kept; an indirect import required at v1.1.0, the version it builds at"

step "mod tidy refuses an import no repository provides"
printf 'import example.test/user/nosuch/thing\nputs 1\n' > missing.iyi
cp iyi.mod iyi.mod.before
"$IYI" mod tidy > tidy4.log 2>&1
if [ $? -eq 0 ] || ! grep -q "no module provides example.test/user/nosuch/thing" tidy4.log; then
  fail "the unprovided import was not refused: $(cat tidy4.log)"
elif ! cmp -s iyi.mod iyi.mod.before; then
  fail "the refusal changed iyi.mod"
else
  echo "  refused, naming every prefix tried, iyi.mod untouched"
fi

step "a short name: iyi.mod writes the path once, files write the name"
mkdir -p "$WORK/sapp" && cd "$WORK/sapp" || exit 1
printf 'module example.test/user/sapp\n' > iyi.mod
"$IYI" get example.test/user/liba@v1.1.0 --as web > short1.log 2>&1 || { fail "get --as failed"; cat short1.log; }
grep -qx "require example.test/user/liba v1.1.0 as web" iyi.mod || fail "get --as wrote: $(grep require iyi.mod)"
# One line: the import loads the package under its short name and brings
# its names into scope.
printf 'import web::*\n\nputs greeting\n' > main.iyi
"$IYI" run main.iyi > short2.log 2>&1 || { fail "the short name did not build"; cat short2.log; }
grep -q "liba 1.1.0" short2.log || fail "the short-named program ran '$(cat short2.log)'"
"$IYI" get -u > short3.log 2>&1 || { fail "get -u failed"; cat short3.log; }
grep -qx "require example.test/user/liba v1.3.0 as web" iyi.mod || fail "get -u lost the short name: $(grep require iyi.mod)"
# Whatever else tidy would do - -u left a sum entry behind - it must not
# take the line a short name imports for unused.
"$IYI" mod tidy --check > short4.log 2>&1
grep -q "remove example.test/user/liba" short4.log && fail "tidy took the short-named line for unused: $(cat short4.log)"
[ "$status" -eq 0 ] && echo "  get --as wrote it, import web::* built, -u kept it, tidy counted it"

step "a package's short names are its own"
mkrepo "$WORK/work/libs"
# libs calls liba `a`; the app below calls libb `a`. Each file means its
# own manifest's `a`.
printf 'module example.test/user/libs\nrequire example.test/user/liba v1.1.0 as a\n' > "$WORK/work/libs/iyi.mod"
printf 'module libs\n\nimport a::*\n\npub def relay : String\n  greeting\nend\n' > "$WORK/work/libs/libs.iyi"
git -C "$WORK/work/libs" add -A && git -C "$WORK/work/libs" commit -qm one
git init -q --bare "$WORK/mirror/example.test/user/libs"
(cd "$WORK" && publish libs v1.0.0)
mkdir -p "$WORK/papp" && cd "$WORK/papp" || exit 1
printf 'module example.test/user/papp\nrequire example.test/user/libs v1.0.0\nrequire example.test/user/libb v1.0.0 as a\n' > iyi.mod
printf 'import example.test/user/libs::*\nimport a::*\n\nputs relay\nputs number\n' > main.iyi
"$IYI" run main.iyi > pkgshort.log 2>&1 || { fail "a package's own short name did not build"; cat pkgshort.log; }
grep -q "liba 1.1.0" pkgshort.log && grep -q "^7$" pkgshort.log || fail "the two a's crossed: $(cat pkgshort.log)"
[ "$status" -eq 0 ] && echo "  libs' a is liba, the app's a is libb, and both built"

step "a short name that is not one is refused by name"
cd "$WORK/sapp" || exit 1
mkdir -p web && printf 'module web\n' > web.iyi
"$IYI" run main.iyi > clash.log 2>&1
if [ $? -eq 0 ] || ! grep -q "names two modules: \`web\` is iyi.mod's short name for example.test/user/liba" clash.log; then
  fail "a short name that is also a local module was not refused: $(cat clash.log)"
else
  echo "  a short name that is also this project's module: refused"
fi
rm -rf web web.iyi
refused "an upper-case short name" "is not a short name" example.test/user/libb --as Web
refused "std as a short name" "\`std\` is iyi's standard library" example.test/user/libb --as std
refused "a short name already taken" "\`web\` already names example.test/user/liba" example.test/user/libb --as web

step "get says what a package reaches, and what an upgrade adds to it"
mkrepo "$WORK/work/libr"
printf 'module example.test/user/libr\n' > "$WORK/work/libr/iyi.mod"
printf 'module libr\n\nimport std/json::*\n\npub def version : String\n  "1.0.0"\nend\n' > "$WORK/work/libr/libr.iyi"
# A test's imports are the package author's, not the consumer's.
printf 'import std/file\n\nputs File.exists?("x")\n' > "$WORK/work/libr/libr_test.iyi"
git -C "$WORK/work/libr" add -A && git -C "$WORK/work/libr" commit -qm one
git init -q --bare "$WORK/mirror/example.test/user/libr"
(cd "$WORK" && publish libr v1.0.0)
# v1.1.0 reaches the network through std/http, and C behind a platform.
cat > "$WORK/work/libr/libr.iyi" <<'EOF'
module libr

import std/json::*
import std/http

{% if flag?(:linux) || !flag?(:linux) %}
  @[Link("m")]
  lib LibM
    fun cos(x : Float64) : Float64
  end
{% end %}

pub def version : String
  "1.1.0"
end
EOF
git -C "$WORK/work/libr" commit -qam two && (cd "$WORK" && publish libr v1.1.0)
printf 'module libr\n\nimport std/json::*\n\npub def version : String\n  "1.2.0"\nend\n' > "$WORK/work/libr/libr.iyi"
git -C "$WORK/work/libr" commit -qam three && (cd "$WORK" && publish libr v1.2.0)
mkdir -p "$WORK/rapp" && cd "$WORK/rapp" || exit 1
printf 'module example.test/user/rapp\n' > iyi.mod
"$IYI" get example.test/user/libr@v1.0.0 > reach1.log 2>&1 || { fail "get libr failed"; cat reach1.log; }
grep -q "example.test/user/libr v1.0.0, new: nothing outside the language" reach1.log ||
  fail "a pure package's reach was not said, or its test's std/file was counted: $(cat reach1.log)"
"$IYI" get example.test/user/libr@v1.1.0 > reach2.log 2>&1 || { fail "get libr@v1.1.0 failed"; cat reach2.log; }
grep -q "libr v1.0.0 -> v1.1.0: now reaches std/socket.*; links m; C LibM.cos" reach2.log ||
  fail "the upgrade's new reach was not said: $(cat reach2.log)"
grep -q "std/json" reach2.log && fail "a std module that calls nothing was counted as reach: $(cat reach2.log)"
"$IYI" mod reach > reach3.log 2>&1 || { fail "mod reach failed"; cat reach3.log; }
grep -q "^example.test/user/libr v1.1.0: std/socket.*; links m; C LibM.cos" reach3.log ||
  fail "mod reach did not list the build's reach: $(cat reach3.log)"
"$IYI" get example.test/user/libr@v1.2.0 > reach4.log 2>&1 || { fail "get libr@v1.2.0 failed"; cat reach4.log; }
grep -q "libr v1.1.0 -> v1.2.0: no longer reaches std/socket.*; links m; C LibM.cos" reach4.log ||
  fail "what the upgrade stopped reaching was not said: $(cat reach4.log)"
[ "$status" -eq 0 ] && echo "  new: nothing; v1.1.0 adds std/socket (through std/http), libm, LibM.cos; v1.2.0 drops them"

step "a commit no tag names is a pseudo-version"
# The committer times are fixed, so the order of the pseudo-versions is
# the order of the commits and not of the seconds the gate ran in.
at() { GIT_COMMITTER_DATE="$1" GIT_AUTHOR_DATE="$1" git -C "$WORK/work/libt" "${@:2}"; }
pseudo() { # pseudo <base> <rev>: the version iyi should write for <rev>
  local stamp hash
  stamp="$(TZ=UTC0 git -C "$WORK/work/libt" show -s --date=format-local:%Y%m%d%H%M%S --format=%cd "$2")"
  hash="$(git -C "$WORK/work/libt" rev-parse "$2" | cut -c1-12)"
  echo "$1$stamp-$hash"
}
push_main() { git -C "$WORK/work/libt" push -q "$WORK/mirror/example.test/user/libt" HEAD:refs/heads/main; }
mkrepo "$WORK/work/libt"
printf 'module example.test/user/libt\n' > "$WORK/work/libt/iyi.mod"
printf 'module libt\n\npub def word : String\n  "one"\nend\n' > "$WORK/work/libt/libt.iyi"
git -C "$WORK/work/libt" add -A && at "2026-03-01 10:00:00 +0300" commit -qm one
git init -q --bare "$WORK/mirror/example.test/user/libt"
git -C "$WORK/mirror/example.test/user/libt" symbolic-ref HEAD refs/heads/main
push_main
mkdir -p "$WORK/tapp" && cd "$WORK/tapp" || exit 1
printf 'module example.test/user/tapp\n' > iyi.mod
printf 'import example.test/user/libt::*\n\nputs word\n' > main.iyi
one="$(pseudo v0.0.0- HEAD)"
"$IYI" get example.test/user/libt > pseudo1.log 2>&1 || { fail "get of an untagged repository failed"; cat pseudo1.log; }
[ "$(requires example.test/user/libt)" = "$one" ] || fail "an untagged repository was written as '$(requires example.test/user/libt)', not $one"
[ "$("$IYI" run main.iyi 2>&1)" = "one" ] || fail "the pseudo-version did not build its commit"
grep -q "example.test/user/libt $one s1:" iyi.sum || fail "iyi.sum has no entry for $one"
sed -i.bak 's/"one"/"two"/' "$WORK/work/libt/libt.iyi" && rm -f "$WORK/work/libt/libt.iyi.bak"
at "2026-03-02 10:00:00 +0300" commit -qam two && push_main
two="$(pseudo v0.0.0- HEAD)"
"$IYI" get -u > pseudo2.log 2>&1 || { fail "get -u on a pseudo-version failed"; cat pseudo2.log; }
[ "$(requires example.test/user/libt)" = "$two" ] || fail "-u left libt at '$(requires example.test/user/libt)', not the branch's $two"
[ "$("$IYI" run main.iyi 2>&1)" = "two" ] || fail "-u's pseudo-version did not build the branch's commit"
[ "$status" -eq 0 ] && echo "  untagged: $one, then -u to $two, each building its commit"

git -C "$WORK/work/libt" tag v0.1.0 && git -C "$WORK/work/libt" push -q "$WORK/mirror/example.test/user/libt" v0.1.0
sed -i.bak 's/"two"/"three"/' "$WORK/work/libt/libt.iyi" && rm -f "$WORK/work/libt/libt.iyi.bak"
at "2026-03-03 10:00:00 +0300" commit -qam three && push_main
three="$(pseudo v0.1.1-0. HEAD)"
"$IYI" get example.test/user/libt@main > pseudo3.log 2>&1 || { fail "get @main failed"; cat pseudo3.log; }
[ "$(requires example.test/user/libt)" = "$three" ] || fail "@main after v0.1.0 was written as '$(requires example.test/user/libt)', not $three"
[ "$("$IYI" run main.iyi 2>&1)" = "three" ] || fail "@main did not build the branch's commit"
"$IYI" get -u > pseudo4.log 2>&1 || { fail "get -u past the latest tag failed"; cat pseudo4.log; }
[ "$(requires example.test/user/libt)" = "$three" ] || fail "-u took $three back down to '$(requires example.test/user/libt)'"
"$IYI" get "example.test/user/libt@$(git -C "$WORK/work/libt" rev-parse --short HEAD~1)" > pseudo5.log 2>&1 || { fail "get @<commit> failed"; cat pseudo5.log; }
[ "$(requires example.test/user/libt)" = "v0.1.0" ] || fail "the commit v0.1.0 tags was written as '$(requires example.test/user/libt)'"
[ "$status" -eq 0 ] && echo "  @main after v0.1.0: $three, kept by -u; the tagged commit is v0.1.0"

cp iyi.mod iyi.mod.good
# The time one second off: the hash is the commit's, and the line still lies.
forged="$(echo "$three" | sed -E 's/-0\.([0-9]{13})[0-9]-/-0.\10-/')"
[ "$forged" != "$three" ] || forged="$(echo "$three" | sed -E 's/-0\.([0-9]{13})[0-9]-/-0.\11-/')"
sed -i.bak "s/v0.1.0\$/$forged/" iyi.mod && rm -f iyi.mod.bak iyi.sum
if "$IYI" run main.iyi > forged.log 2>&1 || ! grep -q "is not that commit's version" forged.log; then
  fail "a pseudo-version with the wrong time was not refused: $(cat forged.log)"
else
  echo "  a pseudo-version whose time is not its commit's: refused"
fi
cp iyi.mod.good iyi.mod
refused "a ref that is not there" "has no \`nosuchbranch\`" example.test/user/libt@nosuchbranch

step "mod release: what the next tag has to be"
REL="$WORK/rel"
mkrepo "$REL"
# Entered through a symlink, as darwin's `/var` is `/private/var`: the
# working directory and git's top level are then two spellings of one place.
ln -s "$REL" "$WORK/rel-link" 2>/dev/null
cd "$WORK/rel-link" 2>/dev/null || cd "$REL" || exit 1
mkdir -p rel examples
printf 'module example.test/user/rel\n' > iyi.mod
printf 'module rel/util\n\npub def twice(n : Int32) : Int32\n  n * 2\nend\n' > rel/util.iyi
# The release before is written the way 0.14 wrote a module's names.
printf 'module rel\n\nimport rel/util\nusing rel/util::{twice}\n\npub def a : Int32\n  twice(1)\nend\n' > rel.iyi
printf 'import rel::*\n\nassert a == 2\n' > rel_test.iyi
git add -A && git commit -qm one && git tag v1.0.0
# The same surface in the one-keyword spelling, and an example program
# beside it that exports nothing: a patch.
printf 'module rel\n\nimport rel/util::{twice}\n\npub def a : Int32\n  twice(1)\nend\n' > rel.iyi
printf 'module examples/demo\n\nimport rel::*\n\nputs a\n' > examples/demo.iyi
git add -A && git commit -qm spelling
"$IYI" mod release > rel1.log 2>&1 || { fail "mod release failed on an unchanged surface"; cat rel1.log; }
grep -q "the next release is v1.0.1: the surface is as it was" rel1.log ||
  fail "a release written with using, respelled, was not the same surface: $(cat rel1.log)"
# A def new: a minor, and a patch is refused by name.
printf '\npub def b : Int32\n  3\nend\n' >> rel.iyi
git commit -qam b
if "$IYI" mod release v1.0.1 > rel2.log 2>&1 || ! grep -q "v1.0.1 is too small: something is new, so the next release is v1.1.0" rel2.log; then
  fail "a patch that hides a new def was not refused: $(cat rel2.log)"
fi
grep -q "new   rel: def b : Int32" rel2.log || fail "the new def was not named: $(cat rel2.log)"
"$IYI" mod release v1.1.0 > rel3.log 2>&1 || fail "v1.1.0 was refused for a new def: $(cat rel3.log)"
# A def gone: a major, at a path of its own.
sed -i.bak 's/pub def a : Int32/pub def a(n : Int32) : Int32/; s/  twice(1)/  twice(n)/' rel.iyi && rm -f rel.iyi.bak
git commit -qam break
if "$IYI" mod release v1.2.0 > rel4.log 2>&1 || ! grep -q "so the next release is v2.0.0, at the path example.test/user/rel/v2" rel4.log; then
  fail "a minor that hides a gone def was not refused: $(cat rel4.log)"
fi
grep -q "gone  rel: def a : Int32" rel4.log || fail "the gone def was not named: $(cat rel4.log)"
if "$IYI" mod release v2.0.0 > rel5.log 2>&1 || ! grep -q "is example.test/user/rel/v2: a major version past 1 is its own module path" rel5.log; then
  fail "v2.0.0 was accepted on a path without /v2: $(cat rel5.log)"
fi
printf 'module example.test/user/rel/v2\n' > iyi.mod && git commit -qam v2
"$IYI" mod release v2.0.0 > rel6.log 2>&1 || fail "v2.0.0 at the /v2 path was refused: $(cat rel6.log)"
grep -q "examples/demo" rel6.log && fail "an example program was counted as surface: $(cat rel6.log)"
if "$IYI" mod release v1.0.0 > rel7.log 2>&1; then fail "a version already tagged was accepted: $(cat rel7.log)"; fi
[ "$status" -eq 0 ] && echo "  respelled: patch; new def: minor, patch refused; gone def: v2 at /v2, refused until iyi.mod says it"

step "mod release before v1: a break is a minor"
REL0="$WORK/rel0"
mkrepo "$REL0"
cd "$REL0" || exit 1
printf 'module example.test/user/zero\n' > iyi.mod
printf 'module zero\n\npub def a : Int32\n  1\nend\n' > zero.iyi
git add -A && git commit -qm one && git tag v0.3.0
printf 'module zero\n\npub def c : Int32\n  1\nend\n' > zero.iyi && git commit -qam break
if "$IYI" mod release v0.3.1 > zero.log 2>&1 || ! grep -q "so the next release is v0.4.0" zero.log; then
  fail "a v0 patch that hides a break was not refused: $(cat zero.log)"
fi
"$IYI" mod release v0.4.0 > zero2.log 2>&1 || fail "v0.4.0 was refused for a v0 break: $(cat zero2.log)"
[ "$status" -eq 0 ] && echo "  v0.3.0 -> a def gone: v0.3.1 refused, v0.4.0 holds it"

step "get says what a move changes in what the project uses"
mkrepo "$WORK/work/libi"
printf 'module example.test/user/libi\n' > "$WORK/work/libi/iyi.mod"
printf 'module libi\n\npub def greeting : String\n  "hi"\nend\n\npub def old : Int32\n  1\nend\n\npub def keep : Int32\n  2\nend\n' > "$WORK/work/libi/libi.iyi"
git -C "$WORK/work/libi" add -A && git -C "$WORK/work/libi" commit -qm one
git init -q --bare "$WORK/mirror/example.test/user/libi"
(cd "$WORK" && publish libi v0.1.0)
printf 'module libi\n\npub def greeting(name : String) : String\n  "hi #{name}"\nend\n\npub def keep : Int32\n  2\nend\n\npub def fresh : Int32\n  3\nend\n' > "$WORK/work/libi/libi.iyi"
git -C "$WORK/work/libi" commit -qam two && (cd "$WORK" && publish libi v0.2.0)
mkdir -p "$WORK/iapp" && cd "$WORK/iapp" || exit 1
printf 'module example.test/user/iapp\n' > iyi.mod
printf 'import example.test/user/libi::{greeting, keep}\n\nputs greeting\nputs keep\n# greeting, in a comment\n' > main.iyi
"$IYI" get example.test/user/libi@v0.1.0 > imp0.log 2>&1 || { fail "get libi@v0.1.0 failed"; cat imp0.log; }
"$IYI" get -u > imp1.log 2>&1 || { fail "get -u of libi failed"; cat imp1.log; }
sed -n '/what the move changes/,$p' imp1.log > imp1.section
if ! grep -q "changed  libi: def greeting : String" imp1.section ||
   ! grep -q "now def greeting(name : String) : String" imp1.section ||
   [ "$(grep -c 'main.iyi:' imp1.section | tr -d ' ')" != "2" ] ||
   ! grep -q "main.iyi:1" imp1.section || ! grep -q "main.iyi:3" imp1.section; then
  fail "the changed export and the two lines that write it were not said: $(cat imp1.log)"
fi
grep -q "gone     libi: def old : Int32 - used nowhere here" imp1.section || fail "the unused gone export was not said: $(cat imp1.log)"
grep -q "and 1 new" imp1.section || fail "the new export was not counted: $(cat imp1.log)"
# The same move for a project that requires libi and imports none of it.
mkdir -p "$WORK/japp" && cd "$WORK/japp" || exit 1
printf 'module example.test/user/japp\n' > iyi.mod
printf 'puts 1\n' > main.iyi
"$IYI" get example.test/user/libi@v0.1.0 > jmp0.log 2>&1 && "$IYI" get -u > jmp1.log 2>&1 || { fail "get in japp failed"; cat jmp0.log jmp1.log; }
grep -q "what the move changes" jmp1.log && fail "a requirement nothing here imports was reported: $(cat jmp1.log)"
[ "$status" -eq 0 ] && echo "  greeting changed at main.iyi:1 and :3, the comment not; old gone, used nowhere; 1 new; an unimported requirement: silent"

echo
if [ "$status" -eq 0 ]; then
  echo "iyi get: every step held"
else
  echo "iyi get: a step failed"
fi
exit $status
