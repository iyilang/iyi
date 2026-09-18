#!/usr/bin/env bash
# Binds a real shard *and the three shards under it*, in dependency order, and
# builds a program against the four boundaries.
#
# `bench/bind_roundtrip.sh` asks R-1's question of one boundary written from a
# shard this file makes up. This asks it of a chain: `backtracer` → `radix` →
# `exception_page` → `kemal`, installed from the network, where each boundary
# is built against the ones before it and the consumer holds all four at once.
#
# Nothing smaller finds what this finds. A single boundary cannot collide with
# another's synthesised names, cannot have an import edge to get wrong, and
# cannot be a *class* root standing beside module roots — `ExceptionPage` is
# one, and a class root's declarations used to be wrapped in a module of the
# class's own name, so every type under it gained a level nobody could name.
#
#     bash bench/bind_chain.sh
#
# Needs `make`, `shards` and the network. The shard is pinned, so what it
# fetches is one version rather than whatever is current.
#
# Exits non-zero if any bind or fill fails, if either arm fails to build or
# link, or if the two print differently.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# the wrappers in bin are posix shell scripts, so a caller that already has
# compilers of its own names them through the environment.
CRYSTAL="${CRYSTAL:-$REPO/bin/crystal}"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"

# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and the shard
# in a scratch directory named `/tmp/tmp.X` is never read.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

KEMAL_VERSION="1.12.0"

if ! command -v shards > /dev/null 2>&1; then
  echo "needs shards, which is not on the PATH"
  exit 1
fi

cat > "$WORK/shard.yml" <<YML
name: bind_chain
version: 0.1.0
dependencies:
  kemal:
    github: kemalcr/kemal
    version: $KEMAL_VERSION
YML

cd "$WORK" || exit 1

if ! shards install > install.log 2>&1; then
  echo "installing the shard failed"
  tail -12 install.log
  echo "workdir $WORK"
  exit 1
fi

# Absolute, because the fill build runs with `mods` as its working directory
# and a relative `lib` would resolve under it.
export CRYSTAL_PATH="$WORK/lib${PSEP}$REPO/src"
export IYI_PATH="$WORK/lib${PSEP}$REPO/share/iyi/src${PSEP}$REPO/share/iyi/crystal${PSEP}$REPO/src"

mkdir mods

# In dependency order, which is the whole of what removes the import cycle:
# the fill step reads the boundaries beside it, so binding `backtracer` after
# `kemal` adds an edge in each direction (SPEC.md Part V item 12).
bind_one() {
  shard="$1"; root="$2"
  # `--use-iyimod mods` is what lets a boundary see the ones bound before it,
  # and the count beside each line is why it matters: without it `Radix::Tree`
  # is a name `Kemal` cannot write, so all three of its handlers cross as
  # *handles* — a pointer with no fields — and a body that travels and touches
  # one cannot be compiled by the consumer at all.
  if ! "$CRYSTAL" tool bind -e "$root" --emit-bind mods --use-iyimod mods \
        "lib/$shard/src/$shard.cr" > "bind-$shard.log" 2>&1; then
    echo "binding $shard failed"
    tail -10 "bind-$shard.log"
    echo "workdir $WORK"
    exit 1
  fi
  if ! (cd mods && "$CRYSTAL" build --iyi-keep "$root" --emit-bind . \
          -o "keep_$shard" "${shard}_keep.cr" > "fill-$shard.log" 2>&1); then
    echo "filling $shard failed"
    tail -10 "mods/fill-$shard.log"
    echo "workdir $WORK"
    exit 1
  fi
  units=$("$IYI" mod dump "mods/$shard.iyimod" 2>/dev/null | sed -n '/^object code/,$p' | grep -c ' bytes')
  handles=$(sed -n '/crossed as handles/,/^$/p' "bind-$shard.log" | grep -c '^    ' || true)
  printf '  %-16s %s units, %s types without their fields\n' "$shard" "$units" "$handles"
}

echo "bound, in dependency order:"
bind_one backtracer Backtracer
bind_one radix Radix
bind_one exception_page ExceptionPage
bind_one kemal Kemal

# The consumer adds a *route*, which is the DSL's own foundation:
# `Kemal::RouteHandler#add_route` takes a block, so its machine code is the
# caller's and its body is compiled here — and that body calls
# `add_to_radix_tree`, which kemal keeps private, which calls
# `Radix::Tree#add`, whose body calls a private overload of itself, which calls
# `Node#add` and a protected `sort!`. Every one of those crosses, or none of it
# works.
#
# `get "/" do …` itself is still a top-level `def` outside `Kemal`, so a
# boundary rooted at `Kemal` cannot carry it — that is a question about what a
# root *is* rather than about what crosses one.
cat > "$WORK/app_source.iyi" <<'IYI'
module main

require "kemal"

config = Kemal.config
config.port = 31893
config.env = "production"
puts config.port
puts config.env
puts config.host_binding
puts Kemal::RouteHandler::INSTANCE.class.to_s
Kemal::RouteHandler::INSTANCE.add_route("GET", "/bound") do |env|
  "hello from a boundary"
end
puts "route added"
IYI

cat > "$WORK/app_artifact.iyi" <<'IYI'
module main

import kemal

config = Kemal.config_instance
config.port = 31893
config.env = "production"
puts config.port
puts config.env
puts config.host_binding
puts Kemal.routehandler_instance.class.to_s
Kemal.routehandler_instance.add_route("GET", "/bound") do |env|
  "hello from a boundary"
end
puts "route added"
IYI

status=0
for arm in source artifact; do
  build_cmd=("$IYI" build --crystal)
  if [ "$arm" = artifact ]; then
    build_cmd+=(--use-iyimod mods)
  fi
  build_cmd+=(-o "out_$arm" "app_$arm.iyi")

  if ! "${build_cmd[@]}" > "build-$arm.log" 2>&1; then
    echo "$arm: build failed"
    grep -oE '(undefined|duplicate) symbol: .*' "build-$arm.log" | sort -u | head -10
    grep -m3 -E '^Error' "build-$arm.log"
    status=1
    continue
  fi
  "./out_$arm" > "out-$arm.txt" 2>&1
done

if [ -f out-source.txt ] && [ -f out-artifact.txt ]; then
  if diff -q out-source.txt out-artifact.txt > /dev/null; then
    echo "four boundaries, and the program prints what the source does"
    sed 's/^/  /' out-artifact.txt
  else
    echo "OUTPUT DIFFERS"
    diff out-source.txt out-artifact.txt | head -10
    status=1
  fi
fi

echo "workdir $WORK"
exit $status
