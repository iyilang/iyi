# iyi: `iyi.sum` — III.7 step 2. The spec's split, kept exactly: `iyi.mod`
# is policy, written by a person; `iyi.sum` is fact, written by the tool,
# "and its only job is to notice that what arrived is not what arrived
# last time."
#
# One line per requirement the build actually used:
#
#     example.test/user/liba v1.1.0 s1:9f2a…
#
# The hash is a tree hash of the checkout: every file, sorted by relative
# path, digested as `<relpath>\0<bytes>`; SHA-1, spelled `s1:` so nobody
# mistakes it for a signature — III.7 is explicit that distribution-grade
# integrity is a whole-artifact signature and a published key, and that is
# a later step. Change detection is this file's whole ambition.
#
# The verbs, and who conjugates them: an entry that matches is silence, an
# entry that differs is a refusal naming both hashes, and a requirement
# with no entry is appended — the tool records facts, it does not ask a
# person to transcribe hashes.
require "crystal/digest/sha1"
require "../codegen/cache_dir"

module Iyi::Mod
  module Sum
    FILE = "iyi.sum"

    # Verifies *selections* against the manifest directory's `iyi.sum`,
    # appending what is new. *checkout* answers a selection's directory.
    def self.check(dir : String, selections : Array(Selection), &checkout : Selection -> String) : Nil
      sum_path = File.join(dir, FILE)
      known = File.file?(sum_path) ? parse(File.read(sum_path), sum_path) : {} of String => String
      added = false

      selections.each do |selection|
        key = "#{selection.path} v#{selection.version}"
        actual = tree_hash(checkout.call(selection))
        if expected = known[key]?
          next if expected == actual
          raise ModError.new(
            "#{key} is not what it was: #{sum_path} says #{expected}, " \
            "the checkout hashes to #{actual}. Something between the tag " \
            "and this machine changed; that is the one thing this file " \
            "exists to notice (SPEC.md III.7)")
        end
        known[key] = actual
        added = true
      end

      # A checkout is read-only. A build whose entry sits inside the module
      # cache — a tool compiling a dependency in place — verifies but never
      # writes, or the write would change the very tree a *user's* sum pins,
      # which is the mutation this file exists to notice, self-inflicted.
      return if dir.starts_with?(Iyi::CacheDir.instance.join("mod"))

      return unless added
      File.write(sum_path, String.build do |io|
        known.to_a.sort_by!(&.first).each do |(key, hash)|
          io << key << ' ' << hash << '\n'
        end
      end)
    end

    # The checkout's content, as one line-friendly token: files only,
    # sorted by relative path, each digested with its path so a rename is
    # a change.
    def self.tree_hash(dir : String) : String
      digest = ::Crystal::Digest::SHA1.new
      files = [] of String
      collect_files(dir, "", files)
      files.sort!
      files.each do |relative|
        full = File.join(dir, relative)
        digest.update(relative)
        digest.update("\0")
        # A symbolic link is hashed as the link, which is git's own model:
        # what a repository stores for one is the target *text*, so that is
        # the content, and retargeting it is a change this notices. Reading
        # through it would hash something the package does not contain —
        # and following one that points at its own parent never ends. A
        # package with `inner/loop -> ..` died with the walker's accident:
        # `Too many levels of symbolic links`, about a path forty levels
        # deep, in place of a sentence about the dependency.
        if File.symlink?(full)
          digest.update(File.readlink(full))
        else
          digest.update(File.read(full))
        end
        digest.update("\0")
      end
      "s1:#{digest.final.hexstring}"
    end

    private def self.collect_files(root : String, prefix : String, into : Array(String)) : Nil
      Dir.each_child(File.join(root, prefix)) do |entry|
        relative = prefix.empty? ? entry : File.join(prefix, entry)
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
        unless fields.size == 3 && fields[2].starts_with?("s1:")
          raise ModError.new("#{source}:#{line_number}: not a sum line; the shape is `<path> v<version> s1:<hash>`")
        end
        known["#{fields[0]} #{fields[1]}"] = fields[2]
      end
      known
    end
  end
end
