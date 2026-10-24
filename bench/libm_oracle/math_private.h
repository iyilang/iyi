/*
 * iyi: what glibc's `e_log10.c`, `s_expm1.c`, `s_log1p.c`, `e_sinh.c`,
 * `e_cosh.c`, `s_tanh.c`, `e_j0.c`, `e_j1.c` and `e_jn.c` read from glibc's
 * internal headers, for `bench/std_math_exercise.sh`'s oracle: the word
 * access, no errno, and the log and exp they build on, which in glibc are
 * Arm's - the ones in this directory - and fdlibm's expm1, `s_expm1.c`
 * here. The Bessel functions' sin and cos are CORE-MATH's (`core_math/`),
 * which iyi's are; glibc's own, IBM's, differ from them for about one
 * argument in a thousand, and so do glibc's j0 and y0 there.
 */
#ifndef IYI_MATH_PRIVATE
#define IYI_MATH_PRIVATE
#include <stdint.h>
#include <string.h>
#define EXTRACT_WORDS64(i, d) do { double iyi_d_ = (d); memcpy (&(i), &iyi_d_, 8); } while (0)
#define INSERT_WORDS64(d, i) do { int64_t iyi_i_ = (i); memcpy (&(d), &iyi_i_, 8); } while (0)
#ifndef __glibc_unlikely
# define __glibc_unlikely(x) __builtin_expect (!!(x), 0)
#endif
#define fabs(x) __builtin_fabs (x)
#define GET_HIGH_WORD(i, d) do { uint64_t iyi_w_; double iyi_d_ = (d); memcpy (&iyi_w_, &iyi_d_, 8); (i) = (uint32_t) (iyi_w_ >> 32); } while (0)
#define GET_LOW_WORD(i, d) do { uint64_t iyi_w_; double iyi_d_ = (d); memcpy (&iyi_w_, &iyi_d_, 8); (i) = (uint32_t) iyi_w_; } while (0)
#define EXTRACT_WORDS(hi, lo, d) do { uint64_t iyi_w_; double iyi_d_ = (d); memcpy (&iyi_w_, &iyi_d_, 8); (hi) = (int32_t) (iyi_w_ >> 32); (lo) = (int32_t) (uint32_t) iyi_w_; } while (0)
#define SET_HIGH_WORD(d, v) do { uint64_t iyi_w_; memcpy (&iyi_w_, &(d), 8); iyi_w_ = (iyi_w_ & 0xffffffffULL) | ((uint64_t) (uint32_t) (v) << 32); memcpy (&(d), &iyi_w_, 8); } while (0)
#define __set_errno(e) ((void) 0)
double log (double);
#define __ieee754_log log
double exp (double);
#define __ieee754_exp exp
double __expm1 (double);
double cr_sin (double);
double cr_cos (double);
#define __sin cr_sin
#define __cos cr_cos
#define __sincos(x, s, c) (*(s) = cr_sin (x), *(c) = cr_cos (x))
#define __ieee754_sqrt(x) __builtin_sqrt (x)
#define SET_RESTORE_ROUND(m) ((void) 0)
#define __feraiseexcept(e) ((void) 0)
double __ieee754_j0 (double);
double __ieee754_j1 (double);
double __ieee754_y0 (double);
double __ieee754_y1 (double);
#endif
