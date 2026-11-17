; ModuleID = 'probe_switch'
source_filename = "probe_switch"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-apple-darwin"

define i32 @pick(i32 %x) {
entry:
  switch i32 %x, label %default [
    i32 0, label %zero
    i32 7, label %seven
  ]

zero:
  ret i32 10

seven:
  ret i32 20

default:
  ret i32 1
}
