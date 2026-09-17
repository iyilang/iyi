#!/usr/bin/env bash
# Exercises `std/time`: `Time` and `Time::Span`.
#
#     bash bench/std_time_exercise.sh
#
# Proves:
#   * Known-value table across calendar landmarks (Unix epoch, leap day, century
#     leap and non-leap years, boundary years 0001 and 9999).
#   * Gregorian leap-year rules and month lengths.
#   * Bidirectional round-trip between civil date and Unix timestamp across 5,000+
#     scattered days.
#   * Platform wall clock and monotonic clock readings.
#   * Span construction, accessors, operators (+, -, -@), and Time arithmetic.
#   * ISO 8601 / RFC 3339 serialization (fraction digits 0, 3, 6, 9) and parsing
#     with timezone offset conversions.
#   * Comparable trait implementation via `Std::Traits::Comparable`.
#   * Negative proofs: the exercise script breaks the leap-year rule, roundtrip
#     arithmetic, and RFC 3339 offset handling, asserting each is caught.
#   * Dependency floor: audits symbols and libraries to prove zero new dependencies.
#
# Needs `make` for bin/iyi, plus `nm`, and `otool` on Darwin or `readelf` on Linux.
# Exits non-zero if any check fails.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/floor_base.sh"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0

# Ensure IYI_PATH can find std modules in src/ and samples/iyi/
export IYI_PATH="$REPO/src:$REPO/samples/iyi"

symbols() {
  nm -u "$1" 2>/dev/null |
    sed -e 's/^ *//' -e 's/^U  *//' -e 's/@.*$//' |
    awk '{ print $NF }' |
    sed -e 's/^_//' |
    grep -v '^$' |
    sort -u
}

libraries() {
  if command -v otool >/dev/null 2>&1; then
    otool -L "$1" 2>/dev/null | sed -n '2,$p' | awk '{ print $1 }' | sed 's|.*/||' | sort -u
  else
    readelf -d "$1" 2>/dev/null |
      sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' |
      sed 's|.*/||' | sort -u
  fi
}

unexpected() {
  local allowed="$1" found="$2" item keep ok
  for item in $found; do
    keep=no
    for ok in $allowed; do
      case "$item" in "$ok"*) keep=yes ;; esac
    done
    [ "$keep" = no ] && printf '%s\n' "$item"
  done
  return 0
}

build_and_run() {
  local label="$1" name="$2" source="$3"
  shift 3
  if ! "$IYI" build "$@" -o "$WORK/$name" "$source" >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/time exercise"
build_and_run "std_time" exercise-time "$REPO/bench/std_time_exercise.iyi"

echo
echo "== every time check reported"
for check in "known-value table" "leap-year rules" "scattered roundtrip" "platform clocks" "span construction" "RFC 3339" "time comparison" "ALL CHECKS PASSED"; do
  if ! grep -q "$check" "$WORK/exercise-time.out" 2>/dev/null; then
    echo "  MISSING: $check"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  known-value table, leap-year rules, roundtrip, clocks, spans, RFC 3339 and Comparable all reported"

# ---------------------------------------------------------------------------
# Negative failure proofs
# ---------------------------------------------------------------------------

echo
echo "== negative proof: broken leap-year rule is caught"
mkdir -p "$WORK/patched_leap/std"
cp "$REPO/src/std/time.iyi" "$WORK/patched_leap/std/time.iyi"
python3 -c "
with open('$WORK/patched_leap/std/time.iyi') as f:
    content = f.read()
broken = content.replace('|| (year % 400 == 0)', '&& false')
with open('$WORK/patched_leap/std/time.iyi', 'w') as f:
    f.write(broken)
"
if (IYI_PATH="$WORK/patched_leap:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_time_exercise.iyi" >"$WORK/leap-fail.out" 2>&1); then
  echo "  the exercise PASSED with a broken leap-year rule (it should have failed):"
  head -15 "$WORK/leap-fail.out" | sed 's/^/    /'
  status=1
else
  leap_exit=$?
  echo "  the broken leap-year rule was caught (exit $leap_exit)"
fi

echo
echo "== negative proof: broken civil roundtrip is caught"
mkdir -p "$WORK/patched_rt/std"
cp "$REPO/src/std/time.iyi" "$WORK/patched_rt/std/time.iyi"
python3 -c "
with open('$WORK/patched_rt/std/time.iyi') as f:
    content = f.read()
broken = content.replace('def to_unix : Int64\n    @seconds', 'def to_unix : Int64\n    @seconds + 1_i64')
with open('$WORK/patched_rt/std/time.iyi', 'w') as f:
    f.write(broken)
"
if (IYI_PATH="$WORK/patched_rt:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_time_exercise.iyi" >"$WORK/rt-fail.out" 2>&1); then
  echo "  the exercise PASSED with broken roundtrip (it should have failed):"
  head -15 "$WORK/rt-fail.out" | sed 's/^/    /'
  status=1
else
  rt_exit=$?
  echo "  the broken civil roundtrip was caught (exit $rt_exit)"
fi

echo
echo "== negative proof: broken RFC 3339 timezone offset is caught"
mkdir -p "$WORK/patched_tz/std"
cp "$REPO/src/std/time.iyi" "$WORK/patched_tz/std/time.iyi"
python3 -c "
with open('$WORK/patched_tz/std/time.iyi') as f:
    content = f.read()
broken = content.replace('utc_sec = local_sec - offset_sec', 'utc_sec = local_sec')
with open('$WORK/patched_tz/std/time.iyi', 'w') as f:
    f.write(broken)
"
if (IYI_PATH="$WORK/patched_tz:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_time_exercise.iyi" >"$WORK/tz-fail.out" 2>&1); then
  echo "  the exercise PASSED with broken timezone offset handling (it should have failed):"
  head -15 "$WORK/tz-fail.out" | sed 's/^/    /'
  status=1
else
  tz_exit=$?
  echo "  the broken RFC 3339 timezone offset was caught (exit $tz_exit)"
fi

echo
echo "== what the parser and the formatter refuse"
# A panicking program has no next line to assert on, so each refusal is
# its own program. `parse_rfc3339("2024-02-30T00:00:00Z")` used to answer
# March 1st - a date nobody wrote - where `Time.utc(2024, 2, 30)` refuses;
# `to_rfc3339(12)` printed no fraction in silence; `DayOfWeek.new(8)` was
# Sunday.
time_panics_with() { # time_panics_with <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nimport std/time\nusing std/time::{Time, Span, DayOfWeek}\n\nputs (%s).to_s\n' "$expression" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,10p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of panicking: $(cat "$WORK/$name.out")"
    status=1
    return
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name.out"; then
    echo "  $label: panicked, but not with '$phrase'"
    sed -n '1,3p' "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits 1 at "%s"\n' "$label" "$(sed -n '1p' "$WORK/$name.out" | sed 's/^iyi: panic: //')"
}
time_panics_with "a day the month does not have, parsed" parse_feb30 "invalid day in RFC 3339 string: 30" \
  'Time.parse_rfc3339("2024-02-30T00:00:00Z").to_rfc3339'
time_panics_with "a thirteenth month, parsed" parse_m13 "invalid month in RFC 3339 string: 13" \
  'Time.parse_rfc3339("2024-13-01T00:00:00Z").to_rfc3339'
time_panics_with "a 25th hour, parsed" parse_h25 "invalid hour in RFC 3339 string: 25" \
  'Time.parse_rfc3339("2024-01-01T25:00:00Z").to_rfc3339'
time_panics_with "fraction digits the format cannot print" frac12 "fraction_digits must be 0, 3, 6 or 9, not 12" \
  'Time.utc(2024, 1, 1).to_rfc3339(12)'
time_panics_with "an eighth day of the week" dow8 "invalid day of week: 8" \
  'DayOfWeek.new(8).to_s'
# Text after the offset was never looked at: `...Zjunk` and `...+05:30:00`
# parsed. An offset is 00..23 hours and 00..59 minutes: `+99:99` moved the
# instant four days in silence. A year no Int32 holds is refused with the
# module's sentence, at the constructor and in the parser, where it used to
# be the prelude's "arithmetic overflow" from `year` or `to_rfc3339`; and
# so is a span or a sum the Int64 seconds do not hold.
time_panics_with "text after the timezone" parse_junk "trailing text after the timezone in RFC 3339 string" \
  'Time.parse_rfc3339("2024-02-29T12:00:00Zjunk").to_rfc3339'
time_panics_with "seconds in the offset" parse_tzsec "trailing text after the timezone in RFC 3339 string" \
  'Time.parse_rfc3339("2024-02-29T12:00:00+05:30:00").to_rfc3339'
time_panics_with "a 99:99 offset" parse_tz99 "invalid timezone offset in RFC 3339 string: 99:99" \
  'Time.parse_rfc3339("2024-02-29T12:00:00+99:99").to_rfc3339'
time_panics_with "a 24:00 offset" parse_tz24 "invalid timezone offset in RFC 3339 string: 24:00" \
  'Time.parse_rfc3339("2024-02-29T12:00:00+24:00").to_rfc3339'
time_panics_with "a year past Int32, parsed" parse_y2g "year out of range in RFC 3339 string" \
  'Time.parse_rfc3339("2147483648-01-01T00:00:00Z").to_rfc3339'
time_panics_with "a year past Int32, from the epoch" unix_1e17 "year out of range" \
  'Time.unix(100000000000000000_i64).to_rfc3339'
time_panics_with "the last Int64 second" unix_max "year out of range" \
  'Time.unix(9223372036854775807_i64).year'
time_panics_with "the first Int64 second" unix_min "year out of range" \
  'Time.unix(-9223372036854775808_i64).to_rfc3339'
time_panics_with "a span sum past Int64" span_add "Span overflows" \
  'Span.seconds(9223372036854775807_i64) + Span.seconds(1_i64)'
time_panics_with "a day count past Int64 seconds" span_days "Span overflows" \
  'Span.days(106751991167301_i64)'
time_panics_with "the negation of the smallest span" span_neg "Span overflows" \
  '-Span.seconds(-9223372036854775808_i64)'
time_panics_with "a time plus a span past Int64" time_add "Span overflows" \
  'Time.utc(2024, 1, 1) + Span.seconds(9223372036854775807_i64)'
# And the one RFC 3339 allows that the constructor does not: a leap second
# is read as the second after 59, not refused.
printf 'module main\n\nimport std/time\nusing std/time::{Time}\n\nputs Time.parse_rfc3339("2016-12-31T23:59:60Z").to_rfc3339\n' > "$WORK/leap.iyi"
if [ "$("$IYI" run "$WORK/leap.iyi" 2>&1)" = "2017-01-01T00:00:00Z" ]; then
  echo "  a leap second is read as the instant it names"
else
  echo "  a leap second was not read as the next second:"; "$IYI" run "$WORK/leap.iyi" 2>&1 | sed -n '1,2p'
  status=1
fi

# ---------------------------------------------------------------------------
# Dependency floor audit
# ---------------------------------------------------------------------------

echo
echo "== the dependency floor, measured against the std_time exercise binary"
case "$(uname -s)" in
  Linux)
    allowed_symbols="$FLOOR_BASE_LINUX"
    if ! command -v readelf >/dev/null 2>&1; then
      echo "  readelf is required on Linux to read NEEDED entries" >&2
      exit 2
    fi
    ;;
  *)
    # The base is every darwin program's (bench/floor_base.sh); the socket
    # and file names beside it are what this exercise's binary asks for on
    # top, each libSystem's, which the `allowed_libs` check below proves.
    allowed_symbols="$FLOOR_BASE_DARWIN accept bind chmod close connect getsockname listen open recv send setsockopt socket unlink"
    ;;
esac
allowed_libs="$FLOOR_LIBS_PROGRAM"

if [ -x "$WORK/exercise-time" ]; then
  time_syms="$(symbols "$WORK/exercise-time")"
  time_libs="$(libraries "$WORK/exercise-time")"
  printf '  symbols   %s\n' "$(echo $time_syms)"
  printf '  libraries %s\n' "$(echo $time_libs)"

  extra_syms="$(unexpected "$allowed_symbols" "$(echo $time_syms)")"
  if [ -n "$extra_syms" ]; then
    echo "  std/time asks the machine for something new:"
    echo "$extra_syms" | sed 's/^/    /'
    echo "  Each is a dependency being taken on. If that is the decision, record it"
    echo "  here and in the commit (SPEC.md III.9)."
    status=1
  fi

  extra_libs="$(unexpected "$allowed_libs" "$(echo $time_libs)")"
  if [ -n "$extra_libs" ]; then
    echo "  std/time links something new:"
    echo "$extra_libs" | sed 's/^/    /'
    status=1
  fi
  [ -z "$extra_syms$extra_libs" ] && echo "  nothing new: std/time costs zero new symbols and zero new libraries"
else
  echo "  no exercise binary to audit"
  status=1
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/time exercise holds"
else
  echo "the std/time exercise did not hold"
fi
exit $status
