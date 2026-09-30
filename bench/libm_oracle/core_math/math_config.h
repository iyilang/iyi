/*
 * iyi: what glibc 2.43's CORE-MATH files read from glibc's own
 * `math_config.h` - not Arm's, one directory up, which a quoted include
 * from here does not reach - for `bench/std_math_exercise.sh`'s oracle:
 * the bit casts, rounding to even, the special results without errno or
 * the exception flags, and glibc's branch hints.
 */
#ifndef IYI_CORE_MATH_CONFIG
#define IYI_CORE_MATH_CONFIG
#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>
#include <math.h>
#define SIGN_MASK UINT64_C(0x8000000000000000)
#ifndef __glibc_unlikely
# define __glibc_unlikely(x) __builtin_expect (!!(x), 0)
#endif
#ifndef __glibc_likely
# define __glibc_likely(x) __builtin_expect (!!(x), 1)
#endif
static inline double asdouble (uint64_t i) { union { uint64_t i; double f; } u = { i }; return u.f; }
static inline uint64_t asuint64 (double f) { union { double f; uint64_t i; } u = { f }; return u.i; }
static inline double roundeven_finite (double x) { return __builtin_roundeven (x); }
static inline double __math_erange (double x) { return x; }
static inline double __math_uflow_value (double x) { return x; }
static inline double __math_invalid (double x) { return (x - x) / (x - x); }
static inline double __math_divzero (uint32_t s) { return (s ? -1.0 : 1.0) / 0.0; }
static inline double __math_check_uflow_lt (double x, double y) { (void) y; return x; }
static inline double __math_check_uflow_zero_lt (double x, double y, double z) { (void) x; (void) y; return z; }
#define __ldexp ldexp
#endif
