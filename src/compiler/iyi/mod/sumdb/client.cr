require "./tlog"

# Checkpoint and record framing follow golang.org/x/mod/sumdb/tlog/note.go.
# Copyright 2019 The Go Authors. See GO_LICENSE.
module Iyi::Mod::SumDB
  class Checkpoint
    getter origin : String, size : Int64, root : Bytes, signed_note : String

    private def initialize(@origin : String, @size : Int64, @root : Bytes, @signed_note : String)
    end

    def self.open(note : String, keys : Array(Verifier), origin : String) : Checkpoint
      text = Note.open(note, keys.select { |key| key.name == origin })
      lines = text.lines
      if lines.size < 3 || lines.any?(&.empty?) || lines[0] != origin
        raise Error.new("sumdb: invalid checkpoint origin or text")
      end
      size_text = lines[1]
      unless !size_text.empty? && size_text.each_char.all?(&.ascii_number?) && (size_text == "0" || !size_text.starts_with?('0'))
        raise Error.new("sumdb: invalid checkpoint size")
      end
      size = size_text.to_i64?
      raise Error.new("sumdb: checkpoint size out of range") unless size
      root = SumDB.decode_base64(lines[2])
      raise Error.new("sumdb: invalid checkpoint hash") unless root.size == TLog::HASH_SIZE
      if size == 0 && root != TLog.empty
        raise Error.new("sumdb: invalid empty checkpoint hash")
      end
      new(origin, size, root, note)
    end
  end

  # A record is exactly the archive and manifest lines from III.7.
  class Record
    getter text : String, path : String, version : String, archive_hash : String, manifest_hash : String

    private def initialize(@text : String, @path : String, @version : String, @archive_hash : String, @manifest_hash : String)
    end

    def self.parse(text : String) : Record
      unless text.valid_encoding? && text.ends_with?('\n') && text.each_byte.none? { |b| b < 32 && b != 10 }
        raise Error.new("sumdb: malformed record")
      end
      lines = text.lines
      raise Error.new("sumdb: record must contain two lines") unless lines.size == 2
      archive = lines[0].split(' ')
      manifest = lines[1].split(' ')
      unless archive.size == 3 && manifest.size == 3 && !archive[0].empty? && !archive[0].each_char.any?(&.whitespace?) &&
             archive[1].starts_with?('v') && archive[1].size > 1 && !archive[1].each_char.any?(&.whitespace?) &&
             manifest[0] == archive[0] && manifest[1] == "#{archive[1]}/iyi.mod" &&
             valid_hash?(archive[2]) && valid_hash?(manifest[2])
        raise Error.new("sumdb: malformed record lines")
      end
      new(text, archive[0], archive[1], archive[2], manifest[2])
    end

    private def self.valid_hash?(hash : String) : Bool
      hash.size == 67 && hash.starts_with?("h2:") && hash[3..].each_char.all? { |c| c.ascii_number? || ('a' <= c && c <= 'f') }
    end

    def verify(path : String, version : String, actual : String, manifest : Bool = false) : Nil
      unless @path == path && @version == version
        raise Error.new("sumdb: wrong record for #{path} #{version}, got #{@path} #{@version}")
      end
      expected = manifest ? @manifest_hash : @archive_hash
      unless expected == actual
        raise Error.new("sumdb: wrong record hash for #{path} #{version}: log says #{expected}, computed #{actual}")
      end
    end
  end

  # Durable newest checkpoint, serialized across processes by a separate lock.
  # The cache re-reads and authenticates the stored note under that lock, so a
  # stale process cannot overwrite a newer checkpoint after another process.
  class Cache
    def initialize(@path : String, @keys : Array(Verifier), @origin : String)
    end

    def latest : Checkpoint?
      return nil unless File.file?(@path)
      Checkpoint.open(File.read(@path), @keys, @origin)
    end

    def observe(note : String, &fetch : String -> Bytes) : Checkpoint
      incoming = Checkpoint.open(note, @keys, @origin)
      Dir.mkdir_p(File.dirname(@path))
      File.open("#{@path}.lock", "a") do |lock|
        lock.flock_exclusive do
          old = latest
          if old
            if incoming.size < old.size
              # Lookup responses are immutable and may carry an older
              # checkpoint. Authenticate it against the newest cached tree
              # without ever replacing that tree with the older one.
              tiles = TLog::Tiles.new(old.size, old.root) { |path| fetch.call(path) }
              tiles.verify_consistency(incoming.size, incoming.root)
              return old
            else
              tiles = TLog::Tiles.new(incoming.size, incoming.root) { |path| fetch.call(path) }
              tiles.verify_consistency(old.size, old.root)
              return old if incoming.size == old.size
            end
          end
          staging = "#{@path}.#{Process.pid}.tmp"
          begin
            File.open(staging, "w") do |file|
              file << note
              file.flush
              file.fsync
            end
            File.rename(staging, @path)
          ensure
            File.delete?(staging)
          end
          incoming
        end
      end
    end
  end

  # The Go sumdb lookup envelope is ID, record text, a blank line, and a
  # signed checkpoint. The callback provides tile bytes, never HTTP.
  class Client
    def initialize(@cache : Cache, @keys : Array(Verifier), @origin : String)
    end

    def verify_lookup(response : String, path : String, version : String, actual : String, manifest : Bool = false, &fetch : String -> Bytes) : Record
      first = response.index('\n')
      raise Error.new("sumdb: malformed lookup record ID") unless first
      id_text = response[0, first]
      unless !id_text.empty? && id_text.each_char.all?(&.ascii_number?) && (id_text == "0" || !id_text.starts_with?('0'))
        raise Error.new("sumdb: malformed lookup record ID")
      end
      id = id_text.to_i64?
      raise Error.new("sumdb: lookup record ID out of range") unless id
      remainder = response[(first + 1)..]
      separator = remainder.index("\n\n")
      raise Error.new("sumdb: malformed lookup record") unless separator
      record = Record.parse(remainder[0, separator + 1])
      note = remainder[(separator + 2)..]
      checkpoint = Checkpoint.open(note, @keys, @origin)
      record.verify(path, version, actual, manifest)
      tiles = TLog::Tiles.new(checkpoint.size, checkpoint.root) { |tile| fetch.call(tile) }
      tiles.verify_record(id, record.text.to_slice)
      @cache.observe(note) { |tile| fetch.call(tile) }
      record
    end
  end
end
