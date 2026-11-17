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
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
REPO_NATIVE="$(native_path "$REPO")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
IYI="$REPO/bin/iyi"
PORT_SRC="$REPO/src/compiler/tools/compile.iyi"
NATIVE_SRC="$REPO/src/compiler/tools/compile_native.iyi"
SITE="$REPO/bench/fixtures/cg_macro_site.iyi"
TARGET_FIX="$REPO/bench/fixtures/cg_macro_target.iyi"
CODEGEN_SRC="$REPO/src/compiler/codegen/codegen.iyi"
. "$REPO/bench/lib/mutation.sh"
. "$REPO/bench/lib/native_signature.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/iyi-macro-exercise.XXXXXX")" || exit 1
WORK_NATIVE="$(native_path "$WORK")" || exit 1
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
status=0

# build_port EXE: the port's own pipeline with the LLVM backend, built by ./bin/iyi from the source as it stands.
build_port() {
  "$IYI" build -o "$(native_path "$1")" "$REPO_NATIVE/src/compiler/tools/compile.iyi" >"$1.build.log" 2>&1
}

# site_exit EXE: runs a program and prints its exit status.
site_exit() {
  "$1" >/dev/null 2>&1 </dev/null
  echo $?
}

echo "== 1. build the port with LLVM (tools/compile.iyi) and the native tool (compile_native.iyi), with ./bin/iyi"
if ! build_port "$WORK/bin/port$EXE"; then
  echo "FAIL: ./bin/iyi could not build $PORT_SRC; the build said:"
  cat "$WORK/bin/port$EXE.build.log"
  exit 1
fi
echo "   built the port with LLVM from $PORT_SRC"
if ! "$IYI" build -o "$WORK_NATIVE/bin/native$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" >"$WORK/bin/native.build.log" 2>&1; then
  echo "FAIL: ./bin/iyi could not build $NATIVE_SRC; the build said:"
  cat "$WORK/bin/native.build.log"
  exit 1
fi
echo "   built the native tool from $NATIVE_SRC"

echo "== 2. A: {{ @type.name.stringify }} in a def body: hosted build, port with LLVM, native back end"
# The fixture carries its own @[Unsafe] header (the hosted checker requires it for a C fun), so the reference is built as written.
hosted_rc="missing"
if "$IYI" build -o "$WORK_NATIVE/site_hosted$EXE" "$REPO_NATIVE/bench/fixtures/cg_macro_site.iyi" >"$WORK/site_hosted.log" 2>&1; then
  hosted_rc=$(site_exit "$WORK/site_hosted$EXE")
else
  echo "FAIL: the hosted compiler could not build the fixture: $(awk '/^Error/ { print; exit }' "$WORK/site_hosted.log")"
  status=1
fi
port_rc="missing"
if "$WORK/bin/port$EXE" "$REPO_NATIVE/bench/fixtures/cg_macro_site.iyi" -o "$WORK_NATIVE/site_port$EXE" >"$WORK/site_port.log" 2>&1; then
  port_rc=$(site_exit "$WORK/site_port$EXE")
fi
native_rc="missing"
if [ "$HOST_ID" = darwin-arm64 ]; then
  if (cd "$WORK" && "$WORK/bin/native$EXE" "$REPO_NATIVE/bench/fixtures/cg_macro_site.iyi" -o "$WORK_NATIVE/site_native" >"$WORK/site_native.log" 2>&1); then
    if native_signature_ok "$WORK/site_native"; then
      native_rc=$(site_exit "$WORK/site_native")
    else
      status=1
    fi
  fi
else
  if ! "$WORK/bin/native$EXE" "$REPO_NATIVE/bench/fixtures/cg_macro_site.iyi" -o "$WORK_NATIVE/site_native.ir" --emit ir >"$WORK/site_native.log" 2>&1 || [ ! -s "$WORK/site_native.ir" ]; then
    cat "$WORK/site_native.log"
    echo "FAIL: native pipeline did not emit verified IR for cg_macro_site"
    status=1
  fi
  host_limited "macro site: native Mach-O signature and execution require macOS arm64"
fi
echo "   hosted exit $hosted_rc, port with LLVM exit $port_rc, native exit $native_rc"
if [ "$hosted_rc" != "missing" ] && [ "$port_rc" = "$hosted_rc" ]; then
  echo "   port with LLVM run equal to the hosted build: cg_macro_site"
else
  echo "FAIL: port with LLVM run differs from the hosted build: cg_macro_site"
  status=1
fi
if [ "$HOST_ID" = darwin-arm64 ]; then
  if [ "$hosted_rc" != "missing" ] && [ "$native_rc" = "$hosted_rc" ]; then
    echo "   native run equal to the hosted build: cg_macro_site"
  else
    echo "FAIL: native run differs from the hosted build: cg_macro_site ($(awk '/Error/ { print; exit }' "$WORK/site_native.log"))"
    status=1
  fi
fi

echo "== 3. B: flag?(:linux) takes the target's branch"
for triple in aarch64-apple-darwin x86_64-linux-gnu; do
  obj="$WORK/target_$triple.o"
  "$WORK/bin/port$EXE" --target "$triple" --emit-obj "$(native_path "$obj")" "$REPO_NATIVE/bench/fixtures/cg_macro_target.iyi" >"$obj.log" 2>&1
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
  if ! "$IYI" run "$(native_path "$fixture")" >"$WORK/$name.hosted" 2>"$WORK/$name.hosted.err"; then
    echo "FAIL: hosted $name"
    typed_fixtures_ok=0
    status=1
    continue
  fi
  if [ "$HOST_ID" != darwin-arm64 ]; then
    if ! "$WORK/bin/native$EXE" "$(native_path "$fixture")" -o "$WORK_NATIVE/$name.ir" --pipeline typed --prelude --probe-phase --emit ir >"$WORK/$name.build" 2>&1 || [ ! -s "$WORK/$name.ir" ]; then
      echo "FAIL: native typed IR $name"
      cat "$WORK/$name.build"
      typed_fixtures_ok=0
      status=1
    fi
    continue
  fi
  if ! "$WORK/bin/native$EXE" "$(native_path "$fixture")" -o "$WORK_NATIVE/$name.native" --pipeline typed --prelude --probe-phase >"$WORK/$name.build" 2>&1; then
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
mut_limited=0

check_typed_macro_fixture() {
  local name="$1"
  if ! "$IYI" build -o "$WORK_NATIVE/bin/native_mut$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" >"$WORK/native_mut.build" 2>&1; then
    cat "$WORK/native_mut.build"
    return 2
  fi
  native_signature_ok "$WORK/bin/native_mut$EXE" || return 2
  if ! "$WORK/bin/native_mut$EXE" "$REPO_NATIVE/bench/fixtures/$name.iyi" -o "$WORK_NATIVE/native_mut_result" --pipeline typed --prelude --probe-phase >"$WORK/native_mut_result.build" 2>&1; then
    cat "$WORK/native_mut_result.build"
    return 2
  fi
  native_signature_ok "$WORK/native_mut_result" || return 2
  if ! "$WORK/native_mut_result" >"$WORK/native_mut.out" 2>"$WORK/native_mut.err"; then
    cat "$WORK/native_mut.err"
    return 2
  fi
  if cmp -s "$WORK/$name.hosted" "$WORK/native_mut.out"; then return 0; fi
  echo "decisive: $name output differs from the hosted compiler"
  return 1
}
if [ "$typed_fixtures_ok" -ne 1 ]; then
  echo "FAIL: typed macro mutation proofs skipped because their unmutated fixtures failed"
  status=1
elif [ "$HOST_ID" = darwin-arm64 ]; then

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
  while IFS= read -r mutation; do
    mut_limited=$((mut_limited + 1))
    host_limited "typed macro mutation: $mutation requires native Mach-O execution on macOS arm64"
  done <<'LIMITED'
a local def fails to stop macro lookup
macro overload ignores required argument count
ancestor list loses its parents
the enclosing type loses its methods
ancestor methods are omitted
typeof fails to restore local types
LIMITED
fi

# The check fails (is caught) when the mutated port's run differs from the hosted build.
check_site_scope() {
  if ! build_port "$WORK/bin/port_mut_site$EXE"; then cat "$WORK/bin/port_mut_site$EXE.build.log"; return 2; fi
  if ! "$WORK/bin/port_mut_site$EXE" "$REPO_NATIVE/bench/fixtures/cg_macro_site.iyi" -o "$WORK_NATIVE/site_mut$EXE" >"$WORK/site_mut.build" 2>&1; then
    cat "$WORK/site_mut.build"
    return 2
  fi
  local rc
  rc=$(site_exit "$WORK/site_mut$EXE")
  [ "$rc" -lt 128 ] || return 2
  if [ "$rc" = "$hosted_rc" ]; then return 0; fi
  echo "decisive: macro-site exit $rc differs from hosted exit $hosted_rc"
  return 1
}
mut_run=$((mut_run + 1))
if prove_mutation "the macro site expands with <Program> as @type" "$CODEGEN_SRC" \
    '(@current_self_type || "<Program>").split("(")[0]' '"<Program>"' -- check_site_scope; then
  mut_caught=$((mut_caught + 1))
else
  status=1
fi

# Choose a target whose linux flag differs from the host's flags.
check_target_flags() {
  local triple expected other obj
  if [ "$HOST_OS" = linux ]; then
    triple=aarch64-apple-darwin; expected=other-branch; other=linux-branch
  else
    triple=x86_64-linux-gnu; expected=linux-branch; other=other-branch
  fi
  obj="$WORK/mut_target.o"
  if ! build_port "$WORK/bin/port_mut_flags$EXE"; then cat "$WORK/bin/port_mut_flags$EXE.build.log"; return 2; fi
  if ! "$WORK/bin/port_mut_flags$EXE" --target "$triple" --emit-obj "$WORK_NATIVE/mut_target.o" "$REPO_NATIVE/bench/fixtures/cg_macro_target.iyi" >"$WORK/mut_target.log" 2>&1 || [ ! -s "$obj" ]; then
    cat "$WORK/mut_target.log"
    return 2
  fi
  if grep -aq "$expected" "$obj" && ! grep -aq "$other" "$obj"; then return 0; fi
  if grep -aq "$other" "$obj" && ! grep -aq "$expected" "$obj"; then
    echo "decisive: $triple took the host's $other"
    return 1
  fi
  echo "unexpected target object contents"
  return 2
}
mut_run=$((mut_run + 1))
if prove_mutation "codegen takes the host's flags for the target" "$CODEGEN_SRC" \
    '@macro_flags = MacroTargetFlags.for_triple(@mod.triple, [] of String)' \
    '@macro_flags = MacroTargetFlags.host([] of String)' -- check_target_flags; then
  mut_caught=$((mut_caught + 1))
else
  status=1
fi

echo "  Mutation summary: $mut_caught/$mut_run attempted caught; $mut_limited host-limited"
if [ "$mut_caught" -ne "$mut_run" ]; then status=1; fi

echo
if [ "$status" -eq 0 ]; then
  echo "ALL NATIVE MACRO CHECKS PASSED!"
else
  echo "SOME NATIVE MACRO CHECKS FAILED"
fi
exit "$status"
