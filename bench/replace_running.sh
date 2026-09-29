#!/usr/bin/env bash
# Makefile.win puts a new binary in place while the old one runs: an editor
# with `iyi lsp` open holds `.build\iyi.exe`, and Windows will not move a
# file onto a running program ("Access is denied"). `REPLACE` renames the
# running one aside and moves the new one in.
#
#     bash bench/replace_running.sh
#
# Four steps, the last a failure proof:
#   1. A running copy of iyi (`iyi lsp`, waiting on its input) is replaced
#      through Makefile.win's own `REPLACE`: make exits 0, the file at the
#      name is the new one, and the session is still running.
#   2. The old file stepped aside under a name of its own.
#   3. Once nothing runs it, the next replacement deletes it.
#   4. Failure proof: the plain `move /Y` the Makefile used before, on the
#      same running program, fails.
# The macro is exercised through a target of its own (`make --eval`), so
# the proof costs no compiler build; `.build\iyi.exe`'s recipe calls the
# same macro.
set -u

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) ;;
  *) echo "replace running: a running binary can be unlinked here, so there is nothing to replace around; nothing to measure"; exit 0 ;;
esac

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/.build/iyi.exe}"
WORK="$(mktemp -d)"
status=0
step() { echo "== $1"; }

cp "$IYI" "$WORK/held.exe"
cp "$IYI" "$WORK/next.exe"
# A byte past the end: a different file with the same behaviour, so which
# one sits at the name afterwards is a checksum away.
printf 'x' >> "$WORK/next.exe"
next_sum="$(sha256sum "$WORK/next.exe" | cut -d' ' -f1)"
held_w="$(cygpath -w "$WORK/held.exe")"
next_w="$(cygpath -w "$WORK/next.exe")"

# The session: `iyi lsp` on a pipe nobody writes and nobody closes, which
# is an editor between keystrokes. `$!` is the pipeline's last process.
start_session() {
  sleep 600 | "$WORK/held.exe" lsp > "$WORK/$1" 2>&1 &
  session=$!
  feeder="$(jobs -p %%)"
  sleep 1
  if ! kill -0 "$session" 2>/dev/null; then
    echo "the session did not start:"; cat "$WORK/$1"
    exit 1
  fi
}

# Its input closed, which is how an editor ends one: `iyi lsp` exits at the
# end of its input. A signal from this shell does not reach a native
# program through its MSYS pid.
stop_session() {
  kill "$feeder" 2>/dev/null
  wait "$session" 2>/dev/null
}

# Until nothing holds the file: no process runs the image - the session's
# worker (`iyi lsp --worker`, started from the same file) exits on its own
# time after the session - and no handle is open on it, which a Windows
# runner's scanner keeps for a while after a rename: the file opens with
# no sharing at all. Thirty seconds for each at most, and what still
# holds the file when the wait gives up is said.
wait_unheld() {
  local path tries=0
  path="$(cygpath -w "$1")"
  while tasklist //FI "IMAGENAME eq held.exe" //NH 2>/dev/null | grep -q 'held.exe'; do
    if [ "$tries" -ge 300 ]; then
      echo "  after 30 s a held.exe still runs:"
      tasklist //FI "IMAGENAME eq held.exe" 2>&1 | sed 's/^/    /'
      break
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
  tries=0
  until powershell -NoProfile -Command "try { [IO.File]::Open('$path', 'Open', 'ReadWrite', 'None').Close(); exit 0 } catch { exit 1 }" >/dev/null 2>&1; do
    if [ "$tries" -ge 60 ]; then
      echo "  after 30 s the file still opens only shared: a handle is held on it"
      break
    fi
    sleep 0.5
    tries=$((tries + 1))
  done
}
start_session lsp.out

# $1 the REPLACE to use (empty: Makefile.win's own), $2 the new file.
replace() {
  local override="$1" source="$2"
  (cd "$REPO" && make -s -f Makefile.win ${override:+"$override"} \
    --eval 'replace_probe: ; $(call REPLACE,'"$source"','"$held_w"')' replace_probe) > "$WORK/make.out" 2>&1
}

step "a running program replaced through Makefile.win's REPLACE"
if replace "" "$next_w"; then
  if [ "$(sha256sum "$WORK/held.exe" | cut -d' ' -f1)" != "$next_sum" ]; then
    echo "  make exited 0 and the file at the name is not the new one"
    status=1
  elif ! kill -0 "$session" 2>/dev/null; then
    echo "  the new file is in place and the session it replaced under is gone"
    status=1
  else
    echo "  make exited 0, the new file is at the name, and the session still runs"
  fi
else
  echo "  make failed:"; sed 's/^/    /' "$WORK/make.out"
  status=1
fi

step "the old file stepped aside"
aside="$(ls "$WORK" | grep '^held\.exe\.old-' | head -1)"
if [ -z "$aside" ]; then
  echo "  no held.exe.old-* beside it"
  status=1
else
  echo "  $aside"
fi

step "and goes at the next replacement, once nothing runs it"
stop_session
[ -n "$aside" ] && wait_unheld "$WORK/$aside"
cp "$IYI" "$WORK/next.exe"
# Deleted is not gone at once: a file deleted while another handle has it
# open - one opened to allow deletion, as a scanner's is, and the probe's
# own open for writing is what asks the scanner in - stays under its name,
# delete-pending, until that handle closes. Found in CI, twice in a row
# with nothing holding the file when the wait above ended.
gone_soon() {
  local tries=0
  while [ -e "$1" ]; do
    [ "$tries" -ge 60 ] && return 1
    sleep 0.5
    tries=$((tries + 1))
  done
}
if replace "" "$next_w" && [ -n "$aside" ] && gone_soon "$WORK/$aside"; then
  echo "  $aside deleted"
else
  echo "  $aside is still there, or the replacement failed:"; sed 's/^/    /' "$WORK/make.out"
  # What holds it, asked the three ways a Windows file is held: a process
  # running an image from this directory, a handle that will not share, and
  # the delete's own sentence, which `REPLACE` sends to NUL.
  aside_w="$(cygpath -w "$WORK/$aside")"
  echo "    processes running from $WORK:"
  powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { \$_.ExecutablePath -like '$(cygpath -w "$WORK")\\*' } | ForEach-Object { '      ' + \$_.ProcessId + ' ' + \$_.ExecutablePath + ' ' + \$_.CommandLine }" 2>&1
  powershell -NoProfile -Command "try { [IO.File]::Open('$aside_w', 'Open', 'Read', 'None').Close(); '    it opens unshared now' } catch { '    it does not open unshared: ' + \$_.Exception.Message }" 2>&1
  echo "    the delete says: $(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" cmd /c del /F /Q "$aside_w" 2>&1 | tr -d "\r")"
  [ -e "$WORK/$aside" ] && echo "    and it is still there" || echo "    and now it is gone"
  status=1
fi

step "failure proof: the plain move onto a running program"
start_session lsp2.out
cp "$IYI" "$WORK/next.exe"
if replace 'REPLACE=move /Y "$1" "$2"' "$next_w"; then
  echo "  the plain move replaced a running program, so this gate proves nothing"
  status=1
else
  printf '  make fails: %s\n' "$(grep -m1 -i 'denied' "$WORK/make.out" | tr -d '\r')"
fi
stop_session

echo
if [ "$status" -eq 0 ]; then
  echo "replace running: every step held"
else
  echo "replace running: FAILED"
fi
exit "$status"
