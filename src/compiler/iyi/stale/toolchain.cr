require "crystal/digest/sha256"
require "./encoding"
require "../config"
require "json"

module Iyi::Stale
  # Flipped to false when RG1 is green on master CI
  EXECUTABLE_IN_TOOLCHAIN = true

  # Flipped to false when RG7 is green on master CI
  THREADS_IN_BEHAVIOR = true

  module Toolchain
    record StatKey, path : String, dev : UInt64, ino : UInt64, size : Int64, mtime : Int64, ctime : Int64

    # Digest of compiler, LLVM and linker driver metadata, cached via C4 memo.
    def self.digest(cache_root : String, executable_path : String? = nil) : Digest
      compiler_path = resolve_compiler_path(executable_path)
      c_stat = file_stat_key(compiler_path)

      llvm_path, llvm_is_shared = resolve_llvm_lib(compiler_path)
      l_stat = llvm_is_shared ? file_stat_key(llvm_path) : nil

      linker_path = resolve_linker_path
      k_stat = file_stat_key(linker_path)

      memo_key = Stale.d("toolchain_memo") do |enc|
        if c_stat
          encode_stat(enc, c_stat)
        else
          enc.str(compiler_path)
        end

        if l_stat
          encode_stat(enc, l_stat)
        else
          enc.str("static")
        end

        if k_stat
          encode_stat(enc, k_stat)
        else
          enc.str(linker_path)
        end
      end

      memo_dir = File.join(cache_root, "tests-v1", "toolchain")
      memo_file = File.join(memo_dir, "#{Stale.hex(memo_key)}.json")

      if File.file?(memo_file)
        begin
          content = File.read(memo_file)
          if hex_val = extract_json_field(content, "toolchain")
            return Stale.parse_hex(hex_val)
          end
        rescue
          # Corrupt memo; fall through to recompute
        end
      end

      compiler_sha = file_sha256(compiler_path)
      llvm_sha = (llvm_is_shared && File.file?(llvm_path)) ? file_sha256(llvm_path) : nil
      linker_ver = linker_version_first_line(linker_path)
      linker_sha = file_sha256(linker_path)

      toolchain_digest = Stale.d("toolchain") do |enc|
        if bi = Config.build_inputs
          enc.str(bi)
        else
          enc.absent
        end

        enc.str(Config.iyi_version)
        enc.str(Config.description)

        if EXECUTABLE_IN_TOOLCHAIN
          enc.digest(compiler_sha)
        else
          enc.absent
        end

        if llvm_is_shared && llvm_sha
          enc.str(llvm_path)
          enc.digest(llvm_sha)
        else
          enc.str("static")
        end

        enc.str(linker_path)
        enc.str(linker_ver)
        enc.digest(linker_sha)
      end

      write_memo_atomic(memo_dir, memo_file, toolchain_digest, compiler_sha, llvm_path, llvm_sha, linker_path, linker_ver, linker_sha)

      toolchain_digest
    end

    def self.file_sha256(path : String) : Digest
      hasher = Crystal::Digest::SHA256.new
      if File.file?(path)
        File.open(path, "rb") do |f|
          buffer = uninitialized UInt8[65536]
          while (bytes_read = f.read(buffer.to_slice)) > 0
            hasher.update(buffer.to_slice[0, bytes_read])
          end
        end
      end
      res = uninitialized StaticArray(UInt8, 32)
      hasher.final(res.to_slice)
      res
    rescue
      StaticArray(UInt8, 32).new(0_u8)
    end

    private def self.resolve_compiler_path(executable_path : String?) : String
      if executable_path
        return File.realpath(executable_path)
      end
      if p = Process.executable_path
        return File.realpath(p)
      end
      if p = Config.exec_path
        candidate = File.join(p, "iyi")
        return File.realpath(candidate) if File.exists?(candidate)
        candidate_exe = File.join(p, "iyi.exe")
        return File.realpath(candidate_exe) if File.exists?(candidate_exe)
      end
      "iyi"
    end

    private def self.resolve_llvm_lib(compiler_path : String) : {String, Bool}
      {% if flag?(:unix) %}
        begin
          fn = ->LibLLVM.create_context
          if LibC.dladdr(fn.pointer, out info) != 0 && info.dli_fname
            fname = String.new(info.dli_fname)
            if !fname.empty? && File.exists?(fname)
              real = File.realpath(fname)
              if real != compiler_path
                return {real, true}
              end
            end
          end
        rescue
        end
        {"static", false}
      {% elsif flag?(:win32) %}
        {"static", false}
      {% else %}
        {"static", false}
      {% end %}
    end

    private def self.resolve_linker_path : String
      driver = {% if flag?(:win32) && !flag?(:gnu) %}
                 Compiler::MSVC_LINKER
               {% else %}
                 Compiler::DEFAULT_LINKER
               {% end %}
      if path = Process.find_executable(driver)
        return File.realpath(path)
      end
      driver
    end

    private def self.linker_version_first_line(linker_path : String) : String
      io = IO::Memory.new
      status = Process.run(linker_path, ["--version"], output: io, error: io) rescue nil
      if status && status.success?
        io.to_s.lines.first?.try(&.strip) || ""
      else
        ""
      end
    end

    private def self.file_stat_key(path : String) : StatKey?
      return nil unless File.exists?(path)
      {% if flag?(:unix) %}
        if LibC.stat(path, out stat) == 0
          {% if flag?(:darwin) %}
            mtime = stat.st_mtimespec.tv_sec.to_i64
            ctime = stat.st_ctimespec.tv_sec.to_i64
          {% else %}
            mtime = stat.st_mtim.tv_sec.to_i64
            ctime = stat.st_ctim.tv_sec.to_i64
          {% end %}
          StatKey.new(path, stat.st_dev.to_u64, stat.st_ino.to_u64, stat.st_size.to_i64, mtime, ctime)
        else
          nil
        end
      {% elsif flag?(:win32) %}
        if LibC._stat64(path, out stat) == 0
          StatKey.new(path, stat.st_dev.to_u64, stat.st_ino.to_u64, stat.st_size.to_i64, stat.st_mtime.to_i64, stat.st_ctime.to_i64)
        else
          nil
        end
      {% else %}
        info = File.info(path)
        StatKey.new(path, 0_u64, 0_u64, info.size, info.modification_time.to_unix, info.modification_time.to_unix)
      {% end %}
    rescue
      nil
    end

    private def self.encode_stat(enc : Encoder, s : StatKey)
      enc.str(s.path)
      enc.uint(s.dev)
      enc.uint(s.ino)
      enc.int(s.size)
      enc.int(s.mtime)
      enc.int(s.ctime)
    end

    private def self.write_memo_atomic(memo_dir : String, memo_file : String, toolchain_digest : Digest,
                                       compiler_sha : Digest, llvm_path : String, llvm_sha : Digest?,
                                       linker_path : String, linker_ver : String, linker_sha : Digest)
      Dir.mkdir_p(memo_dir)
      tmp_file = "#{memo_file}.tmp.#{Process.pid}.#{Random.rand(100000)}"
      json_str = String.build do |io|
        io << "{\n"
        io << "  \"toolchain\": \"" << Stale.hex(toolchain_digest) << "\",\n"
        io << "  \"compiler_sha256\": \"" << Stale.hex(compiler_sha) << "\",\n"
        io << "  \"llvm_path\": \"" << llvm_path << "\",\n"
        if llvm_sha
          io << "  \"llvm_sha256\": \"" << Stale.hex(llvm_sha) << "\",\n"
        else
          io << "  \"llvm_sha256\": null,\n"
        end
        io << "  \"linker_path\": \"" << linker_path << "\",\n"
        io << "  \"linker_version\": \"" << linker_ver.gsub('"', "\\\"") << "\",\n"
        io << "  \"linker_sha256\": \"" << Stale.hex(linker_sha) << "\"\n"
        io << "}\n"
      end

      File.open(tmp_file, "w") do |f|
        f.write(json_str.to_slice)
        f.flush
        {% if flag?(:unix) %}
          f.fsync
        {% end %}
      end

      File.rename(tmp_file, memo_file)
    rescue
      File.delete(tmp_file) if tmp_file rescue nil
    end

    # The memo is JSON this module wrote. Parsed as JSON rather than matched
    # with a regex: a Regex links pcre2 into the compiler, which
    # bench/dependency_floor.sh forbids.
    private def self.extract_json_field(json : String, field : String) : String?
      JSON.parse(json)[field]?.try(&.as_s?)
    rescue JSON::ParseException
      nil
    end
  end
end
