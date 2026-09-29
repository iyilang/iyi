/*
 * iyi: what glibc's `e_log10.c` reads from glibc's internal headers, for
 * `bench/std_math_exercise.sh`'s oracle: the word access, and the log it
 * builds on, which in glibc is Arm's `log` - the one in this directory.
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
double log (double);
#define __ieee754_log log
#endif
