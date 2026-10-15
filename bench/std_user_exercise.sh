#!/usr/bin/env bash
# Exercises `std/user`.
#
#     bash bench/std_user_exercise.sh
#     GO=/path/to/go bash bench/std_user_exercise.sh
#
# The exercise checks what it can know on its own; this gate hands it what
# other programs answer for the same machine - Python's `pwd`, `grp`,
# `os.getuid` and `os.getgrouplist` for the current user, root, every
# account in /etc/passwd and every group in /etc/group, then `getent` and
# `id -G` - and when a Go toolchain runs, has Go's own pure-Go reader
# (`os/user/lookup_unix.go` and `listgroups_unix.go`, copied out of
# GOROOT and built as they are) answer the exercise's fixture files query
# for query. On patched copies of the module it points the lookups at the
# fixture, takes the uid away from the files to make `User.current` fall
# back, refuses a uid nobody can name, and proves that each check fails
# when the code it watches is broken.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
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

# The oracle and the negative proofs are python, and a machine can answer
# `python3` with a store stub that prints a refusal instead of running, so
# the interpreter is resolved once and proven to run before it is trusted.
# `pwd` and `grp` are POSIX-only modules, so they are proven too.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import pwd, grp' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

# Go the same way: a version manager's shim can answer `go` with a refusal
# when no version is selected, so it has to say its version first.
GO="${GO:-go}"
command -v "$GO" >/dev/null 2>&1 && "$GO" version >/dev/null 2>&1 || GO=""

LINUX=0
[ "$(uname -s)" = Linux ] && LINUX=1

# The exercise's current user is found in the files, and a broken module
# that never looks falls back to $USER: a shell started without one would
# make that proof a panic instead of a failed check.
[ -n "${USER:-}" ] || export USER="$(id -un 2>/dev/null)"

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"
EXERCISE="$REPO/bench/std_user_exercise.iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$EXERCISE" >"$WORK/$name.build.log" 2>&1; then
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
  if ! grep -q "ALL CHECKS PASSED" "$WORK/$name.out"; then
    echo "$label: missing pass sentinel"
    status=1
    return 1
  fi
  return 0
}

# What Python answers, one lookup a line, tab-separated, in the shape the
# exercise reads (`USER_EXPECT`): the current user with its groups; every
# name in /etc/passwd through `pwd.getpwnam` with `os.getgrouplist`, and
# every uid there through `pwd.getpwuid`; every group in /etc/group by
# name and by gid; and a name, a uid, a group and a gid Python proves
# nobody has. The names are read out of the files with Go's line rules,
# so a line the module skips is not asked for, and NSS answers what it
# answers for each: the module's answer must be the same. The last line
# of `$WORK/missing` is the uid nobody has, for the fallback below.
MISSING_UID=""
if [ -n "$PY" ]; then
  "$PY" - "$WORK/expect" "$WORK/missing" <<'PY'
import grp, os, pwd, sys

def rows(path, least):
    for line in open(path, encoding="utf-8", errors="surrogateescape"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split(":")
        if len(fields) < least or not fields[0] or fields[0][0] in "+-" or not fields[2].isdigit():
            continue
        yield fields

def user(p):
    return [p.pw_name, str(p.pw_uid), str(p.pw_gid), p.pw_gecos.split(",")[0], p.pw_dir, p.pw_shell]

# darwin's getgrouplist takes the gid as a C int, and `nobody`'s 4294967294
# overflowed it: passed as its signed self, every answer read back unsigned.
def groups(p):
    gid = p.pw_gid - (1 << 32) if p.pw_gid >= 1 << 31 else p.pw_gid
    return ",".join(str(g & 0xFFFFFFFF) for g in os.getgrouplist(p.pw_name, gid))

def group(g):
    return [g.gr_name, str(g.gr_gid), ",".join(g.gr_mem)]

def nobody(lookup, start):
    n = start
    while True:
        try:
            lookup(n)
        except KeyError:
            return n
        n += 1

out = []
me = pwd.getpwuid(os.getuid())
out.append(["current", ""] + user(me) + [groups(me)])
users = list(rows("/etc/passwd", 7))
for name in dict.fromkeys(f[0] for f in users):
    p = pwd.getpwnam(name)
    out.append(["user-name", name] + user(p) + [groups(p)])
for uid in dict.fromkeys(f[2] for f in users):
    out.append(["user-id", uid] + user(pwd.getpwuid(int(uid))))
listed = list(rows("/etc/group", 4))
for name in dict.fromkeys(f[0] for f in listed):
    out.append(["group-name", name] + group(grp.getgrnam(name)))
for gid in dict.fromkeys(f[2] for f in listed):
    out.append(["group-id", gid] + group(grp.getgrgid(int(gid))))
missing_uid = nobody(pwd.getpwuid, 4000000000)
for lookup, name in ((pwd.getpwnam, "iyi-no-such-user"), (grp.getgrnam, "iyi-no-such-group")):
    try:
        lookup(name)
        sys.exit("python found " + name)
    except KeyError:
        pass
out.append(["missing-user-name", "iyi-no-such-user"])
out.append(["missing-user-id", str(missing_uid)])
out.append(["missing-group-name", "iyi-no-such-group"])
out.append(["missing-group-id", str(nobody(grp.getgrgid, 4000000000))])
with open(sys.argv[1], "w") as f:
    for row in out:
        f.write("\t".join(row) + "\n")
with open(sys.argv[2], "w") as f:
    f.write("%d\n%d\n%d\n" % (len(users), len(listed), os.getgid()))
    f.write("%d\n" % missing_uid)
PY
  PY_USERS="$(sed -n 1p "$WORK/missing")"
  PY_GROUPS="$(sed -n 2p "$WORK/missing")"
  PY_GID="$(sed -n 3p "$WORK/missing")"
  MISSING_UID="$(sed -n 4p "$WORK/missing")"
fi

echo "== the std/user exercise, plain build"
build_and_run "plain" user-plain

echo
echo "== every user section reported"
# Windows answers the current user and nothing else by name or number
# (std/user's header), so the exercise asks those three only elsewhere.
if [ "$PSEP" = ';' ]; then
  sections=("== the fixture, as the parsers read it" "== another program agrees")
else
  sections=("== the current user" "== root" "== missing names and ids are nil"
    "== the fixture, as the parsers read it" "== another program agrees")
fi
for phrase in "${sections[@]}"; do
  if ! grep -q "$phrase" "$WORK/user-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" user-release --release >/dev/null && echo "  passed"

echo
echo "== Python agrees: pwd, grp, os.getuid and os.getgrouplist"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3 with pwd and grp"
else
  for build in plain release; do
    if USER_EXPECT="$WORK/expect" "$WORK/user-$build" >"$WORK/py-$build.out" 2>&1 \
       && grep -q "ALL CHECKS PASSED" "$WORK/py-$build.out"; then
      echo "  $build: $(grep -E '^  [0-9]+ lookups agree' "$WORK/py-$build.out" | sed 's/^  //'):" \
        "the current user, $PY_USERS passwd lines, $PY_GROUPS group lines, and four nobody has"
    else
      echo "  $build: disagrees with Python"
      sed 's/^/    /' "$WORK/py-$build.out" | sed -n '1,30p'
      status=1
    fi
  done
fi

echo
echo "== the system's own tools agree: getent passwd, getent group, id -G"
if [ "$LINUX" -eq 1 ] && command -v getent >/dev/null 2>&1 && command -v id >/dev/null 2>&1; then
  # `getent` asks NSS as glibc's `getpwuid` does, and `id -G NAME` lists
  # what `getgrouplist` answers for the account, primary group first; the
  # GECOS field is cut at its first comma as `full_name` is.
  me="$(id -un)"
  {
    getent passwd "$(id -u)" | awk -F: -v OFS='\t' -v groups="$(id -G "$me" | tr ' ' ',')" \
      '{ split($5, g, ","); print "current", "", $1, $3, $4, g[1], $6, $7, groups }'
    getent passwd 0 | awk -F: -v OFS='\t' '{ split($5, g, ","); print "user-id", "0", $1, $3, $4, g[1], $6, $7 }'
    # Every group /etc/group names, as `getent group` answers it.
    grep -E '^[^#+:-][^:]*:[^:]*:[0-9]+:' /etc/group | cut -d: -f1 | sort -u | while read -r name; do
      getent group "$name" | awk -F: -v OFS='\t' -v asked="$name" '{ print "group-name", asked, $1, $3, $4 }'
    done
  } >"$WORK/tools"
  if USER_EXPECT="$WORK/tools" "$WORK/user-plain" >"$WORK/tools.out" 2>&1 && grep -q "ALL CHECKS PASSED" "$WORK/tools.out"; then
    echo "  $me ($(id -u)), groups $(id -G "$me" | tr ' ' ','); root; $(grep -c '^group-name' "$WORK/tools") groups"
  else
    echo "  disagrees with the system's tools"
    sed 's/^/    /' "$WORK/tools.out" | sed -n '1,20p'
    status=1
  fi
else
  echo "  skipped: not Linux, or no getent/id"
fi

echo
echo "== Go's os/user reader answers the fixture as the module does"
# Go's own source, not a transcription of it: `lookup_unix.go` and
# `listgroups_unix.go` are the pure-Go reader every Go program built
# without cgo on Linux uses, and their `findUsername`, `findUserId`,
# `findGroupName`, `findGroupId` and `listGroupsFromReader` take an
# `io.Reader`, so the fixture is handed to them directly. `user.go` brings
# the types; `lookup.go`'s two path constants and the colon are written
# here, as that file carries the cgo-or-not dispatch too.
mkdir -p "$WORK/fixture"
if ! USER_FIXTURE_DIR="$WORK/fixture" "$WORK/user-plain" >"$WORK/fixture.out" 2>&1; then
  echo "  the exercise did not write its fixture"
  sed 's/^/    /' "$WORK/fixture.out"
  status=1
elif [ -z "$GO" ]; then
  echo "  skipped: no working go (GO=/path/to/go names one)"
else
  goroot="$("$GO" env GOROOT)"
  oracle="$WORK/go-oracle"
  mkdir -p "$oracle"
  for file in user.go lookup_unix.go listgroups_unix.go; do
    sed -e 's/^package user$/package main/' -e '/^\/\/go:build/d' "$goroot/src/os/user/$file" >"$oracle/$file" 2>/dev/null
  done
  printf 'module oracle\n\ngo 1.21\n' >"$oracle/go.mod"
  cat >"$oracle/main.go" <<'GO'
package main

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"strings"
)

const (
	userFile  = "/etc/passwd"
	groupFile = "/etc/group"
)

var colon = []byte{':'}

func read(path string) []byte {
	data, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	return data
}

// Each query and its answer, one a line, as the exercise's transcript
// writes them. An error is nil, as the module's nil covers both.
func main() {
	dir := os.Args[1]
	passwd, group := read(dir+"/passwd"), read(dir+"/group")
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	for _, q := range strings.Split(strings.TrimSuffix(string(read(dir+"/queries")), "\n"), "\n") {
		kind, value, _ := strings.Cut(q, " ")
		var err error
		switch kind {
		case "user-name", "user-id":
			var u *User
			if kind == "user-name" {
				u, err = findUsername(value, bytes.NewReader(passwd))
			} else {
				u, err = findUserId(value, bytes.NewReader(passwd))
			}
			if u == nil || err != nil {
				fmt.Fprintf(w, "%s -> nil\n", q)
				continue
			}
			fmt.Fprintf(w, "%s -> %s|%s|%s|%s|%s\n", q, u.Username, u.Uid, u.Gid, u.Name, u.HomeDir)
			if kind == "user-name" {
				ids, err := listGroupsFromReader(u, bytes.NewReader(group))
				if err != nil {
					panic(err)
				}
				fmt.Fprintf(w, "groups %s -> %s\n", value, strings.Join(ids, ","))
			}
		default:
			var g *Group
			if kind == "group-name" {
				g, err = findGroupName(value, bytes.NewReader(group))
			} else {
				g, err = findGroupId(value, bytes.NewReader(group))
			}
			if g == nil || err != nil {
				fmt.Fprintf(w, "%s -> nil\n", q)
				continue
			}
			fmt.Fprintf(w, "%s -> %s|%s\n", q, g.Name, g.Gid)
		}
	}
}
GO
  if ! (cd "$oracle" && CGO_ENABLED=0 GOFLAGS=-mod=mod "$GO" build -o oracle .) >"$WORK/go.build" 2>&1; then
    # A Go whose os/user no longer builds this way has moved the reader,
    # and the gate is what has to follow it; saying "skipped" would let the
    # comparison stop without anyone deciding it should.
    echo "  this Go's os/user sources do not build as the oracle ($("$GO" version)):"
    sed -n '1,6p' "$WORK/go.build" | sed 's/^/    /'
    status=1
  elif ! "$oracle/oracle" "$WORK/fixture" >"$WORK/go.transcript" 2>"$WORK/go.err"; then
    echo "  the Go oracle failed:"
    sed -n '1,6p' "$WORK/go.err" | sed 's/^/    /'
    status=1
  elif ! diff "$WORK/go.transcript" "$WORK/fixture/transcript" >"$WORK/go.diff"; then
    echo "  Go and the module answer the fixture differently (< Go, > iyi):"
    sed -n '1,20p' "$WORK/go.diff" | sed 's/^/    /'
    status=1
  else
    echo "  $(grep -c ' -> ' "$WORK/go.transcript") answers agree with $("$GO" version | cut -d' ' -f3)'s reader:" \
      "$(grep -c -- '-> nil' "$WORK/go.transcript") of them nil, for the lines both skip"
  fi
fi

# A copy of the module with each (old, new) pair applied once, every old
# text required to be in it exactly once, into $WORK/patched/std.
patch_copy() { # patch_copy <old> <new> [<old> <new> ...]
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  "$PY" - "$@" <<PY
import sys
from pathlib import Path
src = Path("$REPO/src/std/user.iyi").read_text()
pairs = sys.argv[1:]
for old, new in zip(pairs[0::2], pairs[1::2]):
    if src.count(old) != 1:
        raise SystemExit("patch site missing or not unique: " + old)
    src = src.replace(old, new, 1)
Path("$WORK/patched/std/user.iyi").write_text(src)
PY
}

patched_build=0
# Builds the exercise against the patched copy into $PATCHED_BIN, a binary
# of its own each time: on Windows the last one's file can still be held a
# moment after it ended, and a link over it fails.
build_patched() {
  patched_build=$((patched_build + 1))
  PATCHED_BIN="$WORK/patched-$patched_build.bin"
  IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" \
    "$IYI" build -o "$PATCHED_BIN" "$EXERCISE" >"$WORK/patched.build" 2>&1
}

# The lookups pointed at the fixture the exercise wrote: its passwd and
# group files read as /etc/passwd and /etc/group are.
FIXTURE_FILES=('PASSWD = "/etc/passwd"' "PASSWD = \"$WORK/fixture/passwd\""
  'GROUP  = "/etc/group"' "GROUP  = \"$WORK/fixture/group\"")
# The kernel's answer for the uid replaced by one nobody has.
NO_ACCOUNT=('uid = UserFiles.sys0(UserFiles::SYS_GETUID).to_u32' "uid = ${MISSING_UID:-4000000123}_u32")

echo
echo "== the lookups read the files as the parsers read them (patched copies that must pass)"
if [ "$LINUX" -eq 0 ] || [ -z "$PY" ] || [ ! -s "$WORK/fixture/passwd" ]; then
  echo "  skipped: the files are Linux's, and the copies are patched by python3"
else
  if ! patch_copy "${FIXTURE_FILES[@]}" || ! build_patched; then
    echo "  the fixture as the system's files: the patched copy did not build"
    sed -n '1,6p' "$WORK/patched.build"
    status=1
  elif USER_FIXTURE_SYSTEM=1 "$PATCHED_BIN" >"$WORK/system.out" 2>&1 && grep -q "ALL CHECKS PASSED" "$WORK/system.out"; then
    echo "  the fixture as /etc/passwd and /etc/group: $(grep -A1 '== the lookups, reading' "$WORK/system.out" | sed -n 2p | sed 's/^  //')"
  else
    echo "  the fixture as /etc/passwd and /etc/group: the lookups answer otherwise"
    sed 's/^/    /' "$WORK/system.out" | sed -n '1,12p'
    status=1
  fi
  # A uid the files do not have: the kernel's ids, $USER and $HOME, as
  # Go's pure-Go `Current` answers.
  printf 'current-fallback\t\tiyi-fallback\t%s\t%s\t\t/nonexistent/iyi-home\t\t%s\n' \
    "$MISSING_UID" "$PY_GID" "$PY_GID" >"$WORK/fallback.expect"
  if ! patch_copy "${NO_ACCOUNT[@]}" || ! build_patched; then
    echo "  a uid the files do not have: the patched copy did not build"
    sed -n '1,6p' "$WORK/patched.build"
    status=1
  elif USER=iyi-fallback HOME=/nonexistent/iyi-home USER_EXPECT="$WORK/fallback.expect" "$PATCHED_BIN" >"$WORK/fallback.out" 2>&1 \
       && grep -q "ALL CHECKS PASSED" "$WORK/fallback.out"; then
    echo "  uid $MISSING_UID, in no file: iyi-fallback, gid $PY_GID, home /nonexistent/iyi-home, from \$USER and \$HOME"
  else
    echo "  a uid the files do not have: did not fall back to \$USER and \$HOME"
    sed 's/^/    /' "$WORK/fallback.out" | sed -n '1,12p'
    status=1
  fi
fi

echo
echo "== what is refused, and the sentence it is refused with"
# A uid no file has and no \$USER to name it: a panic naming the uid,
# never a user made up.
if [ "$LINUX" -eq 0 ] || [ -z "$PY" ]; then
  echo "  skipped: the refusal is Linux's, and the copies are patched by python3"
else
  sentence="User.current: uid $MISSING_UID is not in /etc/passwd, and \$USER is not set to name it"
  for unset in unset empty; do
    if ! patch_copy "${NO_ACCOUNT[@]}" || ! build_patched; then
      echo "  no account, \$USER $unset: the patched copy did not build"
      sed -n '1,6p' "$WORK/patched.build"
      status=1
      continue
    fi
    if [ "$unset" = unset ]; then
      env -u USER "$PATCHED_BIN" >"$WORK/refuse.out" 2>&1
    else
      USER= "$PATCHED_BIN" >"$WORK/refuse.out" 2>&1
    fi
    if [ $? -eq 0 ]; then
      echo "  no account, \$USER $unset: answered instead of refusing"
      status=1
    elif ! grep -qxF "iyi: panic: $sentence" "$WORK/refuse.out"; then
      echo "  no account, \$USER $unset: refused with another sentence:"
      sed -n '1,3p' "$WORK/refuse.out" | sed 's/^/    /'
      status=1
    else
      echo "  no account, \$USER $unset: $sentence"
    fi
  done
fi

echo
echo "== proving the checks can fail when the module is broken"
mutations=0
# prove_broken <label> <phrase> <how> <old> <new> [<old> <new> ...]: <how>
# is `plain` (no oracle: the fixture through the parsers), `python`
# (Python's answers), `fixture` (the lookups reading the fixture) or
# `fallback` (a uid no file has, named by $USER).
prove_broken() {
  local label="$1" phrase="$2" how="$3"
  shift 3
  mutations=$((mutations + 1))
  local pairs=("$@")
  [ "$how" = fixture ] && pairs+=("${FIXTURE_FILES[@]}")
  [ "$how" = fallback ] && pairs+=("${NO_ACCOUNT[@]}")
  if ! patch_copy "${pairs[@]}"; then
    echo "  $label: the patch did not apply"
    status=1
    return
  fi
  # Build first, then run: a patch that does not compile would also
  # "fail", and that proves nothing about whether the exercise catches it.
  if ! build_patched; then
    echo "  $label: the broken copy did not compile"
    sed -n '1,6p' "$WORK/patched.build"
    status=1
    return
  fi
  case "$how" in
    python) USER_EXPECT="$WORK/expect" "$PATCHED_BIN" >"$WORK/mut.out" 2>&1 ;;
    fixture) USER_FIXTURE_SYSTEM=1 "$PATCHED_BIN" >"$WORK/mut.out" 2>&1 ;;
    fallback)
      USER=iyi-fallback HOME=/nonexistent/iyi-home USER_EXPECT="$WORK/fallback.expect" \
        "$PATCHED_BIN" >"$WORK/mut.out" 2>&1
      ;;
    *) "$PATCHED_BIN" >"$WORK/mut.out" 2>&1 ;;
  esac
  if [ $? -eq 0 ]; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  elif ! grep -qF -- "ASSERTION FAILED: $phrase" "$WORK/mut.out"; then
    echo "  $label: failed, but not at the check that names '$phrase':"
    sed -n '1,4p' "$WORK/mut.out" | sed 's/^/    /'
    status=1
  else
    echo "  $label: caught - $(grep -m1 'ASSERTION FAILED' "$WORK/mut.out" | sed 's/^iyi: panic: ASSERTION FAILED: //')"
  fi
}
if [ "$LINUX" -eq 0 ] || [ -z "$PY" ] || [ ! -s "$WORK/fixture/passwd" ]; then
  echo "  skipped: the patched code is Linux's, and the copies are patched by python3"
else
  # The whole GECOS field kept, commas and all.
  prove_broken "the GECOS field not cut" "full_name is the GECOS field's first part" plain \
    'comma ? gecos[0, comma] : gecos' 'gecos'
  # The line taken as it stands, blank space and all.
  prove_broken "a passwd line not trimmed" "a line with blank space around it is trimmed" plain \
    'line = raw.strip
    return nil if line.empty? || line.starts_with?('"'"'#'"'"')
    fields = line.split('"'"':'"'"')
    return nil if fields.size < 7' 'line = raw
    return nil if line.empty? || line.starts_with?('"'"'#'"'"')
    fields = line.split('"'"':'"'"')
    return nil if fields.size < 7'
  # NIS compat entries read as accounts.
  prove_broken "+name and -name lines kept" "a +name line is skipped" plain \
    "return nil if fields.size < 7
    name = fields[0]
    return nil if name.empty? || name.starts_with?('+') || name.starts_with?('-')" "return nil if fields.size < 7
    name = fields[0]
    return nil if name.empty?"
  # A comment read as a line when blank space comes before its `#`.
  prove_broken "an indented comment read" "an indented comment is a comment" plain \
    "return nil if line.empty? || line.starts_with?('#')
    fields = line.split(':')
    return nil if fields.size < 7" "return nil if line.empty?
    fields = line.split(':')
    return nil if fields.size < 7"
  # The shell cut at its first colon.
  prove_broken "the shell cut at a colon" "the shell is the rest of the line, colons and all" plain \
    'shell = fields.size == 7 ? fields[6] : fields[6, fields.size - 6].join(":")' 'shell = fields[6]'
  # The home and the shell swapped.
  prove_broken "home and shell swapped" "the shell is the seventh field" plain \
    'first_gecos(fields[4]), fields[5], shell)' 'first_gecos(fields[4]), shell, fields[5])'
  # An id past what uid_t holds cut to 32 bits, as a C cast would.
  prove_broken "a 33-bit uid cut to 32" "an id past 32 bits is nobody's" plain \
    'return nil if value > ID_MAX' 'value = value & ID_MAX if value > ID_MAX'
  # A group's empty member names kept.
  prove_broken "empty member names kept" "an empty member name is dropped" plain \
    "list.split(',').reject(&.empty?)" "list.split(',')"
  # A gid listed twice in group_ids.
  prove_broken "group_ids not held to one of each" "group_ids holds a gid once, primary first" plain \
    'ids << group.id if group.members.includes?(name) && !ids.includes?(group.id)' 'ids << group.id if group.members.includes?(name)'
  # The primary group left out of group_ids.
  prove_broken "the primary group left out" "group_ids starts with the primary group" plain \
    'def group_ids(groups : Array(Group)) : Array(String)
    ids = [group_id]' 'def group_ids(groups : Array(Group)) : Array(String)
    ids = [] of String'
  # find_by_id comparing the text it was handed, as Go does.
  prove_broken "an id compared as text" "an id is compared as a number" plain \
    "wanted = number.to_s
        found = nil
        UserFiles.each_line(UserFiles::PASSWD)" "wanted = id
        found = nil
        UserFiles.each_line(UserFiles::PASSWD)"
  # The last matching line kept, not the first.
  prove_broken "the last ada line kept" "the first ada line wins" fixture \
    "UserFiles.each_line(UserFiles::PASSWD) do |line|
          entry = parse_line(line)
          if entry && entry.name == name
            found = entry
            break" "UserFiles.each_line(UserFiles::PASSWD) do |line|
          entry = parse_line(line)
          if entry && entry.name == name
            found = entry"
  # A group lookup by id reading the passwd file.
  prove_broken "Group.find_by_id reading /etc/passwd" "the first group with an id wins" fixture \
    "wanted = number.to_s
        found = nil
        UserFiles.each_line(UserFiles::GROUP)" "wanted = number.to_s
        found = nil
        UserFiles.each_line(UserFiles::PASSWD)"
  # group_ids reading the passwd file for the groups.
  prove_broken "group_ids reading /etc/passwd" "current's group_ids is os.getgrouplist" python \
    'group_ids(Group.parse(UserFiles.read(UserFiles::GROUP) || ""))' 'group_ids(Group.parse(UserFiles.read(UserFiles::PASSWD) || ""))'
  # The effective lookup skipped: every current user the fallback.
  prove_broken "current never looked up" "current is find_by_id of its own id" plain \
    'return found if found' ''
  # The fallback's group id the uid.
  prove_broken "the fallback's gid the uid" "current falls back to the kernel's ids, \$USER and \$HOME" fallback \
    'User.new(name, uid.to_s, gid.to_s, "", ENV["HOME"]? || "", "")' 'User.new(name, uid.to_s, uid.to_s, "", ENV["HOME"]? || "", "")'
  echo "  $mutations mutations"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/user exercise holds"
else
  echo "the std/user exercise did not hold"
fi
exit $status
