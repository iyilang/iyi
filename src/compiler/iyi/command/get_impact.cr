# iyi: what a `get` that moved a requirement changed in what this project
# uses (SPEC.md III.7).
#
#     what the move changes in what this project uses:
#       example.com/liba v0.1.0 -> v0.2.0
#         changed  liba: def greeting : String
#              now def greeting(name : String) : String
#           main.iyi:1
#           main.iyi:3
#         gone     liba: def old : Int32 - used nowhere here
#         and 1 new
#
# Reach says what a new version can do; this says what it did to the lines
# a person wrote. The two surfaces are the ones `iyi mod release` compares
# - each version compiled once, from a copy of its checkout - and only for
# a requirement this project's own files import: a module another package
# pulls in is that package's to answer for. A line of the surface gone and
# another of the same name new is a change; a name gone is gone. The sites
# are the lines of the files importing that module that write the name, by
# name and not by type: a local of the same name is listed too, and a
# site is a place to look, not a proof the build breaks.
require "file_utils"

class Iyi::Command
  private def get_impact_lines(dir : String, manifest : Mod::ModFile, previous : Hash(String, SemanticVersion), resolved : Array({Mod::Selection, String})) : Array(String)
    rows = Mod::Installer.short_name_rows(manifest)
    replaced = Mod::Installer.replaced_directories(dir, manifest)
    # Every file of this project, with the module paths it imports.
    imports = {} of String => Array(String)
    mod_tidy_sources(dir).each do |file|
      written = test_imports_of(file) || next
      imports[file] = written.map { |path| Mod::Installer.expand(path, rows) }
    end

    lines = [] of String
    resolved.each do |(selection, checkout)|
      was = previous[selection.path]?
      next if was.nil? || was == selection.version
      # The package's modules this project imports, by in-package name, and
      # the files that import each.
      importers = {} of String => Array(String)
      imports.each do |file, paths|
        paths.each do |path|
          next unless inner = get_impact_inner(selection.path, path)
          (importers[inner] ||= [] of String) << file
        end
      end
      next if importers.empty?

      old_checkout = replaced[selection.path]? || (Mod::Fetcher.checkout(selection.path, was) rescue nil)
      next if old_checkout.nil? || old_checkout == checkout
      header = "#{selection.path} v#{was} -> v#{selection.version}"
      begin
        before, after = get_impact_surfaces(old_checkout, checkout, selection.path, was, selection.version)
      rescue ex : Mod::ModError
        lines << "#{header}: not compared - #{ex.message}"
        next
      end

      body = [] of String
      added_count = 0
      importers.keys.sort.each do |inner|
        old_lines = before[inner]? || [] of String
        new_lines = after[inner]? || [] of String
        gone = old_lines - new_lines
        added = new_lines - old_lines
        gone.each do |line|
          name = get_impact_name(line)
          counterpart = name ? added.find { |candidate| get_impact_name(candidate) == name } : nil
          sites = name ? get_impact_sites(importers[inner], name) : [] of String
          where = sites.empty? ? " - used nowhere here" : ""
          if counterpart
            body << "  changed  #{inner}: #{line}#{where}"
            body << "       now #{counterpart}"
          else
            body << "  gone     #{inner}: #{line}#{where}"
          end
          sites.each { |site| body << "    #{site}" }
        end
        gone_names = gone.compact_map { |line| get_impact_name(line) }.to_set
        added_count += added.count { |line| !(name = get_impact_name(line)) || !gone_names.includes?(name) }
      end
      next if body.empty?
      lines << header
      lines.concat(body)
      lines << "  and #{added_count} new" if added_count > 0
    end
    lines
  end

  # The in-package module *imported* names in the package at *path*, or nil
  # when the import is not the package's.
  private def get_impact_inner(path : String, imported : String) : String?
    if imported == path
      Mod::ModFile.split_major(path)[0].rpartition('/')[2]
    elsif imported.starts_with?("#{path}/")
      imported[(path.size + 1)..]
    end
  end

  # Both versions' surfaces, each from a copy of its checkout: the cache is
  # a cache and the compile writes an entry beside the package.
  private def get_impact_surfaces(old_checkout : String, new_checkout : String, path : String, was : SemanticVersion, now : SemanticVersion) : {Hash(String, Array(String)), Hash(String, Array(String))}
    scratch = File.tempname("iyi-impact", nil)
    Dir.mkdir_p(scratch)
    begin
      surfaces = { {old_checkout, "before", was}, {new_checkout, "after", now} }.map do |(checkout, side, version)|
        copy = File.join(scratch, side)
        FileUtils.cp_r(checkout, copy)
        package_surface(copy, File.join(scratch, "#{side}-build"), "#{path} v#{version}", respell: true)
      end
      {surfaces[0], surfaces[1]}
    ensure
      FileUtils.rm_rf(scratch)
    end
  end

  # The name a surface line gives a consumer to write, or nil for an impl.
  # `def greeting(...)`, `Box.def size`, `struct Outer::Box(T)`,
  # `macro get(...)`.
  private def get_impact_name(line : String) : String?
    return nil if line.starts_with?("impl ")
    text = line
    if (dot = text.index(".def ")) && !text.starts_with?("def ") && !text.starts_with?("abstract ")
      text = text[(dot + 1)..]
    end
    text = text.lchop("abstract ").lchop("private ")
    rest =
      if tail = text.lchop?("def ")
        tail.lchop("self.")
      elsif tail = text.lchop?("macro ")
        tail
      else
        _, space, tail = text.partition(' ')
        return nil if space.empty?
        tail.rpartition("::")[2]
      end
    name = rest.each_char.take_while { |char| char.alphanumeric? || char == '_' || char == '?' || char == '!' }.join
    name.empty? ? nil : name
  end

  # `file:line` for each line of *files* that writes *name* as a word,
  # comments aside.
  private def get_impact_sites(files : Array(String), name : String) : Array(String)
    sites = [] of String
    files.uniq.sort.each do |file|
      File.read(file).each_line.with_index(1) do |text, number|
        next if text.lstrip.starts_with?('#')
        code = text.partition(" #")[0]
        at = 0
        while found = code.index(name, at)
          before = found > 0 ? code[found - 1] : ' '
          after = code[found + name.size]?
          word = !(before.alphanumeric? || before == '_') && !(after && (after.alphanumeric? || after == '_'))
          if word
            sites << "#{Iyi.relative_filename(file)}:#{number}"
            break
          end
          at = found + 1
        end
      end
    end
    sites
  end
end
