require "../../spec_helper"
require "../spec_helper"

{% if flag?(:unix) %}
  describe "running compiler image" do
    it "refuses a replacement at the executable pathname" do
      with_tempfile("running-image-proof") do |dir|
        Dir.mkdir_p(dir)
        executable = File.join(dir, "compiler-image")
        replacement = File.join(dir, "replacement")
        output = IO::Memory.new
        status = Process.run("bin/crystal", ["build", "spec/compiler/stale/running_image_fixture.cr", "-o", executable],
          env: {"CRYSTAL_CACHE_DIR" => File.join(dir, "crystal-cache")}, output: output, error: output)
        status.success?.should be_true, output.to_s
        File.write(replacement, "replacement compiler bytes")
        child = Process.new(executable, [dir], input: Process::Redirect::Pipe, output: Process::Redirect::Pipe)
        begin
          child.output.gets.should eq("ready")
          File.rename(replacement, executable)
          child.input.puts("continue")
          child.input.flush
          child.output.gets.should eq("REFUSED: running compiler image changed")
          child.wait.success?.should be_true
        ensure
          child.close
        end
      end
    end
  end
{% end %}
