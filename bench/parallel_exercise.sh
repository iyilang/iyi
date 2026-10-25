#!/usr/bin/env bash
# Drives bench/parallel_exercise.iyi: tasks across cores (SPEC.md III.4.13).
#
#     bash bench/parallel_exercise.sh
#
# Eight steps; the last three are failure proofs, because a gate that
# cannot fail is not a gate:
#
#   1. The exercise holds every property, plain and --release: parallel
#      tasks start on the pool and on more than one worker, never on the
#      spawning thread, a thousand run exactly once, an atomic count loses
#      nothing, channels carry values across threads once each and in each
#      sender's order, `take_now` and `put_now` from every worker at once
#      lose and repeat nothing, a cancel reaches a task asleep, parked on a
#      channel, or still waiting in the pool, a panic stops at the task's
#      boundary, idle workers steal, collections keep the workers' lists,
#      and the typed group answers.
#   2. bench/parallel_migrate.iyi holds what a task keeps when it resumes
#      on another worker, plain and --release: its stack's lists through
#      collections, thread-locals of the thread it is on, after a park and
#      after a loop's back-edge check that moved it, its socket's bytes, a
#      cancel and a sibling's close that find it, frames 120 KiB deep;
#      tasks parked on one worker finish in under twice the ideal, woken
#      from the main thread and from a worker; and a task joining a thread
#      leaves its worker to its child.
#      bench/parallel_preempt.iyi then holds preemption at loop back-edges
#      (SPEC.md III.4.13, part 9): a short task, a sleeper and a fast
#      request beside a task computing with no call in its loop wait no
#      more than 100 ms, 80 for the request; a preempted task keeps its
#      unit's token; the monitor looks every 4 to 9 ms and the quantum is
#      at most 20 ms; and a tight loop costs at most twice what its
#      `@[NoPreempt]` twin does. Its failure proofs are with step 7's: a
#      `@[NoPreempt]` loop, a monitor that never raises the word, a Windows
#      monitor on the system timer's tick, a check that calls the
#      accessor (darwin and Windows), a slow half that does not poll, and a
#      preempted task that gives its unit's token away.
#   3. The binary keeps the dependency floor the concurrency gate holds,
#      plus `environ`, the C runtime's table `IYI_WORKERS` is read from.
#   4. The speedup, measured: CPU-bound tasks on one worker and on several,
#      release build, best of three, and the ratio held to a floor of 0.6
#      per worker - a pool that is parallel only in name cannot pass it.
#      The table for 1, 2, 4 and 8 workers (as far as the cores go) is
#      printed for the record.
#   5. A deadlock across threads - a parallel task waiting on a channel
#      nobody sends on - is named, not hung.
#   6. `Share` gates the parallel block at compile time: a captured
#      `Array`, a `Channel` of arrays, a local assigned after the spawn, and
#      a loop's local are refused, each by name.
#   7. Failure proofs against broken copies of the runtime, each caught at
#      the named check: a cross-thread wake that does not ring (a lost
#      wakeup), a steal that leaves the task in its victim's queue (a task
#      handed out twice), a cancel that is never delivered to the thread a
#      sleeping task is on, a cancel that skips tasks still waiting in the
#      pool (a cancelled task run as if it were not), and `take_now` and
#      `put_now` without the scheduler's lock; the race step's add made
#      a plain load and store, which loses adds only when tasks really run
#      at the same instant; and for the moves of step 2 - a thread-local
#      read as it was before a park, one read as it was before a loop
#      whose back-edge check moved the task, a collector that skips a fiber
#      on its way between workers, an io wait a cancel cannot find, a close
#      posted to nobody, a pool that never steals a started task, tasks
#      woken back onto the worker they parked on as they were before tasks
#      moved, and a join held in the kernel.
#   8. Failure proof: the pool held to one worker whatever it was asked
#      for, and step 4's floor refuses the ratio that comes out.
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
# Its balance step is timed against four workers' ideal, which a machine
# with fewer cores than that cannot keep; there the other steps run.
MIGRATE_STEPS="channels sockets cancel closes deep loops balance join"
[ "$CORES" -lt 4 ] && MIGRATE_STEPS="channels sockets cancel closes deep loops join"
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
done
# ── 2b. Preemption at loop back-edges, twice ─────────────────────────────
# bench/parallel_preempt.iyi: a task computing with no call in its loop
# no longer holds a short task, a sleeper or a connection behind it past
# 100 ms (80 for a fast request in the server shape); a preempted task
# keeps its unit's token; the monitor looks every 4 to 9 ms and two tasks
# on one worker take turns of 20 ms at most; and the tight loops cost at
# most twice what their `@[NoPreempt]` twins cost.
PREEMPT_WORKERS=8
[ "$CORES" -lt 8 ] && PREEMPT_WORKERS="$CORES"
# The server shape's clients are the program's own main thread, which on
# Windows, by every sign, waits for a core behind workers holding all of
# them: on a 4-core GitHub runner, 4 workers made the slowest fast request 64 to 99
# ms, 760 to 897 of 11,200 over 20 ms, with the monitor's tick at 5 ms and
# at the system timer's alike, and 3 workers made it 36 to 49 ms, 119 to
# 142 over 20. darwin's 3 workers on 3 cores made it 26 to 50 ms.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    [ "$CORES" -gt 1 ] && [ "$PREEMPT_WORKERS" -ge "$CORES" ] && PREEMPT_WORKERS=$((CORES - 1)) ;;
esac
for build in plain release; do
  step "preemption at loop back-edges, $build build"
  flag=""
  [ "$build" = release ] && flag="--release"
  if ! "$IYI" build $flag "$REPO/bench/parallel_preempt.iyi" -o "preempt-$build" > "build-preempt-$build.log" 2>&1; then
    echo "build failed:"; tail -20 "build-preempt-$build.log"; exit 1
  fi
  for run in "slice --workers=1" "unit --workers=1" "period --workers=1" "server --workers=$PREEMPT_WORKERS"; do
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
#            thread and the stop, `pipe`/`read`/`write` for the stop's
#            park, and `close` for a retiring thread's kqueue
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
    runtime='___error __dyld_get_image_header __dyld_get_image_vmaddr_slide __tlv_bootstrap _backtrace _backtrace_symbols_fd _clock_gettime_nsec_np _exit _kevent _kqueue _mmap _mprotect _munmap _pthread_create _pthread_get_stackaddr_np _pthread_self _sigaction _sigaltstack _sysctlbyname _write'
    thread='_close _pipe _pthread_kill _read'
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
TASKS=16
ROUNDS=40000000
best_ms() { # workers binary
  local best="" run ms
  for run in 1 2 3; do
    ms="$(timeout -k 5 300 "./$2" speed "$1" "$TASKS" "$ROUNDS" | sed -n 's/.*wall_ms=\([0-9]*\).*/\1/p')"
    [ -n "$ms" ] || { echo "the speed run at $1 workers printed no time" >&2; return 1; }
    if [ -z "$best" ] || [ "$ms" -lt "$best" ]; then best="$ms"; fi
  done
  echo "$best"
}
# The floor: k workers must finish at least 0.6 * k times faster than one.
holds_floor() { # one_ms k_ms k
  awk -v one="$1" -v many="$2" -v k="$3" 'BEGIN { exit !(many > 0 && one / many >= 0.6 * k) }'
}
K=4
[ "$CORES" -lt "$K" ] && K="$CORES"
step "the speedup: $TASKS CPU-bound tasks, release build, best of three, $CORES cores here"
if [ "$CORES" -lt 2 ]; then
  echo "  one core here: nothing to scale onto, so the ratio is not held"
else
  ONE="$(best_ms 1 exercise-release)" || exit 1
  printf '  %2s worker(s): %6s ms\n' 1 "$ONE"
  MANY=""
  for w in 2 4 8; do
    [ "$w" -gt "$CORES" ] && break
    ms="$(best_ms "$w" exercise-release)" || exit 1
    ratio="$(awk -v a="$ONE" -v b="$ms" 'BEGIN { printf "%.2f", a / b }')"
    printf '  %2s worker(s): %6s ms, %sx one worker\n' "$w" "$ms" "$ratio"
    [ "$w" -eq "$K" ] && MANY="$ms"
  done
  [ -n "$MANY" ] || MANY="$(best_ms "$K" exercise-release)" || exit 1
  if ! holds_floor "$ONE" "$MANY" "$K"; then
    echo "$K workers took $MANY ms against one worker's $ONE ms: under 0.6 x $K, which is not parallel"
    exit 1
  fi
  echo "  $K workers: $(awk -v a="$ONE" -v b="$MANY" 'BEGIN { printf "%.2f", a / b }')x one worker, over the floor of $(awk -v k="$K" 'BEGIN { printf "%.1f", 0.6 * k }')x"
fi

# ── 4. A deadlock across threads is named ────────────────────────────────
step "a deadlock across threads is a diagnosis, not a hang"
cat > paralleldeadlock.iyi <<'IYI'
module paralleldeadlock

never = Channel(Int32).new
group do |g|
  g.spawn_parallel do
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
refused shares_array 'the block spawn_parallel runs on another thread captures `items : Array(Int32)`, which is not Share' '
items = [1, 2, 3]
group do |g|
  g.spawn_parallel { items.size }
end'
refused shares_channel_of_arrays 'captures `lists : Channel(Array(Int32))`, which is not Share' '
lists = Channel(Array(Int32)).new(1)
group do |g|
  g.spawn_parallel { lists.close }
end'
refused assigns_after '`count` is assigned here, after the task was spawned' '
def launch(g : IyiGroup) : Nil
  count = 1
  g.spawn_parallel { count + 1 }
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
    g.spawn_parallel { seed + 1 }
    i = i + 1
  end
end'

# ── 7. Failure proofs: broken copies of the runtime ──────────────────────
# Each a copy of src/iyi with one file changed - concurrency.iyi unless
# another is named - built against through IYI_PATH, of the program named
# or of parallel_exercise.iyi; nothing in the tree is touched.
broken() { # name, awk program[, file in src/iyi[, program in bench]]
  local file="${3:-concurrency.iyi}" program="${4:-parallel_exercise}"
  mkdir -p "$1/iyi"
  cp "$REPO"/src/iyi/*.iyi "$1/iyi/"
  awk "$2" "$REPO/src/iyi/$file" > "$1/iyi/$file"
  if cmp -s "$1/iyi/$file" "$REPO/src/iyi/$file"; then
    echo "the awk for $1 found nothing to change"; exit 1
  fi
  if ! IYI_PATH="$WORK/$1${PSEP}$REPO/src" "$IYI" build "$REPO/bench/$program.iyi" -o "$1-run" > "build-$1.log" 2>&1; then
    echo "the broken copy $1 failed to build:"; tail -20 "build-$1.log"; exit 1
  fi
}
# A broken copy is a race the gate makes on purpose, and its run can lose
# the race some other way first: the intransit copy died of SIGSEGV in 2 of
# 180 runs rather than failing by name. A run that dies of a signal is run
# again, up to five times; one ending in exit 1 at the sentence is the
# proof, and any other end after five is a failure of the gate.
caught() { # name, expected FAIL text, step arguments...
  local name="$1" want="$2" code attempt
  shift 2
  for attempt in 1 2 3 4 5; do
    timeout -k 5 120 "./$name-run" "$@" > "$name.txt" 2>&1
    code=$?
    [ "$code" -lt 128 ] && [ "$code" -ne 124 ] && break
  done
  if [ "$code" -ne 1 ] || ! grep -qF "$want" "$name.txt"; then
    echo "the broken copy $name was not caught at \"$want\" (exit $code):"; tail -20 "$name.txt"; exit 1
  fi
  echo "  exits 1 at \"$(grep -m1 -F "$want" "$name.txt" | sed 's/^FAIL: //; s/^iyi: panic: //')\""
}

step "failure proof: a cross-thread wake that does not ring is a lost wakeup"
broken lostwake '/def self.send_home\(home/ { inhome = 1 } inhome && /^    ring\(home\)$/ { print "    # the doorbell, not rung"; inhome = 0; next } { print }'
caught lostwake 'placement: still waiting after 5000 ms' placement --watch=5000

step "failure proof: a steal that leaves the task in its victim's queue hands it out twice"
broken duplicate '/^          victim.pool_head = fiber.next_run$/ { next } /^          victim.pool_tail = nil if victim.pool_head.is_a\?\(Nil\)$/ { next } { print }'
caught duplicate 'the pool handed one parallel task to a worker twice' steal

step "failure proof: a cancel never delivered to a sleeping task's thread"
broken undelivered '/^    return if fiber.cancel_posted$/ { print "    return"; next } { print }'
caught undelivered 'cancel: still waiting after 5000 ms' cancel --watch=5000

step "failure proof: a cancel that skips tasks waiting in the pool runs them uncancelled"
broken unflagged '/def self.cancel\(fiber/ { incancel = 1 } incancel && /^    fiber.cancelled = true$/ { print "    fiber.cancelled = true unless fiber.home.is_a?(Nil)"; incancel = 0; next } { print }'
caught unflagged 'tasks waiting in the pool ran uncancelled' cancel --watch=60000

step "failure proof: take_now and put_now without the scheduler's lock lose and repeat values across workers"
# Two threads changing one channel's ring and queues at once end the step
# by name most runs - a place still held, a value out of order, a take of
# an empty channel, a wake lost - and some by a fault, or by a hang the
# step's own watchdog does not end, with a channel's queues torn: 10 of 12
# runs ended by name here and 2 hung, and a fault was seen in an earlier
# set. A run that dies of a signal or is timed out is run again, up to
# five times, and one ending by name is the proof.
if [ "$CORES" -lt 2 ]; then
  echo "  one core here: two workers cannot change a channel at the same instant, so the proof is not run"
else
  broken unlocked '/^  def (take_now|put_now)/ { inside = 1 } inside && /^    IyiSchedLock\.(lock|unlock)$/ { next } /^  end$/ { inside = 0 } { print }'
  for attempt in 1 2 3 4 5; do
    timeout -k 5 30 ./unlocked-run now --watch=5000 > unlocked.txt 2>&1
    code=$?
    [ "$code" -lt 124 ] && break
  done
  # Not anchored at the line's start: other workers' panics are printed
  # beside it, and one landed in front of the FAIL in a run of this proof.
  if [ "$code" -ne 1 ] || ! grep -q 'FAIL: now: ' unlocked.txt; then
    echo "the copy without the lock was not caught by the now step (exit $code):"; tail -20 unlocked.txt; exit 1
  fi
  echo "  exits 1 at \"$(grep -m1 -o 'FAIL: now: .*' unlocked.txt | sed 's/^FAIL: //')\""
fi

step "failure proof: a plain add loses counts when tasks run at the same instant"
if [ "$CORES" -lt 2 ]; then
  echo "  one core here: two tasks cannot be at the same instant, so the proof is not run"
else
  if ! "$IYI" build --release -Dparallel_plain_add "$REPO/bench/parallel_exercise.iyi" -o plainadd > build-plainadd.log 2>&1; then
    echo "the plain-add build failed:"; tail -20 build-plainadd.log; exit 1
  fi
  timeout -k 5 120 ./plainadd race > plainadd.txt 2>&1
  code=$?
  if [ "$code" -ne 1 ] || ! grep -q 'increments lost' plainadd.txt; then
    echo "a plain add lost nothing (exit $code), so the race step proves nothing:"; cat plainadd.txt; exit 1
  fi
  echo "  exits 1 at \"$(grep -m1 'increments lost' plainadd.txt | sed 's/^FAIL: //')\""
fi

# What a move keeps, broken one way each, and the migration exercise's
# step that names it. A move needs two workers on two cores.
if [ "$CORES" -lt 2 ]; then
  step "failure proofs for tasks that move"
  echo "  one core here: a task resumes where it parked, so the proofs are not run"
else
  step "failure proof: a thread-local read before a park and kept after it names the thread the task left"
  if ! "$IYI" build --release -Dparallel_stale_tls "$REPO/bench/parallel_migrate.iyi" -o staletls-run > build-staletls.log 2>&1; then
    echo "the stale thread-local build failed:"; tail -20 build-staletls.log; exit 1
  fi
  caught staletls 'a thread-local read after a park named another thread' channels

  step "failure proof: a thread-local read hoisted out of a loop names the thread the task left once the back-edge check moves it"
  if ! "$IYI" build --release -Dparallel_hoisted_tls "$REPO/bench/parallel_migrate.iyi" -o hoistedtls-run > build-hoistedtls.log 2>&1; then
    echo "the hoisted thread-local build failed:"; tail -20 build-hoistedtls.log; exit 1
  fi
  caught hoistedtls "a thread-local read after a loop's back-edge check named another thread" loops

  step "failure proof: a collector that skips a fiber on its way between workers frees the lists on its stack"
  broken intransit '/^            if fiber.state != IyiFiberState::Running && fiber.state != IyiFiberState::Done && fiber.saved_sp != 0$/ { print "            if fiber.state != IyiFiberState::Running && fiber.state != IyiFiberState::Runnable && fiber.state != IyiFiberState::Done && fiber.saved_sp != 0"; next } { print }' prelude.iyi parallel_migrate
  caught intransit 'list was not whole' channels

  step "failure proof: an io wait that does not say whose poller holds it is never cancelled"
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
      broken unlistedio '/def self.park_overlapped_current\(/ { inpark = 1 } inpark && /^    listed\(fiber, waiting_out\)$/ { inpark = 0; next } { print }' concurrency.iyi parallel_migrate ;;
    *)
      broken unlistedio '/def self.wait_posix\(fd/ { inwait = 1 } inwait && /^    listed\(fiber\)$/ { inwait = 0; next } { print }' concurrency.iyi parallel_migrate ;;
  esac
  caught unlistedio 'cancel: still waiting after 5000 ms' cancel --watch=5000

  step "failure proof: a close posted to no thread leaves a read on another worker parked"
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
      echo "  a close on Windows ends the posted read, whose completion its own port takes: there is nothing to post" ;;
    *)
      broken noclose '/def self.wake_closed\(fd/ { inclose = 1 } inclose && /^      return unless @@shared$/ { print "      return"; inclose = 0; next } { print }' concurrency.iyi parallel_migrate
      caught noclose 'closes: still waiting after 5000 ms' closes --watch=5000 ;;
  esac

  step "failure proof: a join held in the kernel holds its worker, and the sleepers on it"
  broken kerneljoin '/^      while @ended.get == 0_u64$/ { skip = 3 } skip > 0 { skip = skip - 1; next } { print }' thread.iyi parallel_migrate
  caught kerneljoin 'join: a task' join

  if [ "$CORES" -lt 4 ]; then
    step "failure proofs for stealing"
    echo "  $CORES cores here: the balance step is not timed, so there is nothing to fail"
  else
    # Both without preemption: a preempted task waits in a queue any worker
    # takes from, which spreads the parked tasks as a steal would, and a
    # pool that never steals took 1.88x the ideal with it on.
    NOPREEMPT='/^            Pointer\(Atomic\(UInt64\)\).new\(address\).value.set\(1_u64\) if address != 0_u64$/ { next } '
    step "failure proof: a pool that never steals a started task leaves tasks woken on one worker there"
    broken nosteal "$NOPREEMPT"'/^  def self.grab\(victim/ { print; print "    return nil"; next } { print }' concurrency.iyi parallel_migrate
    caught nosteal 'woken from a worker, took' balance

    step "failure proof: tasks woken back onto the worker they parked on, as before tasks moved"
    broken pinned "$NOPREEMPT"'/^      if fiber.unit.is_a\?\(IyiUnit\) && !fiber.homebound$/ { print "      if false"; next } /^  def self.grab\(victim/ { print; print "    return nil"; next } { print }' concurrency.iyi parallel_migrate
    caught pinned 'woken from the main thread, took' balance
  fi
fi

step "failure proof: a loop marked @[NoPreempt] holds its worker for its whole computation"
if ! "$IYI" build --release -Dpreempt_off "$REPO/bench/parallel_preempt.iyi" -o preemptoff-run > build-preemptoff.log 2>&1; then
  echo "the @[NoPreempt] build failed:"; tail -20 build-preemptoff.log; exit 1
fi
caught preemptoff 'slice: a short task waited' slice --workers=1

step "failure proof: a monitor that never raises a worker's word preempts nothing"
broken noflag '/^            Pointer\(Atomic\(UInt64\)\).new\(address\).value.set\(1_u64\) if address != 0_u64$/ { next } { print }' concurrency.iyi parallel_preempt
caught noflag 'slice: a short task waited' slice --workers=1

step "failure proof: a Windows monitor that waits on the system timer looks too seldom"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    broken coarse '/^        @@monitor_timer = timer.address$/ { print "        @@monitor_timer = 0_u64"; next } { print }' concurrency.iyi parallel_preempt
    caught coarse 'period: the monitor looked every' period --workers=1 ;;
  *)
    echo "  the monitor's tick here is the kernel's own timeout, and there is no system timer for it to fall back to" ;;
esac

step "failure proof: a check that calls the thread-local accessor at every back-edge costs a tight loop"
if [ "$(uname -s)" = Linux ]; then
  echo "  the check on Linux never called the accessor: the copy builds the same code, so there is nothing to fail"
else
  if ! "$IYI" build --release -Dpreempt_check_accessor "$REPO/bench/parallel_preempt.iyi" -o accessor-run > build-accessor.log 2>&1; then
    echo "the accessor build failed:"; tail -20 build-accessor.log; exit 1
  fi
  caught accessor 'tight: sum:' tight --workers=1
fi

step "failure proof: a slow half that does not poll leaves a connection in a busy worker's poller"
if [ "$CORES" -lt 2 ]; then
  echo "  one core here: no idle worker takes what the poll would hand over, so the proof is not run"
else
  broken nopoll '/^        IyiScheduler.wait_for_events\(false\)$/ { print "        IyiScheduler.wake_expired_sleepers"; next } { print }' concurrency.iyi parallel_preempt
  caught nopoll 'server: a fast request took' server --workers="$PREEMPT_WORKERS"
fi

step "failure proof: a preempted task that gives its unit's token away lets its child run inside it"
broken tokenless '/^      return unless unit.hand_to_yielded\(id\)$/ { print "      unit.give"; next } { print }' concurrency.iyi parallel_preempt
caught tokenless 'unit: a task of the same unit ran' unit --workers=1

# ── 8. Failure proof: one worker, whatever was asked for ──────────────────
step "failure proof: a pool held to one worker fails the speedup floor"
if [ "$CORES" -lt 2 ]; then
  echo "  one core here: the floor is not held, so there is nothing to fail"
else
  mkdir -p oneworker/iyi
  cp "$REPO"/src/iyi/*.iyi oneworker/iyi/
  awk '/^      workers = resolved$/ { print "      workers = 1"; next } { print }' \
    "$REPO/src/iyi/concurrency.iyi" > oneworker/iyi/concurrency.iyi
  cmp -s oneworker/iyi/concurrency.iyi "$REPO/src/iyi/concurrency.iyi" && { echo "the awk for oneworker found nothing to change"; exit 1; }
  if ! IYI_PATH="$WORK/oneworker${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/parallel_exercise.iyi" -o oneworker-run > build-oneworker.log 2>&1; then
    echo "the one-worker copy failed to build:"; tail -20 build-oneworker.log; exit 1
  fi
  SLOW="$(best_ms "$K" oneworker-run)" || exit 1
  if holds_floor "$ONE" "$SLOW" "$K"; then
    echo "a pool of one worker asked for $K took $SLOW ms against $ONE ms and passed the floor"; exit 1
  fi
  echo "  asked for $K, ran on 1: $SLOW ms against $ONE ms, $(awk -v a="$ONE" -v b="$SLOW" 'BEGIN { printf "%.2f", a / b }')x, refused"
fi

echo "parallel gate: every property held"
