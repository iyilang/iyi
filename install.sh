#!/bin/sh
# Installs the latest iyi release into ~/.local (bin/, lib/, share/iyi/):
#
#   curl -fsSL https://raw.githubusercontent.com/iyilang/iyi/master/install.sh | sh
#
# IYI_PREFIX       where to unpack, default ~/.local; the tarball is relocatable
# IYI_VERSION      a release to pin, e.g. 0.21.0; default is the latest release
# IYI_RELEASE_URL  where the release's files are, default the GitHub release;
#                  an https:// URL, or a directory (file://), which is what CI
#                  points it at to install a tarball before it is released and
#                  how this script is gated
#
# POSIX sh, curl and tar are all it needs. The release is resolved by
# following GitHub's /releases/latest redirect, not the API, so there is
# no token and no rate limit in the way. The tarball is checked against
# the SHA256SUMS the release publishes beside it before anything is
# unpacked: what comes out of it reaches the linker, so a byte that is
# not the byte the release job wrote is refused rather than run. A
# SHA256SUMS that cannot be fetched is refused the same way, with nothing
# unpacked: every release from 0.12.0 on publishes one, so its absence is
# a broken release or a broken connection, not an old release.
#
# Every fetch over the network is HTTPS with TLS 1.2 or newer, redirects
# included; curl is told so, and refuses anything else.
#
# The whole script is one function, called on the last line: `curl | sh`
# runs what has arrived so far, and a download cut off part-way is then a
# function that was never closed, which sh refuses, and not the first
# half of an install.
set -eu

say() { printf '%s\n' "$*" >&2; }
die() { say "install.sh: $*"; exit 1; }

# fetch <url> <curl options...>: a `file://` URL as it is, anything else
# over HTTPS only.
fetch() {
  url="$1"
  shift
  case "$url" in
    file://*) curl "$@" "$url" ;;
    *) curl --proto '=https' --proto-redir '=https' --tlsv1.2 "$@" "$url" ;;
  esac
}

# Releases before 0.12.0 published no SHA256SUMS.
before_sha256sums() {
  case "$1" in
    0.[0-9].* | 0.1[01].*) return 0 ;;
  esac
  return 1
}

main() {
  repo="iyilang/iyi"
  prefix="${IYI_PREFIX:-$HOME/.local}"
  version="${IYI_VERSION:-}"

  for tool in curl tar; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
  done

  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os-$arch" in
    Linux-x86_64) target=linux-x86_64 ;;
    Darwin-arm64) target=darwin-arm64 ;;
    *) die "no release for $os $arch: releases ship linux-x86_64 and darwin-arm64, see INSTALL.md (From source) to build from source" ;;
  esac

  if [ -z "$version" ]; then
    tag_url="$(fetch "https://github.com/$repo/releases/latest" -fsSLI -o /dev/null -w '%{url_effective}')" ||
      die "could not resolve the latest release of $repo"
    version="${tag_url##*/tag/v}"
    [ "$version" != "$tag_url" ] || die "unexpected redirect for the latest release: $tag_url"
  fi
  version="${version#v}"

  asset="iyi-$version-$target.tar.gz"
  base="${IYI_RELEASE_URL:-https://github.com/$repo/releases/download/v$version}"
  case "$base" in
    https://* | file://*) ;;
    *) die "IYI_RELEASE_URL is $base: it has to be an https:// or a file:// URL" ;;
  esac

  mkdir -p "$prefix" 2>/dev/null && [ -w "$prefix" ] ||
    die "$prefix is not writable; set IYI_PREFIX to a directory that is"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  say "iyi $version for $target"
  fetch "$base/$asset" -fSL --progress-bar -o "$tmp/$asset" || die "download failed: $base/$asset"

  # The checksum line for this tarball, out of the release's SHA256SUMS.
  # Releases before 0.12.0 published none, and that is said rather than
  # passed over: an install that was not verified should know it was not.
  # From 0.12.0 on a SHA256SUMS that does not arrive stops the install.
  if fetch "$base/SHA256SUMS" -fsSL -o "$tmp/SHA256SUMS" 2>/dev/null; then
    expected="$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1; exit }' "$tmp/SHA256SUMS")"
    [ -n "$expected" ] || die "the release's SHA256SUMS has no line for $asset"
    if command -v sha256sum >/dev/null 2>&1; then
      actual="$(sha256sum "$tmp/$asset" | awk '{ print $1 }')"
    elif command -v shasum >/dev/null 2>&1; then
      actual="$(shasum -a 256 "$tmp/$asset" | awk '{ print $1 }')"
    else
      die "the release publishes a checksum and neither sha256sum nor shasum is here to check it"
    fi
    [ "$actual" = "$expected" ] ||
      die "$asset does not match the release's SHA256SUMS: expected $expected, got $actual. Nothing was unpacked; try again, and if it repeats, say so at https://github.com/$repo/issues"
    say "verified: sha256 $actual"
  elif before_sha256sums "$version"; then
    say "note: release $version publishes no SHA256SUMS; the tarball was not verified"
  else
    die "could not fetch $base/SHA256SUMS, and an unverified tarball is not unpacked. Nothing was unpacked; try again, and if it repeats, say so at https://github.com/$repo/issues"
  fi

  # What a previous install left, removed before this one is unpacked.
  #
  # `tar` overwrites the files it carries and knows nothing about the ones
  # it no longer carries, so an upgrade used to leave every file the
  # release had deleted lying in the prefix. That is not tidy-versus-untidy:
  # `share/iyi/crystal` is a *library*, `crystal/dwarf.cr` requires
  # `./dwarf/**`, and a file a release removed is still required by the
  # glob. One real case, found on a machine that had upgraded in place:
  # `crystal/dwarf/line_numbers.cr` from an older release stayed behind and
  # every `--crystal` build died with `undefined constant FORM`, naming a
  # file the person never wrote and cannot find in the repository.
  #
  # So each install writes down what it unpacked, and the next one removes
  # exactly that - no more, since `bin/` and `lib/` are shared with whatever
  # else lives under the prefix. An install from before this manifest
  # existed leaves no list, and for it the two directories iyi owns whole
  # are cleared instead, which is where the library that poisons a build
  # lives.
  manifest="$prefix/share/iyi/installed-files"
  if [ -f "$manifest" ]; then
    while IFS= read -r path; do
      case "$path" in
        /*|*..*) continue ;;  # a manifest is this script's own writing; refuse anything that climbs out
      esac
      [ -n "$path" ] || continue
      [ -d "$prefix/$path" ] || rm -f "$prefix/$path"
    done < "$manifest"
    # Directories after their contents, and only the ones that emptied.
    sort -r "$manifest" | while IFS= read -r path; do
      case "$path" in
        /*|*..*|"") continue ;;
      esac
      [ -d "$prefix/$path" ] && rmdir "$prefix/$path" 2>/dev/null || true
    done
  elif [ -d "$prefix/share/iyi" ]; then
    say "replacing the install at $prefix (no file list: it predates one)"
    rm -rf "$prefix/share/iyi" "$prefix/share/licenses/iyi"
  fi

  tar -xzf "$tmp/$asset" -C "$prefix"

  # And what this install owns, for the next one to remove. Paths as the
  # archive names them, `./` stripped, so they read as prefix-relative.
  tar -tzf "$tmp/$asset" | sed 's|^\./||' | grep -v '^$' > "$manifest"

  "$prefix/bin/iyi" version >/dev/null || die "$prefix/bin/iyi does not start"

  say "installed $prefix/bin/iyi"
  command -v cc >/dev/null 2>&1 ||
    say "note: no C compiler on PATH; iyi links through cc, so install gcc or clang before building"

  case ":$PATH:" in
    *":$prefix/bin:"*) ;;
    *) say "note: add $prefix/bin to PATH, e.g. export PATH=\"$prefix/bin:\$PATH\"" ;;
  esac
  say "try: $prefix/bin/iyi run $prefix/share/iyi/samples/hello.iyi"
}

main "$@"
