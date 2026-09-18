@echo off
rem iyi, run out of this checkout from cmd: `bin\iyi run samples\iyi\hello.iyi`.
rem
rem `bin/crystal.bat` hands its arguments to `bin/crystal.ps1` through cmd's
rem and PowerShell's stop-parsing token, and that hop cannot carry them:
rem measured here, `bin\iyi.bat run samples\iyi\hello.iyi` arrived at the
rem script as the single argument `run samples\iyi\hello.iyi` and the compiler
rem answered "unknown command or missing file", while dropping the token
rem instead split `"C:\a dir\a file.iyi"` into three arguments and let a `;`
rem end the command. So this runs the binary itself: `%*` is the command tail
rem cmd already parsed, and it reaches the compiler as the person typed it.
rem `bin\iyi.ps1` is the same wrapper for PowerShell, where splatting works.
setlocal
rem `%%~fr` rather than `%~dp0..`: the message a person reads should name the
rem checkout and not `...\bin\..`.
for %%r in ("%~dp0..") do set "IYI_ROOT=%%~fr"
set "IYI=%IYI_ROOT%\.build\iyi.exe"
if not exist "%IYI%" (
  >&2 echo iyi is not built yet. Run `make -f Makefile.win iyi` in %IYI_ROOT%.
  exit /B 1
)
"%IYI%" %*
rem On its own line, not inside the `if` above: cmd expands a parenthesised
rem block when it reads the block, so `%ERRORLEVEL%` there is the value from
rem before the compiler ran.
exit /B %ERRORLEVEL%
