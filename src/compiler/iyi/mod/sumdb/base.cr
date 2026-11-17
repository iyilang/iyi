require "base64"
require "crystal/digest/sha256"

module Iyi
  module Mod
    module SumDB
      class Error < Exception
      end

      # C2SP requires canonical RFC 4648 base64 including padding.
      def self.decode_base64(value : String) : Bytes
        decoded = Base64.decode(value)
        raise Error.new("sumdb: non-canonical base64") unless Base64.strict_encode(decoded) == value
        decoded
      rescue ex : ArgumentError
        raise Error.new("sumdb: invalid base64")
      end
    end
  end
end
