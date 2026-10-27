require "json"
require "./encoding"
require "./receipt"
require "./toolchain"
require "./machine_key"

module Iyi::Stale
  class Store
    getter root_dir : String
    getter cache_root : String
    getter records_dir : String
    getter masks_dir : String
    getter markers_dir : String
    getter imported_dir : String
    getter lock_path : String
    getter seq_path : String
    getter key_path : String

    def initialize(cache_root : String? = nil)
      @cache_root = cache_root || ENV["IYI_CACHE_DIR"]? || ENV["CRYSTAL_CACHE_DIR"]? || CacheDir.instance.dir
      @root_dir = File.join(@cache_root, "tests-v1")
      @records_dir = File.join(@root_dir, "records")
      @masks_dir = File.join(@root_dir, "masks")
      @markers_dir = File.join(@root_dir, "markers")
      @imported_dir = File.join(@root_dir, "imported")
      @lock_path = File.join(@root_dir, "lock")
      @seq_path = File.join(@root_dir, "seq")
      @key_path = File.join(@root_dir, "key")
    end

    def ensure_directories! : Nil
      Dir.mkdir_p(@records_dir) unless Dir.exists?(@records_dir)
      Dir.mkdir_p(@masks_dir) unless Dir.exists?(@masks_dir)
      Dir.mkdir_p(@markers_dir) unless Dir.exists?(@markers_dir)
      Dir.mkdir_p(@imported_dir) unless Dir.exists?(@imported_dir)
    end

    # Atomic write: temp file, fsync, rename. On win32, MoveFileExW with
    # MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH.
    def self.atomic_write(path : String, content : String) : Nil
      dir = File.dirname(path)
      Dir.mkdir_p(dir) unless dir.empty? || Dir.exists?(dir)
      tmp_path = "#{path}.tmp.#{Process.pid}.#{Random::Secure.hex(4)}"

      File.open(tmp_path, "w") do |f|
        f.write(content.to_slice)
        f.flush
        f.fsync
      end

      {% if flag?(:win32) %}
        if LibC.MoveFileExW(
             Crystal::System.to_wstr(tmp_path),
             Crystal::System.to_wstr(path),
             LibC::MOVEFILE_REPLACE_EXISTING | LibC::MOVEFILE_WRITE_THROUGH
           ) == 0
          File.delete(tmp_path) if File.file?(tmp_path) rescue nil
          raise File::Error.from_winerror("Error atomically renaming file", file: tmp_path, other: path)
        end
      {% else %}
        File.rename(tmp_path, path)
      {% end %}
    rescue ex
      if tmp_path && File.file?(tmp_path)
        File.delete(tmp_path) rescue nil
      end
      raise ex
    end

    # Advisory exclusive file lock using flock_exclusive
    def lock(&block)
      Dir.mkdir_p(@root_dir) unless Dir.exists?(@root_dir)
      File.open(@lock_path, "a") do |f|
        f.flock_exclusive do
          yield
        end
      end
    end

    # Advance seq under the lock
    def next_seq : UInt64
      lock do
        advance_seq_under_lock
      end
    end

    def current_seq : UInt64
      if File.file?(@seq_path)
        File.read(@seq_path).strip.to_u64? || 0_u64
      else
        0_u64
      end
    end

    private def advance_seq_under_lock : UInt64
      curr = current_seq
      nxt = curr + 1_u64
      Store.atomic_write(@seq_path, "#{nxt}\n")
      nxt
    end

    def self.d_test_id(test : TestId) : Digest
      Stale.d("test") do |enc|
        enc.str(test.root)
        enc.str(test.path)
      end
    end

    def self.d_namespace(namespace : String) : Digest
      Stale.d("namespace") do |enc|
        enc.str(namespace)
      end
    end

    def record_path(signature : String) : String
      prefix = signature[0..1]
      File.join(@records_dir, prefix, "#{signature}.json")
    end

    def mask_path(signature : String) : String
      File.join(@masks_dir, signature)
    end

    def marker_path(test : TestId) : String
      File.join(@markers_dir, Stale.hex(Store.d_test_id(test)))
    end

    def imported_path(namespace : String) : String
      File.join(@imported_dir, "#{Stale.hex(Store.d_namespace(namespace))}.json")
    end

    def has_marker?(test : TestId) : Bool
      File.file?(marker_path(test))
    end

    def is_masked?(signature : String) : Bool
      File.file?(mask_path(signature))
    end

    def write_marker(test : TestId, reason : String = "contradiction") : Nil
      lock do
        path = marker_path(test)
        content = JSON.build do |j|
          j.object do
            j.field "test" do
              j.object do
                j.field "root", test.root
                j.field "path", test.path
              end
            end
            j.field "reason", reason
            j.field "time", Time.utc.to_unix_ms
          end
        end
        Store.atomic_write(path, content)
      end
    end

    def clear_marker(test : TestId) : Bool
      lock do
        path = marker_path(test)
        if File.file?(path)
          File.delete(path)
          true
        else
          false
        end
      end
    end

    # Record a receipt with read-modify-write keeping contradicted
    def record(receipt : Receipt) : Nil
      lock do
        receipt.ensure_signature!
        receipt.seq = advance_seq_under_lock

        path = record_path(receipt.signature)
        if File.file?(path)
          begin
            existing_content = File.read(path)
            existing = Receipt.from_json(existing_content)
            if existing.contradicted
              receipt.contradicted = true
            end
          rescue ex
            # Corrupt existing record replaced by marker under lock
            replace_corrupt_record_under_lock(path, receipt.test)
            receipt.contradicted = true
          end
        end

        Store.atomic_write(path, receipt.to_json)
      end
    end

    # Candidates: local passes newest first, then unmasked imported receipts by namespace
    def candidates(test : TestId, target : String) : Array(Receipt)
      # Persistent contradiction marker causes miss
      return [] of Receipt if has_marker?(test)

      local_passes = [] of Receipt

      if Dir.exists?(@records_dir)
        Dir.each_child(@records_dir) do |ab|
          ab_dir = File.join(@records_dir, ab)
          next unless Dir.exists?(ab_dir)

          Dir.each_child(ab_dir) do |fname|
            next unless fname.ends_with?(".json")
            fpath = File.join(ab_dir, fname)
            begin
              content = File.read(fpath)
              receipt = Receipt.from_json(content)
              if receipt.test == test && receipt.pass? && !receipt.contradicted
                local_passes << receipt
              end
            rescue ex
              # Corrupt record replaced under lock by marker
              lock do
                replace_corrupt_record_under_lock(fpath, test)
              end
              # If replaced by marker for test, test is now marked -> miss!
              if has_marker?(test)
                return [] of Receipt
              end
            end
          end
        end
      end

      # Sort local passes newest first (seq descending)
      local_passes.sort_by! { |r| -r.seq.to_i64 }

      imported_candidates = [] of Receipt
      if Dir.exists?(@imported_dir)
        # Sort imported snapshots by namespace
        snapshot_files = [] of String
        Dir.each_child(@imported_dir) do |fname|
          snapshot_files << File.join(@imported_dir, fname) if fname.ends_with?(".json")
        end

        snapshots = [] of Snapshot
        snapshot_files.each do |sfile|
          begin
            scontent = File.read(sfile)
            snapshots << Snapshot.from_json(scontent)
          rescue
            # Bad snapshot file ignored or skipped
          end
        end
        snapshots.sort_by!(&.namespace)

        snapshots.each do |snap|
          next unless snap.target == target
          snap.records.each do |rec|
            if rec.test == test && rec.pass?
              rec.ensure_signature!
              # Skip masked imported receipts
              next if is_masked?(rec.signature)
              imported_candidates << rec
            end
          end
        end
      end

      local_passes + imported_candidates
    end

    # Blockers: builds of contradicted receipts and masks of test
    def blockers(test : TestId) : Array(Receipt)
      result = [] of Receipt

      # 1. Local contradicted receipts
      if Dir.exists?(@records_dir)
        Dir.each_child(@records_dir) do |ab|
          ab_dir = File.join(@records_dir, ab)
          next unless Dir.exists?(ab_dir)

          Dir.each_child(ab_dir) do |fname|
            next unless fname.ends_with?(".json")
            fpath = File.join(ab_dir, fname)
            begin
              content = File.read(fpath)
              receipt = Receipt.from_json(content)
              if receipt.test == test && receipt.contradicted
                result << receipt
              end
            rescue
            end
          end
        end
      end

      # 2. Masks of test
      if Dir.exists?(@masks_dir)
        Dir.each_child(@masks_dir) do |fname|
          fpath = File.join(@masks_dir, fname)
          begin
            content = File.read(fpath)
            mask = Mask.from_json(content)
            mask.signature = fname
            if mask.test == test
              result << mask.to_receipt
            end
          rescue
            # Masks are never deleted as corrupt
          end
        end
      end

      result
    end

    # Revoke: marks local receipts contradicted and masks imported ones
    def revoke(test : TestId, &validates_now : Receipt -> Bool) : Tuple(Int32, Int32)
      local_count = 0
      imported_count = 0

      lock do
        # 1. Local receipts
        if Dir.exists?(@records_dir)
          Dir.each_child(@records_dir) do |ab|
            ab_dir = File.join(@records_dir, ab)
            next unless Dir.exists?(ab_dir)

            Dir.each_child(ab_dir) do |fname|
              next unless fname.ends_with?(".json")
              fpath = File.join(ab_dir, fname)
              begin
                content = File.read(fpath)
                receipt = Receipt.from_json(content)
                if receipt.test == test
                  if validates_now.call(receipt)
                    receipt.contradicted = true
                    Store.atomic_write(fpath, receipt.to_json)
                    local_count += 1
                  end
                end
              rescue
              end
            end
          end
        end

        # 2. Imported receipts
        if Dir.exists?(@imported_dir)
          Dir.each_child(@imported_dir) do |fname|
            next unless fname.ends_with?(".json")
            fpath = File.join(@imported_dir, fname)
            begin
              content = File.read(fpath)
              snap = Snapshot.from_json(content)
              snap.records.each do |rec|
                if rec.test == test
                  rec.ensure_signature!
                  mpath = mask_path(rec.signature)
                  unless File.file?(mpath)
                    if validates_now.call(rec)
                      mask = Mask.new(
                        test: rec.test,
                        build: rec.build,
                        profile: rec.profile,
                        trace: rec.trace,
                        signature: rec.signature
                      )
                      Store.atomic_write(mpath, mask.to_json)
                      imported_count += 1
                    end
                  end
                end
              end
            rescue
            end
          end
        end
      end

      {local_count, imported_count}
    end

    # Import snapshot into imported/<hex D(namespace)>.json
    def import_snapshot(snapshot : Snapshot) : String
      lock do
        ensure_directories!
        path = imported_path(snapshot.namespace)
        Store.atomic_write(path, snapshot.to_json)
        path
      end
    end

    # Prune receipts from outdated toolchains
    def prune_outdated_toolchains(current_toolchain : String? = nil) : Int32
      lock do
        prune_outdated_toolchains_under_lock(current_toolchain)
      end
    end

    private def prune_outdated_toolchains_under_lock(current_toolchain : String? = nil) : Int32
      expected = current_toolchain || begin
        Stale.hex(Toolchain.digest(@cache_root)) rescue nil
      end
      return 0 unless expected

      pruned = 0
      return 0 unless Dir.exists?(@records_dir)

      Dir.each_child(@records_dir) do |ab|
        ab_dir = File.join(@records_dir, ab)
        next unless Dir.exists?(ab_dir)

        Dir.each_child(ab_dir) do |fname|
          next unless fname.ends_with?(".json")
          fpath = File.join(ab_dir, fname)
          begin
            content = File.read(fpath)
            receipt = Receipt.from_json(content)
            if receipt.build.toolchain != expected
              File.delete(fpath)
              pruned += 1
            end
          rescue
          end
        end

        Dir.delete(ab_dir) rescue nil
      end

      pruned
    end

    private def replace_corrupt_record_under_lock(file_path : String, test : TestId? = nil) : Nil
      target_test = test || extract_test_from_corrupt_file(file_path)

      if target_test
        mpath = marker_path(target_test)
        content = JSON.build do |j|
          j.object do
            j.field "test" do
              j.object do
                j.field "root", target_test.root
                j.field "path", target_test.path
              end
            end
            j.field "reason", "corrupt_record"
            j.field "file", file_path
            j.field "time", Time.utc.to_unix_ms
          end
        end
        Store.atomic_write(mpath, content)
      end

      File.delete(file_path) if File.file?(file_path)
    end

    private def extract_test_from_corrupt_file(file_path : String) : TestId?
      content = File.read(file_path) rescue return nil
      path = json_string_field(content, "path")
      return nil unless path
      TestId.new(json_string_field(content, "root") || "src", path)
    end

    # The first `"name": "value"` in *content*, read without a Regex (a Regex
    # links pcre2 into the compiler, which the dependency floor forbids) and
    # without a JSON parse, which a corrupt record may not survive.
    private def json_string_field(content : String, name : String) : String?
      key = %("#{name}")
      size = content.bytesize
      from = 0
      while at = content.byte_index(key, from)
        i = skip_blank(content, at + key.bytesize)
        if i < size && content.byte_at(i) == ':'.ord
          i = skip_blank(content, i + 1)
          if i < size && content.byte_at(i) == '"'.ord
            close = content.byte_index('"'.ord.to_u8, i + 1)
            return content.byte_slice(i + 1, close - i - 1) if close && close > i + 1
          end
        end
        from = at + 1
      end
      nil
    end

    private def skip_blank(content : String, i : Int32) : Int32
      while i < content.bytesize && content.byte_at(i).unsafe_chr.ascii_whitespace?
        i += 1
      end
      i
    end
  end
end
