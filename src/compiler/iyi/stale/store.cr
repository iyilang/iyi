require "json"
require "file_utils"
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
    getter fast_dir : String
    getter lock_path : String
    getter seq_path : String
    getter key_path : String
    # Imported snapshot files this store has parsed. A lookup served from the
    # index does not count, so this measures how often the files were read.
    getter imported_parses : Int32 = 0

    # Imported snapshot files as this store last read them, by path. The
    # runner checks tests at once and its fibers run on several threads, so
    # the index has a lock of its own. A thread's lock and not a fiber's:
    # a lookup is made inside `lock` too (`revoke`), where nothing may
    # suspend the fiber, and what this guards only reads files.
    @imported = {} of String => ImportedFile
    @imported_lock = Thread::Mutex.new

    def initialize(cache_root : String? = nil)
      @cache_root = cache_root || ENV["IYI_CACHE_DIR"]? || ENV["CRYSTAL_CACHE_DIR"]? || CacheDir.instance.dir
      @root_dir = File.join(@cache_root, "tests-v1")
      @records_dir = File.join(@root_dir, "records")
      @masks_dir = File.join(@root_dir, "masks")
      @markers_dir = File.join(@root_dir, "markers")
      @imported_dir = File.join(@root_dir, "imported")
      @fast_dir = File.join(@root_dir, "fast")
      @lock_path = File.join(@root_dir, "lock")
      @seq_path = File.join(@root_dir, "seq")
      @key_path = File.join(@root_dir, "key")
    end

    def ensure_directories! : Nil
      Dir.mkdir_p(@records_dir) unless Dir.exists?(@records_dir)
      Dir.mkdir_p(@masks_dir) unless Dir.exists?(@masks_dir)
      Dir.mkdir_p(@markers_dir) unless Dir.exists?(@markers_dir)
      Dir.mkdir_p(@imported_dir) unless Dir.exists?(@imported_dir)
      Dir.mkdir_p(@fast_dir) unless Dir.exists?(@fast_dir)
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

    # Advisory exclusive file lock using flock_exclusive.
    #
    # Invariant the parallel runner relies on: nothing inside a lock block
    # suspends the fiber. No channel send or receive, no sleep, no evented IO
    # (a socket, a pipe read as it arrives). The flock is held by the thread,
    # so a fiber that suspends inside the block lets another fiber on the same
    # thread ask for the lock, and that request blocks the thread itself: the
    # holder can never resume and the process deadlocks.
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

    # The directory holding one test's receipts: records/<hex D(test)>/.
    # Lookups for a test read this directory and no other test's.
    def test_dir(test : TestId) : String
      File.join(@records_dir, Stale.hex(Store.d_test_id(test)))
    end

    def record_path(test : TestId, signature : String) : String
      File.join(test_dir(test), "#{signature}.json")
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

    # The fast-path record of a test. Its contents belong to the fast-path
    # writer; the store only locates and forgets it.
    def fast_path(test : TestId) : String
      File.join(@fast_dir, "#{Stale.hex(Store.d_test_id(test))}.json")
    end

    def forget_fast(test : TestId) : Nil
      lock do
        path = fast_path(test)
        File.delete(path) if File.file?(path)
      end
    end

    # Writes the fast-path record of a test, atomically. The runner calls this
    # under the test's scratch lock; a reader sees the old record or the new one.
    def write_fast(test : TestId, content : String) : Nil
      lock do
        Store.atomic_write(fast_path(test), content)
      end
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

        path = record_path(receipt.test, receipt.signature)
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

    # One imported snapshot file as this store last read it. Every record is
    # indexed by test, so a lookup reads its own test's records and not the
    # whole file. A file that does not parse keeps no records, so it is not
    # parsed again until its stamp changes.
    class ImportedFile
      getter stamp : {Int64, Time}
      getter namespace : String
      getter target : String
      # Whether candidates may draw on this file: the same format and version
      # gate an import applies. Revocation reads every file, usable or not.
      getter? usable : Bool
      # Every record of the file, whatever its mode, by test, in file order.
      getter by_test : Hash(TestId, Array(Receipt))

      def initialize(
        @stamp : {Int64, Time},
        @namespace : String,
        @target : String,
        @usable : Bool,
        @by_test : Hash(TestId, Array(Receipt)),
      )
      end

      def self.read(stamp : {Int64, Time}, path : String) : ImportedFile
        by_test = Hash(TestId, Array(Receipt)).new
        begin
          snap = Snapshot.from_json(File.read(path))
          snap.records.each do |rec|
            rec.namespace = snap.namespace
            rec.ensure_signature!
            (by_test[rec.test] ||= [] of Receipt) << rec
          end
          usable = snap.format == "iyi-test-index" && snap.version == FORMAT_VERSION
          new(stamp, snap.namespace, snap.target, usable, by_test)
        rescue
          new(stamp, "", "", false, Hash(TestId, Array(Receipt)).new)
        end
      end
    end

    # The imported snapshot files as they stand now. A file is parsed when its
    # stamp (size and mtime) differs from the one this store last read, and
    # reused otherwise. The stamp is taken before the file is read: a file
    # replaced after the stamp is read as new content under the old stamp, so
    # the next call reads it again. A stamp taken after the read could pair old
    # content with a new stamp and never be re-read.
    #
    # Another process importing mid-run replaces the file by rename, which
    # changes its size or mtime. The next lookup here parses the new content;
    # lookups already made keep the snapshot they read, which is the answer an
    # import from before the run would have given. A replacement with the same
    # size and mtime as the one already read is not seen until the next change.
    # Atomic writes make that rare, not impossible.
    private def imported_files : Array(ImportedFile)
      @imported_lock.synchronize do
        files = [] of ImportedFile
        fresh = {} of String => ImportedFile
        if Dir.exists?(@imported_dir)
          Dir.each_child(@imported_dir) do |fname|
            next unless fname.ends_with?(".json")
            path = File.join(@imported_dir, fname)
            info = File.info?(path)
            next unless info

            stamp = {info.size, info.modification_time}
            file = @imported[path]?
            if file.nil? || file.stamp != stamp
              file = ImportedFile.read(stamp, path)
              @imported_parses += 1
            end
            fresh[path] = file
            files << file
          end
        end
        @imported = fresh
        files
      end
    end

    # Candidates: local passes newest first, then unmasked imported receipts by
    # namespace. With imported: false only the local passes are returned and no
    # imported snapshot is read.
    def candidates(test : TestId, target : String, imported : Bool = true) : Array(Receipt)
      # Persistent contradiction marker causes miss
      return [] of Receipt if has_marker?(test)

      local_passes = [] of Receipt
      dir = test_dir(test)

      if Dir.exists?(dir)
        Dir.each_child(dir) do |fname|
          next unless fname.ends_with?(".json")
          fpath = File.join(dir, fname)
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

      # Sort local passes newest first (seq descending)
      local_passes.sort_by! { |r| -r.seq.to_i64 }

      return local_passes unless imported

      imported_candidates = [] of Receipt
      imported_files.select(&.usable?).sort_by(&.namespace).each do |file|
        next unless file.target == target
        if recs = file.by_test[test]?
          recs.each do |rec|
            next unless rec.pass?
            # Skip masked imported receipts
            next if is_masked?(rec.signature)
            imported_candidates << rec
          end
        end
      end

      local_passes + imported_candidates
    end

    # Blockers: builds of contradicted receipts and masks of test
    def blockers(test : TestId) : Array(Receipt)
      result = [] of Receipt

      # 1. Local contradicted receipts of this test
      dir = test_dir(test)
      if Dir.exists?(dir)
        Dir.each_child(dir) do |fname|
          next unless fname.ends_with?(".json")
          fpath = File.join(dir, fname)
          begin
            content = File.read(fpath)
            receipt = Receipt.from_json(content)
            if receipt.test == test && receipt.contradicted
              result << receipt
            end
          rescue ex
            raise "cannot inspect receipt blocker #{fpath}: #{ex.message}"
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
          rescue ex
            raise "cannot inspect mask #{fpath}: #{ex.message}"
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
        # 1. Local receipts of this test
        dir = test_dir(test)
        if Dir.exists?(dir)
          Dir.each_child(dir) do |fname|
            next unless fname.ends_with?(".json")
            fpath = File.join(dir, fname)
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

        # 2. Imported receipts of this test, whatever their format
        imported_files.each do |file|
          recs = file.by_test[test]?
          next unless recs
          begin
            recs.each do |rec|
              mpath = mask_path(rec.signature)
              next if File.file?(mpath)
              next unless validates_now.call(rec)
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
          rescue
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
        # The file now holds new content, so its next lookup parses it.
        @imported_lock.synchronize { @imported.delete(path) }
        path
      end
    end

    # Prune receipts from outdated toolchains. Two-character directories are the
    # layout before per-test directories: lookups never read them, so they are
    # deleted whole and the next lookup for each test misses once.
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

      Dir.each_child(@records_dir) do |entry|
        dir = File.join(@records_dir, entry)
        next unless Dir.exists?(dir)

        unless test_dir_name?(entry)
          Dir.each_child(dir) do |fname|
            pruned += 1 if fname.ends_with?(".json")
          end
          FileUtils.rm_r(dir) rescue nil
          next
        end

        Dir.each_child(dir) do |fname|
          next unless fname.ends_with?(".json")
          fpath = File.join(dir, fname)
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

        Dir.delete(dir) rescue nil
      end

      pruned
    end

    # A per-test directory is named by a 64-character digest. The
    # two-character directories of the old layout are not.
    private def test_dir_name?(name : String) : Bool
      name.size == 64
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
