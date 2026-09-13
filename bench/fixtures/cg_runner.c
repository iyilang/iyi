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

// cg_structs
int32_t make_point_x(int32_t x, int32_t y);
int32_t make_point_y(int32_t x, int32_t y);
int32_t mutate_point_x(int32_t x, int32_t y, int32_t new_x);
int32_t rect_area(int32_t x, int32_t y, int32_t w, int32_t h);

// cg_struct_methods
int32_t vec_len_sq(int32_t x, int32_t y);
int32_t vec_dot(int32_t x1, int32_t y1, int32_t x2, int32_t y2);
int32_t vec_add_and_len(int32_t x1, int32_t y1, int32_t x2, int32_t y2);

// cg_pointers
int32_t ptr_read_write(int32_t x, int32_t val);
int32_t ptr_sum_array(int32_t *ptr, int32_t len);
int64_t ptr_diff(int32_t *ptr, int32_t offset);
int32_t ptr_address_roundtrip(int32_t x);

// cg_classes
int32_t class_counter_get(int32_t initial);
int32_t class_counter_inc(int32_t initial, int32_t by);
int32_t class_multiplier_scaled(int32_t initial, int32_t factor);

// cg_virtual_dispatch
int32_t test_virtual_area(int32_t kind, int32_t id, int32_t val);
int32_t test_virtual_base_method(int32_t kind, int32_t id, int32_t val);

// cg_nilable
int32_t test_nilable_class(int32_t flag, int32_t v);
bool test_nil_check(int32_t flag, int32_t v);

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

  // Test 6: Structs and field access
  int32_t p_x = make_point_x(10, 20);
  int32_t p_y = make_point_y(10, 20);
  int32_t p_mut = mutate_point_x(10, 20, 99);
  int32_t r_area = rect_area(0, 0, 8, 6);
  printf("structs: %d %d %d %d\n", p_x, p_y, p_mut, r_area);

  // Test 7: Struct methods
  int32_t v_len = vec_len_sq(3, 4);
  int32_t v_dot = vec_dot(2, 3, 4, 5);
  int32_t v_add_len = vec_add_and_len(1, 2, 2, 2);
  printf("struct_methods: %d %d %d\n", v_len, v_dot, v_add_len);

  // Test 8: Pointer operations
  int32_t p_rw = ptr_read_write(5, 42);
  int32_t arr[5] = {1, 2, 3, 4, 5};
  int32_t p_sum = ptr_sum_array(arr, 5);
  int64_t p_d = ptr_diff(arr, 3);
  int32_t p_addr = ptr_address_roundtrip(77);
  printf("pointers: %d %d %lld %d\n", p_rw, p_sum, (long long)p_d, p_addr);

  // Test 9: Classes and instance variables
  int32_t c_get = class_counter_get(15);
  int32_t c_inc = class_counter_inc(15, 7);
  int32_t m_scaled = class_multiplier_scaled(10, 5);
  printf("classes: %d %d %d\n", c_get, c_inc, m_scaled);

  // Test 10: Virtual hierarchy dynamic dispatch
  int32_t v_c_area = test_virtual_area(1, 100, 5);
  int32_t v_s_area = test_virtual_area(2, 200, 7);
  int32_t v_b_area = test_virtual_area(3, 300, 0);
  int32_t v_c_id = test_virtual_base_method(1, 100, 5);
  int32_t v_s_id = test_virtual_base_method(2, 200, 7);
  int32_t v_b_id = test_virtual_base_method(3, 300, 0);
  printf("virtual: %d %d %d %d %d %d\n", v_c_area, v_s_area, v_b_area, v_c_id,
         v_s_id, v_b_id);

  // Test 11: Nilable values and nil checks
  int32_t n_val = test_nilable_class(1, 42);
  int32_t n_zero = test_nilable_class(0, 42);
  bool n_chk_false = test_nil_check(1, 42);
  bool n_chk_true = test_nil_check(0, 42);
  printf("nilable: %d %d %d %d\n", n_val, n_zero, (int)n_chk_false,
         (int)n_chk_true);

  return 0;
}
