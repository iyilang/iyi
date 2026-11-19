#!/usr/bin/env bash
# Shared host and executable naming for the compiler component gates.
case "$(uname -s)" in
  Linux) HOST_OS=linux; EXE= ;;
  Darwin) HOST_OS=darwin; EXE= ;;
  MINGW* | MSYS* | CYGWIN* | Windows_NT) HOST_OS=windows; EXE=.exe ;;
  *) echo "unsupported test host: $(uname -s)" >&2; return 1 ;;
esac
case "$(uname -m)" in
  x86_64 | amd64 | AMD64) HOST_ARCH=x86_64 ;;
  arm64 | aarch64 | ARM64) HOST_ARCH=arm64 ;;
  *) echo "unsupported test architecture: $(uname -m)" >&2; return 1 ;;
esac
HOST_ID="$HOST_OS-$HOST_ARCH"

native_path() {
  if [ "$HOST_OS" = windows ]; then
    cygpath -m "$1"
  else
    printf '%s\n' "$1"
  fi
}

# Test the interpreter: Windows may answer python3 with a store stub.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

require_test_host() {
  if [ -n "${CI:-}" ] && [ -z "${SELFHOST_HOST:-}" ]; then
    echo 'SELFHOST_HOST must identify the CI runner' >&2
    return 1
  fi
  if [ -n "${SELFHOST_HOST:-}" ] && [ "$SELFHOST_HOST" != "$HOST_ID" ]; then
    echo "expected test host $SELFHOST_HOST, running on $HOST_ID" >&2
    return 1
  fi
  printf 'host: %s (%s %s)\n' "$HOST_ID" "$(uname -s)" "$(uname -m)"
}

# Call only for a section that genuinely needs a different target kernel/tool.
host_limited() {
  printf 'host-limited: %s\n' "$*"
}

# Trims CR and surrounding whitespace, the way the bridge's macro trimmed a line of llvm_VERSION.
_llvm_trim() {
  local s=${1//$'\r'/}
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# Prints, one per line, the arguments the LLVM bridge (src/compiler/llvm/lib_llvm.iyi) builds with on this host: its
# version as -Dllvm_major_N, -Dllvm_minor_N and -Dllvm_patch_N (minor and patch count as 0), one -Dllvm_target_<name>
# per built target, and --link-flags with the libraries to link. Every build of a program that imports the bridge
# passes them. The inputs are the ones the bridge's macro used to read, in the same order: LLVM_VERSION, LLVM_TARGETS
# and LLVM_LDFLAGS when set and not blank; on Windows, the three lines of the llvm_VERSION file in the first directory
# of IYI_LIBRARY_PATH (or, when that is unset, of the bootstrap package's search path) that has one; otherwise
# ${LLVM_CONFIG:-llvm-config} with --version, --targets-built and --libs --system-libs --ldflags. It returns 1 with
# one sentence on stderr when it cannot read them.
llvm_bridge_build_args() {
  local cfg="${LLVM_CONFIG:-llvm-config}" version="" targets="" ldflags="" dir search line1="" line2="" line3=""
  local major="" minor="" patch="" rest="" word lower
  local -a dirs=()
  if [ "$HOST_OS" = windows ]; then
    # The Windows job's environment carries only the bootstrap package's variable (iyi.yml); ours wins when it is set.
    if [ -n "${IYI_LIBRARY_PATH+set}" ]; then search=$IYI_LIBRARY_PATH; else search=${CRYSTAL_LIBRARY_PATH:-}; fi
    IFS=';' read -r -a dirs <<< "$search"
    for dir in "${dirs[@]+"${dirs[@]}"}"; do
      if command -v cygpath >/dev/null 2>&1; then dir=$(cygpath -u "$dir") || continue; fi
      if [ -f "$dir/llvm_VERSION" ]; then
        { IFS= read -r line1; IFS= read -r line2; IFS= read -r line3; } < "$dir/llvm_VERSION" || true
        break
      fi
    done
  fi
  version=$(_llvm_trim "${LLVM_VERSION:-}")
  targets=$(_llvm_trim "${LLVM_TARGETS:-}")
  ldflags=$(_llvm_trim "${LLVM_LDFLAGS:-}")
  if [ "$HOST_OS" = windows ]; then
    [ -n "$version" ] || version=$(_llvm_trim "$line1")
    [ -n "$targets" ] || targets=$(_llvm_trim "$line2")
    [ -n "$ldflags" ] || ldflags=$(_llvm_trim "$line3")
  else
    [ -n "$version" ] || version=$("$cfg" --version 2>/dev/null) || version=""
    [ -n "$targets" ] || targets=$("$cfg" --targets-built 2>/dev/null) || targets=""
    if [ -z "$ldflags" ]; then
      ldflags=$("$cfg" --libs --system-libs --ldflags 2>/dev/null) || ldflags=""
      ldflags=$(_llvm_trim "${ldflags//$'\n'/ }")
    fi
  fi
  if [ -n "$version" ]; then
    IFS=. read -r major minor patch rest <<< "$version"
    major=${major%%[!0-9]*}
    minor=${minor%%[!0-9]*}
    patch=${patch%%[!0-9]*}
  fi
  if [ -z "$major" ] || [ -z "$targets" ]; then
    if [ "$HOST_OS" = windows ]; then
      echo "Cannot read LLVM's version and targets: set LLVM_VERSION and LLVM_TARGETS, or put an llvm_VERSION file in a directory of IYI_LIBRARY_PATH." >&2
    else
      echo "Cannot read LLVM's version and targets: set LLVM_CONFIG to an llvm-config on PATH, or set LLVM_VERSION and LLVM_TARGETS." >&2
    fi
    return 1
  fi
  if [ "$HOST_OS" != windows ] && [ -z "$ldflags" ]; then
    echo "Cannot read LLVM's link flags: set LLVM_CONFIG to an llvm-config on PATH, or set LLVM_LDFLAGS." >&2
    return 1
  fi
  printf '%s\n' "-Dllvm_major_$major" "-Dllvm_minor_${minor:-0}" "-Dllvm_patch_${patch:-0}"
  lower=$(printf '%s' "$targets" | tr 'A-Z' 'a-z')
  for word in $lower; do
    printf '%s\n' "-Dllvm_target_$word"
  done
  if [ -n "$ldflags" ]; then
    printf '%s\n' --link-flags "$ldflags"
  fi
}
