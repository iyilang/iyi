/* iyi: glibc's barriers; the oracle keeps no exception flags. */
#define math_force_eval(x) ((void) (x))
#define math_opt_barrier(x) (x)
