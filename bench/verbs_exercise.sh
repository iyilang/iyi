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
printf 'module main\n\nimport app/lib::{value}\n\nputs value\n' > user.iyi
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
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    # An extension written as a batch file, the shape npm's shims take on
    # Windows: the lookup is `CreateProcess`'s and appends `.exe` only, so
    # `iyi batonly` with `iyi-batonly.cmd` on PATH said "unknown command or
    # missing file" about a file that was there.
    mkdir -p extbin
    printf '@echo batonly %%*\r\n' > extbin/iyi-batonly.cmd
    refuses "an extension that is a batch file" "iyi-batonly.cmd is a batch file" -- \
      env PATH="$(cygpath -u "$WORK/extbin"):$PATH" "$IYI" batonly x
    ;;
esac
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
# And a subcommand's own help. `iyi mod context --help` answered "mod
# context: unknown flag --help", which is the one answer that is
# certainly wrong: a `--help` is how a harness finds a verb's flags, and
# AI_FIRST.md §2b hands `mod context --budget N` to agents as one of the
# loop's seven verbs. `mod diff` and `mod dump` answered the same way.
for sub in context diff dump; do
  if "$IYI" mod "$sub" --help 2>/dev/null | head -1 | grep -q "^Usage: .* mod $sub"; then
    echo "  mod $sub --help is mod $sub's own usage"
  else
    echo "  mod $sub --help did not print its usage:"
    "$IYI" mod "$sub" --help 2>&1 | head -1 | sed 's/^/    /'
    status=1
  fi
done
# The flags each usage names are the flags each one takes: a usage that
# forgets a switch is a switch nobody finds.
if "$IYI" mod context --help 2>/dev/null | grep -q -- "--budget" &&
   "$IYI" mod diff --help 2>/dev/null | grep -q -- "--exit-code" &&
   "$IYI" mod dump --help 2>/dev/null | grep -q -- "--declarations"; then
  echo "  each mod usage names the switches that verb reads"
else
  echo "  a mod usage does not name its own switches"; status=1
fi
# `repl` was a verb for a while: a session on the macro evaluator, which is
# the other language's compile-time library, so `"ab" * -3` answered
# "Negative argument" where this compiler says "negative count: -3". One
# name, two semantics. It was removed rather than taught the prelude, and
# this line is what keeps it removed.
refuses "the session that was removed" "unknown command" -- "$IYI" repl
# The two verbs that are Crystal's and not this language's. The refusal
# used to end with "run it with the `crystal` binary in this checkout",
# which is true of a developer's tree and false of the tarball and the
# zip; it names what stands in for each now. `init` was the third of
# these until it became a verb (`bench/init_project.sh`).
refuses "spec, which is iyi test here" "\`iyi test\` runs them" -- "$IYI" spec
refuses "eval, which has no evaluator here" "\`iyi run\` it" -- "$IYI" eval "puts 1"
refuses "an unknown flag" "Invalid option" -- "$IYI" build --nonesuch good.iyi
# `--mcpu` was handed to LLVM unchecked: an unknown name was warned about
# once per codegen thread, the lines running into each other, and the
# build died in LLVM's `abort()` - "64-bit code requested on a subtarget
# that doesn't support it!", exit 0xC0000409 on Windows. A name it knows
# is still taken.
refuses "an --mcpu LLVM does not know" "is not a CPU LLVM knows" -- \
  "$IYI" build --mcpu nonesuch -o "$WORK/mcpu_bad" good.iyi
case "$(uname -m)" in
  x86_64 | amd64)
    if "$IYI" build --mcpu x86-64 -o mcpu_ok good.iyi > mcpu.log 2>&1 && [ "$(./mcpu_ok | tr -d '\r')" = "ok" ]; then
      echo "  an --mcpu LLVM knows: builds and runs"
    else
      echo "  an --mcpu LLVM knows did not build:"; sed -n '1,3p' mcpu.log; status=1
    fi
    ;;
esac
refuses "a file that is not there" "no such file" -- "$IYI" run "$WORK/nope.iyi"
# One sentence for one mistake, from every verb that takes a file: this was
# "no such file" about a path that is right there, so the reader ran `ls`,
# found it, and learned nothing. `gather_sources` is the one place they all
# come through, so `run`, `build`, `check` and `vet` answer alike.
refuses "a directory as the entry" "is a directory, not a source file" -- "$IYI" run "$WORK"
refuses "a directory where check wants a file" "is a directory" -- "$IYI" check "$WORK"
refuses "two module headers in one file" "a file declares one module" -- "$IYI" run twoheaders.iyi
# A header after an `import` is the file's only header in the wrong place.
# It was told the file "already declares `no module`" and that
# `latehead` belongs in `latehead.iyi` - said to `latehead.iyi`.
printf 'import app/lib\nmodule latehead\n\nputs 1\n' > latehead.iyi
refuses "a module header after an import" 'the `module` header comes first in a file' -- \
  "$IYI" check latehead.iyi
# A file imported without a module header. The refusal was "`bare` is not
# imported here: ... write `import bare::{name}`", under the very import
# it described.
printf 'pub def twice(x : Int32) : Int32\n  x * 2\nend\n' > bare.iyi
printf 'import bare::{twice}\n\nputs twice(3)\n' > usesbare.iyi
refuses "an import of a file with no module header" 'has no `module bare` header' -- \
  "$IYI" run usesbare.iyi
# A macro the module declares and did not mark `pub`, imported by name, was
# told "nothing by that name is declared in `app/macros`, `pub` or not" -
# the answer for a typo, because only defs and types were looked in.
printf 'module app/macros\n\nmacro hidden_m\n  1\nend\n' > app/macros.iyi
printf 'module usesmacro\n\nimport app/macros::{hidden_m}\n\nhidden_m\n' > usesmacro.iyi
refuses "a macro not marked pub, imported by name" 'does not export `hidden_m`' -- \
  "$IYI" check usesmacro.iyi
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
# `name!(1)`: the `!` is a propagation, and an argument list was told it
# "takes no block".
printf 'module bangargs\n\nnomacro!(1)\n' > bangargs.iyi
refuses "a call spelled with ! and arguments" 'propagates an error, and takes no arguments' -- \
  "$IYI" check bangargs.iyi
# A program's own exit status is `iyi run`'s, a negative one too. On
# Windows `exit(-1)` is 0xFFFFFFFF, which the runner took for an abnormal
# end: "terminated abnormally, the cause is unknown", and exit 1.
# Compared with the program's own status as this shell reads it, which
# is not 255 everywhere: Git's shell on Windows reads 0xFFFFFFFF as 127.
printf 'module neg\n\nexit(-1)\n' > neg.iyi
"$IYI" build -o neg neg.iyi > neg.build 2>&1
./neg > /dev/null 2>&1
own_code=$?
"$IYI" run neg.iyi > neg.out 2>&1
neg_code=$?
if [ "$neg_code" -eq "$own_code" ] && [ ! -s neg.out ]; then
  echo "  a program's exit(-1): the runner exits with its status ($own_code here), and says nothing"
else
  echo "  a program's exit(-1): the program exits $own_code, the runner $neg_code, saying: $(head -c 200 neg.out)"
  status=1
fi
# The job `iyi run` holds its program in lets a child break away from it,
# as a shell does: the program's own CREATE_BREAKAWAY_FROM_JOB start was
# refused with "Access is denied" (error 5) under `iyi run` alone.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    away=$("$IYI" run "$REPO/bench/std_process_exercise.iyi" -- breakaway 2>&1 | tail -1)
    if [ "$away" = "started" ]; then
      echo "  a program under iyi run starts a child that breaks away from the runner's job"
    else
      echo "  a program under iyi run could not start a child away from the runner's job: $away"
      status=1
    fi
    ;;
esac
refuses "an output directory that is not there" "there is no" -- \
  "$IYI" build -o "$WORK/nodir/prog" good.iyi
# The refusal of an `--x86-asm-syntax` wrote over the value it refused
# before printing it: "Invalid value `` for x86-asm-syntax".
refuses "an --x86-asm-syntax that is neither" "Invalid value \`x\` for x86-asm-syntax" -- \
  "$IYI" build --x86-asm-syntax x -o "$WORK/asm" good.iyi
# Two `iyi run`s at once of programs with one basename. The runner linked
# into one executable per basename, and Windows will not write over one
# that is running: the second failed with `LNK1104: cannot open file
# ...\iyi-run-main.exe.tmp.exe`. Each runner has its own now.
mkdir -p twin_a twin_b
# The first holds its executable open until the second has run: it says
# it started, and waits (a minute at most) for the second to be done.
printf 'module main\n\nFile.write("twin_a.started", "1")\ni = 0\nwhile i < 600 && !File.exists?("twin_b.done")\n  sleep(100)\n  i = i + 1\nend\nputs "a"\n' > twin_a/main.iyi
printf 'module main\n\nputs "b"\n' > twin_b/main.iyi
"$IYI" run twin_a/main.iyi > twin_a.out 2>&1 &
twin_a=$!
i=0
while [ ! -f twin_a.started ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
if "$IYI" run twin_b/main.iyi > twin_b.out 2>&1 && grep -qx b twin_b.out; then
  echo "  a run beside a running program of the same name: runs"
else
  echo "  a run beside a running program of the same name did not run:"
  sed -n '1,3p' twin_b.out
  status=1
fi
touch twin_b.done
wait "$twin_a"
grep -qx a twin_a.out || { echo "  the first of two same-named runs did not finish: $(head -c 200 twin_a.out)"; status=1; }
# What a runner ended from outside leaves - `taskkill /F` runs no code
# in it, so its program stays in the cache under the runner's own name -
# the next run takes away once it is an hour old, and not before: a
# younger one may be another runner's, linked and about to start.
mkdir -p "$WORK/runcache"
: > "$WORK/runcache/iyi-run-main-99999.tmp.exe"
: > "$WORK/runcache/iyi-run-main-99998.tmp.exe"
touch -d '2 hours ago' "$WORK/runcache/iyi-run-main-99999.tmp.exe"
IYI_CACHE_DIR="$WORK/runcache" "$IYI" run twin_b/main.iyi > sweep.out 2>&1
if [ -e "$WORK/runcache/iyi-run-main-99999.tmp.exe" ]; then
  echo "  a runner's leftover from two hours ago is still in the cache"; status=1
elif [ ! -e "$WORK/runcache/iyi-run-main-99998.tmp.exe" ]; then
  echo "  a runner's leftover from just now was taken"; status=1
else
  echo "  an old runner's leftover is taken, a fresh one kept"
fi
# A path in another case, where the file system says it is the same
# file. The root a header names was found by comparing strings, so `iyi
# run HDR/APP/MAIN.IYI` found none, and the import beside the header was
# "can't find module"; and an entry spelled `.IYI` was built against
# Crystal's library, told of a `--crystal` it was never given.
mkdir -p hdr/app
printf 'module app/util\n\npub def answer : Int32\n  42\nend\n' > hdr/app/util.iyi
printf 'module app/main\n\nimport app/util::{answer}\n\nputs answer\n' > hdr/app/main.iyi
if [ HDR/APP/MAIN.IYI -ef hdr/app/main.iyi ]; then
  if "$IYI" run HDR/APP/MAIN.IYI > hdr_case.out 2>&1 && grep -qx 42 hdr_case.out; then
    echo "  a module run by its path in another case: resolves its imports"
  else
    echo "  a module run by its path in another case did not run:"
    sed -n '1,3p' hdr_case.out
    status=1
  fi
fi
# The front end alone reads the same root (`Compiler#adopt_header_root`).
# `tool dependencies` and `tool hierarchy` never asked the header, and of
# the file `run` builds just above both said "can't find module 'app/util'".
"$IYI" tool dependencies hdr/app/main.iyi > hdr_deps.out 2>&1; deps_code=$?
"$IYI" tool hierarchy hdr/app/main.iyi > hdr_hier.out 2>&1; hier_code=$?
if [ "$deps_code" -eq 0 ] && grep -q 'util\.iyi' hdr_deps.out && [ "$hier_code" -eq 0 ]; then
  echo "  tool dependencies and tool hierarchy of a module: resolve its imports"
else
  echo "  tool dependencies and tool hierarchy of a module: exit $deps_code and $hier_code"
  grep -h -m1 "^Error" hdr_deps.out hdr_hier.out
  status=1
fi
# And the lexer, of `run HDR/APP/MAIN.IYI` above: a path typed in another
# case is the file its directory stores, and a module that writes `!` - a
# token in iyi and part of a name in the other language - ran on iyi's
# prelude and was lexed as the other language: `unexpected token: "!"`.
printf 'module app/bang\n\nstruct Neg\nend\n\nimpl Error for Neg\n  def message : String\n    "neg"\n  end\nend\n\ndef g(x : Int32) : Int32 | Neg\n  return Neg.new if x < 0\n  x\nend\n\ndef h : Int32 | Neg\n  v = g(1)!\n  v + 1\nend\n\nputs h.or(0)\n' > hdr/app/bang.iyi
if [ HDR/APP/BANG.IYI -ef hdr/app/bang.iyi ]; then
  if "$IYI" run HDR/APP/BANG.IYI > hdr_bang.out 2>&1 && grep -qx 2 hdr_bang.out; then
    echo "  a module with \`!\` run by its path in another case: lexed as iyi"
  else
    echo "  a module with \`!\` run by its path in another case did not run:"
    sed -n '1,3p' hdr_bang.out
    status=1
  fi
fi
# A file *stored* as `.IYI` is not an iyi file on any system, and every
# verb says so by name (`Lexer.iyi_miscased?`). On Windows it was half of
# one: `run` folded the case for the prelude and the lexer did not, and
# `fmt DIR` and `test DIR` walked past it at exit 0.
mkdir -p upcase/tests
cp hdr/app/bang.iyi upcase/UP.IYI
cp hdr/app/bang.iyi upcase/tests/up_test.IYI
refuses "a file stored as .IYI, run" 'ends in `.IYI`' -- "$IYI" run upcase/UP.IYI
refuses "a file stored as .IYI, checked" 'ends in `.IYI`' -- "$IYI" check upcase/UP.IYI
refuses "a file stored as .IYI, formatted" 'ends in `.IYI`' -- "$IYI" fmt --check upcase/UP.IYI
refuses "a directory holding a .IYI, formatted" 'ends in `.IYI`' -- "$IYI" fmt --check upcase
refuses "a directory holding a _test.IYI, tested" 'ends in `.IYI`' -- "$IYI" test upcase/tests
# A byte order mark, which a Windows editor may put at the front of a
# file. The lexer skips it; the three readings of a header did not, so a
# module saved with one ran as a script and its import beside the header
# was "can't find module", `iyi doc` said it "declares no module", and
# `fmt` wrote the file back without the mark and `--check` called a
# formatted file unformatted.
mkdir -p bom/app
printf '\357\273\277module app/util\n\npub def answer : Int32\n  42\nend\n' > bom/app/util.iyi
printf '\357\273\277module app/main\n\nimport app/util::{answer}\n\nputs answer\n' > bom/app/main.iyi
cp bom/app/util.iyi bom/util.keep
if "$IYI" run bom/app/main.iyi > bom_run.out 2>&1 && grep -qx 42 bom_run.out; then
  echo "  a module saved with a byte order mark: resolves its imports"
else
  echo "  a module saved with a byte order mark did not run:"; sed -n '1,3p' bom_run.out; status=1
fi
if "$IYI" doc bom/app/util.iyi > bom_doc.out 2>&1 && grep -q 'answer' bom_doc.out; then
  echo "  iyi doc of a module saved with a byte order mark: its surface"
else
  echo "  iyi doc of a module saved with a byte order mark:"; sed -n '1,3p' bom_doc.out; status=1
fi
if "$IYI" fmt --check bom/app/util.iyi > bom_fmt.out 2>&1; then
  echo "  fmt --check of a formatted file with a byte order mark: clean"
else
  echo "  fmt --check of a formatted file with a byte order mark:"; sed -n '1,3p' bom_fmt.out; status=1
fi
"$IYI" fmt bom/app/util.iyi > /dev/null 2>&1
cmp -s bom/app/util.iyi bom/util.keep || { echo "  fmt rewrote a formatted file with a byte order mark"; status=1; }
# And a byte order mark on line 1, which the lexer drops before it counts
# a column: the line was shown with the mark, ` 1 | \uFEFFputs 1.nope`, and
# the caret, placed by the mark-free column, stood under `.nop` wherever
# a terminal gave the mark a cell. The line is read as the lexer counted
# it now (`source_file_lines`).
printf '\357\273\277puts 1.nope\n' > marked1.iyi
"$IYI" check marked1.iyi > marked1.out 2>&1
if grep -qx ' 1 | puts 1.nope' marked1.out &&
   [ "$(grep -A1 '^ 1 | ' marked1.out | sed -n '2p')" = "$(printf '%12s^---' '')" ]; then
  echo "  line 1 behind a byte order mark is shown without it, the caret under the column"
else
  echo "  line 1 behind a byte order mark:"
  sed -n '1,8p' marked1.out | cat -A
  status=1
fi
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    # The entry spelled verbatim, `\\?\C:\...` or `\\.\C:\...`, or with the
    # trailing space Win32 drops: the cache directory was named after the
    # path's parts, `\-C:-...` - refused for its colon, "The directory name
    # is invalid" - and `...-good.iyi `, made without its space and then
    # written into with it, "The system cannot find the path specified".
    for prefix in '\\?\' '\\.\'; do
      if "$IYI" run "$prefix$(cygpath -w "$WORK/hdr/app/main.iyi")" > hdr_verbatim.out 2>&1 && grep -qx 42 hdr_verbatim.out; then
        echo "  a module run by its path spelled $prefix: builds and runs"
      else
        echo "  a module run by its path spelled $prefix did not run:"; sed -n '1,3p' hdr_verbatim.out; status=1
      fi
    done
    if "$IYI" run "good.iyi " > space_run.out 2>&1 && grep -qx ok space_run.out; then
      echo "  a program run by its name with a trailing space: builds and runs"
    else
      echo "  a program run by its name with a trailing space did not run:"; sed -n '1,3p' space_run.out; status=1
    fi
    ;;
esac
# A CRLF file keeps its CRLF through `fmt`, and a literal keeps the line
# breaks it holds, which are the program's data: every `\n` was turned, so
# a string holding a bare line break gained a `\r` and printed eight bytes
# where it had printed seven. A heredoc's opener and the lines inside an
# interpolated string are the other two places a line break can sit. And
# macro text, a macro's body or a `{% if %}`'s, which the parser keeps as
# text: its literals went unseen and `"a` / `b"` there gained the `\r`.
mkdir -p crlf
printf 'module m\r\n\r\ns = "one\ntwo"\r\nputs s.bytesize\r\n' > crlf/lit.iyi
printf 'module h\r\n\r\ntext = <<-EOS\r\n  hello\r\n  world\r\n  EOS\r\nputs text.bytesize\r\n' > crlf/here.iyi
printf 'module p\r\n\r\ndef f(x : Int32) : Int32\r\n  x + 1\r\nend\r\n\r\nputs "a#{f(1)}b\r\nc"\r\n' > crlf/interp.iyi
printf 'module q\r\n\r\nmacro m\r\n  puts "a\nb".bytesize\r\nend\r\n\r\nm\r\n{%% if true %%}\r\n  puts "c\nd".bytesize\r\n{%% end %%}\r\n' > crlf/macro.iyi
for f in lit here interp macro; do
  cp "crlf/$f.iyi" "crlf/$f.keep"
  "$IYI" fmt "crlf/$f.iyi" > /dev/null 2>&1
  if cmp -s "crlf/$f.iyi" "crlf/$f.keep"; then
    echo "  fmt of a formatted CRLF file with line breaks in a literal ($f): unchanged"
  else
    echo "  fmt changed a formatted CRLF file ($f):"; od -c "crlf/$f.iyi" | sed -n '1,6p'; status=1
  fi
done
# What `fmt` writes is what was written - the same program - and is its
# own format: `fmt -` of the input is the wanted text, and the wanted
# text formats to itself.
fmt_gives() { # fmt_gives <label> <input> [<want>]; <want> defaults to <input>
  local label="$1" input="$2" want="${3-$2}" code
  printf '%s' "$input" > fmt_in.iyi
  printf '%s' "$want" > fmt_want.iyi
  "$IYI" fmt - < fmt_in.iyi > fmt_got.iyi 2> fmt_err.out
  code=$?
  "$IYI" fmt - < fmt_want.iyi > fmt_again.iyi 2>> fmt_err.out
  if [ "$code" -eq 0 ] && cmp -s fmt_got.iyi fmt_want.iyi && cmp -s fmt_again.iyi fmt_want.iyi; then
    echo "  fmt $label"
  else
    echo "  fmt $label: exit $code, and wrote:"; sed -n '1,8p' fmt_got.iyi fmt_err.out; status=1
  fi
}
# A comment after a block's `{` or `do`, or a proc literal's: the `}` or
# `end` went onto the last line, after that line's comment, where it
# closed nothing and the file no longer compiled.
fmt_gives "keeps a block's } off the last line, after a comment on its {" \
  $'def run(&)\n  yield\nend\n\nrun { # c\n  y = 1\n  puts y # d\n}\n'
fmt_gives "keeps a proc literal's } off the last line, after a comment on its {" \
  $'f = ->(b : Int32) { # c\n  x = b\n  x + 1 # d\n}\n'
fmt_gives "keeps a proc literal's end off the last line, after a comment on its do" \
  $'f = -> do # c\n  x = 1\n  x + 1 # d\nend\n'
fmt_gives "keeps the comment lines under do |x| # c inside the block" \
  $'[1].each do |x| # c\n  # d\n  puts x\nend\n'
# The blanks and the `\r` a line inside a literal ends with are the
# program's: they were stripped - only heredocs were spared - so `"a  ` /
# `b"` printed 5 before `fmt` and 3 after.
fmt_gives "keeps the blanks and the \\r a line inside a literal ends with" \
  $'x = 1\ns = "a  \nb"\nt = %(c\t\nd)\nu = /e  \nf/\nv = "g\r\nh"\n'
fmt_gives "keeps the blanks a line inside a literal in a macro ends with" \
  $'macro m\n  puts "a  \nb".bytesize\nend\n'
# A NUL byte inside a file is not its end. The lexer took every '\0' for
# one, so `puts 1<NUL>` and the lines after it compiled as `puts 1` -
# `check` exited 0 - and `fmt` wrote back the part before the NUL: a
# UTF-16 file without its byte order mark became `p`. (`check` quotes the
# line, NUL and all, so its answer is read as text: `grep -a`.)
printf 'module main\n\nputs 1\000\nputs 2\n' > nul.iyi
cp nul.iyi nul.keep
refuses "a NUL byte in a file, formatted" "unexpected NUL byte" -- "$IYI" fmt nul.iyi
cmp -s nul.iyi nul.keep || { echo "  fmt wrote back a file with a NUL byte in it"; status=1; }
"$IYI" check nul.iyi > nul_check.out 2>&1
nul_code=$?
if [ "$nul_code" -ne 0 ] && grep -aq "unexpected NUL byte" nul_check.out && ! has_trace nul_check.out; then
  echo "  a NUL byte in a file, checked: exits $nul_code, \"unexpected NUL byte\""
else
  echo "  a NUL byte in a file, checked: exit $nul_code"; sed -n '1,3p' nul_check.out | tr -d '\000'; status=1
fi
printf 'p\000u\000t\000s\000 \0001\000\n\000' > utf16.iyi
refuses "a UTF-16 file without its mark, formatted" "unexpected NUL byte" -- "$IYI" fmt --check utf16.iyi
# `.or(...)` and `.or_panic` on the line under their value: "expecting .,
# not `NEWLINE`", and "there's a bug formatting".
fmt_gives "takes .or and .or_panic on the line under their value" \
  $'x = g(-1)\n  .or(2)\ny = g(5)\n  .or_panic\nz = g(1).or( # c\n  2)\n'
# Under a comment on an `if` or `while` line, `/=` was read as a regex.
fmt_gives "takes x /= y and x //= y under a comment on an if or while line" \
  $'a = 8\nif a > 1 # c\n  a /= 2\nend\nwhile a > 1 # c\n  a //= 2\nend\n'
# A comment in an import's name list, or between `x =` or `type X =` and
# the value, moved at every `fmt`.
fmt_gives "keeps a comment in an import's name list on its own line" \
  $'import std/json::{JSON,\n  # more\n  Builder}\n'
fmt_gives "keeps a comment between x = or type X = and the value on its own line" \
  $'escape =\n  # note\n  if b\n    "one"\n  else\n    "other"\n  end\ntype X =\n  # c\n  Int32\nx = 1\nx += # c\n  2\n'
# A ```crystal fence in a `.iyi` doc comment lost its tag, which made the
# other language's example iyi.
fmt_gives "keeps a doc comment's \`\`\`crystal fence tagged in an iyi file" \
  $'# The original:\n#\n# ```crystal\n# def save!\n#   @x  =  1\n# end\n# ```\ndef add(a, b)\n  a + b\nend\n'
# A `"a" \` continued by a comment line, where the parser ends the literal:
# the formatter took the next line's literal into it, and gave up.
fmt_gives "ends a literal where the parser does, at a comment after its \\" \
  $'x = "a" \\\n    # note\n    "b"\n' $'x = "a" \\\n    # note\n"b"\n'
fmt_gives "sets traits and impls apart by a blank line, as classes are" \
  $'trait A\nend\nimpl A for B\nend\n' $'trait A\nend\n\nimpl A for B\nend\n'
# The parser's spacing warning named `crystal tool format`, and `iyi fmt`
# printed it while rewriting exactly that spacing.
printf 'module colon\n\ndef f(x : Int32): Int32\n  x\nend\n\nputs f(1)\n' > colon.iyi
cp colon.iyi colonfmt.iyi
"$IYI" check colon.iyi > colon.out 2>&1
"$IYI" fmt colonfmt.iyi > colonfmt.out 2>&1
if ! grep -qF 'space required before colon in return type restriction (run `iyi fmt` to fix this)' colon.out ||
  grep -qi crystal colon.out; then
  echo "  a spacing warning from check does not name iyi fmt:"; sed -n '1,6p' colon.out
  status=1
elif grep -q 'Warning' colonfmt.out || ! grep -qF 'def f(x : Int32) : Int32' colonfmt.iyi; then
  echo "  fmt on a spacing warning warned about it, or did not fix it:"; sed -n '1,6p' colonfmt.out
  status=1
else
  echo "  a spacing warning from check says \`iyi fmt\`, and fmt fixes it without the warning"
fi
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    # A module reached through an 8.3 short name, which only the file
    # system can spell out: `APPLIC~1\main.iyi` never ended with its
    # header's `applications_dir/main.iyi`, so it found no root, and `run`,
    # `check` and `test` of it said "can't find module
    # 'applications_dir/util'".
    mkdir -p short/applications_dir
    printf 'module applications_dir/util\n\npub def answer : Int32\n  42\nend\n' > short/applications_dir/util.iyi
    printf 'module applications_dir/main\n\nimport applications_dir/util::{answer}\n\nputs answer\n' > short/applications_dir/main.iyi
    spelled="$(cygpath -d "$WORK/short/applications_dir/main.iyi")"
    if [ "$spelled" = "$(cygpath -w "$WORK/short/applications_dir/main.iyi")" ]; then
      echo "  a module reached through an 8.3 name: this volume makes none, unmeasured"
    elif "$IYI" run "$spelled" > short.out 2>&1 && grep -qx 42 short.out; then
      echo "  a module reached through an 8.3 name: resolves its imports"
    else
      echo "  a module reached through an 8.3 name did not run:"; grep -m1 "^Error" short.out || sed -n '1,3p' short.out; status=1
    fi
    ;;
esac
# A file fmt may not write is the file system's refusal, not a formatter
# bug: a read-only file - common on Windows, a locked checkout or an
# extracted archive - was reported as "there's a bug formatting", with a
# request to file one.
mkdir -p locked
printf 'module locked\n\nputs(  1 )\n' > locked/sloppy.iyi
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" attrib +R "$(cygpath -w locked/sloppy.iyi)" ;;
  *) chmod a-w locked/sloppy.iyi ;;
esac
if [ -w locked/sloppy.iyi ] && [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" = "0" ]; then
  echo "  fmt of a read-only file: root writes anything, unmeasured"
elif "$IYI" fmt locked/sloppy.iyi > locked.out 2>&1; then
  echo "  fmt of a read-only file answered success:"; sed -n '1,3p' locked.out; status=1
elif grep -q "cannot write" locked.out && ! grep -q "bug" locked.out; then
  echo "  fmt of a read-only file: $(tr -d '\r' < locked.out | head -1)"
else
  echo "  fmt of a read-only file:"; sed -n '1,3p' locked.out; status=1
fi
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" attrib -R "$(cygpath -w locked/sloppy.iyi)" ;;
  *) chmod u+w locked/sloppy.iyi ;;
esac
# A directory given to `test` and `fmt` is a name, not a pattern: `proj
# [v2]` and `x{a,b}` were read as a character class and a brace, and on
# Windows a share's root, `\\server\share`, was looked for under the
# current drive's root - the tests were not found, and `fmt --check`
# passed having checked nothing. And a junction back to the project was
# walked through, until the path was too long to open.
for dir in "proj [v2]" "x{a,b}"; do
  mkdir -p "rooted/$dir"
  printf 'module messy\n\nx=1\n' > "rooted/$dir/messy.iyi"
  printf 'module fails_test\n\nexit(1)\n' > "rooted/$dir/fails_test.iyi"
done
roots=("rooted/proj [v2]" "rooted/x{a,b}")
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    share="$(cygpath -w "$WORK/rooted/proj [v2]")"
    share="\\\\127.0.0.1\\${share:0:1}\$${share:2}"
    [ -d "$share" ] && roots+=("$share")
    # And spelled verbatim, `\\?\C:\...` and `\\?\UNC\server\share\...`,
    # the form Rust's `fs::canonicalize` hands over: the `?` went into the
    # pattern as a pattern character, nothing matched, and `fmt --check`
    # exited 0 while `test` said "no *_test.iyi found".
    roots+=("\\\\?\\$(cygpath -w "$WORK/rooted/proj [v2]")")
    [ -d "$share" ] && roots+=("\\\\?\\UNC\\${share:2}")
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" cmd /c mklink /J "$(cygpath -w "$WORK/rooted/x{a,b}/loop")" "$(cygpath -w "$WORK/rooted/x{a,b}")" > /dev/null
    ;;
esac
for root in "${roots[@]}"; do
  "$IYI" fmt --check "$root" > rooted.fmt 2>&1; fmt_code=$?
  "$IYI" test "$root" > rooted.test 2>&1; test_code=$?
  if [ "$fmt_code" -eq 1 ] && [ "$(grep -c 'produced changes' rooted.fmt)" = "1" ] &&
     [ "$test_code" -eq 1 ] && grep -q "0 passed, 1 failed" rooted.test; then
    echo "  fmt --check and test of $root: the one messy file and the one failing test"
  else
    echo "  fmt --check and test of $root: fmt $fmt_code, test $test_code"; sed -n '1,3p' rooted.fmt rooted.test; status=1
  fi
done
[ -e "rooted/x{a,b}/loop" ] && MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" cmd /c rmdir "$(cygpath -w "$WORK/rooted/x{a,b}/loop")"
# `fix` and `mod tidy` walk a directory with a loop of their own rather
# than a glob, asking `File.directory?`, which follows a link: they went
# through one back into the tree, and `fix` died 38 levels down on "The
# system cannot find the path specified", `mod tidy` on a file down there
# that "does not parse".
mkdir -p tidyloop/src
printf 'module example.test/tidyloop\n' > tidyloop/iyi.mod
printf 'module x\n\nputs 1\n' > tidyloop/src/x.iyi
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" cmd /c mklink /J "$(cygpath -w "$WORK/tidyloop/src/loop")" "$(cygpath -w "$WORK/tidyloop/src")" > /dev/null
    ;;
  *) ln -s "$WORK/tidyloop/src" tidyloop/src/loop ;;
esac
"$IYI" fix tidyloop/src > tidyloop.fix 2>&1; fix_code=$?
(cd tidyloop && "$IYI" mod tidy --check) > tidyloop.tidy 2>&1; tidy_code=$?
if [ "$fix_code" -eq 0 ] && grep -q "already clean" tidyloop.fix &&
   [ "$tidy_code" -eq 0 ] && grep -q "say what the source imports" tidyloop.tidy; then
  echo "  fix and mod tidy of a tree with a link back into it: the link is not walked"
else
  echo "  fix and mod tidy through a link: fix $fix_code, tidy $tidy_code"; sed -n '1,3p' tidyloop.fix tidyloop.tidy; status=1
fi
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" cmd /c rmdir "$(cygpath -w "$WORK/tidyloop/src/loop")" ;;
  *) rm tidyloop/src/loop ;;
esac
# `lib` is left alone however the directory is named: the exclude was
# compared as a string prefix, and `fmt --check .` walked to `./lib/x.iyi`,
# which never starts with `lib`, and checked what a bare `fmt --check`
# leaves alone.
mkdir -p excl/lib excl/src
printf 'module messy\n\nx=1\n' > excl/lib/messy.iyi
printf 'module messy\n\nx=1\n' > excl/src/messy.iyi
(cd excl && "$IYI" fmt --check . > ../excl.out 2>&1)
if grep -q 'src.messy.iyi' excl.out && ! grep -q 'lib.messy.iyi' excl.out; then
  echo "  fmt --check . leaves lib alone, as fmt --check does"
else
  echo "  fmt --check . and lib:"; sed -n '1,3p' excl.out; status=1
fi
# But a path named on the command line is formatted, whatever the excludes
# say, which is Black's rule: `fmt --check lib/messy.iyi` and `fmt --check
# lib` exited 0 having checked nothing - the default exclude took back
# what was named.
for named in lib/messy.iyi lib; do
  (cd excl && "$IYI" fmt --check "$named" > ../excl_named.out 2>&1)
  named_code=$?
  if [ "$named_code" -eq 1 ] && grep -q 'lib.messy.iyi. produced changes' excl_named.out; then
    echo "  fmt --check $named, named on the command line: checked"
  else
    echo "  fmt --check $named, named on the command line: exit $named_code"; sed -n '1,3p' excl_named.out; status=1
  fi
done
# A file fmt may not read is reported, and the walk goes on. Asking what
# the path is, and reading it, were outside every rescue: one such file
# ended `fmt DIR` with "Error: ...: Access is denied." and the files after
# it were never looked at.
mkdir -p noread
printf 'module a\n\nx=1\n' > noread/a_noread.iyi
printf 'module z\n\nx=1\n' > noread/z_messy.iyi
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" icacls "$(cygpath -w noread/a_noread.iyi)" /deny "$USERNAME:(R)" > /dev/null ;;
  *) chmod a-r noread/a_noread.iyi ;;
esac
"$IYI" fmt --check noread > noread.out 2>&1
noread_code=$?
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" icacls "$(cygpath -w noread/a_noread.iyi)" /remove:d "$USERNAME" > /dev/null ;;
  *) chmod u+r noread/a_noread.iyi ;;
esac
if [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" = "0" ]; then
  echo "  fmt --check of a directory holding a file it may not read: root reads anything, unmeasured"
elif [ "$noread_code" -eq 1 ] && grep -q "cannot read '.*a_noread.iyi'" noread.out &&
     grep -q "z_messy.iyi' produced changes" noread.out && ! has_trace noread.out; then
  echo "  fmt --check of a directory holding a file it may not read: says so, and checks the rest"
else
  echo "  fmt --check of a directory holding a file it may not read: exit $noread_code"; sed -n '1,3p' noread.out; status=1
fi
# A program rebuilt while it runs, the everyday Windows loop: Windows will
# not write over a running program, and the linker said so after the whole
# compile - "LNK1104: cannot open file", exit status 1104. The running one
# is moved aside, and the new one is written where it was.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    mkdir -p busy
    printf 'module busy\n\nsleep(8000)\n' > busy/slow.iyi
    printf 'module busy\n\nputs "second"\n' > busy/quick.iyi
    if "$IYI" build -o busy/prog.exe busy/slow.iyi > busy.log 2>&1; then
      busy/prog.exe &
      running=$!
      sleep 1
      "$IYI" build -o busy/prog.exe busy/quick.iyi > busy.log 2>&1; rebuilt=$?
      said="$(busy/prog.exe 2>&1 | tr -d '\r')"
      if [ "$rebuilt" -eq 0 ] && [ "$said" = "second" ]; then
        echo "  a program rebuilt while it runs: the running one moved aside, the new one runs"
      else
        echo "  a program rebuilt while it runs: build $rebuilt, it said '$said'"; sed -n '1,3p' busy.log; status=1
      fi
      kill "$running" 2>/dev/null; wait "$running" 2>/dev/null
    else
      echo "  the busy program did not build:"; sed -n '1,3p' busy.log; status=1
    fi
    # And the program database the linker writes beside it, which was
    # never asked about: a read-only `.pdb`, as an extracted tree leaves
    # one, failed the link after the whole compile - "LNK1201: error
    # writing to program database", exit status 1201 - and the linker
    # deleted the program on its way out. It is moved aside like the
    # program; one held open, which cannot be moved, is refused before
    # anything is compiled, and the program is left as it was.
    printf 'module busy\n\nputs "third"\n' > busy/third.iyi
    if "$IYI" build -o busy/db.exe busy/quick.iyi > pdb.log 2>&1 && [ -f busy/db.pdb ]; then
      MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" attrib +R "$(cygpath -w busy/db.pdb)"
      "$IYI" build -o busy/db.exe busy/third.iyi > pdb.log 2>&1; rebuilt=$?
      said="$(busy/db.exe 2>&1 | tr -d '\r')"
      if [ "$rebuilt" -eq 0 ] && [ "$said" = "third" ]; then
        echo "  a program whose .pdb is read-only: the .pdb moved aside, the new program runs"
      else
        echo "  a program whose .pdb is read-only: build $rebuilt, it said '$said'"; sed -n '1,3p' pdb.log; status=1
      fi
      for f in busy/db.pdb*; do MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" attrib -R "$(cygpath -w "$f")"; done
      powershell -NoProfile -Command "\$f = [IO.File]::Open('$(cygpath -w "$WORK/busy/db.pdb")', 'Open', 'Read', 'None'); \
        New-Item -ItemType File '$(cygpath -w "$WORK/busy/held")' | Out-Null; \$i = 0; \
        while (-not (Test-Path '$(cygpath -w "$WORK/busy/release")') -and \$i -lt 600) { Start-Sleep -Milliseconds 100; \$i++ }; \
        \$f.Close()" > /dev/null 2>&1 &
      holder=$!
      i=0
      while [ ! -f busy/held ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
      refuses "a program whose .pdb is held open" "db.pdb is in use and cannot be replaced or moved aside" -- \
        "$IYI" build -o busy/db.exe busy/quick.iyi
      said="$(busy/db.exe 2>&1 | tr -d '\r')"
      [ "$said" = "third" ] || { echo "  the refused build lost the program: it said '$said'"; status=1; }
      touch busy/release; wait "$holder" 2>/dev/null
    else
      echo "  the program with a .pdb did not build:"; sed -n '1,3p' pdb.log; status=1
    fi
    # A directory the program fits in and the write probe does not: the
    # probe's name, `.iyi-write-probe-<pid>`, is longer than `m.exe`, and
    # near MAX_PATH the probe failed and was told as "no permission to
    # write there" - for five-digit process ids only. 245 characters: the
    # probe does not fit whatever the pid, the program does.
    deep="$WORK"
    while [ ${#deep} -lt 233 ]; do deep="$deep/dddddddddd"; done
    deep="$deep/$(printf '%*s' $((245 - ${#deep} - 1)) '' | tr ' ' 'e')"
    mkdir -p "$deep" && printf 'module m\n\nputs "deep"\n' > "$deep/m.iyi"
    (cd "$deep" && "$IYI" build m.iyi > "$WORK/deep.log" 2>&1); deep_code=$?
    if [ "$deep_code" -eq 0 ] && [ -f "$deep/m.exe" ]; then
      echo "  a build in a ${#deep}-character directory writes its program there"
    else
      echo "  a build in a ${#deep}-character directory: exit $deep_code"; sed -n '1,3p' "$WORK/deep.log"; status=1
    fi
    ;;
esac
# A target whose back end the compiler's LLVM does not carry. Windows' is
# Crystal's own Windows package, X86 and AArch64 only, and `--target
# wasm32-wasi` there answered "you've found a bug in the iyi compiler"
# over a bare exception from inside LLVM's set-up; it is a property of the
# build, named as one. Linux's and darwin's LLVM carry WebAssembly, and the
# wasi jobs build with it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    refuses "a target this compiler's LLVM cannot build for" "needs LLVM's WebAssembly back end" -- \
      "$IYI" build --cross-compile --target wasm32-wasi -o "$WORK/towasm" good.iyi
    ;;
esac
# `run --sandbox` names the variable it was given. IYI_WASI_CC pointed at
# nothing was skipped in silence and the refusal said to set it; and under
# `$WASI_SDK` clang is `clang.exe` on Windows, where a bare `clang` was
# looked for, so an installed wasi-sdk was "install wasi-sdk". Found, the
# next tool is the one named.
refuses "an IYI_WASI_CC that points at nothing" "IYI_WASI_CC is" -- \
  env IYI_WASI_CC="$WORK/no-clang" "$IYI" run --sandbox good.iyi
mkdir -p "$WORK/wasisdk/bin"
: > "$WORK/wasisdk/bin/clang"
: > "$WORK/wasisdk/bin/clang.exe"
refuses "a wasi-sdk clang under WASI_SDK" "IYI_WASMTIME is" -- \
  env -u IYI_WASI_CC WASI_SDK="$WORK/wasisdk" IYI_WASMTIME="$WORK/no-wasmtime" "$IYI" run --sandbox good.iyi

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
mkdir -p "$WORK/nofix"
refuses "fix on a directory with no source" "with no .iyi file under it" -- "$IYI" fix "$WORK/nofix"
refuses "an unknown flag to fix" "unknown flag" -- "$IYI" fix --nonesuch good.iyi
refuses "a second file that is not there" "no such file: extra.iyi" -- "$IYI" fix good.iyi extra.iyi
# `.exe` off the end: the usage line names the command, and the command is
# the compiler's name without the suffix Windows puts on the file.
refuses "vet with no file" "Usage: $(basename "$IYI" .exe) vet" -- "$IYI" vet
refuses "a variable env does not have" "no such variable" -- "$IYI" env NOPE
refuses "an argument to clear_cache" "takes no arguments" -- "$IYI" clear_cache extra
refuses "an argument to the mcp server" "takes no arguments" -- "$IYI" mcp --nonesuch
# `iyi env -- IYI_PATH` read the names before `--` only, and printed every
# variable as a shell script, exit 0, for one value.
env_dashed=$("$IYI" env -- IYI_PATH 2>&1)
if [ "$env_dashed" = "$("$IYI" env IYI_PATH 2>&1)" ] && [ "$(printf '%s\n' "$env_dashed" | wc -l)" -eq 1 ]; then
  echo "  env reads the names after --, too"
else
  echo "  env -- IYI_PATH printed: $(printf '%s' "$env_dashed" | head -2)"
  status=1
fi
# A directory is one run: every `using` in every file is rewritten before
# any file compiles, because `a` compiles the module it imports - and the
# second run changes nothing.
mkdir -p "$WORK/mig/app"
printf 'module app/dep\n\npub def value : Int32\n  2\nend\n' > "$WORK/mig/app/dep.iyi"
printf 'module app/mid\n\nimport app/dep\nusing app/dep::{value}\n\npub def twice : Int32\n  value * 2\nend\n' > "$WORK/mig/app/mid.iyi"
printf 'using app/mid\n\nputs twice\n' > "$WORK/mig/main.iyi"
if ! (cd "$WORK/mig" && "$IYI" fix .) > "$WORK/mig.txt" 2>&1 ||
   ! grep -q "3 files: 2 rewritten, every one clean" "$WORK/mig.txt" ||
   grep -q "using" "$WORK/mig/main.iyi" "$WORK/mig/app/mid.iyi" ||
   [ "$("$IYI" run "$WORK/mig/main.iyi" 2>&1)" != "4" ]; then
  echo "  fix over a directory: did not rewrite the tree into a program that runs"
  sed 's/^/    /' "$WORK/mig.txt"
  status=1
elif ! (cd "$WORK/mig" && "$IYI" fix .) 2>&1 | grep -q "3 files: 0 rewritten, every one clean"; then
  echo "  fix over a directory: a second run changed something"
  status=1
else
  echo "  fix over a directory: every using rewritten in one run, and the second run changes nothing"
fi
# A `using` folded into its import in a CRLF file left two blank lines
# where the LF file is left one - only `\n` was a blank line's ending - and
# `fmt --check` then refused the file the rewrite had written.
mkdir -p "$WORK/crlfusing/app"
printf 'module app/greeter\n\npub def polite : String\n  "hi"\nend\n' > "$WORK/crlfusing/app/greeter.iyi"
printf 'module app/main\r\n\r\nimport app/greeter\r\n\r\nusing app/greeter::{polite}\r\n\r\nputs polite\r\n' > "$WORK/crlfusing/app/main.iyi"
printf 'module app/main\r\n\r\nimport app/greeter::{polite}\r\n\r\nputs polite\r\n' > "$WORK/crlfusing/main.want"
(cd "$WORK/crlfusing" && "$IYI" fix app/main.iyi && "$IYI" fmt --check app/main.iyi) > "$WORK/crlfusing.txt" 2>&1; crlf_code=$?
if [ "$crlf_code" -eq 0 ] && cmp -s "$WORK/crlfusing/app/main.iyi" "$WORK/crlfusing/main.want"; then
  echo "  fix folds a using in a CRLF file as in an LF one, and fmt --check agrees"
else
  echo "  fix of a using in a CRLF file (exit $crlf_code):"; sed 's/^/    /' "$WORK/crlfusing.txt" | head -3; status=1
fi
# And the flag that was being dropped is read now, from either side.
if "$IYI" fix good.iyi --json | head -1 | grep -q '^{'; then
  echo "  fix reads --json after the file, too"
else
  echo "  fix --json after the file did not print JSON:"
  "$IYI" fix good.iyi --json | sed -n '1,2p'
  status=1
fi
# A byte order mark is not a column: the lexer drops it before it counts,
# and on line 1 `fix` cut one character to the left - `x = -5.abss` became
# `-5abss`, which does not parse, and a `using` there lost its mark and
# became `import app/greeter::{polite}}`.
mkdir -p "$WORK/marked/app"
printf 'module app/greeter\n\npub def polite : String\n  "hi"\nend\n' > "$WORK/marked/app/greeter.iyi"
printf '\357\273\277x = -5.abss\nputs x\n' > "$WORK/marked/typo.iyi"
printf '\357\273\277using app/greeter::{polite}\n\nputs polite\n' > "$WORK/marked/using.iyi"
printf '\357\273\277x = -5.abs\nputs x\n' > "$WORK/marked/typo.want"
printf '\357\273\277import app/greeter::{polite}\n\nputs polite\n' > "$WORK/marked/using.want"
(cd "$WORK/marked" && "$IYI" fix typo.iyi && "$IYI" fix using.iyi) > "$WORK/marked.txt" 2>&1; marked_code=$?
if [ "$marked_code" -eq 0 ] && cmp -s "$WORK/marked/typo.iyi" "$WORK/marked/typo.want" &&
   cmp -s "$WORK/marked/using.iyi" "$WORK/marked/using.want"; then
  echo "  fix on line 1 behind a byte order mark: the edit and the using rewrite land where they are"
else
  echo "  fix behind a byte order mark (exit $marked_code):"; sed 's/^/    /' "$WORK/marked.txt" | head -3; status=1
fi
# The formats a program reads name a file the way a repository does, on
# every system. On Windows `vet -f json`, `csv` and `codecov` wrote
# `app\helpers.iyi` (`app\\helpers.iyi` in JSON), which codecov's
# repository paths and a csv joined across machines never match.
mkdir -p "$WORK/vetdir/app"
printf 'module app/helpers\n\npub def used : Int32\n  1\nend\n\npub def unused_h : Int32\n  2\nend\n' > "$WORK/vetdir/app/helpers.iyi"
printf 'import app/helpers::{used}\n\nputs used\n' > "$WORK/vetdir/main.iyi"
for vet_format in json csv codecov; do
  (cd "$WORK/vetdir" && "$IYI" vet -f "$vet_format" main.iyi) > "$WORK/vet.$vet_format" 2>&1
  if grep -qF 'app/helpers.iyi' "$WORK/vet.$vet_format" && ! grep -qF '\' "$WORK/vet.$vet_format"; then
    echo "  vet -f $vet_format names app/helpers.iyi with /"
  else
    echo "  vet -f $vet_format: $(head -c 160 "$WORK/vet.$vet_format")"
    status=1
  fi
done

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
# Windows has no fork, so no daemon: it was told to `make iyi-daemon`, a
# target Makefile.win does not have.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    refuses "a daemon on Windows" "there is no daemon on Windows" -- \
      "$IYI" daemon start --socket "$WORK/short.sock"
    ;;
esac
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
# The remedies are ones that can work. The long-path refusal said to set
# TMPDIR, which moves the default socket on no system - it is
# `daemon.sock` in the cache directory - and on Windows, where there is no
# daemon, `daemon build` said "start one with `iyi daemon start`" and the
# stale file was to be removed so that one could listen there.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    refuses "no daemon on a socket, on Windows" "there is no daemon on Windows" -- \
      "$IYI" daemon build --socket "$WORK/absent.sock" -o d6 good.iyi
    refuses "a stale socket file, on Windows" "there is no daemon on Windows" -- \
      "$IYI" daemon build --socket "$WORK/stale.sock" -o d7 good.iyi
    refuses "a socket path past the kernel's limit, on Windows" "there is no daemon on Windows" -- \
      "$IYI" daemon build --socket "$long" -o d8 good.iyi
    ;;
  *)
    refuses "a default socket past the kernel's limit" "CACHE_DIR to a shorter directory" -- \
      env IYI_CACHE_DIR="$WORK/$(printf 'c%.0s' $(seq 1 120))" "$IYI" daemon build -o d6 good.iyi
    ;;
esac

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
# `$ORIGIN` on its own, the compiler's directory: the expansion read the
# character after the name without asking whether there was one, and an
# `IYI_PATH` holding it died of "Index out of bounds (IndexError)" and
# "you've found a bug in the iyi compiler".
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) sep=';' ;;
  *) sep=':' ;;
esac
env IYI_PATH="$REPO/src$sep\$ORIGIN" "$IYI" build -o origin good.iyi > "$WORK/origin.txt" 2>&1
if [ "$(./origin 2>&1 | tr -d '\r')" = "ok" ] && ! has_trace "$WORK/origin.txt"; then
  echo "  a search path holding \$ORIGIN alone: builds"
else
  echo "  a search path holding \$ORIGIN alone:"; sed -n '1,3p' "$WORK/origin.txt"; status=1
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
# The same file under another spelling. NTFS and APFS ignore case, and
# Win32 drops a trailing space, and the refusal compared strings:
# `-o GOOD.iyi good.iyi` on Windows linked the program over its source,
# exit 0. Asked only where the file system says the two names are one.
if [ GOOD.iyi -ef good.iyi ]; then
  refuses "an output that is the source in another case" "the source it would build from" -- \
    "$IYI" build -o GOOD.iyi good.iyi
  cmp -s good.iyi good.keep || { echo "  GOOD.iyi replaced good.iyi"; cp good.keep good.iyi; status=1; }
  refuses "an output that is an imported module in another case" "a file this build read" -- \
    "$IYI" build -o app/LIB.iyi user.iyi
  cmp -s app/lib.iyi lib.keep || { echo "  app/LIB.iyi replaced app/lib.iyi"; cp lib.keep app/lib.iyi; status=1; }
fi
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    refuses "an output that is the source with a trailing space" "the source it would build from" -- \
      "$IYI" build -o "good.iyi " good.iyi
    cmp -s good.iyi good.keep || { echo "  \"good.iyi \" replaced good.iyi"; cp good.keep good.iyi; status=1; }
    ;;
esac
mkdir -p "$WORK/readonly"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) ;;
  *) chmod 500 "$WORK/readonly" ;;
esac
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
# On Windows the mode bits are not the permission, an ACL is: a deny of
# write on the directory is what binds there, and the compiler's question -
# `File.writable?` of a directory - answered yes to it, so the refusal came
# as the linker's LNK1104 after a whole compilation.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" icacls "$(cygpath -w "$WORK/readonly")" /deny "$USERNAME:(WD,AD)" > /dev/null
    candidates="$WORK/readonly" ;;
  *) candidates="$WORK/readonly /sys /proc" ;;
esac
# Asked by writing, not by `test -w`: under Git's shell that reads the
# mode bits and says yes to a directory an ACL denies.
for candidate in $candidates; do
  if [ -d "$candidate" ] && ! (touch "$candidate/.iyi_probe" && rm -f "$candidate/.iyi_probe") 2>/dev/null; then
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
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" icacls "$(cygpath -w "$WORK/readonly")" /remove:d "$USERNAME" > /dev/null ;;
  *) chmod 700 "$WORK/readonly" ;;
esac
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
# And the formatter on a file that imports a package, which is the ordinary
# shape of III.7. A host segment — `example.test` — is one segment to the
# parser, which reads its dots off the characters, and three tokens to the
# lexer; the formatter consumed one token per segment and fell behind its
# own stream, so it raised and the command turned that into "there's a bug
# formatting '<file>', to show more information, please run..." — a bug
# report request about valid source. Every file importing a package was
# unformattable. The tree-wide `--check` never saw it because this
# repository's own `.iyi` files import local modules.
printf 'import   example.test/user/lib::{value}\n\nx=value\n' > "$WORK/pkg.iyi"
if ! "$IYI" tool format "$WORK/pkg.iyi" > "$WORK/pkg.txt" 2>&1; then
  echo "  a package import: the formatter would not format it"
  sed -n '1,4p' "$WORK/pkg.txt"
  status=1
elif [ "$(cat "$WORK/pkg.iyi")" != "$(printf 'import example.test/user/lib::{value}\n\nx = value')" ]; then
  echo "  a package import: the formatter rewrote the path"
  cat "$WORK/pkg.iyi"
  status=1
elif ! "$IYI" tool format --check "$WORK/pkg.iyi" > "$WORK/pkg2.txt" 2>&1; then
  echo "  a package import: formatting it twice produced changes"
  sed -n '1,4p' "$WORK/pkg2.txt"
  status=1
else
  echo "  a package import: the spacing is tidied, the path is untouched"
fi

# Which language a pipe carries is the one question a path answers and a
# pipe does not, and the whole compiler reads the answer off the extension:
# `!` is one token in a `.iyi` file and another in a `.cr` one. Stdin was
# named `STDIN`, which ends in neither, so `iyi tool format -` read iyi
# source as Crystal — the one language this binary is not for — and
# answered valid source with a syntax error on `!`. Stdin is iyi now, and
# `--stdin-filename` is how an editor says where the buffer came from.
printf 'def f : Nil | Cancelled\n  sleep(1)!\nend\n\nf\n' > "$WORK/piped.iyi"
cp "$WORK/piped.iyi" "$WORK/piped_file.iyi"
"$IYI" tool format "$WORK/piped_file.iyi" > /dev/null 2>&1
if ! "$IYI" tool format - < "$WORK/piped.iyi" > "$WORK/piped.out" 2>&1; then
  echo "  iyi source through a pipe: refused"
  sed -n '1,3p' "$WORK/piped.out"
  status=1
elif ! cmp -s "$WORK/piped.out" "$WORK/piped_file.iyi"; then
  echo "  iyi source through a pipe: formatted unlike the same bytes in a file"
  diff "$WORK/piped_file.iyi" "$WORK/piped.out" | sed -n '1,6p'
  status=1
else
  echo "  iyi source through a pipe: formats as the same bytes in a .iyi file"
fi
# And the flag decides, rather than being decoration: the same bytes, read
# by the other language's rules, fail on `!` — and the message names the
# path the caller gave rather than a pipe.
if "$IYI" tool format --stdin-filename x.cr - < "$WORK/piped.iyi" > "$WORK/named.out" 2>&1; then
  echo "  --stdin-filename x.cr: read iyi's ! as Crystal's and formatted it anyway"
  status=1
elif grep -q "syntax error in 'x.cr:" "$WORK/named.out"; then
  echo "  --stdin-filename x.cr: reads the pipe as Crystal, and says which path"
else
  echo "  --stdin-filename x.cr: refused for some other reason"
  sed -n '1,3p' "$WORK/named.out"
  status=1
fi
refuses "--stdin-filename with no pipe to read" "pass '-'" -- \
  "$IYI" tool format --stdin-filename x.cr good.iyi

# The same question a third time, and this one is not a tool's: a macro
# expansion is named by a `VirtualFile`, which ends in neither extension, so
# expansions were parsed by the other language's rules. There `foo!` is one
# identifier, so the rule that `!` is not part of a name (III.1.7) held in
# source and not in what a macro wrote — which is how the prelude came to
# declare `to_i!` and six siblings on five structs. Code a macro generates
# is in the language of the file it expands in, so the rule reaches it.
cat > "$WORK/macro_name.iyi" <<'IYI'
macro declare
  def value! : Int32
    1
  end
end

declare
puts value
IYI
refuses "a macro that declares a name ending in !" "part of a name in iyi" -- \
  "$IYI" build -o "$WORK/macro_name" "$WORK/macro_name.iyi"

# And the other direction, which is the one that cost something: `!` is the
# operator a caller's signature is written for, and no macro could produce
# it. `v = to_number(t)!` came back "undefined local variable or method
# 'to_number!'", and with the parentheses in front of the `!`, "unexpected
# token". Code a macro writes is iyi now, so it propagates the way code a
# person writes does — both branches, because a propagation that never
# carries an error proves half of it.
cat > "$WORK/macro_bang.iyi" <<'IYI'
struct ParseError
  getter text : String

  def initialize(@text : String)
  end
end

impl Error for ParseError
  def message : String
    "not a number: #{text}"
  end
end

def to_number(text : String) : Int32 | ParseError
  return ParseError.new(text) unless text == "12"
  12
end

macro doubled(text)
  to_number({{ text }})! * 2
end

def doubled_number(text : String) : Int32 | ParseError
  doubled(text)
end

["12", "x"].each do |text|
  case doubled_number(text)
  in Int32      then puts "doubled #{it}"
  in ParseError then puts it.message
  end
end
IYI
if ! "$IYI" build -o "$WORK/macro_bang" "$WORK/macro_bang.iyi" > "$WORK/macro_bang.log" 2>&1; then
  echo "  a macro that writes !: the program did not build"
  sed -n '1,6p' "$WORK/macro_bang.log"
  status=1
elif ! "$WORK/macro_bang" > "$WORK/macro_bang.out" 2>&1; then
  echo "  a macro that writes !: the program did not run"
  sed -n '1,4p' "$WORK/macro_bang.out"
  status=1
elif [ "$(cat "$WORK/macro_bang.out")" != "$(printf 'doubled 24\nnot a number: x')" ]; then
  echo "  a macro that writes !: answered"
  cat "$WORK/macro_bang.out"
  status=1
else
  echo "  a macro that writes !: propagates, and carries the value when there is one"
fi

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
# The two libraries, mixed. `--crystal` gives a program Crystal's standard
# library (SPEC.md item 12d) and `src/std` is written in iyi against iyi's
# prelude, so importing one from the other cannot work — and what it
# answered was `undefined constant IyiFloatText`, an internal name of a
# prelude this build does not have, pointing into a file the author never
# opened. An artifact of the same module has been refused by name since
# IV.5; this is the source it is built from.
printf 'import std/json\n\nputs 1\n' > std_in_crystal.iyi
refuses "iyi's std in a build that asked for Crystal's" \
  "is iyi's standard library" -- "$IYI" check --crystal std_in_crystal.iyi
# And the two builds it must not touch: the same import without
# `--crystal`, and a module of the author's own with `--crystal`.
if "$IYI" check std_in_crystal.iyi > std_ok.log 2>&1; then
  echo "  the same import without --crystal still compiles"
else
  echo "  a plain build of an std import was refused:"; head -3 std_ok.log; status=1
fi
mkdir -p mine
printf 'module mine/util\n\npub def two : Int32\n  2\nend\n' > mine/util.iyi
printf 'import mine/util::{two}\n\nputs two\n' > own_crystal.iyi
if "$IYI" check --crystal own_crystal.iyi > own_crystal.log 2>&1; then
  echo "  a module of the author's own is not std, and --crystal takes it"
else
  echo "  --crystal refused a module that is not std:"; head -3 own_crystal.log; status=1
fi

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
# The caret in a macro's expanded text, under a `{{x}}` that starts a
# line. The parser's look for a `.` after `a = 1` reads into the next
# line's interpolation, and a lookahead that failed put back the position
# and not the location pragmas it had fired (the lexer's location_pragma
# cursor is rewound now): `nope` in `  {{x}}.nope` was at column 8, and
# the caret stood under its `e`.
printf 'module interp\n\nmacro m(x)\n  a = 1\n  {{x}}.nope\nend\nm(1)\n' > interp.iyi
"$IYI" check interp.iyi > interp.out 2>&1
if [ "$(grep -A1 '^ > 2 | 1.nope$' interp.out | sed -n '2p')" = "$(printf '%9s^---' '')" ]; then
  echo "  the caret after an interpolation that starts a line of macro text is under the column"
else
  echo "  the caret after an interpolation that starts a line of macro text:"
  sed -n '1,20p' interp.out | cat -A
  status=1
fi
# The caret under a line with tabs inside it: every character before the
# column was counted as one space, so two tabs that pushed `nope` to
# column 34 left the caret at 17. The caret line carries the shown line's
# tabs now, and a terminal expands both the same way.
printf 'module tabbed\n\nx = 1\nputs(\tx,\t\tx.nope)\n' > tabbed.iyi
"$IYI" check tabbed.iyi > tabbed.out 2>&1
caret_line="$(grep -A1 '^ 4 | ' tabbed.out | sed -n '2p')"
if [ "$caret_line" = "$(printf '          \t  \t\t  ^---')" ]; then
  echo "  the caret under a line with tabs carries the line's tabs"
else
  echo "  the caret under a line with tabs is not under the column:"
  sed -n '1,8p' tabbed.out | cat -A
  status=1
fi
# And a wide character, which a terminal draws in two cells: the caret
# counted each as one, so seven CJK characters in front of `nope` left it
# seven cells short. It is padded by the cells each character takes now
# (`caret_padding`).
printf 'module wide\n\ns = "\346\227\245\346\234\254\350\252\236\343\203\206\343\202\255\343\202\271\343\203\210"; puts s.nope\n' > wide.iyi
"$IYI" check wide.iyi > wide.out 2>&1
caret_line="$(grep -A1 '^ 3 | ' wide.out | sed -n '2p')"
if [ "$caret_line" = "$(printf '%34s^---' '')" ]; then
  echo "  the caret after wide characters is under the column a terminal draws"
else
  echo "  the caret after wide characters is not under the column:"
  sed -n '1,8p' wide.out | cat -A
  status=1
fi
# And an abstract class instantiated, which was reported at the prelude's
# `class Reference`, where a generated `new` and its `allocate` are made;
# `-f json`'s deepest frame had file "" and line null.
printf 'module absnew\n\nabstract class A\nend\nA.new\n' > absnew.iyi
"$IYI" check absnew.iyi > absnew.out 2>&1
"$IYI" check -f json absnew.iyi > absnew.json 2>&1
if grep -q '^In absnew.iyi:5:3' absnew.out && grep -q "can't instantiate abstract class" absnew.out &&
   grep -q "\"line\":5,\"column\":3,\"size\":3,\"message\":\"can't instantiate abstract class" absnew.json; then
  echo "  an abstract class instantiated is refused at the call"
else
  echo "  an abstract class instantiated is not refused at the call:"
  sed -n '1,6p' absnew.out; cat absnew.json; echo
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
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
      MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" icacls "$(cygpath -w "$WORK/readonly")" /deny "$USERNAME:(WD,AD)" > /dev/null ;;
    *) chmod 500 "$WORK/readonly" ;;
  esac
  refuses "a --mods directory that will not take the files" "no permission to write there" -- \
    "$IYI" bind --lib bindhere/lib --mods "$unwritable"
  refuses "a --out directory that will not take the modules" "no permission to write there" -- \
    "$IYI" migrate tree --out "$unwritable"
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
      MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" icacls "$(cygpath -w "$WORK/readonly")" /remove:d "$USERNAME" > /dev/null ;;
    *) chmod 700 "$WORK/readonly" ;;
  esac
fi
# As the author typed it, like `--lib` and `--mods` above: the expanded
# path was a different string on Windows — 8.3 names long, separators
# swapped — from the one on the command line.
refuses "a file where --out's directory goes" "and bindhere/shard.yml is a file" -- \
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
