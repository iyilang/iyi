require "json"
require "crystal/digest/md5"
require "../build_inputs"
require "./compiler_env"
require "./win_version"

{% if flag?(:win32) %}
  require "c/fileapi"
  require "c/winbase"
  require "c/handleapi"
  require "c/errhandlingapi"
{% end %}

module Iyi::Stale
  # What a file was when the stale build child looked at it, as the inputs
  # record keeps it: one `stat` (kind, size, modification and change times in
  # nanoseconds, device and inode), and the content's MD5 when the times cannot
  # vouch for it (`BuildInputs.racy?`, taken over the later of the two times).
  #
  # Windows change times are used only on trusted local NTFS volumes.
  module FileStamp

    # Unknown or remote filesystems and older Windows releases cannot vouch
    # for a change while a writer still has the file open.
    def self.trusted_volume?(filesystem : String, remote : Bool, build : Int32, drive_type : UInt32) : Bool
      filesystem == "NTFS" && !remote && build >= 17763 && drive_type == 3_u32
    end

    # A serial is not a locality identity: the same volume may be opened
    # through a local path and an SMB share. Probe every handle.
    def self.volume_trusted?(_serial : UInt64, & : -> {String, Bool, Int32, UInt32}) : Bool
      filesystem, remote, build, drive_type = yield
      trusted_volume?(filesystem, remote, build, drive_type)
    end

    # Only these errors establish that the path cannot currently exist.
    # All other failures must make the recorder refuse reuse.
    def self.windows_open_failure(error : UInt32) : BuildInputs::Stamp
      case error
      when 2_u32, 3_u32, 123_u32 # FILE_NOT_FOUND, PATH_NOT_FOUND, INVALID_NAME
        BuildInputs::ABSENT
      else
        BuildInputs::Stamp.new(BuildInputs::Kind::File, 0_i64, 0_i64)
      end
    end

    {% if flag?(:win32) %}
      private def self.trusted_volume?(handle : LibC::HANDLE, serial : UInt64) : Bool
        volume_trusted?(serial) do
          name = uninitialized UInt16[256]
          ok = LibC.GetVolumeInformationByHandleW(handle, nil, 0, nil, nil, nil, name.to_unsafe, name.size)
          if ok == 0
            {"", true, 0, 0_u32}
          else
            name_slice = name.to_slice
            length = name_slice.index(0_u16) || name_slice.size
            filesystem = String.from_utf16(name_slice[0, length])
            full = uninitialized UInt16[32768]
            root = uninitialized UInt16[32768]
            length = LibC.GetFinalPathNameByHandleW(handle, full.to_unsafe, full.size, 0_u32)
            drive_type = if length > 0 && length < full.size &&
                            LibC.GetVolumePathNameW(full.to_unsafe, root.to_unsafe, root.size) != 0
                           LibC.GetDriveTypeW(root.to_unsafe)
                         else
                           0_u32
                         end
            remote_info = LibC::FILE_REMOTE_PROTOCOL_INFO.new
            remote_info.structureVersion = 2_u16
            remote_info.structureSize = sizeof(LibC::FILE_REMOTE_PROTOCOL_INFO).to_u16
            remote = LibC.GetFileInformationByHandleEx(handle, LibC::FILE_INFO_BY_HANDLE_CLASS::FileRemoteProtocolInfo,
              pointerof(remote_info).as(Void*), sizeof(LibC::FILE_REMOTE_PROTOCOL_INFO)) != 0
            {filesystem, remote, WinVersion.build, drive_type}
          end
        end
      end

      private def self.windows_time(value : Int64) : Int64
        (value - 116444736000000000_i64) * 100_i64
      end

      # A handle opened successfully but whose identity could not be queried
      # is not absent. Force the recorder to refuse reuse.
      private def self.untrusted_stamp : BuildInputs::Stamp
        BuildInputs::Stamp.new(BuildInputs::Kind::File, 0_i64, 0_i64)
      end
    {% end %}

    # The stamp of *path*, from a single stat. A caller takes it before the
    # compiler reads the file, so an edit between the two reaches the compiler
    # and not the record.
    def self.of(path : String, with_digest : Bool = true) : BuildInputs::Stamp
      {% if flag?(:unix) %}
        if LibC.stat(path, out stat) == 0
          {% if flag?(:darwin) %}
            mtime = stat.st_mtimespec.tv_sec.to_i64 * 1_000_000_000_i64 + stat.st_mtimespec.tv_nsec.to_i64
            ctime = stat.st_ctimespec.tv_sec.to_i64 * 1_000_000_000_i64 + stat.st_ctimespec.tv_nsec.to_i64
          {% else %}
            mtime = stat.st_mtim.tv_sec.to_i64 * 1_000_000_000_i64 + stat.st_mtim.tv_nsec.to_i64
            ctime = stat.st_ctim.tv_sec.to_i64 * 1_000_000_000_i64 + stat.st_ctim.tv_nsec.to_i64
          {% end %}
          mode = stat.st_mode.to_u32 & 0o170000_u32
          kind =
            if mode == 0o100000_u32
              BuildInputs::Kind::File
            elsif mode == 0o040000_u32
              BuildInputs::Kind::Directory
            else
              BuildInputs::Kind::Other
            end
          size = kind.file? ? stat.st_size.to_i64 : 0_i64
          digest = nil
          if with_digest && kind.file? && BuildInputs.racy?(Math.max(mtime, ctime), BuildInputs.now)
            digest = fingerprint(path)
          end
          BuildInputs::Stamp.new(kind, size, mtime, digest, ctime, stat.st_dev.to_u64, stat.st_ino.to_u64)
        else
          BuildInputs::ABSENT
        end
      {% elsif flag?(:win32) %}
        handle = LibC.CreateFileW(Crystal::System.to_wstr(path), LibC::FILE_READ_ATTRIBUTES,
          LibC::FILE_SHARE_READ | LibC::FILE_SHARE_WRITE | LibC::FILE_SHARE_DELETE,
          nil, LibC::OPEN_EXISTING, LibC::FILE_FLAG_BACKUP_SEMANTICS, LibC::HANDLE.null)
        return windows_open_failure(LibC.GetLastError) if handle == LibC::INVALID_HANDLE_VALUE
        begin
          return BuildInputs::Stamp.new(BuildInputs::Kind::Other, 0_i64, 0_i64) if LibC.GetFileType(handle) != LibC::FILE_TYPE_DISK
          basic = uninitialized LibC::FILE_BASIC_INFO
          standard = uninitialized LibC::FILE_STANDARD_INFO
          identity = uninitialized LibC::FILE_ID_INFO
          return untrusted_stamp if LibC.GetFileInformationByHandleEx(handle, LibC::FILE_INFO_BY_HANDLE_CLASS::FileBasicInfo, pointerof(basic).as(Void*), sizeof(LibC::FILE_BASIC_INFO)) == 0
          return untrusted_stamp if LibC.GetFileInformationByHandleEx(handle, LibC::FILE_INFO_BY_HANDLE_CLASS::FileStandardInfo, pointerof(standard).as(Void*), sizeof(LibC::FILE_STANDARD_INFO)) == 0
          return untrusted_stamp if LibC.GetFileInformationByHandleEx(handle, LibC::FILE_INFO_BY_HANDLE_CLASS::FileIdInfo, pointerof(identity).as(Void*), sizeof(LibC::FILE_ID_INFO)) == 0
          kind = standard.directory != 0 ? BuildInputs::Kind::Directory : BuildInputs::Kind::File
          mtime = windows_time(basic.lastWriteTime)
          trusted = identity.fileIdHigh == 0 && trusted_volume?(handle, identity.volumeSerialNumber)
          ctime = trusted ? windows_time(basic.changeTime) : 0_i64
          digest = with_digest && kind.file? && BuildInputs.racy?(Math.max(mtime, ctime), BuildInputs.now) ? fingerprint(path) : nil
          BuildInputs::Stamp.new(kind, kind.file? ? standard.endOfFile : 0_i64, mtime, digest,
            ctime, identity.volumeSerialNumber, identity.fileIdLow)
        ensure
          LibC.CloseHandle(handle)
        end
      {% else %}
        BuildInputs.stamp(path)
      {% end %}
    end

    # The MD5 of the content of *path*, read with the recorder paused so the
    # read is not itself an input. Nil when it cannot be read.
    def self.fingerprint(path : String) : String?
      content = BuildInputs.paused { ::File.read(path) }
      Crystal::Digest::MD5.hexdigest(content)
    rescue IO::Error
      nil
    end
  end

  # The inputs record a stale build writes for `--stale-inputs`: what the build
  # read, what it found, and the environment it saw, for the fast path. Written
  # by `Check.run` for a reusable build whose recorder heard every input, and
  # removed by the build verb when something after the check says otherwise.
  module InputsFile
    FORMAT  = "iyi-stale-inputs"
    VERSION = 2

    # The environment names a build reads whether or not its recorder sees
    # them: some before the recorder starts, some in child processes. They are
    # recorded in every record, so a change to any of them is seen.
    def self.forced_env : Array(String)
      (CompilerEnv::LOCATOR_VARS.to_a + BuildInputs::CHILD_ENV + BuildInputs::LINK_ONLY_ENV +
        BuildInputs::CODEGEN_ONLY_ENV +
        %w(CRYSTAL_WORKERS IYI_FORK_PROBE IYI_LIBRARY_PATH CRYSTAL_LIBRARY_PATH IYI_EXEC_PATH CRYSTAL_EXEC_PATH)).uniq
    end

    # Writes the record for *inputs* to *path*, through a temporary file and a
    # rename, so a reader sees the old record or the new one and never half of
    # either.
    def self.write(path : String, inputs : BuildInputs, local_build : String, portable_build : String) : Nil
      BuildInputs.paused do
        observed = inputs.observed_env.dup
        forced_env.each do |name|
          observed[name] = Crystal::System::Env.get(name) unless observed.has_key?(name)
        end

        dir = File.dirname(path)
        Dir.mkdir_p(dir) unless dir.empty? || Dir.exists?(dir)
        tmp = "#{path}.tmp.#{Process.pid}"
        File.open(tmp, "w") do |io|
          JSON.build(io) do |json|
            json.object do
              json.field "format", FORMAT
              json.field "version", VERSION
              json.field "local_build", local_build
              json.field "portable_build", portable_build
              json.field "observed_env" do
                json.object do
                  observed.keys.sort!.each do |name|
                    value = observed[name]
                    json.field name do
                      if value
                        json.string value
                      else
                        json.null
                      end
                    end
                  end
                end
              end
              json.field "env_enumerated", inputs.observed_enumerated?
              json.field "files" do
                json.array do
                  inputs.files.keys.sort!.each do |file|
                    stamp = inputs.files[file]
                    json.array do
                      json.string file
                      json.string stamp.kind.to_s.downcase
                      json.number stamp.size
                      json.number stamp.mtime
                      json.number stamp.ctime
                      json.string stamp.dev.to_s
                      json.string stamp.ino.to_s
                      if digest = stamp.digest
                        json.string digest
                      else
                        json.null
                      end
                    end
                  end
                end
              end
              json.field "listings" do
                json.object do
                  inputs.listings.keys.sort!.each do |dir_path|
                    names = inputs.listings[dir_path]
                    json.field dir_path do
                      if names
                        json.array do
                          names.each { |entry| json.string entry }
                        end
                      else
                        json.null
                      end
                    end
                  end
                end
              end
              json.field "pkg_config" do
                json.array do
                  inputs.pkg_config.each do |module_name, static_link, flags|
                    json.array do
                      json.string module_name
                      json.bool static_link
                      if flags
                        json.string flags
                      else
                        json.null
                      end
                    end
                  end
                end
              end
            end
          end
        end
        File.rename(tmp, path)
      end
    end
  end
end
