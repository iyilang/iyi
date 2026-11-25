/* TEST STAND-IN, NOT THE RUNTIME. The native backend calls these helpers for
 * memory intrinsics that are large or of variable length, and for 128-bit
 * division and remainder. The runtime-helpers slice defines them for real;
 * until it lands, the codegen gate links this file so that the fixtures can
 * run. Replace this file when that slice merges. */
#include <pthread.h>
#include <stdint.h>
#include <string.h>

/* A plain forward copy: on overlapping ranges it differs from memmove, so the
 * gate can tell the two apart. */
void __iyi_native_memcpy(void *dst, const void *src, int64_t n) {
  unsigned char *d = dst;
  const unsigned char *s = src;
  for (int64_t i = 0; i < n; i++)
    d[i] = s[i];
}
void __iyi_native_memmove(void *dst, const void *src, int64_t n) {
  memmove(dst, src, (size_t)n);
}
void __iyi_native_memset(void *dst, int64_t value, int64_t n) {
  memset(dst, (int)value, (size_t)n);
}

/* The 128-bit division helpers, with C's truncating semantics as the IR's
 * sdiv/udiv/srem/urem have. */
__int128 __iyi_native_divti3(__int128 a, __int128 b) { return a / b; }
unsigned __int128 __iyi_native_udivti3(unsigned __int128 a,
                                       unsigned __int128 b) {
  return a / b;
}
__int128 __iyi_native_modti3(__int128 a, __int128 b) { return a % b; }
unsigned __int128 __iyi_native_umodti3(unsigned __int128 a,
                                       unsigned __int128 b) {
  return a % b;
}

/* Runs fn(arg) on a thread of its own and returns what it returns. The threads
 * fixture uses it to show that a thread-local is one copy per thread. */
struct fixture_thread {
  int64_t (*fn)(int64_t);
  int64_t arg;
  int64_t result;
};
static void *fixture_thread_entry(void *p) {
  struct fixture_thread *t = p;
  t->result = t->fn(t->arg);
  return NULL;
}
int64_t __fixture_run_on_thread(int64_t (*fn)(int64_t), int64_t arg) {
  struct fixture_thread t = {fn, arg, 0};
  pthread_t th;
  if (pthread_create(&th, NULL, fixture_thread_entry, &t) != 0)
    return -1;
  pthread_join(th, NULL);
  return t.result;
}

int32_t __fixture_negative(void) { return -1; }
int32_t __fixture_call_byte(int32_t (*fn)(uint8_t)) { return fn(128); }
uint64_t __fixture_argbits(uint64_t value) { return value; }
uint64_t __fixture_signbits(uint64_t value) { return (uint32_t)value; }
