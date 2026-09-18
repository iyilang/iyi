#!/usr/bin/env bash
# What `defer` costs, measured — the price III.1.4's registry charges.
#
# The panic path bought its unwind by making every `defer` register a
# cleanup proc at runtime: one node, one closure, pushed on entry and
# popped on exit. That is not free, and this repository does not carry
# unmeasured costs: two release builds, twenty million calls each, one
# with a `defer` in the callee and one without, and the difference is
# the per-defer price, printed and budgeted. The budget is loose (CI
# machines are not laptops); the claim it holds is architectural — a
# defer is nanoseconds, not a syscall.
set -euo pipefail

IYI=${IYI:-./bin/iyi}
work=$(mktemp -d /tmp/iyi-defer-cost.XXXXXX)
# A native compiler cannot resolve this shell's own path mapping: a
# scratch directory named `/tmp/tmp.X` is silently ignored on the search
# path, so the patched copy is never read and the proof that a check can
# fail quietly stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) work="$(cygpath -m "$work")" ;;
esac
trap 'rm -rf "$work"' EXIT

N=20000000
BUDGET_NS=2000

cat > "$work/bare.iyi" <<'EOF'
module bare

def nothing : Nil
end

def step(i : Int32) : Int32
  nothing
  i
end

pub def total(n : Int32) : Int32
  acc = 0
  i = 0
  while i < n
    acc = acc + (step(i) & 1)
    i = i + 1
  end
  acc
end

puts total(20000000)
EOF

cat > "$work/deferred.iyi" <<'EOF'
module deferred

def nothing : Nil
end

def step(i : Int32) : Int32
  defer nothing
  i
end

pub def total(n : Int32) : Int32
  acc = 0
  i = 0
  while i < n
    acc = acc + (step(i) & 1)
    i = i + 1
  end
  acc
end

puts total(20000000)
EOF

"$IYI" build --release -o "$work/bare" "$work/bare.iyi"
"$IYI" build --release -o "$work/deferred" "$work/deferred.iyi"

time_ns() {
  local start end
  start=$(date +%s%N)
  "$1" > /dev/null
  end=$(date +%s%N)
  echo $((end - start))
}

# Warm, then take the better of two runs each: the question is the
# instruction cost, not the scheduler's mood.
"$work/bare" > /dev/null
"$work/deferred" > /dev/null
bare=$(time_ns "$work/bare"); b2=$(time_ns "$work/bare")
[ "$b2" -lt "$bare" ] && bare=$b2
deferred=$(time_ns "$work/deferred"); d2=$(time_ns "$work/deferred")
[ "$d2" -lt "$deferred" ] && deferred=$d2

per_op=$(( (deferred - bare) / N ))
[ "$per_op" -lt 0 ] && per_op=0

echo "defer cost: bare $((bare / 1000000)) ms, deferred $((deferred / 1000000)) ms over $N calls"
echo "defer cost: ~${per_op} ns per defer (budget ${BUDGET_NS})"

if [ "$per_op" -gt "$BUDGET_NS" ]; then
  echo "OVER BUDGET: a defer costs ${per_op} ns, the budget is ${BUDGET_NS}"
  exit 1
fi
echo "defer cost: inside the budget"
