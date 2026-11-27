require "../../spec_helper"

{% if flag?(:win32) %}
  describe "Windows pre-resume process hook" do
    it "runs before the child can write" do
      with_tempfile("pre-resume-order.txt") do |path|
        File.open(path, "w") do |output|
          hook = ->(_handle : Void*) do
            sleep 250.milliseconds
            output.puts("before")
            output.flush
            nil
          end
          process = Process.new("cmd.exe", ["/d", "/c", "echo", "child"], output: output, before_resume: hook)
          process.wait.success?.should be_true
        end
        File.read(path).lines.map(&.strip).should eq(["before", "child"])
      end
    end

    it "does not resume the child when the hook fails" do
      with_tempfile("pre-resume-refused.txt") do |path|
        File.open(path, "w") do |output|
          hook = ->(_handle : Void*) do
            sleep 250.milliseconds
            raise "refused before resume"
            nil
          end
          expect_raises(Exception, "refused before resume") do
            Process.new("cmd.exe", ["/d", "/c", "echo", "child"], output: output, before_resume: hook)
          end
        end
        File.read(path).should eq("")
      end
    end
  end
{% else %}
  describe "pre-resume process hook" do
    it "refuses a Windows-only hook before spawning on other platforms" do
      hook = ->(_handle : Void*) { nil }
      expect_raises(ArgumentError, "before_resume is only available on Windows") do
        Process.new("not-a-real-command", before_resume: hook)
      end
    end
  end
{% end %}
