# iyi: the buffer name `Program#cached_macro_run` runs the EIY helper with,
# and putting a render's own name back where it stands.
#
# `Eiy.render` names its buffer with a fresh macro variable (`%buf`, which
# expands to `__temp_N`), so no two renders pass `std/eiy/process.iyi` the
# same arguments, and a cache keyed on them never answers one: the generated
# app #143 was measured on rendered 240 times and ran the helper 240 times.
# The helper prints that name and nothing else of it, so it is run with
# `PLACEHOLDER` instead, its output is kept under that, and each render gets
# the output with its own buffer's name put where the placeholder stands.
#
# On its own, with no compiler around it, so `bench/std_eiy_exercise.sh` can
# build it with `iyi build --crystal`, prove it, and prove that a copy which
# skips the substitution is caught.
module Iyi::EiyIO
  # An identifier no program writes, so where it stands in the helper's
  # output it is the buffer and nothing else.
  PLACEHOLDER = "__iyi_eiy_io_7f3a__"

  # *text* with every `PLACEHOLDER` replaced by *io_name*, or nil when one of
  # them is part of a longer word, which is not a name the helper printed.
  # Scanned by hand, not with a `Regex`: one would link the compiler against
  # libpcre2, which the Ubuntu 20.04 image the tarball is built on does not
  # carry (integration/next, job 120807406014).
  def self.substitute(text : String, io_name : String) : String?
    String.build do |io|
      from = 0
      while at = text.index(PLACEHOLDER, from)
        after = at + PLACEHOLDER.bytesize
        return nil if at > 0 && word_byte?(text.byte_at(at - 1))
        return nil if after < text.bytesize && word_byte?(text.byte_at(after))
        io.write text.to_slice[from, at - from]
        io << io_name
        from = after
      end
      io.write text.to_slice[from, text.bytesize - from]
    end
  end

  private def self.word_byte?(byte : UInt8) : Bool
    byte.unsafe_chr.ascii_alphanumeric? || byte == '_'.ord
  end

  # Whether *text* has the placeholder in it anywhere: a template or an
  # argument that does could put it in the output as something other than
  # the buffer, so that render is run with its real name.
  def self.in?(text : String) : Bool
    text.includes?(PLACEHOLDER)
  end
end
