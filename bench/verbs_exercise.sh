#!/usr/bin/env bash
# What the commands say when they refuse - SPEC.md III.1, and the identity
# `bench/identity_floor.py` keeps.
#
#     bash bench/verbs_exercise.sh
#
# Every case here is a mistake a person makes at the command line, and the
# claim is the same for all of them: the answer is a sentence naming what
# was asked for, not a stack trace out of the compiler's own guts. Nine
# defects this file was written for, each found by trying it:
#
#   * `iyi daemon start --socket <a path longer than the kernel takes>` died
#     with "Path size exceeds the maximum size of 107 bytes (ArgumentError)"
#     and a backtrace through `src/socket/address.cr` - a file the author
#     never opened, about a socket they did ask for.
#   * A `.iyi` file of unreadable bytes was reported as "not a valid Crystal
#     source file", which names the other language for this one's file.
#   * `-o nodir/prog` reached `ld.lld` and came back as "cannot open output
#     file", from a program the author did not run, after a whole
#     compilation had been paid for.
#   * `iyi daemon start --socket <too long>` on a machine with no
#     single-threaded server binary answered with a page about `make
#     iyi-daemon`: the server was looked for before the path was read, so
#     the refusal named the machine's missing binary rather than the
#     argument the author had typed wrong.
#   * `iyi doc` on a `.iyi` of unreadable bytes printed "Unhandled
#     exception ... (InvalidByteSequenceError)", twelve frames of this
#     compiler's own files, and an invitation to open an issue against the
#     *other* language: the guard the entry file has had since the line
#     above was written was never on the import path, and a `raise` inside
#     a rescue clause carried every filesystem error past the handler too.
#   * `iyi doc deep/inner/thing.iyi` printed `module thing` and an empty
#     surface, exit 0, for a module that exports a documented function: the
#     name came from the file's basename rather than from its header.
#   * `iyi doc` on a module that does not compile answered `while importing
#     "X"` - the wrapper, never the diagnostic inside it.
#   * `iyi migrate` rewrote bytes that are not text as U+FFFD and reported
#     `2 files -> 2 modules`, exit 0. A migration copies bytes.
#   * `iyi migrate tree --out --check` created a directory named `--check`
#     and exited 0; `mod dump FILE --json` printed prose and exited 0. A
#     flag missing its value ate the next flag, and a flag after the path
#     was dropped on the floor.
#
# So each case asserts three things: a non-zero exit, a phrase that names the
# thing, and *no* trace - no "Unhandled exception", no "(SomeError)" tail, no
# "from /.../src/" frame. The trace detector is proved against a recording of
# the daemon crash at the end, because a check that cannot fail is not a
# check.
#
# Exits non-zero if any case fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0

# A Crystal-level exception reaching the user, in the three shapes it takes.
has_trace() { # has_trace <file>
  grep -qE "Unhandled exception|^ +from .+\.cr:[0-9]+|\([A-Z][A-Za-z]*Error\)$" "$1"
}

refuses() { # refuses <label> <phrase> -- <command...>
  local label="$1" phrase="$2"
  shift 3
  "$@" > "$WORK/out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: exited 0, so nothing was refused"
    status=1
    return
  fi
  # `-- "$phrase"`: a refusal about a flag begins with one, and `grep -qF`
  # read `--out takes a directory` as its own options and failed the case
  # it was asked to check.
  if ! grep -qF -- "$phrase" "$WORK/out"; then
    echo "  $label: refused, but not with \"$phrase\""
    sed -n '1,3p' "$WORK/out"
    status=1
    return
  fi
  if has_trace "$WORK/out"; then
    echo "  $label: refused with a stack trace rather than a sentence"
    sed -n '1,3p' "$WORK/out"
    status=1
    return
  fi
  printf '  %s: exits %s, "%s"\n' "$label" "$code" \
    "$(grep -m1 -oF -- "$phrase" "$WORK/out")"
}

cd "$WORK"
printf 'module main\n\nputs "ok"\n' > good.iyi
printf 'module main\n\nmodule second\n\nputs "two"\n' > twoheaders.iyi
# Bytes that are not UTF-8 at all, rather than a random draw that might be.
printf '\377\376\377\376' > binary.iyi
mkdir -p app mods
printf 'module app/lib\n\npub def value : Int32\n  7\nend\n' > app/lib.iyi
printf 'module main\n\nimport app/lib\nusing app/lib::{value}\n\nputs value\n' > user.iyi
printf '# A comment, and then nothing that declares a module.\nputs "hi"\n' > nomodule.iyi
mkdir -p tree
printf 'class Ok\nend\n' > tree/ok.cr
printf 'class X\n\377\376\377\376\nend\n' > tree/bad.cr

echo "== the good path, first"
if "$IYI" build --emit-iyimod mods -o user user.iyi > build.log 2>&1 && [ "$(./user)" = "7" ]; then
  echo "  a program builds, writes its artifact, and runs"
else
  echo "  the good path does not hold"
  sed -n '1,8p' build.log
  status=1
fi
cp mods/app/lib.iyimod lib.good

echo
echo "== what the command line refuses"
refuses "an unknown verb" "unknown command" -- "$IYI" frobnicate
refuses "an unknown flag" "Invalid option" -- "$IYI" build --nonesuch good.iyi
refuses "a file that is not there" "no such file" -- "$IYI" run "$WORK/nope.iyi"
refuses "a directory as the entry" "no such file" -- "$IYI" run "$WORK"
refuses "two module headers in one file" "a file declares one module" -- "$IYI" run twoheaders.iyi
refuses "bytes that are not text" "not a valid iyi source file" -- "$IYI" run binary.iyi
refuses "an output directory that is not there" "there is no" -- \
  "$IYI" build -o "$WORK/nodir/prog" good.iyi

echo
echo "== what a damaged artifact says"
head -c 40 lib.good > mods/app/lib.iyimod
refuses "a truncated artifact, dumped" "is truncated" -- "$IYI" mod dump mods/app/lib.iyimod
refuses "a truncated artifact, imported" "cannot be read as" -- \
  "$IYI" build --use-iyimod mods -o u2 user.iyi
cp lib.good mods/app/lib.iyimod
printf 'X' | dd of=mods/app/lib.iyimod bs=1 seek=60 conv=notrunc status=none
refuses "a flipped byte, dumped" "checksum does not match" -- "$IYI" mod dump mods/app/lib.iyimod
cp lib.good mods/app/lib.iyimod
refuses "a source file dumped as an artifact" "is not a .iyimod" -- "$IYI" mod dump user.iyi
refuses "an artifact directory that is not there" "needs a directory of .iyimod files" -- \
  "$IYI" build --use-iyimod "$WORK/nodir" -o u3 user.iyi

echo
echo "== what the daemon refuses"
long="$WORK/$(printf 'd%.0s' $(seq 1 130))/iyi.sock"
refuses "a socket path past the kernel's limit, starting" "the socket path is" -- \
  "$IYI" daemon start --socket "$long"
# The same path, on a machine with no server binary to exec. `daemon start`
# on a multi-threaded compiler hands its arguments to the single-threaded
# one, and it used to go looking for that binary before it read them: a CI
# runner without `iyi-daemon` got a page about `make iyi-daemon` and no
# mention of the socket it had been given. IYI_DAEMON pointed at nothing
# stands in for that machine.
refuses "a socket path past the kernel's limit, with no server to exec" "the socket path is" -- \
  env IYI_DAEMON="$WORK/absent-daemon" "$IYI" daemon start --socket "$long"
# And the missing server is still named when the path is one the kernel
# takes, so the case above is an ordering rather than a blanket refusal.
refuses "a server binary that is not there" "IYI_DAEMON points at" -- \
  env IYI_DAEMON="$WORK/absent-daemon" "$IYI" daemon start --socket "$WORK/short.sock"
refuses "a socket path past the kernel's limit, building" "the socket path is" -- \
  "$IYI" daemon build --socket "$long" -o d1 good.iyi
refuses "no daemon on a socket that is there to take" "no daemon listening on" -- \
  "$IYI" daemon build --socket "$WORK/absent.sock" -o d2 good.iyi

echo
echo "== what the other verbs refuse, and what one of them prints"
# `doc`, `migrate`, `bind` and the rest of `mod` were never in this file,
# and every one of them failed the standard the verbs above hold to: `doc`
# on bytes that are not text answered "Unhandled exception ...
# (InvalidByteSequenceError)", a dozen frames of this compiler's own files
# and an invitation to file an issue against the other language; `doc` on a
# module below the search-path root printed an empty surface under a name
# that does not exist, at exit 0; `migrate` rewrote bytes that are not text
# as U+FFFD and said "2 files → 2 modules"; `--out --check` created a
# directory named `--check`; and `mod dump FILE --json` printed prose.
mkdir -p deep/inner
printf 'module deep/inner/thing\n\n# A thing.\npub def thing_value : Int32\n  5\nend\n' \
  > deep/inner/thing.iyi
printf 'module deep/inner/two\n\nmodule second\n\nputs "two"\n' > deep/inner/two.iyi
if [ "$("$IYI" doc deep/inner/thing.iyi | head -1)" = "module deep/inner/thing" ] &&
   "$IYI" doc deep/inner/thing.iyi | grep -q 'pub def thing_value : Int32'; then
  echo "  a module below the root documents itself, by the name it declares"
else
  echo "  doc answered with the wrong module, or with nothing:"
  "$IYI" doc deep/inner/thing.iyi | sed -n '1,3p'
  status=1
fi
if "$IYI" mod dump lib.good --json | head -1 | grep -q '^{'; then
  echo "  a flag after the path is read, not discarded"
else
  echo "  mod dump --json after the path did not print JSON:"
  "$IYI" mod dump lib.good --json | sed -n '1,2p'
  status=1
fi
# `mod context` read its flags only before the path too, and it is the verb
# a model calls: `mod context file.iyi --json` printed the text pack and
# exited 0, so whatever was reading the JSON found out somewhere else.
if "$IYI" mod context user.iyi --json | head -1 | grep -q '^{'; then
  echo "  the context pack's flag is read from either side of the path"
else
  echo "  mod context --json after the path did not print JSON:"
  "$IYI" mod context user.iyi --json | sed -n '1,2p'
  status=1
fi
refuses "doc on bytes that are not text" "not a valid iyi source file" -- \
  "$IYI" doc binary.iyi
refuses "doc on a file that declares no module" "declares no module" -- \
  "$IYI" doc nomodule.iyi
refuses "doc on a module that is not at its own path" "is read from" -- \
  "$IYI" doc twoheaders.iyi
refuses "doc on a module that does not compile" "a file declares one module" -- \
  "$IYI" doc deep/inner/two.iyi
mkdir -p adir.iyimod
refuses "doc on a directory" "is a directory" -- "$IYI" doc adir.iyimod
refuses "a second path after the artifact" "unexpected" -- \
  "$IYI" mod dump lib.good extra.iyimod
refuses "both of mod dump's outputs at once" "two different outputs" -- \
  "$IYI" mod dump --declarations --json lib.good
refuses "mod dump on a directory" "is a directory" -- "$IYI" mod dump adir.iyimod
mkdir -p adir.iyi
refuses "a second path after the module" "unexpected" -- \
  "$IYI" mod context user.iyi extra.iyi
refuses "an unknown flag to the context pack" "unknown flag" -- \
  "$IYI" mod context --nonesuch user.iyi
refuses "mod context on a directory" "is a directory" -- "$IYI" mod context adir.iyi
refuses "a tree with bytes that are not text" "not a valid Crystal source file" -- \
  "$IYI" migrate tree --out "$WORK/migrated"
refuses "a flag where --out's directory goes" "--check is a flag" -- \
  "$IYI" migrate tree --out --check
refuses "a flag where --mods' directory goes" "--mods takes a directory" -- \
  "$IYI" bind --mods --lib
# The refusal `migrate` was asked for is the one it did not write: nothing
# under `--out`, and no directory named after the flag.
if [ -e "$WORK/migrated" ] || [ -e "$WORK/--check" ]; then
  echo "  migrate wrote something while refusing"
  status=1
else
  echo "  a refused migration left nothing behind"
fi
# A file the process cannot read. `chmod 000` does not bite as root, which
# is what CI runs as, so the unreadable file here is the kernel's own:
# `/proc/self/mem` refuses a read at offset 0 for everybody.
if [ -r /proc/self/mem ]; then
  ln -sf /proc/self/mem unreadable.iyi
  refuses "a module the kernel will not hand over" "cannot be read" -- \
    "$IYI" doc unreadable.iyi
else
  echo "  a module the kernel will not hand over: no /proc here, nothing to drive"
fi

echo
echo "== proving the trace detector can fail"
# The daemon crash as it was, recorded. If `has_trace` stops recognising this,
# every case above stops checking the thing this file is about.
cat > recorded.txt <<'CRASH'
Path size exceeds the maximum size of 107 bytes (ArgumentError)
  from ?? in 'initialize'
  from /home/x/playground/iyi/src/socket/address.cr:839:5 in 'new'
CRASH
if has_trace recorded.txt; then
  echo "  the recorded crash is recognised as a trace"
else
  echo "  the recorded crash is not recognised, so the checks above prove nothing"
  status=1
fi
printf 'Error: the socket path is 147 bytes and the kernel takes 107\n' > sentence.txt
if has_trace sentence.txt; then
  echo "  a plain sentence is read as a trace, so the check is too wide"
  status=1
else
  echo "  a plain sentence is not a trace"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "Verbs: every refusal above names what was asked for, and none of them"
  echo "answers with a stack trace out of the compiler's own files."
else
  echo "the verbs do not hold"
fi
exit "$status"
