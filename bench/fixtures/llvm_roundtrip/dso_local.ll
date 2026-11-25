; ModuleID = 'dso_local'
source_filename = "dso_local"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-apple-darwin"

@dso_g = dso_local global i32 5, align 4
@plain_g = global i32 1, align 4

define dso_local i32 @dso_fn(i32 %x) {
entry:
  %y = add i32 %x, 2
  ret i32 %y
}

define i32 @plain(i32 %x) {
entry:
  %y = call i32 @dso_fn(i32 %x)
  %z = load i32, ptr @dso_g, align 4
  %w = load i32, ptr @plain_g, align 4
  %v = add i32 %y, %z
  %u = add i32 %v, %w
  ret i32 %u
}
