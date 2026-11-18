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
ARTIFACT_DIR="${SEMINL_ARTIFACT_DIR:-}"
if [ -n "$ARTIFACT_DIR" ]; then
  mkdir -p "$ARTIFACT_DIR" || exit 1
fi
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
  local artifact=""
  if [ -n "$ARTIFACT_DIR" ]; then
    artifact="$ARTIFACT_DIR/$(printf '%s' "$rel" | tr '/\\' '__')"
  fi
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
    if [ -n "$artifact" ]; then
      cp "$WORK/o.txt" "$artifact.oracle"
      records "$WORK/o.txt" | sort > "$artifact.oracle.records"
    fi
    if "$PORT" "$abs" > "$WORK/p.txt" 2> "$WORK/p.err"; then
      matched=$(agreeing "$WORK/o.txt" "$WORK/p.txt")
      if [ -n "$artifact" ]; then
        cp "$WORK/p.txt" "$artifact.port"
        records "$WORK/p.txt" | sort > "$artifact.port.records"
        comm -23 "$artifact.oracle.records" "$artifact.port.records" > "$artifact.oracle-only.records"
        comm -13 "$artifact.oracle.records" "$artifact.port.records" > "$artifact.port-only.records"
      fi
      note="-"
    else
      matched=0
      [ -z "$artifact" ] || cp "$WORK/p.err" "$artifact.port.err"
      note="PORT: $(head -n 1 "$WORK/p.err" | tr '\t' ' ')"
    fi
  else
    nodes=0
    matched=0
    [ -z "$artifact" ] || cp "$WORK/o.err" "$artifact.oracle.err"
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

# A bare two-file program keeps the required-file proof independent of prelude
# ivars. The later type has a unique name, so its refusal identifies this fixture.
mkdir -p "$WORK/pending_ivar"
cat > "$WORK/pending_ivar/required.iyi" <<'IYI'
class S3PendingOwner
  @value : S3PendingFuture
end
class S3PendingExtra
end
IYI
cat > "$WORK/pending_ivar/root.iyi" <<'IYI'
require "./required"
class S3PendingFuture
end
IYI
check_pending_ivar() {
  local probe="$WORK/mut_pending$EXE" rc=0
  if ! "$PORT" --pending-ivar "$WORK_NATIVE/pending_ivar/root.iyi" > "$WORK/pending_base.out" 2>"$WORK/pending_base.err" ||
     ! grep -Fxq 'S3PendingFuture' "$WORK/pending_base.out"; then
    echo "INVALID: pending-ivar baseline did not resolve the later type"
    cat "$WORK/pending_base.out" "$WORK/pending_base.err"
    return 2
  fi
  if ! "$IYI" build -o "$WORK_NATIVE/mut_pending$EXE" "$REPO_NATIVE/bench/selfhost_semantic_inline_macros_exercise.iyi" > "$WORK/mut_pending.build" 2>&1; then
    echo "INVALID: pending-ivar mutant driver failed to build"
    cat "$WORK/mut_pending.build"
    return 2
  fi
  "$probe" --pending-ivar "$WORK_NATIVE/pending_ivar/root.iyi" > "$WORK/pending_mut.out" 2>"$WORK/pending_mut.err" || rc=$?
  if expected_refusal "$rc" "$WORK/pending_mut.err" refuse_port '^undefined constant S3PendingFuture$'; then
    echo "decisive: the required file resolved S3PendingFuture before the root declared it"
    return 1
  fi
  echo "INVALID: pending-ivar mutant did not produce its named refusal (status $rc)"
  cat "$WORK/pending_mut.out" "$WORK/pending_mut.err"
  return 2
}

# A C struct is valid in both parser modes but yields different AST nodes. This
# catches the parser-mode mutation without relying on a syntax-error panic.
cat > "$WORK/lib_parser_mode.iyi" <<'IYI'
lib S3LibParser
  {% if true %}
    struct S3Fields
      value : Int32
    end
  {% end %}
end
IYI
check_lib_parser_mode() {
  local probe="$WORK/mut_lib_parser$EXE" fixture="$WORK_NATIVE/lib_parser_mode.iyi" rc=0
  if ! "$ORACLE" "$fixture" > "$WORK/lib_base.oracle" 2>"$WORK/lib_base.oracle.err" ||
     ! "$PORT" "$fixture" > "$WORK/lib_base.port" 2>"$WORK/lib_base.port.err" ||
     ! cmp -s "$WORK/lib_base.oracle" "$WORK/lib_base.port"; then
    echo "INVALID: lib parser baseline does not match the oracle"
    cat "$WORK/lib_base.oracle.err" "$WORK/lib_base.port.err"
    return 2
  fi
  if ! "$IYI" build -o "$WORK_NATIVE/mut_lib_parser$EXE" "$REPO_NATIVE/bench/selfhost_semantic_inline_macros_exercise.iyi" > "$WORK/mut_lib_parser.build" 2>&1; then
    echo "INVALID: lib parser mutant driver failed to build"
    cat "$WORK/mut_lib_parser.build"
    return 2
  fi
  "$probe" "$fixture" > "$WORK/lib_mut.port" 2>"$WORK/lib_mut.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # The mutant parses every lib body with an inline site as an ordinary body, the prelude's included,
    # so it can fail while loading. The unmutated driver loaded this fixture above, so a parse failure
    # here belongs to the mutation.
    if grep -Eq '^iyi: panic: Syntax error in .*\.iyi:[0-9]+:[0-9]+: ' "$WORK/lib_mut.err"; then
      echo "decisive: a lib body no longer parses: $(grep -E -m 1 '^iyi: panic: Syntax error in ' "$WORK/lib_mut.err" | sed "s#$REPO_NATIVE/##")"
      return 1
    fi
    echo "INVALID: lib parser mutant exited $rc"
    cat "$WORK/lib_mut.err"
    return 2
  fi
  if ! cmp -s "$WORK/lib_base.oracle" "$WORK/lib_mut.port"; then
    echo "decisive: lib struct declarations differ when parsed as an ordinary body"
    return 1
  fi
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
  "out.concat(splice_inline_sites(inner, scope_name, filename, in_lib, normalizer, locals, bindings, facts, keep_empty, path_lookup, declarations))" \
  "out.concat([] of ASTNode)" \
  -- check_inline_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a required file finishes its pending ivars at once, before a later file declares them" "$MUT_SEM" \
  "inner.exp_nest = 1" \
  "inner.exp_nest = 0" \
  -- check_pending_ivar || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a site inside a lib body is parsed as an ordinary body" "$MUT_INL" \
  "parsed = in_lib ? parser.parse_lib_body : parser.parse" \
  "parsed = parser.parse" \
  -- check_lib_parser_mode || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

echo
echo "== 8. Pipeline reach: each root through the pipeline tool with the prelude, against bench/selfhost_inline_reach.floor"
REACH_FLOOR="$REPO/bench/selfhost_inline_reach.floor"
MUT_PROG="$REPO/src/compiler/lower/program.iyi"
# Both reports use the compiler's existing aarch64-darwin target on every
# host. IR emission runs the same typing and lowering without executing Mach-O.
#
# Returns 0 when the report is complete and lowering ended as expected, and 2 when the report cannot be used. Under a
# mutation it returns 3 when body typing finished, so the table is complete, but lowering did not end as the baseline's
# did. The caller reads the table first: a table that shows the mutation is decisive, and only an unchanged table makes
# status 3 invalid. The reason is kept in $WORK/<kind>_<tag>.unsettled.
run_typed_report() {
  local tool="$1" root="$2" kind="$3" tag="$4"
  local log="$WORK/${kind}_${tag}.log" output="$WORK/${kind}_${tag}.ir" rc=0 failure="" unsettled=""
  rm -f "$output" "$WORK/${kind}_${tag}.unsettled"
  "$tool" "$REPO_NATIVE/$root" -o "$WORK_NATIVE/${kind}_${tag}.ir" \
    --pipeline typed --prelude --probe-phase --keep-going --emit ir > "$log" 2>&1 || rc=$?
  if ! grep -Fxq '[phase] bodies: pass' "$log"; then
    echo "INVALID: $kind report did not finish body typing for $root (status $rc)"
    cat "$log"
    return 2
  fi
  if ! grep -Fxq '[phase] lower: start' "$log"; then
    unsettled="INVALID: $kind report did not start lowering for $root (status $rc)"
  elif [ "$rc" -eq 0 ]; then
    if [ ! -s "$output" ] || ! grep -Fxq '[phase] verify: pass' "$log"; then
      unsettled="INVALID: $kind report did not produce verified IR for $root"
    fi
  elif [ "$rc" -eq 1 ]; then
    if grep -Fxq 'reached: bodies' "$log"; then
      failure=$(awk '/^lower: fail: / { print; exit }' "$log")
    elif grep -Fxq 'reached: lower' "$log"; then
      failure=$(awk '/^verify: fail: / { print; exit }' "$log")
    fi
    if [ -z "$failure" ]; then
      unsettled="INVALID: $kind report exited without a named lowering or verifier refusal for $root"
    elif [ "${_PM_ARMED:-0}" = 1 ] &&
         { [ ! -f "$WORK/base_${kind}_${tag}.failure" ] ||
           [ "$failure" != "$(cat "$WORK/base_${kind}_${tag}.failure")" ]; }; then
      unsettled="INVALID MUTATION: $kind report changed its baseline compiler refusal for $root"
    fi
  else
    unsettled="INVALID: $kind report exited $rc for $root"
  fi
  if [ -n "$unsettled" ]; then
    if [ "${_PM_ARMED:-0}" = 1 ]; then
      printf '%s\n' "$unsettled" > "$WORK/${kind}_${tag}.unsettled"
      return 3
    fi
    echo "$unsettled"
    cat "$log"
    return 2
  fi
  if [ "${_PM_ARMED:-0}" != 1 ]; then
    printf '%s' "$failure" > "$WORK/base_${kind}_${tag}.failure"
  fi
}

# Prints why the report <kind> <tag> is unsettled under a mutation, with its log.
unsettled_report() {
  cat "$WORK/$1_$2.unsettled"
  cat "$WORK/$1_$2.log"
}

# Prints "<defs-reached> <no-record rows> <report status>" for a repo-relative root and tool. The status is 0, or 3
# when lowering did not end as the baseline's did (run_typed_report).
reach_of() {
  local root="$1" tool="$2" tag="$3" log="$WORK/reach_$3.log" reach missing report_rc=0
  run_typed_report "$tool" "$root" reach "$tag" || report_rc=$?
  if [ "$report_rc" -ne 0 ] && [ "$report_rc" -ne 3 ]; then return "$report_rc"; fi
  reach=$(awk '/^table: .* defs-reached=/ { sub(/.*defs-reached=/, ""); print $1; exit }' "$log")
  case "$reach" in
    ""|*[!0-9]*) echo "INVALID: missing defs-reached for $root"; cat "$log"; return 2 ;;
  esac
  missing=$(awk '/no record from the declarations pass/ { n++ } END { print n + 0 }' "$log")
  printf '%s %s %s\n' "$reach" "$missing" "$report_rc"
}

# Checks each floor row (or only the root $2) against the pipeline tool $1. A root below its floor or with a fun that has
# no record fails. A floor below the measured count fails too, unless SEMINL_RAISE=1 writes the count up (never down).
check_reach() {
  local tool="$1" only="${2:-}" fail=0 root floor reach missing unsettled tag values row_ok
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
    unsettled=$3
    echo "  $root: defs-reached $reach (floor $floor), no-record rows $missing"
    row_ok=1
    if [ "$missing" -ne 0 ] || [ "$reach" -lt "$floor" ]; then
      echo "decisive: $root is below its reach floor or has missing declaration records"
      row_ok=0
      fail=1
    elif [ "$unsettled" -ne 0 ]; then
      unsettled_report reach "$tag"
      return 2
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
    if [ "$report_rc" -ne 0 ] && [ "$report_rc" -ne 3 ]; then
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
    elif [ "$report_rc" -eq 3 ]; then
      unsettled_report refusals "$tag"
      invalid=1
      continue
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

# The fixture's constant chooses an Int32 only in its declaration namespace.
check_constant_scope() {
  local probe="$WORK/mut_body_tool$EXE" fixture="$REPO_NATIVE/bench/fixtures/seminl_reach/const_lower_if.iyi" rc=0
  rm -f "$WORK/const_scope_base.ir" "$WORK/const_scope_mut.ir"
  if ! "$WORK/reach_tool$EXE" "$fixture" -o "$WORK_NATIVE/const_scope_base.ir" \
       --pipeline typed --probe-phase --emit ir > "$WORK/const_scope_base.out" 2>"$WORK/const_scope_base.err" ||
     [ ! -s "$WORK/const_scope_base.ir" ] || ! grep -Fxq '[phase] verify: pass' "$WORK/const_scope_base.out"; then
    echo "INVALID: constant-scope baseline did not produce verified IR"
    cat "$WORK/const_scope_base.out" "$WORK/const_scope_base.err"
    return 2
  fi
  if ! "$IYI" build -o "$WORK_NATIVE/mut_body_tool$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/mut_body_build.log" 2>&1; then
    echo "INVALID: constant-scope mutant compiler failed to build"
    cat "$WORK/mut_body_build.log"
    return 2
  fi
  "$probe" "$fixture" -o "$WORK_NATIVE/const_scope_mut.ir" \
    --pipeline typed --probe-phase --emit ir > "$WORK/const_scope_mut.out" 2>"$WORK/const_scope_mut.err" || rc=$?
  if expected_refusal "$rc" "$WORK/const_scope_mut.err" src/compiler/semantic/main_visitor.iyi \
       '^type mismatch for return type: expected Int32, got String$' &&
     grep -Eq '^bodies: refused at .*const_lower_if\.iyi:5:5$' "$WORK/const_scope_mut.out" &&
     grep -Fxq 'reached: declarations' "$WORK/const_scope_mut.out"; then
    echo "decisive: MacroConstant::value chose the wrong namespace branch"
    return 1
  fi
  if [ "$rc" -eq 0 ] && cmp -s "$WORK/const_scope_base.ir" "$WORK/const_scope_mut.ir"; then return 0; fi
  echo "INVALID: constant-scope mutant did not produce the fixture's expected refusal (status $rc)"
  cat "$WORK/const_scope_mut.out" "$WORK/const_scope_mut.err"
  return 2
}

# Probe the splicer without the prelude, so a mutation is observed at its own
# site rather than at an unrelated prelude constant while lowering.
cat > "$WORK/splice_body.iyi" <<'IYI'
{% if true %} 42 {% else %} 17 {% end %}
IYI
cat > "$WORK/splice_existing_local.iyi" <<'IYI'
s3_local = 7
{% if true %} s3_local {% end %}
IYI
cat > "$WORK/splice_expanded_local.iyi" <<'IYI'
{% if true %} s3_local = 7 {% end %}
{% if true %} s3_local {% end %}
IYI
check_splice_probe() {
  local mode="$1" fixture="$2" baseline="$3" changed="$4" probe="$WORK/mut_splice$EXE" rc=0
  if ! "$PORT" "$mode" "$WORK_NATIVE/$fixture" > "$WORK/splice_base.out" 2>"$WORK/splice_base.err" ||
     ! grep -Fxq "$baseline" "$WORK/splice_base.out"; then
    echo "INVALID: splicer baseline did not produce $baseline"
    cat "$WORK/splice_base.out" "$WORK/splice_base.err"
    return 2
  fi
  if ! "$IYI" build -o "$WORK_NATIVE/mut_splice$EXE" "$REPO_NATIVE/bench/selfhost_semantic_inline_macros_exercise.iyi" > "$WORK/mut_splice.build" 2>&1; then
    echo "INVALID: splicer mutant driver failed to build"
    cat "$WORK/mut_splice.build"
    return 2
  fi
  "$probe" "$mode" "$WORK_NATIVE/$fixture" > "$WORK/splice_mut.out" 2>"$WORK/splice_mut.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "INVALID: splicer mutant exited $rc"
    cat "$WORK/splice_mut.err"
    return 2
  fi
  if grep -Fxq "$changed" "$WORK/splice_mut.out" &&
     ! grep -Fxq "$baseline" "$WORK/splice_mut.out"; then
    echo "decisive: $fixture produced $changed instead of $baseline"
    return 1
  fi
  if cmp -s "$WORK/splice_base.out" "$WORK/splice_mut.out"; then return 0; fi
  echo "INVALID: splicer mutant produced an unexpected result"
  cat "$WORK/splice_mut.out" "$WORK/splice_mut.err"
  return 2
}

# A false guard must compile and run like the hosted compiler; a true guard must
# be rejected by both with its own message. The globals deliberately disagree
# with the type's TAKEN so a lookup in the wrong namespace changes the branch.
check_type_const_guards() {
  local style good bad expected message host_rc port_rc
  for style in direct escaped; do
    good="$REPO_NATIVE/bench/fixtures/seminl_reach/type_const_guard_${style}.iyi"
    bad="$REPO_NATIVE/bench/fixtures/seminl_reach/type_const_raise_${style}.iyi"
    if [ "$style" = direct ]; then
      expected=A
    else
      expected=B
    fi
    message="$style type guard caught invalid layout"
    rm -f "$WORK/guard_${style}.ir" "$WORK/guard_${style}.ok"
    if ! "$IYI" build --prelude empty -o "$WORK_NATIVE/guard_${style}_host$EXE" "$good" > "$WORK/guard_${style}_host.build" 2>&1; then
      echo "INVALID: hosted $style guard did not build"; cat "$WORK/guard_${style}_host.build"; return 2
    fi
    host_rc=0
    "$WORK/guard_${style}_host$EXE" > "$WORK/guard_${style}_host.out" 2>&1 || host_rc=$?
    if [ "$host_rc" -ne 0 ] || [ "$(cat "$WORK/guard_${style}_host.out")" != "$expected" ]; then
      echo "INVALID: hosted $style guard did not print $expected (status $host_rc)"; return 2
    fi
    if ! "$WORK/reach_tool$EXE" "$good" -o "$WORK_NATIVE/guard_${style}.ir" \
         --pipeline typed --probe-phase --emit ir > "$WORK/guard_${style}.out" 2> "$WORK/guard_${style}.err" ||
       [ ! -s "$WORK/guard_${style}.ir" ] || ! grep -Fxq '[phase] verify: pass' "$WORK/guard_${style}.out"; then
      echo "INVALID: port $style guard did not produce verified IR"
      cat "$WORK/guard_${style}.out" "$WORK/guard_${style}.err"; return 2
    fi
    if [ "$HOST_ID" = darwin-arm64 ]; then
      if ! "$WORK/reach_tool$EXE" "$good" -o "$WORK_NATIVE/guard_${style}_port$EXE" \
           --pipeline typed --probe-phase > "$WORK/guard_${style}_port.build" 2>&1; then
        echo "INVALID: port $style guard did not link"; cat "$WORK/guard_${style}_port.build"; return 2
      fi
      port_rc=0
      "$WORK/guard_${style}_port$EXE" > "$WORK/guard_${style}_port.out" 2>&1 || port_rc=$?
      if [ "$port_rc" -ne "$host_rc" ] || ! cmp -s "$WORK/guard_${style}_host.out" "$WORK/guard_${style}_port.out"; then
        echo "INVALID: port $style guard differs from the hosted run"; return 2
      fi
    else
      host_limited "inline macros: type constant guard native execution requires Darwin arm64"
    fi
    host_rc=0
    "$IYI" build --prelude empty -o "$WORK_NATIVE/raise_${style}_host$EXE" "$bad" > "$WORK/raise_${style}_host.log" 2>&1 || host_rc=$?
    if [ "$host_rc" -ne 1 ] || ! grep -Fxq "Error: $message" "$WORK/raise_${style}_host.log"; then
      echo "INVALID: hosted $style raise did not report its message (status $host_rc)"
      cat "$WORK/raise_${style}_host.log"; return 2
    fi
    port_rc=0
    "$WORK/reach_tool$EXE" "$bad" -o "$WORK_NATIVE/raise_${style}.ir" \
      --pipeline typed --probe-phase --emit ir > "$WORK/raise_${style}.out" 2> "$WORK/raise_${style}.err" || port_rc=$?
    if ! expected_refusal "$port_rc" "$WORK/raise_${style}.err" src/compiler/semantic/main_visitor.iyi \
         "^macro control expansion: $message$" ||
       ! grep -Fxq "bodies: fail: macro control expansion: $message" "$WORK/raise_${style}.out"; then
      echo "INVALID: port $style raise did not report the hosted message (status $port_rc)"
      cat "$WORK/raise_${style}.out" "$WORK/raise_${style}.err"; return 2
    fi
    : > "$WORK/guard_${style}.ok"
    echo "  $style type guard: false prints $expected, true raises '$message' on both compilers"
  done
}

# A mutant is caught only by the predicted result on both forms. A crash, a
# build failure, or a different refusal is not evidence of either defect.
check_type_const_mutation() {
  local mutation="$1" style fixture message rc caught=0 probe="$WORK/mut_type_const$EXE"
  for style in direct escaped; do
    if [ ! -f "$WORK/guard_${style}.ok" ]; then
      echo "INVALID MUTATION: missing $style hosted/port baseline"; return 2
    fi
  done
  if ! "$IYI" build -o "$WORK_NATIVE/mut_type_const$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/mut_type_const.build" 2>&1; then
    echo "INVALID MUTATION: type-constant compiler failed to build"; cat "$WORK/mut_type_const.build"; return 2
  fi
  for style in direct escaped; do
    if [ "$mutation" = lookup ]; then
      fixture="$REPO_NATIVE/bench/fixtures/seminl_reach/type_const_guard_${style}.iyi"
      message="$style guard must not raise"
    else
      fixture="$REPO_NATIVE/bench/fixtures/seminl_reach/type_const_raise_${style}.iyi"
    fi
    rm -f "$WORK/mut_guard_${style}.ir"
    rc=0
    "$probe" "$fixture" -o "$WORK_NATIVE/mut_guard_${style}.ir" \
      --pipeline typed --probe-phase --emit ir > "$WORK/mut_guard_${style}.out" 2> "$WORK/mut_guard_${style}.err" || rc=$?
    if [ "$mutation" = lookup ]; then
      if expected_refusal "$rc" "$WORK/mut_guard_${style}.err" src/compiler/semantic/main_visitor.iyi \
           "^macro control expansion: $message$" &&
         grep -Fxq "bodies: fail: macro control expansion: $message" "$WORK/mut_guard_${style}.out"; then
        caught=$((caught + 1))
      elif [ "$rc" -ne 0 ] || [ ! -s "$WORK/mut_guard_${style}.ir" ] ||
           ! grep -Fxq '[phase] verify: pass' "$WORK/mut_guard_${style}.out"; then
        echo "INVALID MUTATION: $style lookup produced a different failure (status $rc)"
        cat "$WORK/mut_guard_${style}.out" "$WORK/mut_guard_${style}.err"; return 2
      fi
    elif [ "$rc" -eq 0 ] && [ -s "$WORK/mut_guard_${style}.ir" ] &&
         grep -Fxq '[phase] verify: pass' "$WORK/mut_guard_${style}.out"; then
      caught=$((caught + 1))
    elif expected_refusal "$rc" "$WORK/mut_guard_${style}.err" src/compiler/semantic/main_visitor.iyi \
           "^macro control expansion: $style type guard caught invalid layout$"; then
      :
    else
      echo "INVALID MUTATION: $style dropped-raise probe failed differently (status $rc)"
      cat "$WORK/mut_guard_${style}.out" "$WORK/mut_guard_${style}.err"; return 2
    fi
  done
  if [ "$caught" -eq 2 ]; then
    echo "decisive: $mutation changed the direct and escaped type-constant guards"
    return 1
  fi
  if [ "$caught" -eq 0 ]; then return 0; fi
  echo "INVALID MUTATION: $mutation changed only one guard form"; return 2
}

if [ -x "$WORK/reach_tool$EXE" ]; then
  check_refusals "$WORK/reach_tool$EXE" || status=1
  check_body_lowering "$WORK/reach_tool$EXE" || { echo "  FAIL: single macro body did not lower and run"; status=1; }
  check_macro_mixed_temps "$WORK/reach_tool$EXE" || { echo "  FAIL: macro mixed-temp and prelude regression failed"; status=1; }
  check_type_const_guards || { echo "  FAIL: type-constant guards differ from the hosted compiler"; status=1; }
else
  status=1
fi

prove_mutation "type-body macro paths ignore the enclosing type's constants" "$MUT_TOP" \
  "found = @program.lookup_type_path?(path, @scope)" \
  "found = @program.lookup_type_path?(path, @program)" -- check_type_const_mutation lookup || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a raise in a taken type-body macro branch is dropped" "$REPO/src/compiler/macros/interpreter.iyi" \
  "fail_at(node, raise_message(node.args))" \
  "nil" -- check_type_const_mutation raise || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a single macro node body is left unspliced" "$MUT_INL" \
  "return body unless body.is_a?(MacroIf) || body.is_a?(MacroFor) || body.is_a?(MacroExpression)" \
  "return body" -- check_splice_probe --spliced-body splice_body.iyi expanded:42 node:MacroIf || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# Not "wrapped but not spliced": visit(Expressions) splices the wrapper again, so that mutant is equivalent.
prove_mutation "a single macro node body loses its expansion: the wrapper is empty" "$MUT_INL" \
  "Expressions.new(splice_inline_sites([body] of ASTNode, scope_name, filename, in_lib, normalizer, locals, bindings, facts, keep_empty, path_lookup))" \
  "Expressions.new([] of ASTNode)" -- check_splice_probe --spliced-body splice_body.iyi expanded:42 empty || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))


# Wrapping the site in Expressions is equivalent: the def that reads the constant splices it again in the same namespace. Pass an empty scope so @type is not the declaring type.
prove_mutation "a constant macro expands in the reader's scope instead of its declaration namespace" "$MUT_MAIN" \
  "spliced = splice_body_node(value, scope_name, file, c.namespace.is_a?(LibType), @program.normalizer, [] of String, nil, nil, false, SemanticMacroPathLookup.new(@program, scope))" \
  "spliced = splice_body_node(value, \"\", file, c.namespace.is_a?(LibType), @program.normalizer, [] of String, nil, nil, false, SemanticMacroPathLookup.new(@program, scope))" -- check_constant_scope || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))


# A site's expansion is parsed knowing the names the body declared before it (inline_macros.iyi, the parser's var scope).
prove_mutation "a site's expansion is parsed with no names declared before it, so a later local reads as a call" "$MUT_INL" \
  "parser = Parser.new(text, filename, nil, scopes)" \
  "parser = Parser.new(text, filename)" -- check_splice_probe --spliced-local splice_existing_local.iyi var:s3_local call:s3_local || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# The recursive splice must return names an expansion declared to later sites.
prove_mutation "a recursive splice drops names an earlier expansion declared" "$MUT_INL" \
  "out.concat(splice_inline_sites(inner, scope_name, filename, in_lib, normalizer, locals, bindings, facts, keep_empty, path_lookup, declarations))" \
  "out.concat(splice_inline_sites(inner, scope_name, filename, in_lib, normalizer, locals.dup, bindings, facts, keep_empty, path_lookup, declarations))" -- check_splice_probe --spliced-local splice_expanded_local.iyi var:s3_local call:s3_local || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "PASS: inline macros gate green"
else
  echo "FAIL: inline macros gate red"
fi
exit "$status"
