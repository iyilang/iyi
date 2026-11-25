; ModuleID = 'consts'
source_filename = "consts"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-apple-darwin"

@table = internal constant [3 x i32] [i32 1, i32 2, i32 3], align 4
@fp = global double 1.500000e+00, align 8
@ff = global float 2.500000e+00, align 4
@nul = global ptr null, align 8
@agg = global { i32, double } { i32 3, double 2.500000e+00 }, align 8
@second = global ptr getelementptr inbounds ([3 x i32], ptr @table, i64 0, i64 1), align 8

define i1 @consts(i64 %x, double %fp_in) {
entry:
  %a = icmp eq i64 %x, -1
  %b = or i1 %a, true
  %c = add i64 %x, ptrtoint (ptr @nul to i64)
  %d = fadd double %fp_in, 1.000000e+00
  %e = select i1 %b, i64 %c, i64 undef
  ret i1 %b
}
