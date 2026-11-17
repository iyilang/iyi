; ModuleID = 'main_module'
source_filename = "main_module"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-apple-darwin27.0.0"
define void @main(ptr %p, [2 x i64] %v) {
entry:
  call void %p([2 x i64] %v)
  ret void
}
