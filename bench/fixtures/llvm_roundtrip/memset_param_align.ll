; ModuleID = 'memset_param_align'
source_filename = "memset_param_align"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-apple-darwin"

declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)

define void @zero(ptr %p) {
entry:
  call void @llvm.memset.p0.i64(ptr align 4 %p, i8 0, i64 8, i1 false)
  ret void
}
