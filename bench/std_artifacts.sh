#!/usr/bin/env bash
# Run the source/artifact comparisons, optionally partitioned across CI jobs.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
export LC_ALL=C
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
  [ -f "$source" ] && sources+=("bench/${source##*/}")
done
[ "${#sources[@]}" -gt 0 ] || { echo 'empty artifact source inventory' >&2; exit 2; }
[ "$count" -le "${#sources[@]}" ] || { echo 'artifact shard would be empty' >&2; exit 2; }
# Both planning and execution use this position-based assignment.
assigned_shard() { echo $(( $1 % count + 1 )); }
if [ "$phase" = --plan ]; then
  i=0
  for source in "${sources[@]}"; do
    printf '%s\t%s\n' "$(assigned_shard "$i")" "$source"
    i=$((i + 1))
  done
  exit 0
fi
. "$REPO/bench/darwin_frames.sh"
IYI="${IYI:-$REPO/bin/iyi}"
receipt=${STD_ARTIFACT_RECEIPT:-}
if [ -n "$receipt" ]; then
  case "$receipt" in /*|[A-Za-z]:/*) ;; *) receipt="$PWD/$receipt" ;; esac
  revision=${STD_ARTIFACT_REVISION:-}; run_id=${STD_ARTIFACT_RUN_ID:-}; compiler_hash=${STD_ARTIFACT_COMPILER_SHA256:-}
  [ -n "$revision" ] && [ -n "$run_id" ] && [ -n "$compiler_hash" ] || { echo 'receipt metadata is required' >&2; exit 2; }
  tab=$(printf '\t')
  case "$revision$run_id$compiler_hash" in *"$tab"*|*'
'*) echo 'invalid receipt metadata' >&2; exit 2 ;; esac
  metadata=$(printf 'meta\t%s\t%s\t%s\t%s\t%s' "$revision" "$run_id" "$compiler_hash" "$shard" "$count")
  if [ -e "$receipt" ]; then
    IFS= read -r existing < "$receipt" || { echo 'empty receipt' >&2; exit 2; }
    [ "$existing" = "$metadata" ] || { echo 'receipt metadata mismatch' >&2; exit 2; }
  else
    printf '%s\n' "$metadata" > "$receipt" || exit 2
  fi
fi
# Builds need a short private root. Native binaries retain the caller's cwd.
work_root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT) work_root=$(cygpath -u "$work_root") ;;
esac
WORK=$(mktemp -d "$work_root/iyi-art.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tmp" "$WORK/cache" || exit 2
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    REPO=$(cygpath -m "$REPO"); WORK=$(cygpath -m "$WORK") ;;
esac
export TMPDIR="$WORK/tmp" TMP="$WORK/tmp" TEMP="$WORK/tmp" IYI_CACHE_DIR="$WORK/cache"
status=0
record() {
  verdict=$1; source_status=$2; artifact_status=$3
  elapsed=$(( $(date +%s) - started ))
  printf 'artifact-end\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$phase" "$target" "$relative" "$verdict" "$source_status" "$artifact_status" "$elapsed"
  if [ -n "$receipt" ]; then
    printf 'unit\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$phase" "$target" "$relative" "$verdict" "$source_status" "$artifact_status" "$elapsed" >> "$receipt" || exit 2
  fi
  [ "$verdict" = success ] || status=1
}
run_unit() {
  target=$1; relative=$2; source="$REPO/$relative"
  name=$(basename "$source" .iyi)
  work="$WORK/$phase/$target/$name"
  mkdir -p "$work/mods" || exit 2
  started=$(date +%s)
  printf 'artifact-begin\t%s\t%s\t%s\n' "$phase" "$target" "$relative"
  if [ "$phase" = native ]; then
    (cd "$work" && "$IYI" build --emit-iyimod mods -o from-source "$source") > "$work/emit.log" 2>&1
    emit_status=$?
    if [ "$emit_status" -ne 0 ]; then
      why=$(grep -m1 -E 'Error|BUG' "$work/emit.log" | cut -c1-140)
      [ -n "$why" ] || why="no Error line; it ended: $(tail -3 "$work/emit.log" | tr '\n' ' ' | cut -c1-200)"
      echo " $name: cannot write its artifacts: $why"
      record failure - -; return
    fi
    (cd "$work" && "$IYI" build --use-iyimod mods -o from-artifact "$source") > "$work/use.log" 2>&1
    use_status=$?
    if [ "$use_status" -ne 0 ]; then
      said=$(grep -m1 -E 'Error|BUG|undefined' "$work/use.log")
      [ -n "$said" ] || said="exits $use_status: $(tail -n 1 "$work/use.log")"
      echo " $name: $(printf '%s' "$said" | cut -c1-140)"
      record failure - -; return
    fi
    "$work/from-source" > "$work/source.out" 2>&1; source_status=$?
    "$work/from-artifact" > "$work/artifact.out" 2>&1; artifact_status=$?
    if [ "$source_status" -ne "$artifact_status" ]; then
      echo " $name: exits $artifact_status from its artifacts and $source_status from source"
      failed_out="$work/source.out"
      [ "$artifact_status" -ne 0 ] && failed_out="$work/artifact.out"
      tail -n 6 "$failed_out" | sed 's/^/  /'
      record failure "$source_status" "$artifact_status"; return
    fi
    case "$name" in
      std_big_exercise|std_gc_exercise|std_time_exercise|std_weak_ref_exercise)
        record success "$source_status" "$artifact_status"; return ;;
    esac
    without_frames < "$work/source.out" > "$work/source.cmp"
    without_frames < "$work/artifact.out" > "$work/artifact.cmp"
    if ! cmp -s "$work/source.cmp" "$work/artifact.cmp"; then
      echo " $name: runs differently from its artifacts"
      diff "$work/source.cmp" "$work/artifact.cmp" | sed -n '1,6p' | sed 's/^/  /'
      record failure "$source_status" "$artifact_status"; return
    fi
    record success "$source_status" "$artifact_status"
  else
    (cd "$work" && "$IYI" build --no-codegen --target "$target" --emit-iyimod mods -o out "$source") > "$work/emit.log" 2>&1
    emit_status=$?
    if [ "$emit_status" -ne 0 ]; then
      echo " $target $name: cannot write its artifacts: $(grep -m1 -E 'Error|BUG' "$work/emit.log" | cut -c1-120)"
      record failure - -; return
    fi
    (cd "$work" && "$IYI" build --no-codegen --target "$target" --use-iyimod mods -o out2 "$source") > "$work/use.log" 2>&1
    use_status=$?
    if [ "$use_status" -ne 0 ]; then
      echo " $target $name: $(grep -m1 -E 'Error|BUG' "$work/use.log" | cut -c1-120)"
      record failure - -; return
    fi
    record success - -
  fi
}
if [ "$phase" = native ]; then targets=host; else targets='aarch64-darwin x86_64-windows-msvc aarch64-linux-gnu x86_64-linux-musl'; fi
for target in $targets; do
  i=0
  for relative in "${sources[@]}"; do
    if [ "$(assigned_shard "$i")" -eq "$shard" ]; then run_unit "$target" "$relative"; fi
    i=$((i + 1))
  done
done
if [ "$status" -eq 0 ]; then
  echo " artifact $phase shard $shard/$count passed"
else
  echo " FAIL: artifact $phase shard $shard/$count failed"
fi
exit "$status"
