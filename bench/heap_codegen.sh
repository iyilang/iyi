#!/usr/bin/env bash
# heap22's compiler side (S3), driven: bench/heap_codegen.iyi built with
# partitions and the verifier, plain and optimised, every check passing;
# the pin notes in the build's output; then one broken copy of the
# compiler per mechanism, each turned off by `IYI_SPAWN_BROKEN` at build
# time, and each caught by the check of its mechanism.
#
#   bash bench/heap_codegen.sh
#
# Needs `make` first. `FLAGS` replaces the build flags (default
# `-Dheap_partitions -Dheap_verify`); `FLAGS=` runs the flag-off control
# alone, every check passing and no copy built. Exits non-zero if any step
# fails. A copy is caught when its program exits non-zero with its check's
# `FAIL:` line; each check reads where a chunk lives (`IyiHeap.local?`,
# `owner_of`, the running fiber's record) before any collection, so the
# catch does not wait on a collection or a seed.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
FLAGS="${FLAGS--Dheap_partitions -Dheap_verify}"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac
trap 'rm -rf "$WORK"' EXIT

status=0

build() { # name compiler-env extra-flags
  local name="$1" compiler_env="$2" extra="$3"
  # shellcheck disable=SC2086
  env "$compiler_env" "$IYI" build $FLAGS $extra -o "$WORK/$name" "$REPO/bench/heap_codegen.iyi" \
    >"$WORK/$name.build.log" 2>&1
}

run_case() { # label name extra-flags
  local label="$1" name="$2" extra="$3"
  if ! build "$name" IYI_SPAWN_BROKEN= "$extra"; then
    echo "$label: build failed"
    sed -n '1,12p' "$WORK/$name.build.log"
    status=1
    return
  fi
  timeout 300 "$WORK/$name" >"$WORK/$name.out" 2>&1
  local code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$code" -ne 0 ]; then
    echo "$label: exit $code"
    status=1
  fi
}

echo "== the compiler's mechanisms, plain ($FLAGS)"
run_case "plain" plain ""
echo "== the compiler's mechanisms, optimised ($FLAGS)"
run_case "release" release "--release"

case "$FLAGS" in
  *heap_partitions*) ;;
  *)
    if grep -q "runs in the shared heap" "$WORK/plain.build.log"; then
      echo "flag-off: a pin note was printed without partitions"
      status=1
    fi
    echo
    [ "$status" -eq 0 ] && echo "heap_codegen: the flag-off control holds."
    exit "$status"
    ;;
esac

echo
echo "== the pin notes"
# The spawn reaching `Pool` is pinned, and says so; the one reaching only
# `LentPool` is not.
pins="$(grep -c "this spawn runs in the shared heap because it captures \`pool\`" "$WORK/plain.build.log")"
lent="$(grep -c "captures \`lent\`" "$WORK/plain.build.log")"
if [ "$pins" -ge 1 ] && [ "$lent" -eq 0 ]; then
  echo "  the spawn capturing \`pool\` is noted pinned; the one capturing \`lent\` is not"
else
  echo "  pin notes: $pins for \`pool\` (want 1+), $lent for \`lent\` (want 0)"
  sed -n '1,20p' "$WORK/plain.build.log"
  status=1
fi

echo
echo "== each mechanism turned off in the compiler, caught by its check"
prove_caught() { # label copy check
  local label="$1" copy="$2" check="$3"
  if ! build "broken-$copy" "IYI_SPAWN_BROKEN=$copy" ""; then
    echo "  $label: the build did not finish"
    sed -n '1,12p' "$WORK/broken-$copy.build.log"
    status=1
    return
  fi
  timeout 120 "$WORK/broken-$copy" "$check" >"$WORK/broken-$copy.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: the check '$check' still passed, so it does not test this"
    status=1
    return
  fi
  local how
  if [ "$code" -eq 124 ]; then
    how="a hang, ended at 120 s"
  elif grep -q "^FAIL: " "$WORK/broken-$copy.out"; then
    how="$(grep -m1 "^FAIL: " "$WORK/broken-$copy.out" | sed 's/^FAIL: //')"
  else
    how="a crash (exit $code)"
  fi
  printf '  %s: %s: %s\n' "$label" "$check" "$how"
}

prove_caught "C1 typed crossing context" c1 c1
prove_caught "class-variable store publish" classvar-publish classvar
prove_caught "trusted types born shared" new-shared born_shared
prove_caught "pin (forced off)" pin pin

echo
[ "$status" -eq 0 ] && echo "heap_codegen: every mechanism holds, and every copy is caught."
exit "$status"
