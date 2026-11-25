; ModuleID = 'int192'
source_filename = "int192"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-apple-darwin"

define i192 @id(i192 %x) {
entry:
  ret i192 %x
}
