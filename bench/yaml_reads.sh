#!/usr/bin/env bash
# Reads a YAML document through a boundary built from Crystal's own library.
#
# The other two shard gates bind *shards*. This binds a piece of the standard
# library itself, which is a different measurement and the one that found what
# it found: `YAML` calls libyaml, and which C libraries a boundary's object
# code needs is a question nothing in the format was answering. A consumer that
# replays `require "yaml"` has `lib LibYAML` and its `@[Link("yaml")]` and
# still drops the flag, because a flag is collected from the libs *this* build
# marked used and the call to `yaml_parser_parse` is in an object file the
# consumer reads rather than compiles.
#
#     bash bench/yaml_reads.sh
#
# Needs `make` and libyaml, which the compiler itself already links against.
# Nothing here reaches the network: the library being bound is in this
# checkout.
#
# Exits non-zero if the bind or the fill fails, if either arm fails to build,
# or if the two answer differently.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# Both compilers, overridable for the same reason: `bin/crystal` and
# `bin/iyi` are POSIX shell wrappers, and on Windows the caller is the only
# one who knows where the real binaries are.
CRYSTAL="${CRYSTAL:-$REPO/bin/crystal}"
IYI="${IYI:-$REPO/bin/iyi}"
# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on the search path, so
# the patched copy is never read and the proof that a check can fail
# quietly stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

cd "$WORK" || exit 1

export CRYSTAL_PATH="$REPO/src"
export IYI_PATH="$REPO/share/iyi/src${PSEP}$REPO/share/iyi/crystal${PSEP}$REPO/src"

# Both, and the second is not decoration. `YAML::Any#to_json_object_key` names
# `JSON::Error` in its body, so a boundary measured with `yaml` alone reads one
# signature fewer than one measured with both — what a boundary is measured
# *with* is part of the measurement.
cat > probe.cr <<'CR'
require "yaml"
require "json"
CR

if ! "$CRYSTAL" tool bind -e YAML --emit-bind mods probe.cr > bind.log 2>&1; then
  echo "binding YAML failed"
  tail -10 bind.log
  echo "workdir $WORK"
  exit 1
fi

if ! (cd mods && "$CRYSTAL" build --iyi-keep YAML --emit-bind . \
        -o keep_yaml y_a_m_l_keep.cr > fill.log 2>&1); then
  echo "filling YAML failed"
  tail -10 mods/fill.log
  echo "workdir $WORK"
  exit 1
fi

# Named rather than counted: the point of the section is *which* library, and a
# gate that only checked the count would pass on the wrong one.
if ! "$IYI" mod dump mods/y_a_m_l.iyimod 2>/dev/null | grep -q '^  LibYAML$'; then
  echo "the artifact does not say it calls into LibYAML"
  "$IYI" mod dump mods/y_a_m_l.iyimod 2>/dev/null | sed -n '/^libs/,/^[a-z]/p' | head -8
  echo "workdir $WORK"
  exit 1
fi

# A document with an anchor in it, because that is what makes the parser hold
# state across events: `@anchors` is typed by merging what more than one user
# of a shared module puts in it, which is the shape that kept `yaml` from
# binding at all for a long time.
program='text = "defaults: &d\n  mode: fast\nrun:\n  <<: *d\n  name: iyi\n"
doc = YAML.parse(text)
puts doc["run"]["name"]
puts doc["run"]["mode"]
puts doc["defaults"]["mode"]'

printf 'module main\n\nrequire "yaml"\n\n%s\n' "$program" > app_source.iyi
printf 'module main\n\nimport y_a_m_l\n\n%s\n' "$program" > app_artifact.iyi

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

status=0
./app_source > answers-source.txt 2>&1 || status=1
./app_artifact > answers-artifact.txt 2>&1 || status=1

if diff -q answers-source.txt answers-artifact.txt > /dev/null; then
  echo "a boundary built from the standard library reads what the source does"
  sed 's/^/  /' answers-artifact.txt
else
  echo "THE TWO ARMS ANSWER DIFFERENTLY"
  diff answers-source.txt answers-artifact.txt | head -10
  status=1
fi

echo "workdir $WORK"
exit $status
