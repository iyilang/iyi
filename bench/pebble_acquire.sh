#!/usr/bin/env bash
# bench/pebble_acquire.sh: Acquires and verifies Pebble test server dependencies.
#
# Sourced by bench/std_acme_exercise.sh and bench/std_autocert_exercise.sh,
# or executed directly by focused tests.
#
# Return / Exit codes:
#   0: Success. Pebble binaries ($GOBIN/pebble, $GOBIN/pebble-challtestsrv) and
#      $certs directory are verified and ready.
#   1: Hard failure under proof-only mode (IYI_PROOF_INPUTS_DIR set).
#      Message printed to stderr.
#   2: Skip under normal mode: Go command is missing.
#   3: Skip under normal mode: Go install failed (e.g. ambient network unavailable).
set -u

acquire_pebble() {
  GO="${GO:-go}"
  WORK="${WORK:-}"
  if [ -z "$WORK" ]; then
    echo "pebble_acquire: WORK directory must be set" >&2
    return 1
  fi

  if ! command -v "$GO" >/dev/null 2>&1; then
    if [ "${IYI_PROOF_INPUTS_DIR+set}" = "set" ]; then
      echo "  FAIL: IYI_PROOF_INPUTS_DIR requires Go, but '$GO' was not found" >&2
      return 1
    else
      return 2
    fi
  fi

  GOBIN="$WORK/gobin"
  mkdir -p "$GOBIN"

  if [ "${IYI_PROOF_INPUTS_DIR+set}" = "set" ]; then
    if [ -z "$IYI_PROOF_INPUTS_DIR" ]; then
      echo "  FAIL: IYI_PROOF_INPUTS_DIR must not be empty" >&2
      return 1
    fi
    case "$IYI_PROOF_INPUTS_DIR" in
      /* | [a-zA-Z]:/* | [a-zA-Z]:\\* | \\\\*) ;;
      *)
        echo "  FAIL: IYI_PROOF_INPUTS_DIR must be an absolute path: $IYI_PROOF_INPUTS_DIR" >&2
        return 1
        ;;
    esac
    case "$(uname -s)" in
      MINGW* | MSYS* | CYGWIN* | Windows_NT)
        command -v cygpath >/dev/null 2>&1 && IYI_PROOF_INPUTS_DIR="$(cygpath -m "$IYI_PROOF_INPUTS_DIR")"
        ;;
    esac
    if [ ! -d "$IYI_PROOF_INPUTS_DIR" ]; then
      echo "  FAIL: IYI_PROOF_INPUTS_DIR directory not found: $IYI_PROOF_INPUTS_DIR" >&2
      return 1
    fi
    proxy_dir="$IYI_PROOF_INPUTS_DIR/go-proxy"
    if [ ! -d "$proxy_dir" ]; then
      echo "  FAIL: IYI_PROOF_INPUTS_DIR Go module mirror 'go-proxy/' missing: $proxy_dir" >&2
      return 1
    fi

    GOMODCACHE="$WORK/gomodcache"
    GOCACHE="$WORK/gocache"
    mkdir -p "$GOMODCACHE" "$GOCACHE"
    proxy_path="$proxy_dir"
    case "$(uname -s)" in
      MINGW* | MSYS* | CYGWIN* | Windows_NT) proxy_path="$(cygpath -m "$proxy_path")" ;;
    esac
    case "$proxy_path" in
      /*) proxy_url="file://$proxy_path" ;;
      *) proxy_url="file:///$proxy_path" ;;
    esac

    # Contract: trusted orchestrator independently verifies complete Go mirror
    # artifact manifest/digest before launch; do not claim Go's disabled
    # checksum service (GOSUMDB=off) proves it.
    if ! env -u GOPRIVATE GOBIN="$GOBIN" GOMODCACHE="$GOMODCACHE" GOCACHE="$GOCACHE" \
        GOTOOLCHAIN=local GOPROXY="$proxy_url" GONOPROXY=none GOSUMDB=off GONOSUMDB="*" \
        "$GO" install github.com/letsencrypt/pebble/v2/cmd/pebble@v2.10.1 \
          github.com/letsencrypt/pebble/v2/cmd/pebble-challtestsrv@v2.10.1 >"$WORK/go-install.log" 2>&1; then
      echo "  FAIL: Pebble v2.10.1 could not be installed from offline mirror: $(tail -1 "$WORK/go-install.log")" >&2
      return 1
    fi

    binary="$GOBIN/pebble"
    [ -f "$binary.exe" ] && binary="$binary.exe"
    challtest="$GOBIN/pebble-challtestsrv"
    [ -f "$challtest.exe" ] && challtest="$challtest.exe"
    if [ ! -x "$binary" ] || [ ! -x "$challtest" ]; then
      echo "  FAIL: Pebble v2.10.1 binaries missing or not executable in $GOBIN" >&2
      return 1
    fi

    version="$(env -u GOPRIVATE GOTOOLCHAIN=local GOPROXY="$proxy_url" GONOPROXY=none GOSUMDB=off GONOSUMDB="*" "$GO" version -m "$binary" 2>/dev/null | awk '$1 == "mod" && $2 == "github.com/letsencrypt/pebble/v2" { print $3 }')"
    if [ "$version" != "v2.10.1" ]; then
      echo "  FAIL: Pebble binary module version '$version' != expected 'v2.10.1'" >&2
      return 1
    fi

    certs="$GOMODCACHE/github.com/letsencrypt/pebble/v2@$version/test/certs"
    case "$(uname -s)" in
      MINGW* | MSYS* | CYGWIN* | Windows_NT) certs="$(cygpath -m "$certs")" ;;
    esac
    if [ ! -d "$certs" ] || [ ! -f "$certs/localhost/cert.pem" ] || [ ! -f "$certs/localhost/key.pem" ] || [ ! -f "$certs/pebble.minica.pem" ]; then
      echo "  FAIL: required Pebble test certs missing in $certs" >&2
      return 1
    fi
    return 0
  else
    if ! GOBIN="$GOBIN" "$GO" install github.com/letsencrypt/pebble/v2/cmd/pebble@latest \
        github.com/letsencrypt/pebble/v2/cmd/pebble-challtestsrv@latest >"$WORK/go-install.log" 2>&1; then
      return 3
    fi

    binary="$GOBIN/pebble"
    [ -f "$binary.exe" ] && binary="$binary.exe"
    version="$("$GO" version -m "$binary" 2>/dev/null | awk '$1 == "mod" && $2 == "github.com/letsencrypt/pebble/v2" { print $3 }')"
    certs="$("$GO" env GOMODCACHE)/github.com/letsencrypt/pebble/v2@$version/test/certs"
    case "$(uname -s)" in
      MINGW* | MSYS* | CYGWIN* | Windows_NT) certs="$(cygpath -m "$certs")" ;;
    esac
    return 0
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  acquire_pebble
  exit $?
else
  acquire_pebble
  return $?
fi
