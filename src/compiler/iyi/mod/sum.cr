# iyi: `iyi.sum` — III.7 step 2. The spec's split, kept exactly: `iyi.mod`
# is policy, written by a person; `iyi.sum` is fact, written by the tool,
# "and its only job is to notice that what arrived is not what arrived
# last time."
#
# One line per selected checkout and per manifest the resolver read:
#
#     example.test/user/liba v1.1.0 h2:9f2a…
#     example.test/user/liba v1.0.0/iyi.mod h2:8d4b…
#
# The hash is a tree hash of the checkout, in two steps so that no byte of
# one file can be read as part of another. Each file is digested on its
# own, SHA-256 of its bytes, and written as one line of a list:
#
#     <hex digest> <kind> <relative path>\n
#
# sorted by path, `f` for a file and `l` for a symbolic link, whose bytes
# are its target text. The token is `h2:` and the SHA-256 of that list, in
# hex. A tree the fetcher made has no `l` in it: it checks out with
# `core.symlinks=false` on every platform (`Fetcher::KEEP_BYTES`), so a
# link in a package arrives as a file holding its target's path, `f`, the
# same on Windows - where git makes that file anyway - as anywhere else,
# and one tag has one hash. `l` is for the tree that holds a real link all
# the same: a checkout in which a link was put where the fetched file
# was, a cache filled by something that is not the fetcher, or a checkout
# a compiler before this one fetched on a platform with links. Such a
# tree does not hash to what a fetch of the same tag hashes to, and that
# is the point of the letter - a link cannot stand in for the file under
# the file's hash. A cached checkout of that last kind is the one honest
# case: its `h2:` is not the one a fresh fetch writes, and it is brought
# into line by fetching it again (`clear_cache`, or its directory under
# the cache's `mod/` deleted). A digest is sixty-four hex digits and a kind is one letter, so the
# only field of a line whose length varies is the last, and a path with a
# line break in it is refused rather than listed: the list reads back one
# way. It is still not a signature — III.7 is explicit that
# distribution-grade integrity is a whole-artifact signature and a
# published key, and that is a later step. Change detection is this file's
# whole ambition.
#
# The verbs, and who conjugates them: an entry that matches is silence, an
# entry that differs is a refusal naming both hashes, and a requirement
# with no entry is appended — the tool records facts, it does not ask a
# person to transcribe hashes.
#
# `s1:` is what this file held before `h2:`: SHA-1 over `<relpath>\0<bytes>\0`
# for every file, with no lengths, so bytes could move from one file into
# its neighbour and the hash stay where it was. A line that says `s1:` is
# not kept, and not dropped unread either: the checkout is hashed the old
# way once more (`legacy_tree_hash`, which exists for this and nothing
# else), a checkout that differs is the refusal it always was, naming both
# `s1:` hashes, and one that matches has its line written again as `h2:`,
# with one line on stderr saying so once it is written. Where the file
# cannot be written and no line of it is new, the build is not failed for
# that: the lines matched, and stderr says they could not be recorded
# again and why. Rewriting it unread would have pinned
# whatever the first build after an upgrade found checked out, moved tag
# or not. Inside the module cache, where nothing is written, such a line
# stays as it is and is compared the same way: a dependency's own
# `iyi.sum` that says `s1:` for what it requires is still a claim about
# that checkout, and a build there refuses one that does not hold.
require "crystal/digest/sha1"
require "crystal/digest/sha256"
require "../codegen/cache_dir"

module Iyi::Mod
  module Sum
    FILE = "iyi.sum"

    # The token's prefix, and the one this file wrote before it.
    PREFIX = "h2:"
    LEGACY = "s1:"

    # A single resolution verifies manifests before the resolver reads their
    # requirements, then checks selected trees. Nothing is written until
    # every check and the caller's policy checks have succeeded.
    def self.checker(dir : String, notices : IO = STDERR) : Checker
      sum_path = File.join(dir, FILE)
      known = File.file?(sum_path) ? parse(File.read(sum_path), sum_path) : {} of String => String
      Checker.new(sum_path, known, in_cache?(dir), notices)
    end

    class Checker
      getter manifests = [] of Selection

      def initialize(@sum_path : String, @known : Hash(String, String), @read_only : Bool, @notices : IO)
        @added = 0
        @restated = 0
      end

      # Hash exactly the bytes that will be parsed, before their requirements
      # can affect the graph. Replacements are local policy, not pinned facts.
      def manifest(selection : Selection, text : String) : Nil
        key = "#{selection.path} v#{selection.version}/iyi.mod"
        actual = Sum.manifest_hash(text)
        if expected = @known[key]?
          raise Sum.changed(key, @sum_path, expected, actual) unless expected == actual
        else
          @known[key] = actual
          @added += 1
        end
        @manifests << selection
      end

      def trees(selections : Array(Selection), &checkout : Selection -> String) : Nil
        selections.each do |selection|
          key = "#{selection.path} v#{selection.version}"
          tree = checkout.call(selection)
          actual = Sum.tree_hash(tree)
          if expected = @known[key]?
            if expected.starts_with?(LEGACY)
              was = Sum.legacy_tree_hash(tree)
              raise Sum.changed(key, @sum_path, expected, was) unless expected == was
              next if @read_only
              @restated += 1
            else
              next if expected == actual
              raise Sum.changed(key, @sum_path, expected, actual)
            end
          else
            @added += 1
          end
          @known[key] = actual
        end
      end

      def pending? : Bool
        !@read_only && (@added > 0 || @restated > 0)
      end

      def write : Nil
        return unless pending?
        said = "#{@sum_path}: #{@restated} #{@restated == 1 ? "entry" : "entries"} said `#{LEGACY}`, a hash " \
               "that could not tell two different trees apart; #{@restated == 1 ? "it" : "each"} matched its checkout"
        begin
          File.write(@sum_path, String.build do |io|
            @known.to_a.sort_by!(&.first).each do |(key, hash)|
              io << key << ' ' << hash << '\n'
            end
          end)
        rescue ex : IO::Error
          # A missing fact must be recorded. An s1 line already matched,
          # so a failed rewrite alone does not prevent the build.
          raise ex if @added > 0
          reason = (ex.os_error.try(&.message) || ex.message || "").rchop('.')
          @notices.puts "#{said} and could not be recorded again as `#{PREFIX}`: the file could not be " \
                        "written (#{reason}). The build goes on under the `#{LEGACY}` " \
                        "#{@restated == 1 ? "line" : "lines"}"
          return
        end
        @notices.puts "#{said} and is recorded again as `#{PREFIX}`" if @restated > 0
      end
    end

    def self.changed(key : String, sum_path : String, expected : String, actual : String) : ModError
      subject = key.ends_with?("/iyi.mod") ? "manifest" : "checkout"
      ModError.new(
        "#{key} is not what it was: #{sum_path} says #{expected}, " \
        "the #{subject} hashes to #{actual}. Something between the tag " \
        "and this machine changed; that is the one thing this file " \
        "exists to notice (SPEC.md III.7)")
    end

    # Drops every entry that is not one of *keep*, the selections a build
    # of the manifest in *dir* now uses, and answers how many went: a sum
    # line for a version nothing builds is a fact about another program.
    def self.prune(dir : String, keep : Array(Selection), manifests : Array(Selection) = [] of Selection) : Int32
      sum_path = File.join(dir, FILE)
      return 0 unless File.file?(sum_path)
      known = parse(File.read(sum_path), sum_path)
      wanted = wanted_keys(keep, manifests)
      kept = known.select { |key, _| wanted.includes?(key) }
      dropped = known.size - kept.size
      return 0 if dropped == 0 || in_cache?(dir)
      File.write(sum_path, String.build do |io|
        kept.to_a.sort_by!(&.first).each do |(key, hash)|
          io << key << ' ' << hash << '\n'
        end
      end)
      dropped
    end

    # Which entries of the sum in *dir* are not one of *keep*, without
    # writing anything.
    def self.stale(dir : String, keep : Array(Selection), manifests : Array(Selection) = [] of Selection) : Array(String)
      sum_path = File.join(dir, FILE)
      return [] of String unless File.file?(sum_path)
      wanted = wanted_keys(keep, manifests)
      parse(File.read(sum_path), sum_path).keys.reject { |key| wanted.includes?(key) }.sort!
    end

    private def self.wanted_keys(keep : Array(Selection), manifests : Array(Selection)) : Set(String)
      wanted = keep.map { |selection| "#{selection.path} v#{selection.version}" }.to_set
      manifests.each { |selection| wanted << "#{selection.path} v#{selection.version}/iyi.mod" }
      wanted
    end

    # Whether *dir* is inside the module cache, asked the way the file
    # system names files (`Iyi.file_key`). A string prefix was case- and
    # separator-sensitive: a check run from the checkout entered as `c:\`,
    # as editors and language clients spell the drive, was not "inside"
    # `C:\...\cache\mod`, so it wrote an `iyi.sum` into the cached package,
    # and every project using that version was refused as tampered with
    # until the cache was cleared. Folding the case was not the whole
    # answer: on a CI runner `IYI_CACHE_DIR` is spelled `C:\Users\RUNNER~1\`
    # the way `mktemp` hands it out, and the checkout's directory is
    # `C:\Users\runneradmin\` the way the shell enters it, so the same write
    # happened with every letter folded. Only the file system knows an 8.3
    # name's long one.
    private def self.in_cache?(dir : String) : Bool
      cache = Iyi.file_key(File.expand_path(Iyi::CacheDir.instance.join("mod")))
      !Iyi.path_under?(Iyi.file_key(File.expand_path(dir)), cache).nil?
    end

    # The manifest hash is the tree-hash list containing only iyi.mod.
    # Use the same bytes the parser reads, not a second read of the file.
    def self.manifest_hash(text : String) : String
      digest = ::Crystal::Digest::SHA256.hexdigest(text)
      "#{PREFIX}#{::Crystal::Digest::SHA256.hexdigest("#{digest} f iyi.mod\n")}"
    end

    # The checkout's content, as one line-friendly token: files only, each
    # digested on its own and listed by relative path, so a rename is a
    # change and so is a byte that moves from one file to the next.
    def self.tree_hash(dir : String) : String
      files = [] of String
      collect_files(dir, "", files)
      files.sort!
      list = ::Crystal::Digest::SHA256.new
      file = ::Crystal::Digest::SHA256.new
      files.each do |relative|
        if relative.includes?('\n')
          raise ModError.new(
            "#{dir} holds a file whose name has a line break in it, #{relative.inspect}. " \
            "#{FILE} lists a checkout one file to a line, so that name cannot be hashed; " \
            "the package has to rename it")
        end
        full = File.join(dir, relative)
        file.reset
        # A symbolic link is hashed as the link, which is git's own model:
        # what a repository stores for one is the target *text*, so that is
        # the content, and retargeting it is a change this notices. (The
        # fetcher leaves none in a checkout; see the top of this file for
        # the trees that have one.) Reading
        # through it would hash something the package does not contain —
        # and following one that points at its own parent never ends. A
        # package with `inner/loop -> ..` died with the walker's accident:
        # `Too many levels of symbolic links`, about a path forty levels
        # deep, in place of a sentence about the dependency. The kind is in
        # the line, so a link is not the file that holds its target's name.
        if File.symlink?(full)
          file.update(File.readlink(full))
          kind = 'l'
        else
          file.file(full)
          kind = 'f'
        end
        list.update("#{file.hexfinal} #{kind} #{relative}\n")
      end
      "#{PREFIX}#{list.hexfinal}"
    end

    # What `s1:` was, byte for byte: SHA-1 over `<relpath>\0<bytes>\0` for
    # every file in path order. Only for holding an `s1:` line to its
    # checkout one last time before the line is written again (`check`);
    # nothing is recorded with it.
    def self.legacy_tree_hash(dir : String) : String
      digest = ::Crystal::Digest::SHA1.new
      files = [] of String
      collect_files(dir, "", files)
      files.sort!
      files.each do |relative|
        full = File.join(dir, relative)
        digest.update(relative)
        digest.update("\0")
        digest.update(File.symlink?(full) ? File.readlink(full) : File.read(full))
        digest.update("\0")
      end
      "#{LEGACY}#{digest.final.hexstring}"
    end

    private def self.collect_files(root : String, prefix : String, into : Array(String)) : Nil
      Dir.each_child(File.join(root, prefix)) do |entry|
        # With `/` on every platform: the path is hashed, and `File.join`
        # spelled it with `\` on Windows, so a package with a directory in
        # it hashed one way there and another everywhere else.
        relative = prefix.empty? ? entry : "#{prefix}/#{entry}"
        full = File.join(root, relative)
        # Asked of the name and not of what it points at: `File.directory?`
        # follows a link, so a directory link was walked *through* — into
        # the package's own parent, or into a cycle. A link is an entry
        # here and its target text is what `tree_hash` digests.
        if File.info(full, follow_symlinks: false).directory?
          collect_files(root, relative, into)
        else
          into << relative
        end
      end
    end

    private def self.parse(text : String, source : String) : Hash(String, String)
      known = {} of String => String
      text.each_line.with_index(1) do |line, line_number|
        stripped = line.strip
        next if stripped.empty?
        fields = stripped.split
        unless fields.size == 3 && (fields[2].starts_with?(PREFIX) || fields[2].starts_with?(LEGACY))
          raise ModError.new("#{source}:#{line_number}: not a sum line; the shape is `<path> v<version>[/iyi.mod] #{PREFIX}<hash>`")
        end
        # The suffix is part of the key, distinct from the checkout line.
        known["#{fields[0]} #{fields[1]}"] = fields[2]
      end
      known
    end
  end
end
