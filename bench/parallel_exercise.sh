#!/usr/bin/env bash
# Drives bench/parallel_exercise.iyi: tasks across cores (SPEC.md III.4.13).
#
#     bash bench/parallel_exercise.sh
#
# Seven steps; the last three are failure proofs, because a gate that
# cannot fail is not a gate:
#
#   1. The exercise holds every property, plain and --release: parallel
#      tasks start on the pool and on more than one worker, each stays on
#      the thread that started it, a thousand run exactly once, an atomic
#      count loses nothing, channels carry values across threads once each
#      and in each sender's order, a cancel reaches a task asleep, parked
#      on a channel, or still waiting in the pool, a panic stops at the
#      task's boundary, idle workers steal, collections keep the workers'
#      lists, and the typed group answers.
#   2. The binary keeps the dependency floor the concurrency gate holds,
#      plus `environ`, the C runtime's table `IYI_WORKERS` is read from.
#   3. The speedup, measured: CPU-bound tasks on one worker and on several,
#      release build, best of three, and the ratio held to a floor of 0.6
#      per worker - a pool that is parallel only in name cannot pass it.
#      The table for 1, 2, 4 and 8 workers (as far as the cores go) is
#      printed for the record.
#   4. A deadlock across threads - a parallel task waiting on a channel
#      nobody sends on - is named, not hung.
#   5. `Share` gates the parallel block at compile time: a captured
#      `Array`, a `Channel` of arrays, a local assigned after the spawn, and
#      a loop's local are refused, each by name.
#   6. Failure proofs against broken copies of the runtime, each caught at
#      the named check: a cross-thread wake that does not ring (a lost
#      wakeup), a steal that leaves the task in its victim's queue (a task
#      handed out twice), a cancel that is never delivered to the thread a
#      sleeping task is on, and a cancel that skips tasks still waiting in
#      the pool (a cancelled task run as if it were not); and the race
#      step's add made a plain load and store, which loses adds only when
#      tasks really run at the same instant.
#   7. Failure proof: the pool held to one worker whatever it was asked
#      for, and step 3's floor refuses the ratio that comes out.
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

# ── 6. Failure proofs: broken copies of the runtime ──────────────────────
# Each a copy of src/iyi with one line of concurrency.iyi changed, built
# against through IYI_PATH; nothing in the tree is touched.
broken() { # name, awk program
  mkdir -p "$1/iyi"
  cp "$REPO"/src/iyi/*.iyi "$1/iyi/"
  awk "$2" "$REPO/src/iyi/concurrency.iyi" > "$1/iyi/concurrency.iyi"
  if cmp -s "$1/iyi/concurrency.iyi" "$REPO/src/iyi/concurrency.iyi"; then
    echo "the awk for $1 found nothing to change"; exit 1
  fi
  if ! IYI_PATH="$WORK/$1${PSEP}$REPO/src" "$IYI" build "$REPO/bench/parallel_exercise.iyi" -o "$1-run" > "build-$1.log" 2>&1; then
    echo "the broken copy $1 failed to build:"; tail -20 "build-$1.log"; exit 1
  fi
}
caught() { # name, expected FAIL text, step arguments...
  local name="$1" want="$2"
  shift 2
  timeout -k 5 120 "./$name-run" "$@" > "$name.txt" 2>&1
  local code=$?
  if [ "$code" -ne 1 ] || ! grep -qF "$want" "$name.txt"; then
    echo "the broken copy $name was not caught at \"$want\" (exit $code):"; tail -20 "$name.txt"; exit 1
  fi
  echo "  exits 1 at \"$(grep -m1 -F "$want" "$name.txt" | sed 's/^FAIL: //; s/^iyi: panic: //')\""
}

step "failure proof: a cross-thread wake that does not ring is a lost wakeup"
broken lostwake '/def self.ready\(fiber/ { inready = 1 } inready && /^    ring\(home\)$/ { print "    # the doorbell, not rung"; inready = 0; next } { print }'
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

# ── 7. Failure proof: one worker, whatever was asked for ──────────────────
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
