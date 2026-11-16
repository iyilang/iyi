require "./note"

# Proof algorithms and tile paths adapted from golang.org/x/mod/sumdb/tlog.
# Copyright 2019 The Go Authors. See GO_LICENSE.
# RFC 6962 and the Go sumdb height-8 tile layout. This security boundary has
# not had independent review. Tile bytes are untrusted until checked against
# the signed checkpoint, including hashes not needed for a particular proof.
module Iyi::Mod::SumDB::TLog
  HASH_SIZE = 32

  def self.leaf(data : Bytes) : Bytes
    digest = ::Crystal::Digest::SHA256.new
    digest.update(Bytes[0_u8])
    digest.update(data)
    digest.final
  end

  def self.node(left : Bytes, right : Bytes) : Bytes
    raise Error.new("sumdb: invalid tree hash length") unless left.size == HASH_SIZE && right.size == HASH_SIZE
    digest = ::Crystal::Digest::SHA256.new
    digest.update(Bytes[1_u8])
    digest.update(left)
    digest.update(right)
    digest.final
  end

  def self.empty : Bytes
    ::Crystal::Digest::SHA256.digest("")
  end

  # Largest power of two strictly less than n, with no signed overflow.
  def self.split(n : Int64) : Int64
    raise Error.new("sumdb: invalid tree size") if n < 2
    k = 1_i64
    while k <= (n - 1) // 2
      k <<= 1
    end
    k
  end

  def self.check_inclusion(size : Int64, index : Int64, record : Bytes, root : Bytes, proof : Array(Bytes)) : Bool
    return false unless size > 0 && index >= 0 && index < size && root.size == HASH_SIZE
    return false if proof.any? { |h| h.size != HASH_SIZE }
    used = 0
    computed = inclusion_root(0_i64, size, index, leaf(record), proof, pointerof(used))
    !computed.nil? && used == proof.size && computed == root
  end

  private def self.inclusion_root(lo : Int64, hi : Int64, index : Int64, hash : Bytes, proof : Array(Bytes), used : Pointer(Int32)) : Bytes?
    return hash if hi - lo == 1
    k = split(hi - lo)
    if index < lo + k
      inner = inclusion_root(lo, lo + k, index, hash, proof, used)
      return nil unless inner && used.value < proof.size
      sibling = proof[used.value]
      used.value += 1
      node(inner, sibling)
    else
      inner = inclusion_root(lo + k, hi, index, hash, proof, used)
      return nil unless inner && used.value < proof.size
      sibling = proof[used.value]
      used.value += 1
      node(sibling, inner)
    end
  end

  def self.check_consistency(old_size : Int64, old_root : Bytes, new_size : Int64, new_root : Bytes, proof : Array(Bytes)) : Bool
    return false unless old_size >= 0 && new_size >= old_size && old_root.size == HASH_SIZE && new_root.size == HASH_SIZE
    return false if proof.any? { |h| h.size != HASH_SIZE }
    if old_size == 0
      return old_root == empty && proof.empty? && (new_size != 0 || new_root == empty)
    end
    used = 0
    roots = consistency_roots(0_i64, new_size, old_size, old_root, proof, pointerof(used))
    !roots.nil? && used == proof.size && roots[0] == old_root && roots[1] == new_root
  end

  private def self.consistency_roots(lo : Int64, hi : Int64, previous : Int64, old_root : Bytes, proof : Array(Bytes), used : Pointer(Int32)) : {Bytes, Bytes}?
    if previous == hi
      return {old_root, old_root} if lo == 0
      return nil if used.value >= proof.size
      hash = proof[used.value]
      used.value += 1
      return {hash, hash}
    end
    k = split(hi - lo)
    if previous <= lo + k
      pair = consistency_roots(lo, lo + k, previous, old_root, proof, used)
      return nil unless pair && used.value < proof.size
      right = proof[used.value]
      used.value += 1
      {pair[0], node(pair[1], right)}
    else
      pair = consistency_roots(lo + k, hi, previous, old_root, proof, used)
      return nil unless pair && used.value < proof.size
      left = proof[used.value]
      used.value += 1
      {node(left, pair[0]), node(left, pair[1])}
    end
  end

  # The checkpoint size fixes which partial tile may be requested. A fetcher
  # may return the full tile in place of a requested partial tile.
  class Tiles
    private struct Tile
      getter level : Int32, index : Int64, width : Int32

      def initialize(@level : Int32, @index : Int64, @width : Int32)
      end

      def path : String
        n = @index
        pieces = ["%03d" % (n % 1000)]
        while n >= 1000
          n //= 1000
          pieces.unshift("x%03d" % (n % 1000))
        end
        suffix = @width == 256 ? "" : ".p/#{@width}"
        "tile/8/#{@level}/#{pieces.join('/')}#{suffix}"
      end

      def start : Int64
        (@index * 256) << (@level * 8)
      end

      def leaf_width : Int64
        1_i64 << (@level * 8)
      end
    end

    @tiles = {} of Tile => Bytes

    def initialize(@size : Int64, @root : Bytes, &@fetch : String -> Bytes)
      raise Error.new("sumdb: invalid checkpoint tree") unless @size >= 0 && @root.size == HASH_SIZE
      if @size == 0 && @root != TLog.empty
        raise Error.new("sumdb: invalid empty checkpoint root")
      end
    end

    def verify_record(index : Int64, record : Bytes) : Nil
      raise Error.new("sumdb: record index outside checkpoint") unless index >= 0 && index < @size
      @tiles.clear
      proof = [] of Bytes
      record_proof(0_i64, @size, index, proof)
      authenticate_tiles
      unless TLog.check_inclusion(@size, index, record, @root, proof)
        raise Error.new("sumdb: record inclusion proof does not match checkpoint")
      end
    end

    def verify_consistency(old_size : Int64, old_root : Bytes) : Nil
      unless old_size >= 0 && old_size <= @size && old_root.size == HASH_SIZE
        raise Error.new("sumdb: invalid checkpoint consistency input")
      end
      @tiles.clear
      proof = [] of Bytes
      tree_proof(0_i64, @size, old_size, proof) if old_size > 0
      authenticate_tiles
      unless TLog.check_consistency(old_size, old_root, @size, @root, proof)
        raise Error.new("sumdb: forked checkpoint, consistency proof does not match")
      end
    end

    private def record_proof(lo : Int64, hi : Int64, index : Int64, nodes : Array(Bytes)) : Nil
      return if hi - lo == 1
      k = TLog.split(hi - lo)
      if index < lo + k
        record_proof(lo, lo + k, index, nodes)
        nodes << range_hash(lo + k, hi - lo - k)
      else
        record_proof(lo + k, hi, index, nodes)
        nodes << range_hash(lo, k)
      end
    end

    private def tree_proof(lo : Int64, hi : Int64, old_size : Int64, nodes : Array(Bytes)) : Nil
      if old_size == hi
        nodes << range_hash(lo, hi - lo) unless lo == 0
        return
      end
      k = TLog.split(hi - lo)
      if old_size <= lo + k
        tree_proof(lo, lo + k, old_size, nodes)
        nodes << range_hash(lo + k, hi - lo - k)
      else
        tree_proof(lo + k, hi, old_size, nodes)
        nodes << range_hash(lo, k)
      end
    end

    # Fetch a complete aligned subtree from the coarsest available tile.
    private def range_hash(start : Int64, count : Int64) : Bytes
      if count & (count - 1) != 0
        left = TLog.split(count)
        return TLog.node(range_hash(start, left), range_hash(start + left, count - left))
      end
      height = 0
      v = count
      while v > 1
        v >>= 1
        height += 1
      end
      level = height // 8
      shift = level * 8
      hash_index = start >> shift
      tile_index = hash_index // 256
      # Tile width and offsets are bounded by 256 before narrowing to Int32.
      width = Math.min(256_i64, (@size >> shift) - tile_index * 256).to_i
      tile = Tile.new(level, tile_index, width)
      data = tile_data(tile)
      tile_range(data, (hash_index % 256).to_i, (1 << (height % 8)))
    end

    private def tile_data(tile : Tile) : Bytes
      @tiles[tile] ||= begin
        raise Error.new("sumdb: invalid tile width") unless 1 <= tile.width <= 256
        data = @fetch.call(tile.path)
        expected = tile.width * HASH_SIZE
        unless data.size == expected || (tile.width < 256 && data.size == 256 * HASH_SIZE)
          raise Error.new("sumdb: invalid tile length for #{tile.path}")
        end
        data[0, expected].dup
      end
    end

    private def tile_range(data : Bytes, first : Int32, count : Int32) : Bytes
      if count == 1
        return data[first * HASH_SIZE, HASH_SIZE].dup
      end
      left = TLog.split(count.to_i64).to_i
      TLog.node(tile_range(data, first, left), tile_range(data, first + left, count - left))
    end

    # Authenticate every byte of each tile that supplied a proof. Other
    # tiles may supply sibling hashes while this check reconstructs the root;
    # those are never exposed or saved as authenticated data.
    private def authenticate_tiles : Nil
      used = @tiles.keys
      used.each do |tile|
        unless root_covering(0_i64, @size, tile) == @root
          raise Error.new("sumdb: inconsistent tile #{tile.path} for signed checkpoint")
        end
      end
    end

    private def root_covering(start : Int64, count : Int64, target : Tile) : Bytes
      tstart = target.start
      tend = tstart + target.width.to_i64 * target.leaf_width
      finish = start + count
      return range_hash(start, count) if finish <= tstart || start >= tend
      if start >= tstart && finish <= tend && count >= target.leaf_width
        first = ((start - tstart) // target.leaf_width).to_i
        width = (count // target.leaf_width).to_i
        return tile_range(tile_data(target), first, width)
      end
      left = TLog.split(count)
      TLog.node(root_covering(start, left, target), root_covering(start + left, count - left, target))
    end
  end
end
