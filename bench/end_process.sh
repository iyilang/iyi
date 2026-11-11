# end_process <pid> [KILL]: ends <pid>, a program this shell started in the
# background. Sourced by the gates that stop the servers and clients they
# start, so that on Windows none of them asks Git bash to.
#
# Elsewhere, and for Git bash's own programs on Windows, it is bash's
# `kill` (TERM, or KILL when asked). A native Windows program - an iyi
# build, Python, anything not under /usr - is ended by `taskkill /F` on its
# own Windows pid, and nothing else is touched.
#
# Bash's `kill` to a native program is MSYS's `exit_process_tree`
# (winsup/cygwin/include/cygwin/exit_process.h, msys2-runtime): it ends the
# program and every process whose recorded parent pid is the program's,
# found by that pid alone. Windows keeps a process's parent pid after the
# parent has ended, and hands pids out again, so a process whose parent
# ended long ago is "a child" of whichever program holds that pid next - and
# is ended with it. On a GitHub runner the agent's parent has ended
# (actions/runner#4632 found a process claiming its pid on a real runner);
# ended, the agent goes quiet and the job is failed 45 minutes later, its
# log gone, as "The hosted runner lost communication with the server".
end_process() {
  local pid="$1" exe w
  if [ "$END_PROCESS_WINDOWS" = yes ]; then
    exe="$(cat "/proc/$pid/exename" 2>/dev/null)" || return 1
    case "$exe" in
      /usr/* | /bin/*) ;;
      *)
        { read -r w <"/proc/$pid/winpid"; } 2>/dev/null || return 1
        taskkill //F //PID "$w" >/dev/null 2>&1
        return
        ;;
    esac
  fi
  kill -s "${2:-TERM}" "$pid" 2>/dev/null
}
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) END_PROCESS_WINDOWS=yes ;;
  *) END_PROCESS_WINDOWS=no ;;
esac
