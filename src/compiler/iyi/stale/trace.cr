require "crystal/digest/sha256"
require "./encoding"
require "./roots"

module Iyi::Stale
  record Observation,
    task : UInt64,
    kind : String,
    root : String,
    path : String,
    answer : Digest do
    def to_json(json : JSON::Builder)
      json.object do
        json.field "task", task
        json.field "kind", kind
        json.field "root", root
        json.field "path", path
        json.field "answer", Iyi::Stale.hex(answer)
      end
    end
  end

  record Taint,
    kind : UInt8,
    site : String

  class TraceResult
    property complete : Bool
    property incomplete_reason : String?
    property status : Int32?
    property observations : Array(Observation)
    property taints : Array(Taint)
    property a3_mismatches : Array(String)

    def initialize(@complete : Bool,
                   @incomplete_reason : String? = nil,
                   @status : Int32? = nil,
                   @observations = [] of Observation,
                   @taints = [] of Taint,
                   @a3_mismatches = [] of String)
    end
  end

  module Trace
    TYPE_FILE   = 0x01_u8
    TYPE_DIR    = 0x02_u8
    TYPE_ENV    = 0x03_u8
    TYPE_ENVALL = 0x04_u8
    TYPE_CWD    = 0x05_u8
    TYPE_HOST   = 0x06_u8
    TYPE_WRITE  = 0x07_u8
    TYPE_TAINT  = 0x08_u8
    TYPE_END    = 0x7F_u8

    # A status is reserved if it represents a shell/OS reserved code or signal kill.
    # Unix shells reserve 126..255 (126 cannot exec, 127 not found, 128+N signal deaths, 130 SIGINT, 137 SIGKILL, etc.)
    # Negative codes are system/abnormal termination statuses.
    def self.reserved_status?(status : Int32) : Bool
      status < 0 || status >= 126
    end

    def self.hash_bytes(bytes : Bytes) : Digest
      hasher = Crystal::Digest::SHA256.new
      hasher.update(bytes)
      res = uninitialized StaticArray(UInt8, 32)
      hasher.final(res.to_slice)
      res
    end

    def self.compute_trace_fp(observations : Array(Observation)) : Digest
      h = Iyi::Stale.d("trace0") { |enc| enc.str("") }
      observations.each do |obs|
        h = Iyi::Stale.d("trace") do |enc|
          enc.digest(h)
          enc.uint(obs.task)
          enc.str(obs.kind)
          enc.str(obs.root)
          enc.str(obs.path)
          enc.digest(obs.answer)
        end
      end
      h
    end

    def self.compute_answer(kind : String, root : String, keyer : Keyer, & : Encoder ->) : Digest
      raw = Iyi::Stale.d(kind) do |enc|
        yield enc
      end
      if keyer.mode == "local" && (root == "abs" || kind.starts_with?("env"))
        keyer.k(raw)
      else
        raw
      end
    end

    def self.parse(io : IO, roots : Roots, keyer : Keyer = Keyer.portable, check_disk_after_exit : Bool = true) : TraceResult
      observations = [] of Observation
      taints = [] of Taint
      a3_mismatches = [] of String
      end_seen = false
      exit_status : Int32? = nil

      written_paths = Set(String).new

      loop do
        len_buf = uninitialized UInt8[4]
        read_count = io.read(len_buf.to_slice)
        if read_count == 0
          break # Clean EOF
        elsif read_count < 4
          return TraceResult.new(complete: false, incomplete_reason: "truncated record")
        end

        payload_len = IO::ByteFormat::LittleEndian.decode(UInt32, len_buf.to_slice)
        if payload_len < 1
          return TraceResult.new(complete: false, incomplete_reason: "truncated record")
        end

        payload = Bytes.new(payload_len.to_i32)
        actual_read = io.read_fully?(payload)
        if actual_read.nil?
          return TraceResult.new(complete: false, incomplete_reason: "truncated record")
        end

        if end_seen
          # Any record after END is a trailing record!
          return TraceResult.new(complete: false, incomplete_reason: "trailing record")
        end

        p_io = IO::Memory.new(payload)
        rec_type = p_io.read_byte
        if rec_type.nil?
          return TraceResult.new(complete: false, incomplete_reason: "truncated record")
        end

        # Handle END record
        if rec_type == TYPE_END
          # END record payload is u8 type | [optional u64 task] | i32 status
          # payload_len is 5 (type + status) or 13 (type + task + status)
          if payload_len == 5
            status_buf = uninitialized UInt8[4]
            if p_io.read_fully?(status_buf.to_slice).nil?
              return TraceResult.new(complete: false, incomplete_reason: "malformed END")
            end
            exit_status = IO::ByteFormat::LittleEndian.decode(Int32, status_buf.to_slice)
          elsif payload_len >= 13
            task = p_io.read_bytes(UInt64, IO::ByteFormat::LittleEndian) rescue nil
            status_buf = uninitialized UInt8[4]
            if task.nil? || p_io.read_fully?(status_buf.to_slice).nil?
              return TraceResult.new(complete: false, incomplete_reason: "malformed END")
            end
            exit_status = IO::ByteFormat::LittleEndian.decode(Int32, status_buf.to_slice)
          else
            return TraceResult.new(complete: false, incomplete_reason: "malformed END")
          end

          if reserved_status?(exit_status)
            return TraceResult.new(complete: false, incomplete_reason: "reserved status: #{exit_status}", status: exit_status)
          end

          end_seen = true
          next
        end

        # For all other records: payload has u64 task | fields
        task = p_io.read_bytes(UInt64, IO::ByteFormat::LittleEndian) rescue nil
        if task.nil?
          return TraceResult.new(complete: false, incomplete_reason: "truncated record")
        end

        case rec_type
        when TYPE_FILE
          # u8 kind(1|2|3) str given str real str cwd u32 open_flags u8 present u8 ftype u64 size i64 mtime_ns
          kind_byte = p_io.read_byte
          given = read_str(p_io)
          real = read_str(p_io)
          cwd = read_str(p_io)
          open_flags = p_io.read_bytes(UInt32, IO::ByteFormat::LittleEndian) rescue nil
          present = p_io.read_byte
          ftype = p_io.read_byte
          size = p_io.read_bytes(UInt64, IO::ByteFormat::LittleEndian) rescue nil
          mtime_ns = p_io.read_bytes(Int64, IO::ByteFormat::LittleEndian) rescue nil

          if kind_byte.nil? || given.nil? || real.nil? || cwd.nil? || open_flags.nil? ||
             present.nil? || ftype.nil? || size.nil? || mtime_ns.nil?
            return TraceResult.new(complete: false, incomplete_reason: "truncated record")
          end

          rp = roots.map(real)
          root = rp.root
          rel_path = rp.path
          # The runtime drops reads under scratch, and reads of paths it already wrote, as internal
          if root == "scratch" || written_paths.includes?(real)
            next
          end

          kind_str = case kind_byte
                     when 1_u8 then "file_read"
                     when 2_u8 then "file_stat"
                     when 3_u8 then "file_exists"
                     else           "file_#{kind_byte}"
                     end

          # Post-exit check and answer computation
          if kind_str == "file_read"
            # Hash file content after exit
            content_hash = StaticArray(UInt8, 32).new(0_u8)
            file_exists_now = File.exists?(real)

            if check_disk_after_exit
              if present != 0
                if !file_exists_now
                  a3_mismatches << "file missing after exit: #{real}"
                else
                  info = File.info?(real)
                  if info && (info.size.to_u64 != size)
                    a3_mismatches << "file size changed during run: #{real} (was #{size}, now #{info.size})"
                  end
                  begin
                    bytes = File.read(real).to_slice
                    content_hash = hash_bytes(bytes)
                  rescue
                    content_hash = hash_bytes(Bytes.empty)
                  end
                end
              elsif file_exists_now
                a3_mismatches << "file created during run: #{real}"
              end
            end

            answer = compute_answer(kind_str, root, keyer) do |enc|
              enc.uint(open_flags.to_u64)
              enc.bool(present != 0)
              enc.uint(ftype.to_u64)
              enc.uint(size)
              if present != 0
                enc.digest(content_hash)
              else
                enc.absent
              end
            end
          elsif kind_str == "file_stat"
            if check_disk_after_exit && present != 0
              info = File.info?(real)
              if info && (info.size.to_u64 != size)
                a3_mismatches << "file size changed during run: #{real} (was #{size}, now #{info.size})"
              end
            end

            answer = compute_answer(kind_str, root, keyer) do |enc|
              enc.bool(present != 0)
              enc.uint(ftype.to_u64)
              enc.uint(size)
              enc.int(mtime_ns)
            end
          else # file_exists
            answer = compute_answer(kind_str, root, keyer) do |enc|
              enc.bool(present != 0)
            end
          end

          observations << Observation.new(task, kind_str, root, rel_path, answer)
        when TYPE_DIR
          # str given str real str cwd u32 n then n str names (returned order)
          given = read_str(p_io)
          real = read_str(p_io)
          cwd = read_str(p_io)
          n = p_io.read_bytes(UInt32, IO::ByteFormat::LittleEndian) rescue nil
          if given.nil? || real.nil? || cwd.nil? || n.nil?
            return TraceResult.new(complete: false, incomplete_reason: "truncated record")
          end

          names = [] of String
          n.times do
            name = read_str(p_io)
            return TraceResult.new(complete: false, incomplete_reason: "truncated record") if name.nil?
            names << name
          end

          rp = roots.map(real)
          root = rp.root
          rel_path = rp.path
          if root == "scratch" || written_paths.includes?(real)
            next
          end

          answer = compute_answer("dir_list", root, keyer) do |enc|
            enc.list(names.size) do |l|
              names.each { |item| l.str(item) }
            end
          end

          observations << Observation.new(task, "dir_list", root, rel_path, answer)
        when TYPE_ENV
          # str name u8 present str value u8 written_first
          name = read_str(p_io)
          present = p_io.read_byte
          value = read_str(p_io)
          written_first = p_io.read_byte

          if name.nil? || present.nil? || value.nil? || written_first.nil?
            return TraceResult.new(complete: false, incomplete_reason: "truncated record")
          end

          answer = compute_answer("env_get", "env", keyer) do |enc|
            enc.str(name)
            enc.bool(present != 0)
            enc.str(value)
            enc.bool(written_first != 0)
          end

          observations << Observation.new(task, "env_get", "env", name, answer)
        when TYPE_ENVALL
          answer = compute_env_all_digest(keyer, scratch: roots.scratch)
          observations << Observation.new(task, "env_all", "env", "*", answer)
        when TYPE_CWD
          real = read_str(p_io)
          return TraceResult.new(complete: false, incomplete_reason: "truncated record") if real.nil?

          rp = roots.map(real)
          root = rp.root
          rel_path = rp.path
          answer = compute_answer("cwd", root, keyer) do |enc|
            enc.str(root)
            enc.str(rel_path)
          end
          observations << Observation.new(task, "cwd", root, rel_path, answer)
        when TYPE_HOST
          val = read_str(p_io)
          return TraceResult.new(complete: false, incomplete_reason: "truncated record") if val.nil?

          answer = compute_answer("host", "host", keyer) do |enc|
            enc.str(val)
          end
          observations << Observation.new(task, "host", "host", "hostname", answer)
        when TYPE_WRITE
          # u8 op str real str target_real u8 inside_scratch
          op = p_io.read_byte
          real = read_str(p_io)
          target_real = read_str(p_io)
          inside_scratch = p_io.read_byte

          if op.nil? || real.nil? || target_real.nil? || inside_scratch.nil?
            return TraceResult.new(complete: false, incomplete_reason: "truncated record")
          end

          written_paths.add(real)
          written_paths.add(target_real) unless target_real.empty?

          # Taints shared-write for a WRITE outside scratch
          if inside_scratch == 0_u8
            taints << Taint.new(48_u8, real)
            rp = roots.map(real)
            root = rp.root
            rel_path = rp.path
            answer = compute_answer("taint", root, keyer) do |enc|
              enc.uint(48_u64)
              enc.str(real)
            end
            observations << Observation.new(task, "taint", root, rel_path, answer)
          end
        when TYPE_TAINT
          # u8 kind str site
          kind = p_io.read_byte
          site = read_str(p_io)
          if kind.nil? || site.nil?
            return TraceResult.new(complete: false, incomplete_reason: "truncated record")
          end

          taints << Taint.new(kind, site)
          answer = compute_answer("taint", "abs", keyer) do |enc|
            enc.uint(kind.to_u64)
            enc.str(site)
          end
          observations << Observation.new(task, "taint", "abs", site, answer)
        else
          return TraceResult.new(complete: false, incomplete_reason: "unknown record type #{rec_type}")
        end
      end

      unless end_seen
        return TraceResult.new(complete: false, incomplete_reason: "missing END")
      end

      TraceResult.new(complete: true,
        status: exit_status,
        observations: observations,
        taints: taints,
        a3_mismatches: a3_mismatches)
    end

    def self.parse_file(path : String, roots : Roots, keyer : Keyer = Keyer.portable, check_disk_after_exit : Bool = true) : TraceResult
      File.open(path, "rb") do |f|
        parse(f, roots, keyer, check_disk_after_exit)
      end
    rescue ex : File::NotFoundError
      TraceResult.new(complete: false, incomplete_reason: "missing trace file: #{ex.message}")
    end

    # Replay observations against current state.
    # Returns the first mismatch string or nil if all match.
    def self.replay(observations : Array(Observation), keyer : Keyer, roots : Roots = Roots.new(Dir.current)) : String?
      observations.each do |obs|
        case obs.kind
        when "file_read"
          target = roots.resolve(obs.root, obs.path)
          exists = File.exists?(target)
          content_hash = StaticArray(UInt8, 32).new(0_u8)
          ftype = 0_u8
          size = 0_u64
          open_flags = 0_u32

          if exists
            info = File.info?(target)
            if info
              size = info.size.to_u64
              ftype = case info.type
                      when .file?      then 1_u8
                      when .directory? then 2_u8
                      when .symlink?   then 3_u8
                      else                  0_u8
                      end
            end
            begin
              content_hash = hash_bytes(File.read(target).to_slice)
            rescue
              content_hash = hash_bytes(Bytes.empty)
            end
          end

          current_ans = compute_answer(obs.kind, obs.root, keyer) do |enc|
            enc.uint(open_flags.to_u64)
            enc.bool(exists)
            enc.uint(ftype.to_u64)
            enc.uint(size)
            if exists
              enc.digest(content_hash)
            else
              enc.absent
            end
          end

          if current_ans != obs.answer
            return "run: #{obs.path} changed"
          end
        when "file_stat"
          target = roots.resolve(obs.root, obs.path)
          exists = File.exists?(target)
          ftype = 0_u8
          size = 0_u64
          mtime_ns = 0_i64

          if exists
            info = File.info?(target)
            if info
              size = info.size.to_u64
              mtime_ns = info.modification_time.to_unix_ns.to_i64
              ftype = case info.type
                      when .file?      then 1_u8
                      when .directory? then 2_u8
                      when .symlink?   then 3_u8
                      else                  0_u8
                      end
            end
          end

          current_ans = compute_answer(obs.kind, obs.root, keyer) do |enc|
            enc.bool(exists)
            enc.uint(ftype.to_u64)
            enc.uint(size)
            enc.int(mtime_ns)
          end

          if current_ans != obs.answer
            return "run: #{obs.path} stat changed"
          end
        when "file_exists"
          target = roots.resolve(obs.root, obs.path)
          exists = File.exists?(target)
          current_ans = compute_answer(obs.kind, obs.root, keyer) do |enc|
            enc.bool(exists)
          end

          if current_ans != obs.answer
            return "run: #{obs.path} existence changed"
          end
        when "dir_list"
          target = roots.resolve(obs.root, obs.path)
          names = Dir.children(target).sort rescue [] of String
          current_ans = compute_answer("dir_list", obs.root, keyer) do |enc|
            enc.list(names.size) do |l|
              names.each { |item| l.str(item) }
            end
          end

          if current_ans != obs.answer
            return "run: #{obs.path} directory listing changed"
          end
        when "env_get"
          curr_val = ENV[obs.path]?
          current_ans = compute_answer("env_get", "env", keyer) do |enc|
            enc.str(obs.path)
            enc.bool(!curr_val.nil?)
            enc.str(curr_val || "")
            enc.bool(false)
          end

          if current_ans != obs.answer
            return "run: env #{obs.path} changed"
          end
        when "env_all"
          current_ans = compute_env_all_digest(keyer, scratch: roots.scratch)
          if current_ans != obs.answer
            return "run: env_all changed"
          end
        when "cwd"
          # A CWD record is the directory the program stood in after a
          # `Dir.cd` or saw from a cwd read: a real path, recorded as
          # (root, path). The runner's own cwd says nothing about it. Replay
          # asks whether that directory still resolves to the same real
          # path: gone, or a symlink retargeted, and the run is not the same.
          target = roots.resolve(obs.root, obs.path)
          real = File.directory?(target) ? (File.realpath(target) rescue nil) : nil
          unless real
            return "run: cwd #{obs.path} is gone"
          end
          rp = roots.map(real)
          current_ans = compute_answer("cwd", rp.root, keyer) do |enc|
            enc.str(rp.root)
            enc.str(rp.path)
          end

          if current_ans != obs.answer
            return "run: cwd #{obs.path} changed"
          end
        when "taint"
          # Taints represent non-reusable operations
          return "run: #{obs.path} tainted"
        end
      end

      nil
    end

    def self.compute_env_all_digest(keyer : Keyer, scratch : String = "") : StaticArray(UInt8, 32)
      entries = [] of {String, String}
      ENV.each do |k, v|
        next if k == "IYI_OBSERVE"
        val = (k == "TMPDIR" || k == "TEMP" || k == "TMP") ? "scratch" : v
        entries << {k, val}
      end
      entries.sort_by! { |k, _| k }
      compute_answer("env_all", "env", keyer) do |enc|
        enc.list(entries.size) do |l|
          entries.each do |k, val|
            l.str(k)
            l.str(val)
          end
        end
      end
    end

    private def self.read_str(io : IO) : String?
      len_buf = uninitialized UInt8[4]
      return nil if io.read_fully?(len_buf.to_slice).nil?
      len = IO::ByteFormat::LittleEndian.decode(UInt32, len_buf.to_slice).to_i32
      return "" if len == 0
      bytes = Bytes.new(len)
      return nil if io.read_fully?(bytes).nil?
      String.new(bytes)
    end
  end
end
