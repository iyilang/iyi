/* iyi: glibc's excess-precision guard, which a binary64 target does not need. */
#define math_narrow_eval(x) (x)
