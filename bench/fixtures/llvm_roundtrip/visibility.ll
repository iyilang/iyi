; ModuleID = 'visibility'
source_filename = "visibility"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-apple-darwin"

@hidden_g = hidden global i32 7, align 4
@protected_g = protected global i64 9, align 8
@plain_g = global i32 1, align 4

define hidden i32 @hidden_fn(i32 %x) {
entry:
  %y = add i32 %x, 1
  ret i32 %y
}

define protected i32 @protected_fn(i32 %x) {
entry:
  %y = mul i32 %x, 3
  ret i32 %y
}

declare hidden i32 @hidden_decl(i32)

define i32 @use_all(i32 %x) {
entry:
  %a = call i32 @hidden_fn(i32 %x)
  %b = call i32 @protected_fn(i32 %a)
  %c = call i32 @hidden_decl(i32 %b)
  %d = load i32, ptr @hidden_g, align 4
  %e = load i32, ptr @plain_g, align 4
  %f = add i32 %c, %d
  %g = add i32 %f, %e
  ret i32 %g
}
