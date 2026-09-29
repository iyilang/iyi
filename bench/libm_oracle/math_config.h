/*
 * iyi: the part of optimized-routines' `math/math_config.h` that `exp.c`,
 * `exp2.c`, `log.c`, `log2.c`, `pow.c` and their data read, for `bench/std_math_exercise.sh`'s oracle:
 * the configuration glibc builds them with on x86_64 (128-entry tables, a
 * degree-5 exp polynomial, degree-6 and -12 log ones and a degree-8 one
 * for pow's log, the reduction by adding
 * 1.5 * 2^52, no fused multiply-add), and no errno, which the oracle does
 * not read.
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
#define HAVE_FAST_FMA 0
#define POW_LOG_TABLE_BITS 7
#define POW_LOG_POLY_ORDER 8
#define LOG_TABLE_BITS 7
#define LOG_POLY_ORDER 6
#define LOG_POLY1_ORDER 12
#define LOG2_TABLE_BITS 6
#define LOG2_POLY_ORDER 7
#define LOG2_POLY1_ORDER 11
#define WANT_ROUNDING 1
#define WANT_ERRNO 0
#define USE_GLIBC_ABI 0
#define HIDDEN
#define ALIGN(x)
#define unlikely(x) __builtin_expect (!!(x), 0)
/* No libm is linked: the oracle is these files, and `fabs` is the builtin. */
#define fabs(x) __builtin_fabs (x)
static inline double asdouble (uint64_t i) { union { uint64_t i; double f; } u = { i }; return u.f; }
static inline uint64_t asuint64 (double f) { union { double f; uint64_t i; } u = { f }; return u.i; }
static inline double eval_as_double (double x) { return x; }
static inline double check_oflow (double x) { return x; }
static inline double check_uflow (double x) { return x; }
static inline double opt_barrier_double (double x) { volatile double y = x; return y; }
static inline void force_eval_double (double x) { volatile double y = x; (void) y; }
static inline double __math_uflow (uint32_t s) { return (s ? -0x1p-767 : 0x1p-767) * 0x1p-767; }
static inline double __math_oflow (uint32_t s) { return (s ? -0x1p769 : 0x1p769) * 0x1p769; }
static inline double __math_invalid (double x) { return (x - x) / (x - x); }
static inline double __math_divzero (uint32_t s) { return (s ? -1.0 : 1.0) / 0.0; }
static inline int issignaling_inline (double x) { (void) x; return 0; }
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
extern const struct pow_log_data
{
  double ln2hi;
  double ln2lo;
  double poly[POW_LOG_POLY_ORDER - 1];
  struct { double invc, pad, logc, logctail; } tab[1 << POW_LOG_TABLE_BITS];
} __pow_log_data;
extern const struct log_data
{
  double ln2hi;
  double ln2lo;
  double poly[LOG_POLY_ORDER - 1];
  double poly1[LOG_POLY1_ORDER - 1];
  struct { double invc, logc; } tab[1 << LOG_TABLE_BITS];
  struct { double chi, clo; } tab2[1 << LOG_TABLE_BITS];
} __log_data;
extern const struct log2_data
{
  double invln2hi;
  double invln2lo;
  double poly[LOG2_POLY_ORDER - 1];
  double poly1[LOG2_POLY1_ORDER - 1];
  struct { double invc, logc; } tab[1 << LOG2_TABLE_BITS];
  struct { double chi, clo; } tab2[1 << LOG2_TABLE_BITS];
} __log2_data;
#endif
