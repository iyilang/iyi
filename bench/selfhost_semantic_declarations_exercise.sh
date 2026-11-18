#!/usr/bin/env bash
# Burn-down gate for declaration parity between the iyi semantic port and the
# hosted front end's top-level pass (specification S1b).
#
# Every file is analysed bare (no prelude), with the closure of what it imports
# and requires, by the hosted front end's top-level pass
# (bench/selfhost_semantic_declarations_oracle.cr) and by the iyi port
# (bench/selfhost_semantic_declarations_exercise.iyi). Both search IYI_PATH, set
# below to this checkout's src/. Both print one text dump of the declarations the
# file itself makes: defs, types, nested types, their visibility, superclasses,
# type variables, enum members, aliases and constants. A declaration belongs to
# the file when its location is the file, so an imported file's declarations are
# not repeated. The dump is split into records, one per declaration header
# (a "Type:" or "Def:" line) with its own property lines. A record agrees when
# both sides print it identically. The gate counts agreeing records per file.
#
#   bash bench/selfhost_semantic_declarations_exercise.sh
#
# Verifies:
#   1. The oracle and the port's driver build.
#   2. Every bench/fixtures/semdecl_*.iyi is dumped byte-identical by both sides.
#   3-5. Corpora burn-down: the port's own source (src/compiler), the prelude
#        (src/iyi), std (src/std) and the samples (samples/iyi). Each file's
#        agreeing-record count is checked against the committed floor
#        (bench/selfhost_semantic_declarations.floor), which may only rise. A
#        file the oracle cannot analyse is reported ORACLE with its reason and
#        is not measured. A file the port rejects counts zero and is reported PORT.
#   6. Guarded mutation proofs on the fixtures (bench/lib/mutation.sh).
#
# Environment:
#   SEMDECL_RAISE=1         write the floor up to the measured counts (never lower)
#   SEMDECL_FILES=<f>       measure only the repo-relative paths listed in <f>
#   SEMDECL_FLOOR=<f>       read and write this floor file instead of the default
#
# Exit status 0 when every check passes, 1 otherwise.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if [ -z "$PY" ]; then echo "Python is required for the floor and mutation helpers" >&2; exit 1; fi
REPO_NATIVE="$(native_path "$REPO")"
cd "$REPO" || exit 1
export PWD="$REPO"
IYI="$REPO/bin/iyi"
HOSTED_COMPILER="$REPO/bin/crystal"
FLOOR_FILE="${SEMDECL_FLOOR:-$REPO/bench/selfhost_semantic_declarations.floor}"
RAISE="${SEMDECL_RAISE:-0}"
FILES_LIST="${SEMDECL_FILES:-}"
WORK="$(mktemp -d)"
WORK_NATIVE="$(native_path "$WORK")"
LC_ALL=C
export LC_ALL
export IYI_CACHE_DIR="$WORK_NATIVE/cache"


export IYI_PATH="$REPO_NATIVE/src"
trap 'rm -rf "$WORK"' EXIT INT TERM

ORACLE="$WORK/oracle$EXE"
PORT="$WORK/port$EXE"
RESULTS="$WORK/results.tsv"
VERDICTS="$WORK/verdicts.tsv"
status=0
: > "$RESULTS"

. "$REPO/bench/lib/mutation.sh"

# Splits a dump into records, one per "Type:", "Def:", "Ivar:" or "IvarOrder:" header line,
# each with its own property lines, joined onto one line with the record separator \036.
records() {
  awk '
    function flush() { if (cur != "") print cur }
    /^ *(Type|Def|Ivar|IvarOrder): / { flush(); cur = $0; next }
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

echo "== 1. Building the hosted declaration oracle and the port's declaration driver"
LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" CRYSTAL_PATH="$REPO_NATIVE/src" "$HOSTED_COMPILER" build -Di_know_what_im_doing \
  -o "$WORK_NATIVE/oracle$EXE" "$REPO_NATIVE/bench/selfhost_semantic_declarations_oracle.cr" > "$WORK/oracle_build.log" 2>&1 \
  || { cat "$WORK/oracle_build.log"; echo "FAILED to build the oracle"; exit 1; }
"$IYI" build -o "$WORK_NATIVE/port$EXE" "$REPO_NATIVE/bench/selfhost_semantic_declarations_exercise.iyi" > "$WORK/port_build.log" 2>&1 \
  || { cat "$WORK/port_build.log"; echo "FAILED to build the port's declaration driver"; exit 1; }
echo "  built: oracle, port driver"

echo
echo "== 2. Fixtures: every declaration dumped identically by both sides"
fixture_count=0
fixture_bad=0
total_matched=0
for fixture in "$REPO"/bench/fixtures/semdecl_*.iyi "$REPO"/bench/fixtures/semdecl_*/*.iyi "$REPO"/bench/fixtures/semdecl_*/*/*.iyi; do
  rel="${fixture#$REPO/}"
  fixture_count=$((fixture_count + 1))
  # The typed fixtures (semdecl_ivar_typed_*) are declared with the type system installed: the
  # generic arguments and virtual types of explicit instance variables need it. The oracle and the
  # port both print the instance variables of generic instances with --typed, on these fixtures only.
  oracle_mode=""
  port_mode=""
  case "$(basename "$fixture")" in
    semdecl_ivar_typed_*) oracle_mode="--typed"; port_mode="--typed" ;;
  esac
  if ! "$ORACLE" $oracle_mode "$REPO_NATIVE/$rel" > "$WORK/fx_o.txt" 2> "$WORK/fx_oe.txt"; then
    echo "  $rel: ORACLE REJECTS: $(head -n 1 "$WORK/fx_oe.txt")"
    fixture_bad=$((fixture_bad + 1)); status=1; continue
  fi
  if ! "$PORT" $port_mode "$REPO_NATIVE/$rel" > "$WORK/fx_p.txt" 2> "$WORK/fx_pe.txt"; then
    echo "  $rel: PORT REJECTS: $(head -n 1 "$WORK/fx_pe.txt")"
    fixture_bad=$((fixture_bad + 1)); status=1; continue
  fi
  if cmp -s "$WORK/fx_o.txt" "$WORK/fx_p.txt"; then
    n=$(agreeing "$WORK/fx_o.txt" "$WORK/fx_p.txt")
    total_matched=$((total_matched + n))
    echo "  $rel: identical ($n declarations)"
  else
    echo "  $rel: DECLARATIONS DIFFER"
    diff "$WORK/fx_o.txt" "$WORK/fx_p.txt" | head -n 20
    fixture_bad=$((fixture_bad + 1)); status=1
  fi
done
echo "  Parity summary: $((fixture_count - fixture_bad))/$fixture_count fixtures identical ($total_matched declarations compared)"

echo "== Entry class-variable types are still checked in the declaration phase"
missing_cvar="$REPO_NATIVE/bench/fixtures/cvar_import/missing_entry.iyi"
oracle_rc=0
port_rc=0
"$ORACLE" "$missing_cvar" > "$WORK/cvar_missing_o" 2> "$WORK/cvar_missing_oe" || oracle_rc=$?
"$PORT" "$missing_cvar" > "$WORK/cvar_missing_p" 2> "$WORK/cvar_missing_pe" || port_rc=$?
if [ "$oracle_rc" -ne 2 ] || [ "$port_rc" -eq 0 ] ||
   ! grep -q '^ERROR: undefined constant MissingClassVarType' "$WORK/cvar_missing_oe" ||
   ! grep -q 'undefined constant MissingClassVarType' "$WORK/cvar_missing_pe"; then
  echo "  entry class variable: oracle and port did not both reject the missing type"
  status=1
else
  echo "  entry class variable: both reject the missing type"
fi

echo "== 2b. Lib fun records once the type system is installed: generic argument types resolved"
echo "  (a port-side pin: the oracle has no dump of lib fun types, so the expected lines are the types the fixture declares, written by hand)"
lib_types_expected="$REPO/bench/selfhost_semantic_declarations_lib_types.expected"
if ! "$PORT" --lib-types "$REPO_NATIVE/bench/fixtures/semdecl_lib_types.iyi" > "$WORK/lt_p.txt" 2> "$WORK/lt_pe.txt"; then
  echo "  PORT REJECTS: $(head -n 1 "$WORK/lt_pe.txt")"; status=1
else
  awk '/^lib LibTypes\./' "$WORK/lt_p.txt" > "$WORK/lt_pin.txt"
  if cmp -s "$WORK/lt_pin.txt" "$lib_types_expected"; then
    echo "  semdecl_lib_types.iyi: $(awk 'END{print NR}' "$WORK/lt_pin.txt") lib funs pinned"
  else
    echo "  semdecl_lib_types.iyi: PIN DIFFERS"
    diff "$lib_types_expected" "$WORK/lt_pin.txt" | head -n 20
    status=1
  fi
fi
echo "== Virtual subtype and metaclass compatibility"
if ! "$ORACLE" --virtual-subtype "$REPO_NATIVE/bench/fixtures/semdecl_virtual_subtype.iyi" > "$WORK/virtual_oracle" 2>&1 ||
   ! "$PORT" --virtual-subtype "$REPO_NATIVE/bench/fixtures/semdecl_virtual_subtype.iyi" > "$WORK/virtual_port" 2>&1 ||
   ! cmp -s "$WORK/virtual_oracle" "$WORK/virtual_port"; then
  echo "  virtual subtype DIFFERS"; diff "$WORK/virtual_oracle" "$WORK/virtual_port"; status=1
fi
echo "== Definition owner and cloned owner"
if ! "$ORACLE" --def-owner "$REPO_NATIVE/bench/fixtures/semdecl_def_owner.iyi" > "$WORK/owner_oracle" 2>&1 ||
   ! "$PORT" --def-owner "$REPO_NATIVE/bench/fixtures/semdecl_def_owner.iyi" > "$WORK/owner_port" 2>&1 ||
   ! cmp -s "$WORK/owner_oracle" "$WORK/owner_port"; then
  echo "  definition owner DIFFERS"; diff "$WORK/owner_oracle" "$WORK/owner_port"; status=1
fi
echo "== Enum primitive definitions and result types"
if ! "$ORACLE" --enum-primitives "$REPO_NATIVE/bench/fixtures/semdecl_enum_primitives.iyi" > "$WORK/enum_primitive_oracle" 2>&1 ||
   ! "$PORT" --enum-primitives "$REPO_NATIVE/bench/fixtures/semdecl_enum_primitives.iyi" > "$WORK/enum_primitive_port" 2>&1 ||
   ! cmp -s "$WORK/enum_primitive_oracle" "$WORK/enum_primitive_port"; then
  echo "  enum primitives DIFFER"; diff "$WORK/enum_primitive_oracle" "$WORK/enum_primitive_port"; status=1
fi
echo "== Nested pointer lib signatures"
if ! "$ORACLE" --lib-starstar "$REPO_NATIVE/bench/fixtures/semdecl_lib_starstar.iyi" > "$WORK/lib_starstar_oracle" 2>&1 ||
   ! "$PORT" --lib-types "$REPO_NATIVE/bench/fixtures/semdecl_lib_starstar.iyi" > "$WORK/lib_starstar_all" 2>&1; then
  echo "  nested pointer signatures could not be read"; status=1
else
  awk '/^lib LibBytes\./' "$WORK/lib_starstar_all" > "$WORK/lib_starstar_port"
  if ! cmp -s "$WORK/lib_starstar_oracle" "$WORK/lib_starstar_port"; then
    echo "  nested pointer signatures DIFFER"; diff "$WORK/lib_starstar_oracle" "$WORK/lib_starstar_port"; status=1
  fi
fi
echo "== Enum annotations"
if ! "$ORACLE" --enum-annotations "$REPO_NATIVE/bench/fixtures/semdecl_enum_annotations.iyi" > "$WORK/enum_annotations_oracle" 2>&1 ||
   ! "$PORT" --enum-annotations "$REPO_NATIVE/bench/fixtures/semdecl_enum_annotations.iyi" > "$WORK/enum_annotations_port" 2>&1 ||
   ! cmp -s "$WORK/enum_annotations_oracle" "$WORK/enum_annotations_port"; then
  echo "  enum annotations DIFFER"; diff "$WORK/enum_annotations_oracle" "$WORK/enum_annotations_port"; status=1
fi
echo "== Class variable generic types after type system installation"
if ! "$PORT" --classvar-generic "$REPO_NATIVE/bench/fixtures/semdecl_classvar_generic.iyi" > "$WORK/classvar_result" 2>&1; then
  cat "$WORK/classvar_result"; status=1
fi
echo "== Enum member semantic type: E::B has type E"
enum_type_expected="$WORK/enum_type_expected"
printf '%s\n' 'E::B E' > "$enum_type_expected"
if ! "$PORT" --enum-member-type "$REPO_NATIVE/bench/fixtures/semdecl_enum_member_type.iyi" > "$WORK/enum_type_actual" 2>&1 ||
   ! cmp -s "$WORK/enum_type_actual" "$enum_type_expected"; then
  echo "  enum member type DIFFERS"; status=1
fi
printf 'first binary\nsecond binary\nthird binary\n' > "$WORK/primitive_expected"
if ! "$PORT" --primitive-annotations "$REPO_NATIVE/bench/fixtures/semdecl_primitive_annotations.iyi" > "$WORK/primitive_actual" 2>&1 ||
   ! cmp -s "$WORK/primitive_actual" "$WORK/primitive_expected"; then
  echo "  primitive annotations DIFFER"; status=1
fi


echo "== 2b'. Constant facts once the program is declared: constants in declaration order, the predefined constants, a class variable's owner"
echo "  (a port-side pin: the oracle has no dump of these, so the expected lines are written by hand)"
const_facts_expected="$REPO/bench/selfhost_semantic_declarations_const_facts.expected"
if ! "$PORT" --const-facts "$REPO_NATIVE/bench/fixtures/semdecl_const_facts.iyi" > "$WORK/cf_full.txt" 2> "$WORK/cf_pe.txt"; then
  echo "  PORT REJECTS: $(head -n 1 "$WORK/cf_pe.txt")"; status=1
else
  awk '/^(const (A|B|C) |predef |cvar )/' "$WORK/cf_full.txt" > "$WORK/cf_pin.txt"
  if cmp -s "$WORK/cf_pin.txt" "$const_facts_expected"; then
    echo "  semdecl_const_facts.iyi: $(awk 'END{print NR}' "$WORK/cf_pin.txt") facts pinned"
  else
    echo "  semdecl_const_facts.iyi: PIN DIFFERS"
    diff "$const_facts_expected" "$WORK/cf_pin.txt" | head -n 20
    status=1
  fi
fi
echo "== 2b''. Link annotations once the program is declared: a lib's @[Link] records, in declaration order, positional and named"
echo "  (a port-side pin: the expected lines are written by hand; the oracle's own dump of the same fixture must agree with them)"
link_annotations_expected="$REPO/bench/selfhost_semantic_declarations_link_annotations.expected"
link_oracle_ok=0
if ! "$PORT" --link-annotations "$REPO_NATIVE/bench/fixtures/semdecl_link_annotations.iyi" > "$WORK/la_p.txt" 2> "$WORK/la_pe.txt"; then
  echo "  PORT REJECTS: $(head -n 1 "$WORK/la_pe.txt")"; status=1
else
  awk '/^link /' "$WORK/la_p.txt" > "$WORK/la_pin.txt"
  if ! "$ORACLE" --link-annotations "$REPO_NATIVE/bench/fixtures/semdecl_link_annotations.iyi" > "$WORK/la_o.txt" 2> "$WORK/la_oe.txt"; then
    echo "  ORACLE REJECTS: $(head -n 1 "$WORK/la_oe.txt")"; status=1
  elif ! cmp -s "$WORK/la_o.txt" "$link_annotations_expected"; then
    echo "  semdecl_link_annotations.iyi: ORACLE DIFFERS FROM THE PIN"
    diff "$link_annotations_expected" "$WORK/la_o.txt" | head -n 20
    status=1
  elif cmp -s "$WORK/la_pin.txt" "$link_annotations_expected"; then
    link_oracle_ok=1
    echo "  semdecl_link_annotations.iyi: $(awk 'END{print NR}' "$WORK/la_pin.txt") link records pinned, and the oracle agrees"
  else
    echo "  semdecl_link_annotations.iyi: PIN DIFFERS"
    diff "$link_annotations_expected" "$WORK/la_pin.txt" | head -n 20
    status=1
  fi
fi
echo "== 2d. Total mode with the type system installed: an unresolved superclass is carried past; the class takes the default superclass"
total_typed_expected="$REPO/bench/selfhost_semantic_declarations_total_typed.expected"
if ! "$PORT" --total-typed "$REPO_NATIVE/bench/fixtures/total_unresolved_superclass.iyi" > "$WORK/tt_p.txt" 2> "$WORK/tt_pe.txt"; then
  echo "  PORT REJECTS: $(head -n 1 "$WORK/tt_pe.txt")"; status=1
elif cmp -s "$WORK/tt_p.txt" "$total_typed_expected"; then
  echo "  total_unresolved_superclass.iyi: pinned (carried refusal, default superclass)"
else
  echo "  total_unresolved_superclass.iyi: PIN DIFFERS"
  diff "$total_typed_expected" "$WORK/tt_p.txt" | head -n 20
  status=1
fi
echo "== 2e. A constant read in a metaclass scope is the class's own: HELD read in def self.acquire"
scope_expected="$REPO/bench/selfhost_semantic_declarations_scope_lookup.expected"
if ! "$PORT" --scope-lookup "$REPO_NATIVE/bench/fixtures/semdecl_metaclass_scope.iyi" Lock HELD > "$WORK/sl_p.txt" 2> "$WORK/sl_pe.txt"; then
  echo "  PORT REJECTS: $(head -n 1 "$WORK/sl_pe.txt")"; status=1
elif cmp -s "$WORK/sl_p.txt" "$scope_expected"; then
  echo "  semdecl_metaclass_scope.iyi: Lock::HELD found from the metaclass"
else
  echo "  semdecl_metaclass_scope.iyi: PIN DIFFERS"
  diff "$scope_expected" "$WORK/sl_p.txt" | head -n 20
  status=1
fi
echo "== 2f. Post-declaration re-resolution: explicit instance variables re-resolved when type system installs after declarations"
if ! "$ORACLE" --typed "$REPO_NATIVE/bench/fixtures/semdecl_ivar_typed_generic.iyi" > "$WORK/rr_o.txt" 2> "$WORK/rr_oe.txt"; then
  echo "  ORACLE REJECTS: $(head -n 1 "$WORK/rr_oe.txt")"; status=1
elif ! "$PORT" --typed-reresolve "$REPO_NATIVE/bench/fixtures/semdecl_ivar_typed_generic.iyi" > "$WORK/rr_p.txt" 2> "$WORK/rr_pe.txt"; then
  echo "  PORT REJECTS: $(head -n 1 "$WORK/rr_pe.txt")"; status=1
elif cmp -s "$WORK/rr_o.txt" "$WORK/rr_p.txt"; then
  echo "  semdecl_ivar_typed_generic.iyi: re-resolution identical to oracle"
else
  echo "  semdecl_ivar_typed_generic.iyi: RE-RESOLUTION DIFFERS"
  diff "$WORK/rr_o.txt" "$WORK/rr_p.txt" | head -n 20
  status=1
fi

echo "== 2c. Prelude parent chains: Nil, Object, Reference, Value, Int32, String and a user class, identical to the oracle"
if ! "$ORACLE" --chain "$REPO_NATIVE/bench/fixtures/semdecl_prelude_chain.iyi" > "$WORK/chain_o.txt" 2> "$WORK/chain_oe.txt"; then
  echo "  ORACLE REJECTS: $(head -n 1 "$WORK/chain_oe.txt")"; status=1
elif ! "$PORT" --chain "$REPO_NATIVE/bench/fixtures/semdecl_prelude_chain.iyi" > "$WORK/chain_p.txt" 2> "$WORK/chain_pe.txt"; then
  echo "  PORT REJECTS: $(head -n 1 "$WORK/chain_pe.txt")"; status=1
elif cmp -s "$WORK/chain_o.txt" "$WORK/chain_p.txt"; then
  echo "  parent chains identical ($(awk 'END{print NR}' "$WORK/chain_o.txt") lines)"
else
  echo "  parent chains DIFFER"; status=1
fi
echo
echo
echo "== 2b. Built-in types: the program's initial types dumped identically (a burn-down row)"
if ! "$ORACLE" --initial > "$WORK/init_o.txt" 2> "$WORK/init_oe.txt"; then
  b_nodes=0; b_matched=0; b_note="ORACLE: $(head -n 1 "$WORK/init_oe.txt")"
elif ! "$PORT" --initial > "$WORK/init_p.txt" 2> "$WORK/init_pe.txt"; then
  b_nodes=$(records "$WORK/init_o.txt" | wc -l | tr -d ' '); b_matched=0
  b_note="PORT: $(head -n 1 "$WORK/init_pe.txt")"
else
  b_nodes=$(records "$WORK/init_o.txt" | wc -l | tr -d ' ')
  b_matched=$(agreeing "$WORK/init_o.txt" "$WORK/init_p.txt")
  b_note="-"
fi
echo "  built-in types: $b_matched of $b_nodes agree"
printf 'builtins\t<initial>\t%s\t%s\t%s\n' "$b_nodes" "$b_matched" "$b_note" >> "$RESULTS"


measure() {
  corpus="$1"
  rel="$2"
  abs="$REPO_NATIVE/$2"
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
  printf '%s\t%s\t%s\t%s\t%s\n' "$corpus" "$rel" "$nodes" "$matched" "$note" >> "$RESULTS"
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

echo "== 3b. Whole program: every compiler and prelude file, with the prelude and its import closure loaded (total mode)"
WHOLE="$WORK/whole.tsv"
CARRIED="$WORK/carried.tsv"
: > "$WHOLE"
: > "$CARRIED"
for f in $(find "$REPO/src/compiler" -name '*.iyi' | sort) "$REPO"/src/iyi/*.iyi; do
  rel="${f#$REPO/}"
  if "$PORT" --total "$(native_path "$f")" > "$WORK/w_o.txt" 2> "$WORK/w_e.txt"; then
    printf '%s\tok\n' "$rel" >> "$WHOLE"
    awk -v rel="$rel" '/^carried: / { m = substr($0, 10); gsub(/[0-9]+/, "N", m); print rel "\t" substr(m, 1, 140) }' "$WORK/w_o.txt" >> "$CARRIED"
  else
    msg=$(head -n 1 "$WORK/w_e.txt" | awk '{ gsub(/\/[^ :]*\//, "<path>/"); gsub(/[0-9]+/, "N"); print substr($0, 1, 140) }')
    printf '%s\tfail\t%s\n' "$rel" "$msg" >> "$WHOLE"
  fi
done
whole_total=$(wc -l < "$WHOLE" | tr -d ' ')
whole_pass=$(awk -F'\t' '$2 == "ok"' "$WHOLE" | wc -l | tr -d ' ')
carried_files=$(cut -f1 "$CARRIED" | sort -u | wc -l | tr -d ' ')
clean_pass=$((whole_pass - carried_files))
echo "  whole program: $whole_pass of $whole_total files complete the port's declarations pass"
echo "    with no refusal carried: $clean_pass; with at least one refusal carried past in total mode: $carried_files"
echo "  failure table by first message:"
awk -F'\t' '$2 == "fail" { print $3 }' "$WHOLE" | sort | uniq -c | sort -rn | head -25 | awk '{ print "    " $0 }'
echo "  refusals carried past in total mode, by message (occurrences, message):"
cut -f2 "$CARRIED" | sort | uniq -c | sort -rn | head -25 | awk '{ print "    " $0 }'
WHOLE_FLOOR_FILE="$REPO/bench/selfhost_whole_program.floor"
whole_floor=$(awk '/^complete/ { print $2 }' "$WHOLE_FLOOR_FILE" 2>/dev/null)
clean_floor=$(awk '/^clean/ { print $2 }' "$WHOLE_FLOOR_FILE" 2>/dev/null)
whole_floor=${whole_floor:-0}
clean_floor=${clean_floor:-0}
if [ "$whole_pass" -lt "$whole_floor" ] || [ "$clean_pass" -lt "$clean_floor" ]; then
  echo "  WHOLE PROGRAM BELOW FLOOR: complete $whole_pass (floor $whole_floor), clean $clean_pass (floor $clean_floor). A regression: restore the declaration or lower nothing."
  status=1
elif [ "$whole_pass" -gt "$whole_floor" ] || [ "$clean_pass" -gt "$clean_floor" ]; then
  if [ "$RAISE" = 1 ]; then
    printf 'complete %s\nclean %s\n' "$whole_pass" "$clean_pass" > "$WHOLE_FLOOR_FILE"
    echo "  whole-program floors raised: complete $whole_pass, clean $clean_pass"
  else
    echo "  WHOLE PROGRAM RAISE THE FLOOR: complete $whole_pass (floor $whole_floor), clean $clean_pass (floor $clean_floor) (SEMDECL_RAISE=1)"
    status=1
  fi
fi

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
    corpus = $1; rel = $2; nodes = $3 + 0; matched = $4 + 0; note = $5
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

if [ "$RAISE" = 1 ]; then
  "$PY" - "$(native_path "$VERDICTS")" "$(native_path "$FLOOR_FILE")" <<'PY'
import sys
verdicts, floor_path = sys.argv[1], sys.argv[2]
floor = {}
try:
    for line in open(floor_path, encoding="utf-8"):
        if line.strip() and not line.startswith("#"):
            path, count = line.split()
            floor[path] = int(count)
except FileNotFoundError:
    pass
raised = 0
for line in open(verdicts, encoding="utf-8"):
    cols = line.rstrip("\n").split("\t")
    verdict, rel, matched = cols[0], cols[2], int(cols[4])
    if verdict == "BELOW FLOOR":
        continue
    old = floor.get(rel, 0)
    if matched > old:
        floor[rel] = matched
        raised += 1
    elif rel not in floor:
        floor[rel] = old
with open(floor_path, "w", encoding="utf-8", newline="\n") as out:
    out.write("# semantic declaration floors: <repo-relative file> <agreeing declarations>.\n")
    out.write("# A count may only rise. Raise with: SEMDECL_RAISE=1 bash bench/selfhost_semantic_declarations_exercise.sh\n")
    for rel in sorted(floor):
        out.write(f"{rel} {floor[rel]}\n")
print(f"  floor written: {len(floor)} entries, {raised} raised")
PY
verdicts
  fails=$(awk -F'\t' '$1 == "BELOW FLOOR"' "$VERDICTS" | wc -l | tr -d ' ')
else
  fails=$(awk -F'\t' '$1 == "BELOW FLOOR" || $1 == "RAISE THE FLOOR" || $1 == "NO FLOOR"' "$VERDICTS" | wc -l | tr -d ' ')
fi
awk -F'\t' '
  $1 == "BELOW FLOOR"     { printf "  BELOW FLOOR: %s matched %s, floor %s. A regression: restore the declaration or lower nothing.\n", $3, $5, $7 }
  $1 == "RAISE THE FLOOR" { printf "  RAISE THE FLOOR: %s matched %s, floor %s. Raise the floor in bench/selfhost_semantic_declarations.floor (SEMDECL_RAISE=1).\n", $3, $5, $7 }
  $1 == "NO FLOOR"        { printf "  NO FLOOR: %s has no floor entry. Add it (SEMDECL_RAISE=1).\n", $3 }
' "$VERDICTS"
while IFS= read -r rel; do
  echo "  Declaration differences for $rel (first 20 lines; < oracle, > port):"
  if [ "$rel" = "<initial>" ]; then
    "$ORACLE" --initial > "$WORK/below_o.txt" 2>&1
    "$PORT" --initial > "$WORK/below_p.txt" 2>&1
  else
    "$ORACLE" "$REPO_NATIVE/$rel" > "$WORK/below_o.txt" 2>&1
    "$PORT" "$REPO_NATIVE/$rel" > "$WORK/below_p.txt" 2>&1
  fi
  diff "$WORK/below_o.txt" "$WORK/below_p.txt" | head -n 20
done < <(awk -F'\t' '$1 == "BELOW FLOOR" { print $3 }' "$VERDICTS")
echo "  $fails file(s) below or missing their floor"
if [ "$fails" -gt 0 ]; then
  status=1
fi

echo
echo "== 5. Per-file declaration parity: oracle declarations, port agreeing, fraction, floor"
printf '  %-16s %-46s %7s %8s %8s %7s  %s\n' verdict file decls agree fraction floor note
awk -F'\t' '{
  printf "  %-16s %-46s %7s %8s %8s %7s  %s\n", $1, $3, $4, $5, $6, $7, substr($8, 1, 100)
}' "$VERDICTS"

echo
echo "== 6. Corpus totals"
awk -F'\t' '
  {
    nodes[$1] += $3; matched[$1] += $4; count[$1] += 1
    if ($5 ~ /^ORACLE/) oracle[$1] += 1
    if ($5 ~ /^PORT/) port[$1] += 1
    total_nodes += $3; total_matched += $4; total_files += 1
    if ($5 ~ /^ORACLE/) total_oracle += 1
    if ($5 ~ /^PORT/) total_port += 1
  }
  END {
    n = 0
    for (k in nodes) keys[++n] = k
    for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (keys[j] < keys[i]) { t = keys[i]; keys[i] = keys[j]; keys[j] = t }
    for (i = 1; i <= n; i++) {
      k = keys[i]
      printf "  %-10s files %4d  oracle-failed %3d  port-failed %4d  oracle declarations %7d  agreeing %7d  fraction %6.2f%%\n", \
        k, count[k], oracle[k] + 0, port[k] + 0, nodes[k], matched[k], (nodes[k] ? 100 * matched[k] / nodes[k] : 0)
    }
    printf "  %-10s files %4d  oracle-failed %3d  port-failed %4d  oracle declarations %7d  agreeing %7d  fraction %6.2f%%\n", \
      "ALL", total_files, total_oracle + 0, total_port + 0, total_nodes, total_matched, (total_nodes ? 100 * total_matched / total_nodes : 0)
  }' "$RESULTS"

_decl_difference() {
  diff -u "$1" "$2" | awk '
    NR > 2 && /^-/ && !a { oracle = substr($0, 2); a = 1 }
    NR > 2 && /^\+/ && !b { mutant = substr($0, 2); b = 1 }
    END { printf "oracle [%s]; mutant [%s]", a ? oracle : "<absent>", b ? mutant : "<absent>" }
  '
}

# The precondition establishes baseline parity for each input in this scan.
# _decl_outcome <input> <oracle> <status> <output> <stderr> [<via> <message-ERE>]
# A difference or named refusal returns 1; other deaths are remembered, not caught.
DECL_DIED=""
_decl_outcome() {
  if [ "$3" -eq 0 ]; then
    cmp -s "$2" "$4" && return 0
    echo "decisive: $1: the declarations differ from the oracle's: $(_decl_difference "$2" "$4")"
    return 1
  fi
  if port_refusal "$3" "$5" || { [ -n "${6:-}" ] && expected_refusal "$3" "$5" "$6" "${7:-}"; }; then
    echo "decisive: $1: refused, though the unmutated driver dumps it as the oracle does: $(refusal_note "$3" "$5")"
    return 1
  fi
  [ -n "$DECL_DIED" ] || DECL_DIED="$1: $(refusal_note "$3" "$5")"
  return 0
}

check_decl_fixtures_diverge() {
  local probe="$WORK/mut_port$EXE" rc fixture rel oracle_mode port_mode
  DECL_DIED=""
  "$IYI" build -o "$(native_path "$probe")" "$REPO_NATIVE/bench/selfhost_semantic_declarations_exercise.iyi" > "$WORK/mut_build.log" 2>&1 || { echo "INVALID MUTANT: declaration driver did not build"; cat "$WORK/mut_build.log"; return 0; }
  for fixture in "$REPO"/bench/fixtures/semdecl_*.iyi "$REPO"/bench/fixtures/semdecl_*/*.iyi "$REPO"/bench/fixtures/semdecl_*/*/*.iyi; do
    rel="${fixture#$REPO/}"
    oracle_mode=""
    port_mode=""
    case "$(basename "$fixture")" in
      semdecl_ivar_typed_*) oracle_mode="--typed"; port_mode="--typed" ;;
    esac
    "$ORACLE" $oracle_mode "$REPO_NATIVE/$rel" > "$WORK/mut_o.txt" 2>/dev/null || { echo "INVALID MUTANT: declaration oracle failed on $rel"; return 0; }
    "$probe" $port_mode "$REPO_NATIVE/$rel" > "$WORK/mut_p.txt" 2> "$WORK/mut_p.err"
    rc=$?
    _decl_outcome "$rel" "$WORK/mut_o.txt" "$rc" "$WORK/mut_p.txt" "$WORK/mut_p.err" "$@" || return 1
  done
  "$ORACLE" --chain "$REPO_NATIVE/bench/fixtures/semdecl_prelude_chain.iyi" > "$WORK/mut_co.txt" 2>/dev/null || { echo "INVALID MUTANT: declaration oracle failed on the prelude chain"; return 0; }
  "$probe" --chain "$REPO_NATIVE/bench/fixtures/semdecl_prelude_chain.iyi" > "$WORK/mut_cp.txt" 2> "$WORK/mut_cp.err"
  rc=$?
  _decl_outcome "the prelude chain" "$WORK/mut_co.txt" "$rc" "$WORK/mut_cp.txt" "$WORK/mut_cp.err" "$@" || return 1
  [ -z "$DECL_DIED" ] || echo "INVALID MUTANT: no input told the mutant apart, and it died on $DECL_DIED"
  return 0
}

# This fixture is also covered by the baseline parity precondition.
check_reopen_superclass_diverge() {
  local probe="$WORK/mut_reopen_port$EXE" rel="bench/fixtures/semdecl_reopen_superclass.iyi" rc
  "$IYI" build -o "$(native_path "$probe")" "$REPO_NATIVE/bench/selfhost_semantic_declarations_exercise.iyi" > "$WORK/mut_build.log" 2>&1 || { echo "INVALID MUTANT: declaration driver did not build"; cat "$WORK/mut_build.log"; return 0; }
  "$ORACLE" "$REPO_NATIVE/$rel" > "$WORK/mut_ro.txt" 2>/dev/null || { echo "INVALID MUTANT: declaration oracle failed on $rel"; return 0; }
  "$probe" "$REPO_NATIVE/$rel" > "$WORK/mut_rp.txt" 2> "$WORK/mut_rp.err"
  rc=$?
  DECL_DIED=""
  _decl_outcome "$rel" "$WORK/mut_ro.txt" "$rc" "$WORK/mut_rp.txt" "$WORK/mut_rp.err" || return 1
  [ -z "$DECL_DIED" ] || echo "INVALID MUTANT: the mutant died on $DECL_DIED"
  return 0
}

check_lib_types_diverge() {
  # Compare the lib fun pin after a successful mutant build.
  local probe="$WORK/mut_lib_port$EXE"
  "$IYI" build -o "$(native_path "$probe")" "$REPO_NATIVE/bench/selfhost_semantic_declarations_exercise.iyi" > "$WORK/mut_build.log" 2>&1 || { echo "INVALID MUTANT: declaration driver did not build"; cat "$WORK/mut_build.log"; return 0; }
  "$probe" --lib-types "$REPO_NATIVE/bench/fixtures/semdecl_lib_types.iyi" > "$WORK/mut_lt_all.txt" 2>/dev/null || { echo "INVALID MUTANT: declaration driver failed"; return 0; }
  awk '/^lib LibTypes\./' "$WORK/mut_lt_all.txt" > "$WORK/mut_lt.txt"
  cmp -s "$WORK/mut_lt.txt" "$lib_types_expected" || return 1
  return 0
}
check_enum_primitives_diverge() {
  local probe="$WORK/mut_enum_primitives_port$EXE"
  "$IYI" build -o "$(native_path "$probe")" "$REPO_NATIVE/bench/selfhost_semantic_declarations_exercise.iyi" > "$WORK/mut_build.log" 2>&1 || { echo "INVALID MUTANT: declaration driver did not build"; cat "$WORK/mut_build.log"; return 0; }
  "$probe" --enum-primitives "$REPO_NATIVE/bench/fixtures/semdecl_enum_primitives.iyi" > "$WORK/mut_enum_primitives" 2>/dev/null || { echo "INVALID MUTANT: declaration oracle or driver failed"; return 0; }
  cmp -s "$WORK/mut_enum_primitives" "$WORK/enum_primitive_oracle"
}
check_enum_annotations_diverge() {
  local probe="$WORK/mut_enum_annotations_port$EXE"
  "$IYI" build -o "$(native_path "$probe")" "$REPO_NATIVE/bench/selfhost_semantic_declarations_exercise.iyi" > "$WORK/mut_build.log" 2>&1 || { echo "INVALID MUTANT: declaration driver did not build"; cat "$WORK/mut_build.log"; return 0; }
  "$probe" --enum-annotations "$REPO_NATIVE/bench/fixtures/semdecl_enum_annotations.iyi" > "$WORK/mut_enum_annotations" 2>/dev/null || { echo "INVALID MUTANT: declaration oracle or driver failed"; return 0; }
  cmp -s "$WORK/mut_enum_annotations" "$WORK/enum_annotations_oracle"
}
check_lib_starstar_diverge() {
  local probe="$WORK/mut_lib_starstar_port$EXE"
  "$IYI" build -o "$(native_path "$probe")" "$REPO_NATIVE/bench/selfhost_semantic_declarations_exercise.iyi" > "$WORK/mut_build.log" 2>&1 || { echo "INVALID MUTANT: declaration driver did not build"; cat "$WORK/mut_build.log"; return 0; }
  "$probe" --lib-types "$REPO_NATIVE/bench/fixtures/semdecl_lib_starstar.iyi" > "$WORK/mut_lib_starstar_all" 2>/dev/null || { echo "INVALID MUTANT: declaration oracle or driver failed"; return 0; }
  awk '/^lib LibBytes\./' "$WORK/mut_lib_starstar_all" > "$WORK/mut_lib_starstar"
  cmp -s "$WORK/mut_lib_starstar" "$WORK/lib_starstar_oracle"
}
check_classvar_generic_diverge() {
  local probe="$WORK/mut_classvar_port$EXE"
  "$IYI" build -o "$(native_path "$probe")" "$REPO_NATIVE/bench/selfhost_semantic_declarations_exercise.iyi" > "$WORK/mut_build.log" 2>&1 || { echo "INVALID MUTANT: declaration driver did not build"; cat "$WORK/mut_build.log"; return 0; }
  if "$probe" --classvar-generic "$REPO_NATIVE/bench/fixtures/semdecl_classvar_generic.iyi" > "$WORK/mut_classvar" 2>&1; then
    return 0
  fi
  if grep -Eq 'resolver lost generic arguments|pointer lost its argument|nilable pointer lost its argument' "$WORK/mut_classvar"; then
    return 1
  fi
  echo "INVALID MUTANT: class variable driver failed without the expected assertion"
  cat "$WORK/mut_classvar"
  return 0
}
check_enum_member_type_diverge() {
  local probe="$WORK/mut_enum_port$EXE"
  "$IYI" build -o "$(native_path "$probe")" "$REPO_NATIVE/bench/selfhost_semantic_declarations_exercise.iyi" > "$WORK/mut_build.log" 2>&1 || { echo "INVALID MUTANT: declaration driver did not build"; cat "$WORK/mut_build.log"; return 0; }
  "$probe" --enum-member-type "$REPO_NATIVE/bench/fixtures/semdecl_enum_member_type.iyi" > "$WORK/mut_enum_type" 2>/dev/null || { echo "INVALID MUTANT: declaration oracle or driver failed"; return 0; }
  cmp -s "$WORK/mut_enum_type" "$enum_type_expected"
}
check_primitive_annotations_diverge() {
  local probe="$WORK/mut_primitive_port$EXE"
  "$IYI" build -o "$(native_path "$probe")" "$REPO_NATIVE/bench/selfhost_semantic_declarations_exercise.iyi" > "$WORK/mut_build.log" 2>&1 || { echo "INVALID MUTANT: declaration driver did not build"; cat "$WORK/mut_build.log"; return 0; }
  "$probe" --primitive-annotations "$REPO_NATIVE/bench/fixtures/semdecl_primitive_annotations.iyi" > "$WORK/mut_primitive" 2>/dev/null || { echo "INVALID MUTANT: declaration oracle or driver failed"; return 0; }
  cmp -s "$WORK/mut_primitive" "$WORK/primitive_expected"
}
check_virtual_subtype_diverge() {
  local probe="$WORK/mut_virtual_port$EXE"
  "$IYI" build -o "$(native_path "$probe")" "$REPO_NATIVE/bench/selfhost_semantic_declarations_exercise.iyi" > "$WORK/mut_build.log" 2>&1 || { echo "INVALID MUTANT: declaration driver did not build"; cat "$WORK/mut_build.log"; return 0; }
  "$probe" --virtual-subtype "$REPO_NATIVE/bench/fixtures/semdecl_virtual_subtype.iyi" > "$WORK/mut_virtual" 2>/dev/null || { echo "INVALID MUTANT: declaration oracle or driver failed"; return 0; }
  cmp -s "$WORK/mut_virtual" "$WORK/virtual_oracle"
}
check_def_owner_diverge() {
  local probe="$WORK/mut_owner_port$EXE" rc
  "$IYI" build -o "$(native_path "$probe")" "$REPO_NATIVE/bench/selfhost_semantic_declarations_exercise.iyi" > "$WORK/mut_build.log" 2>&1 || { echo "INVALID MUTANT: declaration driver did not build"; cat "$WORK/mut_build.log"; return 0; }
  "$probe" --def-owner "$REPO_NATIVE/bench/fixtures/semdecl_def_owner.iyi" > "$WORK/mut_owner" 2> "$WORK/mut_owner.err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "INVALID MUTANT: definition owner driver failed: $(refusal_note "$rc" "$WORK/mut_owner.err")"
    return 0
  fi
  cmp -s "$WORK/mut_owner" "$WORK/owner_oracle" || { echo "decisive: semdecl_def_owner.iyi: the definition owners differ: $(_decl_difference "$WORK/owner_oracle" "$WORK/mut_owner")"; return 1; }
  return 0
}


check_const_facts_diverge() {
  # Compare the constant-facts pin after a successful mutant build.
  local probe="$WORK/mut_const_port$EXE"
  "$IYI" build -o "$(native_path "$probe")" "$REPO_NATIVE/bench/selfhost_semantic_declarations_exercise.iyi" > "$WORK/mut_build.log" 2>&1 || { echo "INVALID MUTANT: declaration driver did not build"; cat "$WORK/mut_build.log"; return 0; }
  "$probe" --const-facts "$REPO_NATIVE/bench/fixtures/semdecl_const_facts.iyi" > "$WORK/mut_cf_all.txt" 2>/dev/null || { echo "INVALID MUTANT: declaration driver failed"; return 0; }
  awk '/^(const (A|B|C) |predef |cvar )/' "$WORK/mut_cf_all.txt" > "$WORK/mut_cf.txt"
  cmp -s "$WORK/mut_cf.txt" "$const_facts_expected" || return 1
  return 0
}

check_pins_diverge() {
  local probe="$WORK/mut_pin_port$EXE" rc
  "$IYI" build -o "$(native_path "$probe")" "$REPO_NATIVE/bench/selfhost_semantic_declarations_exercise.iyi" > "$WORK/mut_build.log" 2>&1 || { echo "INVALID MUTANT: declaration driver did not build"; cat "$WORK/mut_build.log"; return 0; }
  "$probe" --total-typed "$REPO_NATIVE/bench/fixtures/total_unresolved_superclass.iyi" > "$WORK/mut_tt.txt" 2> "$WORK/mut_tt.err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$#" -eq 2 ] && expected_refusal "$rc" "$WORK/mut_tt.err" "$1" "$2"; then
      echo "decisive: total_unresolved_superclass.iyi: the total-mode load refused: $(refusal_note "$rc" "$WORK/mut_tt.err")"
      return 1
    fi
    echo "INVALID MUTANT: the total-mode load died: $(refusal_note "$rc" "$WORK/mut_tt.err")"
    return 0
  fi
  cmp -s "$WORK/mut_tt.txt" "$total_typed_expected" || { echo "decisive: total_unresolved_superclass.iyi: the total-mode output differs from the pin"; return 1; }
  "$probe" --scope-lookup "$REPO_NATIVE/bench/fixtures/semdecl_metaclass_scope.iyi" Lock HELD > "$WORK/mut_sl.txt" 2> "$WORK/mut_sl.err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "INVALID MUTANT: the metaclass scope lookup died: $(refusal_note "$rc" "$WORK/mut_sl.err")"
    return 0
  fi
  cmp -s "$WORK/mut_sl.txt" "$scope_expected" || { echo "decisive: semdecl_metaclass_scope.iyi: the metaclass scope lookup differs from the pin"; return 1; }
  return 0
}

check_link_annotations_diverge() {
  local probe="$WORK/mut_link_port$EXE" rc
  "$IYI" build -o "$(native_path "$probe")" "$REPO_NATIVE/bench/selfhost_semantic_declarations_exercise.iyi" > "$WORK/mut_build.log" 2>&1 || { echo "INVALID MUTANT: declaration driver did not build"; cat "$WORK/mut_build.log"; return 0; }
  "$probe" --link-annotations "$REPO_NATIVE/bench/fixtures/semdecl_link_annotations.iyi" > "$WORK/mut_la_all.txt" 2> "$WORK/mut_la.err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$#" -eq 2 ] && expected_refusal "$rc" "$WORK/mut_la.err" "$1" "$2"; then
      echo "decisive: semdecl_link_annotations.iyi: the link annotation load refused: $(refusal_note "$rc" "$WORK/mut_la.err")"
      return 1
    fi
    echo "INVALID MUTANT: the link annotation load died: $(refusal_note "$rc" "$WORK/mut_la.err")"
    return 0
  fi
  awk '/^link /' "$WORK/mut_la_all.txt" > "$WORK/mut_la.txt"
  cmp -s "$WORK/mut_la.txt" "$link_annotations_expected" || { echo "decisive: semdecl_link_annotations.iyi: the link records differ from the pin"; return 1; }
  return 0
}
check_reresolve_diverge() {
  local probe="$WORK/mut_reresolve_port$EXE"
  "$IYI" build -o "$(native_path "$probe")" "$REPO_NATIVE/bench/selfhost_semantic_declarations_exercise.iyi" > "$WORK/mut_build.log" 2>&1 || { echo "INVALID MUTANT: declaration driver did not build"; cat "$WORK/mut_build.log"; return 0; }
  "$ORACLE" --typed "$REPO_NATIVE/bench/fixtures/semdecl_ivar_typed_generic.iyi" > "$WORK/mut_rro.txt" 2>/dev/null || { echo "INVALID MUTANT: declaration oracle or driver failed"; return 0; }
  "$probe" --typed-reresolve "$REPO_NATIVE/bench/fixtures/semdecl_ivar_typed_generic.iyi" > "$WORK/mut_rrp.txt" 2>/dev/null || { echo "INVALID MUTANT: declaration oracle or driver failed"; return 0; }
  cmp -s "$WORK/mut_rro.txt" "$WORK/mut_rrp.txt" || return 1
  return 0
}

echo
echo "== 7. Mutation proofs: patches to the port's declaration pass the fixtures must catch"
MUT_SEM="$REPO/src/compiler/semantic/top_level.iyi"
MUT_IVARS="$REPO/src/compiler/semantic/instance_vars.iyi"
MUTATIONS_RUN=0
# A mutation proof means something only against a baseline the fixtures and the prelude
# chains already agree on: a fixture the oracle rejects fails every patched run and would
# count as a catch.
if [ "$fixture_bad" -ne 0 ] || [ "$link_oracle_ok" -ne 1 ] || ! grep -qx 'class variable generic arguments retained' "$WORK/classvar_result" || ! cmp -s "$WORK/enum_primitive_oracle" "$WORK/enum_primitive_port" || ! cmp -s "$WORK/owner_oracle" "$WORK/owner_port" || ! cmp -s "$WORK/virtual_oracle" "$WORK/virtual_port" || ! cmp -s "$WORK/primitive_actual" "$WORK/primitive_expected" || ! cmp -s "$WORK/enum_type_actual" "$enum_type_expected" || ! cmp -s "$WORK/chain_o.txt" "$WORK/chain_p.txt" || [ ! -s "$WORK/chain_o.txt" ] || ! cmp -s "$WORK/lt_pin.txt" "$lib_types_expected" || ! cmp -s "$WORK/cf_pin.txt" "$const_facts_expected" || ! cmp -s "$WORK/la_pin.txt" "$link_annotations_expected" || ! cmp -s "$WORK/tt_p.txt" "$total_typed_expected" || ! cmp -s "$WORK/sl_p.txt" "$scope_expected" || ! cmp -s "$WORK/rr_o.txt" "$WORK/rr_p.txt"; then
  echo "  mutation proofs not run: the fixtures or the prelude chains do not agree with the oracle"
  status=1
else

prove_mutation "imported class variables resolve eagerly" "$MUT_SEM" \
  "if @imported_unit || @defer_class_vars" \
  "if @defer_class_vars" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation_all "struct default superclass switches to Reference" "$MUT_SEM" \
  "superclass = node.struct ? @program.struct_type : @program.reference_type" \
  "superclass = @program.reference_type" \
  -- check_decl_fixtures_diverge src/compiler/semantic/top_level.iyi "^can't make struct '[^']*' inherit class 'Reference'\$" || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "enum members start numbering at one instead of zero" "$MUT_SEM" \
  "counter = @enum_flags ? 1_i64 : 0_i64" \
  "counter = @enum_flags ? 1_i64 : 1_i64" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "method visibility defaults to private instead of public" "$MUT_SEM" \
  "node.visibility = Visibility::Public" \
  "node.visibility = Visibility::Private" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "module path segments keep their written case" "$MUT_SEM" \
  "mod = NonGenericModuleType.new(@program, base, pname)" \
  "mod = NonGenericModuleType.new(@program, base, pname.downcase)" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "generated new is private instead of public" "$MUT_SEM" \
  "new_def.visibility = Visibility::Public" \
  "new_def.visibility = Visibility::Private" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "generated new drops the initialize arguments" "$MUT_SEM" \
  "new_def = Def.new(\"new\", node.args.map { |a| a.clone.as(Arg) }, Nop.new)" \
  "new_def = Def.new(\"new\", [] of Arg, Nop.new)" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "lib fun records its own name as the real name" "$MUT_SEM" \
  "real = node.real_name || node.name" \
  "real = node.name" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "lib fun drops its varargs flag" "$MUT_SEM" \
  "record = LibFun.new(node.name, real, arg_names, node.varargs, node.return_type)" \
  "record = LibFun.new(node.name, real, arg_names, false, node.return_type)" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "guessed instance variables lose their defining file's imports" "$MUT_IVARS" \
  '    program.current_imports = body.imports' \
  '    program.current_imports = saved_imports' \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "two argument pointer malloc does not infer its element type" "$MUT_IVARS" \
  '    if obj.is_a?(Path) && obj.as(Path).names == ["Pointer"] && node.name == "malloc" && node.args.size == 2' \
  '    if false' \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "lib struct takes Reference as its superclass" "$MUT_SEM" \
  "NonGenericClassType.new(@program, @current_type, node.name, @program.struct_type)" \
  "NonGenericClassType.new(@program, @current_type, node.name, @program.reference_type)" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a class reopened without a superclass takes the reference superclass" "$MUT_SEM" \
  $'      type = cls\n    else\n      created_new_type = true' \
  $'      type = cls\n      created_new_type = node.superclass.nil?\n    else\n      created_new_type = true' \
  -- check_reopen_superclass_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a metaclass takes Class as its parent even when its superclass has a metaclass" "$MUT_SEM" \
  "        @parents << meta_sc" \
  "        @parents << program.types[\"Class\"]" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation_all "a file's imports are never consulted when a name is looked up" "$MUT_SEM" \
  "      t = @current_imports[first_name]?" \
  "      t = nil" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a location-less builtin keeps its name over an import of that name" "$MUT_SEM" \
  "if found.locations.nil?" \
  "if false" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
MUT_DRIVER="$REPO/bench/selfhost_semantic_declarations_exercise.iyi"
prove_mutation "an instance is printed when its generic is declared outside the entry file" "$MUT_DRIVER" \
  "      next unless declared_in?(generic.locations, entry)" \
  "      nil" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a file's own directory is never searched for an import" "$MUT_SEM" \
  "      roots << dir" \
  "      roots << \"/nonexistent-root\"" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "explicit instance variables are recorded in reverse declaration order" "$MUT_IVARS" \
  "        program.pending_ivars.each do |pi|" \
  "        program.pending_ivars.reversed.each do |pi|" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "guessed variables are recorded before explicit variables" "$MUT_IVARS" \
  '      [true, false].each do |explicit_pass|' \
  '      declare_guessed(program, owners, og)
      [true, false].each do |explicit_pass|' \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "subclass declarations are processed before superclass guesses" "$MUT_IVARS" \
  '      next unless class_depth(og.owner) == depth' \
  '      next unless class_depth(og.owner) == max_depth - depth' \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "an initialize argument instance variable is recorded ahead of the class body's" "$MUT_SEM" \
  "@pending_ivars << PendingIvar.new(@current_type, ivar_name, r, nil, true)" \
  "@pending_ivars.unshift(PendingIvar.new(@current_type, ivar_name, r, nil, true))" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
# Pending and guessed declarations cover for each other, so dropping either
# is unobservable. Mutate the pending declaration's type instead.
prove_mutation "a typed argument's instance variable takes its restriction type" "$MUT_IVARS" \
  "mv = MetaTypeVar.new(pi.name, arg_type, pi.initializer)" \
  "mv = MetaTypeVar.new(pi.name, program.nil_type, pi.initializer)" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation_all "a declared instance variable keeps its bare type: the virtual type is not taken" "$MUT_SEM" \
  "return hook.virtual_of(resolved)" \
  "return resolved" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "an initialize argument instance variable keeps its bare type: the virtual type is not taken" "$MUT_SEM" \
  "@pending_ivars << PendingIvar.new(@current_type, ivar_name, r, nil, true)" \
  "@pending_ivars << PendingIvar.new(@current_type, ivar_name, r, nil, false)" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "pointer malloc and null calls do not infer instance variable types" "$MUT_IVARS" \
  '    if obj.is_a?(Generic) && (node.name == "malloc" || node.name == "null")' \
  '    if false' \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "constructor guesses omit classes with subclasses" "$MUT_IVARS" \
  '      if found && found.is_a?(NonGenericClassType)' \
  '      if found && found.is_a?(NonGenericClassType) && found.as(NonGenericClassType).subclasses.empty?' \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "typed array literals do not infer instance variable types" "$MUT_IVARS" \
  '    if node.is_a?(ArrayLiteral)' \
  '    if false' \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "array literal elements do not infer instance variable types" "$MUT_IVARS" \
  '      if literal.name.nil? && literal.of.nil?' \
  '      if false' \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "generic new calls do not infer instance variable types" "$MUT_IVARS" \
  '    if node.name == "new" && obj.is_a?(Generic)' \
  '    if node.name == "never" && obj.is_a?(Generic)' \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a generic class's guessed instance variables are not declared on the generic" "$MUT_IVARS" \
  "if og.owner.is_a?(NonGenericClassType) || og.owner.is_a?(GenericClassType)" \
  "if og.owner.is_a?(NonGenericClassType)" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "an explicit generic instance variable keeps the unbound generic" "$MUT_IVARS" \
  "  type_node_system(program)" \
  "  nil" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "optional type lookup skips enclosing namespaces" "$MUT_SEM" \
  "        match = ns.lookup_type(first_name)" \
  "        match = nil" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "optional proc notation lookup loses its arguments" "$MUT_SEM" \
  "        return hook.instantiate_type(proc_type, args)" \
  "        return proc_type" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a declared instance variable is not re-resolved once the type system is installed" "$MUT_SEM" \
  "di.owner.instance_vars[di.name] = mv" \
  "nil" \
  -- check_reresolve_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "an explicit instance variable is not recorded for re-resolution" "$MUT_IVARS" \
  "program.declared_ivars << DeclaredIvar.new(pi.owner, pi.name, pi.restriction, pi.initializer, pi.virtual, program.current_imports)" \
  "nil" \
  -- check_reresolve_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
MUT_TS="$REPO/src/compiler/types/type_system.iyi"
prove_mutation_all "a generic type node resolves to its base once the type system is installed" "$MUT_SEM" \
  "          return hook.instantiate_type(base_type, type_args)" \
  "          return base_type" \
  -- check_lib_types_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "installing the type system leaves the lib fun records unresolved" "$MUT_TS" \
  "    @program.resolve_declared_types" \
  "    nil" \
  -- check_lib_types_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a lib fun's return type is dropped once the type system is installed" "$MUT_SEM" \
  "                  f.resolved_return = found" \
  "                  f.resolved_return = nil" \
  -- check_lib_types_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a constant is never added to the program's constant list" "$MUT_SEM" \
  "      @program.const_initializers << const" \
  "      nil" \
  -- check_const_facts_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a class variable is declared without its owner" "$MUT_SEM" \
  "@current_type.class_vars[cvar_name] = mv" \
  "@current_type.class_vars[cvar_name] = MetaTypeVar.new(cvar_name, decl_type, node.value)" \
  -- check_const_facts_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "the predefined constants are not found by name" "$MUT_SEM" \
  "if name == \"ARGC_UNSAFE\" || name == \"ARGV_UNSAFE\"" \
  "if name == \"NOPE\"" \
  -- check_const_facts_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a named framework argument of a link annotation is refused" "$MUT_SEM" \
  "          elsif na.name == \"framework\"" \
  "          elsif na.name == \"frameworkX\"" \
  -- check_link_annotations_diverge src/compiler/semantic/top_level.iyi "^unknown link argument: 'framework'\$" || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a positional ldflags argument of a link annotation is refused" "$MUT_SEM" \
  "          elsif i == 1" \
  "          elsif i == 9" \
  -- check_link_annotations_diverge src/compiler/semantic/top_level.iyi "^too many link arguments\$" || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a lib records only its first link annotation" "$MUT_SEM" \
  "      if ann.path.names.last == \"Link\"" \
  "      if ann.path.names.last == \"Link\" && lib_type.link_annotations.empty?" \
  -- check_link_annotations_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "an unresolvable written type raises once the type system is installed, even in total mode" "$MUT_TS" \
  "      raise(message) unless @program.total_mode" \
  "      raise(message)" \
  -- check_pins_diverge src/compiler/types/type_system.iyi "." || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "total mode raises on an unresolved superclass instead of carrying it past" "$MUT_SEM" \
  "      if superclass.is_a?(UnresolvedType) && @program.total_mode" \
  "      if superclass.is_a?(UnresolvedType) && !@program.total_mode" \
  -- check_pins_diverge src/compiler/semantic/top_level.iyi "^<unresolved [^>]*> is not a class, it's a unresolved\$" || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a metaclass scope does not look names up in its instance type" "$MUT_SEM" \
  "        return lookup_type_path?(path, instance.as(ModuleType))" \
  "        return nil" \
  -- check_pins_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
MUT_TYPES="$REPO/src/compiler/types/types.iyi"
prove_mutation "a printed type argument keeps its virtual wrapper" "$MUT_TYPES" \
  "    return @base_type" \
  "    return self" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a virtual restriction does not accept its base or subclasses" "$MUT_SEM" \
  '    return subtype_of?(target) unless target == other' \
  '    return false unless target == other' \
  -- check_virtual_subtype_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a registered definition loses its defining owner" "$MUT_SEM" \
  '    @program.record_def_owner(a_def, self)' \
  '    nil' \
  -- check_def_owner_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a generic instance displays a virtual argument without devirtualizing it" "$MUT_TYPES" \
  '    args_strs = @type_args.map { |a| a.devirtualize.arg_full_name }' \
  '    args_strs = @type_args.map { |a| a.arg_full_name }' \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a generic instance's instance variable keeps its type parameter" "$MUT_TYPES" \
  "if replacement = tv_map[type.name]?" \
  "if replacement = tv_map[\"no such parameter\"]?" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a generic instance's nested generic argument is not rebuilt" "$MUT_TYPES" \
  "return hook.instantiate_type(generic, args)" \
  "return inst" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a generic instance copies no instance variable the first time" "$MUT_TYPES" \
  "unless (copied = @copied_from[name]?) && copied == source" \
  "if (copied = @copied_from[name]?) && copied == source" \
  -- check_decl_fixtures_diverge || status=1

MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a declared instance variable keeps its alias: the optional path takes the alias itself" "$MUT_SEM" \
  "    resolved = remove_alias(found)" \
  "    resolved = found" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a generic instance's declared variable keeps its parameter type" "$MUT_TYPES" \
  "            mv = MetaTypeVar.new(name, TypeQueries.replace_type_parameters(source_type, @type_vars))" \
  "            mv = MetaTypeVar.new(name, source_type)" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a nilable pointer prints without its element type" "$MUT_TYPES" \
  'Pointer(#{@element_type.full_name})' \
  'Pointer' \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a replaced def is not reachable from the def that replaced it" "$MUT_SEM" \
  "          a_def.previous = old" \
  "          a_def.previous = nil" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a type-variable restriction replaces a prelude def of the same text" "$MUT_SEM" \
  "      return vars.includes?(path.names[0])" \
  "      return false" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "an external variable's setter is not added" "$MUT_SEM" \
  "    lib_type.funs << setter_fun" \
  "    setter_fun.external_var = false" \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "an external variable keeps its uninstantiated type" "$MUT_SEM" \
  '    @external_var_funs.each do |f|' \
  '    ([] of LibFun).each do |f|' \
  -- check_lib_types_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "an enum member loses its enum type" "$MUT_SEM" \
  "    c.enum_value_type = self" \
  "    c.enum_value_type = nil" \
  -- check_enum_member_type_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "only the last annotation is read for a primitive" "$MUT_SEM" \
  "    @pending_annotations.each do |ann|" \
  "    if ann = @pending_annotations.last?" \
  -- check_primitive_annotations_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "enum host flags select the wrong platform branch" "$MUT_SEM" \
  '    MacroTargetFlags.for_triple(MacroTargetFlags.compile_time_triple, [] of String).includes?(name)' \
  '    !MacroTargetFlags.for_triple(MacroTargetFlags.compile_time_triple, [] of String).includes?(name)' \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "enum value loses its base integer result" "$MUT_SEM" \
  '    program.record_primitive_return_type(value_def, @base_type)' \
  '    program.record_primitive_return_type(value_def, self)' \
  -- check_enum_primitives_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "class variable generic arguments are not re-resolved" "$MUT_SEM" \
  '    @declared_cvars.each do |dc|' \
  '    ([] of DeclaredIvar).each do |dc|' \
  -- check_classvar_generic_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a redeclared external loses its previous link" "$MUT_SEM" \
  '            record.previous = old' \
  '            record.previous = nil' \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
if cmp -s "$WORK/enum_annotations_oracle" "$WORK/enum_annotations_port"; then
  prove_mutation "an enum loses its annotation" "$MUT_SEM" \
    '      enum_type.add_annotation(annotation_type.as(AnnotationType), ann)' \
    '      nil' \
    -- check_enum_annotations_diverge || status=1
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
else
  echo "  NOT RUN: enum annotation baseline differs"
  status=1
fi
if [ -s "$WORK/lib_starstar_oracle" ] && cmp -s "$WORK/lib_starstar_oracle" "$WORK/lib_starstar_port"; then
  prove_mutation "a nested pointer lib argument loses its resolved type" "$MUT_SEM" \
    '                  resolved_args << found' \
    '                  resolved_args << @program.int32_type' \
    -- check_lib_starstar_diverge || status=1
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
else
  echo "  NOT RUN: nested pointer lib signature baseline differs"
  status=1
fi
prove_mutation "a generic alias loses its instantiated arguments" "$MUT_SEM" \
  '      if @value.is_a?(Generic) && @program.merge_hook.nil?' \
  '      if @value.is_a?(Generic)' \
  -- check_decl_fixtures_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
echo "  $MUTATIONS_RUN mutation proofs run"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "ALL SEMANTIC DECLARATION CHECKS PASSED"
else
  echo "SEMANTIC DECLARATION CHECKS FAILED"
fi
exit "$status"
