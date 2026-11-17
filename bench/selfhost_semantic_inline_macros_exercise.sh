#!/usr/bin/env bash
# Burn-down gate for inline macro expansion in the declarations pass (specification
# S1b-M). The pass expands each `{% if %}`, `{% for %}` and `{{ }}` site at the top
# level and in type bodies with the macro engine, parses the output in the site's
# file and declares what it makes.
#
# Every file is analysed bare (no prelude), with the closure of what it imports and
# requires, by the hosted front end's top-level pass (the oracle,
# bench/selfhost_semantic_inline_macros_oracle.cr, which keeps what a macro declares) and by the iyi port
# (bench/selfhost_semantic_inline_macros_exercise.iyi). Both print one text dump of
# the declarations the file makes, and a record agrees when both sides print it
# identically. The gate counts agreeing records per file.
#
# It also accounts for the file's own macro sites: the sites the scan finds at the
# top level and in type bodies (def bodies belong to the bodies slice), and how the
# pass went with each one the port visited. A site is expanded, refused by the
# engine (with its reason), or not reached. A refusal is printed, never dropped.
#
#   bash bench/selfhost_semantic_inline_macros_exercise.sh
#
# Verifies:
#   1. The oracle and the port's driver build.
#   2. Every bench/fixtures/seminl_*.iyi is dumped byte-identical by both sides, and
#      the port's pass refuses none of its sites.
#   3-6. Corpora burn-down: the port's own source (src/compiler), the prelude
#        (src/iyi), std (src/std) and the samples (samples/iyi). Each file's
#        agreeing-record count is checked against the committed floor
#        (bench/selfhost_semantic_inline_macros.floor), which may only rise. A file
#        the oracle cannot analyse is reported ORACLE and is not measured. A file the
#        port rejects counts zero and is reported PORT.
#   7. Guarded mutation proofs on the fixtures (bench/lib/mutation.sh).
#   8. Pipeline reach: hello and the reach fixture's root through the pipeline tool with the prelude, against
#      bench/selfhost_inline_reach.floor, with three mutation proofs on the reach fixture.
#
# Environment:
#   SEMINL_RAISE=1         write the floor up to the measured counts (never lower)
#   SEMINL_FILES=<f>       measure only the repo-relative paths listed in <f>
#   SEMINL_FLOOR=<f>       read and write this floor file instead of the default
#
# Exit status 0 when every check passes, 1 otherwise.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
REPO_NATIVE="$(native_path "$REPO")" || exit 1
export PWD="$REPO"
IYI="${IYI_COMPILER:-$REPO/bin/iyi}"
CRYSTAL="${CRYSTAL:-$REPO/bin/crystal}"
FLOOR_FILE="${SEMINL_FLOOR:-$REPO/bench/selfhost_semantic_inline_macros.floor}"
RAISE="${SEMINL_RAISE:-0}"
FILES_LIST="${SEMINL_FILES:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM
WORK_NATIVE="$(native_path "$WORK")" || exit 1
LC_ALL=C
export LC_ALL
export IYI_CACHE_DIR="$WORK_NATIVE/cache"
if [ "$HOST_OS" = darwin ]; then
  export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
  export LIBRARY_PATH="/opt/homebrew/opt/bdw-gc/lib:${LIBRARY_PATH:-}"
fi
export IYI_PATH="$REPO_NATIVE/src"

ORACLE="$WORK/oracle$EXE"
PORT="$WORK/port$EXE"
RESULTS="$WORK/results.tsv"
REFUSALS="$WORK/refusals.tsv"
VERDICTS="$WORK/verdicts.tsv"
status=0
: > "$RESULTS"
: > "$REFUSALS"

. "$REPO/bench/lib/mutation.sh"

# Splits a dump into records, one per "Type:" or "Def:" header line, each with its
# own property lines, joined onto one line with the record separator \036.
records() {
  awk '
    function flush() { if (cur != "") print cur }
    /^ *(Type|Def): / { flush(); cur = $0; next }
    { if (cur != "") cur = cur "\036" $0 }
    END { flush() }
  ' "$1"
}

# Number of records of FILE that also occur in REFERENCE, counted with multiplicity.
agreeing() {
  records "$1" | sort > "$WORK/agree_a"
  records "$2" | sort > "$WORK/agree_b"
  comm -12 "$WORK/agree_a" "$WORK/agree_b" | wc -l | tr -d ' '
}

echo "== 1. Building the hosted declaration oracle and the port's driver"
CRYSTAL_PATH="$REPO_NATIVE/src" "$CRYSTAL" build -Di_know_what_im_doing \
  -o "$WORK_NATIVE/oracle$EXE" "$REPO_NATIVE/bench/selfhost_semantic_inline_macros_oracle.cr" > "$WORK/oracle_build.log" 2>&1 \
  || { cat "$WORK/oracle_build.log"; echo "FAILED to build the oracle"; exit 1; }
"$IYI" build -o "$WORK_NATIVE/port$EXE" "$REPO_NATIVE/bench/selfhost_semantic_inline_macros_exercise.iyi" > "$WORK/port_build.log" 2>&1 \
  || { cat "$WORK/port_build.log"; echo "FAILED to build the port's driver"; exit 1; }
echo "  built: oracle, port driver"

echo
echo "== 2. Fixtures: every declaration dumped identically, and no site refused"
fixture_count=0
fixture_bad=0
total_matched=0
for fixture in "$REPO"/bench/fixtures/seminl_*.iyi; do
  rel="bench/fixtures/$(basename "$fixture")"
  fixture_count=$((fixture_count + 1))
  if ! "$ORACLE" "$REPO_NATIVE/$rel" > "$WORK/fx_o.txt" 2> "$WORK/fx_oe.txt"; then
    echo "  $rel: ORACLE REJECTS: $(head -n 1 "$WORK/fx_oe.txt")"
    fixture_bad=$((fixture_bad + 1)); status=1; continue
  fi
  if ! "$PORT" "$REPO_NATIVE/$rel" > "$WORK/fx_p.txt" 2> "$WORK/fx_pe.txt"; then
    echo "  $rel: PORT REJECTS: $(head -n 1 "$WORK/fx_pe.txt")"
    fixture_bad=$((fixture_bad + 1)); status=1; continue
  fi
  if ! "$PORT" --ledger "$REPO_NATIVE/$rel" > "$WORK/fx_l.txt" 2> "$WORK/fx_le.txt"; then
    echo "  $rel: PORT LEDGER REJECTS: $(head -n 1 "$WORK/fx_le.txt")"
    fixture_bad=$((fixture_bad + 1)); status=1; continue
  fi
  refused=$(awk '$1 == "refused_total" { print $2 }' "$WORK/fx_l.txt")
  if [ "$refused" != "0" ]; then
    echo "  $rel: the port refuses $refused site(s):"
    awk '$1 == "refused" { print "    " $0 }' "$WORK/fx_l.txt"
    fixture_bad=$((fixture_bad + 1)); status=1; continue
  fi
  if cmp -s "$WORK/fx_o.txt" "$WORK/fx_p.txt"; then
    n=$(agreeing "$WORK/fx_o.txt" "$WORK/fx_p.txt")
    total_matched=$((total_matched + n))
    echo "  $rel: identical ($n declarations, $(awk '$1 == "expanded_total" { print $2 }' "$WORK/fx_l.txt") sites expanded)"
  else
    echo "  $rel: DECLARATIONS DIFFER"
    diff "$WORK/fx_o.txt" "$WORK/fx_p.txt" | head -n 20
    fixture_bad=$((fixture_bad + 1)); status=1
  fi
done
echo "  Parity summary: $((fixture_count - fixture_bad))/$fixture_count fixtures identical ($total_matched declarations compared)"

# One file: its declarations against the oracle's, and its macro sites by outcome.
# Writes one row to RESULTS and its refusals to REFUSALS.
measure() {
  corpus="$1"
  rel="$2"
  abs="$REPO_NATIVE/$2"
  sites=0; expanded=0; refused=0; not_reached=0
  if "$PORT" --sites "$abs" > "$WORK/s.txt" 2> "$WORK/s.err"; then
    sites=$(awk '$1 == "site" && ($2 == "top" || $2 == "class") { n++ } END { print n + 0 }' "$WORK/s.txt")
  fi
  if "$PORT" --ledger "$abs" > "$WORK/l.txt" 2> "$WORK/l.err"; then
    expanded=$(awk '$1 == "expanded_total" { print $2 }' "$WORK/l.txt")
    refused=$(awk '$1 == "refused_total" { print $2 }' "$WORK/l.txt")
    awk -v f="$rel" -v c="$corpus" '$1 == "refused" { print c "\t" f "\t" $0 }' "$WORK/l.txt" >> "$REFUSALS"
  fi
  not_reached=$((sites - expanded - refused))
  [ "$not_reached" -lt 0 ] && not_reached=0
  if "$ORACLE" "$abs" > "$WORK/o.txt" 2> "$WORK/o.err"; then
    nodes=$(records "$WORK/o.txt" | wc -l | tr -d ' ')
    if "$PORT" "$abs" > "$WORK/p.txt" 2> "$WORK/p.err"; then
      matched=$(agreeing "$WORK/o.txt" "$WORK/p.txt")
      note="-"
    else
      matched=0
      note="PORT: $(head -n 1 "$WORK/p.err" | tr '\t' ' ')"
    fi
  else
    nodes=0
    matched=0
    note="ORACLE: $(head -n 1 "$WORK/o.err" | tr '\t' ' ')"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$corpus" "$rel" "$nodes" "$matched" \
    "$sites" "$expanded" "$refused" "$not_reached" "$note" >> "$RESULTS"
}

echo
if [ -n "$FILES_LIST" ]; then
  echo "== 3. Measuring the files listed in $FILES_LIST"
  while IFS= read -r rel; do
    case "$rel" in
      ""|"#"*) continue ;;
    esac
    measure subset "$rel"
  done < "$FILES_LIST"
else
  echo "== 3. Measuring the port's source, the prelude, std and the samples"
  find "$REPO/src/compiler" -name '*.iyi' | sort | while IFS= read -r f; do measure compiler "${f#$REPO/}"; done
  for f in "$REPO"/src/iyi/*.iyi; do measure prelude "${f#$REPO/}"; done
  for f in "$REPO"/src/std/*.iyi; do measure std "${f#$REPO/}"; done
  for f in "$REPO"/samples/iyi/*.iyi; do measure samples "${f#$REPO/}"; done
fi
echo "  $(wc -l < "$RESULTS" | tr -d ' ') files measured"

echo
echo "== 4. Checking each file against its committed floor"
verdicts() {
awk -F'\t' -v floorfile="$FLOOR_FILE" '
  BEGIN {
    while ((getline line < floorfile) > 0) {
      if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*$/) continue
      split(line, a, /[ \t]+/)
      floor[a[1]] = a[2] + 0
    }
  }
  {
    corpus = $1; rel = $2; nodes = $3 + 0; matched = $4 + 0; note = $9
    if (note ~ /^ORACLE/) verdict = "ORACLE"
    else if (!(rel in floor)) verdict = "NO FLOOR"
    else if (matched < floor[rel]) verdict = "BELOW FLOOR"
    else if (matched > floor[rel]) verdict = "RAISE THE FLOOR"
    else verdict = "ok"
    fl = (rel in floor) ? floor[rel] : "-"
    printf "%s\t%s\t%s\t%d\t%d\t%s\t%s\t%s\n", verdict, corpus, rel, nodes, matched, \
      (nodes > 0 ? sprintf("%.1f%%", 100 * matched / nodes) : "n/a"), fl, note
  }' "$RESULTS" > "$VERDICTS"
}
verdicts

fails=0
if [ "$RAISE" = 1 ]; then
  # Write each measured file's floor up to its count, never down; a file that is
  # not oracle-analysable keeps its old floor.
  awk -F'\t' -v floorfile="$FLOOR_FILE" '
    BEGIN {
      while ((getline line < floorfile) > 0) {
        if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*$/) continue
        split(line, a, /[ \t]+/)
        floor[a[1]] = a[2] + 0
      }
    }
    $9 !~ /^ORACLE/ { if (!($2 in floor) || $4 + 0 > floor[$2]) floor[$2] = $4 + 0 }
    END {
      for (k in floor) print k "\t" floor[k]
    }' "$RESULTS" | sort > "$WORK/floor.new"
  if [ -s "$WORK/floor.new" ]; then
    {
      echo "# Floor for bench/selfhost_semantic_inline_macros_exercise.sh: the agreeing declaration"
      echo "# records each file must keep. Only raise these (SEMINL_RAISE=1); never lower one."
      awk -F'\t' '{ printf "%s %s\n", $1, $2 }' "$WORK/floor.new"
    } > "$FLOOR_FILE"
    echo "  floor written to ${FLOOR_FILE#$REPO/}"
  fi
  verdicts
fi

awk -F'\t' '
  $1 == "BELOW FLOOR"     { printf "  BELOW FLOOR: %s matched %s, floor %s. A regression: restore the declaration or lower nothing.\n", $3, $5, $7; bad++ }
  $1 == "RAISE THE FLOOR" { printf "  RAISE THE FLOOR: %s matched %s, floor %s. Raise the floor (SEMINL_RAISE=1).\n", $3, $5, $7; bad++ }
  $1 == "NO FLOOR"        { printf "  NO FLOOR: %s has no floor entry. Add it (SEMINL_RAISE=1).\n", $3; bad++ }
  END { print bad + 0 }
' "$VERDICTS" > "$WORK/fails.txt"
awk -F'\t' '$1 == "BELOW FLOOR" || $1 == "RAISE THE FLOOR" || $1 == "NO FLOOR" { n++ } END { print n + 0 }' "$VERDICTS" > "$WORK/nfails.txt"
fails=$(cat "$WORK/nfails.txt")
awk '!/^[0-9]+$/' "$WORK/fails.txt"
echo "  $fails file(s) below or missing their floor"
if [ "$fails" -gt 0 ]; then
  status=1
fi

echo
echo "== 5. Per-file declaration parity and macro site accounting"
printf '  %-14s %-44s %6s %7s %6s %6s %8s %11s  %s\n' corpus file decls agree sites expd refused not_reached note
awk -F'\t' '{ printf "  %-14s %-44s %6s %7s %6s %6s %8s %11s  %s\n", $1, $2, $3, $4, $5, $6, $7, $8, substr($9, 1, 60) }' "$RESULTS" | sort

echo
echo "== 6. Corpus totals"
awk -F'\t' '
  {
    nodes[$1] += $3; matched[$1] += $4; count[$1] += 1
    sites[$1] += $5; expd[$1] += $6; refd[$1] += $7; nr[$1] += $8
    if ($9 ~ /^ORACLE/) oracle[$1] += 1
    if ($9 ~ /^PORT/) port[$1] += 1
  }
  END {
    n = 0
    for (k in nodes) keys[++n] = k
    for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (keys[j] < keys[i]) { t = keys[i]; keys[i] = keys[j]; keys[j] = t }
    for (i = 1; i <= n; i++) {
      k = keys[i]
      printf "  %-10s files %3d  oracle-failed %3d  port-failed %3d  declarations %6d agreeing %6d  sites top/class %4d expanded %4d refused %3d not reached %4d\n", \
        k, count[k], oracle[k] + 0, port[k] + 0, nodes[k], matched[k], sites[k], expd[k], refd[k], nr[k]
    }
  }' "$RESULTS"

echo
echo "== 6b. Refusals by reason (every refused site, with its file)"
if [ -s "$REFUSALS" ]; then
  awk -F'\t' '{
    split($3, parts, " ")
    reason = $3
    sub(/^refused [^ ]+ [0-9]+:[0-9]+ /, "", reason)
    count[reason] += 1
  }
  END { for (r in count) printf "  %4d  %s\n", count[r], r }' "$REFUSALS" | sort -rn
  awk -F'\t' '{ printf "  refused: %s %s\n", $2, $3 }' "$REFUSALS"
else
  echo "  none: the pass expanded every site it visited"
fi

check_inline_fixtures_diverge() {
  local probe="$WORK/mut_port$EXE" fixture rel rc refused baseline_refused died=0
  if ! "$IYI" build -o "$WORK_NATIVE/mut_port$EXE" "$REPO_NATIVE/bench/selfhost_semantic_inline_macros_exercise.iyi" > "$WORK/mut_build.log" 2>&1; then
    local saved
    saved=$(mktemp "${SEMINL_ARTIFACT_DIR:-$WORK}/invalid-inline-build.XXXXXX") || saved=""
    if [ -n "$saved" ]; then cp "$WORK/mut_build.log" "$saved"; fi
    echo "INVALID MUTATION: inline driver build failed${saved:+; compiler output: $saved}"
    cat "$WORK/mut_build.log"
    return 2
  fi
  for fixture in "$REPO"/bench/fixtures/seminl_*.iyi; do
    rel="bench/fixtures/$(basename "$fixture")"
    if ! "$ORACLE" "$REPO_NATIVE/$rel" > "$WORK/mut_o.txt" 2>"$WORK/mut_o.err" ||
       ! "$PORT" "$REPO_NATIVE/$rel" > "$WORK/base_p.txt" 2>"$WORK/base_p.err" ||
       ! cmp -s "$WORK/mut_o.txt" "$WORK/base_p.txt"; then
      echo "INVALID MUTATION: unmutated driver does not agree with the oracle for $rel"
      cat "$WORK/mut_o.err" "$WORK/base_p.err"
      return 2
    fi
    if ! "$PORT" --ledger "$REPO_NATIVE/$rel" > "$WORK/base_l.txt" 2>"$WORK/base_l.err"; then
      echo "INVALID MUTATION: baseline ledger failed for $rel"
      cat "$WORK/base_l.err"
      return 2
    fi
    baseline_refused=$(awk '$1 == "refused_total" { count++; value=$2 } END { if (count == 1) print value }' "$WORK/base_l.txt")
    if [ "$baseline_refused" != 0 ]; then
      echo "INVALID MUTATION: baseline ledger does not report zero refusals for $rel"
      return 2
    fi
    rc=0
    "$probe" "$REPO_NATIVE/$rel" > "$WORK/mut_p.txt" 2>"$WORK/mut_p.err" || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$#" -eq 2 ] && expected_refusal "$rc" "$WORK/mut_p.err" "$1" "$2"; then
        echo "decisive: $rel: expected refusal after baseline oracle agreement: $(refusal_note "$rc" "$WORK/mut_p.err")"
        return 1
      fi
      echo "INVALID OBSERVATION: inline driver exited $rc for $rel"
      cat "$WORK/mut_p.err"
      died=1
      continue
    fi
    if ! cmp -s "$WORK/mut_o.txt" "$WORK/mut_p.txt"; then
      echo "decisive: $rel: declarations differ from the oracle"
      return 1
    fi
    if ! "$probe" --ledger "$REPO_NATIVE/$rel" > "$WORK/mut_l.txt" 2>"$WORK/mut_l.err"; then
      echo "INVALID OBSERVATION: inline ledger failed for $rel"
      cat "$WORK/mut_l.err"
      died=1
      continue
    fi
    refused=$(awk '$1 == "refused_total" { count++; value=$2 } END { if (count == 1) print value }' "$WORK/mut_l.txt")
    case "$refused" in
      ""|*[!0-9]*) echo "INVALID OBSERVATION: malformed refusal count for $rel"; died=1; continue ;;
      0) ;;
      *) echo "decisive: $rel: the mutant refused $refused inline site(s)"; return 1 ;;
    esac
  done
  if [ "$died" -eq 1 ]; then return 2; fi
  return 0
}

echo
echo "== 7. Mutation proofs: patches to the port's inline expansion the fixtures must catch"
MUT_INL="$REPO/src/compiler/semantic/inline_macros.iyi"
MUT_SEM="$REPO/src/compiler/semantic/top_level.iyi"
MUTATIONS_RUN=0

prove_mutation "number literals lose non-default kind suffixes" "$REPO/src/compiler/syntax/ast.iyi" \
  "    if @kind != NumberKind::I32" \
  "    if false" \
  -- check_inline_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "an empty expansion is kept and a non-empty one dropped" "$MUT_INL" \
  "return nil if text.bytesize == 0" \
  "return nil if text.bytesize > 0" \
  -- check_inline_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "the expansion is parsed with no file, so its declarations are not the file's" "$MUT_INL" \
  "parser = Parser.new(text, filename, nil, scopes)" \
  "parser = Parser.new(text, \"\", nil, scopes)" \
  -- check_inline_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation_all "no spliced inline macro expansion is ever declared (top-level and type-body sites)" "$MUT_INL" \
  "out.concat(splice_inline_sites(inner, scope_name, filename, in_lib, normalizer, locals, bindings, facts, keep_empty))" \
  "out.concat([] of ASTNode)" \
  -- check_inline_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a required file finishes its pending ivars at once, before a later file declares them" "$MUT_SEM" \
  "inner.exp_nest = 1" \
  "inner.exp_nest = 0" \
  -- check_inline_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a site inside a lib body is parsed as an ordinary body" "$MUT_INL" \
  "parsed = in_lib ? parser.parse_lib_body : parser.parse" \
  "parsed = parser.parse" \
  -- check_inline_fixtures_diverge src/compiler/syntax/parser.iyi \
  "^Syntax error in .*seminl_lib\\.iyi:[0-9]+:[0-9]+: expecting keyword 'end', not 'EOF'$" || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

echo
echo "== 8. Pipeline reach: each root through the pipeline tool with the prelude, against bench/selfhost_inline_reach.floor"
REACH_FLOOR="$REPO/bench/selfhost_inline_reach.floor"
MUT_PROG="$REPO/src/compiler/lower/program.iyi"
# Both reports use the compiler's existing aarch64-darwin target on every
# host. IR emission runs the same typing and lowering without executing Mach-O.
run_typed_report() {
  local tool="$1" root="$2" kind="$3" tag="$4"
  local log="$WORK/${kind}_${tag}.log" output="$WORK/${kind}_${tag}.ir" rc=0 failure=""
  rm -f "$output"
  "$tool" "$REPO_NATIVE/$root" -o "$WORK_NATIVE/${kind}_${tag}.ir" \
    --pipeline typed --prelude --probe-phase --keep-going --emit ir > "$log" 2>&1 || rc=$?
  if ! grep -Fxq '[phase] bodies: pass' "$log" || ! grep -Fxq '[phase] lower: start' "$log"; then
    echo "INVALID: $kind report did not finish body typing for $root (status $rc)"
    cat "$log"
    return 2
  fi
  if [ "$rc" -eq 0 ]; then
    if [ ! -s "$output" ] || ! grep -Fxq '[phase] verify: pass' "$log"; then
      echo "INVALID: $kind report did not produce verified IR for $root"
      cat "$log"
      return 2
    fi
  elif [ "$rc" -eq 1 ]; then
    if grep -Fxq 'reached: bodies' "$log"; then
      failure=$(awk '/^lower: fail: / { print; exit }' "$log")
    elif grep -Fxq 'reached: lower' "$log"; then
      failure=$(awk '/^verify: fail: / { print; exit }' "$log")
    fi
    if [ -z "$failure" ]; then
      echo "INVALID: $kind report exited without a named lowering or verifier refusal for $root"
      cat "$log"
      return 2
    fi
    if [ "${_PM_ARMED:-0}" = 1 ] &&
       { [ ! -f "$WORK/base_${kind}_${tag}.failure" ] ||
         [ "$failure" != "$(cat "$WORK/base_${kind}_${tag}.failure")" ]; }; then
      echo "INVALID MUTATION: $kind report changed its baseline compiler refusal for $root"
      cat "$log"
      return 2
    fi
  else
    echo "INVALID: $kind report exited $rc for $root"
    cat "$log"
    return 2
  fi
  if [ "${_PM_ARMED:-0}" != 1 ]; then
    printf '%s' "$failure" > "$WORK/base_${kind}_${tag}.failure"
  fi
}

# Prints "<defs-reached> <no-record rows>" for a repo-relative root and tool.
reach_of() {
  local root="$1" tool="$2" tag="$3" log="$WORK/reach_$3.log" reach missing
  run_typed_report "$tool" "$root" reach "$tag" || return $?
  reach=$(awk '/^table: .* defs-reached=/ { sub(/.*defs-reached=/, ""); print $1; exit }' "$log")
  case "$reach" in
    ""|*[!0-9]*) echo "INVALID: missing defs-reached for $root"; cat "$log"; return 2 ;;
  esac
  missing=$(awk '/no record from the declarations pass/ { n++ } END { print n + 0 }' "$log")
  printf '%s %s\n' "$reach" "$missing"
}

# Checks each floor row (or only the root $2) against the pipeline tool $1. A root below its floor or with a fun that has
# no record fails. A floor below the measured count fails too, unless SEMINL_RAISE=1 writes the count up (never down).
check_reach() {
  local tool="$1" only="${2:-}" fail=0 root floor reach missing tag values row_ok
  while read -r root floor; do
    case "$root" in ""|\#*) continue ;; esac
    if [ -n "$only" ] && [ "$root" != "$only" ]; then continue; fi
    tag=$(basename "$root" .iyi)
    if [ "${_PM_ARMED:-0}" = 1 ] && [ ! -f "$WORK/base_reach_${tag}.ok" ]; then
      echo "INVALID MUTATION: no passing reach baseline for $root"
      return 2
    fi
    values="$(reach_of "$root" "$tool" "$tag")" || { echo "$values"; return 2; }
    set -- $values
    reach=$1
    missing=$2
    echo "  $root: defs-reached $reach (floor $floor), no-record rows $missing"
    row_ok=1
    if [ "$missing" -ne 0 ] || [ "$reach" -lt "$floor" ]; then
      echo "decisive: $root is below its reach floor or has missing declaration records"
      row_ok=0
      fail=1
    elif [ "$reach" -gt "$floor" ]; then
      if [ "$RAISE" = 1 ]; then
        awk -v r="$root" -v n="$reach" '$1 == r { $2 = n } { print }' "$REACH_FLOOR" > "$WORK/reach.floor.tmp" && mv "$WORK/reach.floor.tmp" "$REACH_FLOOR"
      else
        echo "decisive: $root reaches $reach, floor $floor (SEMINL_RAISE=1)"
        row_ok=0
        fail=1
      fi
    fi
    if [ "${_PM_ARMED:-0}" != 1 ] && [ "$row_ok" -eq 1 ]; then
      : > "$WORK/base_reach_${tag}.ok"
    fi
  done < "$REACH_FLOOR"
  return "$fail"
}

# The check the reach mutations must fail: the reach fixture's root through a pipeline tool built from the tree as it is.
check_reach_fixture() {
  local RAISE=0 probe="$WORK/mut_reach_tool$EXE"
  if ! "$IYI" build -o "$WORK_NATIVE/mut_reach_tool$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/mut_reach_build.log" 2>&1; then
    local saved
    saved=$(mktemp "${SEMINL_ARTIFACT_DIR:-$WORK}/invalid-reach-build.XXXXXX") || saved=""
    if [ -n "$saved" ]; then cp "$WORK/mut_reach_build.log" "$saved"; fi
    echo "INVALID MUTATION: reach tool build failed${saved:+; compiler output: $saved}"
    cat "$WORK/mut_reach_build.log"
    return 2
  fi
  check_reach "$probe" bench/fixtures/seminl_reach/root.iyi
}

echo "  building the pipeline tool"
if "$IYI" build -o "$WORK_NATIVE/reach_tool$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/reach_build.log" 2>&1; then
  check_reach "$WORK/reach_tool$EXE" || status=1
else
  echo "FAILED to build the pipeline tool"
  cat "$WORK/reach_build.log"
  status=1
fi

prove_mutation "the fixture's required file is parsed again instead of read from the pipeline's own tree" "$MUT_SEM" \
  "nodes = @program.unit_tree_or_parse(file)" \
  "nodes = Parser.new(File.read(file), file).parse" \
  -- check_reach_fixture || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "the pipeline's unit trees are registered under a key no require asks for" "$MUT_PROG" \
  "prog.unit_trees[normalize_path(mod_info.filename)] = mod_info.ast" \
  "prog.unit_trees[normalize_path(mod_info.filename) + \"~\"] = mod_info.ast" \
  -- check_reach_fixture || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a require looks up the pipeline's tree under a key that is never registered" "$MUT_SEM" \
  "if tree = @unit_trees[file]?" \
  "if tree = @unit_trees[file + \"~\"]?" \
  -- check_reach_fixture || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# 9. Single-macro-node bodies: a class, module or lib body that is one macro node is spliced, so the typer never refuses its
# macro node. Each fixture's top-level refusal count (root-refusals) stays at or below its ceiling in
# bench/selfhost_inline_refusals.floor. A ceiling is lowered only with SEMINL_RAISE=1, never raised.
REFUSAL_FLOOR="$REPO/bench/selfhost_inline_refusals.floor"
MUT_INL="$REPO/src/compiler/semantic/inline_macros.iyi"
MUT_TOP="$REPO/src/compiler/semantic/top_level.iyi"
MUT_MAIN="$REPO/src/compiler/semantic/main_visitor.iyi"
MUT_TYPE="$REPO/src/compiler/semantic/type_nodes.iyi"

check_refusals() {
  local tool="$1" fail=0 invalid=0 report_rc root ceiling tag log refusals row_ok
  while read -r root ceiling; do
    case "$root" in ""|\#*) continue ;; esac
    tag=$(basename "$root" .iyi)
    if [ "${_PM_ARMED:-0}" = 1 ] && [ ! -f "$WORK/base_refusals_${tag}.ok" ]; then
      echo "INVALID MUTATION: no passing refusal baseline for $root"
      return 2
    fi
    report_rc=0
    run_typed_report "$tool" "$root" refusals "$tag" || report_rc=$?
    if [ "$report_rc" -ne 0 ]; then
      if [ "${_PM_ARMED:-0}" = 1 ]; then invalid=1; continue; fi
      return 2
    fi
    log="$WORK/refusals_${tag}.log"
    refusals=$(awk '/^table: .* root-refusals=/ { sub(/.*root-refusals=/, ""); print $1; exit }' "$log")
    case "$refusals" in
      ""|*[!0-9]*) echo "INVALID: missing root-refusals for $root"; cat "$log"; return 2 ;;
    esac
    echo "  $root: root-refusals $refusals (ceiling $ceiling)"
    row_ok=1
    if [ "$refusals" -gt "$ceiling" ]; then
      echo "decisive: $root exceeds its root-refusals ceiling"
      row_ok=0
      fail=1
    elif [ "$refusals" -lt "$ceiling" ]; then
      if [ "$RAISE" = 1 ]; then
        awk -v r="$root" -v n="$refusals" '$1 == r { $2 = n } { print }' "$REFUSAL_FLOOR" > "$WORK/refusal.floor.tmp" && mv "$WORK/refusal.floor.tmp" "$REFUSAL_FLOOR"
      else
        echo "decisive: $root refuses $refusals, ceiling $ceiling (SEMINL_RAISE=1)"
        row_ok=0
        fail=1
      fi
    fi
    if [ "${_PM_ARMED:-0}" = 1 ] && [ "$row_ok" -eq 0 ]; then
      return 1
    fi
    if [ "${_PM_ARMED:-0}" != 1 ] && [ "$row_ok" -eq 1 ]; then
      : > "$WORK/base_refusals_${tag}.ok"
    fi
  done < "$REFUSAL_FLOOR"
  if [ "$invalid" -eq 1 ]; then return 2; fi
  return "$fail"
}

check_body_lowering() {
  local tool="$1" output="$WORK/body_lower$EXE" rc=0
  rm -f "$WORK/body_lower.ir" "$output"
  "$tool" "$REPO_NATIVE/bench/fixtures/seminl_reach/body_lower_if.iyi" \
    -o "$WORK_NATIVE/body_lower.ir" --pipeline typed --probe-phase --emit ir > "$WORK/body_lower.log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] || [ ! -s "$WORK/body_lower.ir" ] ||
     ! grep -Fxq '[phase] verify: pass' "$WORK/body_lower.log"; then
    echo "INVALID: single macro body did not produce verified IR (status $rc)"
    cat "$WORK/body_lower.log"
    return 2
  fi
  if [ "$HOST_ID" = darwin-arm64 ]; then
    rc=0
    "$tool" "$REPO_NATIVE/bench/fixtures/seminl_reach/body_lower_if.iyi" \
      -o "$WORK_NATIVE/body_lower$EXE" --pipeline typed --probe-phase > "$WORK/body_lower_native.log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] || [ ! -x "$output" ]; then
      echo "INVALID: single macro body native build failed (status $rc)"
      cat "$WORK/body_lower_native.log"
      return 2
    fi
    "$output" > "$WORK/body_lower.out" 2>&1 || {
      echo "INVALID: single macro body execution failed"
      cat "$WORK/body_lower.out"
      return 2
    }
  else
    host_limited "inline macros: single-body native linking and execution require Darwin arm64"
  fi
}

check_macro_mixed_temps() {
  local tool="$1" src="$WORK/mixed_macro_temps.iyi" exe="$WORK/mixed_macro_temps$EXE" hosted="$WORK/mixed_macro_temps.hosted$EXE" rc=0 tstat hstat
  cat <<'IYI' > "$src"
lib LibC
  fun putchar(value : Int32) : Int32
  fun exit(status : Int32) : NoReturn
end

fun __crystal_personality(version : Int32, actions : Int32, exception_class : UInt64, exception_object : Void*, context : Void*) : Int32
  0
end

fun __crystal_get_exception(ex : Void*) : UInt64
  0_u64
end

fun __crystal_raise(ex : Void*) : NoReturn
  LibC.exit(1)
end

macro emit_chain
  if 1 < (3 &+ 3) < 7
    LibC.putchar(67)
  end
end

macro emit_defer
  defer LibC.putchar(66)
  LibC.putchar(68)
end

def with_macro_defer : Int32
  emit_defer
  7
end

count = 1
if count == 1 && count < 2
  {% if true %}
    if 1 < (2 &+ 2) < 5
      LibC.putchar(65)
    end
  {% end %}
  emit_chain
end
LibC.exit(with_macro_defer)
IYI
  "$tool" "$WORK_NATIVE/mixed_macro_temps.iyi" -o "$WORK_NATIVE/mixed_macro_temps.ir" \
    --pipeline typed --probe-phase --emit ir > "$WORK/mixed_macro_temps.probe" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] || [ ! -s "$WORK/mixed_macro_temps.ir" ] ||
     ! grep -Fxq '[phase] verify: pass' "$WORK/mixed_macro_temps.probe"; then
    cat "$WORK/mixed_macro_temps.probe"
    return 1
  fi
  "$IYI" build --prelude empty -o "$WORK_NATIVE/mixed_macro_temps.hosted$EXE" "$WORK_NATIVE/mixed_macro_temps.iyi" > "$WORK/mixed_macro_temps.hosted.log" 2>&1 || { cat "$WORK/mixed_macro_temps.hosted.log"; return 1; }
  "$hosted" > "$WORK/mixed_macro_temps.hosted.out" 2>&1; hstat=$?
  if [ "$hstat" != 7 ] || [ "$(cat "$WORK/mixed_macro_temps.hosted.out")" != ACDB ]; then
    cat "$WORK/mixed_macro_temps.hosted.out"
    return 1
  fi
  if [ "$HOST_ID" = darwin-arm64 ]; then
    "$tool" "$WORK_NATIVE/mixed_macro_temps.iyi" -o "$WORK_NATIVE/mixed_macro_temps$EXE" \
      --pipeline typed --probe-phase > "$WORK/mixed_macro_temps.native.log" 2>&1 || { cat "$WORK/mixed_macro_temps.native.log"; return 1; }
    "$exe" > "$WORK/mixed_macro_temps.typed.out" 2>&1; tstat=$?
    [ "$tstat" = "$hstat" ] && cmp -s "$WORK/mixed_macro_temps.typed.out" "$WORK/mixed_macro_temps.hosted.out"
  else
    host_limited "inline macros: mixed-temp native linking and execution require Darwin arm64"
  fi
}

# The check the single-node mutations must fail: the refusal ceilings through a pipeline tool built from the tree as it is.
check_body_fixture() {
  local RAISE=0 probe="$WORK/mut_body_tool$EXE"
  if ! "$IYI" build -o "$WORK_NATIVE/mut_body_tool$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/mut_body_build.log" 2>&1; then
    local saved
    saved=$(mktemp "${SEMINL_ARTIFACT_DIR:-$WORK}/invalid-body-build.XXXXXX") || saved=""
    if [ -n "$saved" ]; then cp "$WORK/mut_body_build.log" "$saved"; fi
    echo "INVALID MUTATION: body tool build failed${saved:+; compiler output: $saved}"
    cat "$WORK/mut_body_build.log"
    return 2
  fi
  check_refusals "$probe" || return $?
  check_body_lowering "$probe"
}

if [ -x "$WORK/reach_tool$EXE" ]; then
  check_refusals "$WORK/reach_tool$EXE" || status=1
  check_body_lowering "$WORK/reach_tool$EXE" || { echo "  FAIL: single macro body did not lower and run"; status=1; }
  check_macro_mixed_temps "$WORK/reach_tool$EXE" || { echo "  FAIL: macro mixed-temp and prelude regression failed"; status=1; }
else
  status=1
fi

prove_mutation "a single macro node body is left unspliced and cannot be lowered" "$MUT_INL" \
  "return body unless body.is_a?(MacroIf) || body.is_a?(MacroFor) || body.is_a?(MacroExpression)" \
  "return body" -- check_body_fixture || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# Not "wrapped but not spliced": visit(Expressions) splices the wrapper again, so that mutant is equivalent.
prove_mutation "a single macro node body loses its expansion: the wrapper is empty" "$MUT_INL" \
  "Expressions.new(splice_inline_sites([body] of ASTNode, scope_name, filename, in_lib, normalizer, locals, bindings, facts, keep_empty))" \
  "Expressions.new([] of ASTNode)" -- check_body_fixture || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))


# Wrapping the site in Expressions is equivalent: the def that reads the constant splices it again in the same namespace. Pass an empty scope so @type is not the declaring type.
prove_mutation "a constant macro expands in the reader's scope instead of its declaration namespace" "$MUT_MAIN" \
  "spliced = splice_body_node(value, scope_name, file, c.namespace.is_a?(LibType), @program.normalizer)" \
  "spliced = splice_body_node(value, \"\", file, c.namespace.is_a?(LibType), @program.normalizer)" -- check_body_fixture || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))


# A site's expansion is parsed knowing the names the body declared before it (inline_macros.iyi, the parser's var scope).
prove_mutation "a site's expansion is parsed with no names declared before it, so a later local reads as a call" "$MUT_INL" \
  "parser = Parser.new(text, filename, nil, scopes)" \
  "parser = Parser.new(text, filename)" -- check_body_fixture || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# The recursive splice receives the same locals array, so a name an earlier expansion
# declares is visible to a later site (inline_macros.iyi splice_inline_sites). A copy
# keeps the expansion and drops that write-back, so later_block_local.iyi pointerof
# refuses the name and root-refusals rise above 5.
prove_mutation "a recursive splice drops names an earlier expansion declared, so a later block's pointerof refuses them" "$MUT_INL" \
  "out.concat(splice_inline_sites(inner, scope_name, filename, in_lib, normalizer, locals, bindings, facts, keep_empty))" \
  "out.concat(splice_inline_sites(inner, scope_name, filename, in_lib, normalizer, locals.dup, bindings, facts, keep_empty))" -- check_body_fixture || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "PASS: inline macros gate green"
else
  echo "FAIL: inline macros gate red"
fi
exit "$status"
