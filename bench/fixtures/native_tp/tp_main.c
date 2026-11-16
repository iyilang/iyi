/* Calls the native thread pointer read twice on this thread. The value must be
 * non-zero, 8-aligned (its low three bits are the CPU number, which the read
 * clears), and the same on both reads. Exit status 0 when all three hold. */
#include <stdint.h>

int64_t tp_word(void);

int main(void) {
  int64_t a = tp_word();
  int64_t b = tp_word();
  return (a != 0 && (a & 7) == 0 && a == b) ? 0 : 1;
}
