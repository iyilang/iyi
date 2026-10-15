#!/usr/bin/env bash
# Exercises `std/mime`.
#
#     bash bench/std_mime_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# the patches and oracles below are written in python, and windows answers
# `python3` with a store stub that prints and exits rather than running it, so
# the interpreter is measured here instead of assumed.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from `pwd` is `/c/...` and finds no prelude at all, and a
# scratch directory named `/tmp/tmp.X` is silently ignored on that path, so
# the patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_mime_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
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

echo "== the std/mime exercise, plain build"
build_and_run "plain" mime-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/mime-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every mime section reported"
for phrase in "== round trip" "== names" "== parse" "== compressible" "== charset"; do
  if ! grep -q "$phrase" "$WORK/mime-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" mime-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/mime-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== what mime refuses"
# The table is fixed: there is no way to add to it, and the module reads
# no file, so it answers the same on every machine.
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/mime::{MIME}

MIME.register(".iyi", "text/x-iyi")
puts "accepted"
IYI
cat >"$WORK/malformed.iyi" <<'IYI'
module malformed

import std/mime::{MIME}

["text", "/html", "text/", "text/ht ml", "text/html; a", "text/html; a=\"open", "text/html; a = b"].each do |bad|
  puts "#{bad.inspect} -> #{MIME.parse?(bad).nil? ? "refused" : "ACCEPTED"}"
end
IYI
if "$IYI" run "$WORK/refuse.iyi" >"$WORK/refuse.out" 2>&1; then
  echo "  register was accepted"
  status=1
elif ! grep -qF "undefined method 'register'" "$WORK/refuse.out"; then
  echo "  register was refused without saying why: $(tr -d '\r' <"$WORK/refuse.out" | tail -1)"
  status=1
else
  echo "  register: no such method"
fi
if ! "$IYI" run "$WORK/malformed.iyi" >"$WORK/refuse.out" 2>&1 || grep -q ACCEPTED "$WORK/refuse.out" \
   || [ "$(grep -c refused "$WORK/refuse.out")" -ne 7 ]; then
  echo "  malformed media types were not all refused:"
  sed 's/^/    /' "$WORK/refuse.out"
  status=1
else
  echo "  seven malformed media types refused"
fi
if grep -nE '^\s*(lib|fun) |File\.|Dir\.|ENV' "$REPO/src/std/mime.iyi"; then
  echo "  the module reaches outside itself"
  status=1
else
  echo "  no file, environment or C binding in the module"
fi

echo
echo "== the table against Python's mimetypes"
# A fresh `mimetypes.MimeTypes()` is Python's built-in table and nothing
# else, so neither side reads the machine's. `mimetypes.init([])` was
# meant to be: but it reads the system's files anyway on a first call, and
# the registry on Windows, and darwin's /etc/apache2/mime.types answered
# 13 extensions differently. Every extension both know must agree, except the
# pairs below, each a deliberate choice: `.ext python-value` lines.
#   .tgz  application/x-gtar-compressed  a tgz is a gzip stream; Go, nginx
#                                        and browsers send application/gzip.
#   .wav  audio/x-wav                    audio/wav is what browsers and Go
#                                        send; x-wav is the pre-registration name.
#   .rs   application/rls-services+xml   RFC 4855's .rs is not Rust source,
#                                        which is what a web server meets.
#   .rss  application/x-rss+xml          application/rss+xml is what feeds
#                                        are sent as and browsers recognise.
#   .exe  application/x-msdos-program    IANA registered
#                                        application/vnd.microsoft.portable-executable.
# Older Pythons (before 3.12) answer these differently, and ours is the
# value they later adopted:
#   .js   application/javascript         RFC 9239 made it text/javascript.
#   .mjs  application/javascript
#   .xml  text/xml                       RFC 7303 prefers application/xml.
#   .mkv  video/x-matroska               registered as video/matroska.
# And newer Pythons (3.13, 3.14) moved these, each away from what servers
# send, so ours stays:
#   .vcf  text/x-vcard                   RFC 6350 registered text/vcard.
#   .c .h text/plain                     Apache and nginx name the language.
#   .rtf  text/rtf                       both are registered; application/rtf
#                                        is what servers send.
#   .wav  audio/vnd.wave                 RFC 2361's; browsers send audio/wav.
#   .opus audio/opus                     an .opus file is Ogg (RFC 7845 §9).
#   .m4v  video/x-m4v                    Apple's private name for MP4 video.
#   .avi  video/vnd.avi                  servers and browsers send x-msvideo.
#   .exe  application/octet-stream       IANA's portable-executable is kept.
ALLOWED='.tgz application/x-gtar-compressed
.wav audio/x-wav
.rs application/rls-services+xml
.rss application/x-rss+xml
.exe application/x-msdos-program
.js application/javascript
.mjs application/javascript
.xml text/xml
.mkv video/x-matroska
.vcf text/x-vcard
.c text/plain
.h text/plain
.rtf text/rtf
.wav audio/vnd.wave
.opus audio/opus
.m4v video/x-m4v
.avi video/vnd.avi
.exe application/octet-stream'
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the comparison is unmeasured"
elif ! "$WORK/mime-plain" table >"$WORK/table.txt" 2>&1; then
  echo "  the table did not print"
  status=1
elif ! ALLOWED="$ALLOWED" TABLE="$WORK/table.txt" "$PY" - <<'PY'
import mimetypes, os, sys
builtin = mimetypes.MimeTypes().types_map[True]
allowed = set(os.environ["ALLOWED"].splitlines())
bad = 0
both = 0
used = set()
for line in open(os.environ["TABLE"]):
    ext, ours = line.split()
    theirs = builtin.get(ext)
    if theirs is None:
        continue
    both += 1
    if theirs != ours:
        if f"{ext} {theirs}" in allowed:
            used.add(f"{ext} {theirs}")
            print(f"  {ext}: {ours} (python: {theirs}, allowed)")
        else:
            print(f"  {ext}: ours {ours}, python {theirs}")
            bad += 1
print(f"  {both} extensions compared, {bad} unexplained differences")
sys.exit(1 if bad else 0)
PY
then
  status=1
fi

echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <old> <new>: the exercise must fail on a
# copy of the module with <old> replaced, at the check that names <phrase>.
prove_broken() {
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $1 proof is unmeasured"
    return
  fi
  if ! OLD="$3" NEW="$4" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/mime.iyi").read_text()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/mime.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_mime_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on $1"
    status=1
  elif grep -qF "$2" "$WORK/mut.out"; then
    echo "  $1 is caught"
  else
    echo "  $1 failed, but not where it should have:"
    tail -2 "$WORK/mut.out" | sed 's/^/    /'
    status=1
  fi
}
# The lookup lowercases before it probes; without that `index.HTML`
# finds nothing.
prove_broken "a case-sensitive lookup" "upper dotted" \
  '    by_extension[lower(ext)]?' '    by_extension[ext]?'
# A backslash kept rather than undone in a quoted parameter.
prove_broken "a quoted value keeping its backslashes" "quoted with escapes" \
  "        at = at + 1 if bytes[at] == '\\\\'.ord.to_u8
" ''
# The name before the first dot rather than after the last.
prove_broken "the first extension of a multi-dot name" "multi-dot by last" \
  '      if b == '"'"'.'"'"'.ord.to_u8
        dot = i
        break
      end' '      dot = i if b == '"'"'.'"'"'.ord.to_u8'
prove_broken "a parameter without its equals sign accepted" 'refuses "text/html; charset"' \
  "      return nil if pos == name_start || pos >= size || bytes[pos] != '='.ord.to_u8" \
  "      return nil if pos == name_start
      return {essence, params} if pos >= size"
prove_broken "WOFF2 counted compressible" "font/woff2 not compressible" \
  '"font/ttf", "font/otf",' '"font/ttf", "font/otf", "font/woff2",'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/mime exercise holds"
else
  echo "the std/mime exercise did not hold"
fi
exit $status
