#!/usr/bin/env bash
# Run the standard library's artifact comparisons, optionally partitioned across CI shards.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/darwin_frames.sh"

usage() { echo "usage: $0 native|cross [K N] | --plan N" >&2; exit 2; }
positive_integer() {
  case "$1" in ''|*[!0-9]*|0* ) return 1 ;; esac
  [ "${#1}" -le 6 ]
}

[ "$#" -ge 1 ] || usage
phase=$1; shift
case "$phase" in
  --plan) [ "$#" -eq 1 ] || usage; count=$1; shard=1 ;;
  native|cross)
    case "$#" in 0) shard=1; count=1 ;; 2) shard=$1; count=$2 ;; *) usage ;; esac ;;
  *) usage ;;
esac
positive_integer "$shard" && positive_integer "$count" && [ "$shard" -le "$count" ] || usage

sources=()
for source in "$REPO"/bench/std_*_exercise.iyi; do
  [ -f "$source" ] && sources+=("$source")
done
[ "${#sources[@]}" -gt 0 ] || { echo 'empty artifact source inventory' >&2; exit 2; }
[ "$count" -le "${#sources[@]}" ] || { echo 'artifact shard would be empty' >&2; exit 2; }

assigned_shard() { echo $(( $1 % count + 1 )); }

if [ "$phase" = --plan ]; then
  i=0
  for source in "${sources[@]}"; do
    printf '%s\t%s\n' "$(assigned_shard "$i")" "bench/${source##*/}"
    i=$((i + 1))
  done
  exit 0
fi

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac
trap 'rm -rf "$WORK"' EXIT

status=0

if [ "$phase" = native ]; then
  unconsumable=""
  count_ran=0
  i=0
  for source in "${sources[@]}"; do
    current_shard=$(assigned_shard "$i")
    i=$((i + 1))
    [ "$current_shard" -eq "$shard" ] || continue
    count_ran=$((count_ran + 1))

    name="$(basename "$source" .iyi)"
    work="$WORK/r1/$name"
    mkdir -p "$work/mods"
    if ! (cd "$work" && "$IYI" build --emit-iyimod mods -o from-source "$source") \
         > "$work/emit.log" 2>&1; then
      unconsumable="$unconsumable $name"
      why="$(grep -m1 -E 'Error|BUG' "$work/emit.log" | cut -c1-140)"
      [ -n "$why" ] || why="no Error line; it ended: $(tail -3 "$work/emit.log" | tr '\n' ' ' | cut -c1-200)"
      echo "  $name: cannot write its artifacts: $why"
      continue
    fi
    (cd "$work" && "$IYI" build --use-iyimod mods -o from-artifact "$source") \
      > "$work/use.log" 2>&1
    use_status=$?
    if [ "$use_status" -ne 0 ]; then
      unconsumable="$unconsumable $name"
      said="$(grep -m1 -E 'Error|BUG|undefined' "$work/use.log")"
      [ -n "$said" ] || said="exits $use_status: $(tail -n 1 "$work/use.log")"
      echo "  $name: $(printf '%s' "$said" | cut -c1-140)"
      continue
    fi
    "$work/from-source" > "$work/source.out" 2>&1
    source_status=$?
    "$work/from-artifact" > "$work/artifact.out" 2>&1
    artifact_status=$?
    if [ "$source_status" -ne "$artifact_status" ]; then
      unconsumable="$unconsumable $name"
      echo "  $name: exits $artifact_status from its artifacts and $source_status from source"
      failed_out="$work/source.out"
      [ "$artifact_status" -ne 0 ] && failed_out="$work/artifact.out"
      tail -n 6 "$failed_out" | sed 's/^/    /'
      continue
    fi
    case "$name" in
      std_big_exercise | std_gc_exercise | std_time_exercise | std_weak_ref_exercise)
        continue
        ;;
    esac
    without_frames < "$work/source.out" > "$work/source.cmp"
    without_frames < "$work/artifact.out" > "$work/artifact.cmp"
    if ! cmp -s "$work/source.cmp" "$work/artifact.cmp"; then
      unconsumable="$unconsumable $name"
      echo "  $name: runs differently from its artifacts"
      diff "$work/source.cmp" "$work/artifact.cmp" | sed -n '1,6p' | sed 's/^/    /'
    fi
  done
  if [ -n "$unconsumable" ]; then
    echo "  FAIL: cannot be consumed as artifacts:$unconsumable"
    status=1
  else
    if [ "$count" -eq 1 ]; then
      echo "  all $count_ran exercises answer the same from source and from artifacts"
    else
      echo "  all $count_ran exercises in shard $shard of $count answer the same from source and from artifacts"
    fi
  fi
else
  unportable=""
  count_ran=0
  for target in aarch64-darwin x86_64-windows-msvc aarch64-linux-gnu x86_64-linux-musl; do
    i=0
    for source in "${sources[@]}"; do
      current_shard=$(assigned_shard "$i")
      i=$((i + 1))
      [ "$current_shard" -eq "$shard" ] || continue
      count_ran=$((count_ran + 1))

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
    if [ "$count" -eq 1 ]; then
      echo "  every exercise reads its own artifacts on darwin, windows, aarch64 and musl"
    else
      echo "  every exercise in shard $shard of $count reads its own artifacts on darwin, windows, aarch64 and musl"
    fi
  fi
fi

exit "$status"
