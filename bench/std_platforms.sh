#!/usr/bin/env bash
# Every std module exercise, read from its own artifacts for the platforms
# this runner is not: darwin arm64, Windows, aarch64 Linux and musl.
#
#     bash bench/std_platforms.sh
#
# A section of bench/std_exercise.sh, which runs it in place unless
# `STD_PLATFORMS=0`; CI runs it in jobs of its own beside the foundation's
# (`std-platforms`, `windows-std-platforms`). On a slow windows-2025 runner
# it took 2,794 s of that job's 7,605 (CI job 128265739456), which ended 23
# minutes inside its 150; on Linux 2,175 to 2,222 s of the std job's 4,520
# to 4,626, inside its 90 (jobs 127915910948, 128177183684, 128229582584,
# 128266194144).
#
# Exits non-zero if any exercise cannot be consumed on any of the four.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping
# (bench/std_exercise.sh says how that fails): both paths go to it mixed.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

trap 'rm -rf "$WORK"' EXIT

status=0

echo "== and on the platforms this runner is not"
# The front end only, which is where a platform differs: a module's
# `{% if flag?(:darwin) %}` branch declares a different `lib` with
# different `fun`s, and nothing outside darwin ever read one. That is how
# std_exercise.sh's section that runs every exercise from its artifacts
# passed here and failed there — `undefined fun 'opendir' for LibC` — a
# whole day after it was written.
#
# `--no-codegen` because the answer is what a consumer's front end
# resolves, and because it costs a fraction of a build that generates code.
# The whole sweep over four targets was a minute when it was written, over
# sixty exercises; over 114 it is 912 builds, 2.4 s each on Linux CI
# (2,189 s, job 128266194144) and 3.1 s on a slow windows-2025 runner.
unportable=""
for target in aarch64-darwin x86_64-windows-msvc aarch64-linux-gnu x86_64-linux-musl; do
  for source in "$REPO"/bench/std_*_exercise.iyi "$REPO"/bench/std_*_test.iyi; do
    name="$(basename "$source" .iyi)"
    work="$WORK/cross/$target/$name"
    mkdir -p "$work/mods"
    if ! (cd "$work" && "$IYI" build --no-codegen --target "$target" \
            --emit-iyimod mods -o out "$source") > "$work/emit.log" 2>&1; then
      unportable="$unportable $target/$name"
      echo "  $target $name: cannot write its artifacts: $(grep -m1 -E 'Error|BUG' "$work/emit.log" | cut -c1-120)"
      continue
    fi
    if ! (cd "$work" && "$IYI" build --no-codegen --target "$target" \
            --use-iyimod mods -o out2 "$source") > "$work/use.log" 2>&1; then
      unportable="$unportable $target/$name"
      echo "  $target $name: $(grep -m1 -E 'Error|BUG' "$work/use.log" | cut -c1-120)"
    fi
  done
done
if [ -n "$unportable" ]; then
  echo "  FAIL: cannot be consumed on another platform:$unportable"
  status=1
else
  echo "  every exercise reads its own artifacts on darwin, windows, aarch64 and musl"
fi

exit "$status"
