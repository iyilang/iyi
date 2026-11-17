#!/usr/bin/env bash
# Compare a linked root's output and status after both programs have run.
pipeline_outputs_equal() {
  local typed_status="$1" hosted_status="$2" typed_output="$3" hosted_output="$4"
  [ "$typed_status" = "$hosted_status" ] && cmp -s "$typed_output" "$hosted_output"
}

# The first failing phase is the root headline, not the last passing phase.
pipeline_first_refusal() {
  awk '/: fail: / { print; exit }' "$1"
}
