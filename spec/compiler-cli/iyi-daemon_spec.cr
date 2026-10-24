require "./spec_helper"

# iyi: `iyi daemon start` hands the server over to a binary named after the
# binary that was typed — `iyi-daemon`, not `crystal-daemon` (SPEC.md IV.1d).
#
# Worth pinning, because getting it wrong is quiet rather than loud. The two
# binaries are the same compiler and report the same `Crystal::Config`, so the
# version handshake between an `iyi` client and a `crystal` server passes: builds
# would be served, by a daemon holding a prelude that was chosen for the other
# command surface.
describe "`iyi daemon`" do
  it "looks for a server named after itself" do
    pending!("requires #{IYI_BIN} (`make iyi`)") unless File::Info.executable?(IYI_BIN)

    # Somewhere with no sibling server and no `.build` — so the lookup fails and
    # says what it looked for, which is the only part being read here.
    with_tempfile("iyi-daemon-lookup") do |dir|
      Dir.mkdir_p(dir)
      copy = File.join(dir, "iyi")
      File.copy(IYI_BIN, copy)
      File.chmod(copy, 0o755)

      result = Process.capture_result(copy, "daemon", "start", chdir: dir,
        env: {"CRYSTAL_DAEMON" => ""})

      result.should be_failure(1)
      # Windows has no fork and so no server to look for: it says that,
      # rather than naming a make target `Makefile.win` does not have.
      {% if flag?(:win32) %}
        result.error.should contain("there is no daemon on Windows")
        result.error.should_not contain("make ")
      {% else %}
        result.error.should contain("iyi-daemon")
        result.error.should contain("make iyi-daemon")
        result.error.should_not contain("crystal-daemon")
      {% end %}
    end
  end
end
