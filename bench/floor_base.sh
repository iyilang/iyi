# What every program iyi builds leaves undefined, per platform — the part of
# the dependency floor (SPEC.md III.9) that is the prelude's and the
# runtime's rather than any one module's. Sourced, not copied: the gates
# that audit a program's floor each start from this and add what their own
# program asks for beyond it.
#
# It was copied. Eleven gates carried a darwin list of their own, and when
# panics learned to print a backtrace two of them were not told — so every
# darwin program's `backtrace` and `backtrace_symbols_fd` read as "something
# new" in `std/io`'s and `std/time`'s gates, months after
# bench/dependency_floor.sh had recorded both. A floor written in eleven
# places is eleven floors, and the one nobody updates is the one that fails.
#
# The reason each name is here is recorded beside the full list in
# bench/dependency_floor.sh, which is this plus what the standard library's
# platform modules add. The gates whose lists are *exact* — the runtime's
# own twelve in bench/thread_exercise.sh, the thread variants in
# bench/thread_floor.sh, the collector's in bench/mark_exercise.sh — stay
# written out, because "nothing else" is what they assert.
#
# darwin: libSystem is the platform's only stable interface, so the prelude
# (write, read, exit, pipe), the poller (kqueue, kevent, its clock), the
# collector (mmap, munmap, madvise, the stack base and dyld's image for root
# discovery), the thread layer (pthread_*, sigaction, sigaltstack,
# sysctlbyname, the one thread-local), errno's `__error` and the panic
# path's backtrace are all its symbols.
FLOOR_BASE_DARWIN="__error _tlv_bootstrap backtrace backtrace_symbols_fd clock_gettime_nsec_np exit kevent kqueue madvise mmap mprotect munmap pipe pthread_create pthread_get_stackaddr_np pthread_kill pthread_self read sigaction sigaltstack sysctlbyname write _dyld_get_image_header _dyld_get_image_vmaddr_slide"

# Linux: the prelude issues raw syscalls and adds no symbol of its own; what
# a program carries is what the C runtime's start files leave undefined.
FLOOR_BASE_LINUX="ITM_deregisterTMCloneTable ITM_registerTMCloneTable _cxa_finalize _gmon_start__ _libc_start_main"

# What a program may link: the platform libc, and nothing else.
FLOOR_LIBS_PROGRAM="libSystem libc.so ld-linux libgcc_s"

# Windows: a PE leaves nothing undefined, so the floor there is the DLLs its
# import table names, read with the MSVC toolchain's own `dumpbin`, and the
# imported names are the detail under each one. Five gates carried their own
# copy of the reader's lookup, which is the copying this file ended for
# darwin's list.
#   kernel32.dll      the process interface, which is what libc is on the
#                     other two (SPEC.md III.10's inventory)
#   vcruntime140.dll  the MSVC runtime every binary the MSVC linker writes
#                     carries, whatever it was written from
#   ucrtbase.dll      the UCRT itself, for a link that names it directly
#   api-ms-win-crt-   the UCRT's façade DLLs, which is how a default link
#                     names it: runtime, math, stdio, locale, heap and
#                     environment, all of them the C runtime and none of
#                     them a library iyi took on
# That is the runtime's floor - the collector, the scheduler and threads
# are kernel32's - and a program may add two, each through one module:
#   advapi32.dll      `RtlGenRandom`, the OS entropy `std/random` reads, and
#                     `std/random` is its only caller (SPEC.md III.10)
#   ws2_32.dll        Winsock, the platform's network interface, reached by
#                     `std/socket` and `std/udp` and nothing else
#                     (SPEC.md III.10)
FLOOR_DLLS_RUNTIME="kernel32.dll vcruntime140.dll ucrtbase.dll api-ms-win-crt-"
FLOOR_DLLS_PROGRAM="$FLOOR_DLLS_RUNTIME advapi32.dll ws2_32.dll"

# The reader, found the way src/compiler/iyi/codegen/link.cr finds the
# linker: on PATH (a developer prompt), else through the installer's own
# locator. Prints nothing and fails where there is none, and a gate that
# needs it says so rather than reading an empty table as a floor that held.
find_dumpbin() {
  local vswhere root candidate
  if command -v dumpbin >/dev/null 2>&1; then
    printf 'dumpbin\n'
    return 0
  fi
  vswhere="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
  [ -x "$vswhere" ] || return 1
  root="$("$vswhere" -latest -products '*' -property installationPath 2>/dev/null | tr -d '\r')"
  [ -n "$root" ] || return 1
  root="$(cygpath -u "$root" 2>/dev/null)" || return 1
  for candidate in "$root"/VC/Tools/MSVC/*/bin/Hostx64/x64/dumpbin.exe \
                   "$root"/VC/Tools/MSVC/*/bin/Host*/*/dumpbin.exe; do
    [ -x "$candidate" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

# The DLLs a PE imports, lower-cased (the linker spells them KERNEL32.dll
# and a floor is not a question about capitalisation), and the names it
# imports from them. Both read with `$DUMPBIN`, which the caller sets from
# `find_dumpbin`.
pe_dlls() { # pe_dlls <binary.exe>
  "$DUMPBIN" -nologo -dependents "$1" 2>/dev/null |
    sed -n 's/^    \([A-Za-z0-9_.+-]*\.[Dd][Ll][Ll]\)$/\1/p' |
    tr 'A-Z' 'a-z' | sort -u
}

pe_imports() { # pe_imports <binary.exe>
  "$DUMPBIN" -nologo -imports "$1" 2>/dev/null |
    sed -n 's/^ *[0-9A-Fa-f]\{1,4\} \([A-Za-z_?@][A-Za-z0-9_?@$.]*\)$/\1/p' |
    sort -u
}

# Every DLL in *dlls* (one per word) that no entry of *allowed* begins:
# what a binary imports beyond its floor, one per line, or nothing.
extra_dlls() { # extra_dlls "<allowed>" "<dlls>"
  local dll ok keep
  for dll in $2; do
    keep=no
    for ok in $1; do
      case "$dll" in "$ok"*) keep=yes ;; esac
    done
    [ "$keep" = no ] && printf '%s\n' "$dll"
  done
  return 0
}
