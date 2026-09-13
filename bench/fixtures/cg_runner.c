#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

// cg_int_arith
int32_t int_add(int32_t a, int32_t b);
int32_t int_ops(int32_t a, int32_t b);
int32_t int_bitwise(int32_t a, int32_t b);
int32_t int_shifts(int32_t a, int32_t b);
int64_t int64_calc(int64_t a, int64_t b);

// cg_float_arith
double float_add(double a, double b);
double float_ops(double a, double b);
double float_neg(double a);

// cg_comparisons
bool int_lt(int32_t a, int32_t b);
bool int_lte(int32_t a, int32_t b);
bool int_gt(int32_t a, int32_t b);
bool int_gte(int32_t a, int32_t b);
bool int_eq(int32_t a, int32_t b);
bool int_ne(int32_t a, int32_t b);
bool float_lt(double a, double b);
bool float_eq(double a, double b);

// cg_control
int32_t abs_val(int32_t x);
int32_t sum_up_to(int32_t n);

// cg_calls
int32_t square(int32_t x);
int32_t sum_of_squares(int32_t a, int32_t b);
int32_t gcd(int32_t a, int32_t b);

int main(void) {
  // Test 1: Integer arithmetic
  int32_t r_add = int_add(10, 32);
  int32_t r_ops = int_ops(15, 5);
  int32_t r_bit = int_bitwise(12, 10);
  int32_t r_shf = int_shifts(16, 2);
  int64_t r_i64 = int64_calc(100LL, 20LL);
  printf("int_add=%d, int_ops=%d, int_bit=%d, int_shf=%d, int64=%lld\n", r_add,
         r_ops, r_bit, r_shf, (long long)r_i64);

  // Test 2: Float arithmetic
  double f_add = float_add(1.5, 2.5);
  double f_ops = float_ops(5.0, 3.0);
  double f_neg = float_neg(7.25);
  printf("f_add=%.1f, f_ops=%.4f, f_neg=%.2f\n", f_add, f_ops, f_neg);

  // Test 3: Comparisons
  printf("cmps: %d %d %d %d %d %d, flt: %d %d\n", int_lt(5, 10),
         int_lte(10, 10), int_gt(15, 10), int_gte(10, 15), int_eq(42, 42),
         int_ne(42, 42), float_lt(1.5, 2.5), float_eq(3.0, 3.0));

  // Test 4: Control flow
  int32_t abs_neg = abs_val(-42);
  int32_t abs_pos = abs_val(42);
  int32_t sum10 = sum_up_to(10);
  printf("abs_neg=%d, abs_pos=%d, sum10=%d\n", abs_neg, abs_pos, sum10);

  // Test 5: Function calls and algorithms
  int32_t sq7 = square(7);
  int32_t sum_sq = sum_of_squares(3, 4);
  int32_t g = gcd(48, 18);
  printf("square=%d, sum_of_squares=%d, gcd=%d\n", sq7, sum_sq, g);

  return 0;
}
