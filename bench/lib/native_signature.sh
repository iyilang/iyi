#!/usr/bin/env bash
# Reject invalid native executables before the kernel sees them. Non-Darwin hosts
# retain their existing execution behavior.
native_signature_ok() {
  if [ "$(uname -s)" = Darwin ] && ! /usr/bin/codesign -v --strict "$1" >/dev/null 2>&1; then
    if [ -n "${NATIVE_SIGNATURE_FAILURE_FILE:-}" ]; then
      : >"$NATIVE_SIGNATURE_FAILURE_FILE"
    fi
    echo "FAIL: invalid native executable signature: $1" >&2
    return 1
  fi
  return 0
}
