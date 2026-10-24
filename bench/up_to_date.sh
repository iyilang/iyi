#!/usr/bin/env bash
# `iyi build` with nothing changed compiles nothing; with anything changed
# it compiles, and the program it writes is the new one (SPEC.md V.9 (e)).
#
#     bash bench/up_to_date.sh
#
# The project is small and has one of each kind of input a build reads: a
# module, a module that embeds an EIY template (a macro `run` that names the
# file it read), a module whose macro reads an environment variable and one
# that asks `flag?`. Built once, then:
#
#   * built again with nothing changed: the build says it is up to date, runs
#     no stage of the compiler, and takes a fraction of a forced rebuild;
#   * a source edited, only the template edited, the variable changed, a flag
#     added, the output deleted, an artifact touched, a library the link
#     read replaced, another compiler: each one builds again, says why, and
#     the program prints what the change says it should — and the build
#     after it is up to date again;
#   * an input that cannot be listed — a macro that runs a command, a `run`
#     program that names nothing — turns the check off and says so;
#   * each input broken: the source with a syntax error, the template with a
#     tag never closed, the variable set to a value the macro refuses, a flag
#     the macro refuses, a file where the output was, an artifact with a byte
#     flipped. A check that missed the class would say "is up to date" and
#     exit 0 over the broken input; each has to fail, in the compiler's words
#     for that input, or rebuild;
#   * broken copies of the record, each with one class of input taken out of
#     it: the same change is then taken for up to date, which is what says
#     each rebuild above came from the entry for that class.
#
# On a compiler without the check (`IYI=... bash bench/up_to_date.sh` with
# 0.19.1's) the first step fails: nothing says it was rebuilt or up to date.
#
# Each step waits a second after it writes, because a file written inside
# the tick its file system's clock can resolve is one the record does not
# vouch for by its time alone (`BuildInputs.racy?`): the build after it
# compiles again, which is safe, and is not what the step is testing.
#
# Exits non-zero if any of it does not hold.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    EXE=.exe
    ;;
  *) EXE= ;;
esac
trap 'rm -rf "$WORK"' EXIT

# Windows answers `python3` with a store stub that prints and exits, so the
# interpreter is measured here instead of assumed.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

export IYI_PATH="$REPO/src"
export IYI_CACHE_DIR="$WORK/cache"
unset UPTODATE_MODE
status=0

say() {
  if [ "$2" -eq 0 ]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1"
    status=1
  fi
}

mkdir -p "$WORK/p/app"
cd "$WORK/p" || exit 1

cat > main.iyi <<'EOF'
module main

import app/greet
import app/page
import app/config

puts App::Greet.hello("world")
puts App::Page.render("loop")
puts App::Config.mode
EOF
cat > app/greet.iyi <<'EOF'
module app/greet

pub def hello(name : String) : String
  "hello, #{name}"
end
EOF
cat > app/page.iyi <<'EOF'
module app/page

import std/eiy::{Eiy}

pub class Page
  getter title : String

  def initialize(@title : String)
  end

  Eiy.def_to_s("page.eiy")
end

pub def render(title : String) : String
  Page.new(title).to_s
end
EOF
printf '<h1><%%= title %%></h1>\n' > app/page.eiy
cat > app/config.iyi <<'EOF'
module app/config

{% if env("UPTODATE_MODE") == "broken" %}
  {% raise "UPTODATE_MODE is broken" %}
{% end %}
{% if flag?(:broken) %}
  {% raise "built with -Dbroken" %}
{% end %}

pub def mode : String
  {% if flag?(:loud) %}
    {{ (env("UPTODATE_MODE") || "plain").upcase }}
  {% else %}
    {{ env("UPTODATE_MODE") || "plain" }}
  {% end %}
end
EOF
sleep 1

# One build of the project, its output in $WORK/b.log.
build() {
  "$IYI" build -s -o prog main.iyi "$@" > "$WORK/b.log" 2>&1
}

# Up to date: said so, no stage of the compiler ran, exit 0.
skipped() {
  [ "$1" -eq 0 ] && grep -q "${OUT:-prog}$EXE is up to date" "$WORK/b.log" && ! grep -q '^Semantic' "$WORK/b.log"
}

# The build's words with Windows' separators read as `/`, so that one
# sentence about `app/greet.iyi` matches on every platform.
said() {
  tr '\\' '/' < "$WORK/b.log" | grep -qF -- "$1"
}

# Built again, for the reason given, and the compiler ran.
rebuilt() {
  [ "$1" -eq 0 ] && said "Up-to-date check: rebuilding: $2" && grep -q '^Semantic (main)' "$WORK/b.log" &&
    ! grep -q "is up to date" "$WORK/b.log"
}

# What the program prints, on one line.
prints() {
  [ "$(./prog$EXE | tr -d '\r' | tr '\n' '|')" = "$1" ]
}

# A broken input is noticed: not up to date, and refused in the compiler's
# own words for it.
refused() {
  [ "$1" -ne 0 ] && ! grep -q "is up to date" "$WORK/b.log" && said "$2"
}

echo "== the first build, and the next with nothing changed"
build; code=$?
say "the first build compiles" "$(rebuilt $code 'this output has no record'; echo $?)"
say "and the program prints what the sources say" "$(prints 'hello, world|<h1>loop</h1>|plain|'; echo $?)"
build; code=$?
say "nothing changed: up to date, and nothing compiled" "$(skipped $code; echo $?)"
grep 'Up-to-date check: none of' "$WORK/b.log" | sed 's/^/       /'

# Quickly: against a forced rebuild of the same program, the median of
# five each, which is the comparison that survives a slow machine. Each
# skipped build follows a forced one at once, which is the edit loop's
# rhythm and the case that was slow: an output written a moment ago is one
# whose time cannot vouch for it, and the recorder read the whole program
# to fingerprint it before it knew the file was the output - 1.97 s against
# 0.018 s on a debug compiler and a 1.3 MB program.
if [ -n "$PY" ]; then
  timing=$("$PY" - "$IYI" <<'PY'
import statistics, subprocess, sys, time
iyi = sys.argv[1]
def timed(extra):
    start = time.perf_counter()
    subprocess.run([iyi, "build"] + extra + ["-o", "prog", "main.iyi"], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return time.perf_counter() - start
pairs = [(timed(["--force"]), timed([])) for _ in range(5)]
forced = statistics.median(pair[0] for pair in pairs)
skipped = statistics.median(pair[1] for pair in pairs)
print(f"{skipped:.3f} {forced:.3f} {'ok' if skipped * 4 < forced else 'slow'}")
PY
)
  echo "       skipped $(echo "$timing" | cut -d' ' -f1) s against $(echo "$timing" | cut -d' ' -f2) s forced (medians of 5)"
  say "a skipped build costs under a quarter of a forced one" "$([ "$(echo "$timing" | cut -d' ' -f3)" = ok ]; echo $?)"
else
  echo "  no python3 on this machine, so the timing is unmeasured"
fi
build --force; code=$?
say "--force compiles anyway" "$(rebuilt $code '--force'; echo $?)"
# And at once, before the output's time can vouch for it: what the timing
# above measures, asked of what the build says it read. The output is the
# record's to stamp, not an input to fingerprint.
build; code=$?
say "right after a build, up to date without reading the program to fingerprint it" \
  "$(skipped $code && ! grep -q "fingerprinted.*prog$EXE" "$WORK/b.log"; echo $?)"

echo "== each kind of input, changed"
sed 's/hello, /hi, /' app/greet.iyi > app/greet.tmp && mv app/greet.tmp app/greet.iyi
sleep 1
build; code=$?
say "a source edited: rebuilt, naming it" "$(rebuilt $code 'app/greet.iyi changed'; echo $?)"
say "and the program says hi" "$(prints 'hi, world|<h1>loop</h1>|plain|'; echo $?)"
build; code=$?
say "then up to date again" "$(skipped $code; echo $?)"

printf '<h2><%%= title %%></h2>\n' > app/page.eiy
sleep 1
build; code=$?
say "only the template edited: rebuilt, naming it" "$(rebuilt $code 'app/page.eiy changed'; echo $?)"
say "and the page is the new template's" "$(prints 'hi, world|<h2>loop</h2>|plain|'; echo $?)"
build; code=$?
say "then up to date again" "$(skipped $code; echo $?)"

UPTODATE_MODE=fancy build; code=$?
say "the variable the macro read, changed: rebuilt, naming it" "$(rebuilt $code 'UPTODATE_MODE is "fancy", and was unset'; echo $?)"
say "and the program carries the new value" "$(prints 'hi, world|<h2>loop</h2>|fancy|'; echo $?)"
UPTODATE_MODE=fancy build; code=$?
say "then up to date again" "$(skipped $code; echo $?)"
build; code=$?
say "and unset again: rebuilt" "$(rebuilt $code 'UPTODATE_MODE is unset, and was "fancy"'; echo $?)"

build -Dloud; code=$?
say "a flag added: rebuilt, naming the command line" "$(rebuilt $code 'the command line is'; echo $?)"
say "and the program is the flag's" "$(prints 'hi, world|<h2>loop</h2>|PLAIN|'; echo $?)"
build -Dloud; code=$?
say "then up to date again" "$(skipped $code; echo $?)"
build; code=$?
say "and the flag taken away: rebuilt" "$(rebuilt $code 'the command line is'; echo $?)"
"$IYI" build --verbose -o prog main.iyi > "$WORK/b.log" 2>&1; code=$?
say "a switch that changes only what is printed is the same command line" "$(skipped $code; echo $?)"

rm -f "prog$EXE"
build; code=$?
say "the output deleted: rebuilt, naming it" "$(rebuilt $code "prog$EXE is gone"; echo $?)"
say "and the program is back" "$(prints 'hi, world|<h2>loop</h2>|plain|'; echo $?)"

# Artifacts: the IV.3 loop, which reads modules back from `mods`.
abuild() {
  "$IYI" build -s --emit-iyimod mods --use-iyimod mods -o prog main.iyi "$@" > "$WORK/b.log" 2>&1
}
abuild; abuild; code=$?
say "with artifacts, nothing changed: up to date" "$(skipped $code; echo $?)"
sleep 1
touch mods/app/greet.iyimod
abuild; code=$?
say "an artifact touched: rebuilt, naming it" "$(rebuilt $code 'mods/app/greet.iyimod changed'; echo $?)"
say "and the program is the same program" "$(prints 'hi, world|<h2>loop</h2>|plain|'; echo $?)"
abuild; code=$?
say "then up to date again" "$(skipped $code; echo $?)"

# A library the link read: the compiler's command names `-luptodate`, and
# the check finds the file the linker would, the way the linker finds it.
# Unix only, where `cc` and `ar` make the library; an MSVC link wants a
# `.lib`, which this would need `lib.exe` for.
echo "== a library the link read"
have_ar=no
if [ -z "$EXE" ] && command -v cc >/dev/null 2>&1 && command -v ar >/dev/null 2>&1; then
  have_ar=yes
fi
library() {
  printf 'int uptodate_answer(void) { return %s; }\n' "$1" > "$WORK/answer.c"
  cc -c -o "$WORK/answer.o" "$WORK/answer.c" && rm -f lib/libuptodate.a && ar rcs lib/libuptodate.a "$WORK/answer.o"
}
lbuild() {
  "$IYI" build -s --link-flags "-L$WORK/p/lib" -o linked linked.iyi "$@" > "$WORK/b.log" 2>&1
}
if [ "$have_ar" = yes ]; then
  mkdir -p lib
  library 41
  cat > linked.iyi <<'EOF'
module linked

@[Link("uptodate")]
lib LibUptodate
  fun uptodate_answer : Int32
end

puts LibUptodate.uptodate_answer
EOF
  sleep 1
  OUT=linked
  lbuild; lbuild; code=$?
  say "a program linking a library, nothing changed: up to date" "$(skipped $code; echo $?)"
  library 42
  sleep 1
  lbuild; code=$?
  say "the library replaced: rebuilt, naming it" "$(rebuilt $code 'lib/libuptodate.a changed'; echo $?)"
  say "and the program is linked against the new one" "$([ "$(./linked)" = 42 ]; echo $?)"
  lbuild; code=$?
  say "then up to date again" "$(skipped $code; echo $?)"
  OUT=prog
else
  echo "  no cc and ar here (or an MSVC link), so the library step is unmeasured"
fi

# Another compiler: a copy of this one, beside it so that it finds what the
# original finds (Windows' DLLs, the `$ORIGIN` rpath). A rebuilt compiler is
# a new file at the same path; a copy is the same bytes at another path, and
# both are a compiler that did not build this output.
echo "== another compiler"
# `bin/iyi` is a script that runs `.build/iyi`, however `$REPO` is spelled.
case "$IYI" in
  */bin/iyi) real="$(dirname "$(dirname "$IYI")")/.build/iyi$EXE" ;;
  *) real="$IYI" ;;
esac
copy="$(dirname "$real")/iyi-up-to-date-copy$EXE"
if cp -p "$real" "$copy" 2>/dev/null; then
  trap 'rm -rf "$WORK"; rm -f "$copy"' EXIT
  build; build; code=$?
  say "(starting from up to date)" "$(skipped $code; echo $?)"
  "$copy" build -s -o prog main.iyi > "$WORK/b.log" 2>&1; code=$?
  say "built by another compiler: rebuilt, naming it" "$(rebuilt $code 'the compiler is not the one that built it'; echo $?)"
  say "and the program is the same program" "$(prints 'hi, world|<h2>loop</h2>|plain|'; echo $?)"
  "$copy" build -s -o prog main.iyi > "$WORK/b.log" 2>&1; code=$?
  say "then up to date for that compiler" "$(skipped $code; echo $?)"
  build; code=$?
  say "and back to this one: rebuilt" "$(rebuilt $code 'the compiler is not the one that built it'; echo $?)"
else
  echo "  $(dirname "$real") takes no copy of the compiler, so the compiler step is unmeasured"
  copy=""
fi

echo "== inputs the check cannot list"
cat > sys.iyi <<'EOF'
module sys

puts {{ `echo from-a-command`.stringify }}
EOF
cat > gen.iyi <<'EOF'
module gen

puts "1"
EOF
cat > runner.iyi <<'EOF'
module runner

puts {{ run("./gen").stringify }}
EOF
sleep 1
for program in sys runner; do
  "$IYI" build -s -o "$program" "$program.iyi" > "$WORK/b.log" 2>&1
  "$IYI" build -s -o "$program" "$program.iyi" > "$WORK/b.log" 2>&1; code=$?
  case "$program" in
    sys) why="a macro runs a command at sys.iyi:3" ;;
    runner) why='did not say which files it read' ;;
  esac
  say "$program: the second build compiles too, and the first said why" \
    "$([ $code -eq 0 ] && ! grep -q 'is up to date' "$WORK/b.log" && grep -qF "the next build compiles: " "$WORK/b.log" && grep -qF "$why" "$WORK/b.log"; echo $?)"
done

echo "== broken inputs: each input class, broken, is refused rather than taken as up to date"
build >/dev/null; build; code=$?
say "(starting from up to date)" "$(skipped $code; echo $?)"

cp app/greet.iyi "$WORK/greet.keep"
printf 'pub def hello(name : String) : String\n  "hello, #{name}"\n' >> app/greet.iyi
sleep 1
build; code=$?
say "a source that does not parse" "$(refused $code 'expecting'; echo $?)"
cp "$WORK/greet.keep" app/greet.iyi; sleep 1; build

printf '<h2><%%= title \n' > app/page.eiy
sleep 1
build; code=$?
say "a template with a tag never closed" "$(refused $code 'page.eiy'; echo $?)"
printf '<h2><%%= title %%></h2>\n' > app/page.eiy; sleep 1; build

UPTODATE_MODE=broken build; code=$?
say "the variable set to a value the macro refuses" "$(refused $code 'UPTODATE_MODE is broken'; echo $?)"

build -Dbroken; code=$?
say "a flag the macro refuses" "$(refused $code 'built with -Dbroken'; echo $?)"

build; build; code=$?
printf 'not a program\n' > "prog$EXE"
sleep 1
build; code=$?
say "a file where the output was: rebuilt" "$(rebuilt $code "prog$EXE changed"; echo $?)"
say "and it runs" "$(prints 'hi, world|<h2>loop</h2>|plain|'; echo $?)"

abuild; abuild; code=$?
if [ -n "$PY" ]; then
  "$PY" - <<'PY'
p = "mods/app/greet.iyimod"
b = bytearray(open(p, "rb").read())
b[len(b) // 2] ^= 1
open(p, "wb").write(b)
PY
  sleep 1
  abuild; code=$?
  say "an artifact with a byte flipped" "$(refused $code 'mods/app/greet.iyimod: the'; echo $?)"
else
  echo "  no python3 on this machine, so the flipped artifact is unmeasured"
fi

# A broken copy of the record: the one the last build wrote, with one class
# of input taken out of it, as a recorder that missed that class would have
# written it. Then the change that class is there to see. The build has to
# take the change for up to date - the step above that asserts a rebuild
# would fail on this check - which is what says that step's rebuild came
# from that entry and not from something else the change happened to move.
echo "== broken copies of the record: each class taken out, and its change missed"
unrecord() {
  "$PY" - "$WORK/cache" "$@" <<'PY'
import glob, json, os, sys
cache, output, what, arg = sys.argv[1:5]
def slashed(path):
    return path.replace("\\", "/")
found = []
for path in glob.glob(os.path.join(cache, "**", "up-to-date-*.json"), recursive=True):
    with open(path, encoding="utf-8") as handle:
        record = json.load(handle)
    if any(slashed(entry[0]).endswith("/" + output) for entry in record["files"]):
        found.append((path, record))
if len(found) != 1:
    sys.exit(f"{len(found)} records name {output}")
path, record = found[0]
if what == "file":
    kept = [entry for entry in record["files"] if not slashed(entry[0]).endswith("/" + arg)]
    if len(kept) != len(record["files"]) - 1:
        sys.exit(f"{arg} is not in the record once")
    record["files"] = kept
elif what == "env":
    if arg not in record["env"]:
        sys.exit(f"{arg} is not in the record")
    del record["env"][arg]
elif what == "argument":
    record["arguments"].append(arg)
elif what == "compiler":
    stat = os.stat(arg)
    record["compiler"] = "|".join([record["compiler"].rsplit("|", 3)[0], os.path.realpath(arg),
                                   str(stat.st_size), str(stat.st_mtime_ns)])
with open(path, "w", encoding="utf-8") as handle:
    json.dump(record, handle)
PY
}

# missed <label> <code>: the broken record took the change for up to date.
missed() {
  say "$1" "$(skipped "$2"; echo $?)"
}

if [ -n "$PY" ]; then
  rm -rf mods
  build --force; build; code=$?
  say "(starting from up to date)" "$(skipped $code; echo $?)"

  unrecord "prog$EXE" file app/greet.iyi
  sed 's/hi, /hey, /' app/greet.iyi > app/greet.tmp && mv app/greet.tmp app/greet.iyi
  sleep 1
  build; code=$?
  missed "without app/greet.iyi, the source edit is missed" $code
  sed 's/hey, /hi, /' app/greet.iyi > app/greet.tmp && mv app/greet.tmp app/greet.iyi
  sleep 1; build --force

  unrecord "prog$EXE" file app/page.eiy
  printf '<h3><%%= title %%></h3>\n' > app/page.eiy
  sleep 1
  build; code=$?
  missed "without app/page.eiy, the template edit is missed" $code
  printf '<h2><%%= title %%></h2>\n' > app/page.eiy
  sleep 1; build --force

  unrecord "prog$EXE" env UPTODATE_MODE
  UPTODATE_MODE=fancy build; code=$?
  missed "without UPTODATE_MODE, the variable's change is missed" $code
  build --force

  unrecord "prog$EXE" argument -Dloud
  build -Dloud; code=$?
  missed "with the command line taken for -Dloud's, the flag is missed" $code
  build --force

  unrecord "prog$EXE" file "prog$EXE"
  rm -f "prog$EXE"
  build; code=$?
  missed "without the output's own entry, its deletion is missed" $code
  build --force

  abuild --force; abuild; code=$?
  say "(with artifacts, starting from up to date)" "$(skipped $code; echo $?)"
  unrecord "prog$EXE" file mods/app/greet.iyimod
  sleep 1
  touch mods/app/greet.iyimod
  abuild; code=$?
  missed "without mods/app/greet.iyimod, the artifact's change is missed" $code

  if [ "$have_ar" = yes ]; then
    OUT=linked
    lbuild --force; lbuild; code=$?
    say "(the linked program, starting from up to date)" "$(skipped $code; echo $?)"
    unrecord linked file lib/libuptodate.a
    library 43
    sleep 1
    lbuild; code=$?
    missed "without lib/libuptodate.a, the library's change is missed" $code
    OUT=prog
  fi

  if [ -n "$copy" ]; then
    build --force; build; code=$?
    unrecord "prog$EXE" compiler "$copy"
    "$copy" build -s -o prog main.iyi > "$WORK/b.log" 2>&1; code=$?
    missed "with the copy's identity in the record, the other compiler is missed" $code
  fi
else
  echo "  no python3 on this machine, so the broken records are unmeasured"
fi

exit $status
