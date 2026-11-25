; ModuleID = 'control'
source_filename = "control"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-apple-darwin"

define i32 @pick(i32 %x, i1 %flag) {
entry:
  switch i32 %x, label %default [
    i32 0, label %zero
    i32 7, label %seven
  ]

zero:
  br label %join

seven:
  br label %join

default:
  %sel = select i1 %flag, i32 %x, i32 1
  br label %join

join:
  %r = phi i32 [ 10, %zero ], [ 20, %seven ], [ %sel, %default ]
  ret i32 %r
}

define i32 @loop(i32 %n) {
entry:
  br label %head

head:
  %i = phi i32 [ 0, %entry ], [ %next, %body ]
  %acc = phi i32 [ 0, %entry ], [ %acc2, %body ]
  %done = icmp sge i32 %i, %n
  br i1 %done, label %exit, label %body

body:
  %acc2 = add i32 %acc, %i
  %next = add nuw nsw i32 %i, 1
  br label %head

exit:
  ret i32 %acc
}

define i32 @layout(i32 %a) {
entry:
  br label %dom

use:
  %v = add i32 %d, 1
  ret i32 %v

dom:
  %d = mul i32 %a, 2
  br label %use
}

define void @trap_now() {
entry:
  unreachable
}
