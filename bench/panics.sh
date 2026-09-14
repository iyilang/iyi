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
expected=$(printf 'iyi: panic: boom\n  at %s\ntask defer ran\niyi: panic: a task panicked: boom\nouter defer ran' "$work/task.iyi:5")
[ "$out" = "$expected" ] || fail "task panic output was:
$out"
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
expected=$(printf 'iyi: panic: on main\n  at %s\nsecond defer\nfirst defer' "$work/main.iyi:6")
[ "$out" = "$expected" ] || fail "main panic output was:
$out"
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
[ "$out" = "iyi: panic: slice size must be positive" ] || fail "a std panic named a library line:
$out"
cat > "$work/index.iyi" <<'EOF'
module index

a = [1, 2, 3]
i = 5
puts a[i]
EOF
run "$work/index.iyi"
[ "$out" = "iyi: panic: index 5 out of range for 3 elements" ] || fail "a prelude panic named a library line:
$out"
step "a panic the library raises names no library line, prelude or std"

echo "panics gate: every step held"
