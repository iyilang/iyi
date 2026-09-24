# iyi: `iyi mod reach` - what every package this project builds touches
# outside the language, one line each (SPEC.md III.7, `Mod::Reach`).
#
#     example.com/someone/web v0.1.0: std/socket, std/time; File
#     example.com/someone/zip v1.2.0: links z; C LibZ.deflate, LibZ.inflate
#
# The same selection a build makes, read from the checkouts it builds -
# a replaced module from its directory - so the answer is about this
# program and not about the latest of anything.
require "../mod/installer"
require "../mod/reach"

class Iyi::Command
  private def mod_reach
    while option = options.shift?
      case option
      when "--help", "-h"
        puts mod_reach_usage
        exit
      else
        abort! "mod reach: unexpected '#{option}'; it reads the iyi.mod in this directory", :USAGE_ERROR
      end
    end

    dir = Dir.current
    manifest_path = File.join(dir, Mod::Installer::MANIFEST)
    unless File.file?(manifest_path)
      abort! "mod reach: there is no iyi.mod in #{Iyi.relative_filename(dir)}; " \
             "`#{Command.program_name} init MODULE` writes one", :USAGE_ERROR
    end

    begin
      root = Mod::ModFile.parse(File.read(manifest_path), manifest_path)
      resolved = Mod::Installer.resolve(dir, root)
    rescue ex : Mod::ModError
      abort! "mod reach: #{ex.message}", :USAGE_ERROR
    end
    if resolved.empty?
      puts "#{root.path} requires nothing"
      return
    end
    resolved.each do |(selection, checkout)|
      puts "#{selection}: #{Mod::Reach.of(checkout)}"
    end
  end

  private def mod_reach_usage
    <<-USAGE
    Usage: #{Command.program_name} mod reach

    Say, for every module this project's build selects, what its source
    touches outside the language: the std modules it imports, File from
    the prelude, the C libraries it links and the C functions it declares.
    Tests are not counted; a consumer never builds them.

    `#{Command.program_name} get` says the same of every module it adds,
    and of every module it moves whose reach moved with it.
    USAGE
  end
end
