/*
 * iyi: reads doubles from stdin and writes each with Arm's exp of it, as
 * pairs of doubles, for `bench/std_math_exercise.sh`. Built with
 * contraction off: this is the algorithm as written, not the fused build
 * glibc picks on a processor with FMA, which answers differently in the
 * last bit for about 7 arguments in 10,000.
 */
#include <stdio.h>
double exp (double);
int main (void)
{
  double x, y;
  while (fread (&x, sizeof x, 1, stdin) == 1)
    {
      y = exp (x);
      fwrite (&x, sizeof x, 1, stdout);
      fwrite (&y, sizeof y, 1, stdout);
    }
  return 0;
}
