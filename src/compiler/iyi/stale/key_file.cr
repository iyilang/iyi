require "json"
require "../semantic/effects"

module Iyi::Stale
  module KeyFile
    def self.write_out(path : String, phase : String, test_root : String, test_path : String, reach : Reach,
                       not_reusable : Array(Effects::NotReusableReason)? = nil,
                       rg3 : Array(Effects::RG3Site)? = nil) : Nil
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
            if not_reusable
              j.field "not_reusable" do
                j.array do
                  not_reusable.each do |nr|
                    j.object do
                      j.field "category", nr.category
                      j.field "reason", nr.reason
                      j.field "site", nr.site
                    end
                  end
                end
              end
            end
            if rg3
              j.field "rg3" do
                j.array do
                  rg3.each do |entry|
                    j.object do
                      j.field "site", entry.site
                      j.field "enclosing_def", entry.enclosing_def
                      j.field "detail", entry.detail
                    end
                  end
                end
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
