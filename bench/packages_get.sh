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
printf 'import example.test/user/liba\nusing example.test/user/liba::{greeting}\nputs greeting\n' > use.iyi

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
printf 'import example.test/user/liba/v2\nusing example.test/user/liba/v2::{greeting}\nputs greeting\n' > "$WORK/vapp/main.iyi"
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
printf 'import example.test/user/libb\nusing example.test/user/libb::{number}\nputs number\n' > b_test.iyi
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

echo
if [ "$status" -eq 0 ]; then
  echo "iyi get: every step held"
else
  echo "iyi get: a step failed"
fi
exit $status
