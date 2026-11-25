; ModuleID = 'wide_int'
source_filename = "wide_int"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-apple-darwin"

@max = global i128 170141183460469231731687303715884105727, align 16
@min = global i128 -170141183460469231731687303715884105728, align 16
@two64 = global i128 18446744073709551616, align 16

define i128 @wide(i128 %x) {
entry:
  %a = add i128 %x, 18446744073709551617
  %b = icmp slt i128 %a, -18446744073709551616
  %c = select i1 %b, i128 -1, i128 %a
  ret i128 %c
}
