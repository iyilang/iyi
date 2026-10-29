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
#      cancel and a close from a sibling or the main thread that find it,
#      frames 120 KiB deep; tasks parked on one worker finish in under
#      twice the ideal, woken from the main thread and from a worker; and a
#      task joining a thread leaves its worker to its child.
#      bench/parallel_preempt.iyi then holds preemption at loop back-edges
#      (SPEC.md III.4.13, part 9): a short task, a sleeper and a fast
#      request beside a task computing with no call in its loop wait no
#      more than 100 ms, 80 for the request, in the server shape and with
#      the request's window held open on one worker; a preempted task
#      keeps its unit's token; the monitor looks every 4 to 10.5 ms and
#      the quantum is at most 20 ms; a tight loop costs at most twice what
#      its `@[NoPreempt]` twin does; and the release build's IR shows each
#      tight loop's checks reading the worker's word through the thread
#      pointer, none calling its thread-local accessor. Its failure proofs
#      are with step 7's: a `@[NoPreempt]` loop, a monitor that never raises
#      the word, a Windows monitor on the system timer's tick, a check that
#      calls the accessor (darwin and Windows), a slow half that does not
#      poll, and a preempted task that gives its unit's token away.
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
#      a loop's local are refused, each by name. A block that reaches a
#      constant that is not Share through a def it calls is warned about
#      with the path, a failed build under `--error-on-warnings`; its
#      copy with the constant marked `@[SafeReach]` builds clean under it.
#      Two blocks reaching it are one warning, counting the other.
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
#      posted to nobody, a read made on the thread that closes its socket,
#      a pool that never steals a started task, tasks woken back onto the
#      worker they parked on as they were before tasks moved, and a join
#      held in the kernel.
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
# keeps its unit's token; the monitor looks every 4 to 10.5 ms and two tasks
# on one worker take turns of 20 ms at most; the tight loops cost at most
# twice what their `@[NoPreempt]` twins cost; and their checks read
# the word through the thread pointer, in the release build's IR, which
# it writes for that.
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
  [ "$build" = release ] && flag="--release --emit llvm-ir"
  # shellcheck disable=SC2086 # the flags are words
  if ! "$IYI" build $flag "$REPO/bench/parallel_preempt.iyi" -o "preempt-$build" > "build-preempt-$build.log" 2>&1; then
    echo "build failed:"; tail -20 "build-preempt-$build.log"; exit 1
  fi
  for run in "slice --workers=1" "unit --workers=1" "period --workers=1" "poller --workers=1" "server --workers=$PREEMPT_WORKERS"; do
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
if [ -z "$PY" ]; then
  echo "  no python here to read the IR with, so the audit is not run"
elif ! "$PY" "$REPO/bench/preempt_audit.py" preemptlib-release.ll > audit.txt 2>&1; then
  echo "the audit failed:"; cat audit.txt; exit 1
else
  sed 's/^/  /' audit.txt
fi

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
    runtime='___error __dyld_get_image_header __dyld_get_image_vmaddr_slide __tlv_bootstrap _backtrace _backtrace_symbols_fd _clock_gettime_nsec_np _exit _kevent _kqueue _mmap _mprotect _munmap _os_sync_wait_on_address _os_sync_wake_by_address_all _pthread_create _pthread_get_stackaddr_np _pthread_self _sigaction _sigaltstack _sysctlbyname _write'
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

# #148: the issue's shape, a pool in a constant read through `ask`. The
# block names no constant, so nothing above refuses it; it is warned
# about at the block, with the path, by a build and by `check`, and
# `--error-on-warnings` makes the warning a failure. The broken copy is
# the clean one with the mark taken off, and the check that passes the
# marked copy catches it. Two blocks reach `DATABASE`, and that is one
# warning at the first, counting the second: iyiturkiye's routes gave
# 1251 warnings about 37 constants, each once per route that reached
# it, on Linux; gathered they are 37. Its broken copy
# has the second block left out, and says nothing of another block.
step "a parallel block reaching a constant through a call is warned about"
cat > reaches.iyi <<'IYI'
module reaches

class Database
  def initialize
    @total = 0
  end

  def query_one(n : Int64) : Int64
    @total += 1
    n
  end
end

@[SafeReach("the gate's clean copy: one task asks, and the program says so")]
DATABASE = Database.new

def ask(n : Int64) : Int64
  DATABASE.query_one(n)
end

group do |g|
  g.spawn_parallel { ask(1_i64) }
  g.spawn_parallel { ask(2_i64) }
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
if ! "$IYI" build reaches_bare.iyi -o reaches_bare > build-reaches-bare.log 2>&1; then
  echo "a warning stopped a build without --error-on-warnings:"; cat build-reaches-bare.log; exit 1
fi
want='the block spawn_parallel runs on another thread reaches `DATABASE : ReachesBare::Database` (not Share) through `ask` → `DATABASE.query_one`, as does 1 other parallel block: '
if [ "$(grep -c 'reaches `DATABASE' build-reaches-bare.log)" != 1 ]; then
  echo "two blocks reaching DATABASE were not one warning:"; cat build-reaches-bare.log; exit 1
fi
if ! grep -qF "$want" build-reaches-bare.log; then
  echo "the block reaching DATABASE through ask was not warned about:"; cat build-reaches-bare.log; exit 1
fi
if "$IYI" check --error-on-warnings reaches_bare.iyi > check-reaches-strict.log 2>&1; then
  echo "--error-on-warnings passed the program the warning names:"; cat check-reaches-strict.log; exit 1
fi
if ! grep -qF "$want" check-reaches-strict.log; then
  echo "check failed the program, but not for the warning:"; cat check-reaches-strict.log; exit 1
fi
echo "  broken copy, the mark taken off: warned by the build, and failed by check --error-on-warnings"
echo "  warned once for two blocks: $(grep -m1 -F "$want" build-reaches-bare.log | sed 's/^Warning: //' | cut -c1-190)"
awk '/ask\(2_i64\)/ { next } /^module reaches_bare$/ { print "module reaches_lone"; next } { print }' reaches_bare.iyi > reaches_lone.iyi
if cmp -s reaches_bare.iyi reaches_lone.iyi; then
  echo "the awk for reaches_lone found nothing to change"; exit 1
fi
if ! "$IYI" check reaches_lone.iyi > check-reaches-lone.log 2>&1; then
  echo "check failed a program it only warns about:"; cat check-reaches-lone.log; exit 1
fi
if grep -qF "$want" check-reaches-lone.log || grep -qF 'other parallel block' check-reaches-lone.log \
  || ! grep -qF 'through `ask` → `DATABASE.query_one`: ' check-reaches-lone.log; then
  echo "one block reaching DATABASE was not warned about alone:"; cat check-reaches-lone.log; exit 1
fi
echo "  broken copy, the second block left out: warned with no other block counted"

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
# 180 runs rather than failing by name, and in 60 runs each it slipped
# through and exited 0 in 2 on one prelude and 1 on the next. A run that
# ends any way but exit 1 at the sentence is run again, up to five times;
# one ending there is the proof, and none in five is a failure of the gate.
caught() { # name, expected FAIL text, step arguments...
  local name="$1" want="$2" code attempt
  shift 2
  for attempt in 1 2 3 4 5; do
    timeout -k 5 120 "./$name-run" "$@" > "$name.txt" 2>&1
    code=$?
    [ "$code" -eq 1 ] && grep -qF "$want" "$name.txt" && break
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

  step "failure proof: a read made on the thread that closes its socket is a close that never crossed"
  if ! "$IYI" build --release -Dparallel_closes_home "$REPO/bench/parallel_migrate.iyi" -o closeshome-run > build-closeshome.log 2>&1; then
    echo "the closes-home build failed:"; tail -20 build-closeshome.log; exit 1
  fi
  caught closeshome 'the main thread closed a socket on the thread its reader parked on' closes

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
# machine).
broken nopoll '/^        IyiScheduler.wait_for_events\(false\)$/ { print "        IyiScheduler.wake_expired_sleepers"; next } { print }' concurrency.iyi parallel_preempt
caught nopoll 'poller: a fast request took' poller --workers=1

step "failure proof: a preempted task that gives its unit's token away lets its child run inside it"
broken tokenless '/^      return unless unit.hand_to_yielded\(id\)$/ { print "      unit.give"; next } { print }' concurrency.iyi parallel_preempt
caught tokenless 'unit: a task of the same unit ran' unit --workers=1

step "failure proof: the prelude's library compiled as the runtime's holds its worker through a sort, a copy, a growth and a join"
# `array.iyi`, `hash.iyi` and `string.iyi` written into prelude.iyi where it
# requires them, so the compiler takes their defs for the runtime's, which
# never check. A plain build, whose copy is a loop of bytes and long enough
# to tell.
broken libruntime '/^require "\.\/(array|hash|string)"$/ { name = $2; gsub(/"|\.\//, "", name); file = "'"$REPO"'/src/iyi/" name ".iyi"; while ((getline line < file) > 0) print line; close(file); next } { print }' prelude.iyi parallel_preempt_lib
for proof in sort copy rehash join; do
  caught libruntime "$proof: a short task waited" "$proof" --workers=1
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
if ! "$IYI" build -Dpreempt_off "$REPO/bench/parallel_preempt_lib.iyi" -o recursionoff-run > build-recursionoff.log 2>&1; then
  echo "the @[NoPreempt] build failed:"; tail -20 build-recursionoff.log; exit 1
fi
caught recursionoff 'fib: a short task waited' fib --workers=1

step "failure proof: a scheduler the compiler takes for a library's checks, and the audit names where"
if [ -z "$PY" ]; then
  echo "  no python here to read the IR with, so the audit is not run"
else
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
fi

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
