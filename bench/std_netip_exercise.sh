#!/usr/bin/env bash
# Exercises `std/netip`: IP addresses and prefixes as values, against
# Python's `ipaddress` as the oracle over a generated corpus - every
# address, prefix, containment, overlap, subnet list, sort and prefix set
# answered the same, every text one refuses refused by the other - and
# with broken copies of the module proving the checks can fail.
#
#     bash bench/std_netip_exercise.sh
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

# The oracle and the negative proofs are python, and a machine can answer
# `python3` with a store stub that prints a refusal instead of running, so
# the interpreter is resolved once and proven to run before it is trusted.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import ipaddress' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"
export PYTHONIOENCODING=utf-8

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_netip_exercise.iyi" \
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

echo "== the std/netip exercise, plain build"
build_and_run "plain" netip-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/netip-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every netip section reported"
for phrase in "== rfc 4291 text forms" "== rfc 5952 canonical text" "== refused as a value" "== order, next and prev" \
              "== iana special-purpose registries" "== prefixes" "== subnets and supernets" "== prefix sets" "== allocation"; do
  if ! grep -qx -- "$phrase" "$WORK/netip-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
# An optimised build is where an aligned load of a misaligned `UInt128`
# faulted: 65,536 subnets in an array, read back, were SIGSEGV here and
# nowhere in the plain build.
build_and_run "release" netip-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/netip-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== std/netip reaches nothing"
# What it imports, and what those import, declare no C and call no
# runtime hook: a program that only decides about addresses reaches no
# socket, clock, entropy or file.
reached="std/netip"
todo="std/netip"
while [ -n "$todo" ]; do
  next=""
  for module in $todo; do
    for imported in $(sed -n 's/^import \(std\/[a-z_]*\).*/\1/p' "$REPO/src/$module.iyi"); do
      case " $reached " in
        *" $imported "*) ;;
        *) reached="$reached $imported"; next="$next $imported" ;;
      esac
    done
  done
  todo="$next"
done
bound=""
for module in $reached; do
  if grep -nE '^\s*(lib [A-Z]|fun [a-z_]|asm\(|@\[Link)|__iyi_' "$REPO/src/$module.iyi" >/dev/null; then
    bound="$bound $module"
  fi
done
if [ -n "$bound" ]; then
  echo "  FAIL: std/netip reaches the platform through:$bound"
  status=1
else
  echo "  std/netip imports$(echo " $reached" | sed 's/ std\/netip//'), and none of it calls C"
fi

# The corpus: Python writes it and its own answers, one line each; one iyi
# program reads the corpus on stdin and answers every line. Built against
# SEARCH, which is the module under test unless a proof below points it at
# a broken copy.
cat >"$WORK/oracle.py" <<'PY'
import ipaddress as I, os, random, sys

work = sys.argv[1]
rng = random.Random(20261017)
V4, V6 = I.IPv4Address, I.IPv6Address
RFC1918 = [I.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")]
ULA = I.ip_network("fc00::/7")


def private(a):
    a = a.ipv4_mapped or a if a.version == 6 else a
    return any(a in n for n in RFC1918) if a.version == 4 else a in ULA


def scopeless(a):
    return V6(int(a)) if a.version == 6 else a


def show(a):
    return "-" if a is None else str(a)


def step(a, by):
    n = int(a) + by
    if n < 0 or n > (1 << a.max_prefixlen) - 1:
        return None
    b = type(a)(n)
    return V6(f"{b}%{a.scope_id}") if a.version == 6 and a.scope_id else b


def describe_ip(a):
    bare = scopeless(a)
    # Python raises on `exploded` and `reverse_pointer` of a zoned address;
    # the module keeps the zone in the one and leaves it out of the other.
    exploded = bare.exploded + (f"%{a.scope_id}" if a.version == 6 and a.scope_id else "")
    flags = [a.is_loopback, a.is_unspecified, a.is_link_local, a.is_multicast, a.is_reserved,
             a.version == 6 and a.is_site_local, private(a), a.is_global]
    mapped = a.ipv4_mapped if a.version == 6 else None
    return "|".join([str(a), exploded, bare.reverse_pointer, str(a.version), "".join("1" if f else "0" for f in flags),
                     show(step(a, 1)), show(step(a, -1)), show(mapped), str(mapped or a),
                     (a.scope_id or "-") if a.version == 6 else "-", a.packed.hex(), "rt"])


def accepts(cls, text):
    try:
        cls(text)
        return "1"
    except ValueError:
        return "0"


def answer_ip(text):
    tail = accepts(V4, text) + accepts(V6, text)
    try:
        a = I.ip_address(text)
    except ValueError:
        return "refused " + tail
    return describe_ip(a) + "|" + tail


def net(text, strict=True):
    # A zone in a prefix is refused here, kept by Python: the one known
    # difference, checked on its own below.
    if "%" in text:
        raise ValueError("zoned")
    return I.ip_network(text, strict=strict)


def answer_prefix(text, strict):
    try:
        n = net(text, strict)
    except ValueError:
        return "refused"
    return "|".join([str(n), str(n.network_address), str(n.broadcast_address), str(n.netmask), str(n.hostmask),
                     str(n.prefixlen), str(n.supernet()), "1"])


def rand_v4(blocks=True):
    r = rng.random()
    if blocks and r < 0.5:
        n = rng.choice(V4_BLOCKS)
        span = n.num_addresses
        pick = rng.choice([0, span - 1, -1, span, rng.randrange(span)])
        return V4((int(n.network_address) + pick) % (1 << 32))
    return V4(rng.getrandbits(32))


def rand_v6(blocks=True):
    r = rng.random()
    if blocks and r < 0.4:
        n = rng.choice(V6_BLOCKS)
        span = n.num_addresses
        pick = rng.choice([0, span - 1, -1, span, rng.randrange(span)])
        return V6((int(n.network_address) + pick) % (1 << 128))
    if r < 0.5:
        return V6((0xFFFF << 32) | int(rand_v4()))
    groups = [rng.getrandbits(16) for _ in range(8)]
    for _ in range(rng.randrange(4)):
        at = rng.randrange(8)
        for k in range(at, min(8, at + rng.randrange(1, 6))):
            groups[k] = 0
    return V6(int.from_bytes(b"".join(g.to_bytes(2, "big") for g in groups), "big"))


def written_v6(a):
    """One of the many texts of *a*: case, leading zeros, any zero run
    as `::`, a dotted tail, a zone."""
    groups = [(int(a) >> (112 - 16 * i)) & 0xFFFF for i in range(8)]
    tail = None
    if rng.random() < 0.2:
        tail = str(V4(int(a) & 0xFFFFFFFF))
        groups = groups[:6]
    words = []
    for g in groups:
        w = "%x" % g
        if rng.random() < 0.2:
            w = w.rjust(rng.randrange(len(w), 5), "0")
        if rng.random() < 0.3:
            w = w.upper()
        words.append(w)
    runs = [(i, j) for i in range(len(groups)) for j in range(i + 1, len(groups) + 1) if all(g == 0 for g in groups[i:j])]
    if runs and rng.random() < 0.8:
        i, j = rng.choice(runs)
        head, rest = words[:i], words[j:]
        if tail is not None:
            rest = rest + [tail]
        text = ":".join(head) + "::" + ":".join(rest)
    else:
        text = ":".join(words + ([tail] if tail is not None else []))
    if rng.random() < 0.1:
        text += "%" + rng.choice(["eth0", "1", "en0", "lo", "a b", "ü"])
    return text


ALPHABET = "0123456789abcdefABCDEF:.%/ xg-+٣ａ"


def mutate(text):
    chars = list(text)
    for _ in range(rng.randrange(1, 3)):
        r = rng.random()
        at = rng.randrange(len(chars) + 1)
        if r < 0.35:
            chars.insert(at, rng.choice(ALPHABET))
        elif r < 0.65 and chars:
            del chars[min(at, len(chars) - 1)]
        elif chars:
            chars[min(at, len(chars) - 1)] = rng.choice(ALPHABET)
    return "".join(chars)


V4_BLOCKS = [I.ip_network(n) for n in [
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24",
    "192.0.0.0/29", "192.0.0.8/32", "192.0.0.9/32", "192.0.0.10/32", "192.0.0.170/31", "192.0.2.0/24",
    "192.31.196.0/24", "192.52.193.0/24", "192.88.99.0/24", "192.168.0.0/16", "192.175.48.0/24", "198.18.0.0/15",
    "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4", "255.255.255.255/32"]]
V6_BLOCKS = [I.ip_network(n) for n in [
    "::1/128", "::/128", "::ffff:0:0/96", "64:ff9b::/96", "64:ff9b:1::/48", "100::/64", "2001::/23", "2001::/32",
    "2001:1::1/128", "2001:1::2/128", "2001:1::3/128", "2001:2::/48", "2001:3::/32", "2001:4:112::/48",
    "2001:10::/28", "2001:20::/28", "2001:30::/28", "2001:db8::/32", "2002::/16", "2620:4f:8000::/48", "3fff::/20",
    "5f00::/16", "fc00::/7", "fe80::/10", "fec0::/10", "ff00::/8", "::/8", "100::/8", "200::/7", "400::/6",
    "800::/5", "1000::/4", "4000::/3", "6000::/3", "8000::/3", "a000::/3", "c000::/3", "e000::/4", "f000::/5",
    "f800::/6", "fe00::/9"]]

EDGES = [
    "", " ", ".", ":", "::", ":::", "::1", "1::", "::1.2.3.4", "::ffff:1.2.3.4", "::FFFF:1.2.3.4", "0.0.0.0",
    "255.255.255.255", "256.0.0.0", "1.2.3", "1.2.3.4.5", "1.2.3.4.", ".1.2.3.4", "01.2.3.4", "1.2.3.04", "0.0.0.00",
    "1.2.3.0004", "127.1", "0x7f.0.0.1", "1.2.3.4 ", " 1.2.3.4", "1.2.3.4/32", "1.2.3.4%eth0", "١.2.3.4",
    "1:2:3:4:5:6:7:8", "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7::", "::2:3:4:5:6:7:8",
    "1::3:4:5:6:7:8", "1:2:3:4::5:6:7:8", ":1:2:3:4:5:6:7", "1:2:3:4:5:6:7:", ":1::2", "1::2:", "1::2::3",
    "12345::", "01234::", "0001:0002::", "g::", "fe80::1%", "fe80::1%%", "fe80::1%a%b", "fe80::1%eth0",
    "fe80::1%eth0/64", "%eth0", "::%eth0", "1:2:3:4:5:6:1.2.3.4", "1:2:3:4:5:6:7:1.2.3.4", "1:2:3:4:5::1.2.3.4",
    "::1.2.3", "::1.2.3.256", "::01.2.3.4", "1.2.3.4::", "::1.2.3.4:5", "0:0:0:0:0:0:0:0", "0:0:0:0:0:0:0:1",
    "1:0:0:2:0:0:0:3", "1:0:0:0:2:0:0:3", "2001:db8:0:0:1:0:0:1", "0000:0000:0000:0000:0000:0000:0000:00001",
    "1111:2222:3333:4444:5555:6666:123.123.123.123", "1111:2222:3333:4444:5555:6666:7777:123.123.123.123",
    "a" * 46, "0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0", "::ffff:255.255.255.255", "ffff:" * 7 + "ffff",
    "::ffff:0:0", "::fffe:1.2.3.4", "2001:0db8:0000:0000:0000:0000:0000:0001%1", "fe80::%0",
]

lines, want = [], []


def emit(line, answer):
    lines.append(line)
    want.append(answer)


addresses = list(EDGES)
for n in V4_BLOCKS:
    for a in (n.network_address, n.broadcast_address):
        for d in (-1, 0, 1):
            addresses.append(str(V4((int(a) + d) % (1 << 32))))
for n in V6_BLOCKS:
    for a in (n.network_address, n.broadcast_address):
        for d in (-1, 0, 1):
            addresses.append(str(V6((int(a) + d) % (1 << 128))))
for _ in range(6000):
    addresses.append(str(rand_v4()))
for _ in range(9000):
    addresses.append(written_v6(rand_v6()))
for _ in range(9000):
    addresses.append(mutate(rng.choice(addresses[: len(EDGES) + 15000])))
for text in addresses:
    emit(f"A\t{text}", answer_ip(text))

prefixes = []
for _ in range(1500):
    a = rand_v4()
    for length in [rng.randrange(33) for _ in range(3)] + [0, 32]:
        prefixes.append(f"{a}/{length}")
        prefixes.append(f"{I.ip_network((a, length), strict=False)}")
for _ in range(1500):
    a = rand_v6()
    for length in [rng.randrange(129) for _ in range(3)] + [0, 128]:
        prefixes.append(f"{a}/{length}")
        prefixes.append(f"{I.ip_network((a, length), strict=False)}")
# Every length of both families, on an address whose bits are all set.
for length in range(33):
    prefixes += [f"255.255.255.255/{length}", f"{I.ip_network(('255.255.255.255', length), strict=False)}"]
for length in range(129):
    prefixes += [f"ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff/{length}",
                 f"{I.ip_network(('ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff', length), strict=False)}"]
for length in range(33):
    mask = I.IPv4Network(f"0.0.0.0/{length}").netmask
    prefixes += [f"10.0.0.0/{mask}", f"10.0.0.0/{I.IPv4Address(int(mask) ^ 0xFFFFFFFF)}"]
prefixes += ["10.0.0.0/255.0.255.0", "10.0.0.0/0.255.0.255", "10.0.0.0/024", "10.0.0.0/0008", "::/0128", "::/129",
             "1.2.3.0/33", "1.2.3.0/", "1.2.3.0/ 24", "1.2.3.0/+24", "1.2.3.0/-1", "1.2.3.0/24/24", "/24", "1.2.3.0/٢٤",
             "10.0.0.0/255.255.255.256", "10.0.0.0/255.255.255.0255", "::/ffff::", "1.2.3.4", "::1", "2001:db8::/32",
             "2001:0DB8:0000:CD30:0000:0000:0000:0000/60", "2001:0DB8::CD30:0:0:0:0/60", "2001:0DB8:0:CD30::/60",
             "2001:0DB8:0:CD3/60", "2001:0DB8::CD30/60", "2001:0DB8::CD3/60", "::ffff:1.2.3.0/120",
             "10.0.0.0/" + "0" * 50 + "8", "10.0.0.0/" + "9" * 50]
for _ in range(4000):
    prefixes.append(mutate(rng.choice(prefixes)))
for text in prefixes:
    emit(f"P\t{text}", answer_prefix(text, True))
    emit(f"M\t{text}", answer_prefix(text, False))

# Containment and overlap: prefixes drawn near each other, so that they
# nest, touch and miss in about equal measure.
def near_prefix(v6):
    if v6:
        base = rng.choice([0x20010DB8 << 96, 0xFE80 << 112, 0xFFFF << 32])
        a = base | rng.getrandbits(40) << rng.choice([0, 40, 56])
        return I.ip_network((a & ((1 << 128) - 1), rng.randrange(80, 129)), strict=False)
    a = (10 << 24) | rng.getrandbits(rng.choice([8, 16, 24]))
    return I.ip_network((a, rng.randrange(0, 33)), strict=False)


for _ in range(6000):
    v6 = rng.random() < 0.5
    p, q = near_prefix(v6), near_prefix(v6)
    a = V6(int(q.network_address) + rng.randrange(q.num_addresses)) if v6 else V4(int(q.network_address) + rng.randrange(q.num_addresses))
    emit(f"C\t{p}\t{a}", "1" if a in p else "0")
    order = 0 if p == q else (-1 if p < q else 1)
    emit(f"O\t{p}\t{q}", "".join("1" if x else "0" for x in (p.overlaps(q), p.supernet_of(q), p.subnet_of(q), q.overlaps(p))) + str(order + 1))
# Across families: never contained, never overlapping, IPv4 first.
for _ in range(200):
    p, q = near_prefix(False), near_prefix(True)
    emit(f"C\t{p}\t{q.network_address}", "0")
    emit(f"C\t{q}\t{p.network_address}", "0")
    emit(f"O\t{p}\t{q}", "00000")

for _ in range(600):
    v6 = rng.random() < 0.5
    bits = 128 if v6 else 32
    length = rng.randrange(bits + 1)
    p = I.ip_network(((rand_v6() if v6 else rand_v4()), length), strict=False)
    m = rng.randrange(length, min(bits, length + 6) + 1)
    emit(f"S\t{p}\t{m}", " ".join(str(s) for s in p.subnets(new_prefix=m)))
    s = rng.randrange(0, length + 1)
    emit(f"U\t{p}\t{s}", str(p.supernet(new_prefix=s)) if length > 0 else str(p))
    m = rng.randrange(length, bits + 1)
    index = rng.randrange(1 << (m - length))
    emit(f"X\t{p}\t{m}\t{index}", str(I.ip_network((int(p.network_address) + (index << (bits - m)), m))))

for _ in range(300):
    pool = [str(rand_v4()) for _ in range(rng.randrange(1, 20))] + [str(rand_v6()) for _ in range(rng.randrange(0, 20))]
    emit("R\t" + ",".join(pool), ",".join(str(a) for a in sorted((I.ip_address(t) for t in pool), key=I.get_mixed_type_key)))


def longest(nets, a):
    best = None
    for n in nets:
        if n.version == a.version and a in n and (best is None or n.prefixlen > best.prefixlen):
            best = n
    return "-" if best is None else str(best)


def collapse(nets):
    return [str(n) for v in (4, 6) for n in I.collapse_addresses([n for n in nets if n.version == v])]


for _ in range(200):
    nets = []
    for _ in range(rng.randrange(0, 60)):
        v6 = rng.random() < 0.3
        if v6:
            a = (0x20010DB8 << 96) | (rng.getrandbits(16) << 80)
            nets.append(I.ip_network((a, rng.randrange(28, 49)), strict=False))
        else:
            a = (10 << 24) | rng.getrandbits(16) << 8
            nets.append(I.ip_network((a, rng.choice([0, 7, 8] + list(range(9, 25)))), strict=False))
    written = [str(n) for n in nets]
    probes = [str(V4((10 << 24) | rng.getrandbits(24))) for _ in range(30)] + [str(rand_v4()) for _ in range(5)] + \
             [str(V6((0x20010DB8 << 96) | (rng.getrandbits(20) << 76))) for _ in range(15)] + [str(rand_v6()) for _ in range(3)]
    gone = rng.sample(written, len(written) // 3) if written else []
    unique = sorted(set(nets), key=I.get_mixed_type_key)
    rest = [n for n in unique if str(n) not in gone]
    probe_ips = [I.ip_address(p) for p in probes]
    answer = [str(len(unique)), ",".join(longest(unique, a) for a in probe_ips), ",".join(str(n) for n in unique),
              ",".join(collapse(unique)), str(len(rest)), ",".join(longest(rest, a) for a in probe_ips), ",".join(collapse(rest))]
    emit("T\t" + ",".join(written) + "\t" + ",".join(probes) + "\t" + ",".join(gone), "|".join(answer))

with open(os.path.join(work, "corpus.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
with open(os.path.join(work, "expected.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(want) + "\n")
counts = {}
for line in lines:
    counts[line[0]] = counts.get(line[0], 0) + 1
accepted = sum(1 for line, w in zip(lines, want) if line[0] == "A" and not w.startswith("refused"))
print(f"  {counts['A']} addresses ({accepted} valid), {counts['P']} prefixes each strict and masked, "
      f"{counts['C']} containments, {counts['O']} overlaps, {counts['S']} subnet lists, {counts['R']} sorts, "
      f"{counts['T']} prefix sets")
PY
cat >"$WORK/driver.iyi" <<'IYI'
module netip_corpus

import std/netip::{IP, Prefix, PrefixSet, NetipError}
import std/int

def flag(value : Bool) : String
  value ? "1" : "0"
end

def opt(value : IP?) : String
  value ? value.to_s : "-"
end

def hex(bytes : Array(UInt8)) : String
  String.build { |io| bytes.each { |byte| io << byte.to_i32.to_s(16).rjust(2, '0') } }
end

def ip_of(text : String) : IP
  IP.parse(text).or_panic
end

def prefix_of(text : String) : Prefix
  Prefix.parse(text).or_panic
end

def u128_of(text : String) : UInt128
  value = 0_u128
  text.each_char { |ch| value = value * 10_u128 + (ch.ord - 48).to_u128 }
  value
end

def list(text : String) : Array(String)
  text.empty? ? [] of String : text.split(',')
end

def lookups(set : PrefixSet, addresses : Array(String)) : String
  addresses.map do |text|
    found = set.lookup(ip_of(text))
    found ? found.to_s : "-"
  end.join(",")
end

def describe(a : IP) : String
  flags = flag(a.loopback?) + flag(a.unspecified?) + flag(a.link_local?) + flag(a.multicast?) +
          flag(a.reserved?) + flag(a.site_local?) + flag(a.private?) + flag(a.global?)
  back = IP.parse(a.to_s)
  round = back.is_a?(IP) && back == a && (back <=> a) == 0 && back.hash == a.hash ? "rt" : "RT!"
  [a.to_s, a.exploded, a.reverse_pointer, a.v6? ? "6" : "4", flags, opt(a.next), opt(a.prev),
   opt(a.ipv4_mapped), a.unmap.to_s, a.zone || "-", hex(a.bytes), round].join("|")
end

def describe(p : Prefix) : String
  [p.to_s, p.first.to_s, p.last.to_s, p.netmask.to_s, p.hostmask.to_s, p.length.to_s,
   p.supernet.to_s, flag(p.masked == p)].join("|")
end

while line = STDIN.gets(chomp: true)
  fields = line.split('\t')
  case fields[0]
  when "A"
    a = IP.parse(fields[1])
    four = flag(IP.parse_v4(fields[1]).is_a?(IP))
    six = flag(IP.parse_v6(fields[1]).is_a?(IP))
    puts a.is_a?(NetipError) ? "refused #{four}#{six}" : "#{describe(a)}|#{four}#{six}"
  when "P", "M"
    p = Prefix.parse(fields[1], mask: fields[0] == "M")
    puts p.is_a?(NetipError) ? "refused" : describe(p)
  when "C"
    puts flag(prefix_of(fields[1]).contains?(ip_of(fields[2])))
  when "O"
    a = prefix_of(fields[1])
    b = prefix_of(fields[2])
    puts flag(a.overlaps?(b)) + flag(a.contains?(b)) + flag(a.subnet_of?(b)) + flag(b.overlaps?(a)) + ((a <=> b) + 1).to_s
  when "S"
    puts prefix_of(fields[1]).subnets(fields[2].to_i).map { |s| s.to_s }.join(" ")
  when "U"
    puts prefix_of(fields[1]).supernet(fields[2].to_i)
  when "X"
    puts prefix_of(fields[1]).subnet(fields[2].to_i, u128_of(fields[3]))
  when "R"
    puts list(fields[1]).map { |text| ip_of(text) }.sorted.map { |a| a.to_s }.join(",")
  when "T"
    set = PrefixSet.new
    list(fields[1]).each { |text| set.add(Prefix.parse(text, mask: true).or_panic) }
    probes = list(fields[2])
    answer = [set.size.to_s, lookups(set, probes), set.prefixes.map { |p| p.to_s }.join(","), set.collapsed.map { |p| p.to_s }.join(",")]
    list(fields[3]).each { |text| set.delete(Prefix.parse(text, mask: true).or_panic) }
    answer << set.size.to_s
    answer << lookups(set, probes)
    answer << set.collapsed.map { |p| p.to_s }.join(",")
    puts answer.join("|")
  else
    puts "unknown #{fields[0]}"
  end
end
IYI

SEARCH="$IYI_PATH"
# corpus <name>: builds the driver against SEARCH, answers the corpus, and
# compares with Python's answers; prints the first lines that differ.
corpus() {
  local name="$1"
  if ! IYI_PATH="$SEARCH" "$IYI" build -o "$WORK/$name" "$WORK/driver.iyi" >"$WORK/$name.build.log" 2>&1; then
    echo "  the corpus program did not build: $(grep -m1 -E 'Error|BUG' "$WORK/$name.build.log")"
    return 2
  fi
  "$WORK/$name" <"$WORK/corpus.txt" >"$WORK/$name.got" 2>&1
  "$PY" - "$WORK/corpus.txt" "$WORK/expected.txt" "$WORK/$name.got" <<'PY'
import sys
lines, want, got = (open(p, encoding="utf-8").read().splitlines() for p in sys.argv[1:])
bad = [i for i in range(len(want)) if i >= len(got) or got[i] != want[i]]
for i in bad[:8]:
    print(f"  {lines[i][:100]!r}\n    python {want[i][:160]!r}\n    iyi    {(got[i] if i < len(got) else '<nothing>')[:160]!r}")
if bad:
    print(f"  the corpus disagrees: {len(bad)} of {len(want)} answers differ from python's")
    sys.exit(1)
print(f"  all {len(want)} answers are python's")
PY
}

echo
echo "== against python's ipaddress"
# 24,000 addresses: both ends of every IANA special-purpose block and the
# addresses either side of them, random IPv4, random IPv6 written every
# way RFC 4291 allows (case, leading zeros, any run of zeros as `::`, a
# dotted tail, a zone), the edge cases, and 9,000 texts made by inserting,
# deleting or replacing a character of those - each with its text,
# exploded and reverse-pointer forms, family, all eight predicates, next,
# prev, the mapped address, zone and bytes, and whether parse_v4 and
# parse_v6 alone accept it. 34,000 prefixes, every length of both families
# among them, netmasks and hostmasks of every length, and their mutations,
# read strictly and with mask: true. 6,400 containments and 6,200 overlaps
# of prefixes drawn near each other, both families and across them; 600
# subnet lists, supernets and indexed subnets; 300 mixed-family sorts; 200
# prefix sets of up to 60 prefixes, with longest matches for 53 addresses,
# the set in order, collapsed, and all of it again after a third deleted.
if [ -z "$PY" ]; then
  echo "  no python3 with ipaddress on this machine, so the corpus goes uncompared"
  status=1
elif ! "$PY" "$WORK/oracle.py" "$WORK"; then
  echo "  the oracle did not run"
  status=1
elif ! corpus corpus-module; then
  status=1
fi

echo
echo "== where this module and python differ, by design"
# Each difference the module's header names, checked on both sides, so a
# Python that changes its answer shows here.
if [ -n "$PY" ]; then
  cat >"$WORK/differ.iyi" <<'IYI'
module differ

import std/netip::{IP, Prefix, NetipError}

zoned = Prefix.parse("fe80::%eth0/64")
puts zoned.is_a?(NetipError) ? "refused" : zoned.to_s
puts IP.parse("fe80::1%eth0").or_panic.exploded
puts IP.parse("fe80::1%eth0").or_panic.reverse_pointer
last = IP.parse("255.255.255.255").or_panic.next
puts last ? last.to_s : "nil"
puts (IP.parse("fe80::1%eth0").or_panic.next || IP.parse("::").or_panic).to_s
IYI
  if ! "$IYI" run "$WORK/differ.iyi" >"$WORK/differ.out" 2>&1; then
    echo "  the differences program did not run: $(tail -1 "$WORK/differ.out")"
    status=1
  elif ! "$PY" - "$WORK/differ.out" <<'PY'
import ipaddress as I, sys
got = open(sys.argv[1], encoding="utf-8").read().splitlines()
def raises(f):
    try:
        f()
        return False
    except ValueError:
        return True
cases = [
    ("a zone in a prefix", "refused", str(I.ip_network("fe80::%eth0/64")) == "fe80::%eth0/64"),
    ("exploded of a zoned address", "fe80:0000:0000:0000:0000:0000:0000:0001%eth0", raises(lambda: I.ip_address("fe80::1%eth0").exploded)),
    ("reverse_pointer of a zoned address", I.ip_address("fe80::1").reverse_pointer, raises(lambda: I.ip_address("fe80::1%eth0").reverse_pointer)),
    ("next past the last address", "nil", raises(lambda: I.ip_address("255.255.255.255") + 1)),
    ("next of a zoned address", "fe80::2%eth0", str(I.ip_address("fe80::1%eth0") + 1) == "fe80::2"),
]
bad = 0
for (what, mine, python_differs), line in zip(cases, got + [""] * len(cases)):
    if line != mine or not python_differs:
        print(f"  {what}: iyi {line!r} (expected {mine!r}); python still differs: {python_differs}")
        bad += 1
    else:
        print(f"  {what}: iyi {mine!r}, python otherwise")
sys.exit(1 if bad else 0)
PY
  then
    status=1
  fi

  # The registry table the exercise holds is Python's own answer.
  if ! "$PY" - "$REPO/bench/std_netip_exercise.iyi" <<'PY'
import ipaddress, re, sys
source = open(sys.argv[1], encoding="utf-8").read()
table = source[source.index("== iana special-purpose registries"):source.index("check ip(pair[0]).global? == pair[1]")]
rows = re.findall(r'\{"([^"]+)", (true|false)\}', table)
bad = [(a, g) for a, g in rows if ipaddress.ip_address(a).is_global != (g == "true")]
for a, g in bad:
    print(f"  the exercise says {a} is_global {g}; python says otherwise")
print(f"  the exercise's {len(rows)} registry rows are python's is_global")
sys.exit(1 if bad or len(rows) < 50 else 0)
PY
  then
    status=1
  fi
fi

echo
echo "== what the module refuses, by name"
# Malformed text is a NetipError value, checked by the exercise; what
# panics is the program's own mistake, and an error it chose to panic on
# (`or_panic`) panics with its sentence exactly.
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/netip::{IP, Prefix, PrefixSet}
import std/int

ten = Prefix.parse("10.0.0.0/8").or_panic
case Program.args[0]
when "bytes"
  IP.from_bytes([1_u8, 2_u8, 3_u8])
when "v4-zone"
  IP.v4(192_u8, 0_u8, 2_u8, 1_u8).with_zone("eth0")
when "zone-percent"
  IP.v6(1_u128).with_zone("a%b")
when "mapped-twice"
  IP.v6(1_u128).ipv6_mapped
when "long-length"
  IP.v4(192_u8, 0_u8, 2_u8, 1_u8).prefix(33)
when "negative-length"
  Prefix.new(IP.v6(1_u128), -1)
when "zoned-prefix"
  Prefix.new(IP.parse("fe80::1%eth0").or_panic, 64)
when "short-subnet"
  ten.subnets(4)
when "many-subnets"
  ten.subnets(32)
when "subnet-index"
  ten.subnet(10, 4_u128)
when "long-supernet"
  ten.supernet(9)
when "or-panic"
  IP.parse("1.2.3.256").or_panic
when "prefix-or-panic"
  Prefix.parse("10.0.0.1/8").or_panic
end
puts "accepted"
IYI
if ! "$IYI" build -o "$WORK/refuse" "$WORK/refuse.iyi" >"$WORK/refuse.build.log" 2>&1; then
  echo "  the refusal program did not build: $(grep -m1 -E 'Error|BUG' "$WORK/refuse.build.log")"
  status=1
fi
refuse() { # refuse <case> <phrase>
  if "$WORK/refuse" "$1" >"$WORK/refuse.out" 2>&1; then
    echo "  $1 was accepted: $(tr -d '\r' <"$WORK/refuse.out" | tail -1)"
    status=1
  elif ! grep -qxF -e "iyi: panic: $2" "$WORK/refuse.out"; then
    echo "  $1 was refused without saying why: $(tr -d '\r' <"$WORK/refuse.out" | head -1)"
    status=1
  else
    echo "  $1: $2"
  fi
}
refuse bytes "IP: 3 bytes are no address; IPv4 is 4 and IPv6 is 16"
refuse v4-zone "IP: 192.0.2.1 is IPv4, which has no zones"
refuse zone-percent "IP: the zone \"a%b\" holds a '%'"
refuse mapped-twice "IP: ::1 is IPv6 already; ipv6_mapped maps IPv4"
refuse long-length "Prefix: /33 for an IPv4 address; its length is 0 to 32"
refuse negative-length "Prefix: /-1 for an IPv6 address; its length is 0 to 128"
refuse zoned-prefix "Prefix: fe80::1%eth0 has a zone, and a prefix has none"
refuse short-subnet "Prefix: a subnet of 10.0.0.0/8 is /8 to /32, and /4 is not"
refuse many-subnets "Prefix: 10.0.0.0/8 into /32 is 2^24 subnets, past the 65536 subnets answers at once; subnet(new_length, index) reaches any one"
refuse subnet-index "Prefix: 10.0.0.0/8 has 2^2 subnets of /10, and 4 is past them"
refuse long-supernet "Prefix: a supernet of 10.0.0.0/8 is shorter, and /9 is not"
refuse or-panic "netip: \"1.2.3.256\" is not an IPv4 address: the octet 256 is past 255"
refuse prefix-or-panic "netip: \"10.0.0.1/8\" is not a prefix: host bits are set past /8; Prefix.parse(text, mask: true) clears them"
# An address is made by the module's readers and constructors, which
# check what they are given; the field-by-field constructor is the
# module's own.
printf 'module unchecked\n\nimport std/netip::{IP}\nimport std/int\n\nputs IP.new(value: 0x100000000_u128, v6: false, zone: "")\n' >"$WORK/unchecked.iyi"
if "$IYI" build -o "$WORK/unchecked" "$WORK/unchecked.iyi" >"$WORK/unchecked.log" 2>&1; then
  echo "  an IPv4 address of 33 bits was built"
  status=1
elif grep -qF "protected method 'new' called for Std::Netip::IP.class" "$WORK/unchecked.log"; then
  echo "  an unchecked IP.new: protected method 'new' called for Std::Netip::IP.class"
else
  echo "  an unchecked IP.new was refused for another reason: $(grep -m1 Error "$WORK/unchecked.log")"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <old> <new> [corpus]: the exercise (or,
# given `corpus`, the comparison with Python) must fail on a copy of the
# module with <old> replaced, at the check that names <phrase>.
mutations=0
prove_broken() {
  mutations=$((mutations + 1))
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $1 proof is unmeasured"
    status=1
    return
  fi
  if ! OLD="$3" NEW="$4" "$PY" - "$REPO/src/std/netip.iyi" "$WORK/patched/std/netip.iyi" <<'PY'
import os, sys
src = open(sys.argv[1], encoding="utf-8").read()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing: " + os.environ["OLD"])
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
    return
  fi
  local search="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi"
  if [ "${5:-}" = corpus ]; then
    SEARCH="$search" corpus "mut-$mutations" >"$WORK/mut.out" 2>&1
    local code=$?
    if [ "$code" -eq 2 ]; then
      echo "  the $1 copy did not compile"; sed -n '1,4p' "$WORK/mut.out"; status=1
    elif [ "$code" -eq 0 ]; then
      echo "  the corpus PASSED on $1"; status=1
    elif grep -qF "$2" "$WORK/mut.out"; then
      echo "  $1 is caught: $(grep -m1 -F "$2" "$WORK/mut.out" | sed 's/^ *//')"
    else
      echo "  $1 failed, but not where it should have:"; tail -2 "$WORK/mut.out" | sed 's/^/    /'; status=1
    fi
    return
  fi
  # Build first, then run: a patch that does not compile would also
  # "fail", and that proves nothing about whether the exercise catches it.
  if ! IYI_PATH="$search" "$IYI" build -o "$WORK/mut-$mutations" "$REPO/bench/std_netip_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the $1 copy did not compile"
    sed -n '1,6p' "$WORK/mut.out"
    status=1
  elif "$WORK/mut-$mutations" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on $1"
    status=1
  elif grep -qF "$2" "$WORK/mut.out"; then
    echo "  $1 is caught"
  else
    echo "  $1 failed, but not where it should have:"
    { grep -m2 -E 'panic|ASSERTION' "$WORK/mut.out" || tail -2 "$WORK/mut.out"; } | sed 's/^/    /'
    status=1
  fi
}
prove_broken "an octet with a leading zero read as decimal" "a leading zero in an octet is refused" \
  'if count > 1 && raw[start] == 48_u8' 'if false'
prove_broken "an octet of 256" "an octet past 255 is refused" \
  'if number > 255' 'if number > 256'
prove_broken "no limit of 45 characters" "more than 45 characters" \
  'if text.bytesize > 45' 'if text.bytesize > 46'
prove_broken "a second '::' taken" "two '::' are refused" \
  "return \"more than one '::'\" if skip >= 0" "return \"more than one '::'\" if false"
prove_broken "the last of two equal zero runs compressed" "rfc 5952 2.1: 2001:db8:0:0:1:0:0:1" \
  'if index - start + 1 > best_size' 'if index - start + 1 >= best_size'
prove_broken "a single zero group written ::" "rfc 5952 4.2.2: one zero group is not ::" \
  '    best_size = 1' '    best_size = 0'
prove_broken "a mapped address written in hex" "rfc 4291 2.2: 0:0:0:0:0:FFFF:129.144.52.38" \
  'text = if (to_u128 >> 32) == 0xFFFF_u128' 'text = if false'
prove_broken "the registry's global exceptions ignored" "192.0.0.9 is global" \
  ' || NetipBits.listed(v4, NetipBits::GLOBAL_V4, 32)' ''
prove_broken "shared address space taken as global" "100.64.0.1 is not global" \
  'return false if NetipBits.within(v4, 0x64400000_u128, 10, 32)' ''
prove_broken "RFC 9637's documentation block left out" "3fff::1 is not global" \
  '"3fff::/20",' ''
prove_broken "a mapped address classified by its IPv6 bits" "::ffff:8.8.8.8 is global" \
  'return to_u128 & 0xFFFFFFFF_u128 if (to_u128 >> 32) == 0xFFFF_u128' ''
prove_broken "host bits taken" "rfc 4291 2.3: 2001:0DB8::CD30/60 is not that prefix" \
  'Prefix.parse(text, mask: true) clears them") unless mask' 'Prefix.parse(text, mask: true) clears them") if false'
prove_broken "0.0.0.0 read as a hostmask" "0.0.0.0 as a mask is /0" \
  'return length if length >= 0' 'return length if length > 0'
prove_broken "containment across families" "an IPv4 address is in no IPv6 prefix" \
  'return false if ip.v6? != @ip.v6?' ''
prove_broken "overlap asked one way" "overlap is symmetric" \
  '(contains?(other.ip) || other.contains?(@ip))' 'contains?(other.ip)'
prove_broken "the first match taken, not the longest" "the longest prefix wins" \
  'best = depth if @member[node]' 'best = depth if @member[node] && best < 0'
prove_broken "halves never collapsed" "two halves collapse into their whole" \
  '(zero >= 0 && one >= 0 && full[zero] && full[one])' 'false'
prove_broken "next past the last address" "255.255.255.255 has no next" \
  'return nil if to_u128 == max_value' ''
prove_broken "a zone left out of ==" "a zone is part of an address's identity" \
  ' && @zone == (other.zone || "")' ''
# And the comparison with Python fails too, where the exercise's own
# vectors are not what catches it.
prove_broken "the IPv6 reserved table without fe00::/9" "the corpus disagrees" \
  '"f800::/6", "fe00::/9",' '"f800::/6",' corpus
prove_broken "a length with leading zeros refused, as Go refuses it" "the corpus disagrees" \
  'return number <= bits ? number : -1 if digits' 'return (number <= bits && (text.bytesize == 1 || raw[0] != 48_u8)) ? number : -1 if digits' corpus
prove_broken "a dotted tail allowed only after six groups" "the corpus disagrees" \
  'if find(tail, 46_u8, 0) >= 0' 'if find(tail, 46_u8, 0) >= 0 && parts.size == 7' corpus

echo
echo "== doc, format, other platforms and artifacts"
if "$IYI" doc "$REPO/src/std/netip.iyi" >"$WORK/doc.txt" 2>&1; then
  echo "  iyi doc reads std/netip ($(grep -c '^ *def ' "$WORK/doc.txt") methods)"
else
  echo "  iyi doc fails: $(grep -m1 -E 'Error|BUG' "$WORK/doc.txt")"
  status=1
fi
if [ -x "$REPO/bin/crystal" ]; then
  if "$IYI" fmt --check "$REPO/src/std/netip.iyi" "$REPO/bench/std_netip_exercise.iyi" >"$WORK/format.log" 2>&1; then
    echo "  the module and its exercise are formatted"
  else
    echo "  not formatted: $(grep -m1 produced "$WORK/format.log")"
    status=1
  fi
fi
apart=""
for target in x86_64-linux-gnu aarch64-darwin x86_64-windows-msvc aarch64-linux-gnu x86_64-linux-musl; do
  if ! "$IYI" build --no-codegen --target "$target" -o "$WORK/cross" "$REPO/bench/std_netip_exercise.iyi" >"$WORK/cross.log" 2>&1; then
    echo "  $target: $(grep -m1 -E 'Error|BUG' "$WORK/cross.log")"
    apart="$apart $target"
  fi
done
if [ -n "$apart" ]; then
  echo "  FAIL: the exercise does not typecheck for:$apart"
  status=1
else
  echo "  the exercise typechecks for x86_64-linux-gnu, aarch64-darwin, x86_64-windows-msvc, aarch64-linux-gnu, x86_64-linux-musl"
fi
mkdir -p "$WORK/r1/mods"
if (cd "$WORK/r1" && "$IYI" build --emit-iyimod mods -o from-source "$REPO/bench/std_netip_exercise.iyi" \
      && "$IYI" build --use-iyimod mods -o from-artifact "$REPO/bench/std_netip_exercise.iyi") >"$WORK/r1/build.log" 2>&1; then
  "$WORK/r1/from-source" >"$WORK/r1/source.out" 2>&1
  "$WORK/r1/from-artifact" >"$WORK/r1/artifact.out" 2>&1
  if cmp -s "$WORK/r1/source.out" "$WORK/r1/artifact.out" && grep -q "ALL CHECKS PASSED" "$WORK/r1/artifact.out"; then
    echo "  built from its artifacts, the exercise prints what it prints from source"
  else
    echo "  from its artifacts the exercise prints otherwise:"
    diff "$WORK/r1/source.out" "$WORK/r1/artifact.out" | sed -n '1,6p' | sed 's/^/    /'
    status=1
  fi
else
  echo "  the artifacts did not build: $(grep -m1 -E 'Error|BUG' "$WORK/r1/build.log")"
  status=1
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/netip exercise holds"
else
  echo "the std/netip exercise did not hold"
fi
exit $status
