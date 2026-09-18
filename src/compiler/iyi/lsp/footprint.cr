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
# joke: kilobytes on Linux, bytes on darwin, and on Windows there is no
# POSIX call at all — there the proxy falls back to counting requests,
# which is the cruder bound it says it is.
module Iyi::Lsp
  def self.footprint : Int32
    {% if flag?(:darwin) %}
      LibC.getrusage(LibC::RUSAGE_SELF, out darwin_usage)
      (darwin_usage.ru_maxrss.to_i64 // (1024 * 1024)).to_i32
    {% elsif flag?(:unix) && !flag?(:wasm32) %}
      LibC.getrusage(LibC::RUSAGE_SELF, out usage)
      (usage.ru_maxrss.to_i64 // 1024).to_i32
    {% else %}
      0
    {% end %}
  end
end
