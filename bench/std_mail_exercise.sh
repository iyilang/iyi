#!/usr/bin/env bash
# Exercises `std/mail`.
#
#     bash bench/std_mail_exercise.sh
#
# The exercise holds quoted-printable, base64, encoded-words, folding,
# addresses, dates and the MIME tree to RFC 2045, 2047, 2231 and 5322's
# own examples; this gate runs it plain and --release, has Python's
# `email` read 200 messages built here from random addresses, names,
# subjects, texts and attachments and hold every header, part and decoded
# payload to what they were built from, has this read 200 messages
# Python's `EmailMessage` builds under `policy.default` and `policy.SMTP`
# as Python reads them, holds the transfer encodings to `quopri`,
# `base64` and `email.quoprimime`, dates to `email.utils` and address
# lists to `email.headerregistry`, names what is refused with its
# sentence, and proves on broken copies of the module that the checks
# fail where they say.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# the patches and oracles below are written in python, and windows answers
# `python3` with a store stub that prints and exits rather than running it, so
# the interpreter is measured here instead of assumed.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_mail_exercise.iyi" \
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

echo "== the std/mail exercise, plain build"
build_and_run "plain" mail-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/mail-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every mail section reported"
for phrase in "== quoted-printable" "== base64" "== encoded-words" "== header folding" "== addresses" "== dates" "== building" "== reading"; do
  if ! grep -q "$phrase" "$WORK/mail-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" mail-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/mail-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

# The Python halves of the comparisons, written out once.
cat >"$WORK/gen_build.py" <<'PY'
import os, random, sys, json
work = sys.argv[1]
rng = random.Random(5322)
def h(s):
    if isinstance(s, str): s = s.encode("utf-8")
    return "x" + s.hex()
ascii_words = ["hello", "world", "Re:", "Fwd:", "meeting", "at", "noon", "report", "Q3", "a", "x" * 30, "(note)", "[tag]", "50%", "a=b", "C++", "e-mail", "dots...", "\"quoted\"", "semi;colon", "comma,", "under_score", "=?not?=", "tab\there"]
uni_words = ["Grüße", "Köln", "東京", "日本語", "😀", "naïve", "façade", "Ελληνικά", "Привет", "עברית", "€100", "ß", "ﬁ", "\u00a0nbsp"]
def phrase(n):
    out = []
    for _ in range(n):
        out.append(rng.choice(uni_words) if rng.random() < 0.35 else rng.choice(ascii_words))
    return rng.choice([" ", " ", " ", "  "]).join(out)
first = ["Ann", "Ääkkönen José Ελληνικά", "Bob", "Jörg", "Zoë", "José", "李", "Doe, John", "O'Brien", "Mary Smith", "\"JD\" Doe", "Dr. Who", "Ann (work)", "A\\B", "Ääkkönen", "=?x?="]
def name():
    r = rng.random()
    if r < 0.2: return ""
    if r < 0.85: return rng.choice(first) + ("" if rng.random() < 0.5 else " " + rng.choice(first))
    return " ".join(w for w in phrase(rng.randint(1, 4)).split() if w)
locals_ = ["ann", "bob.smith", "j_doe+tag", "x", "o'brien", "first.last", "\"john doe\"", "\"a@b\"", "user-1"]
domains = ["example.com", "example.org", "mail.example.net", "x.test", "[192.0.2.7]"]
def addr(utf8=False):
    if utf8 and rng.random() < 0.5:
        return rng.choice(["jörg", "用户", "zoë"]) + "@" + rng.choice(["bücher.example", "example.com"])
    return rng.choice(locals_) + "@" + rng.choice(domains)
def text():
    lines = []
    for _ in range(rng.randint(0, 12)):
        kind = rng.random()
        if kind < 0.1: lines.append("")
        elif kind < 0.2: lines.append("." + phrase(2))
        elif kind < 0.3: lines.append("From " + phrase(3))
        elif kind < 0.4: lines.append(phrase(rng.randint(15, 40)))
        elif kind < 0.5: lines.append(phrase(3) + "   ")
        elif kind < 0.55: lines.append("x" * rng.randint(70, 200))
        else: lines.append(phrase(rng.randint(1, 10)))
    sep = rng.choice(["\n", "\r\n"])
    return sep.join(lines) + (sep if rng.random() < 0.5 else "")
fnames = ["report.pdf", "data.csv", "image.png", "archive.tar.gz", "noext", "Grüße.txt", "東京の写真.jpg", "a b c.doc", "semi;colon.txt", "quote\"d.txt", "very long file name " * 5 + ".bin", "ünïcödé " * 8 + ".zip"]
spec = []
cases = []
for i in range(200):
    utf8 = i % 10 == 9
    lines = []
    c = {}
    n, a = name(), addr(utf8)
    lines.append(f"from {h(n)} {h(a)}"); c["from"] = [(n, a)]
    for field in ["to", "cc", "bcc", "reply"]:
        c[field] = []
        for _ in range(rng.randint(1 if field == "to" else 0, 3) if field != "reply" or rng.random() < 0.3 else 0):
            n, a = name(), addr(utf8)
            lines.append(f"{field} {h(n)} {h(a)}"); c[field].append((n, a))
    if rng.random() < 0.95:
        s = phrase(rng.randint(1, 25)).strip() if rng.random() < 0.9 else rng.choice(["", " lead", "trail ", "x" * 100])
        lines.append(f"subject {h(s)}"); c["subject"] = s
    t = rng.randint(-2208988800, 253402300799 - 86400 * 2)
    off = rng.randint(-1439, 1439)
    lines.append(f"date {t} {off}"); c["date"] = (t, off)
    if rng.random() < 0.8:
        mid = f"<{rng.getrandbits(40):x}.{i}@example.com>"
        lines.append(f"id {h(mid)}"); c["id"] = mid
    kind = rng.random()
    if kind < 0.8:
        t1 = text(); lines.append(f"text {h(t1)}"); c["text"] = t1
    if kind > 0.5:
        t2 = "<p>" + text() + "</p>"; lines.append(f"html {h(t2)}"); c["html"] = t2
    c["attach"] = []
    for _ in range(rng.choice([0, 0, 1, 2, 3])):
        fn = rng.choice(fnames)
        data = bytes(rng.getrandbits(8) for _ in range(rng.choice([0, 1, 2, 3, 57, 58, 1000, 5000])))
        ct = rng.choice([None, "application/octet-stream", "image/png", "text/csv"])
        lines.append(f"attach {h(fn)} {h(data)} {h(ct) if ct else '-'}"); c["attach"].append((fn, data.hex(), ct))
    if rng.random() < 0.3:
        v = phrase(rng.randint(1, 12)).strip()
        lines.append(f"header {h('X-Note')} {h(v)}"); c["xnote"] = v
    lines.append("end")
    spec.extend(lines); cases.append(c)
open(os.path.join(work, "spec.txt"), "w", encoding="utf-8", newline="\n").write("\n".join(spec) + "\n")
json.dump(cases, open(os.path.join(work, "cases.json"), "w"))
PY
cat >"$WORK/check_build.py" <<'PY'
import email, email.policy, json, os, sys, datetime as dt
from email.utils import parsedate_to_datetime, format_datetime
from email.headerregistry import Address
work = sys.argv[1]
cases = json.load(open(os.path.join(work, "cases.json")))
said = open(os.path.join(work, "built.txt"), encoding="utf-8").read().splitlines()
bad = []
SAFE = set(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!*+-/ ")
def long(name):
    # Whether *name* is too long for one encoded-word: 63 bytes of text.
    data = name.encode("utf-8")
    q = sum(1 if c in SAFE else 3 for c in data)
    return min(q, (len(data) + 2) // 3 * 4) > 63
long_names = [0]
def norm(t): return t.replace("\r\n", "\n").replace("\r", "\n")
def spec(a):
    # The addr-spec as Python's Address writes it from its parts.
    return Address(username="x", domain="y")
for i, c in enumerate(cases):
    raw = open(os.path.join(work, "built", f"{i}.eml"), "rb").read()
    problems = []
    lines = raw.split(b"\r\n")
    if b"\n" in raw.replace(b"\r\n", b"") or b"\r" in raw.replace(b"\r\n", b""):
        problems.append("a line break that is not CRLF")
    utf8 = any(ord(ch) > 127 for ch in "".join(a for _, a in c["from"] + c["to"] + c["cc"] + c["bcc"] + c["reply"]))
    if not utf8:
        if any(b > 127 for b in raw): problems.append("a byte past ASCII")
    for line in lines:
        if len(line) > 78 and not utf8: problems.append(f"a line of {len(line)}: {line[:80]!r}")
    m = email.message_from_bytes(raw, policy=email.policy.default)
    def addrs(field):
        h = m[field]
        # Python reads a header's bytes as ASCII with surrogates for the
        # rest, RFC 6532's UTF-8 among them.
        fix = lambda s: s.encode("utf-8", "surrogateescape").decode("utf-8")
        return [] if h is None else [(fix(a.display_name), fix(a.addr_spec)) for a in h.addresses]
    def want(field):
        out = []
        for n, a in c[field]:
            local, _, domain = a.rpartition("@")
            if local.startswith('"'): local = local[1:-1].replace('\\"', '"')
            out.append((n, Address(username=local, domain=domain).addr_spec))
        return out
    for field, key in [("From", "from"), ("To", "to"), ("Cc", "cc"), ("Reply-To", "reply")]:
        got, given = addrs(field), want(key)
        if got != given and len(got) == len(given):
            # Python's email reads a space into the gap between two
            # encoded-words of a phrase (its own long names come back with
            # one too), where RFC 2047 section 6.2 drops it: a name too
            # long for one encoded-word is held to its text without spaces.
            split = [(g[0].replace(" ", ""), g[1]) == (w[0].replace(" ", ""), w[1]) and g[0] != w[0] and long(w[0]) for g, w in zip(got, given)]
            if all(s or g == w for s, g, w in zip(split, got, given)) and any(split):
                long_names[0] += sum(split)
                got = given
        if got != given: problems.append(f"{field}: python read {got}, given {given}")
    if m["Bcc"] is not None or b"\nbcc:" in b"\n" + raw.split(b"\r\n\r\n")[0].lower(): problems.append("Bcc is written")
    if "subject" in c:
        if str(m["Subject"]) != c["subject"]: problems.append(f"Subject: python read {str(m['Subject'])!r}, given {c['subject']!r}")
    elif m["Subject"] is not None: problems.append("a Subject nobody gave")
    t, off = c["date"]
    # Not fromtimestamp: Windows' C library has no time before 1970, and
    # Python's raised OSError for one there.
    want_date = (dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc) + dt.timedelta(seconds=t)).astimezone(dt.timezone(dt.timedelta(minutes=off)))
    got_date = m["Date"].datetime
    if got_date != want_date or got_date.utcoffset() != want_date.utcoffset() or str(m["Date"]) != format_datetime(want_date):
        problems.append(f"Date: {str(m['Date'])!r} is not {format_datetime(want_date)!r}")
    if c.get("id") != m["Message-ID"]: problems.append(f"Message-ID {m['Message-ID']!r}")
    if c.get("xnote") is not None and str(m["X-Note"]) != c["xnote"]: problems.append(f"X-Note {str(m['X-Note'])!r} is not {c['xnote']!r}")
    plain = m.get_body(("plain",)); html = m.get_body(("html",))
    if "text" in c or ("html" not in c):
        got = norm(plain.get_content()) if plain is not None else None
        if got != norm(c.get("text", "")): problems.append(f"text: python read {got!r}, given {norm(c.get('text', ''))!r}")
    if "html" in c:
        got = norm(html.get_content()) if html is not None else None
        if got != norm(c["html"]): problems.append(f"html: python read {got!r}")
    atts = [p for p in m.walk() if p.is_attachment()]
    if len(atts) != len(c["attach"]): problems.append(f"{len(atts)} attachments, not {len(c['attach'])}")
    for p, (fn, data, ct) in zip(atts, c["attach"]):
        if p.get_filename() != fn: problems.append(f"file name {p.get_filename()!r}, not {fn!r}")
        if p.get_payload(decode=True) != bytes.fromhex(data): problems.append(f"{fn!r}: the bytes differ")
        if ct and p.get_content_type() != ct: problems.append(f"{fn!r} is {p.get_content_type()}, not {ct}")
    for p in m.walk():
        if p.defects: problems.append(f"python found defects in a {p.get_content_type()} part: {p.defects}")
    if m.defects: problems.append(f"python found defects: {m.defects}")
    recips = []
    for _, a in c["to"] + c["cc"] + c["bcc"]:
        local, _, domain = a.rpartition("@")
        if local.startswith('"'): local = local[1:-1]
        s = Address(username=local, domain=domain).addr_spec
        if s not in recips: recips.append(s)
    fields = said[i].split(" ")
    got_recips = [bytes.fromhex(x[1:]).decode() for x in fields[1].split(",")] if fields[1] else []
    if got_recips != recips: problems.append(f"recipients {got_recips} not {recips}")
    if (fields[2] == "true") != utf8: problems.append(f"utf8? said {fields[2]}")
    if problems: bad.append((i, problems))
for i, problems in bad[:8]:
    print(f"  message {i}:")
    for p in problems[:4]: print(f"    {p}")
print(f"  {long_names[0]} names too long for one encoded-word held to their text without spaces")
print(f"  python's email read {len(cases) - len(bad)} of {len(cases)} messages built here back to what they were built from")
sys.exit(1 if bad else 0)
PY
cat >"$WORK/gen_parse.py" <<'PY'
import email, email.policy, hashlib, os, random, sys
from email.message import EmailMessage
from email.headerregistry import Address, Group
work = sys.argv[1]
rng = random.Random(2045)
os.makedirs(os.path.join(work, "py"), exist_ok=True)
words = ["hello", "world", "Grüße", "Köln", "東京", "😀", "naïve", "Привет", "report", "Q3", "a=b", "x" * 40, "(note)", "€100", "semi;colon", "comma,", "\"q\""]
def phrase(n, sep=" "): return sep.join(rng.choice(words) for _ in range(n))
names = ["", "Ann", "Jörg Müller", "Doe, John", "李小龍", "Zoë O'Brien", "José", "Mary Smith", "Dr. Who", "\"JD\"", "Ελληνικά"]
locals_ = ["ann", "bob.smith", "j_doe+tag", "john doe", "a@b", "x"]
domains = ["example.com", "example.org", "x.test"]
def address():
    return Address(rng.choice(names), rng.choice(locals_), rng.choice(domains))
def text():
    lines = [phrase(rng.randint(0, 25)) for _ in range(rng.randint(1, 8))]
    if rng.random() < 0.3: lines.append("x" * rng.randint(70, 300))
    if rng.random() < 0.3: lines.append(".dot line")
    return "\n".join(lines) + "\n"
def latin(n):
    return " ".join(rng.choice(["café", "naïve", "über", "¡hola!", "größe", "plain"]) for _ in range(n)) + "\n"
def describe(m):
    out = []
    fix = lambda s: s.encode("utf-8", "surrogateescape").decode("utf-8")
    out.append("subject " + hx(str(m["Subject"]) if m["Subject"] is not None else ""))
    for field in ["From", "To", "Cc", "Reply-To"]:
        h = m[field]
        if h is not None:
            for a in h.addresses: out.append(f"{field} {hx(fix(a.display_name))} {hx(fix(a.addr_spec))}")
    for part in m.walk():
        ct = part.get_content_type()
        fn = part.get_filename()
        payload = "-"
        if not part.is_multipart():
            if ct.startswith("text/"):
                payload = hashlib.sha256(part.get_content().replace("\r\n", "\n").encode("utf-8")).hexdigest()
            else:
                payload = hashlib.sha256(part.get_payload(decode=True)).hexdigest()
        out.append(f"part {ct} {1 if part.is_attachment() else 0} {hx(fn) if fn is not None else '-'} {payload}")
    return out
def hx(s): return "x" + s.encode("utf-8").hex()
expected = []
count = 0
for i in range(200):
    policy = email.policy.SMTP if i % 2 else email.policy.default
    m = EmailMessage(policy=policy)
    m["From"] = address()
    m["To"] = [address() for _ in range(rng.randint(1, 3))]
    if rng.random() < 0.3:
        m["Cc"] = [Group("Friends" if rng.random() < 0.5 else "Ünïcode group", [address() for _ in range(rng.randint(0, 2))]), address()]
    if rng.random() < 0.2: m["Reply-To"] = address()
    m["Subject"] = phrase(rng.randint(1, 20), rng.choice([" ", "  "]))
    m["Date"] = email.utils.format_datetime(email.utils.localtime())
    m["Message-ID"] = email.utils.make_msgid(domain="example.com")
    kind = rng.random()
    cte = rng.choice([None, None, "quoted-printable", "base64"])
    if kind < 0.15:
        m.set_content(latin(rng.randint(1, 30)), charset=rng.choice(["iso-8859-1", "utf-8"]), cte=cte)
    else:
        m.set_content(text(), cte=cte)
    if rng.random() < 0.5:
        m.add_alternative("<p>" + text() + "</p>", subtype="html", cte=rng.choice([None, "quoted-printable", "base64"]))
    for _ in range(rng.choice([0, 0, 1, 2])):
        r = rng.random()
        fn = rng.choice(["data.bin", "Grüße.pdf", "東京の写真.jpg", "a b.txt", "ünïcödé long file name " * 4 + ".zip", "semi;colon.dat"])
        if r < 0.6:
            m.add_attachment(bytes(rng.getrandbits(8) for _ in range(rng.choice([0, 1, 100, 3000]))), maintype="application", subtype="octet-stream", filename=fn)
        elif r < 0.8:
            m.add_attachment(text(), subtype="csv", filename=fn)
        else:
            inner = EmailMessage(policy=policy)
            inner["Subject"] = phrase(3)
            inner["From"] = address()
            inner.set_content(text())
            m.add_attachment(inner, filename=fn) if rng.random() < 0.5 else m.add_attachment(inner)
    data = m.as_bytes(policy=policy)
    open(os.path.join(work, "py", f"{count}.eml"), "wb").write(data)
    # What Python reads back from its own bytes is the answer.
    back = email.message_from_bytes(data, policy=email.policy.default)
    expected.append(f"message {count}")
    expected.extend(describe(back))
    count += 1
open(os.path.join(work, "py_expected.txt"), "w", encoding="utf-8", newline="\n").write("\n".join(expected) + "\n")
print(count)
PY
cat >"$WORK/cmp_parse.py" <<'PY'
import itertools, os, sys
work = sys.argv[1]
want = open(os.path.join(work, "py_expected.txt")).read().splitlines()
got = open(os.path.join(work, "py_got.txt")).read().splitlines()
bad, current, shown = 0, "", 0
messages = sum(1 for w in want if w.startswith("message "))
wrong = set()
for w, g in itertools.zip_longest(want, got, fillvalue=""):
    if w.startswith("message "): current = w
    if w != g:
        wrong.add(current)
        if shown < 8:
            shown += 1
            print(f"  {current}:\n    python {w[:110]}\n    iyi    {g[:110]}")
parts = sum(1 for w in want if w.startswith("part "))
print(f"  {messages - len(wrong)} of {messages} messages python built ({parts} parts) read here as python reads them")
sys.exit(1 if wrong else 0)
PY
cat >"$WORK/gen_codec.py" <<'PY'
import base64, email.quoprimime as qm, quopri, random, sys, os, datetime as dt, email.utils as eu, email.policy, email
from email.headerregistry import HeaderRegistry
work = sys.argv[1]
rng = random.Random(2047)
def hx(b):
    if isinstance(b, str): b = b.encode("utf-8")
    return "x" + b.hex()
cases, want = [], []
pool = list(b"abcdefghij KLMNOP=._-\t") + [0, 13, 127, 128, 195, 169, 255, 61, 32, 9]
for i in range(400):
    lines = []
    for _ in range(rng.randint(0, 6)):
        lines.append(bytes(rng.choice(pool) if rng.random() < 0.3 else rng.choice(b"abcdefxyz ") for _ in range(rng.choice([0, 1, 5, 40, 74, 75, 76, 77, 78, 150, 300]))).replace(b"\r", b"").replace(b"\n", b""))
    data = b"\n".join(lines) + (b"\n" if rng.random() < 0.5 else b"")
    # email.quoprimime writes str; latin-1 makes it a byte encoder.
    py = qm.body_encode(data.decode("latin-1"), 76, "\r\n").encode("latin-1")
    cases.append(f"qp {hx(data)}"); want.append(f"{hx(py)}\tquoprimime.body_encode of {data[:40]!r}")
    enc = quopri.encodestring(data, quotetabs=rng.random() < 0.5)
    cases.append(f"unqp {hx(enc)}"); want.append(f"{hx(quopri.decodestring(enc).replace(b'\n', b'\r\n'))}\tquopri.decodestring of {enc[:40]!r}")
    py = py.replace(b"\r\n", b"\n") if rng.random() < 0.5 else py
    cases.append(f"unqp {hx(py)}"); want.append(f"{hx(quopri.decodestring(py).replace(b'\r\n', b'\n').replace(b'\n', b'\r\n'))}\tquopri.decodestring of {py[:40]!r}")
for i in range(300):
    data = bytes(rng.getrandbits(8) for _ in range(rng.choice([0, 1, 2, 3, 56, 57, 58, 100, 1000])))
    cases.append(f"b64 {hx(data)}"); want.append(f"{hx(base64.encodebytes(data).replace(b'\n', b'\r\n'))}\tbase64.encodebytes of {len(data)} bytes")
    enc = bytearray(base64.encodebytes(data))
    for _ in range(rng.randint(0, 5)):
        enc.insert(rng.randint(0, len(enc)), rng.choice(b" \t\r\n!*#~"))
    cases.append(f"unb64 {hx(bytes(enc))}"); want.append(f"{hx(base64.b64decode(bytes(enc)))}\tbase64.b64decode of {bytes(enc)[:30]!r}")
# Dates: what email.utils writes, then forms it reads.
for i in range(300):
    t = rng.randint(-2208988800, 253402214400)
    off = rng.randint(-1439, 1439)
    d = (dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc) + dt.timedelta(seconds=t)).astimezone(dt.timezone(dt.timedelta(minutes=off)))  # as above
    cases.append(f"date {t} {off}"); want.append(f"{eu.format_datetime(d)}\tformat_datetime of {t} at {off}")
    text = eu.format_datetime(d)
    r = rng.random()
    if r < 0.2: text = text[5:]
    elif r < 0.3: text = text.replace(" ", "  ").replace(",  ", ",\r\n ")
    elif r < 0.4 and 1950 <= d.year <= 2049: text = text[:12] + text[14:]
    elif r < 0.5: text = text + " (comment (nested))"
    elif r < 0.6 and off % 60 == 0 and -480 <= off <= 0: 
        z = {0: "GMT", -300: "EST", -240: "EDT", -360: "CST", -420: "MST", -480: "PST"}.get(off)
        if z: text = text[:-5] + z
    elif r < 0.7: text = text[:-9] + text[-6:]
    cases.append(f"undate {hx(text)}")
    p = eu.parsedate_to_datetime(text)
    want.append(f"{int(p.timestamp()) if p.tzinfo else int(p.replace(tzinfo=dt.timezone.utc).timestamp())} {int(p.utcoffset().total_seconds() // 60) if p.tzinfo else 0}\tparsedate_to_datetime of {text!r}")
# Address lists Python reads, and the header values it writes.
reg = HeaderRegistry()
names = ["Ann", "Jörg Müller", "Doe, John", "李", "\"JD\" Doe", "a (b) c", "", "Dr. Who"]
for i in range(300):
    parts = []
    for _ in range(rng.randint(1, 4)):
        n = rng.choice(names)
        local = rng.choice(["ann", "j.doe", "\"john doe\"", "\"a\\\\\\\"b\"", "x+y"])
        dom = rng.choice(["example.com", "x.test", "[192.0.2.1]", "sub . example . org"])
        spec = f"{local}{rng.choice(['', ' ', '(c)'])}@{rng.choice(['', ' '])}{dom}"
        if n and rng.random() < 0.5:
            nm = n if all(c.isalnum() or c == ' ' for c in n) and n.isascii() else rng.choice(['"' + n.replace('\\', '\\\\').replace('"', '\\"') + '"', email.header.Header(n, "utf-8").encode()])
            parts.append(f"{nm} <{spec}>")
        elif rng.random() < 0.15:
            parts.append(f"Group{i}: {spec}, Ann <ann@x.test> ;")
        else:
            parts.append(spec + rng.choice(["", " (Comment)"]))
    value = rng.choice([", ", ",\t", " , "]).join(parts)
    h = reg("To", value)
    cases.append(f"addresses {hx(value)}")
    if h.defects:
        want.append(f"?\t{value!r} with defects {h.defects}")
    else:
        want.append(",".join(hx(a.display_name) + "/" + hx(a.addr_spec) for a in h.addresses) + f"\tPython's headerregistry of {value!r}")
# Unstructured values Python folds, read here; values folded here, read by Python.
words = ["hello", "Grüße", "東京", "😀", "x" * 50, "a=?b", "  ", "\t", "naïve"]
for i in range(300):
    v = "".join(rng.choice(words) + rng.choice([" ", "", "  "]) for _ in range(rng.randint(1, 30))).strip()
    folded = email.policy.SMTP.fold("Subject", v)
    # Unfolded as RFC 5322 section 2.2.3 has it: each CRLF removed.
    unfolded = folded[len("Subject: "):].rstrip("\r\n").replace("\r\n", "")
    cases.append(f"words {hx(unfolded)}")
    want.append(f"{hx(str(reg('Subject', unfolded)))}\tPython's fold of {v!r}")
    cases.append(f"fold {hx(v)} {hx('Subject')}")
    want.append(f"FOLD {hx(v)}\tthe fold of {v!r}")
open(os.path.join(work, "codec_cases.txt"), "w", encoding="utf-8", newline="\n").write("\n".join(cases) + "\n")
open(os.path.join(work, "codec_want.txt"), "w", encoding="utf-8", newline="\n").write("\n".join(want) + "\n")
PY
cat >"$WORK/check_codec.py" <<'PY'
import email, email.policy, os, sys
from collections import Counter
work = sys.argv[1]
got = open(os.path.join(work, "codec_got.txt")).read().splitlines()
want = [line.split("\t", 1) for line in open(os.path.join(work, "codec_want.txt")).read().splitlines()]
cases = open(os.path.join(work, "codec_cases.txt")).read().splitlines()
seen, bad = Counter(), Counter()
for c, w, g in zip(cases, want, got + [""] * len(want)):
    op = c.split(" ")[0]
    seen[op] += 1
    if w[0] == "?":
        continue
    if w[0].startswith("FOLD "):
        value = bytes.fromhex(w[0][6:]).decode()
        raw = bytes.fromhex(g[1:])
        m = email.message_from_bytes(raw + b"\r\n", policy=email.policy.default)
        ok = str(m["Subject"]) == value and all(len(l) <= 78 for l in raw.split(b"\r\n")) and not m.defects and raw.endswith(b"\r\n")
        if not ok:
            bad[op] += 1
            if bad[op] <= 4: print(f"  {w[1]}: python read {str(m['Subject'])!r} from {raw!r}")
        continue
    if w[0] != g:
        bad[op] += 1
        if bad[op] <= 4: print(f"  {w[1]}:\n    want {w[0][:120]}\n    got  {g[:120]}")
names = {"qp": "quoted-printable written", "unqp": "quoted-printable read", "b64": "base64 written", "unb64": "base64 read",
         "date": "dates written", "undate": "dates read", "addresses": "address lists read", "words": "encoded-words read", "fold": "values folded"}
print("  " + ", ".join(f"{seen[k] - bad[k]}/{seen[k]} {names[k]}" for k in names))
sys.exit(1 if sum(bad.values()) else 0)
PY

# build_oracle <binary> <dir>: the messages of the spec built by <binary>
# into <dir>, and Python's verdict on them.
build_oracle() {
  rm -rf "$2/built"
  mkdir -p "$2/built"
  "$1" build "$2/spec.txt" "$2/built" >"$2/built.txt" 2>"$2/built.err" || { echo "  the build stopped: $(tail -1 "$2/built.err")"; return 1; }
  "$PY" "$WORK/check_build.py" "$2"
}

echo
echo "== python's email reads what this builds"
# 200 messages of random From, To, Cc, Bcc and Reply-To - names in
# ASCII, quoted, UTF-8, with specials; addresses with quoted local parts,
# domain literals and, one message in ten, RFC 6532's UTF-8 - subjects
# of ASCII, UTF-8, tabs, runs of spaces, `=?` and words too long for a
# line, texts with long lines, trailing spaces and dot lines, HTML, and up
# to three attachments of random bytes with long and UTF-8 file names.
# Python's `email` (policy.default) must find no defect, read every
# address, the Subject, the Date, the Message-ID, the text, the HTML and
# each attachment's name, type and bytes back to what was given, and no
# Bcc; every line must end in CRLF and be 78 or fewer, and the message
# be ASCII, but for a UTF-8 address.
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so what is built goes unread"
else
  mkdir -p "$WORK/oracle"
  "$PY" "$WORK/gen_build.py" "$WORK/oracle"
  build_oracle "$WORK/mail-plain" "$WORK/oracle" || status=1
fi

echo
echo "== this reads what python's EmailMessage builds"
# 200 messages built by `EmailMessage` - set_content of UTF-8 and
# ISO-8859-1 text in 7bit, 8bit, quoted-printable or base64, an HTML
# alternative, attachments of bytes, of CSV text and of whole messages
# (message/rfc822), groups in Cc, UTF-8 names and file names - written by
# `as_bytes` under policy.default (LF) and policy.SMTP (CRLF) in turn. For
# each, the Subject, every address, and each part Python's `walk` yields
# - its type, whether it is an attachment, its file name, and the SHA-256
# of its decoded text or bytes - must be what Python reads.
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so what python builds goes unread"
else
  "$PY" "$WORK/gen_parse.py" "$WORK" >/dev/null
  "$WORK/mail-plain" parse "$WORK/py" 200 >"$WORK/py_got.txt" 2>&1
  "$PY" "$WORK/cmp_parse.py" "$WORK" || status=1
fi

echo
echo "== the encodings beside quopri, base64, email.quoprimime, email.utils and email.headerregistry"
# 400 random texts - escapes, tabs, spaces at line ends, lines of 74 to
# 300 - written here and by `email.quoprimime.body_encode`, byte for
# byte; quoted-printable written by `quopri` and by `body_encode` (CRLF
# and LF) read here as `quopri` reads it; 300 base64 encodings beside
# `base64.encodebytes` and read, with whitespace and junk inserted, as
# `b64decode` reads them; 300 dates written as `format_datetime` writes
# them and read - without the weekday, folded, with comments, obsolete
# zones and two-digit years - as `parsedate_to_datetime` reads them; 300
# address lists read as `headerregistry` reads them; 300 subjects folded
# by policy.SMTP read as Python reads them, and folded here for Python to
# read back.
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the encodings go uncompared"
else
  "$PY" "$WORK/gen_codec.py" "$WORK"
  "$WORK/mail-plain" codec "$WORK/codec_cases.txt" >"$WORK/codec_got.txt" 2>&1
  "$PY" "$WORK/check_codec.py" "$WORK" || status=1
fi

echo
echo "== what mail refuses"
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/mail::{Mail, MailError}

def msg : Mail::Message
  m = Mail::Message.new
  m.from = Mail::Address.new("a@x.test")
  m.date = Mail.date(0_i64)
  m
end

case Program.args[0]
when "no-from"
  m = Mail::Message.new
  m.date = Mail.date(0_i64)
  m.to_s
when "no-date"
  m = Mail::Message.new
  m.from = Mail::Address.new("a@x.test")
  m.to_s
when "bad-date"
  msg.date = "yesterday"
when "bad-id"
  msg.message_id = "<no at sign>"
when "subject-break"
  msg.subject = "one\r\nBcc: injected@x.test"
when "header-break"
  msg.header("X-Note", "a\nb")
when "header-name"
  msg.header("X Note", "a")
when "own-header"
  msg.header("From", "b@x.test")
when "content-header"
  msg.header("Content-Type", "text/html")
when "not-address"
  Mail::Address.new("not an address")
when "name-break"
  Mail::Address.new("a@x.test", "Ann\r\nBcc: b@x.test")
when "offset"
  Mail.date(0_i64, 1440)
when "year"
  Mail.date(-2208988801_i64)
when "media-type"
  msg.attach("a.bin", "x", "not a type")
when "empty-filename"
  msg.attach("", "x")
when "text-not-utf8"
  msg.text = "caf\xE9"
when "parse-or-panic"
  Mail.parse("not a header\r\n\r\n").or_panic
when "address-or-panic"
  Mail::Address.parse("Ann <a@x.test").or_panic
when "text-or-panic"
  Mail.parse("Content-Type: text/plain; charset=koi8-r\r\n\r\nx").or_panic.text.or_panic
end
puts "accepted"
IYI
refuse() { # refuse <case> <phrase>
  if "$IYI" run "$WORK/refuse.iyi" -- "$1" >"$WORK/refuse.out" 2>&1; then
    echo "  $1 was accepted: $(tr -d '\r' <"$WORK/refuse.out" | tail -1)"
    status=1
  elif ! grep -qF -e "$2" "$WORK/refuse.out"; then
    echo "  $1 was refused without saying why: $(tr -d '\r' <"$WORK/refuse.out" | tail -1)"
    status=1
  else
    echo "  $1: $(tr -d '\r' <"$WORK/refuse.out" | grep -oF -e "$2" | head -1)"
  fi
}
refuse no-from "mail: a message has no From"
refuse no-date "mail: a message has no Date"
refuse bad-date "mail: the Date \"yesterday\" is not an RFC 5322 date"
refuse bad-id "mail: the Message-ID \"<no at sign>\" is not <left@right>"
refuse subject-break "mail: the Subject header holds a line break"
refuse header-break "mail: the X-Note header holds a line break"
refuse header-name "mail: a header name is printable ASCII without a colon, not \"X Note\""
refuse own-header "mail: From is set through the message's own property"
refuse content-header "mail: Content-Type is set through the message's own property"
refuse not-address "mail: \"not an address\" is not an address: a local part has two words with no dot between them in \"not an address\""
refuse name-break "mail: a display name holds a line break"
refuse offset "mail: a Date's offset is within a day of UTC, -1439 to 1439 minutes, not 1440"
refuse year "mail: a Date is in the years 1900 to 9999, not 1899"
refuse media-type "mail: \"not a type\" is not a media type"
refuse empty-filename "mail: an attachment's file name is empty"
refuse text-not-utf8 "mail: the text is not UTF-8"
# An error value is not a panic until it is asked to be one.
refuse parse-or-panic "mail: line 1 of a header section is not a field: \"not a header\""
refuse address-or-panic "mail: an angle address is not closed with > in \"Ann <a@x.test\""
refuse text-or-panic "mail: the charset \"koi8-r\" is not one std/mail reads (UTF-8, US-ASCII, ISO-8859-1, ISO-8859-15, windows-1252)"

# patched <old> <new> <dir>: a copy of the module in <dir>/std with <old>
# replaced, once.
patched() {
  rm -rf "$3"
  mkdir -p "$3/std"
  OLD="$1" NEW="$2" "$PY" - "$REPO/src/std/mail.iyi" "$3/std/mail.iyi" <<'PY'
import os, sys
src = open(sys.argv[1], encoding="utf-8").read()
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not one")
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
}

echo
echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <old> <new>: the exercise must fail on a
# copy of the module with <old> replaced, at the check that names <phrase>.
prove_broken() {
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $1 proof is unmeasured"
    return
  fi
  if ! patched "$3" "$4" "$WORK/patched"; then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_mail_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on $1"
    status=1
  elif grep -qF -e "$2" "$WORK/mut.out"; then
    echo "  $1 is caught"
  else
    echo "  $1 failed, but not where it should have:"
    tail -2 "$WORK/mut.out" | sed 's/^/    /'
    status=1
  fi
}
prove_broken "quoted-printable cut at 76 and its soft break" "quoted-printable lines are 76 or fewer" \
  'stop = start + 75' 'stop = start + 76'
prove_broken "a space at a line's end left bare" "space and tab at a line's end are escaped" \
  'if size > 0 && MailText.wsp?(p[size - 1])' 'if false'
prove_broken "a soft break inside an escape" "every byte comes back in binary" \
  'if p[stop - 2] == 61_u8' 'if false'
prove_broken "a gateway's trailing whitespace kept" "whitespace a gateway added at a line's end is dropped" \
  'while e > i && MailText.wsp?(p[e - 1])
        e = e - 1
      end
      soft = false' 'soft = false'
prove_broken "base64 taking what is outside its alphabet" "characters outside the alphabet are passed over" \
  '      if v >= 0
        acc = ((acc << 6) | v) & 0xFFFFFF' '      if v >= 0 || b == 33_u8
        acc = ((acc << 6) | v) & 0xFFFFFF'
prove_broken "base64 in lines of 64" "base64 lines are filled to 76" \
  'take = n - i < 76 ? n - i : 76' 'take = n - i < 64 ? n - i : 64'
prove_broken "the space between two encoded-words kept" "the space between two words is dropped" \
  'io.write(p + i, j - i) unless after_word' 'io.write(p + i, j - i)'
prove_broken "a short name split between encoded-words" "a short name is one encoded-word" \
  'MailText.word_end(p, 0, n, 63, q) == n' 'false'
prove_broken "encoded-words of 77" "every encoded-word is 75 or fewer" \
  'left > 75 ? 75 : left' 'left > 77 ? 77 : left'
prove_broken "an encoded-word cut inside a character" "encoded-words decode to the value" \
  'c = MailText.char_size(p, j, n)' 'c = 1'
prove_broken "headers folded at 98" "a long ASCII subject is folded to 78" \
  'LIMIT = 78' 'LIMIT = 98'
prove_broken "Bcc written into the message" "A.1.1 written" \
  'head << Message.addresses("Cc", @cc) unless @cc.empty?' 'head << Message.addresses("Cc", @cc) unless @cc.empty?
      head << Message.addresses("Bcc", @bcc) unless @bcc.empty?'
prove_broken "a boundary hashed from nothing" "a part is in the boundary's hash" \
  'rendered.each { |r| digest.update(r) }' 'rendered.size'
# With the boundary hashed from nothing, a multipart's parent and child
# draw the same one, and only its being made again where a part holds it
# keeps them apart.
prove_broken "a boundary a part holds kept" "holds no line --iyi-da39a3ee" \
  'rendered.each { |r| digest.update(r) }
      mark = "iyi-" + digest.hexfinal[0, 32]
      while rendered.any? { |r| (' 'rendered.size
      mark = "iyi-" + digest.hexfinal[0, 32]
      while rendered.any? { |r| false && ('
prove_broken "a part's last CR kept from its boundary" "the text comes back" \
  'stop_at = stop_at - 1 if stop_at > open_at && p[stop_at - 1] == 13_u8' 'stop_at = stop_at - 1 if stop_at > open_at && p[stop_at - 1] == 0_u8'
prove_broken "a boundary taken as a prefix" "a boundary is a whole line, not a prefix" \
  'blank = false unless MailText.wsp?(p[rest])' 'blank = true'
prove_broken "nesting unbounded" "nesting is bounded" \
  'if depth > MAX_DEPTH' 'if depth > MAX_DEPTH * 100'
prove_broken "a comment read as words" "A.5 comments are passed over" \
  '      elsif b == 40_u8
        depth = 0' '      elsif false
        depth = 0'
prove_broken "a quoted local part written bare" "a quoted local part stays quoted" \
  'plain ? local : MailText.quoted(local)' 'local'
prove_broken "a space read between two encoded-words of a name" "two encoded-words in a name" \
  'io << " " if w.spaced && !(decoded && last_word)' 'io << " " if w.spaced'
prove_broken "every fourth year a leap year" "\"Mon, 29 Feb 1900 00:00:00 +0000\" is refused" \
  '(year % 100 != 0 || year % 400 == 0)' 'true'
prove_broken "days before 1970 truncated, not floored" "a time of day before 1970" \
  'days = days - 1_i64 if local % 86400_i64 < 0' 'days = days - 1_i64 if local % 86400_i64 < -86400_i64'
prove_broken "two-digit years the wrong way round" "\"21 Nov 97 09:55:06 GMT\" is 880106106" \
  'year < 50 ? 2000 : 1900' 'year < 50 ? 1900 : 2000'
prove_broken "windows-1252 read as ISO-8859-1" "windows-1252" \
  'cp = CP1252[b - 128]' 'cp = b'
prove_broken "ISO-8859-15 without its euro" "ISO-8859-15's euro" \
  'when 0xA4 then 0x20AC' 'when 0xA4 then 0xA4'
prove_broken "an RFC 2231 continuation that is not encoded dropped" "RFC 2231 continuations, plain and encoded" \
  '          bytes << piece[1]' '          bytes << ""'
prove_broken "text read back with its CRLFs" "the text comes back" \
  'io.write_byte(p[i]) unless p[i] == 13_u8 && i + 1 < n && p[i + 1] == 10_u8' 'io.write_byte(p[i])'
prove_broken "7bit lines of up to 998" "a line past 78 makes text quoted-printable" \
  'return false if col > MailFolder::LIMIT' 'return false if col > 998'
prove_broken "the longer encoding chosen" "a line past 78 makes text quoted-printable" \
  'encoding = qp.bytesize <= b64.bytesize ? "quoted-printable" : "base64"
        body = qp.bytesize <= b64.bytesize ? qp : b64' 'encoding = qp.bytesize > b64.bytesize ? "quoted-printable" : "base64"
        body = qp.bytesize > b64.bytesize ? qp : b64'
prove_broken "a folded line's whitespace dropped in unfolding" "a folded field is unfolded" \
  'value.write(p + i, e - i)' 'value.write(p + i + 1, e - i - 1)'
prove_broken "a UTF-8 address taken for ASCII" "a UTF-8 address says so" \
  '!MailText.ascii?(@local) || !MailText.ascii?(@domain)' 'false'

# What only Python's answers catch: the exercise is built on the broken
# copy and its messages and encodings read by Python.
echo
echo "== proving python's answers catch what the exercise cannot"
# prove_oracle <label> <phrase> <old> <new> <which>: the build or codec
# comparison must fail on the broken copy, saying <phrase>.
prove_oracle() {
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $1 proof is unmeasured"
    return
  fi
  if ! patched "$3" "$4" "$WORK/opatched"; then
    echo "  the $1 patch did not apply"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/opatched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/mail-broken" "$REPO/bench/std_mail_exercise.iyi" >"$WORK/obuild.log" 2>&1; then
    echo "  the $1 copy did not compile"
    status=1
    return
  fi
  if [ "$5" = build ]; then
    build_oracle "$WORK/mail-broken" "$WORK/oracle" >"$WORK/omut.out" 2>&1
  else
    "$WORK/mail-broken" codec "$WORK/codec_cases.txt" >"$WORK/codec_got.txt" 2>&1
    "$PY" "$WORK/check_codec.py" "$WORK" >"$WORK/omut.out" 2>&1
  fi
  if [ $? -eq 0 ]; then
    echo "  python's answers PASSED $1"
    status=1
  elif grep -qF -e "$2" "$WORK/omut.out"; then
    echo "  $1 is caught"
  else
    echo "  $1 failed, but not where it should have:"
    tail -2 "$WORK/omut.out" | sed 's/^/    /'
    status=1
  fi
}
if [ -n "$PY" ]; then
  prove_oracle "a dot escaped in quoted-printable" "quoprimime.body_encode of" \
    'if (b >= 32_u8 && b <= 126_u8 && b != 61_u8) || b == 9_u8' 'if (b >= 32_u8 && b <= 126_u8 && b != 61_u8 && b != 46_u8) || b == 9_u8' codec
  prove_oracle "a zone's sign ignored" "parsedate_to_datetime of" \
    'offset = (hh * 60 + mm) * (c == 45_u8 ? -1 : 1)' 'offset = hh * 60 + mm' codec
  prove_oracle "a file name's space left bare in RFC 2231" "file name" \
    'if MailText.attr_char?(p[k])' 'if MailText.attr_char?(p[k]) || p[k] == 32_u8' build
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/mail exercise holds"
else
  echo "the std/mail exercise did not hold"
fi
exit $status
