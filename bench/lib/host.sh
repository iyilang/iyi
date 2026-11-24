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
