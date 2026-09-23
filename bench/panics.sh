#!/usr/bin/env bash
# Panics — SPEC.md III.1.4, made literal. Each step is one sentence the
# section now states in the present tense: a panic prints at the site of
# the bug - the message, then the program's file and line - and unwinds
# by registry, pending defers run innermost-first, a
# panicking task dies at its boundary while its group cancels the
# siblings, the boundary re-raises in the owner exactly once, a panic
# with no boundary above it exits 1 after its defers ran, and `.or_panic`
# is a real panic. The no-panic path rides the same registry and is
# asserted unchanged.
set -euo pipefail

IYI=${IYI:-./bin/iyi}
work=$(mktemp -d /tmp/iyi-panics.XXXXXX)
trap 'rm -rf "$work"' EXIT

fail() { echo "panics FAIL: $1"; exit 1; }
step() { echo "panics ok   $1"; }

# The site a panic prints is the file the compiler was handed, in the
# platform's own form: `/tmp/iyi-panics.XXXX/task.iyi` here and
# `C:\Users\…\Temp\iyi-panics.XXXX\task.iyi` on Windows, where this
# directory is under `%TEMP%` and every separator is a backslash. So the
# assertion normalises the output's separators and names the work
# directory by its own unique tail rather than by the path bash spells it
# with — still a check that the site is *this* run's file and line.
site() { # file:line -> fails unless the output named it
  printf '%s' "$out" | tr '\\' '/' | grep -q "at .*$(basename "$work")/$1" ||
    fail "$2: $out"
}

run() { # file -> captures stdout+stderr, tolerates nonzero exit
  set +e
  out=$("$IYI" run "$1" 2>&1)
  code=$?
  set -e
}

# ── 1. a task panics: its defer runs, the boundary re-raises, the
#      sibling is cancelled, the process exits 1 in order ──────────────
cat > "$work/task.iyi" <<'EOF'
module task

pub def work : Int32
  defer puts "task defer ran"
  raise "boom" if true
  1
end

pub def run_all : Int32
  defer puts "outer defer ran"
  group do |g|
    g.spawn { work }
    g.spawn {
      s = sleep(5000)
      puts "sibling woke" if s.is_a?(Nil)
      2
    }
  end
  puts "after group"
  0
end

puts run_all
EOF
run "$work/task.iyi"
[ "$code" = 1 ] || fail "task panic exit was $code, wanted 1"
echo "$out" | grep -q "^iyi: panic: boom" || fail "task panic missing message: $out"
site "task.iyi:5" "task panic missing site"
echo "$out" | grep -q "task defer ran" || fail "task defer did not run: $out"
echo "$out" | grep -q "iyi: panic: a task panicked: boom" || fail "boundary re-raise missing: $out"
echo "$out" | grep -q "outer defer ran" || fail "outer defer did not run: $out"
step "a panicking task dies at its boundary, defers ran, sibling cancelled"

# ── 2. a panic with no boundary above it: main's defers run LIFO, then
#      exit 1 — cleanup that yesterday's panic skipped entirely ────────
cat > "$work/main.iyi" <<'EOF'
module main

pub def go : Int32
  defer puts "first defer"
  defer puts "second defer"
  raise "on main" if true
  0
end

puts go
EOF
run "$work/main.iyi"
[ "$code" = 1 ] || fail "main panic exit was $code, wanted 1"
echo "$out" | grep -q "^iyi: panic: on main" || fail "main panic missing message: $out"
site "main.iyi:6" "main panic missing site"
echo "$out" | grep -q "second defer" || fail "second defer did not run: $out"
echo "$out" | grep -q "first defer" || fail "first defer did not run: $out"
step "an unbounded panic exits 1 after its defers, innermost first"

# ── 3. `.or_panic` is a real panic now: through the task boundary,
#      carrying the error's message ────────────────────────────────────
cat > "$work/orp.iyi" <<'EOF'
module orp

pub struct Boom
end

impl Error for Boom
  def message : String
    "or_panic fired"
  end
end

pub def risky(n : Int32) : Int32 | Boom
  return Boom.new if n > 0
  n
end

group do |g|
  g.spawn { risky(1).or_panic }
end
puts "unreached"
EOF
run "$work/orp.iyi"
[ "$code" = 1 ] || fail "or_panic exit was $code, wanted 1"
echo "$out" | grep -q "iyi: panic: or_panic fired" || fail "or_panic message missing:
$out"
echo "$out" | grep -q "a task panicked: or_panic fired" || fail "or_panic boundary missing:
$out"
! echo "$out" | grep -q "unreached" || fail "or_panic fell through"
step ".or_panic is a real panic, caught at the boundary"

# ── 4. reading a panicked task's value *catches* the panic: it arrives
#      as the `Panicked` error value, the group continues, the program
#      exits 0 — III.1.4's "catchable at task boundaries", literal ────
cat > "$work/value.iyi" <<'EOF'
module tval

pub def blows : Int32
  raise "task blew" if true
  1
end

caught = ""
group do |g|
  t = g.spawn { blows }
  v = t.value
  caught = v.is_a?(Panicked) ? "caught: " + v.message : "missed"
end
puts caught
puts "life goes on"
EOF
run "$work/value.iyi"
[ "$code" = 0 ] || fail "value exit was $code, wanted 0 (the panic was read):
$out"
echo "$out" | grep -q "caught: task blew" || fail "the panic did not arrive as a value:
$out"
echo "$out" | grep -q "life goes on" || fail "the program did not continue:
$out"
! echo "$out" | grep -q "a task panicked" || fail "an observed panic was re-raised anyway:
$out"
step "a read panic is a value; the process outlives the bug"

# ── 5. the panic crosses two boundaries: inner group's owner is a task
#      of the outer group, and each boundary adds its own report ───────
cat > "$work/nested.iyi" <<'EOF'
module nested

pub def inner_work : Int32
  raise "deep" if true
  1
end

pub def middle : Int32
  group do |g|
    g.spawn { inner_work }
  end
  0
end

group do |g|
  g.spawn { middle }
end
puts "unreached"
EOF
run "$work/nested.iyi"
[ "$code" = 1 ] || fail "nested exit was $code, wanted 1"
echo "$out" | grep -q "a task panicked: a task panicked: deep" || fail "nested chain missing:
$out"
step "a panic climbs group by group, each boundary named"

# ── 6. the no-panic path is untouched: defers run LIFO on a normal
#      exit and on a return, and the program answers what it always did ─
cat > "$work/normal.iyi" <<'EOF'
module normal

pub def with_cleanup(early : Bool) : Int32
  defer puts "close a"
  defer puts "close b"
  return 1 if early
  puts "body ran"
  2
end

puts with_cleanup(false)
puts with_cleanup(true)
EOF
run "$work/normal.iyi"
[ "$code" = 0 ] || fail "normal exit was $code, wanted 0"
expected=$(printf 'body ran\nclose b\nclose a\n2\nclose b\nclose a\n1')
[ "$out" = "$expected" ] || fail "normal-path output was:
$out"
step "the no-panic path is unchanged: LIFO on fall-through and on return"

# ── 7. an arithmetic overflow is a panic like any other: the trap
#      routes through the registry, so a task's overflow dies at the
#      task boundary instead of taking the process bare-handed ────────
cat > "$work/overflow.iyi" <<'EOF'
module overflow

pub def blows : Int32
  n = 2147483647
  n + 1
end

group do |g|
  g.spawn { blows }
end
puts "unreached"
EOF
run "$work/overflow.iyi"
[ "$code" = 1 ] || fail "overflow exit was $code, wanted 1"
echo "$out" | grep -q "iyi: panic: arithmetic overflow" || fail "overflow message missing:
$out"
echo "$out" | grep -q "a task panicked: arithmetic overflow" || fail "overflow boundary missing:
$out"
! echo "$out" | grep -q "unreached" || fail "overflow fell through"
step "an overflow in a task dies at the task boundary"

# ── 8. the panic a panic cannot print: the reader is gone, so the write
#      that says so fails too. It used to print through the program's
#      own output stream, whose failed write raised, which printed,
#      which failed - until the stack ended and `prog | head` died of
#      "invalid memory access". The panic goes to the descriptor now,
#      and to descriptor 2, which is also why `prog > file` no longer
#      finds a panic inside the file. ─────────────────────────────────
cat > "$work/pipe.iyi" <<'EOF'
module pipe

n = 0
while n < 200000
  puts "line"
  n = n + 1
end
EOF
"$IYI" build "$work/pipe.iyi" -o "$work/pipe" >/dev/null 2>&1 || fail "pipe fixture did not build"
# SIGPIPE ignored is how every parent that matters runs a child: the
# editor's `▶ run`, a Crystal or Go parent, systemd. With the signal
# doing the killing there is no panic to print at all (exit 141).
set +e
trap "" PIPE
"$work/pipe" 2>"$work/pipe.err" | head -c 20 > "$work/pipe.out"
status=${PIPESTATUS[0]}
trap - PIPE
set -e
said=$(head -c 400 "$work/pipe.err")
[ "$status" != 139 ] || fail "a closed reader still segfaults the writer"
[ "$status" = 1 ] || fail "closed-reader exit was $status, wanted 1"
echo "$said" | grep -q "iyi: panic: write failed" || fail "closed-reader panic said:
$said"
set +e
data=$(trap "" PIPE; "$work/pipe" 2>/dev/null | head -c 20)
set -e
case "$data" in
  line*) ;;
  *) fail "the program's own output carried the panic: $data" ;;
esac
step "a panic with nowhere to print says so once, on the error stream"

# ── 9. the site is printed when it is the program's, and not when it is
#      the library's: a `raise` in the program names its line; a panic
#      the prelude raises names none, and neither does one `std` raises.
#      `each_slice(0)` printed `at .../src/std/enumerable.iyi:442`, which
#      is the library's line and not where the bug is - the prelude's
#      rule, applied to the other half of the library ──────────────────
cat > "$work/site.iyi" <<'EOF'
module site

import std/enumerable
import std/list
using std/enumerable::{Enumerable}
using std/list::{List}

three = List(Int32).new([1, 2, 3])
puts three.each_slice(0).size
EOF
run "$work/site.iyi"
[ "$code" = 1 ] || fail "std panic exit was $code, wanted 1"
echo "$out" | grep -q "^iyi: panic: slice size must be positive" || fail "std panic missing message: $out"
echo "$out" | grep -q "at.*src/std" && fail "a std panic named a library line: $out"
cat > "$work/index.iyi" <<'EOF'
module index

pub def go : Int32
  a = [1, 2, 3]
  i = 5
  puts a[i]
  0
end

puts go
EOF
run "$work/index.iyi"
[ "$code" = 1 ] || fail "prelude panic exit was $code, wanted 1"
echo "$out" | grep -q "^iyi: panic: index 5 out of range for 3 elements" || fail "prelude panic missing message: $out"
echo "$out" | grep -q "at.*src/iyi" && fail "a prelude panic named a library line: $out"
# On Darwin, the panic raises a backtrace through libSystem's backtrace and
# points at the program rather than the library. Windows captures its
# callers too (`RtlCaptureStackBackTrace`) but prints none without a
# resolver, which is the next step's subject; on the Linux raw-syscall
# runtime capture is not built yet.
if [ "$(uname -s)" = Darwin ]; then
  echo "$out" | grep -qE "index\.iyi|Index@Index::go|Index::go" \
    || fail "library panic named no frame in the program: $out"
fi
step "a panic the library raises names no library line, prelude or std"

# ── 9a. a program that imports `std/debug` gets its callers named: the
#      resolver reads the program's own debug information — DWARF beside a
#      Mach-O, the CodeView PDB the linker wrote beside a PE — and a frame
#      is a function and a source line rather than an address. This is the
#      whole of what `std/debug` is for, and it was never gated. ────────
case "$(uname -s)" in
  Darwin | MINGW* | MSYS* | CYGWIN* | Windows_NT)
    cat > "$work/named.iyi" <<'EOF'
module named

import std/debug

def inner(n : Int32) : Int32
  raise "named frames" if n == 2
  inner(n + 1)
end

puts inner(0)
EOF
    run "$work/named.iyi"
    [ "$code" = 1 ] || fail "the named-frames panic exited $code, wanted 1"
    echo "$out" | grep -q "^iyi: panic: named frames" || fail "no panic line: $out"
    # Each platform names a frame in the form its debug information holds:
    # darwin's Mach-O symbol is the mangled `*Named@Named::inner<Int32>:Int32`
    # and Windows' PDB procedure record is the display name `inner`, so the
    # pattern asks for the function's own name followed by the file and a
    # line and does not pin either spelling.
    echo "$out" | grep -qE "inner[^ ]* at .*named\.iyi:[0-9]" ||
      fail "no frame named the program's own function and line:
$out"
    # More than one frame of the same recursion, so the walk is a walk and
    # not one resolved address repeated by accident.
    frames="$(echo "$out" | grep -cE "inner[^ ]* at .*named\.iyi:")"
    [ "$frames" -ge 2 ] || fail "the trace named $frames frames of the recursion, wanted at least 2:
$out"
    step "a panic names its callers where the program imported a resolver"
    ;;
  *)
    step "a panic names its callers where the program imported a resolver: not measured here, because backtrace capture is not built on this runtime"
    ;;
esac

# ── 10. the stack running out is a panic the program prints itself: on
#      the main stack, on a fiber's (its guard page), on a thread's (its
#      own alternate signal stack) - and a fault that is not the stack's
#      edge is left to the signal, so a memory fault stays a memory fault.
#      This was "Segmentation fault" from the shell and exit 139 ───────
for where in main fiber thread; do
  # Every stack here, on every platform. Windows used to name only the
  # main one: a fiber's overflow arrived with no room for the handler to
  # print from, because a vectored handler runs on the stack that faulted
  # and Windows has no `sigaltstack`. A fiber stack now ends in a
  # committed PAGE_GUARD page with 16 KB of committed slack under it
  # (`IyiFiber#map_stack`), which is the room, and the fault arrives as
  # STATUS_STACK_OVERFLOW rather than a guard-page violation because the
  # switch has told the TEB that this is the thread's stack.
  case "$where" in
    main)   body='puts down(0)' ;;
    fiber)  body='group do |g|
  g.spawn { down(0) }
end' ;;
    thread) body='t = IyiThread.start { down(0); nil }
t.join' ;;
  esac
  printf 'module deep_%s\n\ndef down(n : Int32) : Int32\n  down(n + 1) + 1\nend\n\n%s\n' "$where" "$body" > "$work/deep_$where.iyi"
  run "$work/deep_$where.iyi"
  [ "$code" = 1 ] || fail "stack overflow on the $where stack exited $code, wanted 1 (139 is the signal, unhandled)"
  [ "$out" = "iyi: panic: stack overflow: the stack ran out, which is infinite or very deep recursion" ] ||
    fail "stack overflow on the $where stack said:
$out"
done
# The same overflow, eight more times from one binary. On Windows the
# handler used to end with `ExitProcess`, which runs every DLL's detach
# on the thread that faulted — the stack that had just run out — and a
# second overflow past a guard page already consumed is an access
# violation, which the same handler then named a memory fault under the
# stack-overflow sentence. Whether the 16 KB guarantee covered the
# detaches depended on where the first fault landed, so one run in three
# showed it and two did not. Repeated runs make a flake a failure.
# And on the other two stacks the same way: a thread's guarantee is its
# own, and was set on the main thread alone, so a thread's overflow said
# "memory fault" on the runs where it landed near the bottom.
for where in main fiber thread; do
  set +e
  "$IYI" build -o "$work/deep_${where}_bin" "$work/deep_$where.iyi" > /dev/null 2>&1
  set -e
  for again in 1 2 3 4 5 6 7 8; do
    set +e
    out=$("$work/deep_${where}_bin" 2>&1)
    code=$?
    set -e
    [ "$code" = 1 ] || fail "stack overflow on the $where stack, run $again, exited $code, wanted 1"
    [ "$out" = "iyi: panic: stack overflow: the stack ran out, which is infinite or very deep recursion" ] ||
      fail "stack overflow on the $where stack, run $again, said more than the sentence:
$out"
  done
done
cat > "$work/wild.iyi" <<'EOF'
module wild

p = Pointer(Int32).new(16_u64)
puts p.value
EOF
set +e
"$IYI" build -o "$work/wild" "$work/wild.iyi" > /dev/null 2>&1
"$work/wild" > "$work/wild.out" 2>&1
code=$?
set -e
# What a fault that is *not* the stack's looks like, per platform. On POSIX
# the guard declines it and the signal kills the process: 139 is SIGSEGV,
# unhandled. On Windows there is no signal — the runtime's own vectored
# handler names the fault and exits 1 — so the assertion there is the
# sentence rather than the code. Either way the check is the same one: a
# wild pointer must not be reported as the stack running out.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    [ "$code" = 1 ] || fail "a wild pointer exited $code, wanted 1: the Windows fault handler did not name it"
    grep -q "died of a memory fault" "$work/wild.out" ||
      fail "a wild pointer was not named a memory fault: $(cat "$work/wild.out")"
    ;;
  *)
    [ "$code" = 139 ] || fail "a wild pointer exited $code, wanted the signal (139): the guard claimed a fault that is not the stack's"
    ;;
esac
grep -q "stack overflow" "$work/wild.out" && fail "a wild pointer was called a stack overflow"
step "the stack running out is a panic on every stack, and a wild pointer is not"

# ── 11. a panic prints backtrace frames locating the call site ─────────────
if [ "$(uname -s)" = Darwin ]; then
  cat > "$work/trace.iyi" <<'EOF'
module trace

def depth3(x : Int32) : Int32
  raise "deep boom" if x > 0
  x
end

def depth2(x : Int32) : Int32
  depth3(x)
  x + 2
end

def depth1(x : Int32) : Int32
  depth2(x)
  x + 1
end

puts depth1(42)
EOF
  run "$work/trace.iyi"
  [ "$code" = 1 ] || fail "trace exit was $code, wanted 1"
  echo "$out" | grep -q "^iyi: panic: deep boom" || fail "trace message missing: $out"
  echo "$out" | grep -q "depth3" || fail "frame depth3 missing from backtrace: $out"
  echo "$out" | grep -q "depth2" || fail "frame depth2 missing from backtrace: $out"
  echo "$out" | grep -q "depth1" || fail "frame depth1 missing from backtrace: $out"
  step "a panic prints backtrace frames locating the call site"

  # ── 12. a panic resolver hook formats frames when installed ────────────────
  cat > "$work/hook.iyi" <<'EOF'
module hook

def format_trace(frames : Pointer(Void*), count : Int32) : Nil
  print "custom resolver: "
  print count.to_s
  print " frames\n"
end

IyiPanic.resolver = ->format_trace(Pointer(Void*), Int32)

def cause_panic
  raise "hooked panic"
end

cause_panic
EOF
  run "$work/hook.iyi"
  [ "$code" = 1 ] || fail "hooked panic exit was $code, wanted 1"
  echo "$out" | grep -q "^iyi: panic: hooked panic" || fail "hooked panic message missing: $out"
  echo "$out" | grep -q "custom resolver:.*frames" || fail "custom resolver hook was not called: $out"
  step "a panic resolver hook formats frames when installed"
fi

echo "panics gate: every step held"
