#!/usr/bin/env bash
# No symbol the compiler defines has an `@` in it (SPEC.md IV.1g, *A symbol
# has no `@` in it*).
#
#     bash bench/symbol_names.sh
#
# GNU ld reads `name@suffix` in a definition as a symbol version, and an
# inherited method was `*Derived@Base#hi` and a proc literal
# `~procProc(Int32, Int32)@main.cr:3`. Every distinct suffix became a version
# definition of the executable, the loader keeps 15 bits of a version index,
# and `std_spec` built at 9f0d82076 had 39,376 of them: glibc 2.34's index
# was 39,384, read back as 6,616, and the program stopped before `main` on
# `__libc_start_main` wanting version `Object::==<Pointer(SpecEnumFlags).
# class>:Bool` (Linux, GNU ld 2.46). lld drops the suffix instead, and every
# method an array inherits was `*Array(Int32)` in the symbol table. The
# compiler joins those names with `^` now and escapes
# the `@` of text a person wrote — a file's path, a quoted `NamedTuple` key,
# a `Symbol`'s name — as `%40` (`Iyi::SYMBOL_JOIN`, `Iyi.symbol_text`).
#
# The program below has one of each: an inherited method and an inherited
# class method, a proc literal in the main file and one in a file under a
# package-cache-shaped `pkg@v1.0.0` directory (every dependency's files live
# under `<cache>/mod/<path>@v<version>`), a private def, class variable and
# constant of that file, a method taking a `NamedTuple` with a quoted `a@b`
# key, and a `Symbol` named `x@y` read from a type's own unit. Each one's
# new spelling is asked for by name, so a fixture the optimiser or a
# refactor emptied fails rather than passing on nothing.
#
# Read from the object files, not the executable: what a linker makes of an
# `@` is the linker's (GNU ld a version, lld a cut), so only the objects say
# what the compiler wrote. On Linux the executable is then linked with GNU
# ld (`-fuse-ld=bfd`) and must define no symbol version at all.
#
# The broken copy is the old spelling itself: the bootstrap compiler the fork
# is built with still joins with `@`, so the same program built by it must
# be caught by the same reader. MSVC spells every punctuation of a method's
# or a proc's name as `.XX.`, `@` as `.40.`, so there the broken copy is
# caught by the file-private class variable and constant, whose globals carry
# the path as it is written.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The fork's compiler is the `iyi` the job built: `bin/iyi` runs
# `.build/iyi` and nothing else. Not `bin/crystal`, which runs the bootstrap
# on PATH when there is no `.build/crystal` - darwin's job builds only `make
# iyi-tarball` - and the "fixed" build was then the old spelling, 1,486 of
# 6,348 symbols with an `@` (CI job 128047375530). A caller with a compiler
# of its own names it through the environment, and one that is not the
# fork is refused rather than read.
IYI="${IYI:-$REPO/bin/iyi}"
# Whether a compiler is the fork: its version line starts `iyi `, and the
# bootstrap's names the other language.
is_fork() { # is_fork <compiler...>
  "$@" --version 2>/dev/null | tr -d '\r' | sed -n 1p | grep -q '^iyi '
}
# The broken copy's compiler: the Crystal the fork is bootstrapped with.
BOOTSTRAP="${CRYSTAL_BOOTSTRAP_COMPILER:-crystal}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

windows=0
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    windows=1
    # A native compiler cannot resolve this shell's own path mapping.
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

status=0
fail() { echo "symbol_names FAIL: $1"; status=1; }

if [ "$windows" = 1 ]; then
  . "$REPO/bench/floor_base.sh"
  DUMPBIN="$(find_dumpbin)" || {
    echo "symbol_names FAIL: no dumpbin, and a machine that built this compiler has the toolchain that carries it"
    exit 1
  }
fi

mkdir -p "$WORK/src/pkg@v1.0.0"
cat > "$WORK/src/pkg@v1.0.0/lib.cr" <<'CR'
private class Tally
  @@count = 0

  def self.bump(n : Int32) : Int32
    @@count += n
    @@count
  end
end

private LIMIT = [1, 2, 3]

private def helper(x : Int32) : Int32
  Tally.bump(x)
end

def lib_answer(x : Int32) : Int32
  twice = ->(y : Int32) { helper(y) * 2 }
  twice.call(x) + LIMIT.size
end
CR
cat > "$WORK/src/main.cr" <<'CR'
require "./pkg@v1.0.0/lib"

class Base
  def hi(n : Int32) : Int32
    n + 1
  end

  def self.make : self
    new
  end
end

class Derived < Base
end

def show(t) : Int32
  t[:"a@b"]
end

class Words
  def self.word(s : Symbol) : Int32
    s == :"x@y" ? 1 : 0
  end
end

add = ->(a : Int32) { a + 2 }
puts Derived.make.hi(add.call(1)) + lib_answer(2) + show({"a@b": 4}) + Words.word(:"x@y")
CR
# 4 from `hi`, 7 from `lib_answer`, 4 from `show` and 1 from `word`.
WANT=16

# MSVC's spelling of a method's or a proc's name (`Iyi.safe_mangling`):
# every byte but a letter, a digit and `_` as `.XX.`.
msvc_spelling() { # msvc_spelling <name>
  local name="$1" out="" char i
  for ((i = 0; i < ${#name}; i++)); do
    char="${name:i:1}"
    case "$char" in
      [A-Za-z0-9_]) out+="$char" ;;
      *) out+=".$(printf '%X' "'$char")." ;;
    esac
  done
  printf '%s\n' "$out"
}

# Whether one symbol in <file> carries every `&&`-joined part of <name>, in
# MSVC's spelling where the kind is `code` and the target spells it so.
# Sets $found to the first such symbol.
has_symbol() { # has_symbol <symbols file> <code|data> <part&&part...>
  local kind="$2" rest="$3" part lines
  lines="$(cat "$1")"
  while :; do
    part="${rest%%&&*}"
    [ "$windows" = 1 ] && [ "$kind" = code ] && part="$(msvc_spelling "$part")"
    lines="$(printf '%s\n' "$lines" | grep -F -- "$part")" || return 1
    [ "$rest" = "${rest#*&&}" ] && break
    rest="${rest#*&&}"
  done
  found="$(printf '%s\n' "$lines" | sed -n 1p)"
}

# Every symbol the objects under a cache directory define, one per line.
defined_symbols() { # defined_symbols <cache dir>
  local object
  find "$1" -type f \( -name '*.o' -o -name '*.obj' \) | sort | while read -r object; do
    case "$(uname -s)" in
      Darwin) nm -U "$object" 2>/dev/null | cut -d' ' -f3- ;;
      MINGW* | MSYS* | CYGWIN* | Windows_NT)
        # `008 00000000 SECT3  notype ()    External     | name`; an undefined
        # one says UNDEF where the section is. Left out: the names of the
        # MSVC C++ ABI, which LLVM gives a catch funclet (`?catch$6@?0?<the
        # function>@4HA`) and the exception tables `primitives.cr` writes
        # for `raise` (`??_R0PEAX@8`, `_CT??_R0PEAX@88`), and its constant
        # pool's `__real@<hex>`. There `@` is that ABI's own decoration, the
        # name is the one vcruntime and link.exe expect, and COFF has no
        # symbol versions: 68 of 5,256 in this program, the rest none
        # (Windows 11, 12 logical processors, the user's machine).
        "$DUMPBIN" -nologo -symbols "$object" 2>/dev/null | tr -d '\r' |
          grep ' SECT[0-9A-F]* ' | sed -n 's/^[^|]*| \(.*\)$/\1/p' |
          grep -vE '^(\?|_CT\?\?|_CTA[0-9]\?\?|_TI[0-9]\?|__(real|xmm|ymm|zmm)@)' ;;
      *) nm --defined-only "$object" 2>/dev/null | cut -d' ' -f3- ;;
    esac
  done
}

# Version definitions in a Linux executable: `readelf -V` names the section
# and its count, and an executable that defines no version has none.
version_definitions() { # version_definitions <executable>
  readelf -V "$1" 2>/dev/null |
    sed -n "s/^Version definition section '.gnu.version_d' contains \([0-9]*\) entr.*/\1/p" |
    grep . || echo 0
}

# Linking with GNU ld, which is where an `@` is a version, wherever there is
# one; `-fuse-ld=` also turns off the compiler's own preference for lld.
link_flags=()
if [ "$(uname -s)" = Linux ] && command -v ld.bfd > /dev/null 2>&1; then
  link_flags=(--link-flags=-fuse-ld=bfd)
fi

build() { # build <label> <compiler...>; leaves $WORK/<label>.exe and $WORK/<label>-cache
  local label="$1"
  shift
  rm -rf "$WORK/$label-cache"
  (cd "$WORK/src" && env IYI_CACHE_DIR="$WORK/$label-cache" CRYSTAL_CACHE_DIR="$WORK/$label-cache" \
    "$@" build --no-color ${link_flags[@]+"${link_flags[@]}"} -o "$WORK/$label.exe" main.cr) > "$WORK/$label.log" 2>&1
}

echo "== the fork's compiler =="
if ! is_fork "$IYI"; then
  fail "$IYI is not the fork's compiler (its version line: $("$IYI" --version 2>&1 | sed -n 1p)), so what it writes says nothing about the fork's spelling"
elif ! build fixed "$IYI"; then
  sed -n '1,20p' "$WORK/fixed.log"
  fail "the program did not build with $IYI"
else
  got="$("$WORK/fixed.exe" 2>&1)"
  [ "$got" = "$WANT" ] || fail "the program printed '$got', wanted $WANT"
  defined_symbols "$WORK/fixed-cache" > "$WORK/fixed.symbols"
  total="$(wc -l < "$WORK/fixed.symbols" | tr -d ' ')"
  [ "$total" -gt 100 ] || fail "read $total symbols out of the objects, which is no reading"
  at="$(grep -c '@' "$WORK/fixed.symbols")"
  if [ "$at" -eq 0 ]; then
    echo "  ok   none of the $total symbols the objects define has an @"
  else
    fail "$at of the $total symbols the objects define have an @:"
    grep '@' "$WORK/fixed.symbols" | head -10 | sed 's/^/    /'
  fi
  # Each family, by its new name: methods and procs in MSVC's spelling there,
  # globals as written everywhere. `&&` joins the parts one symbol must
  # carry either side of a path separator, which is the platform's.
  while IFS='|' read -r family kind name; do
    if has_symbol "$WORK/fixed.symbols" "$kind" "$name"; then
      echo "  ok   $family: $found"
    else
      fail "no symbol for $family, wanted one containing ${name//&&/ and }"
    fi
  done <<'FAMILIES'
an inherited method|code|*Derived^Base#hi<Int32>:Int32
an inherited class method|code|*Derived^Base::make:Derived
a proc literal|code|~procProc(Int32, Int32)^main.cr:
a proc literal under a package directory|code|~procProc(Int32, Int32)^pkg%40v1.0.0&&lib.cr:
a file-private def|code|pkg%40v1.0.0&&lib.cr::helper<Int32>:Int32
a quoted NamedTuple key|code|*show<NamedTuple("a%40b": Int32)>:Int32
a file-private class variable|data|pkg%40v1.0.0&&lib.cr::Tally::count
a file-private constant|data|pkg%40v1.0.0&&lib.cr::LIMIT
a Symbol read from a type's own unit|data|~symbol:x%40y
FAMILIES
  if [ "${#link_flags[@]}" -gt 0 ]; then
    defs="$(version_definitions "$WORK/fixed.exe")"
    if [ "$defs" = 0 ]; then
      echo "  ok   linked with GNU ld, the executable defines no symbol version"
    else
      fail "linked with GNU ld, the executable defines $defs symbol versions"
    fi
  fi
fi

echo "== the broken copy: the old spelling, from the Crystal bootstrap =="
if ! command -v "$BOOTSTRAP" > /dev/null 2>&1; then
  fail "no bootstrap compiler '$BOOTSTRAP' on the PATH to build the broken copy with"
elif ! build broken env -u CRYSTAL_PATH -u CRYSTAL_HAS_WRAPPER "$BOOTSTRAP"; then
  sed -n '1,20p' "$WORK/broken.log"
  fail "the program did not build with the bootstrap ($BOOTSTRAP)"
else
  # The refusal above, held against the compiler it is there to refuse.
  if is_fork env -u CRYSTAL_PATH -u CRYSTAL_HAS_WRAPPER "$BOOTSTRAP"; then
    fail "the bootstrap ($BOOTSTRAP) passes for the fork's compiler, so the refusal does not refuse it"
  else
    echo "  failure proof: the bootstrap is refused as the fork's compiler ($("$BOOTSTRAP" --version 2>&1 | tr -d '\r' | sed -n 1p))"
  fi
  defined_symbols "$WORK/broken-cache" > "$WORK/broken.symbols"
  at="$(grep -c '@' "$WORK/broken.symbols")"
  if [ "$at" -gt 0 ]; then
    echo "  failure proof: $at of the symbols the old spelling defines have an @"
  else
    fail "the old spelling defined no symbol with an @, so the reader does not test it"
  fi
  # And by family, so a bootstrap that stopped writing one is noticed rather
  # than proving less than it says. Read as written: these are the `@`s.
  if [ "$windows" = 1 ]; then
    families='a file-private global|pkg@v1.0.0&&lib.cr::'
  else
    families='an inherited method|*Derived@Base#hi<Int32>:Int32
a proc literal|~procProc(Int32, Int32)@main.cr:
a file-private def|pkg@v1.0.0&&lib.cr::helper'
  fi
  while IFS='|' read -r family name; do
    if has_symbol "$WORK/broken.symbols" data "$name"; then
      echo "  failure proof: $family is $found"
    else
      fail "the old spelling has no $family containing ${name//&&/ and }"
    fi
  done <<< "$families"
  if [ "${#link_flags[@]}" -gt 0 ]; then
    defs="$(version_definitions "$WORK/broken.exe")"
    if [ "$defs" -gt 0 ]; then
      echo "  failure proof: linked with GNU ld, the old spelling's executable defines $defs symbol versions"
    else
      fail "linked with GNU ld, the old spelling's executable defines no symbol version, so that check does not test it"
    fi
  fi
fi

if [ "$status" -eq 0 ]; then
  echo "symbol_names: no symbol the compiler defines has an @ in it"
fi
exit "$status"
