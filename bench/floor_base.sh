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
