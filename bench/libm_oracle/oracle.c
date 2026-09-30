/*
 * iyi: Arm's exp, exp2, log, log2 and pow, and glibc's fdlibm log10, expm1,
 * log1p, sinh, cosh and tanh, and its CORE-MATH erf, erfc, asinh, acosh and
 * atanh, lgamma and tgamma behind the wrappers glibc's symbols are, and
 * CORE-MATH's own atan, asin, acos and tan (`core_math/`, linked with
 * libm for their exact `fma`), as `bench/std_math_exercise.sh` asks them.
 * `oracle exp IN OUT` (or `exp2`, `log`, `log2`, `log10`, `expm1`, `log1p`,
 * `sinh`, `cosh`, `tanh`, `erf`, `erfc`, `asinh`, `acosh`, `atanh`, `atan`,
 * `asin`, `acos`, `tan`, `lgamma`, `tgamma`) reads doubles from
 * IN and writes each with its answer to OUT; `oracle pow IN OUT` reads
 * pairs and writes each with its power.
 * The files are opened in binary, which a Windows C runtime's standard
 * streams are not. Built with contraction off: this is the algorithm as
 * written, not the fused build glibc picks on a processor with FMA, which
 * answers differently in the last bit for about 7 arguments in 10,000.
 */
#include <stdio.h>
#include <string.h>
#include <math.h>
double exp (double);
double pow (double, double);
double log (double);
double exp2 (double);
double log2 (double);
double __ieee754_log10 (double);
double __expm1 (double);
double __log1p (double);
double __ieee754_sinh (double);
double __ieee754_cosh (double);
double __tanh (double);
double __erf (double);
double __erfc (double);
double __asinh (double);
double __ieee754_acosh (double);
double __ieee754_atanh (double);
double cr_atan (double);
double cr_asin (double);
double cr_acos (double);
double cr_tan (double);
double __ieee754_lgamma_r (double, int *);
double __ieee754_gamma_r (double, int *);

/* What the x86_64 libm's lgamma and tgamma symbols answer around glibc's
   __ieee754 functions: math/w_lgamma_main.c and math/w_tgamma_compat.c
   under _POSIX_, with the returns of sysdeps/ieee754/k_standard.c. */
static double lgamma_posix (double x)
{
  int sg;
  double y = __ieee754_lgamma_r (x, &sg);
  if (!isfinite (y) && isfinite (x))
    y = HUGE_VAL;
  return y;
}

static double tgamma_posix (double x)
{
  int sg;
  double y = __ieee754_gamma_r (x, &sg);
  if ((!isfinite (y) || y == 0) && (isfinite (x) || (isinf (x) && x < 0.0)))
    {
      if (x == 0.0)
        y = copysign (HUGE_VAL, x);
      else if (floor (x) == x && x < 0.0)
        y = NAN;
      else if (y != 0)
        y = copysign (HUGE_VAL, x);
    }
  return sg < 0 ? -y : y;
}

static double unary (const char *name, double x)
{
  if (strcmp (name, "log") == 0)
    return log (x);
  if (strcmp (name, "exp2") == 0)
    return exp2 (x);
  if (strcmp (name, "log2") == 0)
    return log2 (x);
  if (strcmp (name, "log10") == 0)
    return __ieee754_log10 (x);
  if (strcmp (name, "expm1") == 0)
    return __expm1 (x);
  if (strcmp (name, "log1p") == 0)
    return __log1p (x);
  if (strcmp (name, "sinh") == 0)
    return __ieee754_sinh (x);
  if (strcmp (name, "cosh") == 0)
    return __ieee754_cosh (x);
  if (strcmp (name, "tanh") == 0)
    return __tanh (x);
  if (strcmp (name, "erf") == 0)
    return __erf (x);
  if (strcmp (name, "erfc") == 0)
    return __erfc (x);
  if (strcmp (name, "asinh") == 0)
    return __asinh (x);
  if (strcmp (name, "acosh") == 0)
    return __ieee754_acosh (x);
  if (strcmp (name, "atanh") == 0)
    return __ieee754_atanh (x);
  if (strcmp (name, "atan") == 0)
    return cr_atan (x);
  if (strcmp (name, "asin") == 0)
    return cr_asin (x);
  if (strcmp (name, "acos") == 0)
    return cr_acos (x);
  if (strcmp (name, "tan") == 0)
    return cr_tan (x);
  if (strcmp (name, "lgamma") == 0)
    return lgamma_posix (x);
  if (strcmp (name, "tgamma") == 0)
    return tgamma_posix (x);
  return exp (x);
}
int main (int argc, char **argv)
{
  double v[3];
  FILE *in, *out;
  if (argc != 4)
    return 2;
  in = fopen (argv[2], "rb");
  out = fopen (argv[3], "wb");
  if (in == NULL || out == NULL)
    return 1;
  if (strcmp (argv[1], "pow") == 0)
    while (fread (v, sizeof v[0], 2, in) == 2)
      {
        v[2] = pow (v[0], v[1]);
        fwrite (v, sizeof v[0], 3, out);
      }
  else
    while (fread (v, sizeof v[0], 1, in) == 1)
      {
        v[1] = unary (argv[1], v[0]);
        fwrite (v, sizeof v[0], 2, out);
      }
  return fclose (out) == 0 ? 0 : 1;
}
