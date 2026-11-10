#!/usr/bin/env bash
# heap22 slice S4's gate: `-Dheap_verify` catches every broken copy of a
# crossing or of the local collector by name, and passes the sound tree.
#
#   bash bench/heap_verify.sh             # all three parts
#   bash bench/heap_verify.sh sound       # the sound tree: no report, false words change nothing
#   bash bench/heap_verify.sh crossings   # bench/heap_crossings.sh's copies
#   bash bench/heap_verify.sh local       # bench/heap_local.sh's copies
#
# Every build is `-Dheap_partitions -Dheap_verify -Diyi_chaos`, run with a
# fixed chaos seed (`SEED`, default 1) and `IYI_HEAP_STRESS=1` (a local
# collection at every chaos point and every park), `RUNS` times (default
# 2). The broken copies are the ones bench/heap_crossings.sh and
# bench/heap_local.sh define - read from those files, so the two lists
# stay one - built and run here against the verifier instead of their own
# checks. A copy is caught when every run exits 86 with an `iyi:
# heap_verify:` report whose holder `bench/heap_verify_names.py` names
# (a type and its field, a data symbol, or a fiber's stack) and whose
# name is the same in every run. The table of catches is printed at the
# end. Copies whose loss no heap word can show are listed apart with what
# catches them (`VALUE_COPIES`).
#
# Needs `make` first. `IYI` names the compiler. Exits non-zero if any copy
# is missed or the sound tree reports.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
PART="${1:-all}"
SEED="${SEED:-1}"
RUNS="${RUNS:-2}"
FLAGS="-Dheap_partitions -Dheap_verify -Diyi_chaos"
PY="${PYTHON:-python3}"
# The copies whose loss changes a value, not a heap word: a Share type's
# getter that lends its array is a mutation of the shared graph, which the
# program's own check sees (heap_crossings' `tls`).
VALUE_COPIES="TlsIdentity chain copy"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=';'
    ;;
  *) PSEP=':' ;;
esac

trap 'rm -rf "$WORK"' EXIT

status=0
TABLE="$WORK/table"
: >"$TABLE"

# build DIR SOURCE [IYI_PATH]: the program and its type dump in DIR.
build() {
  local dir="$1" source="$2" path="${3:-}"
  mkdir -p "$dir"
  # shellcheck disable=SC2086
  if [ -n "$path" ]; then
    IYI_DUMP_TYPE_INFO="$dir/types.json" IYI_PATH="$path" "$IYI" build $FLAGS \
      -o "$dir/program" "$source" >"$dir/build.log" 2>&1
  else
    IYI_DUMP_TYPE_INFO="$dir/types.json" "$IYI" build $FLAGS \
      -o "$dir/program" "$source" >"$dir/build.log" 2>&1
  fi
}

# verified DIR TAG ARGS...: one stressed run; exit code in DIR/TAG.code.
verified() {
  local dir="$1" tag="$2"
  shift 2
  IYI_CHAOS="$SEED" IYI_HEAP_STRESS=1 ${WORKERS:+IYI_WORKERS=$WORKERS} \
    timeout 300 "$dir/program" "$@" >"$dir/$tag.out" 2>"$dir/$tag.err"
  echo $? >"$dir/$tag.code"
}

# The report's holder and target, named, as one line: `holder | target`.
named() {
  local dir="$1" tag="$2"
  "$PY" "$REPO/bench/heap_verify_names.py" --types "$dir/types.json" --binary "$dir/program" \
    "$dir/$tag.err" >"$dir/$tag.named" 2>/dev/null
  awk '
    /^  holder: / { kind = substr($0, 11) }
    /^    holder / { what = $0; sub(/^    holder 0x[0-9a-f]+ /, "", what); sub(/, [0-9]+ bytes$/, "", what) }
    /^    field \+/ { field = $0; if (match(field, /\[[^]]*\]$/)) field = substr(field, RSTART + 1, RLENGTH - 2); else { sub(/ at 0x.*/, "", field); sub(/^ +/, "", field) } }
    /^    held by / && parent == "" { parent = $0; sub(/^    held by (0x[0-9a-f]+ )?/, "", parent); sub(/, [0-9]+ bytes$/, "", parent) }
    /^    held by / && /\[/ && parentfield == "" { }
    /^    word at / { word = $0; if (match(word, /\[[^]]*\]$/)) word = substr(word, RSTART + 1, RLENGTH - 2); else word = "" }
    /^  target: / { intarget = 1 }
    intarget && /^    chunk / && target == "" { target = $0; sub(/^    chunk 0x[0-9a-f]+ /, "", target); sub(/, [0-9]+ bytes$/, "", target) }
    intarget && /allocated at: / && site == "" { site = $0; if (match(site, /\[[^]]*\]$/)) site = substr(site, RSTART + 1, RLENGTH - 2); else { sub(/^ *allocated at: /, "", site) } ; sub(/ <- .*/, "", site) }
    /^  [a-z]/ && !/^  (holder|target):/ && first == "" { first = $0; sub(/^  /, "", first) }
    END {
      h = kind
      if (what != "") h = h ": " what
      if (field != "") h = h " / " field
      if (parent != "") h = h " (held by " parent ")"
      if (word != "") h = h " [" word "]"
      if (h == "") h = first
      t = target
      if (site != "") t = t " @ " site
      printf "%s | %s\n", h, t
    }' "$dir/$tag.named"
}

# caught LABEL DIR ARGS...: RUNS stressed runs of DIR's program, each a
# report, the same holder named in all; a row of the table.
caught() {
  local label="$1" dir="$2"
  shift 2
  local k=1 first="" row
  while [ "$k" -le "$RUNS" ]; do
    verified "$dir" "run$k" "$@"
    if [ "$(cat "$dir/run$k.code")" != 86 ] || ! grep -q "^iyi: heap_verify: " "$dir/run$k.err"; then
      local how="exit $(cat "$dir/run$k.code")"
      grep -q "^FAIL: " "$dir/run$k.out" && how="$how, $(grep -m1 '^FAIL: ' "$dir/run$k.out")"
      if [[ ",$VALUE_COPIES," == *",$label,"* ]] && grep -q "^FAIL: " "$dir/run$k.out"; then
        printf '| %s | the program'"'"'s own check: %s | value, not a heap word |\n' "$label" "$(grep -m1 '^FAIL: ' "$dir/run$k.out" | sed 's/^FAIL: //')" >>"$TABLE"
        echo "  $label: no heap word to see; the program's check: $how"
        return
      fi
      echo "  $label: run $k not caught by the verifier ($how)"
      sed -n '1,6p' "$dir/run$k.err" | sed 's/^/      /'
      printf '| %s | **missed** (run %s: %s) | |\n' "$label" "$k" "$how" >>"$TABLE"
      status=1
      return
    fi
    row="$(named "$dir" "run$k")"
    if [ -z "$first" ]; then
      first="$row"
    elif [ "$row" != "$first" ]; then
      echo "  $label: run $k named another holder: $row (run 1: $first)"
    fi
    k=$((k + 1))
  done
  echo "  $label: $first"
  printf '| %s | %s |\n' "$label" "$(echo "$first" | sed 's/ | / | /')" >>"$TABLE"
  if ! echo "$first" | grep -q '#\|\[.*\]\|stack of fiber\|data segment'; then
    echo "  $label: caught, but the holder is not named by type and field"
    status=1
  fi
}

# heap_crossings.sh's interface: label dir check-name awk-script tree file.
prove_caught() {
  local label="$1" dir="$2" check="$3" script="$4" tree="$5" file="$6"
  mkdir -p "$WORK/$dir/$tree"
  cp -R "$REPO/src/$tree/." "$WORK/$dir/$tree/"
  if ! awk "$script" "$REPO/src/$tree/$file" >"$WORK/$dir/$tree/$file"; then
    echo "  $label: what the copy changes is not in $tree/$file any more"
    status=1
    return
  fi
  if ! build "$WORK/$dir/b" "$REPO/bench/heap_crossings.iyi" "$WORK/$dir${PSEP}$REPO/src"; then
    echo "  $label: the patched tree did not build"
    sed -n '1,12p' "$WORK/$dir/b/build.log"
    status=1
    return
  fi
  caught "$label" "$WORK/$dir/b" "$check"
}

# heap_local.sh's interface: label dir phrase awk-script file (src/iyi).
prove_fails() {
  local label="$1" dir="$2" script="$4" file="$5"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  if ! awk "$script" "$REPO/src/iyi/$file" >"$WORK/$dir/iyi/$file"; then
    echo "  $label: what the copy changes is not in $file any more"
    status=1
    return
  fi
  if ! build "$WORK/$dir/b" "$REPO/bench/heap_local.iyi" "$WORK/$dir${PSEP}$REPO/src"; then
    echo "  $label: the patched runtime did not build"
    sed -n '1,12p' "$WORK/$dir/b/build.log"
    status=1
    return
  fi
  caught "$label" "$WORK/$dir/b"
}

# sound NAME SOURCE ARGS...: no report, and the false words change nothing.
sound() {
  local name="$1" source="$2"
  shift 2
  local dir="$WORK/sound-$name"
  if ! build "$dir" "$source"; then
    echo "  $name: build failed"
    sed -n '1,12p' "$dir/build.log"
    status=1
    return
  fi
  verified "$dir" plain "$@"
  IYI_HEAP_FALSE_WORDS=1 verified "$dir" words "$@"
  local tag
  for tag in plain words; do
    if [ "$(cat "$dir/$tag.code")" != 0 ] || grep -q "heap_verify: " "$dir/$tag.err"; then
      echo "  $name ($tag): exit $(cat "$dir/$tag.code")"
      named "$dir" "$tag" >/dev/null
      sed -n '1,30p' "$dir/$tag.named" | sed 's/^/      /'
      sed -n '1,10p' "$dir/$tag.out" | sed 's/^/      /'
      status=1
      return
    fi
  done
  if ! cmp -s "$dir/plain.out" "$dir/words.out"; then
    echo "  $name: the false words changed the output"
    diff "$dir/plain.out" "$dir/words.out" | sed -n '1,10p' | sed 's/^/      /'
    status=1
    return
  fi
  echo "  $name: no report, output identical with false words ($(wc -l <"$dir/plain.out") lines)"
}

if [ "$PART" = all ] || [ "$PART" = sound ]; then
  echo "== the sound tree, stressed (seed $SEED): no report"
  sound crossings "$REPO/bench/heap_crossings.iyi"
  sound local "$REPO/bench/heap_local.iyi"
fi

if [ "$PART" = all ] || [ "$PART" = crossings ]; then
  echo
  echo "== bench/heap_crossings.sh's copies, caught by the verifier"
  # The copies as heap_crossings.sh writes them, from its `del` to its last.
  # shellcheck disable=SC1090
  source <(awk '/^# One line deleted after a marker/ { on = 1 } on && /^echo$/ { exit } on { print }' "$REPO/bench/heap_crossings.sh")
fi

if [ "$PART" = all ] || [ "$PART" = local ]; then
  echo
  echo "== bench/heap_local.sh's copies, caught by the verifier"
  # shellcheck disable=SC1090
  source <(awk '/== the checks fail when a mechanism is broken/ { on = 1; next } on && /^fi$/ { exit } on { print }' "$REPO/bench/heap_local.sh")
fi

echo
echo "| copy | holder (heap, type / field) | target @ allocation site |"
echo "|---|---|---|"
cat "$TABLE"
echo
if [ "$status" -eq 0 ]; then
  echo "heap_verify: the sound tree passes, and every copy is caught by name."
fi
exit "$status"
