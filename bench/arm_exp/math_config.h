/*
 * iyi: the part of optimized-routines' `math/math_config.h` that `exp.c`
 * and `exp_data.c` read, for `bench/std_math_exercise.sh`'s oracle: the
 * configuration glibc builds exp with on x86_64 (a 128-entry table, a
 * degree-5 polynomial, the reduction by adding 1.5 * 2^52), and no errno,
 * which the oracle does not read.
 */
#ifndef IYI_ARM_EXP_CONFIG
#define IYI_ARM_EXP_CONFIG
#include <stdint.h>
#define EXP_TABLE_BITS 7
#define EXP_POLY_ORDER 5
#define EXP_POLY_WIDE 0
#define EXP_USE_TOINT_NARROW 0
#define EXP2_POLY_ORDER 5
#define EXP2_POLY_WIDE 0
#define EXP10_POLY_WIDE 0
#define TOINT_INTRINSICS 0
#define WANT_ROUNDING 1
#define WANT_ERRNO 0
#define USE_GLIBC_ABI 0
#define HIDDEN
#define ALIGN(x)
#define unlikely(x) __builtin_expect (!!(x), 0)
static inline double asdouble (uint64_t i) { union { uint64_t i; double f; } u = { i }; return u.f; }
static inline uint64_t asuint64 (double f) { union { double f; uint64_t i; } u = { f }; return u.i; }
static inline double eval_as_double (double x) { return x; }
static inline double check_oflow (double x) { return x; }
static inline double check_uflow (double x) { return x; }
static inline double opt_barrier_double (double x) { volatile double y = x; return y; }
static inline void force_eval_double (double x) { volatile double y = x; (void) y; }
static inline double __math_uflow (uint32_t s) { return (s ? -0x1p-767 : 0x1p-767) * 0x1p-767; }
static inline double __math_oflow (uint32_t s) { return (s ? -0x1p769 : 0x1p769) * 0x1p769; }
extern const struct exp_data
{
  double invln2N;
  double negln2hiN;
  double negln2loN;
  double poly[4];
  double shift;
  double exp2_shift;
  double exp2_poly[EXP2_POLY_ORDER];
  double neglog10_2hiN;
  double neglog10_2loN;
  double exp10_poly[5];
  uint64_t tab[2 * (1 << EXP_TABLE_BITS)];
  double invlog10_2N;
} __exp_data;
#endif
