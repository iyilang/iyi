#!/usr/bin/env bash
# Drives bench/parallel_exercise.iyi: tasks across cores (SPEC.md III.4.13).
#
#     bash bench/parallel_exercise.sh
#
# Eight steps; the last three are failure proofs, because a gate that
# cannot fail is not a gate:
#
# Timing-decided, not forced:
#   kerneljoin: a finite thread and latency bound decide; hold the joined thread and record its kernel join.
#   nosteal: a balance timing bound decides; hold the owner and record a targeted steal decision.
#   preemptoff: a timed short task decides; hold the computation and require the short task before release.
#   noflag: a timed short task decides; hold the computation and record the monitor's raised-word decision.
#   nopoll: a request latency bound decides; hold the slow task and record the targeted poll decision.
#   stale: a timed monitor/switch alignment decides; force the raised word across the targeted switch.
#   libruntime sort: finite work and latency decide; hold an in-sort poll point until a short task is queued.
#   libruntime copy: finite work and latency decide; hold an in-copy poll point until a short task is queued.
#   libruntime rehash: finite work and latency decide; hold an in-rehash poll point until a short task is queued.
#   libruntime join: finite work and latency decide; hold an in-join poll point until a short task is queued.
#   recursionoff: finite recursion and latency decide; hold a recursion poll point until a short task is queued.
# The healthy library run reports latency without a pass/fail bound.
# Conditional, not forced:
#   closeshome: registration relies on a sleep and a wake-count check can mask the verdict; record registration and judge placement first.
#   duplicate: another worker must steal the stale head; rendezvous at that head would force the witness.
#   tokenless: preemption must land with a same-unit child runnable; hold that child ready across the switch.
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
#   2. bench/parallel_migrate.iyi holds what a task keeps when it resumes
#      on another worker, plain and --release: its stack's lists through
#      collections, thread-locals of the thread it is on, after a park and
#      after a loop's back-edge check that moved it, its socket's bytes, a
#      cancel and a close from a sibling or the main thread that find it,
#      frames 120 KiB deep; tasks parked on one worker finish in under
#      twice the ideal, woken from the main thread and from a worker; a
#      task woken by a task that then computes with preemption off has an
#      idle worker called for it, runs on another worker, and starts
#      within 1 ms (not judged on a host loaded past its cores), and
#      within 50 ms after a ping-pong
#      left its waker's worker calling nobody, where the monitor calls; on
#      Linux and darwin an answer sent while the reader's worker is held
#      is read on another worker before that hold ends; and a task joining
#      a thread leaves its worker to its child. On Windows,
#      bench/completions_taken.iyi checks the shared completion port: an
#      answer is read on another worker while the reader's worker is held.
#      The process's priority boost is off once the pool has started.
#      bench/parallel_preempt.iyi checks preemption at loop back-edges
#      (SPEC.md III.4.13, part 9): a short task and a sleeper run beside a
#      computing task; a dedicated fast request is served while a slow
#      handler stays active, and bulk server latency is measured; the
#      poller request also has its own bound; a preempted task
#      keeps its unit's token; a task switched in after one that held its
#      worker past a look begins its own quantum; the monitor looks every
#      4 to 10.5 ms (8 on Windows) and the quantum is at most three of
#      those looks; a tight loop costs at most twice what its
#      `@[NoPreempt]` twin does; and the release build's IR shows each
#      tight loop's checks reading the worker's word through the thread
#      pointer, none calling its thread-local accessor. Its failure proofs
#      are with step 7's: a `@[NoPreempt]` loop, a monitor that never
#      raises the word, a Windows monitor on the system timer's tick, a
#      monitor that raises it after three unchanged looks, a check that
#      calls the accessor (darwin and Windows), a slow half that does not
#      poll, a word left raised for the task before, and a preempted task
#      that gives its unit's token away.
#   3. The binary keeps the dependency floor the concurrency gate holds,
#      plus `environ`, the C runtime's table `IYI_WORKERS` is read from.
#   4. The speedup, measured: CPU-bound tasks on one worker and on several,
#      release build, best of three. K workers must hold their tasks on
#      0.6 x K threads at once on average, at any load; and where the host
#      leaves K cores free, finish 0.6 x K times faster than one - a pool
#      that is parallel only in name cannot pass either. The table for 1,
#      2, 4 and 8 workers (as far as the cores go) is printed for the
#      record.
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
#      pool (a cancelled task run as if it were not), a cancel that leaves
#      an io wait parked (a panic that never ends its program),
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
#      Timing-decided, not forced: kerneljoin, nosteal, preemptoff, noflag,
#      coarse, nopoll, stale, tokenless, libruntime (sort, copy, rehash and
#      join), and recursionoff. Their elapsed-time checks do not establish
#      the intended scheduler placement or wait decision.
#   8. Failure proof: the pool held to one worker whatever it was asked
#      for, and step 4's floors refuse what comes out.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"

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

. "$REPO/bench/floor_base.sh"

cd "$WORK" || exit 1

step() { echo "== $1"; }

# The cores this process may run on, as the pool counts them.
cores() {
  case "$(uname -s)" in
    Darwin) sysctl -n hw.ncpu ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT) echo "${NUMBER_OF_PROCESSORS:-1}" ;;
    *) nproc ;;
  esac
}
CORES="$(cores)"

# A host with fewer cores than a proof needs fails the gate: a proof skipped
# there proves nothing, and every CI shape has four cores.
need_cores() { # cores, what the proof needs
  if [ "$CORES" -lt "$1" ]; then echo "this host has $CORES cores, and the proof needs $1: $2"; exit 1; fi
}

# ── 1. The exercise, twice ────────────────────────────────────────────────
for build in plain release; do
  step "every property, $build build"
  flag=""
  [ "$build" = release ] && flag="--release"
  if ! "$IYI" build $flag "$REPO/bench/parallel_exercise.iyi" -o "exercise-$build" > "build-$build.log" 2>&1; then
    echo "build failed:"; tail -20 "build-$build.log"; exit 1
  fi
  timeout -k 5 600 "./exercise-$build" > "answers-$build.txt" 2>&1
  code=$?
  if [ "$code" -ne 0 ] || ! grep -q 'every property held' "answers-$build.txt"; then
    echo "the exercise failed (exit $code):"; cat "answers-$build.txt"; exit 1
  fi
  if grep -q 'a done fiber was scheduled' "answers-$build.txt"; then
    echo "the exercise scheduled a finished fiber:"; cat "answers-$build.txt"; exit 1
  fi
  grep -v '^iyi: panic: parallel boom' "answers-$build.txt" | sed 's/^/  /'
done

# ── 2. What a move keeps, twice ───────────────────────────────────────────
# Its balance step is timed against four workers' ideal, so a host with fewer
# cores fails before the migration exercise runs.
MIGRATE_STEPS="channels sockets cancel closes deep loops balance backstop heldio join"
need_cores 4 "the balance step is timed against four workers' ideal"
# The handoff step runs by itself after the others, its host's load read
# the second before it. Its 1 ms median is a sleeping thread's wake,
# which Linux and Windows do not owe a machine with more runnable threads
# than cores: Linux on 12 vCPUs at one-minute loads of 18 to 34 failed it
# in 74 of 80 runs, the medians near its 2.9 ms slice, and Windows on 12
# vCPUs beside 12 and 24 busy loops in 32 of 80, at 0.1 to 6.2 ms.
# So a run whose load is at or past the cores is told so (`--loaded=`),
# and the step holds there only what no clock blurs: an idle worker
# called at each hand-off, the woken task run on another worker, within
# 40 ms. Linux's load is its threads runnable, `procs_running` in
# /proc/stat less the one reading it, ten looks over the second: the
# one-minute average lags it, and a run begun at an average of 8.4 on
# those 12 vCPUs failed the median. Windows keeps none, so its load is
# the busy share of the cores plus the ready queue over the second,
# which read 0.1 to 1.2 idle, 6.1 to 7.3 beside 6 busy loops (no run
# failed) and 20 to 45 beside 12 to 24. darwin woke the tasks in 7 to
# 218 us at loads of 4 to 44 on 10 cores (tmac, 160 runs) of busy loops,
# and was always judged until it failed beside two other CI jobs on the
# project's Mac, three runners on those 10 cores: 11 to 2,925 us, the
# median 2,150 (job 135122969351; its other runs there 14 to 45 at the
# median). A busy loop is not what those jobs run - compilers and gates
# that sleep, fork and touch memory - so darwin is read the way Linux is:
# its threads runnable, a `ps -axM` thread row whose state is R, less the
# one reading it, ten looks over the second.
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
    echo "build failed:"; tail -20 "build-migrate-$build.log"; exit 1
  fi
  # shellcheck disable=SC2086 # the steps are words
  timeout -k 5 600 "./migrate-$build" $MIGRATE_STEPS > "migrated-$build.txt" 2>&1
  code=$?
  if [ "$code" -ne 0 ] || ! grep -q 'every property held' "migrated-$build.txt"; then
    echo "the migration exercise failed (exit $code):"; cat "migrated-$build.txt"; exit 1
  fi
  sed 's/^/  /' "migrated-$build.txt"
  load="$(host_load)"
  loaded=""
  judged=""
  if [ -n "$load" ] && awk -v l="$load" -v c="$CORES" 'BEGIN { exit !(l >= c) }'; then
    loaded="a load of $load on $CORES cores"
  elif [ -n "$load" ]; then
    judged="; judged at a load of $load on $CORES cores"
  fi
  timeout -k 5 300 "./migrate-$build" handoff ${loaded:+"--loaded=$loaded"} > "handed-$build.txt" 2>&1
  code=$?
  if [ "$code" -ne 0 ] || ! grep -q 'every property held' "handed-$build.txt"; then
    echo "the hand-off step failed${load:+ at a load of $load on $CORES cores} (exit $code):"; cat "handed-$build.txt"; exit 1
  fi
  grep -v 'every property held' "handed-$build.txt" | sed "s/^/  /; s/\$/$judged/"
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
        echo "build failed:"; tail -20 "build-taken-$build.log"; exit 1
      fi
      timeout -k 5 300 "./taken-$build" boost taken --workers=12 > "taken-$build.txt" 2>&1
      code=$?
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
# active; bulk server latency is measured; a preempted task
# keeps its unit's token; a task switched in is not given up on the word
# raised for the one before it; the monitor looks every 4 to 10.5 ms (8
# on Windows) and two tasks on one worker take turns of at most three of
# those looks; the tight loops cost at most twice what their
# `@[NoPreempt]` twins cost; and their checks read the word through the
# thread pointer, in the release build's IR, which it writes for that.
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
    echo "build failed:"; tail -20 "build-preempt-$build.log"; exit 1
  fi
  for run in "slice --workers=1" "unit --workers=1" "period --workers=1" "poller --workers=1" "fresh --workers=1" "server --workers=$PREEMPT_WORKERS"; do
    # shellcheck disable=SC2086 # the step and its count are words
    timeout -k 5 300 "./preempt-$build" $run > "preempted-$build.txt" 2>&1
    code=$?
    if [ "$code" -ne 0 ] || ! grep -q 'every property held' "preempted-$build.txt"; then
      echo "the preemption exercise failed at $run (exit $code):"; cat "preempted-$build.txt"; exit 1
    fi
    grep -v 'every property held' "preempted-$build.txt" | sed 's/^/  /'
  done
done
step "what the check costs a tight loop, release build"
timeout -k 5 300 ./preempt-release tight --workers=1 > tight.txt 2>&1
code=$?
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
        if ("accessor" in counts) fails = fails "FAIL: tight checks: " fn ": " counts["accessor"] " of " n " back-edge checks call the thread-local accessor *IyiWorkers::preempt\n"
        else if ("another way" in counts) fails = fails "FAIL: tight checks: " fn ": " counts["another way"] " of " n " back-edge checks read the word neither through the thread pointer nor by the accessor\n"
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

# ── 2c. Preemption inside the library, std and recursion, twice ──────────
# bench/parallel_preempt_lib.iyi: a sort, a copy, a hash's growth, a join,
# a regex search, a JSON parse, a bcrypt hash and a recursion with no loop
# each give their worker up to a short task within 100 ms. The release
# build writes its IR too, for the audit after.
for build in plain release; do
  step "preemption inside library calls and recursion, $build build"
  flag=""
  [ "$build" = release ] && flag="--release --emit llvm-ir"
  # shellcheck disable=SC2086 # the flags are words
  if ! "$IYI" build $flag "$REPO/bench/parallel_preempt_lib.iyi" -o "preemptlib-$build" > "build-preemptlib-$build.log" 2>&1; then
    echo "build failed:"; tail -20 "build-preemptlib-$build.log"; exit 1
  fi
  timeout -k 5 600 "./preemptlib-$build" sort copy rehash join regex json bcrypt fib --workers=1 > "preemptedlib-$build.txt" 2>&1
  code=$?
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
[ -n "$PY" ] || { echo "no python here to read the IR with: the audit cannot run"; exit 1; }
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
    DUMPBIN="$(find_dumpbin || true)"
    if [ -z "$DUMPBIN" ]; then
      echo "  no dumpbin here, so the import floor is not measured"
    else
      dlls="$(pe_dlls exercise-plain.exe)"
      [ -n "$dlls" ] || { echo "dumpbin read no import table out of the exercise"; exit 1; }
      extra="$(extra_dlls "$FLOOR_DLLS_RUNTIME" "$dlls")"
      if [ -n "$extra" ]; then
        echo "the pool moved the Windows floor: the exercise imports $(echo $extra)"; exit 1
      fi
      echo "  imports: $(echo $dlls)"
    fi
    ;;
  Darwin)
    [ -n "$NM" ] || { echo "no nm here, so the symbol floor is not measured"; exit 1; }
    runtime='___error __dyld_get_image_header __dyld_get_image_vmaddr_slide __tlv_bootstrap _backtrace _backtrace_symbols_fd _clock_gettime_nsec_np _exit _kevent _kqueue _mmap _mprotect _munmap _os_sync_wait_on_address _os_sync_wake_by_address_all _pthread_create _pthread_get_stackaddr_np _pthread_self _sigaction _sigaltstack _sysctlbyname _thread_switch _write'
    thread='_close _pthread_kill'
    pool='_environ'
    allowed="$(printf '%s\n' $runtime $thread $pool | sort -u)"
    for bin in exercise-plain exercise-release; do
      found="$("$NM" -u "$bin" | sed -e 's/^ *//' | awk '{ print $NF }' | sort -u)"
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
    [ -n "$NM" ] || { echo "no nm here, so the symbol floor is not measured"; exit 1; }
    for bin in exercise-plain exercise-release; do
      added="$("$NM" -u "$bin" |
        sed -e 's/^ *[wU] *//' -e 's/@.*$//' |
        grep -v -E '^(_ITM_deregisterTMCloneTable|_ITM_registerTMCloneTable|__cxa_finalize|__gmon_start__|__libc_start_main|environ|__environ)$' |
        grep -cv '^\s*$')"
      if [ "$added" -ne 0 ]; then
        echo "the pool put $added undefined symbols on $bin's link line:"; "$NM" -u "$bin"; exit 1
      fi
    done
    echo "  the C runtime template's names and environ, which IYI_WORKERS is read through, plain and release: the pool itself is raw syscalls"
    ;;
esac

# ── 3. The speedup ────────────────────────────────────────────────────────
# Sixteen tasks of integer work with nothing to allocate, so the ratio is
# the scheduler's and not the collector's. Best of three, because a
# shared machine's clock is weather.
#
# The wall-clock ratio is a host's as much as the pool's: Linux on 12
# vCPUs beside 12 busy loops (`procs_running` 17) gave 4 workers 2.10x
# one worker's time, where an idle run gives 3.4 to 3.9x, and 8 workers
# 4.72x in the same run. So the ratio is judged only where the host has
# the K workers' cores free - its load, read as the hand-off step reads
# it, at most the cores less K before the runs and after them - and is
# printed with the reason otherwise. What no load blurs is held at every
# load: how many threads held a task at once, on average over the run
# (`at_once` in hundredths, each task looking at its thread and the clock
# every 65536 rounds): a thread holds its task whether or not the kernel
# has it on a core, and a pool that runs its tasks one thread at a time
# cannot pass 1.00, so K workers are held to 0.6 x K there too.
TASKS=16
ROUNDS=40000000
best_ms() { # workers binary -> "fastest_ms most_at_once"
  local best="" most="" run line ms at
  for run in 1 2 3; do
    line="$(timeout -k 5 300 "./$2" speed "$1" "$TASKS" "$ROUNDS")"
    ms="$(echo "$line" | sed -n 's/.*wall_ms=\([0-9]*\).*/\1/p')"
    at="$(echo "$line" | sed -n 's/.*at_once=\([0-9]*\).*/\1/p')"
    [ -n "$ms" ] && [ -n "$at" ] || { echo "the speed run at $1 workers printed no time: $line" >&2; return 1; }
    if [ -z "$best" ] || [ "$ms" -lt "$best" ]; then best="$ms"; fi
    if [ -z "$most" ] || [ "$at" -gt "$most" ]; then most="$at"; fi
  done
  echo "$best $most"
}
# The floor: k workers must finish at least 0.6 * k times faster than one.
holds_floor() { # one_ms k_ms k
  awk -v one="$1" -v many="$2" -v k="$3" 'BEGIN { exit !(many > 0 && one / many >= 0.6 * k) }'
}
# The same floor on the threads that held a task at once.
holds_at_once() { # at_once_hundredths k
  [ "$1" -ge $((60 * $2)) ]
}
at_once() { awk -v a="$1" 'BEGIN { printf "%.2f", a / 100 }'; }
K=4
[ "$CORES" -lt "$K" ] && K="$CORES"
step "the speedup: $TASKS CPU-bound tasks, release build, best of three, $CORES cores here"
if [ "$CORES" -lt 2 ]; then
  echo "  one core here: nothing to scale onto, so the ratio is not held"
else
  SPEED_LOAD="$(host_load)"
  got="$(best_ms 1 exercise-release)" || exit 1
  ONE="${got% *}"
  printf '  %2s worker(s): %6s ms, %s at once\n' 1 "$ONE" "$(at_once "${got#* }")"
  MANY=""
  MANY_AT=""
  for w in 2 4 8; do
    [ "$w" -gt "$CORES" ] && break
    got="$(best_ms "$w" exercise-release)" || exit 1
    ms="${got% *}"
    ratio="$(awk -v a="$ONE" -v b="$ms" 'BEGIN { printf "%.2f", a / b }')"
    printf '  %2s worker(s): %6s ms, %sx one worker, %s at once\n' "$w" "$ms" "$ratio" "$(at_once "${got#* }")"
    [ "$w" -eq "$K" ] && { MANY="$ms"; MANY_AT="${got#* }"; }
  done
  if [ -z "$MANY" ]; then
    got="$(best_ms "$K" exercise-release)" || exit 1
    MANY="${got% *}"; MANY_AT="${got#* }"
  fi
  after="$(host_load)"
  [ -n "$after" ] && { [ -z "$SPEED_LOAD" ] || awk -v a="$after" -v b="$SPEED_LOAD" 'BEGIN { exit !(a > b) }'; } && SPEED_LOAD="$after"
  if ! holds_at_once "$MANY_AT" "$K"; then
    echo "$K workers held their tasks $(at_once "$MANY_AT") at once on average: under 0.6 x $K, which is not parallel"
    exit 1
  fi
  # Judged where the load leaves K cores free, or where none is read.
  SPEED_JUDGED=yes
  [ -n "$SPEED_LOAD" ] && awk -v l="$SPEED_LOAD" -v c="$CORES" -v k="$K" 'BEGIN { exit !(l > c - k) }' && SPEED_JUDGED=""
  if [ -n "$SPEED_JUDGED" ]; then
    if ! holds_floor "$ONE" "$MANY" "$K"; then
      echo "$K workers took $MANY ms against one worker's $ONE ms: under 0.6 x $K, which is not parallel${SPEED_LOAD:+ (a load of $SPEED_LOAD on $CORES cores)}"
      exit 1
    fi
    echo "  $K workers: $(awk -v a="$ONE" -v b="$MANY" 'BEGIN { printf "%.2f", a / b }')x one worker, over the floor of $(awk -v k="$K" 'BEGIN { printf "%.1f", 0.6 * k }')x${SPEED_LOAD:+, judged at a load of $SPEED_LOAD on $CORES cores}; $(at_once "$MANY_AT") at once"
  else
    echo "  $K workers: $(at_once "$MANY_AT") at once, over the floor of $(awk -v k="$K" 'BEGIN { printf "%.1f", 0.6 * k }'); the time's ratio not judged, a load of $SPEED_LOAD on $CORES cores leaving fewer than $K free"
  fi
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
  echo "the deadlock program failed to build:"; tail -20 build-deadlock.log; exit 1
fi
timeout -k 5 30 ./paralleldeadlock > deadlock.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -q 'deadlock: every fiber is blocked' deadlock.txt; then
  echo "a deadlock across threads exited $code (124 is a hang):"; cat deadlock.txt; exit 1
fi
echo "  exits 1: $(grep -m1 'deadlock' deadlock.txt)"

# ── 4a. A panic or an exit ends the process ──────────────────────────────
# bench/panic_exit.iyi: tasks parked on the poller (reads nobody answers,
# an accept nobody connects to) beside sleepers and channel receivers. The
# program is then ended three ways: a task's panic, the main task's panic,
# and a task's `exit(3)`. Each runs on twelve workers and on the main
# thread alone. The program's watchdog names a run still going 5 s after
# its start, which is a cancel that left some wait parked and the join
# waiting on it. The timeout here is for an exit that never ends. The
# first run is the virus scanner's first look at a new binary, 11.1 s for
# one program on the user's Windows 11 machine (12 logical processors),
# so it is not one of the timed runs.
step "a panic or an exit ends the process with tasks parked on the poller"
if ! "$IYI" build "$REPO/bench/panic_exit.iyi" -o panic_exit > build-panic-exit.log 2>&1; then
  echo "build failed:"; tail -20 build-panic-exit.log; exit 1
fi
timeout -k 5 60 ./panic_exit > /dev/null 2>&1
for workers in 12 0; do
  where="on 12 workers"
  [ "$workers" = 0 ] && where="on the main thread"
  for mode in task-panic main-panic task-exit; do
    case "$mode" in
      task-panic) want=1 said='iyi: panic: a task panicked: ' ;;
      main-panic) want=1 said="iyi: panic: the main task's panic" ;;
      task-exit) want=3 said='' ;;
    esac
    timeout -k 5 10 ./panic_exit "$mode" --workers="$workers" > panic-exit.txt 2>&1
    code=$?
    if [ "$code" -ne "$want" ] || grep -q '^FAIL: ' panic-exit.txt || { [ -n "$said" ] && ! grep -qF "$said" panic-exit.txt; }; then
      echo "$mode $where exited $code, not $want (124 is an exit that never ended):"; cat panic-exit.txt; exit 1
    fi
    ended="$(grep -m1 'every task ended' panic-exit.txt | sed 's/^[a-z-]*: every task ended /, every task ended /')"
    echo "  $mode $where: exits $code$ended"
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
awk '/^@\[SafeReach/ { next } /^module reaches$/ { print "module reaches_bare"; next } { print }' reaches.iyi > reaches_bare.iyi
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
awk '/ask\(2_i64\)/ { next } /^module reaches_bare$/ { print "module reaches_lone"; next } { print }' reaches_bare.iyi > reaches_lone.iyi
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
# Each a copy of src/iyi with one file changed - concurrency.iyi unless
# another is named - built against through IYI_PATH, of the program named
# or of parallel_exercise.iyi, with any build flags after the program's
# name; nothing in the tree is touched. An awk that finds an anchor gone
# exits nonzero, and that fails the gate.
broken() { # name, awk program[, file in src/iyi[, program in bench[, build flags...]]]
  local file="${3:-concurrency.iyi}" program="${4:-parallel_exercise}" awk_status
  mkdir -p "$1/iyi"
  cp "$REPO"/src/iyi/*.iyi "$1/iyi/"
  awk "$2" "$REPO/src/iyi/$file" > "$1/iyi/$file"
  awk_status=$?
  if [ "$awk_status" -ne 0 ]; then
    echo "the awk for $1 exited $awk_status: an anchor it needs is gone from $file"; exit 1
  fi
  if cmp -s "$1/iyi/$file" "$REPO/src/iyi/$file"; then
    echo "the awk for $1 found nothing to change"; exit 1
  fi
  if ! IYI_PATH="$WORK/$1${PSEP}$REPO/src" "$IYI" build "${@:5}" "$REPO/bench/$program.iyi" -o "$1-run" > "build-$1.log" 2>&1; then
    echo "the broken copy $1 failed to build:"; tail -20 "build-$1.log"; exit 1
  fi
}
# Mutants must exit 1 with the exact FAIL or panic line; controls must
# exit with their expected status and exact verdict. Timing-decided
# exceptions are named in the header. Timeouts never count as catches.
verdict_caught() { # name, exact verdict, step arguments...
  local name="$1" want="$2" code
  shift 2
  timeout -k 5 120 "./$name-run" "$@" > "$name.txt" 2>&1
  code=$?
  if [ "$code" -ne 1 ] || ! grep -qxF -- "FAIL: $want" "$name.txt"; then
    echo "the broken copy $name did not end at its verdict on its one run (exit $code; want exit 1 and the line \"FAIL: $want\"):"; tail -20 "$name.txt"; exit 1
  fi
  echo "  exits 1 at \"$want\""
}
verdict_held() { # name, exact verdict, step arguments...
  local name="$1" want="$2" code
  shift 2
  timeout -k 5 120 "./$name-run" "$@" > "$name.txt" 2>&1
  code=$?
  if [ "$code" -ne 0 ] || ! grep -qxF -- "$want" "$name.txt"; then
    echo "the hook-only control $name did not pass with its verdict line (exit $code; want exit 0 and the line \"$want\"):"; tail -20 "$name.txt"; exit 1
  fi
  echo "  hook-only control $name passes: \"$want\""
}
caught_line() { # name, exact line, step arguments...
  local name="$1" want="$2" code
  shift 2
  timeout -k 5 120 "./$name-run" "$@" > "$name.txt" 2>&1
  code=$?
  if [ "$code" -ne 1 ] || ! grep -qxF -- "$want" "$name.txt"; then
    echo "the broken copy $name did not exit 1 at \"$want\" (exit $code):"; tail -20 "$name.txt"; exit 1
  fi
  echo "  exits 1 at \"$want\""
}
# The copy-only definitions the forced proofs add to the runtime's files, in
# awk output only: nothing reaches src/iyi. Each is reached through a -D flag
# the program sets, so no healthy build sees it. An awk that misses an anchor
# exits 3, which fails the gate through broken().
WAKE_COMMON='/^  def self.wait_shared\(st : IyiSchedulerState\) : Nil$/ { inws = 1; n_wait++ }
inws && /^  end$/ { inws = 0 }
inws && /^    st.idle = true$/ { print; print "    IyiScheduler.force_idle_mark(st)"; n_mark++; next }
inws && /^    wait_for_events\(true\)$/ { print "    IyiScheduler.force_idle_hold(st)"; print; n_hold++; next }
/^  def self.send_home\(home : IyiSchedulerState, fiber : IyiFiber\) : Nil$/ { insend = 1; n_send++ }
insend && /^  end$/ { insend = 0 }
insend && /^    home.post_mail$/ { print; print "    force_home_post(home, fiber)"; n_post++; next }'
WAKE_RING_BUG='insend && /^    ring\(home\)$/ { print "    force_home_done(home, fiber)"; n_ring++; next }'
WAKE_RING_HOOK='insend && /^    ring\(home\)$/ { print; print "    force_home_done(home, fiber)"; n_ring++; next }'
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
  print "      raise \"home: copy hook waited for the target post decision\" if __iyi_monotonic_ns - started > 10000000000_i64"
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
  print "      puts \"FAIL: home: the targeted post found the root not idle\""
  print "      __iyi_exit(1)"
  print "    end"
  print "    unless home.notified"
  print "      puts \"FAIL: home: the targeted idle root was posted but not rung\""
  print "      __iyi_exit(1)"
  print "    end"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_home_result).address).value.set(1_u64)"
  print "  end"
  print "  def self.force_home_completed? : Bool"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_home_result).address).value.get == 1_u64"
  print "  end"
  print
  n_defs++
  next
}'
WAKE_END='END { if (n_wait != 1 || n_mark != 1 || n_hold != 1 || n_send != 1 || n_post != 1 || n_ring != 1 || n_defs != 1) exit 3 }'
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
NOW_LOCK_BUG='intake && /^    lock$/ { n_take_lock++; next }
intake && /^    unlock$/ { n_take_unlock++; next }
input && /^    lock$/ { n_put_lock++; next }
input && /^    unlock$/ { n_put_unlock++; next }'
NOW_LOCK_HOOK='intake && /^    lock$/ { n_take_lock++ }
intake && /^    unlock$/ { n_take_unlock++ }
input && /^    lock$/ { n_put_lock++ }
input && /^    unlock$/ { n_put_unlock++ }'
NOW_SHIFT_BUG='/^  private def shift_item : T$/ { inshift = 1; n_method++ }
inshift && /^    @count = @count - 1$/ { print "    seen_count = @count"; print "    IyiScheduler.force_now_hold(pointerof(@guard).address)"; print "    @count = seen_count - 1"; print "    IyiScheduler.force_now_stored(pointerof(@guard).address)"; n_shift++; inshift = 0; next }'
NOW_SHIFT_HOOK='/^  private def shift_item : T$/ { inshift = 1; n_method++ }
inshift && /^    @count = @count - 1$/ { print "    IyiScheduler.force_now_hold(pointerof(@guard).address)"; print; print "    IyiScheduler.force_now_stored(pointerof(@guard).address)"; n_shift++; inshift = 0; next }'
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
  print "    if Pointer(Atomic(UInt64)).new(target).value.get != 0_u64"
  print "      Pointer(Atomic(UInt64)).new(pointerof(@@now_blocked).address).value.set(1_u64)"
  print "    end"
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
  print "      raise \"now: copy hook waited for the second take\" if __iyi_monotonic_ns - started > 10000000000_i64"
  print "    end"
  print "  end"
  print "  def self.force_now_stored(target : UInt64) : Nil"
  print "    return unless target == Pointer(Atomic(UInt64)).new(pointerof(@@now_target).address).value.get"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@now_stored).address).value.set(1_u64)"
  print "  end"
  print
  n_defs++
  next
}'
NOW_END='END { if (n_take != 1 || n_put != 1 || n_attempt != 1 || n_take_lock != 1 || n_take_unlock != 1 || n_put_lock != 1 || n_put_unlock != 1 || n_method != 1 || n_shift != 1 || n_defs != 1) exit 3 }'
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
insus && /^    if fiber.cancelled && fiber.claim\(nonce\)$/ { print "    if false"; print "      force_window_decision(fiber, 1_u64)"; n_decision++; next }
insus && /^    reschedule$/ { print "    force_window_decision(fiber, 2_u64)"; print; insus = 0; n_fall++; next }'
CANCEL_SUSPEND_HOOK='/^  def self.suspend\(fiber : IyiFiber, nonce : UInt64\) : Nil$/ { insus = 1; n_suspend++ }
insus && /^    if fiber.cancelled && fiber.claim\(nonce\)$/ { print; print "      force_window_decision(fiber, 1_u64)"; n_decision++; next }
insus && /^    reschedule$/ { print "    force_window_decision(fiber, 2_u64)"; print; insus = 0; n_fall++; next }'
CANCEL_PARK='/^  def self.park\(fiber : IyiFiber\) : UInt64$/ { inpark = 1; n_park++ }
inpark && /^    fiber.wait_for_wake\(nonce\)$/ { print "    IyiScheduler.force_window_hold(fiber)"; print; inpark = 0; n_hold++; next }'
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
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_window_release).address).value.set(1_u64)"
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
  print "      raise \"lostcancel: copy hook waited for release\" if __iyi_monotonic_ns - started > 10000000000_i64"
  print "    end"
  print "  end"
  print
  n_defs++
  next
}'
CANCEL_END='END { if (n_suspend != 1 || n_decision != 1 || n_fall != 1 || n_park != 1 || n_hold != 1 || n_defs != 1) exit 3 }'
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

step "failure proof: a cross-thread wake that does not ring is a lost wakeup"
broken lostwake "$WAKE_BUG" concurrency.iyi parallel_exercise -Dlostwake_force
verdict_caught lostwake 'home: the targeted idle root was posted but not rung' home --watch=5000
broken lostwake_hook "$WAKE_HOOK" concurrency.iyi parallel_exercise -Dlostwake_force
verdict_held lostwake_hook 'home: a task finished on a worker and woke the main thread it was joined by' home --watch=5000

step "failure proof: a steal that leaves the task in its victim's queue hands it out twice"
broken duplicate '/^  private def self.steal_unstarted\(st : IyiSchedulerState\) : IyiFiber\?$/ { inside = 1; n_method++ }
inside && /^          victim.pool_head = fiber.next_run$/ { n_head++; next }
inside && /^          victim.pool_tail = nil if victim.pool_head.is_a\?\(Nil\)$/ { n_tail++; next }
inside && /^  end$/ { inside = 0 }
{ print }
END { if (n_method != 1 || n_head != 1 || n_tail != 1) exit 3 }'
caught_line duplicate 'iyi: panic: the pool handed one parallel task to a worker twice: two threads would run one stack' steal

step "failure proof: a cancel never delivered to a sleeping task's thread"
# The sleeper is registered on another worker before the program arms its
# identity. Both copies observe the same post_cancel; the mutant returns
# before posting, and the control records the completed post.
POST_COMMON='/^  def self.post_cancel\(home : IyiSchedulerState, fiber : IyiFiber\) : Nil$/ { inpost = 1; n_method++ }
inpost && /^    home.post_mail$/ { print; print "    force_post_done(fiber)"; n_post++; inpost = 0; next }'
POST_BUG='inpost && /^    return if fiber.cancel_posted$/ { print "    force_post_missing(fiber)"; print "    return"; n_guard++; next }'
POST_HOOK='inpost && /^    return if fiber.cancel_posted$/ { n_guard++ }'
POST_DEFS='/^  def self.reschedule : Nil$/ {
  print "  @[UnsafeReach(\"copy-only target fiber, accessed atomically\")]"
  print "  @@forced_post_target : UInt64 = 0_u64"
  print "  def self.force_post_target(fiber : IyiFiber) : Nil"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_post_target).address).value.set(fiber.object_id)"
  print "  end"
  print "  def self.force_post_missing(fiber : IyiFiber) : Nil"
  print "    return unless fiber.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_post_target).address).value.get"
  print "    puts \"FAIL: cancel: the registered target was not posted to its worker\""
  print "    __iyi_exit(1)"
  print "  end"
  print "  def self.force_post_done(fiber : IyiFiber) : Nil"
  print "    return unless fiber.object_id == Pointer(Atomic(UInt64)).new(pointerof(@@forced_post_target).address).value.get"
  print "    puts \"cancel: the registered target was posted to its worker\""
  print "  end"
  print
  n_defs++
  next
}'
POST_END='END { if (n_method != 1 || n_post != 1 || n_guard != 1 || n_defs != 1) exit 3 }'
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

step "failure proof: a cancel that leaves an io wait parked keeps a panicking program running"
# A target reader arms itself before reading. Both copies acknowledge its
# registration and its cancel_wait branch; only the mutant omits that branch.
PARKED_COMMON='/^  def self.park_overlapped_current\(/ { inover = 1; n_over++ }
inover && /^    fiber.list_on\(st.object_id\) if @@shared && fiber.unit.is_a\?\(IyiUnit\)$/ { print; print "    force_io_registered(fiber)"; inover = 0; n_reg_over++; next }
/^  def self.wait_posix\(/ { inposix = 1; n_posix++ }
inposix && /^    fiber.list_on\(st.object_id\) if moving$/ { print; print "    force_io_registered(fiber)"; inposix = 0; n_reg_posix++; next }
/^  def self.cancel_wait\(fiber : IyiFiber\) : Nil$/ { incancel = 1; n_cancel++ }
incancel && /^    elsif fiber.state == IyiFiberState::WaitingCh$/ { print "      force_io_decision(fiber, true)"; print; n_taken++; next }
incancel && /^  end$/ { print "    force_io_decision(fiber, false)"; print; incancel = 0; n_end++; next }'
PARKED_BUG='incancel && /^    elsif fiber.state == IyiFiberState::WaitingIo$/ { print "    elsif false"; n_branch++; next }'
PARKED_HOOK='incancel && /^    elsif fiber.state == IyiFiberState::WaitingIo$/ { n_branch++ }'
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
  print "      puts \"FAIL: task-panic: target cancellation preceded io registration\""
  print "      __iyi_exit(1)"
  print "    end"
  print "    return unless fiber.cancelled"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_io_decided).address).value.set(1_u64)"
  print "    if handled"
  print "      puts \"task-panic: the registered target reached the io cancellation branch\""
  print "    elsif fiber.state == IyiFiberState::WaitingIo"
  print "      puts \"FAIL: task-panic: the registered target missed the io cancellation branch\""
  print "      __iyi_exit(1)"
  print "    end"
  print "  end"
  print
  n_defs++
  next
}'
PARKED_END='END { if (n_over != 1 || n_reg_over != 1 || n_posix != 1 || n_reg_posix != 1 || n_cancel != 1 || n_taken != 1 || n_end != 1 || n_branch != 1 || n_defs != 1) exit 3 }'
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
  if [ "$code" -ne 1 ] || grep -q '^FAIL: ' parkedio_hook.txt \
    || ! grep -qxF 'task-panic: the registered target reached the io cancellation branch' parkedio_hook.txt \
    || ! grep -qxF "iyi: panic: a task's panic, with tasks parked on the poller" parkedio_hook.txt \
    || ! grep -qxF "iyi: panic: a task panicked: a task's panic, with tasks parked on the poller" parkedio_hook.txt \
    || ! grep -qxE 'task-panic: every task ended [0-9]+ ms after the start' parkedio_hook.txt; then
    echo "parkedio hook control did not reach its io decision and original panic (exit $code):"; tail -20 parkedio_hook.txt; exit 1
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
broken unhanded '/^      head.handed = true$/ { n++; next } { print } END { if (n != 1) exit 3 }'
verdict_caught unhanded 'wakes, selects: a value handed to a parked select was not received' wakes --only=handed --watch=5000
broken lostcancel "$CANCEL_BUG" concurrency.iyi parallel_exercise -Dlostcancel_force
verdict_caught lostcancel 'wakes, cancels: the targeted suspend omitted the cancelled claim' wakes --only=cancels --watch=5000
broken lostcancel_hook "$CANCEL_HOOK" concurrency.iyi parallel_exercise -Dlostcancel_force
verdict_held lostcancel_hook 'wakes, cancels: the targeted suspend claimed its cancellation' wakes --only=cancels --watch=5000
  # The same word-keyed hook holds the first park at its word check in both
  # copies. A locked check waits for the wake to attempt the lock; an
  # unlocked check waits for the wake to finish before linking the waiter.
  LOSTWORD_COMMON='/^  def self.park_on\(/ { inpark = 1; inlink = 1; n_park++ }
inlink && /^  end$/ { inlink = 0 }
inlink && /^    tails\[bucket\] = waiter$/ { print; print "    force_lost_link(word)"; n_link++; next }
/^  def self.wake_on\(/ { inwake = 1; n_wake++ }
inwake && /^    IyiChanLock.lock\(lock\)$/ { print "    force_lost_attempt(word)"; n_attempt++ }
inwake && /^    IyiChanLock.unlock\(lock\)$/ { print "    force_lost_scanned(word, woken)"; print; print "    force_lost_done(word)"; n_done++; inwake = 0; next }'
  LOSTWORD_BUG='inpark && /^    IyiChanLock.lock\(lock\)$/ { n_lock++; next }
inpark && /^      IyiChanLock.unlock\(lock\)$/ { n_unlock++; next }
inpark && /^    end$/ { print; print "    force_lost_window(word, lock)"; print "    IyiChanLock.lock(lock)"; n_window++; n_insert++; inpark = 0; next }'
  LOSTWORD_CONTROL='inpark && /^    IyiChanLock.lock\(lock\)$/ { n_lock++ }
inpark && /^      IyiChanLock.unlock\(lock\)$/ { n_unlock++ }
inpark && /^    end$/ { print; print "    force_lost_window(word, lock)"; n_window++; n_insert++; inpark = 0; next }'
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
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_attempted).address).value.set(1_u64)"
  print "  end"
  print "  def self.force_lost_done(word : Pointer(Atomic(UInt64))) : Nil"
  print "    return unless word.address == Pointer(Atomic(UInt64)).new(pointerof(@@forced_word).address).value.get"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_woke).address).value.set(1_u64)"
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
  print "      raise \"lostword: copy hook waited for its wake\" if __iyi_monotonic_ns - started > 10000000000_i64"
  print "    end"
  print "  end"
  n_defs++
  next
}'
  LOSTWORD_END='END { if (n_park != 1 || n_window != 1 || n_wake != 1 || n_attempt != 1 || n_done != 1 || n_link != 1 || n_lock != 1 || n_unlock != 1 || n_insert != 1 || n_defs != 1) exit 3 }'
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

step "failure proof: a plain add loses counts when two tasks add at once"
# The plain add is a load and a store. race_forced puts one task's add between
# another's load and its store, so the build without atomic adds loses a count
# on its one run; the atomic build keeps both (step 1 runs race_forced there).
if ! "$IYI" build --release -Dparallel_plain_add "$REPO/bench/parallel_exercise.iyi" -o plainadd-run > build-plainadd.log 2>&1; then
  echo "the plain-add build failed:"; tail -20 build-plainadd.log; exit 1
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
awk "$TLS_AUDIT" "$REPO/bench/parallel_migrate.iyi" || { echo "TLS mutant or control anchor missing or duplicated"; exit 1; }
step "failure proof: a thread-local read before a park and kept after it names the thread the task left"
  if ! "$IYI" build --release -Dparallel_stale_tls "$REPO/bench/parallel_migrate.iyi" -o staletls-run > build-staletls.log 2>&1; then
    echo "the stale thread-local build failed:"; tail -20 build-staletls.log; exit 1
  fi
  verdict_caught staletls "channels: a thread-local read after a park named another thread than the one the task resumed on" channels
  if ! "$IYI" build --release "$REPO/bench/parallel_migrate.iyi" -o staletls_hook-run > build-staletls-control.log 2>&1; then
    echo "the healthy control build failed:"; tail -20 build-staletls-control.log; exit 1
  fi
  verdict_held staletls_hook "channels: the forced task moved to another worker and its thread-local read named that worker" channels

  step "failure proof: a thread-local read hoisted out of a loop names the thread the task left once the back-edge check moves it"
  if ! "$IYI" build --release -Dparallel_hoisted_tls "$REPO/bench/parallel_migrate.iyi" -o hoistedtls-run > build-hoistedtls.log 2>&1; then
    echo "the hoisted thread-local build failed:"; tail -20 build-hoistedtls.log; exit 1
  fi
  verdict_caught hoistedtls "loops: a thread-local read after a loop's back-edge check named another thread than the one the task was on" loops
  if ! "$IYI" build --release "$REPO/bench/parallel_migrate.iyi" -o hoistedtls_hook-run > build-hoistedtls-control.log 2>&1; then
    echo "the healthy control build failed:"; tail -20 build-hoistedtls-control.log; exit 1
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
in_walker && /^          while fiber\.is_a\?\(IyiFiber\)$/ { print; print "            force_note_seen(fiber)"; n_seen++; next }
in_walker && /^            if fiber\.state != IyiFiberState::Running && fiber\.state != IyiFiberState::Done && fiber\.saved_sp != 0$/ { n_guard++ }
in_walker && /^              scan_range\(fiber\.saved_sp, top, visit\)$/ { print "              force_note_scanned(fiber)"; print; n_scan++; next }'
  INTRANSIT_HOOK="$INTRANSIT_DEFS
{ print }
END { if (n_defs != 1 || n_seen != 1 || n_scan != 1 || n_guard != 1) exit 3 }"
  INTRANSIT_BUG="$INTRANSIT_DEFS
in_walker && /^            if fiber\.state != IyiFiberState::Running && fiber\.state != IyiFiberState::Done && fiber\.saved_sp != 0\$/ { print \"            if fiber.state != IyiFiberState::Running && fiber.state != IyiFiberState::Runnable && fiber.state != IyiFiberState::Done && fiber.saved_sp != 0\"; n_skip++; next }
{ print }
END { if (n_defs != 1 || n_seen != 1 || n_scan != 1 || n_guard != 1 || n_skip != 1) exit 3 }"
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
  n_defs++
  next
}"
  UNLIST_HOOK_RULE="$UNLIST_LIST { print; print \"    force_armed\"; n_list++; next }"
  UNLIST_BUG_RULE="$UNLIST_LIST { print \"    force_armed\"; n_list++; n_mut++; next }"
  UNLIST_DISPATCH_RULE='/^    return if owner == 0_u64$/ { print; print "    force_dispatched"; n_disp++; next }'
  UNLIST_HOOK="$UNLIST_DEFS
$UNLIST_HOOK_RULE
$UNLIST_DISPATCH_RULE
{ print }
END { if (n_defs != 1 || n_list != 1 || n_disp != 1) exit 3 }"
  UNLIST_BUG="$UNLIST_DEFS
$UNLIST_BUG_RULE
$UNLIST_DISPATCH_RULE
{ print }
END { if (n_defs != 1 || n_list != 1 || n_disp != 1 || n_mut != 1) exit 3 }"
  broken unlistedio "$UNLIST_BUG" concurrency.iyi parallel_migrate -Dunlistedio_force
  verdict_caught unlistedio "cancel: a cancel found no listed owner for a reader switched out of its io wait" cancel --watch=5000
  broken unlistedio_hook "$UNLIST_HOOK" concurrency.iyi parallel_migrate -Dunlistedio_force
  verdict_held unlistedio_hook "cancel: a cancel found the listed owner of every reader switched out of its io wait, and each read answered Cancelled" cancel --watch=5000

  step "failure proof: a close posted to no thread leaves a read on another worker parked"
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
      echo "  a close on Windows ends the posted read, whose completion any thread takes off the port: there is nothing to post" ;;
    *)
      CLOSE_COMMON='/^  def self.wait_posix\(/ { inwait = 1; n_wait++ }
inwait && /^    fiber.list_on\(st.object_id\) if moving$/ { print; print "    force_close_registered(fd)"; inwait = 0; n_reg++; next }
/^  def self.wake_closed\(fd : Int32\) : Nil$/ { inclose = 1; n_close++ }
inclose && /^          other.post_mail$/ { print; print "          force_close_posted(fd)"; inclose = 0; n_post++; next }'
      CLOSE_BUG='inclose && /^      return unless @@shared$/ { print "      force_close_missing(fd)"; print "      return"; n_guard++; next }'
      CLOSE_HOOK='inclose && /^      return unless @@shared$/ { n_guard++ }'
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
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_close_registered).address).value.set(1_u64)"
  print "  end"
  print "  def self.force_close_registered? : Bool"
  print "    Pointer(Atomic(UInt64)).new(pointerof(@@forced_close_registered).address).value.get == 1_u64"
  print "  end"
  print "  def self.force_close_missing(fd : Int32) : Nil"
  print "    return unless fd.to_u64 + 1_u64 == Pointer(Atomic(UInt64)).new(pointerof(@@forced_close_fd).address).value.get"
  print "    unless force_close_registered?"
  print "      puts \"FAIL: closes: the target was closed before io registration\""
  print "      __iyi_exit(1)"
  print "    end"
  print "    puts \"FAIL: closes: the registered target close was not posted to its reader\""
  print "    __iyi_exit(1)"
  print "  end"
  print "  def self.force_close_posted(fd : Int32) : Nil"
  print "    return unless fd.to_u64 + 1_u64 == Pointer(Atomic(UInt64)).new(pointerof(@@forced_close_fd).address).value.get"
  print "    puts \"closes: the registered target close was posted to its reader\""
  print "  end"
  print
  n_defs++
  next
}'
      CLOSE_END='END { if (n_wait != 1 || n_reg != 1 || n_close != 1 || n_post != 1 || n_guard != 1 || n_defs != 1) exit 3 }'
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
      verdict_held noclose_hook 'closes: the registered target close was posted to its reader' closes --watch=5000 ;;
  esac

  step "failure proof: a read made on the thread that closes its socket is a close that never crossed"
  if ! "$IYI" build --release -Dparallel_closes_home "$REPO/bench/parallel_migrate.iyi" -o closeshome-run > build-closeshome.log 2>&1; then
    echo "the closes-home build failed:"; tail -20 build-closeshome.log; exit 1
  fi
  verdict_caught closeshome 'closes: the main thread closed a socket on the thread its reader parked on' closes

  step "failure proof: a join held in the kernel holds its worker, and the sleepers on it"
  broken kerneljoin '/^      while @ended.get == 0_u64$/ { skip = 3; n++ } skip > 0 { skip = skip - 1; next } { print } END { if (n != 1) exit 3 }' thread.iyi parallel_migrate
  verdict_caught kerneljoin "join: the child's measured wake was outside the allowed range" join

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
  print "    force_handoff_decide(fiber, handed_on?(st, fiber) ? 5_u64 : 4_u64)"
  print "  end"
  print; inpush = 1; n_defs++; next
}
inpush && /^    if st.ring_size > 1_u64$/ { print; print "      force_handoff_decide(fiber, 1_u64)"; n_ring++; next }
inpush && /^      skip = st.handoff_skip$/ { print; print "      force_handoff_decide(fiber, skip == 0_u64 ? 2_u64 : 3_u64)"; n_skip++; next }
inpush && /^  end$/ { print "    force_handoff_done(st, fiber)"; print; inpush = 0; n_end++; next }'
  NOHAND_BUG='inpush && /^    elsif handed_on\?\(st, fiber\)$/ { print "    elsif false"; n_mut++; next }'
  NOHAND_HOOK='inpush && /^    elsif handed_on\?\(st, fiber\)$/ { n_mut++ }'
  NOHAND_END='END { if (n_defs != 1 || n_ring != 1 || n_skip != 1 || n_end != 1 || n_mut != 1) exit 3 }'
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
  n_defs++
  next
}
/^  def self.wake_one : Nil$/ { print; print "    force_wake_hook"; n_wake++; next }
/^        st.handoff_last = fiber.object_id$/ { print "        force_branch(fiber.object_id, st.object_id)"; print; n_hand++; expect = 1; next }'
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
  print "      raise \"backstop: progress hang: the grab gate did not open in 10000 ms\" if __iyi_monotonic_ns > limit"
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
  n_defs++
  next
}'
  NOBACK_COMMON='/^            stuck = true if st.ring_size > 0_u64$/ { print "            if force_held?(st.object_id)"; print "              stuck = true if force_ring(st)"; print "            else"; print; print "            end"; n_ring++; next }
/^        st.handoff_skip = skip &- 1_u64$/ { print "        force_skip(st.object_id, fiber.object_id)"; print; n_skip++; next }
/^        fiber = grab\(victim, st\)$/ { print "        fiber = force_grab(victim, st)"; n_grab++; next }
/^      return true if listed_at\(index\)\.ring_size > 0_u64$/ { print "      return true if listed_at(index).ring_size > 0_u64 && !force_held?(listed_at(index).object_id)"; n_wait++; next }'
  NOBACK_HOOK_LOOK='/^    wake_one if stuck$/ { print; print "    force_look_end(stuck)"; n_look++; next }'
  NOBACK_BUG_LOOK='/^    wake_one if stuck$/ { print "    force_look_end(false)"; n_look++; n_mut++; next }'
  NOBACK_HOOK="$NOBACK_DEFS
$NOBACK_COMMON
$NOBACK_HOOK_LOOK
{ print }
END { if (n_defs != 1 || n_ring != 1 || n_skip != 1 || n_grab != 1 || n_wait != 1 || n_look != 1) exit 3 }"
  NOBACK_BUG="$NOBACK_DEFS
$NOBACK_COMMON
$NOBACK_BUG_LOOK
{ print }
END { if (n_defs != 1 || n_ring != 1 || n_skip != 1 || n_grab != 1 || n_wait != 1 || n_look != 1 || n_mut != 1) exit 3 }"
  broken nobackstop "$NOBACK_BUG" concurrency.iyi parallel_migrate -Dnobackstop_force
  verdict_caught nobackstop "backstop: the monitor's stuck decision for a held ring omitted its wake_one call" backstop
  broken nobackstop_hook "$NOBACK_HOOK" concurrency.iyi parallel_migrate -Dnobackstop_force
  verdict_held nobackstop_hook "backstop: the monitor's stuck decision for a held ring called wake_one" backstop

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
  n_defs++
  next
}'
      NOHELD_LOOK_END='/^    wake_one if stuck$/ { print; print "    force_look_end(stuck)"; n_look++; next }'
      NOHELD_HOOK_DECIDE='/^          stuck = true if held_io\?\(st\)$/ { print "          io_held = held_io?(st)"; print "          force_io_decision(st.object_id, io_held)"; print "          stuck = true if io_held"; n_dec++; next }'
      NOHELD_BUG_DECIDE='/^          stuck = true if held_io\?\(st\)$/ { print "          io_held = held_io?(st)"; print "          force_io_decision(st.object_id, io_held)"; n_dec++; n_mut++; next }'
      NOHELD_HOOK="$NOHELD_DEFS
$NOHELD_HOOK_DECIDE
$NOHELD_LOOK_END
{ print }
END { if (n_defs != 1 || n_dec != 1 || n_look != 1) exit 3 }"
      NOHELD_BUG="$NOHELD_DEFS
$NOHELD_BUG_DECIDE
$NOHELD_LOOK_END
{ print }
END { if (n_defs != 1 || n_dec != 1 || n_look != 1 || n_mut != 1) exit 3 }"
      broken noheldio "$NOHELD_BUG" concurrency.iyi parallel_migrate -Dnoheldio_force
      verdict_caught noheldio "heldio: the monitor's held-io decision for a reader's poller omitted the wake that rings an idle worker" heldio
      broken noheldio_hook "$NOHELD_HOOK" concurrency.iyi parallel_migrate -Dnoheldio_force
      verdict_held noheldio_hook "heldio: the answer sent to a reader parked on a held worker was read on another worker before the hold ended" heldio
      ;;
  esac

  need_cores 4 "the balance step is timed against four workers' ideal, so the stealing proofs need four cores"
    # Both without preemption: a preempted task waits in a queue any worker
    # takes from, which spreads the parked tasks as a steal would, and a
    # pool that never steals took 1.88x the ideal with it on.
    NOPREEMPT='/^            Pointer\(Atomic\(UInt64\)\).new\(address\).value.set\(1_u64\) if address != 0_u64$/ { n_pre++; next } '
    step "failure proof: a pool that never steals a started task leaves tasks woken on one worker there"
    broken nosteal "$NOPREEMPT"'/^  def self.grab\(victim : IyiSchedulerState, thief : IyiSchedulerState\) : IyiFiber\?$/ { print; print "    return nil"; n_grab++; next } { print } END { if (n_pre != 1 || n_grab != 1) exit 3 }' concurrency.iyi parallel_migrate
    verdict_caught nosteal 'balance: tasks woken from a worker exceeded the balance bound' balance

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
in_ready && /^          IyiWorkers\.push_shared\(fiber\)$/ { print "          force_pin_note(fiber, 1_u64)"; print; n_shared++; next }
in_ready && /^    send_home\(home, fiber\)$/ { print "    force_pin_note(fiber, home.object_id)"; print; n_home++; next }'
    PIN_HOOK="$PIN_DEFS"'
/^  private def self.look : Bool$/ { in_look = 1; n_look++ }
in_look && /^  end$/ { in_look = 0 }
in_look && /^            Pointer\(Atomic\(UInt64\)\).new\(address\).value.set\(1_u64\) if address != 0_u64$/ { n_pre++ }
in_ready && /^      if fiber.unit.is_a\?\(IyiUnit\) && !fiber.homebound$/ { n_ready++ }
/^  def self.grab\(victim : IyiSchedulerState, thief : IyiSchedulerState\) : IyiFiber\?$/ { n_grab++ }
{ print }
END { if (n_defs != 1 || n_shared != 1 || n_home != 1 || n_look != 1 || n_pre != 1 || n_ready != 1 || n_grab != 1) exit 3 }'
    PIN_BUG="$PIN_DEFS"'
/^  private def self.look : Bool$/ { in_look = 1; n_look++ }
in_look && /^  end$/ { in_look = 0 }
in_look && /^            Pointer\(Atomic\(UInt64\)\).new\(address\).value.set\(1_u64\) if address != 0_u64$/ { n_pre++; next }
in_ready && /^      if fiber.unit.is_a\?\(IyiUnit\) && !fiber.homebound$/ { print "      if false"; n_ready++; next }
/^  def self.grab\(victim : IyiSchedulerState, thief : IyiSchedulerState\) : IyiFiber\?$/ { print; print "    return nil"; n_grab++; next }
{ print }
END { if (n_defs != 1 || n_shared != 1 || n_home != 1 || n_look != 1 || n_pre != 1 || n_ready != 1 || n_grab != 1) exit 3 }'
    broken pinned "$PIN_BUG" concurrency.iyi parallel_migrate -Dpinned_force
    verdict_caught pinned "balance: a task woken from the main thread was sent back to the worker it parked on" balance
    broken pinned_hook "$PIN_HOOK" concurrency.iyi parallel_migrate -Dpinned_force
    verdict_held pinned_hook "balance: a task woken from the main thread was queued for the pool and resumed on a spare while the worker it parked on was held" balance

step "failure proof: a loop marked @[NoPreempt] holds its worker for its whole computation"
if ! "$IYI" build --release -Dpreempt_off "$REPO/bench/parallel_preempt.iyi" -o preemptoff-run > build-preemptoff.log 2>&1; then
  echo "the @[NoPreempt] build failed:"; tail -20 build-preemptoff.log; exit 1
fi
verdict_caught preemptoff 'slice: the short task exceeded the wait bound' slice --workers=1

step "failure proof: a monitor that never raises a worker's word preempts nothing"
broken noflag '/^            Pointer\(Atomic\(UInt64\)\).new\(address\).value.set\(1_u64\) if address != 0_u64$/ { next } { print }' concurrency.iyi parallel_preempt
verdict_caught noflag 'slice: the short task exceeded the wait bound' slice --workers=1

# On Windows, observe which wait the active monitor actually completed.
# Elapsed cadence remains in the healthy benchmark, not this verdict.
# Windows probe 44682358165: both exact verdicts held 20 of 20.
step "failure proof: a Windows monitor using the semaphore fallback for an active tick"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    COARSE_COMMON='/^  private def self.monitor_wait\(parked : Bool\) : Nil$/ { inwait = 1; n_wait++ }
inwait && /^          LibC.WaitForSingleObject\(timer, -1_i32\)$/ { print; print "          force_tick_record(1_u64)"; n_timer_wait++; next }
inwait && /^      LibC.WaitForSingleObject\(Pointer\(Void\).new\(@@monitor_handle\), parked \? -1_i32 : PREEMPT_TICK_MS\)$/ { print; print "      force_tick_record(2_u64) unless parked"; inwait = 0; n_fallback++; next }
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
  print "    stored.value.set(result) if stored.value.get == 0_u64"
  print "  end"
  print
  n_defs++
  next
}'
    COARSE_BUG='/^        @@monitor_timer = timer.address$/ { print "        @@monitor_timer = 0_u64"; n_assignment++; next }'
    COARSE_HOOK='/^        @@monitor_timer = timer.address$/ { n_assignment++ }'
    COARSE_END='END { if (n_wait != 1 || n_timer_wait != 1 || n_fallback != 1 || n_defs != 1 || n_assignment != 1) exit 3 }'
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

# The turn is held to three of the period step's own looks. This copy
# took 3.45 to 4.35 looks a turn in 16 runs on macos-15 and 3.84 to 4.02
# in 20 on windows-2025 (debug jobs 124913849625 and 124922160678,
# 124913849506 and 124922160886), 3.88 to 4.21 in three here on Linux,
# and 4.02 and 3.96 on Windows 11, 12 logical processors (the user's
# machine), held to 4; the real monitor's turns took 1.61 to 2.25 looks
# in those debug jobs.
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
  SLOW_TICKS='/^  PREEMPT_TICKS   =       1_u64$/ { print "  PREEMPT_TICKS   =       3_u64"; n_ticks++; next }'
  SLOW_SAVE='/^            ticks = 0_u64$/ { print "            force_pending_ticks(ticks)"; print; n_save++; next }'
  SLOW_STORE='/^            Pointer\(Atomic\(UInt64\)\).new\(address\).value.set\(1_u64\) if address != 0_u64$/ { print; print "            force_raise if address != 0_u64"; n_store++; next }'
  SLOW_HOOK="$SLOW_DEFS
$SLOW_SAVE
$SLOW_STORE
{ print }
END { if (n_defs != 1 || n_save != 1 || n_store != 1) exit 3 }"
  SLOW_BUG="$SLOW_DEFS
$SLOW_TICKS
$SLOW_SAVE
$SLOW_STORE
{ print }
END { if (n_defs != 1 || n_ticks != 1 || n_save != 1 || n_store != 1) exit 3 }"
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
  echo "  the check on Linux never calls the accessor: the copy builds the same code, so there is nothing to fail"
else
  if ! "$IYI" build --release --emit llvm-ir -Dpreempt_check_accessor "$REPO/bench/parallel_preempt.iyi" -o accessor-run > build-accessor.log 2>&1; then
    echo "the accessor build failed:"; tail -20 build-accessor.log; exit 1
  fi
  if tight_checks accessor-run.ll > accessor.txt 2>&1; then
    echo "the broken copy accessor was not caught by the tight loops' checks:"; cat accessor.txt; exit 1
  fi
  if ! grep -q '^FAIL: tight checks: .* call the thread-local accessor' accessor.txt; then
    echo "the tight loops' checks failed the accessor copy some other way:"; cat accessor.txt; exit 1
  fi
  sed '/^FAIL: /d; s/^/  /' accessor.txt
  echo "  exits 1 at \"$(grep -m1 '^FAIL: ' accessor.txt | sed 's/^FAIL: //')\""
fi

step "failure proof: a slow half that does not poll leaves a connection in a busy worker's poller"
# Caught by the poller step, whose window is held: the server shape's
# copy waited only when a connection happened to park on a worker a slow
# request then took, and passed three of eight runs under its 80 ms bound,
# at 76 to 78 ms, on macOS 26.6, Apple M2 Pro, 10 cores (the user's
# machine). Windows' port is the process's, and in the server shape an
# idle worker takes what the busy one's poll would have; the poller
# step's pool of one has no idle worker, so only the poll hands the
# answer on. On Windows 11, 12 logical processors (the user's machine),
# the copy answered at 999 to 1001 ms in ten runs of ten, where the
# gate's own poller step read 7.0 to 9.1 ms in six.
broken nopoll '/^        IyiScheduler.wait_for_events\(false\)$/ { print "        IyiScheduler.wake_expired_sleepers"; next } { print }' concurrency.iyi parallel_preempt
verdict_caught nopoll 'poller: the fast request exceeded the wait bound' poller --workers=1

step "failure proof: a word the monitor raised for the task before preempts the task switched in after it"
# The switch lowers the word no more: the task the fresh step switches
# in after a 30 ms hold with no check gives its worker up at its first
# back-edge, round 1 of 10. Master's runtime did so 0 to 1 us into the
# task in three runs of three on Windows 11, 12 logical processors (the
# user's machine), and 0 us in three of three on Linux here (12 vCPUs);
# the lowered word ran 10 rounds of 10 through with no preemption on
# both, plain and on Windows release too. In this gate's first runs the
# copy was caught at round 1, 0 us in, on that Windows machine at 12
# processors and held to 4, on Linux here and on macOS 26.6, Apple M2
# Pro, 10 cores (the user's machine), and the fresh step held 10 rounds
# with no preemption, plain and release, on each.
# The step now judges each round from the task before's end to the end
# of the slice the give-up came in (`fresh_round`), and the copy was
# caught at round 1 within 55 to 3075 us of that end on Linux (8 runs, 16
# to 48 threads runnable), 64 us in a gate run beside 12 busy loops, and
# 34 to 50 us on tmac.
broken stale '/^        raised.value.set\(0_u64\) if raised.value.get != 0_u64$/ { next } { print }' concurrency.iyi parallel_preempt
verdict_caught stale "fresh: a switched-in task yielded before the monitor's floor" fresh --workers=1

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
    broken boosted '/^        LibC\.SetProcessPriorityBoost\(LibC\.GetCurrentProcess, 1_i32\)$/ { next } { print }' concurrency.iyi completions_taken
    verdict_caught boosted "boost: the process's priority boost is on with the pool started" boost --workers=12 ;;
  *)
    echo "  Windows' alone: the boost is its scheduler's" ;;
esac

step "failure proof: a preempted task that gives its unit's token away lets its child run inside it"
broken tokenless '/^      return unless unit.hand_to_yielded\(id\)$/ { print "      unit.give"; next } { print }' concurrency.iyi parallel_preempt
verdict_caught tokenless 'unit: a task of the same unit ran inside the preempted task' unit --workers=1

step "failure proof: the prelude's library compiled as the runtime's holds its worker through a sort, a copy, a growth and a join"
# `array.iyi`, `hash.iyi` and `string.iyi` written into prelude.iyi where it
# requires them, so the compiler takes their defs for the runtime's, which
# never check. Their own `@[Unsafe]` marks are left out: prelude.iyi's, at
# its top, covers what they handle. A plain build, whose copy is a loop of
# bytes and long enough to tell.
broken libruntime '/^require "\.\/(array|hash|string)"$/ {
  name = $2; gsub(/"|\.\//, "", name); count[name]++
  file = "'"$REPO"'/src/iyi/" name ".iyi"
  read_any = 0
  while ((status = getline line < file) > 0) { read_any = 1; if (line !~ /^@\[Unsafe\(/) print line }
  if (status < 0 || !read_any) exit 3
  close(file); next
}
{ print }
END { if (count["array"] != 1 || count["hash"] != 1 || count["string"] != 1) exit 3 }' prelude.iyi parallel_preempt_lib -Dpreempt_timing_proof
for proof in sort copy rehash join; do
  verdict_caught libruntime "$proof: the short task exceeded the wait bound" "$proof" --workers=1
done

# The two halves of `copy_checks`, broken: `Pointer#copy_from` with no way
# around its loop of runs, as it was, and darwin's anchor in the entry
# block (`-Dpreempt_anchor_entry`), which only darwin's makes by a call.
step "failure proof: a copy whose every run goes through the loop of runs checks however short it is"
mkdir -p copyruns/iyi
cp "$REPO"/src/iyi/*.iyi copyruns/iyi/
awk '/^    return copy_run\(source, count\) if count <= 1048576$/ { next } { print }' \
  "$REPO/src/iyi/string.iyi" > copyruns/iyi/string.iyi
cmp -s copyruns/iyi/string.iyi "$REPO/src/iyi/string.iyi" && { echo "the awk for copyruns found nothing to change"; exit 1; }
if ! IYI_PATH="$WORK/copyruns${PSEP}$REPO/src" "$IYI" build --release --emit llvm-ir "$REPO/bench/parallel_preempt_lib.iyi" -o copyruns-run > build-copyruns.log 2>&1; then
  echo "the copyruns copy failed to build:"; tail -20 build-copyruns.log; exit 1
fi
if copy_checks copyruns-run.ll > copyruns.txt 2>&1; then
  echo "the broken copy copyruns was not caught by the short-copy checks:"; cat copyruns.txt; exit 1
fi
grep -q '^FAIL: copy checks: every copy' copyruns.txt || { echo "the short-copy checks failed copyruns some other way:"; cat copyruns.txt; exit 1; }
echo "  exits 1 at \"$(grep -m1 '^FAIL: ' copyruns.txt | sed 's/^FAIL: //')\""

step "failure proof: darwin's anchor in the entry block calls the accessor at every copy"
if [ "$(uname -s)" != Darwin ]; then
  echo "  the anchor here is a constant or a load and calls nothing: the copy builds the same code, so there is nothing to fail"
else
  if ! "$IYI" build --release --emit llvm-ir -Dpreempt_anchor_entry "$REPO/bench/parallel_preempt_lib.iyi" -o anchorentry-run > build-anchorentry.log 2>&1; then
    echo "the anchor-at-entry build failed:"; tail -20 build-anchorentry.log; exit 1
  fi
  if copy_checks anchorentry-run.ll > anchorentry.txt 2>&1; then
    echo "the broken copy anchorentry was not caught by the short-copy checks:"; cat anchorentry.txt; exit 1
  fi
  grep -q '^FAIL: copy checks: the entry block' anchorentry.txt || { echo "the short-copy checks failed anchorentry some other way:"; cat anchorentry.txt; exit 1; }
  echo "  exits 1 at \"$(grep -m1 '^FAIL: ' anchorentry.txt | sed 's/^FAIL: //')\""
fi

step "failure proof: a recursion marked @[NoPreempt] holds its worker for its whole computation"
if ! "$IYI" build -Dpreempt_off -Dpreempt_timing_proof "$REPO/bench/parallel_preempt_lib.iyi" -o recursionoff-run > build-recursionoff.log 2>&1; then
  echo "the @[NoPreempt] build failed:"; tail -20 build-recursionoff.log; exit 1
fi
verdict_caught recursionoff 'fib: the short task exceeded the wait bound' fib --workers=1

step "failure proof: a scheduler the compiler takes for a library's checks, and the audit names where"
[ -n "$PY" ] || { echo "no python here to read the IR with: the audit cannot run"; exit 1; }
  # `concurrency.iyi` renamed `scheduler.iyi`: the compiler's runtime is
  # the prelude's files of three names (`codegen.cr#IYI_RUNTIME_FILES`),
  # and the audit's is wherever the scheduler is written.
  mkdir -p rtout/iyi
  cp "$REPO"/src/iyi/*.iyi rtout/iyi/
  mv rtout/iyi/concurrency.iyi rtout/iyi/scheduler.iyi
  awk '/^  require "\.\/concurrency"$/ { print "  require \"./scheduler\""; next } { print }' \
    "$REPO/src/iyi/prelude.iyi" > rtout/iyi/prelude.iyi
  cmp -s rtout/iyi/prelude.iyi "$REPO/src/iyi/prelude.iyi" && { echo "the awk for rtout found nothing to change"; exit 1; }
  if ! IYI_PATH="$WORK/rtout${PSEP}$REPO/src" "$IYI" build --emit llvm-ir "$REPO/bench/parallel_preempt_lib.iyi" -o rtout-run > build-rtout.log 2>&1; then
    echo "the renamed scheduler failed to build:"; tail -20 build-rtout.log; exit 1
  fi
  if "$PY" "$REPO/bench/preempt_audit.py" rtout-run.ll > rtout.txt 2>&1; then
    echo "the audit passed a scheduler compiled with checks:"; cat rtout.txt; exit 1
  fi
  grep -q 'hold a preemption check' rtout.txt || { echo "the audit failed some other way:"; cat rtout.txt; exit 1; }
  echo "  $(head -1 rtout.txt | sed 's/^preempt audit: //'), the first of them $(sed -n 2p rtout.txt | sed 's/^ *//')"

# ── 8. Failure proof: one worker, whatever was asked for ──────────────────
# Refused at any load by the threads that held a task at once, which one
# worker holds at 1.00 at most; and where step 3 judged the time's ratio,
# by that too.
step "failure proof: a pool held to one worker fails the speedup floor"
need_cores 2 "the floor is not held on one core, so there is nothing to fail"
  mkdir -p oneworker/iyi
  cp "$REPO"/src/iyi/*.iyi oneworker/iyi/
  awk '/^      workers = resolved$/ { print "      workers = 1"; next } { print }' \
    "$REPO/src/iyi/concurrency.iyi" > oneworker/iyi/concurrency.iyi
  cmp -s oneworker/iyi/concurrency.iyi "$REPO/src/iyi/concurrency.iyi" && { echo "the awk for oneworker found nothing to change"; exit 1; }
  if ! IYI_PATH="$WORK/oneworker${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/parallel_exercise.iyi" -o oneworker-run > build-oneworker.log 2>&1; then
    echo "the one-worker copy failed to build:"; tail -20 build-oneworker.log; exit 1
  fi
  got="$(best_ms "$K" oneworker-run)" || exit 1
  SLOW="${got% *}"
  SLOW_AT="${got#* }"
  if holds_at_once "$SLOW_AT" "$K"; then
    echo "a pool of one worker asked for $K held its tasks $(at_once "$SLOW_AT") at once and passed the floor"; exit 1
  fi
  if [ -n "$SPEED_JUDGED" ] && holds_floor "$ONE" "$SLOW" "$K"; then
    echo "a pool of one worker asked for $K took $SLOW ms against $ONE ms and passed the floor"; exit 1
  fi
  echo "  asked for $K, ran on 1: $(at_once "$SLOW_AT") at once, $SLOW ms against $ONE ms, $(awk -v a="$ONE" -v b="$SLOW" 'BEGIN { printf "%.2f", a / b }')x, refused"

echo "parallel gate: every property held"
