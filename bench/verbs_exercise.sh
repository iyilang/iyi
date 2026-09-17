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
# The compiler, overridable: `bin/iyi` is a POSIX shell wrapper, and on
# Windows the caller is the only one who knows where the real binary is.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on the search path, so
# the patched copy is never read and the proof that a check can fail
# quietly stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac
trap 'rm -rf "$WORK"' EXIT

status=0

# A Crystal-level exception reaching the user, in the three shapes it takes.
has_trace() { # has_trace <file>
  grep -qE "Unhandled exception|^ +from .+\.cr:[0-9]+|\([A-Z][A-Za-z]*Error\)$" "$1"
}

refuses() { # refuses <label> <phrase> -- <command...>
  local label="$1" phrase="$2"
  shift 3
  # `< /dev/null`: none of these should read a line, and one of them —
  # `mcp`, which serves over stdin — would sit there waiting if the
  # refusal it is being checked for ever went missing. A gate that hangs
  # is worse than one that fails.
  "$@" > "$WORK/out" 2>&1 < /dev/null
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: exited 0, so nothing was refused"
    status=1
    return
  fi
  # `-- "$phrase"`: a refusal about a flag begins with one, and `grep -qF`
  # read `--out takes a directory` as its own options and failed the case
  # it was asked to check.
  #
  # Both sides are read with their separators folded to `/`: a phrase built
  # here out of `$WORK` carries this shell's `/`, while a path iyi prints is
  # the platform's, so on Windows a case whose refusal was exactly right
  # reported "refused, but not with ...". Folding changes nothing where the
  # separator already is `/`.
  if ! tr '\\' '/' < "$WORK/out" | grep -qF -- "$(printf '%s' "$phrase" | tr '\\' '/')"; then
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
# `help nonesuch` printed the whole usage and exited 0 - "yes, that is a
# command" - and `help build` did the same, as if the verb had no help of
# its own. `version extra` dropped the word.
refuses "help for a verb that is not one" "there is no" -- "$IYI" help nonesuch
refuses "version with an argument" "takes no arguments" -- "$IYI" version extra
if "$IYI" help build 2>/dev/null | head -1 | grep -q '^Usage: iyi build'; then
  echo "  help for a verb is the verb's own"
else
  echo "  help for a verb printed the general usage"; status=1
fi
# `repl` was a verb for a while: a session on the macro evaluator, which is
# the other language's compile-time library, so `"ab" * -3` answered
# "Negative argument" where this compiler says "negative count: -3". One
# name, two semantics. It was removed rather than taught the prelude, and
# this line is what keeps it removed.
refuses "the session that was removed" "unknown command" -- "$IYI" repl
refuses "an unknown flag" "Invalid option" -- "$IYI" build --nonesuch good.iyi
refuses "a file that is not there" "no such file" -- "$IYI" run "$WORK/nope.iyi"
# One sentence for one mistake, from every verb that takes a file: this was
# "no such file" about a path that is right there, so the reader ran `ls`,
# found it, and learned nothing. `gather_sources` is the one place they all
# come through, so `run`, `build`, `check` and `vet` answer alike.
refuses "a directory as the entry" "is a directory, not a source file" -- "$IYI" run "$WORK"
refuses "a directory where check wants a file" "is a directory" -- "$IYI" check "$WORK"
refuses "two module headers in one file" "a file declares one module" -- "$IYI" run twoheaders.iyi
refuses "bytes that are not text" "not a valid iyi source file" -- "$IYI" run binary.iyi
# A program that ran out of stack says so itself now - `iyi: panic: stack
# overflow`, from a handler on an alternate stack (bench/panics.sh holds
# it on every stack). What the kernel still kills, `iyi run` explains in
# iyi's words rather than relaying "Process terminated because of an
# invalid memory access" about a language with no null to dereference.
printf 'module deep\n\ndef down(n : Int32) : Int32\n  down(n + 1) + 1\nend\n\nputs down(0)\n' > deep.iyi
refuses "a program that ran out of stack" "stack overflow" -- "$IYI" run deep.iyi
printf 'module wild\n\np = Pointer(Int32).new(16_u64)\nputs p.value\n' > wild.iyi
refuses "a program the kernel killed" "died of a memory fault" -- "$IYI" run wild.iyi
refuses "an output directory that is not there" "there is no" -- \
  "$IYI" build -o "$WORK/nodir/prog" good.iyi

echo
echo "== what the verbs that were never here refuse"
# `fix`, `vet`, `env`, `clear_cache` and `mcp` had no case in this file, and
# each of them answered a mistake the way the gated verbs used to: `fix` on
# bytes that are not text exited 1 printing *nothing at all* (the compiler's
# refusal went into the buffer `fix` gives it and the process died silently);
# `fix` called a directory a missing file and an unknown flag a missing file,
# and dropped a second path at exit 0; `vet` with no file printed the usage
# of `iyi tool unreachable`, a command nobody typed; `iyi env NOPE` printed a
# blank line at exit 0, which reads as "set, and empty"; `clear_cache` and
# `mcp` swallowed whatever they were handed, `mcp` by starting a server the
# caller had not configured.
refuses "fix on bytes that are not text" "not a valid iyi source file" -- \
  "$IYI" fix binary.iyi
refuses "fix on a directory" "is a directory" -- "$IYI" fix "$WORK"
refuses "an unknown flag to fix" "unknown flag" -- "$IYI" fix --nonesuch good.iyi
refuses "a second file after fix's" "unexpected" -- "$IYI" fix good.iyi extra.iyi
# `.exe` off the end: the usage line names the command, and the command is
# the compiler's name without the suffix Windows puts on the file.
refuses "vet with no file" "Usage: $(basename "$IYI" .exe) vet" -- "$IYI" vet
refuses "a variable env does not have" "no such variable" -- "$IYI" env NOPE
refuses "an argument to clear_cache" "takes no arguments" -- "$IYI" clear_cache extra
refuses "an argument to the mcp server" "takes no arguments" -- "$IYI" mcp --nonesuch
# And the flag that was being dropped is read now, from either side.
if "$IYI" fix good.iyi --json | head -1 | grep -q '^{'; then
  echo "  fix reads --json after the file, too"
else
  echo "  fix --json after the file did not print JSON:"
  "$IYI" fix good.iyi --json | sed -n '1,2p'
  status=1
fi

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
# The artifact itself, where its directory goes: "there is no
# mods/app/lib.iyimod", about the file the author had just been looking at.
refuses "an artifact where --use-iyimod's directory goes" "is a file" -- \
  "$IYI" build --use-iyimod mods/app/lib.iyimod -o u4 user.iyi

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
# A flag with nothing behind it used to fall through to the default
# socket, so `iyi daemon build --socket` talked to whatever daemon was
# running in ~/.cache rather than the one the author meant to name. The
# three shapes below are the ones a shell produces: no value, the next
# flag read as a value, and a directory.
refuses "a --socket with no path, building" "--socket takes a path" -- \
  "$IYI" daemon build --socket
refuses "a --socket with no path, starting" "--socket takes a path" -- \
  "$IYI" daemon start --socket
refuses "the next flag read as a socket path" "is a flag" -- \
  "$IYI" daemon build --socket -o d3 good.iyi
mkdir -p "$WORK/sockdir"
refuses "a directory named as a socket, building" "is a directory, not a socket" -- \
  "$IYI" daemon build --socket "$WORK/sockdir" -o d4 good.iyi
refuses "a directory named as a socket, starting" "is a directory, not a socket" -- \
  "$IYI" daemon start --socket "$WORK/sockdir"
# A daemon that was killed leaves its socket file behind. "no daemon
# listening" is true and useless: a new daemon on that path answers
# "Address already in use" until the file goes, so the file is the thing
# to say.
: > "$WORK/stale.sock"
refuses "a stale socket file left by a dead daemon" "is a file, not a socket" -- \
  "$IYI" daemon build --socket "$WORK/stale.sock" -o d5 good.iyi

echo
echo "== where a program is written, and where its library is looked for"
# `-o ""` is what `-o "$OUT"` produces with `OUT` unset. It used to mean
# the current directory: the program landed beside its source under a
# name nobody typed, or the linker answered "cannot open output file
# <cwd>: Is a directory" - after a whole compilation had been paid for.
refuses "an empty -o" "-o takes a path" -- "$IYI" build -o "" good.iyi
# And every other place `"$VAR"` with `VAR` unset can land. Each answered
# with a hole where the name goes - `no such file: `, `no daemon listening
# on `, `Error:  is a directory` - or worse: `tool format ""` normalised to
# `./` and rewrote every source under the working directory, in place, and
# `check --affected ""` took the working directory as the changed file.
refuses "an empty file name" "the file name is empty" -- "$IYI" run ""
refuses "an empty --emit-iyimod" "--emit-iyimod takes a directory" -- \
  "$IYI" build --emit-iyimod "" -o p good.iyi
refuses "an empty --use-iyimod" "--use-iyimod takes a directory" -- \
  "$IYI" build --use-iyimod "" -o p good.iyi
refuses "an empty --prelude" "--prelude takes a file name" -- \
  "$IYI" build --prelude "" -o p good.iyi
refuses "an empty --affected, checking" "--affected takes a changed file" -- \
  "$IYI" check --affected ""
refuses "an empty --affected, testing" "--affected takes a changed file" -- \
  "$IYI" test --affected "" .
refuses "an empty test path" "'' is not one" -- "$IYI" test ""
refuses "an empty file for fix" "which file" -- "$IYI" fix ""
refuses "an empty .iyimod path" "expected a .iyimod path" -- "$IYI" mod dump ""
refuses "an empty --socket" "--socket takes a path" -- \
  "$IYI" daemon build --socket "" -o p good.iyi
mkdir -p "$WORK/tree"
printf 'x=1\n' > "$WORK/tree/messy.cr"
cp "$WORK/tree/messy.cr" "$WORK/tree.keep"
cd "$WORK/tree"
refuses "an empty path for format" "'' is not one" -- "$IYI" tool format ""
cd "$WORK"
cmp -s "$WORK/tree/messy.cr" "$WORK/tree.keep" ||
  { echo "  format \"\" rewrote the working directory"; status=1; }
# And the search path itself. `IYI_PATH=""` is a list with nothing in it,
# and the note read "Searched, in order:" followed by nothing.
env IYI_PATH="" "$IYI" build -o lost good.iyi > "$WORK/emptypath.txt" 2>&1
if grep -q "IYI_PATH is set and empty" "$WORK/emptypath.txt"; then
  echo "  an empty search path: says so"
else
  echo "  an empty search path: a list of nothing, printed as nothing"
  sed -n '1,8p' "$WORK/emptypath.txt"
  status=1
fi
# And `-o` naming the source itself - one word, typed twice. It read the
# source, built it, and linked the executable over it: the program's only
# copy was 12 KB of ELF, exit 0. The module a program imports is the same
# mistake one step removed, refused once the build knows what it read.
cp good.iyi good.keep
refuses "an output that is the source" "the source it would build from" -- \
  "$IYI" build -o good.iyi good.iyi
cmp -s good.iyi good.keep || { echo "  the refusal came after the source was replaced"; status=1; }
cp app/lib.iyi lib.keep
refuses "an output that is an imported module" "a file this build read" -- \
  "$IYI" build -o app/lib.iyi user.iyi
cmp -s app/lib.iyi lib.keep || { echo "  the refusal came after the module was replaced"; status=1; }
mkdir -p "$WORK/readonly"
chmod 500 "$WORK/readonly"
# A directory this process cannot write into. `chmod 500` does not bite as
# root, which is what CI runs as (see the unreadable module further down,
# which is `/proc/self/mem` for the same reason): the build really did
# write its program there, exited 0, and this arm failed every run since it
# was added. So the directory is the first one `access(W_OK)` refuses,
# which is the question the compiler asks - the mode-500 one where the bit
# binds, a read-only filesystem where it does not.
unwritable=""
# `/sys` and `/proc` are this shell's own mounts, not places a native
# compiler can be sent: handed `/proc/prog` it resolves the name against the
# current drive and writes the program into `C:\proc`, so the case reported
# that nothing was refused after the build had quietly succeeded.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) candidates="$WORK/readonly" ;;
  *) candidates="$WORK/readonly /sys /proc" ;;
esac
for candidate in $candidates; do
  if [ -d "$candidate" ] && [ ! -w "$candidate" ]; then
    unwritable="$candidate"
    break
  fi
done
if [ -n "$unwritable" ]; then
  refuses "an output directory that will not take the file ($unwritable)" \
    "no permission to write there" -- "$IYI" build -o "$unwritable/prog" good.iyi
else
  echo "  an output directory that will not take the file: nothing here refuses"
  echo "  this process, so this case had nothing to drive"
fi
chmod 700 "$WORK/readonly"
# And the library the program compiles against. With IYI_PATH pointed
# somewhere empty, the prelude is not found - and the answer was Crystal's
# advice about `shards install` and `shard.yml`, to an author whose
# language has neither and whose `require` is refused two lines earlier in
# the same file. What is wrong is the search path, so the search path is
# what it prints.
env IYI_PATH="$WORK/nowhere" "$IYI" build -o lost good.iyi > "$WORK/lost.txt" 2>&1
if grep -q 'shards install' "$WORK/lost.txt"; then
  echo "  a missing prelude: answered with the other language's advice"
  sed -n '1,8p' "$WORK/lost.txt"
  status=1
elif grep -q "iyi's prelude and \`std\` ship beside the compiler" "$WORK/lost.txt" &&
     grep -q "$WORK/nowhere" "$WORK/lost.txt"; then
  echo "  a missing prelude: names the search path it looked down"
else
  echo "  a missing prelude: said neither what was searched nor why"
  sed -n '1,8p' "$WORK/lost.txt"
  status=1
fi
# And the formatter, asked about a file that is not there. It printed
# "file or directory does not exist" and exited 0, so a CI line that
# reads `iyi tool format --check "$FILE"` passed on a path with a typo -
# the one case where the check certainly did not happen.
refuses "a format check on a path that is not there" "does not exist" -- \
  "$IYI" tool format --check nosuch.iyi

# The cache, which is the one thing here a build trusts without asking.
# `IYI_CACHE_DIR` pointed at something that cannot be a directory was
# skipped in silence - it is the first of a list of candidates, and the
# list falls through - so the build wrote its megabytes into
# `~/.cache/iyi`, which is the whole thing the variable was set to stop.
refuses "a cache directory that cannot be one" "IYI_CACHE_DIR is" -- \
  env IYI_CACHE_DIR="$WORK/good.iyi" "$IYI" build -o cached good.iyi
# And an empty one, which is what a shell makes of `IYI_CACHE_DIR="$DIR"`
# with `DIR` unset: `File.expand_path("")` is the working directory, so a
# build dropped its `.bc` and `.o` files, its linker probe and its link
# templates beside the source - and `clear_cache`, which is `rm -rf` on
# that answer, deleted the project. The file left in the directory below
# is what says so: it was gone, at exit 0.
refuses "an empty cache directory, building" 'IYI_CACHE_DIR is "" and that names no' -- \
  env IYI_CACHE_DIR="" "$IYI" build -o cached good.iyi
mkdir -p "$WORK/keep"
printf 'notes\n' > "$WORK/keep/NOTES.md"
cd "$WORK/keep"
refuses "an empty cache directory, clearing" 'IYI_CACHE_DIR is "" and that names no' -- \
  env IYI_CACHE_DIR="" "$IYI" clear_cache
cd "$WORK"
if [ -f "$WORK/keep/NOTES.md" ]; then
  echo "  clear_cache left the working directory where it stood"
else
  echo "  clear_cache deleted the working directory it was run in"
  status=1
fi
# And a cached object that is not an object. A build killed between
# `emit_obj` and `rename`, a full disk, or another build's cleanup
# deleting this one's directory mid-codegen (which is why
# `CacheDir#directory_in_use?` exists) leaves bytes the linker cannot
# read - and every later build linked them again: `ld.lld: error:
# <file>:1: unknown directive: garbage`, until somebody thought of
# `clear_cache`. The empty case was already guarded; these were not.
# The compiler names a cached object the way the platform's linker wants it,
# and on Windows that is `.obj`: a search for `*.o` found nothing to corrupt
# and the case reported that it had checked nothing.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) OBJ_GLOB='*.obj' ;;
  *) OBJ_GLOB='*.o' ;;
esac
mkdir -p "$WORK/cache"
env IYI_CACHE_DIR="$WORK/cache" "$IYI" build -o cached1 good.iyi > cache1.txt 2>&1 ||
  { echo "  a build with its own cache directory failed:"; cat cache1.txt; status=1; }
corrupted=0
for object in $(find "$WORK/cache" -name "$OBJ_GLOB" | head -3); do
  printf 'garbage' > "$object"
  corrupted=$((corrupted + 1))
done
truncate -s 2 "$(find "$WORK/cache" -name "$OBJ_GLOB" | tail -1)" 2>/dev/null
if [ "$corrupted" -eq 0 ]; then
  echo "  the cache held no objects to corrupt, so this case checked nothing"
  status=1
elif env IYI_CACHE_DIR="$WORK/cache" "$IYI" build -o cached2 good.iyi > cache2.txt 2>&1 &&
     [ "$(./cached2)" = "ok" ]; then
  if grep -q 'is not an object file; compiling it again' cache2.txt; then
    echo "  a corrupted cached object: recompiled, and said so"
  else
    echo "  a corrupted cached object: recompiled in silence"
    status=1
  fi
else
  echo "  a corrupted cached object: the build could not recover"
  sed -n '1,4p' cache2.txt
  status=1
fi
# The other half of that rule, and the expensive way to get it wrong: a
# header test that refused objects this compiler wrote would pass every
# case above and recompile the world on every build. `--stats` is where
# the cache answers for itself, and it has to say all of them, which is
# also what says the build above repaired what it refused.
if env IYI_CACHE_DIR="$WORK/cache" "$IYI" build -s -o cached3 good.iyi > cache3.txt 2>&1 &&
   grep -q 'all previous .o files were reused' cache3.txt &&
   ! grep -q 'is not an object file' cache3.txt; then
  echo "  an intact cache: every object reused, none refused"
else
  echo "  an intact cache: objects were refused, or not reused"
  grep -n 'reused\|not an object file' cache3.txt | sed -n '1,4p'
  status=1
fi

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
# A file where a directory goes is not a directory that is missing:
# `--lib shard.yml` said "no shard.yml/ here; run `shards install`" and
# `--mods shard.yml` died of mkdir's "File exists"; an empty shard name
# said "no shard named  under lib/", the two spaces its whole answer.
mkdir -p bindhere/lib/one/src
printf 'name: one\n' > bindhere/lib/one/shard.yml
printf 'module One\nend\n' > bindhere/lib/one/src/one.cr
printf 'name: app\n' > bindhere/shard.yml
refuses "a file where --lib's directory goes" "and bindhere/shard.yml is a file" -- \
  "$IYI" bind --lib bindhere/shard.yml
refuses "a file where --mods' directory goes" "and bindhere/shard.yml is a file" -- \
  "$IYI" bind --lib bindhere/lib --mods bindhere/shard.yml
refuses "an empty shard name" "the shard name is empty" -- \
  "$IYI" bind --lib bindhere/lib --mods "$WORK/bindmods" ""
# A directory that is there and will not take a file: `--mods` died of
# the bind log's "Permission denied", `--out` of the first module's, and
# `--out` naming a file of mkdir's "File exists". `$unwritable` is the
# directory found above, since a mode bit does not bind as root.
if [ -n "$unwritable" ]; then
  chmod 500 "$WORK/readonly"
  refuses "a --mods directory that will not take the files" "no permission to write there" -- \
    "$IYI" bind --lib bindhere/lib --mods "$unwritable"
  refuses "a --out directory that will not take the modules" "no permission to write there" -- \
    "$IYI" migrate tree --out "$unwritable"
  chmod 700 "$WORK/readonly"
fi
refuses "a file where --out's directory goes" "and $WORK/bindhere/shard.yml is a file" -- \
  "$IYI" migrate tree --out bindhere/shard.yml
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
# `/proc/self/mem` refuses a read at offset 0 for everybody. It is this
# shell's own mount, though, and not a file a native compiler can open, so
# on Windows there is nothing here to drive.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) kernel_file="" ;;
  *) kernel_file="/proc/self/mem" ;;
esac
if [ -n "$kernel_file" ] && [ -r "$kernel_file" ]; then
  ln -sf "$kernel_file" unreadable.iyi
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
