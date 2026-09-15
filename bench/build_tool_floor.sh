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

# Allowlists: each entry has a stated reason in the header above.
ALLOWED_BUILD_TOOLS="c++ cc crystal git llvm-config"
ALLOWED_RUNTIME_TOOLS="cc dsymutil git ldd pkg-config wasmtime"
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
build_scan="$(python3 - "$REPO" << 'PYEOF'
import os, re, sys, shlex

repo = sys.argv[1]
found_build = {}

# 1. Parse Makefile
with open(f"{repo}/Makefile") as f:
    raw_lines = f.readlines()

# Join continuation lines ending with backslash
joined_lines = []
current = ""
start_idx = 1
for idx, l in enumerate(raw_lines, 1):
    stripped = l.rstrip("\r\n")
    if stripped.endswith("\\"):
        if not current:
            start_idx = idx
            current = stripped[:-1] + " "
        else:
            current += stripped[:-1] + " "
    else:
        if current:
            joined_lines.append((start_idx, current + stripped))
            current = ""
        else:
            joined_lines.append((idx, stripped))

for idx, line in joined_lines:
    if any(w in line for w in ["bin/crystal build", "$(CRYSTAL) env"]):
        found_build.setdefault("crystal", []).append(f"Makefile:{idx}")
    if any(w in line for w in ["find-llvm-config.sh", "$(LLVM_CONFIG)"]):
        found_build.setdefault("llvm-config", []).append(f"Makefile:{idx}")
    if "$(CXX)" in line:
        found_build.setdefault("c++", []).append(f"Makefile:{idx}")
    if any(w in line for w in ["EXPORT_CC", "CC ?="]):
        found_build.setdefault("cc", []).append(f"Makefile:{idx}")
    if any(w in line for w in ["git rev-parse", "git show", "git -c safe.directory"]):
        found_build.setdefault("git", []).append(f"Makefile:{idx}")

# Scan compiler target recipes in Makefile for any unexpected tools
COMPILER_TARGETS = {
    "$(O)/$(CRYSTAL_BIN)", "$(O)/iyi$(EXE)", "$(O)/$(IYI_DAEMON_BIN)",
    "$(O)/crystal-front$(EXE)", "$(O)/$(CRYSTAL_DAEMON_BIN)", "$(LLVM_EXT_OBJ)",
    "all:", "crystal:", "iyi:", "deps:", "llvm_ext:"
}
KNOWN_BUILTINS = {
    "echo", "printf", "test", "cat", "rm", "mkdir", "cp", "mv", "sed", "awk",
    "head", "tail", "tr", "sort", "uniq", "find", "cd", "pwd", "true", "false",
    "install", "touch", "stat", "chmod", "uname", "exit", "sh", "bash", "xargs",
}
MAKE_MACROS = {"$(call", "$(if", "$(error", "$(warning", "#"}

in_target = False
for idx, line in joined_lines:
    if not line.startswith("\t") and not line.startswith(" "):
        if any(line.startswith(t) for t in COMPILER_TARGETS):
            in_target = True
        else:
            in_target = False
    elif in_target and line.startswith("\t"):
        cmd_str = line.strip().lstrip("@-").strip()
        if cmd_str.startswith("#"):
            continue
        try:
            tokens = shlex.split(cmd_str)
        except Exception:
            tokens = cmd_str.split()
        for tok in tokens:
            if tok.startswith("$(call"):
                if "check_llvm_config" in tok:
                    found_build.setdefault("llvm-config", []).append(f"Makefile:{idx}")
                break
            if tok.startswith("$(if"):
                continue
            if "$(WINDOWS)," in tok:
                sub_cmd = tok.split(",", 1)[1]
                if sub_cmd in KNOWN_BUILTINS:
                    break
            if tok.startswith("$(") and tok.endswith(")"):
                inner = tok[2:-1]
                if inner in ["CXX"]:
                    found_build.setdefault("c++", []).append(f"Makefile:{idx}")
                    break
                elif inner in ["CC", "EXPORT_CC"]:
                    found_build.setdefault("cc", []).append(f"Makefile:{idx}")
                    break
                elif inner in ["CRYSTAL"]:
                    found_build.setdefault("crystal", []).append(f"Makefile:{idx}")
                    break
                continue
            if "=" in tok:
                continue
            clean = tok.strip("\"'()")
            if clean.startswith("./bin/crystal") or clean == "crystal":
                found_build.setdefault("crystal", []).append(f"Makefile:{idx}")
                break
            elif clean in KNOWN_BUILTINS:
                break
            elif clean:
                found_build.setdefault(clean, []).append(f"Makefile:{idx}")
                break

# 2. Check src/llvm/
with open(f"{repo}/src/llvm/ext/find-llvm-config.sh") as f:
    for idx, line in enumerate(f, 1):
        if "llvm-config" in line and not line.strip().startswith("#"):
            found_build.setdefault("llvm-config", []).append(f"src/llvm/ext/find-llvm-config.sh:{idx}")

with open(f"{repo}/src/llvm/lib_llvm.cr") as f:
    for idx, line in enumerate(f, 1):
        if any(w in line for w in ["llvm-config", "find-llvm-config.sh"]):
            found_build.setdefault("llvm-config", []).append(f"src/llvm/lib_llvm.cr:{idx}")

# 3. Check bin/crystal
with open(f"{repo}/bin/crystal") as f:
    for idx, line in enumerate(f, 1):
        if "$PARENT_CRYSTAL" in line and "exec" in line:
            found_build.setdefault("crystal", []).append(f"bin/crystal:{idx}")

for t in sorted(found_build):
    locs = " ".join(found_build[t][:3])
    count = len(found_build[t])
    print(f"TOOL:{t}:{count}:{locs}")
PYEOF
)"

found_build_tools=""
while IFS=: read -r prefix tool count locs; do
  [ "$prefix" = "TOOL" ] || continue
  found_build_tools="$found_build_tools $tool"
  printf '  %-14s (%2d sites)  %s\n' "$tool" "$count" "$locs"
done <<< "$build_scan"
found_build_tools="$(echo $found_build_tools | tr ' ' '\n' | sort -u | tr '\n' ' ')"

echo
echo "== 2. Tools the compiler invokes at RUNTIME to build a user's program"

# Measure runtime tools from compiler source
runtime_scan="$(python3 - "$REPO" << 'PYEOF'
import os, re, sys, glob

repo = sys.argv[1]
found_runtime = {}
compiler_files = glob.glob(f"{repo}/src/compiler/**/*.cr", recursive=True)

for cf in sorted(compiler_files):
    rel = os.path.relpath(cf, repo)
    with open(cf) as fh:
        for idx, line in enumerate(fh, 1):
            for m in re.finditer(r'Process\.find_executable\(\s*"([^"]+)"\s*\)', line):
                t = m.group(1)
                # Exclude dynamic subcommands and alternative modern linkers (probed under cc)
                if not t.startswith("#{") and t not in ["ld.lld", "mold"]:
                    found_runtime.setdefault(t, []).append(f"{rel}:{idx}")
            for m in re.finditer(r'Process\.run\(\s*"([^"]+)"', line):
                t = m.group(1)
                if t not in ["true", "/bin/sh"]:
                    found_runtime.setdefault(t, []).append(f"{rel}:{idx}")
            if "DEFAULT_LINKER" in line and ("Process.run" in line or "probe =" in line or "`#{" in line):
                found_runtime.setdefault("cc", []).append(f"{rel}:{idx}")

for t in sorted(found_runtime):
    locs = " ".join(found_runtime[t][:3])
    count = len(found_runtime[t])
    print(f"TOOL:{t}:{count}:{locs}")
PYEOF
)"

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
