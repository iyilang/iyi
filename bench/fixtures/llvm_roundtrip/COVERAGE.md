# LLVM round-trip coverage: committed fixtures and gap reproducers

Linked LLVM: 22.1.8

Written by `bench/native_llvm_roundtrip_exercise.sh` from `iyi-ir coverage` over every fixture and gap reproducer. The gate fails when this file is stale; `COVERAGE_WRITE=1` rewrites it.

```
category	name	count	in_iyi_ir
atomicrmw operation	1	1	yes
attribute	captures	3	yes
attribute	frame-pointer	1	yes
attribute	immarg	2	yes
attribute	kind#0	1	no
attribute	kind#31	7	no
attribute	memory	5	yes
attribute	noalias	2	yes
attribute	nocallback	6	yes
attribute	nocreateundeforpoison	3	yes
attribute	nosync	5	yes
attribute	nounwind	7	yes
attribute	readonly	1	yes
attribute	speculatable	3	yes
attribute	uwtable	1	yes
attribute	wasm-export-name	1	yes
attribute	willreturn	7	yes
attribute	writeonly	2	yes
calling convention	ccc	48	yes
gep source type	true	1	yes
icmp predicate	32	1	yes
icmp predicate	39	2	yes
icmp predicate	40	2	yes
inline asm template	nop	1	yes
intrinsic	llvm.memcpy.p0.p0.i64	1	yes
intrinsic	llvm.memset.p0.i64	1	yes
intrinsic	llvm.sadd.with.overflow.i32	1	yes
intrinsic	llvm.sadd.with.overflow.i8	1	yes
intrinsic	llvm.umul.with.overflow.i16	1	yes
intrinsic	llvm.va_end.p0	1	yes
intrinsic	llvm.va_start.p0	1	yes
linkage	external	50	yes
linkage	internal	2	yes
linkage	private	1	yes
module flag	CodeView	1	yes
opcode	add	16	yes
opcode	alloca	2	yes
opcode	atomicrmw	1	yes
opcode	br	12	yes
opcode	call	13	yes
opcode	cmpxchg	1	yes
opcode	extractvalue	6	yes
opcode	fadd	1	yes
opcode	fence	1	yes
opcode	getelementptr	1	yes
opcode	icmp	5	yes
opcode	load	6	yes
opcode	mul	4	yes
opcode	or	1	yes
opcode	phi	4	yes
opcode	ret	28	yes
opcode	sdiv	1	yes
opcode	select	5	yes
opcode	store	2	yes
opcode	switch	2	yes
opcode	unreachable	1	yes
opcode	va_arg	1	yes
opcode	zext	1	yes
ordering	acquire	1	yes
ordering	notatomic	8	yes
ordering	seq_cst	2	yes
tail call	none	12	yes
tail call	tail	1	yes
tls	not_thread_local	18	yes
triple	aarch64-apple-darwin	17	yes
unnamed_addr	local_unnamed_addr	1	no
unnamed_addr	none	17	yes
value	basic block	43	yes
value	function	35	yes
value	global variable	18	yes
value	inline asm	1	yes
visibility	default	48	yes
visibility	hidden	3	yes
visibility	protected	2	yes
entries_not_in_ir	3
```
