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
# version already tagged is refused. A constant, a nested type, a type's
# macro, an enum member and an alias's target are surface; a requirement
# new on a trait is a major and a defaulted parameter appended a minor.
#
# Then what a move changes in what the project uses: an export whose
# signature moved is "changed" with the lines that write it - a comment
# that names it is not one - an export gone that nothing here writes says
# so, and a requirement the project's files do not import says nothing.
#
# Then two packages that each have a `util`: each package's modules live
# under its name - `Pa::Util`, `Pb::Util` - so both load and each package's
# own `Util` is its own; a name both export is ambiguous only where a file
# brings both into scope, and a package whose modules already begin with
# its name (`iyi_web/dsl`) is where it was, and a name written before -
# `Util` for `Pa::Util` - is an edit `iyi fix` applies.
#
# Then `reaches` as a limit: `require ... reaches nothing` builds a pure
# version, a `get` to one that opens a socket and declares C is refused
# with what it reaches and iyi.mod and iyi.sum untouched, widening the line
# lets it through and a later `get` keeps the clause, and a word that is not
# something a package reaches is refused where it is written.
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

# A build inside a cached checkout verifies and never writes there. The
# test was a string prefix, so on Windows a cache spelled in another case
# - a drive letter an editor lowercased - was not "inside", iyi.sum was
# written into the package, and every project using it was refused. Then
# it folded the case and still told an 8.3 short name from its long one:
# a CI runner's mktemp spells the cache `C:/Users/RUNNER~1/...`, the shell
# enters the checkout as `C:\Users\runneradmin\...`, and the file was
# written. Now `Sum.in_cache?` compares the two the way the file system
# names them. A file written anyway is taken back out, or libb is "not
# what it was" in every step after this one.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    checkout="$IYI_CACHE_DIR/mod/example.test/user/libb@v1.0.0"
    cache_spelled() { # cache_spelled <how> <IYI_CACHE_DIR>
      (cd "$checkout" && IYI_CACHE_DIR="$2" "$IYI" check libb.iyi) > cachecase.log 2>&1 ||
        fail "check in the cached libb, IYI_CACHE_DIR in $1, failed: $(cat cachecase.log)"
      if [ -e "$checkout/iyi.sum" ]; then
        fail "a check with the cache spelled in $1 wrote iyi.sum into the cached libb"
        rm -f "$checkout/iyi.sum"
      else
        echo "  a check in the cached libb, IYI_CACHE_DIR in $1: no iyi.sum written there"
      fi
    }
    cache_spelled "upper case" "$(echo "$IYI_CACHE_DIR" | tr '[:lower:]' '[:upper:]')"
    short="$(cygpath -m "$(cygpath -d "$IYI_CACHE_DIR" 2>/dev/null)" 2>/dev/null)"
    if [ -n "$short" ] && [ "$short" != "$IYI_CACHE_DIR" ]; then
      cache_spelled "its 8.3 short form" "$short"
    else
      echo "  (this volume gives $IYI_CACHE_DIR no 8.3 short form; that spelling is not asked)"
    fi
    ;;
esac

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

step "the build cache's rotation keeps package checkouts"
# The cache keeps its ten newest build directories, and `mod` was one more
# entry to it: eleven builds after a `get` the checkouts were gone, and a
# project that had just built answered "cannot fetch" with no network.
# Eleven newer directories stand in for the builds; one build rotates.
for i in 0 1 2 3 4 5 6 7 8 9 10; do mkdir -p "$IYI_CACHE_DIR/rotate-$i"; done
"$IYI" build -o rotate use.iyi > rotate.log 2>&1 || { fail "the build that rotates the cache failed"; cat rotate.log; }
[ -d "$IYI_CACHE_DIR/mod" ] || fail "the rotation deleted the package checkouts in $IYI_CACHE_DIR/mod"
IYI_MOD_MIRROR="$WORK/no-mirror" "$IYI" run use.iyi > rotate-run.log 2>&1 ||
  fail "with no mirror, the program did not build from the cache: $(cat rotate-run.log)"
rm -rf "$IYI_CACHE_DIR"/rotate-*
[ "$status" -eq 0 ] && echo "  eleven newer build directories and a build: mod kept, the program builds with no mirror"

step "a manifest saved with a byte order mark is read, and keeps it"
# As PowerShell 5.1's `Out-File -Encoding utf8` writes one. It was refused
# as "`\uFEFFmodule` is not a directive", and every verb with it.
mkdir -p "$WORK/bom" && cd "$WORK/bom" || exit 1
printf '\xef\xbb\xbfmodule example.test/user/bom\n' > iyi.mod
"$IYI" get example.test/user/liba@v1.1.0 > bom.log 2>&1 || { fail "get on a manifest with a BOM failed"; cat bom.log; }
[ "$(head -c 3 iyi.mod | od -An -tx1 | tr -d ' \n')" = "efbbbf" ] || fail "the BOM was not kept: $(od -c iyi.mod | head -2)"
grep -q '^require example.test/user/liba v1.1.0$' iyi.mod || fail "the BOM manifest did not get liba: $(cat iyi.mod)"
cd "$WORK/app" || exit 1
[ "$status" -eq 0 ] && echo "  read past, kept, and liba v1.1.0 required"

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

step "the prelude's own verbs do not fetch the project's packages"
# `doc String`, `doc prelude` and `init` compile the prelude alone, and did
# it as an empty file in the working directory, whose iyi.mod was resolved:
# a requirement not in the cache, with no network, answered "the prelude
# does not compile: cannot fetch ...".
mkdir -p "$WORK/offline" && cd "$WORK/offline" || exit 1
printf 'module example.test/user/offline\nrequire example.test/user/nope v1.0.0\n' > iyi.mod
for verb in "doc String" "doc prelude" "init tool tools/tool"; do
  # shellcheck disable=SC2086 # the verb's words are its arguments
  "$IYI" $verb > offline.log 2>&1 || fail "\`$verb\` in a project whose requirement cannot be fetched: $(head -2 offline.log)"
done
cd "$WORK/app" || exit 1
[ "$status" -eq 0 ] && echo "  doc String, doc prelude and init answer with a requirement that cannot be fetched"

step "what get refuses leaves iyi.mod as it was"
refused "a version that is not a tag" "has no v1.9.9; its versions are v1.0.0, v1.1.0, v1.2.0-rc.1, v1.3.0" \
  example.test/user/liba@v1.9.9
refused "a path that is no repository" "cannot list the versions of example.test/user/nope" \
  example.test/user/nope
refused "a version without its v" "does not start with \`v\`" example.test/user/liba@1.0.0
refused "the module itself" "is this module" example.test/user/app
refused "a path that is not a module path" "is not a module path" Example.test/User/liba
refused "-u beside a path" "takes no path" -u example.test/user/liba
# Two lines for one path: get moved the first, said the second was what it
# moved from - "downgraded v1.3.0 -> v1.1.0" - and built at v1.3.0.
mkdir -p "$WORK/dup" && cd "$WORK/dup" || exit 1
printf 'module example.test/user/dup\nrequire example.test/user/liba v1.0.0\nrequire example.test/user/liba v1.3.0\n' > iyi.mod
refused "a path required twice" "example.test/user/liba is already required, at v1.0.0" example.test/user/liba@v1.1.0
cd "$WORK/app" || exit 1
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

step "a manifest with mixed line endings: each line is found, and keeps its own"
# `init` writes LF and cmd's `echo require ... >> iyi.mod` appends CRLF. The
# file was split on CRLF alone, so the LF lines were one piece and the
# `require` in it was never found: get appended a second line, and tidy
# said "removed" and removed nothing. (`grep -U`: a Windows grep reads a
# line's CR away otherwise.)
mkdir -p "$WORK/mixed" && cd "$WORK/mixed" || exit 1
printf '# made by init\nmodule example.test/user/mixed\nrequire example.test/user/liba v1.1.0\r\n' > iyi.mod
"$IYI" get example.test/user/liba@v1.0.0 > mixed.log 2>&1 || { fail "get on a mixed manifest failed"; cat mixed.log; }
[ "$(grep -c 'example.test/user/liba' iyi.mod | tr -d ' ')" = "1" ] || fail "a mixed manifest gained a second liba line: $(cat iyi.mod)"
grep -qU $'^require example.test/user/liba v1.0.0\r$' iyi.mod && ! grep -qU $'module example.test/user/mixed\r' iyi.mod ||
  fail "the liba line did not move, or a line lost or gained its CR: $(od -c iyi.mod | tail -4)"
printf 'module example.test/user/mixt\nrequire example.test/user/libb v1.0.0\r\n' > iyi.mod
printf 'puts 1\n' > main.iyi
"$IYI" mod tidy > mixed-tidy.log 2>&1 || { fail "tidy on a mixed manifest failed"; cat mixed-tidy.log; }
[ -z "$(requires example.test/user/libb)" ] || fail "tidy said '$(cat mixed-tidy.log)' and left libb's line"
"$IYI" mod tidy --check > mixed-tidy2.log 2>&1 || fail "a tidied mixed manifest was not clean: $(cat mixed-tidy2.log)"
cd "$WORK/app" || exit 1
[ "$status" -eq 0 ] && echo "  get moved the one CRLF line among LF ones, and tidy removed one for good"

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

step "vet reports the program, not the packages it builds from"
# A package's unused export is its author's to act on, as std's is: `iyi
# vet` printed the cached libb's and the replacement's beside the program's
# own and exited 1, which no change to the program could fix.
printf '\npub def unused_here : Int32\n  1\nend\n' >> "$WORK/liba-local/liba.iyi"
printf 'import example.test/user/liba::{greeting}\nimport example.test/user/libb::*\n\ndef own_unused : Int32\n  1\nend\n\nputs greeting\n' > "$WORK/rapp/vet.iyi"
(cd "$WORK/rapp" && "$IYI" vet vet.iyi) > vet.log 2>&1
vet_code=$?
if [ "$vet_code" -ne 1 ] || ! grep -q "own_unused" vet.log || grep -q "unused_here\|number" vet.log; then
  fail "vet answered $vet_code, naming the packages' defs or not the program's:"; sed 's/^/    /' vet.log
else
  echo "  vet names the program's unused def, and neither the cached libb's nor the replacement's"
fi

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

step "a relative IYI_MOD_MIRROR is the working directory's"
# Handed to git as written, the path was read from the top of the git
# repository the project sits in - `outer` here - and was no repository.
mkdir -p "$WORK/outer/proj" && git init -q "$WORK/outer"
printf 'module example.test/user/proj\n' > "$WORK/outer/proj/iyi.mod"
(cd "$WORK/outer/proj" && IYI_MOD_MIRROR=../../mirror "$IYI" get example.test/user/liba@v1.1.0) > relmirror.log 2>&1 ||
  fail "a relative mirror inside a repository was not found: $(cat relmirror.log)"
grep -q "added example.test/user/liba v1.1.0" relmirror.log && echo "  ../../mirror from outer/proj: liba v1.1.0 added" ||
  fail "the relative mirror's get said: $(cat relmirror.log)"

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
bad_replace "a target spelled like a module path" liba-local "is not spelled as a directory"
bad_replace "a directory with a space, unquoted" "../liba local" "holds a space; a directory with one is written in double quotes"

step "a replacement in quotes may hold a space, and Windows' own spelling is one"
# On Windows `C:\Users\First Last\` is an ordinary place for a project, and
# the line was split on spaces: `=> "../greet lib"` was refused as "takes a
# path and a directory". `..\lib`, the native relative spelling every other
# verb takes, was refused as "'..\lib' is not a directory".
good_replace() { # good_replace <label> <target>
  printf 'module example.test/user/rapp\n\nrequire example.test/user/liba v1.0.0\n\nreplace example.test/user/liba => %s\n' "$2" > "$WORK/rapp/iyi.mod"
  (cd "$WORK/rapp" && "$IYI" run use.iyi) > good.log 2>&1
  if [ $? -ne 0 ] || ! grep -q "liba from beside the app" good.log; then
    fail "$1: not built from the replacement:"; sed 's/^/    /' good.log
  else
    echo "  $1: built from the replacement"
  fi
}
cp -r "$WORK/liba-local" "$WORK/liba local"
good_replace "\"../liba local\"" '"../liba local"'
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    good_replace "..\\liba-local" '..\liba-local'
    good_replace ".\\..\\liba-local" '.\..\liba-local'
    ;;
esac

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
# A module saved with a byte order mark, its header carrying a comment,
# its `pub` followed by a tab: the same surface, so a patch. Each was a
# module not found, its whole surface "gone", and a new major.
RELHDR="$WORK/relhdr"
mkrepo "$RELHDR"
cd "$RELHDR" || exit 1
printf 'module example.test/user/relhdr\n' > iyi.mod
printf 'module relhdr\n\npub def greeting : String\n  "one"\nend\n' > relhdr.iyi
git add -A && git commit -qm one && git tag v1.0.0
printf '\xef\xbb\xbfmodule relhdr # the library\n\npub\tdef greeting : String\n  "one"\nend\n' > relhdr.iyi
git commit -qam respelled
"$IYI" mod release > relhdr.log 2>&1 || fail "mod release failed on a respelled header: $(cat relhdr.log)"
grep -q "the next release is v1.0.1: the surface is as it was" relhdr.log ||
  fail "a BOM, a header comment and pub<TAB> changed the surface: $(cat relhdr.log)"
[ "$status" -eq 0 ] && echo "  a BOM, a comment on the header, pub<TAB>: the same surface, v1.0.1"

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

step "mod release measures from the last release, not a pre-release"
# v1.2.0-rc.1 removed what v1.1.0 exported: measured from the rc, the
# removal was never compared and v1.2.0 "held what changed". A release
# after an rc that only adds is a minor of v1.1.0's.
RELRC="$WORK/relrc"
mkrepo "$RELRC"
cd "$RELRC" || exit 1
printf 'module example.test/user/relrc\n' > iyi.mod
printf 'module relrc\n\npub def greeting : String\n  "one"\nend\n' > relrc.iyi
git add -A && git commit -qm one && git tag v1.1.0
printf 'module relrc\n\npub def other : String\n  "x"\nend\n' > relrc.iyi && git commit -qam rc && git tag v1.2.0-rc.1
printf '# the release\n' >> relrc.iyi && git commit -qam release
if "$IYI" mod release v1.2.0 > relrc.log 2>&1 || ! grep -q "compared with v1.1.0" relrc.log ||
  ! grep -q "so the next release is v2.0.0" relrc.log; then
  fail "a break made in an rc was released as a minor: $(cat relrc.log)"
fi
printf 'module relrc\n\npub def greeting : String\n  "one"\nend\n\npub def a : Int32\n  1\nend\n' > relrc.iyi
git commit -qam additive
"$IYI" mod release v1.2.0 > relrc2.log 2>&1 || fail "v1.2.0 after v1.1.0 and an rc, adding a def, was refused: $(cat relrc2.log)"
[ "$status" -eq 0 ] && echo "  an rc that removed: v2.0.0 from v1.1.0; a release that adds after it: v1.2.0"

step "mod release of a package inside another repository"
# The enclosing repository's tags are not the package's: a new package in
# one took its `v0.16.2` for its last release, checked the whole repository
# out to compare, and answered "v0.16.2 has no iyi.mod at ...". Uncommitted,
# it is told so; committed, with no tag that holds it, it has no release.
RELN="$WORK/reln"
mkrepo "$RELN"
cd "$RELN" || exit 1
printf 'outside\n' > README && git add -A && git commit -qm outer && git tag v0.16.2
mkdir -p pkg && cd pkg || exit 1
printf 'module example.test/user/pkg\n' > iyi.mod
printf 'module pkg\n\npub def f : Int32\n  1\nend\n' > pkg.iyi
if "$IYI" mod release > reln.log 2>&1 || ! grep -q "commit the package first" reln.log; then
  fail "an uncommitted package inside a repository was not told so: $(cat reln.log)"
fi
git add -A && git commit -qm pkg
"$IYI" mod release > reln2.log 2>&1 && grep -q "no release before this one" reln2.log ||
  fail "a package no tag holds was compared with one: $(cat reln2.log)"
[ "$status" -eq 0 ] && echo "  uncommitted: told so; committed under the repository's v0.16.2: no release before this one"

step "mod release: every name a consumer writes is surface"
# Each edit below is made to v1.0.0 alone and removes a name a consumer of
# v1.0.0 writes: a constant, a type nested in an exported one (gone, or
# made private), a type's macro, an enum member, what an alias names. Each
# was "the surface is as it was", v1.0.1, and the consumer of v1.0.0 then
# stopped on `undefined constant Kit::LIMIT` and the like. An `abstract
# def` new on a trait that was there breaks every impl of it, and was a
# minor; a defaulted parameter appended to a def breaks no call, and was a
# def gone and a new major at /v2. A constant's value moved is a patch.
RELK="$WORK/relk"
mkrepo "$RELK"
cd "$RELK" || exit 1
printf 'module example.test/user/kit\n' > iyi.mod
cat > kit.iyi <<'EOF'
module kit

pub trait Shape
  abstract def area : Int32
end

pub class Box
  getter v : Int32

  def initialize(@v : Int32)
  end

  macro def_twice(name)
    def {{name.id}} : Int32
      @v * 2
    end
  end

  pub class Inner
    def id : Int32
      1
    end
  end
end

pub LIMIT = 10

pub def scale(x : Int32) : Int32
  x * 2
end

pub enum Color
  Red
  Green
  Blue
end

pub alias Pair = Tuple(Int32, String)
EOF
git add -A && git commit -qm one && git tag v1.0.0
# relk <label> <answer> <sed script>: v1.0.0's kit.iyi edited by the script
# and committed is released as <answer>.
relk() {
  git checkout -q v1.0.0 -- kit.iyi
  sed -i.bak "$3" kit.iyi && rm -f kit.iyi.bak
  git commit -qam "$1"
  "$IYI" mod release > relk.log 2>&1 || fail "mod release failed on $1: $(cat relk.log)"
  grep -q "the next release is $2" relk.log || fail "$1 was not $2: $(cat relk.log)"
}
relk "a constant gone" "v2.0.0" '/^pub LIMIT = 10$/d'
grep -q "gone  kit: const LIMIT" relk.log || fail "the gone constant was not named: $(cat relk.log)"
relk "a nested type gone" "v2.0.0" 's/  pub class Inner/  pub class Inside/'
grep -q "gone  kit: class Box::Inner" relk.log || fail "the gone nested type was not named: $(cat relk.log)"
relk "a nested type made private" "v2.0.0" 's/  pub class Inner/  private class Inner/'
relk "a type's macro gone" "v2.0.0" 's/macro def_twice/macro def_double/'
grep -q "gone  kit: Box.macro def_twice(name)" relk.log || fail "the gone macro was not named: $(cat relk.log)"
relk "an enum member gone" "v2.0.0" '/^  Blue$/d'
grep -q "gone  kit: member Color::Blue" relk.log || fail "the gone member was not named: $(cat relk.log)"
relk "an alias retargeted" "v2.0.0" 's/Tuple(Int32, String)/Tuple(String, Int32)/'
relk "a requirement new on a trait" "v2.0.0" 's/  abstract def area : Int32/&\n  abstract def perimeter : Int32/'
grep -q "new   kit: Shape.abstract def perimeter : Int32 - a requirement" relk.log ||
  fail "the new requirement was not named as one: $(cat relk.log)"
relk "a defaulted parameter appended" "v1.1.0" 's/def scale(x : Int32)/def scale(x : Int32, by : Int32 = 2)/; s/  x \* 2/  x * by/'
grep -q "grown kit: def scale(x : Int32) : Int32 -> def scale(x : Int32, by : Int32 = 2) : Int32" relk.log ||
  fail "the grown def was not named: $(cat relk.log)"
relk "a constant's value moved" "v1.0.1" 's/^pub LIMIT = 10$/pub LIMIT = 11/'
[ "$status" -eq 0 ] && echo "  a constant, a nested type, a type's macro, a member, an alias's target gone, a trait's requirement new: v2.0.0; a defaulted parameter: v1.1.0; a value: v1.0.1"

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

step "two packages' util modules are two modules"
for p in pa pb; do
  mkrepo "$WORK/work/$p"
  printf 'module example.test/user/%s\n' "$p" > "$WORK/work/$p/iyi.mod"
  printf 'module util\n\npub def who : String\n  "%s"\nend\n' "$p" > "$WORK/work/$p/util.iyi"
  printf 'module %s\n\nimport util\n\npub def name : String\n  Util.who\nend\n' "$p" > "$WORK/work/$p/$p.iyi"
  git -C "$WORK/work/$p" add -A && git -C "$WORK/work/$p" commit -qm one
  git init -q --bare "$WORK/mirror/example.test/user/$p"
  (cd "$WORK" && publish "$p" v1.0.0)
done
mkdir -p "$WORK/capp2" && cd "$WORK/capp2" || exit 1
printf 'module example.test/user/capp2\nrequire example.test/user/pa v1.0.0\nrequire example.test/user/pb v1.0.0\n' > iyi.mod
printf 'import example.test/user/pa\nimport example.test/user/pb\nimport example.test/user/pa/util\nimport example.test/user/pb/util\n\nputs Pa.name\nputs Pb.name\nputs Pa::Util.who\nputs Pb::Util.who\n' > main.iyi
"$IYI" run main.iyi > coll.log 2>&1
[ "$(tr '\n' ' ' < coll.log)" = "pa pb pa pb " ] || fail "two packages' util modules did not stay two: $(cat coll.log)"
printf 'import example.test/user/pa/util::{who}\nimport example.test/user/pb/util::{who}\n\nputs who\n' > amb.iyi
"$IYI" run amb.iyi > amb.log 2>&1
grep -q "'who' is ambiguous here: it is exported by both Pa::Util and Pb::Util" amb.log ||
  fail "a name both util modules export was not called ambiguous by both names: $(cat amb.log)"
[ "$status" -eq 0 ] && echo "  Pa::Util and Pb::Util both load, each package's Util is its own; who from both: ambiguous by name"
# The name a program wrote before 0.15.2 is an edit away: `Util` of pa's
# `util` is `Pa::Util`, the error says so as a suggested edit, and `iyi
# fix` applies it.
mkdir -p "$WORK/capp3" && cd "$WORK/capp3" || exit 1
printf 'module example.test/user/capp3\nrequire example.test/user/pa v1.0.0\n' > iyi.mod
printf 'import example.test/user/pa/util\n\nputs Util.who\n' > main.iyi
"$IYI" check -f json main.iyi > old.json 2>&1
grep -q '"replacement":"Pa::Util"' old.json || fail "the old name got no edit to its new one: $(cat old.json)"
"$IYI" fix main.iyi > oldfix.log 2>&1 && grep -q "puts Pa::Util.who" main.iyi && [ "$("$IYI" run main.iyi 2>&1)" = "pa" ] ||
  fail "iyi fix did not move the old name: $(cat oldfix.log main.iyi)"
"$IYI" mod context main.iyi > ctx.log 2>&1
grep -q "^# qualified, the module is Pa::Util" ctx.log || fail "mod context did not say the package module's qualified name: $(head -5 ctx.log)"
"$IYI" doc example.test/user/pa/util > doc.log 2>&1 && grep -q "^pub def who : String" doc.log ||
  fail "iyi doc did not take a package module path: $(cat doc.log)"
[ "$status" -eq 0 ] && echo "  Util written before 0.15.2: the error carries Pa::Util and iyi fix applies it; mod context says Pa::Util, doc takes the package path"

step "reaches: what a package may touch, as a limit"
mkdir -p "$WORK/lapp" && cd "$WORK/lapp" || exit 1
printf 'module example.test/user/lapp\nrequire example.test/user/libr v1.0.0 reaches nothing\n' > iyi.mod
printf 'import example.test/user/libr::{version}\n\nputs version\n' > main.iyi
"$IYI" run main.iyi > lim1.log 2>&1 && grep -q "^1.0.0$" lim1.log || fail "a pure version under reaches nothing did not build: $(cat lim1.log)"
cp iyi.mod iyi.mod.before; cp iyi.sum iyi.sum.before
if "$IYI" get example.test/user/libr@v1.1.0 > lim2.log 2>&1 ||
   ! grep -q "example.test/user/libr v1.1.0 reaches std/socket, C, which its line in iyi.mod does not allow" lim2.log; then
  fail "a get past reaches nothing was not refused by what it reaches: $(cat lim2.log)"
fi
cmp -s iyi.mod iyi.mod.before && cmp -s iyi.sum iyi.sum.before || fail "a refused get changed iyi.mod or iyi.sum"
printf 'module example.test/user/lapp\nrequire example.test/user/libr v1.0.0 reaches std/socket, C\n' > iyi.mod
"$IYI" get example.test/user/libr@v1.1.0 > lim3.log 2>&1 || fail "a get inside the widened limit was refused: $(cat lim3.log)"
grep -qx "require example.test/user/libr v1.1.0 reaches std/socket, C" iyi.mod || fail "get did not keep the reaches clause: $(grep require iyi.mod)"
printf 'module example.test/user/lapp\nrequire example.test/user/libr v1.1.0 reaches std/sockt, Files\n' > iyi.mod
"$IYI" run main.iyi > lim4.log 2>&1
grep -q "\`Files\` is not something a package reaches" lim4.log || fail "a word that is not a reach was not refused: $(cat lim4.log)"
[ "$status" -eq 0 ] && echo "  reaches nothing: v1.0.0 builds, v1.1.0 refused as std/socket, C with nothing written; widened: allowed and kept"

step "a package's sum is the same on every platform"
# SHA-1 over each file's path and committed bytes (sum.cr), so the sum is
# the tag's and not the machine's: on Windows the path of a file in a
# directory went in with `\`, and the bytes were the checkout's, which
# Git for Windows' default `core.autocrlf=true` writes with CRLF - an
# `iyi.sum` made on Linux was refused there as tampering. The package also
# says `* text=auto` in its `.gitattributes`, which has git write its text
# files with `core.eol` - CRLF on Windows by default - whatever autocrlf
# says. Recomputed here from the tag itself, with a global git config that
# asks for CRLF both ways, which the fetcher's KEEP_BYTES both undo.
mkrepo "$WORK/work/libn"
# Its own commit keeps the LF it was written with, quietly: the machine's
# git may ask for CRLF, and warns of it under `text=auto`.
git -C "$WORK/work/libn" config core.autocrlf false
mkdir -p "$WORK/work/libn/sub"
printf 'module example.test/user/libn\n' > "$WORK/work/libn/iyi.mod"
printf 'module libn\n\npub def two : Int32\n  2\nend\n' > "$WORK/work/libn/libn.iyi"
printf 'module libn/sub/extra\n\npub def three : Int32\n  3\nend\n' > "$WORK/work/libn/sub/extra.iyi"
printf '* text=auto\n' > "$WORK/work/libn/.gitattributes"
git -C "$WORK/work/libn" add -A && git -C "$WORK/work/libn" commit -qm one
git init -q --bare "$WORK/mirror/example.test/user/libn"
(cd "$WORK" && publish libn v1.0.0)
expected="$(
  cd "$WORK/work/libn" &&
  for f in $(git ls-tree -r --name-only v1.0.0 | LC_ALL=C sort); do
    printf '%s\0' "$f"; git show "v1.0.0:$f"; printf '\0'
  done | sha1sum | cut -c1-40
)"
# Both: autocrlf for every file, eol for a `text` one (KEEP_BYTES).
printf '[core]\n\tautocrlf = true\n\teol = crlf\n' > "$WORK/crlf.gitconfig"
mkdir -p "$WORK/napp" && cd "$WORK/napp" || exit 1
printf 'module example.test/user/napp\n' > iyi.mod
GIT_CONFIG_GLOBAL="$WORK/crlf.gitconfig" "$IYI" get example.test/user/libn > sum.log 2>&1 || fail "get libn failed: $(cat sum.log)"
got="$(awk '$1 == "example.test/user/libn" { print $3 }' iyi.sum)"
[ "$got" = "s1:$expected" ] || fail "libn's sum is $got, where the tag's bytes and paths make s1:$expected"
[ "$status" -eq 0 ] && echo "  s1:$expected, from the tag's paths and bytes, with a CRLF-asking git"

step "a module in a subdirectory reads the manifest at the root its header names"
# `greet/greeter.iyi` declares `module greet/greeter`, so its root is the
# directory above `greet/`, and iyi.mod is there. `run main.iyi` built it,
# and every verb asked of the module itself read the manifest beside it:
# `check` said "no requirement covers 'example.test/user/liba'", the test
# beside it "does not build", `check --affected` "3 consumer(s) checked, 2
# broke", and `mod context` "does not resolve".
mkdir -p "$WORK/sapp/greet" && cd "$WORK/sapp" || exit 1
printf 'module example.test/user/sapp\nrequire example.test/user/liba v1.1.0\n' > iyi.mod
printf 'module greet/greeter\n\nimport example.test/user/liba\n\npub def hello : String\n  "greeter says " + Liba.greeting\nend\n' > greet/greeter.iyi
printf 'module greet/greeter_test\n\nimport greet/greeter\n\nassert Greet::Greeter.hello == "greeter says liba 1.1.0", "hello"\n' > greet/greeter_test.iyi
printf 'import greet/greeter\n\nputs Greet::Greeter.hello\n' > main.iyi
"$IYI" run main.iyi > sub-run.log 2>&1 && grep -q "greeter says liba 1.1.0" sub-run.log || fail "the entry did not build: $(cat sub-run.log)"
"$IYI" check greet/greeter.iyi > sub-check.log 2>&1 || fail "check of the module alone: $(cat sub-check.log)"
(cd greet && "$IYI" check greeter.iyi) > sub-check2.log 2>&1 || fail "check from inside greet/: $(cat sub-check2.log)"
"$IYI" test > sub-test.log 2>&1 && grep -q "^1 passed, 0 failed" sub-test.log || fail "the test beside the module: $(cat sub-test.log)"
"$IYI" check --affected greet/greeter.iyi > sub-aff.log 2>&1 && grep -q "^3 consumer(s) checked, all compile" sub-aff.log ||
  fail "check --affected of the module: $(cat sub-aff.log)"
"$IYI" mod context greet/greeter.iyi > sub-ctx.log 2>&1 && grep -q "def greeting : String" sub-ctx.log ||
  fail "mod context of the module: $(head -5 sub-ctx.log)"
[ "$status" -eq 0 ] && echo "  greet/greeter.iyi: check, its test, check --affected and mod context resolve liba through the root's iyi.mod"

echo
if [ "$status" -eq 0 ]; then
  echo "iyi get: every step held"
else
  echo "iyi get: a step failed"
fi
exit $status
