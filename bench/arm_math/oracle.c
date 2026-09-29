/*
 * iyi: Arm's exp and pow as `bench/std_math_exercise.sh` asks them.
 * `oracle exp IN OUT` reads doubles from IN and writes each with its exp
 * to OUT; `oracle pow IN OUT` reads pairs and writes each with its power.
 * The files are opened in binary, which a Windows C runtime's standard
 * streams are not. Built with contraction off: this is the algorithm as
 * written, not the fused build glibc picks on a processor with FMA, which
 * answers differently in the last bit for about 7 arguments in 10,000.
 */
#include <stdio.h>
#include <string.h>
double exp (double);
double pow (double, double);
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
        v[1] = exp (v[0]);
        fwrite (v, sizeof v[0], 2, out);
      }
  return fclose (out) == 0 ? 0 : 1;
}
