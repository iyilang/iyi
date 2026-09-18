#!/usr/bin/env bash
# Builds each iyi sample twice and checks it prints the same thing both times:
# once from source, once from the imported modules' `.iyimod` artifacts with
# every one of those modules' source **deleted**.
#
# That deletion is the whole test. R-1 says a consumer compiles against a
# module's declarations and never its source, and the only way to be sure of it
# is to take the source away and see whether the build still produces a program
# that behaves. `spec/compiler/iyimod_spec.cr` checks the same property on small
# programs written for it; this checks it on the samples, which were written to
# document the language rather than to pass this.
#
#     bash bench/samples_roundtrip.sh
#
# Needs `make` (which builds both the compiler and `iyi`). It runs `iyi` rather
# than `crystal` because these are iyi programs and that is the binary a person
# has. Exits non-zero if any sample fails to build either way, or prints
# something different from its artifacts.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
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

# The six that import a module. `hello`, `generics` and `errors` are single
# files and exercise nothing here. `derive` is here for the reason R-5 exists:
# the macro that generated its methods is in `std/derives`, and that source is
# deleted below, so the artifact has to carry what the derive produced.
SAMPLES="modules immutable collections init_order webapp derive"

cp -r "$REPO/samples/iyi/." "$WORK/"
cd "$WORK" || exit 1

status=0

for sample in $SAMPLES; do
  if ! "$IYI" build --emit-iyimod mods -o "from-source-$sample" "$sample.iyi" >"emit-$sample.log" 2>&1; then
    echo "$sample: writing artifacts failed"
    tail -5 "emit-$sample.log"
    status=1
    continue
  fi
  "./from-source-$sample" >"out-source-$sample.txt" 2>&1
done

# Every module's source, gone — so a build that reads one has nothing to fall
# back to.
rm -rf app std boot kemal

for sample in $SAMPLES; do
  [ -f "from-source-$sample" ] || continue
  if ! "$IYI" build --use-iyimod mods -o "from-artifact-$sample" "$sample.iyi" >"use-$sample.log" 2>&1; then
    echo "$sample: building from artifacts failed"
    tail -12 "use-$sample.log"
    status=1
    continue
  fi
  "./from-artifact-$sample" >"out-artifact-$sample.txt" 2>&1
  if diff -q "out-source-$sample.txt" "out-artifact-$sample.txt" >/dev/null; then
    echo "$sample: identical output"
  else
    echo "$sample: OUTPUT DIFFERS"
    diff "out-source-$sample.txt" "out-artifact-$sample.txt" | head -10
    status=1
  fi
done

echo "workdir $WORK"
exit $status
