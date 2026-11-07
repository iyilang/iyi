#!/usr/bin/env bash
# Runs one gate under a bound, and says what was running if it passes it.
#
#     bash bench/bounded_gate.sh MINUTES bench/some_gate.sh [ARGS...]
#
# Exits with the gate's status, or 124 when the bound ends it. The gate's
# output goes where this script's does, as it is written.
#
# Windows' collector gates ran as one step, one after another, with no bound
# of their own: in job 120284584748 bench/sweep_exercise.sh printed its
# first line and then nothing until the job was cancelled at its 150 minutes,
# 2 h 25 min later, and the log could not say whether the compiler, the
# linker or the program was the one still running, nor what its threads
# were doing. Master's green run of the same job two hours earlier (job
# 120284541992, on four cores) took 9 min 37 s for all eight gates, the
# longest of them bench/thread_exercise.sh at 4 min 33 s.
#
# When the bound fires, before anything is ended: every process under the
# gate, and on Windows each of their threads - its state, what it waits on,
# and the CPU it took over two seconds, which is what tells a thread spinning
# from one blocked - with each thread's stack where the Windows SDK's cdb is
# installed; then the tail of every log and output file the gate wrote. The
# gate's scratch directories are made under a TMPDIR of this script's, which
# is how the files are found.
set -u

if [ "$#" -lt 2 ]; then
  echo "usage: bash bench/bounded_gate.sh MINUTES GATE [ARGS...]" >&2
  exit 2
fi
minutes="$1"
shift
gate="$1"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) windows=1 ;;
  *) windows=0 ;;
esac

scratch="$(mktemp -d)"
mkdir -p "$scratch/tmp"
started="$(date +%s)"

TMPDIR="$scratch/tmp" bash "$@" &
pid=$!

# The gate's descendants, its own pid first: by /proc's ppid on Windows,
# which is Git bash's view of its processes, and by pgrep elsewhere. What
# a native program starts in turn is found by its Windows parent, below.
descendants() {
  local list=" $1 " changed=1 dir p parent
  while [ "$changed" -eq 1 ]; do
    changed=0
    if [ "$windows" -eq 1 ]; then
      for dir in /proc/[0-9]*; do
        p="${dir#/proc/}"
        case "$list" in *" $p "*) continue ;; esac
        { read -r parent < "$dir/ppid"; } 2>/dev/null || continue
        case "$list" in *" $parent "*) list="$list$p "; changed=1 ;; esac
      done
    else
      for parent in $list; do
        for p in $(pgrep -P "$parent" 2>/dev/null); do
          case "$list" in *" $p "*) ;; *) list="$list$p "; changed=1 ;; esac
        done
      done
    fi
  done
  echo $list
}

# Every Windows process under the given ones, theirs included, with its
# threads sampled twice two seconds apart, and their stacks through cdb
# where the SDK's debuggers are installed. Git's programs and Windows' own
# - the gate's shells and tools, a console host - are listed and not
# opened; what they run is.
describe_windows() {
  local script="$scratch/describe.ps1"
  cat > "$script" <<'PS1'
param([string]$Roots)
# Not `$roots`: PowerShell's names ignore case, and that one is the string.
$starts = @($Roots -split ',' | Where-Object { $_ } | ForEach-Object { [int]$_ })
$all = @(Get-CimInstance Win32_Process)
$seen = @{}
$queue = New-Object System.Collections.Queue
foreach ($r in $starts) { $queue.Enqueue($r) }
$order = @()
while ($queue.Count -gt 0) {
  $id = $queue.Dequeue()
  if ($seen.ContainsKey($id)) { continue }
  $seen[$id] = $true
  $order += $id
  foreach ($p in $all) { if ([int]$p.ParentProcessId -eq $id -and -not $seen.ContainsKey([int]$p.ProcessId)) { $queue.Enqueue([int]$p.ProcessId) } }
}
$cdb = @("${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe", "$env:ProgramFiles\Windows Kits\10\Debuggers\x64\cdb.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$opened = @()
foreach ($id in $order) {
  $p = $all | Where-Object { [int]$_.ProcessId -eq $id } | Select-Object -First 1
  if (-not $p) { continue }
  $line = "$($p.CommandLine)"
  if ($line.Length -gt 300) { $line = $line.Substring(0, 300) + '...' }
  "  windows pid $id, parent $($p.ParentProcessId): $($p.Name)  $line"
  if ("$($p.ExecutablePath)" -notlike '*\Git\*' -and "$($p.ExecutablePath)" -notlike "$env:SystemRoot\*") { $opened += $id }
}
foreach ($id in $opened) {
  $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
  if (-not $proc) { continue }
  $before = @{}
  foreach ($t in $proc.Threads) { $before[$t.Id] = $t.TotalProcessorTime.TotalMilliseconds }
  Start-Sleep -Seconds 2
  $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
  if (-not $proc) { "  $id ended while it was looked at"; continue }
  "  the threads of $($proc.ProcessName) ($id), CPU over the last two seconds:"
  foreach ($t in $proc.Threads) {
    $state = "$($t.ThreadState)"
    if ($state -eq 'Wait') { $state = "waiting ($($t.WaitReason))" }
    $was = $before[$t.Id]
    $took = if ($null -ne $was) { '{0:N0} ms' -f ($t.TotalProcessorTime.TotalMilliseconds - $was) } else { 'new' }
    '    thread {0}: {1}, {2}, {3:N1} s in all' -f $t.Id, $state, $took, $t.TotalProcessorTime.TotalSeconds
  }
  if ($cdb) {
    "  their stacks (cdb, attached without stopping the process for good):"
    $symbols = if ($proc.Path) { Split-Path -Parent $proc.Path } else { '.' }
    & $cdb -pv -p $id -y $symbols -c '~*k 24; q' 2>&1 | Where-Object { $_ -match '^\s*(#|\.|[0-9]+\s+Id:|[0-9a-f]{2} [0-9a-f`]+ )' } | ForEach-Object { "    $_" }
  } else {
    "  (no cdb on this machine, so no stacks)"
  }
}
PS1
  # Bounded too, so nothing asked of Windows here can hold the step.
  MSYS2_ARG_CONV_EXCL='*' timeout -k 5 180 powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$script")" -Roots "$1" 2>&1 | tr -d '\r'
}

describe() {
  local list p roots="" command files
  list="$(descendants "$pid")"
  echo "  the processes under it:"
  for p in $list; do
    if [ "$windows" -eq 1 ]; then
      command="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
      echo "    pid $p (windows $(cat "/proc/$p/winpid" 2>/dev/null)): ${command:0:300}"
      roots="$roots$(cat "/proc/$p/winpid" 2>/dev/null),"
    else
      ps -o pid=,ppid=,stat=,time=,command= -p "$p" 2>/dev/null | sed 's/^/    /'
    fi
  done
  if [ "$windows" -eq 1 ]; then
    describe_windows "$roots"
  fi
  echo "  what the gate wrote, the newest last:"
  files="$(find "$scratch/tmp" -type f \( -name '*.log' -o -name '*.out' -o -name '*.txt' \) 2>/dev/null)"
  [ -n "$files" ] && ls -1tr $files | while read -r file; do
    echo "    -- ${file#"$scratch/tmp/"} ($(wc -c < "$file") bytes)"
    tail -n 8 "$file" | sed 's/^/       /'
  done
}

end_all() {
  local list p
  list="$(descendants "$pid")"
  for p in $list; do
    if [ "$windows" -eq 1 ]; then
      taskkill //F //T //PID "$(cat "/proc/$p/winpid" 2>/dev/null)" > /dev/null 2>&1
    fi
    kill -KILL "$p" 2>/dev/null
  done
}

deadline=$((started + minutes * 60))
while kill -0 "$pid" 2>/dev/null; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo
    echo "== $gate: still running after $minutes minutes, and ended here"
    describe
    end_all
    # A process Windows cannot end - one thread left in NtTerminateProcess -
    # would hold this script too, so the wait for the end is bounded.
    tries=0
    while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 30 ]; do
      sleep 1
      tries=$((tries + 1))
    done
    kill -0 "$pid" 2>/dev/null && echo "  $gate did not end when asked; it is left behind"
    echo "== $gate: stalled past its bound of $minutes minutes"
    exit 124
  fi
  sleep 1
done
wait "$pid"
status=$?
echo "== $gate: exit $status after $(( $(date +%s) - started )) s"
rm -rf "$scratch"
exit "$status"
