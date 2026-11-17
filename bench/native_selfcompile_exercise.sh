#!/bin/bash
# Self-compile scoreboard (SPEC 2.2, slice B3 step 2): how far the compiler written in iyi gets on its own source with the
# native back end. iyi-compile-native is built by ./bin/iyi from its own source. Every src/iyi/*.iyi and src/compiler/**/*.iyi
# is probed alone as the root of its own require closure, as bench/selfhost_prelude_exercise.sh probes the prelude, with
# --probe-phase. The whole programs compile_native.iyi and stage1.iyi are then built, not probed. No LLVM and no host tool
# take part: the probe reaches link through the native linker only.
#
# Phases, in order: none, parse, semantic, codegen, link. "reached" is the last phase that passed. A refusal the probe prints
# as "<phase>: fail: ..." is in that phase. A refusal printed as "Error: ..." after a pass is in the next phase, since the
# probe prints no fail line for it.
#
# Floor: bench/native_selfcompile.floor, one "<repo file> <reached phase>" per file. A phase may only rise: a file below its
# floor fails the gate, and a file missing from the floor fails it too. NATIVE_SELFCOMPILE_RAISE=1 writes the floor from this
# run, keeping the higher of the old and the new phase. NATIVE_SELFCOMPILE_TABLE=<path> also writes the report there.
#
# Mutations: a source file that reaches codegen gets an instance variable of an undefined type, and must fall below its floor.
# A patch that changes nothing is refused by name, with exit 3, and does not count.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IYI="$REPO/bin/iyi"
TOOL_SRC="$REPO/src/compiler/tools/compile_native.iyi"
FLOOR="$REPO/bench/native_selfcompile.floor"
. "$REPO/bench/lib/mutation.sh"

WORK="$(mktemp -d /tmp/iyi-selfcompile.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/probe" "$WORK/exe"
tool="$WORK/bin/iyi-compile-native"
status=0

rank_of() {
  case "$1" in
    none) echo 0 ;;
    parse) echo 1 ;;
    semantic) echo 2 ;;
    codegen) echo 3 ;;
    link) echo 4 ;;
    *) echo -1 ;;
  esac
}

next_phase() {
  case "$1" in
    none) echo parse ;;
    parse) echo semantic ;;
    semantic) echo codegen ;;
    codegen) echo link ;;
    *) echo "" ;;
  esac
}

# Writes the checkout and the scratch directory as <repo> and <work>, so a refusal line reads the same on every machine.
normalise() {
  awk -v repo="$REPO" -v work="$WORK" '{ gsub(repo, "<repo>"); gsub(work, "<work>"); print }'
}

# probe_one FILE NAME: sets REACHED, REFUSED_IN and REFUSAL for one file, probed alone with --probe-phase.
probe_one() {
  local target="$1" name="$2" log="$WORK/probe/$2.log" rc fail_line
  (cd "$WORK" && IYI_PATH="$REPO/src" "$tool" "$target" -o "$WORK/exe/$name" --probe-phase --prelude >"$log" 2>&1)
  rc=$?
  REACHED=$(awk '/^\[phase\] (parse|semantic|codegen|link): pass/ { r = $2; sub(":", "", r) } END { print (r == "" ? "none" : r) }' "$log")
  REFUSED_IN=""
  REFUSAL=""
  fail_line=$(awk '/^(parse|semantic|codegen|link): fail: / { print; exit }' "$log")
  if [ -n "$fail_line" ]; then
    REFUSED_IN=$(printf '%s\n' "$fail_line" | awk -F: '{ print $1 }')
    REFUSAL="$fail_line"
  else
    fail_line=$(awk '/^(Error|iyi-compile-native):/ { print; exit }' "$log")
    if [ -n "$fail_line" ]; then
      REFUSED_IN=$(next_phase "$REACHED")
      REFUSAL="$fail_line"
    elif [ "$rc" -ne 0 ]; then
      REFUSED_IN=$(next_phase "$REACHED")
      REFUSAL="exit $rc with no refusal line"
    fi
  fi
  if [ -n "$REFUSAL" ]; then REFUSAL=$(printf '%s\n' "$REFUSAL" | normalise); fi
}

echo "== 1. build iyi-compile-native from its source with ./bin/iyi"
if ! "$IYI" build -o "$tool" "$TOOL_SRC" >"$WORK/build.log" 2>&1; then
  echo "FAIL: ./bin/iyi could not build $TOOL_SRC"
  awk '/^Error/ { print; exit }' "$WORK/build.log"
  exit 1
fi
echo "   built iyi-compile-native from $TOOL_SRC"
tool_libs=$(otool -L "$tool" | awk 'NR > 1 { print $1 }')
if [ "$tool_libs" = "/usr/lib/libSystem.B.dylib" ]; then
  echo "   links only /usr/lib/libSystem.B.dylib"
else
  echo "FAIL: iyi-compile-native links more than libSystem: $tool_libs"
  exit 1
fi

echo "== 2. every src/iyi/*.iyi and src/compiler/**/*.iyi, probed alone with the native back end"
shopt -s globstar nullglob
results="$WORK/results.tsv"
: >"$results"
for f in "$REPO"/src/iyi/*.iyi "$REPO"/src/compiler/**/*.iyi; do
  rel="${f#$REPO/}"
  name=$(printf '%s' "$rel" | awk '{ gsub("/", "_"); print }')
  probe_one "$f" "$name"
  printf '%s\t%s\t%s\t%s\n' "$rel" "$REACHED" "$REFUSED_IN" "$REFUSAL" >>"$results"
  echo "   $rel: reached $REACHED${REFUSED_IN:+, refused in $REFUSED_IN}${REFUSAL:+: $REFUSAL}"
done
echo "   probed $(awk 'END { print NR }' "$results") files"

echo "== 3. whole programs, built to an executable (not probed)"
for rel in src/compiler/tools/compile_native.iyi src/compiler/stage1.iyi; do
  base=$(basename "$rel" .iyi)
  if (cd "$WORK" && IYI_PATH="$REPO/src" "$tool" "$REPO/$rel" -o "$WORK/exe/whole_$base" --prelude >"$WORK/whole_$base.log" 2>&1); then
    outcome="built"
  else
    outcome="refused: $(awk '/^((parse|semantic|codegen|link): fail: |Error:|iyi-compile-native:|iyi: panic:)/ { print; exit }' "$WORK/whole_$base.log" | normalise)"
  fi
  printf '%s\t%s\n' "$rel" "$outcome" >>"$WORK/whole.tsv"
  echo "   $rel: $outcome"
done

# report: the per-directory table, the whole programs and the ten most frequent first refusals, as markdown.
report() {
  echo "# Self-compile scoreboard"
  echo
  echo "Generated by \`bench/native_selfcompile_exercise.sh\`; do not edit by hand. The compiler written in iyi, built by"
  echo "\`./bin/iyi\`, probes every file under \`src/iyi\` and \`src/compiler\` alone with the native back end (\`--probe-phase\`),"
  echo "so no LLVM and no host tool take part. \"reached\" is the last phase that passed. The per-file phase is the floor in"
  echo "\`bench/native_selfcompile.floor\`, and it may only rise."
  echo
  echo "## Files per directory"
  echo
  echo "| Directory | Files | none | parse | semantic | codegen | link |"
  echo "|---|---:|---:|---:|---:|---:|---:|"
  awk -F'\t' '
    { d = $1; sub(/\/[^\/]*$/, "", d); files[d]++; at[d SUBSEP $2]++ }
    END {
      split("none parse semantic codegen link", order, " ")
      for (d in files) {
        line = d " " files[d]
        for (i = 1; i <= 5; i++) line = line " " (at[d SUBSEP order[i]] + 0)
        print line
      }
    }' "$results" | sort | awk '{ printf "| %s | %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6, $7 }'
  awk -F'\t' '
    { files++; at[$2]++ }
    END {
      printf "| **all** | %d | %d | %d | %d | %d | %d |\n", files, at["none"] + 0, at["parse"] + 0, at["semantic"] + 0, at["codegen"] + 0, at["link"] + 0
    }' "$results"
  echo
  echo "## Whole programs"
  echo
  awk -F'\t' '{ printf "- `%s`: %s\n", $1, $2 }' "$WORK/whole.tsv"
  echo
  echo "## The ten most frequent first refusals"
  echo
  awk -F'\t' 'NF && $4 != "" { print $4 }' "$results" | sort | uniq -c | sort -rn | awk 'NR <= 10 { n = $1; $1 = ""; sub(/^ /, ""); printf "%d. %s times: `%s`\n", NR, n, $0 }'
  echo
  echo "## Refused files"
  echo
  awk -F'\t' '$4 != "" { printf "- `%s` (%s): %s\n", $1, $3, $4 }' "$results"
}

echo "== 4. report"
report
if [ -n "${NATIVE_SELFCOMPILE_TABLE:-}" ]; then
  report >"$NATIVE_SELFCOMPILE_TABLE"
  echo "   wrote $NATIVE_SELFCOMPILE_TABLE"
fi

echo "== 5. floor: a file's reached phase may only rise"
if [ -n "${NATIVE_SELFCOMPILE_RAISE:-}" ]; then
  awk -F'[ \t]+' '
    BEGIN { rank["none"] = 0; rank["parse"] = 1; rank["semantic"] = 2; rank["codegen"] = 3; rank["link"] = 4 }
    NR == FNR { if ($0 !~ /^#/ && NF) old[$1] = $2; next }
    { keep[$1] = ($1 in old && rank[old[$1]] > rank[$2]) ? old[$1] : $2 }
    END { for (f in keep) print f " " keep[f] }' "${FLOOR}" "$results" 2>/dev/null | sort >"$WORK/floor.new" || true
  if [ ! -s "$WORK/floor.new" ]; then
    awk -F'\t' '{ print $1 " " $2 }' "$results" | sort >"$WORK/floor.new"
  fi
  {
    echo "# native self-compile floor: <repo file> <reached phase>. A phase may only rise."
    echo "# Raise with NATIVE_SELFCOMPILE_RAISE=1 bash bench/native_selfcompile_exercise.sh (keeps the higher phase)."
    cat "$WORK/floor.new"
  } >"$FLOOR"
  echo "   wrote $(awk 'END { print NR }' "$WORK/floor.new") floors to $FLOOR"
else
  if [ ! -f "$FLOOR" ]; then
    echo "FAIL: no floor at $FLOOR"
    status=1
  else
    floor_out=$(awk -F'[ \t]+' '
      BEGIN { rank["none"] = 0; rank["parse"] = 1; rank["semantic"] = 2; rank["codegen"] = 3; rank["link"] = 4 }
      NR == FNR { if ($0 !~ /^#/ && NF) floor[$1] = $2; next }
      {
        if (!($1 in floor)) { print "  NEW " $1 " reached " $2 ", not in the floor"; bad = 1; next }
        if (rank[$2] < rank[floor[$1]]) { print "  REGRESSION " $1 ": reached " $2 ", floor " floor[$1]; bad = 1 }
        else if (rank[$2] > rank[floor[$1]]) raised++
      }
      END {
        if (raised) print "  " raised " files reach a phase above their floor (NATIVE_SELFCOMPILE_RAISE=1 raises it)"
        exit bad
      }' "$FLOOR" "$results") || status=1
    if [ -n "$floor_out" ]; then echo "$floor_out"; fi
    if [ "$status" -eq 0 ]; then echo "   every file reaches its floor or better"; else echo "FAIL: a file fell below its floor, or is missing from it"; fi
  fi
fi

echo "== 6. mutation proofs: the gate must go red when a file that reaches semantic or codegen regresses"
mut_caught=0
mut_run=0
mut_rel=""
while IFS=$'\t' read -r rel reached; do
  case "$reached" in codegen|link|semantic) ;; *) continue ;; esac
  if awk '/^(pub )?(class|struct) / { found = 1 } END { exit !found }' "$REPO/$rel"; then
    mut_rel="$rel"
    break
  fi
done < <(awk -F'\t' '{ print $1 "\t" $2 }' "$results")
if [ -z "$mut_rel" ]; then
  echo "  FAIL: no file that reaches codegen has a class or struct to mutate"
  status=1
else
  mut_line=$(awk '/^(pub )?(class|struct) / { print; exit }' "$REPO/$mut_rel")
  mut_floor=$(awk -v f="$mut_rel" '$1 == f { print $2 }' "$FLOOR")
  echo "  mutating $mut_rel (floor $mut_floor): $mut_line"
  mutant_check() {
    probe_one "$REPO/$mut_rel" mutant_probe
    [ "$(rank_of "$REACHED")" -ge "$(rank_of "$mut_floor")" ]
  }
  mut_run=$((mut_run + 1))
  if prove_mutation "an undefined instance variable type falls below the floor" "$REPO/$mut_rel" \
      "$mut_line" "$mut_line"$'\n'"  @native_selfcompile_probe : UndefinedMutantType12345" -- mutant_check; then
    mut_caught=$((mut_caught + 1))
  else
    status=1
  fi
fi
mut_run=$((mut_run + 1))
( prove_mutation "a patch that changes nothing" "$REPO/$mut_rel" "$mut_line" "$mut_line" -- true ) >"$WORK/noop.log" 2>&1
noop_rc=$?
if [ "$noop_rc" = 3 ]; then
  echo "  refused: a patch that changes nothing (exit 3, not counted)"
else
  echo "  FAIL: a patch that changes nothing was not refused (exit $noop_rc)"
  status=1
fi
mut_run=$((mut_run - 1))
echo "  Mutation summary: $mut_caught/$mut_run source mutations caught (undefined instance variable type in $mut_rel)"
if [ "$mut_caught" -ne "$mut_run" ]; then status=1; fi

echo
if [ "$status" -eq 0 ]; then
  echo "ALL NATIVE SELFCOMPILE CHECKS PASSED!"
else
  echo "SOME NATIVE SELFCOMPILE CHECKS FAILED"
fi
exit "$status"
