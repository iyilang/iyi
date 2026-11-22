#!/usr/bin/env bash
# Drives bench/thread_exercise.iyi and the platform-specific thread checks.
# Usage: bash bench/thread_exercise.sh [again | but-again]
# No argument runs all selected-platform checks. `again` runs only the ten
# additional plain-build stress runs; `but-again` runs everything else.
#
# Checks and their witnesses:
#   1. Plain and release builds exercise live thread and parked-fiber roots,
#      collections, stopping, and list checksums and free flags. An explicit
#      collection runs after all worker lists are ready.
#  1b. Two hundred joined threads each run four sleeping tasks; the scheduler
#      states are checked after they finish, and so is what they leave open:
#      the process's handles on Windows, the lowest unused descriptor elsewhere.
#      Planted mutants leave a scheduler state on the roots' list, and leave
#      handles or descriptors open; each fails by one named sentence.
#  1c. Two hundred fifty-six joined threads each hold a 64 KiB payload. Fewer
#      than half survive a collection, and a joined thread's line is unmapped
#      on every platform. Planted mutants keep the payloads on their thread's
#      list and leave the line mapped; each fails by one named sentence.
#  1d. Join the same thread twice while a later thread is held: the mutant
#      keeps the first line, and that line is the named failure witness.
#   2. Inspect both binaries' undefined symbols or imported DLLs against
#      each platform's dependency floor; a copy that adds one dependency fails
#      by name.
#   3. Print allocations, collections, stops and allocation wall time; no
#      speed threshold decides the result.
#  3b. Windows: compare one- and two-core affinity with the reported core and
#      helper counts. The process mask supplies the cores used by later checks;
#      a copy that counts the machine's cores instead fails by one named line.
#   4. Run the release exercise with twice the core count, clamped to 9..32;
#      on a machine with 32 or more cores this is not necessarily oversubscribed.
#  4b. Measure the contended-lock ratio and mean stop time. On Windows, a
#      copy-only record witnesses all suspend requests before the first context
#      capture; its serial-suspend mutant is caught. A separate sample at the
#      first suspend checks the raised stopper priority against a no-raise copy.
#  4c. Windows: measure starts and joins beside a collector and a lock taker
#      on one core. Forced words record the counted waiter's first lock look,
#      and separate witnesses check yields after explicit and budget collection.
#  4d. Windows: print stop and lock-wait timings beside a burner. After 100
#      lock turns, the control runs 20 collections. Both copies witness actual
#      priority restore relative to runtime unlock, catching restoration inside
#      the lock. Another pair samples the priority restored
#      after a panic. A shared-priority pair holds two stoppers across their
#      raises and records each one's own restoration.
#  4e. Hold a released thread at its allocator park. A count-out word records
#      whether the release waited; the mutant attempts that wait.
#  4f. Linux and Darwin: a stop beside a thread held in the allocator parks it
#      only after it leaves. A copy that parks it inside is named on its one run.
#   5. Remove the thread-root walks for one run: the ready-list rendezvous,
#      explicit collection and sweep flags name the freed live nodes.
#  5b. Remove thread retirement from a copy: the finished-fiber registry count
#      names the leftover fibers.
#  5c. Stress switching tasks; separately hold a switch and collect, using the
#      ledger's free flags to detect an early running-state write. On Windows,
#      a held allocator entry and the second capture expose a stale depth read.
#  5d. Hold the first helper decision between its two writes, then enter a
#      second trigger. Both actual counts and helper starts are witnessed; the
#      swapped-write mutant names the premature publication.
#  5e. Hold one line after its first write, then force a competing write.
#      The captured bytes name the split-write mutant; a stress stays separate.
#  5f. Hold neighbouring fiber retirements around the first membership read.
#      The lock contention, unlinks and final registry identify the unlocked ask.
#   6. Compile negative Share examples, including mutable captures, self,
#      mixin and macro writes, and pointer exposure; check named diagnostics.
#  6b. Refuse locals assigned by the thread or after start, including macro
#      forms; a local assigned before start still runs.
#  6c. Strings and immutable containers run; an object whose String field is
#      reassigned is refused.
#  6d. Mutable constants and class variables are refused by name; Share
#      constants and class variables written only at initialization still run.
#   7. Windows: stress process termination beside collections. Independently,
#      inspect emitted main IR for the final __iyi_exit; a return-to-C copy
#      produces the named IR failure on its single build.
#  7b. Windows: stress thread starts beside collectors. A held start records a
#      scan before the new handle is written; the control writes it first.
#  7c. Windows: stress fresh stacks. A held holder's scan records its start
#      page; separate mutants start in the guard page or return an unnormalized
#      address, each producing its own named failure.
#  7d. Darwin: stress thread births beside a collector. A pre-TLS child is held
#      while the stop's signal site is observed; the early-linked mutant is named.
#  7e. Darwin: hold the first allocation in a frame with registers cleared;
#      two collections must each visit that line. The late-top mutant's sweep
#      flag supplies the named failure before the child's first store.
#  7f. Linux and Darwin: one task asks whether its stack top is in its own
#      stack before any collector runs, and a stop with sp at a fresh fiber's
#      top is bounded by that top. The topless mutant is named on its one run.
#  7g. Linux and Darwin: an armed mark helper faults while holding the lock.
#      The control witnesses handler classification and SIG_DFL installation,
#      then exits on SIGSEGV. The heap-action mutant reports its pre-lock fault.
#  7h. Linux and Darwin: a private waiter publishes its target and the final
#      increment records the actual platform wake. On Linux, a held real
#      spinner and its owed-turn word also expose the collector's lock attempt
#      before payment in the mutant.
#  7i. Darwin: one yield goes through an observer that records only after the
#      real thread_switch returns; the old ARM hint leaves it unanswered. The
#      mutant's binary no longer imports thread_switch, and the control's does.
#      Threads born alone and beside busy processes are measured after 7i
#      (`measure:`), not judged.
#  7j. Darwin: hold an unlinked child, inspect the actual stop roster and count,
#      then link it and witness a later stop. Early counting is named.
#  7k. Linux: tasks and a thread call libc and check its answers and imports.
#      A held thread's pthread handle exposes the raw-clone mutant, and a mark
#      helper launched on a fresh heap exposes the same mutant for helpers.
#
# Stress loops, never retries or claims that a particular schedule occurred:
#   1/4: each exercise runs 20 allocation bursts per thread and main, 200
#        scheduler teardowns and 256 joined payloads; the plain build gets ten
#        further runs. Step 4 varies the thread count.
#   4b: up to 64 lock contenders run 20,000 turns each; five collections run
#        beside computing threads. Their elapsed-time ratios are measurements.
#   4c: five starts and joins beside each of a collector and a lock taker;
#       the two elapsed times are measurements only.
#   5c: five switching runs; the collector repeats while 12 tasks pass tokens.
#   5e: four writers produce 20,000 lines each.
#   7: 200 Windows termination runs; a 20 ms workload does not prove overlap.
#   7b: three Windows start storms of 3 s, with at least one batch each.
#   7c: three Windows stack storms of 2 s, with each worker growing a stack.
#   7d: five Darwin birth storms, each at least 20 and at most 200 batches of
#       16 threads, with a 10 s workload limit after the first 20 batches.
#   7f: three Linux/Darwin fresh-task storms of 5 s, with at least one batch.
#   7k: 16 Linux tasks make 100 libc-call iterations each beside collections.
#
# Removed: the Windows loop repeating the unrooted mutant 200 times, because
# its single named failure is the proof; five diagnostic reruns of failing
# positive controls, which now print the first run's captured output instead.
# The old lock-ratio, stop-time and lock-wait limits are measurements, not
# verdicts. The old timed no-raise comparison is not run; 4b samples priority
# at the first suspend instead.
#
# Not forced: 3 is measurement only. The 4b lock ratio and 4c one-core timings
# have no scheduled starvation witness and are measurements only. The ordinary
# 5c switching and 5e line stresses do not force a particular switch or
# competing write; their separate held proofs do. The 6 variants are direct
# compiler inputs, not mutated compiler builds. The 7 termination storm does
# not prove a collection overlapped process exit; the IR comparison is the
# separate structural check. The 7k held-thread check and the helper launch
# prove the chosen launch path; the libc-call stress does not force a
# particular collection interleaving. The one open item is termination
# concurrent with collection: its failure is a hang inside kernel teardown,
# and the IR check forces the cause rather than the interleaving.
#
# Exit 0: selected checks passed, including detected mutants; unsupported
# platforms are a no-op. Exit 76: setup or watchdog failure, with SETUP:.
# Exit 1: defect, crashed control, or escaped mutant, with a FAIL: sentence.
# Invalid usage exits 2. A watchdog is not evidence of a defect.
#
set -u

part="${1:-}"
case "$part" in
  "" | again | but-again) ;;
  *) echo "usage: bash bench/thread_exercise.sh [again | but-again]" >&2; exit 2 ;;
esac

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/end_process.sh"
# On Windows `timeout` bounds a native child without GNU timeout's MSYS
# process-tree termination. An overrun returns 124 to check_bound, which
# reports a SETUP watchdog failure; other exits belong to the child.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    # The end of an overrunning child is bounded by its own deadline, separate
    # from the child's bound. end_process runs in the background; a stalled end
    # is reported as a child that could not be recovered, and is not waited for.
    end_bounded() {
      local child="$1" killer deadline=$((SECONDS + 10))
      end_process "$child" KILL &
      killer=$!
      while kill -0 "$killer" 2>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo "SETUP: ${current_step:-bounded cleanup}: the child could not be recovered (pid $child)" >&2
          return 76
        fi
        sleep 0.1
      done
      if ! wait "$killer" 2>/dev/null; then
        # The child can exit between the launcher's liveness check and
        # end_process reading its PID. Reap that already-exited child.
        if ! kill -0 "$child" 2>/dev/null; then
          wait "$child" 2>/dev/null || true
          return 0
        fi
        echo "SETUP: ${current_step:-bounded cleanup}: the child could not be recovered (pid $child)" >&2
        return 76
      fi
      while kill -0 "$child" 2>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo "SETUP: ${current_step:-bounded cleanup}: the child could not be recovered (pid $child)" >&2
          return 76
        fi
        sleep 0.1
      done
      return 0
    }
    timeout() {
      local limit child deadline
      while [ "${1:-}" = -k ]; do shift 2; done
      limit="$1"; shift
      deadline=$((SECONDS + limit))
      "$@" &
      child=$!
      while kill -0 "$child" 2>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then
          end_bounded "$child" || return 76
          return 124
        fi
        sleep 0.1
      done
      wait "$child"
    }
    ;;
esac
# The compiler, overridable: `bin/iyi` is a POSIX shell wrapper, and on
# Windows the caller is the only one who knows where the real binary is.
IYI="${IYI:-$REPO/bin/iyi}"
# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on the search path, so
# the patched copy is never read and the proof that a check can fail
# quietly stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

. "$REPO/bench/floor_base.sh"

cd "$WORK" || { echo "SETUP: workspace: could not enter the temporary directory"; exit 76; }

current_step=""
step() {
  [ -z "$current_step" ] || printf '== end: %s\n' "$current_step"
  current_step="$1"
  printf '== start: %s\n' "$current_step"
}
check_bound() {
  # 124 is the watchdog and nothing else. The gate sends TERM at its deadline
  # and no KILL, and `timeout` returns 124 only when the child ended from that
  # TERM. A child killed by SIGKILL from outside, such as the OOM killer,
  # returns 137: a crash, judged as one by the caller. The exercise installs
  # no TERM handler and blocks no signal, so TERM ends it; a child that
  # ignored TERM would run on to the job's own limit.
  if [ "$1" -eq 124 ]; then
    local description="${3:-run}"
    [ "$2" != forced ] || description="$description run"
    echo "SETUP: ${current_step:-bounded run}: $description exceeded its watchdog"
    exit 76
  fi
  if [ "$2" = forced ] && [ -n "${4:-}" ] && [ "$1" -ne 76 ]; then
    local failures
    if [ ! -r "$4" ]; then
      echo "SETUP: ${current_step:-forced proof}: the $3 output could not be read"
      exit 76
    fi
    failures="$(grep -c '^FAIL:' "$4" || :)"
    # fail() prints one FAIL line and exits 1, so a FAIL line with any other
    # ending, or two of them, is the program's own defect, never setup.
    if { [ "$1" -eq 0 ] && [ "$failures" -ne 0 ]; } || [ "$failures" -gt 1 ]; then
      echo "FAIL: ${current_step:-forced proof}: the $3 run printed $failures FAIL lines and exited $1"
      exit 1
    fi
  fi
}
# A forced pair has a control, which is the shipped program with no planted
# mutant, and a mutant. The caller has already checked the success ending it
# expects; pair_mismatch decides what any other ending means.
#   pair_mismatch CODE OUTPUT control
#     A FAIL line or any nonzero status (a crash, a signal or an uncaught
#     raise) is a defect in the shipped program: exit 1. Only exit 0 with no
#     witness is missing setup: SETUP, exit 76.
#   pair_mismatch CODE OUTPUT mutant STATUS LINE...
#     STATUS and LINE... are the control's own success ending. A mutant that
#     ends that way escaped detection: exit 1. Any other ending fails the gate
#     with the tail printed, exit 1. A SETUP line or exit 76 is setup: exit 76.
pair_mismatch() {
  local code="$1" output="$2" copy="$3" status line all=1
  shift 3
  if grep -q '^SETUP:' "$output"; then
    grep -m1 '^SETUP:' "$output"
    exit 76
  fi
  if [ "$code" -eq 76 ]; then
    echo "SETUP: ${current_step:-forced proof}: the $copy exited 76 without a setup sentence"
    cat "$output"
    exit 76
  fi
  if [ "$copy" = control ]; then
    if [ "$code" -eq 0 ] && ! grep -q '^FAIL:' "$output"; then
      echo "SETUP: ${current_step:-forced proof}: the control did not print its witness"
      cat "$output"
      exit 76
    fi
    if grep -q '^FAIL:' "$output"; then
      tr -d '\r' < "$output" | grep -m1 '^FAIL:'
    else
      echo "FAIL: ${current_step:-forced proof}: the control exited $code without its witness"
    fi
    sed 's/^/  /' "$output" | tail -n 5
    exit 1
  fi
  status="$1"
  shift
  if [ "$code" -eq "$status" ] && ! grep -q '^FAIL:' "$output"; then
    for line in "$@"; do
      tr -d '\r' < "$output" | grep -qxF "$line" || all=0
    done
    if [ "$all" -eq 1 ]; then
      echo "FAIL: ${current_step:-forced proof}: the mutant escaped detection"
      exit 1
    fi
  fi
  echo "FAIL: ${current_step:-forced proof}: the mutant ended with exit $code without its named sentence"
  sed 's/^/  /' "$output" | tail -n 5
  exit 1
}
trap 'status=$?; [ -z "$current_step" ] || printf "== end: %s (exit %s)\n" "$current_step" "$status"' EXIT

case "$(uname -s)" in
  Linux | Darwin | MINGW* | MSYS* | CYGWIN* | Windows_NT) ;;
  *)
    echo "thread exercise: measured on Linux, darwin and Windows; nothing to measure here"
    exit 0
    ;;
esac

# ── 1. The program, twice ─────────────────────────────────────────────────
step "stress: threads under the collector, plain build"
if ! "$IYI" build "$REPO/bench/thread_exercise.iyi" -o threads > build.log 2>&1; then
  echo "SETUP: ${current_step:-build}: the program did not build"; cat build.log; exit 76
fi
if [ "$part" != again ]; then
  timeout 300 ./threads 8 > answers.txt 2>&1
  code=$?; check_bound "$code" healthy "run 1"
  if [ "$code" -eq 76 ]; then cat answers.txt; exit 76; fi
  if [ "$code" -ne 0 ] || ! grep -q 'every property held' answers.txt; then
    echo "FAIL: ${current_step}: run 1 exited $code without completing"; cat answers.txt; exit 1
  fi

  step "stress: threads under the collector, release build"
  if ! "$IYI" build --release "$REPO/bench/thread_exercise.iyi" -o threads-release > build-release.log 2>&1; then
    echo "SETUP: ${current_step:-build}: release did not build"; cat build-release.log; exit 76
  fi
  timeout 300 ./threads-release 8 > answers-release.txt 2>&1
  code=$?; check_bound "$code" healthy "run 1"
  if [ "$code" -eq 76 ]; then cat answers-release.txt; exit 76; fi
  if [ "$code" -ne 0 ] || ! grep -q 'every property held' answers-release.txt; then
    echo "FAIL: ${current_step}: run 1 exited $code without completing"; cat answers-release.txt; exit 1
  fi
fi

# Ten additional healthy runs of the plain build. Every run must pass;
# the registry assertion is separate from this stress.
if [ "$part" != but-again ]; then
  step "stress: the plain build, ten more runs, and every one ends well"
  again=1
  while [ "$again" -le 10 ]; do
    timeout 300 ./threads 8 > again.txt 2>&1
    code=$?; check_bound "$code" healthy "run $again"
    if [ "$code" -eq 76 ]; then cat again.txt; exit 76; fi
    if [ "$code" -ne 0 ] || ! grep -q 'every property held' again.txt; then
      echo "FAIL: ${current_step}: run $again exited $code:"; tail -5 again.txt; exit 1
    fi
    again=$((again + 1))
  done
  echo "  ten of ten"
fi
if [ "$part" = again ]; then
  echo "workdir $WORK"
  echo "thread exercise: the plain build's ten more runs held"
  exit 0
fi

# ── 1b and 1c, forced: a finished thread's scheduler, a joined thread's payloads and line ──
# The release run above passed these checks, and its output is the control: the same
# program with no planted mutant, which the stress steps checked exited 0. Each mutant
# is one copy of the runtime or of the program, built against IYI_PATH and run once,
# and must end in exit 1 with its one FAIL sentence. The 300 s watchdog bounds a hang
# only: each 1b task's sleep(1) is one millisecond, so a healthy run finishes far inside it.
teardown_pass='teardown: 200 finished threads gave their schedulers back'
joined_pass="joined: fewer than half of the joined threads' payloads survived a collection"
mapped_pass="joined: a joined thread's line was unmapped"

step "failure proof controls: the healthy release run prints its teardown and joined lines"
tr -d '\r' < answers-release.txt > release-clean.txt
controls=1
grep -qxF "$teardown_pass" release-clean.txt || controls=0
grep -qxF "$joined_pass" release-clean.txt || controls=0
grep -qxF "$mapped_pass" release-clean.txt || controls=0
if [ "$controls" -ne 1 ] || [ "$(grep -c '^FAIL:' release-clean.txt || :)" -ne 0 ]; then
  pair_mismatch 0 release-clean.txt control
fi
echo "  control: $teardown_pass"
echo "  control: $joined_pass"
echo "  control: $mapped_pass"
awk '/teardown: .* changed by|payloads were still live/{print "  measured: " $0}' release-clean.txt

step "failure proof: a finished thread's scheduler state left on the roots' list is named"
mkdir -p retired/iyi && cp "$REPO"/src/iyi/*.iyi retired/iyi/ || { echo "SETUP: ${current_step}: the retired copy could not be made"; exit 76; }
awk '
  /^  def self\.retire_thread : Nil$/ { inside = 1; starts++ }
  inside && /^          previous\.next_state = state\.next_state$/ { print "          nil"; unlink_tail++; next }
  inside && /^          @@states_head = state\.next_state$/ { print "          nil"; unlink_head++; next }
  inside && /^  end$/ { inside = 0; ends++ }
  { print }
  END { if (starts != 1 || ends != 1 || unlink_tail != 1 || unlink_head != 1 || inside) exit 3 }
' "$REPO/src/iyi/concurrency.iyi" > retired/iyi/concurrency.iyi || { echo "SETUP: ${current_step}: the retirement anchors changed"; exit 76; }
cmp -s retired/iyi/concurrency.iyi "$REPO/src/iyi/concurrency.iyi" && { echo "SETUP: ${current_step}: the retired copy was unchanged"; exit 76; }
if ! IYI_PATH="$WORK/retired${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/thread_exercise.iyi" -o retired-run > build-retired.log 2>&1; then
  echo "SETUP: ${current_step}: retired did not build"; cat build-retired.log; exit 76
fi
timeout 300 ./retired-run 8 > retired-raw.txt 2>&1
code=$?; check_bound "$code" forced mutant retired-raw.txt
if [ "$code" -eq 76 ]; then cat retired-raw.txt; exit 76; fi
tr -d '\r' < retired-raw.txt > retired.txt
retired_fail="FAIL: teardown: 200 finished threads left 200 scheduler states on the roots' list"
if [ "$code" -ne 1 ] || [ "$(grep -c '^FAIL:' retired.txt || :)" -ne 1 ] || ! grep -qxF "$retired_fail" retired.txt; then
  pair_mismatch "$code" retired.txt mutant 0 "$teardown_pass"
fi
printf '  exits 1 at "%s"\n' "$retired_fail"

step "failure proof: a finished thread's scheduler descriptors or handles left open are named"
mkdir -p unclosed/iyi && cp "$REPO"/src/iyi/*.iyi unclosed/iyi/ || { echo "SETUP: ${current_step}: the unclosed copy could not be made"; exit 76; }
# The scheduler's close calls in retire_thread, per platform. Linux: the epoll
# descriptor and the eventfd doorbell. darwin: the kqueue. Windows: the
# doorbell and the deadline timer.
unclosed_copy() {
  case "$(uname -s)" in
    Linux)
      awk '
        /^  def self\.retire_thread : Nil$/ { inside = 1; starts++ }
        inside && $0 == "    __iyi_close(state.pollfd) if state.pollfd > 0_i64" { pollfds++; next }
        inside && $0 == "    {% if flag?(:linux) %}" { linux = 1; print; next }
        inside && linux && $0 == "      __iyi_close(state.wake_fd) if state.wake_fd > 0_i64" { wakes++; next }
        inside && linux && $0 == "    {% end %}" { linux = 0; print; next }
        inside && /^  end$/ { inside = 0; ends++ }
        { print }
        END { if (starts != 1 || ends != 1 || pollfds != 1 || wakes != 1 || inside || linux) exit 3 }
      ' "$REPO/src/iyi/concurrency.iyi" ;;
    Darwin)
      awk '
        /^  def self\.retire_thread : Nil$/ { inside = 1; starts++ }
        inside && $0 == "    __iyi_close(state.pollfd) if state.pollfd > 0_i64" { pollfds++; next }
        inside && /^  end$/ { inside = 0; ends++ }
        { print }
        END { if (starts != 1 || ends != 1 || pollfds != 1 || inside) exit 3 }
      ' "$REPO/src/iyi/concurrency.iyi" ;;
    *)
      awk '
        /^  def self\.retire_thread : Nil$/ { inside = 1; starts++ }
        inside && $0 == "    {% if flag?(:win32) %}" { win = 1; print; next }
        inside && win && $0 == "    {% end %}" { win = 0; print; next }
        inside && win && $0 == "      __iyi_close(state.wake_fd) if state.wake_fd > 0_i64" { wake++; next }
        inside && win && $0 == "      __iyi_close(state.deadline_timer) if state.deadline_timer > 0_i64" { timer++; next }
        inside && /^  end$/ { inside = 0; ends++ }
        { print }
        END { if (starts != 1 || ends != 1 || wake != 1 || timer != 1 || inside || win) exit 3 }
      ' "$REPO/src/iyi/concurrency.iyi" ;;
  esac
}
unclosed_copy > unclosed/iyi/concurrency.iyi || { echo "SETUP: ${current_step}: the handle anchors changed"; exit 76; }
cmp -s unclosed/iyi/concurrency.iyi "$REPO/src/iyi/concurrency.iyi" && { echo "SETUP: ${current_step}: the unclosed copy was unchanged"; exit 76; }
if ! IYI_PATH="$WORK/unclosed${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/thread_exercise.iyi" -o unclosed-run > build-unclosed.log 2>&1; then
  echo "SETUP: ${current_step}: unclosed did not build"; cat build-unclosed.log; exit 76
fi
timeout 300 ./unclosed-run 8 > unclosed-raw.txt 2>&1
code=$?; check_bound "$code" forced mutant unclosed-raw.txt
if [ "$code" -eq 76 ]; then cat unclosed-raw.txt; exit 76; fi
tr -d '\r' < unclosed-raw.txt > unclosed.txt
unclosed_fail="FAIL: teardown: 200 finished threads left handles open that their schedulers should have closed"
if [ "$code" -ne 1 ] || [ "$(grep -c '^FAIL:' unclosed.txt || :)" -ne 1 ] || ! grep -qxF "$unclosed_fail" unclosed.txt; then
  pair_mismatch "$code" unclosed.txt mutant 0 "$teardown_pass"
fi
awk '/teardown: .* changed by/{print "  measured: " $0}' unclosed.txt
printf '  exits 1 at "%s"\n' "$unclosed_fail"

step "failure proof: a joined thread's payloads kept by its thread's list are named"
mkdir -p listed/iyi && cp "$REPO"/src/iyi/*.iyi listed/iyi/ || { echo "SETUP: ${current_step}: the listed copy could not be made"; exit 76; }
awk '
  /^    def self\.run\(line : UInt64\) : Nil$/ { inside = 1; starts++ }
  inside && $0 == "      if thread.is_a?(IyiThread)" { print "      if false && thread.is_a?(IyiThread)"; hits++; next }
  inside && /^    end$/ { inside = 0; ends++ }
  { print }
  END { if (starts != 1 || ends != 1 || hits != 1 || inside) exit 3 }
' "$REPO/src/iyi/thread.iyi" > listed/iyi/thread.iyi || { echo "SETUP: ${current_step}: the run anchors changed"; exit 76; }
cmp -s listed/iyi/thread.iyi "$REPO/src/iyi/thread.iyi" && { echo "SETUP: ${current_step}: the listed copy was unchanged"; exit 76; }
if ! IYI_PATH="$WORK/listed${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/thread_exercise.iyi" -o listed-run > build-listed.log 2>&1; then
  echo "SETUP: ${current_step}: listed did not build"; cat build-listed.log; exit 76
fi
timeout 300 ./listed-run 8 > listed-raw.txt 2>&1
code=$?; check_bound "$code" forced mutant listed-raw.txt
if [ "$code" -eq 76 ]; then cat listed-raw.txt; exit 76; fi
tr -d '\r' < listed-raw.txt > listed.txt
listed_fail="FAIL: joined: 256 of 256 joined threads' payloads survived a collection"
if [ "$code" -ne 1 ] || [ "$(grep -c '^FAIL:' listed.txt || :)" -ne 1 ] || ! grep -qxF "$listed_fail" listed.txt; then
  pair_mismatch "$code" listed.txt mutant 0 "$joined_pass"
fi
printf '  exits 1 at "%s"\n' "$listed_fail"

step "failure proof: a joined thread's line left mapped is named"
mkdir -p mapped/iyi && cp "$REPO"/src/iyi/*.iyi mapped/iyi/ || { echo "SETUP: ${current_step}: the mapped copy could not be made"; exit 76; }
awk '
  /^    def join : Nil$/ { inside = 1; starts++ }
  inside && $0 == "      __iyi_munmap(line, IYI_THREAD_LINE)" { hits++; next }
  inside && /^    end$/ { inside = 0; ends++ }
  { print }
  END { if (starts != 1 || ends != 1 || hits != 1 || inside) exit 3 }
' "$REPO/src/iyi/thread.iyi" > mapped/iyi/thread.iyi || { echo "SETUP: ${current_step}: the join anchors changed"; exit 76; }
cmp -s mapped/iyi/thread.iyi "$REPO/src/iyi/thread.iyi" && { echo "SETUP: ${current_step}: the mapped copy was unchanged"; exit 76; }
if ! IYI_PATH="$WORK/mapped${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/thread_exercise.iyi" -o mapped-run > build-mapped.log 2>&1; then
  echo "SETUP: ${current_step}: mapped did not build"; cat build-mapped.log; exit 76
fi
timeout 300 ./mapped-run 8 > mapped-raw.txt 2>&1
code=$?; check_bound "$code" forced mutant mapped-raw.txt
if [ "$code" -eq 76 ]; then cat mapped-raw.txt; exit 76; fi
tr -d '\r' < mapped-raw.txt > mapped.txt
mapped_fail="FAIL: joined: a joined thread's line is still mapped"
if [ "$code" -ne 1 ] || [ "$(grep -c '^FAIL:' mapped.txt || :)" -ne 1 ] || ! grep -qxF "$mapped_fail" mapped.txt; then
  pair_mismatch "$code" mapped.txt mutant 0 "$mapped_pass"
fi
printf '  exits 1 at "%s"\n' "$mapped_fail"

# ── 1d. A second join while a later thread is held ───────────────────────
# Both builds run the same rendezvous. The only mutation removes the
# joined thread's line clear, without changing the zero guard or unmap.
rejoin_copy() {
  awk -v mode="$1" '
    /^    def join : Nil$/ { inside = 1; starts++ }
    inside && /^      line = @line$/ { reads++ }
    inside && /^      return if line == 0$/ { guards++ }
    inside && /^      @line = 0_u64$/ {
      resets++
      after_reset = 1
      if (mode != "mutant") print
      next
    }
    inside && /^      __iyi_munmap\(line, IYI_THREAD_LINE\)$/ {
      unmaps++
      if (!after_reset) wrong_order++
    }
    inside && /^    end$/ { inside = 0; ends++ }
    { after_reset = 0; print }
    END {
      if ((mode != "control" && mode != "mutant") || starts != 1 || ends != 1 ||
          reads != 1 || guards != 1 || resets != 1 || unmaps != 1 || wrong_order || inside) exit 3
    }
  ' "$REPO/src/iyi/thread.iyi" > "$2"
}
for mode in control mutant; do
  if ! mkdir -p "rejoin-$mode/iyi" || ! cp "$REPO"/src/iyi/*.iyi "rejoin-$mode/iyi/"; then
    echo "SETUP: joined: the $mode source copy could not be made"; exit 76
  fi
  rejoin_copy "$mode" "rejoin-$mode/iyi/thread.iyi" || {
    echo "SETUP: joined: the join copy anchors changed"; exit 76
  }
done

# Reinserting the one removed line must reconstruct the control byte for
# byte. Every other copied runtime file must also match the source.
if ! awk '
    /^    def join : Nil$/ { inside = 1; starts++ }
    inside && /^      __iyi_munmap\(line, IYI_THREAD_LINE\)$/ {
      print "      @line = 0_u64"
      restored++
    }
    inside && /^    end$/ { inside = 0; ends++ }
    { print }
    END { if (starts != 1 || ends != 1 || restored != 1 || inside) exit 3 }
  ' rejoin-mutant/iyi/thread.iyi > rejoin-restored.iyi; then
  echo "SETUP: joined: the reconstruction anchors changed"; exit 76
fi
if ! cmp -s rejoin-control/iyi/thread.iyi rejoin-restored.iyi; then
  echo "SETUP: joined: the copies differ beyond the line clear"; exit 76
fi
for source in "$REPO"/src/iyi/*.iyi; do
  file="${source##*/}"
  if ! cmp -s "$source" "rejoin-control/iyi/$file"; then
    echo "SETUP: joined: the control copy differs from the source"; exit 76
  fi
  if [ "$file" != thread.iyi ] && ! cmp -s "rejoin-control/iyi/$file" "rejoin-mutant/iyi/$file"; then
    echo "SETUP: joined: the copies differ beyond the line clear"; exit 76
  fi
done

rejoin_pass='joined: the second join returned while the later thread was held'
rejoin_fail='FAIL: joined: the first join left a line for a second join to use'
for mode in control mutant; do
  step "joined: $mode run"
  if ! IYI_PATH="$WORK/rejoin-$mode${PSEP}$REPO/src" "$IYI" build \
      "$REPO/bench/thread_exercise.iyi" -Djoin_only -o "rejoin-$mode-run" > "build-rejoin-$mode.log" 2>&1; then
    echo "SETUP: joined: the $mode copy did not build"
    cat "build-rejoin-$mode.log"
    exit 76
  fi
  timeout 60 "./rejoin-$mode-run" > "rejoin-$mode-raw.txt" 2>&1
  code=$?; check_bound "$code" forced "$mode" "rejoin-$mode-raw.txt"
  if ! tr -d '\r' < "rejoin-$mode-raw.txt" > "rejoin-$mode.txt"; then
    echo "SETUP: joined: the $mode output could not be read"; exit 76
  fi
  output="rejoin-$mode.txt"
  if [ "$code" -eq 76 ] || grep -q '^SETUP:' "$output"; then
    if grep -q '^SETUP:' "$output"; then
      cat "$output"
    else
      echo "SETUP: joined: the $mode run exited 76 without a diagnostic"
      cat "$output"
    fi
    exit 76
  fi
  fails="$(grep -c '^FAIL:' "$output" || :)"
  passes="$(grep -cxF "$rejoin_pass" "$output" || :)"
  if [ "$mode" = control ]; then
    if [ "$code" -eq 1 ] && [ "$fails" -eq 1 ] && [ "$passes" -eq 0 ] && grep -qxF "$rejoin_fail" "$output"; then
      cat "$output"; exit 1
    fi
    if [ "$code" -ne 0 ] || [ "$fails" -ne 0 ] || [ "$passes" -ne 1 ]; then
      pair_mismatch "$code" "$output" control
    fi
    echo "  control: exit 0, $rejoin_pass"
  else
    if [ "$code" -ne 1 ] || [ "$fails" -ne 1 ] || [ "$passes" -ne 0 ] ||
       ! grep -qxF "$rejoin_fail" "$output"; then
      pair_mismatch "$code" "$output" mutant 0 "$rejoin_pass"
    fi
    printf '  exits 1 at "%s"\n' "$rejoin_fail"
  fi
done

# ── 2. The floor ──────────────────────────────────────────────────────────
case "$(uname -s)" in
  Linux)
    step "dependency floor: threads and their stop add no symbol"
    floor_fail='FAIL: dependency floor: floor-extra adds getppid to the link line'
    floor_note='  five template names and nothing else, plain and release'
    # The undefined names of BINARY, less the five a thread start and stop
    # add: one FAIL line and 1 when any are left, 76 when nm cannot read it.
    floor_verdict() {
      local bin="$1" label="$2" undefined extra
      if ! undefined="$(nm -u "$bin" 2>&1)"; then
        echo "SETUP: dependency floor: nm could not read $label"
        printf '%s\n' "$undefined"
        return 76
      fi
      extra="$(printf '%s\n' "$undefined" |
        sed -e 's/^ *[wU] *//' -e 's/@.*$//' |
        awk 'NF && $0 !~ /^(_ITM_deregisterTMCloneTable|_ITM_registerTMCloneTable|__cxa_finalize|__gmon_start__|__libc_start_main)$/ { print }' |
        sort -u | tr '\n' ' ')"
      extra="${extra% }"
      if [ -n "$extra" ]; then
        printf 'FAIL: dependency floor: %s adds %s to the link line\n' "$label" "$extra"
        return 1
      fi
      return 0
    }
    # Whether BINARY still names the getppid that floor-extra adds.
    floor_carries() { nm -u "$1" 2>/dev/null | grep -qE '(^|[[:space:]])getppid'; }
    ;;
  Darwin)
    # The runtime's list (bench/dependency_floor.sh), the concurrency
    # exercise's `mprotect` (a fiber stack's guard page), and the thread
    # floor's thread list: pthread_create, pthread_join, pthread_kill and
    # sigaction for the thread and the stop, whose park is the futex the
    # runtime's list already names, __tlv_bootstrap for the thread-locals,
    # and close for a finished thread's kqueue
    # (`IyiScheduler.retire_thread`). Nothing else.
    step "dependency floor: what threads cost darwin, by name"
    floor_fail='FAIL: dependency floor: floor-extra asks libSystem for _getppid'
    floor_note="  the runtime's names and the thread floor's, and nothing else"
    floor_verdict() {
      local bin="$1" label="$2" undefined libraries allowed found extra runtime thread
      runtime='___error __dyld_get_image_header __dyld_get_image_vmaddr_slide __tlv_bootstrap _backtrace _backtrace_symbols_fd _clock_gettime_nsec_np _exit _kevent _kqueue _mmap _mprotect _munmap _os_sync_wait_on_address _os_sync_wake_by_address_all _pthread_create _pthread_get_stackaddr_np _pthread_self _sigaction _sigaltstack _sysctlbyname _thread_switch _write'
      thread='_close _pthread_create _pthread_join _pthread_kill'
      if ! undefined="$(nm -u "$bin" 2>&1)"; then
        echo "SETUP: dependency floor: nm could not read $label"
        printf '%s\n' "$undefined"
        return 76
      fi
      allowed="$(printf '%s\n' $runtime $thread | sort -u)"
      found="$(printf '%s\n' "$undefined" | sed -e 's/^ *//' | awk '{ print $NF }' | sort -u)"
      extra="$(comm -13 <(printf '%s\n' "$allowed") <(printf '%s\n' "$found") | tr '\n' ' ')"
      extra="${extra% }"
      if [ -n "$extra" ]; then
        printf 'FAIL: dependency floor: %s asks libSystem for %s\n' "$label" "$extra"
        return 1
      fi
      if ! libraries="$(otool -L "$bin" 2>&1)"; then
        echo "SETUP: dependency floor: otool could not read $label"
        printf '%s\n' "$libraries"
        return 76
      fi
      extra="$(printf '%s\n' "$libraries" | sed -n '2,$p' | awk '{ print $1 }' |
        grep -v -E '^/usr/lib/libSystem|^$' | tr '\n' ' ')"
      extra="${extra% }"
      if [ -n "$extra" ]; then
        printf 'FAIL: dependency floor: %s links beyond libSystem: %s\n' "$label" "$extra"
        return 1
      fi
      return 0
    }
    # Whether BINARY still names the _getppid that floor-extra adds.
    floor_carries() { nm -u "$1" 2>/dev/null | grep -qE '(^|[[:space:]])_getppid$'; }
    ;;
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    # A PE leaves nothing undefined, so the floor is the DLLs a thread
    # program imports, read with the toolchain's own `dumpbin`: threads
    # and their stop are kernel32's (`CreateThread`, `SuspendThread`,
    # `GetThreadContext`), and nothing else may join the C runtime.
    step "dependency floor: threads and their stop add no DLL"
    floor_fail='FAIL: dependency floor: floor-extra imports advapi32.dll beyond kernel32 and the C runtime'
    floor_note="  kernel32 and the C runtime's DLLs, plain and release"
    DUMPBIN="$(find_dumpbin || true)"
    [ -n "$DUMPBIN" ] || { echo "SETUP: dependency floor: dumpbin is unavailable"; exit 76; }
    floor_verdict() {
      local bin="$1" label="$2" dlls extra
      dlls="$(pe_dlls "$bin.exe")"
      if [ -z "$dlls" ]; then
        echo "SETUP: dependency floor: dumpbin read no import table from $label"
        return 76
      fi
      extra="$(extra_dlls "$FLOOR_DLLS_RUNTIME" "$dlls" | tr '\n' ' ')"
      extra="${extra% }"
      if [ -n "$extra" ]; then
        printf 'FAIL: dependency floor: %s imports %s beyond kernel32 and the C runtime\n' "$label" "$extra"
        return 1
      fi
      return 0
    }
    # Whether BINARY still imports the advapi32 DLL that floor-extra adds.
    floor_carries() { pe_dlls "$1.exe" | grep -qx 'advapi32.dll'; }
    ;;
esac

# The control: the shipped binaries pass the verdict, then print the note.
( floor_verdict threads threads && floor_verdict threads-release threads-release && echo "$floor_note" ) > floor-control.txt 2>&1
code=$?
if [ "$code" -ne 0 ] || ! tr -d '\r' < floor-control.txt | grep -qxF "$floor_note"; then
  pair_mismatch "$code" floor-control.txt control
fi
cat floor-control.txt

step "failure proof: an added dependency is named by the floor"
if ! mkdir -p floor-extra/iyi || ! cp "$REPO"/src/iyi/*.iyi floor-extra/iyi/; then
  echo "SETUP: dependency floor: the floor-extra source copy could not be made"; exit 76
fi
if ! awk '
  /^      fun pthread_attr_destroy\(attributes : Void\*\) : Int32$/ {
    print
    print "      fun getppid : Int32"
    linux++
    next
  }
  /^      fun thread_switch\(thread : UInt32, option : Int32, time : UInt32\) : Int32$/ {
    print
    print "      fun getppid : Int32"
    darwin++
    next
  }
  /^  \{% elsif flag\?\(:win32\) %\}$/ {
    print
    print "    @[Link(\"advapi32\")]"
    print "    lib LibFloorExtra"
    print "      fun RtlGenRandom = SystemFunction036(buffer : Void*, length : UInt32) : UInt8"
    print "    end"
    windows++
    next
  }
  /^    def self\.start\(proc : Proc\(Nil\)\) : IyiThread$/ {
    print
    print "      {% if flag?(:win32) %}"
    print "        @@count = LibFloorExtra.RtlGenRandom(Pointer(Void).new(0_u64), 0_u32).to_i64 if @@count < 0_i64"
    print "      {% else %}"
    print "        @@count = LibC.getppid.to_i64 if @@count < 0_i64"
    print "      {% end %}"
    starts++
    next
  }
  { print }
  END { if (linux != 1 || darwin != 1 || windows != 1 || starts != 1) exit 3 }
' "$REPO/src/iyi/thread.iyi" > floor-extra/iyi/thread.iyi; then
  echo "SETUP: dependency floor: the floor-extra anchors changed"; exit 76
fi
if cmp -s floor-extra/iyi/thread.iyi "$REPO/src/iyi/thread.iyi"; then
  echo "SETUP: dependency floor: the floor-extra copy was unchanged"; exit 76
fi
if ! IYI_PATH="$WORK/floor-extra${PSEP}$REPO/src" "$IYI" build \
    "$REPO/bench/thread_exercise.iyi" -o floor-extra-run > build-floor-extra.log 2>&1; then
  echo "SETUP: dependency floor: floor-extra did not build"; cat build-floor-extra.log; exit 76
fi
if ! floor_carries floor-extra-run; then
  echo "SETUP: dependency floor: floor-extra lost its added dependency in the build"; exit 76
fi
( floor_verdict floor-extra-run floor-extra && echo "$floor_note" ) > floor-extra-verdict.txt 2>&1
code=$?
if [ "$code" -eq 1 ] && [ "$(tr -d '\r' < floor-extra-verdict.txt | grep -c '^FAIL:' || :)" -eq 1 ] &&
   tr -d '\r' < floor-extra-verdict.txt | grep -qxF "$floor_fail"; then
  printf '  exits 1 at "%s"\n' "$floor_fail"
else
  pair_mismatch "$code" floor-extra-verdict.txt mutant 0 "$floor_note"
fi

# ── 3. The numbers ────────────────────────────────────────────────────────
cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")"
step "the numbers, release build ($cores cores here)"
grep -E '^(threads|speed):' answers-release.txt | sed 's/^/  /'

# ── 3b. Windows: the cores are the process's ──────────────────────────────
# The cores the marker sizes its helpers by were the machine's, whatever
# the affinity mask: a process held to one core (`start /affinity 1`) on
# twelve started eleven mark helpers, and eight allocating threads ran
# 3,077 ms against 178 with none. The mask's bits are counted now.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    step "the cores a process may run on are its affinity mask's"
    cat > cores.iyi <<'IYI'
@[Unsafe("the test reads Windows process affinity using pointer arguments")]
module cores
if Program.args.size > 0 && Program.args[0] == "active"
  puts "active=#{LibC.GetActiveProcessorCount(0xFFFF_u16)}"
elsif Program.args.size > 0
  process = 0_u64
  system = 0_u64
  if LibC.GetProcessAffinityMask(LibC.GetCurrentProcess, pointerof(process), pointerof(system)) == 0_i32
    print "SETUP: affinity: GetProcessAffinityMask failed\n"
    __iyi_exit(76)
  end
  puts "mask=#{process}"
else
  puts "core_count=#{IyiThread.core_count} default_helpers=#{IyiMark.default_helpers}"
end
IYI
    if ! "$IYI" build cores.iyi -o cores > build-cores.log 2>&1; then
      echo "SETUP: affinity: the core-count probe did not build"; cat build-cores.log; exit 76
    fi
    ./cores mask > affinity-mask.txt 2>&1
    code=$?
    if [ "$code" -ne 0 ]; then
      cat affinity-mask.txt
      grep -q '^SETUP:' affinity-mask.txt || echo "SETUP: affinity: the process mask probe ended with exit $code"
      exit 76
    fi
    mask="$(tr -d '\r' < affinity-mask.txt)"
    case "$mask" in mask=*) mask="${mask#mask=}" ;; *) echo "SETUP: affinity: invalid process mask"; exit 76 ;; esac
    case "$mask" in ''|*[!0-9]*) echo "SETUP: affinity: invalid process mask"; exit 76 ;; esac
    AFFINITY_COUNT=0
    AFFINITY_FIRST=0
    AFFINITY_SECOND=0
    AFFINITY_LAST=0
    for ((cpu = 0; cpu < 64; cpu++)); do
      if (( mask & (1 << cpu) )); then
        if [ "$AFFINITY_COUNT" -eq 0 ]; then AFFINITY_FIRST=$cpu; fi
        if [ "$AFFINITY_COUNT" -eq 1 ]; then AFFINITY_SECOND=$cpu; fi
        AFFINITY_LAST=$cpu
        AFFINITY_COUNT=$((AFFINITY_COUNT + 1))
      fi
    done
    if [ "$AFFINITY_COUNT" -lt 2 ]; then
      echo "SETUP: affinity: the process has fewer than two allowed processors" >&2
      exit 76
    fi
    affinity_one="$(printf '%X' "$((1 << AFFINITY_FIRST))")"
    affinity_two="$(printf '%X' "$(((1 << AFFINITY_FIRST) | (1 << AFFINITY_SECOND)))")"
    # The machine's active processors, which a process with no mask counts.
    # The maskless copy below must report them, and its expected line is named from them.
    ./cores active > cores-active.txt 2>&1
    code=$?
    if [ "$code" -ne 0 ]; then cat cores-active.txt; echo "SETUP: affinity: the active processor count did not run"; exit 76; fi
    cores_active="$(tr -d '\r' < cores-active.txt)"
    case "$cores_active" in active=*) cores_active="${cores_active#active=}" ;; *) echo "SETUP: affinity: invalid active processor count"; exit 76 ;; esac
    case "$cores_active" in ''|*[!0-9]*) echo "SETUP: affinity: invalid active processor count"; exit 76 ;; esac
    if [ "$cores_active" -gt 16 ]; then cores_helpers=15; elif [ "$cores_active" -gt 1 ]; then cores_helpers=$((cores_active - 1)); else cores_helpers=0; fi
    # held HEXMASK PROGRAM OUTPUT: the program's line, run on those cores. The
    # status is the program's own, so a crash shows as its exit status.
    held() {
      MSYS2_ARG_CONV_EXCL='*' cmd /c "start /affinity $1 /b /wait $2" > "$3" 2>&1
      local status=$?
      tr -d '\r' < "$3"
      return "$status"
    }
    # A nonzero status: the program's own SETUP sentence is setup (76). Any other
    # ending is a crash, a defect (exit 1 with its FAIL sentence), never setup.
    held_ended() {
      local status="$1" label="$2" file="$3"
      if tr -d '\r' < "$file" | grep -q '^SETUP:'; then
        tr -d '\r' < "$file" | grep -m1 '^SETUP:'
        return 76
      fi
      echo "FAIL: affinity: $label ended with exit $status"
      return 1
    }
    # The two checks the control runs. Each prints one FAIL line and returns 1
    # when the program answers otherwise, and returns what held_ended decides
    # when the program ends with a nonzero status.
    one_core() {
      local got status
      got="$(held "$affinity_one" "$1" "held-one-$2.txt")"
      status=$?
      if [ "$status" -ne 0 ]; then held_ended "$status" "the one-core run of $1" "held-one-$2.txt"; return; fi
      if [ "$got" != "core_count=1 default_helpers=0" ]; then
        echo "FAIL: affinity: held to one core: $got"
        return 1
      fi
    }
    two_core() {
      local got status
      got="$(held "$affinity_two" "$1" "held-two-$2.txt")"
      status=$?
      if [ "$status" -ne 0 ]; then held_ended "$status" "the two-core run of $1" "held-two-$2.txt"; return; fi
      if [ "$got" != "core_count=2 default_helpers=1" ]; then
        echo "FAIL: affinity: held to two cores: $got"
        return 1
      fi
    }
    affinity_pass='  held to one core it counts 1 and starts no helper; held to two, 2 and one'
    ( one_core cores.exe cores && two_core cores.exe cores && echo "$affinity_pass" ) > affinity-control.txt 2>&1
    code=$?
    if [ "$code" -ne 0 ] || ! tr -d '\r' < affinity-control.txt | grep -qxF "$affinity_pass"; then
      pair_mismatch "$code" affinity-control.txt control
    fi
    cat affinity-control.txt

    step "failure proof: a process held to one core counts the machine's cores"
    if ! mkdir -p maskless/iyi || ! cp "$REPO"/src/iyi/*.iyi maskless/iyi/; then
      echo "SETUP: affinity: the maskless source copy could not be made"; exit 76
    fi
    if ! awk '
      /^        if LibC\.GetProcessAffinityMask\(LibC\.GetCurrentProcess, pointerof\(mask\), pointerof\(system\)\) != 0$/ {
        print "        if false && LibC.GetProcessAffinityMask(LibC.GetCurrentProcess, pointerof(mask), pointerof(system)) != 0"
        found++
        next
      }
      { print }
      END { if (found != 1) exit 3 }
    ' "$REPO/src/iyi/thread.iyi" > maskless/iyi/thread.iyi; then
      echo "SETUP: affinity: the core-count anchor changed"; exit 76
    fi
    if cmp -s maskless/iyi/thread.iyi "$REPO/src/iyi/thread.iyi"; then
      echo "SETUP: affinity: the maskless copy was unchanged"; exit 76
    fi
    if ! IYI_PATH="$WORK/maskless${PSEP}$REPO/src" "$IYI" build cores.iyi -o cores-maskless > build-maskless.log 2>&1; then
      echo "SETUP: affinity: the maskless probe did not build"; cat build-maskless.log; exit 76
    fi
    maskless_expected="FAIL: affinity: held to one core: core_count=$cores_active default_helpers=$cores_helpers"
    ( one_core cores-maskless.exe maskless && two_core cores-maskless.exe maskless && echo "$affinity_pass" ) > maskless-verdict.txt 2>&1
    code=$?
    if [ "$code" -eq 1 ] && [ "$(tr -d '\r' < maskless-verdict.txt | grep -c '^FAIL:' || :)" -eq 1 ] &&
       tr -d '\r' < maskless-verdict.txt | grep -qxF "$maskless_expected"; then
      printf '  exits 1 at "%s"\n' "$maskless_expected"
    else
      pair_mismatch "$code" maskless-verdict.txt mutant 0 "$affinity_pass"
    fi
    ;;
esac

# ── 4. Past the core count ────────────────────────────────────────────────
# Twice the cores, clamped to at least nine and at most 32 threads.
over=$((cores * 2))
[ "$over" -lt 9 ] && over=9
[ "$over" -gt 32 ] && over=32
step "stress: the same, $over threads, release ($cores cores here)"
timeout 300 ./threads-release "$over" > answers-32.txt 2>&1
code=$?; check_bound "$code" healthy "run 1"
if [ "$code" -eq 76 ]; then cat answers-32.txt; exit 76; fi
if [ "$code" -ne 0 ] || ! grep -q 'every property held' answers-32.txt; then
  echo "FAIL: ${current_step}: run 1 exited $code without completing"; cat answers-32.txt; exit 1
fi
grep -E '^threads:' answers-32.txt | sed 's/^/  /'

# ── 4b. The runtime lock with four times the cores' threads, and the stop ─
# The lock only spun: a holder preempted with it waited out the spinners'
# timeslices, and 48 threads taking it on twelve cores took 30 to 35 times
# what one thread took for all of their turns (r2_alloc_threads: 64 threads
# allocating 1.8 to 20 s against 0.2 to 0.4 for twelve). It yields the core
# every 128th turn now: 1.3 to 1.5 times. That ratio was asserted, at 5,
# with a copy whose lock never gives its core away as the proof, and the
# bound is retired: what the copy measured was the spin's code shape, not
# its spinning. On mt/next the copy took 14.7 to 15.4 times one thread on
# Linux (12 vCPU) and on Windows 11, 12 logical processors (the user's
# machine), and 37 to 43 with the first turn's yield gone too; with the
# runtime lock's spin keeping a word for the turn a stop's release owes
# it (`IyiThread.owe_turn`), the same copy took 2.4 to 3.5 times on both,
# a copy with no yield and no count of spinners 1.8 to 2.1, one taking
# the lock by CAS of the whole word 2.0 - and the runtime's lock 2.0. Any
# one of the four lines that word adds to the lock's path took the first
# copy from 37 to between 5 and 7, with no stop in the run and an overlap
# count of holders at 0; holds of 500 and 2,000 increments showed nothing
# for any copy (1.1 to 2.1). A bound no broken lock can cross holds
# nothing, so the ratio is printed now and not asserted. What the yield
# is for is held where it shows: one core, a thread taking the lock in a
# loop, and threads starting beside it (4c), with its proof copy.
#
# And Windows' stop waited for each suspend before asking for the next, so
# a thread with no core held the stop until the scheduler ran it:
# collections beside 48 threads computing on twelve cores, half a second
# after they started, stopped them in 85 to 275 ms each, and in 0 to 13
# asked all at once. The stop is now measured with threads that have no
# core by construction (below). Asserted on Windows, where it was
# measured; printed everywhere.
cat > crowd.iyi <<'IYI'
@[Unsafe("on Windows the spinners pin and prioritize themselves through Windows' thread functions, a lib and C calls with pointerof answers")]
module crowd

class Counter
  getter value : Atomic(Int64)

  def initialize
    @value = Atomic(Int64).new(0_i64)
  end
end

class Flag
  getter stop : Atomic(Int64)
  getter held : Atomic(Int64)
  getter go : Atomic(Int64)
  getter burst : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
    @held = Atomic(Int64).new(0_i64)
    @go = Atomic(Int64).new(0_i64)
    @burst = Atomic(Int64).new(0_i64)
  end
end

{% if flag?(:win32) %}
  lib Placing
    fun SetThreadAffinityMask(thread : Void*, mask : UInt64) : UInt64
    fun SetThreadPriority(thread : Void*, priority : Int32) : Int32
    fun Sleep(milliseconds : UInt32) : Nil
  end
{% end %}

# The running thread held to the processors `mask` names, at Windows'
# `priority` (-2 lowest, 2 highest) with no boost above it; nothing
# elsewhere, where the stop is not asserted.
def hold(mask : UInt64, priority : Int32) : Nil
  {% if flag?(:win32) %}
    Placing.SetThreadAffinityMask(::LibC.GetCurrentThread, mask)
    Placing.SetThreadPriority(::LibC.GetCurrentThread, priority)
    ::LibC.SetThreadPriorityBoost(::LibC.GetCurrentThread, 1_i32)
  {% end %}
end

# The processors this process may run on, lowest first; one guessed bit
# outside Windows.
def processors : Array(UInt64)
  mask = 1_u64
  {% if flag?(:win32) %}
    system = 0_u64
    ::LibC.GetProcessAffinityMask(::LibC.GetCurrentProcess, pointerof(mask), pointerof(system))
  {% end %}
  bits = [] of UInt64
  bit = 1_u64
  while mask != 0_u64
    bits << bit if (mask & 1_u64) != 0_u64
    mask = mask.unsafe_shr(1_u64)
    bit = bit.unsafe_shl(1_u64)
  end
  bits
end

def hammer(counter : Counter, rounds : Int32) : Nil
  index = 0
  while index < rounds
    IyiRuntimeLock.lock
    hold = 0
    while hold < 50
      counter.value.add(1_i64)
      hold = hold + 1
    end
    IyiRuntimeLock.unlock
    index = index + 1
  end
end

def spin(flag : Flag) : Nil
  x = 0_i64
  while flag.stop.get == 0_i64
    x = x &+ 1
  end
end

# A thread on the shared processor below the one above it: `hold` moves it
# there before it lowers it, so it gets there while nothing above it is.
def spin_low(flag : Flag, mask : UInt64) : Nil
  hold(mask, -2_i32)
  flag.held.add(1_i64)
  spin(flag)
end

# The thread above the two low ones, moved there once they are: it
# computes 400 ms at a time, counting each start, and lets them run for a
# millisecond in between.
def spin_high(flag : Flag, mask : UInt64) : Nil
  while flag.go.get == 0_i64
    IyiThread.yield_cpu
  end
  hold(mask, 2_i32)
  flag.held.add(1_i64)
  while flag.stop.get == 0_i64
    flag.burst.add(1_i64)
    ends = IyiMark.now_ns + 400000000_u64
    while IyiMark.now_ns < ends && flag.stop.get == 0_i64
    end
    {% if flag?(:win32) %}
      Placing.Sleep(1_u32)
    {% end %}
  end
end

def fail(message : String) : Nil
  print "FAIL: #{message}\n"
  __iyi_exit(1)
end

{% if flag?(:win32) && flag?(:stop_order_force) %}
IyiThread.stop_order_reset
{% end %}
cores = IyiThread.core_count.to_i
crowd = cores * 4
crowd = 8 if crowd < 8
crowd = 64 if crowd > 64
rounds = 20000
counter = Counter.new
started = IyiMark.now_ns
hammer(counter, crowd * rounds)
alone = IyiMark.now_ns - started
started = IyiMark.now_ns
threads = [] of IyiThread
crowd.times { threads << IyiThread.start { hammer(counter, rounds); nil } }
threads.each { |thread| thread.join }
took = IyiMark.now_ns - started
puts "lock: #{crowd} threads taking the runtime lock on #{cores} cores took #{(took * 10_u64) // alone // 10_u64}.#{(took * 10_u64) // alone % 10_u64} times what one thread took for all their turns (printed, not bounded)"

# The stop, beside three threads that only compute on one processor, the
# stopping thread on another: one thread at Windows' highest priority,
# which computes 400 ms at a time, and two at its lowest, which it keeps
# off the processor. The stop walks the threads newest first and the high
# one is in the middle, so either way round a low one is asked first; and
# each collection starts as a run of the high one does. A stop asked all
# at once suspends the high thread at once, and the low ones take theirs
# the moment they run; one that waits for each suspend before asking for
# the next waits out the high thread's run for the first low one. Beside
# 48 threads with no such hold, on a Windows machine (Windows 11, 12
# logical processors), that stop stayed under 60 ms in 15 runs of 15 and
# the check could not tell it from a stop asked all at once.
cpus = processors
shared = cpus.last
hold(cpus.first, 0_i32)
flag = Flag.new
spinners = [] of IyiThread
spinners << IyiThread.start { spin_low(flag, shared) }
spinners << IyiThread.start { spin_high(flag, shared) }
spinners << IyiThread.start { spin_low(flag, shared) }
while flag.held.get < 2_i64
  IyiThread.yield_cpu
end
# On a machine of one processor, the stopping thread shares it, and stays
# level with the high thread, or that thread would hold it off as well.
hold(cpus.first, 2_i32) if cpus.size == 1
flag.go.set(1_i64)
while flag.held.get < 3_i64
  IyiThread.yield_cpu
end
stop_ns = IyiThread.stop_ns
stops = IyiThread.stops
5.times do
  burst = flag.burst.get
  while flag.burst.get == burst
    IyiThread.yield_cpu
  end
  IyiMark.collect
end
mean = (IyiThread.stop_ns - stop_ns) // (IyiThread.stops - stops)
flag.stop.set(1_i64)
spinners.each { |thread| thread.join }
{% if flag?(:win32) && flag?(:stop_order_force) %}
fail("stop: a context was captured before all suspend requests were issued") if IyiThread.stop_order_early?
if !IyiThread.stop_order_seen?
  print "SETUP: stop: no context capture was observed\n"
  __iyi_exit(76)
end
puts "stop: every suspend request preceded the first context capture"
{% end %}
puts "stop: five collections stopped #{spinners.size} threads that only compute, on one processor, in #{mean // 1000_u64} us each (measurement only)"
IYI
step "stress: the runtime lock with four times the cores' threads, and the stop"
if ! "$IYI" build --release crowd.iyi -o crowd > build-crowd.log 2>&1; then
  echo "SETUP: ${current_step:-build}: crowd did not build"; cat build-crowd.log; exit 76
fi
timeout 300 ./crowd > crowd.txt 2>&1
code=$?; check_bound "$code" healthy "run 1"
if [ "$code" -eq 76 ]; then cat crowd.txt; exit 76; fi
if [ "$code" -ne 0 ]; then
  echo "FAIL: ${current_step}: run 1 exited $code"; cat crowd.txt; exit 1
fi
sed 's/^/  /' crowd.txt
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    cat > stop-order.part <<'IYI'
    IYI_STOP_ORDER_SEEN = 1408_u64
    IYI_STOP_ORDER_EARLY = 1472_u64
    IYI_STOP_PRIORITY_ARM = 1536_u64
    IYI_STOP_PRIORITY_SAMPLE = 1600_u64
    def self.stop_priority_arm : Nil
      page = control
      word(page + IYI_STOP_PRIORITY_SAMPLE).value.set(0_u64)
      word(page + IYI_STOP_PRIORITY_ARM).value.set(1_u64)
    end
    def self.stop_priority_sample : Nil
      page = control
      return unless word(page + IYI_STOP_PRIORITY_ARM).value.compare_and_set(1_u64, 0_u64)[1]
      actual = LibC.GetThreadPriority(LibC.GetCurrentThread)
      if actual == 2147483647_i32
        message = "SETUP: raise: GetThreadPriority failed\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        __iyi_exit(76)
      end
      word(page + IYI_STOP_PRIORITY_SAMPLE).value.set((actual.to_i64 + 16_i64).to_u64)
    end
    def self.stop_priority_value : Int64
      word(control + IYI_STOP_PRIORITY_SAMPLE).value.get.to_i64 - 16_i64
    end
    def self.stop_order_reset : Nil
      word(control + IYI_STOP_ORDER_SEEN).value.set(0_u64)
      word(control + IYI_STOP_ORDER_EARLY).value.set(0_u64)
    end
    def self.stop_order_suspend(handle : Pointer(Void)) : Nil
      if LibC.SuspendThread(handle) < 0_i32
        message = "SETUP: stop: SuspendThread failed\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        __iyi_exit(76)
      end
      stop_priority_sample
    end
    def self.stop_order_observe(asked : Int64, expected : Int64, sp : UInt64) : Nil
      if sp == 0_u64
        message = "SETUP: stop: context capture returned no stack\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        __iyi_exit(76)
      end
      page = control
      word(page + IYI_STOP_ORDER_SEEN).value.set(1_u64)
      word(page + IYI_STOP_ORDER_EARLY).value.set(1_u64) if asked < expected
    end
    def self.stop_order_seen? : Bool
      word(control + IYI_STOP_ORDER_SEEN).value.get != 0_u64
    end
    def self.stop_order_early? : Bool
      word(control + IYI_STOP_ORDER_EARLY).value.get != 0_u64
    end
IYI
    stop_order_copy() {
      awk -v part=stop-order.part -v mode="$1" '
        /^    # ── Roots/ { while ((getline s < part) > 0) print s; roots++ }
        mode == "noraise" && /^        @@stopper_raised = LibC\.SetThreadPriority\(me, THREAD_PRIORITY_HIGHEST\) != 0$/ { print "        @@stopper_raised = false"; raise_removed++; next }
        /^      private def self\.suspend_others\(line : UInt64\) : Int64$/ { print; print "        stop_asked = 0_i64"; entry++; next }
        /^          LibC\.SuspendThread\(Pointer\(Void\)\.new\(IyiHeap\.read64\(cursor \+ IYI_TL_HANDLE\)\)\) if cursor != line$/ {
          if (mode != "forced") {
            print "          if cursor != line"
            print "            stop_order_suspend(Pointer(Void).new(IyiHeap.read64(cursor + IYI_TL_HANDLE)))"
            print "            stop_asked += 1_i64"
            print "          end"
          }
          asked++; next
        }
        /^            handle = Pointer\(Void\)\.new\(IyiHeap\.read64\(cursor \+ IYI_TL_HANDLE\)\)$/ {
          print
          if (mode == "forced") { print "            stop_order_suspend(handle)"; print "            stop_asked += 1_i64" }
          handles++; next
        }
        /^            sp = IyiRoots\.capture_thread_registers\(handle, cursor \+ IYI_TL_SPILL\)$/ {
          print
          print "            stop_order_observe(stop_asked, @@count - (line != 0_u64 ? 1_i64 : 0_i64), sp)"
          capture++; next
        }
        { print }
        END { if (roots != 1 || entry != 1 || asked != 1 || handles != 1 || capture != 1 || (mode == "noraise" && raise_removed != 1)) exit 3 }
      ' "$REPO/src/iyi/thread.iyi" > "$2"
    }
    step "stop ordering: the control issues every suspend before the first capture"
    mkdir -p ordered/iyi serial/iyi
    cp "$REPO"/src/iyi/*.iyi ordered/iyi/
    cp "$REPO"/src/iyi/*.iyi serial/iyi/
    stop_order_copy control ordered/iyi/thread.iyi || { echo "SETUP: stop: ordering control anchors changed"; exit 76; }
    stop_order_copy forced serial/iyi/thread.iyi || { echo "SETUP: stop: ordering mutant anchors changed"; exit 76; }
    if ! IYI_PATH="$WORK/ordered${PSEP}$REPO/src" "$IYI" build --release crowd.iyi -Dstop_order_force -o crowd-order > build-order.log 2>&1; then
      echo "SETUP: ${current_step:-build}: order did not build"; cat build-order.log; exit 76
    fi
    timeout 300 ./crowd-order > order.txt 2>&1
    code=$?; check_bound "$code" forced control order.txt
    if [ "$code" -eq 76 ]; then cat order.txt; exit 76; fi
    if [ "$code" -ne 0 ] || ! tr -d '\r' < order.txt | grep -qxF 'stop: every suspend request preceded the first context capture'; then
      pair_mismatch "$code" order.txt control
    fi
    echo "  control: exit 0, every suspend request preceded the first context capture"
    step "failure proof: a stop that captures before issuing every suspend request is caught"
    if ! IYI_PATH="$WORK/serial${PSEP}$REPO/src" "$IYI" build --release crowd.iyi -Dstop_order_force -o crowd-serial > build-serial.log 2>&1; then
      echo "SETUP: ${current_step:-build}: serial did not build"; cat build-serial.log; exit 76
    fi
    timeout 300 ./crowd-serial > serial.txt 2>&1
    code=$?; check_bound "$code" forced mutant serial.txt
    if [ "$code" -eq 76 ]; then cat serial.txt; exit 76; fi
    if [ "$code" -ne 1 ] || ! tr -d '\r' < serial.txt | grep -qxF 'FAIL: stop: a context was captured before all suspend requests were issued'; then
      pair_mismatch "$code" serial.txt mutant 0 'stop: every suspend request preceded the first context capture'
    fi
    echo '  exits 1 at "FAIL: stop: a context was captured before all suspend requests were issued"'

    cat > raising.iyi <<'IYI'
@[Unsafe("the test sets and queries the stopping thread's Windows priority")]
module raising
class Flag
  getter ready : Atomic(Int64)
  getter done : Atomic(Int64)
  def initialize
    @ready = Atomic(Int64).new(0_i64)
    @done = Atomic(Int64).new(0_i64)
  end
end
IyiMark.auto = false
IyiMark.workers = 0_u64
if LibC.SetThreadPriority(LibC.GetCurrentThread, 0_i32) == 0_i32 || LibC.GetThreadPriority(LibC.GetCurrentThread) != 0_i32
  print "SETUP: raise: could not set and verify normal priority\n"
  __iyi_exit(76)
end
flag = Flag.new
worker = IyiThread.start do
  flag.ready.set(1_i64)
  while flag.done.get == 0_i64
    IyiThread.spin_pause
  end
  nil
end
deadline = IyiMark.now_ns &+ 20000000000_u64
while flag.ready.get == 0_i64
  if IyiMark.now_ns >= deadline
    print "SETUP: raise: the worker did not start\n"
    __iyi_exit(76)
  end
  IyiThread.yield_cpu
end
IyiThread.stop_priority_arm
IyiMark.collect
sample = IyiThread.stop_priority_value
if sample == -16_i64
  print "SETUP: raise: the first suspend was not sampled\n"
  __iyi_exit(76)
end
if sample != 2_i64
  print "FAIL: raise: the stopper was not raised at the first suspend\n"
  __iyi_exit(1)
end
flag.done.set(1_i64)
worker.join
puts "raise: the stopper was raised at the first suspend"
IYI
    mkdir -p noraise/iyi
    cp "$REPO"/src/iyi/*.iyi noraise/iyi/
    stop_order_copy noraise noraise/iyi/thread.iyi || { echo "SETUP: raise: copy anchors changed"; exit 76; }
    for mode in control noraise; do
      tree=ordered
      [ "$mode" = noraise ] && tree=noraise
      if ! IYI_PATH="$WORK/$tree${PSEP}$REPO/src" "$IYI" build --release raising.iyi -o "raising-$mode" > "build-raising-$mode.log" 2>&1; then
        echo "SETUP: raise: the $mode copy did not build"; cat "build-raising-$mode.log"; exit 76
      fi
      step "the stopper's priority at the first suspend, $mode"
      timeout 60 "./raising-$mode" > "raising-$mode.txt" 2>&1
      code=$?; check_bound "$code" forced "$mode" "raising-$mode.txt"
      if [ "$code" -eq 76 ]; then cat "raising-$mode.txt"; exit 76; fi
      if [ "$mode" = control ]; then
        [ "$code" -eq 0 ] && tr -d '\r' < "raising-$mode.txt" | grep -qxF 'raise: the stopper was raised at the first suspend' || pair_mismatch "$code" "raising-$mode.txt" control
        echo '  control: exit 0, raise: the stopper was raised at the first suspend'
      else
        [ "$code" -eq 1 ] && tr -d '\r' < "raising-$mode.txt" | grep -qxF 'FAIL: raise: the stopper was not raised at the first suspend' || pair_mismatch "$code" "raising-$mode.txt" mutant 0 'raise: the stopper was raised at the first suspend'
        echo '  exits 1 at "FAIL: raise: the stopper was not raised at the first suspend"'
      fi
    done
    ;;
esac

# ── 4c. Windows: on one core a waiter gets the runtime lock ──────────────
# The lock was a plain test-and-set, and a holder on one core runs its
# unlock and its next lock back to back: a spinner ran only while the
# holder was preempted, so with the lock held. Under `start /affinity 1`
# a thread starting beside one looping collections waited in its first
# allocation for minutes, and ten beside one taking the lock in a loop
# waited more than a minute.
# A spinner that sees no release in 128 turns counts itself on the lock's
# word now, and a free lock with one counted is its first; a collection
# gives the core away once it has released the threads it stopped, which
# was nearly all the time they had. The controls below check those three
# invariants directly rather than killing a deliberately hung process.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    step "stress: one-core starts beside a collector and a lock taker, timings measured"
    cat > starve.iyi <<'IYI'
@[Unsafe("the one-core exercise pins its process with the Windows affinity API")]
module starve

import std/text

lib CorePin
  fun SetProcessAffinityMask(process : Void*, mask : UInt64) : Int32
end

class Flag
  getter stop : Atomic(Int64)
  getter turns : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
    @turns = Atomic(Int64).new(0_i64)
  end
end

# Five threads started and joined one after another beside a thread that
# collects in a loop, or takes the runtime lock in one and holds it for
# 2,000 increments a turn; answers the nanoseconds the five took.
def beside(collect : Bool) : UInt64
  flag = Flag.new
  busy = IyiThread.start do
    while flag.stop.get == 0_i64
      if collect
        IyiMark.collect
      else
        IyiRuntimeLock.lock
        held = 0
        while held < 2000
          flag.turns.add(1_i64)
          held = held + 1
        end
        IyiRuntimeLock.unlock
      end
    end
    nil
  end
  started = IyiMark.now_ns
  5.times { IyiThread.start { nil }.join }
  took = IyiMark.now_ns - started
  flag.stop.set(1_i64)
  busy.join
  took
end

if CorePin.SetProcessAffinityMask(::LibC.GetCurrentProcess, 1_u64.unsafe_shl(Program.args[0].to_i.to_u64)) == 0_i32 || IyiThread.core_count != 1_u64
  print "SETUP: affinity: the process could not be held to one allowed core\n"
  __iyi_exit(76)
end

took = beside(true)
puts "five threads started and joined beside a thread collecting in a loop in #{took // 1000000_u64} ms (measurement only)"
took = beside(false)
puts "five threads started and joined beside a thread taking the runtime lock in a loop in #{took // 1000000_u64} ms (measurement only)"
IYI
    # Unlike GNU timeout on MSYS, end_process ends only this native child.
    # A stuck child's wait is bounded even if Windows cannot terminate it.
    win_native() {
      local limit="$1" child deadline
      shift 2
      "$@" &
      child=$!
      deadline=$((SECONDS + limit))
      while kill -0 "$child" 2>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then
          end_bounded "$child" || return 76
          return 124
        fi
        sleep 0.1
      done
      wait "$child"
    }
    if ! "$IYI" build --release starve.iyi -o starve > build-starve.log 2>&1; then
      echo "SETUP: fairness: the one-core measurement did not build"; cat build-starve.log; exit 76
    fi
    win_native 120 "the one-core check" ./starve "$AFFINITY_FIRST" > starve-raw.txt 2>&1
    code=$?; check_bound "$code" healthy "run 1"
    if [ "$code" -eq 76 ]; then cat starve-raw.txt; exit 76; fi
    tr -d '\r' < starve-raw.txt > starve.txt
    if [ "$code" -ne 0 ] || [ "$(grep -c ' (measurement only)$' starve.txt)" -ne 2 ]; then
      echo "FAIL: ${current_step}: run 1 did not finish normally (exit $code)"; cat starve.txt; exit 1
    fi
    sed 's/^/  /' starve.txt

    # Both copies use the real runtime lock and the same rendezvous hooks.
    # The owner cannot unlock until the other thread's 128th lock turn;
    # the waiter cannot proceed until the owner's next look is observed.
    # Each collection then stops a registered thread actually waiting on
    # that lock, and records the release, unlock and yield in order.
    cat > fairness.iyi <<'IYI'
@[Unsafe("the copy-only witnesses are atomic words outside the collected heap")]
module fairness

lib CorePin
  fun SetProcessAffinityMask(process : Void*, mask : UInt64) : Int32
end

def priority : Nil
  thread = ::LibC.GetCurrentThread
  if ::LibC.SetThreadPriority(thread, 2_i32) == 0_i32 ||
     ::LibC.SetThreadPriorityBoost(thread, 1_i32) == 0_i32 ||
     ::LibC.GetThreadPriority(thread) != 2_i32
    IyiThread.fair_setup("SETUP: fairness: the threads could not be given equal priority\n")
  end
end

def await_word(slot : UInt64, value : UInt64, message : String) : Nil
  deadline = IyiMark.now_ns &+ 20000000000_u64
  while IyiThread.fair_get(slot) != value
    IyiThread.fair_setup(message) if IyiMark.now_ns >= deadline
    IyiThread.yield_cpu
  end
end

def check_collection(stage : UInt64) : Nil
  explicit = stage == 2_u64
  if IyiThread.fair_get(IyiThread::IYI_FAIR_WAIT) != stage
    IyiThread.fair_setup(explicit ? "SETUP: fairness: the explicit collection did not stage its waiter\n" : "SETUP: fairness: the budget collection did not stage its waiter\n")
  end
  if IyiThread.fair_get(IyiThread::IYI_FAIR_SUSPENDED) != stage
    IyiThread.fair_setup(explicit ? "SETUP: fairness: the explicit collection did not suspend its waiter\n" : "SETUP: fairness: the budget collection did not suspend its waiter\n")
  end
  if IyiThread.fair_get(IyiThread::IYI_FAIR_RESUMED) != stage || IyiThread.fair_get(IyiThread::IYI_FAIR_RELEASE) == 0_u64
    IyiThread.fair_setup(explicit ? "SETUP: fairness: the explicit collection did not release its waiter\n" : "SETUP: fairness: the budget collection did not release its waiter\n")
  end
  released = IyiThread.fair_get(IyiThread::IYI_FAIR_RELEASE)
  unlocked = IyiThread.fair_get(IyiThread::IYI_FAIR_UNLOCK)
  yielded = IyiThread.fair_get(IyiThread::IYI_FAIR_YIELD)
  if unlocked == 0_u64
    IyiThread.fair_setup(explicit ? "SETUP: fairness: the explicit collection did not unlock after release\n" : "SETUP: fairness: the budget collection did not unlock after release\n")
  end
  if yielded == 0_u64 || released >= unlocked || unlocked >= yielded
    message = explicit ? "FAIL: fairness: the explicit collection did not yield after releasing its waiter and unlocking\n" : "FAIL: fairness: the budget collection did not yield after releasing its waiter and unlocking\n"
    __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
    __iyi_exit(1)
  end
end

if CorePin.SetProcessAffinityMask(::LibC.GetCurrentProcess, 1_u64.unsafe_shl(Program.args[0].to_i.to_u64)) == 0_i32 || IyiThread.core_count != 1_u64
  print "SETUP: fairness: the process could not be held to one allowed core\n"
  __iyi_exit(76)
end
IyiMark.auto = false
IyiMark.workers = 0_u64
IyiThread.fair_init
priority
worker = IyiThread.start do
  priority
  IyiThread.fair_set(IyiThread::IYI_FAIR_WORKER, IyiThread.current_line)
  IyiThread.fair_set(IyiThread::IYI_FAIR_READY, 1_u64)
  await_word(IyiThread::IYI_FAIR_COMMAND, 1_u64, "SETUP: fairness: the waiter was not commanded to enter the handoff\n")
  IyiRuntimeLock.lock
  IyiRuntimeLock.unlock
  IyiThread.fair_set(IyiThread::IYI_FAIR_DONE, 1_u64)
  await_word(IyiThread::IYI_FAIR_COMMAND, 2_u64, "SETUP: fairness: the waiter was not commanded to enter the explicit collection\n")
  IyiRuntimeLock.lock
  IyiRuntimeLock.unlock
  IyiThread.fair_set(IyiThread::IYI_FAIR_DONE, 2_u64)
  await_word(IyiThread::IYI_FAIR_COMMAND, 3_u64, "SETUP: fairness: the waiter was not commanded to enter the budget collection\n")
  IyiRuntimeLock.lock
  IyiRuntimeLock.unlock
  IyiThread.fair_set(IyiThread::IYI_FAIR_DONE, 3_u64)
  await_word(IyiThread::IYI_FAIR_COMMAND, 4_u64, "SETUP: fairness: the budget waiter was not released after the yield witness\n")
  nil
end
IyiThread.fair_set(IyiThread::IYI_FAIR_OWNER, IyiThread.current_line)
await_word(IyiThread::IYI_FAIR_READY, 1_u64, "SETUP: fairness: the registered waiter did not start\n")
if IyiThread.fair_get(IyiThread::IYI_FAIR_OWNER) == 0_u64 || IyiThread.fair_get(IyiThread::IYI_FAIR_WORKER) == 0_u64
  IyiThread.fair_setup("SETUP: fairness: the owner or waiter has no registered line\n")
end

IyiRuntimeLock.lock
IyiThread.fair_set(IyiThread::IYI_FAIR_STAGE, 1_u64)
IyiThread.fair_set(IyiThread::IYI_FAIR_COMMAND, 1_u64)
deadline = IyiMark.now_ns &+ 20000000000_u64
while IyiThread.fair_get(IyiThread::IYI_FAIR_TURN) == 0_u64
  IyiThread.fair_setup("SETUP: fairness: the waiter did not reach turn 128 while the owner held the lock\n") if IyiMark.now_ns >= deadline
  IyiThread.yield_cpu
end
IyiThread.fair_set(IyiThread::IYI_FAIR_ARMED, 1_u64)
IyiRuntimeLock.unlock
IyiRuntimeLock.lock
IyiRuntimeLock.unlock
if IyiThread.fair_get(IyiThread::IYI_FAIR_LOOK) == 2_u64
  print "FAIL: fairness: the owner retook the lock at its first look ahead of the waiter\n"
  __iyi_exit(1)
end
if IyiThread.fair_get(IyiThread::IYI_FAIR_LOOK) != 1_u64
  IyiThread.fair_setup("SETUP: fairness: the owner's first look was not observed\n")
end
if IyiThread.fair_get(IyiThread::IYI_FAIR_TURN) != 2_u64
  IyiThread.fair_setup("SETUP: fairness: the witnessed waiter was not counted at turn 128\n")
end
if IyiThread.fair_get(IyiThread::IYI_FAIR_TAKEN) != 1_u64
  IyiThread.fair_setup("SETUP: fairness: the counted waiter did not take the lock\n")
end
await_word(IyiThread::IYI_FAIR_DONE, 1_u64, "SETUP: fairness: the handoff waiter did not unlock\n")

IyiThread.fair_arm_collection(2_u64)
IyiMark.collect
check_collection(2_u64)
await_word(IyiThread::IYI_FAIR_DONE, 2_u64, "SETUP: fairness: the explicit collection waiter did not finish\n")
IyiHeap.allocated_word.value.set(IyiMark.budget)
IyiThread.fair_arm_collection(3_u64)
IyiMark.collect_if_due
check_collection(3_u64)
await_word(IyiThread::IYI_FAIR_DONE, 3_u64, "SETUP: fairness: the budget collection waiter did not finish\n")
IyiThread.fair_set(IyiThread::IYI_FAIR_STAGE, 0_u64)
IyiThread.fair_set(IyiThread::IYI_FAIR_COMMAND, 4_u64)
worker.join
puts "fairness: the owner deferred to its counted waiter; explicit and budget collections released, unlocked, and yielded"
IYI
    cat > fairness.part <<'IYI'
    # A private mapping avoids changing the runtime control page. Every
    # word read by both threads, including the rendezvous, is atomic.
    IYI_FAIR_OWNER     = 0_u64
    IYI_FAIR_WORKER    = 8_u64
    IYI_FAIR_READY     = 16_u64
    IYI_FAIR_COMMAND   = 24_u64
    IYI_FAIR_STAGE     = 32_u64
    IYI_FAIR_TURN      = 40_u64
    IYI_FAIR_LOOK      = 48_u64
    IYI_FAIR_TAKEN     = 56_u64
    IYI_FAIR_DONE      = 64_u64
    IYI_FAIR_WAIT      = 72_u64
    IYI_FAIR_SUSPENDED = 80_u64
    IYI_FAIR_RESUMED   = 88_u64
    IYI_FAIR_RELEASE   = 96_u64
    IYI_FAIR_UNLOCK    = 104_u64
    IYI_FAIR_YIELD     = 112_u64
    IYI_FAIR_SEQUENCE  = 120_u64
    IYI_FAIR_ARMED     = 128_u64
    @@fair_page : UInt64 = 0_u64

    def self.fair_setup(message : String) : Nil
      __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
      __iyi_exit(76)
    end

    def self.fair_init : Nil
      @@fair_page = __iyi_mmap(4096_u64).address
      fair_setup("SETUP: fairness: the witness page could not be mapped\n") if @@fair_page == 0_u64
    end

    def self.fair_get(slot : UInt64) : UInt64
      word(@@fair_page + slot).value.get
    end

    def self.fair_set(slot : UInt64, value : UInt64) : Nil
      word(@@fair_page + slot).value.set(value)
    end

    def self.fair_stamp(slot : UInt64) : Nil
      value = word(@@fair_page + IYI_FAIR_SEQUENCE).value.add(1_u64) + 1_u64
      fair_set(slot, value)
    end

    def self.fair_arm_collection(stage : UInt64) : Nil
      fair_set(IYI_FAIR_WAIT, 0_u64)
      fair_set(IYI_FAIR_SUSPENDED, 0_u64)
      fair_set(IYI_FAIR_RESUMED, 0_u64)
      fair_set(IYI_FAIR_RELEASE, 0_u64)
      fair_set(IYI_FAIR_UNLOCK, 0_u64)
      fair_set(IYI_FAIR_YIELD, 0_u64)
      fair_set(IYI_FAIR_SEQUENCE, 0_u64)
      fair_set(IYI_FAIR_STAGE, stage)
    end

    def self.fair_first_turn(seen : UInt64) : Nil
      return if @@fair_page == 0_u64
      stage = fair_get(IYI_FAIR_STAGE)
      if stage == 1_u64 && @@line == fair_get(IYI_FAIR_OWNER) && fair_get(IYI_FAIR_ARMED) == 1_u64 && fair_get(IYI_FAIR_LOOK) == 0_u64
        if (seen & 1_u64) != 0_u64 || (seen & 0xFFFE_u64) == 0_u64
          fair_setup("SETUP: fairness: the owner's first look did not see the free counted lock\n")
        end
        fair_set(IYI_FAIR_LOOK, 1_u64)
        deadline = IyiMark.now_ns &+ 20000000000_u64
        while fair_get(IYI_FAIR_TAKEN) == 0_u64
          fair_setup("SETUP: fairness: the waiter did not acquire after the owner's refusal\n") if IyiMark.now_ns >= deadline
          yield_cpu
        end
      elsif (stage == 2_u64 || stage == 3_u64) && @@line == fair_get(IYI_FAIR_WORKER) && (seen & 1_u64) != 0_u64
        fair_set(IYI_FAIR_WAIT, stage)
      end
    end

    def self.fair_turn128(turn : Int64, counted : Bool) : Nil
      return if @@fair_page == 0_u64 || fair_get(IYI_FAIR_STAGE) != 1_u64 || @@line != fair_get(IYI_FAIR_WORKER) || turn != 128_i64
      fair_set(IYI_FAIR_TURN, counted ? 2_u64 : 1_u64)
      deadline = IyiMark.now_ns &+ 20000000000_u64
      while fair_get(IYI_FAIR_LOOK) == 0_u64
        fair_setup("SETUP: fairness: the owner did not look after the waiter's 128th turn\n") if IyiMark.now_ns >= deadline
        yield_cpu
      end
    end

    def self.fair_taken(spins : Int64) : Nil
      return if @@fair_page == 0_u64 || fair_get(IYI_FAIR_STAGE) != 1_u64 || fair_get(IYI_FAIR_ARMED) == 0_u64
      if @@line == fair_get(IYI_FAIR_WORKER)
        fair_set(IYI_FAIR_TAKEN, 1_u64)
      elsif @@line == fair_get(IYI_FAIR_OWNER) && fair_get(IYI_FAIR_LOOK) == 0_u64
        fair_setup("SETUP: fairness: the owner's first lock turn was not observed\n") if spins != 0_i64
        fair_set(IYI_FAIR_LOOK, 2_u64)
      end
    end

    def self.fair_before_stop : Nil
      return if @@fair_page == 0_u64
      stage = fair_get(IYI_FAIR_STAGE)
      return unless (stage == 2_u64 || stage == 3_u64) && @@line == fair_get(IYI_FAIR_OWNER)
      fair_set(IYI_FAIR_COMMAND, stage)
      deadline = IyiMark.now_ns &+ 20000000000_u64
      while fair_get(IYI_FAIR_WAIT) != stage
        if IyiMark.now_ns >= deadline
          fair_setup(stage == 2_u64 ? "SETUP: fairness: the explicit collection waiter did not enter the held lock\n" : "SETUP: fairness: the budget collection waiter did not enter the held lock\n")
        end
        yield_cpu
      end
    end

    def self.fair_suspend(line : UInt64, result : Int32) : Nil
      return if @@fair_page == 0_u64
      stage = fair_get(IYI_FAIR_STAGE)
      return unless (stage == 2_u64 || stage == 3_u64) && line == fair_get(IYI_FAIR_WORKER) && fair_get(IYI_FAIR_WAIT) == stage
      fair_setup("SETUP: fairness: SuspendThread did not suspend the collection waiter\n") if result != 0_i32
      fair_set(IYI_FAIR_SUSPENDED, stage)
    end

    def self.fair_resume(line : UInt64, result : Int32) : Nil
      return if @@fair_page == 0_u64
      stage = fair_get(IYI_FAIR_STAGE)
      return unless (stage == 2_u64 || stage == 3_u64) && line == fair_get(IYI_FAIR_WORKER) && fair_get(IYI_FAIR_WAIT) == stage
      fair_setup("SETUP: fairness: ResumeThread did not release the collection waiter\n") if result != 1_i32 || fair_get(IYI_FAIR_SUSPENDED) != stage
      fair_set(IYI_FAIR_RESUMED, stage)
    end

    def self.fair_release(others : Int64) : Nil
      return if @@fair_page == 0_u64
      stage = fair_get(IYI_FAIR_STAGE)
      return unless (stage == 2_u64 || stage == 3_u64) && @@line == fair_get(IYI_FAIR_OWNER)
      if others <= 0_i64 || fair_get(IYI_FAIR_WAIT) != stage || fair_get(IYI_FAIR_RESUMED) != stage
        fair_setup("SETUP: fairness: the collection release did not include its waiting thread\n")
      end
      fair_stamp(IYI_FAIR_RELEASE)
    end

    def self.fair_unlock : Nil
      return if @@fair_page == 0_u64
      stage = fair_get(IYI_FAIR_STAGE)
      if (stage == 2_u64 || stage == 3_u64) && @@line == fair_get(IYI_FAIR_OWNER) && fair_get(IYI_FAIR_RELEASE) != 0_u64 && fair_get(IYI_FAIR_UNLOCK) == 0_u64
        fair_stamp(IYI_FAIR_UNLOCK)
      end
    end

    def self.fair_yield : Nil
      return if @@fair_page == 0_u64
      stage = fair_get(IYI_FAIR_STAGE)
      fair_stamp(IYI_FAIR_YIELD) if (stage == 2_u64 || stage == 3_u64) && @@line == fair_get(IYI_FAIR_OWNER)
    end
IYI
    fair_thread() {
      awk -v mode="$1" -v part=fairness.part '
        /^    # ── Roots/ {
          while ((got = getline text < part) > 0) { print text; part_lines++ }
          if (got < 0) bad = 1
          close(part)
          roots++
        }
        /^    def self\.lock_turn\(word : Pointer\(Atomic\(UInt64\)\), seen : UInt64, spins : Int64, since : UInt64\) : Tuple\(Int64, UInt64\)$/ { in_turn = 1; turns++ }
        in_turn && /^    end$/ { in_turn = 0 }
        in_turn && /^      if turn == 1$/ { print; print "        fair_first_turn(seen)"; first++; next }
        in_turn && /^        if !counted && released == since$/ {
          count_anchor++
          if (mode == "uncounted") { print "        if false"; removed++; next }
        }
        in_turn && /^        yield_cpu if turn >= YIELD_AFTER$/ { print "        fair_turn128(turn, counted)"; print; turn128++; next }
        /^      private def self\.suspend_others\(line : UInt64\) : Int64$/ { in_suspend = 1; suspends++ }
        in_suspend && /^      end$/ { in_suspend = 0 }
        in_suspend && /^          LibC\.SuspendThread\(Pointer\(Void\)\.new\(IyiHeap\.read64\(cursor \+ IYI_TL_HANDLE\)\)\) if cursor != line$/ {
          print "          fair_suspend(cursor, LibC.SuspendThread(Pointer(Void).new(IyiHeap.read64(cursor + IYI_TL_HANDLE)))) if cursor != line"
          suspend_call++; next
        }
        /^      private def self\.resume_suspended\(line : UInt64\) : Nil$/ { in_resume = 1; resumes++ }
        in_resume && /^      end$/ { in_resume = 0 }
        in_resume && /^            LibC\.ResumeThread\(Pointer\(Void\)\.new\(IyiHeap\.read64\(cursor \+ IYI_TL_HANDLE\)\)\)$/ {
          print "            fair_resume(cursor, LibC.ResumeThread(Pointer(Void).new(IyiHeap.read64(cursor + IYI_TL_HANDLE))))"
          resume_call++; next
        }
        /^    def self\.resume_others\(others : Int64\) : Nil$/ { in_release = 1; releases++ }
        in_release && /^    end$/ { in_release = 0 }
        in_release && /^        @@owed = @@deferred$/ { print; print "        fair_release(others)"; release_call++; next }
        /^    def self\.yield_to_stopped : Nil$/ { in_yield = 1; yields++ }
        in_yield && /^    end$/ { in_yield = 0 }
        in_yield && /^      yield_cpu if @@count > 1_i64$/ {
          print "      if @@count > 1_i64"
          print "        yield_cpu"
          print "        fair_yield"
          print "      end"
          yield_call++; next
        }
        { print }
        END {
          if (bad || part_lines == 0 || roots != 1 || turns != 1 || first != 1 || count_anchor != 1 || turn128 != 1 ||
              suspends != 1 || suspend_call != 1 || resumes != 1 || resume_call != 1 ||
              releases != 1 || release_call != 1 || yields != 1 || yield_call != 1 ||
              (mode == "uncounted" && removed != 1) || (mode != "uncounted" && removed != 0)) exit 3
        }
      ' "$REPO/src/iyi/thread.iyi" > "$2"
    }
    fair_prelude() {
      awk -v mode="$1" '
        /^class IyiRuntimeLock$/ { in_runtime = 1; runtime++ }
        in_runtime && /^end$/ { in_runtime = 0 }
        in_runtime && /^  def self\.lock : Nil$/ { in_lock = 1; locks++ }
        in_lock && /^  end$/ { in_lock = 0 }
        in_lock && /^    \{% if !flag\?\(:gc_none\).*IyiThread\.lock_taken/ { print "    IyiThread.fair_taken(spins)"; print; taken++; next }
        /^      def self\.collect_locked\(eager : Bool\) : Nil$/ { in_collect = 1; collections++ }
        in_collect && /^      end$/ { in_collect = 0 }
        in_collect && /^          others = IyiThread\.stop_others$/ { print "          IyiThread.fair_before_stop"; print; stop++; next }
        /^      def self\.unlock_released : Nil$/ { in_unlock = 1; unlocks++ }
        in_unlock && /^      end$/ { in_unlock = 0 }
        in_unlock && /^        IyiRuntimeLock\.unlock$/ { print; print "        IyiThread.fair_unlock"; unlock_call++; next }
        /^      def self\.collect_if_due : Nil$/ { in_budget = 1; budgets++ }
        in_budget && /^      end$/ { in_budget = 0 }
        in_budget && /^          IyiThread\.yield_to_stopped$/ {
          budget_yield++
          if (mode == "budget") { removed++; next }
        }
        /^      def self\.collect_cleared : Nil$/ { in_explicit = 1; explicits++ }
        in_explicit && /^      end$/ { in_explicit = 0 }
        in_explicit && /^          IyiThread\.yield_to_stopped$/ {
          explicit_yield++
          if (mode == "explicit") { removed++; next }
        }
        { print }
        END {
          if (runtime != 1 || locks != 1 || taken != 1 || collections != 1 || stop != 1 ||
              unlocks != 1 || unlock_call != 1 || budgets != 1 || budget_yield != 1 ||
              explicits != 1 || explicit_yield != 1 ||
              ((mode == "explicit" || mode == "budget") && removed != 1) ||
              ((mode != "explicit" && mode != "budget") && removed != 0)) exit 3
        }
      ' "$REPO/src/iyi/prelude.iyi" > "$2"
    }
    for mode in control uncounted explicit budget; do
      case "$mode" in
        control)
          step "the counted-waiter handoff and collection-yield control"
          expected="fairness: the owner deferred to its counted waiter; explicit and budget collections released, unlocked, and yielded"
          expected_code=0
          ;;
        uncounted)
          step "failure proof: an uncounted waiter loses the first lock look"
          expected="FAIL: fairness: the owner retook the lock at its first look ahead of the waiter"
          expected_code=1
          ;;
        explicit)
          step "failure proof: an explicit collection omits its yield"
          expected="FAIL: fairness: the explicit collection did not yield after releasing its waiter and unlocking"
          expected_code=1
          ;;
        budget)
          step "failure proof: a budget collection omits its yield"
          expected="FAIL: fairness: the budget collection did not yield after releasing its waiter and unlocking"
          expected_code=1
          ;;
      esac
      mkdir -p "fair-$mode/iyi"
      cp "$REPO"/src/iyi/*.iyi "fair-$mode/iyi/"
      fair_thread "$mode" "fair-$mode/iyi/thread.iyi" || { echo "SETUP: fairness: the $mode thread-copy anchors changed"; exit 76; }
      fair_prelude "$mode" "fair-$mode/iyi/prelude.iyi" || { echo "SETUP: fairness: the $mode prelude-copy anchors changed"; exit 76; }
      if ! IYI_PATH="$WORK/fair-$mode${PSEP}$REPO/src" "$IYI" build --release fairness.iyi -Dfairness_force -o "fair-$mode-run" > "build-fair-$mode.log" 2>&1; then
        echo "SETUP: fairness: the $mode proof did not build"; cat "build-fair-$mode.log"; exit 76
      fi
      win_native 60 "fairness: the $mode proof" "./fair-$mode-run" "$AFFINITY_FIRST" > "fair-$mode-raw.txt" 2>&1
      code=$?; check_bound "$code" forced "$mode" "fair-$mode-raw.txt"
      if [ "$code" -eq 76 ]; then cat "fair-$mode-raw.txt"; exit 76; fi
      tr -d '\r' < "fair-$mode-raw.txt" > "fair-$mode.txt"
      fail_lines="$(grep -c '^FAIL:' "fair-$mode.txt")"
      expected_fails=0
      [ "$expected_code" -eq 1 ] && expected_fails=1
      if [ "$code" -ne "$expected_code" ] || [ "$fail_lines" -ne "$expected_fails" ] || ! grep -qxF "$expected" "fair-$mode.txt"; then
        if [ "$mode" = control ]; then
          pair_mismatch "$code" "fair-$mode.txt" control
        fi
        pair_mismatch "$code" "fair-$mode.txt" mutant 0 'fairness: the owner deferred to its counted waiter; explicit and budget collections released, unlocked, and yielded'
      fi
      printf '  exits %s at "%s"\n' "$code" "$expected"
    done
    ;;
esac

# ── 4d. Windows: the stopping thread above a burst on its processor ──────
# A stop on Windows is the stopping thread's own loop of `SuspendThread`
# and `ResumeThread` calls, and nothing else moves until it ends: where a
# thread above it takes its processor, the world stays stopped until that
# thread lets go. In a real server on a saturated machine (iyiturkiye,
# Windows 11, 12 logical processors, the user's machine) single calls in
# that loop took 148 to 214 ms. The stop raises its thread to Windows'
# highest priority now (`IyiThread.raise_stopper`).
#
# The stopping thread shares a processor with a separate, higher-priority
# burner. Stop and lock-wait durations are measurements only. The forced
# witness records whether priority was restored before the runtime unlock;
# the control and mutant differ in that ordering, not in a timing limit.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    if [ "$AFFINITY_COUNT" -lt 2 ]; then
      echo "SETUP: burst: the process has fewer than two allowed processors" >&2
      exit 76
    else
    cat > burst.iyi <<'IYI'
@[Unsafe("the burner pins itself to one processor and raises its priority by calling Windows' thread functions through a lib")]
module burst

import std/file::{File}

lib Placing
  fun SetThreadAffinityMask(thread : Void*, mask : UInt64) : UInt64
  fun SetThreadPriority(thread : Void*, priority : Int32) : Int32
  fun Sleep(milliseconds : UInt32) : Nil
end

# On the processor the first argument numbers, one level above normal and
# with no boost, computing the second argument's milliseconds at a time
# and sleeping a millisecond between, until a file named burst-stop
# appears, or 300 s.
processor = Program.args[0].to_i
length = Program.args[1].to_i.to_u64 * 1000000_u64
Placing.SetThreadAffinityMask(::LibC.GetCurrentThread, 1_u64.unsafe_shl(processor.to_u64))
Placing.SetThreadPriority(::LibC.GetCurrentThread, 1_i32)
::LibC.SetThreadPriorityBoost(::LibC.GetCurrentThread, 1_i32)
File.touch("burst-ready")
bursts = 0
deadline = IyiMark.now_ns + 300000000000_u64
while !File.file?("burst-stop") && IyiMark.now_ns < deadline
  ends = IyiMark.now_ns + length
  while IyiMark.now_ns < ends
  end
  bursts = bursts + 1
  Placing.Sleep(1_u32)
end
if !File.file?("burst-stop")
  print "SETUP: burst: the burner reached its watchdog before it was stopped\n"
  __iyi_exit(76)
end
puts "bursts: #{bursts}"
IYI
    cat > stopping.iyi <<'IYI'
@[Unsafe("each thread pins itself to its processors by calling Windows' SetThreadAffinityMask through a lib")]
module stopping

class Flag
  getter stop : Atomic(Int64)
  getter held : Atomic(Int64)
  getter waited : Atomic(Int64)
  getter waits : Atomic(Int64)
  getter turns : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
    @held = Atomic(Int64).new(0_i64)
    @waited = Atomic(Int64).new(0_i64)
    @waits = Atomic(Int64).new(0_i64)
    @turns = Atomic(Int64).new(0_i64)
  end
end

lib Placing
  fun SetThreadAffinityMask(thread : Void*, mask : UInt64) : UInt64
end

def fail(message : String) : Nil
  print "FAIL: #{message}\n"
  __iyi_exit(1)
end

# Computes, allocating nothing, on the processors *mask* names.
def compute(flag : Flag, mask : UInt64) : Nil
  Placing.SetThreadAffinityMask(::LibC.GetCurrentThread, mask)
  flag.held.add(1_i64)
  x = 0_i64
  while flag.stop.get == 0_i64
    x = x &+ 1
  end
end

# Takes the runtime lock in a loop on the processors *mask* names,
# computing 20 us between turns, and keeps its longest wait and how many
# waits passed *bound*.
def taker(flag : Flag, mask : UInt64, bound : UInt64) : Nil
  Placing.SetThreadAffinityMask(::LibC.GetCurrentThread, mask)
  flag.held.add(1_i64)
  while flag.stop.get == 0_i64
    asked = IyiMark.now_ns
    IyiRuntimeLock.lock
    took = IyiMark.now_ns - asked
    IyiRuntimeLock.unlock
    flag.waits.add(1_i64) if took > bound
    flag.turns.add(1_i64)
    flag.waited.set(took.to_i64) if took.to_i64 > flag.waited.get
    ends = IyiMark.now_ns + 20000_u64
    while IyiMark.now_ns < ends
    end
  end
end

# The processor the first argument numbers is the stopping thread's, and
# the burst's; the threads it stops run on every other one. The second
# and third are the bounds on a stop and on a wait for the lock, in ms.
processor = Program.args[0].to_i
bound = Program.args[1].to_i.to_u64 * 1000000_u64
lock_bound = Program.args[2].to_i.to_u64 * 1000000_u64
shared = 1_u64.unsafe_shl(processor.to_u64)
mask = 0_u64
system = 0_u64
::LibC.GetProcessAffinityMask(::LibC.GetCurrentProcess, pointerof(mask), pointerof(system))
elsewhere = mask ^ shared
# As many threads that compute as the other processors hold beside the
# taker and one left idle, up to four: a taker that shares a processor
# with one waits out that thread's quantum, a lock it never asked for. On
# windows-2025's 4-processor runners four computed on the 3 processors
# left with the taker, and five runs of five had 2 to 11 waits past 50
# ms, the longest 102 to 611 ms (debug job 126403714389); CI run
# 41778179340 had 17, the longest 303 ms. Two beside the taker, filling
# the three, still left the taker waiting out the runner's own threads:
# its longest wait 0.2 to 41 ms in 45 runs on three runners, against 0.2
# to 1.6 ms with one beside it and a processor idle (debug run
# 41812323963). Windows 11, 12 logical processors (the user's machine),
# leaves 11 for the five.
others = 0
bits = elsewhere
while bits != 0_u64
  others = others + 1 if bits & 1_u64 != 0_u64
  bits = bits.unsafe_shr(1_u64)
end
computes = others - 2
computes = 4 if computes > 4
computes = 0 if computes < 0
IyiMark.workers = 0_u64
{% if flag?(:burst_force) %}
# Initialize the copy-only record before any thread can read it.
IyiThread.burst_probe_init
{% end %}
flag = Flag.new
threads = [] of IyiThread
computes.times { threads << IyiThread.start { compute(flag, elsewhere) } }
threads << IyiThread.start { taker(flag, elsewhere, lock_bound) }
while flag.held.get < computes.to_i64 + 1_i64
  IyiThread.yield_cpu
end
Placing.SetThreadAffinityMask(::LibC.GetCurrentThread, shared)
::LibC.SetThreadPriorityBoost(::LibC.GetCurrentThread, 1_i32)
collections = 0
over = 0
longest = 0_u64
stop_ns = IyiThread.stop_ns
started = IyiMark.now_ns
watch = started + 60000000000_u64
# The collections follow the taker's 100th acknowledged lock attempt, a
# happens-before word (the turns counter), not a clock window. The healthy
# verdict is the structural counter below and that the taker reached 100
# turns within 60 s. Stop and wait timings are measurements only.
while flag.turns.get < 100_i64
  if IyiMark.now_ns >= watch
    print "SETUP: lock: fewer than 100 turns on the runtime lock within 60 s\n"
    __iyi_exit(76)
  end
  IyiThread.yield_cpu
end
20.times do
  {% if flag?(:burst_force) %}
  seen_before = IyiThread.burst_probe_seen
  IyiThread.burst_probe_begin
  {% end %}
  before = IyiThread.stop_ns
  IyiMark.collect
  {% if flag?(:burst_force) %}
  IyiThread.burst_probe_end
  if IyiThread.burst_probe_seen == seen_before
    print "SETUP: lock: a collection did not restore its stopper priority\n"
    __iyi_exit(76)
  end
  {% end %}
  took = IyiThread.stop_ns - before
  longest = took if took > longest
  over = over + 1 if took > bound
  collections = collections + 1
end
share = (IyiThread.stop_ns - stop_ns) * 100_u64 // (IyiMark.now_ns - started)
flag.stop.set(1_i64)
threads.each { |thread| thread.join }
# Stop and lock-wait durations above the supplied thresholds are measured,
# never verdicts. Both copies observe the same lower_stopper body and the
# actual runtime-unlock event on the collecting thread. The mutant moves
# the restore before that unlock; the control keeps the original order.
{% if flag?(:burst_force) %}
seen = IyiThread.burst_probe_seen
unlocked = IyiThread.burst_probe_unlocked
if seen == 0_u64
  print "SETUP: lock: no priority restore was recorded\n"
  __iyi_exit(76)
end
fail("lock: the priority was restored while the stopper still held the runtime lock") if unlocked == 0_u64
puts "lock: restore recorded after the runtime lock was released"
{% end %}
puts "stop: #{collections} stops of #{threads.size} threads beside a burst on the stopping thread's processor, #{share}% of the run in stops, #{over} past #{bound // 1000000_u64} ms, the longest #{longest // 1000_u64} us"
puts "lock: #{flag.waits.get} waits for the runtime lock beside #{collections} collections took past #{lock_bound // 1000000_u64} ms, the longest #{flag.waited.get // 1000_i64} us"
IYI
    shared="$AFFINITY_LAST"
    # `./$1` beside the burst, its output in `$2`.
    beside_burst() {
      local burst_pid deadline
      rm -f burst-ready burst-stop
      MSYS_NO_PATHCONV=1 ./burst.exe "$shared" 100 > burst.txt 2>&1 &
      burst_pid=$!
      deadline=$((SECONDS + 10))
      while [ ! -f burst-ready ]; do
        if ! kill -0 "$burst_pid" 2>/dev/null || [ "$SECONDS" -ge "$deadline" ]; then
          if kill -0 "$burst_pid" 2>/dev/null; then end_bounded "$burst_pid" || exit 76; fi
          wait "$burst_pid" 2>/dev/null || true
          echo "SETUP: burst: owned burner did not become ready (pid $burst_pid)" >&2
          exit 76
        fi
        sleep 0.1
      done
      timeout 120 "./$1" "$shared" 20 50 > "$2" 2>&1
      BURST_STATUS=$?
      touch burst-stop
      deadline=$((SECONDS + 10))
      while kill -0 "$burst_pid" 2>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then
          end_bounded "$burst_pid" || exit 76
          wait "$burst_pid" 2>/dev/null || true
          echo "SETUP: burst: owned burner did not stop before its watchdog (pid $burst_pid)" >&2
          exit 76
        fi
        sleep 0.1
      done
      if ! wait "$burst_pid" 2>/dev/null; then
        echo "SETUP: burst: owned burner exited unsuccessfully (pid $burst_pid)" >&2
        cat burst.txt >&2
        exit 76
      fi
      tr -d '\r' < burst.txt >> "$2"
      check_bound "$BURST_STATUS" forced "$1" "$2"
      if [ "$BURST_STATUS" -eq 76 ]; then
        if grep -q '^SETUP:' "$2"; then
          cat "$2"
        else
          echo "SETUP: ${current_step:-burst}: $1 exited 76 without a diagnostic"
        fi
        exit 76
      fi
    }
    cat > burst.part <<'IYI'
    # Both copies inspect the actual restore result and the collecting
    # thread's runtime-lock ownership at every armed priority restore.
    IYI_BURST_SEEN     = 384_u64
    IYI_BURST_EARLY    = 448_u64
    @[ThreadLocal]
    @@burst_probe_active : Bool = false
    @[ThreadLocal]
    @@burst_probe_holding : Bool = false

    def self.burst_probe_init : Nil
      page = control
      word(page + IYI_BURST_SEEN).value.set(0_u64)
      word(page + IYI_BURST_EARLY).value.set(0_u64)
    end

    def self.burst_probe_begin : Nil
      @@burst_probe_holding = false
      @@burst_probe_active = true
    end

    def self.burst_probe_lock : Nil
      @@burst_probe_holding = true if @@burst_probe_active
    end

    def self.burst_probe_unlock : Nil
      @@burst_probe_holding = false if @@burst_probe_active
    end

    def self.burst_probe_restore(expected : Int32, result : Int32) : Nil
      return unless @@burst_probe_active
      actual = LibC.GetThreadPriority(LibC.GetCurrentThread)
      if result == 0_i32 || actual == 2147483647_i32
        message = "SETUP: lock: restoring or querying stopper priority failed\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        __iyi_exit(76)
      end
      if actual != expected
        message = "FAIL: lock: the stopper priority was not restored\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        __iyi_exit(1)
      end
      page = control
      word(page + IYI_BURST_SEEN).value.add(1_u64)
      word(page + IYI_BURST_EARLY).value.add(1_u64) if @@burst_probe_holding
    end

    def self.burst_probe_end : Nil
      @@burst_probe_active = false
    end

    def self.burst_probe_seen : UInt64
      word(control + IYI_BURST_SEEN).value.get
    end

    def self.burst_probe_unlocked : UInt64
      word(control + IYI_BURST_EARLY).value.get == 0_u64 ? 1_u64 : 0_u64
    end
IYI
    burst_copy() {
      awk -v gate=burst.part -v mode="$1" '
        /^    # ── Roots/ { while ((getline line < gate) > 0) print line; roots++ }
        /^        LibC\.SetThreadPriority\(LibC\.GetCurrentThread, @@stopper_priority\)$/ {
          print "        restored = LibC.SetThreadPriority(LibC.GetCurrentThread, @@stopper_priority)"
          print "        IyiThread.burst_probe_restore(@@stopper_priority, restored)"
          observed++; next
        }
        mode == "forced" && /^        @@owed = @@deferred$/ {
          print
          print "        lower_stopper"
          moved++; next
        }
        { print }
        END { if (roots != 1 || observed != 1 || (mode == "forced" && moved != 1)) exit 3 }
      ' "$REPO/src/iyi/thread.iyi" > "$2"
    }
    burst_prelude() {
      awk -v mode="$1" '
        /^  def self\.lock : Nil$/ { in_lock = 1; lock_methods++ }
        in_lock && /^  end$/ { in_lock = 0 }
        in_lock && /^    \{% if !flag\?\(:gc_none\).*IyiThread\.lock_taken/ { print; print "    IyiThread.burst_probe_lock"; locked++; next }
        /^  def self\.unlock : Nil$/ { in_runtime_unlock = 1; runtime_unlocks++ }
        in_runtime_unlock && /^  end$/ { in_runtime_unlock = 0 }
        in_runtime_unlock && /^    \{% if flag\?\(:heap_verify\) %\}@@holding = false; word\.value\.add/ { print; print "    IyiThread.burst_probe_unlock"; released++; next }
        mode == "forced" && in_release && /^          IyiThread\.lower_stopper$/ { lower++; next }
        /^      def self\.unlock_released : Nil$/ { releases++; in_release = 1 }
        in_release && /^      end$/ { in_release = 0 }
        { print }
        END { if (lock_methods != 1 || locked != 1 || runtime_unlocks != 1 || released != 1 || releases != 1 || (mode == "forced" && lower != 1)) exit 3 }
      ' "$REPO/src/iyi/prelude.iyi" > "$2"
    }
    step "the stop beside a burst on the stopping thread's processor"
    if ! "$IYI" build --release burst.iyi -o burst > build-burst.log 2>&1; then
      echo "SETUP: ${current_step:-build}: burst did not build"; cat build-burst.log; exit 76
    fi
    mkdir -p burst-ctl/iyi
    cp "$REPO"/src/iyi/*.iyi burst-ctl/iyi/
    burst_copy control burst-ctl/iyi/thread.iyi || { echo "SETUP: lock: the control thread anchors changed"; exit 76; }
    burst_prelude control burst-ctl/iyi/prelude.iyi || { echo "SETUP: lock: the control prelude anchors changed"; exit 76; }
    if ! IYI_PATH="$WORK/burst-ctl${PSEP}$REPO/src" "$IYI" build --release stopping.iyi -Dburst_force -o stopping > build-stopping.log 2>&1; then
      echo "SETUP: ${current_step:-build}: stopping did not build"; cat build-stopping.log; exit 76
    fi
    beside_burst stopping stopping.txt
    if [ "$BURST_STATUS" -ne 0 ] || grep -q '^FAIL' stopping.txt || ! grep -qxF 'lock: restore recorded after the runtime lock was released' stopping.txt || ! grep -q '^stop:' stopping.txt || ! grep -qE '^lock: [0-9]+ waits for the runtime lock beside [0-9]+ collections took past 50 ms, the longest [0-9]+ us$' stopping.txt; then
      pair_mismatch "$BURST_STATUS" stopping.txt control
    fi
    sed 's/^/  /' stopping.txt

    step "failure proof: a priority put back inside the release holds the runtime lock through the burst"
    # The copy lowers the priority where the release ends, after its last
    # `ResumeThread`, where it was lowered before. The release waited there
    # for the resumed threads to count out, and this copy found its end by
    # that wait; the release waits for nobody now (`resume_others`) and
    # ends by leaving the count owed to the next stop, `@@owed`.
    mkdir -p inside/iyi
    cp "$REPO"/src/iyi/*.iyi inside/iyi/
    burst_copy forced inside/iyi/thread.iyi || { echo "SETUP: lock: the mutant thread anchors changed"; exit 76; }
    burst_prelude forced inside/iyi/prelude.iyi || { echo "SETUP: lock: the mutant prelude anchors changed"; exit 76; }
    if ! IYI_PATH="$WORK/inside${PSEP}$REPO/src" "$IYI" build --release stopping.iyi -Dburst_force -o stopping-inside > build-inside.log 2>&1; then
      echo "SETUP: ${current_step:-build}: inside did not build"; cat build-inside.log; exit 76
    fi
    beside_burst stopping-inside inside.txt
    if [ "$BURST_STATUS" -ne 1 ] || ! grep -qxF 'FAIL: lock: the priority was restored while the stopper still held the runtime lock' inside.txt; then
      pair_mismatch "$BURST_STATUS" inside.txt mutant 0 'lock: restore recorded after the runtime lock was released'
    fi
    printf '  exits 1 at "%s"\n' "$(grep -m1 '^FAIL: lock:' inside.txt)"
    fi


    # A panic inside a stop ends its task, not its thread, which then runs
    # every task after it: `raise` puts the priority back. A copy panics
    # in its first stop, raised, and the main fiber's defer reads its
    # thread's priority, writing what it read without allocating - the
    # runtime lock is the stop's still.
    step "a panic inside a stop puts the stopping thread's priority back"
    cat > panicky.iyi <<'IYI'
@[Unsafe("the report writes through __iyi_write and reads the thread's priority from Windows, so it allocates nothing inside the stop")]
module panicky

def say(text : String) : Nil
  __iyi_write(1, text.to_unsafe.as(Void*), text.bytesize.to_u64)
end

def report : Nil
  if ::LibC.GetThreadPriority(::LibC.GetCurrentThread) == 0
    say("panic: the stopping thread's priority put back\n")
  else
    say("FAIL: panic: the stopping thread kept the stop's priority\n")
  end
end

def run : Nil
  defer report
  IyiMark.collect
end

asleep = IyiThread.start { sleep(10000); nil }
run
asleep.join
IYI
    mkdir -p panicking/iyi
    cp "$REPO"/src/iyi/*.iyi panicking/iyi/
    awk '{ print } /^        raise_stopper$/ { print "        raise \"inside the stop\""; found++ } END { if (found != 1) exit 3 }' \
      "$REPO/src/iyi/thread.iyi" > panicking/iyi/thread.iyi || { echo "SETUP: ${current_step:-panic}: the stop raise anchor changed"; exit 76; }
    if ! IYI_PATH="$WORK/panicking${PSEP}$REPO/src" "$IYI" build --release panicky.iyi -o panicky > build-panicky.log 2>&1; then
      echo "SETUP: ${current_step:-build}: panicky did not build"; cat build-panicky.log; exit 76
    fi
    timeout 60 ./panicky > panicky.txt 2>&1
    code=$?; check_bound "$code" forced control panicky.txt
    if [ "$code" -eq 76 ]; then cat panicky.txt; exit 76; fi
    if [ "$code" -ne 1 ] || ! tr -d '\r' < panicky.txt | grep -qxF "panic: the stopping thread's priority put back" || ! tr -d '\r' < panicky.txt | grep -q '^iyi: panic: inside the stop'; then
      pair_mismatch "$code" panicky.txt control
    fi
    echo "  $(grep -m1 '^panic:' panicky.txt)"

    step "failure proof: a panic inside a stop that keeps the priority is caught"
    mkdir -p unlowered/iyi
    cp panicking/iyi/*.iyi unlowered/iyi/
    awk '/^      IyiThread\.lower_stopper$/ { found++; next } { print } END { if (found != 1) exit 3 }' \
      "$REPO/src/iyi/prelude.iyi" > unlowered/iyi/prelude.iyi || { echo "SETUP: ${current_step:-panic}: the panic lowering anchor changed"; exit 76; }
    if ! IYI_PATH="$WORK/unlowered${PSEP}$REPO/src" "$IYI" build --release panicky.iyi -o panicky-unlowered > build-unlowered.log 2>&1; then
      echo "SETUP: ${current_step:-build}: unlowered did not build"; cat build-unlowered.log; exit 76
    fi
    timeout 60 ./panicky-unlowered > unlowered.txt 2>&1
    code=$?; check_bound "$code" forced mutant unlowered.txt
    if [ "$code" -eq 76 ]; then cat unlowered.txt; exit 76; fi
    if [ "$code" -ne 1 ] || ! tr -d '\r' < unlowered.txt | grep -qxF "FAIL: panic: the stopping thread kept the stop's priority"; then
      pair_mismatch "$code" unlowered.txt mutant 1 "panic: the stopping thread's priority put back"
    fi
    printf '  says "%s"\n' "$(grep -m1 '^FAIL: panic:' unlowered.txt)"

    # Both stoppers raise before either restores. The first holds the real
    # runtime lock until the second has raised, then unlocks and records
    # its priority before the second takes the lock and restores. The same
    # hooks observe both calls to lower_stopper and each actual Windows
    # restore; only the two thread-local annotations differ in the mutant.
    cat > shared-priority.part <<'IYI'
    {% if flag?(:win32) %}
      IYI_SHARED_ARM       = 1664_u64
      IYI_SHARED_A_LINE    = 1728_u64
      IYI_SHARED_B_LINE    = 1792_u64
      IYI_SHARED_A_READY   = 1856_u64
      IYI_SHARED_B_READY   = 1920_u64
      IYI_SHARED_GO        = 1984_u64
      IYI_SHARED_A_RAISED  = 2048_u64
      IYI_SHARED_B_RAISED  = 2112_u64
      IYI_SHARED_A_HELD    = 2176_u64
      IYI_SHARED_A_LOWER   = 2240_u64
      IYI_SHARED_B_LOWER   = 2304_u64
      IYI_SHARED_A_RESTORE = 2368_u64
      IYI_SHARED_B_RESTORE = 2432_u64
      IYI_SHARED_A_AFTER   = 2496_u64
      IYI_SHARED_B_AFTER   = 2560_u64

      def self.shared_priority_say(message : String, status : Int32) : Nil
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        __iyi_exit(status)
      end

      def self.shared_priority_init : UInt64
        page = control
        offset = IYI_SHARED_ARM
        while offset <= IYI_SHARED_B_AFTER
          word(page + offset).value.set(0_u64)
          offset = offset + 64_u64
        end
        page
      end

      def self.shared_priority_slot(page : UInt64, first : UInt64, second : UInt64) : UInt64
        line = @@line
        if line != 0_u64 && line == word(page + IYI_SHARED_A_LINE).value.get
          first
        elsif line != 0_u64 && line == word(page + IYI_SHARED_B_LINE).value.get
          second
        else
          shared_priority_say("SETUP: shared priority: an unexpected thread reached a priority hook\n", 76)
          0_u64
        end
      end

      # Check the priority the real raise is about to save.
      def self.shared_priority_before_raise(original : Int32) : Nil
        page = @@control
        return if page == 0_u64 || word(page + IYI_SHARED_ARM).value.get == 0_u64
        if original == 2147483647_i32
          shared_priority_say("SETUP: shared priority: GetThreadPriority failed before a raise\n", 76)
        end
        slot = shared_priority_slot(page, IYI_SHARED_A_LINE, IYI_SHARED_B_LINE)
        if (slot == IYI_SHARED_A_LINE && original != -1_i32) || (slot == IYI_SHARED_B_LINE && original != 0_i32)
          shared_priority_say("SETUP: shared priority: a starting priority changed before its raise\n", 76)
        end
      end

      # Called after the real SetThreadPriority in raise_stopper.
      def self.shared_priority_raise(result : Int32) : Nil
        page = @@control
        return if page == 0_u64 || word(page + IYI_SHARED_ARM).value.get == 0_u64
        if result == 0_i32
          shared_priority_say("SETUP: shared priority: SetThreadPriority failed during a raise\n", 76)
        end
        actual = LibC.GetThreadPriority(LibC.GetCurrentThread)
        if actual == 2147483647_i32
          shared_priority_say("SETUP: shared priority: GetThreadPriority failed during a raise\n", 76)
        end
        if actual != THREAD_PRIORITY_HIGHEST
          shared_priority_say("SETUP: shared priority: a raise did not reach the highest priority\n", 76)
        end
        slot = shared_priority_slot(page, IYI_SHARED_A_RAISED, IYI_SHARED_B_RAISED)
        word(page + slot).value.add(1_u64)
      end

      # This runs even when the real lower returns without a Windows call.
      def self.shared_priority_lower : Nil
        page = @@control
        return if page == 0_u64 || word(page + IYI_SHARED_ARM).value.get == 0_u64
        slot = shared_priority_slot(page, IYI_SHARED_A_LOWER, IYI_SHARED_B_LOWER)
        word(page + slot).value.add(1_u64)
      end

      # A nonzero encoded priority witnesses a successful real restore.
      def self.shared_priority_restored(result : Int32) : Nil
        page = @@control
        return if page == 0_u64 || word(page + IYI_SHARED_ARM).value.get == 0_u64
        if result == 0_i32
          shared_priority_say("SETUP: shared priority: SetThreadPriority failed during a restore\n", 76)
        end
        actual = LibC.GetThreadPriority(LibC.GetCurrentThread)
        if actual == 2147483647_i32
          shared_priority_say("SETUP: shared priority: GetThreadPriority failed during a restore\n", 76)
        end
        slot = shared_priority_slot(page, IYI_SHARED_A_RESTORE, IYI_SHARED_B_RESTORE)
        word(page + slot).value.set((actual.to_i64 + 16_i64).to_u64)
      end
    {% end %}
IYI
    shared_priority_copy() {
      awk -v gate=shared-priority.part '
        /^    # ── Roots/ {
          roots++
          while ((getline line < gate) > 0) { print line; gate_lines++ }
          close(gate)
        }
        /^      def self\.raise_stopper : Nil$/ { raises++; in_raise = 1; print; next }
        in_raise && /^      end$/ { in_raise = 0 }
        in_raise && /^        priority = LibC\.GetThreadPriority\(me\)$/ {
          print
          print "        IyiThread.shared_priority_before_raise(priority)"
          raise_query++; next
        }
        in_raise && /^        @@stopper_raised = LibC\.SetThreadPriority\(me, THREAD_PRIORITY_HIGHEST\) != 0$/ {
          print "        shared_result = LibC.SetThreadPriority(me, THREAD_PRIORITY_HIGHEST)"
          print "        @@stopper_raised = shared_result != 0"
          print "        IyiThread.shared_priority_raise(shared_result)"
          raise_call++; next
        }
        /^      def self\.lower_stopper : Nil$/ {
          lowers++; in_lower = 1
          print
          print "        IyiThread.shared_priority_lower"
          next
        }
        in_lower && /^      end$/ { in_lower = 0 }
        in_lower && /^        LibC\.SetThreadPriority\(LibC\.GetCurrentThread, @@stopper_priority\)$/ {
          print "        shared_result = LibC.SetThreadPriority(LibC.GetCurrentThread, @@stopper_priority)"
          print "        IyiThread.shared_priority_restored(shared_result)"
          lower_call++; next
        }
        { print }
        END {
          if (roots != 1 || gate_lines == 0 || raises != 1 || raise_query != 1 || raise_call != 1 || lowers != 1 || lower_call != 1) exit 3
        }
      ' "$REPO/src/iyi/thread.iyi" > "$1"
    }
    shared_priority_mutate() {
      awk '
        /^      THREAD_PRIORITY_HIGHEST = 2_i32$/ { in_fields = 1; starts++ }
        in_fields && /^      def self\.raise_stopper : Nil$/ { in_fields = 0; ends++ }
        in_fields && /^      @\[ThreadLocal\]$/ {
          if (held != "") print held
          held = $0; next
        }
        in_fields && $0 == "      @@stopper_priority : Int32 = 0_i32" {
          priorities++
          if (held == "") bad++
          held = ""; print; next
        }
        in_fields && $0 == "      @@stopper_raised : Bool = false" {
          raised++
          if (held == "") bad++
          held = ""; print; next
        }
        {
          if (held != "") { print held; held = "" }
          print
        }
        END {
          if (held != "") print held
          if (starts != 1 || ends != 1 || priorities != 1 || raised != 1 || bad != 0) exit 3
        }
      ' "$1" > "$2"
    }
    shared_priority_restore_annotations() {
      awk '
        /^      THREAD_PRIORITY_HIGHEST = 2_i32$/ { in_fields = 1; starts++ }
        in_fields && /^      def self\.raise_stopper : Nil$/ { in_fields = 0; ends++ }
        in_fields && $0 == "      @@stopper_priority : Int32 = 0_i32" {
          priorities++; print "      @[ThreadLocal]"
        }
        in_fields && $0 == "      @@stopper_raised : Bool = false" {
          raised++; print "      @[ThreadLocal]"
        }
        { print }
        END { if (starts != 1 || ends != 1 || priorities != 1 || raised != 1) exit 3 }
      ' "$1" > "$2"
    }
    if ! mkdir -p shared-priority-control/iyi shared-priority-mutant/iyi ||
       ! cp "$REPO"/src/iyi/*.iyi shared-priority-control/iyi/ ||
       ! shared_priority_copy shared-priority-control/iyi/thread.iyi ||
       ! cp shared-priority-control/iyi/*.iyi shared-priority-mutant/iyi/ ||
       ! shared_priority_mutate shared-priority-control/iyi/thread.iyi shared-priority-mutant/iyi/thread.iyi ||
       ! shared_priority_restore_annotations shared-priority-mutant/iyi/thread.iyi shared-priority-restored.iyi; then
      echo "SETUP: shared priority: the copy anchors or files changed"; exit 76
    fi
    if ! cmp -s shared-priority-control/iyi/thread.iyi shared-priority-restored.iyi; then
      echo "SETUP: shared priority: the copies differ beyond the two annotations"; exit 76
    fi
    for source in shared-priority-control/iyi/*.iyi; do
      file="${source##*/}"
      [ "$file" = thread.iyi ] && continue
      if ! cmp -s "$source" "shared-priority-mutant/iyi/$file"; then
        echo "SETUP: shared priority: the copies differ beyond the two annotations"; exit 76
      fi
    done

    cat > shared-priority.iyi <<'IYI'
@[Unsafe("the test pins each stopper and checks the real Windows priority operations")]
module shared_priority

lib SharedPlacing
  fun SetThreadAffinityMask(thread : Void*, mask : UInt64) : UInt64
end

def load_word(page : UInt64, offset : UInt64) : UInt64
  IyiThread.word(page + offset).value.get
end

def store_word(page : UInt64, offset : UInt64, value : UInt64) : Nil
  IyiThread.word(page + offset).value.set(value)
end

def wait_word(page : UInt64, offset : UInt64, message : String) : Nil
  started = IyiMark.now_ns
  while load_word(page, offset) == 0_u64
    if IyiMark.now_ns &- started > 20000000000_u64
      IyiThread.shared_priority_say(message, 76)
    end
    IyiThread.yield_cpu
  end
end

def priority : Int32
  actual = LibC.GetThreadPriority(LibC.GetCurrentThread)
  if actual == 2147483647_i32
    IyiThread.shared_priority_say("SETUP: shared priority: GetThreadPriority failed at a readback\n", 76)
  end
  actual
end

def prepare(page : UInt64, mask : UInt64, original : Int32, line_slot : UInt64, ready_slot : UInt64) : Nil
  me = LibC.GetCurrentThread
  if SharedPlacing.SetThreadAffinityMask(me, mask) == 0_u64
    IyiThread.shared_priority_say("SETUP: shared priority: SetThreadAffinityMask failed\n", 76)
  end
  if LibC.SetThreadPriority(me, original) == 0_i32
    IyiThread.shared_priority_say("SETUP: shared priority: SetThreadPriority failed at setup\n", 76)
  end
  if priority != original
    IyiThread.shared_priority_say("SETUP: shared priority: a starting priority did not read back\n", 76)
  end
  line = IyiThread.current_line
  if line == 0_u64
    IyiThread.shared_priority_say("SETUP: shared priority: a stopper has no registered line\n", 76)
  end
  store_word(page, line_slot, line)
  store_word(page, ready_slot, 1_u64)
  wait_word(page, IyiThread::IYI_SHARED_GO, "SETUP: shared priority: the stoppers were not released\n")
end

def first(page : UInt64, mask : UInt64) : Nil
  prepare(page, mask, -1_i32, IyiThread::IYI_SHARED_A_LINE, IyiThread::IYI_SHARED_A_READY)
  IyiThread.raise_stopper
  if load_word(page, IyiThread::IYI_SHARED_A_RAISED) != 1_u64
    IyiThread.shared_priority_say("SETUP: shared priority: the first stopper did not raise\n", 76)
  end
  IyiRuntimeLock.lock
  store_word(page, IyiThread::IYI_SHARED_A_HELD, 1_u64)
  wait_word(page, IyiThread::IYI_SHARED_B_RAISED, "SETUP: shared priority: the second stopper did not raise\n")
  IyiMark.unlock_released
  store_word(page, IyiThread::IYI_SHARED_A_AFTER, (priority.to_i64 + 16_i64).to_u64)
end

def second(page : UInt64, mask : UInt64) : Nil
  prepare(page, mask, 0_i32, IyiThread::IYI_SHARED_B_LINE, IyiThread::IYI_SHARED_B_READY)
  wait_word(page, IyiThread::IYI_SHARED_A_HELD, "SETUP: shared priority: the first stopper did not hold the lock\n")
  IyiThread.raise_stopper
  if load_word(page, IyiThread::IYI_SHARED_B_RAISED) != 1_u64
    IyiThread.shared_priority_say("SETUP: shared priority: the second stopper did not raise\n", 76)
  end
  wait_word(page, IyiThread::IYI_SHARED_A_AFTER, "SETUP: shared priority: the first stopper did not read back its restore\n")
  IyiRuntimeLock.lock
  IyiMark.unlock_released
  store_word(page, IyiThread::IYI_SHARED_B_AFTER, (priority.to_i64 + 16_i64).to_u64)
end

IyiMark.auto = false
IyiMark.workers = 0_u64
page = IyiThread.shared_priority_init
first_mask = 1_u64.unsafe_shl(Program.args[0].to_i.to_u64)
second_mask = 1_u64.unsafe_shl(Program.args[1].to_i.to_u64)
first_thread = IyiThread.start { first(page, first_mask); nil }
second_thread = IyiThread.start { second(page, second_mask); nil }
wait_word(page, IyiThread::IYI_SHARED_A_READY, "SETUP: shared priority: the first stopper did not start\n")
wait_word(page, IyiThread::IYI_SHARED_B_READY, "SETUP: shared priority: the second stopper did not start\n")
if load_word(page, IyiThread::IYI_SHARED_A_LINE) == load_word(page, IyiThread::IYI_SHARED_B_LINE)
  IyiThread.shared_priority_say("SETUP: shared priority: the stoppers did not have distinct lines\n", 76)
end
store_word(page, IyiThread::IYI_SHARED_ARM, 1_u64)
store_word(page, IyiThread::IYI_SHARED_GO, 1_u64)
wait_word(page, IyiThread::IYI_SHARED_A_HELD, "SETUP: shared priority: the first stopper did not hold the lock\n")
wait_word(page, IyiThread::IYI_SHARED_B_RAISED, "SETUP: shared priority: the second stopper did not raise\n")
wait_word(page, IyiThread::IYI_SHARED_A_AFTER, "SETUP: shared priority: the first stopper did not read back its restore\n")
wait_word(page, IyiThread::IYI_SHARED_B_AFTER, "SETUP: shared priority: the second stopper did not read back its restore\n")
first_thread.join
second_thread.join

if load_word(page, IyiThread::IYI_SHARED_A_RAISED) != 1_u64 || load_word(page, IyiThread::IYI_SHARED_B_RAISED) != 1_u64
  IyiThread.shared_priority_say("SETUP: shared priority: both real raises were not observed\n", 76)
end
if load_word(page, IyiThread::IYI_SHARED_A_LOWER) != 1_u64 || load_word(page, IyiThread::IYI_SHARED_B_LOWER) != 1_u64
  IyiThread.shared_priority_say("SETUP: shared priority: both real lowers were not observed\n", 76)
end
a_restore = load_word(page, IyiThread::IYI_SHARED_A_RESTORE)
b_restore = load_word(page, IyiThread::IYI_SHARED_B_RESTORE)
a_after = load_word(page, IyiThread::IYI_SHARED_A_AFTER)
b_after = load_word(page, IyiThread::IYI_SHARED_B_AFTER)
if a_restore == 0_u64 || a_restore != a_after || (b_restore != 0_u64 && b_restore != b_after)
  IyiThread.shared_priority_say("SETUP: shared priority: a real restore readback was not observed\n", 76)
end
if b_restore == 0_u64 && b_after != 18_u64
  IyiThread.shared_priority_say("SETUP: shared priority: the second restore result was not observed\n", 76)
end
if a_after == 15_u64 && b_after == 16_u64 && b_restore == 16_u64
  puts "shared priority: both stoppers restored their own priorities"
elsif a_after == 16_u64 && b_after == 18_u64 && b_restore == 0_u64
  IyiThread.shared_priority_say("FAIL: shared priority: an overlapping raise overwrote another stopper's priority record\n", 1)
else
  IyiThread.shared_priority_say("SETUP: shared priority: the restore readbacks did not match either witness\n", 76)
end
IYI
    shared_priority_success="shared priority: both stoppers restored their own priorities"
    shared_priority_failure="FAIL: shared priority: an overlapping raise overwrote another stopper's priority record"
    for mode in control mutant; do
      step "shared priority: $mode"
      if ! IYI_PATH="$WORK/shared-priority-$mode${PSEP}$REPO/src" "$IYI" build --release shared-priority.iyi -o "shared-priority-$mode-run" > "build-shared-priority-$mode.log" 2>&1; then
        echo "SETUP: shared priority: the $mode build failed"
        cat "build-shared-priority-$mode.log"; exit 76
      fi
      timeout 60 "./shared-priority-$mode-run" "$AFFINITY_FIRST" "$AFFINITY_SECOND" > "shared-priority-$mode-raw.txt" 2>&1
      code=$?; check_bound "$code" forced "$mode" "shared-priority-$mode-raw.txt"
      tr -d '\r' < "shared-priority-$mode-raw.txt" > "shared-priority-$mode.txt"
      if [ "$code" -eq 76 ] || grep -q '^SETUP:' "shared-priority-$mode.txt"; then
        if grep -q '^SETUP:' "shared-priority-$mode.txt"; then
          grep '^SETUP:' "shared-priority-$mode.txt"
        else
          echo "SETUP: shared priority: the $mode process exited without a setup diagnostic"
        fi
        exit 76
      fi
      if [ "$mode" = control ]; then
        if [ "$code" -ne 0 ] || [ "$(grep -cxF "$shared_priority_success" "shared-priority-$mode.txt")" -ne 1 ] || grep -q '^FAIL:' "shared-priority-$mode.txt"; then
          pair_mismatch "$code" "shared-priority-$mode.txt" control
        fi
        echo "  $shared_priority_success"
      else
        if [ "$code" -ne 1 ] || [ "$(grep -c '^FAIL:' "shared-priority-$mode.txt")" -ne 1 ] || ! grep -qxF "$shared_priority_failure" "shared-priority-$mode.txt"; then
          pair_mismatch "$code" "shared-priority-$mode.txt" mutant 0 "$shared_priority_success"
        fi
        printf '  exits 1 at "%s"\n' "$shared_priority_failure"
      fi
    done
    ;;
esac

# ── 4e. The release waits for nobody it lets go ──────────────────────────
# A stop's release used to wait for every thread it let go to leave its
# park, so a collection lasted until the last of them had a processor
# again: on Windows 11, 12 logical processors, a thread parked inside the
# allocator and then held off its processor by another program kept each
# collection 403 to 410 ms past its stop, and 25 to 28 ms once the release
# stopped waiting (the mark of 2,000,000 links among it). The next stop
# now waits, before it clears the words the released threads read
# (`stop_others`), and the release waits for none of them (`resume_others`).
#
# The released thread is held before counting out. Both copies read the
# actual count-out after resume_others returns; the mutant waits for that
# count inside the release after letting the held thread leave its gate.
# A missing or expired hold is a distinct setup failure, not the verdict.
#
# The bound this replaces was 200 ms on a mean of five collections. It read
# 175 ms in one run and 411 ms in the next on GitHub's windows-2025 runner,
# beside 76 ms for the healthy release (jwaldrip/iyi run 44368465397), so
# it measured the runner's scheduling and not the release.
#
# The gate uses words on the control page past IYI_TC_TURNS, and it
# exists only in copies of the runtime's thread.iyi, made here by awk, so
# the tree is never touched. The healthy copy is the tree with the hook and
# nothing else; the waiting copy adds the wait a release would make.
cat > gate.part <<'IYI'
    # ── The release gate (bench/thread_exercise.sh, step 4e) ─────────────
    # Copies only: the awk in that step puts this into a copy of the
    # runtime's thread.iyi, and the tree has none of it. The control-page
    # words name the armed line, hold, opening, expiry, and start time.
    # The start time also lets the collector detect an expired hold while
    # the held thread itself is suspended.
    IYI_GATE_LINE    = 384_u64
    IYI_GATE_HELD    = 448_u64
    IYI_GATE_OPEN    = 512_u64
    IYI_GATE_EXPIRED = 576_u64
    IYI_GATE_STARTED = 832_u64
    IYI_GATE_NS      = 5000000000_u64

    # The calling thread's own line is the one the gate holds.
    def self.release_gate_arm : Nil
      word(control + IYI_GATE_LINE).value.set(@@line)
    end

    # `park` calls this for every parked thread before it counts itself out
    # of the release. Atomics only: nothing allocates and no lock is taken.
    # For the armed line the thread sets `held`, then waits for its owner.
    # A deadline failure ends the process; it never opens the gate.
    def self.release_gate_hold(line : UInt64, message : String) : Nil
      page = control
      return if line == 0_u64 || word(page + IYI_GATE_LINE).value.get != line
      began = IyiMark.now_ns
      word(page + IYI_GATE_STARTED).value.set(began)
      word(page + IYI_GATE_HELD).value.set(1_u64)
      while word(page + IYI_GATE_OPEN).value.get == 0_u64
        if IyiMark.now_ns &- began > IYI_GATE_NS
          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
          {% if flag?(:darwin) %}
            LibC.thread_gate_exit(76_i32)
          {% else %}
            __iyi_exit(76)
          {% end %}
        end
        yield_cpu
      end
    end

    # Opens the gate and answers {held, expired}. The release may return
    # before the armed thread has reached the gate, so this waits for `held`
    # as well, within the same bound.
    def self.release_gate_open : Tuple(Bool, Bool)
      page = control
      began = IyiMark.now_ns
      while word(page + IYI_GATE_HELD).value.get == 0_u64
        if IyiMark.now_ns &- began > IYI_GATE_NS
          message = "SETUP: release gate: the held thread never arrived\n"
          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
          __iyi_exit(76)
        end
        yield_cpu
      end
      if release_gate_expired?
        message = "SETUP: release gate: hold deadline elapsed before opening\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        __iyi_exit(76)
      end
      word(page + IYI_GATE_OPEN).value.set(1_u64)
      {true, false}
    end

    # Whether the armed thread has reached its gate. A skipping copy's main
    # waits on this before it collects; nothing else reads it.
    def self.release_gate_held? : Bool
      word(control + IYI_GATE_HELD).value.get != 0_u64
    end
    def self.release_gate_expired? : Bool
      page = control
      return true if word(page + IYI_GATE_EXPIRED).value.get != 0_u64
      return false if word(page + IYI_GATE_HELD).value.get == 0_u64
      IyiMark.now_ns &- word(page + IYI_GATE_STARTED).value.get > IYI_GATE_NS
    end
    # Both copies observe the actual count-out after the held thread reaches
    # its gate. A missing hold or expired gate is a setup failure.
    def self.release_gate_wait_held(page : UInt64) : Nil
      began = IyiMark.now_ns
      while word(page + IYI_GATE_HELD).value.get == 0_u64
        if IyiMark.now_ns &- began > IYI_GATE_NS
          message = "SETUP: release: the held thread never reached its park\n"
          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
          __iyi_exit(76)
        end
        yield_cpu
      end
    end

    # Mutant: allow the held thread to leave its gate and wait for the real
    # count-out before returning from resume_others.
    def self.release_gate_wait_resumed(page : UInt64, target : UInt64) : Nil
      release_gate_wait_held(page)
      word(page + IYI_GATE_OPEN).value.set(1_u64)
      began = IyiMark.now_ns
      while word(page + IYI_TC_RESUMED).value.get < target
        if IyiMark.now_ns &- began > IYI_GATE_NS
          message = "SETUP: release: the held thread never counted out\n"
          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
          __iyi_exit(76)
        end
        yield_cpu
      end
    end

    def self.release_gate_counted_out? : Bool
      page = control
      release_gate_wait_held(page)
      word(page + IYI_TC_RESUMED).value.get != 0_u64
    end



    # ── Copy-only: an armed start with its handle written late ──────────
    # `release_gate_arm_next` arms exactly one start. `release_gate_take_arm`
    # is called once per start before its CreateThread: the one armed start
    # is created suspended-free but writes its handle only after its unlock,
    # and holds there in `release_gate_start_hold` until the gate opens. A
    # stop reads each thread's handle once, in `release_gate_unnamed?`, and
    # records a visit to the armed line whose handle is still 0.
    IYI_GATE_ARM    = 640_u64
    IYI_GATE_RECORD = 704_u64
    IYI_GATE_SKIP   = 768_u64

    def self.release_gate_arm_next : Nil
      word(control + IYI_GATE_ARM).value.set(1_u64)
    end

    def self.release_gate_take_arm : Bool
      word(control + IYI_GATE_ARM).value.swap(0_u64) != 0_u64
    end

    def self.release_gate_start_hold(line : UInt64) : Nil
      word(control + IYI_GATE_LINE).value.set(line)
      release_gate_hold(line, "SETUP: unnamed: held start gate timed out\n")
    end

    def self.release_gate_unnamed?(cursor : UInt64, line : UInt64) : Bool
      return false if cursor == line
      return false if word(control + IYI_GATE_LINE).value.get != cursor
      return false if IyiHeap.read64(cursor + IYI_TL_HANDLE) != 0_u64
      word(control + IYI_GATE_SKIP).value.set(cursor)
      word(control + IYI_GATE_RECORD).value.set(1_u64)
      true
    end
    def self.release_gate_clear_skip : Nil
      word(control + IYI_GATE_SKIP).value.set(0_u64)
    end

    def self.release_gate_skipped?(cursor : UInt64) : Bool
      cursor == word(control + IYI_GATE_SKIP).value.get
    end


    def self.release_gate_recorded? : Bool
      word(control + IYI_GATE_RECORD).value.get != 0_u64
    end

IYI
cat > release.iyi <<'IYI'
@[Unsafe("a timed-out allocator rendezvous writes its diagnostic without allocating")]
module release

class Flag
  getter stop : Atomic(Int64)
  getter inside : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
    @inside = Atomic(Int64).new(0_i64)
  end
end

def fail(message : String) : Nil
  print "FAIL: #{message}\n"
  __iyi_exit(1)
end

# The held thread. It is inside the allocator from `enter_barrier` to
# `leave_barrier` for all the time it is not leaving, so every stop finds
# it there and it parks where it leaves. `inside` tells the stopper that it
# has entered, before the stop is sent.
def hold_in_allocator(flag : Flag) : Nil
  IyiThread.release_gate_arm
  while flag.stop.get == 0_i64
    IyiHeap.enter_barrier
    flag.inside.set(1_i64)
    began = IyiMark.now_ns
    while flag.stop.get == 0_i64 && !IyiHeap.stop_requested?
      if IyiMark.now_ns &- began > 20000000000_u64
        message = "SETUP: release: the holder never received a stop request\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        __iyi_exit(76)
      end
      IyiThread.spin_pause
    end
    flag.inside.set(0_i64)
    IyiHeap.leave_barrier
  end
end

flag = Flag.new
held = IyiThread.start { hold_in_allocator(flag) }
deadline = IyiMark.now_ns &+ 20000000000_u64
while flag.inside.get == 0_i64
  if IyiMark.now_ns >= deadline
    print "SETUP: release: the holder never entered the allocator\n"
    __iyi_exit(76)
  end
  IyiThread.yield_cpu
end
IyiRuntimeLock.lock
others = IyiThread.stop_others
IyiThread.resume_others(others)
waited = IyiThread.release_gate_counted_out?
IyiRuntimeLock.unlock
reached, expired = IyiThread.release_gate_open
flag.stop.set(1_i64)
held.join
if !reached || expired
  print "SETUP: release: the held thread did not remain at its park\n"
  __iyi_exit(76)
end
fail("release: the release waited for the thread it let go") if waited
puts "release: the held thread parked inside the allocator, and the release did not wait for it"
IYI
step "a release beside a thread held in the allocator, which it does not wait for"
mkdir -p gated/iyi waiting/iyi
cp "$REPO"/src/iyi/*.iyi gated/iyi/
awk -v gate=gate.part '
  /^    # ── Roots / { while ((getline line < gate) > 0) print line; roots++ }
  /^      fun thread_switch\(thread : UInt32, option : Int32, time : UInt32\) : Int32$/ { print; print "      fun thread_gate_exit = _exit(status : Int32) : NoReturn"; darwin_exit++; next }
  /^      count_in\(page \+ IYI_TC_RESUMED\)$/ { print "      release_gate_hold(line, \"SETUP: release: held thread gate timed out\\n\")"; hook++ }
  { print }
  END { if (roots != 1 || hook != 1 || darwin_exit != 1) exit 3 }
' "$REPO/src/iyi/thread.iyi" > gated/iyi/thread.iyi || { echo "SETUP: release: the park or roots anchors changed"; exit 76; }
if ! IYI_PATH="$WORK/gated${PSEP}$REPO/src" "$IYI" build --release release.iyi -o release > build-release.log 2>&1; then
  echo "SETUP: ${current_step:-build}: release did not build"; cat build-release.log; exit 76
fi
timeout 120 ./release > release.txt 2>&1
code=$?; check_bound "$code" forced control release.txt
if [ "$code" -eq 76 ]; then cat release.txt; exit 76; fi
if [ "$code" -ne 0 ] || ! grep -qxF 'release: the held thread parked inside the allocator, and the release did not wait for it' release.txt; then
  pair_mismatch "$code" release.txt control
fi
sed 's/^/  /' release.txt

step "failure proof: a release that waits for the threads it let go is caught on its one run"
cp "$REPO"/src/iyi/*.iyi waiting/iyi/
awk '
  /^        @@owed = @@deferred$/ { print; print "        release_gate_wait_resumed(page, @@owed.to_u64)"; deferred++; next }
  /^        @@owed = others$/ { print; print "        release_gate_wait_resumed(page, @@owed.to_u64)"; owed++; next }
  { print }
  END { if (deferred != 1 || owed != 1) exit 3 }
' gated/iyi/thread.iyi > waiting/iyi/thread.iyi || { echo "SETUP: release: the release anchors changed"; exit 76; }
if ! IYI_PATH="$WORK/waiting${PSEP}$REPO/src" "$IYI" build --release release.iyi -o release-waiting > build-waiting.log 2>&1; then
  echo "SETUP: ${current_step:-build}: waiting did not build"; cat build-waiting.log; exit 76
fi
timeout 120 ./release-waiting > waiting.txt 2>&1
code=$?; check_bound "$code" forced mutant waiting.txt
if [ "$code" -eq 76 ]; then cat waiting.txt; exit 76; fi
if [ "$code" -ne 1 ] || ! grep -q '^FAIL: release: the release waited for the thread it let go$' waiting.txt; then
  pair_mismatch "$code" waiting.txt mutant 0 'release: the held thread parked inside the allocator, and the release did not wait for it'
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 '^FAIL: release:' waiting.txt)"

# ── 4f. A stop parks no thread inside the allocator ─────────────────────────
# A stop that reaches a thread inside the allocator does not park it there.
# The handler asks for a park, and `leave` parks the thread at depth 0 once it
# is out (prelude.iyi, `leave`). A thread parked inside could hold a chunk in
# a register the scan does not name, or the centre's lock against the sweep
# (thread.iyi, `stopped_by_signal`). The witness holds one thread inside the
# allocator, stops the others, and reads at the held thread's first park
# whether it was inside. The control copy adds one hook to `park` and nothing
# else. The mutant also removes the handler's check, so the hook then runs
# inside the signal handler; that is why the hook uses atomics only.
case "$(uname -s)" in
  Linux | Darwin)
    depth_success='allocator: the stop parked the held thread after it left the allocator'
    depth_failure='FAIL: allocator: a stop parked a thread inside the allocator'
    cat > depth.part <<'IYI' || { echo "SETUP: allocator: could not write the hook"; exit 76; }
    # ── The depth witness (bench/thread_exercise.sh, step 4f) ───────────────
    # Copies only: the awk in that step puts this into a copy of the
    # runtime's thread.iyi, and the tree has none of it. The control-page
    # words name the armed line, whether that line has parked during a stop,
    # and whether the thread was inside the allocator at its first park.
    IYI_DEPTH_LINE   = 1280_u64
    IYI_DEPTH_PARKED = 1344_u64
    IYI_DEPTH_INSIDE = 4032_u64

    # The calling thread's own line is the one the witness watches.
    def self.depth_arm : Nil
      word(control + IYI_DEPTH_LINE).value.set(@@line)
    end

    # `park` calls this for every park, before it counts the thread in. Only
    # the armed line's first park is recorded. Atomics only: nothing allocates
    # and no lock is taken, because the mutant runs this in the signal handler.
    def self.depth_park(line : UInt64, page : UInt64) : Nil
      return if line == 0_u64 || word(page + IYI_DEPTH_LINE).value.get != line
      return if word(page + IYI_DEPTH_PARKED).value.get != 0_u64
      inside = 0_u64
      inside = 1_u64 if IyiHeap.in_allocator?
      word(page + IYI_DEPTH_INSIDE).value.set(inside)
      word(page + IYI_DEPTH_PARKED).value.set(1_u64)
    end

    # Read by the stopper once `stop_others` has returned.
    def self.depth_parked? : Bool
      word(control + IYI_DEPTH_PARKED).value.get != 0_u64
    end

    def self.depth_inside? : Bool
      word(control + IYI_DEPTH_INSIDE).value.get != 0_u64
    end

IYI
    cat > depth.iyi <<'IYI' || { echo "SETUP: allocator: could not write the witness program"; exit 76; }
@[Unsafe("copy-only witness: a stop's park records the allocator depth of the thread it parks")]
module depth

class Flag
  getter stop : Atomic(Int64)
  getter inside : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
    @inside = Atomic(Int64).new(0_i64)
  end
end

# The held thread, as release.iyi holds it: inside the allocator from
# `enter_barrier` to `leave_barrier` for all the time it is not leaving, so a
# stop finds it at depth 1.
def hold_in_allocator(flag : Flag) : Nil
  IyiThread.depth_arm
  while flag.stop.get == 0_i64
    IyiHeap.enter_barrier
    flag.inside.set(1_i64)
    began = IyiMark.now_ns
    while flag.stop.get == 0_i64 && !IyiHeap.stop_requested?
      if IyiMark.now_ns &- began > 20000000000_u64
        message = "SETUP: allocator: the holder never received a stop request\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        __iyi_exit(76)
      end
      IyiThread.spin_pause
    end
    flag.inside.set(0_i64)
    IyiHeap.leave_barrier
  end
end

IyiMark.auto = false
IyiMark.workers = 0_u64
flag = Flag.new
held = IyiThread.start { hold_in_allocator(flag) }
deadline = IyiMark.now_ns &+ 20000000000_u64
while flag.inside.get == 0_i64
  if IyiMark.now_ns >= deadline
    print "SETUP: allocator: the holder never entered the allocator\n"
    __iyi_exit(76)
  end
  IyiThread.yield_cpu
end
IyiRuntimeLock.lock
others = IyiThread.stop_others
was_parked = IyiThread.depth_parked?
was_inside = IyiThread.depth_inside?
IyiThread.resume_others(others)
IyiRuntimeLock.unlock
flag.stop.set(1_i64)
held.join
if others != 1_i64
  print "SETUP: allocator: the stop did not stop exactly the held thread\n"
  __iyi_exit(76)
end
if !was_parked
  print "SETUP: allocator: the held thread did not park during the stop\n"
  __iyi_exit(76)
end
if was_inside
  print "FAIL: allocator: a stop parked a thread inside the allocator\n"
  __iyi_exit(1)
end
puts "allocator: the stop parked the held thread after it left the allocator"
IYI
    step "a stop beside a thread held in the allocator parks it after it leaves"
    mkdir -p parkdepth-control/iyi parkdepth-mutant/iyi || { echo "SETUP: allocator: could not make the copies"; exit 76; }
    cp "$REPO"/src/iyi/*.iyi parkdepth-control/iyi/ || { echo "SETUP: allocator: could not populate the control copy"; exit 76; }
    awk -v part=depth.part '
      /^    # ── Roots / { while ((getline line < part) > 0) print line; roots++ }
      /^    def self\.park\(line : UInt64\) : Nil$/ { inpark = 1; parks++ }
      inpark && /^      page = control$/ { print; print "      depth_park(line, page)"; hooks++; inpark = 0; next }
      inpark && /^    end$/ { inpark = 0 }
      { print }
      END { if (roots != 1 || parks != 1 || hooks != 1) exit 3 }
    ' "$REPO/src/iyi/thread.iyi" > parkdepth-control/iyi/thread.iyi || { echo "SETUP: allocator: the park or roots anchors changed"; exit 76; }
    cmp -s parkdepth-control/iyi/thread.iyi "$REPO/src/iyi/thread.iyi" && { echo "SETUP: allocator: the control copy was unchanged"; exit 76; }
    if ! IYI_PATH="$WORK/parkdepth-control${PSEP}$REPO/src" "$IYI" build --release depth.iyi -o parkdepth-control-run > parkdepth-control.build.log 2>&1; then
      echo "SETUP: allocator: the control did not build"; cat parkdepth-control.build.log; exit 76
    fi
    timeout 120 ./parkdepth-control-run > parkdepth-control.txt 2>&1
    code=$?; check_bound "$code" forced control parkdepth-control.txt
    if [ "$code" -ne 0 ] || [ "$(tr -d '\r' < parkdepth-control.txt | grep -c '^FAIL:' || :)" -ne 0 ] || ! tr -d '\r' < parkdepth-control.txt | grep -qxF "$depth_success"; then
      pair_mismatch "$code" parkdepth-control.txt control
    fi
    echo "  $depth_success"

    step "failure proof: a stop that parks a thread inside the allocator is caught on its one run"
    cp parkdepth-control/iyi/*.iyi parkdepth-mutant/iyi/ || { echo "SETUP: allocator: could not populate the mutant copy"; exit 76; }
    awk '
      /^    def self\.stopped_by_signal\(context : UInt64\) : Nil$/ { insignal = 1; signals++ }
      insignal && /^      if IyiHeap\.in_allocator\?$/ { print "      if false && IyiHeap.in_allocator?"; guards++; insignal = 0; next }
      insignal && /^    end$/ { insignal = 0 }
      { print }
      END { if (signals != 1 || guards != 1) exit 3 }
    ' parkdepth-control/iyi/thread.iyi > parkdepth-mutant/iyi/thread.iyi || { echo "SETUP: allocator: the allocator guard anchor changed"; exit 76; }
    cmp -s parkdepth-mutant/iyi/thread.iyi parkdepth-control/iyi/thread.iyi && { echo "SETUP: allocator: the mutant copy was unchanged"; exit 76; }
    if ! IYI_PATH="$WORK/parkdepth-mutant${PSEP}$REPO/src" "$IYI" build --release depth.iyi -o parkdepth-mutant-run > parkdepth-mutant.build.log 2>&1; then
      echo "SETUP: allocator: the mutant did not build"; cat parkdepth-mutant.build.log; exit 76
    fi
    timeout 120 ./parkdepth-mutant-run > parkdepth-mutant.txt 2>&1
    code=$?; check_bound "$code" forced mutant parkdepth-mutant.txt
    if [ "$code" -ne 1 ] || [ "$(tr -d '\r' < parkdepth-mutant.txt | grep -c '^FAIL:' || :)" -ne 1 ] || ! tr -d '\r' < parkdepth-mutant.txt | grep -qxF "$depth_failure"; then
      pair_mismatch "$code" parkdepth-mutant.txt mutant 0 "$depth_success"
    fi
    printf '  exits 1 at "%s"\n' "$depth_failure"
    ;;
esac

# ── 5. Failure proof: a stopped thread's frames are roots ─────────────────
# The walk over stopped threads removed from the root set, in a copy of
# the prelude built against through IYI_PATH; nothing in the tree is
# touched. Every collection another thread triggers then frees this
# thread's list, and the check names the node on a free list.
step "failure proof: without the thread-root walk a live list is swept"
mkdir -p patched/iyi
cp "$REPO"/src/iyi/*.iyi patched/iyi/
awk '
  /^      def self\.each_root\(visit : Proc\(UInt64, Nil\)\) : Nil$/ { in_root = 1; root_methods++ }
  /^      def self\.each_root_of_others\(visit : Proc\(UInt64, Nil\)\) : Nil$/ { in_others = 1; other_methods++ }
  (in_root || in_others) && /^      end$/ { in_root = 0; in_others = 0 }
  /each_thread_root\(visit\)/ {
    matches = gsub(/each_thread_root\(visit\)/, "each_global_root(visit)")
    if (in_root) root_calls += matches
    else if (in_others) other_calls += matches
    else outside_calls += matches
  }
  { print }
  END {
    if (root_methods != 1 || other_methods != 1 || root_calls != 1 || other_calls != 1 || outside_calls != 0) exit 3
  }
' "$REPO/src/iyi/prelude.iyi" > patched/iyi/prelude.iyi || { echo "SETUP: ${current_step:-unrooted}: the thread-root anchors changed"; exit 76; }
cmp -s patched/iyi/prelude.iyi "$REPO/src/iyi/prelude.iyi" && { echo "SETUP: ${current_step:-unrooted}: the thread-root copy was unchanged"; exit 76; }
if ! IYI_PATH="$WORK/patched${PSEP}$REPO/src" "$IYI" build --release "$REPO/bench/thread_exercise.iyi" -o unrooted > build-unrooted.log 2>&1; then
  echo "SETUP: ${current_step:-build}: unrooted did not build"; cat build-unrooted.log; exit 76
fi
# `-k`: Git Bash's TERM can be lost on a native program, and a deadline
# that does not end the run is a job that hangs to its own limit.
timeout 120 ./unrooted 8 > unrooted.txt 2>&1
code=$?; check_bound "$code" forced mutant unrooted.txt
if [ "$code" -eq 76 ]; then cat unrooted.txt; exit 76; fi
if [ "$code" -ne 1 ] || ! tr -d '\r' < unrooted.txt | grep -qxF "FAIL: thread roots: the explicit collection swept a held thread's live nodes"; then
  pair_mismatch "$code" unrooted.txt mutant 0 'thread exercise: every property held'
fi
printf '  exits 1 at "%s"\n' "FAIL: thread roots: the explicit collection swept a held thread's live nodes"


# ── 5b. Failure proof: a finished thread's fibers leave the registry ──────
# The thread's retirement from the scheduler taken out of a copy of the
# runtime: every thread that ran fibers leaves its main fiber on the list,
# and the exercise's count names them.
step "failure proof: a finished thread's main fiber left registered is named"
mkdir -p stale/iyi
cp "$REPO"/src/iyi/*.iyi stale/iyi/
awk '/^      IyiScheduler.retire_thread$/ { found++; next } { print } END { if (found != 1) exit 3 }' \
  "$REPO/src/iyi/thread.iyi" > stale/iyi/thread.iyi || { echo "SETUP: ${current_step:-registry}: the retirement anchor changed"; exit 76; }
if ! IYI_PATH="$WORK/stale${PSEP}$REPO/src" "$IYI" build "$REPO/bench/thread_exercise.iyi" -o stale-threads > build-stale.log 2>&1; then
  echo "SETUP: ${current_step:-build}: stale did not build"; cat build-stale.log; exit 76
fi
timeout 120 ./stale-threads 8 > stale.txt 2>&1
code=$?; check_bound "$code" forced mutant stale.txt
if [ "$code" -eq 76 ]; then cat stale.txt; exit 76; fi
if [ "$code" -ne 1 ] || ! tr -d '\r' < stale.txt | grep -qxF 'FAIL: registry: 8 fibers of 8 finished threads are still registered, naming stacks that are gone'; then
  pair_mismatch "$code" stale.txt mutant 0 'thread exercise: every property held'
fi
printf '  exits 1 at "%s"\n' 'FAIL: registry: 8 fibers of 8 finished threads are still registered, naming stacks that are gone'

# ── 5c. A task being switched to is a root ────────────────────────────────
# A switch marked the fiber it enters running before its stack was the
# thread's, and the fiber walk skips the running one: a thread stopped
# between the two had that fiber's stack scanned by nobody, and what only
# it named was freed. The fiber is marked on its own stack now. Two tasks per thread hand a token back and forth,
# each holding a list only its own stack names, while the main thread
# collects every millisecond; each checks its list every 64 trips.
step "stress: a task a thread is switching into keeps its objects, five runs"
cat > switching.iyi <<'IYI'
@[Unsafe("the tallies live in a page from __iyi_mmap read as atomic words, so counting allocates nothing the collector sees")]
module switching

import std/gc::{GC}

class Node
  getter value : Int64
  getter next_node : Node?

  def initialize(@value : Int64, @next_node : Node?)
  end
end

def build(n : Int32, seed : Int64) : Node?
  head = nil.as(Node?)
  n.times { |i| head = Node.new(seed + i.to_i64, head) }
  head
end

def intact?(head : Node?, n : Int32, seed : Int64) : Bool
  i = n - 1
  cur = head
  while cur.is_a?(Node)
    return false if cur.value != seed + i.to_i64
    i = i - 1
    cur = cur.next_node
  end
  i == -1
end

class Tally
  @@page = 0_u64

  def self.setup : Nil
    @@page = __iyi_mmap(4096_u64).address
  end

  def self.wrong : Pointer(Atomic(UInt64))
    Pointer(Atomic(UInt64)).new(@@page)
  end

  def self.finished : Pointer(Atomic(UInt64))
    Pointer(Atomic(UInt64)).new(@@page + 8_u64)
  end
end
{% if flag?(:skipping_force) %}
# Addresses in this mapping are not roots; the sweep's flags can be read
# without following links in nodes that may have been freed.
class Ledger
  @@page = 0_u64

  def self.setup : Nil
    @@page = __iyi_mmap(8192_u64).address
  end

  def self.record(side : Int32, head : Node?) : Nil
    index = 0
    node = head
    while node.is_a?(Node)
      Pointer(Atomic(UInt64)).new(@@page + (side * 300 + index).to_u64 * 8_u64).value.set(node.object_id)
      node = node.next_node
      index = index + 1
    end
  end

  def self.freed : Int32
    count = 0
    600.times do |index|
      address = Pointer(Atomic(UInt64)).new(@@page + index.to_u64 * 8_u64).value.get
      if address == 0_u64
        print "SETUP: skipping: the ledger was not populated\n"
        __iyi_exit(76)
      end
      count = count + 1 if IyiMark.flags(address) & IyiHeap::FREE_FLAG != 0
    end
    count
  end
end
{% end %}


def pair(id : Int32, trips : Int32) : Nil
  there = Channel(Int32).new(1)
  back = Channel(Int32).new(1)
  group do |g|
    2.times do |side|
      g.spawn do
        seed = (id * 10 + side).to_i64 * 1000000_i64
        mine = build(300, seed)
        {% if flag?(:skipping_force) %}
        Ledger.record(side, mine)
        {% end %}
        wrong = 0
        trips.times do |t|
          if side == 0
            there.send(t)
            back.receive
          else
            there.receive
            back.send(t)
          end
          {% if flag?(:skipping_force) %}
          IyiThread.release_gate_arm if id == 1 && side == 0 && t == 2
          {% end %}
          build(20, 0_i64) if t % 8 == 0
          wrong = wrong + 1 if t % 64 == 0 && !intact?(mine, 300, seed)
        end
        Tally.wrong.value.add(wrong.to_u64)
        Tally.finished.value.add(1_u64)
        0
      end
    end
    0
  end
end

Tally.setup
count = 6
{% if flag?(:skipping_force) %}
IyiMark.auto = false
Ledger.setup
count = 1
{% end %}
threads = [] of IyiThread
count.times do |id|
  threads << IyiThread.start { pair(id + 1, 100000); nil }
end
{% if flag?(:skipping_force) %}
# Collect once while the switch is held. Read the sweep flags before any
# allocation can reuse the unrooted nodes recorded in the mmap ledger.
deadline = IyiMark.now_ns &+ 20000000000_u64
while !IyiThread.release_gate_held? && IyiMark.now_ns < deadline
  IyiThread.yield_cpu
end
if !IyiThread.release_gate_held?
  print "SETUP: skipping: the armed switch never reached the gate\n"
  __iyi_exit(76)
end
if IyiThread.release_gate_expired?
  print "SETUP: skipping: the hold deadline elapsed before the collection\n"
  __iyi_exit(76)
end
GC.collect
if IyiThread.release_gate_expired?
  print "SETUP: skipping: the hold deadline elapsed during the collection\n"
  __iyi_exit(76)
end
freed = Ledger.freed
if IyiThread.release_gate_expired?
  print "SETUP: skipping: the hold deadline elapsed before the ledger was read\n"
  __iyi_exit(76)
end
if freed != 0
  puts "FAIL: skipping: a task marked running before its switch lost live nodes"
  __iyi_exit(1)
end
puts "skipping: held=1 collected=1 expired=0 freed=0"
__iyi_exit(0)
{% end %}
while Tally.finished.value.get < 12_u64
  GC.collect
  sleep(1)
end
threads.each { |th| th.join }
puts "wrong=#{Tally.wrong.value.get}"
IYI
if ! "$IYI" build switching.iyi -o switching > build-switching.log 2>&1; then
  echo "SETUP: ${current_step:-build}: switching did not build"; cat build-switching.log; exit 76
fi
run=1
while [ "$run" -le 5 ]; do
  timeout 120 ./switching > switching.txt 2>&1
  code=$?; check_bound "$code" healthy "run $run"
  if [ "$code" -eq 76 ]; then cat switching.txt; exit 76; fi
  if [ "$code" -ne 0 ] || ! grep -q '^wrong=0$' switching.txt; then
    echo "FAIL: ${current_step}: run $run exited $code:"; tail -3 switching.txt; exit 1
  fi
  run=$((run + 1))
done
echo "  five runs, no list lost"

# Hold the switch before the planted early Running write is followed by a
# context swap. A single collection must free nodes belonging to the skipped
# target; the mmap ledger observes the free flags without reading freed nodes.
step "failure proof: a fiber marked running before the switch loses its list"
mkdir -p skipping/iyi
cp "$REPO"/src/iyi/*.iyi skipping/iyi/
# The gate's functions go into the copy's thread.iyi, before its roots.
splice_gate() {
  awk -v gate=gate.part '
    /^      fun thread_switch\(thread : UInt32, option : Int32, time : UInt32\) : Int32$/ { print; print "      fun thread_gate_exit = _exit(status : Int32) : NoReturn"; darwin_exit++; next }
    /^    # ── Roots/ { while ((getline line < gate) > 0) print line; roots++ }
    { print }
    END { if (roots != 1 || darwin_exit != 1) exit 3 }
  ' "$REPO/src/iyi/thread.iyi" > "$1"
}
splice_gate skipping/iyi/thread.iyi || { echo "SETUP: skipping: the mutant roots anchor changed"; exit 76; }
awk '
  /^    st.current = fiber$/ { print "    fiber.state = IyiFiberState::Running"; print "    IyiThread.release_gate_hold(IyiThread.current_line, \"SETUP: skipping: held switch gate timed out\\n\")"; found++ }
  { print }
  END { if (found != 1) exit 3 }
' "$REPO/src/iyi/concurrency.iyi" > skipping/iyi/concurrency.iyi || { echo "SETUP: skipping: the mutant current-fiber anchor changed"; exit 76; }
if ! IYI_PATH="$WORK/skipping${PSEP}$REPO/src" "$IYI" build switching.iyi -Dskipping_force -o skipping-run > build-skipping.log 2>&1; then
  echo "SETUP: ${current_step:-build}: skipping did not build"; cat build-skipping.log; exit 76
fi
timeout 120 ./skipping-run > skipping.txt 2>&1
code=$?; check_bound "$code" forced mutant skipping.txt
if [ "$code" -eq 76 ]; then cat skipping.txt; exit 76; fi
if [ "$code" -ne 1 ] || ! tr -d '\r' < skipping.txt | grep -qxF 'FAIL: skipping: a task marked running before its switch lost live nodes'; then
  pair_mismatch "$code" skipping.txt mutant 0 'skipping: held=1 collected=1 expired=0 freed=0'
fi
printf '  exits 1 at "%s"\n' 'FAIL: skipping: a task marked running before its switch lost live nodes'

# The same hold after the switch scans both lists, so no node is free.
step "the same hold after the switch, with the fiber already running: every list holds"
mkdir -p skipping-ctl/iyi
cp "$REPO"/src/iyi/*.iyi skipping-ctl/iyi/
splice_gate skipping-ctl/iyi/thread.iyi || { echo "SETUP: skipping: the control roots anchor changed"; exit 76; }
awk '
  /^    current.state = IyiFiberState::Running$/ { print; print "    IyiThread.release_gate_hold(IyiThread.current_line, \"SETUP: skipping: held switch gate timed out\\n\")"; found++; next }
  { print }
  END { if (found != 1) exit 3 }
' "$REPO/src/iyi/concurrency.iyi" > skipping-ctl/iyi/concurrency.iyi || { echo "SETUP: skipping: the control running-write anchor changed"; exit 76; }
if ! IYI_PATH="$WORK/skipping-ctl${PSEP}$REPO/src" "$IYI" build switching.iyi -Dskipping_force -o skipping-ctl-run > build-skipping-ctl.log 2>&1; then
  echo "SETUP: ${current_step:-build}: skipping-ctl did not build"; cat build-skipping-ctl.log; exit 76
fi
timeout 120 ./skipping-ctl-run > skipping-ctl.txt 2>&1
code=$?; check_bound "$code" forced control skipping-ctl.txt
if [ "$code" -eq 76 ]; then cat skipping-ctl.txt; exit 76; fi
if [ "$code" -ne 0 ] || ! grep -qxF 'skipping: held=1 collected=1 expired=0 freed=0' skipping-ctl.txt; then
  pair_mismatch "$code" skipping-ctl.txt control
fi
echo "  hook-only control: held=1 collected=1 expired=0 freed=0"

# Windows can run a thread on into take after SuspendThread returns. The
# same-hook control below forces that rendezvous, confirms the owner was
# deferred, and checks a live list held on its stack through the collection.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    # One forced rendezvous replaces the former five 2 ms searches.
    # ── 15. The handshake: the armed thread is held inside `take` ─────────
    # The same rendezvous runs in both copies: the stopper first sees the
    # armed owner outside `take`, lets it enter the fast path, suspends it
    # again, and captures its actual registers and sp. The control reads the
    # allocator depth after that capture, as shipped. The broken copy uses
    # the earlier depth instead. A world-stopped snapshot distinguishes a
    # deferred owner from one incorrectly held inside the allocator.
    cat > early.part <<'IYI'
    # Copy-only state for the forced run-on after the first context capture.
    IYI_EARLY_TARGET  = 384_u64
    IYI_EARLY_GO      = 448_u64
    IYI_EARLY_HELD    = 512_u64
    IYI_EARLY_OPEN    = 576_u64
    IYI_EARLY_LAPSED  = 640_u64
    IYI_EARLY_ARMED   = 704_u64
    IYI_EARLY_SEEN    = 768_u64
    IYI_EARLY_BEFORE  = 832_u64
    IYI_EARLY_AFTER   = 896_u64
    IYI_EARLY_SP2     = 960_u64
    IYI_EARLY_STOPPED = 1024_u64
    IYI_EARLY_PARKED  = 1088_u64
    IYI_EARLY_SAME_SP = 1152_u64
    IYI_EARLY_SNAPSHOT = 1216_u64

    def self.early_setup : Nil
      word(control + IYI_EARLY_ARMED).value.set(0_u64)
    end

    def self.early_arm : Nil
      page = control
      word(page + IYI_EARLY_ARMED).value.set(@@line)
      word(page + IYI_EARLY_TARGET).value.set(@@line)
    end

    def self.early_target?(line : UInt64) : Bool
      line != 0_u64 && word(control + IYI_EARLY_TARGET).value.get == line
    end

    def self.early_go? : Bool
      go = word(control + IYI_EARLY_GO).value.get
      go != 0_u64 && go == @@line
    end

    def self.early_open : Nil
      word(control + IYI_EARLY_OPEN).value.set(1_u64)
    end

    def self.early_take_hook : Nil
      # Allocations before early_setup must not race to create control.
      page = @@control
      return if page == 0_u64
      go = word(page + IYI_EARLY_GO).value.get
      return if go == 0_u64 || go != @@line
      began = IyiMark.now_ns
      word(page + IYI_EARLY_HELD).value.set(1_u64)
      while word(page + IYI_EARLY_OPEN).value.get == 0_u64
        if IyiMark.now_ns &- began >= 5000000000_u64
          message = "SETUP: early: the gate inside take never opened\n"
          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
          __iyi_exit(76)
        end
        spin_pause
      end
    end

    # A setup failure of the rendezvous ends the run here, by its own named
    # sentence, before any path reaches the scanner with a stale stack
    # pointer. The stopper writes and exits; it never returns a stale sp.
    def self.early_setup_fail(message : String) : Nil
      __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
      __iyi_exit(76)
    end

    def self.early_rendezvous(cursor : UInt64, handle : Pointer(Void), sp : UInt64) : UInt64
      page = control
      return sp unless early_target?(cursor)
      word(page + IYI_EARLY_TARGET).value.set(0_u64)
      cache = IyiHeap.read64(cursor + IYI_TL_CACHE)
      before = IyiHeap.cache_inside?(cache) ? 1_u64 : 0_u64
      word(page + IYI_EARLY_BEFORE).value.set(before)
      word(page + IYI_EARLY_SEEN).value.set(1_u64)
      return sp if before != 0_u64
      word(page + IYI_EARLY_GO).value.set(cursor)
      if LibC.ResumeThread(handle) != 1_i32
        early_setup_fail("SETUP: early: the armed thread could not be resumed\n")
      end
      began = IyiMark.now_ns
      while word(page + IYI_EARLY_HELD).value.get == 0_u64
        if IyiMark.now_ns &- began >= 5000000000_u64
          word(page + IYI_EARLY_LAPSED).value.set(1_u64)
          word(page + IYI_EARLY_GO).value.set(0_u64)
          early_setup_fail("SETUP: early: the armed thread never reached the hook inside take\n")
        end
        yield_cpu
      end
      word(page + IYI_EARLY_GO).value.set(0_u64)
      if LibC.SuspendThread(handle) != 0_i32
        early_setup_fail("SETUP: early: the armed thread could not be suspended\n")
      end
      captured = IyiRoots.capture_thread_registers(handle, cursor + IYI_TL_SPILL)
      if captured == 0_u64
        word(page + IYI_EARLY_LAPSED).value.set(2_u64)
        early_setup_fail("SETUP: early: the second context capture returned no stack\n")
      end
      word(page + IYI_EARLY_AFTER).value.set(IyiHeap.cache_inside?(cache) ? 1_u64 : 0_u64)
      word(page + IYI_EARLY_SP2).value.set(captured)
      early_open
      captured
    end

    # Called after the stop's deferral wait, before the marker reads roots.
    def self.early_stopped : Nil
      page = control
      return if word(page + IYI_EARLY_SEEN).value.get == 0_u64
      return if word(page + IYI_EARLY_SNAPSHOT).value.get != 0_u64
      line = word(page + IYI_EARLY_ARMED).value.get
      cache = IyiHeap.read64(line + IYI_TL_CACHE)
      captured = word(page + IYI_EARLY_SP2).value.get
      word(page + IYI_EARLY_STOPPED).value.set(IyiHeap.cache_inside?(cache) ? 1_u64 : 0_u64)
      word(page + IYI_EARLY_PARKED).value.set(word(page + IYI_TC_SUSPENDED).value.get)
      same = captured != 0_u64 && IyiHeap.read64(line + IYI_TL_SP) == captured
      word(page + IYI_EARLY_SAME_SP).value.set(same ? 1_u64 : 0_u64)
      word(page + IYI_EARLY_SNAPSHOT).value.set(1_u64)
    end

    def self.early_value(offset : UInt64) : UInt64
      word(control + offset).value.get
    end
IYI
    # Both copies run the same rendezvous after the first capture. Only the
    # broken copy moves the allocator-depth decision before that capture.
    early_thread() {
      awk -v gate=early.part -v mode="$1" '
        /^    # ── Roots/ { while ((getline line < gate) > 0) print line; roots++ }
        /^            sp = IyiRoots\.capture_thread_registers\(handle, cursor \+ IYI_TL_SPILL\)$/ {
          if (mode == "forced") {
            print "            early_armed = IyiThread.early_target?(cursor)"
            print "            early_inside = false"
            print "            early_inside = IyiHeap.cache_inside?(IyiHeap.read64(cursor + IYI_TL_CACHE)) if early_armed"
          }
          print
          print "            sp = IyiThread.early_rendezvous(cursor, handle, sp)"
          capture++; next
        }
        mode == "forced" && /^            if IyiHeap\.cache_inside\?\(cache\)$/ {
          print "            if (early_armed && early_inside) || (!early_armed && IyiHeap.cache_inside?(cache))"
          decision++; next
        }
        /^        while word\(page \+ IYI_TC_SUSPENDED\)\.value\.get < deferred\.to_u64$/ {
          print "        early_deadline = IyiMark.now_ns &+ 20000000000_u64"
          print
          print "          if IyiMark.now_ns >= early_deadline"
          print "            message = \"SETUP: early: the deferred owner never parked\\n\""
          print "            __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)"
          print "            __iyi_exit(76)"
          print "          end"
          bounded++; next
        }
        /^      IyiStat\.bump\(IyiStat::STOPS, 1_u64\)$/ { print "      IyiThread.early_stopped"; snapshot++ }
        { print }
        END { if (roots != 1 || capture != 1 || bounded != 1 || snapshot != 1 || (mode == "forced" && decision != 1)) exit 3 }
      ' "$REPO/src/iyi/thread.iyi" > "$2"
    }
    # The copy of prelude.iyi: `take`'s fast path calls the hook after its stamp.
    early_prelude() {
      awk '
        /^      def self\.take\(size : UInt64, clear : Bool, bits : UInt64, type_id : UInt64\) : UInt64$/ { declarations++; intake = 1; print; next }
        intake && /^      end$/ { intake = 0; closures++; print; next }
        intake && /^ *stamp\(table, index, head, bits, type_id\)$/ { ind = substr($0, 1, match($0, /[^ ]/) - 1); print; print ind "IyiThread.early_take_hook"; stamps++; next }
        { print }
        END { if (declarations != 1 || closures != 1 || stamps != 1) exit 3 }
      ' "$REPO/src/iyi/prelude.iyi" > "$1"
    }
    cat > early.iyi <<'IYI'
@[Unsafe("the live-list ledger stores non-root addresses in a private mapping")]
module early

class Flag
  getter waiting : Atomic(Int64)
  getter release : Atomic(Int64)
  getter list_ok : Atomic(Int64)

  def initialize
    @waiting = Atomic(Int64).new(0_i64)
    @release = Atomic(Int64).new(0_i64)
    @list_ok = Atomic(Int64).new(0_i64)
  end
end

class Node
  getter value : Int64
  getter next_node : Node?

  def initialize(@value : Int64, @next_node : Node?)
  end
end

def fill(n : Int32) : Node?
  head = nil.as(Node?)
  n.times { |i| head = Node.new(999_i64, head) }
  head
end

@[UnsafeReach("the ledger mapping records addresses without making them roots")]
class EarlyLedger
  @@page = 0_u64
  def self.setup : Nil
    @@page = __iyi_mmap(4096_u64).address
  end
  def self.record(head : Node?) : Nil
    node = head
    i = 0
    while node.is_a?(Node) && i < 300
      Pointer(Atomic(UInt64)).new(@@page + i.to_u64 * 8_u64).value.set(node.object_id)
      node = node.next_node
      i += 1
    end
    if i != 300 || node.is_a?(Node)
      print "SETUP: early: the live-list ledger was not populated\n"
      __iyi_exit(76)
    end
  end
  def self.freed : Int32
    count = 0
    300.times do |i|
      address = Pointer(Atomic(UInt64)).new(@@page + i.to_u64 * 8_u64).value.get
      if address == 0_u64
        print "SETUP: early: the live-list ledger has an empty slot\n"
        __iyi_exit(76)
      end
      count += 1 if IyiMark.flags(address) & IyiHeap::FREE_FLAG != 0
    end
    count
  end
end


{% if flag?(:early_force) %}
IyiMark.auto = false
IyiMark.workers = 0_u64
IyiThread.early_setup
EarlyLedger.setup
{% end %}
flag = Flag.new
owner = IyiThread.start do
  held_list = fill(300)
  EarlyLedger.record(held_list)
  warm = fill(400)
  warm = nil
  IyiThread.early_arm
  flag.waiting.set(1_i64)
  deadline = IyiMark.now_ns &+ 20000000000_u64
  while !IyiThread.early_go? && flag.release.get == 0_i64
    if IyiMark.now_ns >= deadline
      print "SETUP: early: the owner was never let go\n"
      __iyi_exit(76)
    end
    IyiThread.spin_pause
  end
  kept = Node.new(42_i64, nil)
  if IyiThread.early_value(IyiThread::IYI_EARLY_STOPPED) == 0_u64
    count = 0
    node = held_list
    while node.is_a?(Node)
      break unless node.value == 999_i64
      count += 1
      node = node.next_node
    end
    flag.list_ok.set(1_i64) if count == 300
  end
  kept.value
end
deadline = IyiMark.now_ns &+ 20000000000_u64
while flag.waiting.get == 0_i64
  if IyiMark.now_ns >= deadline
    print "SETUP: early: the owner never armed\n"
    __iyi_exit(76)
  end
  IyiThread.yield_cpu
end
IyiMark.collect
flag.release.set(1_i64)
IyiThread.early_open
owner.join
lapsed = IyiThread.early_value(IyiThread::IYI_EARLY_LAPSED)
if lapsed == 1_u64
  print "SETUP: early: the armed thread never reached the hook inside take\n"
  __iyi_exit(76)
end
if lapsed == 2_u64
  print "SETUP: early: the second context capture returned no stack\n"
  __iyi_exit(76)
end
held = IyiThread.early_value(IyiThread::IYI_EARLY_HELD)
seen = IyiThread.early_value(IyiThread::IYI_EARLY_SEEN)
before = IyiThread.early_value(IyiThread::IYI_EARLY_BEFORE)
after = IyiThread.early_value(IyiThread::IYI_EARLY_AFTER)
snapshot = IyiThread.early_value(IyiThread::IYI_EARLY_SNAPSHOT)
stopped = IyiThread.early_value(IyiThread::IYI_EARLY_STOPPED)
parked = IyiThread.early_value(IyiThread::IYI_EARLY_PARKED)
same_sp = IyiThread.early_value(IyiThread::IYI_EARLY_SAME_SP)
puts "early: held=#{held} before=#{before} after=#{after} stopped=#{stopped} parked=#{parked}"
if held != 1_u64 || seen != 1_u64 || before != 0_u64 || after != 1_u64 || snapshot != 1_u64
  print "SETUP: early: the rendezvous did not take the armed thread from outside take to inside it\n"
  __iyi_exit(76)
end
if stopped == 1_u64 && parked == 0_u64 && same_sp == 1_u64
  puts "early: the second captured sp was stored on the stopped line"
  print "FAIL: early: a stop held a thread inside take on a decision read before it went in\n"
  __iyi_exit(1)
end
if stopped != 0_u64 || parked != 1_u64
  print "SETUP: early: the stop neither parked nor held the armed thread\n"
  __iyi_exit(76)
end
if EarlyLedger.freed != 0 || flag.list_ok.get != 1_i64
  print "FAIL: early: the deferred thread's live list was not preserved\n"
  __iyi_exit(1)
end
puts "early: the deferred thread's 300-node live list remained intact"
puts "early: the stop deferred the thread after the second context capture"
IYI
    step "the late context capture is followed by a fresh allocator-depth check"
    mkdir -p early-ctl/iyi early-fz/iyi
    cp "$REPO"/src/iyi/*.iyi early-ctl/iyi/
    early_prelude early-ctl/iyi/prelude.iyi || { echo "SETUP: early: the take fast-path anchors changed"; exit 76; }
    early_thread control early-ctl/iyi/thread.iyi || { echo "SETUP: early: the thread anchors changed"; exit 76; }
    if ! IYI_PATH="$WORK/early-ctl${PSEP}$REPO/src" "$IYI" build early.iyi -Dearly_force -o early-ctl-run > build-early-ctl.log 2>&1; then
      echo "SETUP: early: the control copy did not build"; cat build-early-ctl.log; exit 76
    fi
    win_native 60 "the late-capture control" ./early-ctl-run > early-ctl-raw.txt 2>&1
    code=$?; check_bound "$code" forced control early-ctl-raw.txt
    if [ "$code" -eq 76 ]; then cat early-ctl-raw.txt; exit 76; fi
    tr -d '\r' < early-ctl-raw.txt > early-ctl.txt
    if [ "$code" -ne 0 ] || ! grep -qxF 'early: held=1 before=0 after=1 stopped=0 parked=1' early-ctl.txt || ! grep -qxF 'early: the stop deferred the thread after the second context capture' early-ctl.txt || ! grep -qxF "early: the deferred thread's 300-node live list remained intact" early-ctl.txt; then
      pair_mismatch "$code" early-ctl.txt control
    fi
    printf '  control: exit 0, %s\n' "$(grep -m1 '^early: held=' early-ctl.txt)"
    step "failure proof: a stop uses the allocator depth read before the second context capture"
    cp "$REPO"/src/iyi/*.iyi early-fz/iyi/
    early_prelude early-fz/iyi/prelude.iyi || { echo "SETUP: early: the take fast-path anchors changed"; exit 76; }
    early_thread forced early-fz/iyi/thread.iyi || { echo "SETUP: early: the thread anchors changed"; exit 76; }
    if ! IYI_PATH="$WORK/early-fz${PSEP}$REPO/src" "$IYI" build early.iyi -Dearly_force -o early-fz-run > build-early-fz.log 2>&1; then
      echo "SETUP: early: the mutant copy did not build"; cat build-early-fz.log; exit 76
    fi
    win_native 60 "the stale-decision proof" ./early-fz-run > early-fz-raw.txt 2>&1
    code=$?; check_bound "$code" forced mutant early-fz-raw.txt
    if [ "$code" -eq 76 ]; then cat early-fz-raw.txt; exit 76; fi
    tr -d '\r' < early-fz-raw.txt > early-fz.txt
    if [ "$code" -ne 1 ] || ! grep -qxF 'early: held=1 before=0 after=1 stopped=1 parked=0' early-fz.txt || ! grep -qxF 'early: the second captured sp was stored on the stopped line' early-fz.txt || ! grep -qxF 'FAIL: early: a stop held a thread inside take on a decision read before it went in' early-fz.txt; then
      pair_mismatch "$code" early-fz.txt mutant 0 'early: held=1 before=0 after=1 stopped=0 parked=1' 'early: the stop deferred the thread after the second context capture' "early: the deferred thread's 300-node live list remained intact"
    fi
    printf '  exits 1 at "%s" (%s)\n' 'FAIL: early: a stop held a thread inside take on a decision read before it went in' "$(grep -m1 '^early: held=' early-fz.txt)"
    ;;
esac

# ── 5d. The first collection's helpers ────────────────────────────────────
# Hold one trigger between the helper count and its decided flag, before
# the runtime lock. A second trigger enters while it is held, and each
# reports the actual `wanted` local used by collect_if_due. The control
# starts those helpers and finishes its first collection; the copy with
# just the two decision writes reversed reports the mismatch.
cat > first.part <<'IYI'
    IYI_FIRST_A_LINE    = 3584_u64
    IYI_FIRST_HELD      = 3648_u64
    IYI_FIRST_B_BETWEEN = 3712_u64
    IYI_FIRST_B_READ    = 3776_u64
    IYI_FIRST_CHECKED   = 3840_u64
    IYI_FIRST_STARTED   = 3904_u64

    def self.first_say(message : String, status : Int32) : Nil
      __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
      {% if flag?(:darwin) %}
        LibC.first_proof_exit(status)
      {% elsif flag?(:win32) %}
        LibC.TerminateProcess(LibC.GetCurrentProcess, status)
        LibC.ExitProcess(status)
      {% else %}
        __iyi_exit(status)
      {% end %}
    end

    def self.first_init : Nil
      page = control
      first_say("SETUP: first helpers: the control page was not mapped\n", 76) if page == 0_u64
      offset = IYI_FIRST_A_LINE
      while offset <= IYI_FIRST_STARTED
        word(page + offset).value.set(0_u64)
        offset = offset + 64_u64
      end
    end

    def self.first_value(offset : UInt64) : UInt64
      word(control + offset).value.get
    end

    def self.first_wait(offset : UInt64, message : String) : Nil
      page = @@control
      first_say("SETUP: first helpers: the control page was not initialized\n", 76) if page == 0_u64
      began = IyiMark.now_ns
      while word(page + offset).value.get == 0_u64
        first_say(message, 76) if IyiMark.now_ns &- began > 20000000000_u64
        yield_cpu
      end
    end

    def self.first_claim : Nil
      page = @@control
      if page == 0_u64 || @@line == 0_u64
        first_say("SETUP: first helpers: the first trigger has no thread line\n", 76)
      end
      if word(page + IYI_FIRST_A_LINE).value.get != 0_u64
        first_say("SETUP: first helpers: the first trigger was already claimed\n", 76)
      end
      word(page + IYI_FIRST_A_LINE).value.set(@@line)
    end

    # Both copies call here between the two real writes. The second
    # trigger records its visit but does not wait in this hook.
    def self.first_between : Nil
      page = @@control
      return if page == 0_u64
      owner = word(page + IYI_FIRST_A_LINE).value.get
      first_say("SETUP: first helpers: a decision had no first trigger\n", 76) if owner == 0_u64 || @@line == 0_u64
      if @@line == owner
        word(page + IYI_FIRST_HELD).value.set(1_u64)
        first_wait(IYI_FIRST_B_READ, "SETUP: first helpers: the second trigger did not read the count\n")
      else
        if word(page + IYI_FIRST_HELD).value.get == 0_u64
          first_say("SETUP: first helpers: the second trigger entered before the hold\n", 76)
        end
        word(page + IYI_FIRST_B_BETWEEN).value.set(1_u64)
      end
    end

    # Called after the `if (wanted = ...)` block, even when wanted is
    # zero. The second trigger stays off the lock until the first compares
    # its own local with that snapshot.
    def self.first_snapshot(wanted : UInt64) : Nil
      page = @@control
      return if page == 0_u64
      owner = word(page + IYI_FIRST_A_LINE).value.get
      if owner == 0_u64 || @@line == 0_u64 || word(page + IYI_FIRST_HELD).value.get == 0_u64
        first_say("SETUP: first helpers: a snapshot had no held first trigger\n", 76)
      end
      if @@line == owner
        other = word(page + IYI_FIRST_B_READ).value.get
        if other == 0_u64
          first_say("SETUP: first helpers: the second trigger did not read the count\n", 76)
        end
        if wanted == 0_u64
          first_say("SETUP: first helpers: the first trigger read no helpers\n", 76)
        end
        if wanted + 1_u64 != other
          first_say("FAIL: first helpers: the helper decision was published before the count\n", 1)
        end
        if word(page + IYI_FIRST_B_BETWEEN).value.get != 1_u64
          first_say("SETUP: first helpers: the second trigger did not take the decision path\n", 76)
        end
        word(page + IYI_FIRST_CHECKED).value.set(wanted + 1_u64)
      else
        if word(page + IYI_FIRST_B_READ).value.get != 0_u64
          first_say("SETUP: first helpers: more than one second snapshot arrived\n", 76)
        end
        word(page + IYI_FIRST_B_READ).value.set(wanted + 1_u64)
        first_wait(IYI_FIRST_CHECKED, "SETUP: first helpers: the first trigger did not check its count\n")
      end
    end

    # `count` is @@helpers immediately after the real start_helpers call.
    def self.first_started(count : UInt64) : Nil
      page = @@control
      word(page + IYI_FIRST_STARTED).value.set(count) if page != 0_u64
    end
IYI

first_thread_copy() {
  awk -v part=first.part '
    /^  \{% elsif flag\?\(:darwin\) %\}$/ { darwin = 1 }
    /^  \{% elsif flag\?\(:win32\) %\}$/ { darwin = 0 }
    darwin && /^    lib LibC$/ { inlib = 1; libs++ }
    darwin && inlib && /^    end$/ { inlib = 0; lib_ends++ }
    darwin && inlib && /^      fun thread_switch\(thread : UInt32, option : Int32, time : UInt32\) : Int32$/ {
      print
      print "      fun first_proof_exit = _exit(status : Int32) : NoReturn"
      exits++
      next
    }
    /^  class IyiThread$/ { inthread = 1; threads++ }
    inthread && /^  end$/ { inthread = 0; thread_ends++ }
    inthread && /^    # ── Roots / {
      while ((getline line < part) > 0) { print line; part_lines++ }
      close(part)
      roots++
    }
    { print }
    END {
      if (libs != 1 || lib_ends != 1 || exits != 1 || threads != 1 ||
          thread_ends != 1 || roots != 1 || part_lines == 0) exit 3
    }
  ' "$REPO/src/iyi/thread.iyi"
}

first_prelude_copy() {
  awk -v mode="$1" '
    /^    class IyiMark$/ { mark = 1; marks++ }
    mark && /^    end$/ { mark = 0; mark_ends++ }
    mark && /^      def self\.collect_if_due : Nil$/ { due = 1; dues++ }
    mark && /^      def self\.decide_helpers : Nil$/ {
      decisions++
      print "      def self.first_fresh? : Bool"
      print "        !@@helpers_decided && !@@workers_set && @@helpers_wanted == 0_u64 && @@helpers == 0_u64"
      print "      end"
      print ""
      decision = 1
    }
    due && /^      end$/ {
      due = 0
      due_ends++
    }
    decision && /^      end$/ {
      if (pending) bad = 1
      decision = 0
      decision_ends++
    }
    decision && /^        return if @@helpers_decided$/ { returns++ }
    decision && /^        @@helpers_wanted = default_helpers unless @@workers_set$/ {
      counts++
      pending = 1
      count_line = $0
      if (mode == "control") {
        print
        print "        IyiThread.first_between"
      }
      next
    }
    decision && /^        @@helpers_decided = true$/ {
      flags++
      if (!pending) bad = 1
      if (mode == "mutant") {
        print
        print "        IyiThread.first_between"
        print count_line
      } else {
        print
      }
      pending = 0
      next
    }
    decision && pending { bad = 1 }
    due && /^          if \(wanted = @@helpers_wanted\) > 0_u64$/ {
      reads++
      inread = 1
    }
    due && inread && /^            IyiThread\.register_current$/ { registrations++ }
    due && inread && /^            IyiThread\.install_handler$/ { handlers++ }
    due && inread && /^          end$/ {
      read_ends++
      inread = 0
      print
      print "          IyiThread.first_snapshot(wanted)"
      next
    }
    due && /^          start_helpers\(wanted\)$/ {
      starts++
      print
      print "          IyiThread.first_started(@@helpers)"
      next
    }
    { print }
    END {
      if ((mode != "control" && mode != "mutant") || marks != 1 ||
          mark_ends != 1 || dues != 1 || due_ends != 1 || decisions != 1 ||
          decision_ends != 1 || returns != 1 || counts != 1 || flags != 1 ||
          reads != 1 || registrations != 1 || handlers != 1 || read_ends != 1 ||
          starts != 1 || pending || bad) exit 3
    }
  ' "$REPO/src/iyi/prelude.iyi"
}

# Undo only the declared swap and compare the entire result, not just its
# length. All other copied runtime files must be byte-identical as well.
first_normalize_mutant() {
  awk '
    /^      def self\.decide_helpers : Nil$/ { decision = 1; declarations++ }
    decision && /^      end$/ { decision = 0; endings++ }
    decision && /^        @@helpers_decided = true$/ {
      flag = $0
      if ((getline hook) <= 0 || (getline count) <= 0) { bad = 1; next }
      if (hook != "        IyiThread.first_between" ||
          count != "        @@helpers_wanted = default_helpers unless @@workers_set") bad = 1
      print count
      print hook
      print flag
      swaps++
      next
    }
    { print }
    END { if (declarations != 1 || endings != 1 || swaps != 1 || bad) exit 3 }
  ' first-mutant/iyi/prelude.iyi
}

cat > first.iyi <<'IYI'
@[Unsafe("the first-decision witnesses are atomic words in the runtime control page")]
module first

# No automatic collection may decide the helpers before the held trigger.
IyiMark.auto = false
if IyiMark.collections != 0_u64 || !IyiMark.first_fresh?
  IyiThread.first_say("SETUP: first helpers: the helper decision was not fresh\n", 76)
end
expected = IyiMark.default_helpers
if expected == 0_u64
  IyiThread.first_say("SETUP: first helpers: the default helper count was not positive\n", 76)
end
before = IyiMark.collections

# Go through the real allocator with auto disabled, then enter the real
# trigger directly from both registered threads. This leaves the trigger
# above budget without letting an allocation decide the count first.
block = Pointer(UInt8).malloc(IyiMark.budget + 4096_u64)
block.value = 1_u8
if IyiMark.allocated_since < IyiMark.budget
  IyiThread.first_say("SETUP: first helpers: the allocation did not cross the budget\n", 76)
end
IyiThread.first_init
reader = IyiThread.start do
  IyiThread.first_wait(IyiThread::IYI_FIRST_HELD, "SETUP: first helpers: the first trigger did not reach the hold\n")
  IyiMark.collect_if_due
  nil
end
if IyiMark.collections != before || !IyiMark.first_fresh?
  IyiThread.first_say("SETUP: first helpers: the helper decision was not fresh\n", 76)
end
holder = IyiThread.start do
  IyiThread.first_claim
  IyiMark.collect_if_due
  nil
end
holder.join
reader.join
IyiMark.settle

if IyiThread.first_value(IyiThread::IYI_FIRST_A_LINE) == 0_u64 ||
   IyiThread.first_value(IyiThread::IYI_FIRST_HELD) != 1_u64 ||
   IyiThread.first_value(IyiThread::IYI_FIRST_B_BETWEEN) != 1_u64 ||
   IyiThread.first_value(IyiThread::IYI_FIRST_B_READ) != expected + 1_u64 ||
   IyiThread.first_value(IyiThread::IYI_FIRST_CHECKED) != expected + 1_u64
  IyiThread.first_say("SETUP: first helpers: the two decision witnesses were incomplete\n", 76)
end
if IyiThread.first_value(IyiThread::IYI_FIRST_STARTED) != expected
  IyiThread.first_say("SETUP: first helpers: the real helper start count did not match\n", 76)
end
if IyiMark.collections <= before
  IyiThread.first_say("SETUP: first helpers: the first collection did not finish\n", 76)
end
puts "first helpers: both triggers read the same positive count and the first collection finished"
IYI

step "the first helper decision beside a second trigger"
for first_mode in control mutant; do
  mkdir -p "first-$first_mode/iyi" || { echo "SETUP: first helpers: the runtime copy directory could not be created"; exit 76; }
  cp "$REPO"/src/iyi/*.iyi "first-$first_mode/iyi/" || { echo "SETUP: first helpers: the runtime copy could not be made"; exit 76; }
  first_thread_copy > "first-$first_mode/iyi/thread.iyi" || { echo "SETUP: first helpers: the thread hook anchors changed"; exit 76; }
  first_prelude_copy "$first_mode" > "first-$first_mode/iyi/prelude.iyi" || { echo "SETUP: first helpers: the collector hook anchors changed"; exit 76; }
done
first_normalize_mutant > first-normalized.iyi || { echo "SETUP: first helpers: the mutant write-order anchors changed"; exit 76; }
if ! cmp -s first-control/iyi/prelude.iyi first-normalized.iyi; then
  echo "SETUP: first helpers: the copies differ in more than the write order"; exit 76
fi
for first_source in "$REPO"/src/iyi/*.iyi; do
  first_file="${first_source##*/}"
  [ "$first_file" = prelude.iyi ] && continue
  if ! cmp -s "first-control/iyi/$first_file" "first-mutant/iyi/$first_file"; then
    echo "SETUP: first helpers: the copies differ in more than the write order"; exit 76
  fi
done

first_success='first helpers: both triggers read the same positive count and the first collection finished'
first_failure='FAIL: first helpers: the helper decision was published before the count'
for first_mode in control mutant; do
  if ! IYI_PATH="$WORK/first-$first_mode${PSEP}$REPO/src" "$IYI" build first.iyi -o "first-$first_mode-run" > "build-first-$first_mode.log" 2>&1; then
    echo "SETUP: first helpers: the $first_mode copy did not build"
    cat "build-first-$first_mode.log"
    exit 76
  fi
done
for first_mode in control mutant; do
  timeout 120 "./first-$first_mode-run" > "first-$first_mode-raw.txt" 2>&1
  code=$?; check_bound "$code" forced "$first_mode" "first-$first_mode-raw.txt"
  tr -d '\r' < "first-$first_mode-raw.txt" > "first-$first_mode.txt"
  if grep -q '^SETUP:' "first-$first_mode.txt"; then
    cat "first-$first_mode.txt"
    exit 76
  fi
  if [ "$code" -eq 76 ]; then
    echo "SETUP: first helpers: the $first_mode exited without a setup sentence"
    cat "first-$first_mode.txt"
    exit 76
  fi
  if [ "$first_mode" = control ]; then
    if [ "$code" -eq 1 ] && [ "$(grep -c '^FAIL:' "first-$first_mode.txt")" -eq 1 ] && grep -qxF "$first_failure" "first-$first_mode.txt"; then
      cat "first-$first_mode.txt"
      exit 1
    fi
    if [ "$code" -ne 0 ] || ! grep -qxF "$first_success" "first-$first_mode.txt" ||
       grep -q '^FAIL:' "first-$first_mode.txt"; then
      pair_mismatch "$code" "first-$first_mode.txt" control
    fi
    printf '  control: exit 0, %s\n' "$first_success"
  else
    if [ "$code" -ne 1 ] || [ "$(grep -c '^FAIL:' "first-$first_mode.txt")" -ne 1 ] ||
       ! grep -qxF "$first_failure" "first-$first_mode.txt"; then
      pair_mismatch "$code" "first-$first_mode.txt" mutant 0 "$first_success"
    fi
    printf '  exits 1 at "%s"\n' "$first_failure"
  fi
done

# ── 5e. A line `puts` writes is one write ─────────────────────────────────
# Hold a real synchronous line write after its first write, then make another
# thread write a line before releasing it. The verdict is the resulting bytes.
step "whole lines: a competing write cannot split a line"
if ! mkdir -p "$WORK/line-hold-control/iyi" "$WORK/line-hold-mutant/iyi"; then
  echo "SETUP: whole lines: the runtime copy directories could not be created"; exit 76
fi
if ! cp "$REPO"/src/iyi/*.iyi "$WORK/line-hold-control/iyi/" ||
   ! cp "$REPO"/src/iyi/*.iyi "$WORK/line-hold-mutant/iyi/"; then
  echo "SETUP: whole lines: the runtime copies could not be populated"; exit 76
fi
if ! cat > line_hold.part <<'IYI'
  LINE_HOLD_ARMED   =   0_u64
  LINE_HOLD_HELD    =  64_u64
  LINE_HOLD_WRITTEN = 128_u64
  @@line_hold : UInt64 = 0_u64

  def self.line_hold_word(offset : UInt64) : Pointer(Atomic(UInt64))
    Pointer(Atomic(UInt64)).new(@@line_hold + offset)
  end

  def self.line_hold_say(message : String, status : Int32) : Nil
    __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
    __iyi_exit(status)
  end

  def self.line_hold_wait(offset : UInt64, message : String) : Nil
    line_hold_say("SETUP: whole lines: the hold page was not initialized\n", 76) if @@line_hold == 0_u64
    began = IyiMark.now_ns
    while line_hold_word(offset).value.get == 0_u64
      line_hold_say(message, 76) if IyiMark.now_ns &- began > 20000000000_u64
      IyiThread.yield_cpu
    end
  end

  def self.line_hold_init : Nil
    @@line_hold = __iyi_mmap(4096_u64).address
    line_hold_say("SETUP: whole lines: the hold page was not mapped\n", 76) if @@line_hold == 0_u64
  end

  def self.line_hold_arm : Nil
    line_hold_word(LINE_HOLD_ARMED).value.set(1_u64)
  end

  def self.line_hold_between : Nil
    return if @@line_hold == 0_u64
    return if line_hold_word(LINE_HOLD_ARMED).value.swap(2_u64) != 1_u64
    line_hold_word(LINE_HOLD_HELD).value.set(1_u64)
    line_hold_wait(LINE_HOLD_WRITTEN, "SETUP: whole lines: the competing line was never written\n")
  end

  def self.line_hold_await_held : Nil
    line_hold_wait(LINE_HOLD_HELD, "SETUP: whole lines: the held line never reached its hold\n")
  end

  def self.line_hold_written : Nil
    line_hold_word(LINE_HOLD_WRITTEN).value.set(1_u64)
  end
IYI
then
  echo "SETUP: whole lines: the rendezvous could not be written"; exit 76
fi
if ! cat > line_hold.iyi <<'IYI'
IyiIO.line_hold_init
holder = IyiThread.start do
  IyiIO.line_hold_arm
  puts "held: this line was held after its first write"
  nil
end
competitor = IyiThread.start do
  IyiIO.line_hold_await_held
  puts "competing: this line was written whole while the other was held"
  IyiIO.line_hold_written
  nil
end
holder.join
competitor.join
IYI
then
  echo "SETUP: whole lines: the witness could not be written"; exit 76
fi
if ! awk -v part=line_hold.part '
  $0 == "  def write_line(text : String = \"\") : Nil" {
    while ((getline line < part) > 0) { print line; part_lines++ }
    close(part); print; defs++; after = 1; next
  }
  after { print; if ($0 !~ /^    write\(/) bad = 1; print "    IyiIO.line_hold_between"; hooks++; after = 0; next }
  { print }
  END { if (defs != 1 || hooks != 1 || bad || part_lines == 0) exit 3 }
' "$REPO/src/iyi/io.iyi" > "$WORK/line-hold-control/iyi/io.iyi"; then
  echo "SETUP: whole lines: the control rendezvous could not be placed"; exit 76
fi
line_pass='whole lines: the held line was written whole before the competing line'
line_fail='FAIL: whole lines: a competing line was written between a held line and its newline'
if ! printf 'held: this line was held after its first write\ncompeting: this line was written whole while the other was held\n' > line-hold-whole.expected ||
   ! printf 'held: this line was held after its first writecompeting: this line was written whole while the other was held\n\n' > line-hold-split.expected; then
  echo "SETUP: whole lines: the expected bytes could not be written"; exit 76
fi
for line_mode in control mutant; do
  if [ "$line_mode" = mutant ]; then
    if ! awk '
      $0 == "    write(@sync ? text + \"\\n\" : text)" { print "    write(text)"; firsts++; next }
      $0 == "    write(\"\\n\") unless @sync" { print "    write(\"\\n\")"; print "    flush if @sync"; seconds++; next }
      { print }
      END { if (firsts != 1 || seconds != 1) exit 3 }
    ' "$WORK/line-hold-control/iyi/io.iyi" > "$WORK/line-hold-mutant/iyi/io.iyi"; then
      echo "SETUP: whole lines: the split-write mutant could not be constructed"; exit 76
    fi
  fi
  if ! IYI_PATH="$WORK/line-hold-$line_mode${PSEP}$REPO/src" "$IYI" build line_hold.iyi -o "line-hold-$line_mode-run" > "build-line-hold-$line_mode.log" 2>&1; then
    echo "SETUP: whole lines: the $line_mode copy did not build"; cat "build-line-hold-$line_mode.log"; exit 76
  fi
  timeout 120 "./line-hold-$line_mode-run" > "line-hold-$line_mode.bytes" 2> "line-hold-$line_mode.err"
  code=$?
  check_bound "$code" healthy "$line_mode"
  if [ "$code" -ne 0 ]; then
    # The writer's own SETUP line, or a crash or defect in the program under
    # test. pair_mismatch decides which: a control is never filed as setup.
    if [ "$line_mode" = control ]; then pair_mismatch "$code" "line-hold-$line_mode.err" control; fi
    pair_mismatch "$code" "line-hold-$line_mode.err" mutant 0 "$line_pass"
  fi
  # The writer has exited and released the redirected handle before cmp.
  # Iyi's low-level writes emit LF bytes directly on Windows as on POSIX.
  (
    if cmp -s "line-hold-$line_mode.bytes" line-hold-whole.expected; then
      printf '%s\n' "$line_pass"
      exit 0
    elif cmp -s "line-hold-$line_mode.bytes" line-hold-split.expected; then
      printf '%s\n' "$line_fail"
      exit 1
    else
      # The control never printed its witness: setup. A mutant that ends on
      # neither byte sequence did not produce its witness, which is a defect.
      # Its line carries no SETUP prefix, and exit 2 reaches pair_mismatch.
      if [ "$line_mode" = control ]; then
        echo "SETUP: whole lines: the control output held neither byte sequence"
        exit 76
      fi
      echo "whole lines: the mutant output held neither byte sequence"
      exit 2
    fi
  ) > "line-hold-$line_mode.txt"
  code=$?
  if [ "$code" -eq 76 ]; then cat "line-hold-$line_mode.txt"; exit 76; fi
  check_bound "$code" forced "$line_mode" "line-hold-$line_mode.txt"
  if [ "$line_mode" = control ]; then
    if [ "$code" -ne 0 ] || ! grep -qxF "$line_pass" "line-hold-$line_mode.txt"; then
      pair_mismatch "$code" "line-hold-$line_mode.txt" control
    fi
    printf '  control: exit 0, %s\n' "$line_pass"
  else
    if [ "$code" -ne 1 ] || ! grep -qxF "$line_fail" "line-hold-$line_mode.txt"; then
      pair_mismatch "$code" "line-hold-$line_mode.txt" mutant 0 "$line_pass"
    fi
    printf '  exits 1 at "%s"\n' "$line_fail"
  fi
done

step "stress: four threads printing at once, every line whole"
cat > whole_lines.iyi <<'IYI'
threads = [] of IyiThread
4.times do |t|
  threads << IyiThread.start do
    20000.times { |i| puts "thread-#{t}-line-#{i}-of-twenty-thousand" }
    nil
  end
end
threads.each { |th| th.join }
IYI
if ! "$IYI" build whole_lines.iyi -o whole_lines > build-whole_lines.log 2>&1; then
  echo "SETUP: ${current_step:-build}: whole_lines did not build"; cat build-whole_lines.log; exit 76
fi
timeout 120 ./whole_lines > whole_lines.txt 2>&1
code=$?
check_bound "$code" healthy "run 1"
if [ "$code" -eq 76 ]; then cat whole_lines.txt; exit 76; fi
total=$(wc -l < whole_lines.txt | tr -d ' ')
broken=$(LC_ALL=C grep -cvE '^thread-[0-3]-line-[0-9]+-of-twenty-thousand$' whole_lines.txt)
if [ "$code" -ne 0 ] || [ "$total" -ne 80000 ] || [ "$broken" -ne 0 ]; then
  echo "FAIL: ${current_step}: run 1 exited $code; $broken of $total lines are not one thread's whole line"; exit 1
fi
echo "  80000 lines from four threads, none merged"

# ── 5f. A finished thread asks the registry under the lock ────────────────
# A reads the head while B is immediately before it. B may return from its
# body only after that read. The locked ask releases A after B's actual
# failed lock acquisition; the unlocked ask releases A only after B's real
# unlink. Both copies use the same hooks, and differ only in the ask's lock
# and unlock. The last walk names the fibers, not just the registry's size.
step "two neighbours retire together: the registry is asked under the lock"
if ! mkdir -p "$WORK/registry-ctl/iyi" "$WORK/registry-cut/iyi"; then
  echo "SETUP: registry: the runtime copy directories could not be created"; exit 76
fi
if ! cat > "$WORK/registry.part" <<'IYI'
    IYI_REG_A_FIBER    = 2560_u64
    IYI_REG_B_FIBER    = 2624_u64
    IYI_REG_RETIRE_A   = 2688_u64
    IYI_REG_A_HEAD     = 2752_u64
    IYI_REG_B_ASK_LINE = 2816_u64
    IYI_REG_B_CONTENDED = 2880_u64
    # Bit 0 records B's unlink; bit 1 records A's unlink.
    IYI_REG_UNLINKED   = 2944_u64
    IYI_REG_A_CUT      = 3008_u64
    # 0 means unanswered, 1 means false, 2 means true.
    IYI_REG_A_ANSWER   = 3072_u64

    # This can run while the caller owns the runtime lock. In particular,
    # Windows' __iyi_exit tries that lock, so terminate directly there.
    def self.registry_die(message : String, status : Int32) : NoReturn
      __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
      {% if flag?(:darwin) %}
        LibC.registry_probe_exit(status)
      {% elsif flag?(:win32) %}
        LibC.TerminateProcess(LibC.GetCurrentProcess, status)
        LibC.ExitProcess(status)
      {% else %}
        __iyi_exit(status)
      {% end %}
    end

    def self.registry_init : Nil
      page = control
      if page == 0_u64 || page == 0xFFFFFFFFFFFFFFFF_u64
        registry_die("SETUP: registry: the control page could not be mapped\n", 76)
      end
      offset = IYI_REG_A_FIBER
      while offset <= IYI_REG_A_ANSWER
        word(page + offset).value.set(0_u64)
        offset = offset + 64_u64
      end
    end

    def self.registry_set(offset : UInt64, value : UInt64) : Nil
      word(@@control + offset).value.set(value)
    end

    def self.registry_get(offset : UInt64) : UInt64
      word(@@control + offset).value.get
    end

    def self.registry_wait(offset : UInt64, message : String) : UInt64
      page = @@control
      began = IyiMark.now_ns
      value = word(page + offset).value.get
      while value == 0_u64
        registry_die(message, 76) if IyiMark.now_ns &- began > 20000000000_u64
        yield_cpu
        value = word(page + offset).value.get
      end
      value
    end

    # The marker brackets only B's actual registered? lock call. In the
    # mutant the two markers are adjacent, so another lock cannot count.
    def self.registry_ask_begin(fiber : UInt64) : Nil
      page = @@control
      return if page == 0_u64 || fiber == 0_u64 || fiber != word(page + IYI_REG_B_FIBER).value.get
      registry_die("SETUP: registry: the neighbour has no thread line\n", 76) if @@line == 0_u64
      word(page + IYI_REG_B_ASK_LINE).value.set(@@line)
    end

    def self.registry_ask_end(fiber : UInt64) : Nil
      page = @@control
      return if page == 0_u64 || fiber == 0_u64 || fiber != word(page + IYI_REG_B_FIBER).value.get
      word(page + IYI_REG_B_ASK_LINE).value.set(0_u64)
    end

    # Called from the failed iteration of the real lock, before lock_turn.
    def self.registry_lock_wait(seen : UInt64) : Nil
      page = @@control
      return if page == 0_u64 || (seen & 1_u64) == 0_u64
      asker = word(page + IYI_REG_B_ASK_LINE).value.get
      return if asker == 0_u64 || asker != @@line
      word(page + IYI_REG_B_CONTENDED).value.set(1_u64)
    end

    # A is inside registered?, immediately after its actual head read.
    # Do not release it on a timer: the watchdog only terminates the run.
    def self.registry_head(fiber : UInt64, head : UInt64, previous : UInt64) : Nil
      page = @@control
      return if page == 0_u64 || fiber == 0_u64 || fiber != word(page + IYI_REG_A_FIBER).value.get
      neighbour = word(page + IYI_REG_B_FIBER).value.get
      if neighbour == 0_u64 || head != neighbour || previous != neighbour
        registry_die("SETUP: registry: the neighbour was not the head and the first fiber's backlink\n", 76)
      end
      word(page + IYI_REG_A_HEAD).value.set(head)
      began = IyiMark.now_ns
      while true
        if word(page + IYI_REG_B_CONTENDED).value.get != 0_u64
          word(page + IYI_REG_A_CUT).value.set(1_u64)
          return
        end
        if (word(page + IYI_REG_UNLINKED).value.get & 1_u64) != 0_u64
          word(page + IYI_REG_A_CUT).value.set(2_u64)
          return
        end
        if IyiMark.now_ns &- began > 20000000000_u64
          registry_die("SETUP: registry: the neighbour neither contended nor unlinked\n", 76)
        end
        yield_cpu
      end
    end

    def self.registry_answer(fiber : UInt64, held : Bool) : Nil
      page = @@control
      return if page == 0_u64 || fiber == 0_u64 || fiber != word(page + IYI_REG_A_FIBER).value.get
      word(page + IYI_REG_A_ANSWER).value.set(held ? 2_u64 : 1_u64)
    end

    # Called after unregister actually updates the head and backlinks.
    def self.registry_unlinked(fiber : UInt64) : Nil
      page = @@control
      return if page == 0_u64 || fiber == 0_u64
      bit = 0_u64
      if fiber == word(page + IYI_REG_B_FIBER).value.get
        bit = 1_u64
      elsif fiber == word(page + IYI_REG_A_FIBER).value.get
        bit = 2_u64
      else
        return
      end
      while true
        seen = word(page + IYI_REG_UNLINKED).value.get
        if (seen & bit) != 0_u64
          registry_die("SETUP: registry: a main fiber was unlinked more than once\n", 76)
        end
        return if word(page + IYI_REG_UNLINKED).value.compare_and_set(seen, seen | bit)[1]
      end
    end
IYI
then
  echo "SETUP: registry: the hook source could not be written"; exit 76
fi

if ! cat > "$WORK/neighbours.iyi" <<'IYI'
@[Unsafe("the rendezvous uses initialized atomic words, and the final walk reads the registry after both threads have joined")]
module neighbours

IyiMark.auto = false
IyiMark.workers = 0_u64
IyiThread.registry_init
baseline = IyiScheduler.current.object_id
initial = IyiScheduler.first_fiber
unless initial.is_a?(IyiFiber) && initial.object_id == baseline && !initial.next_fiber.is_a?(IyiFiber)
  IyiThread.registry_die("SETUP: registry: the baseline was not the sole main fiber\n", 76)
end

first = IyiThread.start do
  IyiThread.registry_set(IyiThread::IYI_REG_A_FIBER, IyiScheduler.current.object_id)
  IyiThread.registry_wait(IyiThread::IYI_REG_RETIRE_A, "SETUP: registry: the first thread was not told to retire\n")
  nil
end
first_id = IyiThread.registry_wait(IyiThread::IYI_REG_A_FIBER, "SETUP: registry: the first thread did not register its main fiber\n")
second = IyiThread.start do
  IyiThread.registry_set(IyiThread::IYI_REG_B_FIBER, IyiScheduler.current.object_id)
  IyiThread.registry_wait(IyiThread::IYI_REG_A_HEAD, "SETUP: registry: the first thread did not read the head\n")
  nil
end
second_id = IyiThread.registry_wait(IyiThread::IYI_REG_B_FIBER, "SETUP: registry: the second thread did not register its main fiber\n")
IyiThread.registry_set(IyiThread::IYI_REG_RETIRE_A, 1_u64)
# No join or other runtime-lock operation on main until A has answered.
answer = IyiThread.registry_wait(IyiThread::IYI_REG_A_ANSWER, "SETUP: registry: the first membership ask did not answer\n")
first.join
second.join

cut = IyiThread.registry_get(IyiThread::IYI_REG_A_CUT)
contended = IyiThread.registry_get(IyiThread::IYI_REG_B_CONTENDED)
unlinked = IyiThread.registry_get(IyiThread::IYI_REG_UNLINKED)
if IyiThread.registry_get(IyiThread::IYI_REG_B_ASK_LINE) != 0_u64
  IyiThread.registry_die("SETUP: registry: the neighbour did not finish its membership ask\n", 76)
end

count = 0
first_seen = 0
second_seen = 0
baseline_seen = 0
node = IyiScheduler.first_fiber
head_id = node.is_a?(IyiFiber) ? node.object_id : 0_u64
while node.is_a?(IyiFiber) && count < 4
  first_seen += 1 if node.object_id == first_id
  second_seen += 1 if node.object_id == second_id
  baseline_seen += 1 if node.object_id == baseline
  count += 1
  node = node.next_fiber
end
if node.is_a?(IyiFiber)
  IyiThread.registry_die("SETUP: registry: the final registry walk did not terminate\n", 76)
end

if cut == 1_u64
  if contended != 1_u64
    IyiThread.registry_die("SETUP: registry: the neighbour's failed lock acquisition was not recorded\n", 76)
  end
  if answer != 2_u64
    IyiThread.registry_die("FAIL: registry: the locked membership check answered no for the first fiber\n", 1)
  end
  if unlinked != 3_u64
    IyiThread.registry_die("SETUP: registry: both real unlinks were not observed\n", 76)
  end
  if count != 1 || baseline_seen != 1 || head_id != baseline || first_seen != 0 || second_seen != 0
    IyiThread.registry_die("FAIL: registry: the locked retirement did not restore the baseline registry\n", 1)
  end
  puts "registry: the neighbour waited for the lock and both fibers were removed"
elsif cut == 2_u64
  if contended != 0_u64 || unlinked != 1_u64
    IyiThread.registry_die("SETUP: registry: the unlocked ask did not observe only the neighbour's unlink\n", 76)
  end
  if answer != 1_u64
    IyiThread.registry_die("SETUP: registry: the unlocked ask did not observe the stale membership result\n", 76)
  end
  if count != 2 || baseline_seen != 1 || head_id != first_id || first_seen != 1 || second_seen != 0
    IyiThread.registry_die("SETUP: registry: the stale first fiber was not found on the final registry\n", 76)
  end
  IyiThread.registry_die("FAIL: registry: the unlocked membership check left a retired main fiber registered\n", 1)
else
  IyiThread.registry_die("SETUP: registry: the first ask did not record its release event\n", 76)
end
IYI
then
  echo "SETUP: registry: the exercise source could not be written"; exit 76
fi

for copy in registry-ctl registry-cut; do
  if ! cp "$REPO"/src/iyi/*.iyi "$WORK/$copy/iyi/"; then
    echo "SETUP: registry: the runtime sources could not be copied"; exit 76
  fi
done

# Generate the common hooks once. Every method and splice is counted
# separately, including the Darwin alias needed by a lock-held watchdog.
if ! awk -v part="$WORK/registry.part" '
  /^    # ── Roots/ {
    while ((getline line < part) > 0) print line
    close(part); roots++
  }
  /^      fun thread_switch\(thread : UInt32, option : Int32, time : UInt32\) : Int32$/ {
    print; print "      fun registry_probe_exit = _exit(status : Int32) : NoReturn"; darwin++; next
  }
  { print }
  END { if (roots != 1 || darwin != 1) exit 3 }
' "$REPO/src/iyi/thread.iyi" > "$WORK/registry-ctl/iyi/thread.iyi"; then
  echo "SETUP: registry: the thread hook anchors changed"; exit 76
fi
if ! cp "$WORK/registry-ctl/iyi/thread.iyi" "$WORK/registry-cut/iyi/thread.iyi"; then
  echo "SETUP: registry: the common thread hooks could not be copied"; exit 76
fi
if ! awk '
  /^  def self\.lock : Nil$/ { inside = 1; methods++ }
  inside && /^  end$/ { inside = 0; ends++ }
  inside && /^        spins, since = IyiThread\.lock_turn\(word, seen, spins, since\)$/ {
    print "        IyiThread.registry_lock_wait(seen)"; waits++
  }
  { print }
  END { if (methods != 1 || ends != 1 || waits != 1) exit 3 }
' "$REPO/src/iyi/prelude.iyi" > "$WORK/registry-ctl/iyi/prelude.iyi"; then
  echo "SETUP: registry: the failed-lock hook anchors changed"; exit 76
fi
if ! cp "$WORK/registry-ctl/iyi/prelude.iyi" "$WORK/registry-cut/iyi/prelude.iyi"; then
  echo "SETUP: registry: the common lock hook could not be copied"; exit 76
fi
if ! awk '
  /^  def self\.registered\?\(fiber : IyiFiber\) : Bool$/ { ask = 1; asks++; print; next }
  ask && /^  end$/ { ask = 0; ask_ends++; print; next }
  /^  def self\.unregister\(fiber : IyiFiber\) : Nil$/ { unlink = 1; unlinks++; print; next }
  unlink && /^  end$/ { unlink = 0; unlink_ends++; print; next }
  ask && $0 == "    IyiRuntimeLock.lock" {
    print "    IyiThread.registry_ask_begin(fiber.object_id)"
    print
    print "    IyiThread.registry_ask_end(fiber.object_id)"
    locks++; next
  }
  ask && $0 == "    IyiRuntimeLock.unlock" { unlocks++; print; next }
  ask && $0 == "    head = @@all_head" {
    print
    print "    registry_previous = fiber.prev_fiber"
    print "    IyiThread.registry_head(fiber.object_id, head.is_a?(IyiFiber) ? head.object_id : 0_u64, registry_previous.is_a?(IyiFiber) ? registry_previous.object_id : 0_u64)"
    heads++; next
  }
  ask && $0 == "    held = fiber.prev_fiber.is_a?(IyiFiber) || (head.is_a?(IyiFiber) && head.object_id == fiber.object_id)" {
    print; print "    IyiThread.registry_answer(fiber.object_id, held)"; answers++; next
  }
  unlink && $0 == "    fiber.prev_fiber = nil" {
    print; print "    IyiThread.registry_unlinked(fiber.object_id)"; unlinked++; next
  }
  { print }
  END {
    if (asks != 1 || ask_ends != 1 || unlinks != 1 || unlink_ends != 1 ||
        locks != 1 || unlocks != 1 || heads != 1 || answers != 1 || unlinked != 1) exit 3
  }
' "$REPO/src/iyi/concurrency.iyi" > "$WORK/registry-ctl/iyi/concurrency.iyi"; then
  echo "SETUP: registry: the membership or unlink hook anchors changed"; exit 76
fi

# The mutant removes exactly one lock and one unlock, both inside the ask.
if ! awk '
  /^  def self\.registered\?\(fiber : IyiFiber\) : Bool$/ { ask = 1; asks++ }
  ask && /^  end$/ { ask = 0; ends++ }
  ask && $0 == "    IyiRuntimeLock.lock" { locks++; next }
  ask && $0 == "    IyiRuntimeLock.unlock" { unlocks++; next }
  { print }
  END { if (asks != 1 || ends != 1 || locks != 1 || unlocks != 1) exit 3 }
' "$WORK/registry-ctl/iyi/concurrency.iyi" > "$WORK/registry-cut/iyi/concurrency.iyi"; then
  echo "SETUP: registry: the mutant lock and unlock anchors changed"; exit 76
fi
# Reinsert those two lines independently and compare the complete files.
if ! awk '
  /^  def self\.registered\?\(fiber : IyiFiber\) : Bool$/ { ask = 1; asks++ }
  ask && /^  end$/ { ask = 0; ends++ }
  ask && $0 == "    IyiThread.registry_ask_begin(fiber.object_id)" {
    print; print "    IyiRuntimeLock.lock"; locks++; next
  }
  ask && $0 == "    IyiThread.registry_answer(fiber.object_id, held)" {
    print; print "    IyiRuntimeLock.unlock"; unlocks++; next
  }
  { print }
  END { if (asks != 1 || ends != 1 || locks != 1 || unlocks != 1) exit 3 }
' "$WORK/registry-cut/iyi/concurrency.iyi" > "$WORK/registry-restored.iyi"; then
  echo "SETUP: registry: the mutant comparison anchors changed"; exit 76
fi
if ! cmp -s "$WORK/registry-ctl/iyi/concurrency.iyi" "$WORK/registry-restored.iyi"; then
  echo "SETUP: registry: the mutant differs by more than the lock and unlock"; exit 76
fi
for source in "$REPO"/src/iyi/*.iyi; do
  name=${source##*/}
  [ "$name" = concurrency.iyi ] && continue
  if ! cmp -s "$WORK/registry-ctl/iyi/$name" "$WORK/registry-cut/iyi/$name"; then
    echo "SETUP: registry: the runtime copies differ outside the membership ask"; exit 76
  fi
done

for copy in registry-ctl registry-cut; do
  if ! IYI_PATH="$WORK/$copy${PSEP}$REPO/src" "$IYI" build "$WORK/neighbours.iyi" -o "$WORK/$copy-run" > "$WORK/build-$copy.log" 2>&1; then
    echo "SETUP: registry: $copy did not build"; cat "$WORK/build-$copy.log"; exit 76
  fi
done

control='registry: the neighbour waited for the lock and both fibers were removed'
failure='FAIL: registry: the unlocked membership check left a retired main fiber registered'
for copy in registry-ctl registry-cut; do
  timeout 120 "$WORK/$copy-run" > "$WORK/$copy-raw.txt" 2>&1
  code=$?; check_bound "$code" forced "$copy" "$WORK/$copy-raw.txt"
  tr -d '\r' < "$WORK/$copy-raw.txt" > "$WORK/$copy.txt"
  if [ "$code" -eq 76 ] || grep -q '^SETUP:' "$WORK/$copy.txt"; then
    if grep -q '^SETUP:' "$WORK/$copy.txt"; then
      cat "$WORK/$copy.txt"
    else
      echo "SETUP: registry: $copy exited 76 without a stage diagnostic"
    fi
    exit 76
  fi
  failures=$(grep -c '^FAIL:' "$WORK/$copy.txt" || true)
  if [ "$copy" = registry-ctl ]; then
    if [ "$code" -ne 0 ] || [ "$failures" -ne 0 ] || ! grep -qxF "$control" "$WORK/$copy.txt"; then
      pair_mismatch "$code" "$WORK/$copy.txt" control
    fi
    printf '  control: exit 0, %s\n' "$control"
  else
    if [ "$code" -ne 1 ] || [ "$failures" -ne 1 ] || ! grep -qxF "$failure" "$WORK/$copy.txt"; then
      pair_mismatch "$code" "$WORK/$copy.txt" mutant 0 "$control"
    fi
    printf '  exits 1 at "%s"\n' "$failure"
  fi
done

# ── 6. Share: what a thread's block may capture is decided at compile time ─
# SPEC.md III.4.4's marker, gating III.4.11's block: a value whose type has
# a mutable field — here an `Array`, whose size is assigned by its own
# methods — cannot be captured by a block another thread runs, and the
# compiler names the variable, the type and the field that failed. The
# exercise itself captures integers and passes; this program must not
# compile.
step "failure proof: a block capturing a mutable value does not compile"
cat > unshared.iyi <<'IYI'
items = [1, 2, 3]
t = IyiThread.start do
  items.size
  nil
end
t.join
IYI
if "$IYI" build unshared.iyi -o unshared > build-unshared.log 2>&1; then
  echo "a block capturing an Array compiled:"; cat build-unshared.log; exit 1
fi
if ! grep -q "captures \`items : Array(Int32)\`, which is not Share" build-unshared.log; then
  echo "the refusal did not name the capture:"; cat build-unshared.log; exit 1
fi
printf '  refused: %s\n' "$(grep -m1 'is not Share' build-unshared.log | sed 's/^Error: //')"

# `self` is captured by a receiverless call as much as by an instance
# variable: `bump` written for `self.bump` in the block of a method of a
# Counter whose `bump` does `@n += 1`, twenty million times beside its
# starter's twenty million, compiled and counted 28936626 of 40000000,
# while `@n += 1` in the block itself was refused. A method of a Share
# self, and a class method calling another receiverless, still build and
# run.
step "failure proof: a block calling a method of a self that is not Share does not compile"
cat > selfcall.iyi <<'IYI'
class Counter
  @n = 0

  def bump : Nil
    @n += 1
  end

  def run : Nil
    t = IyiThread.start do
      bump
      nil
    end
    t.join
  end
end

Counter.new.run
IYI
cat > selfcall_shared.iyi <<'IYI'
class Greeter
  def initialize(@name : String)
  end

  def greeting : String
    "hi #{@name}"
  end

  def run : Nil
    t = IyiThread.start do
      puts greeting
      nil
    end
    t.join
  end

  def self.twice(n : Int32) : Int32
    n * 2
  end

  def self.go : Nil
    t = IyiThread.start do
      puts twice(21)
      nil
    end
    t.join
  end
end

Greeter.new("ada").run
Greeter.go
IYI
if "$IYI" build selfcall.iyi -o selfcall > build-selfcall.log 2>&1; then
  echo "a block calling a receiverless method of a Counter compiled:"; cat build-selfcall.log; exit 1
fi
if ! grep -q "captures \`self : Counter\`, which is not Share: Counter's field @n is assigned in \`bump\`" build-selfcall.log; then
  echo "the refusal did not name self:"; cat build-selfcall.log; exit 1
fi
printf '  refused: %s\n' "$(grep -m1 'is not Share' build-selfcall.log | sed 's/^Error: //')"
if ! "$IYI" build selfcall_shared.iyi -o selfcall_shared > build-selfcall-shared.log 2>&1; then
  echo "receiverless calls on a Share self and on a class were refused:"; cat build-selfcall-shared.log; exit 1
fi
./selfcall_shared > selfcall-shared.txt
if [ "$(tr -d '\r' < selfcall-shared.txt | tr '\n' ' ')" != "hi ada 42 " ]; then
  echo "receiverless calls on a Share self and on a class built, but printed:"; cat selfcall-shared.txt; exit 1
fi
echo "  a Share self's method and a class method, called receiverless, still build and print hi ada 42"

# The structural scan for an assigned field reads every method the type
# has, not only the ones its class and superclasses declare, and reads
# macro code as what it expands to. A `bump` from an included `module`, and
# one whose `@n += 1` sat inside `{% if true %}` or in a macro it called,
# each compiled, and two threads bumping the counter two million times each
# counted 2336841 and 2343960 of 4000000; each is refused by its field now.
step "failure proof: a field assigned by a mixin's method or by macro code is not Share"
for shape in mixin macro_if macro_call; do
  case "$shape" in
    mixin) bump='include Bump' ;;
    macro_if) bump='def bump : Nil
    {% if true %}
      @n += 1
    {% end %}
  end' ;;
    macro_call) bump='macro incr
    @n += 1
  end

  def bump : Nil
    incr
  end' ;;
  esac
  cat > "assigned_$shape.iyi" <<IYI
module Bump
  def bump : Nil
    @n += 1
  end
end

class Counter
  $bump

  def initialize
    @n = 0_i64
  end
end

c = Counter.new
t = IyiThread.start do
  c.bump
  nil
end
t.join
IYI
  if "$IYI" build "assigned_$shape.iyi" -o "assigned_$shape" > "build-assigned-$shape.log" 2>&1; then
    echo "a counter bumped by $shape code compiled:"; cat "build-assigned-$shape.log"; exit 1
  fi
  if ! grep -q "Counter's field @n is assigned in \`bump\`" "build-assigned-$shape.log"; then
    echo "the $shape refusal did not name the field:"; cat "build-assigned-$shape.log"; exit 1
  fi
done
echo "  refused by its field three ways: a mixin's method, {% if %} and a macro call"

# An address is a write the scan cannot see: `pointerof(@n).value += 1` in
# `poke` read as no assignment, so the Counter was Share, and two threads
# poking it 100 million times each counted 122761325 of 200000000. A field
# whose address a method other than `initialize` takes is mutable now.
step "failure proof: a field given out by pointerof is not Share"
cat > addressed.iyi <<'IYI'
@[Unsafe("poke writes the counter through pointerof, the address the Share refusal must name")]
class Counter
  def initialize(@n : Int32)
  end

  def poke : Nil
    pointerof(@n).value += 1
  end
end

c = Counter.new(0)
t = IyiThread.start do
  c.poke
  nil
end
t.join
IYI
if "$IYI" build addressed.iyi -o addressed > build-addressed.log 2>&1; then
  echo "a counter written through pointerof compiled:"; cat build-addressed.log; exit 1
fi
if ! grep -q "Counter's field @n is given out by \`pointerof\` in \`poke\`" build-addressed.log; then
  echo "the pointerof refusal did not name the field:"; cat build-addressed.log; exit 1
fi
printf '  refused: %s\n' "$(grep -m1 'is not Share' build-addressed.log | sed 's/^Error: //')"

# ── 6b. A captured local is one cell, and nothing assigns it after the start
# A Share type makes a value safe to read from two threads, not a variable
# safe to write: a captured local is one cell both threads reach. `count`
# added to two million times by a thread and two million by its starter
# compiled, and counted 2684265, 2355445 and 4000000 on three runs. The
# block assigning it, and the starter assigning it after the start, are
# refused by name now; a local assigned before the start, and a block's
# own local captured on each call, still build and run.
step "failure proof: a captured local the thread or its starter assigns does not compile"
cat > raced.iyi <<'IYI'
count = 0
t = IyiThread.start do
  2000000.times { count += 1 }
  nil
end
2000000.times { count += 1 }
t.join
puts count
IYI
cat > reassigned.iyi <<'IYI'
limit = 1
t = IyiThread.start do
  puts limit
  nil
end
limit = 2
t.join
IYI
cat > assigned_before.iyi <<'IYI'
total = 0
[1, 2, 3].each { |v| total += v }
3.times do |i|
  part = total * 10 + i
  t = IyiThread.start do
    puts part
    nil
  end
  t.join
end
IYI
if "$IYI" build raced.iyi -o raced > build-raced.log 2>&1; then
  echo "a thread assigning a captured local compiled:"; cat build-raced.log; exit 1
fi
if ! grep -q "assigns \`count\`, a local of the code that started the thread" build-raced.log; then
  echo "the refusal did not name the variable:"; cat build-raced.log; exit 1
fi
printf '  refused: %s\n' "$(grep -m1 'assigns `count`' build-raced.log | sed 's/^Error: //')"
if "$IYI" build reassigned.iyi -o reassigned > build-reassigned.log 2>&1; then
  echo "a captured local assigned after the thread started compiled:"; cat build-reassigned.log; exit 1
fi
if ! grep -q "\`limit\` is assigned here, after the thread has started" build-reassigned.log; then
  echo "the refusal did not name the variable:"; cat build-reassigned.log; exit 1
fi
printf '  refused: %s\n' "$(grep -m1 'is assigned here' build-reassigned.log | sed 's/^Error: //')"
# The advice names what iyi has to keep a value two threads write: an
# `Atomic`, or a `Mutex` from std/mutex. It once said "or behind a
# `Mutex`" before there was one; the module is named now, so the advice
# leads somewhere.
if ! grep -q 'Keep the value in an `Atomic`, or behind a `Mutex` (std/mutex)' build-raced.log || ! grep -q 'or behind a `Mutex` (std/mutex)' build-reassigned.log; then
  echo "the advice does not name Atomic and std/mutex's Mutex:"; cat build-raced.log build-reassigned.log; exit 1
fi
# The same line inside `{% if true %}` or `{% for %}`: the walk read the
# macro's text rather than its expansion, so it compiled, and a thread
# reading a captured `Int64 | Float64` its starter kept reassigning that
# way counted 243585 torn reads in a debug build.
for flow in if for; do
  case "$flow" in
    if) open='{% if true %}' ;;
    for) open='{% for i in [1] %}' ;;
  esac
  cat > "reassigned_$flow.iyi" <<IYI
limit = 1
t = IyiThread.start do
  puts limit
  nil
end
$open
  limit = 2
{% end %}
t.join
IYI
  if "$IYI" build "reassigned_$flow.iyi" -o "reassigned_$flow" > "build-reassigned-$flow.log" 2>&1; then
    echo "a captured local assigned after the start inside {% $flow %} compiled:"; cat "build-reassigned-$flow.log"; exit 1
  fi
  if ! grep -q "\`limit\` is assigned here, after the thread has started" "build-reassigned-$flow.log"; then
    echo "the {% $flow %} refusal did not name the variable:"; cat "build-reassigned-$flow.log"; exit 1
  fi
done
echo "  and refused the same inside {% if %} and {% for %}"
if ! "$IYI" build assigned_before.iyi -o assigned_before > build-assigned-before.log 2>&1; then
  echo "locals assigned before the start were refused:"; cat build-assigned-before.log; exit 1
fi
./assigned_before > assigned-before.txt
if [ "$(tr -d '\r' < assigned-before.txt | tr '\n' ' ')" != "60 61 62 " ]; then
  echo "locals assigned before the start built, but read:"; cat assigned-before.txt; exit 1
fi
echo "  a local assigned before the start, and a block's own local, still build and read 60 61 62"

# ── 6c. A String is Share, and so is what holds one immutably ──────────────
# `String#size` caches the character count in `@length`, the one write a
# string has after it is built, and the structural scan read it as a
# mutable field: `s = "x"` captured by a thread's block was refused with
# "String's field @length is assigned in `size`", and with it a struct
# holding a string and `List(String)`. The cache is idempotent - every
# thread writes the same count of the same bytes - so String is trusted.
# A type that assigns its own String field after construction still is not.
step "a String, a struct holding one and a List(String) are captured; a field assigned later is not"
cat > strings.iyi <<'IYI'
module strings

import std/list::{List}

struct User
  getter name : String

  def initialize(@name : String)
  end
end

s = "x"
u = User.new("ada")
l = List.new(["a", "b"])
t = IyiThread.start do
  puts "#{s} #{s.size} #{u.name} #{l.size}"
  nil
end
t.join
IYI
if ! "$IYI" build strings.iyi -o strings > build-strings.log 2>&1; then
  echo "a block capturing a String, a User and a List(String) was refused:"; cat build-strings.log; exit 1
fi
./strings > strings.txt
if [ "$(tr -d '\r' < strings.txt)" != "x 1 ada 2" ]; then
  echo "the block capturing strings built, but printed:"; cat strings.txt; exit 1
fi
echo "  a String, a struct holding one and a List(String) captured, and read x 1 ada 2"
cat > renamed.iyi <<'IYI'
module renamed

class Tag
  def initialize(@name : String)
  end

  def rename(to : String) : Nil
    @name = to
  end
end

tag = Tag.new("a")
t = IyiThread.start do
  tag.rename("b")
  nil
end
t.join
IYI
if "$IYI" build renamed.iyi -o renamed > build-renamed.log 2>&1; then
  echo "a block capturing a Tag whose String field is reassigned compiled:"; cat build-renamed.log; exit 1
fi
if ! grep -q "Tag's field @name is assigned in \`rename\`" build-renamed.log; then
  echo "the refusal did not name the field:"; cat build-renamed.log; exit 1
fi
printf '  refused: %s\n' "$(grep -m1 'is not Share' build-renamed.log | sed 's/^Error: //')"

# ── 6d. A constant the block names is module-level state ──────────────────
# SPEC.md III.4.5: module-level mutable state is not reachable from another
# thread. The block names a constant in its own text rather than capturing
# it, so the closure's variables never listed it: `COUNTS = [0]` with
# `COUNTS[0] += 1` run a million times in the block and a million by its
# starter compiled and printed 1061337, and `C2 = Counter.new` bumped the
# same way printed 1404865. Each is refused by the constant's name now; a
# constant whose type is Share - an integer, a String, a List - is read
# from the thread as before.
step "failure proof: a block naming a constant that is not Share does not compile"
cat > constant_array.iyi <<'IYI'
COUNTS = [0]
t = IyiThread.start do
  COUNTS[0] += 1
  nil
end
t.join
IYI
cat > constant_counter.iyi <<'IYI'
class Counter
  @n = 0

  def bump : Nil
    @n += 1
  end
end

C2 = Counter.new
t = IyiThread.start do
  C2.bump
  nil
end
t.join
IYI
cat > constant_shared.iyi <<'IYI'
module constant_shared

import std/list::{List}

LIMIT = 3
GREETING = "hi"
NAMES = List.new(["a", "b"])
t = IyiThread.start do
  puts "#{GREETING} #{LIMIT} #{NAMES.size}"
  nil
end
t.join
IYI
if "$IYI" build constant_array.iyi -o constant_array > build-constant-array.log 2>&1; then
  echo "a block naming an Array constant compiled:"; cat build-constant-array.log; exit 1
fi
if ! grep -q "names the constant \`COUNTS : Array(Int32)\`, which is not Share" build-constant-array.log; then
  echo "the refusal did not name the constant:"; cat build-constant-array.log; exit 1
fi
printf '  refused: %s\n' "$(grep -m1 'is not Share' build-constant-array.log | sed 's/^Error: //')"
if "$IYI" build constant_counter.iyi -o constant_counter > build-constant-counter.log 2>&1; then
  echo "a block naming a Counter constant compiled:"; cat build-constant-counter.log; exit 1
fi
if ! grep -q "names the constant \`C2 : Counter\`, which is not Share: Counter's field @n is assigned in \`bump\`" build-constant-counter.log; then
  echo "the refusal did not name the constant:"; cat build-constant-counter.log; exit 1
fi
printf '  refused: %s\n' "$(grep -m1 'is not Share' build-constant-counter.log | sed 's/^Error: //')"
if ! "$IYI" build constant_shared.iyi -o constant_shared > build-constant-shared.log 2>&1; then
  echo "a block naming Share constants was refused:"; cat build-constant-shared.log; exit 1
fi
./constant_shared > constant-shared.txt
if [ "$(tr -d '\r' < constant-shared.txt)" != "hi 3 2" ]; then
  echo "a block naming Share constants built, but printed:"; cat constant-shared.txt; exit 1
fi
echo "  an Int32, a String and a List(String) constant still build and read hi 3 2"

# A class variable is module-level state too, and the block names it with
# nothing the closure lists: a class method whose thread block and starter
# each ran `@@count += 1` two million times compiled, and printed 2548908
# and 2461914 of 4000000. One written after its initializer - by the block
# or by a method - is one cell every thread shares, and one whose type is
# not Share is refused as a constant is; one only its initializer writes,
# of a Share type, is read from the thread as before.
step "failure proof: a block naming a class variable written again, or not Share, does not compile"
cat > classvar_assigned.iyi <<'IYI'
class Tally
  @@count = 0

  def self.run : Nil
    t = IyiThread.start do
      @@count += 1
      nil
    end
    t.join
  end
end

Tally.run
IYI
cat > classvar_written.iyi <<'IYI'
class Tally
  @@count = 0

  def self.bump : Nil
    @@count += 1
  end

  def self.run : Nil
    t = IyiThread.start do
      puts @@count
      nil
    end
    bump
    t.join
  end
end

Tally.run
IYI
cat > classvar_array.iyi <<'IYI'
class Tally
  @@items = [1, 2, 3]

  def self.run : Nil
    t = IyiThread.start do
      puts @@items.size
      nil
    end
    t.join
  end
end

Tally.run
IYI
cat > classvar_shared.iyi <<'IYI'
module classvar_shared

import std/list::{List}

class Tally
  @@limit = 3
  @@name = "x"
  @@names : List(String) = List.new(["a", "b"])

  def self.run : Nil
    t = IyiThread.start do
      puts "#{@@name} #{@@limit} #{@@names.size}"
      nil
    end
    t.join
  end
end

Tally.run
IYI
for shape in assigned written array; do
  case "$shape" in
    assigned) said="assigns \`@@count\`, a class variable, so every thread that reaches it shares one mutable cell" ;;
    written) said="names the class variable \`@@count\`, which is written after its initializer (in \`bump\`)" ;;
    array) said="names the class variable \`@@items : Array(Int32)\`, which is not Share" ;;
  esac
  if "$IYI" build "classvar_$shape.iyi" -o "classvar_$shape" > "build-classvar-$shape.log" 2>&1; then
    echo "a block naming a class variable ($shape) compiled:"; cat "build-classvar-$shape.log"; exit 1
  fi
  if ! grep -qF "$said" "build-classvar-$shape.log"; then
    echo "the class variable refusal ($shape) did not say what it should:"; cat "build-classvar-$shape.log"; exit 1
  fi
  printf '  refused: %s\n' "$(grep -m1 'class variable' "build-classvar-$shape.log" | sed 's/^Error: //')"
done
if ! "$IYI" build classvar_shared.iyi -o classvar_shared > build-classvar-shared.log 2>&1; then
  echo "a block naming class variables only their initializers write was refused:"; cat build-classvar-shared.log; exit 1
fi
./classvar_shared > classvar-shared.txt
if [ "$(tr -d '\r' < classvar-shared.txt)" != "x 3 2" ]; then
  echo "a block naming class variables only their initializers write built, but printed:"; cat classvar-shared.txt; exit 1
fi
echo "  an Int32, a String and a List(String) class variable only their initializers write still build and read x 3 2"

# ── 7. Windows: a program ends while a collection stops it ────────────────
# A thread runs collections back to back - each one stops the main thread -
# while the main thread comes to the end of the program. Back into the C
# runtime, that end was `ExitProcess`, which ended the collecting thread
# with the main thread still suspended: the process never ended, its one
# thread in `NtTerminateProcess` and beyond `timeout`; 35 runs in 100 here,
# 20 in 40 held to four cores. `main` ends through `TerminateProcess` now:
# 0 in 1,000. The proof puts the return back, and the emitted IR of main
# shows it on one build: the end must be the `__iyi_exit` call with no `ret`
# in main. Two hundred runs stay as the stress test of the end itself.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    cat > ends.iyi <<'IYI'
head = [] of Int32
n = 0
while n < 2000
  head << n
  n = n + 1
end
t = IyiThread.start do
  while true
    IyiMark.collect
  end
  nil
end
until_ns = IyiMark.now_ns + 20000000_u64
while IyiMark.now_ns < until_ns
end
print "ended with #{head.size}\n"
IYI
    cat > release.ps1 <<'PS1'
param([string]$Name)
Add-Type -Namespace IyiGate -Name Thread -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr OpenThread(int access, bool inherit, int id);
[DllImport("kernel32.dll")] public static extern int ResumeThread(System.IntPtr thread);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(System.IntPtr handle);
'@
Get-Process $Name -ErrorAction SilentlyContinue | ForEach-Object {
  $process = $_
  $process.Threads | ForEach-Object {
    $thread = [IyiGate.Thread]::OpenThread(2, $false, $_.Id)
    if ($thread -ne [System.IntPtr]::Zero) { [void][IyiGate.Thread]::ResumeThread($thread); [void][IyiGate.Thread]::CloseHandle($thread) }
  }
  [void]$process.WaitForExit(5000)
}
"left: $(@(Get-Process $Name -ErrorAction SilentlyContinue).Count)"
PS1
    release() { powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$WORK/release.ps1")" -Name "$1"; }
    # Windows' `main` ends in `__iyi_exit`, which ends the process with
    # `TerminateProcess`. In LLVM IR that is the call and then `unreachable`,
    # with no `ret` in main. A copy that returns to the C runtime has a `ret`
    # where the call was, and its run is the one that can hang under a
    # collection. The check reads main's body from the emitted IR, on one
    # build, so it is the same on every run.
    ends_in_exit() {
      awk '
        function is_exit_call(line) {
          return line ~ /(^|[[:space:]])call[[:space:]].*@\.2A\.__iyi_exit\.3C\.Int32\.3E\.\.3A\.NoReturn\(/
        }
        /^define .*@main\(/ { definitions++; inmain = 1; next }
        inmain && /^}/ { closed++; inmain = 0; next }
        inmain && /^  / {
          if ($0 ~ /^  ret /) rets++
          if (is_exit_call($0)) exits++
          prev = last; last = $0
        }
        END {
          if (definitions != 1 || closed != 1 || last == "") {
            print "SETUP: ends: missing or malformed main in the IR"; exit 76
          }
          if (rets > 0) {
            print "FAIL: main returns to the C runtime instead of ending in __iyi_exit"; exit 1
          }
          if (exits >= 1 && last ~ /^  unreachable([[:space:]]|,|$)/ && is_exit_call(prev)) {
            print "main ends in __iyi_exit"; exit 0
          }
          print "SETUP: ends: main has no final exit call followed by unreachable"; exit 76
        }
      ' "$1"
    }
    step "process exit: the control ends in __iyi_exit"
    if ! "$IYI" build --release --emit llvm-ir ends.iyi -o ends > build-ends.log 2>&1; then
      echo "SETUP: ${current_step:-build}: ends did not build"; cat build-ends.log; exit 76
    fi
    ends_in_exit ends.ll > ends-end.txt
    code=$?
    if [ "$code" -eq 76 ]; then cat ends-end.txt; exit 76; fi
    if [ "$code" -ne 0 ] || [ "$(cat ends-end.txt)" != 'main ends in __iyi_exit' ]; then
      echo "the healthy program does not end in __iyi_exit:"; cat ends-end.txt; exit 1
    fi
    echo '  control: exit 0, main ends in __iyi_exit'
    step "stress: a program ends while another thread's collections stop it, two hundred runs"
    again=1
    while [ "$again" -le 200 ]; do
      timeout 30 ./ends > ends.txt 2>&1
      code=$?; check_bound "$code" healthy "run $again"
      if [ "$code" -eq 76 ]; then cat ends.txt; exit 76; fi
      if [ "$code" -ne 0 ] || ! grep -q "^ended with 2000$" ends.txt; then
        echo "FAIL: ${current_step}: run $again exited $code:"; tail -3 ends.txt; release ends; exit 1
      fi
      again=$((again + 1))
    done
    echo "  two hundred of two hundred ended"

    step "failure proof: a program that ends back in the C runtime fails the end check on its one build"
    mkdir -p crt-end/iyi
    cp "$REPO"/src/iyi/*.iyi crt-end/iyi/
    # The pair is the win32 end of `fun main`; `def exit` writes the same
    # `__iyi_exit(status)` line, so only the one after the flush is taken.
    awk '
      /^fun main\(argc : Int32, argv : UInt8\*\*\) : Int32$/ { main++; inmain = 1 }
      inmain && /^end$/ { inmain = 0; closed++ }
      inmain && after && /^    __iyi_exit\(status\)$/ { exits++; after = 0; next }
      after { after = 0 }
      inmain && /^    LibC\.fflush\(Pointer\(Void\)\.new\(0_u64\)\)$/ { flushes++; after = 1; next }
      { print }
      END { if (main != 1 || closed != 1 || flushes != 1 || exits != 1) exit 3 }
    ' "$REPO/src/iyi/prelude.iyi" > crt-end/iyi/prelude.iyi || { echo "SETUP: ends: main flush/exit anchors changed"; exit 76; }
    if ! IYI_PATH="$WORK/crt-end${PSEP}$REPO/src" "$IYI" build --release --emit llvm-ir ends.iyi -o ends-in-crt > build-crt-end.log 2>&1; then
      echo "SETUP: ${current_step:-build}: crt-end did not build"; cat build-crt-end.log; exit 76
    fi
    ends_in_exit ends-in-crt.ll > crt-end.txt
    code=$?
    if [ "$code" -eq 76 ]; then cat crt-end.txt; exit 76; fi
    if [ "$code" -ne 1 ]; then
      pair_mismatch "$code" crt-end.txt mutant 0 'main ends in __iyi_exit'
    fi
    if [ "$(cat crt-end.txt)" != 'FAIL: main returns to the C runtime instead of ending in __iyi_exit' ]; then
      pair_mismatch "$code" crt-end.txt mutant 0 'main ends in __iyi_exit'
    fi
    echo '  exits 1 at "FAIL: main returns to the C runtime instead of ending in __iyi_exit"'
    ;;
esac

# ── 7b. Windows: a thread is named on its line before a stop can see it ───
# A child was linked for the stops under the runtime lock and ran at once,
# and its handle reached its line only after the lock was released: a stop
# in between suspended NULL, read sp 0 and scanned from address 0. The
# child is created suspended now, its handle written under the lock, and
# resumed after. The failure proof holds the next start after its unlock and
# before its handle is written, while a helper collects: the child runs
# unnamed meanwhile, and the copy's stop that visits its line records it and
# skips it. The child holds nothing a stop would free, so the record is
# the observable and the copy skips that line to avoid scanning address 0.
# The control holds the same start after its handle is written and before
# the thread is resumed, and records nothing.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    cat > starting.iyi <<'IYI'
class Flag
  getter stop : Atomic(Int64)
  getter ran : Atomic(Int64)
  getter opened : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
    @ran = Atomic(Int64).new(0_i64)
    @opened = Atomic(Int64).new(0_i64)
  end
end

class Node
  property next_node : Node?
  property value : Int64

  def initialize(@value : Int64)
    @next_node = nil
  end
end

def churn(flag : Flag) : Nil
  while flag.stop.get == 0_i64
    head : Node? = nil
    200.times do |i|
      n = Node.new(i.to_i64)
      n.next_node = head
      head = n
    end
    sum = 0_i64
    cur = head
    while cur.is_a?(Node)
      sum = sum + cur.value
      cur = cur.next_node
    end
    raise "churn sum #{sum}" if sum != 19900_i64
  end
end

def child(flag : Flag, i : Int32) : Nil
  a = [] of String
  20.times { |k| a << "child-#{i}-#{k}" }
  raise "child list" if a.size != 20 || a[19] != "child-#{i}-19"
  flag.ran.add(1_i64)
end

# The forced program's child allocates nothing, so a stop that skips its
# unnamed line frees nothing this child still holds.
def child_quiet(flag : Flag) : Nil
  # Linked until the collection that the armed start was held for is over:
  # a child that exited earlier would leave the stop nothing to visit.
  deadline = IyiMark.now_ns &+ 20000000000_u64
  while flag.opened.get == 0_i64
    if IyiMark.now_ns >= deadline
      print "SETUP: unnamed: the held child's gate never opened\n"
      __iyi_exit(76)
    end
    IyiThread.spin_pause
  end
  flag.ran.add(1_i64)
end

flag = Flag.new
churners = [] of IyiThread
started = 0
{% if flag?(:unnamed_force) %}
IyiMark.auto = false
{% else %}
2.times { churners << IyiThread.start { churn(flag) } }
{% end %}
{% if flag?(:unnamed_force) %}
# Started before the arm, so its own start is not the one held. It waits,
# with a bound of its own, for the armed start to reach its gate, collects
# while that start is held, and opens the gate. A lapsed hold or a missed
# gate ends the run with its own sentence.
helper = IyiThread.start do
  bound = IyiMark.now_ns &+ 20000000000_u64
  while !IyiThread.release_gate_held? && IyiMark.now_ns < bound
    IyiThread.yield_cpu
  end
  if !IyiThread.release_gate_held?
    print "SETUP: unnamed: the armed start never reached its gate\n"
    __iyi_exit(76)
  end
  if IyiThread.release_gate_expired?
    print "SETUP: unnamed: the hold deadline elapsed before the collection\n"
    __iyi_exit(76)
  end
  IyiMark.collect
  if IyiThread.release_gate_expired?
    print "SETUP: unnamed: the hold deadline elapsed during the collection\n"
    __iyi_exit(76)
  end
  held, expired = IyiThread.release_gate_open
  if !held || expired
    print "SETUP: unnamed: the held start gate did not open\n"
    __iyi_exit(76)
  end
  flag.opened.set(1_i64)
  nil
end
IyiThread.release_gate_arm_next
armed = IyiThread.start { child_quiet(flag) }
armed.join
helper.join
flag.stop.set(1_i64)
churners.each(&.join)
if IyiThread.release_gate_recorded?
  print "FAIL: a stop met a started thread whose handle was not yet written\n"
  __iyi_exit(1)
end
puts "unnamed: held=1 collected=1 expired=0, and no stop met a thread without its handle"
started = 1
{% else %}
deadline = __iyi_monotonic_ns + Program.args[0].to_i.to_i64 * 1_000_000_000_i64
while started == 0 || __iyi_monotonic_ns < deadline
  batch = [] of IyiThread
  4.times do |k|
    n = started + k
    batch << IyiThread.start { child(flag, n) }
  end
  started = started + 4
  batch.each(&.join)
end
flag.stop.set(1_i64)
churners.each(&.join)
{% end %}
raise "ran #{flag.ran.get} of #{started}" if flag.ran.get != started
puts "ok started=#{started}"
IYI
    # The gate's functions go into a copy's thread.iyi before its roots, and
    # the start is held after its unlock. `forced` creates the thread running
    # and writes its handle after the hold; `control` writes it before the
    # unlock, as shipped, and holds after. Both copies make a stop skip and
    # record a visit to a line whose handle is still 0.
    unnamed_copy() {
      awk -v gate=gate.part -v mode="$1" '
        /^      fun thread_switch\(thread : UInt32, option : Int32, time : UInt32\) : Int32$/ { print; print "      fun thread_gate_exit = _exit(status : Int32) : NoReturn"; darwin_exit++; next }
        /^    # ── Roots/ { while ((getline line < gate) > 0) print line; roots++ }
        /^    def self\.start\(proc : Proc\(Nil\)\) : IyiThread$/ { starts++; in_start = 1 }
        in_start && /^      \{% elsif flag\?\(:win32\) %\}$/ { win_branches++; in_win = 1 }
        in_start && /^    end$/ { closes++; in_start = 0; in_win = 0 }
        in_win && /^        h = LibC\.CreateThread\(nil, 0_u64, Pointer\(Void\)\.new\(thread_entry\), Pointer\(Void\)\.new\(line\), 4_i32, nil\)$/ {
          created++
          print "        late = IyiThread.release_gate_take_arm"
          if (mode == "forced") print "        h = LibC.CreateThread(nil, 0_u64, Pointer(Void).new(thread_entry), Pointer(Void).new(line), (late ? 0_i32 : 4_i32), nil)"
          else print
          next
        }
        in_win && /^        IyiHeap\.write64\(line \+ IYI_TL_HANDLE, h\.address\)$/ {
          stores++
          if (created != 1 || stores != 1 || unlocks != 0) bad_order = 1
          if (mode == "forced") print "        IyiHeap.write64(line + IYI_TL_HANDLE, h.address) unless late"
          else print
          next
        }
        in_win && /^        IyiRuntimeLock\.unlock$/ {
          unlocks++
          if (created != 1 || stores != 1 || unlocks != 1) bad_order = 1
          print
          print "        IyiThread.release_gate_start_hold(line) if late"
          if (mode == "forced") print "        IyiHeap.write64(line + IYI_TL_HANDLE, h.address) if late"
          next
        }
        /^      private def self\.suspend_others\(line : UInt64\) : Int64$/ { print; print "        IyiThread.release_gate_clear_skip"; clears++; next }
        /^          LibC\.SuspendThread\(Pointer\(Void\)\.new\(IyiHeap\.read64\(cursor \+ IYI_TL_HANDLE\)\)\) if cursor != line$/ { print "          LibC.SuspendThread(Pointer(Void).new(IyiHeap.read64(cursor + IYI_TL_HANDLE))) if cursor != line && !IyiThread.release_gate_unnamed?(cursor, line)"; one++; next }
        /^        deferred = 0_i64$/ { armed_scan = 1 }
        armed_scan && /^          if cursor != line$/ { print "          if cursor != line && !IyiThread.release_gate_skipped?(cursor)"; two++; armed_scan = 0; next }
        /^        if cursor != own$/ { print "        if cursor != own && !IyiThread.release_gate_skipped?(cursor)"; roots3++; next }
        { print }
        END { if (roots != 1 || darwin_exit != 1 || starts != 1 || closes != 1 || win_branches != 1 || created != 1 || stores != 1 || unlocks != 1 || bad_order || clears != 1 || one != 1 || two != 1 || roots3 != 1) exit 3 }
      ' "$REPO/src/iyi/thread.iyi" > "$2"
    }

    step "stress: threads started while two others collect, three runs"
    if ! "$IYI" build starting.iyi -o starting > build-starting.log 2>&1; then
      echo "SETUP: ${current_step:-build}: starting did not build"; cat build-starting.log; exit 76
    fi
    run=1
    while [ "$run" -le 3 ]; do
      timeout 60 ./starting 3 > starting.txt 2>&1
      code=$?; check_bound "$code" healthy "run $run"
      if [ "$code" -eq 76 ]; then cat starting.txt; exit 76; fi
      if [ "$code" -ne 0 ] || ! grep -q '^ok ' starting.txt; then
        echo "FAIL: ${current_step}: run $run exited $code:"; tail -3 starting.txt; exit 1
      fi
      run=$((run + 1))
    done
    echo "  three runs of three seconds, and every thread ran its body"

    step "the gate after the handle is written, the thread still suspended: one run, and nothing recorded"
    mkdir -p held/iyi
    cp "$REPO"/src/iyi/*.iyi held/iyi/
    unnamed_copy control held/iyi/thread.iyi || { echo "SETUP: unnamed: the control start or suspend anchors changed"; exit 76; }
    if ! IYI_PATH="$WORK/held${PSEP}$REPO/src" "$IYI" build starting.iyi -Dunnamed_force -o held-run > build-held.log 2>&1; then
      echo "SETUP: ${current_step:-build}: held did not build"; cat build-held.log; exit 76
    fi
    timeout 60 ./held-run 3 > held.txt 2>&1
    code=$?; check_bound "$code" forced control held.txt
    if [ "$code" -eq 76 ]; then cat held.txt; exit 76; fi
    if [ "$code" -ne 0 ] || ! tr -d '\r' < held.txt | grep -qFx 'unnamed: held=1 collected=1 expired=0, and no stop met a thread without its handle' || ! tr -d '\r' < held.txt | grep -qFx 'ok started=1'; then
      pair_mismatch "$code" held.txt control
    fi
    echo "  control: exit 0, unnamed: held=1 collected=1 expired=0, and no stop met a thread without its handle"

    step "failure proof: a stop that meets a started thread before its handle is written is recorded on its one run"
    mkdir -p unnamed/iyi
    cp "$REPO"/src/iyi/*.iyi unnamed/iyi/
    unnamed_copy forced unnamed/iyi/thread.iyi || { echo "SETUP: unnamed: the mutant start or suspend anchors changed"; exit 76; }
    if ! IYI_PATH="$WORK/unnamed${PSEP}$REPO/src" "$IYI" build starting.iyi -Dunnamed_force -o unnamed-run > build-unnamed.log 2>&1; then
      echo "SETUP: ${current_step:-build}: unnamed did not build"; cat build-unnamed.log; exit 76
    fi
    timeout 60 ./unnamed-run 3 > unnamed.txt 2>&1
    code=$?; check_bound "$code" forced mutant unnamed.txt
    if [ "$code" -eq 76 ]; then cat unnamed.txt; exit 76; fi
    if [ "$code" -ne 1 ] || ! tr -d '\r' < unnamed.txt | grep -qFx 'FAIL: a stop met a started thread whose handle was not yet written'; then
      pair_mismatch "$code" unnamed.txt mutant 0 'unnamed: held=1 collected=1 expired=0, and no stop met a thread without its handle' 'ok started=1'
    fi
    printf '  exits 1 at "%s"\n' 'FAIL: a stop met a started thread whose handle was not yet written'
    ;;
esac

# ── 7c. Windows: a stop scans no stack's guard page ──────────────────────
# A thread, or a task on its fiber stack, stopped after a frame moved sp
# below the committed stack and before its first touch of the new page
# has sp in that stack's guard page, and the scan from sp read it from the
# collecting thread: STATUS_GUARD_PAGE_VIOLATION there, and the process
# died with 0x80000001 and nothing printed, or a fiber's overflow handler
# named a "stack overflow" nobody had. The scan starts at the first
# committed page that is not a guard page now. Ten runs of the old scan
# in ten died, each inside a second; the proof puts it back.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    step "stress: threads and tasks grow fresh stacks beside a collector, three runs"
    cat > guard.iyi <<'IYI'
@[Unsafe("each frame writes an uninitialized pad through pointerof so a fresh stack is touched as it grows")]
class Shared
  getter stop : Atomic(Int64)
  getter grown : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
    @grown = Atomic(Int64).new(0_i64)
  end
end

# Sixteen words a frame, each read back after the call below returns:
# every level steps sp into a page this stack has not touched yet.
def deep(n : Int32) : Int32
  return 0 if n == 0
  pad = uninitialized UInt64[16]
  slot = pointerof(pad).as(Pointer(UInt64))
  slot.value = n.to_u64
  below = deep(n - 1)
  below + (slot.value == n.to_u64 ? 0 : 1)
end

shared = Shared.new
{% if flag?(:guard_force) %}
IyiThread.release_gate_arm_guard
{% end %}
collector = IyiThread.start do
  while shared.stop.get == 0_i64
    IyiMark.collect
  end
  nil
end
deadline = IyiMark.now_ns + Program.args[0].to_i.to_u64 * 1000000_u64
workers = [] of IyiThread
4.times do
  workers << IyiThread.start do
    first = true
    while first || IyiMark.now_ns < deadline
      first = false
      # A healthy stress only: it shows the stacks grow beside a collector
      # and that every run ends. It does not decide the guard proof (step 7c's
      # holder does); a collector that runs after the workers finish proves
      # nothing here, and that is why the proof does not use it.
      IyiThread.start do
        raise "a thread's frames read back wrong" if deep(2000) != 0
        group do |g|
          2.times { g.spawn { deep(400) } }
          0
        end
        nil
      end.join
      shared.grown.add(1_i64)
    end
    nil
  end
end
workers.each(&.join)
shared.stop.set(1_i64)
collector.join
puts "stacks grown beside a collecting thread: #{shared.grown.get > 0}"
IYI
    if ! "$IYI" build guard.iyi -o guard > build-guard.log 2>&1; then
      echo "SETUP: ${current_step:-build}: guard did not build"; cat build-guard.log; exit 76
    fi
    run=1
    while [ "$run" -le 3 ]; do
      timeout 60 ./guard 2000 > guard.txt 2>&1
      code=$?; check_bound "$code" healthy "run $run"
      if [ "$code" -eq 76 ]; then cat guard.txt; exit 76; fi
      if [ "$code" -ne 0 ] || ! grep -q '^stacks grown beside a collecting thread: true' guard.txt; then
        echo "FAIL: ${current_step}: run $run exited $code:"; tail -3 guard.txt; exit 1
      fi
      run=$((run + 1))
    done
    echo "  three runs of two seconds, and every one ended"

    # The guard scan's functions go into a copy's thread.iyi before its roots:
    # `keep` answers the committed page, as shipped (the control); the forced
    # copy answers the page one below it while the arm is up, which is the
    # guard page under a growing stack.
    cat > guard.part <<'IYI'
    # ── The guard scan (bench/thread_exercise.sh, step 7c) ─────────────────
    # Copies only: the awk in that step puts this into a copy of thread.iyi,
    # and the tree has none of it. While armed, a copy's scan of a stopped
    # stack starts inside the stack's guard page (64 bytes into it), which is
    # the guard page under a growing stack.
    IYI_GATE_GUARD = 768_u64
    IYI_GATE_GUARD_HIT = 832_u64
    IYI_GATE_HOLDER = 960_u64
    IYI_GATE_CANDIDATE = 1024_u64
    IYI_GATE_SCANNED = 1088_u64

    def self.release_gate_guard_hit?(address : UInt64) : Bool
      page = word(control + IYI_GATE_GUARD_HIT).value.get
      page != 0_u64 && address >= page && address < page + 4096_u64
    end

    def self.release_gate_arm_guard : Nil
      word(control + IYI_GATE_GUARD).value.set(1_u64)
    end

    # The guard page of the stack `sp` is in: the committed page with
    # PAGE_GUARD in its reservation, found walking up from the allocation
    # base to the top. Windows keeps one guard page at a growing stack's
    # committed edge, so this is the page a scan from below that edge reads
    # first, wherever the stack's sp sits. 0 when there is none.
    def self.guard_page_of(sp : UInt64, top : UInt64) : UInt64
      buffer = uninitialized UInt64[6]
      info = pointerof(buffer).as(Pointer(UInt64))
      if LibC.VirtualQuery(Pointer(Void).new(sp), info.as(Void*), 48_u64) == 0_u64
        message = "SETUP: guard: stack VirtualQuery failed\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        __iyi_exit(76)
      end
      pos = info[1]
      while pos < top
        if LibC.VirtualQuery(Pointer(Void).new(pos), info.as(Void*), 48_u64) == 0_u64 || info[3] == 0_u64
          message = "SETUP: guard: reservation VirtualQuery failed\n"
          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
          __iyi_exit(76)
        end
        return pos if (info[4] & 0xFFFFFFFF_u64) == 0x1000_u64 && (info[4].unsafe_shr(32_u64) & 0x100_u64) != 0_u64
        pos = info[0] + info[3]
      end
      0_u64
    end

    # The holder marks its own stack top before it holds, so the scan can
    # recognise its stack by top alone (no timing, no sp).
    def self.release_gate_holder_mark : Nil
      top = IyiHeap.read64(current_line + IYI_TL_TOP)
      word(control + IYI_GATE_HOLDER).value.set(top)
    end

    # Both copies resolve the same candidate for the holder's stack: the guard
    # page found from its allocation base. The control records the committed
    # scan start it used; the mutant scans from the guard page instead.
    def self.release_gate_candidate : UInt64
      word(control + IYI_GATE_CANDIDATE).value.get
    end

    def self.release_gate_scanned_from : UInt64
      word(control + IYI_GATE_SCANNED).value.get
    end

    def self.release_gate_guard_scan(sp : UInt64, top : UInt64, keep : Bool) : UInt64
      return first_written(sp, top) if word(control + IYI_GATE_GUARD).value.get == 0_u64
      return first_written(sp, top) if word(control + IYI_GATE_HOLDER).value.get != top
      guard = guard_page_of(sp, top)
      if guard == 0_u64
        message = "SETUP: guard: the holder has no guard page\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        __iyi_exit(76)
      end
      word(control + IYI_GATE_CANDIDATE).value.set(guard)
      if keep
        committed = first_written(guard + 64_u64, top)
        buffer = uninitialized UInt64[6]
        info = pointerof(buffer).as(Pointer(UInt64))
        if LibC.VirtualQuery(Pointer(Void).new(committed), info.as(Void*), 48_u64) == 0_u64
          message = "SETUP: guard: normalized scan VirtualQuery failed\n"
          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
          __iyi_exit(76)
        end
        if committed > sp || committed >= top || (info[4] & 0xFFFFFFFF_u64) != 0x1000_u64 || (info[4].unsafe_shr(32_u64) & 0x100_u64) != 0_u64
          message = "FAIL: guard: normalization did not find committed stack memory\n"
          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
          __iyi_exit(1)
        end
        word(control + IYI_GATE_SCANNED).value.set(committed)
        return committed
      end
      word(control + IYI_GATE_GUARD_HIT).value.set(guard)
      guard + 64_u64
    end
IYI
    guard_copy() {
      awk -v gate=guard.part -v keep="$1" '
        /^    # ── Roots/ { while ((getline line < gate) > 0) print line; roots++ }
        /^            sp = first_written\(sp, top\)$/ { print "            sp = IyiThread.release_gate_guard_scan(sp, top, " keep ")"; scans++; next }
        { print }
        END { if (roots != 1 || scans != 1) exit 3 }
      ' "$REPO/src/iyi/thread.iyi" > "$2"
    }
    guard_prelude() {
      awk '
        /^    if code == IYI_WIN_GUARD_PAGE$/ { guard_branch++; inside_guard = 1 }
        /^    if code == IYI_WIN_ACCESS_VIOLATION$/ { access_branch++; inside_guard = 0 }
        inside_guard && /^        if IyiScheduler.fiber_guard_hit\?\(faulting\)$/ {
          print "        if IyiThread.release_gate_guard_hit?(faulting)"
          print "          message = \"FAIL: guard: a stop scan began inside its guard page\\n\""
          print "          LibC.WriteFile(handle, message.to_unsafe.as(Void*), message.bytesize, pointerof(written), nil)"
          print "          __iyi_win_fault_exit"
          print "        end"
          found++
        }
        { print }
        END { if (guard_branch != 1 || access_branch != 1 || found != 1) exit 3 }
      ' "$REPO/src/iyi/prelude.iyi" > "$1"
    }

    cat > guard-hold.iyi <<'IYI'
@[Unsafe("the holder marks its own stack top and then spins without allocating; the copy records are the only shared state")]
class Shared
  getter ready : Atomic(Int64)
  getter release : Atomic(Int64)

  def initialize
    @ready = Atomic(Int64).new(0_i64)
    @release = Atomic(Int64).new(0_i64)
  end
end

def hold(shared : Shared) : Nil
  {% if flag?(:guard_force) %}
  IyiThread.release_gate_holder_mark
  {% end %}
  shared.ready.set(1_i64)
  while shared.release.get == 0_i64
    IyiThread.spin_pause
  end
end

shared = Shared.new
{% if flag?(:guard_force) %}
IyiThread.release_gate_arm_guard
{% end %}
holder = IyiThread.start { hold(shared); nil }
watch = IyiMark.now_ns &+ 20000000000_u64
while shared.ready.get == 0_i64
  if IyiMark.now_ns >= watch
    print "SETUP: guard: the holder never reached its hold\n"
    __iyi_exit(76)
  end
  IyiThread.yield_cpu
end
IyiMark.collect
shared.release.set(1_i64)
holder.join
{% if flag?(:guard_force) %}
if IyiThread.release_gate_candidate == 0_u64
  print "SETUP: guard: the holder's stack has no guard page\n"
  __iyi_exit(76)
end
if IyiThread.release_gate_scanned_from == 0_u64
  print "SETUP: guard: the stop did not scan the holder's stack\n"
  __iyi_exit(76)
end
puts "guard: the stop scanned the holder's stack from its committed page"
{% end %}
IYI
    step "the holder's stack, scanned from its committed page, armed: one run, and the scan is reported"
    mkdir -p kept/iyi
    cp "$REPO"/src/iyi/*.iyi kept/iyi/
    guard_copy true kept/iyi/thread.iyi || { echo "SETUP: guard: scan anchor changed"; exit 76; }
    guard_prelude kept/iyi/prelude.iyi || { echo "SETUP: guard: fault handler anchor changed"; exit 76; }
    if ! IYI_PATH="$WORK/kept${PSEP}$REPO/src" "$IYI" build guard-hold.iyi -Dguard_force -o guard-kept > build-kept.log 2>&1; then
      echo "SETUP: guard: the control copy did not build"; cat build-kept.log; exit 76
    fi
    timeout 60 ./guard-kept > kept.txt 2>&1
    code=$?; check_bound "$code" forced control kept.txt
    if [ "$code" -eq 76 ]; then cat kept.txt; exit 76; fi
    if [ "$code" -ne 0 ] || ! tr -d '\r' < kept.txt | grep -qxF "guard: the stop scanned the holder's stack from its committed page"; then
      pair_mismatch "$code" kept.txt control
    fi
    echo "  control: exit 0, guard: the stop scanned the holder's stack from its committed page"

    step "failure proof: the holder's stack scanned from its guard page dies on its one run"
    mkdir -p guarded/iyi
    cp "$REPO"/src/iyi/*.iyi guarded/iyi/
    guard_copy false guarded/iyi/thread.iyi || { echo "SETUP: guard: scan anchor changed"; exit 76; }
    guard_prelude guarded/iyi/prelude.iyi || { echo "SETUP: guard: fault handler anchor changed"; exit 76; }
    if ! IYI_PATH="$WORK/guarded${PSEP}$REPO/src" "$IYI" build guard-hold.iyi -Dguard_force -o guard-from-sp > build-guarded.log 2>&1; then
      echo "SETUP: guard: the guard-page copy did not build"; cat build-guarded.log; exit 76
    fi
    timeout 60 ./guard-from-sp > guarded.txt 2>&1
    code=$?; check_bound "$code" forced mutant guarded.txt
    if [ "$code" -eq 76 ]; then cat guarded.txt; exit 76; fi
    if [ "$code" -ne 1 ] || ! grep -qxF 'FAIL: guard: a stop scan began inside its guard page' guarded.txt; then
      pair_mismatch "$code" guarded.txt mutant 0 "guard: the stop scanned the holder's stack from its committed page"
    fi
    echo "  exits 1 at \"FAIL: guard: a stop scan began inside its guard page\""

    step "failure proof: an identity stack normalization rejects a guard-page input"
    mkdir -p identity/iyi
    cp kept/iyi/*.iyi identity/iyi/
    awk '
      /^      def self\.first_written\(sp : UInt64, top : UInt64\) : UInt64$/ {
        print; print "        return sp"; found++; next
      }
      { print }
      END { if (found != 1) exit 3 }
    ' kept/iyi/thread.iyi > identity/iyi/thread.iyi || { echo "SETUP: guard: normalization anchor changed"; exit 76; }
    if ! IYI_PATH="$WORK/identity${PSEP}$REPO/src" "$IYI" build guard-hold.iyi -Dguard_force -o guard-identity > build-identity.log 2>&1; then
      echo "SETUP: guard: the identity copy did not build"; cat build-identity.log; exit 76
    fi
    timeout 60 ./guard-identity > identity.txt 2>&1
    code=$?; check_bound "$code" forced mutant identity.txt
    if [ "$code" -eq 76 ]; then cat identity.txt; exit 76; fi
    if [ "$code" -ne 1 ] || ! tr -d '\r' < identity.txt | grep -qxF 'FAIL: guard: normalization did not find committed stack memory'; then
      pair_mismatch "$code" identity.txt mutant 0 "guard: the stop scanned the holder's stack from its committed page"
    fi
    echo '  exits 1 at "FAIL: guard: normalization did not find committed stack memory"'
    ;;
esac

# ── 7d. darwin: a stop names a thread only once its thread-locals are made ─
# dyld makes a thread's thread-locals at its first touch of one, a `calloc`
# of the image's whole block, and the stop's handler reads two of them. The
# parent linked a thread's line before `pthread_create`, so a stop could
# signal the thread inside that `calloc`; the handler's read made the block
# again and took the allocator's lock the interrupted call held, and
# libplatform killed the process ("Trying to recursively lock an
# os_unfair_lock") or libmalloc trapped ("ulock_wait failure"). The
# switching program above died so in 5 runs of 130 on macOS 26.6 (an M2
# Pro), and the program below in 19 of 20 (18 killed, 1 trapped), each
# inside 4 s. A thread links its own line now, after its first touch: the
# program, 3,200 threads a run, sixteen at a time beside a thread that
# collects in a loop, remains as stress. The proof holds one child at run
# entry, before the TLS write. Both copies observe the stop's real signal
# site; the mutant links the line in its parent and fails before signaling it.
#
# A run is bounded by its own clock, not by a count: twenty rounds, then
# rounds until 10 s have passed, 200 at most. Every run was 200 rounds and
# held to 60 s by the harness, and macos-15's three-core runners make 54
# to 479 threads a second (147 the median, 425 runs over four runners in
# debug jobs) where the M2 makes about 1,100: 3,200 threads took 7.2 to
# 59.6 s there, and CI's job ran out the 60 s on its first run once. The
# slowest twenty rounds of 438 runs took 11.5 s, so a run ends inside
# about 23 s on that machine, and the 60 s is left to say a run hung.
case "$(uname -s)" in
  Darwin)
    step "stress: darwin threads born sixteen at a time beside a collector, five runs"
    cat > born.iyi <<'IYI'
module born

import std/gc::{GC}

class Flag
  getter stop : Atomic(Int64)
  getter born : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
    @born = Atomic(Int64).new(0_i64)
  end
end

def storm(flag : Flag) : Nil
  while flag.stop.get == 0_i64
    GC.collect
  end
end

def arrive(flag : Flag) : Nil
  flag.born.add(1_i64)
end

flag = Flag.new
stormer = IyiThread.start { storm(flag) }
rounds = Program.args[0].to_i
deadline = __iyi_monotonic_ns + Program.args[1].to_i.to_i64 * 1_000_000_000_i64
started = 0
round = 0
while round < rounds && (round < 20 || __iyi_monotonic_ns < deadline)
  batch = [] of IyiThread
  16.times { batch << IyiThread.start { arrive(flag) } }
  started = started + 16
  batch.each(&.join)
  round = round + 1
end
flag.stop.set(1_i64)
stormer.join
raise "born #{flag.born.get} of #{started}" if flag.born.get != started
puts "ok born=#{started} stops=#{IyiThread.stops}"
IYI
    if ! "$IYI" build born.iyi -o born > build-born.log 2>&1; then
      echo "SETUP: ${current_step:-build}: born did not build"; cat build-born.log; exit 76
    fi
    # In a subshell that waits, so a run a signal ends is reported here,
    # by its status, and not by the shell's job notice.
    run=1
    born=""
    while [ "$run" -le 5 ]; do
      ( timeout 60 ./born 200 10 > born.txt 2>&1; exit $? ) 2> /dev/null
      code=$?; check_bound "$code" healthy "run $run"
      if [ "$code" -eq 76 ]; then cat born.txt; exit 76; fi
      if [ "$code" -ne 0 ] || ! grep -q '^ok born=[0-9]* ' born.txt; then
        echo "FAIL: ${current_step}: run $run exited $code:"; tail -3 born.txt; exit 1
      fi
      born="$born $(sed -n 's/^ok born=\([0-9]*\) .*/\1/p' born.txt)"
      run=$((run + 1))
    done
    echo "  five runs, every thread born and joined:$born threads"

    cat > pretls.part <<'IYI'
    IYI_PRETLS_ARM = 384_u64
    IYI_PRETLS_LINE = 448_u64
    IYI_PRETLS_OPEN = 512_u64
    IYI_PRETLS_STOP = 576_u64
    def self.pretls_arm : Nil
      word(control + IYI_PRETLS_ARM).value.set(1_u64)
    end
    def self.pretls_held? : Bool
      word(control + IYI_PRETLS_LINE).value.get != 0_u64
    end
    def self.pretls_stopped? : Bool
      word(control + IYI_PRETLS_STOP).value.get != 0_u64
    end
    def self.pretls_open : Nil
      word(control + IYI_PRETLS_OPEN).value.set(1_u64)
    end
    # Called at run entry, before the child's first TLS write. Do not read a
    # thread-local or lazily create the shared control page here.
    def self.pretls_hold(line : UInt64) : Nil
      page = @@control
      return if page == 0_u64 || !word(page + IYI_PRETLS_ARM).value.compare_and_set(1_u64, 0_u64)[1]
      word(page + IYI_PRETLS_LINE).value.set(line)
      began = IyiMark.now_ns
      while word(page + IYI_PRETLS_OPEN).value.get == 0_u64
        if IyiMark.now_ns &- began > 20000000000_u64
          message = "SETUP: pretls: the held child was never opened\n"
          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
          LibC.pretls_exit(76_i32)
        end
        yield_cpu
      end
    end
    def self.pretls_stop : Nil
      page = @@control
      return if page == 0_u64 || word(page + IYI_PRETLS_LINE).value.get == 0_u64 || word(page + IYI_PRETLS_OPEN).value.get != 0_u64
      word(page + IYI_PRETLS_STOP).value.set(1_u64)
    end
    def self.pretls_signal(cursor : UInt64) : Nil
      page = @@control
      return if page == 0_u64 || word(page + IYI_PRETLS_OPEN).value.get != 0_u64
      return if cursor == 0_u64 || cursor != word(page + IYI_PRETLS_LINE).value.get
      message = "FAIL: pretls: a stop named a child before its first TLS write\n"
      __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
      LibC.pretls_exit(1_i32)
    end
IYI
    pretls_copy() {
      awk -v part=pretls.part -v mode="$1" '
        /^      fun thread_switch\(thread : UInt32, option : Int32, time : UInt32\) : Int32$/ { print; print "      fun pretls_exit = _exit(status : Int32) : NoReturn"; alias_count++; next }
        /^    # ── Roots/ { while ((getline s < part) > 0) print s; roots++ }
        /^    def self\.start\(proc : Proc\(Nil\)\) : IyiThread$/ { in_start = 1; starts++ }
        in_start && /^      \{% elsif flag\?\(:darwin\) %\}$/ { in_darwin = 1; darwin++ }
        in_start && /^      \{% elsif flag\?\(:win32\) %\}$/ { in_darwin = 0 }
        in_start && /^    end$/ { in_start = 0; in_darwin = 0; start_ends++ }
        in_darwin && /^        result = LibC\.pthread_create\(Pointer\(UInt64\)\.new\(line \+ IYI_TL_HANDLE\), / {
          if (mode == "forced") { print "        IyiHeap.write64(line + IYI_TL_NEXT, @@lines)"; print "        @@lines = line"; print "        @@count = @@count + 1_i64" }
          created++
        }
        /^    def self\.run\(line : UInt64\) : Nil$/ { print; print "      IyiThread.pretls_hold(line)"; runs++; in_run = 1; next }
        in_run && /^    end$/ { in_run = 0; run_ends++ }
        in_run && /^        link\(line\)$/ { links++; if (mode == "forced") next }
        /^      return 0_i64 if @@count == 0_i64 \|\| \(line != 0 && @@count <= 1_i64\)$/ { print "      IyiThread.pretls_stop"; stops++ }
        /^              result = LibC\.pthread_kill\(handle, IYI_SIGSTOP_THE_WORLD\)$/ { print "              IyiThread.pretls_signal(cursor)"; signals++ }
        { print }
        END { if (alias_count != 1 || roots != 1 || starts != 1 || start_ends != 1 || darwin != 1 || created != 1 || runs != 1 || run_ends != 1 || links != 1 || stops != 1 || signals != 1) exit 3 }
      ' "$REPO/src/iyi/thread.iyi" > "$2"
    }
    cat > pretls.iyi <<'IYI'
@[Unsafe("the copy-only proof holds a child before its first thread-local write")]
class Gate
  getter ready : Atomic(Int64)
  getter stop : Atomic(Int64)
  def initialize
    @ready = Atomic(Int64).new(0_i64)
    @stop = Atomic(Int64).new(0_i64)
  end
end
IyiMark.auto = false
IyiMark.workers = 0_u64
IyiThread.pretls_arm
gate = Gate.new
thread = IyiThread.start do
  gate.ready.set(1_i64)
  while gate.stop.get == 0_i64
    IyiThread.spin_pause
  end
  nil
end
deadline = IyiMark.now_ns &+ 20000000000_u64
while !IyiThread.pretls_held?
  if IyiMark.now_ns >= deadline
    print "SETUP: pretls: the child never reached run entry\n"
    __iyi_exit(76)
  end
  IyiThread.yield_cpu
end
IyiMark.collect
unless IyiThread.pretls_stopped?
  print "SETUP: pretls: the held-child stop was not observed\n"
  __iyi_exit(76)
end
IyiThread.pretls_open
deadline = IyiMark.now_ns &+ 20000000000_u64
while gate.ready.get == 0_i64
  if IyiMark.now_ns >= deadline
    print "SETUP: pretls: the child did not start after opening\n"
    __iyi_exit(76)
  end
  IyiThread.yield_cpu
end
before = IyiThread.stopped
IyiMark.collect
if IyiThread.stopped <= before
  print "SETUP: pretls: the linked child was not stopped\n"
  __iyi_exit(76)
end
gate.stop.set(1_i64)
thread.join
puts "pretls: the pre-TLS child was not named, then its linked line was stopped"
IYI
    for mode in control forced; do
      mkdir -p "pretls-$mode/iyi"
      cp "$REPO"/src/iyi/*.iyi "pretls-$mode/iyi/"
      pretls_copy "$mode" "pretls-$mode/iyi/thread.iyi" || { echo "SETUP: pretls: copy anchors changed"; exit 76; }
      if ! IYI_PATH="$WORK/pretls-$mode${PSEP}$REPO/src" "$IYI" build pretls.iyi -o "pretls-$mode-run" > "build-pretls-$mode.log" 2>&1; then
        echo "SETUP: pretls: the $mode copy did not build"; cat "build-pretls-$mode.log"; exit 76
      fi
      step "darwin: pre-TLS child $mode"
      timeout 60 "./pretls-$mode-run" > "pretls-$mode.txt" 2>&1
      code=$?; check_bound "$code" forced "$mode" "pretls-$mode.txt"
      if [ "$code" -eq 76 ]; then cat "pretls-$mode.txt"; exit 76; fi
      if [ "$mode" = control ]; then
        [ "$code" -eq 0 ] && grep -qxF 'pretls: the pre-TLS child was not named, then its linked line was stopped' "pretls-$mode.txt" || pair_mismatch "$code" "pretls-$mode.txt" control
        echo '  control: exit 0, pretls: the pre-TLS child was not named, then its linked line was stopped'
      else
        [ "$code" -eq 1 ] && grep -qxF 'FAIL: pretls: a stop named a child before its first TLS write' "pretls-$mode.txt" || pair_mismatch "$code" "pretls-$mode.txt" mutant 0 'pretls: the pre-TLS child was not named, then its linked line was stopped'
        echo '  exits 1 at "FAIL: pretls: a stop named a child before its first TLS write"'
      fi
    done

    ;;
esac

# ── 7e. darwin: a thread's first allocation, held by its own frame ────────
# A darwin thread wrote its stack's top on its line after
# `IyiStackGuard.install`, whose `stack_t` is the thread's first heap chunk.
# A stop between that allocation and the top write scanned nothing for the
# stack, `GC.collect` swept the chunk in its pause, and the stores after it
# wrote over the free batch it went onto: 7d's program died of SIGSEGV in 13
# runs of 342 of 3,200 threads on macos-15's three cores, 12 of the 13 at the
# centre's next pop of the class, reading 0x10008, the `stack_t`'s 65,536 plus
# 8. The runtime writes the top before the install (copy `topfirst`); copy
# `toplate` writes it after the install again.
#
# The two copies carry the same witnesses and differ only in that order. The
# child makes the `stack_t` in `IyiStackGuard.install` (through the armed call
# of `IyiThread.line_first_alloc`), keeps its address in one slot of its own
# frame, clears every integer register that could hold it, and publishes HELD.
# The parent runs two collections, and each must visit the held line. The
# child then releases the hold (OPEN) and checks the chunk before its first
# store: it must still be allocated. The control's frame scan keeps the chunk.
# In the mutant the stopped thread has no top yet, so the stack scan covers
# none of its frame, the sweep frees the chunk, and the child exits 1 with the
# named sentence. A setup failure and a hung run exit 76.
case "$(uname -s)" in
  Darwin)
    step "darwin: a thread's first allocation, held in its frame through two collections, is not swept"
    cat > first-asm.part <<'IYI'
{% if flag?(:darwin) && flag?(:aarch64) %}
# The copy-only hold of the first allocation (bench/thread_exercise.sh, 7e).
# `cell` is the frame slot that holds the allocation's address, and `page` is
# the control page. The hold publishes the allocation and the slot's address
# to the page (ALLOCATION at 576, CELL at 640), saves the caller's callee-saved
# registers on its own frame, clears every integer register that could hold
# the allocation, publishes HELD (448), and waits for OPEN (512).
@[NoInline]
@[Naked]
fun __iyi_first_frame_hold(cell : UInt64, page : UInt64) : Nil
  asm("stp x19, x20, [sp, #-96]!
       stp x21, x22, [sp, #16]
       stp x23, x24, [sp, #32]
       stp x25, x26, [sp, #48]
       stp x27, x28, [sp, #64]
       stp x29, x30, [sp, #80]
       add x29, sp, #80
       ldr x2, [x0]
       add x3, x1, #576
       stlr x2, [x3]
       add x3, x1, #640
       stlr x0, [x3]
       mov x0, x1
       mov x1, xzr
       mov x2, xzr
       mov x3, xzr
       mov x4, xzr
       mov x5, xzr
       mov x6, xzr
       mov x7, xzr
       mov x8, xzr
       mov x9, xzr
       mov x10, xzr
       mov x11, xzr
       mov x12, xzr
       mov x13, xzr
       mov x14, xzr
       mov x15, xzr
       mov x16, xzr
       mov x17, xzr
       mov x19, xzr
       mov x20, xzr
       mov x21, xzr
       mov x22, xzr
       mov x23, xzr
       mov x24, xzr
       mov x25, xzr
       mov x26, xzr
       mov x27, xzr
       mov x28, xzr
       mov x1, #1
       add x2, x0, #448
       stlr x1, [x2]
       add x2, x0, #512
       1:
       ldar x3, [x2]
       cbnz x3, 2f
       yield
       b 1b
       2:
       ldp x29, x30, [sp, #80]
       ldp x27, x28, [sp, #64]
       ldp x25, x26, [sp, #48]
       ldp x23, x24, [sp, #32]
       ldp x21, x22, [sp, #16]
       ldp x19, x20, [sp], #96
       ret" :::: "volatile")
end

# The walk's check of one stopped thread: 0 when the frame slot holds the
# allocation and no saved integer register points into it, 1 when the slot
# does not hold it, 2 when a register does. `spill` is the thread's 31 saved
# integer registers, and `allocation_word` is the page's ALLOCATION word.
@[NoInline]
@[Naked]
fun __iyi_first_frame_check(cell : UInt64, spill : UInt64, allocation_word : UInt64) : UInt64
  asm("ldar x3, [x2]
       ldr x4, [x0]
       cmp x4, x3
       b.ne 3f
       mov x5, #31
       1:
       ldr x4, [x1], #8
       sub x4, x4, x3
       cmp x4, #24
       b.lo 4f
       subs x5, x5, #1
       b.ne 1b
       mov x0, #0
       b 5f
       3:
       mov x0, #1
       b 5f
       4:
       mov x0, #2
       5:
       mov x1, xzr
       mov x2, xzr
       mov x3, xzr
       mov x4, xzr
       mov x5, xzr
       ret" :::: "volatile")
  0_u64
end
{% end %}
IYI
    cat > first-thread.part <<'IYI'
    # ── The first allocation under test (bench/thread_exercise.sh, 7e) ─────
    # Copies only: the awk in that step puts this into a copy of the runtime's
    # thread.iyi, and the tree has none of it. The control-page words are
    # armed by the parent (ARM), set by the child (LINE, CELL and ALLOCATION,
    # then HELD), released by the parent (OPEN), and counted by each collection
    # that visits the armed line while it is held (VISITS).
    IYI_FIRST_ARM        = 384_u64
    IYI_FIRST_HELD       = 448_u64
    IYI_FIRST_OPEN       = 512_u64
    IYI_FIRST_ALLOCATION = 576_u64
    IYI_FIRST_CELL       = 640_u64
    IYI_FIRST_LINE       = 704_u64
    IYI_FIRST_VISITS     = 768_u64

    def self.first_arm : Nil
      word(control + IYI_FIRST_ARM).value.set(1_u64)
    end

    def self.first_held? : Bool
      word(control + IYI_FIRST_HELD).value.get != 0_u64
    end

    def self.first_open : Nil
      word(control + IYI_FIRST_OPEN).value.set(1_u64)
    end

    def self.first_visits : UInt64
      word(control + IYI_FIRST_VISITS).value.get
    end

    # The chunk `IyiStackGuard.install` makes for its `stack_t`. The armed call
    # keeps the chunk's address in one slot of this frame until the parent
    # releases it; every other call is a plain allocation. Before the first
    # store the chunk must still be allocated. A sweep that freed it leaves its
    # FREE flag set, or releases its arena, and then `IyiHeap.arena_of` answers
    # 0 from the directory without touching the unmapped memory.
    @[NoInline]
    def self.line_first_alloc : UInt64
      page = @@control
      if page == 0_u64 || !word(page + IYI_FIRST_ARM).value.compare_and_set(1_u64, 0_u64)[1]
        return Pointer(UInt64).malloc(3_u64).address
      end
      if @@line == 0_u64
        message = "SETUP: first: the first allocation ran before its thread was named\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        LibC.first_frame_exit(76_i32)
      end
      cell = uninitialized UInt64
      cell_address = pointerof(cell).address
      Pointer(UInt64).new(cell_address).value = Pointer(UInt64).malloc(3_u64).address
      word(page + IYI_FIRST_LINE).value.set(@@line)
      __iyi_first_frame_hold(cell_address, page)
      allocation = Pointer(UInt64).new(cell_address).value
      if IyiHeap.arena_of(allocation) == 0_u64 || IyiMark.flags(allocation) & IyiHeap::FREE_FLAG != 0_u64
        message = "FAIL: toplate: the first allocation was swept while its frame held it\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        LibC.first_frame_exit(1_i32)
      end
      allocation
    end

    # Each collection calls this for every stopped thread, after it has scanned
    # that thread's stack. The armed line counts a visit while it is held. The
    # frame slot must lie in the scanned stack and no saved integer register
    # may hold the allocation; a broken witness is a setup failure. A top the
    # thread has not written scans nothing, which is how the mutant's stop
    # finds the frame.
    def self.first_visit(cursor : UInt64, sp : UInt64, top : UInt64) : Nil
      page = @@control
      return if page == 0_u64 || word(page + IYI_FIRST_HELD).value.get == 0_u64
      return if word(page + IYI_FIRST_LINE).value.get != cursor
      cell = word(page + IYI_FIRST_CELL).value.get
      if cell == 0_u64 || cell.unsafe_mod(8_u64) != 0_u64 || cell < sp || (top != 0_u64 && (cell >= top || top &- cell < 8_u64))
        message = "SETUP: first: the frame slot is outside the stopped stack\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        LibC.first_frame_exit(76_i32)
      end
      checked = __iyi_first_frame_check(cell, cursor + IYI_TL_SPILL, page + IYI_FIRST_ALLOCATION)
      if checked == 1_u64
        message = "SETUP: first: the frame slot does not hold the allocation\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        LibC.first_frame_exit(76_i32)
      elsif checked == 2_u64
        message = "SETUP: first: a stopped register holds the allocation\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        LibC.first_frame_exit(76_i32)
      end
      word(page + IYI_FIRST_VISITS).value.add(1_u64)
    end

IYI
    cat > first-concurrency.awk <<'AWK'
# Puts the copy-only hold and check before `module IyiStackGuard`, once, and
# makes the darwin install's `stack_t` the armed first allocation, once.
/^  module IyiStackGuard$/ {
  while ((getline line < part) > 0) print line
  modules++
}
/^    def self\.install : Nil$/ { inside = 1; installs++ }
inside && /^      \{% if flag\?\(:darwin\) %\}$/ { in_darwin = 1; darwins++ }
inside && /^      \{% else %\}$/ { in_darwin = 0 }
inside && /^    end$/ { inside = 0 }
in_darwin && /^        stack = Pointer\(UInt64\)\.malloc\(3_u64\)$/ {
  print "        stack = Pointer(UInt64).new(IyiThread.line_first_alloc)"
  allocations++
  next
}
{ print }
END { if (modules != 1 || installs != 1 || darwins != 1 || allocations != 1) exit 3 }
AWK
    cat > first-thread.awk <<'AWK'
# Each anchor once: the darwin lib's thread_switch (for the exit alias), the
# part before the roots, the run's darwin top and install (the top moves after
# the install in toplate only), and the stack scan that gets the visit hook.
/^      fun thread_switch\(thread : UInt32, option : Int32, time : UInt32\) : Int32$/ {
  print
  print "      fun first_frame_exit = _exit(status : Int32) : NoReturn"
  exits++
  next
}
/^    # ── Roots/ {
  while ((getline line < part) > 0) print line
  roots++
}
/^    def self\.run\(line : UInt64\) : Nil$/ { in_run = 1; runs++ }
in_run && /^      \{% if flag\?\(:darwin\) %\}$/ && !seen_darwin { in_darwin = 1; seen_darwin = 1; darwins++ }
in_run && in_darwin && /^      \{% elsif flag\?\(:linux\) %\}$/ { in_darwin = 0 }
in_run && in_darwin && /^        IyiHeap\.write64\(line \+ IYI_TL_TOP, IyiRoots\.discover_stack_base\)$/ {
  top = $0
  tops++
  if (mode == "toplate") next
}
in_run && /^        IyiStackGuard\.install$/ {
  print
  if (mode == "toplate" && tops == 1) print top
  installs++
  next
}
in_run && /^    end$/ { in_run = 0; run_ends++ }
/^    def self\.each_stopped_root\(visit : Proc\(UInt64, Nil\)\) : Nil$/ { in_scan = 1; scans++ }
in_scan && /^          IyiRoots\.scan_range\(sp, top, visit\)$/ {
  print
  print "          IyiThread.first_visit(cursor, sp, top)"
  visits++
  next
}
in_scan && /^    end$/ { in_scan = 0; scan_ends++ }
{ print }
END {
  if (mode != "topfirst" && mode != "toplate") exit 3
  if (exits != 1 || roots != 1 || runs != 1 || run_ends != 1 || darwins != 1 || tops != 1 || installs != 1 || scans != 1 || scan_ends != 1 || visits != 1) exit 3
}
AWK
    cat > first-frame.iyi <<'IYI'
module first_frame

IyiMark.auto = false
IyiMark.workers = 0_u64
IyiThread.first_arm
thread = IyiThread.start { nil }
deadline = IyiMark.now_ns &+ 20000000000_u64
while !IyiThread.first_held?
  if IyiMark.now_ns >= deadline
    print "SETUP: first: the child never held its first allocation\n"
    __iyi_exit(76)
  end
  IyiThread.yield_cpu
end
before = IyiThread.first_visits
IyiMark.collect
if IyiThread.first_visits <= before
  print "SETUP: first: the first collection did not visit the held line\n"
  __iyi_exit(76)
end
before = IyiThread.first_visits
IyiMark.collect
if IyiThread.first_visits <= before
  print "SETUP: first: the second collection did not visit the held line\n"
  __iyi_exit(76)
end
IyiThread.first_open
thread.join
puts "first: the first allocation survived two collections that visited its line"
IYI
    first_ok='first: the first allocation survived two collections that visited its line'
    first_fail='FAIL: toplate: the first allocation was swept while its frame held it'
    for copy in topfirst toplate; do
      mkdir -p "$copy/iyi"
      cp "$REPO"/src/iyi/*.iyi "$copy/iyi/"
      awk -v part=first-asm.part -f first-concurrency.awk "$REPO/src/iyi/concurrency.iyi" > "$copy/iyi/concurrency.iyi" || { echo "SETUP: first: the stack guard's first allocation is not in concurrency.iyi any more"; exit 76; }
      awk -v part=first-thread.part -v mode="$copy" -f first-thread.awk "$REPO/src/iyi/thread.iyi" > "$copy/iyi/thread.iyi" || { echo "SETUP: first: the thread's top, its stack guard or its stack scan is not in thread.iyi any more"; exit 76; }
      if ! IYI_PATH="$WORK/$copy${PSEP}$REPO/src" "$IYI" build first-frame.iyi -o "$copy-run" > "build-$copy.log" 2>&1; then
        cat "build-$copy.log"; echo "SETUP: first: the $copy copy did not build"; exit 76
      fi
    done
    for copy in topfirst toplate; do
      timeout 60 "./$copy-run" > "$copy.txt" 2>&1
      code=$?; check_bound "$code" forced "$copy" "$copy.txt"
      if [ "$code" -eq 76 ]; then cat "$copy.txt"; exit 76; fi
      answer="$(cat "$copy.txt")"
      if [ "$copy" = topfirst ]; then
        if [ "$code" -eq 0 ] && [ "$answer" = "$first_ok" ]; then
          echo "  control: exit 0, $first_ok"
        else
          pair_mismatch "$code" "$copy.txt" control
        fi
      elif [ "$code" -eq 1 ] && [ "$answer" = "$first_fail" ]; then
        echo "  exits 1 at \"$first_fail\""
      else
        pair_mismatch "$code" "$copy.txt" mutant 0 "$first_ok"
      fi
    done
    ;;
esac

# ── 7f. A stop at a fresh task's first instruction scans that task's stack ─
# On aarch64 a fresh fiber's first resume pops the whole frame
# `settle_stack` laid, so the switch's `ret` and `__iyi_fiber_main`'s first
# instruction run with sp at the fiber stack's top. The stop's scan asks
# `IyiScheduler.fiber_top_holding` which stack holds a stopped thread's sp,
# and it answered that the top was no fiber's: the scan ran from there up
# to the thread's own top, across the mappings between. On macOS 26.6, an
# M2 Pro with 10 cores, the program below without its check died so, of
# SIGSEGV or SIGBUS in the collector's `scan_range`, in 9 runs of 23 of
# 5 s, the main thread stopped at that instruction in every crash report;
# and bench/concurrency_exercise.iyi hung in 2 of 675 soak runs there,
# the one sampled where a mark helper had faulted so and its fault
# handler waited on the runtime lock (7g). With the top counted as the
# fiber's, none of 26.
# A stop lands on one of two instructions in a task's life, so a run's
# death is luck; each task asks the scan's own question of its own top
# as well, which the old bound answers wrongly every time. It asks under
# the runtime lock, as the stop does: the fiber list changes under that
# lock, and with the pool's workers starting tasks beside it the walk
# unlocked read a list mid-change. On the M2, on mt/next at 341a034b3,
# the unlocked check failed 18 of 20 runs of 5 s, with and without the
# turn-counter release; under the lock, none of 6.
case "$(uname -s)" in
  Linux | Darwin)
    step "a fresh task's first-instruction stack top, control"
    cat > fresh.iyi <<'IYI'
module fresh

import std/gc::{GC}

class Flag
  getter stop : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
  end
end

def storm(flag : Flag) : Nil
  while flag.stop.get == 0_i64
    GC.collect
  end
end

# Where a stop finds sp at a task's first instruction on aarch64, asked of
# the scan the way the stop asks it.
def first_run : Int32
  top = IyiScheduler.current_stack_top
  if top == 0_u64
    print "SETUP: fresh tasks: a task ran on no fiber stack\n"
    __iyi_exit(76)
  end
  IyiRuntimeLock.lock
  held = IyiScheduler.fiber_top_holding(top)
  IyiRuntimeLock.unlock
  if held != top
    print "FAIL: fresh tasks: a task's stack top is no task's to the stop's scan\n"
    __iyi_exit(1)
  end
  0
end

def burst : Nil
  group do |g|
    64.times do
      g.spawn do
        first_run
      end
    end
  end
end

{% if flag?(:fresh_witness) %}
IyiMark.auto = false
group do |g|
  g.spawn(unit: :same) { first_run }
  0
end
puts "fresh tasks: the first task's top is its own stack's to the stop's scan"
__iyi_exit(0)
{% end %}

flag = Flag.new
stormer = IyiThread.start { storm(flag) }
deadline = __iyi_monotonic_ns + Program.args[0].to_i.to_i64 * 1_000_000_000_i64
started = 0
while started == 0 || __iyi_monotonic_ns < deadline
  burst
  started = started + 64
end
flag.stop.set(1_i64)
stormer.join
puts "ok started=#{started} stops=#{IyiThread.stops}"
IYI
    fresh_ok="fresh tasks: the first task's top is its own stack's to the stop's scan"
    fresh_fail="FAIL: fresh tasks: a task's stack top is no task's to the stop's scan"
    if ! "$IYI" build -Dfresh_witness fresh.iyi -o fresh-control > build-fresh-control.log 2>&1; then
      echo "SETUP: fresh tasks: the control did not build"; cat build-fresh-control.log; exit 76
    fi
    ( timeout 60 ./fresh-control > fresh-control.txt 2>&1; exit $? ) 2> /dev/null
    code=$?; check_bound "$code" forced control fresh-control.txt
    if [ "$code" -eq 76 ]; then cat fresh-control.txt; exit 76; fi
    [ "$code" -eq 0 ] && grep -qxF "$fresh_ok" fresh-control.txt || pair_mismatch "$code" fresh-control.txt control
    printf '  control: exit 0, %s\n' "$fresh_ok"

    step "failure proof: a fiber's top read as no fiber's, as it was"
    mkdir -p topless/iyi
    cp "$REPO"/src/iyi/*.iyi topless/iyi/
    awk '/^      return top if top != 0 && address <= top && address > top - IyiFiber::STACK_BYTES$/ {
        print "      return top if top != 0 && address < top && address >= top - IyiFiber::STACK_BYTES"; found++; next }
      { print } END { if (found != 1) exit 3 }' \
      "$REPO/src/iyi/concurrency.iyi" > topless/iyi/concurrency.iyi || { echo "SETUP: ${current_step:-topless}: the fiber stack bound anchor changed"; exit 76; }
    if ! IYI_PATH="$WORK/topless${PSEP}$REPO/src" "$IYI" build -Dfresh_witness fresh.iyi -o topless-run > build-topless.log 2>&1; then
      echo "SETUP: fresh tasks: the mutant did not build"; cat build-topless.log; exit 76
    fi
    ( timeout 60 ./topless-run > topless.txt 2>&1; exit $? ) 2> /dev/null
    code=$?; check_bound "$code" forced mutant topless.txt
    if [ "$code" -eq 76 ]; then cat topless.txt; exit 76; fi
    [ "$code" -eq 1 ] && grep -qxF "$fresh_fail" topless.txt || pair_mismatch "$code" topless.txt mutant 0 "$fresh_ok"
    printf '  exits 1 at "%s"\n' "$fresh_fail"

    step "stress: tasks begin on fresh stacks beside a collector, three runs of 5 s"
    if ! "$IYI" build fresh.iyi -o fresh > build-fresh.log 2>&1; then
      echo "SETUP: fresh tasks: the stress program did not build"; cat build-fresh.log; exit 76
    fi
    run=1
    started=""
    while [ "$run" -le 3 ]; do
      ( timeout 60 ./fresh 5 > fresh.txt 2>&1; exit $? ) 2> /dev/null
      code=$?; check_bound "$code" healthy "run $run"
      if [ "$code" -eq 76 ]; then cat fresh.txt; exit 76; fi
      if [ "$code" -ne 0 ] || ! grep -q '^ok started=[0-9]* ' fresh.txt; then
        if [ "$code" -eq 1 ] && grep -qxF "$fresh_fail" fresh.txt; then
          echo "$fresh_fail"
        else
          echo "FAIL: ${current_step}: run $run exited $code:"
          tail -3 fresh.txt | sed 's/^/  /'
        fi
        exit 1
      fi
      started="$started $(sed -n 's/^ok started=\([0-9]*\) .*/\1/p' fresh.txt)"
      run=$((run + 1))
    done
    echo "  three runs, every task's top its own stack's:$started tasks"
    ;;
esac

# ── 7f (forced). A stop with sp at a fresh fiber's top, control and topless ─
# A fiber made by hand is prepared and registered, never queued, and its top is
# published. The child sets sp to that top in asm, publishes HELD and spins on
# OPEN without touching its stack. The parent's one collection stops the child
# there, and the copy-only hook in `each_stopped_root` checks that the top the
# stop found is the armed one before anything is scanned. The topless copy reads
# the top as no fiber's (`address < top`), so the bound is another mapping's top
# or 0: the hook names that and exits before the scan. Hooks exist only in awk
# copies under $WORK. A setup, watchdog or broken witness exits 76.
case "$(uname -s)" in
  Linux | Darwin)
    stoptop_ok="stoptop: a stop at a fiber's top bounded its scan by that fiber's top"
    stoptop_fail="FAIL: stoptop: a stop at a fiber's top was not bounded by that fiber's top"

    # Module level, before `class IyiThread`: the switch the child calls. The
    # caller's rbx (x19 on aarch64) goes on its own stack, sp moves to the armed
    # top, HELD is stored, and the spin on OPEN never pushes, pops or calls.
    cat > stoptop-asm.part <<'IYI'
  {% if flag?(:x86_64) %}
    @[NoInline]
    @[Naked]
    fun __iyi_stoptop_switch(top : UInt64, page : UInt64) : Nil
      asm("pushq %rbx
           movq %rsp, %rbx
           movq %rdi, %rsp
           movl $$1, %eax
           xchgq %rax, 3264(%rsi)
           1:
           movq 3328(%rsi), %rax
           testq %rax, %rax
           jnz 2f
           pause
           jmp 1b
           2:
           movq %rbx, %rsp
           popq %rbx
           retq" :::: "volatile")
    end
  {% else %}
    @[NoInline]
    @[Naked]
    fun __iyi_stoptop_switch(top : UInt64, page : UInt64) : Nil
      asm("str x19, [sp, #-16]!
           mov x19, sp
           mov sp, x0
           mov x2, #1
           add x3, x1, #3264
           stlr x2, [x3]
           add x3, x1, #3328
           1:
           ldar x2, [x3]
           cbnz x2, 2f
           yield
           b 1b
           2:
           mov sp, x19
           ldr x19, [sp], #16
           ret" :::: "volatile")
    end
  {% end %}
IYI

    # Copies only: the awk below puts this before the roots of a copy of
    # thread.iyi. Control-page words: LINE (the held child's line), TOP (the
    # armed fiber top), HELD (set by the child once sp is at TOP), OPEN (set by
    # the parent to let the child return), BOUND (the top the stop's scan was
    # given) and VISITS (collections that visited the armed line while held).
    cat > stoptop.part <<'IYI'
    IYI_STOPTOP_LINE   = 3136_u64
    IYI_STOPTOP_TOP    = 3200_u64
    IYI_STOPTOP_HELD   = 3264_u64
    IYI_STOPTOP_OPEN   = 3328_u64
    IYI_STOPTOP_BOUND  = 3392_u64
    IYI_STOPTOP_VISITS = 3456_u64

    # Made by hand and registered, never queued, so it never runs: its stack is
    # prepared, and the registry the stop walks holds it with its top.
    def self.stoptop_fresh_fiber : Nil
      fiber = IyiFiber.new
      fiber.prepare_stack
      IyiScheduler.register(fiber)
      word(control + IYI_STOPTOP_TOP).value.set(fiber.stack_top)
    end

    def self.stoptop_held? : Bool
      word(control + IYI_STOPTOP_HELD).value.get != 0_u64
    end

    def self.stoptop_visits : UInt64
      word(control + IYI_STOPTOP_VISITS).value.get
    end

    def self.stoptop_open : Nil
      word(control + IYI_STOPTOP_OPEN).value.set(1_u64)
    end

    # The child's body, with no captures: publishes its line, then switches sp
    # to the armed top and holds there until OPEN.
    def self.stoptop_hold : Nil
      page = control
      word(page + IYI_STOPTOP_LINE).value.set(@@line)
      __iyi_stoptop_switch(word(page + IYI_STOPTOP_TOP).value.get, page)
    end

    # Called by `each_stopped_root` with the top the stop found for a stopped
    # thread's sp, before anything is scanned. Words and a literal only: no
    # allocation, no lock, no print, so a stop may reach it at any point.
    def self.stoptop_visit(cursor : UInt64, sp : UInt64, top : UInt64) : Nil
      page = @@control
      return if page == 0_u64 || word(page + IYI_STOPTOP_HELD).value.get == 0_u64
      return if word(page + IYI_STOPTOP_LINE).value.get != cursor
      armed = word(page + IYI_STOPTOP_TOP).value.get
      if sp != armed
        message = "SETUP: stoptop: the held child's sp was not its fiber's top\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        {% if flag?(:darwin) %}
          LibC.stoptop_exit(76_i32)
        {% else %}
          __iyi_exit(76)
        {% end %}
      end
      word(page + IYI_STOPTOP_BOUND).value.set(top)
      word(page + IYI_STOPTOP_VISITS).value.add(1_u64)
      if top != armed
        message = "FAIL: stoptop: a stop at a fiber's top was not bounded by that fiber's top\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        {% if flag?(:darwin) %}
          LibC.stoptop_exit(1_i32)
        {% else %}
          __iyi_exit(1)
        {% end %}
      end
    end
IYI

    # The awk that puts the part, the asm and the hook into a copy of thread.iyi.
    # Each anchor is exact and counted once; a copy that does not match exits 3.
    stoptop_copy() {
      awk -v asmfile=stoptop-asm.part -v part=stoptop.part '
        /^  class IyiThread$/ { while ((getline line < asmfile) > 0) print line; classes++ }
        /^    # ── Roots/ { while ((getline line < part) > 0) print line; roots++ }
        /^      fun thread_switch\(thread : UInt32, option : Int32, time : UInt32\) : Int32$/ {
          print
          print "      fun stoptop_exit = _exit(status : Int32) : NoReturn"
          exits++
          next
        }
        /^    def self\.each_stopped_root\(visit : Proc\(UInt64, Nil\)\) : Nil$/ { in_scan = 1; scans++ }
        in_scan && /^          top = IyiScheduler\.fiber_top_holding\(sp\)$/ {
          print
          print "          IyiThread.stoptop_visit(cursor, sp, top)"
          visits++
          next
        }
        in_scan && /^    end$/ { in_scan = 0; scan_ends++ }
        { print }
        END { if (classes != 1 || roots != 1 || exits != 1 || scans != 1 || visits != 1 || scan_ends != 1) exit 3 }
      ' "$REPO/src/iyi/thread.iyi" > "$1"
    }

    step "a stop with sp at a fresh fiber's top, control"
    cat > stoptop.iyi <<'IYI'
module stoptop

IyiMark.auto = false
IyiMark.workers = 0_u64
IyiThread.stoptop_fresh_fiber
thread = IyiThread.start { IyiThread.stoptop_hold; nil }
deadline = IyiMark.now_ns &+ 20000000000_u64
while !IyiThread.stoptop_held?
  if IyiMark.now_ns >= deadline
    print "SETUP: stoptop: the held child never reached its fiber's top\n"
    __iyi_exit(76)
  end
  IyiThread.yield_cpu
end
before = IyiThread.stoptop_visits
IyiMark.collect
if IyiThread.stoptop_visits <= before
  print "SETUP: stoptop: the collection did not visit the held line\n"
  __iyi_exit(76)
end
IyiThread.stoptop_open
thread.join
puts "stoptop: a stop at a fiber's top bounded its scan by that fiber's top"
IYI
    mkdir -p stoptop-control/iyi
    cp "$REPO"/src/iyi/*.iyi stoptop-control/iyi/
    stoptop_copy stoptop-control/iyi/thread.iyi || { echo "SETUP: ${current_step:-stoptop}: the thread anchors changed"; exit 76; }
    if ! IYI_PATH="$WORK/stoptop-control${PSEP}$REPO/src" "$IYI" build stoptop.iyi -o stoptop-control-run > stoptop-control-build.log 2>&1; then
      echo "SETUP: ${current_step:-stoptop}: the control copy did not build"; cat stoptop-control-build.log; exit 76
    fi
    ( timeout 60 ./stoptop-control-run > stoptop-control.txt 2>&1; exit $? ) 2> /dev/null
    code=$?; check_bound "$code" forced control stoptop-control.txt
    [ "$code" -eq 0 ] && tr -d '\r' < stoptop-control.txt | grep -qxF "$stoptop_ok" || pair_mismatch "$code" stoptop-control.txt control
    printf '  control: exit 0, %s\n' "$stoptop_ok"

    step "failure proof: a stop with sp at a fresh fiber's top, its scan bounded by the mapping above"
    mkdir -p stoptop-topless/iyi
    cp "$REPO"/src/iyi/*.iyi stoptop-topless/iyi/
    stoptop_copy stoptop-topless/iyi/thread.iyi || { echo "SETUP: ${current_step:-stoptop}: the thread anchors changed"; exit 76; }
    awk '/^      return top if top != 0 && address <= top && address > top - IyiFiber::STACK_BYTES$/ {
        print "      return top if top != 0 && address < top && address >= top - IyiFiber::STACK_BYTES"; found++; next }
      { print } END { if (found != 1) exit 3 }' "$REPO/src/iyi/concurrency.iyi" > stoptop-topless/iyi/concurrency.iyi || { echo "SETUP: ${current_step:-stoptop}: the fiber stack bound anchor changed"; exit 76; }
    cmp -s stoptop-topless/iyi/concurrency.iyi "$REPO/src/iyi/concurrency.iyi" && { echo "SETUP: ${current_step:-stoptop}: the topless copy was unchanged"; exit 76; }
    if ! IYI_PATH="$WORK/stoptop-topless${PSEP}$REPO/src" "$IYI" build stoptop.iyi -o stoptop-topless-run > stoptop-topless-build.log 2>&1; then
      echo "SETUP: ${current_step:-stoptop}: the topless copy did not build"; cat stoptop-topless-build.log; exit 76
    fi
    ( timeout 60 ./stoptop-topless-run > stoptop-topless.txt 2>&1; exit $? ) 2> /dev/null
    code=$?; check_bound "$code" forced mutant stoptop-topless.txt
    [ "$code" -eq 1 ] && tr -d '\r' < stoptop-topless.txt | grep -qxF "$stoptop_fail" || pair_mismatch "$code" stoptop-topless.txt mutant 0 "$stoptop_ok"
    printf '  exits 1 at "%s"\n' "$stoptop_fail"
    ;;
esac

# ── 7g. A fault the stack guard does not own kills the process ───────────
# The guard's handler (`IyiStackGuard.faulted`) gives a fault away from a
# stack's edge back to the signal's default action, which was built in a heap
# block. A mark helper has no allocator cache, so its first touch of a heap
# page takes the runtime lock, and a helper that faulted holding the lock
# waited on it for good: on macOS 26.6, an M2 Pro with 10 cores, a soak run of
# bench/concurrency_exercise.iyi hung so. The action is in the handler's frame
# now. Two copies carry the same witnesses and differ only in where the action
# lives. The control witnesses its handler's store and reads its default action
# back as SIG_DFL, and the process dies of SIGSEGV (139). The heaped mutant
# builds the action in a heap block; its first touch, inside that window and
# holding the lock, names the failure and exits 1 before the lock is taken. A
# setup, query or watchdog failure exits 76 by name. No timing decides a verdict.
case "$(uname -s)" in
  Linux | Darwin)
    wild_handler_line="wild: the fault handler classified the armed helper's store outside any stack edge"
    wild_install_line="wild: the default action was installed and read back as SIG_DFL"
    wild_fail_line="FAIL: heaped: the default action was allocated while its helper held the runtime lock"

    # The witness: a copy-only part of thread.iyi, and hooks in concurrency.iyi
    # and prelude.iyi. Every awk anchor is unique or scoped, counted exactly
    # once and checked; a copy that does not match is a setup failure, status
    # 76.
    cat > wild.part <<'IYI'
    # ── The fault witness (bench/thread_exercise.sh, step 7g) ───────────────
    # Copies only: the awk in that step puts this into a copy of thread.iyi
    # before its roots. The state is one page the main thread maps before the
    # helper starts. The helper arms it with atomic stores while it owns the
    # runtime lock. The fault handler witnesses the armed helper's store and
    # opens the window in which it builds its default action; a first touch of
    # a heap page inside that window names the failure before the lock. Nothing
    # here allocates or takes a lock, and each failure is a named sentence and
    # an exit.
    IYI_WILD_TARGET   = 0_u64
    IYI_WILD_ARMED    = 64_u64
    IYI_WILD_BUILDING = 128_u64
    @@wild_state : UInt64 = 0_u64

    def self.wild_map(state : UInt64) : Nil
      @@wild_state = state
    end

    def self.wild_word(offset : UInt64) : Pointer(Atomic(UInt64))
      Pointer(Atomic(UInt64)).new(@@wild_state + offset)
    end

    def self.wild_armed? : Bool
      wild_word(IYI_WILD_ARMED).value.get != 0_u64
    end

    # The thread's identity: its pthread on darwin, its tid on Linux.
    def self.wild_self : UInt64
      {% if flag?(:darwin) %}
        LibC.pthread_self.address
      {% else %}
        __iyi_conc_syscall3(IYI_SYS_GETTID, 0_i64, 0_i64, 0_i64).to_u64
      {% end %}
    end

    # One write and nothing allocated: the sentences the handler writes.
    def self.wild_say(text : String) : Nil
      __iyi_write(2, text.to_unsafe.as(Void*), text.bytesize.to_u64)
    end

    # A named sentence, then the exit. Darwin's `_exit`: libSystem's `exit`
    # runs its handlers and flushes its streams, which a signal handler may not
    # do.
    def self.wild_fail(text : String, status : Int32) : NoReturn
      wild_say(text)
      {% if flag?(:darwin) %}
        LibC._exit(status)
      {% else %}
        __iyi_exit(status)
      {% end %}
    end

    # The helper, while it owns the runtime lock: where it will store, then its
    # identity. A fault is the armed helper's only on this thread and on the
    # page the helper stored to.
    def self.wild_arm(address : UInt64) : Nil
      wild_fail("SETUP: wild: the state page was never mapped\n", 76) if @@wild_state == 0_u64
      wild_word(IYI_WILD_TARGET).value.set(address)
      wild_word(IYI_WILD_ARMED).value.set(wild_self)
    end

    # The fault handler calls this once it has classified the address as outside
    # the stack's edge. The armed helper's own store is witnessed here, and the
    # window for its default action opens.
    def self.wild_classified(address : UInt64) : Nil
      return if @@wild_state == 0_u64
      owner = wild_self
      return if wild_word(IYI_WILD_ARMED).value.get != owner
      return if address.unsafe_shr(12_u64) != wild_word(IYI_WILD_TARGET).value.get.unsafe_shr(12_u64)
      wild_say("wild: the fault handler classified the armed helper's store outside any stack edge\n")
      wild_word(IYI_WILD_BUILDING).value.set(owner)
    end

    # The first touch of a heap page takes the runtime lock. In the window for
    # the default action, on the armed helper, that lock is the helper's own and
    # is never released, so the failure is named here, before the lock.
    def self.wild_prelock : Nil
      return if @@wild_state == 0_u64
      owner = wild_self
      return if wild_word(IYI_WILD_BUILDING).value.get != owner
      return if wild_word(IYI_WILD_ARMED).value.get != owner
      wild_fail("FAIL: heaped: the default action was allocated while its helper held the runtime lock\n", 1) if IyiRuntimeLock.held?
    end

    # The handler's sigaction, given its answer. The install must succeed, and
    # a read-back of the disposition must find SIG_DFL; anything else is a setup
    # failure. Then the window closes and the install is witnessed.
    def self.wild_installed(signal : Int32, result : Int64) : Nil
      if result != 0_i64
        wild_fail("SETUP: wild: the default action could not be installed\n", 76)
      end
      prior = uninitialized UInt64[4]
      probe = pointerof(prior).as(Pointer(UInt64))
      probe[0] = 1_u64
      {% if flag?(:darwin) %}
        query = LibC.sigaction(signal, Pointer(Void).new(0_u64), probe.as(Void*)).to_i64
      {% else %}
        query = __iyi_conc_syscall6(IYI_SYS_RT_SIGACTION, signal.to_i64, 0_i64, probe.address.to_i64, 8_i64, 0_i64, 0_i64)
      {% end %}
      if query != 0_i64
        wild_fail("SETUP: wild: the default action could not be read back\n", 76)
      end
      if probe[0] != 0_u64
        wild_fail("SETUP: wild: the default action did not read back as SIG_DFL\n", 76)
      end
      wild_word(IYI_WILD_BUILDING).value.set(0_u64)
      wild_say("wild: the default action was installed and read back as SIG_DFL\n")
    end

IYI

    # Each copy's awk. thread.iyi gets the part before its roots; prelude.iyi's
    # first touch gets the hook before its lock, scoped to first_touch;
    # concurrency.iyi's handler gets the classification, the two sigaction
    # wraps, the _exit declaration and, in the heaped copy alone, the heap block
    # in place of the stack action. A miss in any count exits 3, and the caller
    # turns that into a setup failure.
    wild_thread_copy() {
      awk -v part=wild.part '
        /^    # ── Roots/ { while ((getline line < part) > 0) print line; roots++ }
        { print }
        END { if (roots != 1) exit 3 }
      ' "$REPO/src/iyi/thread.iyi" > "$1"
    }
    wild_prelude_copy() {
      awk '
        /^      def self\.first_touch : UInt64$/ { scope = 1; defs++ }
        scope && /^        lock$/ { print "        IyiThread.wild_prelock"; print; locks++; next }
        scope && /^      end$/ { scope = 0 }
        { print }
        END { if (defs != 1 || locks != 1) exit 3 }
      ' "$REPO/src/iyi/prelude.iyi" > "$1"
    }
    wild_concurrency_copy() {
      awk -v mode="$1" '
        /^      fun sigaction\(signal : Int32, action : Void\*, previous : Void\*\) : Int32$/ {
          print; print "      fun _exit(status : Int32) : NoReturn"; declared++; next
        }
        /^      # Not the stack.s edge: the signal.s default action, on the retry\.$/ {
          print "      IyiThread.wild_classified(address)"; print; classified++; next
        }
        mode == "heaped" && /^      action = uninitialized UInt64\[4\]$/ { heaped_action++; next }
        mode == "heaped" && /^      words = pointerof\(action\)\.as\(Pointer\(UInt64\)\)$/ {
          print "      words = Pointer(UInt64).malloc(4_u64)"; heaped_words++; next
        }
        /^        LibC\.sigaction\(signal, words\.as\(Void\*\), Pointer\(Void\)\.new\(0_u64\)\)$/ {
          print "        IyiThread.wild_installed(signal, LibC.sigaction(signal, words.as(Void*), Pointer(Void).new(0_u64)).to_i64)"; libc_installed++; next
        }
        /^        __iyi_conc_syscall6\(IYI_SG_SYS_RT_SIGACTION, signal\.to_i64, words\.address\.to_i64, 0_i64, 8_i64, 0_i64, 0_i64\)$/ {
          print "        IyiThread.wild_installed(signal, __iyi_conc_syscall6(IYI_SG_SYS_RT_SIGACTION, signal.to_i64, words.address.to_i64, 0_i64, 8_i64, 0_i64, 0_i64))"; syscall_installed++; next
        }
        { print }
        END {
          if (declared != 1 || classified != 1 || libc_installed != 1 || syscall_installed != 1) exit 3
          if (mode == "heaped" && (heaped_action != 1 || heaped_words != 1)) exit 3
        }
      ' "$REPO/src/iyi/concurrency.iyi" > "$2"
    }

    # The program: the main thread maps the state page, then starts the helper.
    # A fault ends it at once; its own exit is the 5 s watchdog's, 76.
    cat > wild.iyi <<'IYI'
@[Unsafe("a mark helper is started on a function that writes to a wild address, the fault the gate wants inside a collection")]
module wild

# A helper's life here: the runtime lock taken, the helper armed while it owns
# the lock (the arm is in the copies only, step 7g), then a store to an address
# nothing maps.
def fault_holding_the_lock(address : UInt64) : Nil
  IyiRuntimeLock.lock
  IyiThread.wild_arm(address)
  Pointer(UInt64).new(address).value = 1_u64
end

IyiThread.wild_map(__iyi_mmap(4096_u64).address)
entry = ->(address : UInt64) { fault_holding_the_lock(address) }
IyiThread.start_helper(Pointer(UInt64).new(pointerof(entry).address).value, 8_u64)
deadline = __iyi_monotonic_ns + 5_000_000_000_i64
while __iyi_monotonic_ns < deadline
end
armed = IyiThread.wild_armed?
message = armed ? "SETUP: wild: the helper's fault did not end the process within 5 s\n" : "SETUP: wild: the helper never armed\n"
__iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
__iyi_exit(76)
IYI

    step "a mark helper's fault holding the runtime lock: the control witnesses its handler and default action, and dies of SIGSEGV"
    for mode in control heaped; do
      mkdir -p "wild-$mode/iyi"
      cp "$REPO"/src/iyi/*.iyi "wild-$mode/iyi/"
      wild_thread_copy "wild-$mode/iyi/thread.iyi" || { echo "SETUP: wild: the roots anchor in thread.iyi changed"; exit 76; }
      wild_prelude_copy "wild-$mode/iyi/prelude.iyi" || { echo "SETUP: wild: the first touch's lock in prelude.iyi changed"; exit 76; }
      wild_concurrency_copy "$mode" "wild-$mode/iyi/concurrency.iyi" || { echo "SETUP: wild: a fault handler anchor in concurrency.iyi changed"; exit 76; }
      if ! IYI_PATH="$WORK/wild-$mode${PSEP}$REPO/src" "$IYI" build wild.iyi -o "wild-$mode-run" > "build-wild-$mode.log" 2>&1; then
        echo "SETUP: wild: the $mode copy did not build:"; cat "build-wild-$mode.log"; exit 76
      fi
    done
    ( timeout 60 ./wild-control-run > wild-control.txt 2>&1; exit $? ) 2> /dev/null
    code=$?; check_bound "$code" forced control wild-control.txt
    if [ "$code" -eq 76 ]; then cat wild-control.txt; exit 76; fi
    if [ "$code" -ne 139 ] || ! grep -qxF "$wild_handler_line" wild-control.txt || ! grep -qxF "$wild_install_line" wild-control.txt; then
      pair_mismatch "$code" wild-control.txt control
    fi
    printf '  control: exit 139 (SIGSEGV), with "%s" and "%s"\n' "$wild_handler_line" "$wild_install_line"

    step "failure proof: the default action built in a heap block fails at its first touch, before the lock, and exits 1"
    ( timeout 60 ./wild-heaped-run > wild-heaped.txt 2>&1; exit $? ) 2> /dev/null
    code=$?; check_bound "$code" forced mutant wild-heaped.txt
    if [ "$code" -eq 76 ]; then cat wild-heaped.txt; exit 76; fi
    if [ "$code" -ne 1 ] || ! grep -qxF "$wild_handler_line" wild-heaped.txt || ! grep -qxF "$wild_fail_line" wild-heaped.txt; then
      pair_mismatch "$code" wild-heaped.txt mutant 139 "$wild_handler_line" "$wild_install_line"
    fi
    printf '  exits 1 at "%s"\n' "$wild_fail_line"
    ;;
esac

# ── 7h. A stop sleeps on its count, and its last thread wakes it ─────────
# The stopper waited for its threads to count in, and after the release
# to count out, in a loop around `yield_cpu`; it spins a little now and
# then sleeps on the count's word (`IyiThread.wait_count`), and the thread
# that brings the count to what the stopper waits for wakes it
# (`IyiThread.count_in`). The proof publishes a waiter on a private word,
# then checks whether the final increment actually called the platform wake.
case "$(uname -s)" in
  Linux | Darwin)
    cat > final-wake.part <<'IYI'
    IYI_WAKE_TARGET = 384_u64
    IYI_WAKE_PUBLISHED = 448_u64
    IYI_WAKE_CALLED = 512_u64
    def self.final_wake_arm(address : UInt64) : Nil
      page = control
      word(page + IYI_WAKE_TARGET).value.set(address)
      word(page + IYI_WAKE_PUBLISHED).value.set(0_u64)
      word(page + IYI_WAKE_CALLED).value.set(0_u64)
    end
    def self.final_wake_published(address : UInt64) : Nil
      page = @@control
      return if page == 0_u64 || word(page + IYI_WAKE_TARGET).value.get != address
      word(page + IYI_WAKE_PUBLISHED).value.set(1_u64)
    end
    def self.final_wake_called(address : UInt64) : Nil
      page = @@control
      return if page == 0_u64 || word(page + IYI_WAKE_TARGET).value.get != address
      word(page + IYI_WAKE_CALLED).value.set(1_u64)
    end
    def self.final_wake_published? : Bool
      word(control + IYI_WAKE_PUBLISHED).value.get != 0_u64
    end
    def self.final_wake_called? : Bool
      word(control + IYI_WAKE_CALLED).value.get != 0_u64
    end
IYI
    final_wake_copy() {
      awk -v part=final-wake.part -v mode="$1" '
        /^    # ── Roots/ { while ((getline s < part) > 0) print s; roots++ }
        /^    def self\.wait_count\(address : UInt64, target : UInt64\) : Nil$/ { in_wait = 1; waits++ }
        in_wait && /^    end$/ { in_wait = 0; wait_ends++ }
        in_wait && /^        word\(control \+ IYI_TC_SLEEPER\)\.value\.set\(target\)$/ { print; print "        IyiThread.final_wake_published(address)"; published++; next }
        /^    def self\.count_in\(address : UInt64\) : Nil$/ { in_count = 1; counts++ }
        in_count && /^    end$/ { in_count = 0; count_ends++ }
        in_count && /^        return if sleeper == 0_u64 \|\| now < sleeper$/ {
          if (mode == "forced") print "        return"
          else print
          condition++; next
        }
        in_count && /^          __iyi_conc_syscall6\(IYI_SYS_FUTEX, address\.to_i64, IYI_FUTEX_WAKE, 1_i64, 0_i64, 0_i64, 0_i64\)$/ { print; print "          IyiThread.final_wake_called(address)"; linux++; next }
        in_count && /^          LibC\.os_sync_wake_by_address_all\(Pointer\(Void\)\.new\(address\), 8_u64, 0_u32\)$/ { print; print "          IyiThread.final_wake_called(address)"; darwin++; next }
        { print }
        END { if (roots != 1 || waits != 1 || wait_ends != 1 || published != 1 || counts != 1 || count_ends != 1 || condition != 1 || linux != 1 || darwin != 1) exit 3 }
      ' "$REPO/src/iyi/thread.iyi" > "$2"
    }
    cat > final-wake.iyi <<'IYI'
@[Unsafe("the proof uses a private mapped counter and copy-only wake witnesses")]
module final_wake

IyiMark.auto = false
IyiMark.workers = 0_u64
address = __iyi_mmap(4096_u64).address
Pointer(Atomic(UInt64)).new(address).value.set(0_u64)
IyiThread.final_wake_arm(address)
waiter = IyiThread.start do
  IyiThread.wait_count(address, 1_u64)
  nil
end
deadline = IyiMark.now_ns &+ 20000000000_u64
while !IyiThread.final_wake_published?
  if IyiMark.now_ns >= deadline
    print "SETUP: final wake: the waiter never published its target\n"
    __iyi_exit(76)
  end
  IyiThread.yield_cpu
end
IyiThread.count_in(address)
unless IyiThread.final_wake_called?
  print "FAIL: final wake: the last increment did not call the platform wake\n"
  __iyi_exit(1)
end
waiter.join
puts "final wake: the last increment called the platform wake"
IYI
    for mode in control forced; do
      mkdir -p "final-wake-$mode/iyi"
      cp "$REPO"/src/iyi/*.iyi "final-wake-$mode/iyi/"
      final_wake_copy "$mode" "final-wake-$mode/iyi/thread.iyi" || { echo "SETUP: final wake: copy anchors changed"; exit 76; }
      if ! IYI_PATH="$WORK/final-wake-$mode${PSEP}$REPO/src" "$IYI" build final-wake.iyi -o "final-wake-$mode-run" > "build-final-wake-$mode.log" 2>&1; then
        echo "SETUP: final wake: the $mode copy did not build"; cat "build-final-wake-$mode.log"; exit 76
      fi
      step "the last increment's platform wake, $mode"
      ( timeout 60 "./final-wake-$mode-run" > "final-wake-$mode.txt" 2>&1; exit $? ) 2> /dev/null
      code=$?; check_bound "$code" forced "$mode" "final-wake-$mode.txt"
      if [ "$code" -eq 76 ]; then cat "final-wake-$mode.txt"; exit 76; fi
      if [ "$mode" = control ]; then
        [ "$code" -eq 0 ] && grep -qxF 'final wake: the last increment called the platform wake' "final-wake-$mode.txt" || pair_mismatch "$code" "final-wake-$mode.txt" control
        echo '  control: exit 0, final wake: the last increment called the platform wake'
      else
        [ "$code" -eq 1 ] && grep -qxF 'FAIL: final wake: the last increment did not call the platform wake' "final-wake-$mode.txt" || pair_mismatch "$code" "final-wake-$mode.txt" mutant 0 'final wake: the last increment called the platform wake'
        echo '  exits 1 at "FAIL: final wake: the last increment did not call the platform wake"'
      fi
    done

    # Hold one real runtime-lock spinner through a stop and count-out, then
    # hold its next pay_turn until await_turns reaches its nonzero branch.
    # Both copies carry the same hooks; only that branch's return changes.
    if [ "$(uname -s)" = Linux ]; then
      cat > turn.part <<'IYI' || { echo "SETUP: unowed: could not write the hooks"; exit 76; }
    # Copy-only words. The runtime's suspended, resumed, and turns words
    # are observed but never written by this proof.
    IYI_TURN_LINE = 1088_u64
    IYI_TURN_SPIN = 1096_u64
    IYI_TURN_STAGE = 1104_u64
    IYI_TURN_PAY_HOLD = 1112_u64
    IYI_TURN_AWAITED = 1120_u64
    IYI_TURN_PAID = 1128_u64
    IYI_TURN_CHECKED = 1136_u64
    IYI_TURN_LIMIT = 20000000000_u64

    def self.turn_setup(message : String) : Nil
      __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
      __iyi_exit(76)
    end

    def self.turn_arm(line : UInt64) : Nil
      page = control
      turn_setup("SETUP: unowed: the worker has no line\n") if line == 0_u64
      word(page + IYI_TURN_SPIN).value.set(0_u64)
      word(page + IYI_TURN_STAGE).value.set(0_u64)
      word(page + IYI_TURN_PAY_HOLD).value.set(0_u64)
      word(page + IYI_TURN_AWAITED).value.set(0_u64)
      word(page + IYI_TURN_PAID).value.set(0_u64)
      word(page + IYI_TURN_CHECKED).value.set(0_u64)
      word(page + IYI_TURN_LINE).value.set(line)
    end

    # Called just after the real first spin wrote LOCKWAIT=1. A stop
    # interrupts this hold and parks the worker with that word still set.
    def self.turn_spinning(line : UInt64) : Nil
      page = @@control
      return if page == 0_u64 || line == 0_u64 || word(page + IYI_TURN_LINE).value.get != line
      if IyiRuntimeLock.word.value.get & 1_u64 == 0_u64
        turn_setup("SETUP: unowed: the spinner did not find the runtime lock held\n")
      end
      word(page + IYI_TURN_SPIN).value.set(1_u64)
      began = IyiMark.now_ns
      while word(page + IYI_TURN_STAGE).value.get == 0_u64
        if IyiMark.now_ns &- began > IYI_TURN_LIMIT
          turn_setup("SETUP: unowed: the spinner was not released after count-out\n")
        end
        yield_cpu
      end
    end

    # This runs at the real next pay_turn, before its swap. It cannot
    # manufacture a debt: the park must already have written 3 and added
    # exactly one to the runtime's turns word.
    def self.turn_pay_hold(line : UInt64) : Nil
      page = @@control
      return if page == 0_u64 || line == 0_u64 || word(page + IYI_TURN_LINE).value.get != line
      if word(line + IYI_TL_LOCKWAIT).value.get != 3_u64 || word(page + IYI_TC_TURNS).value.get != 1_u64
        turn_setup("SETUP: unowed: the spinner reached payment without one real debt\n")
      end
      word(page + IYI_TURN_PAY_HOLD).value.set(1_u64)
      began = IyiMark.now_ns
      while word(page + IYI_TURN_STAGE).value.get != 2_u64
        if IyiMark.now_ns &- began > IYI_TURN_LIMIT
          turn_setup("SETUP: unowed: the payment hold was never opened\n")
        end
        yield_cpu
      end
    end

    # The witness follows pay_turn's actual subtraction, not the hold.
    def self.turn_paid(line : UInt64) : Nil
      page = @@control
      return if page == 0_u64 || line == 0_u64 || word(page + IYI_TURN_LINE).value.get != line
      if word(page + IYI_TURN_PAY_HOLD).value.get != 1_u64 || word(page + IYI_TURN_STAGE).value.get != 2_u64 || word(page + IYI_TC_TURNS).value.get != 0_u64
        turn_setup("SETUP: unowed: the real payment did not clear its debt\n")
      end
      word(page + IYI_TURN_PAID).value.set(1_u64)
    end

    # Reached only after await_turns has observed a nonzero turns word,
    # before the production deadline is calculated.
    def self.turn_awaited(page : UInt64) : Nil
      return if word(page + IYI_TURN_LINE).value.get == 0_u64
      if word(page + IYI_TURN_PAY_HOLD).value.get != 1_u64 || word(page + IYI_TURN_STAGE).value.get != 1_u64 || word(page + IYI_TC_TURNS).value.get != 1_u64
        turn_setup("SETUP: unowed: the wait did not find the held debt\n")
      end
      word(page + IYI_TURN_AWAITED).value.set(1_u64)
      word(page + IYI_TURN_STAGE).value.set(2_u64)
      began = IyiMark.now_ns
      while word(page + IYI_TURN_PAID).value.get == 0_u64
        if IyiMark.now_ns &- began > IYI_TURN_LIMIT
          turn_setup("SETUP: unowed: the spinner did not pay its turn\n")
        end
        yield_cpu
      end
    end

    # The collection calls this immediately before its first real lock
    # attempt, so the mutant is named before it can begin a second stop.
    def self.turn_lock_check : Nil
      page = @@control
      return if page == 0_u64
      line = word(page + IYI_TURN_LINE).value.get
      return if line == 0_u64
      if word(page + IYI_TURN_SPIN).value.get != 1_u64 || word(page + IYI_TURN_PAY_HOLD).value.get != 1_u64 || word(page + IYI_TC_RESUMED).value.get != 1_u64
        turn_setup("SETUP: unowed: the collector missed the held count-out\n")
      end
      if word(page + IYI_TURN_AWAITED).value.get == 0_u64
        if word(page + IYI_TURN_STAGE).value.get != 1_u64 || word(page + IYI_TURN_PAID).value.get != 0_u64 || word(line + IYI_TL_LOCKWAIT).value.get != 3_u64 || word(page + IYI_TC_TURNS).value.get != 1_u64
          turn_setup("SETUP: unowed: the collector did not find the unpaid turn\n")
        end
        message = "FAIL: unowed: the collector attempted the runtime lock before waiting for an owed turn\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        __iyi_exit(1)
      end
      if word(page + IYI_TURN_STAGE).value.get != 2_u64 || word(page + IYI_TURN_PAID).value.get != 1_u64 || word(page + IYI_TC_TURNS).value.get != 0_u64
        turn_setup("SETUP: unowed: the collector did not observe the paid turn\n")
      end
      word(page + IYI_TURN_CHECKED).value.set(1_u64)
      # A later stop may legitimately create another debt; this proof is
      # complete and must not hold that separate payment.
      word(page + IYI_TURN_LINE).value.set(0_u64)
    end

    def self.turn_spinning? : Bool
      word(control + IYI_TURN_SPIN).value.get == 1_u64
    end
    def self.turn_owed? : Bool
      page = control
      line = word(page + IYI_TURN_LINE).value.get
      line != 0_u64 && word(page + IYI_TC_SUSPENDED).value.get == 1_u64 && word(line + IYI_TL_LOCKWAIT).value.get == 3_u64 && word(page + IYI_TC_TURNS).value.get == 1_u64
    end
    def self.turn_resumed : UInt64
      word(control + IYI_TC_RESUMED).value.get
    end
    def self.turn_release_spin : Nil
      word(control + IYI_TURN_STAGE).value.set(1_u64)
    end
    def self.turn_payment_held? : Bool
      word(control + IYI_TURN_PAY_HOLD).value.get == 1_u64
    end
    def self.turn_checked? : Bool
      word(control + IYI_TURN_CHECKED).value.get == 1_u64
    end
IYI
      turn_thread_copy() {
        awk -v part="$WORK/turn.part" -v mode="$1" '
          /^    # ── Roots/ {
            roots++
            while ((result = getline s < part) > 0) { print s; part_lines++ }
            if (result < 0) part_error++
            close(part)
          }
          /^    def self\.pay_turn\(line : UInt64, waiting : UInt64\) : Nil$/ { in_pay = 1; pay_defs++ }
          in_pay && /^    end$/ { in_pay = 0; pay_ends++ }
          in_pay && /^      if word\(line \+ IYI_TL_LOCKWAIT\)\.value\.swap\(waiting\) == 3_u64$/ {
            print "      turn_pay_hold(line)"; print; pay_hold++; next
          }
          in_pay && /^        word\(control \+ IYI_TC_TURNS\)\.value\.sub\(1_u64\)$/ {
            print; print "        turn_paid(line)"; paid++; next
          }
          /^    def self\.await_turns : Nil$/ { in_await = 1; await_defs++ }
          in_await && /^    end$/ { in_await = 0; await_ends++ }
          in_await && /^      return if turns\.value\.get == 0_u64$/ {
            if (mode == "forced") print "      return"
            else print
            return_anchor++; next
          }
          in_await && /^      ends = IyiMark\.now_ns \+ TURN_WAIT_NS$/ {
            print "      turn_awaited(page)"; print; awaited++; next
          }
          /^    def self\.lock_turn\(word : Pointer\(Atomic\(UInt64\)\), seen : UInt64, spins : Int64, since : UInt64\) : Tuple\(Int64, UInt64\)$/ { in_lock = 1; lock_defs++ }
          in_lock && /^    end$/ { in_lock = 0; lock_ends++ }
          in_lock && /^        IyiHeap\.write64\(line \+ IYI_TL_LOCKWAIT, 1_u64\) if line != 0$/ {
            print; print "        turn_spinning(line)"; spinning++; next
          }
          { print }
          END {
            if (roots != 1 || part_lines == 0 || part_error != 0 ||
                pay_defs != 1 || pay_ends != 1 || pay_hold != 1 || paid != 1 ||
                await_defs != 1 || await_ends != 1 || return_anchor != 1 || awaited != 1 ||
                lock_defs != 1 || lock_ends != 1 || spinning != 1) exit 3
          }
        ' "$REPO/src/iyi/thread.iyi" > "$2"
      }
      turn_prelude_copy() {
        awk '
          /^      def self\.collect_cleared : Nil$/ { in_collect = 1; definitions++ }
          in_collect && /^      end$/ { in_collect = 0; ends++ }
          in_collect && /^ *IyiRuntimeLock\.lock$/ {
            if ($0 == "        IyiRuntimeLock.lock") { first++; print "        IyiThread.turn_lock_check" }
            else if ($0 == "          IyiRuntimeLock.lock") second++
            else extra++
          }
          { print }
          END { if (definitions != 1 || ends != 1 || first != 1 || second != 1 || extra != 0) exit 3 }
        ' "$REPO/src/iyi/prelude.iyi" > "$1"
      }
      cat > unowed.iyi <<'IYI' || { echo "SETUP: unowed: could not write the witness program"; exit 76; }
@[Unsafe("copy-only atomic witnesses coordinate a real runtime-lock spinner")]
module unowed

class TurnGate
  getter ready : Atomic(Int64)
  getter go : Atomic(Int64)
  getter finish : Atomic(Int64)

  def initialize
    @ready = Atomic(Int64).new(0_i64)
    @go = Atomic(Int64).new(0_i64)
    @finish = Atomic(Int64).new(0_i64)
  end
end

IyiMark.auto = false
IyiMark.workers = 0_u64
gate = TurnGate.new
worker = IyiThread.start do
  gate.ready.set(1_i64)
  began = IyiMark.now_ns
  while gate.go.get == 0_i64
    if IyiMark.now_ns &- began > 20000000000_u64
      IyiThread.turn_setup("SETUP: unowed: the worker was not started\n")
    end
    IyiThread.yield_cpu
  end
  IyiRuntimeLock.lock
  IyiRuntimeLock.unlock
  began = IyiMark.now_ns
  while gate.finish.get == 0_i64
    if IyiMark.now_ns &- began > 20000000000_u64
      IyiThread.turn_setup("SETUP: unowed: the worker was not released after collection\n")
    end
    IyiThread.yield_cpu
  end
  nil
end
began = IyiMark.now_ns
while gate.ready.get == 0_i64
  if IyiMark.now_ns &- began > 20000000000_u64
    IyiThread.turn_setup("SETUP: unowed: the worker never entered its body\n")
  end
  IyiThread.yield_cpu
end
IyiRuntimeLock.lock
IyiThread.turn_arm(worker.line)
gate.go.set(1_i64)
began = IyiMark.now_ns
while !IyiThread.turn_spinning?
  if IyiMark.now_ns &- began > 20000000000_u64
    IyiThread.turn_setup("SETUP: unowed: the worker never spun on the runtime lock\n")
  end
  IyiThread.yield_cpu
end
others = IyiThread.stop_others
if others != 1_i64
  IyiThread.turn_setup("SETUP: unowed: the stop did not park exactly one worker\n")
end
unless IyiThread.turn_owed?
  IyiThread.turn_setup("SETUP: unowed: the parked spinner did not owe exactly one turn\n")
end
IyiThread.resume_others(others)
began = IyiMark.now_ns
while IyiThread.turn_resumed == 0_u64
  if IyiMark.now_ns &- began > 20000000000_u64
    IyiThread.turn_setup("SETUP: unowed: the parked spinner never counted out\n")
  end
  IyiThread.yield_cpu
end
if IyiThread.turn_resumed != 1_u64 || !IyiThread.turn_owed?
  IyiThread.turn_setup("SETUP: unowed: count-out did not preserve exactly one debt\n")
end
IyiThread.turn_release_spin
IyiRuntimeLock.unlock
began = IyiMark.now_ns
while !IyiThread.turn_payment_held?
  if IyiMark.now_ns &- began > 20000000000_u64
    IyiThread.turn_setup("SETUP: unowed: the spinner never reached its next payment\n")
  end
  IyiThread.yield_cpu
end
IyiMark.collect
unless IyiThread.turn_checked?
  IyiThread.turn_setup("SETUP: unowed: the collector never reached its lock attempt\n")
end
gate.finish.set(1_i64)
worker.join
puts "unowed: the collector waited for the parked spinner to pay its turn"
IYI
      for mode in control forced; do
        mkdir -p "unowed-$mode/iyi" || { echo "SETUP: unowed: could not make the $mode copy"; exit 76; }
        cp "$REPO"/src/iyi/*.iyi "unowed-$mode/iyi/" || { echo "SETUP: unowed: could not populate the $mode copy"; exit 76; }
        turn_thread_copy "$mode" "unowed-$mode/iyi/thread.iyi" || { echo "SETUP: unowed: thread copy anchors changed"; exit 76; }
        turn_prelude_copy "unowed-$mode/iyi/prelude.iyi" || { echo "SETUP: unowed: collector copy anchors changed"; exit 76; }
        if ! IYI_PATH="$WORK/unowed-$mode${PSEP}$REPO/src" "$IYI" build unowed.iyi -o "unowed-$mode-run" > "build-unowed-$mode.log" 2>&1; then
          echo "SETUP: unowed: the $mode copy did not build"; cat "build-unowed-$mode.log"; exit 76
        fi
        step "owed turns: real parked spinner and collector lock, $mode"
        ( timeout 60 "./unowed-$mode-run" > "unowed-$mode.txt" 2>&1; exit $? ) 2> /dev/null
        code=$?; check_bound "$code" forced "$mode" "unowed-$mode.txt"
        case "$code" in
          76)
            if ! grep -q '^SETUP:' "unowed-$mode.txt"; then echo "SETUP: unowed: the $mode run exited 76 without a stage"; fi
            cat "unowed-$mode.txt"; exit 76 ;;
        esac
        if grep -q '^SETUP:' "unowed-$mode.txt"; then cat "unowed-$mode.txt"; exit 76; fi
        if [ "$mode" = control ]; then
          if [ "$code" -eq 1 ] && [ "$(grep -c '^FAIL:' "unowed-$mode.txt")" -eq 1 ] && grep -qxF 'FAIL: unowed: the collector attempted the runtime lock before waiting for an owed turn' "unowed-$mode.txt"; then
            cat "unowed-$mode.txt"; exit 1
          fi
          if [ "$code" -ne 0 ] || [ "$(grep -c '^FAIL:' "unowed-$mode.txt")" -ne 0 ] || [ "$(grep -cFx 'unowed: the collector waited for the parked spinner to pay its turn' "unowed-$mode.txt")" -ne 1 ]; then
            pair_mismatch "$code" "unowed-$mode.txt" control
          fi
          echo '  control: unowed: the collector waited for the parked spinner to pay its turn'
        else
          if [ "$code" -ne 1 ] || [ "$(grep -c '^FAIL:' "unowed-$mode.txt")" -ne 1 ] || [ "$(grep -cFx 'FAIL: unowed: the collector attempted the runtime lock before waiting for an owed turn' "unowed-$mode.txt")" -ne 1 ]; then
            pair_mismatch "$code" "unowed-$mode.txt" mutant 0 'unowed: the collector waited for the parked spinner to pay its turn'
          fi
          echo '  exits 1 at "FAIL: unowed: the collector attempted the runtime lock before waiting for an owed turn"'
        fi
      done
    fi
    ;;
esac

# ── 7i. darwin: witness the actual yield call ────────────────────────────
# Both copies route the call through the same observer, which increments its
# counter only after thread_switch returns. The mutant replaces only the
# observer call with the former ARM hint. One direct yield is bracketed by
# counter reads on the initial thread, with no worker threads or retries.
case "$(uname -s)" in
  Darwin)
    yield_pass='yield: the real thread_switch call returned'
    yield_fail='FAIL: yield: yield_cpu returned without calling thread_switch'
    cat > yield_observer.part <<'IYI'
    @@yield_observed : UInt64 = 0_u64

    def self.yield_observed : UInt64
      @@yield_observed
    end

    def self.yield_observe_switch : Nil
      LibC.thread_switch(0_u32, IYI_SWITCH_OPTION_DEPRESS, 1_u32)
      @@yield_observed = @@yield_observed + 1_u64
    end

IYI
    cat > yield_witness.iyi <<'IYI'
module yield_witness

before = IyiThread.yield_observed
IyiThread.yield_cpu
after = IyiThread.yield_observed
if after == before
  print "FAIL: yield: yield_cpu returned without calling thread_switch\n"
  __iyi_exit(1)
elsif after == before + 1_u64
  puts "yield: the real thread_switch call returned"
else
  print "SETUP: yield: the observer count changed by more than one\n"
  __iyi_exit(76)
end
IYI
    mkdir -p yield-control/iyi || { echo 'SETUP: yield: could not make the control copy'; exit 76; }
    cp "$REPO"/src/iyi/*.iyi yield-control/iyi/ || { echo 'SETUP: yield: could not populate the control copy'; exit 76; }
    # The call must be inside the unique yield_cpu definition. The next
    # method definition ends that scope; matching a call elsewhere is not proof.
    awk '
      $0 == "    def self.yield_cpu : Nil" {
        defs++; inside = 1
        while ((getline line < "yield_observer.part") > 0) { print line; parts++ }
        close("yield_observer.part")
        print; next
      }
      inside && /^    def self\./ { inside = 0 }
      $0 == "        LibC.thread_switch(0_u32, IYI_SWITCH_OPTION_DEPRESS, 1_u32)" {
        calls++
        if (!inside) bad = 1
        print "        yield_observe_switch"; replaced++; next
      }
      { print }
      END { if (defs != 1 || calls != 1 || replaced != 1 || parts == 0 || bad) exit 3 }
    ' "$REPO/src/iyi/thread.iyi" > yield-control/iyi/thread.iyi || { echo 'SETUP: yield: the yield_cpu call anchors changed'; exit 76; }

    step 'darwin: the real yield call returns through its observer, control'
    if ! IYI_PATH="$WORK/yield-control${PSEP}$REPO/src" "$IYI" build yield_witness.iyi -o yield-control-run > build-yield-control.log 2>&1; then
      echo 'SETUP: yield: the control copy did not build'; cat build-yield-control.log; exit 76
    fi
    printf '%s\n' "$yield_pass" > yield-pass.expected || { echo 'SETUP: yield: could not write the expected control output'; exit 76; }
    printf '%s\n' "$yield_fail" > yield-fail.expected || { echo 'SETUP: yield: could not write the expected mutant output'; exit 76; }
    ( timeout 120 ./yield-control-run > yield-control.txt 2>&1; exit $? ) 2>/dev/null
    code=$?; check_bound "$code" forced control yield-control.txt
    if [ "$code" -ne 0 ] || ! cmp -s yield-pass.expected yield-control.txt; then
      pair_mismatch "$code" yield-control.txt control
    fi
    echo "  control: $yield_pass"

    mkdir -p yield-mutant/iyi || { echo 'SETUP: yield: could not make the mutant copy'; exit 76; }
    cp yield-control/iyi/*.iyi yield-mutant/iyi/ || { echo 'SETUP: yield: could not populate the mutant copy'; exit 76; }
    awk '
      $0 == "    def self.yield_cpu : Nil" { defs++; inside = 1; print; next }
      inside && /^    def self\./ { inside = 0 }
      $0 == "        yield_observe_switch" {
        calls++; if (!inside) bad = 1
        print "        asm(\"yield\" :::: \"volatile\")"; next
      }
      { print }
      END { if (defs != 1 || calls != 1 || bad) exit 3 }
    ' yield-control/iyi/thread.iyi > yield-mutant/iyi/thread.iyi || { echo 'SETUP: yield: the observer-call anchor changed'; exit 76; }
    # Reverse the one intended substitution and compare all bytes, including
    # the identical observer and every other hook, to the control copy.
    awk '
      $0 == "    def self.yield_cpu : Nil" { inside = 1; print; next }
      inside && /^    def self\./ { inside = 0 }
      inside && $0 == "        asm(\"yield\" :::: \"volatile\")" {
        print "        yield_observe_switch"; restored++; next
      }
      { print }
      END { if (restored != 1) exit 3 }
    ' yield-mutant/iyi/thread.iyi > yield-restored.iyi || { echo 'SETUP: yield: the mutant restoration anchor changed'; exit 76; }
    cmp -s yield-control/iyi/thread.iyi yield-restored.iyi || { echo 'SETUP: yield: control and mutant differ beyond the observer call'; exit 76; }

    step 'darwin: the former ARM hint bypasses the observer, mutant'
    if ! IYI_PATH="$WORK/yield-mutant${PSEP}$REPO/src" "$IYI" build yield_witness.iyi -o yield-mutant-run > build-yield-mutant.log 2>&1; then
      echo 'SETUP: yield: the mutant copy did not build'; cat build-yield-mutant.log; exit 76
    fi
    if ! nm -u yield-control-run > yield-control-symbols.txt 2>&1 ||
       ! nm -u yield-mutant-run > yield-mutant-symbols.txt 2>&1; then
      echo 'SETUP: yield: the import tables could not be read'
      exit 76
    fi
    if ! grep -Eq '(^|[[:space:]])_thread_switch$' yield-control-symbols.txt; then
      echo 'FAIL: yield: the control did not import thread_switch'
      exit 1
    fi
    if grep -Eq '(^|[[:space:]])_thread_switch$' yield-mutant-symbols.txt; then
      echo 'SETUP: yield: the mutant still imports thread_switch, so its observer witness is broken'
      exit 76
    fi
    echo '  imports: control has _thread_switch; mutant does not'
    ( timeout 120 ./yield-mutant-run > yield-mutant.txt 2>&1; exit $? ) 2>/dev/null
    code=$?; check_bound "$code" forced mutant yield-mutant.txt
    if [ "$code" -ne 1 ] || ! cmp -s yield-fail.expected yield-mutant.txt; then
      pair_mismatch "$code" yield-mutant.txt mutant 0 "$yield_pass"
    fi
    echo "  exits 1 at \"$yield_fail\""
    ;;
esac

# ── measure: darwin's threads born beside busy processes ────────────────────
# Information, not a verdict. The rate of threads born alone and beside a busy
# process per core, and the most CPU the program spent per thread born beside
# them: the figures master's spinner step judged (7i), kept as measurements.
# The storm is sixteen threads at a time beside a thread that collects in a
# loop, for 10 s or 200 rounds, best of three runs each way. A run beside the
# busy processes counts toward the rate only where they and the program held
# 90 % of the cores' time (`ps` and time(1) read it); one where something else
# held more is set aside and run again, and after ten such runs the rate is
# taken from the held runs so far.
case "$(uname -s)" in
  Darwin)
    cores="$(sysctl -n hw.ncpu)"
    # The CPU seconds the given processes (comma-separated pids) have run so far.
    cpu_of() {
      ps -o time= -p "$1" | awk '{ n = split($1, f, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + f[i]; t += s } END { printf "%.2f\n", t }'
    }
    SHARE_MIN=90
    UNASKED_TRIES=10
    rates() {
      alone=0; beside=0; anyheld=0; shares=""; aside=""; unasked=0; spent=0
      for way in alone beside; do
        run=1
        while [ "$run" -le 3 ]; do
          busy=""
          if [ "$way" = beside ]; then
            i=0
            while [ "$i" -lt "$cores" ]; do yes > /dev/null & busy="$busy${busy:+,}$!"; i=$((i + 1)); done
            before="$(cpu_of "$busy")"
          fi
          ( /usr/bin/time -p -o times.txt timeout -k 5 60 "./$1" 200 10 > rates.txt 2>&1; exit $? ) 2> /dev/null
          code=$?
          if [ -n "$busy" ]; then
            after="$(cpu_of "$busy")"
            for b in $(echo "$busy" | tr , ' '); do end_process "$b"; done
            wait $(echo "$busy" | tr , ' ') 2> /dev/null
          fi
          if [ "$code" -ne 0 ] || ! grep -q '^ok born=[0-9]* ms=[0-9]* ' rates.txt; then
            echo "FAIL: rates: $1, $way, run $run exited $code:"; tail -3 rates.txt; exit 1
          fi
          born="$(sed -n 's/^ok born=\([0-9]*\) .*/\1/p' rates.txt)"
          ms="$(sed -n 's/^ok born=[0-9]* ms=\([0-9]*\) .*/\1/p' rates.txt)"
          rate=$((born * 1000 / (ms + 1)))
          if [ "$way" = beside ]; then
            us="$(awk -v n="$born" '$1 == "user" || $1 == "sys" { t += $2 } END { printf "%d\n", t * 1000000 / n }' times.txt)"
            [ "$us" -gt "$spent" ] && spent=$us
            [ "$rate" -gt "$anyheld" ] && anyheld=$rate
            share="$(awk -v b="$before" -v a="$after" -v c="$cores" '$1 == "real" { r = $2 } $1 == "user" || $1 == "sys" { t += $2 } END { printf "%d\n", (r > 0 ? 100 * (a - b + t) / (c * r) : 0) }' times.txt)"
            if [ "$share" -lt "$SHARE_MIN" ]; then
              unasked=$((unasked + 1))
              aside="$aside $share%"
              [ "$unasked" -ge "$UNASKED_TRIES" ] && run=4
              continue
            fi
            shares="$shares $share%"
          fi
          if [ "$way" = alone ]; then [ "$rate" -gt "$alone" ] && alone=$rate; else [ "$rate" -gt "$beside" ] && beside=$rate; fi
          run=$((run + 1))
        done
      done
    }
    if [ "$cores" -lt 6 ]; then
      echo "measure: threads born beside busy processes: needs 6 cores, this machine has $cores: unmeasured here"
    else
      cat > asleep.iyi <<'IYI'
module asleep

import std/gc::{GC}

class Flag
  getter stop : Atomic(Int64)
  getter born : Atomic(Int64)

  def initialize
    @stop = Atomic(Int64).new(0_i64)
    @born = Atomic(Int64).new(0_i64)
  end
end

def storm(flag : Flag) : Nil
  while flag.stop.get == 0_i64
    GC.collect
  end
end

def arrive(flag : Flag) : Nil
  flag.born.add(1_i64)
end

flag = Flag.new
stormer = IyiThread.start { storm(flag) }
rounds = Program.args[0].to_i
deadline = __iyi_monotonic_ns + Program.args[1].to_i.to_i64 * 1_000_000_000_i64
started_ns = __iyi_monotonic_ns
started = 0
round = 0
while round < rounds && (round < 20 || __iyi_monotonic_ns < deadline)
  batch = [] of IyiThread
  16.times { batch << IyiThread.start { arrive(flag) } }
  started = started + 16
  batch.each(&.join)
  round = round + 1
end
took = (__iyi_monotonic_ns - started_ns) // 1_000_000_i64
flag.stop.set(1_i64)
stormer.join
raise "born #{flag.born.get} of #{started}" if flag.born.get != started
puts "ok born=#{started} ms=#{took} stops=#{IyiThread.stops} owing=#{IyiThread.owing_stops} outwaited=#{IyiThread.turn_waits_out}"
IYI
      if ! "$IYI" build asleep.iyi -o asleep > build-asleep.log 2>&1; then
        echo "SETUP: rates: the storm program did not build"; cat build-asleep.log; exit 76
      fi
      rates asleep
      echo "measure: threads born alone $alone a second; beside $cores busy processes $anyheld a second, at up to $spent us of CPU a thread (they and the program held${shares:- none} of the cores${aside:+; set aside at$aside})"
    fi
    ;;
esac

# ── 7j. darwin: a stop counts only the lines it can name ─────────────────
# Hold one child after TLS is established but before it links its line.
# The same copy-only observer checks the actual count and roster at entry
# to stop_others. The mutant counts in start before the held line is linked.
case "$(uname -s)" in
  Darwin)
    cat > count-roster.part <<'IYI'
    IYI_ROSTER_ARM = 384_u64
    IYI_ROSTER_HELD = 448_u64
    IYI_ROSTER_OPEN = 512_u64
    IYI_ROSTER_CHECKED = 576_u64

    def self.roster_arm : Nil
      word(control + IYI_ROSTER_ARM).value.set(1_u64)
    end
    def self.roster_held? : Bool
      word(control + IYI_ROSTER_HELD).value.get != 0_u64
    end
    def self.roster_checked? : Bool
      word(control + IYI_ROSTER_CHECKED).value.get != 0_u64
    end
    def self.roster_open : Nil
      word(control + IYI_ROSTER_OPEN).value.set(1_u64)
    end
    def self.roster_pre_link : Nil
      page = @@control
      return if page == 0_u64 || !word(page + IYI_ROSTER_ARM).value.compare_and_set(1_u64, 0_u64)[1]
      word(page + IYI_ROSTER_HELD).value.set(1_u64)
      started = IyiMark.now_ns
      while word(page + IYI_ROSTER_OPEN).value.get == 0_u64
        if IyiMark.now_ns &- started > 20000000000_u64
          message = "SETUP: roster: the held child was never opened\n"
          __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
          LibC.roster_exit(76_i32)
        end
        yield_cpu
      end
    end
    def self.roster_check(line : UInt64) : Nil
      page = @@control
      return if page == 0_u64 || word(page + IYI_ROSTER_HELD).value.get == 0_u64 || word(page + IYI_ROSTER_OPEN).value.get != 0_u64
      roster = 0_i64
      cursor = @@lines
      while cursor != 0_u64
        roster += 1_i64
        cursor = IyiHeap.read64(cursor + IYI_TL_NEXT)
      end
      if @@count != roster
        message = "FAIL: roster: a thread was counted before its line was linked\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        LibC.roster_exit(1_i32)
      end
      if roster != 1_i64 || line == 0_u64
        message = "SETUP: roster: the held-child stop did not have one collector line\n"
        __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        LibC.roster_exit(76_i32)
      end
      word(page + IYI_ROSTER_CHECKED).value.set(1_u64)
    end
IYI
    roster_copy() {
      awk -v part=count-roster.part -v mode="$1" '
        /^      fun thread_switch\(thread : UInt32, option : Int32, time : UInt32\) : Int32$/ { print; print "      fun roster_exit = _exit(status : Int32) : NoReturn"; alias_count++; next }
        /^    # ── Roots/ { while ((getline s < part) > 0) print s; roots++ }
        /^    def self\.start\(proc : Proc\(Nil\)\) : IyiThread$/ { in_start = 1; starts++ }
        in_start && /^      \{% elsif flag\?\(:darwin\) %\}$/ { in_darwin = 1; darwin++ }
        in_start && /^      \{% elsif flag\?\(:win32\) %\}$/ { in_darwin = 0 }
        in_start && /^    end$/ { in_start = 0; in_darwin = 0; start_ends++ }
        in_darwin && /^          Pointer\(Void\)\.new\(thread_entry\), Pointer\(Void\)\.new\(line\)\)$/ {
          print
          if (mode == "forced") print "        @@count = @@count + 1_i64 if result == 0"
          created++; next
        }
        /^    def self\.run\(line : UInt64\) : Nil$/ { in_run = 1; runs++ }
        in_run && /^    end$/ { in_run = 0; run_ends++ }
        in_run && /^        link\(line\)$/ {
          print "        IyiThread.roster_pre_link"
          if (mode == "forced") {
            print "        IyiRuntimeLock.lock"
            print "        IyiHeap.write64(line + IYI_TL_NEXT, @@lines)"
            print "        @@lines = line"
            print "        IyiRuntimeLock.unlock"
          } else print
          links++; next
        }
        /^      return 0_i64 if @@count == 0_i64 \|\| \(line != 0 && @@count <= 1_i64\)$/ { print "      IyiThread.roster_check(line)"; checks++ }
        { print }
        END { if (alias_count != 1 || roots != 1 || starts != 1 || start_ends != 1 || darwin != 1 || created != 1 || runs != 1 || run_ends != 1 || links != 1 || checks != 1) exit 3 }
      ' "$REPO/src/iyi/thread.iyi" > "$2"
    }
    cat > roster.iyi <<'IYI'
@[Unsafe("the proof holds a child at a copy-only pre-link rendezvous")]
class Gate
  getter ready : Atomic(Int64)
  getter stop : Atomic(Int64)
  def initialize
    @ready = Atomic(Int64).new(0_i64)
    @stop = Atomic(Int64).new(0_i64)
  end
end

IyiMark.auto = false
IyiMark.workers = 0_u64
IyiThread.roster_arm
gate = Gate.new
thread = IyiThread.start do
  gate.ready.set(1_i64)
  while gate.stop.get == 0_i64
    IyiThread.spin_pause
  end
  nil
end
deadline = IyiMark.now_ns &+ 20000000000_u64
while !IyiThread.roster_held?
  if IyiMark.now_ns >= deadline
    print "SETUP: roster: the child never reached the pre-link gate\n"
    __iyi_exit(76)
  end
  IyiThread.yield_cpu
end
IyiMark.collect
unless IyiThread.roster_checked?
  print "SETUP: roster: the held-child stop was not observed\n"
  __iyi_exit(76)
end
IyiThread.roster_open
deadline = IyiMark.now_ns &+ 20000000000_u64
while gate.ready.get == 0_i64
  if IyiMark.now_ns >= deadline
    print "SETUP: roster: the child did not link after opening\n"
    __iyi_exit(76)
  end
  IyiThread.yield_cpu
end
before = IyiThread.stopped
IyiMark.collect
if IyiThread.stopped <= before
  print "SETUP: roster: the linked child was not stopped\n"
  __iyi_exit(76)
end
gate.stop.set(1_i64)
thread.join
puts "roster: the unlinked child was not counted, then its linked line was stopped"
IYI
    for mode in control forced; do
      mkdir -p "roster-$mode/iyi"
      cp "$REPO"/src/iyi/*.iyi "roster-$mode/iyi/"
      roster_copy "$mode" "roster-$mode/iyi/thread.iyi" || { echo "SETUP: roster: copy anchors changed"; exit 76; }
      if ! IYI_PATH="$WORK/roster-$mode${PSEP}$REPO/src" "$IYI" build roster.iyi -o "roster-$mode-run" > "build-roster-$mode.log" 2>&1; then
        echo "SETUP: roster: the $mode copy did not build"; cat "build-roster-$mode.log"; exit 76
      fi
      step "darwin: pre-link roster $mode"
      timeout 60 "./roster-$mode-run" > "roster-$mode.txt" 2>&1
      code=$?; check_bound "$code" forced "$mode" "roster-$mode.txt"
      if [ "$code" -eq 76 ]; then cat "roster-$mode.txt"; exit 76; fi
      if [ "$mode" = control ]; then
        [ "$code" -eq 0 ] && grep -qxF 'roster: the unlinked child was not counted, then its linked line was stopped' "roster-$mode.txt" || pair_mismatch "$code" "roster-$mode.txt" control
        echo '  control: exit 0, roster: the unlinked child was not counted, then its linked line was stopped'
      else
        [ "$code" -eq 1 ] && grep -qxF 'FAIL: roster: a thread was counted before its line was linked' "roster-$mode.txt" || pair_mismatch "$code" "roster-$mode.txt" mutant 0 'roster: the unlinked child was not counted, then its linked line was stopped'
        echo '  exits 1 at "FAIL: roster: a thread was counted before its line was linked"'
      fi
    done
    ;;
esac

# ── 7k. A program that calls C runs it on threads libc made ──────────────
# The pool's threads were a raw `clone` with a TLS block made from the
# executable's PT_TLS and none of libc's thread state, so C reaching for it
# ran on nothing: `pthread_self` answered 0 on a worker and `strerror`
# died of SIGSEGV (issue #158). A program whose own code calls C now gets
# `pthread_create` threads (`IyiThread.program_calls_c?`); every worker
# and a started thread answer libc's own questions through collections
# that stop them, and the binary names `pthread_create` and
# `pthread_join`, where step 2's binaries, which call no C, name neither.
# The separate held-thread pair reads the actual pthread handle before the
# child calls libc, naming a raw clone without depending on a crash.
case "$(uname -s)" in
  Linux)
    step "stress: C called from parallel tasks and a thread runs on libc's threads"
    cat > calls_c.iyi <<'IYI'
@[Unsafe("the program asks libc for its thread, errno and strings through a lib, and compares C strings byte by byte")]
@[Link("c")]
lib LibCalls
  fun pthread_self : UInt64
  fun strerror(code : Int32) : UInt8*
  fun __errno_location : Int32*
  fun close(fd : Int32) : Int32
  fun strdup(text : UInt8*) : UInt8*
  fun free(pointer : Void*) : Void
end

def same?(c : UInt8*, s : String) : Bool
  bytes = s.to_unsafe
  i = 0
  while i < s.bytesize
    return false if c[i] != bytes[i]
    i += 1
  end
  c[i] == 0_u8
end

selfless = Atomic(Int64).new(0_i64)
errno = Atomic(Int64).new(0_i64)
text = Atomic(Int64).new(0_i64)
done = Atomic(Int64).new(0_i64)
main_self = LibCalls.pthread_self

group do |g|
  16.times do
    g.spawn(unit: :new) do
      100.times do |i|
        selfless.add(1_i64) if LibCalls.pthread_self == 0_u64 || LibCalls.pthread_self == main_self
        LibCalls.close(-1)
        errno.add(1_i64) if LibCalls.__errno_location.value != 9
        text.add(1_i64) unless same?(LibCalls.strerror(2), "No such file or directory")
        line = "line #{i}"
        copy = LibCalls.strdup(line.to_unsafe)
        text.add(1_i64) unless same?(copy, line)
        LibCalls.free(copy.as(Void*))
        IyiMark.collect if i % 25 == 0
      end
      done.add(1_i64)
      nil
    end
  end
end

thread = IyiThread.start do
  selfless.add(1_i64) if LibCalls.pthread_self == 0_u64 || LibCalls.pthread_self == main_self
  nil
end
thread.join

if done.get != 16 || selfless.get != 0 || errno.get != 0 || text.get != 0
  puts "tasks #{done.get} of 16; pthread_self wrong #{selfless.get}, errno wrong #{errno.get}, strings wrong #{text.get}"
  exit 1
end
puts "every property held, #{IyiThread.stops} stops"
IYI
    if ! "$IYI" build calls_c.iyi -o calls-c > build-calls-c.log 2>&1; then
      echo "SETUP: ${current_step:-build}: calls-c did not build"; cat build-calls-c.log; exit 76
    fi
    timeout 120 ./calls-c > calls-c.txt 2>&1
    code=$?; check_bound "$code" healthy "run 1"
    if [ "$code" -eq 76 ]; then cat calls-c.txt; exit 76; fi
    if [ "$code" -ne 0 ] || ! grep -q 'every property held' calls-c.txt; then
      echo "FAIL: ${current_step}: run 1 exited $code without completing"; cat calls-c.txt; exit 1
    fi
    named=$(nm -u calls-c | sed -e 's/^ *[wU] *//' -e 's/@.*$//' | grep -cE '^(pthread_create|pthread_join)$')
    if [ "$named" -ne 2 ]; then
      echo "FAIL: ${current_step}: run 1 calls C but its threads are not libc's:"; nm -u calls-c; exit 1
    fi
    echo "  $(cat calls-c.txt)"

    step "failure proof: a C-calling program launches a held libc thread"
    cat > calls_c_witness.iyi <<'IYI'
@[Unsafe("the parent reads a held thread's line and checks its libc handle")]
@[Link("c")]
lib LibCalls
  fun pthread_self : UInt64
end

main_self = LibCalls.pthread_self
if main_self == 0_u64
  puts "SETUP: calls-c: the main thread has no pthread handle"
  __iyi_exit(76)
end
go = Atomic(Int64).new(0_i64)
observed = Atomic(UInt64).new(0_u64)
thread = IyiThread.start do
  while go.get == 0_i64
    IyiThread.spin_pause
  end
  observed.set(LibCalls.pthread_self)
  nil
end
line = thread.line
if line == 0_u64
  puts "SETUP: calls-c: the held thread has no line"
  __iyi_exit(76)
end
handle = IyiHeap.read64(line + IYI_TL_PTHREAD)
if handle == 0_u64
  puts "FAIL: calls-c: a C-calling program started a raw-clone thread"
  __iyi_exit(1)
end
go.set(1_i64)
thread.join
if observed.get != handle || observed.get == main_self
  puts "FAIL: calls-c: the worker's pthread_self did not match its recorded handle"
  __iyi_exit(1)
end
puts "calls-c: the held thread used its own pthread handle"
IYI
    mkdir -p cloned/iyi
    cp "$REPO"/src/iyi/*.iyi cloned/iyi/
    awk '/^    @\[Primitive\(:iyi_calls_c\)\]$/ { primitive++; next }
      /^    def self\.program_calls_c\? : Bool$/ { print; print "      Pointer(UInt8).new(0_u64).address != 0_u64"; method++; next }
      { print } END { if (primitive != 1 || method != 1) exit 3 }' \
      "$REPO/src/iyi/thread.iyi" > cloned/iyi/thread.iyi || { echo "SETUP: ${current_step:-calls-c}: the compiler answer anchors changed"; exit 76; }
    for mode in control mutant; do
      if [ "$mode" = control ]; then path="$REPO/src"; else path="$WORK/cloned${PSEP}$REPO/src"; fi
      if ! IYI_PATH="$path" "$IYI" build calls_c_witness.iyi -o "calls-c-$mode" > "build-calls-c-$mode.log" 2>&1; then
        echo "SETUP: calls-c: the $mode witness did not build"; cat "build-calls-c-$mode.log"; exit 76
      fi
      step "linux: libc thread $mode"
      timeout 120 "./calls-c-$mode" > "calls-c-$mode.txt" 2>&1
      code=$?; check_bound "$code" forced "$mode" "calls-c-$mode.txt"
      if [ "$code" -eq 76 ]; then cat "calls-c-$mode.txt"; exit 76; fi
      if [ "$mode" = control ]; then
        [ "$code" -eq 0 ] && grep -qxF 'calls-c: the held thread used its own pthread handle' "calls-c-$mode.txt" || pair_mismatch "$code" "calls-c-$mode.txt" control
        echo '  control: exit 0, calls-c: the held thread used its own pthread handle'
      else
        [ "$code" -eq 1 ] && grep -qxF 'FAIL: calls-c: a C-calling program started a raw-clone thread' "calls-c-$mode.txt" || pair_mismatch "$code" "calls-c-$mode.txt" mutant 0 'calls-c: the held thread used its own pthread handle'
        echo '  exits 1 at "FAIL: calls-c: a C-calling program started a raw-clone thread"'
      fi
    done
    # ── 7k, the mark helper: a collection's helper launch under a C-calling program ──
    # A collection makes helper threads as well as the program's own. On a
    # fresh heap the first mark finds no earlier mark to size its helpers by,
    # so it asks for none; the second finds four mebibytes live and asks for
    # the one helper allowed. Automatic collection is off, workers is one, and
    # two explicit collections run. The control is hooks only: they count the
    # launch and keep the first pthread handle it got, and the program decides.
    # The mutant makes every launch a raw clone, by letting program_calls_c?
    # answer false, so its one launch gets no handle.
    helper_pass='calls-c helper: the mark helper runs on its own libc thread'
    helper_fail='FAIL: calls-c helper: a C-calling program launched its mark helper by raw clone'
    step "failure proof: a C-calling program launches its mark helper on libc's thread"
    cat > helper_launch.part <<'IYI' || { echo "SETUP: ${current_step:-calls-c helper}: could not write the hooks"; exit 76; }
    # ── The mark helper's launch (bench/thread_exercise.sh, step 7k) ────────
    # Copies only: the awk in that step puts this into a copy of thread.iyi
    # before its roots. Two words of the control page count the launches
    # start_helper makes and keep the first pthread handle one got. Nothing
    # here allocates, takes a lock or writes a message: the program reads the
    # words and decides the verdict.
    IYI_HELPER_LAUNCHES = 3520_u64
    IYI_HELPER_HANDLE = 3968_u64

    # Zeroes both words. Mapping the page here means the launch hooks, which
    # read @@control and never map it, find it.
    def self.helper_arm : Nil
      word(control + IYI_HELPER_LAUNCHES).value.set(0_u64)
      word(control + IYI_HELPER_HANDLE).value.set(0_u64)
    end

    # start_helper, once the helper's stack is mapped and before the choice
    # between libc's thread and a raw clone.
    def self.helper_launch_counted : Nil
      page = @@control
      return if page == 0_u64
      word(page + IYI_HELPER_LAUNCHES).value.add(1_u64)
    end

    # start_helper, right after libc's pthread_create. The first handle stays.
    def self.helper_launch_handle(handle : UInt64) : Nil
      page = @@control
      return if page == 0_u64
      slot = word(page + IYI_HELPER_HANDLE)
      slot.value.set(handle) if slot.value.get == 0_u64
    end

    def self.helper_launch_count : UInt64
      word(control + IYI_HELPER_LAUNCHES).value.get
    end

    def self.helper_first_handle : UInt64
      word(control + IYI_HELPER_HANDLE).value.get
    end

IYI
    cat > helper_launch.iyi <<'IYI' || { echo "SETUP: ${current_step:-calls-c helper}: could not write the witness program"; exit 76; }
@[Unsafe("the program asks libc for its thread, zeroes the helper words of its copy's control page, and reads the pthread handle of the mark helper its second collection launched")]
module helper_launch
lib HelperLibc
  fun pthread_self : UInt64
end
# Sixty-four 64 KiB strings, held by a class variable: a global is a root, and
# each string is an ordinary heap chunk, so the four mebibytes stay live through
# both collections with no local naming them.
class Ballast
  @@keep : Array(String) = [] of String

  def self.hold(chunk : String) : Nil
    @@keep << chunk
  end
end

main_self = HelperLibc.pthread_self
if main_self == 0_u64
  puts "SETUP: calls-c helper: the main thread has no pthread handle"
  __iyi_exit(76)
end

# A fresh heap: no automatic collection, and one helper allowed. A host with
# one core reads the helper count back as zero, which is setup.
IyiMark.auto = false
IyiMark.workers = 1_u64
if IyiMark.workers != 1_u64
  puts "SETUP: calls-c helper: the helper count did not read back as one, which needs two cores"
  __iyi_exit(76)
end
IyiThread.helper_arm

# The first mark finds no earlier mark to size its helpers by, so it asks for
# none. The second finds four mebibytes live and asks for the one allowed.
index = 0
while index < 64
  Ballast.hold("x" * 65536)
  index = index + 1
end
IyiMark.collect
IyiMark.collect

if IyiThread.helper_launch_count == 0_u64
  puts "SETUP: calls-c helper: the second collection launched no helper"
  __iyi_exit(76)
end
handle = IyiThread.helper_first_handle
if handle == 0_u64
  puts "FAIL: calls-c helper: a C-calling program launched its mark helper by raw clone"
  __iyi_exit(1)
end
if handle == main_self
  puts "FAIL: calls-c helper: the mark helper was given the main thread handle"
  __iyi_exit(1)
end
puts "calls-c helper: the mark helper runs on its own libc thread"
IYI
    helper_control_copy() {
      awk -v part=helper_launch.part '
        /^    # ── Roots/ {
          while ((getline line < part) > 0) { print line; part_lines++ }
          close(part)
          roots++
        }
        /^    def self\.start_helper\(entry : UInt64, argument : UInt64\) : Nil$/ { in_helper = 1; helpers++ }
        in_helper && /^        stack = __iyi_mmap\(IYI_THREAD_STACK\)\.address$/ {
          print; print "        IyiThread.helper_launch_counted"; launches++; next
        }
        in_helper && /^          result = start_by_libc\(stack, entry, argument, pointerof\(handle\)\.address\)$/ {
          print; print "          IyiThread.helper_launch_handle(handle)"; handles++; next
        }
        in_helper && /^    end$/ { in_helper = 0; ends++ }
        { print }
        END {
          if (roots != 1 || part_lines == 0 || helpers != 1 || launches != 1 || handles != 1 || ends != 1) exit 3
        }
      ' "$REPO/src/iyi/thread.iyi" > "$1"
    }
    mkdir -p helper-control/iyi helper-cloned/iyi || { echo "SETUP: calls-c helper: could not make the copies"; exit 76; }
    cp "$REPO"/src/iyi/*.iyi helper-control/iyi/ || { echo "SETUP: calls-c helper: could not populate the control copy"; exit 76; }
    helper_control_copy helper-control/iyi/thread.iyi || { echo "SETUP: calls-c helper: the start_helper anchors changed"; exit 76; }
    cp helper-control/iyi/*.iyi helper-cloned/iyi/ || { echo "SETUP: calls-c helper: could not populate the mutant copy"; exit 76; }
    awk '/^    @\[Primitive\(:iyi_calls_c\)\]$/ { primitive++; next }
      /^    def self\.program_calls_c\? : Bool$/ { print; print "      Pointer(UInt8).new(0_u64).address != 0_u64"; method++; next }
      { print } END { if (primitive != 1 || method != 1) exit 3 }' \
      helper-control/iyi/thread.iyi > helper-cloned/iyi/thread.iyi || { echo "SETUP: calls-c helper: the compiler answer anchors changed"; exit 76; }
    cmp -s helper-control/iyi/thread.iyi helper-cloned/iyi/thread.iyi && { echo "SETUP: ${current_step:-calls-c helper}: the raw-clone copy was unchanged"; exit 76; }
    for mode in control cloned; do
      if ! IYI_PATH="$WORK/helper-$mode${PSEP}$REPO/src" "$IYI" build helper_launch.iyi -o "helper-$mode-run" > "build-helper-$mode.log" 2>&1; then
        echo "SETUP: calls-c helper: the $mode copy did not build"; cat "build-helper-$mode.log"; exit 76
      fi
      step "linux: mark helper launch, $mode"
      ( timeout 120 "./helper-$mode-run" > "helper-$mode.txt" 2>&1; exit $? ) 2> /dev/null
      code=$?; check_bound "$code" forced "$mode" "helper-$mode.txt"
      if [ "$mode" = control ]; then
        if [ "$code" -eq 0 ] && [ "$(grep -c '^FAIL:' "helper-$mode.txt" || :)" -eq 0 ] && tr -d '\r' < "helper-$mode.txt" | grep -qxF "$helper_pass"; then
          echo "  control: exit 0, $helper_pass"
        else
          pair_mismatch "$code" "helper-$mode.txt" control
        fi
      else
        if [ "$code" -eq 1 ] && [ "$(grep -c '^FAIL:' "helper-$mode.txt" || :)" -eq 1 ] && tr -d '\r' < "helper-$mode.txt" | grep -qxF "$helper_fail"; then
          echo "  exits 1 at \"$helper_fail\""
        else
          pair_mismatch "$code" "helper-$mode.txt" mutant 0 "$helper_pass"
        fi
      fi
    done
    ;;
esac

echo "workdir $WORK"
echo "thread exercise: every step held"
exit 0
