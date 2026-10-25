require "json"

module Iyi::Stale
  module KeyFile
    def self.write_out(path : String, phase : String, test_root : String, test_path : String, reach : Reach) : Nil
      json = String.build do |io|
        JSON.build(io, indent: 2) do |j|
          j.object do
            j.field "format", "iyi-stale-key"
            j.field "version", 1
            j.field "phase", phase
            j.field "test" do
              j.object do
                j.field "root", test_root
                j.field "path", test_path
              end
            end
            j.field "reach" do
              j.object do
                j.field "checked", phase == "linked"
                j.field "mismatch", reach.mismatch
              end
            end
          end
        end
      end

      dir = File.dirname(path)
      Dir.mkdir_p(dir) unless dir.empty? || Dir.exists?(dir)
      tmp_path = "#{path}.tmp.#{Process.pid}"
      File.write(tmp_path, json)
      File.rename(tmp_path, path)
    end
  end
end
