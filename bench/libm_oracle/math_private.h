/*
 * iyi: what glibc's `e_log10.c`, `s_expm1.c` and `s_log1p.c` read from
 * glibc's internal headers, for `bench/std_math_exercise.sh`'s oracle: the
 * word access, no errno, and the log `e_log10.c` builds on, which in glibc
 * is Arm's `log` - the one in this directory.
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
#define SET_HIGH_WORD(d, v) do { uint64_t iyi_w_; memcpy (&iyi_w_, &(d), 8); iyi_w_ = (iyi_w_ & 0xffffffffULL) | ((uint64_t) (uint32_t) (v) << 32); memcpy (&(d), &iyi_w_, 8); } while (0)
#define __set_errno(e) ((void) 0)
double log (double);
#define __ieee754_log log
#endif
