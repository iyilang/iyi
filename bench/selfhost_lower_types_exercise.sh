#!/usr/bin/env bash
# Fails when the iyi lowering of analysed types stops agreeing with the hosted typer.
#
# Each fixture (bench/fixtures/lowty_*.iyi) declares types and lists each one to
# lower as a `# type: <expr>` line. The hosted oracle
# (bench/selfhost_lower_types_oracle.cr) and the port's driver
# (bench/selfhost_lower_types_exercise.iyi) each print one block per type: its
# LLVM type, its wants_size type, its struct and offsets where it has one, its
# embedded type, size, alignment and by-value flag. The two outputs must be
# byte-identical for the same target triple.
#
# Mutation proofs patch the ported code, rebuild the driver, and require the gate
# to fail. A patch that changes nothing is refused by prove_mutation.
#
#   bash bench/selfhost_lower_types_exercise.sh
#   LOWER_TYPES_TARGET=x86_64-unknown-linux-gnu bash bench/selfhost_lower_types_exercise.sh
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
export IYI_PATH="$REPO/src"
IYI="${IYI_COMPILER:-$REPO/bin/iyi}"
CRYSTAL="${CRYSTAL:-crystal}"
TYPER_FILE="$REPO/src/compiler/lower/typer.iyi"
TYPE_ID_FILE="$REPO/src/compiler/lower/type_id.iyi"
LAYOUTS_FILE="$REPO/src/compiler/lower/layouts.iyi"
UNIONS_FILE="$REPO/src/compiler/lower/unions.iyi"
HEADED_FILE="$REPO/src/compiler/lower/headed.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

. "$REPO/bench/lib/mutation.sh"

# The host triple both printers are given, so the layouts agree. The gate runs on
# the darwin arm64 and linux x86_64 runners; another host is named explicitly.
if [ -n "${LOWER_TYPES_TARGET:-}" ]; then
  TRIPLE="$LOWER_TYPES_TARGET"
else
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)  TRIPLE="aarch64-apple-darwin" ;;
    Linux-x86_64)  TRIPLE="x86_64-unknown-linux-gnu" ;;
    Linux-aarch64) TRIPLE="aarch64-unknown-linux-gnu" ;;
    *) echo "no lowering target for $(uname -s)-$(uname -m); set LOWER_TYPES_TARGET"; exit 1 ;;
  esac
fi

echo "== 1. Building the hosted oracle and the port driver ($TRIPLE)"
LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
  CRYSTAL_PATH="$REPO/src" "$CRYSTAL" build -Di_know_what_im_doing \
    -o "$WORK/oracle" "$REPO/bench/selfhost_lower_types_oracle.cr" >/dev/null 2>&1 || { echo "oracle build failed"; exit 1; }
"$IYI" build -o "$WORK/port" "$REPO/bench/selfhost_lower_types_exercise.iyi" || { echo "port driver build failed"; exit 1; }
type_id_fork_ok() {
  if ! "$IYI" build -o "$WORK/fork_probe" "$REPO/bench/selfhost_type_id_fork_probe.iyi" > "$WORK/fork_probe.build.log" 2>&1; then
    echo "INVALID MUTANT: type-id fork probe failed to build" >&2
    if [ "${_PM_ARMED:-0}" = 1 ]; then return 0; fi
    return 1
  fi
  if [ "$(uname -s)" = Darwin ] && ! codesign -v --strict "$WORK/fork_probe"; then
    echo "INVALID MUTANT: type-id fork probe failed signature verification" >&2
    return 0
  fi
  "$WORK/fork_probe" > "$WORK/fork_probe.out" 2>&1
}
if type_id_fork_ok; then
  prove_mutation "type-id probe forks share the baseline map" "$TYPE_ID_FILE" \
    'LowerTypeIds.new(@ids.dup, @id_to_metaclass.dup, @next_id, @names.dup, @types.dup)' \
    'LowerTypeIds.new(@ids, @id_to_metaclass.dup, @next_id, @names.dup, @types.dup)' -- type_id_fork_ok || status=1
else
  echo "  FAIL: type-id fork baseline failed"
  status=1
fi
if "$IYI" build --no-codegen "$REPO/bench/fixtures/refuse_type_id_tuple_write.iyi" > "$WORK/tuple_write.log" 2>&1 ||
   ! grep -Fq "undefined method '[]=' for Tuple(Int32, Int32)" "$WORK/tuple_write.log"; then
  echo "  FAIL: tuple element assignment was not rejected"
  status=1
fi


# The type ids (`lowtyid_*.iyi`) are compared by shape: the port's ids must equal the
# hosted ids shifted by one constant, across every type_id and type_range value of the
# fixture. The shift is the builtins' numbering difference (NEEDS.md row 16). Prints the
# shift, and fails when the shape differs or a value is missing.
ids_shape() {
  awk 'FNR == NR { if ($1 == "type_id:" || $1 == "type_range:") { for (i = 2; i <= NF; i++) o[++n] = $i } if ($1 == "metaclass_id:") om[++mn] = $2; next }
       $1 == "type_id:" || $1 == "type_range:" { for (i = 2; i <= NF; i++) p[++m] = $i }
       $1 == "metaclass_id:" { pm[++mp] = $2 }
       END {
         if (n == 0 || n != m) exit 1
         if (mn == 0 || mn != mp) exit 1
         shift = p[1] - o[1]
         for (k = 1; k <= n; k++) { if (o[k] !~ /^-?[0-9]+$/ || p[k] !~ /^-?[0-9]+$/) exit 1; if (p[k] - o[k] != shift) exit 1 }
         for (k = 1; k <= mn; k++) { if (om[k] == "-" || pm[k] == "-") { if (om[k] != pm[k]) exit 1; continue } if (om[k] !~ /^-?[0-9]+$/ || pm[k] !~ /^-?[0-9]+$/) exit 1; if (pm[k] - om[k] != shift) exit 1 }
         print shift
       }' "$1" "$2"
}

echo
echo "== 2. Each fixture's blocks, hosted oracle against the port"
fixture_count=0
block_count=0
diverged=0
for fixture in "$REPO"/bench/fixtures/lowty_*.iyi; do
  name="$(basename "$fixture" .iyi)"
  if ! "$WORK/oracle" "$fixture" "$TRIPLE" > "$WORK/$name.oracle" 2> "$WORK/$name.oracle.err"; then
    echo "  $name: oracle failed: $(cat "$WORK/$name.oracle.err")"
    diverged=$((diverged + 1))
    continue
  fi
  if ! "$WORK/port" "$fixture" "$TRIPLE" > "$WORK/$name.port" 2> "$WORK/$name.port.err"; then
    echo "  $name: port driver failed: $(head -n 2 "$WORK/$name.port.err")"
    diverged=$((diverged + 1))
    continue
  fi
  if cmp -s "$WORK/$name.oracle" "$WORK/$name.port"; then
    fixture_count=$((fixture_count + 1))
    n=$(awk '/^== /{ n++ } END { print n + 0 }' "$WORK/$name.oracle")
    block_count=$((block_count + n))
  else
    echo "  $name: DIVERGES from the hosted oracle:"
    diff "$WORK/$name.oracle" "$WORK/$name.port" | head -n 20
    diverged=$((diverged + 1))
  fi
done
echo "  Parity summary: $fixture_count fixtures identical ($block_count types compared), $diverged diverged"
ids_count=0
for fixture in "$REPO"/bench/fixtures/lowtyid_*.iyi; do
  name="$(basename "$fixture" .iyi)"
  "$WORK/oracle" "$fixture" "$TRIPLE" ids > "$WORK/$name.ids_oracle" 2>"$WORK/$name.oracle.err" || { echo "  $name: oracle failed"; diverged=$((diverged + 1)); continue; }
  "$WORK/port" "$fixture" "$TRIPLE" ids > "$WORK/$name.ids_port" 2>"$WORK/$name.port.err" || { echo "  $name: port driver failed: $(head -n 2 "$WORK/$name.port.err")"; diverged=$((diverged + 1)); continue; }
  if shift=$(ids_shape "$WORK/$name.ids_oracle" "$WORK/$name.ids_port"); then
    ids_count=$((ids_count + 1))
    echo "  $name: type ids agree in shape with the hosted numbering (port = hosted + $shift)"
  else
    echo "  $name: type ids DIVERGE in shape from the hosted numbering"
    diverged=$((diverged + 1))
  fi
done
echo "  Type id summary: $ids_count fixtures agree in shape"
if [ "$ids_count" -eq 0 ]; then
  echo "  no type id fixture was compared"
  status=1
fi
headed_count=0
for fixture in "$REPO"/bench/fixtures/lowhead_*.iyi; do
  name="$(basename "$fixture" .iyi)"
  "$WORK/oracle" "$fixture" "$TRIPLE" headed > "$WORK/$name.headed_oracle" 2>"$WORK/$name.oracle.err" || { echo "  $name: oracle failed"; diverged=$((diverged + 1)); continue; }
  "$WORK/port" "$fixture" "$TRIPLE" headed > "$WORK/$name.headed_port" 2>"$WORK/$name.port.err" || { echo "  $name: port driver failed: $(head -n 2 "$WORK/$name.port.err")"; diverged=$((diverged + 1)); continue; }
  if cmp -s "$WORK/$name.headed_oracle" "$WORK/$name.headed_port"; then
    headed_count=$((headed_count + 1))
    echo "  $name: headed bytes agree with the hosted census"
  else
    echo "  $name: headed bytes DIVERGE from the hosted census:"
    diff "$WORK/$name.headed_oracle" "$WORK/$name.headed_port" | head -n 20
    diverged=$((diverged + 1))
  fi
done
echo "  Headed census summary: $headed_count fixtures agree"
if [ "$headed_count" -eq 0 ]; then
  echo "  no headed fixture was compared"
  status=1
fi
if [ "$fixture_count" -eq 0 ]; then
  echo "  no fixture was compared"
  status=1
fi
if [ "$diverged" -ne 0 ]; then
  status=1
fi

echo
echo "== 2c. Own source: every type each file declares, the hosted oracle against the port (floor)"
own_list="$WORK/own_files.txt"
if [ -n "${LOWER_TYPES_FILES:-}" ]; then
  cp "$LOWER_TYPES_FILES" "$own_list"
else
  (cd "$REPO" && find src/compiler -name '*.iyi' | sort) > "$own_list"
fi
own_results="$WORK/own_results.tsv"
own_reasons="$WORK/own_reasons.tsv"
: > "$own_results"
: > "$own_reasons"
while IFS= read -r file; do
  [ -n "$file" ] || continue
  id=$(printf '%s' "$file" | tr '/' '_')
  timeout 900 "$WORK/oracle" --own "$REPO/$file" "$TRIPLE" > "$WORK/$id.o" 2> "$WORK/$id.oe"
  oracle_status=$?
  timeout 900 "$WORK/port" --own "$REPO/$file" "$TRIPLE" > "$WORK/$id.p" 2> "$WORK/$id.pe"
  port_status=$?
  declared=$(awk '/^== /{n++} END{print n+0}' "$WORK/$id.o")
  if [ "$oracle_status" -ne 0 ]; then
    printf '%s\tORACLE\t0\t0\t0\t0\t0\t%s\n' "$file" "$(awk 'NR==1' "$WORK/$id.oe" | tr -d '\t')" >> "$own_results"
    continue
  fi
  if [ "$port_status" -ne 0 ]; then
    printf '%s\tPORT\t%s\t0\t0\t0\t0\t%s\n' "$file" "$declared" "$(awk 'NR==1' "$WORK/$id.pe" | tr -d '\t')" >> "$own_results"
    continue
  fi
  python3 "$REPO/bench/lib/lower_types_compare.py" "$WORK/$id.o" "$WORK/$id.p" > "$WORK/$id.cmp"
  read -r declared identical failed missing differs < <(awk 'NR==1' "$WORK/$id.cmp")
  awk -v f="$file" '/^(REASON|EXAMPLE) / {print f "\t" $0}' "$WORK/$id.cmp" >> "$own_reasons"
  printf '%s\tOK\t%s\t%s\t%s\t%s\t%s\t\n' "$file" "$declared" "$identical" "$failed" "$missing" "$differs" >> "$own_results"
done < "$own_list"
own_floor="$REPO/bench/selfhost_lower_types.floor"
own_verdicts="$WORK/own_verdicts.tsv"
awk -F'\t' -v floorf="$own_floor" '
  BEGIN {
    while ((getline line < floorf) > 0) {
      if (line ~ /^#/ || line == "") continue
      split(line, a, " "); floor[a[1]] = a[2]
    }
  }
  {
    file = $1; status = $2; identical = $4 + 0
    if (status == "ORACLE") { print "NOT MEASURED\t" file "\t" $8; next }
    if (!(file in floor)) { print "NO FLOOR\t" file "\t" identical "\t-"; next }
    if (identical < floor[file] + 0) print "BELOW FLOOR\t" file "\t" identical "\t" floor[file]
    else if (identical > floor[file] + 0) print "RAISE THE FLOOR\t" file "\t" identical "\t" floor[file]
    else print "AT FLOOR\t" file "\t" identical "\t" floor[file]
  }' "$own_results" > "$own_verdicts"
if [ "${LOWER_TYPES_RAISE:-0}" = 1 ]; then
  awk -F'\t' -v floorf="$own_floor" '
    BEGIN {
      while ((getline line < floorf) > 0) {
        if (line ~ /^#/ || line == "") continue
        split(line, a, " "); floor[a[1]] = a[2]
      }
    }
    $2 == "OK" || $2 == "PORT" { if (!($1 in floor) || $4 + 0 > floor[$1] + 0) floor[$1] = $4 + 0 }
    END { for (f in floor) print f " " floor[f] }' "$own_results" | LC_ALL=C sort > "$own_floor.new"
  { echo "# lowering own-source floors: <repo-relative file> <identical types>."; echo "# A count may only rise. Raise with: LOWER_TYPES_RAISE=1 bash bench/selfhost_lower_types_exercise.sh"; cat "$own_floor.new"; } > "$own_floor"
  rm -f "$own_floor.new"
fi
own_fails=$(awk -F'\t' '$1 == "BELOW FLOOR" || $1 == "RAISE THE FLOOR" || $1 == "NO FLOOR"' "$own_verdicts" | wc -l | tr -d ' ')
if [ "${LOWER_TYPES_RAISE:-0}" = 1 ]; then
  own_fails=$(awk -F'\t' '$1 == "BELOW FLOOR"' "$own_verdicts" | wc -l | tr -d ' ')
fi
awk -F'\t' '$1 == "BELOW FLOOR" { printf "  BELOW FLOOR: %s identical %s, floor %s. A regression: restore the lowering, lower nothing.\n", $2, $3, $4 }
  $1 == "RAISE THE FLOOR" { printf "  RAISE THE FLOOR: %s identical %s, floor %s. Raise it (LOWER_TYPES_RAISE=1).\n", $2, $3, $4 }
  $1 == "NO FLOOR" { printf "  NO FLOOR: %s has no floor entry (LOWER_TYPES_RAISE=1).\n", $2 }' "$own_verdicts"
echo "  $own_fails file(s) below, above or missing their floor"
if [ "$own_fails" -ne 0 ]; then
  status=1
fi
echo "  per file: verdict, file, hosted types declared, identical, floor"
awk -F'\t' '{ printf "  %-18s %-52s %6s %6s %6s %s\n", $1, $2, "", $3, "", $4 }' "$own_verdicts"
own_totals=$(awk -F'\t' '
  $2 == "OK" { measured++; declared += $3; identical += $4; differs += $7 }
  $2 == "PORT" { port_failed++; declared += $3 }
  $2 == "ORACLE" { oracle_failed++ }
  END { printf "%d %d %d %d %d %d %d", measured + 0, port_failed + 0, oracle_failed + 0, declared + 0, identical + 0, differs + 0, NR }' "$own_results")
read -r own_measured own_port_failed own_oracle_failed own_declared own_identical own_differs own_files_total <<< "$own_totals"
echo "  own source: $own_files_total files, $own_measured measured, $own_oracle_failed hosted failures (not measured), $own_port_failed port failures"
echo "  own source types: $own_identical identical of $own_declared declared ($own_differs differ) across the measured files"
echo "  ranked reasons (types that differ or are not measured, by count):"
awk -F'\t' '
  $2 ~ /^REASON / { line = $2; sub(/^REASON /, "", line); n = line; sub(/ .*/, "", n); text = line; sub(/^[0-9]+ /, "", text); tot[text] += n }
  $2 ~ /^EXAMPLE / { text = $2; sub(/^EXAMPLE /, "", text); if (!(text in ex)) ex[text] = $3 }
  END { for (t in tot) printf "%7d\t%s\t%s\n", tot[t], t, ex[t] }' "$own_reasons" | sort -t"$(printf '\t')" -k1,1rn | awk -F'\t' 'NR <= 40 { printf "%7d  %s   [e.g. %s]\n", $1, $2, $3 }'
awk -F'\t' '$2 == "ORACLE" { print "  hosted: " $8 }' "$own_results" | sort | uniq -c | sort -rn | awk 'NR <= 15'
awk -F'\t' '$2 == "PORT" { print "  port:   " $8 }' "$own_results" | sort | uniq -c | sort -rn | awk 'NR <= 15'

echo
echo "== 3. Guarded mutation proofs (patch, rebuild, the gate must fail)"
MUTATIONS_RUN=0

# A check fails (non-zero) when the mutated driver is detected: it does not build,
# it fails on a fixture, or any fixture's blocks differ from the hosted oracle's.
# It returns 0 only when every fixture still matches, which is the unmutated behaviour.
check_lowering_diverges() {
  "$IYI" build -o "$WORK/mut_port" "$REPO/bench/selfhost_lower_types_exercise.iyi" >/dev/null 2>&1 || return 1
  for fixture in "$REPO"/bench/fixtures/lowty_*.iyi; do
    name="$(basename "$fixture" .iyi)"
    "$WORK/mut_port" "$fixture" "$TRIPLE" > "$WORK/mut.out" 2>/dev/null || return 1
    cmp -s "$WORK/$name.oracle" "$WORK/mut.out" || return 1
  done
  return 0
}

prove_mutation "Bool lowered to i8, not i1" "$TYPER_FILE" \
  "      return @table.int1" \
  "      return @table.int8" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "Char lowered to i16, not i32" "$TYPER_FILE" \
  "      return @table.int32" \
  "      return @table.int16" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "Float32 lowered to double" "$TYPER_FILE" \
  "      return primitive_bytes(type) == 4 ? @table.float(32) : @table.float(64)" \
  "      return @table.float(64)" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "enum lowered to Int64 whatever its base" "$TYPER_FILE" \
  "      return llvm_type(type.as(EnumType).base_type)" \
  "      return @table.int64" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "metaclass branch bypassed (metaclasses fall through to the raise)" "$TYPER_FILE" \
  "    if type.is_a?(MetaclassType) || type.is_a?(VirtualMetaclassType)" \
  "    if false" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "void alignment reported as 2 bytes" "$TYPER_FILE" \
  "    return 1 if t.void?" \
  "    return 2 if t.void?" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "Nil lowered to an i8 instead of the named empty struct" "$TYPER_FILE" \
  "      return nil_type" \
  "      return @table.int8" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "mixed union drops its type id word" "$UNIONS_FILE" \
  "  [table.int32, value_type]" \
  "  [value_type]" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "mixed union value area ignores its largest member" "$TYPER_FILE" \
  "      max_size = size if size > max_size" \
  "      max_size = max_size if size > max_size" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "mixed union aligned to 4 bytes, not the largest member" "$TYPER_FILE" \
  "    max_alignment = pointer_size.to_i32" \
  "    max_alignment = 4" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a module or trait union member is laid out as itself" "$TYPER_FILE" \
  "        includers.each { |includer| expanded << includer }" \
  "        expanded << member" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))


prove_mutation "indirect threshold above a 136-byte value" "$TYPER_FILE" \
  "    size_of(llvm_type(type)) > 128" \
  "    size_of(llvm_type(type)) > 136" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "closure context pointer not prepended" "$TYPER_FILE" \
  "    params << @table.ptr if closure" \
  "    params << @table.ptr if false" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "indirect result returned as int32, not void" "$TYPER_FILE" \
  "      return @table.func(params, @table.void)" \
  "      return @table.func(params, @table.int32)" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

check_ids_diverge() {
  "$IYI" build -o "$WORK/mut_port" "$REPO/bench/selfhost_lower_types_exercise.iyi" >/dev/null 2>&1 || return 1
  for fixture in "$REPO"/bench/fixtures/lowtyid_*.iyi; do
    name="$(basename "$fixture" .iyi)"
    "$WORK/mut_port" "$fixture" "$TRIPLE" ids > "$WORK/mut_ids.out" 2>/dev/null || return 1
    ids_shape "$WORK/$name.ids_oracle" "$WORK/mut_ids.out" >/dev/null || return 1
  done
  return 0
}

check_headed_diverges() {
  "$IYI" build -o "$WORK/mut_port" "$REPO/bench/selfhost_lower_types_exercise.iyi" >/dev/null 2>&1 || return 1
  for fixture in "$REPO"/bench/fixtures/lowhead_*.iyi; do
    name="$(basename "$fixture" .iyi)"
    "$WORK/mut_port" "$fixture" "$TRIPLE" headed > "$WORK/mut_headed.out" 2>/dev/null || return 1
    cmp -s "$WORK/$name.headed_oracle" "$WORK/mut_headed.out" || return 1
  done
  return 0
}

prove_mutation "class instance variables stored as one i8 each" "$TYPER_FILE" \
  "      fields << llvm_embedded_type(var_type.as(Type), wants_size)" \
  "      fields << @table.int8" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a generic instance's fields are its generic's own, not its arguments'" "$TYPER_FILE" \
  "type.as(GenericClassInstanceType).all_instance_vars" \
  "type.as(GenericClassInstanceType).generic_type.as(ModuleType).all_instance_vars" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "object header id placed in front under the iyi layout" "$TYPER_FILE" \
  "    id_in_front = !type.struct? && !@iyi_layout" \
  "    id_in_front = !type.struct? && @iyi_layout" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "class value lowered to its struct, not a pointer" "$TYPER_FILE" \
  "      return final_type if type.struct?" \
  "      return final_type" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "type ids step by two" "$TYPE_ID_FILE" \
  "    @next_id = @next_id + 1" \
  "    @next_id = @next_id + 2" \
  -- check_ids_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "unnumbered types do not get a lazy id" "$TYPE_ID_FILE" \
  '    id = next_id
    put(type, id, id)
    id
  end

  # The hosted `id_to_metaclass' \
  '    raise "BUG: no lazy id"
  end

  # The hosted `id_to_metaclass' \
  -- check_ids_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a range's min is its last subtype, not the first" "$TYPE_ID_FILE" \
  "      if first && sub_id != 0" \
  "      if sub_id != 0" \
  -- check_ids_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "a Tuple instance is not recorded in Tuple's instantiated types" "$REPO/src/compiler/types/instances.iyi" \
  '    @program.types["Tuple"].as(GenericClassType).instantiated_types << inst' \
  '    @program.types["Tuple"].as(GenericClassType).instantiated_types.size' \
  -- check_ids_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "Nil created after Bool, not before it" "$REPO/src/compiler/semantic/top_level.iyi" \
  '    nil_t = NilType.new(self, self, "Nil", val)
    @types["Nil"] = nil_t
    bool_t = NonGenericClassType.new(self, self, "Bool", val)
    bool_t.struct = true
    @types["Bool"] = bool_t' \
  '    bool_t = NonGenericClassType.new(self, self, "Bool", val)
    bool_t.struct = true
    @types["Bool"] = bool_t
    nil_t = NilType.new(self, self, "Nil", val)
    @types["Nil"] = nil_t' \
  -- check_ids_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "ARGV_UNSAFE's Pointer(Pointer(UInt8)) not made, so Pointer(UInt8) alone" "$REPO/src/compiler/types/type_system.iyi" \
  "    @instances.pointer_of(@instances.pointer_of(uint8))" \
  "    @instances.pointer_of(uint8)" \
  -- check_ids_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "leaves take no id of their own" "$TYPE_ID_FILE" \
  "    if subtypes.size == 0" \
  "    if subtypes.size == 99" \
  -- check_ids_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation_all "a metaclass id reuses its class's id" "$TYPE_ID_FILE" \
  "      @id_to_metaclass[hosted_type_id(type)] = metaclass_type_id(meta)" \
  "      @id_to_metaclass[hosted_type_id(type)] = hosted_type_id(type)" \
  -- check_ids_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a generic instance's metaclass is not numbered" "$TYPE_ID_FILE" \
  "    if type.is_a?(GenericClassInstanceType)" \
  "    if type.is_a?(GenericClassInstanceType) && false" \
  -- check_ids_diverge || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a class reference holds no pointer" "$LAYOUTS_FILE" \
  "    return true unless type.struct?" \
  "    return false unless type.struct?" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "scan cap ignores the last field" "$LAYOUTS_FILE" \
  "    @typer.offset_of(struct_type, last) + @typer.size_of(element)" \
  "    @typer.offset_of(struct_type, last) + 0_i64" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "pointer map reads field offsets by the wrong index" "$LAYOUTS_FILE" \
  "      index = index + 1" \
  "      index = index + 2" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a by-value aggregate passed to C as itself, not behind a pointer" "$TYPER_FILE" \
  "    if passed_by_value?(type)" \
  "    if false" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a tuple returned by an intrinsic as void" "$TYPER_FILE" \
  "      return @table.struct_of(fields)" \
  "      return @table.void" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a proc argument to C not a pointer to its function" "$TYPER_FILE" \
  "    if type.is_a?(ProcInstanceType) || type.is_a?(NilableProcType)" \
  "    if type.is_a?(NilableProcType)" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# The own-source probes: files whose floors a mutation of the namespace or struct rules must
# lower below. A probe fails the check when the mutated port's identical count drops below its
# floor, when the mutated driver does not build, or when the port fails the file.
OWN_PROBES="src/compiler/foundation/location.iyi src/compiler/platform/target.iyi src/compiler/syntax/ast.iyi src/compiler/lower/type_id.iyi"
check_own_diverges() {
  "$IYI" build -o "$WORK/mut_port" "$REPO/bench/selfhost_lower_types_exercise.iyi" > /dev/null 2>&1 || return 1
  for probe in $OWN_PROBES; do
    id=$(printf '%s' "$probe" | tr '/' '_')
    timeout 900 "$WORK/oracle" --own "$REPO/$probe" "$TRIPLE" > "$WORK/mut_$id.o" 2> /dev/null || return 1
    timeout 900 "$WORK/mut_port" --own "$REPO/$probe" "$TRIPLE" > "$WORK/mut_$id.p" 2> /dev/null || return 1
    got=$(python3 "$REPO/bench/lib/lower_types_compare.py" "$WORK/mut_$id.o" "$WORK/mut_$id.p" | awk 'NR==1 { print $2 }')
    want=$(awk -v f="$probe" '$1 == f { print $2 }' "$own_floor")
    [ "${want:-0}" -gt 0 ] || return 0
    [ "${got:-0}" -ge "$want" ] || return 1
  done
  return 0
}

# The own-source fixtures (bench/fixtures/ownty_*.iyi): each file's own-source dump, the hosted oracle
# against the port, with the prelude loaded. A declared generic argument keeps its arguments (NEEDS.md row 22).
own_fixture_bad=0
own_fixture_count=0
for fixture in "$REPO"/bench/fixtures/ownty_*.iyi; do
  own_fixture_count=$((own_fixture_count + 1))
  name="$(basename "$fixture" .iyi)"
  if ! timeout 900 "$WORK/oracle" --own "$fixture" "$TRIPLE" > "$WORK/$name.own_o" 2> "$WORK/$name.own_oe"; then
    echo "  $name: oracle failed: $(head -n 1 "$WORK/$name.own_oe")"
    own_fixture_bad=$((own_fixture_bad + 1))
    continue
  fi
  if ! timeout 900 "$WORK/port" --own "$fixture" "$TRIPLE" > "$WORK/$name.own_p" 2> "$WORK/$name.own_pe"; then
    echo "  $name: port failed: $(head -n 1 "$WORK/$name.own_pe")"
    own_fixture_bad=$((own_fixture_bad + 1))
    continue
  fi
  if cmp -s "$WORK/$name.own_o" "$WORK/$name.own_p"; then
    echo "  $name: own-source dump identical to the hosted oracle"
  else
    echo "  $name: DIVERGES from the hosted oracle:"
    diff "$WORK/$name.own_o" "$WORK/$name.own_p" | head -n 20
    own_fixture_bad=$((own_fixture_bad + 1))
  fi
done
echo "  Own-source fixtures: $((own_fixture_count - own_fixture_bad))/$own_fixture_count identical"
if [ "$own_fixture_count" -eq 0 ] || [ "$own_fixture_bad" -ne 0 ]; then
  status=1
fi


# The baseline: the unmutated port meets every probe floor. Without it a port that fails a probe would
# count as a catch.
if ! check_own_diverges; then
  echo "  own-source probes fail on the unmutated port (the own mutation proofs would be vacuous)"
  status=1
fi

prove_mutation "a namespace module's branch bypassed (namespaces fall through to the raise)" "$TYPER_FILE" \
  "    if (type.is_a?(NonGenericModuleType) || type.is_a?(TraitType)) && !type.is_a?(LibType)" \
  "    if false" \
  -- check_own_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a struct's by-value answer removed (passed_by_value? of a class)" "$TYPER_FILE" \
  "  if type.is_a?(ClassType)" \
  "  if type.is_a?(ClassType) && false" \
  -- check_own_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a reference union lowered as an integer, not a pointer" "$TYPER_FILE" \
  "    if type.is_a?(ReferenceUnionType) || type.is_a?(NilableReferenceUnionType)
      return @table.ptr" \
  "    if type.is_a?(ReferenceUnionType) || type.is_a?(NilableReferenceUnionType)
      return @table.int64" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "the file's own module answers i1, not i32" "$TYPER_FILE" \
  "        return @table.int32 if type.iyi_unit" \
  "        return @table.int1 if type.iyi_unit" \
  -- check_own_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a reference-only module union lowered as a mixed union, not a pointer" "$TYPER_FILE" \
  "  return @table.ptr if all_references" \
  "  return @table.ptr if false" \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a module's own metaclass counted as an implementor" "$TYPER_FILE" \
  "    found << t unless t.is_a?(MetaclassType) || t.is_a?(VirtualMetaclassType)" \
  "    found << t" \
  -- check_own_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "headed census drops virtual_type_made? classes" "$HEADED_FILE" \
  '    next unless headed_candidate?(type) && TypeQueries.virtual_type_made?(type)' \
  '    next unless headed_candidate?(type) && false' \
  -- check_headed_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "headed census drops reference unions from program.unions" "$HEADED_FILE" \
  '    next unless union.is_a?(ReferenceUnionType) || union.is_a?(NilableReferenceUnionType)' \
  '    next unless false' \
  -- check_headed_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "headed census drops subclasses of virtual-type classes" "$HEADED_FILE" \
  '    TypeQueries.all_subclasses(type).each do |sub|' \
  '    ([] of Type).each do |sub|' \
  -- check_headed_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "headed census drops subclasses of union members" "$HEADED_FILE" \
  '      TypeQueries.all_subclasses(resolved).each do |sub|' \
  '      ([] of Type).each do |sub|' \
  -- check_headed_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "the sixteen-bit slot is zero bits wide" "$HEADED_FILE" \
  '  65535' \
  '  0' \
  -- check_headed_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation_all "String is not headed by rule" "$HEADED_FILE" \
  '  return true if type.full_name == "String"' \
  '  return false if type.full_name == "String"' \
  -- check_headed_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation_all "an unheaded candidate answers headed" "$HEADED_FILE" \
  '  return false unless headed_candidate?(type)' \
  '  return true unless headed_candidate?(type)' \
  -- check_headed_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))


prove_mutation "traits bypassed in create_llvm_type (fall through to BUG raise)" "$TYPER_FILE" \
  '    if (type.is_a?(NonGenericModuleType) || type.is_a?(TraitType)) && !type.is_a?(LibType)' \
  '    if type.is_a?(NonGenericModuleType) && !type.is_a?(LibType)' \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "untyped union in passed_by_value? answered false instead of checking members" "$TYPER_FILE" \
  '  if type.is_a?(UnionType)
    return !reference_union?(type.as(UnionType))
  end' \
  '  if type.is_a?(UnionType)
    return false
  end' \
  -- check_lowering_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "generic type arguments retain virtual marker outside codegen" "$REPO/src/compiler/types/rendering.iyi" \
  '    if codegen
      return type
    end
    type.devirtualize' \
  '    if codegen
      return type
    end
    type' \
  -- check_own_diverges || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "PASS: the iyi lowering of analysed types agrees with the hosted typer on every fixture, and every mutation is caught"
else
  echo "FAIL: the iyi lowering of analysed types diverges from the hosted typer, or a mutation was not caught"
fi
exit "$status"
