; ModuleID = 'probe_phi'
source_filename = "probe_phi"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-apple-darwin"

define i32 @loop(i32 %n) {
entry:
  br label %head

head:
  %i = phi i32 [ 0, %entry ], [ %next, %body ]
  %done = icmp sge i32 %i, %n
  br i1 %done, label %exit, label %body

body:
  %next = add nuw nsw i32 %i, 1
  br label %head

exit:
  ret i32 %i
}
