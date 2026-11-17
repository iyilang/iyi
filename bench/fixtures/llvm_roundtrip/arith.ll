; ModuleID = 'arith'
source_filename = "arith"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-apple-darwin"

define i32 @add_nsw(i32 %a, i32 %b) {
entry:
  %s = add nsw i32 %a, %b
  %t = mul i32 %s, 3
  %c = icmp slt i32 %t, 100
  br i1 %c, label %small, label %big

small:
  ret i32 %t

big:
  %d = sdiv exact i32 %t, 2
  ret i32 %d
}
