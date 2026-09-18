#!/usr/bin/env bash
# Signs and verifies a JWT through four `.iyimod` boundaries.
#
# `bench/kemal_serves.sh` proves a kemal application crosses. This proves a
# different *kind* of shard does, and the difference is the point of having
# both. kemal reaches nothing outside Crystal's own library; `jwt` reaches
# OpenSSL through a reopened `lib`, and under it `bindata` writes classes with
# macros that write classes — each subclass getting its own copy of a class
# variable its superclass declared — and hangs an exception hierarchy off
# `Exception`. Every one of those broke separately here: a `fun` a travelling
# body calls, a `lib` constant, a class variable four subclasses share the name
# of, a `to_s` a consumer reaches through a class held virtually.
#
#     bash bench/jwt_signs.sh
#
# Needs `make`, `shards` and the network. Both shards are pinned, so what it
# fetches is one version rather than whatever is current.
#
# Exits non-zero if any bind or fill fails, if either arm fails to build, or if
# the two answer differently. Answering differently is the failure worth
# naming: a token is a signature over bytes, so a boundary that dropped a field
# or numbered a type differently does not crash, it signs something else.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# Both compilers are whichever ones the caller names; `bin/crystal` and
# `bin/iyi` are shell wrappers, and on Windows the caller has to point at
# the built exes themselves.
CRYSTAL="${CRYSTAL:-$REPO/bin/crystal}"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"

# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` on it is silently ignored, so the shard the
# boundary is built from is never read.
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

# Pinned, and the version SPEC.md Part V item 12 measured, so a number here is
# comparable to the numbers there.
JWT_VERSION="1.6.1"

for tool in shards; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "needs $tool, which is not on the PATH"
    exit 1
  fi
done

cat > "$WORK/shard.yml" <<YML
name: jwt_signs
version: 0.1.0
dependencies:
  jwt:
    github: crystal-community/jwt
    version: $JWT_VERSION
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

# In dependency order, and each boundary built against the ones before it. See
# `bench/bind_chain.sh` for why both halves of that matter — binding into a
# directory that already holds a *later* boundary gives the earlier one an
# import edge back to it, and a stale directory is how three measurements in
# SPEC.md came to name the wrong type.
#
# Four boundaries from two shards: `-e` names a *root*, not a package, and
# `bindata` defines `BinData` and `ASN1` in files `jwt` requires separately.
bind_one() {
  name="$1"; root="$2"; source="$3"
  if ! "$CRYSTAL" tool bind -e "$root" --emit-bind mods --use-iyimod mods \
        "$source" > "bind-$name.log" 2>&1; then
    echo "binding $name failed"
    tail -10 "bind-$name.log"
    echo "workdir $WORK"
    exit 1
  fi
  keep="$(ls -t mods/*_keep.cr | head -1)"
  if ! (cd mods && "$CRYSTAL" build --iyi-keep "$root" --emit-bind . \
          -o "keep_$name" "$(basename "$keep")" > "fill-$name.log" 2>&1); then
    echo "filling $name failed"
    tail -10 "mods/fill-$name.log"
    echo "workdir $WORK"
    exit 1
  fi
  echo "  bound $name ($root)"
}

echo "bound, in dependency order:"
bind_one openssl_ext OpenSSL lib/openssl_ext/src/openssl_ext.cr
bind_one bindata     BinData lib/bindata/src/bindata.cr
bind_one asn1        ASN1    lib/bindata/src/bindata/asn1.cr
bind_one jwt         JWT     lib/jwt/src/jwt.cr

# The program, written the way jwt's own README writes one. `JWT.encode` takes
# an untyped `payload` and a `**header_keys`, so nobody wrote its shape and its
# body is what says it — the consumer compiles both. The round trip is what
# makes this a measurement rather than a smoke test: `encode` and `decode` have
# to agree about the payload's bytes, and a boundary that got a field or a type
# id wrong signs something else and says so here.
program='payload = {"sub" => "iyi", "n" => 1}
token = JWT.encode(payload, "secret", JWT::Algorithm::HS256)
puts "encoded #{token.size > 20}"
back, header = JWT.decode(token, "secret", JWT::Algorithm::HS256)
puts back["sub"]
puts header["alg"]'

printf 'module main\n\nrequire "jwt"\n\n%s\n' "$program" > app_source.iyi
printf 'module main\n\nimport j_w_t\n\n%s\n' "$program" > app_artifact.iyi

status=0

if ! "$IYI" build --crystal -o app_source app_source.iyi > build-source.log 2>&1; then
  echo "the source arm failed to build"
  tail -12 build-source.log
  echo "workdir $WORK"
  exit 1
fi

if ! "$IYI" build --crystal --use-iyimod mods -o app_artifact app_artifact.iyi \
      > build-artifact.log 2>&1; then
  echo "the artifact arm failed to build"
  tail -12 build-artifact.log
  echo "workdir $WORK"
  exit 1
fi

./app_source > answers-source.txt 2>&1 || status=1
./app_artifact > answers-artifact.txt 2>&1 || status=1

if diff -q answers-source.txt answers-artifact.txt > /dev/null; then
  echo "four boundaries, and a signed token reads back the way the source's does"
  sed 's/^/  /' answers-artifact.txt
else
  echo "THE TWO ARMS ANSWER DIFFERENTLY"
  diff answers-source.txt answers-artifact.txt | head -10
  status=1
fi

echo "workdir $WORK"
exit $status
