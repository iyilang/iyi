require "./spec_helper"

# `iyi foo` runs `iyi-foo` from PATH, the way `git foo` runs `git-foo`. The
# lookup was in the command layer and `iyi`'s own dispatch never reached it:
# a name that was not a verb or a file was "unknown command" before anything
# asked PATH.
describe "`iyi-*` external commands" do
  exec_path = File.tempname
  echo_env_path = File.join(exec_path, "iyi-echo_env#{EXE_SUFFIX}")

  before_all do
    Dir.mkdir_p(exec_path)
    Process.capture_result(crystal, "build", "-o", echo_env_path, fixture_path("iyi-echo_env.cr"))
      .should(be_success)
    File::Info.executable?(echo_env_path).should be_true
  end

  after_all do
    FileUtils.rm_rf(exec_path)
  end

  it "runs iyi-* from PATH with the rest of the line" do
    result = Process.capture_result(iyi, "echo_env", "foo", "bar", env: {"PATH" => "#{exec_path}#{Process::PATH_DELIMITER}#{ENV["PATH"]?}"})
    result.should(be_success)
      .output.should(contain("PROGRAM_NAME=#{echo_env_path}"))
    result.output.should contain(%(ARGV=["foo", "bar"]))
    # The directory `iyi` itself is in, for the command to find its sibling:
    # compared as a file, because the path it is read from may be resolved.
    exec_dir = result.output.lines.find(&.starts_with?("IYI_EXEC_PATH=")).not_nil!.lchop("IYI_EXEC_PATH=")
    File.same?(File.join(exec_dir, File.basename(IYI_BIN)), IYI_BIN).should be_true
  end

  it "still refuses a name nothing on PATH answers to" do
    Process.capture_result(iyi, "echo_env_nonesuch")
      .should(be_failure(1))
      .error.should(contain("unknown command or missing file: echo_env_nonesuch"))
  end
end
