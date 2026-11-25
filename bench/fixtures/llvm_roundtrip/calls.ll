; ModuleID = 'calls'
source_filename = "calls"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-apple-darwin"

declare i32 @external(i32)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
declare { i32, i1 } @llvm.sadd.with.overflow.i32(i32, i32)

define i32 @caller(ptr %dst, ptr %src, i32 %a) #0 {
entry:
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr %src, i64 16, i1 false)
  %ov = call { i32, i1 } @llvm.sadd.with.overflow.i32(i32 %a, i32 1)
  %v = extractvalue { i32, i1 } %ov, 0
  %r = tail call i32 @external(i32 %v)
  ret i32 %r
}

attributes #0 = { "frame-pointer"="all" }
