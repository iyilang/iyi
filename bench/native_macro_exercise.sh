#!/bin/bash
# Macro sites in def bodies, and the target's flags (self-compile items A and B).
#
# A: `{{ @type.name.stringify }}` in a def body is expanded by the macro engine with the enclosing type as @type, as the
#    hosted compiler expands it. The hosted build, the port with LLVM and the native back end must run cg_macro_site equal.
# B: the code generator and the declaration pass evaluate `flag?` against the TARGET's flags. The same source built for
#    aarch64-apple-darwin and x86_64-linux-gnu takes each target's branch: the object for x86_64-linux-gnu holds
#    "linux-branch" and the object for aarch64-apple-darwin holds "other-branch".
#
# Mutations are made to the SOURCE with bench/lib/mutation.sh; each must be caught: A replaces the enclosing type's name
# with "<Program>" (the exit status moves), B takes the host's flags for the target (the linux object loses its branch).
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export IYI_PATH="$REPO/src${IYI_PATH:+:$IYI_PATH}"
IYI="$REPO/bin/iyi"
PORT_SRC="$REPO/src/compiler/tools/compile.iyi"
NATIVE_SRC="$REPO/src/compiler/tools/compile_native.iyi"
SITE="$REPO/bench/fixtures/cg_macro_site.iyi"
TARGET_FIX="$REPO/bench/fixtures/cg_macro_target.iyi"
CODEGEN_SRC="$REPO/src/compiler/codegen/codegen.iyi"
. "$REPO/bench/lib/mutation.sh"
. "$REPO/bench/lib/native_signature.sh"

WORK="$(mktemp -d /tmp/iyi-macro-exercise.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
status=0

# build_port EXE: the port's own pipeline with the LLVM backend, built by ./bin/iyi from the source as it stands.
build_port() {
  "$IYI" build -o "$1" "$PORT_SRC" >"$1.build.log" 2>&1
}

# site_exit EXE: runs a program and prints its exit status.
site_exit() {
  "$1" >/dev/null 2>&1 </dev/null
  echo $?
}

echo "== 1. build the port with LLVM (tools/compile.iyi) and the native tool (compile_native.iyi), with ./bin/iyi"
if ! build_port "$WORK/bin/port"; then
  echo "FAIL: ./bin/iyi could not build $PORT_SRC; the build said:"
  grep -v '^ld: warning' "$WORK/bin/port.build.log" | tail -n 25 | sed 's/^/    /'
  exit 1
fi
echo "   built the port with LLVM from $PORT_SRC"
if ! "$IYI" build -o "$WORK/bin/native" "$NATIVE_SRC" >"$WORK/bin/native.build.log" 2>&1; then
  echo "FAIL: ./bin/iyi could not build $NATIVE_SRC; the build said:"
  grep -v '^ld: warning' "$WORK/bin/native.build.log" | tail -n 25 | sed 's/^/    /'
  exit 1
fi
echo "   built the native tool from $NATIVE_SRC"

echo "== 2. A: {{ @type.name.stringify }} in a def body: hosted build, port with LLVM, native back end"
# The fixture carries its own @[Unsafe] header (the hosted checker requires it for a C fun), so the reference is built as written.
hosted_rc="missing"
if "$IYI" build -o "$WORK/site_hosted" "$SITE" >"$WORK/site_hosted.log" 2>&1; then
  hosted_rc=$(site_exit "$WORK/site_hosted")
else
  echo "FAIL: the hosted compiler could not build the fixture: $(awk '/^Error/ { print; exit }' "$WORK/site_hosted.log")"
  status=1
fi
port_rc="missing"
if "$WORK/bin/port" "$SITE" -o "$WORK/site_port" >"$WORK/site_port.log" 2>&1; then
  port_rc=$(site_exit "$WORK/site_port")
fi
native_rc="missing"
if (cd "$WORK" && "$WORK/bin/native" "$SITE" -o "$WORK/site_native" >"$WORK/site_native.log" 2>&1); then
  if native_signature_ok "$WORK/site_native"; then
    native_rc=$(site_exit "$WORK/site_native")
  else
    status=1
  fi
fi
echo "   hosted exit $hosted_rc, port with LLVM exit $port_rc, native exit $native_rc"
if [ "$hosted_rc" != "missing" ] && [ "$port_rc" = "$hosted_rc" ]; then
  echo "   port with LLVM run equal to the hosted build: cg_macro_site"
else
  echo "FAIL: port with LLVM run differs from the hosted build: cg_macro_site"
  status=1
fi
if [ "$hosted_rc" != "missing" ] && [ "$native_rc" = "$hosted_rc" ]; then
  echo "   native run equal to the hosted build: cg_macro_site"
else
  echo "FAIL: native run differs from the hosted build: cg_macro_site ($(awk '/Error/ { print; exit }' "$WORK/site_native.log"))"
  status=1
fi

echo "== 3. B: flag?(:linux) takes the target's branch"
for triple in aarch64-apple-darwin x86_64-linux-gnu; do
  obj="$WORK/target_$triple.o"
  "$WORK/bin/port" --target "$triple" --emit-obj "$obj" "$TARGET_FIX" >"$obj.log" 2>&1
  if [ ! -s "$obj" ]; then
    echo "FAIL: no object for $triple: $(awk '/Error/ { print; exit }' "$obj.log")"
    status=1
    continue
  fi
  echo "   $triple: linux-branch in object $(grep -ac 'linux-branch' "$obj"), other-branch in object $(grep -ac 'other-branch' "$obj")"
done
linux_obj="$WORK/target_x86_64-linux-gnu.o"
darwin_obj="$WORK/target_aarch64-apple-darwin.o"
if [ -s "$linux_obj" ] && [ -s "$darwin_obj" ]; then
  if grep -aq 'linux-branch' "$linux_obj" && ! grep -aq 'other-branch' "$linux_obj" \
     && grep -aq 'other-branch' "$darwin_obj" && ! grep -aq 'linux-branch' "$darwin_obj"; then
    echo "   each target takes its own branch"
  else
    echo "FAIL: a target took the other target's branch"
    status=1
  fi
fi

typed_fixtures_ok=1
echo "== Native typed macro fixtures"
for name in macro_def_shadows_macro macro_typenode_ancestors macro_array_any macro_array_map macro_tuple_map_splat macro_range_map macro_lookup_arity macro_typeof_prelude; do
  fixture="$REPO/bench/fixtures/$name.iyi"
  if ! "$IYI" run "$fixture" >"$WORK/$name.hosted" 2>"$WORK/$name.hosted.err"; then
    echo "FAIL: hosted $name"
    typed_fixtures_ok=0
    status=1
    continue
  fi
  if ! "$WORK/bin/native" "$fixture" -o "$WORK/$name.native" --pipeline typed --prelude --probe-phase >"$WORK/$name.build" 2>&1; then
    echo "FAIL: native build $name"
    cat "$WORK/$name.build"
    typed_fixtures_ok=0
    status=1
    continue
  fi
  if ! native_signature_ok "$WORK/$name.native" || ! "$WORK/$name.native" >"$WORK/$name.out" 2>"$WORK/$name.err"; then
    echo "FAIL: native run $name"
    typed_fixtures_ok=0
    status=1
    continue
  fi
  if ! cmp -s "$WORK/$name.hosted" "$WORK/$name.out"; then
    echo "FAIL: output differs for $name"
    typed_fixtures_ok=0
    status=1
  else
    echo "  $name: native output matches hosted"
  fi
done

echo "== 4. mutations: each must be caught by a check that fails on the mutated source"
mut_run=0
mut_caught=0

check_typed_macro_fixture() {
  local name="$1"
  "$IYI" build -o "$WORK/bin/native_mut" "$NATIVE_SRC" >/dev/null 2>&1 || return 1
  native_signature_ok "$WORK/bin/native_mut" || return 1
  "$WORK/bin/native_mut" "$REPO/bench/fixtures/$name.iyi" -o "$WORK/native_mut_result" --pipeline typed --prelude --probe-phase >/dev/null 2>&1 || return 1
  native_signature_ok "$WORK/native_mut_result" || return 1
  "$WORK/native_mut_result" >"$WORK/native_mut.out" || return 1
  cmp -s "$WORK/$name.hosted" "$WORK/native_mut.out"
}
if [ "$typed_fixtures_ok" -eq 1 ]; then

mut_run=$((mut_run + 1))
prove_mutation "a local def fails to stop macro lookup" "$REPO/src/compiler/semantic/top_level.iyi" \
  'return true if @defs.has_key?(call.name)' 'return true if false' \
  -- check_typed_macro_fixture macro_def_shadows_macro && mut_caught=$((mut_caught + 1)) || status=1

mut_run=$((mut_run + 1))
prove_mutation "macro overload ignores required argument count" "$REPO/src/compiler/semantic/top_level.iyi" \
  '    return false if named.nil? && call.args.size < min' '    nil' \
  -- check_typed_macro_fixture macro_lookup_arity && mut_caught=$((mut_caught + 1)) || status=1

mut_run=$((mut_run + 1))
prove_mutation "ancestor list loses its parents" "$REPO/src/compiler/semantic/macro_bindings.iyi" \
  '    owner.parents.each do |parent|
      add_ancestor(parent, facts)' '    owner.parents.each do |parent|
      nil' \
  -- check_typed_macro_fixture macro_typenode_ancestors && mut_caught=$((mut_caught + 1)) || status=1

mut_run=$((mut_run + 1))
prove_mutation "the enclosing type loses its methods" "$REPO/src/compiler/semantic/macro_bindings.iyi" \
  '      collect_methods(owner.as(ModuleType), facts.methods)' '      nil' \
  -- check_typed_macro_fixture macro_typenode_ancestors && mut_caught=$((mut_caught + 1)) || status=1

mut_run=$((mut_run + 1))
prove_mutation "ancestor methods are omitted" "$REPO/src/compiler/macros/methods.iyi" \
  '            ancestor.methods.each { |item| ancestor_facts.methods << item }' '            nil' \
  -- check_typed_macro_fixture macro_typenode_ancestors && mut_caught=$((mut_caught + 1)) || status=1

mut_run=$((mut_run + 1))
prove_mutation "typeof fails to restore local types" "$REPO/src/compiler/semantic/type_nodes.iyi" \
  '    visitor.vars[name] = t' '    nil' \
  -- check_typed_macro_fixture macro_typeof_prelude && mut_caught=$((mut_caught + 1)) || status=1
else
  echo "FAIL: typed macro mutation proofs skipped because their unmutated fixtures failed"
  status=1
fi

# The check fails (is caught) when the mutated port's run differs from the hosted build.
check_site_scope() {
  build_port "$WORK/bin/port_mut_site" || return 1
  "$WORK/bin/port_mut_site" "$SITE" -o "$WORK/site_mut" >/dev/null 2>&1 || return 1
  [ "$(site_exit "$WORK/site_mut")" = "$hosted_rc" ]
}
mut_run=$((mut_run + 1))
if prove_mutation "the macro site expands with <Program> as @type" "$CODEGEN_SRC" \
    '(@current_self_type || "<Program>").split("(")[0]' '"<Program>"' -- check_site_scope; then
  mut_caught=$((mut_caught + 1))
else
  status=1
fi

# The check fails (is caught) when the mutated port's linux object loses its branch.
check_target_flags() {
  build_port "$WORK/bin/port_mut_flags" || return 1
  "$WORK/bin/port_mut_flags" --target x86_64-linux-gnu --emit-obj "$WORK/mut_linux.o" "$TARGET_FIX" >/dev/null 2>&1 || return 1
  grep -aq 'linux-branch' "$WORK/mut_linux.o"
}
mut_run=$((mut_run + 1))
if prove_mutation "codegen takes the host's flags for the target" "$CODEGEN_SRC" \
    '@macro_flags = MacroTargetFlags.for_triple(@mod.triple, [] of String)' \
    '@macro_flags = MacroTargetFlags.host([] of String)' -- check_target_flags; then
  mut_caught=$((mut_caught + 1))
else
  status=1
fi

echo "  Mutation summary: $mut_caught/$mut_run source mutations caught (A: the enclosing type's name; B: the target's flags)"
if [ "$mut_caught" -ne "$mut_run" ]; then status=1; fi

echo
if [ "$status" -eq 0 ]; then
  echo "ALL NATIVE MACRO CHECKS PASSED!"
else
  echo "SOME NATIVE MACRO CHECKS FAILED"
fi
exit "$status"
