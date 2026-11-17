#!/usr/bin/env bash
# The native Mach-O and ELF executable gate.
#
# 1. The driver (src/compiler/tools/link_macho.iyi) builds from source.
# 2. The hand-built program links, prints its message, exits 7 and passes
#    codesign -v --strict. bench/fixtures/native_link/hello.expected holds that.
# 3. For every samples/iyi/*.iyi the Crystal-hosted compiler emits an arm64 Mach-O
#    object and prints its link line. The native linker links that object with
#    the frameworks the link line names. On macOS the two programs run with no
#    stdin and must match on exit status, stdout and stderr. socket and webapp
#    are linked and checked, not run: socket opens a network socket and webapp
#    serves HTTP until it is stopped.
# 4. Every linked executable: codesign -v --strict passes, there is no
#    __stub_helper section, nm -u lists no dyld_stub_binder, otool -L lists
#    libSystem and only the frameworks the link line names, and LC_BUILD_VERSION
#    lists zero tools.
# 5. Tripwire: the driver runs under a PATH whose ld, cc, clang, codesign and
#    dsymutil are shims that log and exit 1. The log must stay empty.
# 6. Each executable links twice to identical bytes (cmp).
# 7. Mutation proofs (macOS): a CodeDirectory page hash, a library ordinal, and a
#    rebase are each broken in a copy of the source. The check must fail.
#
# Needs a built compiler (`make`). Every host builds the driver, links the
# Mach-O corpus and both ELF machines, and inspects their output. Native
# execution is checked separately on the matching operating system and CPU.

set -u

root="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$root" || exit 1
. "$root/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if [ -z "$PY" ]; then
  echo 'a functional Python interpreter is required' >&2
  exit 1
fi

triple="${1:-aarch64-apple-darwin}"
iyi=./bin/iyi
driver_src=src/compiler/tools/link_macho.iyi
imports_src=src/compiler/native/link/imports.iyi
codesign_src=src/compiler/native/link/codesign.iyi
link_src=src/compiler/native/link/link.iyi
fixture=bench/fixtures/native_link/hello.expected
darwin=0
if [ "$HOST_OS" = darwin ]; then darwin=1; fi

work="$(mktemp -d "${TMPDIR:-/tmp}/native_link.XXXXXX")" || exit 1
. bench/lib/native_signature.sh
export NATIVE_SIGNATURE_FAILURE_FILE="$work/signature-failure"
restore=""
backup=""
cleanup() {
  if [ -n "$restore" ] && [ -n "$backup" ]; then
    cp "$backup" "$restore"
  fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

failures=0
fail() {
  echo "   $*"
  failures=$((failures + 1))
}

# Samples that are linked and checked, but not run, each with its reason.
excluded_reason() {
  case "$1" in
    socket) echo "opens a network socket" ;;
    webapp) echo "serves HTTP until it is stopped" ;;
    *) echo "" ;;
  esac
}

# run_program EXE OUT ERR: runs EXE from a scratch directory with no stdin for at
# most 30 seconds, its stdout to OUT and its stderr to ERR, and prints the status.
run_program() {
  rundir="$work/run"
  mkdir -p "$rundir"
  (cd "$rundir" && perl -e 'alarm 30; exec @ARGV' "$1" </dev/null >"$2" 2>"$3")
  echo $?
}

# build_tool: builds the driver from the current source into $work/bin.
build_tool() {
  mkdir -p "$work/bin"
  "$iyi" build -o "$(native_path "$work/bin/link_macho$EXE")" "$driver_src" >"$work/build-tool.log" 2>&1
}

# check_hello: the hand-built program links with the current driver and matches
# the fixture: its message, exit 7, and a strict signature.
check_hello() {
  "$work/bin/link_macho$EXE" hello "$(native_path "$work/hello")" >"$work/hello.link.log" 2>&1 || return 1
  chmod +x "$work/hello"
  native_signature_ok "$work/hello" || return 1
  status="$(run_program "$work/hello" "$work/hello.out" "$work/hello.err")"
  head -n 1 "$fixture" >"$work/hello.expected"
  want_exit="$(tail -n 1 "$fixture" | awk '{print $2}')"
  [ "$status" = "$want_exit" ] && cmp -s "$work/hello.out" "$work/hello.expected" &&
    [ ! -s "$work/hello.err" ] && /usr/bin/codesign -v --strict "$work/hello" >/dev/null 2>&1
}

# check_corpus: every corpus program the current driver links runs as its
# original did. It fails on the first sample that differs.
check_corpus() {
  for name in $names; do
    if [ -n "$(excluded_reason "$name")" ]; then
      continue
    fi
    fw_args=""
    if ! "$work/bin/link_macho$EXE" link "$(native_path "$work/corpus/$name.mut")" "$name" $(cat "$work/corpus/$name.fw") "$(native_path "$work/corpus/$name.o")" >/dev/null 2>&1; then
      return 1
    fi
    chmod +x "$work/corpus/$name.mut"
    native_signature_ok "$work/corpus/$name.mut" || return 1
    status="$(run_program "$work/corpus/$name.mut" "$work/corpus/$name.mut.out" "$work/corpus/$name.mut.err")"
    if [ "$status" != "$(cat "$work/corpus/$name.status")" ] ||
      ! cmp -s "$work/corpus/$name.out" "$work/corpus/$name.mut.out" ||
      ! cmp -s "$work/corpus/$name.err" "$work/corpus/$name.mut.err"; then
      return 1
    fi
  done
  return 0
}

# Inspect format bytes on every host, independently of the target kernel.
check_macho() {
  "$PY" - "$(native_path "$1")" <<'PY'
import struct, sys

try:
    data = open(sys.argv[1], "rb").read()
    if len(data) < 32:
        raise ValueError("short Mach-O header")
    magic, cpu, _, kind, ncmds, size, _, _ = struct.unpack_from("<IIIIIIII", data)
    if (magic, cpu, kind) != (0xfeedfacf, 0x0100000c, 2):
        raise ValueError("not an arm64 Mach-O executable")
    if 32 + size > len(data):
        raise ValueError("load commands extend past the image")
    at, entry, signature, libraries = 32, False, False, []
    for _ in range(ncmds):
        cmd, length = struct.unpack_from("<II", data, at)
        if length < 8 or at + length > 32 + size:
            raise ValueError("invalid Mach-O load command")
        if cmd == 0x80000028:
            if length < 24 or struct.unpack_from("<Q", data, at + 8)[0] >= len(data):
                raise ValueError("invalid LC_MAIN entry")
            entry = True
        elif cmd == 0x1d:
            if length < 16:
                raise ValueError("short code-signature command")
            offset, count = struct.unpack_from("<II", data, at + 8)
            signature = count > 0 and offset + count <= len(data)
        elif cmd == 0xc:
            if length < 24:
                raise ValueError("short dylib command")
            offset = struct.unpack_from("<I", data, at + 8)[0]
            if offset >= length:
                raise ValueError("invalid dylib name")
            libraries.append(data[at + offset:at + length].split(b"\0", 1)[0])
        at += length
    if at != 32 + size or not entry or not signature or b"/usr/lib/libSystem.B.dylib" not in libraries:
        raise ValueError("missing entry, signature, or libSystem")
except (OSError, ValueError, struct.error) as error:
    print(f"Mach-O inspection failed: {error}", file=sys.stderr)
    sys.exit(1)
PY
}

check_elf() {
  "$PY" - "$(native_path "$1")" "$2" "$(native_path "$root/bench/fixtures/native_link/elf_hello.expected")" <<'PY'
import struct, sys

def require(condition, message):
    if not condition:
        raise ValueError(message)

def sign(value, bits):
    return value - (1 << bits) if value & (1 << (bits - 1)) else value

try:
    data = open(sys.argv[1], "rb").read()
    arch = sys.argv[2]
    expected = open(sys.argv[3], "rb").read()
    require(len(data) >= 64 and data[:7] == b"\x7fELF\x02\x01\x01", "not little-endian ELF64")
    header = struct.unpack_from("<16sHHIQQQIHHHHHH", data)
    _, kind, machine, version, entry, phoff, shoff, _, ehsize, phsize, phnum, shsize, shnum, shstr = header
    require(kind == 3 and version == 1 and machine == {"x86_64": 62, "aarch64": 183}[arch],
            "wrong ELF type, version, or machine")
    require(ehsize == 64 and phsize == 56 and phnum > 0 and phoff + phsize * phnum <= len(data),
            "invalid program headers")
    loads = []
    for i in range(phnum):
        ptype, flags, offset, vaddr, _, filesz, memsz, _ = struct.unpack_from("<IIQQQQQQ", data, phoff + i * phsize)
        require(ptype not in (2, 3), "PT_DYNAMIC or PT_INTERP present")
        require(offset + filesz <= len(data) and filesz <= memsz, "invalid segment bounds")
        if ptype == 1:
            loads.append((flags, offset, vaddr, filesz))
    def file_offset(address, length, flags):
        for access, offset, vaddr, size in loads:
            if access & flags == flags and vaddr <= address and address + length <= vaddr + size:
                return offset + address - vaddr
        raise ValueError("address is not in the required load segment")
    start = file_offset(entry, 32, 1)
    require(shsize == 64 and shnum > 0 and shstr < shnum and shoff + shsize * shnum <= len(data),
            "invalid section headers")
    sections = [struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shsize) for i in range(shnum)]
    names = sections[shstr]
    require(names[4] + names[5] <= len(data), "invalid section-name table")
    strings = data[names[4]:names[4] + names[5]]
    def name_at(table, index):
        require(index < len(table), "invalid string-table offset")
        end = table.find(b"\0", index)
        require(end >= 0, "unterminated string-table entry")
        return table[index:end]
    symtabs = [section for section in sections if name_at(strings, section[0]) == b".symtab"]
    require(len(symtabs) == 1, "missing symbol table")
    table = symtabs[0]
    require(table[1] == 2 and table[9] == 24 and table[5] % 24 == 0 and
            table[4] + table[5] <= len(data) and table[6] < shnum, "invalid symbol table")
    names = sections[table[6]]
    require(names[4] + names[5] <= len(data), "invalid symbol string table")
    strings = data[names[4]:names[4] + names[5]]
    symbols = {}
    for at in range(table[4], table[4] + table[5], 24):
        name, _, _, _, value, _ = struct.unpack_from("<IBBHQQ", data, at)
        symbols[name_at(strings, name)] = value
    require(symbols.get(b"_start") == entry and entry != 0, "entry does not name _start")
    msg, helper = symbols[b"msg"], symbols[b"write_syscall"]
    file_offset(helper, 1, 1)
    off = file_offset(msg, len(expected), 4)
    require(data[off:off + len(expected)] == expected, "rodata message differs")
    if arch == "x86_64":
        lea, call = start + 12, start + 25
        require(data[lea:lea + 3] == b"\x48\x8d\x35" and data[call] == 0xe8, "missing x86 address or call")
        disp = struct.unpack_from("<i", data, lea + 3)[0]
        branch = struct.unpack_from("<i", data, call + 1)[0]
        require(entry + 19 + disp == msg, "x86 data relocation is wrong")
        require(entry + 30 + branch == helper, "x86 call relocation is wrong")
    else:
        adrp, add, branch = (
            struct.unpack_from("<I", data, start + 4)[0],
            struct.unpack_from("<I", data, start + 8)[0],
            struct.unpack_from("<I", data, start + 20)[0])
        require(adrp & 0x9f00001f == 0x90000001 and add & 0xffc003ff == 0x91000021 and
                branch & 0xfc000000 == 0x94000000, "missing AArch64 address or call")
        imm = ((adrp >> 29) & 3) | (((adrp >> 5) & 0x7ffff) << 2)
        target = ((entry + 4) & ~4095) + sign(imm, 21) * 4096 + ((add >> 10) & 0xfff)
        require(target == msg, "AArch64 data relocation is wrong")
        require(entry + 20 + sign(branch & 0x3ffffff, 26) * 4 == helper, "AArch64 call relocation is wrong")
except (OSError, ValueError, KeyError, struct.error) as error:
    print(f"ELF inspection failed: {error}", file=sys.stderr)
    sys.exit(1)
PY
}

# prove_mutation LABEL FILE OLD NEW CHECK...: replaces the first OLD in FILE with
# NEW, runs CHECK, and requires it to fail. Restores FILE on every exit path.
prove_mutation() {
  label=$1
  file=$2
  old=$3
  new=$4
  shift 4
  backup="$work/mutation-$RANDOM.bak"
  cp "$file" "$backup" || return 1
  restore="$file"
  "$PY" - "$(native_path "$file")" "$old" "$new" <<'PY'
import pathlib, sys
path, old, new = pathlib.Path(sys.argv[1]), sys.argv[2].encode(), sys.argv[3].encode()
data = path.read_bytes()
if old not in data:
    sys.exit(3)
path.write_bytes(data.replace(old, new, 1))
PY
  patched=$?
  if [ "$patched" -eq 3 ]; then
    cp "$backup" "$file"
    restore=""
    fail "PATCH CHANGED NOTHING: '$label' found no text to change: this proves nothing"
    return 1
  fi
  if [ "$patched" -ne 0 ]; then
    cp "$backup" "$file"
    restore=""
    fail "could not apply '$label'"
    return 1
  fi
  if ! build_tool; then
    cat "$work/build-tool.log"
    cp "$backup" "$file"
    restore=""
    fail "INVALID MUTANT: '$label' did not compile"
    return 1
  fi
  if "$@" >"$work/mutation-check.log" 2>&1; then
    fail "NOT caught: $label"
  else
    echo "   caught: $label"
  fi
  cp "$backup" "$file"
  restore=""
  return 0
}

echo "== 1. build the driver from the source"
if ! build_tool; then
  cat "$work/build-tool.log"
  fail "the driver does not build"
  echo "== SOME NATIVE_LINK CHECKS FAILED"
  exit 1
fi
cp "$work/bin/link_macho$EXE" "$work/bin/link_macho.good$EXE"

if [ "$darwin" -eq 1 ]; then
  echo "== 2. the hand-built program prints its message, exits 7 and is signed"
  if check_hello; then
    echo "   hello: message, exit 7 and codesign -v --strict as the fixture says"
  else
    fail "the hand-built program does not match $fixture"
  fi
else
  if ! "$work/bin/link_macho$EXE" hello "$(native_path "$work/hello")" >"$work/hello.link.log" 2>&1; then
    cat "$work/hello.link.log"
    fail "the hand-built Mach-O program did not link"
  fi
  host_limited "Mach-O arm64 execution and strict codesign require macOS"
fi
if ! check_macho "$work/hello"; then
  fail "the hand-built Mach-O image did not pass format inspection"
fi
if ! "$work/bin/link_macho$EXE" hello "$(native_path "$work/hello.again")" >/dev/null 2>&1 ||
   ! cmp -s "$work/hello" "$work/hello.again"; then
  fail "the hand-built Mach-O image does not relink identically"
fi

echo "== 3. link every samples/iyi program from its oracle object"
mkdir -p "$work/corpus"
names=""
linked=0
for src in samples/iyi/*.iyi; do
  name="$(basename "$src" .iyi)"
  obj="$work/corpus/$name.o"
  if ! "$iyi" build --cross-compile --target "$triple" -o "$(native_path "$obj")" "$src" \
      >"$work/corpus/$name.link" 2>"$work/corpus/$name.err"; then
    fail "the oracle does not compile $src"
    continue
  fi
  names="$names $name"
  line="$(tail -n 1 "$work/corpus/$name.link" | tr -d '\r')"
  fw=""
  prev=""
  for word in $line; do
    if [ "$prev" = "-framework" ]; then
      fw="$fw -framework $word"
    fi
    prev="$word"
  done
  echo "$fw" >"$work/corpus/$name.fw"
  if ! "$work/bin/link_macho$EXE" link "$(native_path "$work/corpus/$name")" "$name" $fw "$(native_path "$obj")" \
      >"$work/corpus/$name.native.log" 2>&1; then
    fail "the native linker does not link $name:"
    sed 's/^/     /' "$work/corpus/$name.native.log" | tail -n 3
    continue
  fi
  linked=$((linked + 1))
  mv "$work/corpus/$name" "$work/corpus/$name.nat"
  chmod +x "$work/corpus/$name.nat"
  if ! check_macho "$work/corpus/$name.nat"; then
    fail "$name: Mach-O format inspection failed"
  fi
  echo "   $name: linked natively (frameworks:${fw:- none})"
done
echo "   linked $linked corpus programs"

if [ "$darwin" -eq 1 ]; then
  echo "== 4. each native program matches its oracle on exit status, stdout and stderr"
  matched=0
  for name in $names; do
    why="$(excluded_reason "$name")"
    if [ -n "$why" ]; then
      echo "   $name: linked and checked, not run: $why"
      continue
    fi
    line="$(tail -n 1 "$work/corpus/$name.link" | tr -d '\r')"
    if ! sh -c "$line" >"$work/corpus/$name.origlog" 2>&1; then
      fail "the compiler's link line does not link $name"
      continue
    fi
    orig="$work/corpus/$name.orig"
    mv "$work/corpus/$name" "$orig"
    status="$(run_program "$orig" "$work/corpus/$name.out" "$work/corpus/$name.err")"
    echo "$status" >"$work/corpus/$name.status"
    again="$(run_program "$orig" "$work/corpus/$name.again" "$work/corpus/$name.again.err")"
    if [ "$again" != "$status" ] || ! cmp -s "$work/corpus/$name.out" "$work/corpus/$name.again" ||
       ! cmp -s "$work/corpus/$name.err" "$work/corpus/$name.again.err"; then
      fail "$name: the oracle is not stable across two runs"
      continue
    fi
    if ! native_signature_ok "$work/corpus/$name.nat"; then
      fail "$name: invalid native signature"
      continue
    fi
    nat_status="$(run_program "$work/corpus/$name.nat" "$work/corpus/$name.nat.out" "$work/corpus/$name.nat.err")"
    if [ "$nat_status" = "$status" ] &&
      cmp -s "$work/corpus/$name.out" "$work/corpus/$name.nat.out" &&
      cmp -s "$work/corpus/$name.err" "$work/corpus/$name.nat.err"; then
      echo "   $name: matches the original (exit $status)"
      matched=$((matched + 1))
    else
      fail "$name differs from the original: exit $nat_status against $status"
    fi
  done
  echo "   matched $matched corpus programs"

  echo "== 5. every executable: strict signature, no stub helper, no dyld_stub_binder, libraries, zero build tools"
  for name in $names; do
    exe="$work/corpus/$name.nat"
    if ! /usr/bin/codesign -v --strict "$exe" >/dev/null 2>&1; then
      fail "$name: codesign -v --strict rejects it"
    fi
    if /usr/bin/otool -l "$exe" | grep -q "__stub_helper"; then
      fail "$name: it has a __stub_helper section"
    fi
    if /usr/bin/nm -u "$exe" | grep -q "dyld_stub_binder"; then
      fail "$name: nm -u lists dyld_stub_binder"
    fi
    libs="$(/usr/bin/otool -L "$exe" | tail -n +2 | awk '{print $1}' | sort | paste -sd ' ' -)"
    want="/usr/lib/libSystem.B.dylib "
    fw="$(cat "$work/corpus/$name.fw")"
    for word in $fw; do
      if [ "$word" != "-framework" ]; then
        want="$want/System/Library/Frameworks/$word.framework/$word "
      fi
    done
    want="$(echo "$want" | tr ' ' '\n' | grep -v '^$' | sort | paste -sd ' ' -)"
    if [ "$libs" != "$want" ]; then
      fail "$name: otool -L lists '$libs', expected '$want'"
    fi
    tools="$(/usr/bin/otool -l "$exe" | awk '/LC_BUILD_VERSION/{f=1} f && /ntools/{print $2; f=0}')"
    if [ "$tools" != "0" ]; then
      fail "$name: LC_BUILD_VERSION lists $tools build tools"
    fi
  done
  if [ "$failures" -eq 0 ]; then
    echo "   every executable passes the five properties"
  fi
  tool_libs="$(/usr/bin/otool -L "$work/bin/link_macho$EXE" | tail -n +2 | awk '{print $1}')"
  if [ "$tool_libs" != "/usr/lib/libSystem.B.dylib" ]; then
    fail "the driver links '$tool_libs', expected only /usr/lib/libSystem.B.dylib"
  fi
else
  host_limited "Mach-O corpus execution, strict signatures and library checks require macOS"
fi

echo "== 6. each executable links twice to identical bytes"
for name in $names; do
  fw="$(cat "$work/corpus/$name.fw")"
  if ! "$work/bin/link_macho$EXE" link "$(native_path "$work/corpus/$name.again.exe")" "$name" $fw "$(native_path "$work/corpus/$name.o")" >/dev/null 2>&1; then
    fail "$name does not link a second time"
    continue
  fi
  if ! cmp -s "$work/corpus/$name.nat" "$work/corpus/$name.again.exe"; then
    fail "$name links to different bytes the second time"
  fi
done
echo "   checked $(echo $names | wc -w | tr -d ' ') programs"

echo "== ELF static-PIE: link and inspect both machines"
for arch in x86_64 aarch64; do
  image="$work/elf-$arch"
  if ! "$work/bin/link_macho$EXE" elf-hello "$arch" "$(native_path "$image")" >"$work/elf-$arch.log" 2>&1; then
    cat "$work/elf-$arch.log"
    fail "$arch ELF did not link"
    continue
  fi
  if ! "$work/bin/link_macho$EXE" elf-hello "$arch" "$(native_path "$image.again")" >"$work/elf-$arch.again.log" 2>&1 ||
     ! cmp -s "$image" "$image.again"; then
    fail "$arch ELF does not relink identically"
  fi
  if ! check_elf "$image" "$arch"; then
    fail "$arch ELF header, segments, entry or relocations are wrong"
    continue
  fi
  echo "   $arch: ELF64 ET_DYN, entry, load segments, data and call relocations checked"

  # Negative controls change the image, not the source: the checker must reject
  # a wrong ELF class and damaged data and call relocations on each machine.
  if ! "$PY" - "$(native_path "$image")" "$(native_path "$image.bad-header")" \
      "$(native_path "$image.bad-reloc")" "$(native_path "$image.bad-call")" "$arch" <<'PY'
import pathlib, struct, sys
image, header, reloc, call, arch = sys.argv[1:]
data = bytearray(pathlib.Path(image).read_bytes())
bad = bytearray(data)
bad[4] = 1
pathlib.Path(header).write_bytes(bad)
entry = struct.unpack_from("<Q", data, 24)[0]
phoff = struct.unpack_from("<Q", data, 32)[0]
phsize, phnum = struct.unpack_from("<HH", data, 54)
for i in range(phnum):
    kind, flags, offset, addr, _, size, _, _ = struct.unpack_from("<IIQQQQQQ", data, phoff + i * phsize)
    if kind == 1 and flags & 1 and addr <= entry < addr + size:
        start = offset + entry - addr
        break
else:
    raise SystemExit("entry is not in an executable segment")
bad_call = bytearray(data)
if arch == "x86_64":
    data[start + 15] ^= 1
    bad_call[start + 26] ^= 1
else:
    data[start + 7] ^= 0x20
    bad_call[start + 20] ^= 1
pathlib.Path(reloc).write_bytes(data)
pathlib.Path(call).write_bytes(bad_call)
PY
  then
    fail "$arch ELF negative controls could not be created"
    continue
  fi
  for defect in header reloc call; do
    case "$defect:$arch" in
      header:*) reason="not little-endian ELF64" ;;
      reloc:x86_64) reason="x86 data relocation is wrong" ;;
      call:x86_64) reason="x86 call relocation is wrong" ;;
      reloc:aarch64) reason="AArch64 data relocation is wrong" ;;
      call:aarch64) reason="AArch64 call relocation is wrong" ;;
    esac
    if check_elf "$image.bad-$defect" "$arch" >"$work/elf-$arch.bad-$defect.log" 2>&1; then
      fail "$arch ELF inspector accepted a damaged $defect"
    elif ! grep -Fq "$reason" "$work/elf-$arch.bad-$defect.log"; then
      cat "$work/elf-$arch.bad-$defect.log"
      fail "$arch ELF inspector rejected $defect for the wrong reason"
    else
      echo "   $arch: damaged $defect rejected"
    fi
  done

  if [ "$HOST_OS" = linux ]; then
    head="$(git rev-parse HEAD)" || { fail "cannot obtain git HEAD for ELF provenance"; continue; }
    if ! "$PY" - "$(native_path "$image")" "$(native_path "$image.json")" "$arch" "$head" <<'PY'
import hashlib, json, pathlib, sys
image, output, arch, head = sys.argv[1:]
digest = hashlib.sha256(pathlib.Path(image).read_bytes()).hexdigest()
pathlib.Path(output).write_text(json.dumps({"architecture": arch, "git_head": head, "sha256": digest}) + "\n", encoding="utf-8")
PY
    then
      fail "$arch ELF provenance could not be written"
      continue
    fi
    if { [ "$HOST_ARCH" = x86_64 ] && [ "$arch" = x86_64 ]; } ||
       { [ "$HOST_ARCH" = arm64 ] && [ "$arch" = aarch64 ]; }; then
      if ! bash "$root/bench/native_elf_run.sh" "$image" "$image.json"; then
        fail "$arch ELF native Linux execution failed"
      fi
    else
      host_limited "$arch ELF execution requires its matching Linux kernel"
    fi
  else
    host_limited "$arch ELF execution requires its matching Linux kernel"
  fi
done

echo "== 7. tripwire: no ld, cc, clang, codesign or dsymutil is run while linking"
shims="$work/shims"
tripwire_log="$work/tripwire.log"
mkdir -p "$shims"
export LINK_TRIPWIRE_LOG="$(native_path "$tripwire_log")"
if [ "$HOST_OS" = windows ]; then
  cat >"$work/tripwire.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  const char *path = getenv("LINK_TRIPWIRE_LOG");
  FILE *log = path ? fopen(path, "ab") : NULL;
  if (!log) return 2;
  fprintf(log, "%s\n", argc ? argv[0] : "tool");
  fclose(log);
  return 1;
}
C
  compiler="$(command -v cl.exe || command -v cl)" || compiler=""
  if [ -z "$compiler" ] ||
     ! MSYS2_ARG_CONV_EXCL='*' "$compiler" /nologo /TC "/Fe$(native_path "$shims/ld.exe")" \
       "/Fo$(native_path "$work/tripwire.obj")" "$(native_path "$work/tripwire.c")" >"$work/tripwire-build.log" 2>&1; then
    [ ! -f "$work/tripwire-build.log" ] || cat "$work/tripwire-build.log"
    fail "Windows native tripwire did not build"
  else
    for tool in cc clang codesign dsymutil; do
      cp "$shims/ld.exe" "$shims/$tool.exe"
    done
  fi
else
  for tool in ld cc clang codesign dsymutil; do
    printf '#!/bin/sh\nprintf "%%s\\n" "$0" >>"$LINK_TRIPWIRE_LOG"\nexit 1\n' >"$shims/$tool"
    chmod +x "$shims/$tool"
  done
fi
: >"$tripwire_log"
python_cmd="$(command -v "$PY")" || { fail "cannot locate the Python executable"; exit 1; }
if ! PATH="$shims" "$python_cmd" - "$HOST_OS" <<'PY'
import os, subprocess, sys
host = sys.argv[1]
env = os.environ.copy()
tools = ("ld", "cc", "clang", "codesign", "dsymutil")
for tool in tools:
    if host == "windows":
        cmd = [os.path.join(os.environ["SystemRoot"], "System32", "cmd.exe"), "/d", "/c", tool]
    else:
        cmd = [tool]
    result = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    if result.returncode != 1:
        raise SystemExit(f"native process could not find {tool} shim: {result.returncode}, {result.stderr!r}")
with open(env["LINK_TRIPWIRE_LOG"], "rb") as f:
    if len(f.read().splitlines()) != len(tools):
        raise SystemExit("native tripwire control did not log every shim")
PY
then
  fail "native-process tripwire control failed"
else
  echo "   native process located and ran all five tripwire shims"
fi
: >"$tripwire_log"
tw_hello="$(native_path "$work/tripwire-hello")"
PATH="$shims" "$work/bin/link_macho$EXE" hello "$tw_hello" >/dev/null 2>&1 || fail "the tripwire run did not link the hello program"
for name in $names; do
  fw="$(cat "$work/corpus/$name.fw")"
  tw_out="$(native_path "$work/corpus/$name.tw")"
  tw_obj="$(native_path "$work/corpus/$name.o")"
  PATH="$shims" "$work/bin/link_macho$EXE" link "$tw_out" "$name" $fw "$tw_obj" >/dev/null 2>&1 || fail "the tripwire run did not link $name"
done
for arch in x86_64 aarch64; do
  tw_out="$(native_path "$work/elf-$arch.tw")"
  PATH="$shims" "$work/bin/link_macho$EXE" elf-hello "$arch" "$tw_out" >/dev/null 2>&1 || fail "the tripwire run did not link $arch ELF"
done
if [ -s "$tripwire_log" ]; then
  fail "a host tool ran while linking: $(cat "$tripwire_log")"
else
  echo "   the log is empty after linking under the shims"
fi

if [ "$darwin" -eq 1 ]; then
  echo "== 8. mutation proofs"
  # The broken signature is refused by codesign; the binary is not executed,
  # because a program with a bad page hash can hang in the kernel where
  # alarm cannot reach it.
  check_page_hash() {
    "$work/bin/link_macho$EXE" hello "$(native_path "$work/hello-page")" >/dev/null 2>&1 || return 1
    /usr/bin/codesign -v --strict "$work/hello-page" >/dev/null 2>&1
  }
  prove_mutation "hash one CodeDirectory page wrong" "$codesign_src" \
    "    digest = SHA256.digest(image[start.to_i32, count.to_i32])" \
    "    digest = SHA256.digest(image[start.to_i32, count.to_i32])
    if page == 0_i64
      digest[0] = digest[0] ^ 1_u8
    end" \
    check_page_hash

  check_wrong_ordinal() {
    check_hello
  }
  prove_mutation "bind one import to the wrong library ordinal" "$imports_src" \
    "LIBSYSTEM_ORDINAL = 1_i64" "LIBSYSTEM_ORDINAL = 2_i64" \
    check_wrong_ordinal

  check_drop_rebase() {
    check_corpus
  }
  prove_mutation "drop the rebase of one absolute pointer" "$link_src" \
    "    @exe.rebases << p # rebase: dyld slides this pointer by the load slide" \
    "    # the rebase of this pointer is dropped" \
    check_drop_rebase

  check_ignore_addend() {
    check_corpus
  }
  prove_mutation "ignore Reloc#addend for absolute pointers" "$link_src" \
    "      patch_abs64(dst_out, off, code, r.addend)" \
    "      patch_abs64(dst_out, off, code, 0_i64)" \
    check_ignore_addend
  cp "$work/bin/link_macho.good$EXE" "$work/bin/link_macho$EXE"
else
  host_limited "Mach-O mutation execution and signature checks require macOS"
fi

[ ! -e "$NATIVE_SIGNATURE_FAILURE_FILE" ] || fail "a native executable failed signature verification"
if [ "$failures" -eq 0 ] && [ "$HOST_ID" = linux-x86_64 ] && [ -n "${SELFHOST_ARTIFACT_DIR:-}" ]; then
  if ! mkdir -p "$SELFHOST_ARTIFACT_DIR" ||
     ! cp "$work/elf-aarch64" "$SELFHOST_ARTIFACT_DIR/elf-aarch64" ||
     ! cp "$work/elf-aarch64.json" "$SELFHOST_ARTIFACT_DIR/elf-aarch64.json"; then
    fail "could not export the exact AArch64 ELF and provenance"
  else
    echo "   exported AArch64 ELF and provenance to $SELFHOST_ARTIFACT_DIR"
  fi
fi
if [ "$failures" -eq 0 ]; then
  echo "== ALL NATIVE_LINK CHECKS PASSED"
  exit 0
fi
echo "== SOME NATIVE_LINK CHECKS FAILED"
exit 1
