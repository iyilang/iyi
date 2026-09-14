#!/usr/bin/env bash
# The wasm32 toolchain the CI jobs run on: wasi-sdk (clang, wasm-ld and the
# sysroot) and wasmtime, installed under one prefix so that actions/cache can
# hand the whole thing back.
#
#     bash scripts/install-wasm-toolchain.sh ~/wasm-toolchain
#
# Both are GitHub release assets, and the two jobs used to fetch them with a
# bare `curl -sSL | tar`. The day github.com answered 504 for one asset for an
# hour, the error page was saved as the tarball and the job died of "gzip:
# stdin: not in gzip format"; in the other job wasmtime's installer failed
# somewhere inside its pipe and the gate reported "wasmtime not found" - two
# red jobs about a download, on a commit that changed no wasm. So a fetch here
# fails on an HTTP error instead of saving it, retries, then falls back to the
# release API's own asset endpoint, which answered 200 on the same day the
# download URL answered 504; and what arrived is checked to be the archive it
# claims to be before anything is extracted, and the tools are run once
# before the script says they are installed.
#
# Idempotent: a prefix that already holds the pinned versions is left alone,
# which is what a cache hit looks like from here.
set -euo pipefail

WASI_SDK_VERSION=${WASI_SDK_VERSION:-24}
WASMTIME_VERSION=${WASMTIME_VERSION:-v48.0.1}

prefix=${1:-$HOME/wasm-toolchain}
sdk_dir="$prefix/wasi-sdk"
wasmtime_dir="$prefix/wasmtime"
mkdir -p "$prefix"

# fetch <repo> <tag> <asset> <out>: the download URL, and when that does not
# answer, the release API's asset endpoint by name. The token, when the
# workflow passes one, keeps the API call out of the anonymous rate limit
# every runner shares.
fetch() {
  local repo="$1" tag="$2" asset="$3" out="$4"
  local curl=(curl -fsSL --retry 4 --retry-delay 5 --retry-all-errors)
  local auth=()
  [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")

  local url="https://github.com/$repo/releases/download/$tag/$asset"
  if "${curl[@]}" -o "$out" "$url"; then
    return 0
  fi
  echo "  $url did not answer; asking the release API for $asset"
  local api="https://api.github.com/repos/$repo/releases/tags/$tag" release asset_url
  # With the token when there is one, and without it when the token is
  # refused: a workflow that grants no permissions still has one, and what
  # it can read here is public either way.
  release=$("${curl[@]}" "${auth[@]}" "$api") || release=$("${curl[@]}" "$api")
  asset_url=$(printf '%s' "$release" | python3 -c 'import json, sys
name = sys.argv[1]
release = json.load(sys.stdin)
print(next(a["url"] for a in release["assets"] if a["name"] == name))' "$asset")
  "${curl[@]}" "${auth[@]}" -H "Accept: application/octet-stream" -o "$out" "$asset_url" ||
    "${curl[@]}" -H "Accept: application/octet-stream" -o "$out" "$asset_url"
}

# What arrived has to be the archive it claims to be: a saved error page is
# not, and it says so here rather than as tar's "not in gzip format".
is_archive() { # is_archive <file> <gzip|xz>
  case "$2" in
    gzip) gzip -t "$1" 2>/dev/null ;;
    xz) xz -t "$1" 2>/dev/null ;;
  esac
}

echo "== wasi-sdk $WASI_SDK_VERSION"
if [ -x "$sdk_dir/bin/clang" ] && [ -f "$sdk_dir/.iyi-version-$WASI_SDK_VERSION" ]; then
  echo "  already installed under $sdk_dir"
else
  asset="wasi-sdk-$WASI_SDK_VERSION.0-x86_64-linux.tar.gz"
  fetch WebAssembly/wasi-sdk "wasi-sdk-$WASI_SDK_VERSION" "$asset" /tmp/wasi-sdk.tar.gz
  if ! is_archive /tmp/wasi-sdk.tar.gz gzip; then
    echo "  $asset arrived as something that is not a gzip; its first bytes:"
    head -c 200 /tmp/wasi-sdk.tar.gz | tr -c '[:print:]\n' '.'
    echo
    exit 1
  fi
  rm -rf "$sdk_dir"
  mkdir -p "$sdk_dir"
  tar -xzf /tmp/wasi-sdk.tar.gz -C "$sdk_dir" --strip-components=1
  rm -f /tmp/wasi-sdk.tar.gz
  touch "$sdk_dir/.iyi-version-$WASI_SDK_VERSION"
fi
"$sdk_dir/bin/clang" --version | head -1 | sed 's/^/  /'
[ -x "$sdk_dir/bin/wasm-ld" ] || { echo "  wasi-sdk unpacked without wasm-ld"; exit 1; }

echo "== wasmtime $WASMTIME_VERSION"
if [ -x "$wasmtime_dir/bin/wasmtime" ] &&
   "$wasmtime_dir/bin/wasmtime" --version 2>/dev/null | grep -q "${WASMTIME_VERSION#v}"; then
  echo "  already installed under $wasmtime_dir"
else
  asset="wasmtime-$WASMTIME_VERSION-x86_64-linux.tar.xz"
  fetch bytecodealliance/wasmtime "$WASMTIME_VERSION" "$asset" /tmp/wasmtime.tar.xz
  if ! is_archive /tmp/wasmtime.tar.xz xz; then
    echo "  $asset arrived as something that is not an xz archive; its first bytes:"
    head -c 200 /tmp/wasmtime.tar.xz | tr -c '[:print:]\n' '.'
    echo
    exit 1
  fi
  rm -rf "$wasmtime_dir"
  mkdir -p "$wasmtime_dir/bin"
  tar -xJf /tmp/wasmtime.tar.xz -C "$wasmtime_dir/bin" --strip-components=1
  rm -f /tmp/wasmtime.tar.xz
fi
"$wasmtime_dir/bin/wasmtime" --version | sed 's/^/  /'
"$wasmtime_dir/bin/wasmtime" --version | grep -q "${WASMTIME_VERSION#v}" ||
  { echo "  the wasmtime that unpacked is not $WASMTIME_VERSION"; exit 1; }

echo "wasm toolchain: wasi-sdk at $sdk_dir, wasmtime at $wasmtime_dir/bin"
