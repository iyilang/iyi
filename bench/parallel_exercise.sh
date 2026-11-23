#!/usr/bin/env bash
# Drives bench/parallel_exercise.iyi: tasks across cores (SPEC.md III.4.13).
#
#     bash bench/parallel_exercise.sh
#
# Eight steps; the last three are failure proofs, because a gate that
# cannot fail is not a gate:
#
# The formerly timing-decided and conditional copies force the relevant
# queue, monitor, poll, switch, or library-loop state. A hooked control
# uses the same observation as its mutant. Close placement uses the
# corresponding healthy program as its control.
# Each copy gets one run; a progress hang is not a successful catch.
# Every progress failure ends the run once, through the shared one-ending block.
# A scan (below the fixture checks) refuses any other exit, raw write, svc or
# FAIL: sentence in a fixture or a generated copy, and probes each refusal.
# Socket and deep-frame movement are forced before their larger exercises.
# Speed and tight-loop timings are performance information, sampled once.
#
# State visibility limit: IyiFiber.state is a plain enum, and its writers do
# not share one lock. The registry walks hold IyiRuntimeLock for list links;
# they do not make the state field atomic. The cancel, close, channel-park,
# deep, balance, handoff, backstop, held-io, and Windows completion witnesses
# read that field, through those walks and the copy hooks, so they prove
# nothing about its visibility. Their target waits stay parked until the test
# releases them, and a missed observation ends as a named status-76 progress
# hang, never as a caught mutant. Poller and panic-exit's reader waits read
# the reader's atomic listed_on and on_cpu words instead, and a reader on the
# main thread is checked under the io list's lock.
#
#   1. The exercise holds every property, plain and --release: parallel
#      tasks start on the pool and on more than one worker, never on the
#      spawning thread, a thousand run exactly once, an atomic count loses
#      nothing, channels carry values across threads once each and in each
#      sender's order, `take_now` and `put_now` from every worker at once
#      lose and repeat nothing, a cancel reaches a task asleep, parked on a
#      channel, or still waiting in the pool, a panic stops at the task's
#      boundary, idle workers steal, collections keep the workers' lists,
#      the typed group answers, and wakes that race across workers are
#      neither lost nor doubled: selects parked on two channels and a
#      deadline take each value once, a cancel landing as a task parks
#      ends it, and turns handed through `park_on` and `wake_on` are
#      every one taken.
#   2. bench/parallel_migrate.iyi exercises what a task keeps through a
#      move, plain and --release: its stack's lists through collections,
#      thread-locals after a park and a loop, its socket's bytes, a cancel
#      and a close from a sibling or the main thread, and frames 120 KiB
#      deep. Keyed copies force the relevant migration and hand-off
#      decisions. Balance and wake timings are measured, not judged; the
#      monitor can call for a hand-off after the waker stops calling.
#      On Linux and darwin an answer sent while the reader's worker is held
#      is read on another worker before that hold ends; and a task joining
#      a thread leaves its worker to its child. On Windows,
#      bench/completions_taken.iyi checks the shared completion port: an
#      answer is read on another worker while the reader's worker is held.
#      The process's priority boost is off once the pool has started.
#      bench/parallel_preempt.iyi checks preemption at loop back-edges
#      (SPEC.md III.4.13, part 9): a short task and a sleeper run beside a
#      computing task; a dedicated fast request is served while a slow
#      handler stays active; a preempted task keeps its unit's token; a task
#      switched in after one that held its worker past a look begins its own
#      quantum; tight loops and their `@[NoPreempt]` twins give the same
#      answers, and the release build's IR shows each tight loop's checks
#      reading the word through the thread pointer, without calling its
#      accessor. Latencies are measured and printed with `measure:`, never
#      judged: the ticker, the poller's fast response, the monitor's look
#      interval (4 to 10.5 ms, 8 on Windows) and quantum, and the tight-loop
#      timing ratios. What is forced is the decision: the monitor's raise after
#      one unchanged look (the control) and after three (the slowturn mutant,
#      which is caught), a Windows monitor that falls back to the semaphore
#      (coarse, also caught), and the requested tick, pinned by the anchors the
#      copies must match on PREEMPT_TICK_NS. Its failure proofs are with step
#      7's: a `@[NoPreempt]` loop, a monitor that never raises the word, a check
#      that calls the accessor (darwin and Windows), a slow half that does not
#      poll, a word left raised for the task before, and a preempted task that
#      gives its unit's token away.
#   3. The binary keeps the dependency floor the concurrency gate holds,
#      plus `environ`, the C runtime's table `IYI_WORKERS` is read from.
#   4. A capacity witness holds K tasks on K workers together. CPU-bound
#      tasks report wall time, speed ratio, and average threads at once.
#      OPEN: the original 0.6 x K time-weighted occupancy guarantee is not
#      proved; those samples are measure: information, not healthy verdicts.
#   5. A deadlock across threads - a parallel task waiting on a channel
#      nobody sends on - is named, not hung. And bench/panic_exit.iyi
#      ends the process with tasks parked on the poller, on twelve
#      workers and on the main thread alone: a task's panic and the main
#      task's panic each exit 1, and a task's `exit(3)` exits 3, inside
#      the program's watchdog's 5 s.
#   6. `Share` gates the parallel block at compile time: a captured
#      `Array`, a `Channel` of arrays, a local assigned after the spawn, and
#      a loop's local are refused, each by name. A block that reaches a
#      constant that is not Share through a def it calls is refused with
#      the path (SPEC.md III.4.5), and told the claim the compiler would
#      prove; its copy with the constant marked `@[SafeReach]` builds
#      clean, the constant built at startup and only read, which the
#      compiler proves (bench/safe_reach.sh holds what it refuses).
#      Two blocks reaching it are one refusal, counting the other.
#   7. Failure proofs against broken copies of the runtime, each caught at
#      the named check: a cross-thread wake that does not ring (a lost
#      wakeup), a steal that leaves the task in its victim's queue (a task
#      handed out twice), a cancel that is never delivered to the thread a
#      sleeping task is on, a cancel that skips tasks still waiting in the
#      pool (a cancelled task run as if it were not), a cancel that misses
#      an instrumented io-wait branch after the reader registers,
#      `take_now` and `put_now` without their channel's lock, a
#      rendezvous hand that never marks the select it woke, a cancel the
#      park it lands in never looks for, and `park_on` looking at its word
#      outside its list's lock; the race
#      step's add made a plain load and store, which loses adds only when
#      tasks really run at the same instant; and for the moves of step 2 -
#      a thread-local read as it was before a park, one read as it was
#      before a loop whose back-edge check moved the task, a collector that
#      skips a fiber on its way between workers, an io wait a cancel cannot
#      find, a close posted to nobody, a read made on the thread that
#      closes its socket, a pool that never steals a started task, tasks
#      woken back onto the worker they parked on as they were before tasks
#      moved, a hand-off that calls no idle worker, one that marks its call
#      and rings nobody, a monitor that calls nobody for a held worker's
#      ring, a monitor that calls nobody for a held worker's poller, and a
#      join held in the kernel; and on Windows
#      a port whose packets only the worker their task parked on runs, and
#      a pool that leaves the priority boost on.
#      Coarse uses a structural timer decision. Slice, recursion, library
#      loops, std calls and tokenless use keyed eligible decisions; a refused
#      check waits in its slow path or exits as a progress failure.
#      Five simultaneous endings, an unclaimed copy, a runtime-hook race,
#      and withheld placement arrivals check the watchdog failure path itself.
#   8. Failure proof: a pool held to one worker is refused by the capacity
#      witness. The speed parser and at-once floor also have a separate
#      one-worker negative check; neither measured value gates a healthy run.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)" || { echo "FAIL: gate: setup: could not resolve the repository"; exit 76; }
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)" || { echo "FAIL: gate: setup: could not create a temporary directory"; exit 76; }

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

. "$REPO/bench/floor_base.sh" || { echo "FAIL: gate: setup: could not load the dependency-floor helpers"; exit 76; }

cd "$WORK" || { echo "FAIL: gate: setup: could not enter the temporary directory"; exit 76; }

step() { echo "== $1"; }
child_progress_status() { # label, status, output
  if [ "$2" -eq 76 ]; then cat "$3"; exit 76; fi
  if [ "$2" -eq 124 ] || [ "$2" -eq 137 ]; then
    echo "FAIL: $1: progress hang: the shell emergency timeout stopped the run (exit $2)"
    exit 76
  fi
}

one_ending() { # output, exact FAIL line, status
  [ "$3" -eq 76 ] && [ "$(grep -cxF -- "$2" "$1")" -eq 1 ] && [ "$(grep -c '^FAIL: ' "$1")" -eq 1 ]
}
emergency_timeout() { # name, child status
  if [ "$2" -eq 124 ] || [ "$2" -eq 137 ]; then
    echo "FAIL: $1: progress hang: the shell emergency timeout stopped the run (exit $2)"
    exit 76
  fi
}

# The cores this process may run on, as the pool counts them.
cores() {
  case "$(uname -s)" in
    Darwin) sysctl -n hw.ncpu ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT) echo "${NUMBER_OF_PROCESSORS:-1}" ;;
    *) nproc ;;
  esac
}
if ! CORES="$(cores)" || [[ ! "$CORES" =~ ^[1-9][0-9]*$ ]]; then
  echo "FAIL: cores: setup: could not determine a positive processor count"; exit 76
fi

# A host with fewer cores than a proof needs fails rather than skipping it.
need_cores() { # cores, what the proof needs
  if [ "$CORES" -lt "$1" ]; then echo "FAIL: cores: setup: this host has $CORES cores but needs $1: $2"; exit 76; fi
}

# Every running runtime copy receives exactly the fixture's ending block.
run_end_block() { # fixture file
  awk '/^    # one ending: begin$/ { begun++; on = 1; next }
/^    # one ending: end$/ { ended++; on = 0; next }
on { print }
END { if (begun != 1 || ended != 1) exit 3 }' "$1"
}
if ! RUN_END="$(run_end_block "$REPO/bench/parallel_exercise.iyi")" || [ -z "$RUN_END" ]; then
  echo "FAIL: one ending: setup: bench/parallel_exercise.iyi has no single one-ending block"; exit 76
fi

# The one-ending scan. Outside the shared block, a fixture may not call exit or
# abort in any spelling (Process.exit and LibC.abort included), write raw bytes,
# use svc, or name a FAIL: sentence unless its line calls end_run, fail,
# progress_hang, setup_* or held_exit with that sentence as an argument, and the
# line holds only one FAIL: sentence. Lines are checked one at a time, so a call
# that spans lines is refused. The same rules check the lines a generated copy
# adds (scan_added). The rules are awk, loaded with -f; a refusal prints one
# FAIL: line and the scan exits 76.
cat > "$WORK/one_ending_rules.awk" <<'AWK'
function refuse(kind) {
  printf "FAIL: one ending: setup: %s line %d has %s outside the run's one-ending block\n", name, FNR, kind
  exit 76
}
function check(text) {
  if (text ~ /^[ \t]*#/) return
  if (text ~ /LibC\.(_?exit|abort|ExitProcess|TerminateProcess)\(/) refuse("a libc exit")
  if (text ~ /__iyi_exit\(/) refuse("an __iyi_exit call")
  if (text ~ /(^|[^A-Za-z0-9_])_?exit\(/) refuse("an exit call")
  if (text ~ /(^|[^A-Za-z0-9_])abort\(/) refuse("an abort call")
  if (text ~ /(^|[^A-Za-z0-9_])svc([^A-Za-z0-9_]|$)/) refuse("an svc instruction")
  if (text ~ /__iyi_write\(|LibC\.write\(/) refuse("a raw write")
  if (text ~ /FAIL: / && (text !~ /(end_run|fail|progress_hang|setup_[A-Za-z_]*|held_exit)\([^";]*"FAIL: / || split(text, parts, "FAIL: ") != 2)) refuse("a FAIL: sentence that is not an argument of end_run, fail, progress_hang, setup_* or held_exit")
}
AWK
cat > "$WORK/one_ending_fixture.awk" <<'AWK'
/^    # one ending: begin$/ { inblock = 1; next }
/^    # one ending: end$/ { inblock = 0; next }
inblock { next }
{ check($0) }
AWK
cat > "$WORK/one_ending_added.awk" <<'AWK'
FNR == NR { seen[$0]++; next }
{ if (seen[$0] > 0) { seen[$0]--; next } check($0) }
AWK
# Prints the first refusal, if any, and returns its status.
scan_fixture() { # fixture file
  awk -v name="$(basename "$1")" -f "$WORK/one_ending_rules.awk" -f "$WORK/one_ending_fixture.awk" "$1"
}
# The lines GENERATED adds to ORIGINAL, scanned by the same rules.
scan_added() { # original, generated, label
  awk -v name="$3" -f "$WORK/one_ending_rules.awk" -f "$WORK/one_ending_added.awk" "$1" "$2"
}
for fixture in parallel_exercise parallel_migrate parallel_preempt parallel_preempt_lib completions_taken; do
  if ! block="$(run_end_block "$REPO/bench/$fixture.iyi")" || [ "$block" != "$RUN_END" ]; then
    echo "FAIL: one ending: setup: bench/$fixture.iyi's one-ending block is not bench/parallel_exercise.iyi's"; exit 76
  fi
  if ! out="$(scan_fixture "$REPO/bench/$fixture.iyi")"; then
    printf '%s\n' "${out:-FAIL: one ending: setup: bench/$fixture.iyi could not be scanned}"; exit 76
  fi
done
echo "  the five fixtures keep every exit, raw write and FAIL: sentence inside their one-ending block"

step "one ending: the scan refuses each way out of the block, in a fixture and in a copy it generates"
# A probe line put before the fixture's STEPS list, or before the runtime's
# reschedule, must be refused by name at the probe's own line.
scan_mutant() { # label, probe line, what the scan names
  local m="$WORK/scan-$1.iyi" n out code want
  if ! PROBE="$2" awk '/^  STEPS = \[/ && !done { print ENVIRON["PROBE"]; done = 1 } { print }
END { if (!done) exit 3 }' "$REPO/bench/parallel_exercise.iyi" > "$m"; then
    echo "FAIL: scan: setup: the STEPS anchor is missing from bench/parallel_exercise.iyi"; exit 76
  fi
  n="$(awk -v key="scan_probe_$1" 'index($0, key) { print FNR; exit }' "$m")"
  out="$(scan_fixture "$m")"; code=$?
  want="FAIL: one ending: setup: scan-$1.iyi line $n has $3 outside the run's one-ending block"
  if [ "$code" -ne 76 ] || [ "$out" != "$want" ]; then
    echo "FAIL: scan: setup: the $1 probe was not refused at its line: exit $code: $out"; exit 76
  fi
  echo "  scan mutant $1 exits 76 at \"${want#FAIL: }\""
}
scan_mutant_added() { # label, probe line, what the scan names
  local g="$WORK/scan-added-$1.iyi" n out code want
  if ! PROBE="$2" awk '/^  def self.reschedule : Nil$/ && !done { print ENVIRON["PROBE"]; done = 1 } { print }
END { if (!done) exit 3 }' "$REPO/src/iyi/concurrency.iyi" > "$g"; then
    echo "FAIL: scan: setup: the reschedule anchor is missing from src/iyi/concurrency.iyi"; exit 76
  fi
  n="$(awk -v key="scan_probe_$1" 'index($0, key) { print FNR; exit }' "$g")"
  out="$(scan_added "$REPO/src/iyi/concurrency.iyi" "$g" "scan-added-$1.iyi")"; code=$?
  want="FAIL: one ending: setup: scan-added-$1.iyi line $n has $3 outside the run's one-ending block"
  if [ "$code" -ne 76 ] || [ "$out" != "$want" ]; then
    echo "FAIL: scan: setup: the added $1 probe was not refused at its line: exit $code: $out"; exit 76
  fi
  echo "  scan mutant added-$1 exits 76 at \"${want#FAIL: }\""
}
scan_mutant libc '  def scan_probe_libc : Nil; ::LibC.exit(1); end' 'a libc exit'
scan_mutant iyi '  def scan_probe_iyi : Nil; __iyi_exit(1); end' 'an __iyi_exit call'
scan_mutant exit '  def scan_probe_exit : Nil; exit(1); end' 'an exit call'
scan_mutant svc '  def scan_probe_svc : Nil; asm("svc #0x80" :: "{x16}"(1_i64) : "memory" : "volatile"); end' 'an svc instruction'
scan_mutant write '  def scan_probe_write : Nil; __iyi_write(1, nil, 0_u64); end' 'a raw write'
scan_mutant literal '  def scan_probe_literal : Nil; print "FAIL: probe\n"; end' 'a FAIL: sentence that is not an argument of end_run, fail, progress_hang, setup_* or held_exit'
scan_mutant pexit '  def scan_probe_pexit : Nil; Process.exit(1); end' 'an exit call'
scan_mutant abort '  def scan_probe_abort : Nil; abort("probe"); end' 'an abort call'
scan_mutant libcabort '  def scan_probe_libcabort : Nil; ::LibC.abort(1); end' 'a libc exit'
scan_mutant shared '  def scan_probe_shared : Nil; fail("probe"); print "FAIL: probe\n"; end' 'a FAIL: sentence that is not an argument of end_run, fail, progress_hang, setup_* or held_exit'
scan_mutant_added libc '  def scan_probe_libc : Nil; ::LibC.exit(1); end' 'a libc exit'
scan_mutant_added iyi '  def scan_probe_iyi : Nil; __iyi_exit(1); end' 'an __iyi_exit call'
scan_mutant_added exit '  def scan_probe_exit : Nil; exit(1); end' 'an exit call'
scan_mutant_added svc '  def scan_probe_svc : Nil; asm("svc #0x80" :: "{x16}"(1_i64) : "memory" : "volatile"); end' 'an svc instruction'
scan_mutant_added write '  def scan_probe_write : Nil; __iyi_write(1, nil, 0_u64); end' 'a raw write'
scan_mutant_added literal '  def scan_probe_literal : Nil; print "FAIL: probe\n"; end' 'a FAIL: sentence that is not an argument of end_run, fail, progress_hang, setup_* or held_exit'
scan_mutant_added pexit '  def scan_probe_pexit : Nil; Process.exit(1); end' 'an exit call'
scan_mutant_added abort '  def scan_probe_abort : Nil; abort("probe"); end' 'an abort call'
scan_mutant_added libcabort '  def scan_probe_libcabort : Nil; ::LibC.abort(1); end' 'a libc exit'
scan_mutant_added shared '  def scan_probe_shared : Nil; fail("probe"); print "FAIL: probe\n"; end' 'a FAIL: sentence that is not an argument of end_run, fail, progress_hang, setup_* or held_exit'

# ── 1. The exercise, twice ────────────────────────────────────────────────
for build in plain release; do
  step "every property, $build build"
  flag=""
  [ "$build" = release ] && flag="--release"
  if ! "$IYI" build $flag "$REPO/bench/parallel_exercise.iyi" -o "exercise-$build" > "build-$build.log" 2>&1; then
    echo "FAIL: exercise: setup: the $build exercise failed to build"; tail -20 "build-$build.log"; exit 76
  fi
  timeout -k 5 600 "./exercise-$build" > "answers-$build.txt" 2>&1
  code=$?
  child_progress_status exercise "$code" "answers-$build.txt"
  if [ "$code" -ne 0 ] || ! grep -q 'every property held' "answers-$build.txt"; then
    echo "the exercise failed (exit $code):"; cat "answers-$build.txt"; exit 1
  fi
  if grep -q 'a done fiber was scheduled' "answers-$build.txt"; then
    echo "the exercise scheduled a finished fiber:"; cat "answers-$build.txt"; exit 1
  fi
  grep -v '^iyi: panic: parallel boom' "answers-$build.txt" | sed 's/^/  /'
done

# ── 2. What a move keeps, twice ───────────────────────────────────────────
# The migration exercises use four workers.
MIGRATE_STEPS="channels sockets cancel closes deep loops balance backstop heldio join"
need_cores 4 "the migration exercises use four workers"
# The handoff step runs separately. Sample host load only as context, not
# as a condition on its verdict. Linux and darwin average runnable threads
# over ten samples; Windows reads processor usage and its ready queue.
host_load() {
  case "$(uname -s)" in
    Linux)
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        grep '^procs_running ' /proc/stat
        sleep 0.1
      done | awk '{ sum += $2 - 1 } END { if (NR) printf "%.1f\n", sum / NR }' ;;
    Darwin)
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        ps -axM | awk 'NR > 1 { for (i = 1; i < NF; i++) if ($i ~ /^R/ && $(i + 1) ~ /^[0-9]+T?$/) { n++; break } } END { print n - 1 }'
        sleep 0.1
      done | awk '{ sum += $1 } END { if (NR) printf "%.1f\n", sum / NR }' ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
      powershell -NoProfile -Command '$c = (Get-Counter "\Processor(_Total)\% Processor Time","\System\Processor Queue Length" -SampleInterval 1 -MaxSamples 1).CounterSamples; [string]::Format([cultureinfo]::InvariantCulture, "{0:F1}", $c[0].CookedValue * [Environment]::ProcessorCount / 100 + $c[1].CookedValue)' 2> /dev/null | tr -d '\r' ;;
  esac
}
for build in plain release; do
  step "what a task keeps when it resumes on another worker, $build build"
  flag=""
  [ "$build" = release ] && flag="--release"
  if ! "$IYI" build $flag "$REPO/bench/parallel_migrate.iyi" -o "migrate-$build" > "build-migrate-$build.log" 2>&1; then
    echo "FAIL: migrate: setup: the $build exercise failed to build"; tail -20 "build-migrate-$build.log"; exit 76
  fi
  # shellcheck disable=SC2086 # the steps are words
  timeout -k 5 600 "./migrate-$build" $MIGRATE_STEPS > "migrated-$build.txt" 2>&1
  code=$?
  child_progress_status migrate "$code" "migrated-$build.txt"
  if [ "$code" -ne 0 ] || ! grep -q 'every property held' "migrated-$build.txt"; then
    echo "the migration exercise failed (exit $code):"; cat "migrated-$build.txt"; exit 1
  fi
  sed 's/^/  /' "migrated-$build.txt"
  load="$(host_load)"
  if [ -n "$load" ]; then
    echo "  measure: handoff host load $load on $CORES cores"
  fi
  timeout -k 5 300 "./migrate-$build" handoff > "handed-$build.txt" 2>&1
  code=$?
  child_progress_status handoff "$code" "handed-$build.txt"
  if [ "$code" -ne 0 ] || ! grep -q 'every property held' "handed-$build.txt"; then
    echo "the hand-off step failed (exit $code):"; cat "handed-$build.txt"; exit 1
  fi
  grep -v 'every property held' "handed-$build.txt" | sed 's/^/  /'
done
# ── 2a. Windows' one completion port, twice ──────────────────────────────
# bench/completions_taken.iyi at twelve workers: the reader's owner holds
# on a release word, and a healthy read finishes on another worker before
# release. The mutant exits at the armed reader's homebound dispatch, not
# at a later read. The process's priority boost is off once the pool starts.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    for build in plain release; do
      step "the process's one completion port and its boost, $build build"
      flag=""
      [ "$build" = release ] && flag="--release"
      if ! "$IYI" build $flag "$REPO/bench/completions_taken.iyi" -o "taken-$build" > "build-taken-$build.log" 2>&1; then
        echo "FAIL: taken: setup: the $build exercise failed to build"; tail -20 "build-taken-$build.log"; exit 76
      fi
      timeout -k 5 300 "./taken-$build" boost taken --workers=12 > "taken-$build.txt" 2>&1
      code=$?
      child_progress_status taken "$code" "taken-$build.txt"
      if [ "$code" -ne 0 ] || ! grep -q 'every property held' "taken-$build.txt"; then
        echo "the completion port exercise failed (exit $code):"; cat "taken-$build.txt"; exit 1
      fi
      grep -v 'every property held' "taken-$build.txt" | sed 's/^/  /'
    done ;;
  *)
    step "the process's one completion port and its boost"
    echo "  Windows' alone: a poller here is the waiting worker's epoll or kqueue" ;;
esac

# ── 2b. Preemption at loop back-edges, twice ─────────────────────────────
# bench/parallel_preempt.iyi: a short task and a sleeper run beside a
# computing task; a fast request is served while a slow handler stays
# active; a preempted task keeps its unit's token; a task switched in is not
# given up on the word raised for the one before it; tight loops and their
# `@[NoPreempt]` twins must answer alike. The monitor's look interval and
# quantum, the poller's fast response and the timing ratios are printed as
# information. The release build's IR gates the checks: they read the word
# through the thread pointer.
PREEMPT_WORKERS=8
[ "$CORES" -lt 8 ] && PREEMPT_WORKERS="$CORES"
# The server shape's clients are the program's own main thread, which on
# a machine of few cores, by every sign, waits for a core behind workers
# holding all of them: on a 4-core GitHub Windows runner, 4 workers made
# the slowest fast request 64 to 99 ms, 760 to 897 of 11,200 over 20 ms,
# with the monitor's tick at 5 ms and at the system timer's alike, and 3
# workers made it 36 to 49 ms, 119 to 142 over 20. darwin's 3 workers on
# 3 cores made it 26 to 50 ms.
#
# Three left the main thread one core and none for anything else the
# machine runs. GitHub's 4-core Windows runners come in two speeds: the
# job's runtime exercises take 486 to 658 s or 688 to 738 s, and on the
# slower the plain `spin` runs a sixth slower than its calibration (the
# period step's 111 to 121 looks, where the faster takes 86 to 99). There
# the plain build's server step read 36 to 63 ms, 286 to 427 over 20, in
# 13 jobs, then 157 and 159 ms, 2753 and 1682 over (CI jobs 123312302895
# and 123350279733); a commit master has since merged read 102 ms, 2504
# over, with its ticker 61 ms late (123170544267). Windows 11, 12 logical
# processors (the user's machine), held to 4 by `start /affinity F` with
# a shell loop busy on one of them, made the same shape: 3 workers 59 to
# 104 ms, 914 to 1364 over 20, in 24 runs, master's binary and this one
# alike, the poller step before it or not; 2 workers 26 to 31 ms, 123 to
# 300 over, in 20. So Windows was left two cores, the main thread's and a
# spare: on 2 workers CI read 27 to 31 ms plain, 409 to 458 over,
# and 27 to 37 release, 250 to 303 over, in four jobs, three of them on
# the slower runner (123506061763, 123575207812, 123639425845; and
# 123702042367). The 4 slow connections still outnumber the workers, so
# a fast request is answered beside them only by a preemption. On 2
# workers master then failed at 83 ms on the slower runner (job
# 124117601245). Traced on that Windows 11 machine, held to 4 with one
# busy, its slowest requests were not waiting for a core: each was a fast
# task given up at its first back-edge on the word raised for the task
# before it, which the switch now lowers (`IyiScheduler.switch_to`, and
# the fresh step). There, master's 20 runs each read 24 to 43 ms plain
# and 22 to 38 release, and the lowered word's 23 to 29 and 22 to 31.
#
# darwin's three-core runners, where 3 workers took every core, then
# starved the same way: 24 to 46 ms in the 13 macos-14 and macos-15 runs
# in CI's logs, and then 87 and 85 ms, 356 and 138 over 20, in two of
# the three macos-15 runs of master 7cdb1271a's soak (jobs 124862458037
# and 124885593220; the third read 44 ms, 197 over). Left two cores
# there, 1 worker made it worse, not better: 54 to 100 ms, 2951 to 5466
# over 20, failing 4 of 10 runs (debug job 124913849625), as every fast
# request then waits behind the slow ones' turns on the one worker. So a
# machine of four cores or fewer runs 2 workers: two cores left on 4, one
# on 3. On 2 workers, ten debug runs on macos-15 read 37 to 55 ms
# plain, 654 to 1044 over 20, and 31 to 50 release, 542 to 1068 over, and
# windows-2025's 10 read 24 to 33 plain and 23 to 47 release (jobs
# 124922160678 and 124922160886); Linux here, 12 vCPUs held to 4 by
# `taskset`, read 32 and 33 ms. The 4 slow connections outnumber the
# workers, so a fast request is still answered only by a preemption.
[ "$CORES" -le 4 ] && [ "$PREEMPT_WORKERS" -gt 2 ] && PREEMPT_WORKERS=2
for build in plain release; do
  step "preemption at loop back-edges, $build build"
  flag=""
  [ "$build" = release ] && flag="--release --emit llvm-ir"
  # shellcheck disable=SC2086 # the flags are words
  if ! "$IYI" build $flag "$REPO/bench/parallel_preempt.iyi" -o "preempt-$build" > "build-preempt-$build.log" 2>&1; then
    echo "FAIL: preempt: setup: the $build exercise failed to build"; tail -20 "build-preempt-$build.log"; exit 76
  fi
  for run in "slice --workers=1" "unit --workers=1" "period --workers=1" "poller --workers=1" "fresh --workers=1" "server --workers=$PREEMPT_WORKERS"; do
    # shellcheck disable=SC2086 # the step and its count are words
    timeout -k 5 300 "./preempt-$build" $run > "preempted-$build.txt" 2>&1
    code=$?
    child_progress_status preempt "$code" "preempted-$build.txt"
    if [ "$code" -ne 0 ] || ! grep -q 'every property held' "preempted-$build.txt"; then
      echo "the preemption exercise failed at $run (exit $code):"; cat "preempted-$build.txt"; exit 1
    fi
    grep -v 'every property held' "preempted-$build.txt" | sed 's/^/  /'
  done
done
step "what the check costs a tight loop, release build"
timeout -k 5 300 ./preempt-release tight --workers=1 > tight.txt 2>&1
code=$?
child_progress_status tight "$code" tight.txt
if [ "$code" -ne 0 ] || ! grep -q 'every property held' tight.txt; then
  echo "the tight loops failed (exit $code):"; cat tight.txt; exit 1
fi
grep '^tight' tight.txt | sed 's/^/  /'

# The checks at the tight step's loops' back-edges in an IR file, as
# `--emit llvm-ir` writes it after they went in (`PreemptChecks`): the
# loops of bench/parallel_preempt.iyi's `spin`, `sum`, `sum_each` and
# `crc`, each `@[NoInline]` so that it is a function of its own. A check is
# the block that branches to a block calling `__iyi_preempt`, that block's
# one predecessor, and it reads the worker's word through the thread
# pointer - `%gs:off` on x86-64 Windows (address space 256), `%fs:off` on
# x86-64 Linux (257), `tpidrro_el0` on darwin arm64, `tpidr_el0` on arm64
# Linux - or by calling the word's thread-local accessor,
# `*IyiWorkers::preempt`, at every turn. darwin's entry block calls the
# accessor once for the offset, and is no check. A line per loop, and exit
# 1 at a loop that is not there, one with no check, and one with a check
# that does not read the thread pointer. The timing above cannot tell the
# accessor's checks from these: on the Windows runner of CI job
# 122792275988 they cost `sum` 1.776x and `each` 1.828x, where the thread
# pointer's cost them 1.049x and 1.108x, and the bound was twice.
tight_checks() { # IR file
  awk '
    BEGIN {
      split("spin sum sum_each crc", order, " ")
      for (i = 1; i <= 4; i++) wanted[order[i]] = 1
      split("%gs:off|%fs:off|tpidrro_el0|tpidr_el0|accessor|another way", kinds, "|")
    }
    /^define / {
      line = $0
      gsub(/\.3A\./, ":", line)
      gsub(/\.3C\./, "<", line)
      fn = ""
      if (match(line, /ParallelPreempt::[a-z_]+</)) {
        name = substr(line, RSTART + 17, RLENGTH - 18)
        if (name in wanted) { fn = name; found[fn] = 1; block = "%entry"; pred = "" }
      }
      next
    }
    fn == "" { next }
    /^}/ { fn = ""; next }
    /^[^ \t]/ {
      block = "%" substr($0, 1, index($0, ":") - 1)
      at = index($0, "; preds = ")
      pred = at ? substr($0, at + 10) : ""
      sub(/[ \t]+$/, "", pred)
      next
    }
    index($0, "call void @__iyi_preempt()") { checks[fn] = checks[fn] + 1; check[fn, checks[fn]] = pred; next }
    index($0, "@\"*IyiWorkers::preempt\"(") || index($0, "@.2A.IyiWorkers.3A..3A.preempt(") { how[fn, block] = "accessor"; next }
    how[fn, block] == "accessor" { next }
    /load volatile i64, ptr addrspace\(256\)/ { how[fn, block] = "%gs:off"; next }
    /load volatile i64, ptr addrspace\(257\)/ { how[fn, block] = "%fs:off"; next }
    /tpidrro_el0/ { how[fn, block] = "tpidrro_el0"; next }
    /tpidr_el0/ { how[fn, block] = "tpidr_el0"; next }
    END {
      for (i = 1; i <= 4; i++) {
        fn = order[i]
        if (!(fn in found)) { fails = fails "FAIL: tight checks: " fn " is not a function of the IR\n"; continue }
        n = checks[fn] + 0
        if (n == 0) { fails = fails "FAIL: tight checks: " fn " checks at no back-edge\n"; continue }
        split("", counts)
        for (k = 1; k <= n; k++) {
          kind = how[fn, check[fn, k]]
          if (kind == "") kind = "another way"
          counts[kind] = counts[kind] + 1
        }
        said = ""
        for (k = 1; k <= 6; k++) {
          kind = kinds[k]
          if (!(kind in counts)) continue
          word = kind == "accessor" ? "calling the accessor" : (kind == "another way" ? "reading the word another way" : "reading " kind)
          said = said ", " counts[kind] " " word
        }
        print fn ": " n " back-edge check" (n == 1 ? "" : "s") said
        if ("accessor" in counts && fails == "") fails = "FAIL: tight checks: " fn " calls the thread-local accessor *IyiWorkers::preempt at a back-edge\n"
        else if ("another way" in counts && fails == "") fails = "FAIL: tight checks: " fn ": " counts["another way"] " of " n " back-edge checks read the word neither through the thread pointer nor by the accessor\n"
      }
      printf "%s", fails
      exit (fails != "")
    }
  ' "$1"
}
step "how the tight loops' checks read the worker's word, release build"
if ! tight_checks preempt-release.ll > reads.txt 2>&1; then
  echo "the tight loops' checks are not the thread pointer's:"; cat reads.txt; exit 1
fi
sed 's/^/  /' reads.txt
if [ "$(uname -s)" = Linux ]; then
  echo "  the check on Linux never calls the accessor: \`-Dpreempt_check_accessor\` builds the same code"
fi

# ── 2c. Library calls and recursion, twice ───────────────────────────────
# Each call runs with a short task queued on its worker. Whether the short
# task runs inside the call is informational: any thread holding the runtime
# lock can make a check refuse a turn. Keyed copies in step 7 judge ordering.
# The release build writes its IR too, for the audit after.
for build in plain release; do
  step "library calls and recursion with a queued task, $build build"
  flag=""
  [ "$build" = release ] && flag="--release --emit llvm-ir"
  # shellcheck disable=SC2086 # the flags are words
  if ! "$IYI" build $flag "$REPO/bench/parallel_preempt_lib.iyi" -o "preemptlib-$build" > "build-preemptlib-$build.log" 2>&1; then
    echo "FAIL: preemptlib: setup: the $build exercise failed to build"; tail -20 "build-preemptlib-$build.log"; exit 76
  fi
  timeout -k 5 600 "./preemptlib-$build" sort copy rehash join regex json bcrypt fib --workers=1 > "preemptedlib-$build.txt" 2>&1
  code=$?
  child_progress_status preemptlib "$code" "preemptedlib-$build.txt"
  if [ "$code" -ne 0 ] || ! grep -q 'every property held' "preemptedlib-$build.txt"; then
    echo "the library preemption exercise failed (exit $code):"; cat "preemptedlib-$build.txt"; exit 1
  fi
  grep -v 'every property held' "preemptedlib-$build.txt" | sed 's/^/  /'
done

# A short copy's checks, in the release IR of bench/parallel_preempt_lib.iyi's
# `copy_bytes`, `Pointer#copy_from` as a function of its own. Its loop of
# runs checks between runs; a copy of one run or less takes no such loop.
# With the check at that loop's latch every copy read the word once,
# however short: a join of 1,000,000 short strings, two copies a string,
# read it three times a string, and cost 9.5 to 10.7% over the same
# program with the library unchecked (Linux here, release, load 3 to 4.5).
# So some path from the entry must reach a block that copies and go on to
# a return through no check. And on darwin, where what a check reads
# through is made by calling the word's accessor, that call must not be in
# the entry block: there `String::Builder#<<` paid it at every append, and
# the join cost 1.37x to 1.43x the unchecked one (an M2 Pro, load 3 to
# 17; `PreemptChecks.entry_value`). A check is the block that calls
# `__iyi_preempt` and the blocks that branch to it. Exit 1 at a function
# that is not there, one with no check at all - a long copy must still
# give its worker up - one whose every copy passes a check, and one whose
# entry calls the accessor.
copy_checks() { # IR file
  awk '
    function label(text) {
      if (substr(text, 1, 1) == "\"") return "%" substr(text, 1, index(substr(text, 2), "\"") + 1)
      return "%" substr(text, 1, index(text, ":") - 1)
    }
    /^define / {
      line = $0
      gsub(/\.3A\./, ":", line)
      gsub(/\.3C\./, "<", line)
      inside = (line ~ /ParallelPreemptLib::copy_bytes</)
      if (inside) { found = 1; block = "%entry"; blocks[block] = 1 }
      next
    }
    !inside { next }
    /^}/ { inside = 0; next }
    /^[^ \t]/ { block = label($0); blocks[block] = 1; next }
    {
      rest = $0
      while (match(rest, /label %("[^"]*"|[-a-zA-Z$._0-9]+)/)) {
        to = substr(rest, RSTART + 6, RLENGTH - 6)
        edges[block, ++count[block]] = to
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
    index($0, "call void @__iyi_preempt()") { slow[block] = 1; checks++ }
    /^  store / { stores[block] = 1 }
    /^  ret / { returns[block] = 1 }
    block == "%entry" && (index($0, "@\"*IyiWorkers::preempt\"(") || index($0, "@.2A.IyiWorkers.3A..3A.preempt(")) { accessor = 1 }
    END {
      if (!found) { print "FAIL: copy checks: copy_bytes is not a function of the IR"; exit 1 }
      if (checks == 0) { print "FAIL: copy checks: copy_bytes checks at no back-edge, so a long copy holds its worker"; exit 1 }
      for (b in blocks) {
        checking[b] = slow[b]
        for (k = 1; k <= count[b]; k++) if (slow[edges[b, k]]) checking[b] = 1
      }
      # From the entry through no check, and back from a return through none.
      queue[1] = "%entry"; reached["%entry"] = 1; n = 1
      for (i = 1; i <= n; i++) {
        b = queue[i]
        for (k = 1; k <= count[b]; k++) {
          to = edges[b, k]
          if (!(to in reached) && !checking[to]) { reached[to] = 1; queue[++n] = to }
        }
      }
      do {
        grew = 0
        for (b in blocks) {
          if (checking[b] || (b in leaves)) continue
          if (returns[b]) { leaves[b] = 1; grew = 1; continue }
          for (k = 1; k <= count[b]; k++) if (edges[b, k] in leaves) { leaves[b] = 1; grew = 1; break }
        }
      } while (grew)
      free = 0
      for (b in stores) if ((b in reached) && (b in leaves)) free++
      print "copy_bytes: " checks " check" (checks == 1 ? "" : "s") " between runs, " free " copying block" (free == 1 ? "" : "s") " a short copy reaches and returns from past none"
      if (free == 0) { print "FAIL: copy checks: every copy in copy_bytes passes a check before it returns, however short"; exit 1 }
      if (accessor) { print "FAIL: copy checks: the entry block of copy_bytes calls the thread-local accessor *IyiWorkers::preempt, which every copy then pays"; exit 1 }
    }
  ' "$1"
}
step "a short copy passes no check, release build"
if ! copy_checks preemptlib-release.ll > copies.txt 2>&1; then
  echo "a short copy checks:"; cat copies.txt; exit 1
fi
sed 's/^/  /' copies.txt

# The runtime's own functions, and every function they reach by a direct
# call, hold no check (bench/preempt_audit.py), read from the release
# build's IR. Python reads it, where there is a Python.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done
step "the runtime reaches no preemption check, release build"
[ -n "$PY" ] || { echo "FAIL: preempt audit: setup: Python is unavailable for the audit"; exit 76; }
if ! "$PY" "$REPO/bench/preempt_audit.py" preemptlib-release.ll > audit.txt 2>&1; then
  echo "the audit failed:"; cat audit.txt; exit 1
fi
sed 's/^/  /' audit.txt

# ── 2. The floor ──────────────────────────────────────────────────────────
# What the pool costs each platform, by name. Its workers are the
# runtime's own threads, so it pays what a thread pays and nothing else:
#
#   Linux    nothing of the pool's own: threads by raw `clone`, the stop by
#            `tgkill`, the doorbell by `eventfd2`, all syscalls. `environ`
#            is the one name, the C runtime's table `IYI_WORKERS` is read
#            from through `Program.env`.
#   darwin   the runtime's list (bench/thread_exercise.sh spells it out),
#            the thread floor's names a started thread costs -
#            `pthread_create`, `pthread_kill` and `sigaction` for the
#            thread and the stop, whose park is the futex already on the
#            list, and `close` for a retiring thread's kqueue
#            (`IyiScheduler.retire_thread`, linked with every thread
#            body) - and `_environ` for `IYI_WORKERS`. The doorbell is an
#            `EVFILT_USER` change through `kevent`, already on the list,
#            and the core count is `sysctlbyname("hw.ncpu")`, also already
#            there for the marker. No `pthread_join`: nothing joins a
#            worker.
#   Windows  kernel32 and the C runtime's DLLs; the doorbell is
#            `PostQueuedCompletionStatus`, kernel32's.
step "dependency floor: the pool costs what a thread costs, and the environment it reads IYI_WORKERS from"
NM=""
command -v nm >/dev/null 2>&1 && NM=nm
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    if ! DUMPBIN="$(find_dumpbin)" || [ -z "$DUMPBIN" ]; then
      echo "FAIL: dependency floor: setup: dumpbin is unavailable on Windows"; exit 76
    fi
    if ! dlls="$(set -o pipefail; pe_dlls exercise-plain.exe)" || [ -z "$dlls" ]; then
      echo "FAIL: dependency floor: setup: dumpbin did not read the exercise import table"; exit 76
    fi
    extra="$(extra_dlls "$FLOOR_DLLS_RUNTIME" "$dlls")"
    if [ -n "$extra" ]; then
      echo "the pool moved the Windows floor: the exercise imports $(echo $extra)"; exit 1
    fi
    echo "  imports: $(echo $dlls)"
    ;;
  Darwin)
    [ -n "$NM" ] || { echo "FAIL: dependency floor: setup: nm is unavailable"; exit 76; }
    runtime='___error __dyld_get_image_header __dyld_get_image_vmaddr_slide __tlv_bootstrap _backtrace _dladdr _dprintf _clock_gettime_nsec_np _exit _kevent _kqueue _mmap _mprotect _munmap _os_sync_wait_on_address _os_sync_wake_by_address_all _pthread_create _pthread_get_stackaddr_np _pthread_self _sigaction _sigaltstack _sysctlbyname _thread_switch _write'
    thread='_close _pthread_kill'
    pool='_environ'
    allowed="$(printf '%s\n' $runtime $thread $pool | sort -u)"
    for bin in exercise-plain exercise-release; do
      if ! symbols="$("$NM" -u "$bin")" || [ -z "$symbols" ]; then
        echo "FAIL: dependency floor: setup: nm could not read undefined symbols from $bin"; exit 76
      fi
      found="$(printf '%s\n' "$symbols" | sed -e 's/^ *//' | awk '{ print $NF }' | sort -u)"
      extra="$(comm -13 <(echo "$allowed") <(echo "$found"))"
      if [ -n "$extra" ]; then
        echo "$bin asks libSystem for more than the list:"
        echo "$extra" | sed 's/^/  /'
        exit 1
      fi
    done
    echo "  the runtime's names, a thread's ($(echo $thread)) and $pool, and nothing else, plain and release"
    ;;
  *)
    [ -n "$NM" ] || { echo "FAIL: dependency floor: setup: nm is unavailable"; exit 76; }
    for bin in exercise-plain exercise-release; do
      if ! symbols="$("$NM" -u "$bin")" || [ -z "$symbols" ]; then
        echo "FAIL: dependency floor: setup: nm could not read undefined symbols from $bin"; exit 76
      fi
      added="$(printf '%s\n' "$symbols" | sed -e 's/^ *[wU] *//' -e 's/@.*$//' |
        awk 'NF && $0 !~ /^(_ITM_deregisterTMCloneTable|_ITM_registerTMCloneTable|__cxa_finalize|__gmon_start__|__libc_start_main|environ|__environ)$/ { n++ } END { print n + 0 }')"
      if [ "$added" -ne 0 ]; then
        echo "the pool put $added undefined symbols on $bin's link line:"; "$NM" -u "$bin"; exit 1
      fi
    done
    echo "  the C runtime template's names and environ, which IYI_WORKERS is read through, plain and release: the pool itself is raw syscalls"
    ;;
esac

# ── 3. Capacity and speed ─────────────────────────────────────────────────
# The capacity witness proves that K distinct workers can hold K tasks
# together, not the former 0.6 x K time-weighted occupancy fraction. Wall
# time, speed ratio, and sampled at-once are information only.
TASKS=16
ROUNDS=40000000
speed_run() { # workers binary -> this run's "wall_ms at_once"
  local workers="$1" binary="$2" line code pair
  line="$(timeout -k 5 300 "./$binary" speed "$workers" "$TASKS" "$ROUNDS" 2>&1)"
  code=$?
  if [ "$code" -eq 76 ]; then
    printf '%s\n' "$line" >&2
    return 76
  fi
  if [ "$code" -eq 124 ] || [ "$code" -eq 137 ]; then
    echo "FAIL: speed: progress hang: the $workers-worker run hit the shell emergency timeout (exit $code)" >&2
    return 76
  fi
  if [ "$code" -ne 0 ]; then
    echo "FAIL: speed: setup: the $workers-worker run exited $code: $line" >&2
    return 76
  fi
  if ! pair="$(printf '%s\n' "$line" | awk -v workers="$workers" -v tasks="$TASKS" -v rounds="$ROUNDS" '
    $1 ~ /^workers=/ {
      found++
      if (NF != 6 || $1 != "workers=" workers || $2 != "tasks=" tasks ||
          $3 != "rounds=" rounds || $4 !~ /^wall_ms=[0-9]+$/ ||
          $5 !~ /^at_once=[0-9]+$/ || $6 !~ /^checksum=[0-9]+$/) {
        bad = 1
        next
      }
      ms = substr($4, 9); at = substr($5, 9)
    }
    END {
      if (found != 1 || bad || ms + 0 <= 0 || at + 0 > tasks * 100) exit 1
      print ms, at
    }')"; then
    echo "FAIL: speed: setup: $workers-worker run did not print one valid time and at-once pair: $line" >&2
    return 76
  fi
  printf '%s\n' "$pair"
}
at_once() { awk -v a="$1" 'BEGIN { printf "%.2f", a / 100 }'; }
check_at_once_floor() { # at_once_hundredths and k
  case "$1:$2" in
    :*|*:|*[!0-9:]*)
      echo "FAIL: speed: setup: invalid at-once sample or worker count" >&2
      return 76 ;;
  esac
  if ! [ "$1" -ge 0 ] 2>/dev/null || ! [ "$2" -gt 0 ] 2>/dev/null ||
     ! [ "$2" -le 153722867280912930 ] 2>/dev/null; then
    echo "FAIL: speed: setup: invalid at-once sample or worker count" >&2
    return 76
  fi
  if [ "$1" -lt $((60 * 10#$2)) ]; then
    echo "FAIL: speed: $2 workers held their tasks $(at_once "$1") at once on average: under 0.6 x $2, which is not parallel"
    return 1
  fi
}
K=2
[ "$CORES" -ge 4 ] && K=4
need_cores 2 "the capacity witness needs at least two workers"
step "capacity: $K workers hold tasks together"
timeout -k 5 300 ./exercise-release capacity "$K" > capacity-release.txt 2>&1
code=$?
child_progress_status capacity "$code" capacity-release.txt
capacity_line="capacity: $K workers held tasks together"
if [ "$code" -eq 1 ] &&
   [ "$(grep -cE "^FAIL: capacity: the pool started [0-9]+ worker, expected $K$" capacity-release.txt)" -eq 1 ] &&
   [ "$(grep -c '^FAIL: ' capacity-release.txt)" -eq 1 ]; then
  grep -xE "^FAIL: capacity: the pool started [0-9]+ worker, expected $K$" capacity-release.txt
  exit 1
fi
if [ "$code" -ne 0 ] || [ "$(grep -cxF -- "$capacity_line" capacity-release.txt)" -ne 1 ] || grep -q '^FAIL: ' capacity-release.txt; then
  echo "FAIL: capacity: setup: expected one exact success verdict with exit 0, got exit $code"; cat capacity-release.txt; exit 76
fi
echo "  $capacity_line"
step "the speedup: $TASKS CPU-bound tasks, one run per worker count, $CORES cores here"
echo "  measure: sampled at-once and wall times are performance information only"
echo "  measure: capacity does not prove the 0.6 x K time-weighted occupancy floor"
got="$(speed_run 1 exercise-release)" || exit $?
ONE="${got% *}"
printf '  measure: %2s worker(s): %6s ms, %s at once\n' 1 "$ONE" "$(at_once "${got#* }")"
MANY=""
for w in 2 4 8; do
  [ "$w" -gt "$CORES" ] && break
  got="$(speed_run "$w" exercise-release)" || exit $?
  ms="${got% *}"
  if ! ratio="$(awk -v a="$ONE" -v b="$ms" 'BEGIN { printf "%.2f", a / b }')"; then
    echo "FAIL: speed: setup: could not compute the $w-worker speed ratio"; exit 76
  fi
  printf '  measure: %2s worker(s): %6s ms, %sx one worker, %s at once\n' "$w" "$ms" "$ratio" "$(at_once "${got#* }")"
  [ "$w" -eq "$K" ] && MANY="$ms"
done
if [ -z "$MANY" ]; then
  echo "FAIL: speed: setup: no measurement was made for the required $K-worker run"; exit 76
fi
if ! awk -v one="$ONE" -v many="$MANY" -v k="$K" 'BEGIN {
  if (one / many >= 0.6 * k) result = "above"
  else result = "below"
  printf "  measure: %d workers, %.2fx one worker; 0.6 x K is %.2fx (%s)\n", k, one / many, 0.6 * k, result
}'; then
  echo "FAIL: speed: setup: could not compute the performance information"; exit 76
fi

# ── 4. A deadlock across threads is named ────────────────────────────────
step "a deadlock across threads is a diagnosis, not a hang"
cat > paralleldeadlock.iyi <<'IYI'
module paralleldeadlock

never = Channel(Int32).new
group do |g|
  g.spawn(unit: :new) do
    never.receive
    0
  end
end
puts "the group ended"
IYI
if ! "$IYI" build paralleldeadlock.iyi -o paralleldeadlock > build-deadlock.log 2>&1; then
  echo "FAIL: deadlock: setup: the deadlock program failed to build"; tail -20 build-deadlock.log; exit 76
fi
timeout -k 5 30 ./paralleldeadlock > deadlock.txt 2>&1
code=$?
child_progress_status deadlock "$code" deadlock.txt
deadlock_line='iyi: panic: deadlock: every fiber is blocked and nothing can wake one'
if [ "$code" -ne 1 ] || [ "$(grep -cxF -- "$deadlock_line" deadlock.txt)" -ne 1 ]; then
  echo "FAIL: deadlock: the blocked task exited $code without the expected diagnosis"; cat deadlock.txt; exit 1
fi
echo "  exits 1: $deadlock_line"

# ── 4a. A panic or an exit ends the process ──────────────────────────────
# bench/panic_exit.iyi: tasks parked on the poller (reads nobody answers,
# an accept nobody connects to) beside sleepers and channel receivers. The
# program is then ended three ways: a task's panic, the main task's panic,
# and a task's `exit(3)`. Each runs on twelve workers and on the main
# thread alone. The program's five-second watchdog starts after every I/O
# task has reached the park rendezvous. The shell timeout bounds setup and
# exit as well.
step "a panic or an exit ends the process with tasks parked on the poller"
if ! "$IYI" build "$REPO/bench/panic_exit.iyi" -o panic_exit > build-panic-exit.log 2>&1; then
  echo "FAIL: panic: setup: the exercise failed to build"; tail -20 build-panic-exit.log; exit 76
fi
for workers in 12 0; do
  where="on 12 workers"
  [ "$workers" = 0 ] && where="on the main thread"
  for mode in task-panic main-panic task-exit; do
    case "$mode" in
      task-panic) want=1 said='iyi: panic: a task panicked: ' ;;
      main-panic) want=1 said="iyi: panic: the main task's panic" ;;
      task-exit) want=3 said='' ;;
    esac
    timeout -k 5 60 ./panic_exit "$mode" --workers="$workers" > panic-exit.txt 2>&1
    code=$?
    if [ "$code" -eq 76 ]; then cat panic-exit.txt; exit 76; fi
    if [ "$code" -ne "$want" ] || grep -q '^FAIL: ' panic-exit.txt || { [ -n "$said" ] && ! grep -qF "$said" panic-exit.txt; }; then
      echo "FAIL: panic: setup: $mode $where exited $code, not $want (124 is a timeout)"; cat panic-exit.txt; exit 76
    fi
    ended="$(grep -m1 'every task ended' panic-exit.txt | sed 's/^[a-z-]*: every task ended /, every task ended /')"
    echo "  $mode $where: exits $code$ended"
  done
done

step "failure proof: each panic mode names a reader that never parks"
if ! "$IYI" build -Dpanic_park_watchdog "$REPO/bench/panic_exit.iyi" -o panic_park_watchdog-run > build-panic_park_watchdog.log 2>&1; then
  echo "FAIL: panic_park_watchdog: setup: the exercise failed to build"; tail -20 build-panic_park_watchdog.log; exit 76
fi
for workers in 0 12; do
  for mode in task-panic main-panic task-exit; do
    timeout -k 5 120 ./panic_park_watchdog-run "$mode" --workers="$workers" --watch=100 > panic_park_watchdog.txt 2>&1
    code=$?
    emergency_timeout panic_park_watchdog "$code"
    want="FAIL: $mode: progress hang: a reader did not park on its io wait"
    if ! one_ending panic_park_watchdog.txt "$want" "$code"; then
      echo "FAIL: panic_park_watchdog: setup: expected one exact watchdog verdict for $mode with $workers workers and exit 76, got exit $code"; tail -20 panic_park_watchdog.txt; exit 76
    fi
    echo "  watchdog control panic_park_watchdog workers=$workers mode=$mode exits 76 at \"$want\""
  done
done

# ── 5. Share gates the parallel block ─────────────────────────────────────
step "Share gates what a parallel task's block captures"
refused() { # name, expected text, program body
  printf 'module %s\n\n%s\n' "$1" "$3" > "$1.iyi"
  if "$IYI" build "$1.iyi" -o "$1" > "$1.log" 2>&1; then
    echo "a program that must not compile compiled: $1"; cat "$1.iyi"; exit 1
  fi
  if ! grep -qF "$2" "$1.log"; then
    echo "$1 was refused, but not for the reason:"; cat "$1.log"; exit 1
  fi
  echo "  refused: $(grep -m1 -F "$2" "$1.log" | sed 's/^ *//' | cut -c1-150)"
}
refused shares_array 'the block spawn(unit: :new) runs in a unit of its own, on another thread captures `items : Array(Int32)`, which is not Share' '
items = [1, 2, 3]
group do |g|
  g.spawn(unit: :new) { items.size }
end'
refused shares_channel_of_arrays 'captures `lists : Channel(Array(Int32))`, which is not Share' '
lists = Channel(Array(Int32)).new(1)
group do |g|
  g.spawn(unit: :new) { lists.close }
end'
refused assigns_after '`count` is assigned here, after the task was spawned' '
def launch(g : IyiGroup) : Nil
  count = 1
  g.spawn(unit: :new) { count + 1 }
  count = 2
end

group do |g|
  launch(g)
end'
refused loop_local 'in a loop or a block that spawns the task again' '
group do |g|
  i = 0
  while i < 4
    seed = i * 10
    g.spawn(unit: :new) { seed + 1 }
    i = i + 1
  end
end'

# #148: the issue's shape, a pool in a constant read through `ask`. The
# block names no constant, so nothing above refuses it; it is refused at
# the constant it reaches, with the block and the path, by a build and by
# `check` (SPEC.md III.4.5; 0.21 warned). The broken copy is the clean
# one with the mark taken off, and the build that passes the marked copy
# catches it. Two blocks reach `DATABASE`, and that is one refusal,
# counting the second: iyiturkiye's routes gave 1251 warnings about 37
# constants, each once per route that reached it, on Linux; gathered they
# are 37. Its broken copy has the second block left out, and says nothing
# of another block. The clean copy's `Database` is built at startup and
# only read: its claim is one the compiler proves, and the refusal of the
# bare copy says so. This copy once assigned a field in `query_one`, from
# both tasks, under the claim that one task asked, and passed; that claim
# is refused now (bench/safe_reach.sh).
step "a parallel block reaching a constant through a call is refused"
cat > reaches.iyi <<'IYI'
module reaches

class Database
  def initialize
    @rows = [] of Int64
    @rows << 7_i64
  end

  def query_one(n : Int64) : Int64
    @rows[0] + n
  end
end

@[SafeReach("the gate's clean copy: built at startup, and every task only reads it")]
DATABASE = Database.new

def ask(n : Int64) : Int64
  DATABASE.query_one(n)
end

group do |g|
  g.spawn(unit: :new) { ask(1_i64) }
  g.spawn(unit: :new) { ask(2_i64) }
end
IYI
if ! awk '/^@\[SafeReach/ { marks++; at_mark = NR; next } /^DATABASE = Database.new$/ { databases++; at_database = NR } /^module reaches$/ { modules++; print "module reaches_bare"; next } { print } END { if (marks != 1 || modules != 1 || databases != 1 || at_database != at_mark + 1) exit 3 }' reaches.iyi > reaches_bare.iyi; then
  echo "the awk for reaches_bare found a missing or duplicate anchor"; exit 1
fi
if cmp -s reaches.iyi reaches_bare.iyi; then
  echo "the awk for reaches_bare found nothing to change"; exit 1
fi
if ! "$IYI" check --error-on-warnings reaches.iyi > check-reaches.log 2>&1; then
  echo "a constant marked @[SafeReach] failed the check under --error-on-warnings:"; cat check-reaches.log; exit 1
fi
echo "  checks under --error-on-warnings: DATABASE marked @[SafeReach]"
if "$IYI" build reaches_bare.iyi -o reaches_bare > build-reaches-bare.log 2>&1; then
  echo "the build passed a block reaching DATABASE unmarked:"; cat build-reaches-bare.log; exit 1
fi
want='reaches `DATABASE : ReachesBare::Database` (not Share) through `ask` → `DATABASE.query_one`, as does 1 other parallel block: '
claim='Nothing writes it once a parallel task may start, so a claim is proven: `iyi fix` adds `@[SafeReach("set before the first parallel task starts, then only read")]`'
if [ "$(grep -c 'reaches `DATABASE' build-reaches-bare.log)" != 1 ]; then
  echo "two blocks reaching DATABASE were not one refusal:"; cat build-reaches-bare.log; exit 1
fi
if ! grep -qF "$want" build-reaches-bare.log || ! grep -qF "$claim" build-reaches-bare.log; then
  echo "the build was refused, but not for the block reaching DATABASE through ask, with the claim:"; cat build-reaches-bare.log; exit 1
fi
if "$IYI" check reaches_bare.iyi > check-reaches-bare.log 2>&1; then
  echo "check passed the program the build refuses:"; cat check-reaches-bare.log; exit 1
fi
if ! grep -qF "$want" check-reaches-bare.log; then
  echo "check failed the program, but not for the block reaching DATABASE:"; cat check-reaches-bare.log; exit 1
fi
echo "  broken copy, the mark taken off: refused by the build and by check, the claim offered"
echo "  refused once for two blocks: $(grep -m1 -oF "$want" build-reaches-bare.log | cut -c1-150)"
if ! awk '/^  g.spawn\(unit: :new\) \{ ask\(1_i64\) \}$/ { first++; at_first = NR } /^  g.spawn\(unit: :new\) \{ ask\(2_i64\) \}$/ { calls++; at_second = NR; next } /^module reaches_bare$/ { modules++; print "module reaches_lone"; next } { print } END { if (first != 1 || calls != 1 || modules != 1 || at_second != at_first + 1) exit 3 }' reaches_bare.iyi > reaches_lone.iyi; then
  echo "the awk for reaches_lone found a missing or duplicate anchor"; exit 1
fi
if cmp -s reaches_bare.iyi reaches_lone.iyi; then
  echo "the awk for reaches_lone found nothing to change"; exit 1
fi
if "$IYI" check reaches_lone.iyi > check-reaches-lone.log 2>&1; then
  echo "check passed one block reaching DATABASE:"; cat check-reaches-lone.log; exit 1
fi
if grep -qF "$want" check-reaches-lone.log || grep -qF 'other parallel block' check-reaches-lone.log \
  || ! grep -qF 'through `ask` → `DATABASE.query_one`: ' check-reaches-lone.log; then
  echo "one block reaching DATABASE was not refused alone:"; cat check-reaches-lone.log; exit 1
fi
echo "  broken copy, the second block left out: refused with no other block counted"

# ── 7. Failure proofs: broken copies of the runtime ──────────────────────
# Each running copy of src/iyi has one file changed by awk and shares its
# ending with the fixture through -Drun_end_copy. IR-only copies stay separate.
# The program is a bench fixture name or a generated fixture path. Missing
# or duplicate awk anchors fail the gate; nothing in the tree is touched.
copy_build() { # copy directory, bench fixture name or generated path, build flags...
  local program="$REPO/bench/$2.iyi"
  case "$2" in *.iyi) program="$2" ;; esac
  printf '%s\n' "$RUN_END" >> "$1/iyi/concurrency.iyi" || { echo "FAIL: $1: setup: could not append the run's one ending to the runtime copy"; exit 76; }
  IYI_PATH="$WORK/$1${PSEP}$REPO/src" "$IYI" build -Drun_end_copy "${@:3}" "$program" -o "$1-run" > "build-$1.log" 2>&1
}
broken() { # name, awk program[, file in src/iyi[, bench fixture name or path[, build flags...]]]
  local file="${3:-concurrency.iyi}" program="${4:-parallel_exercise}" awk_status cmp_status
  mkdir -p "$1/iyi" || { echo "FAIL: $1: setup: could not create the runtime copy"; exit 76; }
  cp "$REPO"/src/iyi/*.iyi "$1/iyi/" || { echo "FAIL: $1: setup: could not copy the runtime"; exit 76; }
  awk "$2" "$REPO/src/iyi/$file" > "$1/iyi/$file"
  awk_status=$?
  if [ "$awk_status" -ne 0 ]; then
    echo "FAIL: $1: setup: the awk exited $awk_status because an anchor is missing or duplicated in $file"; exit 76
  fi
  cmp -s "$1/iyi/$file" "$REPO/src/iyi/$file"
  cmp_status=$?
  if [ "$cmp_status" -eq 0 ]; then
    echo "FAIL: $1: setup: the awk found nothing to change"; exit 76
  elif [ "$cmp_status" -ne 1 ]; then
    echo "FAIL: $1: setup: could not compare the generated runtime copy"; exit 76
  fi
  out="$(scan_added "$REPO/src/iyi/$file" "$1/iyi/$file" "$1/$file")" || { printf '%s\n' "${out:-FAIL: one ending: setup: $1/$file could not be scanned}"; exit 76; }
  if ! copy_build "$1" "$program" "${@:5}"; then
    echo "FAIL: $1: setup: the runtime copy failed to build"; tail -20 "build-$1.log"; exit 76
  fi
}
# Mutants must exit 1 with the exact FAIL or panic line; controls must
# exit with their expected status and exact verdict. Timeouts never count
# as catches.
verdict_caught() { # name, exact verdict, step arguments...
  local name="$1" want="$2" code
  shift 2
  timeout -k 5 120 "./$name-run" "$@" > "$name.txt" 2>&1
  code=$?
  emergency_timeout "$name" "$code"
  if [ "$code" -eq 76 ]; then cat "$name.txt"; exit 76; fi
  if [ "$code" -ne 1 ] || [ "$(grep -cxF -- "FAIL: $want" "$name.txt")" -ne 1 ] || [ "$(grep -c '^FAIL: ' "$name.txt")" -ne 1 ]; then
    echo "FAIL: $name: setup: expected one exact mutant verdict with exit 1, got exit $code"; tail -20 "$name.txt"; exit 76
  fi
  echo "  exits 1 at \"$want\""
}
verdict_held() { # name, exact verdict, step arguments...
  local name="$1" want="$2" code
  shift 2
  timeout -k 5 120 "./$name-run" "$@" > "$name.txt" 2>&1
  code=$?
  emergency_timeout "$name" "$code"
  if [ "$code" -eq 76 ]; then cat "$name.txt"; exit 76; fi
  if [ "$code" -ne 0 ] || [ "$(grep -cxF -- "$want" "$name.txt")" -ne 1 ] || grep -q '^FAIL: ' "$name.txt"; then
    echo "FAIL: $name: setup: expected one exact control verdict with exit 0, got exit $code"; tail -20 "$name.txt"; exit 76
  fi
  echo "  hook-only control $name passes: \"$want\""
}
caught_line() { # name, exact line, step arguments...
  local name="$1" want="$2" code
  shift 2
  timeout -k 5 120 "./$name-run" "$@" > "$name.txt" 2>&1
  code=$?
  emergency_timeout "$name" "$code"
  if [ "$code" -eq 76 ]; then cat "$name.txt"; exit 76; fi
  if [ "$code" -ne 1 ] || [ "$(grep -cxF -- "$want" "$name.txt")" -ne 1 ] || grep -q '^FAIL: ' "$name.txt"; then
    echo "FAIL: $name: setup: expected one exact panic verdict with exit 1, got exit $code"; tail -20 "$name.txt"; exit 76
  fi
  echo "  exits 1 at \"$want\""
}
verdict_watchdog() { # name, exact FAIL line, step arguments...
  local name="$1" want="$2" code
  shift 2
  timeout -k 5 120 "./$name-run" "$@" > "$name.txt" 2>&1
  code=$?
  emergency_timeout "$name" "$code"
  if ! one_ending "$name.txt" "$want" "$code"; then
    echo "FAIL: $name: setup: expected one exact watchdog verdict with exit 76, got exit $code"; tail -20 "$name.txt"; exit 76
  fi
  echo "  watchdog control $name exits 76 at \"$want\""
}
verdict_repeated() { # name, exact FAIL line, required repetitions, step arguments...
  local name="$1" want="$2" times="$3" code
  shift 3
  timeout -k 5 120 "./$name-run" "$@" > "$name.txt" 2>&1
  code=$?
  emergency_timeout "$name" "$code"
  if [ "$code" -ne 76 ] || [ "$(grep -cxF -- "$want" "$name.txt")" -ne "$times" ] ||
     [ "$(grep -c '^FAIL: ' "$name.txt")" -ne "$times" ] || one_ending "$name.txt" "$want" "$code"; then
    echo "FAIL: $name: setup: expected $times exact unclaimed watchdog verdicts with exit 76, got exit $code"; tail -20 "$name.txt"; exit 76
  fi
  echo "  unclaimed control $name exits 76 with $times identical failures; one-ending check rejects it"
}
# Copy-only definitions below are generated into runtime files, never src.
# Hook and fixture endings use the one block appended by copy_build; the
# fixture's own block is compiled out. An awk that misses an anchor exits 3.
WAKE_COMMON='/^  def self.wait_shared\(st : IyiSchedulerState\) : Nil$/ { inws = 1; n_wait++ }
inws && /^  end$/ { inws = 0 }
inws && /^    st.idle = true$/ { print; print "    IyiScheduler.force_idle_mark(st)"; n_mark++; at_mark = NR; next }
inws && /^    wait_for_events\(true\)$/ { print "    IyiScheduler.force_idle_hold(st)"; print; n_hold++; at_hold = NR; next }
/^  def self.send_home\(home : IyiSchedulerState, fiber : IyiFiber\) : Nil$/ { insend = 1; n_send++ }
insend && /^  end$/ { insend = 0 }
insend && /^    home.post_mail$/ { print; print "    force_home_post(home, fiber)"; n_post++; at_post = NR; next }'
WAKE_RING_BUG='insend && /^    ring\(home\)$/ { print "    force_home_done(home, fiber)"; n_ring++; at_ring = NR; next }'
WAKE_RING_HOOK='insend && /^    ring\(home\)$/ { print; print "    force_home_done(home, fiber)"; n_ring++; at_ring = NR; next }'
WAKE_DEFS='/^  def self.reschedule : Nil$/ {
  print "  @[UnsafeReach(\"copy-only home wake rendezvous, accessed atomically\")]"
  print "  @@forced_home_state : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only home wake rendezvous, accessed atomically\")]"
  print "  @@forced_home_fiber : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only home wake rendezvous, accessed atomically\")]"
  print "  @@forced_idle : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only home wake rendezvous, accessed atomically\")]"
  print "  @@forced_home_posted : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only home wake rendezvous, accessed atomically\")]"
  print "  @@forced_home_result : UInt64 = 0_u64"
  print "  def self.force_home_arm(state : IyiSchedulerState, fiber : IyiFiber) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_home_state).address).value.set(state.object_id)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_home_fiber).address).value.set(fiber.object_id)"
  print "  end"
  print "  def self.force_idle_mark(state : IyiSchedulerState) : Nil"
  print "    return unless state.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_home_state).address).value.get"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_idle).address).value.set(1_u64)"
  print "  end"
  print "  def self.force_idle_hold(state : IyiSchedulerState) : Nil"
  print "    return unless state.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_home_state).address).value.get"
  print "    started = __iyi_monotonic_ns"
  print "    while !force_home_completed?"
  print "      IyiThread.spin_pause"
  print "      if __iyi_monotonic_ns - started > 10000000000_i64"
  print "        end_run(76, 2, \"FAIL: home: progress hang: the copy hook waited for the target post decision\\n\")"
  print "      end"
  print "    end"
  print "  end"
  print "  def self.force_idle_seen? : Bool"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_idle).address).value.get == 1_u64"
  print "  end"
  print "  def self.force_home_post(home : IyiSchedulerState, fiber : IyiFiber) : Nil"
  print "    return if force_home_completed?"
  print "    return unless home.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_home_state).address).value.get"
  print "    return unless fiber.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_home_fiber).address).value.get"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_home_posted).address).value.set(1_u64)"
  print "  end"
  print "  def self.force_home_done(home : IyiSchedulerState, fiber : IyiFiber) : Nil"
  print "    return if force_home_completed?"
  print "    return unless home.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_home_state).address).value.get"
  print "    return unless fiber.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_home_fiber).address).value.get"
  print "    return unless Pointer(Atomic(UInt64)).new(pointerof(@@forced_home_posted).address).value.get == 1_u64"
  print "    unless home.idle"
  print "      end_run(76, 2, \"FAIL: home: not armed: the targeted post found the root not idle\\n\")"
  print "    end"
  print "    unless home.notified"
  print "      end_run(1, 1, \"FAIL: home: the targeted idle root was posted but not rung\\n\")"
  print "    end"
  print "    {% if !flag?(:copy_hook_watchdog) %}"
  print "      Pointer(Atomic(UInt64)).new(pointerof(@@forced_home_result).address).value.set(1_u64)"
  print "    {% end %}"
  print "  end"
  print "  def self.force_home_completed? : Bool"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_home_result).address).value.get == 1_u64"
  print "  end"
  print
  n_defs++
  next
}'
WAKE_END='END { if (n_wait != 1 || n_mark != 1 || n_hold != 1 || at_mark >= at_hold || n_send != 1 || n_post != 1 || n_ring != 1 || at_post >= at_ring || n_defs != 1) exit 3 }'
WAKE_BUG="$WAKE_COMMON
$WAKE_RING_BUG
$WAKE_DEFS
{ print }
$WAKE_END"
WAKE_HOOK="$WAKE_COMMON
$WAKE_RING_HOOK
$WAKE_DEFS
{ print }
$WAKE_END"
NOW_COMMON='/^  def take_now : T \| ChannelClosed$/ { intake = 1; n_take++ }
/^  def put_now\(value : T\) : Nil \| ChannelClosed$/ { input = 1; n_put++ }
(intake || input) && /^  end$/ { intake = 0; input = 0 }
intake && /^    lock$/ { print "    IyiScheduler.force_now_attempt(pointerof(@guard).address)"; n_attempt++ }'
NOW_LOCK_BUG='intake && /^    lock$/ { n_take_lock++; at_take_lock = NR; next }
intake && /^    unlock$/ { n_take_unlock++; at_take_unlock = NR; next }
input && /^    lock$/ { n_put_lock++; at_put_lock = NR; next }
input && /^    unlock$/ { n_put_unlock++; at_put_unlock = NR; next }'
NOW_LOCK_HOOK='intake && /^    lock$/ { n_take_lock++; at_take_lock = NR }
intake && /^    unlock$/ { n_take_unlock++; at_take_unlock = NR }
input && /^    lock$/ { n_put_lock++; at_put_lock = NR }
input && /^    unlock$/ { n_put_unlock++; at_put_unlock = NR }'
NOW_SHIFT_BUG='/^  private def shift_item : T$/ { inshift = 1; n_method++ }
inshift && /^  end$/ { inshift = 0 }
inshift && /^    @count = @count - 1$/ { print "    seen_count = @count"; print "    IyiScheduler.force_now_hold(pointerof(@guard).address)"; print "    @count = seen_count - 1"; print "    IyiScheduler.force_now_stored(pointerof(@guard).address)"; n_shift++; at_shift = NR; next }
inshift && /^    value$/ { n_value++; at_value = NR }'
NOW_SHIFT_HOOK='/^  private def shift_item : T$/ { inshift = 1; n_method++ }
inshift && /^  end$/ { inshift = 0 }
inshift && /^    @count = @count - 1$/ { print "    IyiScheduler.force_now_hold(pointerof(@guard).address)"; print; print "    IyiScheduler.force_now_stored(pointerof(@guard).address)"; n_shift++; at_shift = NR; next }
inshift && /^    value$/ { n_value++; at_value = NR }'
NOW_DEFS='/^  def self.reschedule : Nil$/ {
  print "  @[UnsafeReach(\"copy-only rendezvous words accessed atomically\")]"
  print "  @@now_target : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only rendezvous words accessed atomically\")]"
  print "  @@now_entered : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only rendezvous words accessed atomically\")]"
  print "  @@now_blocked : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only rendezvous words accessed atomically\")]"
  print "  @@now_stored : UInt64 = 0_u64"
  print "  def self.force_now_arm(target : UInt64) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@now_target).address).value.set(target)"
  print "  end"
  print "  def self.force_now_entered? : Bool"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@now_entered).address).value.get == 1_u64"
  print "  end"
  print "  def self.force_now_attempt(target : UInt64) : Nil"
  print "    return unless target == Pointer(Atomic(UInt64)).new(pointerof(@@now_target).address).value.get"
  print "    return unless force_now_entered?"
  print "    {% if !flag?(:copy_hook_watchdog) %}"
  print "      if Pointer(Atomic(UInt64)).new(target).value.get != 0_u64"
  print "        Pointer(Atomic(UInt64)).new(pointerof(@@now_blocked).address).value.set(1_u64)"
  print "      end"
  print "    {% end %}"
  print "  end"
  print "  def self.force_now_hold(target : UInt64) : Nil"
  print "    return unless target == Pointer(Atomic(UInt64)).new(pointerof(@@now_target).address).value.get"
  print "    entered = Pointer(Atomic(UInt64)).new(pointerof(@@now_entered).address)"
  print "    return if entered.value.get != 0_u64"
  print "    entered.value.set(1_u64)"
  print "    blocked = Pointer(Atomic(UInt64)).new(pointerof(@@now_blocked).address)"
  print "    stored = Pointer(Atomic(UInt64)).new(pointerof(@@now_stored).address)"
  print "    started = __iyi_monotonic_ns"
  print "    while blocked.value.get == 0_u64 && stored.value.get == 0_u64"
  print "      IyiThread.spin_pause"
  print "      if __iyi_monotonic_ns - started > 10000000000_i64"
  print "        end_run(76, 2, \"FAIL: now: progress hang: the copy hook waited for the second take\\n\")"
  print "      end"
  print "    end"
  print "  end"
  print "  def self.force_now_stored(target : UInt64) : Nil"
  print "    return unless target == Pointer(Atomic(UInt64)).new(pointerof(@@now_target).address).value.get"
  print "    {% if !flag?(:copy_hook_watchdog) %}"
  print "      Pointer(Atomic(UInt64)).new(pointerof(@@now_stored).address).value.set(1_u64)"
  print "    {% end %}"
  print "  end"
  print
  n_defs++
  next
}'
NOW_END='END { if (n_take != 1 || n_put != 1 || n_attempt != 1 || n_take_lock != 1 || n_take_unlock != 1 || at_take_lock >= at_take_unlock || n_put_lock != 1 || n_put_unlock != 1 || at_put_lock >= at_put_unlock || n_method != 1 || n_shift != 1 || n_value != 1 || at_value != at_shift + 1 || n_defs != 1) exit 3 }'
NOW_BUG="$NOW_COMMON
$NOW_LOCK_BUG
$NOW_SHIFT_BUG
$NOW_DEFS
{ print }
$NOW_END"
NOW_HOOK="$NOW_COMMON
$NOW_LOCK_HOOK
$NOW_SHIFT_HOOK
$NOW_DEFS
{ print }
$NOW_END"
CANCEL_SUSPEND_BUG='/^  def self.suspend\(fiber : IyiFiber, nonce : UInt64\) : Nil$/ { insus = 1; n_suspend++ }
insus && /^  end$/ { insus = 0; at_suspend_end = NR }
insus && /^    if fiber.cancelled && fiber.claim\(nonce\)$/ { print "    if false"; print "      force_window_decision(fiber, 1_u64)"; n_decision++; at_decision = NR; next }
insus && /^    reschedule$/ { print "    force_window_decision(fiber, 2_u64)"; print; n_fall++; at_fall = NR; next }'
CANCEL_SUSPEND_HOOK='/^  def self.suspend\(fiber : IyiFiber, nonce : UInt64\) : Nil$/ { insus = 1; n_suspend++ }
insus && /^  end$/ { insus = 0; at_suspend_end = NR }
insus && /^    if fiber.cancelled && fiber.claim\(nonce\)$/ { print; print "      force_window_decision(fiber, 1_u64)"; n_decision++; at_decision = NR; next }
insus && /^    reschedule$/ { print "    force_window_decision(fiber, 2_u64)"; print; n_fall++; at_fall = NR; next }'
CANCEL_PARK='/^  def self.park\(fiber : IyiFiber\) : UInt64$/ { inpark = 1; n_park++ }
inpark && /^  end$/ { inpark = 0 }
inpark && /^    nonce = parking\(fiber\)$/ { n_parking++; at_parking = NR }
inpark && /^    fiber.wait_for_wake\(nonce\)$/ { print "    IyiScheduler.force_window_hold(fiber)"; print; n_hold++; at_hold = NR; next }
inpark && /^    nonce$/ { n_nonce++; at_nonce = NR }'
CANCEL_DEFS='/^  def self.reschedule : Nil$/ {
  print "  @[UnsafeReach(\"copy-only cancellation rendezvous, accessed atomically\")]"
  print "  @@forced_window_target : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only cancellation rendezvous, accessed atomically\")]"
  print "  @@forced_window_held : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only cancellation rendezvous, accessed atomically\")]"
  print "  @@forced_window_release : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only cancellation rendezvous, accessed atomically\")]"
  print "  @@forced_window_result : UInt64 = 0_u64"
  print "  def self.force_window_arm(fiber : IyiFiber) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_window_target).address).value.set(fiber.object_id)"
  print "  end"
  print "  def self.force_window_held? : Bool"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_window_held).address).value.get == 1_u64"
  print "  end"
  print "  def self.force_window_release : Nil"
  print "    {% if !flag?(:copy_hook_watchdog) %}"
  print "      Pointer(Atomic(UInt64)).new(pointerof(@@forced_window_release).address).value.set(1_u64)"
  print "    {% end %}"
  print "  end"
  print "  def self.force_window_result : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_window_result).address).value.get"
  print "  end"
  print "  def self.force_window_decision(fiber : IyiFiber, result : UInt64) : Nil"
  print "    return unless fiber.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_window_target).address).value.get"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_window_result).address).value.set(result)"
  print "  end"
  print "  def self.force_window_hold(fiber : IyiFiber) : Nil"
  print "    return unless fiber.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_window_target).address).value.get"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_window_held).address).value.set(1_u64)"
  print "    released = Pointer(Atomic(UInt64)).new(pointerof(@@forced_window_release).address)"
  print "    started = __iyi_monotonic_ns"
  print "    while released.value.get == 0_u64"
  print "      IyiThread.spin_pause"
  print "      if __iyi_monotonic_ns - started > 10000000000_i64"
  print "        end_run(76, 2, \"FAIL: lostcancel: progress hang: the copy hook waited for release\\n\")"
  print "      end"
  print "    end"
  print "  end"
  print
  n_defs++
  next
}'
CANCEL_END='END { if (n_suspend != 1 || n_decision != 1 || n_fall != 1 || at_decision >= at_fall || at_suspend_end != at_fall + 1 || n_park != 1 || n_parking != 1 || n_hold != 1 || n_nonce != 1 || at_hold != at_parking + 1 || at_nonce != at_hold + 1 || n_defs != 1) exit 3 }'
CANCEL_BUG="$CANCEL_SUSPEND_BUG
$CANCEL_PARK
$CANCEL_DEFS
{ print }
$CANCEL_END"
CANCEL_HOOK="$CANCEL_SUSPEND_HOOK
$CANCEL_PARK
$CANCEL_DEFS
{ print }
$CANCEL_END"

ENDING_HOOK='/^  def self.reschedule : Nil$/ {
  print "  def self.force_end_claim : Bool"
  print "    RunEnd.claim"
  print "  end"
  print "  def self.force_end_reset : Nil"
  print "    RunEnd.reset_for_test"
  print "  end"
  print ""
  print "  @[NoInline]"
  print "  @[NoPreempt]"
  print "  def self.force_end_now : NoReturn"
  print "    end_run(76, 2, \"FAIL: ending: progress hang: five watchdogs reached one deadline together\\n\")"
  print "  end"
  print
  n_defs++
  next
}
{ print }
END { if (n_defs != 1) exit 3 }'

step "failure proof: five failures at one deadline end the run once"
ENDING_LINE='FAIL: ending: progress hang: five watchdogs reached one deadline together'
if ! "$IYI" build "$REPO/bench/parallel_exercise.iyi" -o ending-run > build-ending.log 2>&1; then
  echo "FAIL: ending: setup: the exercise failed to build"; tail -20 build-ending.log; exit 76
fi
verdict_watchdog ending "$ENDING_LINE" ending
if ! "$IYI" build -Dending_unclaimed "$REPO/bench/parallel_exercise.iyi" -o ending_unclaimed-run > build-ending_unclaimed.log 2>&1; then
  echo "FAIL: ending_unclaimed: setup: the exercise failed to build"; tail -20 build-ending_unclaimed.log; exit 76
fi
verdict_repeated ending_unclaimed "$ENDING_LINE" 5 ending
broken ending_hook "$ENDING_HOOK" concurrency.iyi parallel_exercise -Dending_hook
verdict_watchdog ending_hook "$ENDING_LINE" ending
if ! "$IYI" build -Dplacement_withhold_arrival "$REPO/bench/parallel_exercise.iyi" -o placementheld-run > build-placementheld.log 2>&1; then
  echo "FAIL: placementheld: setup: the exercise failed to build"; tail -20 build-placementheld.log; exit 76
fi
verdict_watchdog placementheld 'FAIL: placement: progress hang: a parallel task held its worker for 10000 ms and no second task started' placement

step "failure proof: a cross-thread wake that does not ring is a lost wakeup"
broken lostwake "$WAKE_BUG" concurrency.iyi parallel_exercise -Dlostwake_force
verdict_caught lostwake 'home: the targeted idle root was posted but not rung' home --watch=5000
broken lostwake_hook "$WAKE_HOOK" concurrency.iyi parallel_exercise -Dlostwake_force
verdict_held lostwake_hook 'home: a task finished on a worker and woke the main thread it was joined by' home --watch=5000
broken lostwake_watchdog "$WAKE_HOOK" concurrency.iyi parallel_exercise -Dlostwake_force -Dcopy_hook_watchdog
verdict_watchdog lostwake_watchdog 'FAIL: home: progress hang: the copy hook waited for the target post decision' home --watch=5000

step "failure proof: a steal that leaves the task in its victim's queue hands it out twice"
# Both copies record the first fiber seen at the armed victim, then the
# first subsequent look at that same victim. The first thief waits only
# after assigning home and unlocking; if the second look finds the same
# fiber it remains held until the runtime's duplicate guard terminates.
DUP_COMMON='/^  private def self.steal_unstarted\(st : IyiSchedulerState\) : IyiFiber\?$/ { insteal = 1; n_steal++ }
insteal && /^  end$/ { insteal = 0; n_steal_end++ }
insteal && /^        fiber = victim.pool_head$/ { print; print "        force_dup_look(victim, fiber)"; n_look++; at_look = NR; next }
insteal && /^        if fiber.is_a\?\(IyiFiber\)$/ { n_if++; at_if = NR }
/^  def self.take_queued\(st : IyiSchedulerState\) : IyiFiber\?$/ { intake = 1; n_take++ }
intake && /^  end$/ { intake = 0; n_take_end++ }
intake && /^    unless fiber.home.is_a\?\(Nil\)$/ { n_guard++; at_guard = NR }
intake && /^      __iyi_exit\(1\)$/ { n_exit++; at_exit = NR }
intake && /^    fiber.home = st$/ { n_home++; at_home = NR }
intake && /^    IyiSchedLock.unlock$/ { n_unlock++; at_unlock = NR }
intake && /^    fiber$/ { print "    force_dup_hold(fiber)"; print; n_hold++; at_hold = NR; next }'
DUP_REMOVE='insteal && /^          victim.pool_head = fiber.next_run$/ { n_head++; at_head = NR; next }
insteal && /^          victim.pool_tail = nil if victim.pool_head.is_a\?\(Nil\)$/ { n_tail++; at_tail = NR; next }'
DUP_KEEP='insteal && /^          victim.pool_head = fiber.next_run$/ { n_head++; at_head = NR }
insteal && /^          victim.pool_tail = nil if victim.pool_head.is_a\?\(Nil\)$/ { n_tail++; at_tail = NR }'
DUP_DEFS='/^  def self.preempts : UInt64$/ {
  print "  @[UnsafeReach(\"copy-only duplicate-steal victim, accessed atomically\")]"
  print "  @@forced_dup_victim : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only first stolen fiber, accessed atomically\")]"
  print "  @@forced_dup_first : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only second-look count, accessed atomically\")]"
  print "  @@forced_dup_seconds : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only second-look result, accessed atomically\")]"
  print "  @@forced_dup_result : UInt64 = 0_u64"
  print "  def self.force_dup_arm(state : IyiSchedulerState) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_dup_victim).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_dup_first).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_dup_seconds).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_dup_result).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_dup_victim).address).value.set(state.object_id)"
  print "  end"
  print "  def self.force_dup_look(victim : IyiSchedulerState, fiber : IyiFiber?) : Nil"
  print "    return unless victim.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_dup_victim).address).value.get"
  print "    first = Pointer(Atomic(UInt64)).new(pointerof(@@forced_dup_first).address)"
  print "    seen = first.value.get"
  print "    if seen == 0_u64"
  print "      first.value.compare_and_set(0_u64, fiber.object_id) if fiber.is_a?(IyiFiber)"
  print "      return"
  print "    end"
  print "    same = fiber.is_a?(IyiFiber) && fiber.object_id == seen"
  print "    result = same ? 2_u64 : 1_u64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_dup_result).address).value.compare_and_set(0_u64, result)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_dup_seconds).address).value.add(1_u64)"
  print "  end"
  print "  def self.force_dup_hold(fiber : IyiFiber) : Nil"
  print "    return unless fiber.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_dup_first).address).value.get"
  print "    result = Pointer(Atomic(UInt64)).new(pointerof(@@forced_dup_result).address)"
  print "    started = __iyi_monotonic_ns"
  print "    while result.value.get != 1_u64"
  print "      IyiThread.spin_pause"
  print "      if __iyi_monotonic_ns - started > 10_000_000_000_i64"
  print "        end_run(76, 2, \"FAIL: duplicate: progress hang: the second look or duplicate guard never arrived\\n\")"
  print "      end"
  print "    end"
  print "  end"
  print "  def self.force_dup_seconds : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_dup_seconds).address).value.get"
  print "  end"
  print "  def self.force_dup_stale : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_dup_result).address).value.get == 2_u64 ? 1_u64 : 0_u64"
  print "  end"
  print ""
  print
  n_defs++
  next
}'
DUP_END='END { if (n_steal != 1 || n_steal_end != 1 || n_look != 1 || n_if != 1 || n_head != 1 || n_tail != 1 || at_if != at_look + 1 || at_head != at_if + 1 || at_tail != at_head + 1 || n_take != 1 || n_take_end != 1 || n_guard != 1 || n_exit != 1 || at_exit != at_guard + 4 || n_home != 1 || at_home != at_exit + 2 || n_unlock != 1 || at_unlock != at_home + 1 || n_hold != 1 || at_hold != at_unlock + 1 || n_defs != 1) exit 3 }'
DUP_BUG="$DUP_COMMON
$DUP_REMOVE
$DUP_DEFS
{ print }
$DUP_END"
DUP_HOOK="$DUP_COMMON
$DUP_KEEP
$DUP_DEFS
{ print }
$DUP_END"
broken duplicate "$DUP_BUG" concurrency.iyi parallel_exercise -Dduplicate_force
caught_line duplicate 'iyi: panic: the pool handed one parallel task to a worker twice: two threads would run one stack' steal
broken duplicate_hook "$DUP_HOOK" concurrency.iyi parallel_exercise -Dduplicate_force
verdict_held duplicate_hook "steal: a second steal found the task the first took gone from its victim's queue" steal

step "failure proof: a cancel never delivered to a sleeping task's thread"
# The sleeper is registered on another worker before the program arms its
# identity. Both copies observe the same post_cancel; the mutant returns
# before posting, and the control records the completed post.
POST_COMMON='/^  def self.post_cancel\(home : IyiSchedulerState, fiber : IyiFiber\) : Nil$/ { inpost = 1; n_method++ }
inpost && /^  end$/ { inpost = 0 }
inpost && /^    home.post_mail$/ { print; print "    force_post_done(fiber)"; n_post++; at_post = NR; next }
inpost && /^    ring\(home\)$/ { n_ring++; at_ring = NR }'
POST_BUG='inpost && /^    return if fiber.cancel_posted$/ { print "    force_post_missing(fiber)"; print "    return"; n_guard++; at_guard = NR; next }'
POST_HOOK='inpost && /^    return if fiber.cancel_posted$/ { n_guard++; at_guard = NR }'
POST_DEFS='/^  def self.reschedule : Nil$/ {
  print "  @[UnsafeReach(\"copy-only target fiber, accessed atomically\")]"
  print "  @@forced_post_target : UInt64 = 0_u64"
  print "  def self.force_post_target(fiber : IyiFiber) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_post_target).address).value.set(fiber.object_id)"
  print "  end"
  print "  def self.force_post_missing(fiber : IyiFiber) : Nil"
  print "    return unless fiber.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_post_target).address).value.get"
  print "    end_run(1, 1, \"FAIL: cancel: the registered target was not posted to its worker\\n\")"
  print "  end"
  print "  def self.force_post_done(fiber : IyiFiber) : Nil"
  print "    return unless fiber.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_post_target).address).value.get"
  print "    puts \"cancel: the registered target was posted to its worker\""
  print "  end"
  print
  n_defs++
  next
}'
POST_END='END { if (n_method != 1 || n_post != 1 || n_guard != 1 || n_ring != 1 || at_guard >= at_post || at_ring != at_post + 1 || n_defs != 1) exit 3 }'
broken undelivered "$POST_COMMON
$POST_BUG
$POST_DEFS
{ print }
$POST_END" concurrency.iyi parallel_exercise -Dundelivered_force
verdict_caught undelivered 'cancel: the registered target was not posted to its worker' cancel --watch=5000
broken undelivered_hook "$POST_COMMON
$POST_HOOK
$POST_DEFS
{ print }
$POST_END" concurrency.iyi parallel_exercise -Dundelivered_force
verdict_held undelivered_hook 'cancel: the registered target was posted to its worker' cancel --watch=5000

step "failure proof: a cancel that skips tasks waiting in the pool runs them uncancelled"
broken unflagged '/^  def self.cancel\(fiber : IyiFiber\) : Nil$/ { incancel = 1; n_method++ } incancel && /^    fiber.cancelled = true$/ { print "    fiber.cancelled = true unless fiber.home.is_a?(Nil)"; n_flag++; next } incancel && /^  end$/ { incancel = 0 } { print } END { if (n_method != 1 || n_flag != 1) exit 3 }'
verdict_caught unflagged 'cancel: 32 tasks waiting in the pool ran uncancelled' cancel_unstarted --watch=5000

step "failure proof: a cancel misses the registered reader's io-wait branch"
# A target reader arms itself before reading. Both copies acknowledge its
# registration and its cancel_wait branch; only the mutant omits that branch.
PARKED_COMMON='/^  def self.park_overlapped_current\(/ { inover = 1; n_over++ }
inover && /^  end$/ { inover = 0 }
inover && /^    fiber.list_on\(st.object_id\) if @@shared && fiber.unit.is_a\?\(IyiUnit\)$/ { print; print "    force_io_registered(fiber)"; n_reg_over++; next }
/^  def self.wait_posix\(/ { inposix = 1; n_posix++ }
inposix && /^  end$/ { inposix = 0 }
inposix && /^    fiber.list_on\(st.object_id\) if moving$/ { print; print "    force_io_registered(fiber)"; n_reg_posix++; next }
/^  (@\[Effect\([a-z_:]+\)\]; )?def self.cancel_wait\(fiber : IyiFiber\) : Nil$/ { incancel = 1; n_cancel++ }
incancel && /^    (elsif|else)( |$)/ && waitingio && !/^    elsif fiber.state == IyiFiberState::WaitingCh$/ { n_intervening++ }
incancel && /^    elsif fiber.state == IyiFiberState::WaitingCh$/ { print "      force_io_decision(fiber, true)"; print; n_taken++; at_taken = NR; waitingio = 0; next }
incancel && /^  end$/ { print "    force_io_decision(fiber, false)"; print; incancel = 0; n_end++; next }'
PARKED_BUG='incancel && /^    elsif fiber.state == IyiFiberState::WaitingIo$/ { print "    elsif false"; n_branch++; at_branch = NR; waitingio = 1; next }'
PARKED_HOOK='incancel && /^    elsif fiber.state == IyiFiberState::WaitingIo$/ { n_branch++; at_branch = NR; waitingio = 1 }'
PARKED_DEFS='/^  def self.reschedule : Nil$/ {
  print "  @[UnsafeReach(\"copy-only io cancellation rendezvous, accessed atomically\")]"
  print "  @@forced_io_target : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only io cancellation rendezvous, accessed atomically\")]"
  print "  @@forced_io_registered : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only io cancellation rendezvous, accessed atomically\")]"
  print "  @@forced_io_decided : UInt64 = 0_u64"
  print "  def self.force_io_target(fiber : IyiFiber) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_io_target).address).value.set(fiber.object_id)"
  print "  end"
  print "  def self.force_io_registered(fiber : IyiFiber) : Nil"
  print "    return unless fiber.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_io_target).address).value.get"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_io_registered).address).value.set(1_u64)"
  print "  end"
  print "  def self.force_io_registered? : Bool"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_io_registered).address).value.get == 1_u64"
  print "  end"
  print "  def self.force_io_decision(fiber : IyiFiber, handled : Bool) : Nil"
  print "    return unless fiber.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_io_target).address).value.get"
  print "    return if Pointer(Atomic(UInt64)).new(pointerof(@@forced_io_decided).address).value.get != 0_u64"
  print "    unless force_io_registered?"
  print "      end_run(76, 2, \"FAIL: task-panic: not armed: target cancellation preceded io registration\\n\")"
  print "    end"
  print "    return unless fiber.cancelled"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_io_decided).address).value.set(1_u64)"
  print "    if handled"
  print "      puts \"task-panic: the registered target reached the io cancellation branch\""
  print "    elsif fiber.state == IyiFiberState::WaitingIo"
  print "      end_run(1, 1, \"FAIL: task-panic: the registered target missed the io cancellation branch\\n\")"
  print "    end"
  print "  end"
  print
  n_defs++
  next
}'
PARKED_END='END { if (n_over != 1 || n_reg_over != 1 || n_posix != 1 || n_reg_posix != 1 || n_cancel != 1 || n_taken != 1 || n_end != 1 || n_branch != 1 || at_branch >= at_taken || n_intervening != 0 || n_defs != 1) exit 3 }'
broken parkedio "$PARKED_COMMON
$PARKED_BUG
$PARKED_DEFS
{ print }
$PARKED_END" concurrency.iyi panic_exit -Dparkedio_force
broken parkedio_hook "$PARKED_COMMON
$PARKED_HOOK
$PARKED_DEFS
{ print }
$PARKED_END" concurrency.iyi panic_exit -Dparkedio_force
for workers in 12 0; do
  verdict_caught parkedio 'task-panic: the registered target missed the io cancellation branch' task-panic "--workers=$workers"
  timeout -k 5 120 ./parkedio_hook-run task-panic "--workers=$workers" > parkedio_hook.txt 2>&1
  code=$?
  emergency_timeout parkedio_hook "$code"
  if [ "$code" -eq 76 ]; then cat parkedio_hook.txt; exit 76; fi
  if [ "$code" -ne 1 ] || grep -q '^FAIL: ' parkedio_hook.txt \
    || [ "$(grep -cxF 'task-panic: the registered target reached the io cancellation branch' parkedio_hook.txt)" -ne 1 ] \
    || [ "$(grep -cxF "iyi: panic: a task's panic, with tasks parked on the poller" parkedio_hook.txt)" -ne 1 ] \
    || [ "$(grep -cxF "iyi: panic: a task panicked: a task's panic, with tasks parked on the poller" parkedio_hook.txt)" -ne 1 ] \
    || ! grep -qxE 'task-panic: every task ended [0-9]+ ms after the start' parkedio_hook.txt; then
    echo "FAIL: parkedio_hook: setup: the control did not reach its io decision and original panic (exit $code)"; tail -20 parkedio_hook.txt; exit 76
  fi
  echo "  parkedio control workers=$workers: the registered target reached the io cancellation branch"
done

step "failure proof: take_now without its channel's lock loses a place when two takes overlap"
# The first take waits inside the critical section. The second observes the
# guard before taking it: in the control it reports contention, so the first
# proceeds and unlocks; in the mutant it stores before the first resumes.
# Both copies use the same hook, and only the mutant removes the four locks
# and writes the stale count.
broken unlocked "$NOW_BUG" concurrency.iyi parallel_exercise -Dnow_force
verdict_caught unlocked 'now: a place is still held after both takes' now_forced
broken unlocked_hook "$NOW_HOOK" concurrency.iyi parallel_exercise -Dnow_force
verdict_held unlocked_hook 'now: two takes from one full channel on two workers left no place held' now_forced
broken unlocked_watchdog "$NOW_HOOK" concurrency.iyi parallel_exercise -Dnow_force -Dcopy_hook_watchdog
verdict_watchdog unlocked_watchdog 'FAIL: now: progress hang: the copy hook waited for the second take' now_forced

step "failure proof: a hand that never marks its select, a cancel lost as a task parks, a word's wake lost before the link"
# Each channel and each list `park_on` waits in has a lock of its own, so
# a select parked on two channels is in the reach of two wakers holding
# two locks, and a cancel claims a park under neither: the wake goes to
# the one claim that takes the park's nonce (`IyiFiber#claim`). A
# rendezvous sender that hands its value without marking the node lets
# the select take another arm, and the value is gone; a cancel between a
# park's look at its flag and its wake word finds nothing to claim unless
# the park looks again (`IyiScheduler.suspend`); and a look at the word
# outside its list's lock misses the wake between the look and the link.
# On Linux x86_64 each copy was caught by name in 10 runs of 10, and on
# Windows 11, 12 logical processors (the user's machine), in 20 of 20 at
# IYI_WORKERS=2 and 10 of 10 at four workers (48c31c427). A copy
# whose claim is a load and a store, not an exchange, never failed at the
# count in 10 runs: 9 hung and 1 ended at the selects' watchdog. The one
# sampled had a worker in `take_mail` holding the scheduler's lock and
# every other thread waiting for it, its watchdog's among them, so it is
# not one of the proofs.
broken unhanded '/^  private def hand\(value : T\) : Bool$/ { inside = 1; methods++ }
inside && /^  end$/ { inside = 0 }
inside && /^      head.handed = true$/ { n++; next }
{ print }
END { if (methods != 1 || n != 1) exit 3 }'
verdict_caught unhanded 'wakes, selects: a value handed to a parked select was not received' wakes --only=handed --watch=5000
broken lostcancel "$CANCEL_BUG" concurrency.iyi parallel_exercise -Dlostcancel_force
verdict_caught lostcancel 'wakes, cancels: the targeted suspend omitted the cancelled claim' wakes --only=cancels --watch=5000
broken lostcancel_hook "$CANCEL_HOOK" concurrency.iyi parallel_exercise -Dlostcancel_force
verdict_held lostcancel_hook 'wakes, cancels: the targeted suspend claimed its cancellation' wakes --only=cancels --watch=5000
broken lostcancel_watchdog "$CANCEL_HOOK" concurrency.iyi parallel_exercise -Dlostcancel_force -Dcopy_hook_watchdog
verdict_watchdog lostcancel_watchdog 'FAIL: lostcancel: progress hang: the copy hook waited for release' wakes --only=cancels --watch=5000
  # The same word-keyed hook holds the first park at its word check in both
  # copies. A locked check waits for the wake to attempt the lock; an
  # unlocked check waits for the wake to finish before linking the waiter.
  LOSTWORD_COMMON='/^  def self.park_on\(/ { inpark = 1; inlink = 1; n_park++ }
inpark && /^  end$/ { inpark = 0 }
inlink && /^  end$/ { inlink = 0 }
expect_link_unlock { if ($0 != "    IyiChanLock.unlock(lock)") exit 3; expect_link_unlock = 0; n_link_unlock++; print; next }
inlink && /^    tails\[bucket\] = waiter$/ { print; print "    force_lost_link(word)"; n_link++; at_link = NR; expect_link_unlock = 1; next }
/^  def self.wake_on\(/ { inwake = 1; n_wake++ }
inwake && /^  end$/ { inwake = 0 }
inwake && /^    IyiChanLock.lock\(lock\)$/ { print "    force_lost_attempt(word)"; n_attempt++; at_attempt = NR }
inwake && /^    IyiChanLock.unlock\(lock\)$/ { print "    force_lost_scanned(word, woken)"; print; print "    force_lost_done(word)"; n_done++; at_done = NR; next }
inwake && /^    while chain.is_a\?\(IyiFiber\)$/ { n_chain++; at_chain = NR }'
  LOSTWORD_BUG='inpark && !seq_open && !seq_done && /^    IyiChanLock.lock\(lock\)$/ { seq_open = 1; seq = 1; n_lock++; next }
seq == 1 { if ($0 != "    if word.value.get != seen") exit 3; seq = 2; print; next }
seq == 2 { if ($0 != "      IyiChanLock.unlock(lock)") exit 3; seq = 3; n_unlock++; next }
seq == 3 { if ($0 != "      return nil") exit 3; seq = 4; print; next }
seq == 4 { if ($0 != "    end") exit 3; seq = 0; seq_done = 1; at_seq = NR; print; print "    force_lost_window(word, lock)"; print "    IyiChanLock.lock(lock)"; n_window++; n_insert++; next }
inpark && (/^ +if word\.value\.get != seen$/ || /^      IyiChanLock\.unlock\(lock\)$/) { n_stray++ }'
  LOSTWORD_CONTROL='inpark && !seq_open && !seq_done && /^    IyiChanLock.lock\(lock\)$/ { seq_open = 1; seq = 1; n_lock++; print; next }
seq == 1 { if ($0 != "    if word.value.get != seen") exit 3; seq = 2; print; next }
seq == 2 { if ($0 != "      IyiChanLock.unlock(lock)") exit 3; seq = 3; n_unlock++; print; next }
seq == 3 { if ($0 != "      return nil") exit 3; seq = 4; print; next }
seq == 4 { if ($0 != "    end") exit 3; seq = 0; seq_done = 1; at_seq = NR; print; print "    force_lost_window(word, lock)"; n_window++; n_insert++; next }
inpark && (/^ +if word\.value\.get != seen$/ || /^      IyiChanLock\.unlock\(lock\)$/) { n_stray++ }'
  LOSTWORD_DEFS='/^  @@lot_locks : Pointer\(UInt64\)/ {
  print
  print "  @[UnsafeReach(\"copy-only word rendezvous accessed atomically\")]"
  print "  @@forced_word : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only word rendezvous accessed atomically\")]"
  print "  @@forced_in_window : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only word rendezvous accessed atomically\")]"
  print "  @@forced_attempted : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only word rendezvous accessed atomically\")]"
  print "  @@forced_woke : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only first wake scan and waiter link, accessed atomically\")]"
  print "  @@forced_scan : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only first wake scan and waiter link, accessed atomically\")]"
  print "  @@forced_link : UInt64 = 0_u64"
  print "  def self.forced_scan : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_scan).address).value.get"
  print "  end"
  print "  def self.forced_link : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_link).address).value.get"
  print "  end"
  print "  def self.force_lost_scanned(word : Pointer(Atomic(UInt64)), woken : Int32) : Nil"
  print "    return unless word.address == Pointer(Atomic(UInt64)).new(pointerof(@@forced_word).address).value.get"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_scan).address).value.compare_and_set(0_u64, woken.to_u64 &+ 1_u64)"
  print "  end"
  print "  def self.force_lost_link(word : Pointer(Atomic(UInt64))) : Nil"
  print "    return unless word.address == Pointer(Atomic(UInt64)).new(pointerof(@@forced_word).address).value.get"
  print "    decision = forced_scan == 1_u64 ? 2_u64 : 1_u64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_link).address).value.compare_and_set(0_u64, decision)"
  print "  end"
  print "  def self.force_lost_wake_on(word : Pointer(Atomic(UInt64))) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_word).address).value.set(word.address)"
  print "  end"
  print "  def self.forced_in_window? : Bool"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_in_window).address).value.get == 1_u64"
  print "  end"
  print "  def self.force_lost_attempt(word : Pointer(Atomic(UInt64))) : Nil"
  print "    return unless word.address == Pointer(Atomic(UInt64)).new(pointerof(@@forced_word).address).value.get"
  print "    {% if !flag?(:copy_hook_watchdog) %}"
  print "      Pointer(Atomic(UInt64)).new(pointerof(@@forced_attempted).address).value.set(1_u64)"
  print "    {% end %}"
  print "  end"
  print "  def self.force_lost_done(word : Pointer(Atomic(UInt64))) : Nil"
  print "    return unless word.address == Pointer(Atomic(UInt64)).new(pointerof(@@forced_word).address).value.get"
  print "    {% if !flag?(:copy_hook_watchdog) %}"
  print "      Pointer(Atomic(UInt64)).new(pointerof(@@forced_woke).address).value.set(1_u64)"
  print "    {% end %}"
  print "  end"
  print "  def self.force_lost_window(word : Pointer(Atomic(UInt64)), lock : Pointer(Atomic(UInt64))) : Nil"
  print "    return unless word.address == Pointer(Atomic(UInt64)).new(pointerof(@@forced_word).address).value.get"
  print "    entered = Pointer(Atomic(UInt64)).new(pointerof(@@forced_in_window).address)"
  print "    return if entered.value.get != 0_u64"
  print "    locked = lock.value.get != 0_u64"
  print "    entered.value.set(1_u64)"
  print "    attempted = Pointer(Atomic(UInt64)).new(pointerof(@@forced_attempted).address)"
  print "    woke = Pointer(Atomic(UInt64)).new(pointerof(@@forced_woke).address)"
  print "    started = __iyi_monotonic_ns"
  print "    while locked ? attempted.value.get == 0_u64 : woke.value.get == 0_u64"
  print "      IyiThread.spin_pause"
  print "      if __iyi_monotonic_ns - started > 10000000000_i64"
  print "        end_run(76, 2, \"FAIL: lostword: progress hang: the copy hook waited for its wake\\n\")"
  print "      end"
  print "    end"
  print "  end"
  n_defs++
  next
}'
  LOSTWORD_END='END { if (n_park != 1 || n_window != 1 || n_wake != 1 || n_attempt != 1 || n_done != 1 || n_link != 1 || n_link_unlock != 1 || expect_link_unlock || n_chain != 1 || n_lock != 1 || n_unlock != 1 || n_insert != 1 || n_defs != 1 || seq_open != 1 || seq_done != 1 || seq != 0 || n_stray != 0 || at_seq >= at_link || at_attempt >= at_done || at_chain != at_done + 1) exit 3 }'
  broken lostword "$LOSTWORD_COMMON
$LOSTWORD_BUG
$LOSTWORD_DEFS
{ print }
$LOSTWORD_END" concurrency.iyi parallel_exercise -Dlostword_force
  verdict_caught lostword 'wakes, words: the forced first wake was lost before its waiter linked' wakes --only=words --watch=5000
  broken lostword_hook "$LOSTWORD_COMMON
$LOSTWORD_CONTROL
$LOSTWORD_DEFS
{ print }
$LOSTWORD_END" concurrency.iyi parallel_exercise -Dlostword_force
  verdict_held lostword_hook 'wakes, words: the forced first wake claimed the waiter that linked before its scan' wakes --only=words --watch=5000
  broken lostword_watchdog "$LOSTWORD_COMMON
$LOSTWORD_CONTROL
$LOSTWORD_DEFS
{ print }
$LOSTWORD_END" concurrency.iyi parallel_exercise -Dlostword_force -Dcopy_hook_watchdog
  verdict_watchdog lostword_watchdog 'FAIL: lostword: progress hang: the copy hook waited for its wake' wakes --only=words --watch=5000

step "failure proof: a plain add loses counts when two tasks add at once"
# The plain add is a load and a store. race_forced puts one task's add between
# another's load and its store, so the build without atomic adds loses a count
# on its one run; the atomic build keeps both (step 1 runs race_forced there).
if ! "$IYI" build --release -Dparallel_plain_add "$REPO/bench/parallel_exercise.iyi" -o plainadd-run > build-plainadd.log 2>&1; then
  echo "FAIL: plainadd: setup: the copy failed to build"; tail -20 build-plainadd.log; exit 76
fi
verdict_caught plainadd "race: a task stored the count it read before another task's add landed" race_forced

# What a move keeps, broken one way each, and the migration exercise's
# step that names it. A move needs two workers on two cores.
need_cores 2 "a move needs two workers on two cores"
# These mutants are compile-time branches rather than awk-made copies.
# Audit each method and both its mutant and control expressions independently.
TLS_AUDIT='
/^  def state_after\(before : UInt64\) : UInt64$/ { state = 1; n_state++ }
/^  def line_in_loop\(before : UInt64\) : UInt64$/ { line = 1; n_line++ }
state && /^    {% if flag\?\(:parallel_stale_tls\) %}$/ { n_stale++ }
line && /^    {% if flag\?\(:parallel_hoisted_tls\) %}$/ { n_hoisted++ }
state && /^      before$/ { n_state_before++ }
line && /^      before$/ { n_line_before++ }
state && /^      IyiScheduler.state.object_id$/ { n_state_current++ }
line && /^      IyiThread.current_line$/ { n_line_current++ }
/^  end$/ { state = 0; line = 0 }
END { if (n_state != 1 || n_line != 1 || n_stale != 1 || n_hoisted != 1 || n_state_before != 1 || n_line_before != 1 || n_state_current != 1 || n_line_current != 1) exit 3 }'
awk "$TLS_AUDIT" "$REPO/bench/parallel_migrate.iyi" || { echo "FAIL: tls: setup: a mutant or control anchor is missing or duplicated"; exit 76; }
step "failure proof: a thread-local read before a park and kept after it names the thread the task left"
  if ! "$IYI" build --release -Dparallel_stale_tls "$REPO/bench/parallel_migrate.iyi" -o staletls-run > build-staletls.log 2>&1; then
    echo "FAIL: staletls: setup: the copy failed to build"; tail -20 build-staletls.log; exit 76
  fi
  verdict_caught staletls "channels: a thread-local read after a park named another thread than the one the task resumed on" channels
  if ! "$IYI" build --release "$REPO/bench/parallel_migrate.iyi" -o staletls_hook-run > build-staletls-control.log 2>&1; then
    echo "FAIL: staletls_hook: setup: the control failed to build"; tail -20 build-staletls-control.log; exit 76
  fi
  verdict_held staletls_hook "channels: the forced task moved to another worker and its thread-local read named that worker" channels

  step "failure proof: a thread-local read hoisted out of a loop names the thread the task left once the back-edge check moves it"
  if ! "$IYI" build --release -Dparallel_hoisted_tls "$REPO/bench/parallel_migrate.iyi" -o hoistedtls-run > build-hoistedtls.log 2>&1; then
    echo "FAIL: hoistedtls: setup: the copy failed to build"; tail -20 build-hoistedtls.log; exit 76
  fi
  verdict_caught hoistedtls "loops: a thread-local read after a loop's back-edge check named another thread than the one the task was on" loops
  if ! "$IYI" build --release "$REPO/bench/parallel_migrate.iyi" -o hoistedtls_hook-run > build-hoistedtls-control.log 2>&1; then
    echo "FAIL: hoistedtls_hook: setup: the control failed to build"; tail -20 build-hoistedtls-control.log; exit 76
  fi
  verdict_held hoistedtls_hook "loops: the forced loop resumed on another worker and its thread-local read named that worker" loops

  step "failure proof: a collector's stack walk omits a queued fiber's saved stack that held a list's head"
  # Copy only, for the intransit proof of bench/parallel_migrate.iyi (-Dintransit_force). The head is kept complemented,
  # so the global the copy adds is not an address the root walk could take for a retained list. The walk records, for
  # each queued fiber whose saved stack holds the head, the fiber it saw (force_note_seen, before the state test) and
  # the fiber it scanned (force_note_scanned, in the scan). The mutant's walk omits Runnable fibers, so it sees the
  # task's fiber and scans none; the verdict is read there, keyed to the task's fiber. Nothing claims a loss or a reuse.
  INTRANSIT_DEFS='/^      def self.each_fiber_root\(visit : Proc\(UInt64, Nil\)\) : Nil$/ {
  print "      # Copy only, for the intransit proof of bench/parallel_migrate.iyi: the head word the program names, kept complemented,"
  print "      # and the queued fibers whose saved stacks hold it, which the root walk saw and which it scanned."
  print "      @[UnsafeReach(\"set by the program before a collection, read by the walk: atomics only\")]"
  print "      @@forced_head : UInt64 = 0_u64"
  print "      @[UnsafeReach(\"set by the walk, read by the program after it: atomics only\")]"
  print "      @@forced_seen_fiber : UInt64 = 0_u64"
  print "      @[UnsafeReach(\"set by the walk, read by the program after it: atomics only\")]"
  print "      @@forced_scanned_fiber : UInt64 = 0_u64"
  print ""
  print "      def self.force_head_set(head : UInt64) : Nil"
  print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_head).address).value.set(~head)"
  print "      end"
  print ""
  print "      def self.force_seen_fiber : UInt64"
  print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_seen_fiber).address).value.get"
  print "      end"
  print ""
  print "      def self.force_scanned_fiber : UInt64"
  print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_scanned_fiber).address).value.get"
  print "      end"
  print ""
  print "      # Whether the fiber is queued (Runnable) and its saved stack, from its saved pointer to its top, holds the head word."
  print "      def self.force_queued_holds?(fiber : IyiFiber) : Bool"
  print "        stored = Pointer(Atomic(UInt64)).new(pointerof(@@forced_head).address).value.get"
  print "        return false if stored == 0_u64 || fiber.state != IyiFiberState::Runnable || fiber.saved_sp == 0_u64"
  print "        head = ~stored"
  print "        top = fiber.stack_top"
  print "        top = stack_base if top == 0_u64"
  print "        address = fiber.saved_sp"
  print "        while address < top"
  print "          return true if Pointer(UInt64).new(address).value == head"
  print "          address += 8_u64"
  print "        end"
  print "        false"
  print "      end"
  print ""
  print "      def self.force_note_seen(fiber : IyiFiber) : Nil"
  print "        return unless force_queued_holds?(fiber)"
  print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_seen_fiber).address).value.set(fiber.object_id)"
  print "      end"
  print ""
  print "      def self.force_note_scanned(fiber : IyiFiber) : Nil"
  print "        return unless force_queued_holds?(fiber)"
  print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_scanned_fiber).address).value.set(fiber.object_id)"
  print "      end"
  print ""
  print
  n_defs++
  in_walker = 1
  next
}
in_walker && /^      end$/ { in_walker = 0; print; next }
in_walker && /^          while fiber\.is_a\?\(IyiFiber\)$/ { print; print "            force_note_seen(fiber)"; n_seen++; at_seen = NR; next }
in_walker && /^            if fiber\.state != IyiFiberState::Running && fiber\.state != IyiFiberState::Done && fiber\.saved_sp != 0$/ { n_guard++; at_guard = NR }
in_walker && /^              scan_range\(fiber\.saved_sp, top, visit\)$/ { print "              force_note_scanned(fiber)"; print; n_scan++; at_scan = NR; next }'
  INTRANSIT_HOOK="$INTRANSIT_DEFS
{ print }
END { if (n_defs != 1 || n_seen != 1 || n_scan != 1 || n_guard != 1 || at_seen >= at_guard || at_guard >= at_scan) exit 3 }"
  INTRANSIT_BUG="$INTRANSIT_DEFS
in_walker && /^            if fiber\.state != IyiFiberState::Running && fiber\.state != IyiFiberState::Done && fiber\.saved_sp != 0\$/ { print \"            if fiber.state != IyiFiberState::Running && fiber.state != IyiFiberState::Runnable && fiber.state != IyiFiberState::Done && fiber.saved_sp != 0\"; n_skip++; next }
{ print }
END { if (n_defs != 1 || n_seen != 1 || n_scan != 1 || n_guard != 1 || n_skip != 1 || at_seen >= at_guard || at_guard >= at_scan) exit 3 }"
  broken intransit "$INTRANSIT_BUG" prelude.iyi parallel_migrate -Dintransit_force
  verdict_caught intransit "channels: the collector's stack walk omitted a queued fiber's saved stack that held a list's head" channels
  broken intransit_hook "$INTRANSIT_HOOK" prelude.iyi parallel_migrate -Dintransit_force
  verdict_held intransit_hook "channels: the collector's stack walk scanned a queued fiber's saved stack that held a list's head" channels

  step "failure proof: a cancel finds no owner for an io wait that does not say whose poller holds it"
  # Count registrations and cancel_moving calls with a nonzero listed owner.
  # The program cancels only after each reader has switched out, past its
  # own cancellation check.
  # Each anchor is counted once; the awk exits 3 on any other count.
  UNLIST_PRINTS='  print "  # Copy only, for the unlistedio proof of bench/parallel_migrate.iyi: each io wait counts itself once its"
  print "  # registration has run (force_armed). The program reads the count (force_armed_count)."
  print "  @[UnsafeReach(\"bumped by each io wait after its registration, read by the program: atomics only\")]"
  print "  @@forced_armed : UInt64 = 0_u64"
  print ""
  print "  def self.force_armed : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_armed).address).value.add(1_u64)"
  print "  end"
  print ""
  print "  def self.force_armed_count : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_armed).address).value.get"
  print "  end"
  print "  @[UnsafeReach(\"bumped by a cancel that finds the poller of a waiter, read by the program: atomics only\")]"
  print "  @@forced_dispatched : UInt64 = 0_u64"
  print ""
  print "  def self.force_dispatched : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_dispatched).address).value.add(1_u64)"
  print "  end"
  print ""
  print "  def self.force_dispatched_count : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_dispatched).address).value.get"
  print "  end"
  print ""'
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
      UNLIST_ANCHOR='/^  def self.park_overlapped_current\(ms : Int32 = -1\) : Int64 \| Cancelled$/'
      UNLIST_LIST='/^    fiber\.list_on\(st\.object_id\) if @@shared && fiber\.unit\.is_a\?\(IyiUnit\)$/' ;;
    *)
      UNLIST_ANCHOR='/^  def self.wait_posix\(fd : Int32, direction : Int32, ms : Int32\) : Nil \| Cancelled$/'
      UNLIST_LIST='/^    fiber\.list_on\(st\.object_id\) if moving$/' ;;
  esac
  UNLIST_DEFS="$UNLIST_ANCHOR {
$UNLIST_PRINTS
  print
  n_defs++; inowner = 1
  next
}"
  UNLIST_SCOPE='inowner && /^  end$/ { inowner = 0 }
/^  def self.cancel_moving\(fiber : IyiFiber\) : Nil$/ { incancel = 1; n_cancel++ }
incancel && /^  end$/ { incancel = 0 }'
  UNLIST_HOOK_RULE="inowner && $UNLIST_LIST { print; print \"    force_armed\"; n_list++; next }"
  UNLIST_BUG_RULE="inowner && $UNLIST_LIST { print \"    force_armed\"; n_list++; n_mut++; next }"
  UNLIST_DISPATCH_RULE='incancel && /^    return if owner == 0_u64$/ { print; print "    force_dispatched"; n_disp++; next }'
  UNLIST_HOOK="$UNLIST_DEFS
$UNLIST_SCOPE
$UNLIST_HOOK_RULE
$UNLIST_DISPATCH_RULE
{ print }
END { if (n_defs != 1 || n_cancel != 1 || n_list != 1 || n_disp != 1) exit 3 }"
  UNLIST_BUG="$UNLIST_DEFS
$UNLIST_SCOPE
$UNLIST_BUG_RULE
$UNLIST_DISPATCH_RULE
{ print }
END { if (n_defs != 1 || n_cancel != 1 || n_list != 1 || n_disp != 1 || n_mut != 1) exit 3 }"
  broken unlistedio "$UNLIST_BUG" concurrency.iyi parallel_migrate -Dunlistedio_force
  verdict_caught unlistedio "cancel: a cancel found no listed owner for a reader switched out of its io wait" cancel --watch=5000
  broken unlistedio_hook "$UNLIST_HOOK" concurrency.iyi parallel_migrate -Dunlistedio_force
  verdict_held unlistedio_hook "cancel: a cancel found the listed owner of every reader switched out of its io wait, and each read answered Cancelled" cancel --watch=5000

  step "failure proof: a close posted to no thread leaves a read on another worker parked"
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
      echo "  noclose and its registration watchdog control: skipped on Windows, where the completion port handles close without this POSIX post" ;;
    *)
      CLOSE_COMMON='/^  def self.wait_posix\(/ { inwait = 1; n_wait++ }
inwait && /^  end$/ { inwait = 0 }
inwait && /^    fiber.list_on\(st.object_id\) if moving$/ { print; print "    force_close_registered(fd)"; n_reg++; next }
/^  def self.wake_closed\(fd : Int32\) : Nil$/ { inclose = 1; n_close++ }
inclose && /^  end$/ { inclose = 0 }
inclose && /^          other.post_mail$/ { print; print "          force_close_posted(fd)"; n_post++; at_post = NR; next }'
      CLOSE_BUG='inclose && /^      return unless @@shared$/ { print "      force_close_missing(fd)"; print "      return"; n_guard++; at_guard = NR; next }'
      CLOSE_HOOK='inclose && /^      return unless @@shared$/ { n_guard++; at_guard = NR }'
      CLOSE_DEFS='/^  def self.reschedule : Nil$/ {
  print "  @[UnsafeReach(\"copy-only close target, accessed atomically\")]"
  print "  @@forced_close_fd : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only close registration, accessed atomically\")]"
  print "  @@forced_close_registered : UInt64 = 0_u64"
  print "  def self.force_close_target(fd : Int32) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_close_fd).address).value.set(fd.to_u64 + 1_u64)"
  print "  end"
  print "  def self.force_close_registered(fd : Int32) : Nil"
  print "    return unless fd.to_u64 + 1_u64 == Pointer(Atomic(UInt64)).new(pointerof(@@forced_close_fd).address).value.get"
  print "    {% if !flag?(:noclose_withhold_registration) %}"
  print "      Pointer(Atomic(UInt64)).new(pointerof(@@forced_close_registered).address).value.set(1_u64)"
  print "    {% end %}"
  print "  end"
  print "  def self.force_close_registered? : Bool"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_close_registered).address).value.get == 1_u64"
  print "  end"
  print "  def self.force_close_missing(fd : Int32) : Nil"
  print "    return unless fd.to_u64 + 1_u64 == Pointer(Atomic(UInt64)).new(pointerof(@@forced_close_fd).address).value.get"
  print "    unless force_close_registered?"
  print "      end_run(76, 2, \"FAIL: closes: not armed: the target was closed before io registration\\n\")"
  print "    end"
  print "    end_run(1, 1, \"FAIL: closes: the registered target close was not posted to its reader\\n\")"
  print "  end"
  print "  def self.force_close_posted(fd : Int32) : Nil"
  print "    return unless fd.to_u64 + 1_u64 == Pointer(Atomic(UInt64)).new(pointerof(@@forced_close_fd).address).value.get"
  print "    puts \"closes: the registered target close was posted to its reader\""
  print "  end"
  print
  n_defs++
  next
}'
      CLOSE_END='END { if (n_wait != 1 || n_reg != 1 || n_close != 1 || n_post != 1 || n_guard != 1 || at_guard >= at_post || n_defs != 1) exit 3 }'
      broken noclose "$CLOSE_COMMON
$CLOSE_BUG
$CLOSE_DEFS
{ print }
$CLOSE_END" concurrency.iyi parallel_migrate -Dnoclose_force
      verdict_caught noclose 'closes: the registered target close was not posted to its reader' closes --watch=5000
      broken noclose_hook "$CLOSE_COMMON
$CLOSE_HOOK
$CLOSE_DEFS
{ print }
$CLOSE_END" concurrency.iyi parallel_migrate -Dnoclose_force
      verdict_held noclose_hook 'closes: the registered target close was posted to its reader' closes --watch=5000
      broken noclose_watchdog "$CLOSE_COMMON
$CLOSE_HOOK
$CLOSE_DEFS
{ print }
$CLOSE_END" concurrency.iyi parallel_migrate -Dnoclose_force -Dnoclose_withhold_registration
      verdict_watchdog noclose_watchdog 'FAIL: closes: progress hang: the targeted reader did not complete io registration' closes --watch=100 ;;
  esac

  step "failure proof: a read made on the thread that closes its socket is a close that never crossed"
  if ! "$IYI" build --release -Dparallel_closes_home "$REPO/bench/parallel_migrate.iyi" -o closeshome-run > build-closeshome.log 2>&1; then
    echo "FAIL: closeshome: setup: the copy failed to build"; tail -20 build-closeshome.log; exit 76
  fi
  verdict_caught closeshome 'closes: the main thread closed a socket on the thread its reader parked on' closes

  step "failure proof: a join held in the kernel holds its worker, and the sleepers on it"
  JOIN_COMMON='/^    (@\[Effect\([a-z_:]+\)\]; )?def join : Nil$/ {
  print "    @[UnsafeReach(\"copy-only keyed join decision, accessed atomically\")]"
  print "    @@forced_join_thread : UInt64 = 0_u64"
  print "    @[UnsafeReach(\"copy-only keyed join decision, accessed atomically\")]"
  print "    @@forced_join_decision : UInt64 = 0_u64"
  print "    def self.force_join_key(thread : IyiThread) : Nil"
  print "      Pointer(Atomic(UInt64)).new(pointerof(@@forced_join_thread).address).value.set(thread.object_id)"
  print "    end"
  print "    def self.force_join_decision : UInt64"
  print "      Pointer(Atomic(UInt64)).new(pointerof(@@forced_join_decision).address).value.get"
  print "    end"
  print "    def self.force_join_decided(thread : IyiThread, decision : UInt64) : Nil"
  print "      return unless thread.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_join_thread).address).value.get"
  print "      Pointer(Atomic(UInt64)).new(pointerof(@@forced_join_decision).address).value.compare_and_set(0_u64, decision)"
  print "    end"
  print; injoin = 1; n_method++; next
}
injoin && /^    end$/ { injoin = 0 }
injoin && /^      {% if flag\?\(:linux\) %}$/ { print "      IyiThread.force_join_decided(self, @ended.get == 0_u64 ? 2_u64 : 3_u64)"; n_kernel++; at_kernel = NR }'
  JOIN_BUG='injoin && /^      while @ended.get == 0_u64$/ { sequence = 1; n_loop++; at_loop = NR; next }
sequence == 1 { if ($0 != "        IyiScheduler.park_on(pointerof(@ended), 0_u64, false)") exit 3; sequence = 2; n_park++; next }
sequence == 2 { if ($0 != "      end") exit 3; sequence = 0; n_end++; next }
injoin && /^      end$/ { n_other_end++ }'
  JOIN_HOOK='injoin && /^      while @ended.get == 0_u64$/ { sequence = 1; n_loop++; at_loop = NR; print; next }
sequence == 1 { if ($0 != "        IyiScheduler.park_on(pointerof(@ended), 0_u64, false)") exit 3; sequence = 2; n_park++; print "        IyiThread.force_join_decided(self, 1_u64)"; print; next }
sequence == 2 { if ($0 != "      end") exit 3; sequence = 0; n_end++; print; next }
injoin && /^      end$/ { n_other_end++ }'
  JOIN_END='END { if (sequence || n_other_end != 0 || n_method != 1 || n_kernel != 1 || n_loop != 1 || n_park != 1 || n_end != 1 || at_kernel != at_loop + 3) exit 3 }'
  broken kerneljoin "$JOIN_COMMON
$JOIN_BUG
{ print }
$JOIN_END" thread.iyi parallel_migrate -Dkerneljoin_force
  verdict_caught kerneljoin "join: the join of a running thread entered the kernel's join without parking" join
  broken kerneljoin_hook "$JOIN_COMMON
$JOIN_HOOK
{ print }
$JOIN_END" thread.iyi parallel_migrate -Dkerneljoin_force
  verdict_held kerneljoin_hook "join: the join of a running thread took its park path" join

  step "failure proof: a task woken by a task that computes on waits for that computation"
  # The parked target is keyed before its waker is released. The copy records
  # the decision inside push_runnable, before the waker can consume its handoff.
  NOHAND_COMMON='/^  def self.push_runnable\(st : IyiSchedulerState, fiber : IyiFiber\) : Nil$/ {
  print "  @[UnsafeReach(\"copy-only keyed handoff decision, accessed atomically\")]"
  print "  @@forced_handoff_target : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only keyed handoff decision, accessed atomically\")]"
  print "  @@forced_handoff_decision : UInt64 = 0_u64"
  print "  def self.force_handoff_key(id : UInt64) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_handoff_target).address).value.set(id)"
  print "  end"
  print "  def self.force_handoff_decision : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_handoff_decision).address).value.get"
  print "  end"
  print "  def self.force_handoff_decide(fiber : IyiFiber, decision : UInt64) : Nil"
  print "    return unless fiber.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_handoff_target).address).value.get"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_handoff_decision).address).value.compare_and_set(0_u64, decision)"
  print "  end"
  print "  def self.force_handoff_done(st : IyiSchedulerState, fiber : IyiFiber) : Nil"
  print "    force_handoff_decide(fiber, handed_on?(st, fiber) ? (st.handoff_skip == 0_u64 ? 5_u64 : 3_u64) : 4_u64)"
  print "  end"
  print; inpush = 1; n_defs++; next
}
inpush && /^    if st.ring_size > 1_u64$/ { print; print "      force_handoff_decide(fiber, 1_u64)"; n_ring++; at_ring = NR; next }
inpush && /^      skip = st.handoff_skip$/ { print; print "      force_handoff_decide(fiber, skip == 0_u64 ? 2_u64 : 3_u64)"; n_skip++; at_skip = NR; next }
inpush && /^  end$/ { print "    force_handoff_done(st, fiber)"; print; inpush = 0; n_end++; next }'
  NOHAND_BUG='inpush && /^    elsif handed_on\?\(st, fiber\)$/ { print "    elsif false"; n_mut++; at_mut = NR; next }'
  NOHAND_HOOK='inpush && /^    elsif handed_on\?\(st, fiber\)$/ { n_mut++; at_mut = NR }'
  NOHAND_END='END { if (n_defs != 1 || n_ring != 1 || n_skip != 1 || n_end != 1 || n_mut != 1 || at_ring >= at_mut || at_mut >= at_skip) exit 3 }'
  broken nohandoff "$NOHAND_COMMON
$NOHAND_BUG
{ print }
$NOHAND_END" concurrency.iyi parallel_migrate -Dnohandoff_force
  verdict_caught nohandoff 'handoff: an eligible hand-off for a parked task took no hand-off branch' handoff
  broken nohandoff_hook "$NOHAND_COMMON
$NOHAND_HOOK
{ print }
$NOHAND_END" concurrency.iyi parallel_migrate -Dnohandoff_force
  verdict_held nohandoff_hook 'handoff: the eligible hand-off for a parked task took its branch with no back-off' handoff

  step "failure proof: a hand-off for a parked task omits its immediate wake_one call"
  # Copy only, for the nocall proof of bench/parallel_migrate.iyi. Both copies record the hand-off branch's
  # fiber and worker (push_runnable), and wake_one, when it runs on that worker, records the fiber as woken.
  # The mutant differs from the hook-only control by exactly one deleted line: the wake_one that follows
  # `st.handoff_last`. Each anchor is counted once; an awk that finds another count exits 3.
  NOCALL_DEFS='/^  def self.push_runnable\(st : IyiSchedulerState, fiber : IyiFiber\) : Nil$/ {
  print "  # Copy only, for the nocall proof of bench/parallel_migrate.iyi: the hand-off branch records the fiber it took and"
  print "  # its worker, and wake_one, when it runs on that worker, records the fiber as woken."
  print "  @[UnsafeReach(\"set by the hand-off branch, read by wake_one and the program: atomics only\")]"
  print "  @@forced_branch : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"set by the hand-off branch, read by wake_one: atomics only\")]"
  print "  @@forced_worker : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"set by wake_one on the worker of the branch, read by the program: atomics only\")]"
  print "  @@forced_wake : UInt64 = 0_u64"
  print ""
  print "  def self.force_branch(fiber_id : UInt64, worker : UInt64) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_worker).address).value.set(worker)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_branch).address).value.set(fiber_id)"
  print "  end"
  print ""
  print "  def self.force_wake_hook : Nil"
  print "    fiber_id = Pointer(Atomic(UInt64)).new(pointerof(@@forced_branch).address).value.get"
  print "    return if fiber_id == 0_u64"
  print "    return unless Pointer(Atomic(UInt64)).new(pointerof(@@forced_worker).address).value.get == IyiScheduler.state_id"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_wake).address).value.set(fiber_id)"
  print "  end"
  print ""
  print "  def self.force_branch_id : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_branch).address).value.get"
  print "  end"
  print ""
  print "  def self.force_wake_id : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_wake).address).value.get"
  print "  end"
  print ""
  print
  n_defs++; inpush = 1
  next
}
inpush && /^  end$/ { inpush = 0 }
/^  def self.wake_one : Nil$/ { print; print "    force_wake_hook"; n_wake++; next }
inpush && /^        st.handoff_last = fiber.object_id$/ { print "        force_branch(fiber.object_id, st.object_id)"; print; n_hand++; expect = 1; next }'
  NOCALL_HOOK_TAIL='expect { if (!/^        wake_one$/) exit 3; expect = 0; print; next }'
  NOCALL_BUG_TAIL='expect { if (!/^        wake_one$/) exit 3; expect = 0; n_mut++; next }'
  NOCALL_HOOK="$NOCALL_DEFS
$NOCALL_HOOK_TAIL
{ print }
END { if (n_defs != 1 || n_wake != 1 || n_hand != 1 || expect) exit 3 }"
  NOCALL_BUG="$NOCALL_DEFS
$NOCALL_BUG_TAIL
{ print }
END { if (n_defs != 1 || n_wake != 1 || n_hand != 1 || n_mut != 1 || expect) exit 3 }"
  broken nocall "$NOCALL_BUG" concurrency.iyi parallel_migrate -Dnocall_force
  verdict_caught nocall 'nocall: a hand-off for a parked task omitted its immediate wake_one call' handoff
  broken nocall_hook "$NOCALL_HOOK" concurrency.iyi parallel_migrate -Dnocall_force
  verdict_held nocall_hook 'nocall: the hand-off for a parked task made its immediate wake_one call' handoff

  step "failure proof: a monitor that decides a held ring is stuck and omits its wake_one call"
  # Copy only: serialize grabs with the arm, and hide the target ring until
  # the skipped hand-off has a monitor decision with an idle spare. Both
  # copies use the same hooks; every source anchor must match exactly once.
  NOBACK_DEFS='/^  private def self.look : Bool$/ {
  print "  # Copy only: record the target ring and the completed monitor wake decision."
  print "  @[UnsafeReach(\"set by the waker, read by the monitor: atomics only\")]"
  print "  @@forced_target : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"set by the monitor, read by the program: atomics only\")]"
  print "  @@forced_pending : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"set at the look end, read by the program: atomics only\")]"
  print "  @@forced_done : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"set at the look end, read by the program: atomics only\")]"
  print "  @@forced_woke_done : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"set by the monitor, read by the program: atomics only\")]"
  print "  @@forced_idle : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"set by the waker, read by the enqueue: atomics only\")]"
  print "  @@forced_fiber : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"set by the enqueue, read by the program: atomics only\")]"
  print "  @@forced_skipped : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"updated by the monitor and thieves, read by the program: atomics only\")]"
  print "  @@forced_evals : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"updated by thieves, read by the program: atomics only\")]"
  print "  @@forced_turned : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"updated by the monitor, read by the program: atomics only\")]"
  print "  @@forced_ring_size : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"updated by the monitor, read by the program: atomics only\")]"
  print "  @@forced_spinning : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"serializes the armed target with in-flight ring grabs: atomics only\")]"
  print "  @@forced_grab_lock : UInt64 = 0_u64"
  print ""
  print "  def self.force_lock : Nil"
  print "    lock = Pointer(Atomic(UInt64)).new(pointerof(@@forced_grab_lock).address)"
  print "    limit = __iyi_monotonic_ns + 10_000_000_000_i64"
  print "    until lock.value.compare_and_set(0_u64, 1_u64)[1]"
  print "      IyiThread.spin_pause"
  print "      if __iyi_monotonic_ns > limit"
  print "        end_run(76, 2, \"FAIL: backstop: progress hang: the grab gate did not open in 10000 ms\\n\")"
  print "      end"
  print "    end"
  print "  end"
  print ""
  print "  def self.force_unlock : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_grab_lock).address).value.set(0_u64)"
  print "  end"
  print ""
  print "  def self.force_grab(victim : IyiSchedulerState, thief : IyiSchedulerState) : IyiFiber?"
  print "    force_lock"
  print "    fiber = force_steal_held?(victim.object_id) ? nil : grab(victim, thief)"
  print "    force_unlock"
  print "    fiber"
  print "  end"
  print ""
  print "  def self.force_target(worker : UInt64, fiber : UInt64) : Nil"
  print "    force_lock"
  print "    {% if flag?(:copy_hook_watchdog) %}"
  print "      force_lock"
  print "    {% end %}"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_fiber).address).value.set(fiber)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_target).address).value.set(worker)"
  print "    force_unlock"
  print "    IyiScheduler.state.handoff_skip = 1_u64"
  print "  end"
  print ""
  print "  def self.force_held?(worker : UInt64) : Bool"
  print "    target = Pointer(Atomic(UInt64)).new(pointerof(@@forced_target).address).value.get"
  print "    target != 0_u64 && worker == target && Pointer(Atomic(UInt64)).new(pointerof(@@forced_done).address).value.get != target"
  print "  end"
  print ""
  print "  def self.force_steal_held?(worker : UInt64) : Bool"
  print "    return false unless force_held?(worker)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_turned).address).value.add(1_u64)"
  print "    true"
  print "  end"
  print ""
  print "  def self.force_skip(worker : UInt64, fiber : UInt64) : Nil"
  print "    return unless worker == Pointer(Atomic(UInt64)).new(pointerof(@@forced_target).address).value.get"
  print "    return unless fiber == Pointer(Atomic(UInt64)).new(pointerof(@@forced_fiber).address).value.get"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_skipped).address).value.set(1_u64)"
  print "  end"
  print ""
  print "  def self.force_skipped? : Bool"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_skipped).address).value.get == 1_u64"
  print "  end"
  print ""
  print "  def self.force_idle? : Bool"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_idle).address).value.get == 1_u64"
  print "  end"
  print ""
  print "  def self.force_ring(st : IyiSchedulerState) : Bool"
  print "    return false unless force_held?(st.object_id) && force_skipped?"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_evals).address).value.add(1_u64)"
  print "    size = st.ring_size"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_ring_size).address).value.set(size)"
  print "    idle = word(pointerof(@@idle)).value.get"
  print "    spinning = word(pointerof(@@spinning)).value.get"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_spinning).address).value.set(spinning.to_u64)"
  print "    return false unless size == 1_u64 && st.slot(st.ring_head) == Pointer(Atomic(UInt64)).new(pointerof(@@forced_fiber).address).value.get"
  print "    return false unless idle > 0_i64 && spinning == 0_i64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_idle).address).value.set(1_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_pending).address).value.set(st.object_id)"
  print "    true"
  print "  end"
  print ""
  print "  def self.force_look_end(called : Bool) : Nil"
  print "    pending = Pointer(Atomic(UInt64)).new(pointerof(@@forced_pending).address).value.get"
  print "    return if pending == 0_u64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_woke_done).address).value.set(called ? 1_u64 : 0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_done).address).value.set(pending)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_pending).address).value.set(0_u64)"
  print "  end"
  print ""
  print "  def self.force_reset : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_pending).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_done).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_woke_done).address).value.set(0_u64)"
  print "  end"
  print ""
  print "  def self.force_done_id : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_done).address).value.get"
  print "  end"
  print ""
  print "  def self.force_woke_done : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_woke_done).address).value.get"
  print "  end"
  print "  def self.force_figures : String"
  print "    \"evals=#{Pointer(Atomic(UInt64)).new(pointerof(@@forced_evals).address).value.get} ring=#{Pointer(Atomic(UInt64)).new(pointerof(@@forced_ring_size).address).value.get} turned=#{Pointer(Atomic(UInt64)).new(pointerof(@@forced_turned).address).value.get} idle=#{word(pointerof(@@idle)).value.get} spinning=#{Pointer(Atomic(UInt64)).new(pointerof(@@forced_spinning).address).value.get}\""
  print "  end"
  print ""
  print ""
  print
  n_defs++; inlook = 1
  next
}'
  NOBACK_COMMON='inlook && /^  end$/ { inlook = 0 }
/^  def self.push_runnable\(st : IyiSchedulerState, fiber : IyiFiber\) : Nil$/ { inpush = 1; n_push++ }
inpush && /^  end$/ { inpush = 0 }
/^  def self.steal\(st : IyiSchedulerState\) : IyiFiber\?$/ { insteal = 1; n_steal++ }
insteal && /^  end$/ { insteal = 0 }
/^  def self.work_waiting\? : Bool$/ { inwait = 1; n_wait_method++ }
inwait && /^  end$/ { inwait = 0 }
inlook && /^            stuck = true if st.ring_size > 0_u64$/ { print "            if force_held?(st.object_id)"; print "              stuck = true if force_ring(st)"; print "            else"; print; print "            end"; n_ring++; at_ring = NR; next }
inpush && /^        st.handoff_skip = skip &- 1_u64$/ { print "        force_skip(st.object_id, fiber.object_id)"; print; n_skip++; next }
insteal && /^        fiber = grab\(victim, st\)$/ { print "        fiber = force_grab(victim, st)"; n_grab++; next }
inwait && /^      return true if listed_at\(index\)\.ring_size > 0_u64$/ { print "      return true if listed_at(index).ring_size > 0_u64 && !force_held?(listed_at(index).object_id)"; n_wait++; next }'
  NOBACK_HOOK_LOOK='inlook && /^    wake_one if stuck$/ { print; print "    force_look_end(stuck)"; n_look++; at_look = NR; next }'
  NOBACK_BUG_LOOK='inlook && /^    wake_one if stuck$/ { print "    force_look_end(false)"; n_look++; at_look = NR; n_mut++; next }'
  NOBACK_HOOK="$NOBACK_DEFS
$NOBACK_COMMON
$NOBACK_HOOK_LOOK
{ print }
END { if (n_defs != 1 || n_push != 1 || n_steal != 1 || n_wait_method != 1 || n_ring != 1 || n_skip != 1 || n_grab != 1 || n_wait != 1 || n_look != 1 || at_ring >= at_look) exit 3 }"
  NOBACK_BUG="$NOBACK_DEFS
$NOBACK_COMMON
$NOBACK_BUG_LOOK
{ print }
END { if (n_defs != 1 || n_push != 1 || n_steal != 1 || n_wait_method != 1 || n_ring != 1 || n_skip != 1 || n_grab != 1 || n_wait != 1 || n_look != 1 || at_ring >= at_look || n_mut != 1) exit 3 }"
  broken nobackstop "$NOBACK_BUG" concurrency.iyi parallel_migrate -Dnobackstop_force
  verdict_caught nobackstop "backstop: the monitor's stuck decision for a held ring omitted its wake_one call" backstop
  broken nobackstop_hook "$NOBACK_HOOK" concurrency.iyi parallel_migrate -Dnobackstop_force
  verdict_held nobackstop_hook "backstop: the monitor's stuck decision for a held ring called wake_one" backstop
  broken nobackstop_watchdog "$NOBACK_HOOK" concurrency.iyi parallel_migrate -Dnobackstop_force -Dcopy_hook_watchdog
  verdict_watchdog nobackstop_watchdog 'FAIL: backstop: progress hang: the grab gate did not open in 10000 ms' backstop

  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
      echo "  noheldio: skipped on Windows, where the monitor's held-io decision is not compiled (concurrency.iyi's look is unless flag?(:win32)); the completions port has its own proof"
      ;;
    *)
      step "failure proof: a monitor that finds news on a held worker's poller and omits the wake that rings an idle worker"
      # Copy only: record the held-io decision for the selected poller and
      # whether the same monitor look called wake_one at its call site.
      NOHELD_DEFS='/^  private def self.look : Bool$/ {
  print "  # Copy only: record the selected poller and the monitor wake decision."
  print "  @[UnsafeReach(\"set by the program, read by the monitor: atomics only\")]"
  print "  @@forced_target : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"set by the monitor, read by the program: atomics only\")]"
  print "  @@forced_pending : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"set at the look end, read by the program: atomics only\")]"
  print "  @@forced_done : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"set at the look end, read by the program: atomics only\")]"
  print "  @@forced_woke_done : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"set at the look end, read by the program: atomics only\")]"
  print "  @@forced_seq : UInt64 = 0_u64"
  print ""
  print "  def self.force_io_target(worker : UInt64) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_target).address).value.set(worker)"
  print "  end"
  print ""
  print "  def self.force_io_decision(worker : UInt64, held : Bool) : Nil"
  print "    return unless held && worker == Pointer(Atomic(UInt64)).new(pointerof(@@forced_target).address).value.get"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_pending).address).value.set(worker)"
  print "  end"
  print ""
  print "  def self.force_look_end(called : Bool) : Nil"
  print "    pending = Pointer(Atomic(UInt64)).new(pointerof(@@forced_pending).address).value.get"
  print "    return if pending == 0_u64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_woke_done).address).value.set(called ? 1_u64 : 0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_done).address).value.set(pending)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_pending).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_seq).address).value.add(1_u64)"
  print "  end"
  print ""
  print "  def self.force_seq : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_seq).address).value.get"
  print "  end"
  print ""
  print "  def self.force_done_id : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_done).address).value.get"
  print "  end"
  print ""
  print "  def self.force_woke_done : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_woke_done).address).value.get"
  print "  end"
  print ""
  print
  n_defs++; inlook = 1
  next
}
inlook && /^  end$/ { inlook = 0 }'
      NOHELD_LOOK_END='inlook && /^    wake_one if stuck$/ { print; print "    force_look_end(stuck)"; n_look++; at_look = NR; next }'
      NOHELD_HOOK_DECIDE='inlook && /^          stuck = true if held_io\?\(st\)$/ { print "          io_held = held_io?(st)"; print "          force_io_decision(st.object_id, io_held)"; print "          stuck = true if io_held"; n_dec++; at_dec = NR; next }'
      NOHELD_BUG_DECIDE='inlook && /^          stuck = true if held_io\?\(st\)$/ { print "          io_held = held_io?(st)"; print "          force_io_decision(st.object_id, io_held)"; n_dec++; at_dec = NR; n_mut++; next }'
      NOHELD_HOOK="$NOHELD_DEFS
$NOHELD_HOOK_DECIDE
$NOHELD_LOOK_END
{ print }
END { if (n_defs != 1 || n_dec != 1 || n_look != 1 || at_dec >= at_look) exit 3 }"
      NOHELD_BUG="$NOHELD_DEFS
$NOHELD_BUG_DECIDE
$NOHELD_LOOK_END
{ print }
END { if (n_defs != 1 || n_dec != 1 || n_look != 1 || at_dec >= at_look || n_mut != 1) exit 3 }"
      broken noheldio "$NOHELD_BUG" concurrency.iyi parallel_migrate -Dnoheldio_force
      verdict_caught noheldio "heldio: the monitor's held-io decision for a reader's poller omitted the wake that rings an idle worker" heldio
      broken noheldio_hook "$NOHELD_HOOK" concurrency.iyi parallel_migrate -Dnoheldio_force
      verdict_held noheldio_hook "heldio: the answer sent to a reader parked on a held worker was read on another worker before the hold ended" heldio
      ;;
  esac

  need_cores 4 "the balance step is timed against four workers' ideal, so the stealing proofs need four cores"
    step "failure proof: a pool that never steals a started task leaves tasks woken on one worker there"
    # Both copies record the first grab decision for the held waker. The
    # program releases exactly one thief only after the waker's ring is full.
    NOSTEAL_COMMON='/^  def self.preempts : UInt64$/ {
  print "  # Copy only: record the first grab decision for the armed victim."
  print "  @[UnsafeReach(\"set by the program, read by stealing workers: atomics only\")]"
  print "  @@forced_grab_target : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"set by a stealing worker, read by the program: atomics only\")]"
  print "  @@forced_grab_result : UInt64 = 0_u64"
  print ""
  print "  def self.force_grab_arm(state : UInt64) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_grab_result).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_grab_target).address).value.set(state)"
  print "  end"
  print ""
  print "  def self.force_grab_decided(victim : IyiSchedulerState, fiber : IyiFiber?) : Nil"
  print "    return unless victim.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_grab_target).address).value.get"
  print "    decision = fiber.is_a?(IyiFiber) ? 1_u64 : 2_u64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_grab_result).address).value.compare_and_set(0_u64, decision)"
  print "  end"
  print ""
  print "  def self.force_grab_result : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_grab_result).address).value.get"
  print "  end"
  print ""
  print
  n_defs++
  next
}
/^  def self.steal\(st : IyiSchedulerState\) : IyiFiber\?$/ { in_steal = 1; n_steal++ }
in_steal && /^  end$/ { in_steal = 0 }
in_steal && /^        fiber = grab\(victim, st\)$/ { print; print "        force_grab_decided(victim, fiber)"; n_dec++; at_dec = NR; next }
in_steal && /^        if fiber\.is_a\?\(IyiFiber\)$/ { n_next++; at_next = NR }
/^  def self.grab\(victim : IyiSchedulerState, thief : IyiSchedulerState\) : IyiFiber\?$/ { n_grab++ }'
    NOSTEAL_HOOK="$NOSTEAL_COMMON"'
{ print }
END { if (n_defs != 1 || n_steal != 1 || n_dec != 1 || n_next != 1 || at_next != at_dec + 1 || n_grab != 1) exit 3 }'
    NOSTEAL_BUG="$NOSTEAL_COMMON"'
/^  def self.grab\(victim : IyiSchedulerState, thief : IyiSchedulerState\) : IyiFiber\?$/ { print; print "    return nil"; n_bug++; next }
{ print }
END { if (n_defs != 1 || n_steal != 1 || n_dec != 1 || n_next != 1 || at_next != at_dec + 1 || n_grab != 1 || n_bug != 1) exit 3 }'
    broken nosteal "$NOSTEAL_BUG" concurrency.iyi parallel_migrate -Dnosteal_force
    verdict_caught nosteal "balance: a worker looking for work took none of the tasks woken into a held worker's ring" balance
    broken nosteal_hook "$NOSTEAL_HOOK" concurrency.iyi parallel_migrate -Dnosteal_force
    verdict_held nosteal_hook "balance: a worker looking for work took tasks woken into a held worker's ring" balance

    step "failure proof: tasks woken back onto the worker they parked on, as before tasks moved"
    # Both copies record the target fiber's actual route in ready: 1 for
    # the shared queue, or the parked worker's state for its inbox.
    PIN_DEFS='/^  def self.ready\(fiber : IyiFiber, held : Bool = true\) : Nil$/ {
  print "  @[UnsafeReach(\"set by the program, read by ready: atomics only\")]"
  print "  @@forced_pin_target : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"set by ready, read by the program: atomics only\")]"
  print "  @@forced_pin_route : UInt64 = 0_u64"
  print ""
  print "  def self.force_pin_target(id : UInt64) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_pin_target).address).value.set(id)"
  print "  end"
  print ""
  print "  def self.force_pin_note(fiber : IyiFiber, to : UInt64) : Nil"
  print "    return unless fiber.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_pin_target).address).value.get"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_pin_route).address).value.compare_and_set(0_u64, to)"
  print "  end"
  print ""
  print "  def self.force_pin_route : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_pin_route).address).value.get"
  print "  end"
  print ""
  print
  in_ready = 1
  n_defs++
  next
}
in_ready && /^  end$/ { in_ready = 0 }
in_ready && /^          IyiWorkers\.push_shared\(fiber\)$/ { print "          force_pin_note(fiber, 1_u64)"; print; n_shared++; at_shared = NR; next }
in_ready && /^    send_home\(home, fiber\)$/ { print "    force_pin_note(fiber, home.object_id)"; print; n_home++; at_home = NR; next }'
    PIN_HOOK="$PIN_DEFS"'
/^  private def self.look : Bool$/ { in_look = 1; n_look++ }
in_look && /^  end$/ { in_look = 0 }
in_look && /^            Pointer\(Atomic\(UInt64\)\).new\(address\).value.set\(1_u64\) if address != 0_u64$/ { n_pre++ }
in_ready && /^      if fiber.unit.is_a\?\(IyiUnit\) && !fiber.homebound$/ { n_ready++; at_ready = NR }
/^  def self.grab\(victim : IyiSchedulerState, thief : IyiSchedulerState\) : IyiFiber\?$/ { n_grab++ }
{ print }
END { if (n_defs != 1 || n_shared != 1 || n_home != 1 || n_look != 1 || n_pre != 1 || n_ready != 1 || at_ready >= at_shared || at_shared >= at_home || n_grab != 1) exit 3 }'
    PIN_BUG="$PIN_DEFS"'
/^  private def self.look : Bool$/ { in_look = 1; n_look++ }
in_look && /^  end$/ { in_look = 0 }
in_look && /^            Pointer\(Atomic\(UInt64\)\).new\(address\).value.set\(1_u64\) if address != 0_u64$/ { n_pre++; next }
in_ready && /^      if fiber.unit.is_a\?\(IyiUnit\) && !fiber.homebound$/ { print "      if false"; n_ready++; at_ready = NR; next }
/^  def self.grab\(victim : IyiSchedulerState, thief : IyiSchedulerState\) : IyiFiber\?$/ { print; print "    return nil"; n_grab++; next }
{ print }
END { if (n_defs != 1 || n_shared != 1 || n_home != 1 || n_look != 1 || n_pre != 1 || n_ready != 1 || at_ready >= at_shared || at_shared >= at_home || n_grab != 1) exit 3 }'
    broken pinned "$PIN_BUG" concurrency.iyi parallel_migrate -Dpinned_force
    verdict_caught pinned "balance: a task woken from the main thread was sent back to the worker it parked on" balance
    broken pinned_hook "$PIN_HOOK" concurrency.iyi parallel_migrate -Dpinned_force
    verdict_held pinned_hook "balance: a task woken from the main thread was queued for the pool and resumed on a spare while the worker it parked on was held" balance

# Both copies publish an eligible scheduler decision, not merely a changed
# switch count. The target waits inside the slow path through a lock refusal.
TURN_COMMON='/^class IyiWorkers$/ { in_turn_workers = 1; n_turn_workers++ }
in_turn_workers && /^end$/ { in_turn_workers = 0 }
in_turn_workers && /^  def self.preempts : UInt64$/ {
  n_turn_defs++; at_turn_defs = NR
  print "  @[UnsafeReach(\"copy-only forced turn target, accessed atomically\")]"
  print "  @@force_turn_fiber : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only forced turn worker, accessed atomically\")]"
  print "  @@force_turn_worker : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only forced turn switch count, accessed atomically\")]"
  print "  @@force_turn_switches : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only forced turn rendezvous, accessed atomically\")]"
  print "  @@force_turn_phase : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only eligible decision, accessed atomically\")]"
  print "  @@force_turn_eligible : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only forced turn result, accessed atomically\")]"
  print "  @@force_turn_result : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only forced turn site, accessed atomically\")]"
  print "  @@force_turn_key : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only forced turn instance, accessed atomically\")]"
  print "  @@force_turn_instance : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only forced turn loop run, accessed atomically\")]"
  print "  @@force_turn_run : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only forced turn child, accessed atomically\")]"
  print "  @@force_turn_child : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only give-up worker, accessed atomically\")]"
  print "  @@force_turn_giveup : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only child decision, accessed atomically\")]"
  print "  @@force_turn_child_result : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only slow-path watchdog ownership, accessed atomically\")]"
  print "  @@force_turn_slow_active : UInt64 = 0_u64"
  print "  def self.force_turn_arm(fiber : UInt64, key : UInt64 = 0_u64) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_fiber).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_worker).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_switches).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_phase).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_eligible).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_result).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_key).address).value.set(key)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_instance).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_run).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_child).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_giveup).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_child_result).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_slow_active).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_fiber).address).value.set(fiber)"
  print "  end"
  print "  def self.force_turn_ready? : Bool"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_phase).address).value.get == 1_u64"
  print "  end"
  print "  def self.force_turn_release : Nil"
  print "    {% if !flag?(:copy_hook_watchdog) %}"
  print "      Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_phase).address).value.compare_and_set(1_u64, 2_u64)"
  print "    {% end %}"
  print "  end"
  print "  def self.force_turn_result : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_result).address).value.get"
  print "  end"
  print "  def self.force_turn_child_arm(child : UInt64) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_child).address).value.set(child)"
  print "  end"
  print "  def self.force_turn_child_result : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_child_result).address).value.get"
  print "  end"
  print "  @[NoPreempt]"
  print "  def self.force_turn_giveup_enter(st : IyiSchedulerState, fiber : IyiFiber) : Nil"
  print "    return if Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_child).address).value.get == 0_u64"
  print "    return unless fiber.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_fiber).address).value.get"
  print "    return unless Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_phase).address).value.get == 2_u64"
  print "    return unless st.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_worker).address).value.get"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_giveup).address).value.set(st.object_id)"
  print "  end"
  print "  @[NoPreempt]"
  print "  def self.force_turn_candidate(st : IyiSchedulerState, fiber : IyiFiber) : Nil"
  print "    return unless st.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_giveup).address).value.get"
  print "    return if fiber.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_child).address).value.get"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_child_result).address).value.set(3_u64)"
  print "  end"
  print "  @[NoPreempt]"
  print "  def self.force_turn_child_deferred(st : IyiSchedulerState, fiber : IyiFiber) : Nil"
  print "    return unless st.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_giveup).address).value.get"
  print "    return unless fiber.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_child).address).value.get"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_child_result).address).value.compare_and_set(0_u64, 1_u64)"
  print "  end"
  print "  @[NoPreempt]"
  print "  def self.force_turn_giveup_done(st : IyiSchedulerState, following : IyiFiber?) : Nil"
  print "    active = Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_giveup).address)"
  print "    return unless st.object_id == active.value.get"
  print "    result = Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_child_result).address)"
  print "    unless result.value.get == 3_u64"
  print "      if following.is_a?(IyiFiber)"
  print "        child = Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_child).address).value.get"
  print "        result.value.set(following.object_id == child ? 2_u64 : 3_u64)"
  print "      elsif result.value.get != 1_u64"
  print "        result.value.set(3_u64)"
  print "      end"
  print "    end"
  print "    active.value.set(0_u64)"
  print "  end"
  print "  def self.force_turn_unit_waiting? : Bool"
  print "    unit = IyiScheduler.current.unit"
  print "    unit.is_a?(IyiUnit) && unit.waiting?"
  print "  end"
  print "  @[NoPreempt]"
  print "  def self.force_turn_target_on?(st : IyiSchedulerState) : Bool"
  print "    target = Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_fiber).address).value.get"
  print "    return false if target == 0_u64 || force_turn_result != 0_u64"
  print "    return false unless Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_phase).address).value.get == 2_u64"
  print "    return false unless st.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_worker).address).value.get"
  print "    fiber = IyiScheduler.current?"
  print "    fiber.is_a?(IyiFiber) && fiber.object_id == target"
  print "  end"
  print "  def self.force_turn_slow_active? : Bool"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_slow_active).address).value.get == 1_u64"
  print "  end"
  print "  def self.force_turn_outer_claim? : Bool"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_slow_active).address).value.compare_and_set(0_u64, 2_u64)[1]"
  print "  end"
  print "  @[NoPreempt]"
  print "  def self.force_turn_wait_lock : Nil"
  print "    end_run(76, 2, \"FAIL: forced turn: not armed: the target holds the scheduler lock at its check\\n\") if IyiSchedLock.held_here?"
  print "    owner = Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_slow_active).address)"
  print "    until owner.value.compare_and_set(0_u64, 1_u64)[1]"
  print "      IyiThread.park_if_requested"
  print "      IyiThread.spin_pause"
  print "    end"
  print "    started = __iyi_monotonic_ns"
  print "    while IyiRuntimeLock.held?"
  print "      IyiThread.park_if_requested"
  print "      IyiThread.spin_pause"
  print "      end_run(76, 2, \"FAIL: forced turn: progress hang: the runtime lock did not clear at the eligible check in 20000 ms\\n\") if __iyi_monotonic_ns - started > 20000000000_i64"
  print "    end"
  print "    owner.value.set(0_u64)"
  print "  end"
  print "  @[NoPreempt]"
  print "  def self.force_turn_decided(st : IyiSchedulerState, fiber : IyiFiber) : Nil"
  print "    return unless fiber.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_fiber).address).value.get"
  print "    return unless Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_phase).address).value.get == 2_u64"
  print "    return unless st.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_worker).address).value.get"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_eligible).address).value.compare_and_set(0_u64, 1_u64)"
  print "  end"
  print "  @[NoPreempt]"
  print "  def self.force_turn(key : UInt64 = 0_u64, instance : UInt64 = 0_u64, run : UInt64 = 0_u64, successor : Bool = true) : Nil"
  print "    target = Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_fiber).address).value.get"
  print "    return if target == 0_u64 || force_turn_result != 0_u64"
  print "    fiber = IyiScheduler.current?"
  print "    return unless fiber.is_a?(IyiFiber) && fiber.object_id == target"
  print "    phase = Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_phase).address)"
  print "    wanted = Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_key).address).value.get"
  print "    if key != wanted"
  print "      end_run(76, 2, \"FAIL: forced turn: not armed: the target entered another hook site before its decision\\n\") if phase.value.get == 2_u64"
  print "      return"
  print "    end"
  print "    st = IyiScheduler.state"
  print "    end_run(76, 2, \"FAIL: forced turn: not armed: the target'"'"'s worker has no preemption word\\n\") if st.preempt_word == 0_u64"
  print "    word = Pointer(Atomic(UInt64)).new(st.preempt_word)"
  print "    worker = Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_worker).address)"
  print "    switches = Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_switches).address)"
  print "    eligible = Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_eligible).address)"
  print "    result = Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_result).address)"
  print "    saved_instance = Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_instance).address)"
  print "    saved_run = Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_run).address)"
  print "    if phase.value.get == 0_u64"
  print "      end_run(76, 2, \"FAIL: forced turn: not armed: the target turn has no successor in its loop\\n\") unless successor"
  print "      owner = Pointer(Atomic(UInt64)).new(pointerof(@@force_turn_slow_active).address)"
  print "      until owner.value.compare_and_set(0_u64, 1_u64)[1]"
  print "        IyiThread.park_if_requested"
  print "        IyiThread.spin_pause"
  print "      end"
  print "      worker.value.set(st.object_id)"
  print "      saved_instance.value.set(instance)"
  print "      saved_run.value.set(run)"
  print "      phase.value.set(1_u64)"
  print "      started = __iyi_monotonic_ns"
  print "      while phase.value.get == 1_u64"
  print "        IyiThread.park_if_requested"
  print "        IyiThread.spin_pause"
  print "        end_run(76, 2, \"FAIL: forced turn: progress hang: the held turn was not released in 20000 ms\\n\") if __iyi_monotonic_ns - started > 20000000000_i64"
  print "      end"
  print "      owner.value.set(0_u64)"
  print "      switches.value.set(st.switches)"
  print "      word.value.set(1_u64)"
  print "      return"
  print "    end"
  print "    end_run(76, 2, \"FAIL: forced turn: not armed: the target turned on another worker\\n\") unless st.object_id == worker.value.get"
  print "    end_run(76, 2, \"FAIL: forced turn: not armed: the target turned in another loop instance\\n\") unless instance == saved_instance.value.get && run == saved_run.value.get"
  print "    if eligible.value.get != 0_u64"
  print "      result.value.compare_and_set(0_u64, 1_u64)"
  print "      return"
  print "    end"
  print "    if st.switches == switches.value.get"
  print "      end_run(76, 2, \"FAIL: forced turn: not armed: the raised word went down with no check and no switch\\n\") if word.value.get == 0_u64"
  print "      result.value.compare_and_set(0_u64, 2_u64)"
  print "      return"
  print "    end"
  print "    end_run(76, 2, \"FAIL: forced turn: not armed: the check returned before an eligible decision\\n\")"
  print "  end"
  print ""
  print; next
}
/^  def self.worker_next\(st : IyiSchedulerState\) : IyiFiber\?$/ { in_turn_next = 1; n_turn_next++ }
in_turn_next && /^  end$/ { in_turn_next = 0 }
in_turn_next && /^        return nil unless fiber.is_a\?\(IyiFiber\)$/ { n_turn_candidate_guard++; at_turn_candidate_guard = NR }
in_turn_next && /^        return fiber if take_unit\(st, fiber\)$/ {
  n_turn_candidate++; at_turn_candidate = NR
  print "        IyiWorkers.force_turn_candidate(st, fiber)"; print; next
}
/^  def self.take_unit\(st : IyiSchedulerState, fiber : IyiFiber\) : Bool$/ { in_turn_take = 1; n_turn_take++ }
in_turn_take && /^  end$/ { in_turn_take = 0 }
in_turn_take && /^        unit.waiting = true$/ {
  n_turn_deferred++; at_turn_deferred = NR
  print; print "        IyiWorkers.force_turn_child_deferred(st, fiber)"; next
}
in_turn_take && /^        drain_unit\(st, unit\) if unit.holder == 0_u64$/ { n_turn_drain++; at_turn_drain = NR }
in_turn_workers && /^  private def self.give_up\(st : IyiSchedulerState, fiber : IyiFiber\) : Nil$/ { in_turn_giveup_common = 1; n_turn_giveup++ }
in_turn_giveup_common && /^  end$/ { in_turn_giveup_common = 0 }
in_turn_giveup_common && /^      st.unit = nil$/ { n_turn_handed++; at_turn_handed = NR }
in_turn_giveup_common && /^      following = IyiScheduler.worker_next\(st\)$/ {
  n_turn_following++; at_turn_following = NR
  print "      force_turn_giveup_enter(st, fiber)"; print; print "      force_turn_giveup_done(st, following)"; next
}
in_turn_workers && /^    IyiStat\.atomic\(IyiStat::PREEMPTS\)\.value\.get$/ { n_turn_body++; at_turn_body = NR }
in_turn_workers && /^  def self.preempted : Nil$/ { in_turn_preempted = 1; n_turn_preempted++ }
in_turn_preempted && /^  end$/ { in_turn_preempted = 0 }
in_turn_preempted && /^      return if IyiSchedLock.held_here\? \|\| IyiRuntimeLock.held\?$/ {
  n_turn_refusal++; at_turn_refusal = NR
  print "      if force_turn_target_on?(st)"
  print "        force_turn_wait_lock"
  print "      else"
  print
  print "      end"
  next
}
in_turn_preempted && /^      pay$/ { n_turn_pay++; at_turn_pay = NR }
in_turn_preempted && /^      give_up\(st, fiber\) if turn_wanted\?\(st, fiber\)$/ {
  n_turn_site++; at_turn_site = NR
  print "      force_turn_decided(st, fiber)"; print; next
}'
TURN_CHECK='n_turn_workers != 1 || n_turn_defs != 1 || n_turn_body != 1 || at_turn_body != at_turn_defs + 1 || n_turn_preempted != 1 || n_turn_refusal != 1 || n_turn_pay != 1 || at_turn_refusal >= at_turn_pay || n_turn_site != 1 || at_turn_site != at_turn_pay + 4 || n_turn_next != 1 || n_turn_candidate_guard != 1 || n_turn_candidate != 1 || at_turn_candidate != at_turn_candidate_guard + 1 || n_turn_take != 1 || n_turn_deferred != 1 || n_turn_drain != 1 || at_turn_drain != at_turn_deferred + 1 || n_turn_giveup != 1 || n_turn_handed != 1 || n_turn_following != 1 || at_turn_following != at_turn_handed + 1'
TURN="$TURN_COMMON
{ print }
END { if ($TURN_CHECK) exit 3 }"
TOKENLESS_BUG='/^  private def self.give_up\(st : IyiSchedulerState, fiber : IyiFiber\) : Nil$/ { in_turn_giveup = 1; n_giveup++ }
in_turn_giveup && /^  end$/ { in_turn_giveup = 0 }
in_turn_giveup && /^      return unless unit.hand_to_yielded\(id\)$/ { n_handed++; print "      unit.give"; next }'
TURN_TOKENLESS="$TURN_COMMON
$TOKENLESS_BUG
{ print }
END { if ($TURN_CHECK || n_giveup != 1 || n_handed != 1) exit 3 }"

step "failure proof: a loop marked @[NoPreempt] holds its worker for its whole computation"
broken preemptoff "$TURN" concurrency.iyi parallel_preempt -Dslice_force -Dpreempt_off
verdict_caught preemptoff "slice: the walk turned with its worker's word raised and kept its worker" slice --workers=1
broken preemptoff_hook "$TURN" concurrency.iyi parallel_preempt -Dslice_force
verdict_held preemptoff_hook "slice: the walk gave its worker up at the turn after its word was raised" slice --workers=1
broken forced_turn_watchdog "$TURN" concurrency.iyi parallel_preempt -Dslice_force -Dcopy_hook_watchdog
verdict_watchdog forced_turn_watchdog 'FAIL: forced turn: progress hang: the held turn was not released in 20000 ms' slice --workers=1
broken turn_refusal_watchdog "$TURN" concurrency.iyi parallel_preempt -Dslice_force -Dturn_refusal_watchdog
verdict_watchdog turn_refusal_watchdog 'FAIL: forced turn: progress hang: the runtime lock did not clear at the eligible check in 20000 ms' slice --workers=1
step "failure proof: a vectorizable sum without preemption keeps its worker"
broken sumoff "$TURN" concurrency.iyi parallel_preempt --release --emit llvm-ir -Dsum_force -Dpreempt_off
verdict_caught sumoff "slice: the sum turned with its worker's word raised and kept its worker" slice --workers=1
broken sumoff_hook "$TURN" concurrency.iyi parallel_preempt --release --emit llvm-ir -Dsum_force
if ! awk '
  /^define / {
    line = $0
    gsub(/\.3A\./, ":", line)
    gsub(/\.3C\./, "<", line)
    inside = (line ~ /ParallelPreempt::forced_sum</)
    if (inside) found++
    next
  }
  inside && /^}/ { inside = 0; next }
  inside && index($0, "call void @__iyi_preempt()") { checks++ }
  inside && /[[:space:]]add[[:space:]].*<[0-9]+ x i64>/ { vector_add++ }
  END {
    if (found != 1 || checks == 0) {
      print "FAIL: sumoff_hook: setup: the checked forced_sum body or its preemption check is missing"
      exit 76
    }
    if (vector_add > 0) print "  forced_sum: the release IR contains vector integer addition"
    else print "  forced_sum: vectorization is not proven by the release IR"
  }
' sumoff_hook-run.ll; then
  exit 76
fi
verdict_held sumoff_hook "slice: the sum gave its worker up at the turn after its word was raised" slice --workers=1

step "failure proof: a monitor that never raises a worker's word preempts nothing"
# At the armed worker's first decision, both copies lower its word just
# before the store position and record the word afterward. Only the mutant
# omits the store.
NOFLAG_COMMON='/^  def self.preempts : UInt64$/ {
  print "  @[UnsafeReach(\"armed by the held task, read by the monitor: atomics only\")]"
  print "  @@forced_flag_target : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"set by the monitor, read by the held task: atomics only\")]"
  print "  @@forced_flag_seen : UInt64 = 0_u64"
  print ""
  print "  def self.force_flag_arm(state : UInt64) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_flag_target).address).value.set(state)"
  print "  end"
  print ""
  print "  def self.force_flag_prepare(st : IyiSchedulerState, address : UInt64) : Nil"
  print "    return unless st.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_flag_target).address).value.get"
  print "    return if address == 0_u64"
  print "    return unless Pointer(Atomic(UInt64)).new(pointerof(@@forced_flag_seen).address).value.get == 0_u64"
  print "    Pointer(Atomic(UInt64)).new(address).value.set(0_u64)"
  print "  end"
  print ""
  print "  def self.force_flag_decision(st : IyiSchedulerState, address : UInt64) : Nil"
  print "    return unless st.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_flag_target).address).value.get"
  print "    return if address == 0_u64"
  print "    seen = Pointer(Atomic(UInt64)).new(address).value.get == 0_u64 ? 1_u64 : 2_u64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_flag_seen).address).value.compare_and_set(0_u64, seen)"
  print "  end"
  print ""
  print "  def self.force_flag_seen : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_flag_seen).address).value.get"
  print "  end"
  print ""
  print
  n_defs++
  next
}
/^  private def self.look : Bool$/ { in_look = 1; n_look++ }
in_look && /^  end$/ { in_look = 0 }
in_look && /^            Pointer\(Atomic\(UInt64\)\).new\(address\).value.set\(1_u64\) if address != 0_u64$/ {
  n_store++; at_store = NR
  print "            force_flag_prepare(st, address)"
  if (!drop_raise) print
  print "            force_flag_decision(st, address)"
  next
}
in_look && /^            stuck = true if st\.ring_size > 0_u64$/ { n_stuck++; at_stuck = NR }'
NOFLAG_HOOK="$NOFLAG_COMMON"'
{ print }
END { if (n_defs != 1 || n_look != 1 || n_store != 1 || n_stuck != 1 || at_stuck != at_store + 1) exit 3 }'
NOFLAG_BUG='BEGIN { drop_raise = 1 }
'"$NOFLAG_COMMON"'
{ print }
END { if (n_defs != 1 || n_look != 1 || n_store != 1 || n_stuck != 1 || at_stuck != at_store + 1) exit 3 }'
broken noflag "$NOFLAG_BUG" concurrency.iyi parallel_preempt -Dnoflag_force
verdict_caught noflag "slice: the monitor's preemption decision for a held worker left its word down" slice --workers=1
broken noflag_hook "$NOFLAG_HOOK" concurrency.iyi parallel_preempt -Dnoflag_force
verdict_held noflag_hook "slice: the monitor's preemption decision for a held worker raised its word" slice --workers=1

# Both copies make, set and wait on the high-resolution timer before the
# mutant drops its handle. Setup and wait failures have separate verdicts.
step "failure proof: a Windows monitor using the semaphore fallback for an active tick"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    COARSE_COMMON='/^  (@\[Effect\([a-z_:]+\)\]; )?def self.start_monitor : Nil$/ { instart = 1; n_start++ }
instart && /^  end$/ { instart = 0 }
/^  (@\[Effect\([a-z_:]+\)\]; )?private def self.monitor_wait\(parked : Bool\) : Nil$/ { inwait = 1; n_wait++ }
inwait && /^  end$/ { inwait = 0 }
inwait && /^        if set != 0_i32$/ { print "        force_tick_fail(4_u64) if set == 0_i32"; print; n_set++; at_set = NR; next }
inwait && /^          LibC.WaitForSingleObject\(timer, -1_i32\)$/ { print "          waited = LibC.WaitForSingleObject(timer, -1_i32)"; print "          force_tick_fail(3_u64) if waited != 0_i32"; print "          force_tick_record(1_u64) if waited == 0_i32"; n_timer_wait++; at_timer = NR; next }
inwait && /^      LibC.WaitForSingleObject\(Pointer\(Void\).new\(@@monitor_handle\), parked \? -1_i32 : PREEMPT_TICK_MS\)$/ { print "      fallback = LibC.WaitForSingleObject(Pointer(Void).new(@@monitor_handle), parked ? -1_i32 : PREEMPT_TICK_MS)"; print "      force_tick_fail(6_u64) if !parked && fallback == -1_i32"; print "      force_tick_record(2_u64) if !parked && fallback != -1_i32"; n_fallback++; at_fallback = NR; next }
/^  def self.monitor_entry : UInt64$/ {
  print "  @[UnsafeReach(\"copy-only monitor tick observation, accessed atomically\")]"
  print "  @@forced_tick_armed : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only monitor tick observation, accessed atomically\")]"
  print "  @@forced_tick_result : UInt64 = 0_u64"
  print "  def self.force_tick_arm : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_tick_armed).address).value.set(1_u64)"
  print "  end"
  print "  def self.force_tick_wait : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_tick_result).address).value.get"
  print "  end"
  print "  def self.force_tick_record(result : UInt64) : Nil"
  print "    return unless Pointer(Atomic(UInt64)).new(pointerof(@@forced_tick_armed).address).value.get == 1_u64"
  print "    stored = Pointer(Atomic(UInt64)).new(pointerof(@@forced_tick_result).address)"
  print "    stored.value.compare_and_set(0_u64, result)"
  print "  end"
  print "  def self.force_tick_fail(result : UInt64) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_tick_result).address).value.compare_and_set(0_u64, result)"
  print "  end"
  print "  def self.force_tick_made(timer : Pointer(Void)) : Nil"
  print "    if timer.address == 0_u64"
  print "      force_tick_fail(5_u64)"
  print "      return"
  print "    end"
  print "    due = 0_i64 - (PREEMPT_TICK_NS // 100_u64).to_i64"
  print "    if LibC.SetWaitableTimer(timer, pointerof(due), 0_i32, Pointer(Void).new(0_u64), Pointer(Void).new(0_u64), 0_i32) == 0_i32"
  print "      force_tick_fail(4_u64)"
  print "      return"
  print "    end"
  print "    force_tick_fail(3_u64) if LibC.WaitForSingleObject(timer, 1000_i32) != 0_i32"
  print "  end"
  print
  n_defs++
  next
}'
    COARSE_BUG='instart && /^        @@monitor_timer = timer.address$/ { print "        force_tick_made(timer)"; print "        @@monitor_timer = 0_u64"; n_assignment++; next }'
    COARSE_HOOK='instart && /^        @@monitor_timer = timer.address$/ { print "        force_tick_made(timer)"; n_assignment++ }'
    COARSE_END='END { if (n_start != 1 || n_wait != 1 || n_set != 1 || n_timer_wait != 1 || n_fallback != 1 || at_set >= at_timer || at_timer >= at_fallback || n_defs != 1 || n_assignment != 1) exit 3 }'
    broken coarse "$COARSE_COMMON
$COARSE_BUG
{ print }
$COARSE_END" concurrency.iyi parallel_preempt -Dcoarse_force
    verdict_caught coarse 'period: the active monitor used the semaphore fallback' period --workers=1
    broken coarse_hook "$COARSE_COMMON
$COARSE_HOOK
{ print }
$COARSE_END" concurrency.iyi parallel_preempt -Dcoarse_force
    verdict_held coarse_hook 'period: the active monitor used its high-resolution timer' period --workers=1 ;;
  *)
    echo "  the monitor's tick here is the kernel's own timeout, and there is no system timer for it to fall back to" ;;
esac

# Copy only: the monitor's raise is held to one unchanged look by the hook-only
# control and to three by the mutant (PREEMPT_TICKS = 3). The program reads the
# last raise and its count of unchanged looks. Nothing here times a turn; the
# look counts a real turn takes are printed by the period step as information.
step "failure proof: a monitor that raises a worker's word after three unchanged looks"
  # Copy only, for the slowturn proof of bench/parallel_preempt.iyi (-Dslowturn_force). Both copies save the unchanged
  # looks at each raise (force_pending_ticks, before the reset) and count each raise at the store of the worker's word
  # (force_raise, after the nonzero-address store). The mutant differs from the hook-only control only in PREEMPT_TICKS.
  # The program reads the last raise: exactly one unchanged look is the control, exactly three the mutant. Zero is unarmed.
  SLOW_DEFS='/^  def self.preempts : UInt64$/ {
  print "  # Copy only, for the slowturn proof of bench/parallel_preempt.iyi: the unchanged looks each raise came after, and"
  print "  # the number of raises. The store of the worker word is where a raise is counted (force_raise)."
  print "  @[UnsafeReach(\"set by the monitor look, read by the program: atomics only\")]"
  print "  @@forced_pending_ticks : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"set by the monitor look, read by the program: atomics only\")]"
  print "  @@forced_raise_count : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"set by the monitor look, read by the program: atomics only\")]"
  print "  @@forced_raise_ticks : UInt64 = 0_u64"
  print ""
  print "  def self.force_pending_ticks(ticks : UInt64) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_pending_ticks).address).value.set(ticks)"
  print "  end"
  print ""
  print "  def self.force_raise : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_raise_ticks).address).value.set(Pointer(Atomic(UInt64)).new(pointerof(@@forced_pending_ticks).address).value.get)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_raise_count).address).value.add(1_u64)"
  print "  end"
  print ""
  print "  def self.force_raise_count : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_raise_count).address).value.get"
  print "  end"
  print ""
  print "  def self.force_raise_ticks : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_raise_ticks).address).value.get"
  print "  end"
  print ""
  print
  n_defs++
  next
}'
  SLOW_TICKS='/^  PREEMPT_TICKS   =       1_u64$/ { print "  PREEMPT_TICKS   =       3_u64"; n_ticks++; at_ticks = NR; next }'
  SLOW_TICKS_HOOK='/^  PREEMPT_TICKS   =       1_u64$/ { n_ticks++; at_ticks = NR }'
  SLOW_SCOPE='/^  PREEMPT_TICK_NS = 5000000_u64$/ { n_tick_ns++; at_tick_ns = NR }
/^  private def self.look : Bool$/ { inlook = 1; n_look_method++ }
inlook && /^  end$/ { inlook = 0 }'
  SLOW_SAVE='inlook && /^            ticks = 0_u64$/ { print "            force_pending_ticks(ticks)"; print; n_save++; at_save = NR; next }'
  SLOW_STORE='inlook && /^            Pointer\(Atomic\(UInt64\)\).new\(address\).value.set\(1_u64\) if address != 0_u64$/ { print; print "            force_raise if address != 0_u64"; n_store++; at_store = NR; next }'
  SLOW_HOOK="$SLOW_DEFS
$SLOW_SCOPE
$SLOW_TICKS_HOOK
$SLOW_SAVE
$SLOW_STORE
{ print }
END { if (n_defs != 1 || n_look_method != 1 || n_tick_ns != 1 || n_ticks != 1 || at_ticks != at_tick_ns + 1 || n_save != 1 || n_store != 1 || at_save >= at_store) exit 3 }"
  SLOW_BUG="$SLOW_DEFS
$SLOW_SCOPE
$SLOW_TICKS
$SLOW_SAVE
$SLOW_STORE
{ print }
END { if (n_defs != 1 || n_look_method != 1 || n_tick_ns != 1 || n_ticks != 1 || at_ticks != at_tick_ns + 1 || n_save != 1 || n_store != 1 || at_save >= at_store) exit 3 }"
  broken slowturn "$SLOW_BUG" concurrency.iyi parallel_preempt -Dslowturn_force
  verdict_caught slowturn "period: a worker's word was raised after 3 unchanged looks" period --workers=1
  broken slowturn_hook "$SLOW_HOOK" concurrency.iyi parallel_preempt -Dslowturn_force
  verdict_held slowturn_hook "period: the monitor raised a worker's word after one unchanged look" period --workers=1

# The accessor's checks are caught in the IR, where they are calls of
# `*IyiWorkers::preempt` however fast the runner is. By the clock the
# copy's `sum` measured 5.351x and 5.409x on macos-14 runners, but 1.776x
# on the windows-2025 one of CI job 122792275988, under the bound of twice
# it had to pass, and the thread pointer's checks measured `each` up to
# 1.762x on another windows-2025 runner (CI job 122916661258): no bound
# between the two holds on every runner. So the copy's timing is not a
# proof any more, and is not run.
step "failure proof: a check that calls the thread-local accessor at every back-edge"
if [ "$(uname -s)" = Linux ]; then
  echo "  accessor: skipped on Linux, where the flag builds the same check without an accessor call"
else
  if ! "$IYI" build --release --emit llvm-ir -Dpreempt_check_accessor "$REPO/bench/parallel_preempt.iyi" -o accessor-run > build-accessor.log 2>&1; then
    echo "FAIL: accessor: setup: the copy failed to build"; tail -20 build-accessor.log; exit 76
  fi
  tight_checks accessor-run.ll > accessor.txt 2>&1
  code=$?
  want='FAIL: tight checks: spin calls the thread-local accessor *IyiWorkers::preempt at a back-edge'
  if [ "$code" -ne 1 ] || [ "$(grep -cxF -- "$want" accessor.txt)" -ne 1 ] || [ "$(grep -c '^FAIL: ' accessor.txt)" -ne 1 ]; then
    echo "FAIL: accessor: setup: the checker did not exit 1 at its exact accessor line (exit $code)"; cat accessor.txt; exit 76
  fi
  sed '/^FAIL: /d; s/^/  /' accessor.txt
  echo "  exits 1 at \"${want#FAIL: }\""
fi

step "failure proof: a slow half that does not poll leaves a connection in a busy worker's poller"
# Both copies record the first armed decision on the selected worker. The
# mutant changes only the call between the identical expect/decided hooks.
NOPOLL_DEFS='/^  def self.preempts : UInt64$/ {
  print "  @[UnsafeReach(\"copy-only poll decision state, accessed atomically\")]"
  print "  @@forced_poll_target : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only poll decision state, accessed atomically\")]"
  print "  @@forced_poll_expected : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only poll decision state, accessed atomically\")]"
  print "  @@forced_poll_entered : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only poll decision state, accessed atomically\")]"
  print "  @@forced_poll_result : UInt64 = 0_u64"
  print "  def self.force_poll_arm(state : UInt64) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_poll_expected).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_poll_entered).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_poll_result).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_poll_target).address).value.set(state)"
  print "  end"
  print "  def self.force_poll_expect(st : IyiSchedulerState) : Nil"
  print "    target = Pointer(Atomic(UInt64)).new(pointerof(@@forced_poll_target).address).value.get"
  print "    return if target == 0_u64 || st.object_id != target || force_poll_result != 0_u64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_poll_expected).address).value.set(1_u64)"
  print "  end"
  print "  def self.force_poll_entered(blocking : Bool) : Nil"
  print "    return if blocking || Pointer(Atomic(UInt64)).new(pointerof(@@forced_poll_expected).address).value.get == 0_u64"
  print "    target = Pointer(Atomic(UInt64)).new(pointerof(@@forced_poll_target).address).value.get"
  print "    return if target == 0_u64 || IyiScheduler.state_id != target"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_poll_entered).address).value.set(1_u64)"
  print "  end"
  print "  def self.force_poll_decided(st : IyiSchedulerState) : Nil"
  print "    target = Pointer(Atomic(UInt64)).new(pointerof(@@forced_poll_target).address).value.get"
  print "    return if target == 0_u64 || st.object_id != target"
  print "    return if Pointer(Atomic(UInt64)).new(pointerof(@@forced_poll_expected).address).value.get == 0_u64"
  print "    entered = Pointer(Atomic(UInt64)).new(pointerof(@@forced_poll_entered).address).value.get"
  print "    {% if !flag?(:nopoll_withhold_decision) %}"
  print "      Pointer(Atomic(UInt64)).new(pointerof(@@forced_poll_result).address).value.compare_and_set(0_u64, entered == 1_u64 ? 1_u64 : 2_u64)"
  print "    {% end %}"
  print "  end"
  print "  def self.force_poll_result : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_poll_result).address).value.get"
  print "  end"
  print
  n_defs++
  next
}'
NOPOLL_COMMON='/^  (@\[Effect\([a-z_:]+\)\]; )?def self.wait_for_events\(blocking : Bool\) : Nil$/ {
  in_poll_wait = 1; n_wait++; at_wait = NR
  print; print "    IyiWorkers.force_poll_entered(blocking)"; next
}
in_poll_wait && /^    st = state$/ { n_wait_state++; at_wait_state = NR }
in_poll_wait && /^  end$/ { in_poll_wait = 0 }
/^  def self.preempted : Nil$/ { in_poll_preempted = 1; n_preempted++ }
in_poll_preempted && /^  end$/ { in_poll_preempted = 0 }
in_poll_preempted && /^      if io$/ { n_poll_if++; at_poll_if = NR }
in_poll_preempted && /^      else$/ { n_poll_else++; at_poll_else = NR }'
NOPOLL_SITE_HOOK='in_poll_preempted && /^        IyiScheduler.wait_for_events\(false\)$/ {
  print "        force_poll_expect(st)"; print; print "        force_poll_decided(st)"
  n_poll++; at_poll = NR; next
}'
NOPOLL_SITE_BUG='in_poll_preempted && /^        IyiScheduler.wait_for_events\(false\)$/ {
  print "        force_poll_expect(st)"; print "        IyiScheduler.wake_expired_sleepers"; print "        force_poll_decided(st)"
  n_poll++; at_poll = NR; next
}'
NOPOLL_END='END {
  if (n_defs != 1 || n_wait != 1 || n_wait_state != 1 || at_wait_state != at_wait + 1 ||
      n_preempted != 1 || n_poll_if != 1 || n_poll != 1 || n_poll_else != 1 ||
      at_poll != at_poll_if + 1 || at_poll_else != at_poll + 1) exit 3
}'
NOPOLL_HOOK="$NOPOLL_DEFS
$NOPOLL_COMMON
$NOPOLL_SITE_HOOK
{ print }
$NOPOLL_END"
NOPOLL_BUG="$NOPOLL_DEFS
$NOPOLL_COMMON
$NOPOLL_SITE_BUG
{ print }
$NOPOLL_END"
broken nopoll "$NOPOLL_BUG" concurrency.iyi parallel_preempt -Dnopoll_force
verdict_caught nopoll "poller: a preemption with a read waiting did not poll its worker's poller" poller --workers=1
broken nopoll_hook "$NOPOLL_HOOK" concurrency.iyi parallel_preempt -Dnopoll_force
verdict_held nopoll_hook "poller: a preemption with a read waiting polled its worker's poller" poller --workers=1
broken nopoll_watchdog "$NOPOLL_HOOK" concurrency.iyi parallel_preempt -Dnopoll_force -Dnopoll_withhold_decision
verdict_watchdog nopoll_watchdog 'FAIL: poller: progress hang: the armed worker made no poll decision in 10000 ms' poller --workers=1

step "failure proof: a preempted worker that does not wake its expired sleeper"
# Both copies pin the keyed sleeper's deadline before insertion, then make it
# due on the keyed long task's eligible no-I/O slow path. Only the mutant
# omits that path's wake call; the enqueue hook runs after enqueue returns.
TICKER_COMMON='/^class IyiWorkers$/ { in_ticker_workers = 1; n_ticker_workers++ }
in_ticker_workers && /^end$/ { in_ticker_workers = 0 }
/^  (@\[Effect\([a-z_:]+\)\]; )?def self.sleep_current\(ms : Int32\) : Nil \| Cancelled$/ { in_ticker_sleep = 1; n_ticker_sleep++ }
in_ticker_sleep && /^  end$/ { in_ticker_sleep = 0 }
in_ticker_sleep && /^    fiber.deadline = __iyi_monotonic_ns \+ ms.to_i64 \* 1000000_i64$/ {
  n_ticker_deadline++; at_ticker_deadline = NR
  print; print "    IyiWorkers.force_ticker_hold(fiber)"; next
}
in_ticker_sleep && /^    fiber.state = IyiFiberState::Sleeping$/ { n_ticker_state++; at_ticker_state = NR }
in_ticker_sleep && /^    sleep_insert\(fiber\)$/ { n_ticker_insert++; at_ticker_insert = NR }
/^  (@\[Effect\([a-z_:]+\)\]; )?def self.wake_expired_sleepers : Nil$/ { in_ticker_wake = 1; n_ticker_wake++ }
in_ticker_wake && /^  end$/ { in_ticker_wake = 0 }
in_ticker_wake && /^      if head.state == IyiFiberState::Sleeping \|\| head.state == IyiFiberState::WaitingIo$/ {
  n_ticker_branch++; at_ticker_branch = NR
}
in_ticker_wake && /^        enqueue\(head\)$/ {
  n_ticker_enqueue++
  if (n_ticker_enqueue == 1) {
    at_ticker_first_enqueue = NR
    print; print "        IyiWorkers.force_ticker_enqueued(head)"; next
  }
  at_ticker_second_enqueue = NR
}
in_ticker_workers && /^  def self.preempted : Nil$/ { in_ticker_preempted = 1; n_ticker_preempted++ }
in_ticker_preempted && /^  end$/ { in_ticker_preempted = 0 }
in_ticker_preempted && /^      return if IyiSchedLock.held_here\? \|\| IyiRuntimeLock.held\?$/ {
  n_ticker_refusal++; at_ticker_refusal = NR
  print "      if force_ticker_target_on?(st)"
  print "        force_ticker_wait_lock"
  print "      else"
  print
  print "      end"
  next
}
in_ticker_preempted && /^      if io$/ {
  n_ticker_io++; at_ticker_io = NR
  print "      force_ticker_guard_io(st, io)"; print; next
}
in_ticker_preempted && /^      else$/ { n_ticker_else++; at_ticker_else = NR }'
TICKER_DEFS='in_ticker_workers && /^  def self.preempts : UInt64$/ {
  n_ticker_defs++
  print "  @[UnsafeReach(\"copy-only keyed sleeper worker, accessed atomically\")]"
  print "  @@forced_ticker_worker : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only keyed sleeper, accessed atomically\")]"
  print "  @@forced_ticker_sleeper : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only keyed long task, accessed atomically\")]"
  print "  @@forced_ticker_long : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only sleeper insertion, accessed atomically\")]"
  print "  @@forced_ticker_held : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only wake decision, accessed atomically\")]"
  print "  @@forced_ticker_expected : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only enqueue observation, accessed atomically\")]"
  print "  @@forced_ticker_enqueued : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only ticker result, accessed atomically\")]"
  print "  @@forced_ticker_result : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only ticker watchdog ownership, accessed atomically\")]"
  print "  @@forced_ticker_slow_active : UInt64 = 0_u64"
  print "  def self.force_ticker_result : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_result).address).value.get"
  print "  end"
  print "  def self.force_ticker_slow_active? : Bool"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_slow_active).address).value.get == 1_u64"
  print "  end"
  print "  def self.force_ticker_outer_claim? : Bool"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_slow_active).address).value.compare_and_set(0_u64, 2_u64)[1]"
  print "  end"
  print "  def self.force_ticker_key(worker : UInt64, sleeper : UInt64) : Nil"
  print "    st = IyiScheduler.state"
  print "    fiber = IyiScheduler.current"
  print "    end_run(76, 2, \"FAIL: ticker: not armed: the sleeper key did not name the running worker and fiber\\n\") if worker == 0_u64 || sleeper == 0_u64 || !st.worker || st.object_id != worker || fiber.object_id != sleeper"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_long).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_held).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_expected).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_enqueued).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_result).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_slow_active).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_worker).address).value.set(worker)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_sleeper).address).value.set(sleeper)"
  print "  end"
  print "  def self.force_ticker_hold(fiber : IyiFiber) : Nil"
  print "    sleeper = Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_sleeper).address).value.get"
  print "    return if sleeper == 0_u64 || fiber.object_id != sleeper"
  print "    worker = Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_worker).address).value.get"
  print "    end_run(76, 2, \"FAIL: ticker: not armed: the keyed sleeper entered sleep on another worker\\n\") unless IyiScheduler.state_id == worker"
  print "    held = Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_held).address)"
  print "    end_run(76, 2, \"FAIL: ticker: not armed: the keyed sleeper entered sleep more than once\\n\") unless held.value.compare_and_set(0_u64, 1_u64)[1]"
  print "    fiber.deadline = 9223372036854775807_i64"
  print "  end"
  print "  def self.force_ticker_arm(worker : UInt64, long : UInt64) : Nil"
  print "    st = IyiScheduler.state"
  print "    fiber = IyiScheduler.current"
  print "    wanted = Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_worker).address).value.get"
  print "    sleeper = Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_sleeper).address).value.get"
  print "    end_run(76, 2, \"FAIL: ticker: not armed: the long task did not name the keyed worker and its own fiber\\n\") if worker == 0_u64 || long == 0_u64 || sleeper == 0_u64 || worker != wanted || !st.worker || st.object_id != worker || fiber.object_id != long"
  print "    end_run(76, 2, \"FAIL: ticker: not armed: the worker has no preemption word\\n\") if st.preempt_word == 0_u64"
  print "    IyiScheduler.lists_lock(st)"
  print "    head = st.sleep_head"
  print "    valid = false"
  print "    if head.is_a?(IyiFiber)"
  print "      valid = head.object_id == sleeper && head.state == IyiFiberState::Sleeping && head.deadline == 9223372036854775807_i64 && head.listed_on_fenced == worker && !head.on_cpu? && !head.io_timed && st.io_head.is_a?(Nil)"
  print "    end"
  print "    IyiScheduler.lists_unlock(st)"
  print "    end_run(76, 2, \"FAIL: ticker: not armed: the keyed sleeper was not the parked sleep-heap root without worker I/O\\n\") unless valid"
  print "    {% if flag?(:win32) %}"
  print "      end_run(76, 2, \"FAIL: ticker: not armed: the completion port has an I/O waiter\\n\") if IyiScheduler.io_waiting?"
  print "    {% end %}"
  print "    target = Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_long).address)"
  print "    end_run(76, 2, \"FAIL: ticker: not armed: the long task was already armed\\n\") unless target.value.compare_and_set(0_u64, long)[1]"
  print "    Pointer(Atomic(UInt64)).new(st.preempt_word).value.set(1_u64)"
  print "  end"
  print "  @[NoPreempt]"
  print "  def self.force_ticker_target_on?(st : IyiSchedulerState) : Bool"
  print "    long = Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_long).address).value.get"
  print "    return false if long == 0_u64 || force_ticker_result != 0_u64"
  print "    worker = Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_worker).address).value.get"
  print "    return false unless st.object_id == worker"
  print "    fiber = IyiScheduler.current?"
  print "    fiber.is_a?(IyiFiber) && fiber.object_id == long"
  print "  end"
  print "  @[NoPreempt]"
  print "  def self.force_ticker_wait_lock : Nil"
  print "    end_run(76, 2, \"FAIL: ticker: not armed: the long task holds the scheduler lock at its check\\n\") if IyiSchedLock.held_here?"
  print "    st = IyiScheduler.state"
  print "    fiber = IyiScheduler.current"
  print "    root = st.root"
  print "    end_run(76, 2, \"FAIL: ticker: not armed: the long task was not running on a non-root fiber\\n\") if fiber.state != IyiFiberState::Running || (root.is_a?(IyiFiber) && root.object_id == fiber.object_id)"
  print "    owner = Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_slow_active).address)"
  print "    until owner.value.compare_and_set(0_u64, 1_u64)[1]"
  print "      IyiThread.park_if_requested"
  print "      IyiThread.spin_pause"
  print "    end"
  print "    started = __iyi_monotonic_ns"
  print "    while IyiRuntimeLock.held?"
  print "      IyiThread.park_if_requested"
  print "      IyiThread.spin_pause"
  print "      end_run(76, 2, \"FAIL: ticker: progress hang: the runtime lock did not clear for the keyed preemption in 20000 ms\\n\") if __iyi_monotonic_ns - started > 20000000000_i64"
  print "    end"
  print "  end"
  print "  def self.force_ticker_guard_io(st : IyiSchedulerState, io : Bool) : Nil"
  print "    end_run(76, 2, \"FAIL: ticker: not armed: the keyed preemption took the I/O branch\\n\") if force_ticker_target_on?(st) && io"
  print "  end"
  print "  def self.force_ticker_prepare(st : IyiSchedulerState) : Nil"
  print "    sleeper = Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_sleeper).address).value.get"
  print "    worker = Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_worker).address).value.get"
  print "    IyiScheduler.lists_lock(st)"
  print "    head = st.sleep_head"
  print "    valid = false"
  print "    if head.is_a?(IyiFiber)"
  print "      valid = head.object_id == sleeper && head.state == IyiFiberState::Sleeping && head.deadline == 9223372036854775807_i64 && head.listed_on_fenced == worker && !head.on_cpu? && !head.io_timed"
  print "      head.deadline = __iyi_monotonic_ns if valid"
  print "    end"
  print "    IyiScheduler.lists_unlock(st)"
  print "    end_run(76, 2, \"FAIL: ticker: not armed: the keyed sleeper changed before the wake decision\\n\") unless valid"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_expected).address).value.set(1_u64)"
  print "  end"
  print "  def self.force_ticker_enqueued(fiber : IyiFiber) : Nil"
  print "    return unless Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_expected).address).value.get == 1_u64"
  print "    sleeper = Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_sleeper).address).value.get"
  print "    return unless fiber.object_id == sleeper && force_ticker_target_on?(IyiScheduler.state)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_enqueued).address).value.set(1_u64)"
  print "  end"
  print "  def self.force_ticker_finish(st : IyiSchedulerState) : Nil"
  print "    end_run(76, 2, \"FAIL: ticker: not armed: the wake decision lost its keyed target\\n\") unless force_ticker_target_on?(st)"
  print "    expected = Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_expected).address).value.get"
  print "    end_run(76, 2, \"FAIL: ticker: not armed: the wake decision was not prepared\\n\") unless expected == 1_u64"
  print "    enqueued = Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_enqueued).address).value.get"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_result).address).value.set(enqueued == 1_u64 ? 1_u64 : 2_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_ticker_slow_active).address).value.set(0_u64)"
  print "  end"
  print ""
  print; next
}'
TICKER_SITE='in_ticker_preempted && /^        IyiScheduler.wake_expired_sleepers$/ {
  n_ticker_site++; at_ticker_site = NR
  print "        if force_ticker_target_on?(st)"
  print "          force_ticker_prepare(st)"
  if (ticker_keep) print "          IyiScheduler.wake_expired_sleepers"
  print "          force_ticker_finish(st)"
  print "        else"
  print "          IyiScheduler.wake_expired_sleepers"
  print "        end"
  next
}'
TICKER_END='END {
  if (n_ticker_workers != 1 || n_ticker_defs != 1 || n_ticker_sleep != 1 ||
      n_ticker_deadline != 1 || n_ticker_state != 1 || at_ticker_state != at_ticker_deadline + 1 ||
      n_ticker_insert != 1 || at_ticker_insert != at_ticker_state + 1 ||
      n_ticker_wake != 1 || n_ticker_branch != 1 || n_ticker_enqueue != 2 ||
      at_ticker_first_enqueue != at_ticker_branch + 1 || at_ticker_second_enqueue != at_ticker_branch + 3 ||
      n_ticker_preempted != 1 || n_ticker_refusal != 1 || n_ticker_io != 1 ||
      n_ticker_else != 1 || n_ticker_site != 1 || at_ticker_refusal >= at_ticker_io ||
      at_ticker_else != at_ticker_io + 2 || at_ticker_site != at_ticker_else + 1) exit 3
}'
TICKER_HOOK="BEGIN { ticker_keep = 1 }
$TICKER_COMMON
$TICKER_DEFS
$TICKER_SITE
{ print }
$TICKER_END"
TICKER_BUG="BEGIN { ticker_keep = 0 }
$TICKER_COMMON
$TICKER_DEFS
$TICKER_SITE
{ print }
$TICKER_END"
broken tickerwake "$TICKER_BUG" concurrency.iyi parallel_preempt -Dticker_force
verdict_caught tickerwake "unit: an expired sleeper was not enqueued by its worker's preemption" unit --workers=1
broken tickerwake_hook "$TICKER_HOOK" concurrency.iyi parallel_preempt -Dticker_force
verdict_held tickerwake_hook "unit: the preempted worker enqueued and ran its expired sleeper" unit --workers=1

step "failure proof: ticker watchdogs name withheld progress"
for proof in ready decision resumed lock; do
  copy="ticker_${proof}_watchdog"
  if ! awk -v mode="$proof" '
    /^  def unit_ticker_sleeper\(/ { sleeper = 1 }
    /^  def unit_ticker_long\(/ { long = 1 }
    /^  def unit_ticker : Nil/ { main = 1 }
    /^  end$/ { sleeper = 0; long = 0; main = 0 }
    sleeper && mode == "ready" && /^    state\.ready$/ { n++; print "    # withhold readiness"; next }
    sleeper && mode == "resumed" && /^    state\.observe\(observed\)$/ { n++; print "    # withhold the return witness"; next }
    long && mode == "decision" && /IyiWorkers\.force_ticker_arm\(/ { n++; print "    # withhold the preemption arm"; next }
    main && mode == "lock" && /^      state\.queue$/ {
      print "      lock_gate = SliceLockGate.new"
      print "      IyiThread.start do"
      print "        lock_gate.hold"
      print "        nil"
      print "      end"
      print "      until lock_gate.held?"
      print "        IyiThread.spin_pause"
      print "      end"
      print
      n++; next
    }
    { print }
    END { if (n != 1) exit 3 }
  ' "$REPO/bench/parallel_preempt.iyi" > "$copy.iyi"; then
    echo "FAIL: $copy: setup: the fixture mutation anchor was missing or duplicated"; exit 76
  fi
  flags=(-Dticker_force)
  case "$proof" in
    ready) want='FAIL: unit: progress hang: the keyed sleeper did not hold its worker in 10000 ms' ;;
    decision) want="FAIL: unit: progress hang: the keyed sleeper's preemption decision did not finish in 20000 ms" ;;
    resumed) want='FAIL: unit: progress hang: the enqueued sleeper did not resume in 20000 ms' ;;
    lock)
      want='FAIL: ticker: progress hang: the runtime lock did not clear for the keyed preemption in 20000 ms'
      flags+=(-Dturn_refusal_watchdog) ;;
  esac
  broken "$copy" "$TICKER_HOOK" concurrency.iyi "$WORK/$copy.iyi" "${flags[@]}"
  verdict_watchdog "$copy" "$want" unit --workers=1
done

step "failure proof: a word the monitor raised for the task before preempts the task switched in after it"
# The monitor waits at the next look's entry. That rendezvous also drains
# any earlier look, preventing its old decision from raising the word after
# the switch. Only the lowering line differs between the two copies.
STALE_DEFS='/^  def self.preempts : UInt64$/ {
  print "  @[UnsafeReach(\"copy-only switch decision state, accessed atomically\")]"
  print "  @@forced_stale_target : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only switch decision state, accessed atomically\")]"
  print "  @@forced_stale_gate : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only switch decision state, accessed atomically\")]"
  print "  @@forced_stale_word : UInt64 = 0_u64"
  print "  @[UnsafeReach(\"copy-only switch decision state, accessed atomically\")]"
  print "  @@forced_stale_before : UInt64 = 0_u64"
  print "  def self.force_stale_arm(state : UInt64) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_stale_before).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_stale_word).address).value.set(0_u64)"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_stale_target).address).value.set(state)"
  print "  end"
  print "  def self.force_stale_close_gate : Nil"
  print "    gate = Pointer(Atomic(UInt64)).new(pointerof(@@forced_stale_gate).address)"
  print "    return if gate.value.compare_and_set(0_u64, 1_u64)[1]"
  print "    while gate.value.get == 4_u64"
  print "      IyiThread.park_if_requested"
  print "      IyiThread.spin_pause"
  print "    end"
  print "    end_run(76, 2, \"FAIL: stale: not armed: the monitor gate had an unexpected state before closing\\n\")"
  print "  end"
  print "  def self.force_stale_gate_state : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_stale_gate).address).value.get"
  print "  end"
  print "  def self.force_stale_timeout_claim? : Bool"
  print "    gate = Pointer(Atomic(UInt64)).new(pointerof(@@forced_stale_gate).address)"
  print "    return true if gate.value.compare_and_set(0_u64, 4_u64)[1]"
  print "    gate.value.compare_and_set(1_u64, 4_u64)[1]"
  print "  end"
  print "  def self.force_stale_gate : Nil"
  print "    gate = Pointer(Atomic(UInt64)).new(pointerof(@@forced_stale_gate).address)"
  print "    return unless gate.value.compare_and_set(1_u64, 2_u64)[1]"
  print "    limit = __iyi_monotonic_ns + 10000000000_i64"
  print "    while gate.value.get == 2_u64"
  print "      if __iyi_monotonic_ns > limit"
  print "        end_run(76, 2, \"FAIL: stale: progress hang: the monitor gate was not released by the target switch in 10000 ms\\n\")"
  print "      end"
  print "      IyiThread.spin_pause"
  print "    end"
  print "  end"
  print "  def self.force_stale_input(st : IyiSchedulerState, word : UInt64) : Nil"
  print "    return unless st.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_stale_target).address).value.get"
  print "    return unless force_stale_gate_state == 2_u64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_stale_before).address).value.compare_and_set(0_u64, word == 0_u64 ? 1_u64 : 2_u64)"
  print "  end"
  print "  def self.force_stale_before : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_stale_before).address).value.get"
  print "  end"
  print "  def self.force_stale_decision(st : IyiSchedulerState, word : UInt64) : Nil"
  print "    return unless st.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_stale_target).address).value.get"
  print "    gate = Pointer(Atomic(UInt64)).new(pointerof(@@forced_stale_gate).address)"
  print "    return unless gate.value.get == 2_u64"
  print "    {% if !flag?(:copy_hook_watchdog) %}"
  print "      Pointer(Atomic(UInt64)).new(pointerof(@@forced_stale_word).address).value.compare_and_set(0_u64, word == 0_u64 ? 1_u64 : 2_u64)"
  print "      gate.value.compare_and_set(2_u64, 3_u64)"
  print "    {% end %}"
  print "  end"
  print "  def self.force_stale_word : UInt64"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_stale_word).address).value.get"
  print "  end"
  print
  n_defs++
  next
}'
STALE_COMMON='/^  (@\[Effect\([a-z_:]+\)\]; )?def self.switch_to\(fiber : IyiFiber\) : Nil$/ { in_stale_switch = 1; n_switch++ }
in_stale_switch && /^  end$/ { in_stale_switch = 0 }
in_stale_switch && /^        st\.switches = st\.switches &\+ 1_u64$/ { n_switch_count++; at_switch_count = NR }
in_stale_switch && /^        raised = Pointer\(Atomic\(UInt64\)\).new\(st\.preempt_word\)$/ {
  n_raised++; at_raised = NR
  print; print "        IyiWorkers.force_stale_input(st, raised.value.get)"; next
}
/^  private def self.look : Bool$/ {
  in_stale_look = 1; n_look++; at_look = NR
  print; print "    force_stale_gate"; next
}
in_stale_look && /^    busy = false$/ { n_busy++; at_busy = NR }
in_stale_look && /^  end$/ { in_stale_look = 0 }'
STALE_SITE_HOOK='in_stale_switch && /^        raised\.value\.set\(0_u64\) if raised\.value\.get != 0_u64$/ {
  print; print "        IyiWorkers.force_stale_decision(st, raised.value.get)"
  n_lower++; at_lower = NR; next
}'
STALE_SITE_BUG='in_stale_switch && /^        raised\.value\.set\(0_u64\) if raised\.value\.get != 0_u64$/ {
  print "        IyiWorkers.force_stale_decision(st, raised.value.get)"
  n_lower++; at_lower = NR; next
}'
STALE_END='END {
  if (n_defs != 1 || n_switch != 1 || n_switch_count != 1 || n_raised != 1 || n_lower != 1 ||
      at_raised != at_switch_count + 1 || at_lower != at_raised + 1 ||
      n_look != 1 || n_busy != 1 || at_busy != at_look + 1) exit 3
}'
STALE_HOOK="$STALE_DEFS
$STALE_COMMON
$STALE_SITE_HOOK
{ print }
$STALE_END"
STALE_BUG="$STALE_DEFS
$STALE_COMMON
$STALE_SITE_BUG
{ print }
$STALE_END"
broken stale "$STALE_BUG" concurrency.iyi parallel_preempt -Dstale_force
verdict_caught stale "fresh: the word raised for the task before was still up after the switch" fresh --workers=1
broken stale_hook "$STALE_HOOK" concurrency.iyi parallel_preempt -Dstale_force
verdict_held stale_hook "fresh: the switch after a task held its raised word lowered the word" fresh --workers=1
broken stale_release_hook "$STALE_HOOK" concurrency.iyi parallel_preempt --release -Dstale_force
verdict_held stale_release_hook "fresh: the switch after a task held its raised word lowered the word" fresh --workers=1
broken stale_watchdog "$STALE_HOOK" concurrency.iyi parallel_preempt -Dstale_force -Dcopy_hook_watchdog
verdict_watchdog stale_watchdog 'FAIL: stale: progress hang: the monitor gate was not released by the target switch in 10000 ms' fresh --workers=1

step "failure proof: a port whose packets only the thread their task parked on runs leaves an answer behind a computation"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    # Every packet's fiber is woken onto the worker it parked on, when the packet is taken by another
    # worker, if it is made homebound (the mutant, at both take_packet dispatches). The copy records only the
    # armed reader's dispatch before waking it; other completions cannot overwrite the target's verdict.
    NOX_DEFS='/^    def self.take_packet\(overlapped : UInt64, bytes : Int64\) : Nil$/ {
  print "    # Copy only: record the armed reader dispatch before waking it."
  print "    @[UnsafeReach(\"set by the program, read by packet dispatch: atomics only\")]"
  print "    @@forced_dispatch_target : UInt64 = 0_u64"
  print "    @[UnsafeReach(\"set by packet dispatch, read by the program: atomics only\")]"
  print "    @@forced_dispatch_fiber : UInt64 = 0_u64"
  print "    @[UnsafeReach(\"set by packet dispatch, read by the program: atomics only\")]"
  print "    @@forced_dispatch_homebound : UInt64 = 0_u64"
  print ""
  print "    def self.force_dispatch_target(fiber : UInt64) : Nil"
  print "      Pointer(Atomic(UInt64)).new(pointerof(@@forced_dispatch_target).address).value.set(fiber)"
  print "    end"
  print ""
  print "    def self.force_dispatch(fiber : IyiFiber, owner : IyiSchedulerState) : Nil"
  print "      return unless fiber.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_dispatch_target).address).value.get"
  print "      Pointer(Atomic(UInt64)).new(pointerof(@@forced_dispatch_homebound).address).value.set(fiber.homebound ? 1_u64 : 0_u64)"
  print "      Pointer(Atomic(UInt64)).new(pointerof(@@forced_dispatch_fiber).address).value.set(fiber.object_id)"
  print "    end"
  print ""
  print "    def self.force_dispatch_fiber : UInt64"
  print "      Pointer(Atomic(UInt64)).new(pointerof(@@forced_dispatch_fiber).address).value.get"
  print "    end"
  print ""
  print "    def self.force_dispatch_homebound : UInt64"
  print "      Pointer(Atomic(UInt64)).new(pointerof(@@forced_dispatch_homebound).address).value.get"
  print "    end"
  print ""
  print
  in_packet = 1
  n_defs++
  next
}
in_packet && /^    end$/ { in_packet = 0 }
in_packet && /^      posting = fiber_posting\(overlapped\)$/ { after_posting = 1; n_posting++ }'
    NOX_REC='in_packet && /^        wake_completed\(fiber\)$/ { print "        force_dispatch(fiber, owner)"; print; if (after_posting) n_second++; else n_first++; next }'
    NOX_HOME='in_packet && /^        wake_completed\(fiber\)$/ { print "        fiber.homebound = true if owner.object_id != state.object_id"; print "        force_dispatch(fiber, owner)"; print; if (after_posting) n_second++; else n_first++; next }'
    NOX_HOOK="$NOX_DEFS
$NOX_REC
{ print }
END { if (n_defs != 1 || n_posting != 1 || n_first != 1 || n_second != 1) exit 3 }"
    NOX_BUG="$NOX_DEFS
$NOX_HOME
{ print }
END { if (n_defs != 1 || n_posting != 1 || n_first != 1 || n_second != 1) exit 3 }"
    broken nocross "$NOX_BUG" concurrency.iyi completions_taken -Dnocross_force
    verdict_caught nocross "taken: the packet's fiber was made homebound to the worker it parked on, so its answer waits for that worker" taken --workers=12
    broken nocross_hook "$NOX_HOOK" concurrency.iyi completions_taken -Dnocross_force
    verdict_held nocross_hook "taken: a packet's answer was read on another worker while its reader's worker computed" taken --workers=12 ;;
  *)
    echo "  Windows' alone, as the port is" ;;
esac

step "failure proof: a pool that leaves Windows' priority boost on"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    broken boosted '/^  def self.start : Nil$/ { inside = 1; methods++ }
inside && /^  end$/ { inside = 0 }
inside && /^        LibC\.SetProcessPriorityBoost\(LibC\.GetCurrentProcess, 1_i32\)$/ { n++; next }
{ print }
END { if (methods != 1 || n != 1) exit 3 }' concurrency.iyi completions_taken
    verdict_caught boosted "boost: the process's priority boost is on with the pool started" boost --workers=12 ;;
  *)
    echo "  Windows' alone: the boost is its scheduler's" ;;
esac

step "failure proof: a preempted task that gives its unit's token away lets its child run inside it"
broken tokenless "$TURN_TOKENLESS" concurrency.iyi parallel_preempt -Dtokenless_force
verdict_caught tokenless 'unit: a task of the same unit ran inside the preempted task' unit --workers=1
broken tokenless_hook "$TURN" concurrency.iyi parallel_preempt -Dtokenless_force
verdict_held tokenless_hook "unit: the same-unit child waited on its unit at the computing task's eligible preemption decision" unit --workers=1

step "failure proof: the prelude's library compiled as the runtime's holds its worker through a sort, a copy, a growth and a join"
# The same loop hooks and scheduler definitions go into both copies. Only
# the mutant inlines the hooked library into the runtime's prelude.
LIB_POLL_ARRAY='/^  def join\(separator : String\) : String$/ { in_join = 1; n_join_def++ }
in_join && /^  end$/ { in_join = 0 }
in_join && /^      each do \|value\|$/ {
  n_join_loop++; at_join_loop = NR
  print; print "        IyiWorkers.force_turn(4_u64, object_id, 0_u64, first && @size > 1)"; next
}
in_join && /^        io << separator unless first$/ { n_join_body++; at_join_body = NR }
/^  def sort_in_place\(& : T, T -> Int32\) : self$/ { in_sort = 1; n_sort_def++ }
in_sort && /^  end$/ { in_sort = 0 }
in_sort && /^      while index < finish$/ {
  n_sort_loop++; at_sort_loop = NR
  print; print "        IyiWorkers.force_turn(1_u64, object_id, start.to_u64, index + 1 < finish)"; next
}
in_sort && /^        value = @buffer\.array_at\(index\)$/ { n_sort_body++; at_sort_body = NR }
{ print }
END {
  if (n_join_def != 1 || n_join_loop != 1 || n_join_body != 1 || at_join_body != at_join_loop + 1 ||
      n_sort_def != 1 || n_sort_loop != 1 || n_sort_body != 1 || at_sort_body != at_sort_loop + 1) exit 3
}'
LIB_POLL_STRING='/^  def copy_from\(source : Pointer\(T\), count : Int32\) : Nil$/ { inside = 1; n_def++ }
inside && /^  end$/ { inside = 0 }
inside && /^    while index < count$/ {
  n_loop++; at_loop = NR
  print; print "      IyiWorkers.force_turn(2_u64, self.address, 0_u64, count - index > 1048576)"; next
}
inside && /^      run = count - index > 1048576 \? 1048576 : count - index$/ { n_body++; at_body = NR }
{ print }
END { if (n_def != 1 || n_loop != 1 || n_body != 1 || at_body != at_loop + 1) exit 3 }'
LIB_POLL_HASH='/^  private def grow : Nil$/ { inside = 1; n_def++ }
inside && /^  end$/ { inside = 0 }
inside && /^    while entry < old_used$/ {
  n_loop++; at_loop = NR
  print; print "      IyiWorkers.force_turn(3_u64, object_id, 0_u64, entry + 1 < old_used)"; next
}
inside && /^      unless old_gone\.address != 0_u64 && old_gone\[entry\]$/ { n_body++; at_body = NR }
{ print }
END { if (n_def != 1 || n_loop != 1 || n_body != 1 || at_body != at_loop + 1) exit 3 }'
LIB_INLINE='/^require "\.\/(float|range|set)"$/ {
  name = $2; gsub(/"|\.\//, "", name); count[name]++; position[name] = NR
}
/^require "\.\/(array|hash|string)"$/ {
  name = $2; gsub(/"|\.\//, "", name); count[name]++; position[name] = NR
  file = "'"$WORK"'/libhooked/" name ".iyi"
  read_any = 0
  while ((status = getline line < file) > 0) { read_any = 1; if (line !~ /^@\[Unsafe\(/) print line }
  if (status < 0 || !read_any) exit 3
  close(file); next
}
{ print }
END {
  if (count["float"] != 1 || count["range"] != 1 || count["set"] != 1 ||
      count["array"] != 1 || count["hash"] != 1 || count["string"] != 1 ||
      position["string"] != position["float"] + 1 || position["array"] != position["string"] + 1 ||
      position["hash"] != position["range"] + 1 || position["set"] != position["hash"] + 1) exit 3
}'
lib_awk() { # label, source, destination, awk program
  local label="$1" source="$2" destination="$3" status
  awk "$4" "$source" > "$destination"
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "FAIL: $label: setup: the awk exited $status because an anchor is missing or duplicated"; exit 76
  fi
  cmp -s "$source" "$destination"
  status=$?
  if [ "$status" -eq 0 ]; then
    echo "FAIL: $label: setup: the awk found nothing to change"; exit 76
  elif [ "$status" -ne 1 ]; then
    echo "FAIL: $label: setup: could not compare the generated copy"; exit 76
  fi
  out="$(scan_added "$source" "$destination" "$label")" || { printf '%s\n' "${out:-FAIL: one ending: setup: $label could not be scanned}"; exit 76; }
}
mkdir -p libhooked libruntime/iyi libruntime_hook/iyi || { echo "FAIL: libruntime: setup: could not create the runtime copies"; exit 76; }
lib_awk libruntime-array "$REPO/src/iyi/array.iyi" libhooked/array.iyi "$LIB_POLL_ARRAY"
lib_awk libruntime-string "$REPO/src/iyi/string.iyi" libhooked/string.iyi "$LIB_POLL_STRING"
lib_awk libruntime-hash "$REPO/src/iyi/hash.iyi" libhooked/hash.iyi "$LIB_POLL_HASH"
lib_awk libruntime-defs "$REPO/src/iyi/concurrency.iyi" libhooked/concurrency.iyi "$TURN"
for copy in libruntime libruntime_hook; do
  cp "$REPO"/src/iyi/*.iyi "$copy/iyi/" || { echo "FAIL: $copy: setup: could not copy the runtime"; exit 76; }
  cp libhooked/*.iyi "$copy/iyi/" || { echo "FAIL: $copy: setup: could not copy the hooks"; exit 76; }
done
lib_awk libruntime-inline "$REPO/src/iyi/prelude.iyi" libruntime/iyi/prelude.iyi "$LIB_INLINE"
for copy in libruntime libruntime_hook; do
  if ! copy_build "$copy" parallel_preempt_lib -Dlibruntime_force; then
    echo "FAIL: $copy: setup: the library copy failed to build"; tail -20 "build-$copy.log"; exit 76
  fi
done
for proof in sort copy rehash join; do
  verdict_caught libruntime "$proof: the library's loop turned with its worker's word raised and kept its worker" "$proof" --workers=1
  verdict_held libruntime_hook "$proof: the library's loop gave its worker up at the turn after its word was raised" "$proof" --workers=1
done

step "failure proof: a library operation that never starts is named"
if ! awk '
  /^        answer\.set\(run_op\(name, clock\)\)$/ { n++; print "        sleep(60000)"; next }
  { print }
  END { if (n != 1) exit 3 }
' "$REPO/bench/parallel_preempt_lib.iyi" > library_watchdog.iyi; then
  echo "FAIL: library_watchdog: setup: the operation anchor was missing or duplicated"; exit 76
fi
if ! "$IYI" build "$WORK/library_watchdog.iyi" -o library_watchdog-run > build-library_watchdog.log 2>&1; then
  echo "FAIL: library_watchdog: setup: the fixture failed to build"; tail -20 build-library_watchdog.log; exit 76
fi
verdict_watchdog library_watchdog 'FAIL: sort: progress hang: the operation did not reach its checkpoint' sort --workers=1

# The two halves of `copy_checks`, broken: `Pointer#copy_from` with no way
# around its loop of runs, as it was, and darwin's anchor in the entry
# block (`-Dpreempt_anchor_entry`), which only darwin's makes by a call.
step "failure proof: a copy whose every run goes through the loop of runs checks however short it is"
mkdir -p copyruns/iyi || { echo "FAIL: copyruns: setup: could not create the runtime copy"; exit 76; }
cp "$REPO"/src/iyi/*.iyi copyruns/iyi/ || { echo "FAIL: copyruns: setup: could not copy the runtime"; exit 76; }
lib_awk copyruns "$REPO/src/iyi/string.iyi" copyruns/iyi/string.iyi '/^  def copy_from\(source : Pointer\(T\), count : Int32\) : Nil$/ { inside = 1; methods++ }
inside && /^  end$/ { inside = 0 }
inside && /^    return copy_run\(source, count\) if count <= 1048576$/ { n++; next }
{ print }
END { if (methods != 1 || n != 1) exit 3 }'
if ! IYI_PATH="$WORK/copyruns${PSEP}$REPO/src" "$IYI" build --release --emit llvm-ir "$REPO/bench/parallel_preempt_lib.iyi" -o copyruns-run > build-copyruns.log 2>&1; then
  echo "FAIL: copyruns: setup: the copy failed to build"; tail -20 build-copyruns.log; exit 76
fi
copy_checks copyruns-run.ll > copyruns.txt 2>&1
code=$?
want='FAIL: copy checks: every copy in copy_bytes passes a check before it returns, however short'
if [ "$code" -ne 1 ] || [ "$(grep -cxF -- "$want" copyruns.txt)" -ne 1 ] || [ "$(grep -c '^FAIL: ' copyruns.txt)" -ne 1 ]; then
  echo "FAIL: copyruns: setup: the checker did not exit 1 at its exact copy line (exit $code)"; cat copyruns.txt; exit 76
fi
echo "  exits 1 at \"${want#FAIL: }\""

step "failure proof: darwin's anchor in the entry block calls the accessor at every copy"
if [ "$(uname -s)" != Darwin ]; then
  echo "  anchorentry: skipped outside Darwin, where this anchor does not call an accessor"
else
  if ! "$IYI" build --release --emit llvm-ir -Dpreempt_anchor_entry "$REPO/bench/parallel_preempt_lib.iyi" -o anchorentry-run > build-anchorentry.log 2>&1; then
    echo "FAIL: anchorentry: setup: the copy failed to build"; tail -20 build-anchorentry.log; exit 76
  fi
  copy_checks anchorentry-run.ll > anchorentry.txt 2>&1
  code=$?
  want='FAIL: copy checks: the entry block of copy_bytes calls the thread-local accessor *IyiWorkers::preempt, which every copy then pays'
  if [ "$code" -ne 1 ] || [ "$(grep -cxF -- "$want" anchorentry.txt)" -ne 1 ] || [ "$(grep -c '^FAIL: ' anchorentry.txt)" -ne 1 ]; then
    echo "FAIL: anchorentry: setup: the checker did not exit 1 at its exact accessor line (exit $code)"; cat anchorentry.txt; exit 76
  fi
  echo "  exits 1 at \"${want#FAIL: }\""
fi

step "failure proof: a recursion marked @[NoPreempt] holds its worker for its whole computation"
broken recursionoff "$TURN" concurrency.iyi parallel_preempt_lib -Drecursion_force -Dpreempt_off
verdict_caught recursionoff "fib: the recursion entered a call with its worker's word raised and kept its worker" fib --workers=1
broken recursionoff_hook "$TURN" concurrency.iyi parallel_preempt_lib -Drecursion_force
verdict_held recursionoff_hook "fib: the recursion gave its worker up at the call after its word was raised" fib --workers=1

step "failure proof: a regex search, a JSON parse and a bcrypt hash made through the runtime hold their worker for the whole call"
# Both copies use the same forced turns. Only the mutant invokes the call
# through a runtime definition, compiling its body without preemption checks.
STD_UNCHECKED='in_turn_workers && /^  def self.looks : UInt64$/ {
  n_unchecked++
  print "  def self.force_runtime_call(call : T) : Int64 forall T"
  print "    call.run_call"
  print "  end"
  print ""
}'
TURN_STD="$TURN_COMMON
$STD_UNCHECKED
{ print }
END { if ($TURN_CHECK || n_unchecked != 1) exit 3 }"
broken stdcall "$TURN_STD" concurrency.iyi parallel_preempt_lib -Dstdcall_force -Dstd_unchecked
broken stdcall_hook "$TURN_STD" concurrency.iyi parallel_preempt_lib -Dstdcall_force
for proof in regex json bcrypt; do
  verdict_caught stdcall "$proof: the library call returned with its worker's word raised and kept its worker" "$proof" --workers=1
  verdict_held stdcall_hook "$proof: the library call gave its worker up after its word was raised" "$proof" --workers=1
done

step "failure proof: a scheduler the compiler takes for a library's checks, and the audit names where"
[ -n "$PY" ] || { echo "FAIL: rtout: setup: Python is unavailable for the audit"; exit 76; }
  # `concurrency.iyi` renamed `scheduler.iyi`: the compiler treats it as
  # a library, while the audit finds its scheduler functions by identity.
  mkdir -p rtout/iyi || { echo "FAIL: rtout: setup: could not create the runtime copy"; exit 76; }
  cp "$REPO"/src/iyi/*.iyi rtout/iyi/ || { echo "FAIL: rtout: setup: could not copy the runtime"; exit 76; }
  mv rtout/iyi/concurrency.iyi rtout/iyi/scheduler.iyi || { echo "FAIL: rtout: setup: could not rename the scheduler"; exit 76; }
  lib_awk rtout "$REPO/src/iyi/prelude.iyi" rtout/iyi/prelude.iyi '$0 == "{% if (flag?(:linux) && (flag?(:x86_64) || flag?(:aarch64))) || (flag?(:darwin) && flag?(:aarch64)) || (flag?(:win32) && flag?(:x86_64)) %}" { platforms++; expect = 1; print; next }
expect { if ($0 != "  require \"./concurrency\"") exit 3; expect = 0 }
/^  require "\.\/concurrency"$/ { n++; print "  require \"./scheduler\""; next }
{ print }
END { if (platforms != 1 || n != 1 || expect) exit 3 }'
  if ! IYI_PATH="$WORK/rtout${PSEP}$REPO/src" "$IYI" build --emit llvm-ir "$REPO/bench/parallel_preempt_lib.iyi" -o rtout-run > build-rtout.log 2>&1; then
    echo "FAIL: rtout: setup: the renamed scheduler failed to build"; tail -20 build-rtout.log; exit 76
  fi
  "$PY" "$REPO/bench/preempt_audit.py" rtout-run.ll > rtout.txt 2>&1
  code=$?
  audit_count="$(awk 'NR == 1 && /^preempt audit: [1-9][0-9]* function\(s\) the runtime reaches hold a preemption check:$/ { print $3 }' rtout.txt)"
  want="preempt audit: $audit_count function(s) the runtime reaches hold a preemption check:"
  if [ "$code" -ne 1 ] || [ -z "$audit_count" ] || [ "$(grep -cxF -- "$want" rtout.txt)" -ne 1 ]; then
    echo "FAIL: rtout: setup: the audit did not exit 1 at its exact checked-runtime line (exit $code)"; cat rtout.txt; exit 76
  fi
  echo "  exits 1 at \"$want\""

# ── 8. Failure proof: one worker, whatever was asked for ──────────────────
# The capacity witness catches the wrong pool size before trying to hold K
# tasks together. The speed parser and the floor checker are checked separately.
step "failure proof: a pool held to one worker fails the capacity witness"
need_cores 2 "the capacity witness needs at least two workers"
  mkdir -p oneworker/iyi || { echo "FAIL: one-worker: setup: could not create the copy"; exit 76; }
  cp "$REPO"/src/iyi/*.iyi oneworker/iyi/ || { echo "FAIL: one-worker: setup: could not copy the runtime"; exit 76; }
  if ! awk '/^  def self.start : Nil$/ { inside = 1; methods++ }
inside && /^  end$/ { inside = 0 }
inside && /^      workers = resolved$/ { print "      workers = 1"; n++; next }
{ print }
END { if (methods != 1 || n != 1) exit 3 }' \
    "$REPO/src/iyi/concurrency.iyi" > oneworker/iyi/concurrency.iyi; then
    echo "FAIL: one-worker: setup: the mutation anchor was missing or duplicated"; exit 76
  fi
  if ! copy_build oneworker parallel_exercise --release; then
    echo "FAIL: one-worker: setup: the copy failed to build"; tail -20 build-oneworker.log; exit 76
  fi
  verdict_caught oneworker "capacity: the pool started 1 worker, expected $K" capacity "$K"
  step "failure proof: the at-once floor checker rejects a one-worker sample"
  got="$(speed_run "$K" oneworker-run)" || exit $?
  SLOW="${got% *}"
  SLOW_AT="${got#* }"
  floor_line="FAIL: speed: $K workers held their tasks $(at_once "$SLOW_AT") at once on average: under 0.6 x $K, which is not parallel"
  check_at_once_floor "$SLOW_AT" "$K" > oneworker-floor.txt 2>&1
  code=$?
  if [ "$code" -ne 1 ] || [ "$(grep -cxF -- "$floor_line" oneworker-floor.txt)" -ne 1 ] || [ "$(wc -l < oneworker-floor.txt | tr -d ' ')" -ne 1 ]; then
    echo "FAIL: one-worker: setup: the floor checker did not exit 1 at its exact below-floor line (exit $code)"; cat oneworker-floor.txt; exit 76
  fi
  echo "  exits 1 at \"$floor_line\""
  echo "  measure: asked for $K, ran on 1, one run: $(at_once "$SLOW_AT") at once, under the floor; $SLOW ms, not judged"

echo "parallel gate: every property held"
