require "c/stddef"
require "c/int_safe"
require "c/winnt"
require "c/win_def"

lib LibC
  struct PROCESS_MEMORY_COUNTERS
    cb : DWORD
    pageFaultCount : DWORD
    peakWorkingSetSize : SizeT
    workingSetSize : SizeT
    quotaPeakPagedPoolUsage : SizeT
    quotaPagedPoolUsage : SizeT
    quotaPeakNonPagedPoolUsage : SizeT
    quotaNonPagedPoolUsage : SizeT
    pagefileUsage : SizeT
    peakPagefileUsage : SizeT
  end

  # kernel32's own export (Windows 7 on), so no psapi.lib is linked for it.
  fun K32GetProcessMemoryInfo(process : HANDLE, ppsmemCounters : PROCESS_MEMORY_COUNTERS*, cb : DWORD) : BOOL
end
