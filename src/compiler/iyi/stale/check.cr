require "./encoding"
require "./key_file"
require "./machine_key"
require "./reach"
require "./roots"
require "./call_path"
require "./toolchain"
require "./link"
require "./compiler_env"
require "../compiler"
require "../program"
require "../semantic/effects"

module Iyi::Stale
  class CheckResult
    getter test_root : String
    getter test_path : String
    getter reach : Reach
    getter callpath_result : CallPathResult
    getter local_build : Digest
    getter portable_build : Digest
    getter local_mode_build : KeyFile::ModeBuild
    getter portable_mode_build : KeyFile::ModeBuild
    getter not_reusable : Array(KeyFile::NotReusable)
    getter hit : KeyFile::Hit?
    getter? blocked : Bool
    getter rg3 : Array(Effects::RG3Site)?

    def initialize(
      @test_root : String,
      @test_path : String,
      @reach : Reach,
      @callpath_result : CallPathResult,
      @local_build : Digest,
      @portable_build : Digest,
      @local_mode_build : KeyFile::ModeBuild,
      @portable_mode_build : KeyFile::ModeBuild,
      @not_reusable : Array(KeyFile::NotReusable),
      @hit : KeyFile::Hit?,
      @blocked : Bool,
      @rg3 : Array(Effects::RG3Site)? = nil,
    )
    end

    def hit? : Bool
      !@hit.nil?
    end

    def local_build_hex : String
      Stale.hex(@local_build)
    end

    def portable_build_hex : String
      Stale.hex(@portable_build)
    end
  end

  module Check
    def self.closure_check(program : Program, reach : Reach) : Effects::ClosureResult
      Effects.closure_check(program, reach)
    end

    def self.run(
      compiler : Compiler,
      program : Program,
      node : ASTNode,
      source_or_sources,
    ) : CheckResult
      reach = Stale::ReachWalk.walk(program, node, drop: compiler.stale_drop)
      program.stale_reach = reach

      recorder = Stale::Recorder.new
      program.stale_recorder = recorder

      closure = Effects.closure_check(program, reach)
      program.stale_closure_result = closure

      primary_source = source_or_sources.is_a?(Array) ? source_or_sources.first : source_or_sources
      test_root = "src"
      entry_root = Compiler.entry_root_of(primary_source.filename, primary_source.code)
      rel_path = ::Path[File.expand_path(primary_source.filename)].relative_to(File.expand_path(entry_root)).to_s rescue primary_source.filename
      test_path = rel_path.starts_with?("./") ? rel_path[2..-1] : rel_path

      cache_root = CacheDir.instance.dir
      roots = Stale::Roots.default(program, primary_source.filename, primary_source.code, cache_root)

      callpath_result = Stale::CallPath.compute(program, reach, roots)

      if dump_path = compiler.stale_dump_elements
        dir = File.dirname(dump_path)
        Dir.mkdir_p(dir) unless dir.empty? || Dir.exists?(dir)
        tmp_dump = "#{dump_path}.tmp.#{Process.pid}"
        File.open(tmp_dump, "w") do |io|
          callpath_result.dump_rows.each do |row|
            row.to_json(io)
            io.puts
          end
        end
        File.rename(tmp_dump, dump_path)
      end

      toolchain_fp = Stale::Toolchain.digest(cache_root)
      behavior_fp = compiler.behavior_key
      lib_flags = program.lib_flags(compiler.cross_compile?)
      link_fp = Stale::Link.fp(lib_flags, compiler.link_flags, compiler.static?, ENV)
      cenv_fp = Stale::CompilerEnv.fp

      machine_key = Stale::MachineKey.load_or_create(cache_root)
      keyer_local = Stale::Keyer.local(machine_key)
      keyer_portable = Stale::Keyer.portable

      local_k_callpath = keyer_local.k(callpath_result.digest)
      local_k_link = keyer_local.k(link_fp)
      local_k_cenv = keyer_local.k(cenv_fp)

      local_build = Stale.d("build") do |enc|
        enc.digest(toolchain_fp)
        enc.digest(behavior_fp)
        enc.digest(local_k_callpath)
        enc.digest(local_k_link)
        enc.digest(local_k_cenv)
      end

      portable_k_callpath = keyer_portable.k(callpath_result.digest)
      portable_k_link = keyer_portable.k(link_fp)
      portable_k_cenv = keyer_portable.k(cenv_fp)

      portable_build = Stale.d("build") do |enc|
        enc.digest(toolchain_fp)
        enc.digest(behavior_fp)
        enc.digest(portable_k_callpath)
        enc.digest(portable_k_link)
        enc.digest(portable_k_cenv)
      end

      local_explain = Hash(String, String).new
      callpath_result.explain.each do |k, v|
        local_explain[k] = Stale.hex(keyer_local.k(v))
      end

      local_mode_build = KeyFile::ModeBuild.new(
        build: Stale.hex(local_build),
        toolchain: Stale.hex(toolchain_fp),
        behavior: Stale.hex(behavior_fp),
        callpath: Stale.hex(local_k_callpath),
        link: Stale.hex(local_k_link),
        cenv: Stale.hex(local_k_cenv),
        explain: local_explain
      )

      portable_explain = Hash(String, String).new
      callpath_result.explain.each do |k, v|
        portable_explain[k] = Stale.hex(keyer_portable.k(v))
      end

      portable_mode_build = KeyFile::ModeBuild.new(
        build: Stale.hex(portable_build),
        toolchain: Stale.hex(toolchain_fp),
        behavior: Stale.hex(behavior_fp),
        callpath: Stale.hex(portable_k_callpath),
        link: Stale.hex(portable_k_link),
        cenv: Stale.hex(portable_k_cenv),
        explain: portable_explain
      )

      not_reusable = [] of KeyFile::NotReusable

      # S2 build mode refusals
      compiler.stale_refusals.each do |r|
        not_reusable << KeyFile::NotReusable.new("refused build mode", r, nil)
      end

      # S3d link flag refusal
      if link_refusal = Stale::Link.refusal(lib_flags, compiler.link_flags)
        not_reusable << KeyFile::NotReusable.new("refused build mode", link_refusal, nil)
      end

      # S3f ambiguous keys
      callpath_result.ambiguous_keys.each do |_k|
        not_reusable << KeyFile::NotReusable.new("internal", "ambiguous key", nil)
      end

      # Compatibility mode
      if compiler.crystal_library?
        not_reusable << KeyFile::NotReusable.new("crystal", "Crystal library effects are not classified", nil)
      end

      # S4a closure check not_reusable reasons
      closure.not_reusable.each do |nr|
        not_reusable << KeyFile::NotReusable.new(nr.category, nr.reason, nr.site)
      end

      # Read block file
      block_rules = KeyFile.read_rules(compiler.stale_block)
      local_build_hex = Stale.hex(local_build)
      portable_build_hex = Stale.hex(portable_build)

      blocked = block_rules.any? do |rule|
        (rule.mode == "local" && rule.build.compare(local_build_hex, case_insensitive: true) == 0) ||
          (rule.mode == "portable" && rule.build.compare(portable_build_hex, case_insensitive: true) == 0)
      end

      # Read accept file
      hit = nil
      if !blocked && not_reusable.empty?
        accept_rules = KeyFile.read_rules(compiler.stale_accept)
        if local_match = accept_rules.find { |r| r.mode == "local" && r.build.compare(local_build_hex, case_insensitive: true) == 0 }
          hit = KeyFile::Hit.new("local", local_build_hex)
        elsif portable_match = accept_rules.find { |r| r.mode == "portable" && r.build.compare(portable_build_hex, case_insensitive: true) == 0 }
          hit = KeyFile::Hit.new("portable", portable_build_hex)
        end
      end

      phase = hit ? "hit" : "checked"

      if key_file = compiler.stale_key
        KeyFile.write_out(
          path: key_file,
          phase: phase,
          test_root: test_root,
          test_path: test_path,
          local: local_mode_build,
          portable: portable_mode_build,
          not_reusable: not_reusable,
          hit: hit,
          blocked: blocked,
          reach: reach,
          rg3: closure.rg3_sites
        )
      end

      result = CheckResult.new(
        test_root: test_root,
        test_path: test_path,
        reach: reach,
        callpath_result: callpath_result,
        local_build: local_build,
        portable_build: portable_build,
        local_mode_build: local_mode_build,
        portable_mode_build: portable_mode_build,
        not_reusable: not_reusable,
        hit: hit,
        blocked: blocked,
        rg3: closure.rg3_sites
      )
      program.stale_check_result = result
      result
    end
  end
end
