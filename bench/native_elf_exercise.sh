#!/usr/bin/env bash
# The native ELF object and linker gate on each supported host.
# It round-trips the object corpus, checks relocation listings when
# llvm-readelf is available, builds the start code, and structurally checks
# and byte-compares each executable. Source mutations must build before their
# checks can catch them. A matching Linux kernel runs the corpus against
# hosted-linked references with bounded execution, and one program of the
# corpus (fixtures/native_elf/environ_probe) reads the environment the start
# code hands it. Where nothing runs, check_start.py reads the start code's
# translation: `environ` must be the environment block of the initial stack.

set -uo pipefail

if [ "$#" -ne 0 ]; then
  echo "usage: bash bench/native_elf_exercise.sh" >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
cd "$root" || exit 1
. "$root/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if [ -z "$PY" ]; then
  host_limited "ELF structural checks, mutations and provenance require Python"
  exit 1
fi
export IYI_PATH="$(native_path "$root/src")"

HOSTED_COMPILER="$root/bin/iyi"
obj_src=src/compiler/tools/obj_elf.iyi
link_src=src/compiler/tools/link_elf.iyi
elf_src=src/compiler/native/obj/elf.iyi
exe_src=src/compiler/native/link/elf_exe.iyi
isel_src=src/compiler/native/aarch64/isel.iyi
check=bench/fixtures/native_elf/check_exe.py
start_check=bench/fixtures/native_elf/check_start.py
start_a64_ir=src/compiler/native/rt/start_linux_aarch64.ir
start_x86_ir=src/compiler/native/rt/start_linux_x86_64.ir
arches="x86_64-linux-gnu aarch64-linux-gnu"

work="$(mktemp -d "${TMPDIR:-/tmp}/native_elf.XXXXXX")" || exit 1
restore=""
backup=""
cleanup() {
  if [ -n "$restore" ] && [ -n "$backup" ]; then
    if ! cp "$backup" "$restore" || ! cmp -s "$backup" "$restore"; then
      echo "cannot restore $restore; backup retained at $backup" >&2
      return 1
    fi
  fi
  rm -rf "$work"
}
trap 'cleanup || exit 2' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

failures=0
fail() {
  echo "   $*"
  failures=$((failures + 1))
}

# Record the compiler actually selected by bin/iyi, not just the launcher.
head="$(git rev-parse HEAD)" || exit 1
if [ -x "$root/.build/iyi.exe" ]; then
  iyi_binary="$root/.build/iyi.exe"
elif [ -x "$root/.build/iyi" ]; then
  iyi_binary="$root/.build/iyi"
else
  echo "the hosted compiler is not built in .build" >&2
  exit 1
fi
printf 'revision: %s\nhosted compiler launcher: %s\nhosted compiler binary: %s\n' \
  "$head" "$(native_path "$HOSTED_COMPILER")" "$(native_path "$iyi_binary")"
if ! "$PY" - "$(native_path "$iyi_binary")" <<'PY'
import hashlib
import pathlib
import sys
print("hosted compiler sha256:", hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
then
  echo "cannot identify the hosted compiler" >&2
  exit 1
fi
printf 'Python: %s\n' "$(command -v "$PY")"
"$PY" --version || exit 1

# Prefer the tools beside the LLVM used by the hosted bridge. On Windows,
# LLVM_CONFIG may be absent, so use the same LLVM_PATH and Program Files
# locations as the posted native codegen gates.
shell_path() {
  case "$1" in
    [A-Za-z]:[\\/]*) if [ "$HOST_OS" = windows ]; then cygpath -u "$1"; else printf '%s\n' "$1"; fi ;;
    *) printf '%s\n' "$1" ;;
  esac
}
llvm_bindir=""
llvm_config="${LLVM_CONFIG:-}"
if [ -z "$llvm_config" ]; then
  llvm_config="$(command -v llvm-config 2>/dev/null || command -v llvm-config-20 2>/dev/null || true)"
fi
if [ -n "$llvm_config" ]; then
  llvm_config="$(shell_path "$llvm_config")"
  llvm_bindir="$("$llvm_config" --bindir 2>/dev/null | tr -d '\r' || true)"
  [ -z "$llvm_bindir" ] || llvm_bindir="$(shell_path "$llvm_bindir")"
  printf 'LLVM config: %s; bindir: %s\n' "$llvm_config" "${llvm_bindir:-unavailable}"
fi
llvm_mc_dir=""
if [ -n "${LLVM_MC:-}" ]; then
  llvm_mc_dir="$(dirname "$(shell_path "$LLVM_MC")")"
fi
resolve_llvm_tool() {
  local requested="$1" name="$2" candidate found="" dir
  if [ -n "$requested" ]; then
    candidate="$(shell_path "$requested")"
    found="$(command -v "$candidate" 2>/dev/null || true)"
  else
    for dir in "$llvm_bindir" "$llvm_mc_dir" "${LLVM_PATH:-}/bin" "${ProgramFiles:+$ProgramFiles/LLVM/bin}" "/c/Program Files/LLVM/bin"; do
      [ -n "$dir" ] || continue
      dir="$(shell_path "$dir")"
      candidate="$dir/$name$EXE"
      if [ -x "$candidate" ]; then found="$candidate"; break; fi
    done
    [ -n "$found" ] || found="$(command -v "$name" 2>/dev/null || true)"
  fi
  [ -n "$found" ] || return 1
  if [ "$HOST_OS" = windows ] && [ -f "$found.exe" ]; then found="$found.exe"; fi
  printf '%s\n' "$found"
}
llc_tool="$(resolve_llvm_tool "${LLVM_LLC:-}" llc || true)"
readelf_tool="$(resolve_llvm_tool "${LLVM_READELF:-}" llvm-readelf || true)"
if [ -n "$llc_tool" ] && "$llc_tool" --version >"$work/llc.version" 2>&1; then
  printf 'llc: %s\n' "$(native_path "$llc_tool")"
  head -n 1 "$work/llc.version"
else
  llc_tool=""
  host_limited "llc is unavailable; bridged start objects and x86_64 ELF corpus linking require it"
fi
if [ -n "$readelf_tool" ] && "$readelf_tool" --version >"$work/readelf.version" 2>&1; then
  printf 'llvm-readelf: %s\n' "$(native_path "$readelf_tool")"
  head -n 1 "$work/readelf.version"
else
  readelf_tool=""
  host_limited "llvm-readelf is unavailable; ELF listing comparisons and the REX relocation mutation require it"
fi

# The object file's machine, for the name a corpus object is keyed by.
arch_short() {
  case "$1" in
    x86_64-linux-gnu) echo x86_64 ;;
    aarch64-linux-gnu) echo aarch64 ;;
  esac
}

# Build both drivers with paths accepted by the native hosted compiler.
build_tools() {
  mkdir -p "$work/bin"
  "$HOSTED_COMPILER" build -o "$(native_path "$work/bin/obj_elf$EXE")" "$(native_path "$root/$obj_src")" >"$work/build-obj.log" 2>&1 || return 1
  "$HOSTED_COMPILER" build -o "$(native_path "$work/bin/link_elf$EXE")" "$(native_path "$root/$link_src")" >"$work/build-link.log" 2>&1 || return 1
}

# The original comparison excludes only the two rows affected by string-table
# layout; a failing llvm-readelf command is never treated as equal output.
filtered_listing() {
  "$readelf_tool" -S -s -r -W "$(native_path "$1")" 2>&1 |
    awk '!/section headers, starting at offset/ && !/ \.strtab /'
}

# The relocation loop must reach its image base and bounds without an unrebased GOT.
bootstrap_direct() {
  "$readelf_tool" -r -W "$(native_path "$1")" |
    awk '($5 == "__ehdr_start" || $5 == "__iyi_rela_start" || $5 == "__iyi_rela_end") {
           if (!seen[$5]++) count++
           if ($3 ~ /GOT/) { print $3, $5; bad = 1 }
         }
         END {
           if (count != 3) print "bootstrap symbol relocations: found", count + 0, "of 3"
           exit (bad || count != 3)
         }'
}

# A check may count a mutation as caught only after the mutated drivers build.
# The source is restored even if the process is interrupted.
prove_mutation() {
  local label="$1" file="$2" old="$3" new="$4" patched
  shift 4
  if [ "${MUTATION_SKIP:-0}" = 1 ]; then
    fail "NOT RUN (MUTATION_SKIP=1): $label"
    return 1
  fi
  backup="$work/mutation-$RANDOM.bak"
  if ! cp "$file" "$backup"; then
    fail "cannot back up $file for '$label'"
    return 1
  fi
  restore="$file"
  "$PY" - "$(native_path "$root/$file")" "$old" "$new" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
old, new = sys.argv[2].encode(), sys.argv[3].encode()
data = path.read_bytes()
if old not in data or old == new:
    sys.exit(3)
path.write_bytes(data.replace(old, new, 1))
PY
  patched=$?
  if [ "$patched" -eq 3 ]; then
    fail "PATCH CHANGED NOTHING: '$label'"
  elif [ "$patched" -ne 0 ]; then
    fail "could not apply '$label'"
  elif ! build_tools; then
    fail "INVALID MUTANT: '$label' did not build"
    tail -n 20 "$work/build-obj.log" "$work/build-link.log" 2>/dev/null
  elif "$@" >"$work/mutation-check.log" 2>&1; then
    fail "NOT caught: $label"
  elif grep -q '^CHECK NOT RUN' "$work/mutation-check.log"; then
    fail "INVALID MUTANT: '$label' could not be judged"
    tail -n 5 "$work/mutation-check.log"
  else
    echo "   caught: $label"
    awk '/^decisive: / { print "     " $0; exit }' "$work/mutation-check.log"
  fi
  if ! cp "$backup" "$file" || ! cmp -s "$backup" "$file"; then
    fail "cannot restore $file; backup retained at $backup"
    exit 1
  fi
  restore=""
  rm -f "$backup"
  backup=""
}

echo "== 1. build the drivers from the source"
if ! build_tools; then
  echo "   a driver does not build:"
  tail -n 20 "$work/build-obj.log" "$work/build-link.log"
  echo "== SOME NATIVE_ELF CHECKS FAILED"
  exit 1
fi
cp "$work/bin/obj_elf$EXE" "$work/bin/obj_elf.good$EXE" || exit 1
cp "$work/bin/link_elf$EXE" "$work/bin/link_elf.good$EXE" || exit 1
echo "   obj_elf and link_elf built"

echo "== 2. object round trip, both Linux architectures"
objects_total=0
excluded_total=0
for triple in $arches; do
  short="$(arch_short "$triple")"
  mkdir -p "$work/obj/$short"
  : >"$work/obj/$short/coverage.txt"
  ok=0
  for src in samples/iyi/*.iyi bench/fixtures/native_obj/*.iyi bench/fixtures/native_elf/*.iyi; do
    [ -f "$src" ] || continue
    name="$(basename "$src" .iyi)"
    obj="$work/obj/$short/$name.o"
    if ! "$HOSTED_COMPILER" build --cross-compile --target "$triple" -o "$(native_path "$obj")" "$(native_path "$root/$src")" \
        >"$work/obj/$short/$name.build" 2>"$work/obj/$short/$name.err"; then
      fail "the hosted compiler does not compile $src for $triple"
      continue
    fi
    objects_total=$((objects_total + 1))
    rt="$work/obj/$short/$name.rt.o"
    if ! "$work/bin/obj_elf$EXE" "$(native_path "$obj")" "$(native_path "$rt")" >"$work/obj/$short/$name.rt.log" 2>&1; then
      if grep -q "type 17" "$work/obj/$short/$name.rt.log"; then
        echo "   $short $name: excluded, COMDAT group sections, which the object reader refuses by name"
        excluded_total=$((excluded_total + 1))
        continue
      fi
      fail "$short $name does not round trip:"
      sed 's/^/     /' "$work/obj/$short/$name.rt.log" | tail -n 3
      continue
    fi
    if ! grep -q "^ROUNDTRIP EQUAL" "$work/obj/$short/$name.rt.log"; then
      fail "$short $name: the round trip did not report equality"
      continue
    fi
    if [ -n "$readelf_tool" ]; then
      if ! filtered_listing "$obj" >"$work/obj/$short/$name.original.list" ||
         ! filtered_listing "$rt" >"$work/obj/$short/$name.roundtrip.list"; then
        fail "$short $name: llvm-readelf could not inspect an object"
        cat "$work/obj/$short/$name.original.list" "$work/obj/$short/$name.roundtrip.list" 2>/dev/null
        continue
      fi
      if ! diff "$work/obj/$short/$name.original.list" "$work/obj/$short/$name.roundtrip.list" >"$work/obj/$short/$name.diff"; then
        fail "$short $name: the rewritten object's listing differs:"
        sed 's/^/     /' "$work/obj/$short/$name.diff" | tail -n 6
        continue
      fi
    fi
    grep '^reloc ' "$work/obj/$short/$name.rt.log" >>"$work/obj/$short/coverage.txt"
    ok=$((ok + 1))
  done
  if [ -n "$readelf_tool" ]; then
    echo "   $short: $ok objects round-trip equal, listing equal but for the string table"
  else
    echo "   $short: $ok objects round-trip equal; llvm-readelf listings not checked"
  fi
  echo "   $short: relocation coverage (zero counts included)"
  awk '{ count[$2] += $3 } END { for (k in count) print k, count[k] }' "$work/obj/$short/coverage.txt" | sort |
    while read -r kind total; do
      echo "     $kind $total"
    done
done
echo "   $objects_total objects read; $excluded_total excluded (COMDAT groups)"

echo "== 3. mutation proofs"
# Each driver goes back as a new file. A copy over the file a mutant has just
# run from can fail on Linux with "Text file busy" while the exited process's
# image is still being released.
restore_tools() {
  rm -f "$work/bin/obj_elf$EXE" "$work/bin/link_elf$EXE" &&
    cp "$work/bin/obj_elf.good$EXE" "$work/bin/obj_elf$EXE" &&
    cp "$work/bin/link_elf.good$EXE" "$work/bin/link_elf$EXE"
}
check_round_trip_hello() {
  "$work/bin/obj_elf$EXE" "$(native_path "$work/obj/aarch64/hello.o")" "$(native_path "$work/mut.o")" >"$work/mut-rt.log" 2>&1 &&
    grep -q "^ROUNDTRIP EQUAL" "$work/mut-rt.log"
}
if check_round_trip_hello; then
  prove_mutation "drop the addend the writer emits for every relocation" "$elf_src" \
    "poke(at + 16_i64, reloc.addend, 8)" "poke(at + 16_i64, 0_i64, 8)" \
    check_round_trip_hello
else
  fail "baseline AArch64 hello round trip failed; addend mutation was not run"
fi
restore_tools || exit 1
check_rex_hello() {
  "$work/bin/obj_elf$EXE" "$(native_path "$work/obj/x86_64/hello.o")" "$(native_path "$work/mut.o")" >"$work/mut-rt.log" 2>&1 &&
    grep -q "^ROUNDTRIP EQUAL" "$work/mut-rt.log" &&
    filtered_listing "$work/obj/x86_64/hello.o" >"$work/mut-original.list" &&
    filtered_listing "$work/mut.o" >"$work/mut-roundtrip.list" &&
    diff "$work/mut-original.list" "$work/mut-roundtrip.list" >/dev/null
}
if [ -n "$readelf_tool" ]; then
  if check_rex_hello; then
    prove_mutation "read REX_GOTPCRELX as the plain GOTPCRELX kind" "$elf_src" \
      "return 8_i64 if type == 42_i64" "return 7_i64 if type == 42_i64" \
      check_rex_hello
  else
    fail "baseline x86_64 hello listing failed; REX relocation mutation was not run"
  fi
else
  echo "   REX relocation mutation not run: llvm-readelf unavailable"
fi
restore_tools || exit 1
check_linked_structure() {
  "$work/bin/link_elf$EXE" start "$(native_path "$root/$start_a64_ir")" "$(native_path "$work/mut_start.o")" >"$work/mut-start.log" 2>&1 &&
    "$work/bin/link_elf$EXE" link "$(native_path "$work/mut.exe")" _start "$(native_path "$work/mut_start.o")" "$(native_path "$work/obj/aarch64/hello.o")" >"$work/mut-link.log" 2>&1 &&
    "$PY" "$(native_path "$root/$check")" "$(native_path "$work/mut.exe")" --expect-tls >"$work/mut-check.log" 2>&1
}
if check_linked_structure; then
  prove_mutation "skip the relative relocation table entries" "$exe_src" \
    "exe_put(image, @rela_addr + k.to_i64 * 8_i64, rel_sites[k], 8)" "exe_put(image, @rela_addr + k.to_i64 * 8_i64, 0_i64, 8)" \
    check_linked_structure
else
  fail "baseline AArch64 hello link or structural check failed; relocation mutation was not run"
fi
restore_tools || exit 1
check_start_direct() {
  "$work/bin/link_elf$EXE" start "$(native_path "$root/$start_a64_ir")" "$(native_path "$work/mut_start.o")" >"$work/mut-start.log" 2>&1 &&
    bootstrap_direct "$work/mut_start.o"
}
if [ -n "$readelf_tool" ]; then
  if check_start_direct; then
    prove_mutation "reach a hidden declaration through the GOT" "$isel_src" \
      "visibility == Visibility::Default && !dso_local" "true" check_start_direct
  else
    fail "baseline AArch64 bootstrap addressing failed; visibility mutation was not run"
  fi
else
  echo "   start-code addressing mutation not run: llvm-readelf unavailable"
fi
restore_tools || exit 1
echo "   TLS variant offsets and the start-code relocation loop need runtime coverage"

echo "== 4. start code"
for ir in "$start_a64_ir" "$start_x86_ir"; do
  if "$work/bin/link_elf$EXE" verify "$(native_path "$root/$ir")" >"$work/verify.log" 2>&1; then
    cat "$work/verify.log"
  else
    fail "$ir does not verify:"
    tail -n 5 "$work/verify.log"
  fi
done
if "$work/bin/link_elf$EXE" start "$(native_path "$root/$start_a64_ir")" "$(native_path "$work/start_a64.o")" >"$work/start.log" 2>&1; then
  cat "$work/start.log"
else
  fail "the aarch64 start code does not compile:"
  tail -n 5 "$work/start.log"
fi
if [ -n "$readelf_tool" ]; then
  if bootstrap_direct "$work/start_a64.o" >"$work/start-direct.log" 2>&1; then
    echo "   aarch64 native start code: bootstrap symbols use direct addressing"
  else
    fail "aarch64 native start code has unsafe bootstrap addressing:"
    cat "$work/start-direct.log"
  fi
fi
iyi_ir="$work/bin/iyi-ir$EXE"
# iyi-ir imports the LLVM bridge, which is told its LLVM by build arguments (bench/lib/host.sh).
llvm_bridge_args=()
if llvm_bridge_text=$(llvm_bridge_build_args); then
  while IFS= read -r llvm_arg; do llvm_bridge_args+=("$llvm_arg"); done <<< "$llvm_bridge_text"
else
  fail "no LLVM build arguments for this host, see the sentence above"
fi
if ! "$HOSTED_COMPILER" build ${llvm_bridge_args[@]+"${llvm_bridge_args[@]}"} -o "$(native_path "$iyi_ir")" "$(native_path "$root/src/compiler/tools/ir.iyi")" >"$work/iyi-ir.build" 2>&1; then
  fail "iyi-ir does not build, the LLVM bridge that translates the start code; its log ends:"
  tail -n 20 "$work/iyi-ir.build" | sed 's/^/     /'
fi
# The LLVM bridge translates the start IR; llc compiles its result to ELF.
bridge_start() {
  "$iyi_ir" translate "$(native_path "$root/$1")" >"$2.ll" 2>"$2.translate" || return 1
  "$llc_tool" -filetype=obj -relocation-model=pic -o "$(native_path "$2")" "$(native_path "$2.ll")" >"$2.llc" 2>&1
}
bridge_check() {
  local arch="$1" ir="$2" object="$3" exe="$work/hello_bridged_$1"
  if ! bridge_start "$ir" "$object"; then
    fail "$arch start code: LLVM bridge or llc failed: $(head -n 3 "$object.translate" "$object.llc" 2>/dev/null | tr '\n' ' ')"
    return 1
  fi
  if [ -n "$readelf_tool" ] && ! bootstrap_direct "$object" >"$object.direct" 2>&1; then
    fail "$arch bridged start code has unsafe bootstrap addressing:"
    cat "$object.direct"
    return 1
  fi
  if "$work/bin/link_elf$EXE" link "$(native_path "$exe")" _start "$(native_path "$object")" \
      "$(native_path "$work/obj/$arch/hello.o")" >"$exe.link" 2>&1 &&
      "$PY" "$(native_path "$root/$check")" "$(native_path "$exe")" --expect-tls >"$exe.check" 2>&1; then
    echo "   $arch start code: iyi-ir and llc produced an object which links and passes structural inspection"
  else
    fail "$arch bridged start code does not link and pass inspection: $(head -n 1 "$exe.link" "$exe.check" 2>/dev/null | tr '\n' ' ')"
    return 1
  fi
}
if [ -x "$iyi_ir" ] && [ -n "$llc_tool" ]; then
  bridge_check x86_64 "$start_x86_ir" "$work/start_x86_64_bridge.o" || rm -f "$work/start_x86_64_bridge.o"
  bridge_check aarch64 "$start_a64_ir" "$work/start_aarch64_bridge.o" || rm -f "$work/start_aarch64_bridge.o"
fi
# check_start_environ IR: the LLVM bridge's translation of a start code stores the environment block of the initial
# stack in `environ` (check_start.py). Status 1 is a difference. A translation that fails, or a check that cannot
# judge, prints CHECK NOT RUN and returns 2, which a mutation proof does not take for a catch.
check_start_environ() {
  if ! "$iyi_ir" translate "$(native_path "$root/$1")" >"$work/start-environ.ll" 2>"$work/start-environ.err"; then
    echo "CHECK NOT RUN: iyi-ir could not translate $1: $(head -n 1 "$work/start-environ.err")"
    return 2
  fi
  "$PY" "$(native_path "$root/$start_check")" "$(native_path "$work/start-environ.ll")"
  environ_status=$?
  if [ "$environ_status" -gt 1 ]; then
    echo "CHECK NOT RUN: check_start.py could not judge $1 (status $environ_status)"
  fi
  return "$environ_status"
}
check_start_environ_x86() {
  check_start_environ "$start_x86_ir"
}
if [ -x "$iyi_ir" ]; then
  for ir in "$start_a64_ir" "$start_x86_ir"; do
    if check_start_environ "$ir" >"$work/start-environ.out" 2>&1; then
      echo "   $(basename "$ir" .ir): environ is the environment block of the initial stack"
    else
      fail "$ir does not install the environment block of the initial stack in environ:"
      sed 's/^/     /' "$work/start-environ.out" | head -n 3
    fi
  done
  prove_mutation "point x86_64 environ at the terminator of argv" "$start_x86_ir" \
    "%n1 = add i64 %argc, 1" "%n1 = add i64 %argc, 0" \
    check_start_environ_x86
else
  echo "   start code environ check not run: iyi-ir did not build"
fi

echo "== 5. link and inspect the executable corpus"
exes=0
mkdir -p "$work/manifest"
for triple in $arches; do
  short="$(arch_short "$triple")"
  : >"$work/manifest/$short"
  start="$work/start_a64.o"
  if [ "$short" = x86_64 ]; then
    start="$work/start_x86_64_bridge.o"
  fi
  if [ ! -f "$start" ]; then
    if [ "$short" = x86_64 ] && [ -z "$llc_tool" ]; then
      echo "   $short: corpus linking not run without llc"
    else
      fail "$short start object is unavailable; corpus linking was not run"
    fi
    continue
  fi
  linked=0
  mkdir -p "$work/exe/$short"
  for obj in "$work/obj/$short"/*.o; do
    [ -f "$obj" ] || continue
    case "$obj" in *.rt.o) continue ;; esac
    name="$(basename "$obj" .o)"
    exe="$work/exe/$short/$name"
    if ! "$work/bin/link_elf$EXE" link "$(native_path "$exe")" _start \
        "$(native_path "$start")" "$(native_path "$obj")" >"$exe.link" 2>&1; then
      fail "$short $name does not link: $(head -n 1 "$exe.link")"
      continue
    fi
    if ! "$PY" "$(native_path "$root/$check")" "$(native_path "$exe")" --expect-tls >"$exe.check" 2>&1; then
      fail "$short $name fails the structural check:"
      sed 's/^/     /' "$exe.check" | tail -n 6
      continue
    fi
    if ! "$work/bin/link_elf$EXE" link "$(native_path "$exe.again")" _start \
        "$(native_path "$start")" "$(native_path "$obj")" >"$exe.again.log" 2>&1 ||
       ! cmp -s "$exe" "$exe.again"; then
      fail "$short $name does not link to identical bytes twice"
      continue
    fi
    exes=$((exes + 1))
    linked=$((linked + 1))
    printf '%s\n' "$name" >>"$work/manifest/$short"
  done
  echo "   $short: $linked executables linked, inspected, and compared byte for byte"
done
[ "$exes" -gt 0 ] || fail "no ELF corpus executable passed structural and byte checks"

# The hosted compiler prints its cross-link command. Keep its flags, apart
# from host library search directories, exactly as the original runner did.
oracle_flags() {
  awk '/^cc / { found = 1; out = ""; for (i = 5; i <= NF; i++) if ($i !~ /^-L/) out = out " " $i; sub(/^ /, "", out); print (out == "" ? "-" : out); exit }
       END { if (!found) exit 1 }' "$1"
}

# Each run gets a private working directory and the original 30-second bound.
run_one() {
  local image="$1" directory="$2" prefix="$3" status
  mkdir -p "$directory"
  (cd "$directory" && timeout -k 5s 30s "$image" </dev/null >"$prefix.out" 2>"$prefix.err")
  status=$?
  printf '%s\n' "$status" >"$prefix.status"
}

echo "== 6. native Linux runtime comparisons"
# environ_probe prints this variable, so an executable whose environ does not reach the program prints what its twin does not.
export IYI_ELF_ENV_PROBE="the-start-code-hands-over-the-environment"
for triple in $arches; do
  short="$(arch_short "$triple")"
  case "$HOST_ID:$short" in
    linux-x86_64:x86_64 | linux-arm64:aarch64) ;;
    *:aarch64)
      host_limited "AArch64 ELF corpus execution requires Linux arm64; the existing CI consumer accepts only its fixed hello image"
      continue
      ;;
    *)
      host_limited "x86_64 ELF corpus execution requires Linux x86_64"
      continue
      ;;
  esac
  if [ "$short" = x86_64 ] && [ -z "$llc_tool" ]; then
    echo "   x86_64 runtime comparison not run without a bridged start object"
    continue
  fi
  if ! command -v cc >/dev/null 2>&1; then
    host_limited "$short runtime comparison requires cc to link the hosted reference objects"
    continue
  fi
  if ! command -v timeout >/dev/null 2>&1; then
    host_limited "$short runtime comparison requires timeout to bound each execution"
    continue
  fi
  printf 'reference linker: %s\n' "$(command -v cc)"
  cc --version >"$work/cc.version" 2>&1 || { fail "cc --version failed"; continue; }
  head -n 1 "$work/cc.version"
  ran=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    obj="$work/obj/$short/$name.o"
    image="$work/exe/$short/$name"
    run="$work/run/$short/$name"
    mkdir -p "$run"
    oracle="$run/oracle-image"
    if ! flags="$(oracle_flags "$work/obj/$short/$name.build")"; then
      fail "$short $name: hosted cross-link command is missing"
      continue
    fi
    [ "$flags" = "-" ] && flags=""
    # The hosted command's flags are a word list, as in the original runner.
    # shellcheck disable=SC2086
    if ! cc "$obj" -o "$oracle" $flags >"$run/link.log" 2>&1; then
      fail "$short $name: hosted reference does not link: $(head -n 1 "$run/link.log")"
      continue
    fi
    if ! chmod +x "$image"; then
      fail "$short $name: cannot make the ELF executable"
      continue
    fi
    run_one "$oracle" "$run/oracle-work" "$run/oracle"
    run_one "$image" "$run/native-work" "$run/native"
    ran=$((ran + 1))
    oracle_status="$(cat "$run/oracle.status")"
    native_status="$(cat "$run/native.status")"
    case "$oracle_status:$native_status" in
      124:* | *:124 | 137:* | *:137)
        fail "$short $name: a reference or native run exceeded its bound"
        continue
        ;;
    esac
    if [ "$oracle_status" != "$native_status" ]; then
      fail "$short $name: native exit $native_status, hosted exit $oracle_status"
      continue
    fi
    if ! cmp -s "$run/oracle.err" "$run/native.err"; then
      fail "$short $name: stderr differs from the hosted reference"
      continue
    fi
    if [ "$name" = addr_main ]; then
      run_one "$oracle" "$run/oracle-work" "$run/oracle2"
      run_one "$image" "$run/native-work" "$run/native2"
      if [ "$oracle_status" != 0 ] || [ "$(cat "$run/oracle2.status")" != 0 ] ||
         [ "$(cat "$run/native2.status")" != 0 ] ||
         ! cmp -s "$run/oracle.err" "$run/oracle2.err" ||
         ! cmp -s "$run/oracle.err" "$run/native2.err" ||
         cmp -s "$run/oracle.out" "$run/oracle2.out" ||
         cmp -s "$run/native.out" "$run/native2.out"; then
        fail "$short $name: random-address runs did not both succeed with different addresses"
        continue
      fi
      echo "   $short $name: native and hosted addresses changed across runs; exit and stderr matched"
      continue
    elif ! cmp -s "$run/oracle.out" "$run/native.out"; then
      fail "$short $name: stdout differs from the hosted reference"
      continue
    fi
    echo "   $short $name: native and hosted execution matched"
  done <"$work/manifest/$short"
  [ "$ran" -gt 0 ] || fail "$short: no corpus executable ran"
  echo "   $short: $ran corpus programs executed on $HOST_ID"
done

if [ "$failures" -eq 0 ]; then
  echo "== AVAILABLE NATIVE_ELF CHECKS PASSED; see host-limited lines for remaining coverage"
  exit 0
fi
echo "== SOME NATIVE_ELF CHECKS FAILED"
exit 1
