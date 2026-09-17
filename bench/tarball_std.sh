#!/usr/bin/env bash
# The standard library, out of the thing people download.
#
#     bash bench/tarball_std.sh /tmp/unpacked
#
# `import std/text` is a program's line, not a checkout's: every `src/std/`
# module has to be inside the package under its own name, and it has to
# resolve out of the package with nothing else on the machine — no IYI_PATH,
# no CRYSTAL_PATH, no Crystal, no checkout.
#
# Two states this is written against, both real. 0.11.0 shipped
# `share/iyi/src/iyi` and nothing beside it, so `import std/enumerable`
# answered "can't find module" for everybody who downloaded it. And between
# `src/std/` being made and `install_iyi` naming it, the directory rode into
# the tarball as a passenger of the other language's library
# (`share/iyi/crystal/std/`) and resolved out of a library it is not part of.
# A gate that runs `hello.iyi` passes in both states, which is why this one
# reads the package instead.
#
# Takes the root of an unpacked tarball, or an `install_iyi` DESTDIR;
# defaults to `.build/iyi-package`. Exits non-zero if any check fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# A native compiler cannot resolve this shell's own path mapping, and the
# package root and every source handed to it are named through this one, so
# it is converted before anything is derived from it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) REPO="$(cygpath -m "$REPO")" ;;
esac
ROOT="${1:-$REPO/.build/iyi-package}"
IYI="$ROOT/bin/iyi"
SHIPPED="$ROOT/share/iyi/src/std"
SAMPLES="$ROOT/share/iyi/samples"
WORK="$(mktemp -d)"
# And the same for the scratch directory, which is where the compiler is
# told to write every binary it builds here.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) WORK="$(cygpath -m "$WORK")" ;;
esac

status=0

# The negative check below moves the shipped directory aside. It goes back
# on every exit path, including a failed build's, so a package this ran
# against is the package it found.
cleanup() {
  if [ -d "$SHIPPED.away" ]; then
    mv "$SHIPPED.away" "$SHIPPED"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "  FAIL: $*"
  status=1
}

if [ ! -x "$IYI" ]; then
  echo "bench/tarball_std.sh: no compiler at $IYI"
  echo "give it an unpacked tarball's root, or run make iyi-tarball first"
  exit 1
fi

# Built from a work directory that has no `std/` in it and with both names
# unset — the compiler falls back to CRYSTAL_PATH, so a stray one in the
# environment would answer for the package and this would stop proving
# anything. What is left to resolve the import is the binary's own
# `$ORIGIN/../share/iyi/src`.
build() { # build <name> <source>
  (
    cd "$WORK" &&
      env -u IYI_PATH -u CRYSTAL_PATH "$IYI" build --no-color -o "$WORK/$1" "$2"
  ) > "$WORK/$1.log" 2>&1
}

# The compiler's own first line is "Showing last frame", so the sentence
# worth printing is the one that names the failure.
first_error() {
  grep -m1 "^Error:" "$WORK/$1.log" 2>/dev/null ||
    grep -m1 -i "error" "$WORK/$1.log" 2>/dev/null ||
    tail -1 "$WORK/$1.log" 2>/dev/null
}

echo "== every src/std module is in the package, byte for byte"
count=0
first=""
for source in "$REPO"/src/std/*.iyi; do
  [ -f "$source" ] || continue
  name="$(basename "$source" .iyi)"
  count=$((count + 1))
  [ -n "$first" ] || first="$name"
  if [ ! -f "$SHIPPED/$name.iyi" ]; then
    fail "std/$name is not in $SHIPPED"
  elif ! cmp -s "$source" "$SHIPPED/$name.iyi"; then
    fail "std/$name in the package is not the file in src/std"
  fi
done
if [ "$count" -eq 0 ]; then
  fail "no modules in $REPO/src/std — nothing was checked"
elif [ "$status" -eq 0 ]; then
  echo "  $count modules, each under its own name in share/iyi/src/std"
fi

echo
echo "== each one imports and builds out of the package, then runs"
for source in "$REPO"/src/std/*.iyi; do
  [ -f "$source" ] || continue
  name="$(basename "$source" .iyi)"
  printf 'import std/%s\nputs "std/%s"\n' "$name" "$name" > "$WORK/probe_$name.iyi"
  if ! build "probe_$name" "$WORK/probe_$name.iyi"; then
    fail "import std/$name does not build out of the package: $(first_error "probe_$name")"
    continue
  fi
  got="$("$WORK/probe_$name" 2>&1)"
  if [ "$got" != "std/$name" ]; then
    fail "import std/$name built but printed '$got'"
  fi
done
if [ "$status" -eq 0 ]; then
  echo "  all $count built with IYI_PATH and CRYSTAL_PATH unset, and ran"
fi

echo
echo "== the shipped samples that import std build out of the package"
before="$status"
if [ -d "$SAMPLES" ]; then
  samples=0
  for sample in "$SAMPLES"/*.iyi; do
    [ -f "$sample" ] || continue
    grep -q "^import std/" "$sample" || continue
    samples=$((samples + 1))
    name="sample_$(basename "$sample" .iyi)"
    if ! build "$name" "$sample"; then
      fail "$(basename "$sample") does not build out of the package: $(first_error "$name")"
    fi
  done
  if [ "$samples" -eq 0 ]; then
    fail "no sample in $SAMPLES imports std — the samples are not the ones packaged"
  elif [ "$status" -eq "$before" ]; then
    echo "  $samples samples, built from where the tarball put them"
  fi
else
  echo "  (no samples in this root: an install_iyi DESTDIR ships none)"
fi

echo
echo "== and the checks fail when the package does not carry std"
probe="$first"
if [ ! -d "$SHIPPED" ]; then
  echo "  (nothing to move aside: $SHIPPED is already missing, said above)"
else
  mv "$SHIPPED" "$SHIPPED.away"
  if build "negative" "$WORK/probe_$probe.iyi"; then
    fail "import std/$probe built with $SHIPPED moved aside — something else in the package answers for it"
  elif grep -q "can't find module 'std/$probe'" "$WORK/negative.log"; then
    echo "  without it: can't find module 'std/$probe', which is what 0.11.0 said"
  else
    fail "it failed, but not with can't find module: $(first_error negative)"
  fi
  mv "$SHIPPED.away" "$SHIPPED"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the package carries the standard library, and it resolves out of it"
else
  echo "the package does not carry a usable standard library"
fi
exit "$status"
