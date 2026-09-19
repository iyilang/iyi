#!/usr/bin/env bash
# Installing over an install leaves nothing of the old one behind.
#
# `install.sh` unpacks a tarball into a prefix. `tar` writes the files it
# carries and knows nothing about the ones the release deleted, so an
# upgrade used to leave them lying in the prefix - and `share/iyi/crystal`
# is a library, not a pile of files: `crystal/dwarf.cr` requires
# `./dwarf/**`, so a file a release removed is still *required* by the
# glob that outlived it.
#
# That is measured, not imagined. On a machine that had upgraded in
# place, `crystal/dwarf/line_numbers.cr` from an older release stayed
# behind and every `--crystal` build died with:
#
#     Error: undefined constant FORM
#
# naming a file inside the install that the person never wrote and cannot
# find in the repository. The fresh-install gate beside this one could
# never see it: it installs into an empty directory, which is the path
# only a first-time user takes.
#
# So this gate takes the other path. It installs, plants a file of the
# exact shape that broke it - a `.cr` under the library that does not
# compile and that a `**` require will reach - installs again, and asks
# for two things: the planted file is gone, and a `--crystal` program
# still builds out of the prefix.
#
# Teeth: against the commit before the fix, both fail - the file survives
# and the build dies on it.
#
#   bash bench/install_upgrade.sh <directory holding the tarball>
#
# The directory is what the release job writes and what CI's clean room
# already has: one `iyi-<version>-<target>.tar.gz` and a `SHA256SUMS`
# beside it.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
dist="${1:-$here/.build}"

shopt -s nullglob
tarballs=("$dist"/iyi-*.tar.gz)
shopt -u nullglob
if [ ${#tarballs[@]} -eq 0 ]; then
  echo "install upgrade: no iyi-*.tar.gz in $dist, so this checked nothing"
  exit 1
fi
# A release directory holds one; a build directory holds every tarball
# ever built there, and the one this run means is the newest.
newest="${tarballs[0]}"
for candidate in "${tarballs[@]}"; do
  if [ "$candidate" -nt "$newest" ]; then
    newest="$candidate"
  fi
done
tarball="$(basename "$newest")"
version="${tarball#iyi-}"
version="${version%-*-*.tar.gz}"
echo "install upgrade: $tarball"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
prefix="$work/prefix"

# The installer verifies what it downloads, so it needs a SHA256SUMS. A
# release directory arrives with one; a build directory does not, and the
# line this run needs is the one for the tarball above - checksumming
# every tarball a build directory has ever held is half a gigabyte of
# reading for one line. The file is written beside the archive, where the
# installer looks.
# Computed here rather than copied from the release directory: the step
# before this one in CI corrupts that file on purpose, to prove the
# installer refuses a tarball that does not match it. This gate is about
# what an upgrade leaves behind, so it gives the installer a checksum
# that is true of the archive it is about to unpack.
cp "$newest" "$work/$tarball"
if command -v sha256sum > /dev/null 2>&1; then
  (cd "$work" && sha256sum "$tarball") > "$work/SHA256SUMS"
elif command -v shasum > /dev/null 2>&1; then
  (cd "$work" && shasum -a 256 "$tarball") > "$work/SHA256SUMS"
else
  echo "install upgrade: neither sha256sum nor shasum is here, and the installer verifies"
  exit 1
fi

export IYI_RELEASE_URL="file://$work"
export IYI_VERSION="$version"

failures=0
step() {
  if [ "$2" = "ok" ]; then
    printf 'install upgrade ok   %s  %s\n' "$1" "${3:-}"
  else
    printf 'install upgrade FAIL %s  %s\n' "$1" "${3:-}"
    failures=$((failures + 1))
  fi
}

# A program of the kind a stale library file breaks, to prove the bite
# rather than only the tidiness.
cat > "$work/compat.cr" <<'PROG'
require "json"
puts({"answer" => 42}.to_json)
PROG

stale_path="share/iyi/crystal/crystal/dwarf/gone_in_the_next_release.cr"

# The shape that broke a real machine: a source file under the library,
# in a directory something requires with a glob, that does not compile.
plant() {
  mkdir -p "$(dirname "$prefix/$stale_path")"
  cat > "$prefix/$stale_path" <<'STALE'
# A file an older release shipped and this one does not. `crystal/dwarf.cr`
# requires `./dwarf/**`, so leaving it behind is not untidiness: it is a
# compile error in every program that reaches the library.
module Crystal::DWARF
  record LeftBehind, format : A_CONSTANT_THAT_IS_NOT_THERE
end
STALE
}

# `--no-codegen`, and the reason is the room this runs in: a `--crystal`
# program links Crystal's runtime, which wants bdw-gc, and the clean room
# is a machine with nothing on it - that is its whole claim. The question
# here is whether the *library* is whole, and the front end answers it:
# a file a release deleted is a compile error, not a link error.
builds() {
  env -u IYI_PATH -u CRYSTAL_PATH "$prefix/bin/iyi" build --crystal \
      --no-codegen "$work/compat.cr" > "$1" 2>&1
}

install_again() {
  IYI_PREFIX="$prefix" sh "$here/install.sh" > "$1" 2>&1 ||
    { cat "$1"; echo "install upgrade: an install failed"; exit 1; }
}

# ── The upgrade every machine that has iyi today will take ─────────────
#
# An install from before this script wrote down what it owns. There is no
# list to remove, so the library directory - which iyi owns whole - is
# replaced. This is the path that was broken: the machine this gate was
# written on had `crystal/dwarf/line_numbers.cr` from an older release
# still in it and could not build a `--crystal` program at all.
install_again "$work/first.log"
rm -f "$prefix/share/iyi/installed-files"
plant

if builds "$work/poisoned.log"; then
  step "a stale library file breaks a --crystal build" "FAIL" \
       "it built anyway, so this gate is no longer watching what it says"
else
  step "a stale library file breaks a --crystal build" "ok" \
       "$(grep -o 'Error.*' "$work/poisoned.log" | head -n 1 | cut -c1-60)"
fi

install_again "$work/second.log"
if [ -e "$prefix/$stale_path" ]; then
  step "an install with no file list is replaced, not merged into" "FAIL" \
       "the planted file is still there"
else
  step "an install with no file list is replaced, not merged into" "ok" \
       "the planted file is gone"
fi

if builds "$work/after.log"; then
  step "and a --crystal program compiles out of the prefix" "ok" \
       "the library is whole again"
else
  step "and a --crystal program compiles out of the prefix" "FAIL" \
       "$(tail -n 3 "$work/after.log" | tr '\n' ' ' | cut -c1-140)"
fi

# ── And the upgrade from an install this script wrote ──────────────────
#
# Here the file *is* one the previous release shipped, so it is in the
# list that install wrote, and removing exactly the list is what takes it
# away. Adding the path by hand is not cheating: it is what the older
# install's own `tar -tzf` would have recorded.
plant
echo "$stale_path" >> "$prefix/share/iyi/installed-files"
install_again "$work/third.log"

if [ -e "$prefix/$stale_path" ]; then
  step "a file the last release shipped and this one does not is removed" \
       "FAIL" "the planted file is still there"
else
  step "a file the last release shipped and this one does not is removed" \
       "ok" "removed by the list the last install wrote"
fi

# What the list must *not* do: reach outside the prefix or take a file no
# install of iyi's ever wrote.
mine="$prefix/share/iyi/my-notes.txt"
echo "a person's own file, under the install" > "$mine"
outside="$work/not-iyi.txt"
echo "not iyi's" > "$outside"
printf '../not-iyi.txt\n/etc/passwd\n' >> "$prefix/share/iyi/installed-files"
install_again "$work/fourth.log"
if [ -f "$outside" ]; then
  step "a list that climbs out of the prefix is refused" "ok" \
       "the file beside the prefix is untouched"
else
  step "a list that climbs out of the prefix is refused" "FAIL" \
       "$outside was removed"
fi

# The upgrade has to leave a working install, not just a clean one.
if env -u IYI_PATH -u CRYSTAL_PATH "$prefix/bin/iyi" run \
     "$prefix/share/iyi/samples/hello.iyi" > "$work/hello.log" 2>&1; then
  step "and an iyi program still runs" "ok" \
       "$(head -n 1 "$work/hello.log" | cut -c1-40)"
else
  step "and an iyi program still runs" "FAIL" \
       "$(tail -n 2 "$work/hello.log" | tr '\n' ' ' | cut -c1-120)"
fi

# A manifest is what makes the removal exact rather than a directory
# wipe: the prefix is shared with whatever else lives under it.
owned=0
if [ -f "$prefix/share/iyi/installed-files" ]; then
  owned="$(grep -c . "$prefix/share/iyi/installed-files" | tr -d ' ')"
fi
# The binary is the one path every install of iyi has, so a list without
# it is a list nothing wrote - which is how this step tells "the
# installer recorded what it unpacked" from "a file happens to be here".
if [ "$owned" -gt 100 ] && grep -qx 'bin/iyi' "$prefix/share/iyi/installed-files"; then
  step "the install says what it owns" "ok" "$owned paths, bin/iyi among them"
else
  step "the install says what it owns" "FAIL" \
       "$owned path(s), and bin/iyi is $(grep -qx 'bin/iyi' "$prefix/share/iyi/installed-files" 2>/dev/null && echo in || echo "not in") the list"
fi

if [ "$failures" -gt 0 ]; then
  echo "install upgrade: $failures step(s) failed"
  exit 1
fi
echo "install upgrade: an install over an install is the install, not both"
