#!/usr/bin/env bash
# What a string knows about itself, checked by running one.
#
# The prelude decides `String`'s layout and fills in its two counts, and
# a wrong count is not a crash: it is a number that is quietly wrong
# somewhere far away. Nothing else in this repository catches that. The
# specs are the compiler's, `samples_roundtrip.sh` compares a program
# against itself, and the samples have no expected output pinned, so a
# concatenation that reported four characters where it holds five would
# pass every gate there is.
#
# Written after exactly that. `String#+` used to count the characters of
# its result by walking it, which made building a string in a loop
# quadratic; replacing the walk with the sum of the two counts is right
# only if the sum is right, and that is what this asks.
set -u
# Homebrew is where this laptop keeps clang and libgc. On a machine
# without it these add nothing and, unlike replacing PATH outright,
# they take nothing away either: a runner that puts its toolchain
# somewhere else keeps it.
if [ -d /opt/homebrew/bin ]; then export PATH="/opt/homebrew/bin:$PATH"; fi
if [ -d /opt/homebrew/opt/bdw-gc/lib ]; then
  export LIBRARY_PATH="/opt/homebrew/opt/bdw-gc/lib:${LIBRARY_PATH:-}"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -x "$REPO/bin/iyi" ] || { echo "  no $REPO/bin/iyi: run make first"; exit 1; }

cat > "$WORK/strings.iyi" <<'IYI'
# Each line prints a name, what was asked, and what came back. The
# checker below holds the answers, so a wrong one is a diff rather than
# an opinion.
def say(name : String, got : Int32) : Nil
  print name
  print " "
  print got.to_s
  print "\n"
end

# The bytes themselves, weighted by where they are. Counting alone was
# not enough: `String#+` copies a word at a time where it can, and a
# copy that hands off to the byte loop at the wrong offset leaves the
# right number of bytes in the wrong order. Three mutations of that
# handoff passed a gate that compared only lengths.
def checksum(text : String) : Int32
  total = 0
  index = 0
  while index < text.bytesize
    total = (total + text.to_unsafe[index].to_i32 * (index % 7 + 1)) % 1000003
    index = index + 1
  end
  total
end

ascii = "hello" + ", world"
say("ascii.bytesize", ascii.bytesize)
say("ascii.size", ascii.size)

# Six bytes and five characters: the two counts are different numbers,
# so a concatenation that reports one where it means the other is
# visible here and nowhere else.
wide = "h\u00e9l" + "lo"
say("wide.bytesize", wide.bytesize)
say("wide.size", wide.size)

# Both operands multibyte, so neither count can stand in for the sum.
both = "\u00e9\u00e9" + "\u00e9"
say("both.bytesize", both.bytesize)
say("both.size", both.size)

# An empty operand takes the short path that returns the other string
# whole, which has to keep its own counts.
short = "" + wide
say("short.bytesize", short.bytesize)
say("short.size", short.size)

# Built in a loop, which is the shape that made this matter.
grown = ""
index = 0
while index < 100
  grown = grown + "h\u00e9"
  index = index + 1
end
say("grown.bytesize", grown.bytesize)
say("grown.size", grown.size)
say("grown.checksum", checksum(grown))

# Long enough that the word path does the work, and joined at an offset
# that is a multiple of eight so the second copy takes it too.
eight = "abcdefgh"
block = eight + eight + eight + eight
wider = block + block
say("wider.bytesize", wider.bytesize)
say("wider.checksum", checksum(wider))

# The same length, joined one byte off, so the second copy hands the
# word loop an address it cannot use and falls back to bytes.
odd = "a" + wider
say("odd.bytesize", odd.bytesize)
say("odd.checksum", checksum(odd))

say("ascii.checksum", checksum(ascii))
say("wide.checksum", checksum(wide))

print ascii
print "\n"
print wider
print "\n"
IYI

cat > "$WORK/want.txt" <<'WANT'
ascii.bytesize 12
ascii.size 12
wide.bytesize 6
wide.size 5
both.bytesize 6
both.size 3
short.bytesize 6
short.size 5
grown.bytesize 300
grown.size 200
grown.checksum 186862
wider.bytesize 64
wider.checksum 25444
odd.bytesize 65
odd.checksum 25624
ascii.checksum 3720
wide.checksum 2639
hello, world
abcdefghabcdefghabcdefghabcdefghabcdefghabcdefghabcdefghabcdefgh
WANT

IYI_CACHE_DIR="$WORK/iyi" "$REPO/bin/iyi" run "$WORK/strings.iyi" > "$WORK/got.txt" 2> "$WORK/err.txt"
status=$?
if [ "$status" -ne 0 ]; then
  echo "  the program did not run:"
  head -5 "$WORK/err.txt" | sed 's|^|    |'
  exit 1
fi

if diff -q "$WORK/want.txt" "$WORK/got.txt" > /dev/null; then
  echo "  strings agree: $(wc -l < "$WORK/want.txt" | tr -d ' ') answers"
  exit 0
fi

echo "  strings differ:"
diff -u "$WORK/want.txt" "$WORK/got.txt" | tail -n +4 | head -20 | sed 's|^|    |'
exit 1
