# iyi: what this process has cost so far, in resident megabytes.
#
# `iyi` carries no collector, so for a compiler process this number only
# ever goes up and peak is current: nothing is handed back until the
# process exits. That is exactly what makes it a usable retirement
# signal — `Lsp::Proxy` replaces a worker that has cost enough, and the
# worker is the only one who can cheaply say how much that is.
#
# `getrusage` is one call and a few nanoseconds, which is why this is
# measured per request rather than sampled. Its unit is the platform's
# joke: kilobytes on Linux, bytes on darwin. Windows has no POSIX call,
# and kernel32 answers the same question as the peak working set. The
# proxy counted requests there instead, and a Windows session typing
# without a pause reached 1,023 MB against the 760 its gate allows -
# twenty-four requests of a collector-free front end cost more than the
# 512 MB a worker is retired at.
{% if flag?(:win32) %}
  require "c/psapi"
{% end %}

module Iyi::Lsp
  def self.footprint : Int32
    {% if flag?(:darwin) %}
      LibC.getrusage(LibC::RUSAGE_SELF, out darwin_usage)
      (darwin_usage.ru_maxrss.to_i64 // (1024 * 1024)).to_i32
    {% elsif flag?(:unix) && !flag?(:wasm32) %}
      LibC.getrusage(LibC::RUSAGE_SELF, out usage)
      (usage.ru_maxrss.to_i64 // 1024).to_i32
    {% elsif flag?(:win32) %}
      counters = LibC::PROCESS_MEMORY_COUNTERS.new
      counters.cb = sizeof(LibC::PROCESS_MEMORY_COUNTERS)
      return 0 if LibC.K32GetProcessMemoryInfo(LibC.GetCurrentProcess, pointerof(counters), counters.cb) == 0
      (counters.peakWorkingSetSize // (1024 * 1024)).to_i32
    {% else %}
      0
    {% end %}
  end
end
