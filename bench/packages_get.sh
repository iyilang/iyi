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
sed -i.bak 's/1.2.0-rc.1/1.3.0/' "$WORK/work/liba/liba.iyi" && rm -f "$WORK/work/liba/liba.iyi.bak"
git -C "$WORK/work/liba" commit -qam four && (cd "$WORK" && publish liba v1.3.0)
"$IYI" get -u > get4.log 2>&1 || { fail "get -u failed"; cat get4.log; }
[ "$(requires example.test/user/liba)" = "v1.3.0" ] || fail "-u left liba at '$(requires example.test/user/liba)'"
grep -q "upgraded example.test/user/liba v1.0.0 -> v1.3.0" get4.log || fail "the upgrade was not said: $(cat get4.log)"
grep -q "example.test/user/libb is already at v1.0.0" get4.log || fail "libb's standing was not said: $(cat get4.log)"
"$IYI" run use.iyi > run2.log 2>&1 || { fail "the program did not build after -u"; cat run2.log; }
grep -q "liba 1.3.0" run2.log || fail "after -u the program ran '$(cat run2.log)'"

step "what get refuses leaves iyi.mod as it was"
refused "a version that is not a tag" "has no v9.9.9; its versions are v1.0.0, v1.1.0, v1.2.0-rc.1, v1.3.0" \
  example.test/user/liba@v9.9.9
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

echo
if [ "$status" -eq 0 ]; then
  echo "iyi get: every step held"
else
  echo "iyi get: a step failed"
fi
exit $status
