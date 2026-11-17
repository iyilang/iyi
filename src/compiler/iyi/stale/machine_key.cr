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

        # The key is written whole to a file of its own and then linked to
        # its name, which fails when the name exists: of two runs that start
        # together one link wins and both read the winner's key, and no run
        # ever sees a half-written key. A descriptor opened with O_EXCL
        # cannot be adopted on Windows, where its blocking mode is fixed.
        key_bytes = Random::Secure.random_bytes(KEY_SIZE)
        staged = File.tempfile("iyi-machine-key", dir: key_dir) do |io|
          io.write(key_bytes)
        end
        begin
          File.link(staged.path, key_path)
          key_bytes
        rescue File::AlreadyExistsError
          # Created by another run between the check above and the link.
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
        ensure
          File.delete?(staged.path)
        end
      end
    end

    def self.load_or_create : Bytes
      load_or_create(CacheDir.instance.dir)
    end
  end
end
