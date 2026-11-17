require "./encoding"
require "../build_inputs"

module Iyi::Stale
  module Link
    CHILD_ENV     = BuildInputs::CHILD_ENV
    REFUSED_CHARS = {'`', '$', '*', '?', '[', '~'}

    # Returns a refusal reason if any ldflags or link flag contains a shell character
    # that would fail or expand without a shell (`$*?[~), or nil if safe for stale reuse.
    def self.refusal(lib_flags : String, link_flags : String? = nil) : String?
      REFUSED_CHARS.each do |ch|
        if lib_flags.includes?(ch)
          return "refused link flag: contains '#{ch}'"
        end
        if link_flags && link_flags.includes?(ch)
          return "refused link flag: contains '#{ch}'"
        end
      end
      nil
    end

    # LinkFp = D("link", lib_flags, link_flags, static, CHILD_ENV values)
    def self.fp(
      lib_flags : String,
      link_flags : String?,
      static : Bool,
      child_env = ENV,
    ) : Digest
      Stale.d("link") do |enc|
        enc.str(lib_flags)
        if link_flags
          enc.str(link_flags)
        else
          enc.absent
        end
        enc.bool(static)
        CHILD_ENV.each do |name|
          val = child_env[name]?
          if val
            enc.str(val)
          else
            enc.absent
          end
        end
      end
    end
  end

  def self.link_fp(
    lib_flags : String,
    link_flags : String?,
    static : Bool,
    child_env = ENV,
  ) : Digest
    Link.fp(lib_flags, link_flags, static, child_env)
  end
end
