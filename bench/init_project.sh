#!/usr/bin/env bash
# `iyi init` writes a project that runs, tests and grounds — and refuses to
# write over one.
#
#     bash bench/init_project.sh
#
# The verb was refused for as long as this fork has had a binary: `init`
# sat in the list of verbs that belong to Crystal, and the refusal told the
# reader to run it "with the `crystal` binary in this checkout" — a person
# who installed the zip has neither. What it writes now is the shape a
# project has here, four files, and the claim is that all four are right
# the moment they land: the entry runs, the test passes, the context pack
# grounds the module the entry imports, and a second `init` changes not one
# byte. Exits non-zero if any of that does not hold.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac
trap 'rm -rf "$WORK"' EXIT

export IYI_PATH="$REPO/src"
status=0

say() {
  if [ "$2" -eq 0 ]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1"
    status=1
  fi
}

cd "$WORK" || exit 1

# ── the project, and what it does on arrival ─────────────────────────────
"$IYI" init example.com/me/hello app > init.txt 2>&1
say "init writes a project and says what it wrote" \
  "$([ $? -eq 0 ] && grep -qE 'wrote app[/\\]greet.iyi' init.txt && grep -q 'iyi test' init.txt; echo $?)"
[ -f app/iyi.mod ] && [ -f app/main.iyi ] && [ -f app/greet.iyi ] && [ -f app/main_test.iyi ]
say "all four files are there" $?
grep -q '^module example.com/me/hello$' app/iyi.mod
say "the manifest names the module" $?

(cd app && "$IYI" run main.iyi) > run.txt 2>&1
say "the entry runs: $(tail -1 run.txt)" "$([ "$(tail -1 run.txt)" = "hello, iyi" ]; echo $?)"

(cd app && "$IYI" test) > test.txt 2>&1
say "the test passes: $(tail -1 test.txt)" "$(grep -q '^1 passed, 0 failed' test.txt; echo $?)"

(cd app && "$IYI" mod context main.iyi) > context.txt 2>&1
say "the context pack grounds the module the entry imports" \
  "$(grep -q '^pub def hello(name : String) : String' context.txt; echo $?)"

# ── nothing written twice ────────────────────────────────────────────────
before="$(cat app/iyi.mod app/main.iyi app/greet.iyi app/main_test.iyi | cksum)"
"$IYI" init example.com/me/hello app > again.txt 2>&1
rc=$?
after="$(cat app/iyi.mod app/main.iyi app/greet.iyi app/main_test.iyi | cksum)"
say "a second init is refused by name" \
  "$([ $rc -ne 0 ] && grep -q 'already has `iyi.mod`' again.txt; echo $?)"
say "and changes not one byte" "$([ "$before" = "$after" ]; echo $?)"

# ── the current directory, and the refusals ──────────────────────────────
mkdir -p here && (cd here && "$IYI" init hello) > here.txt 2>&1
say "init with no directory writes into the current one" \
  "$([ -f here/main.iyi ] && grep -q '^module hello$' here/iyi.mod; echo $?)"
"$IYI" init "Example.com/Me/App" bad > bad.txt 2>&1
say "a path the manifest would refuse is refused before anything is written" \
  "$([ $? -ne 0 ] && grep -q 'is not a module path' bad.txt && [ ! -e bad ]; echo $?)"
"$IYI" init > none.txt 2>&1
say "no module path is a usage error that shows the form" \
  "$([ $? -ne 0 ] && grep -q 'example.com/me/hello' none.txt; echo $?)"
"$IYI" init --help > help.txt 2>&1
say "--help is init's own usage" "$(head -1 help.txt | grep -q '^Usage: .* init MODULE'; echo $?)"

echo
if [ "$status" -eq 0 ]; then
  echo "init gate: every step held"
else
  echo "init gate: a step failed"
fi
exit "$status"
