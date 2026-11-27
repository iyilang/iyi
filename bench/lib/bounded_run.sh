#!/usr/bin/env bash
# Runs a program under a time bound, for the native gates that execute what they build.
#
#   . "$REPO/bench/lib/bounded_run.sh"
#   bounded_run SECONDS EXE PREFIX
#
# EXE runs with no arguments and stdin from /dev/null. Its stdout goes to
# PREFIX.out, its stderr to PREFIX.err, and its exit status to PREFIX.status
# (128 + N when signal N ended it). Returns
#   0  the program ended on its own, whatever its status;
#   1  the bound ended it: PREFIX.timeout exists;
#   2  it could not be started, or its end could not be observed.
#
# The bound is Perl's alarm, set in the child before exec, so SIGALRM ends the
# program itself after SECONDS. Perl is on every host the gates run on; GNU
# timeout is not on macOS. An alarm is told apart from a program that exits
# 142 by the signal in its wait status.
bounded_run() {
  local seconds=$1 exe=$2 prefix=$3 status
  rm -f "$prefix.timeout" "$prefix.exec-error" "$prefix.done" || return 2
  perl -e '
    my ($seconds, $timeout, $error, $done, $exe) = @ARGV;
    my $pid = fork();
    defined($pid) or die "fork: $!";
    if ($pid == 0) {
      alarm $seconds;
      exec { $exe } $exe;
      open my $fh, ">", $error or die "exec and error marker failed: $!";
      print $fh "exec failed: $!\n";
      close $fh or die "error marker: $!";
      exit 127;
    }
    my $waited = waitpid($pid, 0);
    my $status = $?;
    $waited == $pid or die "waitpid: $!";
    if (($status & 127) == 14) {
      open my $fh, ">", $timeout or die "timeout marker: $!";
      close $fh or die "timeout marker: $!";
    }
    open my $fh, ">", $done or die "completion marker: $!";
    close $fh or die "completion marker: $!";
    exit (($status & 127) ? 128 + ($status & 127) : $status >> 8);
  ' "$seconds" "$prefix.timeout" "$prefix.exec-error" "$prefix.done" "$exe" </dev/null >"$prefix.out" 2>"$prefix.err"
  status=$?
  echo "$status" >"$prefix.status" || return 2
  [ -e "$prefix.done" ] && [ ! -e "$prefix.exec-error" ] || return 2
  [ ! -e "$prefix.timeout" ] || return 1
  return 0
}
