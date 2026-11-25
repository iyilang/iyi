; ModuleID = 'variadic'
source_filename = "variadic"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-apple-darwin"

declare void @llvm.va_start.p0(ptr)
declare void @llvm.va_end.p0(ptr)

define i32 @first(i32 %n, ...) {
entry:
  %ap = alloca ptr, align 8
  call void @llvm.va_start.p0(ptr %ap)
  %v = va_arg ptr %ap, i32
  call void @llvm.va_end.p0(ptr %ap)
  %r = add i32 %v, %n
  ret i32 %r
}
