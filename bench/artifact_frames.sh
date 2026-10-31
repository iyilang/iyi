# Sourced by the gates that hold a program built from its artifacts to
# the output of the same program built from source.
#
# A panic prints its frames on darwin, through `backtrace_symbols_fd`, and
# every frame names its binary (`from-source` or `from-artifact`) and an
# address no two builds share. On the main thread it always did. Under a
# panic a task raises on purpose it did not on CI's macos-14 (14.8.9),
# where `backtrace` walked no frames off a task's stack: all 113 std
# exercises printed the same from source and from artifacts there (job
# 123810587348). macos-15 walks them, and in the first run on it 22 of
# those exercises differed in these lines, as did the std/big, std/toml
# and std/websocket gates' own comparisons (jobs 124324684065,
# 124324684192 and 124324684116); macOS 26.6 on an Apple M2 Pro prints
# them as well. The panic's message is still compared, only the frames
# are left out.
#
# `grep -a` under `LC_ALL=C` rather than sed: some exercises print bytes
# that are not UTF-8, and darwin's sed stopped at the first of them
# ("illegal byte sequence"), which left the rest of the output out of the
# comparison; the uutils sed of a Linux machine stops at them under
# `LC_ALL=C` as well ("stream did not contain valid UTF-8"). Its status is
# grep's but for 1, which says only that no line was left.
without_frames() { # without_frames < output > comparable
  LC_ALL=C grep -a -v -E '^ *[0-9]+ +from-(source|artifact) +0x[0-9a-f]+ '
  [ $? -le 1 ]
}
