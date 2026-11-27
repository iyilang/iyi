require "../../spec_helper"

{% if flag?(:win32) %}
  require "compiler/iyi/command"

  describe Iyi::Command::TestTree do
    it "ends its running child when the job handle closes" do
      process, tree = Iyi::Command::TestTree.start(strict: true) do |before_resume|
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

    {"CreateJobObjectW", "SetInformationJobObject"}.each do |call|
      it "runs a plain test outside a job when Windows refuses #{call}" do
        tree = Iyi::Command::TestTree.new(strict: false, refuse: call)
        tree.before_resume.should be_nil
        process = Process.new("cmd.exe", ["/d", "/c", "exit 3"], before_resume: tree.before_resume)
        tree.attach(process)
        process.wait.exit_code.should eq(3)
        tree.close
      end

      it "refuses the receipt runner's test when Windows refuses #{call}" do
        expect_raises(RuntimeError, call) do
          Iyi::Command::TestTree.new(strict: true, refuse: call)
        end
      end
    end
  end
{% end %}
