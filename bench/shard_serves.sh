#!/usr/bin/env bash
# Installs a real shard, builds an iyi program that requires it, and asks the
# program for two pages over HTTP.
#
# This is the README's headline example taken literally: `require "kemal"` in
# an `.iyi` file, built `--crystal`, serving. Nothing here checked it. The
# samples cannot — none of them requires a shard, which is the whole point of
# the example — and CI's tarball job builds a *synthetic* shard against
# `crystal/syntax_highlighter` to prove the library ships whole. That catches a
# missing file. It cannot catch a language rule that a real shard breaks, an
# ecosystem macro that iyi's parser refuses, or a route block that does not
# compile, and every one of those would leave the headline claim false with
# every gate green.
#
#     bash bench/shard_serves.sh
#
# Needs `make` and the network, which is what makes it the only gate here that
# reaches outside the checkout. The shard is pinned, so what it fetches is one
# version rather than whatever is current.
#
# Exits non-zero if the shard does not install, if the program does not build,
# if the server does not come up, or if either page is not what the routes say.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from `pwd` is `/c/...` and finds no prelude at all, and a
# scratch directory named `/tmp/tmp.X` is silently ignored on that path, so
# the patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

# Pinned, and 1.12.0 rather than whatever is newest: SPEC.md Part V item 12
# measured this version, so a number here is comparable to the numbers there.
KEMAL_VERSION="1.12.0"

# High and fixed. A random port would make a failure unreproducible, and this
# refuses rather than guesses when something already holds it.
PORT=31871

cleanup() {
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
  wait "${SERVER_PID:-}" 2>/dev/null
}
trap cleanup EXIT

# Named rather than discovered halfway through. `shards` fetches the shard and
# `curl` asks the server for a page; without either, the failure would arrive
# as a confusing error from a step that had already done minutes of work.
for tool in shards curl; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "needs $tool, which is not on the PATH"
    exit 1
  fi
done

cat > "$WORK/shard.yml" <<YML
name: shard_serves
version: 0.1.0
dependencies:
  kemal:
    github: kemalcr/kemal
    version: $KEMAL_VERSION
YML

# Two routes and not one. A single static string would compile if the router
# never ran; the second reads a URL parameter, so the answer is only right if
# the request reached the block the shard's macros defined.
cat > "$WORK/serve.iyi" <<IYI
module main

require "kemal"

get "/" do |env|
  "hello from iyi"
end

get "/echo/:word" do |env|
  env.params.url["word"]
end

Kemal.config.port = $PORT
Kemal.run
IYI

cd "$WORK" || exit 1

if ! shards install > install.log 2>&1; then
  echo "installing the shard failed"
  tail -12 install.log
  echo "workdir $WORK"
  exit 1
fi
echo "installed $(grep -c 'Installing' install.log) shards, kemal pinned at $KEMAL_VERSION"

# `lib` first, because that is where the shard is, and then whatever the iyi
# wrapper says this checkout's own path is. Asked of `iyi` rather than
# `crystal`: the two command surfaces answer in their own vocabularies, and
# `crystal env IYI_PATH` prints an empty line and exits 0.
IYI_PATH="lib${PSEP}$("$IYI" env IYI_PATH 2>/dev/null)"
export IYI_PATH

if ! "$IYI" build --crystal -o serve serve.iyi > build.log 2>&1; then
  echo "building against the shard failed"
  tail -20 build.log
  echo "workdir $WORK"
  exit 1
fi
echo "built a program that requires kemal"

./serve > server.log 2>&1 &
SERVER_PID=$!

# Polled, not slept. A fixed sleep is a flake on a slow machine and wasted
# seconds on a fast one, and the thing being waited for is answerable.
ready=""
for _ in $(seq 1 50); do
  if curl -s --max-time 2 "http://127.0.0.1:$PORT/" > /dev/null 2>&1; then
    ready=yes
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "the server exited before answering"
    tail -12 server.log
    echo "workdir $WORK"
    exit 1
  fi
  sleep 0.2
done

if [ -z "$ready" ]; then
  echo "the server never answered on port $PORT"
  tail -12 server.log
  echo "workdir $WORK"
  exit 1
fi

status=0
check() {
  path="$1"
  want="$2"
  got="$(curl -s --max-time 5 "http://127.0.0.1:$PORT$path")"
  if [ "$got" = "$want" ]; then
    echo "  GET $path -> $got"
  else
    echo "  GET $path -> $got (wanted: $want)"
    status=1
  fi
}

check "/" "hello from iyi"
check "/echo/iyi" "iyi"

if [ "$status" -eq 0 ]; then
  echo "a real shard serves"
fi

echo "workdir $WORK"
exit $status
