require "./winnt"

lib LibC
  fun CreateJobObjectW(lpJobAttributes : SECURITY_ATTRIBUTES*, lpName : LPWSTR) : HANDLE
  fun SetInformationJobObject(hJob : HANDLE, jobObjectInformationClass : JOBOBJECTINFOCLASS, lpJobObjectInformation : Void*, cbJobObjectInformationLength : DWORD) : BOOL
  fun QueryInformationJobObject(hJob : HANDLE, jobObjectInformationClass : JOBOBJECTINFOCLASS, lpJobObjectInformation : Void*, cbJobObjectInformationLength : DWORD, lpReturnLength : DWORD*) : BOOL
  fun IsProcessInJob(process : HANDLE, job : HANDLE, result : BOOL*) : BOOL
  fun AssignProcessToJobObject(hJob : HANDLE, hProcess : HANDLE) : BOOL
  fun TerminateJobObject(hJob : HANDLE, uExitCode : UInt) : BOOL
  fun AcquireSRWLockExclusive(lock : Void**) : Void
  fun ReleaseSRWLockExclusive(lock : Void**) : Void
end
