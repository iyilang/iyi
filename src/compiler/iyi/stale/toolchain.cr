require "crystal/digest/sha256"
require "./encoding"
require "../config"
require "json"
require "./inputs_file"

{% if flag?(:win32) %}
  require "c/libloaderapi"
{% end %}

module Iyi::Stale
  # Flipped to false when RG1 is green on master CI
  EXECUTABLE_IN_TOOLCHAIN = true

  # Flipped to false when RG7 is green on master CI
  THREADS_IN_BEHAVIOR = true

  module Toolchain
    record StatKey, path : String, stamp : BuildInputs::Stamp

    class ImageChangedError < Exception
    end

    # A shared MSVC build must identify the loaded DLL, not the executable's
    # import thunk. Only a build explicitly linked static may omit the DLL.
    def self.windows_llvm_identity(compiler_path : String, module_path : String?, static_linked : Bool) : {String, Bool}
      return {"static", false} if static_linked
      unless module_path && File.basename(module_path).downcase == "llvm-c.dll" &&
             module_path.compare(compiler_path, case_insensitive: true) != 0
        raise ImageChangedError.new("loaded LLVM-C.dll cannot be identified")
      end
      {module_path, true}
    end

    # Capture at process startup, before a later pathname replacement can
    # make the running image appear to be the new file.
    @@running_image : {String, BuildInputs::Stamp}? = begin
      if path = Process.executable_path
        stamp = FileStamp.of(path)
        if stamp.kind.file? && stamp.ctime > 0 &&
           (stamp.digest || !BuildInputs.racy?(Math.max(stamp.mtime, stamp.ctime), BuildInputs.now))
          {path, stamp}
        end
      end
    rescue
      nil
    end
    {% if flag?(:win32) && !flag?(:static) %}
      # A DLL replaced after process startup is no longer the image this
      # process has loaded, even if its new pathname can be hashed.
      @@running_llvm : {String, BuildInputs::Stamp}? = begin
        compiler_path = File.realpath(Process.executable_path.not_nil!)
        path, _ = resolve_llvm_lib(compiler_path)
        stamp = FileStamp.of(path)
        if stamp.kind.file? && stamp.ctime > 0 &&
           (stamp.digest || !BuildInputs.racy?(Math.max(stamp.mtime, stamp.ctime), BuildInputs.now))
          {path, stamp}
        end
      rescue
        nil
      end
    {% end %}
    @@image_lock = Mutex.new
    @@image_refusal : String? = nil

    def self.running_image_refusal : String?
      @@image_lock.synchronize do
        return @@image_refusal if @@image_refusal
        image = @@running_image
        unless image
          return @@image_refusal = "running compiler image cannot be identified"
        end
        path, original = image
        current = FileStamp.of(path, with_digest: false)
        same = original.kind.file? && original.ctime > 0 && current.kind.file? &&
               original.size == current.size && original.mtime == current.mtime &&
               original.ctime == current.ctime && original.dev == current.dev && original.ino == current.ino
        if same && (digest = original.digest)
          same = FileStamp.fingerprint(path) == digest
          if same && !BuildInputs.racy?(Math.max(original.mtime, original.ctime), BuildInputs.now)
            @@running_image = {path, original.copy_with(digest: nil)}
          end
        end
        return @@image_refusal = "running compiler image changed" unless same
        {% if flag?(:win32) && !flag?(:static) %}
          llvm_image = @@running_llvm
          unless llvm_image
            return @@image_refusal = "loaded LLVM-C.dll cannot be identified"
          end
          llvm_path, llvm_original = llvm_image
          llvm_current = FileStamp.of(llvm_path, with_digest: false)
          same_llvm = llvm_current.kind.file? && llvm_original.size == llvm_current.size &&
                      llvm_original.mtime == llvm_current.mtime && llvm_original.ctime == llvm_current.ctime &&
                      llvm_original.dev == llvm_current.dev && llvm_original.ino == llvm_current.ino
          if same_llvm && (digest = llvm_original.digest)
            same_llvm = FileStamp.fingerprint(llvm_path) == digest
            if same_llvm && !BuildInputs.racy?(Math.max(llvm_original.mtime, llvm_original.ctime), BuildInputs.now)
              @@running_llvm = {llvm_path, llvm_original.copy_with(digest: nil)}
            end
          end
          return @@image_refusal = "loaded LLVM-C.dll changed" unless same_llvm
        {% end %}
        nil
      end
    rescue
      @@image_refusal = "running compiler image cannot be identified"
    end

    private def self.check_running_image! : Nil
      if reason = running_image_refusal
        raise ImageChangedError.new(reason)
      end
    end

    # Digest of compiler, LLVM and linker driver metadata, cached via C4 memo.
    def self.digest(cache_root : String, executable_path : String? = nil, linker_override : String? = nil) : Digest
      check_running_image! unless executable_path
      compiler_path = resolve_compiler_path(executable_path)
      llvm_path, llvm_is_shared = resolve_llvm_lib(compiler_path)
      linker_path = linker_override ? File.realpath(linker_override) : resolve_linker_path

      # Racy and untrusted stamps cannot key a memo, on any platform.
      memo_dir = File.join(cache_root, "tests-v1", "toolchain")
      memo_file = nil
      c_stat = file_stat_key(compiler_path)
      l_stat = llvm_is_shared ? file_stat_key(llvm_path) : nil
      k_stat = file_stat_key(linker_path)
      if c_stat && k_stat && (!llvm_is_shared || l_stat)
        memo_key = Stale.d("toolchain_memo") do |enc|
          encode_stat(enc, c_stat)
          if l_stat
            encode_stat(enc, l_stat)
          else
            enc.str("static")
          end
          encode_stat(enc, k_stat)
        end
        memo_file = File.join(memo_dir, "#{Stale.hex(memo_key)}.json")
        if File.file?(memo_file)
          begin
            content = File.read(memo_file)
            if hex_val = extract_json_field(content, "toolchain")
              check_running_image! unless executable_path
              return Stale.parse_hex(hex_val)
            end
          rescue ex : ImageChangedError
            raise ex
          rescue
            # Corrupt memo; fall through to recompute.
          end
        end
      end

      compiler_sha = file_sha256(compiler_path)
      llvm_sha = llvm_is_shared ? file_sha256(llvm_path) : nil
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
      check_running_image! unless executable_path

      if memo_file
        write_memo_atomic(memo_dir, memo_file, toolchain_digest, compiler_sha, llvm_path, llvm_sha, linker_path, linker_ver, linker_sha)
      end

      toolchain_digest
    end

    def self.file_sha256(path : String) : Digest
      hasher = Crystal::Digest::SHA256.new
      File.open(path, "rb") do |f|
        buffer = uninitialized UInt8[65536]
        while (bytes_read = f.read(buffer.to_slice)) > 0
          hasher.update(buffer.to_slice[0, bytes_read])
        end
      end
      res = uninitialized StaticArray(UInt8, 32)
      hasher.final(res.to_slice)
      res
    end

    # The files a build is made by, which the fast path stamps: the compiler,
    # the LLVM library when that is a shared library, and the linker driver.
    def self.paths(executable_path : String? = nil) : Array(String)
      compiler_path = resolve_compiler_path(executable_path)
      llvm_path, llvm_is_shared = resolve_llvm_lib(compiler_path)
      paths = [compiler_path]
      paths << llvm_path if llvm_is_shared
      paths << resolve_linker_path
      paths
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
      {% elsif flag?(:win32) && flag?(:static) %}
        windows_llvm_identity(compiler_path, nil, true)
      {% elsif flag?(:win32) %}
        # MSVC's function address can be an import thunk in the EXE. Ask the
        # loader for the DLL by the name used by LibLLVM instead.
        module_handle = LibC.GetModuleHandleW(Crystal::System.to_wstr("LLVM-C.dll"))
        filename = unless module_handle.null?
          Crystal::System.retry_wstr_buffer do |buffer, small_buf|
            len = LibC.GetModuleFileNameW(module_handle, buffer, buffer.size)
            if 0 < len < buffer.size
              break String.from_utf16(buffer[0, len])
            elsif small_buf && len == buffer.size
              next 32767
            else
              break nil
            end
          end
        end
        real = begin
          filename ? File.realpath(filename) : nil
        rescue File::Error
          nil
        end
        windows_llvm_identity(compiler_path, real, false)
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
      stamp = FileStamp.of(path, with_digest: false)
      return nil unless stamp.kind.file? && stamp.ctime > 0
      return nil if BuildInputs.racy?(Math.max(stamp.mtime, stamp.ctime), BuildInputs.now)
      StatKey.new(path, stamp)
    rescue
      nil
    end

    private def self.encode_stat(enc : Encoder, key : StatKey)
      stamp = key.stamp
      enc.str(key.path)
      enc.uint(stamp.dev)
      enc.uint(stamp.ino)
      enc.int(stamp.size)
      enc.int(stamp.mtime)
      enc.int(stamp.ctime)
    end

    private def self.write_memo_atomic(memo_dir : String, memo_file : String, toolchain_digest : Digest,
                                       compiler_sha : Digest, llvm_path : String, llvm_sha : Digest?,
                                       linker_path : String, linker_ver : String, linker_sha : Digest)
      Dir.mkdir_p(memo_dir, 0o700)
      tmp_file = "#{memo_file}.tmp.#{Process.pid}.#{Random.rand(100000)}"
      File.open(tmp_file, "w", perm: 0o600) do |f|
        JSON.build(f) do |json|
          json.object do
            json.field "toolchain", Stale.hex(toolchain_digest)
            json.field "compiler_sha256", Stale.hex(compiler_sha)
            json.field "llvm_path", llvm_path
            json.field "llvm_sha256", llvm_sha.try { |sha| Stale.hex(sha) }
            json.field "linker_path", linker_path
            json.field "linker_version", linker_ver
            json.field "linker_sha256", Stale.hex(linker_sha)
          end
        end
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
