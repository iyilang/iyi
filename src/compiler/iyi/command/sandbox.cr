# iyi: `iyi run --sandbox` — the cheapest container for generated code.
#
# SPEC.md III.12 measured this and the bench proved it: a program
# compiled for wasm32-wasi cannot open a file, a socket, or a clock the
# runtime did not hand it, and a default wasmtime hands it nothing. The
# theft dies with "File is not available on wasm32-wasi", by name. Until
# now that was a bench; an agent running code it just generated wants it
# as a verb.
#
# The pipeline is exactly the one CI runs (bench/sandbox_story.sh):
# cross-compile to wasm32-wasi — which *prints* the link command rather
# than running it, because the target toolchain is not ours — then run
# that command with wasi-sdk's clang standing as `cc`, then execute
# under wasmtime with no preopens. Three tools, each found or named:
# a sandbox that silently fell back to native would be a lie with a
# flag on it.
class Iyi::Command
  private def run_sandbox
    file = nil
    program_args = [] of String
    seen_dashdash = false
    options.each do |option|
      if seen_dashdash
        program_args << option
      elsif option == "--"
        seen_dashdash = true
      elsif option == "--help" || option == "-h"
        puts <<-USAGE
          Usage: #{Command.program_name} run --sandbox <file> [-- args]

          Compile <file> for wasm32-wasi and run it under wasmtime with
          nothing preopened: no filesystem, no network, no environment.
          The program computes and prints; everything else is refused by
          the runtime, by name.

          Needs a wasi-sdk clang (IYI_WASI_CC, $WASI_SDK/bin/clang,
          /opt/wasi-sdk/bin/clang or ~/.local/opt/wasi-sdk/bin/clang)
          and wasmtime (IYI_WASMTIME or on PATH). Missing tools are
          named, never worked around.
          USAGE
        exit
      elsif file.nil?
        file = option
      else
        abort! "run --sandbox takes one file; unexpected '#{option}'", :USAGE_ERROR
      end
    end

    abort! "run --sandbox: which file?", :USAGE_ERROR unless file
    abort! "run --sandbox: file '#{file}' does not exist", :USAGE_ERROR unless File.file?(file)

    cc = sandbox_wasi_cc
    wasmtime = sandbox_wasmtime

    work = File.tempname("iyi-sandbox", nil)
    Dir.mkdir_p(work)
    begin
      binary = File.join(work, "program")

      # Step 1: the front end and codegen, to one .wasm object; stdout is
      # the link command, by design (cross-compile prints, never links).
      link_line = IO::Memory.new
      build_error = IO::Memory.new
      status = Process.run(
        Process.executable_path.not_nil!,
        ["build", "--cross-compile", "--target", "wasm32-wasi", "-o", binary, file],
        output: link_line, error: build_error,
      )
      unless status.success?
        STDERR << build_error.to_s
        exit status.exit_code
      end

      # Step 2: the printed command, with wasi-sdk's clang standing as
      # `cc` — the same PATH trick the bench and CI use, kept in a
      # directory of ours rather than theirs.
      shim = File.join(work, "bin")
      Dir.mkdir_p(shim)
      File.symlink(cc, File.join(shim, "cc"))
      command = link_line.to_s.lines.last?.try(&.strip)
      abort! "cross-compile printed no link command", :USAGE_ERROR unless command && !command.empty?
      link_status = Process.run(
        "/bin/sh", ["-c", command],
        env: {"PATH" => "#{shim}#{Process::PATH_DELIMITER}#{ENV["PATH"]?}"},
        output: STDOUT, error: STDERR,
      )
      exit link_status.exit_code unless link_status.success?

      # Step 3: wasmtime, defaults untouched: no preopened directories,
      # no inherited environment — that absence *is* the sandbox.
      run_status = Process.run(
        wasmtime, [binary] + (program_args.empty? ? [] of String : ["--"] + program_args),
        input: Process::Redirect::Inherit, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit,
      )
      exit run_status.exit_code
    ensure
      FileUtils.rm_rf(work)
    end
  end

  # iyi: a variable the author set is the answer or the refusal, and the
  # refusal names it. Pointed at nothing, IYI_WASI_CC was skipped in
  # silence and the sentence said to set it - which they had. And clang
  # under `$WASI_SDK` is `clang.exe` on Windows: the bare `clang` this
  # looked for is not there, so an installed wasi-sdk was "install
  # wasi-sdk", and the help names `$WASI_SDK` while the refusal did not.
  private def sandbox_wasi_cc : String
    if from_env = ENV["IYI_WASI_CC"]?
      return from_env if File.file?(from_env)
      abort! "run --sandbox: IYI_WASI_CC is #{from_env}, and there is no file there. " \
             "Point it at wasi-sdk's clang, or unset it", :USAGE_ERROR
    end
    clang = {% if flag?(:win32) %} "clang.exe" {% else %} "clang" {% end %}
    candidates = [] of String
    if sdk = ENV["WASI_SDK"]?
      candidates << File.join(sdk, "bin", clang)
    end
    candidates << "/opt/wasi-sdk/bin/clang"
    candidates << File.expand_path("~/.local/opt/wasi-sdk/bin/#{clang}", home: true)
    candidates.find { |candidate| File.file?(candidate) } ||
      abort! "run --sandbox needs a wasi-sdk clang, and there is none at " \
             "#{candidates.join(", ")}. Set IYI_WASI_CC to one, or install wasi-sdk " \
             "(https://github.com/WebAssembly/wasi-sdk) and set WASI_SDK", :USAGE_ERROR
  end

  private def sandbox_wasmtime : String
    if from_env = ENV["IYI_WASMTIME"]?
      return from_env if File.file?(from_env)
      abort! "run --sandbox: IYI_WASMTIME is #{from_env}, and there is no file there. " \
             "Point it at wasmtime, or unset it", :USAGE_ERROR
    end
    Process.find_executable("wasmtime") ||
      begin
        fallback = File.expand_path("~/.wasmtime/bin/wasmtime", home: true)
        File.file?(fallback) ? fallback : nil
      end ||
      abort! "run --sandbox needs wasmtime: set IYI_WASMTIME or install it " \
             "(https://wasmtime.dev) on PATH", :USAGE_ERROR
  end
end
