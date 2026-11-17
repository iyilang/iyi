; ModuleID = 'flags_attrs'
source_filename = "flags_attrs"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-apple-darwin"

define void @exported() #0 {
entry:
  ret void
}

attributes #0 = { uwtable "wasm-export-name"="exported" }

!llvm.module.flags = !{!0}
!0 = !{i32 2, !"CodeView", i32 1}
