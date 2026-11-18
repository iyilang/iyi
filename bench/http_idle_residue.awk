# std/http.iyi with the address of each HTTP/1.1 request left on the stack
# right after its handler returns: a call (`HttpIdleResidue.leave`) fills
# 512 words (4 KiB) of its own frame with it, the stack the wait for the
# next request then lays its own frames over. bench/heap_local.sh uses it
# on the tree's std/http, where the loop's zeroing
# (`IyiRoots.clear_dead_stack(WAIT_STACK)`) has to clear those words before
# the connection parks; on its copy of the loop without that zeroing, and
# on one that zeroes only `clear_dead_stack`'s 2 KiB default, where they
# must keep the request alive. 4 KiB reaches past 2 KiB from any frame the
# handler's caller has, and stays inside the 8 KiB the loop clears.
#
# Without it the copy relied on the words some frame of the loop happened
# to leave behind: after the master merge `Conn#fill`'s frame grew from
# 1,592 to 1,880 bytes in a --release build and covered them, and the copy
# passed. The stores end in an `asm` that takes the buffer and clobbers
# memory, so a --release build keeps them.
#
#   awk -f bench/http_idle_residue.awk src/std/http.iyi > COPY/std/http.iyi
/^        response = handler\.call\(req\)$/ && !done {
  print
  print "        HttpIdleResidue.leave(req.object_id)"
  done = 1
  next
}
{ print }
END {
  if (!done) exit 3
  print ""
  print "# bench/http_idle_residue.awk's: *word* in 512 words of this call's frame."
  print "struct HttpIdleResidue"
  print "  @[NoInline]"
  print "  def self.leave(word : UInt64) : Nil"
  print "    words = uninitialized UInt64[512]"
  print "    at = pointerof(words).as(Pointer(UInt64))"
  print "    i = 0"
  print "    while i < 512"
  print "      at[i] = word"
  print "      i = i + 1"
  print "    end"
  print "    asm(\"\" :: \"r\"(at) : \"memory\")"
  print "  end"
  print "end"
}
