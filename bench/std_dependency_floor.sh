#!/usr/bin/env bash
# Fails when iyi's standard library grows a dependency.
#
# `bench/dependency_floor.sh` builds the samples and checks what they link. The
# samples are not the surface a user imports: `src/std` is. This builds every
# module in it, alone, and checks the binary that comes out.
#
#     bash bench/std_dependency_floor.sh
#
# Why a second floor rather than a wider first one: the tree still vendors
# Crystal's bindings, and they still carry live attributes.
#
#     src/openssl   21 files   @[Link("ssl")], @[Link("crypto")]
#     src/yaml      17 files   @[Link("yaml", pkg_config: "yaml-0.1")]
#     src/xml       16 files   @[Link("xml2", pkg_config: "libxml-2.0")]
#     src/compress  18 files   @[Link("z")]
#     src/digest     8 files
#     src/crypto     6 files
#     src/big        8 files   @[Link("gmp")]
#
# None of them is reachable from iyi code today, measured rather than assumed.
# But one `import` that reaches one of those files puts an ancestor library
# back on the link line of every program that imports the module, and until
# this script existed nothing would have said so. The bindings are inert, not
# absent, and inert is a property that has to be checked to stay true.
#
# Three ways this goes red, because a check that only reports good news is not
# a check:
#
#   1. A module links something other than the platform libc. Names the module
#      and the library.
#   2. A module that used to build alone stops building. A quietly smaller
#      count is a regression hiding as a pass.
#   3. A module recorded below as a known failure starts passing, or fails with
#      a different error than the one on record. A recorded reason that has
#      gone stale is worse than no reason, because it reads as understood.
#
# Needs `make` for bin/iyi, plus `otool` on darwin or `readelf` on Linux.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

status=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Crystal's thirteen, plus the spellings a linker actually emits.
ANCESTOR_LIBS="bdw-gc libgc libevent compiler-rt pcre pcre2 gmp iconv crypto ssl xml2 yaml zlib libz LLVM ffi"

# The platform libc, and nothing else. Same rule as ALLOWED_LIBS_PROGRAM in
# bench/dependency_floor.sh, because a std module is a program's dependency and
# inherits a program's floor.
ALLOWED_LIBS="libSystem libc.so ld-linux libgcc_s"

# Measured floor, on this branch's base. Both numbers matter: see failure
# mode 2. They are a floor and not a target, so they rise as the remaining
# `src/std` modules land: a module arriving that builds alone and links only
# the platform libc pushes both counts up, and the commit that raises them
# records that it measured them.
FLOOR_MODULES=52
FLOOR_BUILT=52

# Known failures, each with the error on record. Empty, and measured that way
# rather than assumed: all 52 modules on this base build alone.
#
# It is kept because four modules not yet on master need it. `oauth`, `oauth2`
# and `websocket` reach `src/std/dns.iyi`, which used a bare `rescue`, and
# `src/std/spec.iyi` declared `pub class SpecError < Exception` while
# `Std::Exception` is a module. Under a compiler carrying the rule that
# refuses `rescue` in an iyi file, those four did not build. Fixes exist and
# land with the modules.
#
# The list stays empty on purpose. If one of those arrives still broken, it
# fails as failure mode 2 and the gate names it, which is the right outcome:
# a list of excuses written in advance would absorb exactly the regression
# this is here to report.
KNOWN_FAIL_MODULES=""

known_fail() {
  case " $KNOWN_FAIL_MODULES " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

known_pattern() {
  eval "printf '%s' \"\${KNOWN_FAIL_PATTERN_$1:-}\""
}

libs_of() {
  case "$(uname -s)" in
    Darwin) otool -L "$1" 2>/dev/null | sed 1d | awk '{print $1}' ;;
    *) readelf -d "$1" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' ;;
  esac
}

if [ ! -x ./bin/iyi ]; then
  echo "bin/iyi is missing; run make first."
  exit 1
fi

echo "== iyi's standard library, one module at a time"

modules="$(ls src/std/*.iyi 2>/dev/null)"
module_count="$(printf '%s\n' "$modules" | grep -c . )"

built=0
failed=0
dep_hits=""
new_failures=""
stale_known=""
all_libs="$WORK/all_libs"
: > "$all_libs"

for m in $modules; do
  name="$(basename "$m" .iyi)"
  probe="$WORK/probe_$name.iyi"
  {
    printf 'module stdprobe_%s\n\n' "$name"
    printf 'import std/%s\n\n' "$name"
    printf 'print "ok\\n"\n'
  } > "$probe"

  out="$WORK/bin_$name"
  err="$WORK/err_$name"

  if IYI_PATH="$REPO/src" ./bin/iyi build -o "$out" "$probe" > "$err" 2>&1; then
    if known_fail "$name"; then
      # Failure mode 3: recorded as broken, now builds.
      stale_known="$stale_known $name(now-builds)"
    fi
    built=$((built + 1))
    libs="$(libs_of "$out")"
    printf '%s\n' "$libs" >> "$all_libs"
    for lib in $libs; do
      keep=no
      for ok in $ALLOWED_LIBS; do
        case "$lib" in *"$ok"*) keep=yes ;; esac
      done
      if [ "$keep" = no ]; then
        for anc in $ANCESTOR_LIBS; do
          case "$lib" in
            *"$anc"*) dep_hits="$dep_hits
  $name links $lib  (ancestor dependency: $anc)" ;;
          esac
        done
        case "$dep_hits" in
          *"$name links $lib"*) : ;;
          *) dep_hits="$dep_hits
  $name links $lib  (not the platform libc)" ;;
        esac
      fi
    done
  else
    failed=$((failed + 1))
    if known_fail "$name"; then
      pat="$(known_pattern "$name")"
      if ! grep -q "$pat" "$err" 2>/dev/null; then
        # Failure mode 3: recorded reason no longer describes the error.
        stale_known="$stale_known $name(reason-changed)"
      fi
    else
      # Failure mode 2: a module stopped building alone.
      new_failures="$new_failures $name"
    fi
  fi
done

echo "  modules found:        $module_count  (floor $FLOOR_MODULES)"
echo "  built alone:          $built  (floor $FLOOR_BUILT)"
echo "  known failures:       $(echo $KNOWN_FAIL_MODULES | wc -w | tr -d ' ')"
echo "  libraries linked:"
sort -u "$all_libs" | sed '/^$/d' | sed 's/^/    /'

if [ -n "$dep_hits" ]; then
  echo
  echo "A STANDARD LIBRARY MODULE REACHES A DEPENDENCY"
  echo "$dep_hits"
  echo
  echo "A module iyi ships may link the platform libc and nothing else, the same"
  echo "floor a program gets (SPEC.md III.10). The vendored Crystal bindings under"
  echo "src/openssl, src/yaml, src/xml, src/compress, src/digest, src/crypto and"
  echo "src/big are reachable by import; one of them just became reachable."
  status=1
fi

if [ -n "$new_failures" ]; then
  echo
  echo "A MODULE STOPPED BUILDING ALONE:$new_failures"
  echo
  echo "This is reported rather than absorbed into a smaller count, because a"
  echo "module that no longer compiles is a regression and a gate that quietly"
  echo "counts fewer modules is not measuring anything."
  status=1
fi

if [ -n "$stale_known" ]; then
  echo
  echo "A RECORDED KNOWN FAILURE CHANGED:$stale_known"
  echo
  echo "Either it builds now, and the entry should come out of"
  echo "KNOWN_FAIL_MODULES in this script, or it fails for a different reason"
  echo "than the one written beside it and the reason needs updating. A stale"
  echo "reason reads as understood when it is not."
  status=1
fi

if [ "$module_count" -lt "$FLOOR_MODULES" ]; then
  echo
  echo "MODULE COUNT FELL: $module_count against a floor of $FLOOR_MODULES."
  echo "If modules were removed on purpose, lower FLOOR_MODULES in the same commit."
  status=1
fi

if [ "$built" -lt "$FLOOR_BUILT" ]; then
  echo
  echo "BUILT COUNT FELL: $built against a floor of $FLOOR_BUILT."
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo
  echo "the standard library reaches no dependency"
fi

exit $status
