#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_DIR}"

if [[ ! -x .build/stale_store_concurrency ]]; then
  echo "Building .build/stale_store_concurrency..."
  ./bin/crystal build -o .build/stale_store_concurrency bench/stale_store_concurrency.cr
fi

TMP_STORE=$(mktemp -d /tmp/stale_store_concurrency.XXXXXX)
trap 'rm -rf "${TMP_STORE}"' EXIT

echo "Starting 2 concurrent processes each recording 1000 receipts..."
.build/stale_store_concurrency run "${TMP_STORE}" 1 1000 &
PID1=$!
.build/stale_store_concurrency run "${TMP_STORE}" 2 1000 &
PID2=$!

wait "${PID1}"
wait "${PID2}"

echo "Verifying every record file is parseable and seq is correct..."
.build/stale_store_concurrency verify "${TMP_STORE}" 2000

echo "Row 21 concurrency test PASSED: 2000 parseable records, seq=2000."
