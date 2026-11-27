#!/usr/bin/env bash
# Build an iyi tool that imports the LLVM bridge with this host's version, targets, and link flags.
set -euo pipefail

. "$(dirname "$0")/../bench/lib/host.sh"
bridge_text=$(llvm_bridge_build_args)
bridge_args=()
while IFS= read -r arg; do bridge_args+=("$arg"); done <<< "$bridge_text"
exec "$1" build "${bridge_args[@]}" -o "$2" "$3"
