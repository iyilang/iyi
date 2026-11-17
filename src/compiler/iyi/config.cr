require "./codegen/target"
{% if flag?(:darwin) %}
  require "json"

  lib LibC
    fun sysctlbyname(name : UInt8*, old : Void*, old_size : UInt64*, new : Void*, new_size : UInt64) : Int32
  end
{% end %}

module Iyi
  module Config
    class_property path : String = {{env("IYI_CONFIG_PATH") || ""}}

    # Crystal's own specs, and anyone invoking the compatibility binary, set
    # `CRYSTAL_PATH`, `CRYSTAL_CACHE_DIR`, `CRYSTAL_LIBRARY_PATH`, `CRYSTAL_OPTS`,
    # `CRYSTAL_EXEC_PATH`, `CRYSTAL_DAEMON`, `CRYSTAL_DAEMON_SOCKET`. The
    # compiler's own names are `IYI_*`. Both have to work, because this is still
    # Crystal's compiler when the binary is called `crystal`. `IYI_*` wins when
    # both are set.
    def self.env(name : String) : String?
      ENV["IYI_#{name}"]? || ENV["CRYSTAL_#{name}"]?
    end

    def self.version
      {{ read_file("#{__DIR__}/../../VERSION").chomp }}
    end

    # iyi: the fork's own version, which is not Crystal's.
    #
    # A file rather than an environment variable because two binaries in this
    # repository write `.iyimod` artifacts and IV.5 makes the version an
    # equality test between them. `crystal` built without the variable and
    # `iyi` built with it would disagree about what they are, and the disagreement
    # would show up as an artifact one of them refuses to read.
    def self.iyi_version
      {{ read_file("#{__DIR__}/../../IYI_VERSION").chomp }}
    end

    def self.description
      String.build do |io|
        io << "Crystal " << version
        io << " [" << build_commit << "]" if build_commit
        io << " (" << date << ")" unless date.empty?

        io << "\n\nThe compiler was not built in release mode." unless release_mode?

        io << "\n\nLLVM: " << LLVM.version
        io << "\nDefault target: " << host_target
        io << "\n"
      end
    end

    def self.build_commit
      sha = {{ env("IYI_CONFIG_BUILD_COMMIT") || "" }}
      sha = nil if sha.empty?

      sha
    end

    def self.build_inputs : String?
      sha = {{ env("IYI_CONFIG_BUILD_INPUTS") || "" }}
      sha.empty? ? nil : sha
    end

    def self.date
      source_date_epoch = {{ (t = env("SOURCE_DATE_EPOCH")) && !t.empty? ? t.to_i : nil }}
      if source_date_epoch
        Time.unix(source_date_epoch).to_s("%Y-%m-%d")
      else
        ""
      end
    end

    def self.release_mode?
      {{ flag?(:release) }}
    end

    def self.exec_path
      if exec = env("EXEC_PATH")
        return exec
      end
      executable_path = Process.executable_path || return
      File.dirname(executable_path)
    end

    @@host_target : Iyi::Codegen::Target?

    def self.host_target : Iyi::Codegen::Target
      @@host_target ||= begin
        target = Iyi::Codegen::Target.new({{env("IYI_CONFIG_TARGET")}} || LLVM.default_target_triple)

        if target.linux?
          # The statically linked linux binary runs as well on linux-gnu as
          # on linux-musl, but the default target needs to match the C
          # library used on the current system.
          # This can be automatically detected from the output of `ldd --version`
          # in order to use the appropriate environment target.
          default_libc = target.gnu? ? "-gnu" : "-musl"

          target = Iyi::Codegen::Target.new(target.to_s.sub(default_libc, "-#{linux_runtime_libc}"))
        end

        if target.macos?
          # LLVM derives the target macOS version from the host kernel version
          # in `LLVM.default_target_triple`, and that can run ahead of the OS
          # (e.g. darwin27.0.0 yields macosx28.0 on macOS 27.0.1 with SDK 27.0).
          # When an object file's deployment target is higher than the linker's
          # target, each object file being linked produces a linker warning:
          #
          # > ld: warning: object file (...o0.o) was built for newer 'macOS' version (28.0) than being linked (27.0)
          #
          # Clang's linker driver resolves the deployment target by taking
          # `MACOSX_DEPLOYMENT_TARGET` first, then the SDK version capped at the
          # system version. We take both steps: an explicit environment variable
          # override first, else the component-wise minimum of the resolved macOS
          # SDK version and OS product version. If neither is available, LLVM's
          # default triple is kept.
          if min_version = ENV["MACOSX_DEPLOYMENT_TARGET"]?
            triple = "#{target.architecture}-#{target.vendor}-macosx#{min_version}"
            target = Iyi::Codegen::Target.new(triple)
          else
            {% if flag?(:darwin) %}
              if v = macos_link_version(macos_sdk_version(darwin_sdk), macos_os_version)
                triple = "#{target.architecture}-#{target.vendor}-macosx#{v}"
                target = Iyi::Codegen::Target.new(triple)
              end
            {% end %}
          end
        end

        target
      end
    end

    def self.linux_runtime_libc
      ldd_version = String.build do |io|
        Process.run("ldd", {"--version"}, output: io, error: io)
      rescue
        # In case of an error (eg. `ldd` not available), we assume it's gnu.
        return "gnu"
      end

      # Generally, `ldd --version` should print `musl`.
      # But there is a bug in alpine 3.10 which breaks `ldd --version`.
      # But detection still works with `-musl`, and it doesn't do harm in other
      # cases.
      if ldd_version.starts_with?("musl") || ldd_version.includes?("-musl")
        "musl"
      else
        "gnu"
      end
    end

    def self.library_path
      {{env("IYI_CONFIG_LIBRARY_PATH") || ""}}
    end

    {% if flag?(:darwin) %}
      # `SDKROOT` when it is set, which is what the driver reads first, and
      # otherwise `xcrun`'s answer. Nil when neither answers, and a library
      # only the SDK has is then one the check says it cannot see.
      def self.darwin_sdk : String?
        if sdk = ENV["SDKROOT"]?.presence
          return sdk
        end
        output = IO::Memory.new
        status = Process.run("xcrun", {"--show-sdk-path"}, output: output, error: Process::Redirect::Close)
        status.success? ? output.to_s.strip.presence : nil
      rescue IO::Error
        nil
      end

      def self.macos_sdk_version(path : ::Path | String | Nil) : String?
        return nil if path.nil? || path.to_s.empty?
        settings_path = File.join(path.to_s, "SDKSettings.json")
        return nil unless File.file?(settings_path)
        content = File.read(settings_path)
        JSON.parse(content)["Version"]?.try { |v| v.as_s? || v.to_s }
      rescue
        nil
      end

      def self.macos_os_version : String?
        size = 256_u64
        buffer = uninitialized UInt8[256]
        if LibC.sysctlbyname("kern.osproductversion".to_unsafe, buffer.to_unsafe.as(Void*), pointerof(size), Pointer(Void).null, 0_u64) == 0 && size > 1
          raw = String.new(buffer.to_unsafe).strip
          parts = raw.split('.')
          if parts.size >= 2
            "#{parts[0]}.#{parts[1]}"
          elsif parts.size == 1 && !parts[0].empty?
            parts[0]
          else
            nil
          end
        else
          nil
        end
      rescue
        nil
      end
    {% end %}

    def self.macos_link_version(sdk : String?, os : String?) : String?
      if sdk.nil? && os.nil?
        return nil
      elsif os.nil?
        v = parse_version(sdk)
        return v ? "#{v[0]}.#{v[1]}" : nil
      elsif sdk.nil?
        v = parse_version(os)
        return v ? "#{v[0]}.#{v[1]}" : nil
      end

      v_sdk = parse_version(sdk)
      v_os = parse_version(os)

      if v_sdk && v_os
        min = v_sdk < v_os ? v_sdk : v_os
        "#{min[0]}.#{min[1]}"
      elsif v_sdk
        "#{v_sdk[0]}.#{v_sdk[1]}"
      elsif v_os
        "#{v_os[0]}.#{v_os[1]}"
      else
        nil
      end
    end

    private def self.parse_version(str : String?) : Tuple(Int32, Int32)?
      return nil unless str
      parts = str.split('.')
      return nil if parts.empty?

      major = parts[0].to_i?
      return nil unless major

      minor = 0
      if parts.size > 1
        m = parts[1].to_i?
        return nil unless m
        minor = m
      end

      {major, minor}
    end
  end
end
