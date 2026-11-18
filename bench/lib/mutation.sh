#!/usr/bin/env bash
# Shared mutation proof for the selfhost gates (SPEC 3.8).
#
#   . "$REPO/bench/lib/mutation.sh"
#   prove_mutation     <label> <file> <old> <new> -- <check command...>
#   prove_mutation_all <label> <file> <old> <new> -- <check command...>
#
# Copies <file> aside, replaces <old> with <new> (literal text, not a pattern),
# then runs the check and requires a controlled failure.
#   prove_mutation     replaces the FIRST occurrence of <old>.
#   prove_mutation_all replaces EVERY occurrence, as sed's s/// does on each
#                      matching line. Use it where the mutation is meant to
#                      change every site the label names.
#   - check exits 1 -> prints "    caught: <label>", returns 0
#   - any other status -> prints "    FAIL: ...", returns 1
#   - <old> absent, or the patch changes nothing -> prints
#     "PATCH CHANGED NOTHING: this proves nothing", exits 3
#   - MUTATION_SKIP=1 in the environment -> no file is touched, prints
#     "    NOT RUN (MUTATION_SKIP=1, ...): <label>", returns 1. A gate run that
#     way shows its fixtures quickly and always ends red.
#
# The check runs as a background job in its own process group. The file is
# restored, and the copy aside removed, through traps on EXIT, INT and TERM,
# so an interrupt never leaves a mutated source behind. The traps that were
# set before the call (for example a WORK cleanup) are put back afterwards.
#
# The check is a command or a shell function. It must return 1 only when
# the mutated behavior is detected. Build failures and crashes are invalid;
# checks handle those explicitly, and other check-process statuses fail here.

_PM_ARMED=0
_PM_FILE=""
_PM_BACKUP=""
_PM_CHILD=""
_PM_MONITOR=0
_PM_SAVED_EXIT=""
_PM_SAVED_INT=""
_PM_SAVED_TERM=""

_prove_mutation_restore() {
  if [ -n "$_PM_CHILD" ]; then
    if [ "$_PM_MONITOR" -eq 1 ]; then
      kill -TERM -- "-$_PM_CHILD" 2>/dev/null || true
    else
      kill -TERM "$_PM_CHILD" 2>/dev/null || true
    fi
    wait "$_PM_CHILD" 2>/dev/null || true
    _PM_CHILD=""
  fi
  if [ -n "$_PM_BACKUP" ] && [ -f "$_PM_BACKUP" ]; then
    cp "$_PM_BACKUP" "$_PM_FILE"
    rm -f "$_PM_BACKUP"
  fi
  _PM_BACKUP=""
}

_prove_mutation_disarm() {
  [ "$_PM_ARMED" -eq 1 ] || return 0
  _prove_mutation_restore
  trap - EXIT INT TERM
  [ -n "$_PM_SAVED_EXIT" ] && eval "$_PM_SAVED_EXIT"
  [ -n "$_PM_SAVED_INT" ] && eval "$_PM_SAVED_INT"
  [ -n "$_PM_SAVED_TERM" ] && eval "$_PM_SAVED_TERM"
  _PM_ARMED=0
}

_prove_mutation_signal() {
  _prove_mutation_disarm
  exit "$1"
}

_prove_mutation_arm() {
  _PM_FILE="$1"
  _PM_BACKUP="$2"
  _PM_SAVED_EXIT="$(trap -p EXIT)"
  _PM_SAVED_INT="$(trap -p INT)"
  _PM_SAVED_TERM="$(trap -p TERM)"
  _PM_ARMED=1
  trap '_prove_mutation_restore' EXIT
  trap '_prove_mutation_signal 130' INT
  trap '_prove_mutation_signal 143' TERM
}

# _prove_mutation_run <all|first> <label> <file> <old> <new> -- <check...>
_prove_mutation_run() {
  local mode="$1" label="$2" file="$3" old="$4" new="$5"
  shift 5
  if [ "${1:-}" != "--" ]; then
    echo "prove_mutation: expected -- before the check command ($label)" >&2
    exit 2
  fi
  shift
  if [ "$#" -eq 0 ]; then
    echo "prove_mutation: no check command given ($label)" >&2
    exit 2
  fi

  # MUTATION_SKIP=1 is for a quick look at a gate's fixtures while working: no mutation is applied, and each proof
  # answers as NOT caught, so the gate ends red by its own count and a quick run can never be read as a pass.
  if [ "${MUTATION_SKIP:-0}" = 1 ]; then
    echo "    NOT RUN (MUTATION_SKIP=1, so this gate cannot pass): $label"
    return 1
  fi

  # The edit is made by perl, on bytes, with index and substr: literal text, never a pattern. It was a bash
  # substitution on the whole file held in a variable, which had two defects under bash 3.2 (darwin's /bin/bash, the
  # bash of a macos runner). A quoted replacement kept its quotes as text, so every mutation arrived wrapped in '"'
  # and a patch that changes nothing changed two bytes and ran as a mutation. And the substitution is quadratic
  # there: 2.4 seconds on a 5 KB file, more than a minute on an 82 KB one, about three quarters of an hour on the
  # parser, per mutation; the darwin gates never finished.
  local patched backup log rc=0 monitor_was_on=0 edit_rc=0
  patched="$(mktemp)"
  MUT_OLD="$old" MUT_NEW="$new" MUT_MODE="$mode" perl -e '
    local $/; binmode STDIN; binmode STDOUT;
    my $s = <STDIN>; my $old = $ENV{MUT_OLD}; my $new = $ENV{MUT_NEW};
    exit 4 if length($old) == 0 || index($s, $old) < 0;
    my ($out, $pos, $i) = ("", 0, 0);
    while (($i = index($s, $old, $pos)) >= 0) {
      $out .= substr($s, $pos, $i - $pos) . $new;
      $pos = $i + length($old);
      last unless $ENV{MUT_MODE} eq "all";
    }
    print $out . substr($s, $pos);
  ' < "$file" > "$patched" || edit_rc=$?
  if [ "$edit_rc" -eq 4 ]; then
    rm -f "$patched"
    echo "PATCH CHANGED NOTHING: this proves nothing ($label: text not found in $file)"
    exit 3
  fi
  if [ "$edit_rc" -ne 0 ]; then
    rm -f "$patched"
    echo "prove_mutation: the edit of $file could not be made ($label: perl exit $edit_rc)" >&2
    exit 2
  fi
  if cmp -s "$file" "$patched"; then
    rm -f "$patched"
    echo "PATCH CHANGED NOTHING: this proves nothing ($label: replacement left $file unchanged)"
    exit 3
  fi

  backup="$(mktemp)"
  cp "$file" "$backup"
  log="$(mktemp)"

  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  _PM_MONITOR=1
  _prove_mutation_arm "$file" "$backup"
  cat "$patched" > "$file"
  rm -f "$patched"

  { "$@" > "$log" 2>&1 & } 2>/dev/null
  _PM_CHILD=$!
  wait "$_PM_CHILD" || rc=$?
  _PM_CHILD=""

  _prove_mutation_disarm
  [ "$monitor_was_on" -eq 1 ] || set +m
  _PM_MONITOR=0

  if [ "$rc" -eq 1 ]; then
    echo "    caught: $label"
    awk '/^decisive: / { print "      " $0; exit }' "$log"
    rm -f "$log"
    return 0
  fi
  if [ "$rc" -eq 0 ]; then
    echo "    FAIL: mutation was not caught: $label"
  else
    echo "    FAIL: mutation check exited $rc instead of 0 or 1: $label"
  fi
  echo "    check exit: $rc"
  echo "    check output:"
  sed 's/^/      /' "$log"
  rm -f "$log"
  return 1
}

prove_mutation() {
  _prove_mutation_run first "$@"
}

prove_mutation_all() {
  _prove_mutation_run all "$@"
}

# A panic identifies a compiler refusal only when its source site is known.
# Library panics omit that site; signals and other raises never count.
refusal_site() {
  awk '/^  at .*:[0-9]+$/ {
    site = substr($0, 6); gsub(/\\/, "/", site)
    i = index(site, "src/compiler/")
    if (i == 1 || (i > 1 && substr(site, i - 1, 1) == "/")) print substr(site, i)
    exit
  }' "$1"
}

refusal_note() {
  local site
  site="$(refusal_site "$2")"
  printf 'exit %s: %s%s' "$1" "$(awk 'NR == 1 { print; exit }' "$2")" "${site:+ (at $site)}"
}

# port_refusal <status> <stderr-file>
# Match refuse_port or MainVisitor's refusal raises in the source used to
# build this mutant. An index, cast, BUG or driver panic is not a refusal.
port_refusal() {
  local first site text
  [ "$1" -eq 1 ] || return 1
  first="$(awk 'NR == 1 { print; exit }' "$2")"
  case "$first" in
    "Error: "*) return 0 ;;
    "iyi: panic: "*) ;;
    *) return 1 ;;
  esac
  site="$(refusal_site "$2")"
  case "$site" in
    src/compiler/semantic/main_visitor.iyi:*) ;;
    *) return 1 ;;
  esac
  text="$(awk -v n="${site##*:}" 'NR == n { sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print; exit }' "$REPO/${site%:*}")"
  [ "$text" = 'raise(message) unless @total || @speculation.depth > 0' ] || [ "$text" = 'raise(reason)' ]
}

# expected_refusal <status> <stderr-file> <source-file|refuse_port> <message-ERE>
# A proof may name another refusal path and its expected diagnostic.
expected_refusal() {
  local first message site
  [ "$1" -eq 1 ] || return 1
  first="$(awk 'NR == 1 { print; exit }' "$2")"
  if [ "$3" = refuse_port ]; then
    case "$first" in "Error: "*) message="${first#Error: }" ;; *) return 1 ;; esac
  else
    case "$first" in "iyi: panic: "*) message="${first#iyi: panic: }" ;; *) return 1 ;; esac
    site="$(refusal_site "$2")"
    [ "${site%:*}" = "$3" ] || return 1
  fi
  printf '%s\n' "$message" | grep -Eq -- "$4"
}
