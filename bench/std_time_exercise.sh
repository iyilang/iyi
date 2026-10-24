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
#   * `Time::Format`: every directive and flag written against fixed instants,
#     round trips through patterns and every named format (HTTP date, RFC
#     2822, RFC 3339, ISO 8601), RFC 9110's three HTTP date forms, bad text
#     refused as a `TimeParseError` rather than a panic, ISO weeks and
#     `shift(months:)`; the same program optimised (`--release`).
#   * `Time::Location`: the exercise's own TZif files; Windows
#     TIME_ZONE_INFORMATION bytes made by hand for six zones, checked against
#     Python's zoneinfo, and the machine's own zone; then the machine's
#     zone database read for fifteen zones and checked against Python's
#     zoneinfo, and twelve `TZ` settings against glibc's `localtime`.
#   * Negative proofs: the exercise script breaks the leap-year rule, roundtrip
#     arithmetic, RFC 3339 offset handling, eight parts of `Time::Format`
#     (month names, both offset directions, trailing text, RFC 9110's year
#     rule, the month's last day, ISO weeks, the 12-hour clock) and eight of
#     `Time::Location` (a rule's weekday, the footer, the version 2 block,
#     signed words, header counts, a repeated wall time, a shifted day, a
#     Windows bias read unsigned), asserting each is caught.
#   * Dependency floor: audits symbols and libraries to prove zero new dependencies.
#
# Needs `make` for bin/iyi, plus `nm`, and `otool` on Darwin or `readelf` on Linux.
# Exits non-zero if any check fails.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/floor_base.sh"
# The gate runs the compiler the caller names; bin/iyi is a POSIX shell
# wrapper a Windows build cannot run.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on that path, so the
# patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# The negative proofs are patched by python, and a machine can answer
# `python3` with a store stub that prints a refusal instead of running, so
# the interpreter is resolved once and proven to run before it is trusted.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

status=0

# Ensure IYI_PATH can find std modules in src/ and samples/iyi/
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

symbols() {
  nm -u "$1" 2>/dev/null |
    sed -e 's/^ *//' -e 's/^U  *//' -e 's/@.*$//' |
    awk '{ print $NF }' |
    sed -e 's/^_//' |
    # glibc's `environ` is a weak alias of `__environ`, and which one a
    # binary names is the libc's choice; bench/dependency_floor.sh reads
    # them as one name too.
    sed -e 's/^_environ$/environ/' |
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
echo "== the same program with optimisation on (--release)"
build_and_run "release" exercise-time-release "$REPO/bench/std_time_exercise.iyi" --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/exercise-time-release.out" 2>/dev/null; then
  echo "  release: missing pass sentinel"
  sed -n '1,15p' "$WORK/exercise-time-release.out" 2>/dev/null | sed 's/^/    /'
  status=1
else
  echo "  every check passed with --release too"
fi

echo
echo "== every time check reported"
for check in "known-value table" "leap-year rules" "scattered roundtrip" "platform clocks" "span construction" "RFC 3339" "time comparison" "hash keys" "strftime directives" "format round-trips" "RFC 9110 date forms" "parse refusals" "ISO weeks and month arithmetic" "== locations" "times in a location" "wall clocks in a location" "Windows zone information" "ALL CHECKS PASSED"; do
  if ! grep -q "$check" "$WORK/exercise-time.out" 2>/dev/null; then
    echo "  MISSING: $check"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  known-value table, leap-year rules, roundtrip, clocks, spans, RFC 3339, Comparable, hash keys, directives, round trips, HTTP dates, refusals, ISO weeks, month arithmetic, locations and Windows zones all reported"

# ---------------------------------------------------------------------------
# Negative failure proofs
# ---------------------------------------------------------------------------

echo
echo "== negative proof: broken leap-year rule is caught"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched_leap/std"
  cp "$REPO/src/std/time.iyi" "$WORK/patched_leap/std/time.iyi"
  "$PY" -c "
with open('$WORK/patched_leap/std/time.iyi') as f:
    content = f.read()
broken = content.replace('|| (year % 400 == 0)', '&& false')
with open('$WORK/patched_leap/std/time.iyi', 'w') as f:
    f.write(broken)
"
  if (IYI_PATH="$WORK/patched_leap${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_time_exercise.iyi" >"$WORK/leap-fail.out" 2>&1); then
    echo "  the exercise PASSED with a broken leap-year rule (it should have failed):"
    head -15 "$WORK/leap-fail.out" | sed 's/^/    /'
    status=1
  else
    leap_exit=$?
    echo "  the broken leap-year rule was caught (exit $leap_exit)"
  fi
fi

echo
echo "== negative proof: broken civil roundtrip is caught"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched_rt/std"
  cp "$REPO/src/std/time.iyi" "$WORK/patched_rt/std/time.iyi"
  "$PY" -c "
with open('$WORK/patched_rt/std/time.iyi') as f:
    content = f.read()
broken = content.replace('def to_unix : Int64\n    @seconds', 'def to_unix : Int64\n    @seconds + 1_i64')
with open('$WORK/patched_rt/std/time.iyi', 'w') as f:
    f.write(broken)
"
  if (IYI_PATH="$WORK/patched_rt${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_time_exercise.iyi" >"$WORK/rt-fail.out" 2>&1); then
    echo "  the exercise PASSED with broken roundtrip (it should have failed):"
    head -15 "$WORK/rt-fail.out" | sed 's/^/    /'
    status=1
  else
    rt_exit=$?
    echo "  the broken civil roundtrip was caught (exit $rt_exit)"
  fi
fi

echo
echo "== negative proof: broken RFC 3339 timezone offset is caught"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched_tz/std"
  cp "$REPO/src/std/time.iyi" "$WORK/patched_tz/std/time.iyi"
  "$PY" -c "
with open('$WORK/patched_tz/std/time.iyi') as f:
    content = f.read()
broken = content.replace('utc_sec = local_sec - offset_sec', 'utc_sec = local_sec')
with open('$WORK/patched_tz/std/time.iyi', 'w') as f:
    f.write(broken)
"
  if (IYI_PATH="$WORK/patched_tz${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_time_exercise.iyi" >"$WORK/tz-fail.out" 2>&1); then
    echo "  the exercise PASSED with broken timezone offset handling (it should have failed):"
    head -15 "$WORK/tz-fail.out" | sed 's/^/    /'
    status=1
  else
    tz_exit=$?
    echo "  the broken RFC 3339 timezone offset was caught (exit $tz_exit)"
  fi
fi

# Each of these breaks one part of `Time::Format` in a copy of the module
# and proves the exercise fails against it. The copy is compared with the
# original first: a replacement that matches nothing would leave the module
# whole, and the proof would pass while proving nothing.
format_break_caught() { # format_break_caught <label> <name> <old> <new>
  local label="$1" name="$2"
  if [ -z "$PY" ]; then
    echo "  $label: skipped, no working python3 to make the broken copy"
    return
  fi
  mkdir -p "$WORK/patched_$name/std"
  OLD="$3" NEW="$4" SRC="$REPO/src/std/time.iyi" DST="$WORK/patched_$name/std/time.iyi" "$PY" -c "
import os
content = open(os.environ['SRC']).read()
old = os.environ['OLD']
if content.count(old) != 1:
    raise SystemExit('the text to break is in std/time %d times, not once: %r' % (content.count(old), old))
open(os.environ['DST'], 'w').write(content.replace(old, os.environ['NEW']))
" || { echo "  $label: the broken copy could not be made"; status=1; return; }
  if (IYI_PATH="$WORK/patched_$name${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_time_exercise.iyi" >"$WORK/$name-fail.out" 2>&1); then
    echo "  $label: the exercise PASSED against the broken copy (it should have failed)"
    status=1
  else
    echo "  $label: caught ($(grep -m1 -o 'ASSERTION FAILED: .\{0,90\}' "$WORK/$name-fail.out" || sed -n '1p' "$WORK/$name-fail.out"))"
  fi
}

echo
echo "== negative proofs: broken parts of Time::Format are caught"
format_break_caught "a month name read one month early" month_name \
  '    @month = index + 1' '    @month = index'
format_break_caught "an offset written the wrong way" format_offset \
  'local = time.seconds + @offset.to_i64' 'local = time.seconds - @offset.to_i64'
format_break_caught "an offset read the wrong way" parse_offset \
  '                    wall - offset.to_i64
                  elsif location' '                    wall + offset.to_i64
                  elsif location'
format_break_caught "text after the pattern accepted" trailing \
  'return true if @pos >= @len
        fail("unexpected text after the time")' 'return true'
format_break_caught "RFC 850's two-digit year read without RFC 9110's rule" recent_year \
  'year > now + 50_i64 ? year - 100_i64 : year' 'year'
format_break_caught "a day the month does not have accepted" month_day \
  'if @day < 1 || @day > last' 'if @day < 1'
format_break_caught "an ISO week counted from the wrong Monday" iso_week \
  'week = (day_of_year - day_of_week + 10) // 7' 'week = (day_of_year - day_of_week + 11) // 7'
format_break_caught "the afternoon an hour short" twelve_hour \
  'hour += 12 unless hour == 12' 'hour += 11 unless hour == 12'

echo
echo "== negative proofs: broken parts of Time::Location are caught"
format_break_caught "a rule's Sunday counted from the wrong weekday" rule_weekday \
  'weekday = Time.floor_mod(first + 4_i64, 7_i64)' 'weekday = Time.floor_mod(first + 3_i64, 7_i64)'
format_break_caught "a TZif footer passed over" footer \
  'if width == 8 && stop < size && p[stop] == 10_u8' 'if false'
format_break_caught "the version 2 block read where version 1's is" version_two \
  '      at = 44 + first
' '      at = 0
'
format_break_caught "a 32-bit word read unsigned" signed_word \
  'value = u32(p, at)
    value >= 2147483648_i64 ? value - 4294967296_i64 : value' 'value = u32(p, at)
    value'
format_break_caught "a header's counts trusted" header_counts \
  'return nil if count > 1000000_i64 ||' 'return nil if false ||'
format_break_caught "a repeated wall time read as the later instant" resolve_earlier \
  'best = candidate if lookup_range(candidate)[0].offset == offset && candidate < best' 'best = candidate if lookup_range(candidate)[0].offset == offset && candidate > best'
format_break_caught "a day shifted by 24 hours rather than on the wall clock" shift_wall \
  'moved = Time.new(@location.resolve(date), @nanoseconds, @location)' 'moved = Time.new(date - @offset.to_i64, @nanoseconds, @location)'
# Issue #133: Windows' Bias is a signed LONG, and Turkey's -180 read
# unsigned is 4294967116, which `Location.local` panicked on.
format_break_caught "a Windows bias read unsigned" windows_bias \
  '(p[at + 3].to_i64 << 24)
    value >= 2147483648_i64 ? value - 4294967296_i64 : value' '(p[at + 3].to_i64 << 24)
    value'

echo
echo "== locations against the machine's own zone database"
# Python's zoneinfo reads the same TZif files with code of its own, so a
# difference is a reading of the files, not of the data. For each zone: the
# offset, abbreviation and summer flag at 3,000 instants from 1800 to 2140
# and at every hour of 2024 and 2099 - the last read from the footer's rule
# - and the instant each of those hours, half past, reads as on the wall
# clock, which is Python's `fold=0`. The zones are chosen for what they
# hold: half-hour and 45-minute offsets, a 30-minute summer, a summer
# that spans New Year, negative summer time, a skipped day.
zones="Europe/Berlin America/New_York Australia/Sydney Australia/Lord_Howe Asia/Kolkata America/Sao_Paulo Pacific/Apia Africa/Casablanca Europe/Dublin Pacific/Chatham America/St_Johns Europe/Istanbul Asia/Tehran UTC Etc/GMT+5"
if [ -z "$PY" ] || ! "$PY" -c 'import zoneinfo; zoneinfo.ZoneInfo("Europe/Berlin")' >/dev/null 2>&1 || [ ! -f /usr/share/zoneinfo/Europe/Berlin ]; then
  echo "  skipped: this machine has no zone database, or no Python zoneinfo to read it with"
else
  cat >"$WORK/zones.iyi" <<'IYI'
module zones
import std/time::{Time, Location}

Program.args.each do |name|
  loc = Location.load(name).or_panic
  seed = 12345_i64
  3000.times do
    seed = (seed * 1103515245_i64 + 12345_i64) % 2147483648_i64
    unix = -5364662400_i64 + seed * 5_i64
    z = loc.lookup(unix)
    puts "#{name} at #{unix} #{z.offset} #{z.name} #{z.dst?}"
  end
  [2024, 2099].each do |year|
    start = Time.utc(year, 1, 1).to_unix
    h = 0_i64
    while h < 8784_i64
      unix = start + h * 3600_i64
      z = loc.lookup(unix)
      puts "#{name} at #{unix} #{z.offset} #{z.name} #{z.dst?}"
      wall = Time.unix(unix + 1800_i64)
      local = Time.local(wall.year, wall.month, wall.day, wall.hour, wall.minute, wall.second, location: loc)
      puts "#{name} wall #{wall.year}-#{wall.month}-#{wall.day} #{wall.hour}:#{wall.minute} #{local.to_unix} #{local.hour}:#{local.minute}"
      h = h + 1_i64
    end
  end
end
IYI
  cat >"$WORK/zones.py" <<'PY'
import sys
from datetime import datetime, timezone, timedelta
from zoneinfo import ZoneInfo
epoch = datetime(1970, 1, 1, tzinfo=timezone.utc)
for name in sys.argv[1:]:
    z = ZoneInfo(name)
    def at(unix):
        l = (epoch + timedelta(seconds=unix)).astimezone(z)
        print(f"{name} at {unix} {int(l.utcoffset().total_seconds())} {l.tzname()} {'true' if l.dst() else 'false'}")
    seed = 12345
    for _ in range(3000):
        seed = (seed * 1103515245 + 12345) % 2147483648
        at(-5364662400 + seed * 5)
    for year in (2024, 2099):
        start = int(datetime(year, 1, 1, tzinfo=timezone.utc).timestamp())
        for h in range(8784):
            unix = start + h * 3600
            at(unix)
            w = datetime(1970, 1, 1) + timedelta(seconds=unix + 1800)
            inst = int(w.replace(tzinfo=z).timestamp())
            back = (epoch + timedelta(seconds=inst)).astimezone(z)
            print(f"{name} wall {w.year}-{w.month}-{w.day} {w.hour}:{w.minute} {inst} {back.hour}:{back.minute}")
PY
  if ! "$IYI" build --release -o "$WORK/zones" "$WORK/zones.iyi" >"$WORK/zones.build.log" 2>&1; then
    echo "  the zone reader did not build:"; tail -5 "$WORK/zones.build.log" | sed 's/^/    /'
    status=1
  else
    "$WORK/zones" $zones >"$WORK/zones.iyi.out" 2>&1
    "$PY" "$WORK/zones.py" $zones >"$WORK/zones.py.out" 2>&1
    if cmp -s "$WORK/zones.iyi.out" "$WORK/zones.py.out"; then
      echo "  $(wc -l <"$WORK/zones.iyi.out" | tr -d ' ') offsets, abbreviations, summer flags and wall clocks over $(echo $zones | wc -w | tr -d ' ') zones agree with Python's zoneinfo"
    else
      echo "  std/time and Python's zoneinfo read the database differently:"
      diff "$WORK/zones.py.out" "$WORK/zones.iyi.out" | sed -n '1,8p' | sed 's/^/    /'
      status=1
    fi
  fi
fi

echo
echo "== the local zone, and the TZ variable, against the C library"
# glibc's `localtime` is the oracle for what `TZ` means: a name, a
# leading colon, a POSIX rule with each of its three day forms, a quoted
# name, a negative transition time, a negative summer, an offset alone,
# and no TZ at all, which is /etc/localtime. Two readings are left out on
# purpose, both glibc's own: a summer named without dates is the United
# States' since 2007 here, as in Go, where glibc falls back on an older
# table; and a rule whose summer runs all year (`J1/0,J365/25`) holds
# across New Year here, as RFC 8536 says, where glibc works out one year.
if [ "$(uname -s)" != Linux ] || [ -z "$PY" ]; then
  echo "  skipped: the oracle is glibc's localtime, read through Python, on Linux"
else
  cat >"$WORK/tzvar.iyi" <<'IYI'
module tzvar
import std/time::{Time, Location}

loc = Location.local
start = Time.utc(2024, 1, 1).to_unix
h = 0_i64
while h < 17568_i64
  unix = start + h * 3600_i64
  z = loc.lookup(unix)
  puts "#{unix} #{z.offset} #{z.name} #{z.dst?}"
  h = h + 1_i64
end
IYI
  cat >"$WORK/tzvar.py" <<'PY'
import time
start = 1704067200
for h in range(17568):
    l = time.localtime(start + h * 3600)
    print(f"{start + h * 3600} {l.tm_gmtoff} {l.tm_zone} {'true' if l.tm_isdst > 0 else 'false'}")
PY
  if ! "$IYI" build -o "$WORK/tzvar" "$WORK/tzvar.iyi" >"$WORK/tzvar.build.log" 2>&1; then
    echo "  the TZ reader did not build:"; tail -5 "$WORK/tzvar.build.log" | sed 's/^/    /'
    status=1
  else
    agreed=0
    for tz in "EST5EDT,M3.2.0,M11.1.0" "<+0330>-3:30" "CET-1CEST,M3.5.0,M10.5.0/3" "AEST-10AEDT,M10.1.0,M4.1.0/3" "XXX3YYY,J60/2,J300/2" "XXX3YYY,59/2,299/2" "IST-1GMT0,M10.5.0,M3.5.0/1" "<-03>3<-02>,M3.5.0/-2,M10.5.0/-1" ":Europe/Berlin" "Asia/Tokyo" "UTC0" "unset"; do
      if [ "$tz" = unset ]; then
        [ -f /etc/localtime ] || continue
        env -u TZ "$WORK/tzvar" >"$WORK/tzvar.iyi.out" 2>&1
        env -u TZ "$PY" "$WORK/tzvar.py" >"$WORK/tzvar.py.out" 2>&1
      else
        TZ="$tz" "$WORK/tzvar" >"$WORK/tzvar.iyi.out" 2>&1
        TZ="$tz" "$PY" "$WORK/tzvar.py" >"$WORK/tzvar.py.out" 2>&1
      fi
      if cmp -s "$WORK/tzvar.iyi.out" "$WORK/tzvar.py.out"; then
        agreed=$((agreed + 1))
      else
        echo "  TZ=$tz is read differently from glibc:"
        diff "$WORK/tzvar.py.out" "$WORK/tzvar.iyi.out" | sed -n '1,6p' | sed 's/^/    /'
        status=1
      fi
    done
    echo "  $agreed TZ settings read as glibc reads them, every hour of 2024 and 2025"
  fi
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
  printf 'module main\n\nimport std/time::{Time, Span, DayOfWeek}\n\nputs (%s).to_s\n' "$expression" > "$WORK/$name.iyi"
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
# A millisecond and a nanosecond past one second between them carried into
# the next second, day and year in silence.
time_panics_with "a fraction past one second" utc_frac "invalid millisecond + nanosecond: 999 ms and 999999999 ns are past one second" \
  'Time.utc(2024, 12, 31, 23, 59, 59, 999, 999999999).to_rfc3339(9)'
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
# A designator of several bytes is named whole: its lead byte alone, as a
# character of its own, was `Â` for `²`.
time_panics_with "milliseconds past an Int64" unix_ms_far "is past the milliseconds an Int64 holds" \
  'Time.utc(300000000, 1, 1).to_unix_ms'
time_panics_with "a designator of two bytes" parse_tz_utf8 "invalid timezone designator in RFC 3339: ²" \
  'Time.parse_rfc3339("2024-02-29T12:30:45²Z").to_rfc3339'
# The 808 milliseconds above Int64::MIN answer now; the one below it is
# still refused.
time_panics_with "the millisecond below Int64::MIN" unix_ms_min "-9223372036854776 seconds from the epoch is past the milliseconds an Int64 holds" \
  'Time.unix(-9223372036854776_i64, 191999999).to_unix_ms'
time_panics_with "a year past Int32, parsed" parse_y2g "year out of range in RFC 3339 string" \
  'Time.parse_rfc3339("2147483648-01-01T00:00:00Z").to_rfc3339'
time_panics_with "a year past Int32, from the epoch" unix_1e17 "year out of range" \
  'Time.unix(100000000000000000_i64).to_rfc3339'
time_panics_with "the last Int64 second" unix_max "year out of range" \
  'Time.unix(9223372036854775807_i64).year'
time_panics_with "the first Int64 second" unix_min "year out of range" \
  'Time.unix(-9223372036854775808_i64).to_rfc3339'
# A refusal after the carry names the count after it: it named the count
# before, a second the module had just accepted.
time_panics_with "the last second's last nanosecond and one more" max_carry "year out of range: 67767976233532800 seconds from the epoch" \
  '(Time.unix(67767976233532799_i64, 999999999) + Span.nanoseconds(1_i64)).to_rfc3339'
time_panics_with "a span sum past Int64" span_add "Span overflows" \
  'Span.seconds(9223372036854775807_i64) + Span.seconds(1_i64)'
time_panics_with "a day count past Int64 seconds" span_days "Span overflows" \
  'Span.days(106751991167301_i64)'
time_panics_with "the negation of the smallest span" span_neg "Span overflows" \
  '-Span.seconds(-9223372036854775808_i64)'
time_panics_with "a time plus a span past Int64" time_add "Span overflows" \
  'Time.utc(2024, 1, 1) + Span.seconds(9223372036854775807_i64)'
# The program's own mistakes in `Time::Format` panic, as the constructor's
# do: an offset of a day or more, a week the year does not have, an offset
# RFC 3339 cannot write, a shift past the years an Int32 holds. Bad text is
# not among them: that is a `TimeParseError`, which the exercise checks.
time_panics_with "an offset of a day" offset_day "offset out of range: 86400 seconds is a day or more from UTC" \
  'Time.utc(2024, 1, 1).to_s("%F", 86400)'
time_panics_with "a week the year does not have" week53 "invalid week: 2024 has weeks 1 to 52, not 53" \
  'Time.week_date(2024, 53, 1)'
time_panics_with "an RFC 3339 offset with seconds" rfc3339_seconds "an RFC 3339 offset is whole minutes, not 30 seconds" \
  'Time::Format::RFC_3339.format(Time.utc(2024, 1, 1), 0, 30)'
time_panics_with "a month past the last year" shift_far "year out of range: 2147483647-12-01T00:00:00Z shifted by 0 years and 1 months is in year 2147483648" \
  'Time.utc(2147483647, 12, 1).shift(months: 1)'
# And the one RFC 3339 allows that the constructor does not: a leap second
# is read as the second after 59, not refused.
printf 'module main\n\nimport std/time::{Time}\n\nputs Time.parse_rfc3339("2016-12-31T23:59:60Z").to_rfc3339\n' > "$WORK/leap.iyi"
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
# `environ` is the C runtime's table of the environment, which `Location`
# reads for TZ and ZONEINFO through the prelude as std/env does
# (bench/dependency_floor.sh allows it for the same reason); it is a
# symbol of the libc already linked, not a library.
case "$(uname -s)" in
  Linux)
    allowed_symbols="$FLOOR_BASE_LINUX environ"
    if ! command -v readelf >/dev/null 2>&1; then
      echo "  readelf is required on Linux to read NEEDED entries" >&2
      exit 2
    fi
    ;;
  *)
    # The base is every darwin program's (bench/floor_base.sh); the socket
    # and file names beside it are what this exercise's binary asks for on
    # top, each libSystem's, which the `allowed_libs` check below proves.
    # `fstat64` is the runtime's read asking whether standard input is a
    # regular file, which a socket's read shares the code of.
    allowed_symbols="$FLOOR_BASE_DARWIN accept bind chmod close connect environ fstat64 getsockname listen open recv send setsockopt socket unlink"
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
