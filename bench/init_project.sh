#!/usr/bin/env bash
# `iyi init` writes a project that runs - two files, the manifest and the
# root module its name promises - and refuses to write over one.
#
#     bash bench/init_project.sh
#
# The verb was refused for as long as this fork has had a binary: `init`
# sat in the list of verbs that belong to Crystal, and the refusal told the
# reader to run it "with the `crystal` binary in this checkout" - a person
# who installed the zip has neither. It then wrote four files, an entry, a
# module it imported and a test, which every project began by deleting.
# Now `iyi init kemal` is `iyi.mod` and `kemal.iyi`, and the claim is that
# both are right the moment they land: the module runs, a consumer's
# `import` of the package reads it, and a second `init` changes not one
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
  "$([ $? -eq 0 ] && grep -qE 'wrote app[/\\]hello.iyi' init.txt && grep -q 'run hello.iyi' init.txt; echo $?)"
say "two files and no more: iyi.mod and hello.iyi" \
  "$([ "$(ls app | sort | tr '\n' ' ')" = "hello.iyi iyi.mod " ]; echo $?)"
grep -q '^module example.com/me/hello$' app/iyi.mod
say "the manifest names the module" $?
grep -q '^module hello$' app/hello.iyi
say "the file is the root module the name promises" $?

(cd app && "$IYI" run hello.iyi) > run.txt 2>&1
say "it runs: $(tail -1 run.txt)" "$([ "$(tail -1 run.txt)" = "hello from hello" ]; echo $?)"

# A consumer's `import` of the package reads that file: the root module is
# what `import example.com/me/hello` means.
mkdir -p user && printf 'module example.com/me/user\nrequire example.com/me/hello v0.0.1\nreplace example.com/me/hello => ../app\n' > user/iyi.mod
printf 'import example.com/me/hello\n' > user/main.iyi
(cd user && "$IYI" run main.iyi) > use.txt 2>&1
say "a consumer's import of the package reads it" "$([ "$(tail -1 use.txt)" = "hello from hello" ]; echo $?)"

# ── nothing written twice ────────────────────────────────────────────────
before="$(cat app/iyi.mod app/hello.iyi | cksum)"
"$IYI" init example.com/me/hello app > again.txt 2>&1
rc=$?
after="$(cat app/iyi.mod app/hello.iyi | cksum)"
say "a second init is refused by name" \
  "$([ $rc -ne 0 ] && grep -q 'already has `iyi.mod`' again.txt; echo $?)"
say "and changes not one byte" "$([ "$before" = "$after" ]; echo $?)"

# ── the name, the current directory, and the refusals ────────────────────
mkdir -p here && (cd here && "$IYI" init kemal) > here.txt 2>&1
say "init kemal writes iyi.mod and kemal.iyi into the current directory" \
  "$([ "$(ls here | sort | tr '\n' ' ')" = "iyi.mod kemal.iyi " ] && grep -q '^module kemal$' here/iyi.mod; echo $?)"
"$IYI" init github.com/me/iyi-web dash > dash.txt 2>&1
say "a repository name with - is a module name with _" \
  "$([ -f dash/iyi_web.iyi ] && grep -q '^module iyi_web$' dash/iyi_web.iyi; echo $?)"
"$IYI" init example.com/me/lib/v2 major > major.txt 2>&1
say "a /v2 suffix is a version, and the file is the name before it" "$([ -f major/lib.iyi ]; echo $?)"
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
