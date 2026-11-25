; ModuleID = 'overflow8_16'
source_filename = "overflow8_16"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-apple-darwin"

declare { i8, i1 } @llvm.sadd.with.overflow.i8(i8, i8)
declare { i16, i1 } @llvm.umul.with.overflow.i16(i16, i16)

define i8 @add8(i8 %a, i8 %b) {
entry:
  %r = call { i8, i1 } @llvm.sadd.with.overflow.i8(i8 %a, i8 %b)
  %v = extractvalue { i8, i1 } %r, 0
  %o = extractvalue { i8, i1 } %r, 1
  %s = select i1 %o, i8 127, i8 %v
  ret i8 %s
}

define i16 @mul16(i16 %a, i16 %b) {
entry:
  %r = call { i16, i1 } @llvm.umul.with.overflow.i16(i16 %a, i16 %b)
  %v = extractvalue { i16, i1 } %r, 0
  %o = extractvalue { i16, i1 } %r, 1
  %s = select i1 %o, i16 -1, i16 %v
  ret i16 %s
}
