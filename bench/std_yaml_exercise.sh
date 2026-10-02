#!/usr/bin/env bash
# Exercises `std/yaml`: YAML 1.2 core schema, dump, anchors, merge, refusals.
#
#     bash bench/std_yaml_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The gate runs the compiler the caller names; bin/iyi is a POSIX shell
# wrapper a Windows build cannot run.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on that path, so the
# patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# The negative proofs are patched by python, and a machine can answer
# `python3` with a store stub that prints a refusal instead of running, so
# the interpreter is resolved once and proven to run before it is trusted.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_yaml_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/yaml exercise, plain build"
build_and_run "plain" yaml-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/yaml-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every yaml section reported"
for phrase in "== scalars and collections" "== dump round trip" "== anchors, aliases, merge" "== streams and typed keys" "== what the reader refuses"; do
  if ! grep -q "$phrase" "$WORK/yaml-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  scalars, dump, anchors, streams and refusals all reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" yaml-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/yaml-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when a repeated key is accepted"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched_dup/std"
  SRC="$REPO/src/std/yaml.iyi" DST="$WORK/patched_dup/std/yaml.iyi" "$PY" - <<'PY'
import os
from pathlib import Path
src = Path(os.environ["SRC"]).read_text()
old = "if !merge && spelled.has_key?(key)"
new = "if !merge && spelled.has_key?(key) && false"
if old not in src:
    raise SystemExit("patch site missing")
Path(os.environ["DST"]).parent.mkdir(parents=True, exist_ok=True)
Path(os.environ["DST"]).write_text(src.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched_dup${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_yaml_exercise.iyi" >"$WORK/dup.out" 2>&1; then
    echo "  the exercise PASSED with duplicate keys accepted"
    status=1
  else
    echo "  a repeated mapping key is caught"
  fi
fi

echo
echo "== proving the checks can fail when alias expansion is unbounded"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched_alias/std"
  SRC="$REPO/src/std/yaml.iyi" DST="$WORK/patched_alias/std/yaml.iyi" "$PY" - <<'PY'
import os
from pathlib import Path
src = Path(os.environ["SRC"]).read_text()
old = "if @expanded > ALIAS_NODE_LIMIT"
new = "if @expanded > ALIAS_NODE_LIMIT && false"
if old not in src:
    raise SystemExit("patch site missing")
Path(os.environ["DST"]).parent.mkdir(parents=True, exist_ok=True)
Path(os.environ["DST"]).write_text(src.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched_alias${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" timeout 60 "$IYI" run "$REPO/bench/std_yaml_exercise.iyi" >"$WORK/alias.out" 2>&1; then
    echo "  the exercise PASSED with alias expansion unbounded"
    status=1
  else
    echo "  unbounded alias expansion is caught"
  fi
fi

# One proof per reading fix: the module is copied with one site patched
# back to (or towards) what it did before, as the proofs above do, and
# the exercise must then fail at the check that guards that fix, not
# merely fail.
prove_caught() {
  local name="$1" what="$2" message="$3" old="$4" new="$5"
  echo
  echo "== proving the checks can fail when $what"
  if [ -z "$PY" ]; then
    echo "  skipped: no working python3, so the broken copy could not be made"
    return
  fi
  mkdir -p "$WORK/patched_$name/std"
  if ! OLD="$old" NEW="$new" SRC="$REPO/src/std/yaml.iyi" DST="$WORK/patched_$name/std/yaml.iyi" "$PY" - <<'PY'
import os
from pathlib import Path
src = Path(os.environ["SRC"]).read_text()
old = os.environ["OLD"]
if old not in src:
    raise SystemExit("patch site missing")
Path(os.environ["DST"]).write_text(src.replace(old, os.environ["NEW"], 1))
PY
  then
    echo "  the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched_$name${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" timeout 60 "$IYI" run "$REPO/bench/std_yaml_exercise.iyi" >"$WORK/$name.out" 2>&1; then
    echo "  the exercise PASSED with $what"
    status=1
  elif ! grep -qF -- "ASSERTION FAILED: $message" "$WORK/$name.out"; then
    echo "  the exercise failed, but not at \"$message\":"
    grep -m1 'ASSERTION FAILED\|panic' "$WORK/$name.out" | sed 's/^/    /'
    status=1
  else
    echo "  caught: $message"
  fi
}

prove_caught qplain "a plain scalar may not start with '?'" \
  "a plain scalar may start with '?'" \
  'if b == 63_u8 && lone' 'if b == 63_u8'
prove_caught keytag "a core tag on a key is refused" \
  "a core tag on a key is read" \
  '      while @error.nil? && @bytes[text_pos] == 33_u8' $'      fail("an alias, anchor or tag as a mapping key is not supported", key_pos) if @bytes[key_pos] == 33_u8\n      while @error.nil? && @bytes[text_pos] == 33_u8'
prove_caught loneq "a lone '?' line is refused as a scalar" \
  'refusal of "? lone' \
  $'if b == 63_u8 && lone\n      fail("an explicit \'?\' key is not supported", pos)' $'if b == 63_u8 && lone\n      fail("a scalar cannot start with \'?\'", pos)'
prove_caught mergedup "a second '<<' merges as well" \
  'accepted "merged:' \
  'if merge && merged' 'if merge && merged && false'
prove_caught entry "'- b' after a key reads as text" \
  'accepted "a: - b' \
  'if b == 45_u8 && lone' 'if b == 45_u8 && lone && false'
prove_caught bracketkey "a key may start with what a scalar cannot start with" \
  'accepted "]: 1' \
  'elsif plain_first_refused?(b)' 'elsif false && plain_first_refused?(b)'
prove_caught folded "a folded scalar drops its leading empty lines" \
  "a folded scalar keeps its leading empty lines" \
  $'first = false\n          while blanks > 0' $'first = false\n          while blanks > 0 && false'
prove_caught spaced "spaces past the indentation make an empty line" \
  "spaces past the indentation on a blank line are text" \
  'if start + spaces >= finish && spaces <= indent' 'if start + spaces >= finish'
prove_caught tabindent "a tab after a block scalar's indentation counts as indentation" \
  "a tab after a block scalar's indentation is text" \
  'content = @heads[look]' 'content = skip_blank(@starts[look])'
prove_caught keep "the line after the stream's last line break is kept" \
  "keep chomping adds no line after the stream's last line break" \
  'break if finish >= @size' 'break if finish >= @size && false'
prove_caught esctab "folding trims escaped blanks" \
  "an escaped tab before a folded line break stays" \
  'trim_trailing_blanks(hard)' 'trim_trailing_blanks(0)'
prove_caught foldcopy "folding copies a quoted scalar to trim it, not in place" \
  "quoted scalars of 20,000 lines read in under a second" \
  $'    count = @buffer.size\n    while count > floor' $'    text = @buffer.to_s\n    count = text.bytesize\n    @buffer.clear\n    @buffer.append(text.to_unsafe, count)\n    while count > floor'
prove_caught escbreak "an escaped line break folds like a plain one" \
  "blanks before an escaped line break stay" \
  'next_quoted_line(opener, parent, flow, true)' 'next_quoted_line(opener, parent, flow, false)'
prove_caught jsonkey "a quoted key in a flow sequence needs a blank after ':'" \
  "a quoted key in a flow sequence takes an adjacent ':'" \
  '(quoted_key || value_indicator?(pos, true, @ends[@line]))' '(value_indicator?(pos, true, @ends[@line]))'
prove_caught flowfold "a plain scalar in a flow collection stops at its line end" \
  "a plain scalar folds across lines in a flow collection" \
  'while skip_blank(stop) >= @ends[@line]' 'while skip_blank(stop) >= @ends[@line] && false'
prove_caught docend "a document's end marked more than once is refused" \
  "a document's end may be marked more than once" \
  $'          skip_blank_lines\n        end\n        implicit_allowed = true' $'          break\n        end\n        implicit_allowed = true'
prove_caught rootscalar "a root block scalar must be indented" \
  "a root block scalar may start at the first column" \
  $'      floor = parent + 1\n' $'      floor = parent + 1\n      floor = 1 if floor < 1\n'
prove_caught tagbelow "a scalar tag alone on its line applies to the resolved node below" \
  "a tag over an empty node tags the empty scalar" \
  'if tag.nil? || tag == "!!seq" || tag == "!!map"' 'if true'
prove_caught flowempty "properties over nothing in a flow collection are refused" \
  "properties over nothing in a flow collection are the empty scalar" \
  '(b == 44_u8 || b == 93_u8 || b == 125_u8) && !(anchor.nil? && tag.nil?)' '(b == 44_u8 || b == 93_u8 || b == 125_u8) && !(anchor.nil? && tag.nil?) && false'
prove_caught comment "a plain scalar folds on past a comment" \
  'accepted "a: b # c' \
  'break if skip_blank(@flow_end) < @ends[@line]' 'break if skip_blank(@flow_end) < @ends[@line] && false'
prove_caught dashtext "a plain scalar's next line may not start with '- '" \
  "a plain scalar's next line may start with '- '" \
  $'      if key_colon(look) >= 0\n' $'      if sequence_entry?(look)\n        fail("bad indentation of a sequence entry", @heads[look])\n        break\n      end\n      if key_colon(look) >= 0\n'
prove_caught intkey "an Int32 never reaches an integer key" \
  "an Int32 reaches an integer key through []? and dig?" \
  $'    return self[Any.new(index)] if kind == KIND_HASH\n    as_a[index]\n  end\n\n  def []?(index : Int32) : Any?\n    return self[Any.new(index)]? if kind == KIND_HASH\n' \
  $'    as_a[index]\n  end\n\n  def []?(index : Int32) : Any?\n'
prove_caught hash "a '#' starts a flow scalar" \
  'accepted "[1,#c' \
  '|| b == 62_u8 || b == 35_u8' '|| b == 62_u8'
prove_caught flowentry "'? a' and '- a' read as text in a flow collection" \
  'accepted "[? a]' \
  'elsif (b == 63_u8 || b == 45_u8) && (pos + 1' 'elsif false && (b == 63_u8 || b == 45_u8) && (pos + 1'
prove_caught aliasdepth "an alias's levels are not counted against the limit" \
  'accepted "a0: &a0 x' \
  'if deepest > DEPTH_LIMIT' 'if deepest > DEPTH_LIMIT && false'
prove_caught escapes "the dump writes a byte order mark and C1 controls raw" \
  "a byte order mark is escaped when dumped" \
  $'size : Int32) : Int32\n    b = bytes[i]' $'size : Int32) : Int32\n    return -1\n    b = bytes[i]'
prove_caught c1 "a C1 control is read as text" \
  'accepted "c1: b' \
  $'      return c.to_i32 if c >= 0x80_u8 && c <= 0x9F_u8 && c != 0x85_u8\n' ''
prove_caught noncharacter "a noncharacter is read as text" \
  'accepted "nc: b' \
  $'      return d.to_i32 - 0xBE + 0xFFFE if d == 0xBE_u8 || d == 0xBF_u8\n' ''
prove_caught utf16 "a UTF-16 stream is refused for its first zero byte" \
  "a UTF-16 stream is named by its byte order mark" \
  'if @size >= 2 && ((@bytes[0] == 0xFF_u8' 'if false && ((@bytes[0] == 0xFF_u8'
prove_caught eofbreak "a block scalar ending the stream gets a line feed it lacks" \
  "a literal entry ending the stream without a line break keeps no line feed it lacks" \
  'final = lines.size > 0 && @ends[last_content] < @size' 'final = lines.size > 0'
prove_caught maphash "a mapping's hash sums its pairs unmixed" \
  "a 150 by 150 grid of mappings has at least 22,000 hashes" \
  'value = value &+ {key, item}.hash' 'value = value &+ ((key.hash &* 31) &+ item.hash)'
prove_caught mergespaced "a flow '<<' merges only with its ':' adjacent" \
  "a merge key spaced from its ':' merges" \
  'key.kind == Any::KIND_STRING && key.as_s == "<<"' 'key.kind == Any::KIND_STRING && key.as_s == "<<" && @bytes[pos + 2] == 58_u8'
prove_caught mergepair "a one-pair flow mapping keeps '<<' as a key" \
  "a merge in a one-pair flow mapping merges" \
  'if merge_key?(item_pos, item)' 'if false && merge_key?(item_pos, item)'
prove_caught tabline "a tab after a continuation line's spaces is refused" \
  "a tab after a continuation line's indentation separates" \
  $'      # and as a tab in the indentation.\n' \
  $'      # and as a tab in the indentation.\n      if @tabbed[look]\n        fail("tab used for indentation", @heads[look])\n        break\n      end\n'
prove_caught pairkey "a one-pair flow mapping takes a collection key" \
  'accepted "[[a]: b]' \
  'if item.kind == Any::KIND_ARRAY || item.kind == Any::KIND_HASH' 'if false'
prove_caught secondtag "a second tag replaces the first" \
  'accepted "a: !!str !!int 1' \
  'fail("a second tag", pos) unless tag.nil?' 'nil'
prove_caught secondanchor "a second anchor in a flow collection replaces the first" \
  'refusal of "[&a &b 1, *a]' \
  $'the `!!int`.\n        fail("a second anchor", pos) unless anchor.nil?' $'the `!!int`.\n        nil'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/yaml exercise holds"
else
  echo "the std/yaml exercise did not hold"
fi
exit $status
