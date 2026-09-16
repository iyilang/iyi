#!/usr/bin/env bash
# Fails when iyi grows a dependency.
#
# Crystal requires thirteen libraries: libc, bdw-gc, libevent, compiler-rt,
# pcre2, gmp, iconv, openssl, libxml2, libyaml, zlib, LLVM and libffi. A program
# iyi builds must reach none of them, and the compiler must reach only the ones
# named below with a reason beside each. This checks it rather than asserting it
# (SPEC.md III.9, III.10).
#
#     bash bench/dependency_floor.sh
#
# Two layers, because either alone can be fooled. The symbol list catches a
# dependency arriving as a call into something the linker resolves from libc.
# The library list catches one arriving as a whole `-l`, which adds no undefined
# symbol a naive check would notice once it is satisfied. Two builds, plain
# and --release, because the optimiser can put a name on the line the plain
# build never had (`bzero` on darwin was one, for a day).
#
# A new entry is not automatically wrong. It is a dependency being taken on,
# which is a decision, and the way to record the decision is to add it here in
# the same commit that causes it. What this refuses is the version where a
# library arrives with a feature and nobody finds out until a build fails on a
# machine that does not have it.
#
# Needs `make` for bin/iyi, plus `nm` and `otool` on darwin or `nm` and
# `readelf` on Linux. Exits non-zero if any floor moved, in either direction: a
# floor that got lower with this script left behind stops having teeth.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# What a program iyi builds may leave undefined. On darwin these are libSystem's
# and there is no way around that: Apple supports libSystem as its only
# interface and raw syscalls are explicitly not a stable ABI, which is why Go
# links it there too. On Linux the prelude issues raw syscalls instead and adds
# no symbol of its own; what it does carry are five left undefined by the C
# runtime objects every link template adds (crt1.o, crti.o, crtbegin.o):
# __libc_start_main, __gmon_start__, __cxa_finalize and the two weak _ITM_
# references. They are the template's, not the prelude's. The list spells them
# the way `symbols()` reports them, with the ELF leading underscore stripped;
# `malloc` or `mmap` is not among them and would still fail, because that would
# mean the prelude fell back to libc. What the prelude ITSELF asks for is read
# one layer down, at the object, by the per-target audit in CI, where an iyi
# program's .o for x86_64-linux-gnu is empty.
# `read` joined the list when `samples/iyi/calc` started reading standard
# input: on darwin that is `LibC.read` for the same reason `write` is, and on
# Linux it is syscall 0 (63 on aarch64), so the Linux list is unchanged and
# `calc`'s x86_64-linux-gnu object still has zero undefined symbols.
# `open`, `close` and `chmod` joined when `File` did. Darwin binds libSystem;
# Linux issues `openat`/`close` as syscalls, so the Linux list is still
# unchanged and `files.iyi`'s x86_64-linux-gnu object is empty.
# `unlink` joined with File.delete. Darwin binds libSystem again; Linux issues
# `unlinkat`, so its undefined list and the files object remain empty.
# `kqueue`, `kevent`, `clock_gettime_nsec_np` and `__error` joined when the
# concurrency runtime (SPEC.md III.4.8) reached darwin arm64: the panic path
# runs through the scheduler, so every darwin program carries the poller and
# its clock, all of it libSystem for the same reason `write` is. Linux keeps
# raw syscalls, so its list and the per-target objects are unchanged.
# `mmap`, `munmap`, `pthread_self`, `pthread_get_stackaddr_np` and the two
# `_dyld_get_image_*` calls joined when the owned collector became the
# default (GC_DESIGN.md, the flip): the arena maps and unmaps through
# libSystem's VM interface, and root discovery asks libSystem for the stack
# base and dyld for the image's segments — the same standing `write` has.
# `malloc` and `realloc` LEFT the list with the same flip: a default darwin
# program allocates from the arena now, and a build that asks libSystem for
# malloc again is the regression this list exists to catch. `mprotect`
# appears only in a program that spawns a task, and no sample does;
# bench/concurrency_exercise.sh allows it for the exercise binary.
# `memset` LEFT with the same flip, which the gate's own tightness check
# demanded: the arena clears reused chunks with its own clear_block, so no
# darwin sample references libSystem's memset any more, and an allowlist
# entry nothing uses is a check without teeth.
# `_tlv_bootstrap` joined when the scheduler's state moved behind one
# `@[ThreadLocal]` pointer (concurrency.iyi, GC_DESIGN.md's thread cutover):
# Mach-O has no local-exec, so every thread-local descriptor names dyld's
# thunk, and every darwin program reaches the scheduler. Linux pays no name
# for the same variable, which is the thread floor's finding.
# `pthread_kill` joined with the runtime's kernel thread (thread.iyi, GC
# Stage 4): every darwin program's collector can stop a thread, and the
# stop's name is referenced whether or not the program ever starts one
# (the plain build keeps it; the optimiser drops it as unreachable with
# no thread to stop). Linux's stop is syscalls.
# `pthread_create` and `sysctlbyname` joined with the parallel marker
# (Stage 7): the collector starts its helpers as kernel threads of its own
# and sizes them by `hw.ncpu`. `pipe` joined with the concurrent mark
# (Stage 9): helper 0 takes the mark's second stop, which stops the main
# thread, so the main thread registers a line - and on darwin a line's park
# is a pipe - the first time a mark runs beside it, and `sigaction`
# joins with it, the stop's handler installed then. `madvise` is the
# sweep handing a run of dead pages back (`MADV_FREE_REUSABLE`, the
# advice darwin's accounting honours). `mprotect` joined with the first
# sample that starts a task (`samples/iyi/workers.iyi`, III.4): a fiber's
# stack has a guard page under it, and on darwin the guard is libSystem's
# `mprotect`. Linux names none of the six: clone, sched_getaffinity,
# futex, rt_sigaction, madvise and mprotect are syscalls. `accept`, `bind`,
# `connect`, `getsockname`, `listen`, `recv`, `send`, `setsockopt` and `socket`
# joined with `IyiSocket` (samples/iyi/socket.iyi): on darwin libSystem is the
# platform interface, while Linux issues raw socket syscalls and names none of them.
# `sigaltstack` joined with the stack guard (concurrency.iyi, III.1.4): a
# stack overflow is the program's own panic, said from a handler on an
# alternate stack, and every darwin program installs one. Linux's is a
# syscall.
# `environ` joined when the std exercises started calling `Program.env`
# (`std/colorize` reads `NO_COLOR`/`TERM`, `std/path` reads `HOME`/`PWD`).
# The prelude walks the C runtime's exported global, which on darwin is
# libSystem and on Linux is the one libc data symbol env has. Samples
# never asked, so the name was invisible until the exercises did.
# `pthread_join` joined with `IyiThread.join` on darwin: `pthread_create`
# was already on the list for the collector's helpers, and an exercise
# that starts a thread and waits for it names the other half. Linux's
# join is a futex.
# `backtrace` and `backtrace_symbols_fd` joined when panics gained backtraces:
# the panic path captures the frames and writes them directly to stderr
# through libSystem, linking no new library.
# `std/file` and `std/dir` (stat64, lstat64, fstat64, rename, link, symlink,
# readlink, realpath, chown, truncate, ftruncate, access, utimes, opendir,
# readdir, closedir, rewinddir, getcwd, chdir, mkdir, rmdir) and `std/udp`
# (sendto, recvfrom, getsockopt) joined the way `IyiSocket` did: libSystem is
# darwin's interface, and on Linux each is a raw syscall the object does not
# name. `std/debug` reads the program's own image through `dladdr`,
# `_NSGetExecutablePath` and `lseek`, all libSystem's.
ALLOWED_SYMBOLS_DARWIN="__error _tlv_bootstrap accept backtrace backtrace_symbols_fd bind chmod clock_gettime_nsec_np close connect environ exit getsockname kevent kqueue listen madvise mmap mprotect munmap open pipe pthread_create pthread_get_stackaddr_np pthread_join pthread_kill pthread_self read recv send setsockopt sigaction sigaltstack socket sysctlbyname unlink write _dyld_get_image_header _dyld_get_image_vmaddr_slide stat64 lstat64 fstat64 rename link symlink readlink realpath chown truncate ftruncate access utimes opendir readdir closedir rewinddir getcwd chdir mkdir rmdir sendto recvfrom getsockopt dladdr _NSGetExecutablePath lseek"
ALLOWED_SYMBOLS_LINUX="ITM_deregisterTMCloneTable ITM_registerTMCloneTable _cxa_finalize _gmon_start__ _libc_start_main environ"

# What a program may link. The platform libc only.
ALLOWED_LIBS_PROGRAM="libSystem libc.so ld-linux libgcc_s"

# What the compiler may link, each with a reason recorded in SPEC.md.
#   LLVM       the back end (B.2, Part V.9)
#   c++        conditional, and on two independent reasons, the same two the
#              Makefile gates NEEDS_CXX_RUNTIME on. llvm_ext.cc shims operand
#              bundles and debug locations below LLVM 18, and a statically
#              linked libLLVM carries its own C++ symbols at any version. When
#              both are absent, libc++ (and libstdc++ on Linux) drops off the
#              floor; when either holds it is on it, and this list says so
#              rather than the gate going red for a library the build was
#              right to link
#   gc         a compiler without a collector emits invalid IR (III.9)
#
# Every entry is a library the compiler names on its own link line. What
# libLLVM pulls in beyond itself (its own NEEDED list, a dozen libraries on a
# typical Linux, among them libxml2, libz and libffi) is LLVM's decision and
# the distribution's build, recorded when LLVM was accepted, and this list does
# not measure it. See libraries() for why it must not.
#
#
# pcre2 was here, with macro-level regex as its reason. It is not any more:
# macro regex runs on Crystal::Rx and the four stdlib files the compiler
# compiled into itself (option_parser, semantic_version, process/shell,
# spec/cli) parse by hand, so pcre2 is on the denylist below and the
# compiler is held to it too (Appendix B #22).
ALLOWED_LIBS_COMPILER="libLLVM libgc libSystem libc.so ld-linux libgcc_s libm.so libdl libpthread librt"
if [ -z "${LLVM_VERSION:-}" ]; then
  _llvm_config="${LLVM_CONFIG:-$("$REPO/src/llvm/ext/find-llvm-config.sh" 2>/dev/null || true)}"
  _llvm_version="$([ -n "$_llvm_config" ] && "$_llvm_config" --version 2>/dev/null || true)"
  [ -z "$_llvm_version" ] && _llvm_version="$("$REPO/bin/crystal" --version 2>/dev/null | sed -n 's/^LLVM: //p')"
else
  _llvm_version="$LLVM_VERSION"
fi
_llvm_major="${_llvm_version%%.*}"
_llvm_shared="$([ -n "${_llvm_config:-}" ] && "$_llvm_config" --shared-mode 2>/dev/null || true)"
[ -n "${LLVM_SHARED_MODE:-}" ] && _llvm_shared="$LLVM_SHARED_MODE"
_cxx_shim=false
[ -n "$_llvm_major" ] && [ "$_llvm_major" -lt 18 ] 2>/dev/null && _cxx_shim=true
# Unknown shared mode is not read as shared: a missing answer must not quietly
# widen the floor, and must not narrow it either, so it allows and the
# measurement below is what decides.
_llvm_static=true
[ "$_llvm_shared" = "shared" ] && _llvm_static=false
if [ "$_cxx_shim" = true ] || [ "$_llvm_static" = true ]; then
  ALLOWED_LIBS_COMPILER="$ALLOWED_LIBS_COMPILER libc++ libstdc++"
fi

# Crystal requires thirteen libraries:
#   1. libc        platform runtime (permitted for programs and compiler)
#   2. bdw-gc      garbage collector (compiler only, until self-hosting; forbidden for programs)
#   3. LLVM        code generation back end (compiler only, toolchain requirement; forbidden for programs)
#   4. libevent    event loop (forbidden for both; in-tree event loop)
#   5. compiler-rt runtime builtins (forbidden for both; ported in tree)
#   6. pcre2       regular expressions (forbidden for both; owned Iyi::Rx engine)
#   7. gmp         arbitrary precision numbers (forbidden for both)
#   8. iconv       character encoding (forbidden for both; UTF-8 only)
#   9. openssl     TLS and cryptography (forbidden for both; digests in tree)
#  10. libxml2     XML parsing (forbidden for both)
#  11. libyaml     YAML parsing (forbidden for both)
#  12. zlib        compression (forbidden for both; std/compress in tree)
#  13. libffi      interpreter FFI (forbidden for both; interpreter removed)
#
# The ancestor denylist names all thirteen. If an ancestor library appears on
# a link line, the failure message names it and identifies it as an ancestor
# dependency from Crystal's required-libraries list.
#
# Ancestor libraries forbidden for ALL binaries (programs and compiler alike):
ANCESTOR_FORBIDDEN_ALL="libevent:libevent compiler-rt:libclang_rt compiler-rt:compiler_rt pcre2:libpcre gmp:libgmp gmp:mpir iconv:libiconv openssl:libssl openssl:libcrypto libxml2:libxml2 libyaml:libyaml zlib:libz\\. libffi:libffi"

# Ancestor libraries permitted for the compiler only (with a recorded reason in SPEC.md III.9),
# but strictly forbidden for any program iyi builds:
ANCESTOR_COMPILER_ONLY="bdw-gc:libgc LLVM:libLLVM"

symbols() {
  nm -u "$1" 2>/dev/null |
    sed -e 's/^ *//' -e 's/^U  *//' -e 's/@.*$//' |
    awk '{ print $NF }' |
    sed -e 's/^_//' |
    grep -v '^$' |
    sort -u
}

libraries() {
  # What the binary itself asks to have loaded, and nothing more. `otool -L`
  # reports exactly that on darwin: the binary's own LC_LOAD_DYLIB commands.
  # readelf's NEEDED entries are the same thing on Linux. `ldd` was here and is
  # wrong twice: it prints the whole transitive closure, so libLLVM's own
  # choices landed in iyi's list (libxml2, libz, libffi and friends on Linux,
  # invisible on darwin only because otool reads direct dependencies, which
  # made the two platforms measure different claims), and it lists
  # linux-vdso.so.1, which the kernel maps at runtime and no binary requests.
  # The cost of reading direct dependencies is honest and small: a change in
  # what an ACCEPTED library pulls is not caught. LLVM taking on a new library
  # is not a decision any iyi commit made, and no iyi commit can unmake it.
  if command -v otool >/dev/null 2>&1; then
    otool -L "$1" 2>/dev/null | sed -n '2,$p' | awk '{ print $1 }' | sed 's|.*/||' | sort -u
  else
    readelf -d "$1" 2>/dev/null |
      sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' |
      sed 's|.*/||' | sort -u
  fi
}

# Reports every element of $2 not matched by a prefix in $1.
unexpected() {
  local allowed="$1" found="$2" item keep ok
  for item in $found; do
    keep=no
    for ok in $allowed; do
      case "$item" in "$ok"*) keep=yes ;; esac
    done
    [ "$keep" = no ] && printf '%s\n' "$item"
  done
  return 0
}

status=0
case "$(uname -s)" in
  Linux)
    allowed_symbols="$ALLOWED_SYMBOLS_LINUX"
    # A library reader that prints nothing passes every check, so the tool is
    # required up front rather than discovered missing one binary at a time.
    if ! command -v readelf >/dev/null 2>&1; then
      echo "dependency_floor: readelf is required on Linux to read NEEDED entries" >&2
      exit 2
    fi
    ;;
  *) allowed_symbols="$ALLOWED_SYMBOLS_DARWIN" ;;
esac

# Plain and --release both, into one set: the optimiser is a source of
# names of its own. It inlines the allocator and leaves variable-length
# `llvm.memset`s behind, and the aarch64 back end spelled those `bzero` —
# a name every darwin release binary asked libSystem for, that this gate
# never saw while it built plain, and that the thread floor found by
# reading its own release binary. The floor is what a program a person
# ships asks for, and a person ships --release.
found_syms="$WORK/syms"
found_libs="$WORK/libs"
: >"$found_syms"
: >"$found_libs"

for mode in "" "--release"; do
  echo "== programs, ${mode:-plain} build"
  for source in "$REPO"/samples/iyi/*.iyi; do
    sample="$(basename "$source" .iyi)${mode:+-release}"
    if ! "$IYI" build $mode -o "$WORK/$sample" "$source" >"$WORK/$sample.log" 2>&1; then
      echo "$sample: build failed"
      tail -5 "$WORK/$sample.log"
      status=1
      continue
    fi
    symbols "$WORK/$sample" >>"$found_syms"
    libraries "$WORK/$sample" >>"$found_libs"
    printf '  %-20s %s | %s\n' "$sample" \
      "$(symbols "$WORK/$sample" | tr '\n' ' ')" \
      "$(libraries "$WORK/$sample" | tr '\n' ' ')"
  done
done

# The samples are what a person writes; `src/std/` is what they import, and a
# module no sample reaches was measured by nothing. `import std/socket` alone
# does not move the link line — codegen is demand-driven, so a `fun` nobody
# calls is a declaration and not a symbol — which is exactly why the
# exercises are the thing to build here: each one calls its module's surface.
echo "== the std exercises, which call what src/std declares"
for source in "$REPO"/bench/std_*_exercise.iyi; do
  [ -f "$source" ] || continue
  exercise="$(basename "$source" .iyi)"
  if ! "$IYI" build -o "$WORK/$exercise" "$source" >"$WORK/$exercise.log" 2>&1; then
    echo "$exercise: build failed"
    tail -5 "$WORK/$exercise.log"
    status=1
    continue
  fi
  symbols "$WORK/$exercise" >>"$found_syms"
  libraries "$WORK/$exercise" >>"$found_libs"
  printf '  %-28s %s | %s\n' "$exercise" \
    "$(symbols "$WORK/$exercise" | tr '\n' ' ')" \
    "$(libraries "$WORK/$exercise" | tr '\n' ' ')"
done

[ "$status" -eq 0 ] || { echo; echo "a sample did not build, so no floor was measured"; exit 1; }

prog_syms="$(sort -u "$found_syms")"
prog_libs="$(sort -u "$found_libs")"

echo
echo "== libgc is opt-in, and asking for it is the only way to get it"
# The default is the owned collector, which links nothing; libgc arrives
# only with -Dgc_boehm, and -Dgc_none (the bump pointer) must stay as
# library-free as the default it used to be.
"$IYI" build -Dgc_boehm -o "$WORK/boehm" "$REPO/samples/iyi/hello.iyi" >/dev/null 2>&1
boehm_libs="$(libraries "$WORK/boehm")"
printf '  -Dgc_boehm  %s\n' "$(echo "$boehm_libs" | tr '\n' ' ')"
if ! echo "$boehm_libs" | grep -q 'libgc\.'; then
  echo "  -Dgc_boehm did not link a collector, so the opt-in is broken"
  status=1
fi
if echo "$prog_libs" | grep -q 'libgc\.'; then
  echo "  a plain build linked libgc, so the owned default is not holding the floor"
  status=1
fi
"$IYI" build -Dgc_none -o "$WORK/none" "$REPO/samples/iyi/hello.iyi" >/dev/null 2>&1
none_libs="$(libraries "$WORK/none")"
printf '  -Dgc_none   %s\n' "$(echo "$none_libs" | tr '\n' ' ')"
if echo "$none_libs" | grep -q 'libgc\.'; then
  echo "  -Dgc_none linked libgc, so the opt-out is broken"
  status=1
fi

echo
echo "== the compiler"
compiler_libs="$(libraries "$REPO/.build/iyi")"
printf '  %s\n' "$(echo "$compiler_libs" | tr '\n' ' ')"

echo
echo "== what the library declares, reached or not"
# A measurement only sees what a program calls, so a `@[Link]` sitting in the
# library against the day somebody calls it is invisible to everything above.
# It is also the shape a link line grows in: one annotation, no caller yet,
# and the floor moves the first time a module uses it. So the annotations are
# read as text, and the list is the three the library has reasons for.
while IFS= read -r annotation; do
  [ -n "$annotation" ] || continue
  case "$annotation" in
    '@[Link("kernel32")]') ;;
    '@[Link(ldflags: "msvcrt.lib ucrt.lib vcruntime.lib")]') ;;
    '@[Link("gc", pkg_config: "bdw-gc")]') ;;
    *)
      echo "  THE FLOOR MOVED: the library declares $annotation"
      echo "  A library iyi ships links the platform libc and, opt-in, a"
      echo "  collector. A fourth annotation needs a reason in SPEC.md III.10"
      echo "  before it needs a line here."
      status=1
      ;;
  esac
done <<LINKS
$(grep -rhoE '@\[Link\([^]]*\)\]' "$REPO/src/iyi" "$REPO/src/std" | sort -u)
LINKS
printf '  %s\n' "$(grep -rhoE '@\[Link\([^]]*\)\]' "$REPO/src/iyi" "$REPO/src/std" | sort -u | tr '\n' ' ')"

echo
report() {
  local what="$1" extra="$2" note="$3"
  if [ -n "$extra" ]; then
    echo "THE FLOOR MOVED: $what gained:"
    printf '  %s\n' $extra
    echo "$note"
    status=1
  fi
}

report "a program's undefined symbols" \
  "$(unexpected "$allowed_symbols" "$(echo $prog_syms)")" \
  "Each is something the machine must supply. If that is the decision, add it to
ALLOWED_SYMBOLS_* in this script and say why in the commit (SPEC.md III.9)."

report "a program's libraries" \
  "$(unexpected "$ALLOWED_LIBS_PROGRAM" "$(echo $prog_libs)")" \
  "A program iyi builds may link the platform libc and nothing else (SPEC.md III.10)."

report "the compiler's libraries" \
  "$(unexpected "$ALLOWED_LIBS_COMPILER" "$(echo $compiler_libs)")" \
  "The compiler's list is short and every entry has a reason in SPEC.md III.9 or
III.10. A new one needs a reason there before it needs a line here."

# The denylist is separate from the allowlists on purpose: an allowlist typo
# would silently permit one of these, and these are the ones the objective
# names. It is read against what a binary itself loads, so iyi naming one of
# these on its own link line fails here even when the same name arrives
# legitimately inside libLLVM's own dependency list.
for binary in "$WORK"/* "$REPO/.build/iyi"; do
  [ -f "$binary" ] || continue
  case "$binary" in *.log | *syms | *libs | */boehm) continue ;; esac
  bin_libs="$(libraries "$binary")"
  is_compiler=no
  [ "$binary" = "$REPO/.build/iyi" ] && is_compiler=yes

  for entry in $ANCESTOR_FORBIDDEN_ALL; do
    name="${entry%%:*}"
    pattern="${entry#*:}"
    if match="$(echo "$bin_libs" | grep -E "$pattern" | head -n 1)"; then
      [ -n "$match" ] || continue
      echo "FORBIDDEN: $(basename "$binary") links $name ($match), which is an ancestor dependency"
      echo "from Crystal's required-libraries list and iyi is not allowed to need it."
      status=1
    fi
  done

  if [ "$is_compiler" = no ]; then
    for entry in $ANCESTOR_COMPILER_ONLY; do
      name="${entry%%:*}"
      pattern="${entry#*:}"
      if match="$(echo "$bin_libs" | grep -E "$pattern" | head -n 1)"; then
        [ -n "$match" ] || continue
        echo "FORBIDDEN: $(basename "$binary") links $name ($match), which is an ancestor dependency"
        echo "from Crystal's required-libraries list and is not allowed in an iyi program."
        status=1
      fi
    done
  fi
done

# A floor that dropped and was not recorded stops being a floor.
missing="$(unexpected "$(echo $prog_syms)" "$allowed_symbols")"
if [ -n "$missing" ]; then
  echo "The floor got lower and this script is out of date. No longer needed:"
  printf '  %s\n' $missing
  echo "Remove them from ALLOWED_SYMBOLS_* so the check keeps its teeth."
  status=1
fi

[ "$status" -eq 0 ] && echo "the floor holds"
exit $status
