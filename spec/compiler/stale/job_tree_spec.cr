require "../../spec_helper"

{% if flag?(:win32) %}
  require "compiler/iyi/command"

  describe Iyi::Command::TestTree do
    it "ends its running child when the job handle closes" do
      process, tree = Iyi::Command::TestTree.start do |before_resume|
        Process.new("cmd.exe", ["/d", "/c", "ping -n 60 127.0.0.1 > nul"],
          before_resume: before_resume)
      end
      begin
        process.exists?.should be_true
        tree.close
        # Closing the job ends the child. Windows gives such a process a
        # success status, so it is the wait's return, not the status, that
        # shows it ended: the `ping` would otherwise run for 60 seconds.
        started = Time.instant
        process.wait
        (Time.instant - started).should be < 30.seconds
        process.exists?.should be_false
      ensure
        tree.close
      end
    end
  end
{% end %}
