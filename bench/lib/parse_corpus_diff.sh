#!/usr/bin/env bash
# Compare two parser or parser-exercise executables over the self-host corpus.
set -u

if [ "$#" -ne 2 ]; then
  echo "usage: $0 HOSTED_EXECUTABLE CANDIDATE_EXECUTABLE" >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/../.." && pwd)" || exit 2
case "$1" in /*) hosted="$1" ;; *) hosted="$PWD/$1" ;; esac
case "$2" in /*) candidate="$2" ;; *) candidate="$PWD/$2" ;; esac
if [ ! -x "$hosted" ] || [ ! -x "$candidate" ]; then
  echo "both arguments must be executable files" >&2
  exit 2
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/parse_corpus_diff.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT
cd "$root" || exit 2
agree=0
differ=0
compare() {
  local label="$1" hs cs
  shift
  perl -e 'alarm 30; exec @ARGV or exit 127' -- "$hosted" "$@" </dev/null >"$work/hosted.out" 2>"$work/hosted.err"
  hs=$?
  perl -e 'alarm 30; exec @ARGV or exit 127' -- "$candidate" "$@" </dev/null >"$work/candidate.out" 2>"$work/candidate.err"
  cs=$?
  if [ "$hs" -ne 142 ] && [ "$cs" -ne 142 ] && [ "$hs" -eq "$cs" ] && cmp -s "$work/hosted.out" "$work/candidate.out" && cmp -s "$work/hosted.err" "$work/candidate.err"; then
    printf 'agree %s\n' "$label"
    agree=$((agree + 1))
  else
    printf 'differ %s (status %s/%s; stdout ' "$label" "$hs" "$cs"
    if cmp -s "$work/hosted.out" "$work/candidate.out"; then printf 'equal'; else printf 'different'; fi
    printf '; stderr '
    if cmp -s "$work/hosted.err" "$work/candidate.err"; then printf 'equal'; else printf 'different'; fi
    printf ')\n'
    differ=$((differ + 1))
    if [ -n "${PARSE_CORPUS_DIFF_DIR:-}" ]; then
      local evidence="$PARSE_CORPUS_DIFF_DIR/case-$differ"
      mkdir -p "$evidence"
      printf '%s\n' "$label" >"$evidence/input.txt"
      printf '%s\n' "$hs" >"$evidence/hosted.status"
      printf '%s\n' "$cs" >"$evidence/candidate.status"
      cp "$work/hosted.out" "$work/hosted.err" "$work/candidate.out" "$work/candidate.err" "$evidence/"
    fi
  fi
}
compare '<no argument>'
while IFS= read -r -d '' file; do
  compare "$file" "$file"
done < <(find src samples/iyi bench/fixtures -type f -name '*.iyi' -print0)
printf 'summary: %s agree, %s differ\n' "$agree" "$differ"
[ "$differ" -eq 0 ]
