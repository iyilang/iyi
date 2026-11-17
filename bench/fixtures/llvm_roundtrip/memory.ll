; ModuleID = 'memory'
source_filename = "memory"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-apple-darwin"

%pair = type { i32, [4 x i8] }

@counter = global i64 0, align 8
@table = internal constant [3 x i32] [i32 1, i32 2, i32 3], align 4
@msg = private unnamed_addr constant [6 x i8] c"hello\00", align 1
@pairs = global %pair zeroinitializer, align 8

define i64 @bump(ptr %p) {
entry:
  %old = load volatile i64, ptr %p, align 8
  %new = add i64 %old, 1
  store i64 %new, ptr %p, align 8
  %slot = alloca %pair, align 8
  %f = getelementptr inbounds %pair, ptr %slot, i32 0, i32 0
  store i32 5, ptr %f, align 4
  %x = load i32, ptr %f, align 4
  %ext = zext i32 %x to i64
  %sum = add i64 %new, %ext
  ret i64 %sum
}

define i32 @atomics(ptr %p) {
entry:
  fence seq_cst
  %r = atomicrmw add ptr %p, i32 1 seq_cst
  %cx = cmpxchg ptr %p, i32 %r, i32 9 acq_rel monotonic
  %v = extractvalue { i32, i1 } %cx, 0
  ret i32 %v
}

define ptr @string_ptr() {
entry:
  ret ptr @msg
}
