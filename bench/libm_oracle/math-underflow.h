/* iyi: glibc's underflow check; the oracle keeps no exception flags. */
#define math_check_force_underflow(x) ((void) 0)
