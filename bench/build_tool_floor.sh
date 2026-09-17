#!/usr/bin/env bash
# Fails when iyi grows a build or runtime tool dependency:
#
#   crystal, llvm-config, c++, cc, git (build time)
#   cc, dsymutil, pkg-config, git, ldd, wasmtime (compiler runtime)
#
# A program iyi builds links only the platform libc (SPEC.md III.9, III.10).
# The compiler binary links four libraries (libLLVM, libc++, libgc, libSystem).
# `bench/dependency_floor.sh` gates the library and symbol dependencies.
#
# This script gates the EXTERNAL TOOLS: the executables the build system and
# compiler invoke. A new tool arriving with a feature is a decision, and this
# check ensures it cannot arrive silently.
#
# Two distinct dependency surfaces, reported separately:
#
# 1. BUILD-TIME TOOLS (tools required to construct the compiler from source):
#    - crystal: The bootstrap compiler that compiles .build/crystal and
#      .build/iyi from source. Goes when the compiler is fully self-hosted.
#    - llvm-config: Locates LLVM headers, libraries, targets, and compiler/linker
#      flags. Conditional: bypassed if LLVM_VERSION, LLVM_TARGETS, and LLVM_LDFLAGS
#      are supplied externally. Goes when LLVM is replaced by an independent backend.
#    - c++ (or $(CXX)): Compiles src/llvm/ext/llvm_ext.cc (C++ compatibility shim).
#      Conditional: required only when building against LLVM < 18 (Makefile:176-178
#      sets DEPS = when LLVM_VERSION >= 18, and llvm_ext.cc is guarded by
#      #if !LLVM_VERSION_GE(18, 0)). On LLVM 18+ (such as LLVM 22), it is unneeded.
#      Goes when targeting LLVM 18+ exclusively or when the shim is eliminated.
#    - cc (or clang / $CC): C compiler and linker driver used by ./bin/crystal build
#      to link compiler binary objects (.build/crystal, .build/iyi).
#      Goes when the compiler directly emits linked executables.
#    - git: Reads commit hash and timestamp for build metadata
#      (IYI_CONFIG_BUILD_COMMIT, SOURCE_DATE_EPOCH). Conditional: skipped when
#      metadata is passed in environment or when building from release tarball.
#      Goes when metadata is passed statically.
#
# 2. RUNTIME TOOLS (tools the compiler invokes to build a user's program):
#    - cc (or $CC / DEFAULT_LINKER): Links compiled program objects (.o) with
#      libc and system libraries into an executable.
#      Goes only if iyi gains an internal object-file linker.
#    - dsymutil: Extracts DWARF debug companion files on Darwin. Conditional on
#      macOS (flag?(:darwin)) and debug builds (!debug.none?).
#      Goes when DWARF debug info is embedded directly or debug info is omitted.
#    - pkg-config: Queries flags for external C libraries declared via
#      @[Link(..., pkg_config: "...")]. Conditional: invoked only when compiling
#      code that binds external C libraries. Pure iyi programs link only libc
#      and never invoke pkg-config.
#    - git: Fetches remote module dependencies for `iyi mod`. Conditional:
#      invoked only when resolving remote packages (iyi mod get).
#    - ldd: Detects GNU vs musl host libc on Linux. Conditional on Linux target
#      configuration. Goes when target libc is specified explicitly.
#    - wasmtime: WebAssembly runtime for `iyi run --sandbox`. Conditional on
#      --sandbox. Goes if sandboxing uses native container isolation.
#
# Usage:
#     bash bench/build_tool_floor.sh
#
# Exits non-zero if:
#   - An unexpected tool is invoked in the build system or compiler source
#   - An allowlisted tool is no longer invoked anywhere (stale allowlist)
#   - A forbidden tool appears anywhere in the build or runtime path

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# A native compiler cannot resolve this shell's own path mapping, and the
# scan below is handed the repository root to read: the shell's `pwd` names
# it in a way nothing outside this shell resolves.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) REPO="$(cygpath -m "$REPO")" ;;
esac

# The scan is written in python, and a machine can answer `python3` with a
# stub that prints a sentence and exits: an interpreter is the one that
# imports a module, so that is what is asked of it here.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

# Allowlists: each entry has a stated reason in the header above.
ALLOWED_BUILD_TOOLS="c++ cc crystal git llvm-config"
ALLOWED_RUNTIME_TOOLS="cc dsymutil git ldd pkg-config wasmtime"

# Tools reached only by auxiliary targets: docs, lint, spec, packaging. These
# are not dependencies of iyi, because nobody needs them to build the compiler
# or to build a program with it. They are still listed, because an unlisted
# tool appearing anywhere is what this gate exists to notice, and "it is only
# in the docs target" is a judgement for a reader to make rather than a reason
# to stay silent.
#
#   asciidoctor  renders the man pages in `docs`
#   gzip         compresses them
#   grep, ldd    used by `lint` and by the install checks
#   shellcheck   lints the shell scripts
ALLOWED_AUX_TOOLS="asciidoctor grep gzip ldd shellcheck"

FORBIDDEN_TOOLS="ar strip python python3 ruby perl nasm yasm"

unexpected() {
  local allowed="$1" found="$2" item keep ok
  for item in $found; do
    keep=no
    for ok in $allowed; do
      [ "$item" = "$ok" ] && keep=yes
    done
    [ "$keep" = no ] && printf '%s\n' "$item"
  done
  return 0
}

status=0

echo "== 1. Tools required to BUILD the compiler"

# Measure build tools from build files
if [ -n "$PY" ]; then
  build_scan="$("$PY" "$REPO/bench/build_tool_scan.py" build "$REPO")"
else
  build_scan=""
  echo "  the build files went unread: no python3 or python here is an interpreter"
fi

found_build_tools=""
found_aux_tools=""
while IFS=: read -r prefix tool count locs; do
  case "$prefix" in
    TOOL)
      found_build_tools="$found_build_tools $tool"
      printf '  %-14s (%2d sites)  %s\n' "$tool" "$count" "$locs"
      ;;
    AUX)
      found_aux_tools="$found_aux_tools $tool"
      ;;
  esac
done <<< "$build_scan"
found_build_tools="$(echo $found_build_tools | tr ' ' '\n' | sort -u | tr '\n' ' ')"
found_aux_tools="$(echo $found_aux_tools | tr ' ' '\n' | sort -u | tr '\n' ' ')"

if [ -n "$(echo $found_aux_tools)" ]; then
  echo
  echo "== 1b. Tools used only by auxiliary targets (docs, lint, spec, package)"
  echo "       Not required to build the compiler, so not a dependency of iyi."
  for t in $found_aux_tools; do
    printf '  %s\n' "$t"
  done
fi

echo
echo "== 2. Tools the compiler invokes at RUNTIME to build a user's program"

# Measure runtime tools from compiler source
if [ -n "$PY" ]; then
  runtime_scan="$("$PY" "$REPO/bench/build_tool_scan.py" runtime "$REPO")"
else
  runtime_scan=""
  echo "  the compiler source went unread: no python3 or python here is an interpreter"
fi

found_runtime_tools=""
while IFS=: read -r prefix tool count locs; do
  [ "$prefix" = "TOOL" ] || continue
  found_runtime_tools="$found_runtime_tools $tool"
  printf '  %-14s (%2d sites)  %s\n' "$tool" "$count" "$locs"
done <<< "$runtime_scan"
found_runtime_tools="$(echo $found_runtime_tools | tr ' ' '\n' | sort -u | tr '\n' ' ')"

echo
echo "== 3. Active environment probe (current machine)"

# Probe active LLVM and conditionality
active_llvm_version=""
if command -v llvm-config >/dev/null 2>&1; then
  active_llvm_version="$(llvm-config --version 2>/dev/null || true)"
fi
if [ -n "$active_llvm_version" ]; then
  major_llvm="${active_llvm_version%%.*}"
  printf '  llvm-config:   version %s\n' "$active_llvm_version"
  if [ "${major_llvm:-0}" -ge 18 ] 2>/dev/null; then
    printf '  $(CXX):        bypassed (LLVM %s >= 18: DEPS is empty, llvm_ext.o unneeded)\n' "$active_llvm_version"
  else
    printf '  $(CXX):        active (LLVM %s < 18: llvm_ext.o required)\n' "$active_llvm_version"
  fi
else
  echo "  llvm-config:   not found on PATH (using external configuration if set)"
fi

if command -v crystal >/dev/null 2>&1; then
  printf '  crystal:       %s\n' "$(crystal --version 2>/dev/null | head -1)"
fi
if command -v cc >/dev/null 2>&1; then
  printf '  cc:            %s\n' "$(command -v cc)"
fi

# The allowlists judge what the scan found, and with no interpreter the scan
# found nothing: a floor that went unmeasured is not a floor that moved, so
# this says so instead of reading an empty answer as either verdict.
if [ -z "$PY" ]; then
  echo "the tool floor went unmeasured: the scan needs python and this machine has none"
  exit "$status"
fi

echo
report() {
  local what="$1" extra="$2" note="$3"
  if [ -n "$extra" ]; then
    echo "THE FLOOR MOVED: $what gained:"
    printf '  %s\n' $extra
    echo "$note"
    status=1
  fi
}

report "build tools" \
  "$(unexpected "$ALLOWED_BUILD_TOOLS" "$found_build_tools")" \
  "Each build tool must be recorded in ALLOWED_BUILD_TOOLS with its reason (SPEC.md III.9, III.10)."

report "runtime tools" \
  "$(unexpected "$ALLOWED_RUNTIME_TOOLS" "$found_runtime_tools")" \
  "Each runtime tool must be recorded in ALLOWED_RUNTIME_TOOLS with its reason (SPEC.md III.9, III.10)."

report "auxiliary tools" \
  "$(unexpected "$ALLOWED_AUX_TOOLS" "$found_aux_tools")" \
  "A tool reached from any target must be recorded. Auxiliary ones go in
ALLOWED_AUX_TOOLS with their reason; they are not dependencies of iyi, but an
unrecorded one is a dependency nobody decided to take on."

# Failure in the other direction: stale allowlist entries
missing_build="$(unexpected "$found_build_tools" "$ALLOWED_BUILD_TOOLS")"
if [ -n "$missing_build" ]; then
  echo "The floor got lower and this script is out of date. No longer needed in build tools:"
  printf '  %s\n' $missing_build
  echo "Remove them from ALLOWED_BUILD_TOOLS so the check keeps its teeth."
  status=1
fi

missing_runtime="$(unexpected "$found_runtime_tools" "$ALLOWED_RUNTIME_TOOLS")"
if [ -n "$missing_runtime" ]; then
  echo "The floor got lower and this script is out of date. No longer needed in runtime tools:"
  printf '  %s\n' $missing_runtime
  echo "Remove them from ALLOWED_RUNTIME_TOOLS so the check keeps its teeth."
  status=1
fi

# Forbidden tools check
for forbidden in $FORBIDDEN_TOOLS; do
  if echo "$found_build_tools $found_runtime_tools" | grep -qw "$forbidden"; then
    echo "FORBIDDEN: $forbidden appears in tool dependencies; iyi is not allowed to need it."
    status=1
  fi
done

[ "$status" -eq 0 ] && echo "the tool floor holds"
exit $status
