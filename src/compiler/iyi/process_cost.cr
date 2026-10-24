# iyi: what this process holds and has paid for in memory, asked of the
# operating system rather than of an allocator, for `-s` (`ProgressTracker`).
#
# The allocator cannot answer. The compiler is built `-Dgc_none` (Makefile,
# `BINARY_GC_FLAGS`), whose `GC.stats` is all zeros, which is how `iyi build -s`
# came to print `( 0.00MB)` after every phase (#144).
#
# **Resident set, now.** Not the peak `getrusage` reports, because on Linux
# that figure survives `execve` (getrusage(2): "resource usage metrics are
# preserved across an execve"): a probe that touched 20 MB reported a 596 MB
# peak when a large process started it, and 19.65 MB under `/usr/bin/time`.
# What is resident now belongs to this program's own address space on every
# platform, and a compiler without a collector hands next to nothing back,
# so it is also the most this build has held, give or take what `realloc`
# returned. Asked of:
#
# * Linux: `/proc/self/statm`, its second field, in pages;
# * darwin: `task_info(MACH_TASK_BASIC_INFO)`, `resident_size`, in bytes;
# * Windows: `K32GetProcessMemoryInfo`, `WorkingSetSize`, in bytes.
#
# Anywhere else it is nil and `-s` leaves it out rather than print a zero.
#
# **Page faults, so far.** `ru_minflt + ru_majflt` on unix and
# `PageFaultCount` on Windows, which counts soft faults (a page first
# touched, or taken back from the standby list) with the hard ones. The
# count carries over an `execve` too, which is why `-s` prints the faults a
# phase took, a difference, and never the count itself. They are here
# because they are the cost a never-freeing heap adds and a timer cannot
# tell apart from work: a phase that grows the heap by a gigabyte
# first-touches a quarter of a million pages, and what one fault costs is
# the machine's business (a VM's nested paging, Windows zeroing a page it
# had no zeroed one for), not the compiler's.
{% if flag?(:win32) %}
  require "c/psapi"
{% end %}

{% if flag?(:darwin) %}
  lib LibC
    # <mach/time_value.h>
    struct TimeValueT
      seconds : Int
      microseconds : Int
    end

    # <mach/task_info.h>: `MACH_TASK_BASIC_INFO`, the flavour whose sizes
    # are 64-bit on every darwin.
    struct MachTaskBasicInfo
      virtual_size : UInt64
      resident_size : UInt64
      resident_size_max : UInt64
      user_time : TimeValueT
      system_time : TimeValueT
      policy : Int
      suspend_count : Int
    end

    MACH_TASK_BASIC_INFO = 20_u32

    # `mach_task_self()` is a macro for this variable.
    $mach_task_self_ : UInt

    fun task_info(target_task : UInt, flavor : UInt, task_info_out : Int*, task_info_out_count : UInt*) : Int
  end
{% end %}

module Iyi::ProcessCost
  # The bytes this process has resident now, or nil where the platform
  # cannot say.
  def self.resident_bytes : Int64?
    {% if flag?(:linux) %}
      fields = File.read("/proc/self/statm").split(' ', 3)
      pages = fields[1]?.try(&.to_i64?)
      page_size = LibC.sysconf(LibC::SC_PAGESIZE)
      return nil unless pages && page_size > 0
      pages * page_size
    {% elsif flag?(:darwin) %}
      info = LibC::MachTaskBasicInfo.new
      count = (sizeof(LibC::MachTaskBasicInfo) // sizeof(LibC::UInt)).to_u32
      return nil unless LibC.task_info(LibC.mach_task_self_, LibC::MACH_TASK_BASIC_INFO, pointerof(info).as(LibC::Int*), pointerof(count)) == 0
      info.resident_size.to_i64
    {% elsif flag?(:win32) %}
      counters = LibC::PROCESS_MEMORY_COUNTERS.new
      counters.cb = sizeof(LibC::PROCESS_MEMORY_COUNTERS)
      return nil if LibC.K32GetProcessMemoryInfo(LibC.GetCurrentProcess, pointerof(counters), counters.cb) == 0
      counters.workingSetSize.to_i64
    {% else %}
      nil
    {% end %}
  rescue File::Error
    nil
  end

  # The page faults this process has taken so far, or nil where the platform
  # cannot say. Only a difference of two of these means anything.
  def self.page_faults : Int64?
    {% if flag?(:unix) && !flag?(:wasm32) %}
      return nil unless LibC.getrusage(LibC::RUSAGE_SELF, out usage) == 0
      usage.ru_minflt.to_i64 + usage.ru_majflt.to_i64
    {% elsif flag?(:win32) %}
      counters = LibC::PROCESS_MEMORY_COUNTERS.new
      counters.cb = sizeof(LibC::PROCESS_MEMORY_COUNTERS)
      return nil if LibC.K32GetProcessMemoryInfo(LibC.GetCurrentProcess, pointerof(counters), counters.cb) == 0
      counters.pageFaultCount.to_i64
    {% else %}
      nil
    {% end %}
  end
end
