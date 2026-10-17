#!/usr/bin/env bash
# Exercises `std/jwt`.
#
#     bash bench/std_jwt_exercise.sh
#
# The exercise holds RFC 7515's appendix A, RFC 7520's JWS examples, RFC
# 8037's Ed25519 example, RFC 7638's thumbprint, RFC 7517's JWK Sets,
# thirteen tokens PyJWT wrote, PEM keys cryptography wrote, the attacks
# and the claims at their edges; this gate runs it plain and --release,
# holds 2,700 tokens PyJWT 2.10.1 writes over keys Python's cryptography
# draws (every algorithm, RSA of 2048 to 4096 bits, a tenth of them
# attacked) and 2,100 tokens this module writes to what PyJWT reads of
# them, byte for byte where both sign deterministically; names what is
# refused with its sentence; reads std/jwt's import lines for a clock or
# any other platform module; builds the documentation, checks the
# formatting, typechecks the exercise for the five targets and builds it
# from artifacts; and proves on broken copies of the module that the
# checks fail where they say.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
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
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from `pwd` is `/c/...` and finds no prelude at all, and a
# scratch directory named `/tmp/tmp.X` is silently ignored on that path, so
# the patched copy is never read and the proof that a check can fail quietly
# stops proving it.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_jwt_exercise.iyi" \
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

echo "== the std/jwt exercise, plain build"
build_and_run "plain" jwt-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/jwt-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every jwt section reported"
for phrase in "== RFC 7515 appendix A.1, HS256" "== RFC 7515 appendix A.2, RS256" "== RFC 7515 appendix A.3, ES256" \
  "== RFC 7515 appendix A.4, ES512" "== RFC 7515 appendix A.5, the unsecured JWS refused" "== RFC 7520 section 4" \
  "== RFC 8037 appendix A, Ed25519" "== RFC 7638 section 3.1" "== RFC 7517 appendix A, JWK Sets" "== keys from PEM" \
  "== tokens PyJWT wrote" "== every algorithm, signed and checked" "== the attacks" "== claims at their edges" \
  "== JWK read and written" "== the clock is the caller's"; do
  if ! grep -qF "$phrase" "$WORK/jwt-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" jwt-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/jwt-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
else
  echo "  ALL CHECKS PASSED"
fi

echo
echo "== against PyJWT, both ways"
# Python draws the keys - two HMAC secrets per HS algorithm, two RSA keys
# each of 2048, 3072 and 4096 bits, two on each NIST curve, two Ed25519 -
# and hands each over as the JWK PyJWT writes and, for the asymmetric ones,
# as PEM (PKCS #8 or the traditional form), which iyi must read as one
# key. Then 2,700 tokens PyJWT writes of random claims - registered ones
# valid or not at the moment the case is written, custom ones of every
# JSON kind, strings with escapes, control bytes and non-ASCII - which iyi
# decodes at that same moment with the same leeway, audience and issuer
# PyJWT was given: its claims where PyJWT takes the token, a refusal for
# PyJWT's reason where it does not. Two in five are attacked first: a bit
# of the signature turned, the payload changed under the signature, alg
# none, alg changed within its family, an HS256 MAC under the public
# key's PEM, a token signed by another key, a crit header - which PyJWT
# refuses as well - and three PyJWT takes that the module's header says
# this refuses: a padded signature, a second spelling of its last
# character, and a claim written twice. Then 2,100 claims sets iyi signs,
# which PyJWT must verify and read back to the claims given; where both
# sign deterministically (HS, RS, EdDSA) and the claims are written alike
# (printable ASCII, no fractions), iyi's token must be PyJWT's byte for
# byte, and every ES256 signature must be the one cryptography's RFC 6979
# signer makes.
if [ -z "$PY" ] || ! "$PY" -c 'import jwt, cryptography; assert jwt.__version__.startswith("2.")' >/dev/null 2>&1; then
  echo "  PyJWT 2 and cryptography are not installed here, so std/jwt goes uncompared with them"
else
  cat >"$WORK/oracle.iyi" <<'IYI'
module oracle

import std/jwt::{JWT, JWK, JWTAlgorithm, JWTError}
import std/json::{JSON, Any}
import std/base64::{Base64}

def b64(text : String) : String
  Base64.urlsafe_encode(text).split('=')[0]
end

keys = {} of String => JWK
while line = STDIN.read_line(chomp: true)
  f = line.split(' ')
  case f[0]
  when "key"
    k = JWK.parse(Base64.decode(f[2])).or_panic
    if f[3] != "-"
      from_pem = JWK.from_pem(Base64.decode(f[3])).or_panic
      same = from_pem.thumbprint == k.thumbprint && from_pem.private? == k.private?
      raise "the PEM and the JWK of #{f[1]} are not one key" unless same
    end
    keys[f[1]] = k
  when "dec"
    algorithm = JWTAlgorithm.named(f[1]).as(JWTAlgorithm)
    k = keys[f[2]]
    verifier = algorithm.family == "HS" || !k.private? ? k : k.public
    audience = f[5] == "-" ? nil : f[5]
    issuer = f[6] == "-" ? nil : f[6]
    answer = JWT.decode(f[7], verifier, [algorithm], f[3].to_i.to_i64, f[4].to_i.to_i64, audience, issuer)
    puts answer.is_a?(JWTError) ? "err #{answer.message}" : "ok #{b64(JSON.to_json(answer.claims))}"
  when "enc"
    algorithm = JWTAlgorithm.named(f[1]).as(JWTAlgorithm)
    puts JWT.encode(JSON.parse(Base64.decode(f[3])), keys[f[2]], algorithm)
  end
end
IYI
  if ! "$PY" - "$WORK" >"$WORK/oracle_gen.log" 2>&1 <<'PY'
import base64, hashlib, hmac, json, os, random, sys, time
import jwt
from jwt.api_jws import PyJWS
from cryptography.hazmat.primitives import hashes, serialization as S
from cryptography.hazmat.primitives.asymmetric import ec, ed25519, rsa

work = sys.argv[1]
rng = random.Random(7519)
NOW = int(time.time())


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def std64(data):
    return base64.b64encode(data).decode()


ALGS = ["HS256", "HS384", "HS512", "RS256", "RS384", "RS512", "PS256", "PS384", "PS512", "ES256", "ES384", "ES512", "EdDSA"]
# Tokens PyJWT writes for iyi to decode, and claims iyi signs for PyJWT to
# check, by algorithm. ES384 and ES512 are checked only.
DEC = {"HS": 300, "RS": 150, "PS": 150, "ES256": 300, "ES384": 150, "ES512": 150, "EdDSA": 300}
# RSA signing here is std/big's square-and-multiply, about 10 ms for 2048
# bits and eight times that for 4096: fewer of those.
ENC = {"HS": 300, "RS": 100, "PS": 100, "ES256": 300, "ES384": 0, "ES512": 0, "EdDSA": 300}


def count(table, alg):
    return table.get(alg, table.get(alg[:2], 0))


# The keys: HMAC secrets of the hash's size and longer, RSA of 2048, 3072
# and 4096 bits, one key on each NIST curve, and Ed25519; two of each so
# that a token can be signed by the wrong one.
keys = {}
lines = []


def add_key(name, private, jwk, pem):
    keys[name] = private
    lines.append(f"key {name} {std64(json.dumps(jwk).encode())} {std64(pem) if pem else '-'}")


for alg in ["HS256", "HS384", "HS512"]:
    size = {"HS256": 32, "HS384": 48, "HS512": 64}[alg]
    for i in range(2):
        secret = os.urandom(rng.choice([size, size + 1, 64, 100]))
        add_key(f"{alg}-{i}", secret, json.loads(jwt.algorithms.HMACAlgorithm.to_jwk(secret)), None)
for bits in [2048, 3072, 4096]:
    for i in range(2):
        k = rsa.generate_private_key(65537, bits)
        fmt = S.PrivateFormat.PKCS8 if i == 0 else S.PrivateFormat.TraditionalOpenSSL
        add_key(f"RSA{bits}-{i}", k, jwt.algorithms.RSAAlgorithm.to_jwk(k, as_dict=True), k.private_bytes(S.Encoding.PEM, fmt, S.NoEncryption()))
for alg, curve in [("ES256", ec.SECP256R1()), ("ES384", ec.SECP384R1()), ("ES512", ec.SECP521R1())]:
    for i in range(2):
        k = ec.generate_private_key(curve)
        jwk = jwt.algorithms.ECAlgorithm.to_jwk(k, as_dict=True)
        if alg == "ES256":
            fmt = S.PrivateFormat.PKCS8 if i == 0 else S.PrivateFormat.TraditionalOpenSSL
            pem = k.private_bytes(S.Encoding.PEM, fmt, S.NoEncryption())
        else:
            # std signs on P-256 alone: the key iyi holds is the public half.
            del jwk["d"]
            jwk["key_ops"] = ["verify"]
            pem = k.public_key().public_bytes(S.Encoding.PEM, S.PublicFormat.SubjectPublicKeyInfo)
        add_key(f"{alg}-{i}", k, jwk, pem)
for i in range(2):
    k = ed25519.Ed25519PrivateKey.generate()
    add_key(f"EdDSA-{i}", k, jwt.algorithms.OKPAlgorithm.to_jwk(k, as_dict=True), k.private_bytes(S.Encoding.PEM, S.PrivateFormat.PKCS8, S.NoEncryption()))


def key_for(alg, i):
    if alg.startswith("HS") or alg.startswith("ES") or alg == "EdDSA":
        return f"{alg}-{i}"
    return f"RSA{rng.choice([2048] * 8 + [3072, 4096])}-{i}"


def public(name):
    k = keys[name]
    return k if isinstance(k, bytes) else k.public_key()


PRINTABLE = [chr(c) for c in range(32, 127)]
WIDE = PRINTABLE + ["\n", "\t", "\u0001", "\u007f", "é", "ü", "中", "😀", "\u2028", "\u00a0"]


def text(ascii_only):
    pool = PRINTABLE if ascii_only else WIDE
    return "".join(rng.choice(pool) for _ in range(rng.randint(0, 16)))


def value(depth, plain):
    roll = rng.random()
    if roll < 0.3:
        return text(plain)
    if roll < 0.55:
        return rng.choice([rng.randint(-1000, 1000), rng.randint(-2**63, 2**63 - 1), 0])
    if roll < 0.62 and not plain:
        return rng.choice([0.5, -1.25, 1e-7, 3.141592653589793, 1e300, 123456.789])
    if roll < 0.7:
        return rng.choice([True, False, None])
    if roll < 0.85 and depth < 3:
        return [value(depth + 1, plain) for _ in range(rng.randint(0, 4))]
    if depth < 3:
        return {text(True) + str(i): value(depth + 1, plain) for i in range(rng.randint(0, 4))}
    return 7


AUDS = ["api", "web", "mobile"]
ISSS = ["https://a.example", "https://b.example"]


def offset():
    return rng.choice([-1, 1]) * rng.randint(100, 10**6)


# A claims set: registered claims or not, each valid at NOW most of the
# time and not the rest, and the audience and issuer the decoder will ask
# for - most often what the token names - so that about half decode.
def claim_set(plain):
    c = {}
    if rng.random() < 0.6:
        c["exp"] = NOW + (offset() if rng.random() < 0.15 else rng.randint(100, 10**6))
    if rng.random() < 0.3:
        c["nbf"] = NOW + (offset() if rng.random() < 0.15 else -rng.randint(100, 10**6))
    if rng.random() < 0.3:
        c["iat"] = NOW + (offset() if rng.random() < 0.15 else -rng.randint(100, 10**6))
    if not plain and rng.random() < 0.1:
        c["exp"] = NOW + offset() + 0.5
    aud = None
    if rng.random() < 0.4:
        c["aud"] = rng.choice([rng.choice(AUDS), rng.sample(AUDS, rng.randint(1, 3))])
        named = c["aud"] if isinstance(c["aud"], list) else [c["aud"]]
        aud = rng.choice(named) if rng.random() < 0.85 else rng.choice(AUDS + [None])
    elif rng.random() < 0.1:
        aud = rng.choice(AUDS)
    iss = None
    if rng.random() < 0.4:
        c["iss"] = rng.choice(ISSS)
        iss = rng.choice([c["iss"], c["iss"], c["iss"], None, rng.choice(ISSS)])
    elif rng.random() < 0.1:
        iss = rng.choice(ISSS)
    if rng.random() < 0.5:
        c["sub"] = text(plain) if rng.random() < 0.97 else 42
    if rng.random() < 0.2:
        c["jti"] = text(plain) if rng.random() < 0.97 else [1]
    for i in range(rng.randint(0, 5)):
        c[text(True) + "_" + str(i)] = value(0, plain)
    return c, aud, iss


def pyjwt_says(token, alg, name, leeway, aud, iss):
    try:
        claims = jwt.decode(token, public(name), algorithms=[alg], leeway=leeway, audience=aud, issuer=iss)
        return "ok", claims
    except jwt.InvalidTokenError as e:
        return type(e).__name__, None


def resign(alg, name, header, payload):
    return PyJWS().encode(payload, keys[name], algorithm=alg, headers=header, sort_headers=False)


def spare_bits(segment):
    return {2: 15, 3: 3, 0: 0}[len(segment) % 4]


ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

dec_expected = []
for alg in ALGS:
    for n in range(count(DEC, alg)):
        name = key_for(alg, 0)
        claims, aud, iss = claim_set(False)
        leeway = rng.choice([0, 0, 10, 60])
        headers = {"kid": "k" + str(n)} if rng.random() < 0.2 else None
        token = jwt.encode(claims, keys[name], algorithm=alg, headers=headers)
        attack = "-"
        if rng.random() < 0.4:
            attack = rng.choice(["sig", "payload", "none", "swap", "confusion", "pad", "spelling", "duplicate", "wrong_key", "crit"])
            h, p, s = token.split(".")
            if attack == "sig":
                raw = bytearray(base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)))
                raw[rng.randrange(len(raw))] ^= 1 << rng.randrange(8)
                token = f"{h}.{p}.{b64(bytes(raw))}"
            elif attack == "payload":
                changed = dict(claims)
                changed["admin"] = True
                token = f"{h}.{b64(json.dumps(changed, separators=(',', ':')).encode())}.{s}"
            elif attack == "none":
                token = f"{b64(json.dumps({'alg': 'none', 'typ': 'JWT'}).encode())}.{p}."
            elif attack == "swap":
                other = rng.choice([a for a in ALGS if a[:2] == alg[:2] and a != alg] or ["HS256"])
                token = f"{b64(json.dumps({'alg': other, 'typ': 'JWT'}).encode())}.{p}.{s}"
            elif attack == "confusion":
                secret = public(name) if alg.startswith("HS") else public(name).public_bytes(S.Encoding.PEM, S.PublicFormat.SubjectPublicKeyInfo)
                head = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
                token = f"{head}.{p}.{b64(hmac.new(secret, f'{head}.{p}'.encode(), hashlib.sha256).digest())}"
            elif attack == "pad":
                token = token + "="
            elif attack == "spelling":
                if spare_bits(s) == 0:
                    attack = "-"
                else:
                    token = f"{h}.{p}.{s[:-1]}{ALPHABET[ALPHABET.index(s[-1]) + 1]}"
            elif attack == "duplicate":
                body = json.dumps(claims, separators=(",", ":"))
                body = '{"sub":"first",' + body[1:] if body != "{}" else '{"sub":"first"}'
                body = body[:-1] + ',"sub":"second"}'
                token = resign(alg, name, {"typ": "JWT"}, body.encode())
            elif attack == "wrong_key":
                token = jwt.encode(claims, keys[key_for(alg, 1)], algorithm=alg)
            elif attack == "crit":
                token = resign(alg, name, {"typ": "JWT", "crit": ["exp"], "exp": 1}, json.dumps(claims).encode())
        said, decoded = pyjwt_says(token, alg, name, leeway, aud, iss)
        lines.append(f"dec {alg} {name} {NOW} {leeway} {aud or '-'} {iss or '-'} {token}")
        dec_expected.append({"alg": alg, "attack": attack, "pyjwt": said, "claims": decoded, "token": token})

enc_expected = []
for alg in ALGS:
    for n in range(count(ENC, alg)):
        name = key_for(alg, 0)
        plain = rng.random() < 0.5
        claims, _, _ = claim_set(plain)
        text_json = json.dumps(claims, ensure_ascii=False)
        lines.append(f"enc {alg} {name} {std64(text_json.encode())}")
        enc_expected.append({"alg": alg, "name": name, "claims": claims, "plain": plain})

open(os.path.join(work, "oracle_in.txt"), "w").write("\n".join(lines) + "\n")
with open(os.path.join(work, "oracle_cases.pickle"), "wb") as f:
    import pickle
    pickle.dump({"dec": dec_expected, "enc": enc_expected, "keys": {k: (v if isinstance(v, bytes) else v.private_bytes(S.Encoding.PEM, S.PrivateFormat.PKCS8, S.NoEncryption())) for k, v in keys.items()}}, f)
print(f"  {len(dec_expected)} tokens written by PyJWT and {len(enc_expected)} claims sets for iyi to sign, over {len(keys)} keys")
PY
  then
    echo "  the cases could not be written:"
    tail -5 "$WORK/oracle_gen.log" | sed 's/^/    /'
    status=1
  elif ! "$IYI" build --release -o "$WORK/oracle" "$WORK/oracle.iyi" >"$WORK/oracle.build.log" 2>&1; then
    echo "  the oracle did not build:"
    tail -5 "$WORK/oracle.build.log" | sed 's/^/    /'
    status=1
  else
    cat "$WORK/oracle_gen.log"
    if ! "$WORK/oracle" <"$WORK/oracle_in.txt" >"$WORK/oracle_out.txt" 2>"$WORK/oracle_err.txt"; then
      echo "  the oracle stopped: $(tail -2 "$WORK/oracle_err.txt")"
      status=1
    elif ! "$PY" - "$WORK" <<'PY'
import base64, json, os, pickle, sys
import jwt
from cryptography.hazmat.primitives import hashes, serialization as S
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

work = sys.argv[1]
cases = pickle.load(open(os.path.join(work, "oracle_cases.pickle"), "rb"))
keys = {k: (v if not v.startswith(b"-----") else S.load_pem_private_key(v, None)) for k, v in cases["keys"].items()}
got = open(os.path.join(work, "oracle_out.txt"), encoding="utf-8").read().split("\n")


def b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


# What a refusal is about, from PyJWT's exception and from iyi's sentence.
PYJWT = {"InvalidSignatureError": "signature", "ExpiredSignatureError": "exp", "ImmatureSignatureError": "nbf/iat",
         "InvalidAudienceError": "aud", "InvalidIssuerError": "iss", "InvalidSubjectError": "sub", "InvalidJTIError": "jti",
         "InvalidAlgorithmError": "alg"}


def pyjwt_kind(name, claims_missing=None):
    return PYJWT.get(name, name)


def iyi_kind(message):
    for phrase, kind in [("signature does not verify", "signature"), ("has expired", "exp"), ("not valid yet", "nbf/iat"),
                         ("issued in the future", "nbf/iat"), ("audience", "aud"), ("aud claim", "aud"), ("issuer", "iss"),
                         ("iss claim", "iss"), ("sub claim", "sub"), ("subject", "sub"), ("jti claim", "jti"),
                         ("not among the algorithms", "alg"), ("unsecured", "alg"), ("and the key is", "alg"),
                         ("padded", "pad"), ("one spelling", "spelling"), ("duplicate key", "duplicate"), ("crit", "crit")]:
        if phrase in message:
            return kind
    return message


# PyJWT's MissingRequiredClaimError names the claim it missed.
def pyjwt_case_kind(case):
    said = case["pyjwt"]
    if said == "MissingRequiredClaimError":
        return "aud" if "aud" in json.dumps(case.get("why", "aud")) else "iss"
    return pyjwt_kind(said)


dec = cases["dec"]
answers = got[: len(dec)]
bad = []
agreed_ok = agreed_err = 0
divergent = {}
for case, answer in zip(dec, answers + [""] * len(dec)):
    attack = case["attack"]
    word, _, rest = answer.partition(" ")
    if attack in ("pad", "spelling", "duplicate", "crit"):
        # Refused whatever PyJWT says: the module's header says why.
        if word == "err" and iyi_kind(rest) == attack:
            if case["pyjwt"] == "ok":
                divergent[attack] = divergent.get(attack, 0) + 1
            else:
                agreed_err += 1
        else:
            bad.append((case, answer, f"a {attack} token should be refused for it"))
        continue
    if case["pyjwt"] == "ok":
        if word == "ok" and json.loads(b64d(rest)) == case["claims"]:
            agreed_ok += 1
        else:
            bad.append((case, answer, "PyJWT took it"))
    else:
        want = pyjwt_kind(case["pyjwt"])
        if case["pyjwt"] == "MissingRequiredClaimError":
            want = iyi_kind(rest) if iyi_kind(rest) in ("aud", "iss") else "aud or iss"
        if word == "err" and iyi_kind(rest) == want:
            agreed_err += 1
        else:
            bad.append((case, answer, f"PyJWT refused it: {case['pyjwt']}"))
for case, answer, why in bad[:8]:
    print(f"  {case['alg']} attack {case['attack']}: {why}; iyi said {answer[:160]!r}\n    {case['token'][:120]}")
total_div = sum(divergent.values())
names = {"pad": "padded", "spelling": "a second spelling of the signature", "duplicate": "a claim written twice", "crit": "crit"}
print(f"  {len(dec) - len(bad)} of {len(dec)} tokens PyJWT wrote read alike: {agreed_ok} decoded to PyJWT's claims, {agreed_err} refused for PyJWT's reason, "
      f"{total_div} that PyJWT takes refused for the module header's ({', '.join(f'{n} {names[k]}' for k, n in sorted(divergent.items()))})")

enc = cases["enc"]
tokens = got[len(dec): len(dec) + len(enc)]
wrong = []
same_bytes = rfc6979 = 0
OFF = {"verify_exp": False, "verify_nbf": False, "verify_iat": False, "verify_aud": False, "verify_iss": False, "verify_sub": False, "verify_jti": False}
for case, token in zip(enc, tokens + [""] * len(enc)):
    alg, k = case["alg"], keys[case["name"]]
    verifier = k if isinstance(k, bytes) else k.public_key()
    try:
        claims = jwt.decode(token, verifier, algorithms=[alg], options=OFF)
    except Exception as e:
        wrong.append((case, token, f"PyJWT refused it: {type(e).__name__} {e}"))
        continue
    if claims != case["claims"]:
        wrong.append((case, token, f"PyJWT read {claims!r}"))
        continue
    if case["plain"] and (alg[:2] in ("HS", "RS") or alg == "EdDSA"):
        theirs = jwt.encode(case["claims"], k, algorithm=alg)
        if theirs != token:
            wrong.append((case, token, f"PyJWT writes {theirs[:100]}"))
            continue
        same_bytes += 1
    if alg == "ES256":
        head, payload, _ = token.split(".")
        der = k.sign(f"{head}.{payload}".encode(), ec.ECDSA(hashes.SHA256(), deterministic_signing=True))
        r, s = decode_dss_signature(der)
        if f"{head}.{payload}.{b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}" != token:
            wrong.append((case, token, "not RFC 6979's signature"))
            continue
        rfc6979 += 1
for case, token, why in wrong[:8]:
    print(f"  {case['alg']} {case['name']}: {why}\n    {token[:160]}")
print(f"  {len(enc) - len(wrong)} of {len(enc)} tokens iyi wrote read back by PyJWT to the claims given: {same_bytes} byte for byte PyJWT's own, "
      f"{rfc6979} ES256 signatures RFC 6979's as cryptography makes them")
sys.exit(1 if bad or wrong else 0)
PY
    then
      status=1
    fi
  fi
fi

echo
echo "== what jwt refuses"
# Each a panic: a decode that names no algorithm, a secret that is a
# public key or shorter than the hash, a key that cannot sign what it is
# asked to, a header that would contradict the algorithm. And an error
# value is not a panic until it is asked to be one.
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/jwt::{JWT, JWS, JWK, JWTAlgorithm, JWTError}
import std/json::{JSON, Any}

secret = JWK.secret(Array(UInt8).new(32, 7_u8))
token = JWT.encode({"sub" => "x"}, secret, JWTAlgorithm::HS256)
ed = JWK.ed25519(Array(UInt8).new(32, 1_u8))
pem = "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAiojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=\n-----END PUBLIC KEY-----\n"
case Program.args[0]
when "no-algorithms"
  JWT.decode(token, secret, [] of JWTAlgorithm, now: 0_i64)
when "negative-leeway"
  JWT.decode(token, secret, [JWTAlgorithm::HS256], now: 0_i64, leeway: -1_i64)
when "pem-as-secret"
  JWT.decode(token, pem, [JWTAlgorithm::EdDSA, JWTAlgorithm::HS256], now: 0_i64)
when "short-secret-decode"
  JWT.decode(token, "secret", [JWTAlgorithm::HS256], now: 0_i64)
when "short-secret-encode"
  JWT.encode({"sub" => "x"}, Array(UInt8).new(40, 1_u8), JWTAlgorithm::HS384)
when "public-key-signs"
  JWT.encode({"sub" => "x"}, ed.public, JWTAlgorithm::EdDSA)
when "wrong-kind"
  JWT.encode({"sub" => "x"}, ed, JWTAlgorithm::RS256)
when "es384-signs"
  key = JWK.parse("{\"kty\":\"EC\",\"crv\":\"P-384\",\"x\":\"r9gXgCY_q0qCvZfPfiLLZeFRBA2r4Nt_7WXAcHHhNrJ_ysKgPNRuSA6nOBsJX1TX\",\"y\":\"N0EqSFmbXFuH-oGLyHPw0wFNcAJFF77n48gD1_c5DJ9WOK7hdYnjacI-VH8RTfCI\"}").or_panic
  JWT.encode({"sub" => "x"}, key, JWTAlgorithm::ES384)
when "alg-in-header"
  JWT.encode({"sub" => "x"}, secret, JWTAlgorithm::HS256, {"alg" => Any.new("none")})
when "claims-array"
  JWT.encode(JSON.parse("[1]"), secret, JWTAlgorithm::HS256)
when "jws-other-alg"
  JWS.sign("{\"alg\":\"HS512\"}", "x", secret, JWTAlgorithm::HS256)
when "jws-header-not-json"
  JWS.sign("{alg}", "x", secret, JWTAlgorithm::HS256)
when "seed-31"
  JWK.ed25519(Array(UInt8).new(31, 1_u8))
when "oct-public"
  secret.public
when "ops-without-sign"
  key = JWK.parse("{\"kty\":\"oct\",\"k\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"key_ops\":[\"verify\"]}").or_panic
  JWT.encode({"sub" => "x"}, key, JWTAlgorithm::HS256)
when "decode-or-panic"
  JWT.decode(token + "x", secret, [JWTAlgorithm::HS256], now: 0_i64).or_panic
end
puts "accepted"
IYI
refuse() { # refuse <case> <phrase>
  if "$IYI" run "$WORK/refuse.iyi" -- "$1" >"$WORK/refuse.out" 2>&1; then
    echo "  $1 was accepted: $(tr -d '\r' <"$WORK/refuse.out" | tail -1)"
    status=1
  elif ! grep -qF -e "$2" "$WORK/refuse.out"; then
    echo "  $1 was refused without saying why: $(tr -d '\r' <"$WORK/refuse.out" | head -1)"
    status=1
  else
    echo "  $1: $(tr -d '\r' <"$WORK/refuse.out" | grep -oF -e "$2" | head -1)"
  fi
}
refuse no-algorithms "jwt: decode needs the algorithms it accepts named, and the list is empty"
refuse negative-leeway "jwt: the leeway must not be negative, not -1"
refuse pem-as-secret "jwt: an HMAC secret that is a PEM or SSH key: an asymmetric key used as a shared secret is how the RS256/HS256 confusion forges tokens"
refuse short-secret-decode "jwt: an HS256 key must be at least 32 bytes (RFC 7518 section 3.2), and this one is 6"
refuse short-secret-encode "jwt: an HS384 key must be at least 48 bytes (RFC 7518 section 3.2), and this one is 40"
refuse public-key-signs "jwt: an EdDSA token is signed with a private key, and this key holds only the public half"
refuse wrong-kind "jwt: an RS256 token, and the key is an Ed25519 key (OKP)"
refuse es384-signs "jwt: ES384 tokens can be checked here and not signed: std has no P-384 signer"
refuse alg-in-header "jwt: the header's alg is the algorithm's to write, and the header gives one"
refuse claims-array "jwt: the claims are a JSON array, and a JWT's claims are an object"
refuse jws-other-alg "jwt: the header's alg is not HS256"
refuse jws-header-not-json "jwt: the header is not JSON: "
refuse seed-31 "jwt: an Ed25519 seed is 32 bytes, not 31"
refuse oct-public "jwt: an oct key is a shared secret and has no public half"
refuse ops-without-sign "jwt: the key's key_ops do not include sign"
refuse decode-or-panic "jwt: the signature does not verify"

echo
echo "== std/jwt reads no clock and no entropy of its own"
# A pure-computation module takes the time, the keys and the bytes from
# its caller. std/jwt imports none of the platform's modules itself; what
# it reaches it reaches through std/asn1, which std/rsa, std/ecdsa and
# std/p256 read keys with and which imports std/time for the dates
# X.509 carries. That reach is the cryptography's, listed here as it is,
# and not this module's to add to.
platform="std/time std/random std/file std/dir std/env std/socket std/process std/signal std/udp std/system_roots std/user"
own=$(sed -n 's/^import \(std\/[a-z0-9_]*\).*/\1/p' "$REPO/src/std/jwt.iyi" | tr '\n' ' ')
bad=""
for module in $own; do
  case " $platform " in *" $module "*) bad="$bad $module" ;; esac
done
if [ -n "$bad" ]; then
  echo "  FAIL: std/jwt imports$bad itself"
  status=1
else
  echo "  std/jwt imports $own- none of them a platform module"
fi
if grep -nE '^\s*(lib [A-Z]|fun [a-z_]|asm\(|@\[Link)|__iyi_' "$REPO/src/std/jwt.iyi" >/dev/null; then
  echo "  FAIL: std/jwt declares C"
  status=1
fi
reached="std/jwt"
todo="std/jwt"
while [ -n "$todo" ]; do
  next=""
  for module in $todo; do
    for imported in $(sed -n 's/^import \(std\/[a-z0-9_]*\).*/\1/p' "$REPO/src/$module.iyi"); do
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
echo "  through the modules it imports it reaches:${bound:- nothing}"

echo
echo "== documentation, formatting and the five targets"
if "$IYI" doc "$REPO/src/std/jwt.iyi" >"$WORK/doc.out" 2>&1; then
  echo "  iyi doc reads std/jwt"
else
  echo "  FAIL: iyi doc: $(tail -2 "$WORK/doc.out")"
  status=1
fi
if [ -x "$REPO/bin/crystal" ]; then
  if "$REPO/bin/crystal" tool format --check "$REPO/src/std/jwt.iyi" "$REPO/bench/std_jwt_exercise.iyi" >"$WORK/format.out" 2>&1; then
    echo "  the module and the exercise are formatted"
  else
    echo "  FAIL: not formatted: $(head -3 "$WORK/format.out")"
    status=1
  fi
fi
crossed=0
for target in x86_64-linux-gnu aarch64-darwin x86_64-windows-msvc aarch64-linux-gnu x86_64-linux-musl; do
  if ! "$IYI" build --no-codegen --target "$target" "$REPO/bench/std_jwt_exercise.iyi" -o "$WORK/cross" >"$WORK/cross.log" 2>&1; then
    echo "  FAIL: the exercise does not typecheck for $target: $(grep -m1 Error "$WORK/cross.log")"
    status=1
    crossed=1
  fi
done
[ "$crossed" -eq 0 ] && echo "  the exercise typechecks for x86_64-linux-gnu, aarch64-darwin, x86_64-windows-msvc, aarch64-linux-gnu and x86_64-linux-musl"

echo
echo "== the same answers from artifacts"
# Built once with --emit-iyimod and again from those artifacts, as
# bench/std_exercise.sh builds every exercise: a method whose body the
# artifact keeps as text must read back as it was written.
mkdir -p "$WORK/art"
if ! (cd "$WORK/art" && "$IYI" build --emit-iyimod mods -o from-source "$REPO/bench/std_jwt_exercise.iyi") >"$WORK/art.log" 2>&1; then
  echo "  FAIL: the build that writes the artifacts: $(tail -2 "$WORK/art.log")"
  status=1
elif ! (cd "$WORK/art" && "$IYI" build --use-iyimod mods -o from-artifact "$REPO/bench/std_jwt_exercise.iyi") >"$WORK/art.log" 2>&1; then
  echo "  FAIL: the build from the artifacts: $(grep -m1 -A2 'In mods' "$WORK/art.log" | tr '\n' ' ')"
  status=1
else
  "$WORK/art/from-source" >"$WORK/art/source.out" 2>&1
  "$WORK/art/from-artifact" >"$WORK/art/artifact.out" 2>&1
  if cmp -s "$WORK/art/source.out" "$WORK/art/artifact.out" && grep -q "ALL CHECKS PASSED" "$WORK/art/artifact.out"; then
    echo "  built from artifacts, the exercise prints what it prints from source"
  else
    echo "  FAIL: from artifacts the exercise printed otherwise: $(tail -2 "$WORK/art/artifact.out")"
    status=1
  fi
fi

echo
echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <old> <new>: the exercise must fail on a
# copy of the module with <old> replaced, at the check that names <phrase>.
prove_broken() {
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $1 proof is unmeasured"
    return
  fi
  if ! OLD="$3" NEW="$4" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/jwt.iyi").read_text(encoding="utf-8")
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/jwt.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1), encoding="utf-8")
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_jwt_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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
prove_broken "the accepted algorithms not consulted" "A.1 where HS256 is not accepted" \
  '    return JWTError.new("alg #{name}, which is not among the algorithms accepted (#{list})") unless accepted.includes?(algorithm)' ''
prove_broken "alg none left to the algorithm table" "A.5 refused" \
  '    if name == "none"' '    if name == "nothing"'
prove_broken "any key taken for an HS token" "the RS/HS confusion with both algorithms accepted" \
  'when "HS"       then m.is_a?(JWTOct)' 'when "HS"       then true'
prove_broken "a P-384 key taken for ES256" "A.3 under a P-384 key" \
  'm.is_a?(JWTEc) && m.verifier.curve == algorithm.curve' 'm.is_a?(JWTEc)'
prove_broken "padding passed over as a byte" "a padded signature" \
  '      if b == 61_u8' '      if b == 0_u8'
prove_broken "a second spelling taken" "a second spelling of the signature" \
  '    if last & spare != 0' '    if false'
prove_broken "crit passed over" "a crit header" \
  '    if header.has_key?("crit")' '    if false'
prove_broken "a set's keys tried whatever their kid" "a kid no key has" \
  'keys = keys.select { |k| k.kid == kid_text }' 'keys = keys.select { |k| true }'
prove_broken "a JWK's use passed over" "a key for encryption" \
  '    return "the key'"'"'s use is #{usage}, not sig" if usage && usage != "sig"' ''
prove_broken "a JWK's key_ops passed over" "key_ops without verify" \
  '    return "the key'"'"'s key_ops do not include #{op}" if ops && !ops.includes?(op)' ''
prove_broken "a JWK's alg passed over" "a key bound to RS256" \
  '    return "#{algorithm.spoken} token, and the key is for #{alg}" if alg && alg != algorithm.to_s' ''
prove_broken "exp's second taken as valid" "A.1 at its exp" \
  'date.is_a?(Int64) ? date > time : date > time.to_f' 'date.is_a?(Int64) ? date >= time : date >= time.to_f'
prove_broken "the leeway not given to exp" "exp within the leeway" \
  'unless after?(number, now - leeway)' 'unless after?(number, now)'
prove_broken "the leeway not given to nbf" "nbf within the leeway" \
  '(nbf #{nbf.to_json}, now #{now})") if after?(number, now + leeway)' '(nbf #{nbf.to_json}, now #{now})") if after?(number, now)'
prove_broken "iat unchecked" "iat in the future" \
  '      return JWTError.new("the token was issued in the future (iat #{iat.to_json}, now #{now})") if after?(number, now + leeway)' ''
prove_broken "an aud taken when none is expected" "an aud when none is expected" \
  '      return JWTError.new("the token names an audience (aud), and none is expected")' '      return nil'
prove_broken "HS384 MACed with SHA-256" "PyJWT's HS384 token decodes" \
  '    when 384 then HMAC.digest(SHA384, key, data)' '    when 384 then HMAC.digest(SHA256, key, data)'
prove_broken "RS384 and PS384 hashed with SHA-256" "4.2 PS384 verifies" \
  '    when 384 then RsaHash::SHA384' '    when 384 then RsaHash::SHA256'
prove_broken "PSS's M' given seven zero bytes" "PS256 round trip" \
  'h = hash.digest(Array(UInt8).new(8, 0_u8) + m_hash + salt)' 'h = hash.digest(Array(UInt8).new(7, 0_u8) + m_hash + salt)'
# One half of the CRT taken under the other half's exponent, and the
# blinding left in: the check before a signature is given out is what
# stops both. The halves going through `pow_mod_secret` rather than
# `pow_mod` answers the same numbers, so that choice has no proof here;
# std/big's gate holds `pow_mod_secret` to `pow_mod`.
prove_broken "q's half taken under dp" "an RSA signature that does not check against its own public key" \
  's2 = (c % @q).pow_mod_secret(@dq, @q)' 's2 = (c % @q).pow_mod_secret(@dp, @q)'
prove_broken "the blinding not taken off" "an RSA signature that does not check against its own public key" \
  's = ((s2 + h * @q) * r_inverse) % @n' 's = (s2 + h * @q) % @n'
prove_broken "an ECDSA integer's sign byte left off" "the signature does not verify" \
  '    value = [0_u8] + value if value[0] >= 0x80_u8' ''
prove_broken "an RSA member's leading zero taken" "an RSA n with a leading zero byte" \
  '    if value.size > 1 && value[0] == 0_u8' '    if false'
prove_broken "an EC coordinate of any width" "an EC x short of its width" \
  '    return JWTError.new("the JWK member #{name} is #{value.size} bytes, not the curve'"'"'s #{size}") unless value.size == size' ''
prove_broken "qi unchecked" "a qi that is not q's inverse" \
  'unless bqi < bp && (bqi * bq) % bp == one' 'unless true'
prove_broken "the thumbprint's members unsorted" "A.3 thumbprint of the private key" \
  '.to_a.sorted_by { |pair| pair[0] }' '.to_a'
prove_broken "the key's kid not written" "the key's kid written in the header" \
  '        b.field("kid", kid) if kid && !header.has_key?("kid")' ''
prove_broken "sign in key_ops kept in the public half" "a signing key's public half verifies" \
  'ops.map { |op| op == "sign" ? "verify" : op }.uniq' 'ops'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/jwt exercise holds"
else
  echo "the std/jwt exercise did not hold"
fi
exit $status
