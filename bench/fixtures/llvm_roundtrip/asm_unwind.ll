; ModuleID = 'asm_unwind'
source_filename = "asm_unwind"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-apple-darwin"

define void @u() {
entry:
  call void asm sideeffect unwind "nop", ""()
  ret void
}
