/* iyi: C23's <stdbit.h>, the one function glibc's CORE-MATH lgamma calls,
   and only on a 64-bit word; mingw's gcc on the Windows runner has no
   header, and the oracle's CORE-MATH part did not build there. */
#ifndef IYI_ORACLE_STDBIT_H
#define IYI_ORACLE_STDBIT_H
#include <stdint.h>

static inline int
iyi_oracle_leading_zeros (uint64_t x)
{
  return x == 0 ? 64 : __builtin_clzll (x);
}

#define stdc_leading_zeros(x) iyi_oracle_leading_zeros (x)
#endif
