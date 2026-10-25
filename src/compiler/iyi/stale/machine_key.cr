require "random/secure"
require "../build_inputs"
require "../codegen/cache_dir"

module Iyi::Stale
  module MachineKey
    KEY_SIZE = 32

    def self.load_or_create(cache_root : String) : Bytes
      BuildInputs.paused do
        key_dir = File.join(cache_root, "tests-v1")
        key_path = File.join(key_dir, "key")

        if File.file?(key_path)
          bytes = File.read(key_path).to_slice
          return bytes if bytes.size == KEY_SIZE
        end

        Dir.mkdir_p(key_dir)

        flags = LibC::O_RDWR | LibC::O_CREAT | LibC::O_EXCL
        perm = File::Permissions.new(0o600)
        open_result = Crystal::EventLoop.current.open(key_path, flags, perm, blocking: true)

        case open_result
        when Tuple(Crystal::System::FileDescriptor::Handle, Bool)
          handle, blocking = open_result
          IO::FileDescriptor.set_blocking(handle, blocking)
          io = IO::FileDescriptor.new(handle)
          begin
            {% if flag?(:unix) %}
              File.chmod(key_path, 0o600)
            {% end %}
            key_bytes = Random::Secure.random_bytes(KEY_SIZE)
            io.write(key_bytes)
            io.flush
            key_bytes
          ensure
            io.close
          end
        else
          # File already exists or was created concurrently
          read_bytes = Bytes.empty
          10.times do
            if File.file?(key_path)
              read_bytes = File.read(key_path).to_slice
              break if read_bytes.size == KEY_SIZE
            end
            sleep 10.milliseconds
          end
          if read_bytes.size == KEY_SIZE
            read_bytes
          else
            raise File::Error.new("Corrupt or incomplete stale machine key at #{key_path}", file: key_path)
          end
        end
      end
    end

    def self.load_or_create : Bytes
      load_or_create(CacheDir.instance.dir)
    end
  end
end
