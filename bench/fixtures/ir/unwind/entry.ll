; ModuleID = 'entry'
source_filename = "entry"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-apple-darwin"

declare i32 @putchar(i32)

declare i32 @__iyi_personality(...)

declare void @__iyi_reraise(ptr)

define internal { i32, i32 } @__crystal_main(i32 %argc, ptr %argv) personality ptr @__iyi_personality {
entry:
  %0 = invoke i32 @putchar(i32 101)
          to label %invoke_out unwind label %rescue

invoke_out:
  br label %exit

rescue:
  %1 = landingpad { ptr, i32 }
          cleanup
  %2 = extractvalue { ptr, i32 } %1, 0
  %3 = call i32 @putchar(i32 100)
  call void @__iyi_reraise(ptr %2)
  unreachable

exit:
  %4 = phi i32 [ 7, %invoke_out ]
  %5 = call i32 @putchar(i32 100)
  %6 = insertvalue { i32, i32 } undef, i32 %4, 0
  %7 = insertvalue { i32, i32 } %6, i32 %5, 1
  ret { i32, i32 } %7
}

define internal i32 @__iyi_main(i32 %argc, ptr %argv) {
entry:
  ret i32 %argc
}

define i32 @main(i32 %argc, ptr %argv) {
entry:
  %0 = call { i32, i32 } @__crystal_main(i32 %argc, ptr %argv)
  %1 = call i32 @__iyi_main(i32 %argc, ptr %argv)
  ret i32 0
}
