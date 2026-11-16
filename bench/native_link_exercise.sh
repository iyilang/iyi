#!/usr/bin/env bash
# The native Mach-O executable gate (SPEC 2.3, slice C2).
#
# 1. The driver (src/compiler/tools/link_macho.iyi) builds from source.
# 2. The hand-built program links, prints its message, exits 7 and passes
#    codesign -v --strict. bench/fixtures/native_link/hello.expected holds that.
# 3. For every samples/iyi/*.iyi the Crystal-hosted compiler emits an arm64 Mach-O
#    object and prints its link line. The native linker links that object with
#    the frameworks the link line names. On macOS the two programs run with no
#    stdin and must match on exit status, stdout and stderr. socket and webapp
#    are linked and checked, not run: socket opens a network socket and webapp
#    serves HTTP until it is stopped.
# 4. Every linked executable: codesign -v --strict passes, there is no
#    __stub_helper section, nm -u lists no dyld_stub_binder, otool -L lists
#    libSystem and only the frameworks the link line names, and LC_BUILD_VERSION
#    lists zero tools.
# 5. Tripwire: the driver runs under a PATH whose ld, cc, clang, codesign and
#    dsymutil are shims that log and exit 1. The log must stay empty.
# 6. Each executable links twice to identical bytes (cmp).
# 7. Mutation proofs (macOS): a CodeDirectory page hash, a library ordinal, and a
#    rebase are each broken in a copy of the source. The check must fail.
#
# Needs a built compiler (`make`). The native-darwin job runs every step; on other
# systems the linking, relinking and tripwire steps run and the rest says so.

set -u

root="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$root" || exit 1

triple="${1:-aarch64-apple-darwin}"
iyi=./bin/iyi
driver_src=src/compiler/tools/link_macho.iyi
imports_src=src/compiler/native/link/imports.iyi
codesign_src=src/compiler/native/link/codesign.iyi
link_src=src/compiler/native/link/link.iyi
fixture=bench/fixtures/native_link/hello.expected
darwin=0
if [ "$(uname -s)" = Darwin ]; then darwin=1; fi

work="$(mktemp -d "${TMPDIR:-/tmp}/native_link.XXXXXX")" || exit 1
. bench/lib/native_signature.sh
export NATIVE_SIGNATURE_FAILURE_FILE="$work/signature-failure"
restore=""
backup=""
cleanup() {
  if [ -n "$restore" ] && [ -n "$backup" ]; then
    cp "$backup" "$restore"
  fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

failures=0
fail() {
  echo "   $*"
  failures=$((failures + 1))
}

# Samples that are linked and checked, but not run, each with its reason.
excluded_reason() {
  case "$1" in
    socket) echo "opens a network socket" ;;
    webapp) echo "serves HTTP until it is stopped" ;;
    *) echo "" ;;
  esac
}

# run_program EXE OUT ERR: runs EXE from a scratch directory with no stdin for at
# most 30 seconds, its stdout to OUT and its stderr to ERR, and prints the status.
run_program() {
  rundir="$work/run"
  mkdir -p "$rundir"
  (cd "$rundir" && perl -e 'alarm 30; exec @ARGV' "$1" </dev/null >"$2" 2>"$3")
  echo $?
}

# build_tool: builds the driver from the current source into $work/bin.
build_tool() {
  mkdir -p "$work/bin"
  "$iyi" build -o "$work/bin/link_macho" "$driver_src" >"$work/build-tool.log" 2>&1
}

# check_hello: the hand-built program links with the current driver and matches
# the fixture: its message, exit 7, and a strict signature.
check_hello() {
  build_tool || return 1
  "$work/bin/link_macho" hello "$work/hello" >"$work/hello.link.log" 2>&1 || return 1
  chmod +x "$work/hello"
  native_signature_ok "$work/hello" || return 1
  status="$(run_program "$work/hello" "$work/hello.out" "$work/hello.err")"
  want_msg="$(head -n 1 "$fixture")"
  want_exit="$(tail -n 1 "$fixture" | awk '{print $2}')"
  [ "$status" = "$want_exit" ] && [ "$(cat "$work/hello.out")" = "$want_msg" ] &&
    /usr/bin/codesign -v --strict "$work/hello" >/dev/null 2>&1
}

# check_corpus: every corpus program the current driver links runs as its
# original did. It fails on the first sample that differs.
check_corpus() {
  build_tool || return 1
  for name in $names; do
    if [ -n "$(excluded_reason "$name")" ]; then
      continue
    fi
    fw_args=""
    if ! "$work/bin/link_macho" link "$work/corpus/$name.mut" "$name" $(cat "$work/corpus/$name.fw") "$work/corpus/$name.o" >/dev/null 2>&1; then
      return 1
    fi
    chmod +x "$work/corpus/$name.mut"
    native_signature_ok "$work/corpus/$name.mut" || return 1
    status="$(run_program "$work/corpus/$name.mut" "$work/corpus/$name.mut.out" "$work/corpus/$name.mut.err")"
    if [ "$status" != "$(cat "$work/corpus/$name.status")" ] ||
      ! cmp -s "$work/corpus/$name.out" "$work/corpus/$name.mut.out" ||
      ! cmp -s "$work/corpus/$name.err" "$work/corpus/$name.mut.err"; then
      return 1
    fi
  done
  return 0
}

# prove_mutation LABEL FILE OLD NEW CHECK...: replaces the first OLD in FILE with
# NEW, runs CHECK, and requires it to fail. Restores FILE on every exit path.
prove_mutation() {
  label=$1
  file=$2
  old=$3
  new=$4
  shift 4
  backup="$work/mutation-$RANDOM.bak"
  cp "$file" "$backup" || return 1
  restore="$file"
  python3 - "$file" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
if old not in text:
    sys.exit(3)
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
  patched=$?
  if [ "$patched" -eq 3 ]; then
    cp "$backup" "$file"
    restore=""
    fail "PATCH CHANGED NOTHING: '$label' found no text to change: this proves nothing"
    return 1
  fi
  if [ "$patched" -ne 0 ]; then
    cp "$backup" "$file"
    restore=""
    fail "could not apply '$label'"
    return 1
  fi
  if "$@" >"$work/mutation-check.log" 2>&1; then
    fail "NOT caught: $label"
  else
    echo "   caught: $label"
  fi
  cp "$backup" "$file"
  restore=""
  return 0
}

echo "== 1. build the driver from the source"
if ! build_tool; then
  cat "$work/build-tool.log"
  fail "the driver does not build"
  echo "== SOME NATIVE_LINK CHECKS FAILED"
  exit 1
fi
cp "$work/bin/link_macho" "$work/bin/link_macho.good"

if [ "$darwin" -eq 1 ]; then
  echo "== 2. the hand-built program prints its message, exits 7 and is signed"
  if check_hello; then
    echo "   hello: message, exit 7 and codesign -v --strict as the fixture says"
  else
    fail "the hand-built program does not match $fixture"
  fi
else
  echo "   not run on $(uname -s): the native-darwin job runs the hand-built program"
fi

echo "== 3. link every samples/iyi program from its oracle object"
mkdir -p "$work/corpus"
names=""
for src in samples/iyi/*.iyi; do
  name="$(basename "$src" .iyi)"
  obj="$work/corpus/$name.o"
  if ! "$iyi" build --cross-compile --target "$triple" -o "$obj" "$src" \
      >"$work/corpus/$name.link" 2>"$work/corpus/$name.err"; then
    fail "the oracle does not compile $src"
    continue
  fi
  names="$names $name"
  line="$(tail -n 1 "$work/corpus/$name.link")"
  fw=""
  prev=""
  for word in $line; do
    if [ "$prev" = "-framework" ]; then
      fw="$fw -framework $word"
    fi
    prev="$word"
  done
  echo "$fw" >"$work/corpus/$name.fw"
  if ! "$work/bin/link_macho" link "$work/corpus/$name" "$name" $fw "$obj" \
      >"$work/corpus/$name.native.log" 2>&1; then
    fail "the native linker does not link $name:"
    sed 's/^/     /' "$work/corpus/$name.native.log" | tail -n 3
    continue
  fi
  mv "$work/corpus/$name" "$work/corpus/$name.nat"
  chmod +x "$work/corpus/$name.nat"
  echo "   $name: linked natively (frameworks:${fw:- none})"
done

if [ "$darwin" -eq 1 ]; then
  echo "== 4. each native program matches its oracle on exit status, stdout and stderr"
  for name in $names; do
    why="$(excluded_reason "$name")"
    if [ -n "$why" ]; then
      echo "   $name: linked and checked, not run: $why"
      continue
    fi
    line="$(tail -n 1 "$work/corpus/$name.link")"
    if ! sh -c "$line" >"$work/corpus/$name.origlog" 2>&1; then
      fail "the compiler's link line does not link $name"
      continue
    fi
    orig="$work/corpus/$name.orig"
    mv "$work/corpus/$name" "$orig"
    status="$(run_program "$orig" "$work/corpus/$name.out" "$work/corpus/$name.err")"
    echo "$status" >"$work/corpus/$name.status"
    again="$(run_program "$orig" "$work/corpus/$name.again" "$work/corpus/$name.again.err")"
    if [ "$again" != "$status" ] || ! cmp -s "$work/corpus/$name.out" "$work/corpus/$name.again"; then
      echo "   $name: excluded, the original gives different output on two runs"
      continue
    fi
    if ! native_signature_ok "$work/corpus/$name.nat"; then
      fail "$name: invalid native signature"
      continue
    fi
    nat_status="$(run_program "$work/corpus/$name.nat" "$work/corpus/$name.nat.out" "$work/corpus/$name.nat.err")"
    if [ "$nat_status" = "$status" ] &&
      cmp -s "$work/corpus/$name.out" "$work/corpus/$name.nat.out" &&
      cmp -s "$work/corpus/$name.err" "$work/corpus/$name.nat.err"; then
      echo "   $name: matches the original (exit $status)"
    else
      fail "$name differs from the original: exit $nat_status against $status"
    fi
  done

  echo "== 5. every executable: strict signature, no stub helper, no dyld_stub_binder, libraries, zero build tools"
  for name in $names; do
    exe="$work/corpus/$name.nat"
    if ! /usr/bin/codesign -v --strict "$exe" >/dev/null 2>&1; then
      fail "$name: codesign -v --strict rejects it"
    fi
    if /usr/bin/otool -l "$exe" | grep -q "__stub_helper"; then
      fail "$name: it has a __stub_helper section"
    fi
    if /usr/bin/nm -u "$exe" | grep -q "dyld_stub_binder"; then
      fail "$name: nm -u lists dyld_stub_binder"
    fi
    libs="$(/usr/bin/otool -L "$exe" | tail -n +2 | awk '{print $1}' | sort | paste -sd ' ' -)"
    want="/usr/lib/libSystem.B.dylib "
    fw="$(cat "$work/corpus/$name.fw")"
    for word in $fw; do
      if [ "$word" != "-framework" ]; then
        want="$want/System/Library/Frameworks/$word.framework/$word "
      fi
    done
    want="$(echo "$want" | tr ' ' '\n' | grep -v '^$' | sort | paste -sd ' ' -)"
    if [ "$libs" != "$want" ]; then
      fail "$name: otool -L lists '$libs', expected '$want'"
    fi
    tools="$(/usr/bin/otool -l "$exe" | awk '/LC_BUILD_VERSION/{f=1} f && /ntools/{print $2; f=0}')"
    if [ "$tools" != "0" ]; then
      fail "$name: LC_BUILD_VERSION lists $tools build tools"
    fi
  done
  if [ "$failures" -eq 0 ]; then
    echo "   every executable passes the five properties"
  fi
  tool_libs="$(/usr/bin/otool -L "$work/bin/link_macho" | tail -n +2 | awk '{print $1}')"
  if [ "$tool_libs" != "/usr/lib/libSystem.B.dylib" ]; then
    fail "the driver links '$tool_libs', expected only /usr/lib/libSystem.B.dylib"
  fi
else
  echo "   not run on $(uname -s): the native-darwin job runs the corpus, signatures and libraries"
fi

echo "== 6. each executable links twice to identical bytes"
for name in $names; do
  fw="$(cat "$work/corpus/$name.fw")"
  if ! "$work/bin/link_macho" link "$work/corpus/$name.again.exe" "$name" $fw "$work/corpus/$name.o" >/dev/null 2>&1; then
    fail "$name does not link a second time"
    continue
  fi
  if ! cmp -s "$work/corpus/$name.nat" "$work/corpus/$name.again.exe"; then
    fail "$name links to different bytes the second time"
  fi
done
echo "   checked $(echo $names | wc -w | tr -d ' ') programs"

echo "== 7. tripwire: no ld, cc, clang, codesign or dsymutil is run while linking"
shims="$work/shims"
tripwire_log="$work/tripwire.log"
mkdir -p "$shims"
for tool in ld cc clang codesign dsymutil; do
  printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 1\n' "$tool" "$tripwire_log" >"$shims/$tool"
  chmod +x "$shims/$tool"
done
: >"$tripwire_log"
PATH="$shims" "$work/bin/link_macho" hello "$work/tripwire-hello" >/dev/null 2>&1 || fail "the tripwire run did not link the hello program"
for name in $names; do
  fw="$(cat "$work/corpus/$name.fw")"
  PATH="$shims" "$work/bin/link_macho" link "$work/corpus/$name.tw" "$name" $fw "$work/corpus/$name.o" >/dev/null 2>&1 || fail "the tripwire run did not link $name"
done
if [ -s "$tripwire_log" ]; then
  fail "a host tool ran while linking: $(cat "$tripwire_log")"
else
  echo "   the log is empty after linking under the shims"
fi

if [ "$darwin" -eq 1 ]; then
  echo "== 8. mutation proofs"
  # The broken signature is refused by codesign; the binary is not executed,
  # because a program with a bad page hash can hang in the kernel where
  # alarm cannot reach it.
  check_page_hash() {
    build_tool || return 1
    "$work/bin/link_macho" hello "$work/hello-page" >/dev/null 2>&1 || return 1
    /usr/bin/codesign -v --strict "$work/hello-page" >/dev/null 2>&1
  }
  prove_mutation "hash one CodeDirectory page wrong" "$codesign_src" \
    "    digest = SHA256.digest(image[start.to_i32, count.to_i32])" \
    "    digest = SHA256.digest(image[start.to_i32, count.to_i32])
    if page == 0_i64
      digest[0] = digest[0] ^ 1_u8
    end" \
    check_page_hash

  check_wrong_ordinal() {
    check_hello
  }
  prove_mutation "bind one import to the wrong library ordinal" "$imports_src" \
    "LIBSYSTEM_ORDINAL = 1_i64" "LIBSYSTEM_ORDINAL = 2_i64" \
    check_wrong_ordinal

  check_drop_rebase() {
    check_corpus
  }
  prove_mutation "drop the rebase of one absolute pointer" "$link_src" \
    "    @exe.rebases << p # rebase: dyld slides this pointer by the load slide" \
    "    # the rebase of this pointer is dropped" \
    check_drop_rebase

  check_ignore_addend() {
    check_corpus
  }
  prove_mutation "ignore Reloc#addend for absolute pointers" "$link_src" \
    "      patch_abs64(dst_out, off, code, r.addend)" \
    "      patch_abs64(dst_out, off, code, 0_i64)" \
    check_ignore_addend
  cp "$work/bin/link_macho.good" "$work/bin/link_macho"
else
  echo "== 8. mutation proofs: not run on $(uname -s): the native-darwin job runs them"
fi

[ ! -e "$NATIVE_SIGNATURE_FAILURE_FILE" ] || fail "a native executable failed signature verification"
if [ "$failures" -eq 0 ]; then
  echo "== ALL NATIVE_LINK CHECKS PASSED"
  exit 0
fi
echo "== SOME NATIVE_LINK CHECKS FAILED"
exit 1
