require "json"
require "./reach"
require "../build_inputs"
require "../semantic/effects"

module Iyi::Stale
  module KeyFile
    struct ModeBuild
      include JSON::Serializable

      getter build : String
      getter toolchain : String
      getter behavior : String
      getter callpath : String
      getter link : String
      getter cenv : String
      getter explain : Hash(String, String)

      def initialize(@build : String, @toolchain : String, @behavior : String,
                     @callpath : String, @link : String, @cenv : String,
                     @explain : Hash(String, String))
      end
    end

    struct NotReusable
      include JSON::Serializable

      getter category : String
      getter reason : String
      getter site : String?

      def initialize(@category : String, @reason : String, @site : String? = nil)
      end
    end

    struct Hit
      include JSON::Serializable

      getter mode : String
      getter build : String

      def initialize(@mode : String, @build : String)
      end
    end

    struct StaleRule
      include JSON::Serializable

      getter mode : String
      getter build : String

      def initialize(@mode : String, @build : String)
      end
    end

    struct KeyFileData
      include JSON::Serializable

      getter format : String
      getter version : Int32
      getter phase : String
      getter test : Hash(String, String)
      getter local : ModeBuild?
      getter portable : ModeBuild?
      getter not_reusable : Array(NotReusable)?
      getter hit : Hit?
      getter blocked : Bool?
      getter reach : Hash(String, JSON::Any)?
      getter rg3 : Array(JSON::Any)?
    end

    def self.read_rules(path : String?) : Array(StaleRule)
      return [] of StaleRule unless path && File.file?(path)
      BuildInputs.paused do
        content = File.read(path)
        Array(StaleRule).from_json(content)
      rescue
        [] of StaleRule
      end
    end

    def self.parse(content : String) : KeyFileData
      KeyFileData.from_json(content)
    end

    def self.write_out(
      path : String,
      phase : String,
      test_root : String,
      test_path : String,
      local : ModeBuild,
      portable : ModeBuild,
      not_reusable : Array(NotReusable),
      hit : Hit?,
      blocked : Bool,
      reach : Reach,
      rg3 : Array(Effects::RG3Site)? = nil,
    ) : Nil
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
            j.field "local" do
              j.object do
                j.field "build", local.build
                j.field "toolchain", local.toolchain
                j.field "behavior", local.behavior
                j.field "callpath", local.callpath
                j.field "link", local.link
                j.field "cenv", local.cenv
                j.field "explain" do
                  j.object do
                    local.explain.keys.sort.each do |k|
                      j.field k, local.explain[k]
                    end
                  end
                end
              end
            end
            j.field "portable" do
              j.object do
                j.field "build", portable.build
                j.field "toolchain", portable.toolchain
                j.field "behavior", portable.behavior
                j.field "callpath", portable.callpath
                j.field "link", portable.link
                j.field "cenv", portable.cenv
                j.field "explain" do
                  j.object do
                    portable.explain.keys.sort.each do |k|
                      j.field k, portable.explain[k]
                    end
                  end
                end
              end
            end
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
            j.field "hit" do
              if h = hit
                j.object do
                  j.field "mode", h.mode
                  j.field "build", h.build
                end
              else
                j.null
              end
            end
            j.field "blocked", blocked
            j.field "reach" do
              j.object do
                j.field "checked", phase == "linked"
                j.field "mismatch" do
                  j.array do
                    reach.mismatch.each { |m| j.string m }
                  end
                end
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

    # S4a backwards-compatible overload
    def self.write_out(path : String, phase : String, test_root : String, test_path : String, reach : Reach,
                       not_reusable : Array(Effects::NotReusableReason)? = nil,
                       rg3 : Array(Effects::RG3Site)? = nil) : Nil
      empty_build = ModeBuild.new(
        build: "",
        toolchain: "",
        behavior: "",
        callpath: "",
        link: "",
        cenv: "",
        explain: {} of String => String
      )
      nr_list = [] of NotReusable
      if not_reusable
        not_reusable.each do |nr|
          nr_list << NotReusable.new(nr.category, nr.reason, nr.site)
        end
      end
      write_out(
        path: path,
        phase: phase,
        test_root: test_root,
        test_path: test_path,
        local: empty_build,
        portable: empty_build,
        not_reusable: nr_list,
        hit: nil,
        blocked: false,
        reach: reach,
        rg3: rg3
      )
    end
  end
end
