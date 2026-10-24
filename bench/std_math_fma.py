"""Cases for `Math.fma`, each with its exact answer: `bench/std_math_exercise.sh`
writes them and the exercise requires every one to the last bit.

`std_math_fma.py DOUBLES SINGLES` writes quadruples a, b, c, fma(a, b, c) -
doubles to DOUBLES and singles to SINGLES. The answer is a * b + c taken
exactly as a fraction and rounded once, to nearest with ties to even, so it
is IEEE 754's `fusedMultiplyAdd` without asking any C library for it. The
cases are the ones an fma gets wrong: sums that cancel, results on a
halfway point or a hair off one, the sums the software arm's fast path
rounds twice without its round to odd, subnormal and overflowing results, the
specials crossed with each other, and for singles the sums a double rounds
onto a single's halfway point while the exact value is just off it - where
a single's fma taken in double rounds twice.
"""
import math, random, struct, sys
from fractions import Fraction

def exact_fma(a, b, c, single=False):
    if any(math.isnan(v) for v in (a, b, c)):
        return float("nan")
    if math.isinf(a) or math.isinf(b):
        if (a == 0 or b == 0):
            return float("nan")
        p = math.copysign(1.0, a) * math.copysign(1.0, b)
        if math.isinf(c) and math.copysign(1.0, c) != p:
            return float("nan")
        return math.copysign(float("inf"), p)
    if math.isinf(c):
        return c
    exact = Fraction(a) * Fraction(b) + Fraction(c)
    if exact == 0:
        pz = math.copysign(1.0, a) * math.copysign(1.0, b)
        prod_zero_neg = pz < 0
        c_neg = math.copysign(1.0, c) < 0
        return -0.0 if (prod_zero_neg and c_neg) else 0.0
    return round_to(exact, single)

def round_to(q, single):
    # Round a nonzero rational to the nearest double (or single), ties to even.
    mant, emin, emax = (53, -1074, 1023) if not single else (24, -149, 127)
    neg = q < 0
    q = abs(q)
    e = q.numerator.bit_length() - q.denominator.bit_length()
    if Fraction(2) ** e > q:
        e -= 1
    # q in [2^e, 2^(e+1))
    if e > emax:
        return -math.inf if neg else math.inf
    lsb = max(e - (mant - 1), emin)
    scaled = q / Fraction(2) ** lsb
    n = scaled.numerator // scaled.denominator
    rem = scaled - n
    if rem > Fraction(1, 2) or (rem == Fraction(1, 2) and n % 2 == 1):
        n += 1
    v = Fraction(n) * Fraction(2) ** lsb
    if v >= Fraction(2) ** (emax + 1):
        return -math.inf if neg else math.inf
    f = float(v)
    return -f if neg else f

def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]

rnd = random.Random(7)

def rand_double(lo=-1074, hi=1023):
    return math.ldexp(rnd.random() * 2 - 1, rnd.randint(lo, hi))

cases = []
specials = [0.0, -0.0, 1.0, -1.0, math.inf, -math.inf, math.nan, 5e-324, -5e-324,
            2.2250738585072014e-308, -2.2250738585072014e-308, 1.7976931348623157e308,
            -1.7976931348623157e308, 0.5, 3.0, 1e-300, 1e300]
for a in specials:
    for b in specials:
        for c in specials:
            cases.append((a, b, c))
for _ in range(60000):
    a, b = rand_double(-60, 60), rand_double(-60, 60)
    p = a * b
    kind = rnd.randint(0, 5)
    if kind == 0:
        c = -p
    elif kind == 1:
        c = -p + math.ulp(p) * rnd.choice([0.5, -0.5, 0.25, 1.5, 1, -1])
    elif kind == 2:
        c = math.ulp(p) * rnd.choice([0.5, -0.5]) * (1 + rnd.random())
    elif kind == 3:
        c = rand_double(-120, 120)
    elif kind == 4:
        c = -p * (1 + rnd.choice([1, -1]) * 2.0 ** -rnd.randint(1, 60))
    else:
        c = rnd.choice([1, -1]) * math.ulp(p) / 2
    cases.append((a, b, c))
# Halfway: a*b exactly a double plus half its ulp, plus or minus a hair.
for _ in range(20000):
    a = float(rnd.randint(2 ** 26, 2 ** 27) | 1)
    b = float(rnd.randint(2 ** 26, 2 ** 27) | 1)
    p = a * b
    c = rnd.choice([1.0, -1.0, 0.5, -0.5, 2.0 ** -40, -(2.0 ** -40)]) * math.ulp(p) / 2
    cases.append((a * rnd.choice([1, -1]), b, c))
# Subnormal and underflowing results, and overflow.
for _ in range(30000):
    a = rand_double(-600, -450)
    b = rand_double(-600, -450)
    c = rnd.choice([0.0, -0.0, rand_double(-1074, -1000), -a * b, 5e-324, -5e-324])
    cases.append((a, b, c))
for _ in range(10000):
    a = rand_double(500, 1023)
    b = rand_double(0, 600)
    c = rnd.choice([-a * b, rand_double(1000, 1023), 1.0, -math.inf])
    cases.append((a, b, c))
for _ in range(30000):
    cases.append((rand_double(), rand_double(), rand_double()))
# Where rounding tl + pl to nearest instead of to odd rounds twice: x*y is
# 1 - 2^-2a, a double 1 and a low part below it, and z = 2^53 + 2k for an
# odd k puts z + 1 on a halfway point the exact sum is just short of.
for _ in range(20000):
    a = rnd.randint(27, 50)
    x, y = 1 + 2.0 ** -a, 1 - 2.0 ** -a
    z = 2.0 ** 53 + 2 * (2 * rnd.randint(0, 2 ** 50) + 1)
    sign = rnd.choice([1, -1])
    sx, sy = rnd.randint(-200, 200), rnd.randint(-200, 200)
    cases.append((math.ldexp(sign * x, sx), math.ldexp(y, sy), math.ldexp(sign * z, sx + sy)))

with open(sys.argv[1], "wb") as out:
    for a, b, c in cases:
        out.write(struct.pack("<dddd", a, b, c, exact_fma(a, b, c)))

# Singles, with their own specials and the halfway cases the double sum hides.
singles = []
fspec = [0.0, -0.0, 1.0, -1.0, math.inf, -math.inf, math.nan, f32(1.4e-45), f32(1.1754943508222875e-38),
         f32(3.4028234663852886e38), 0.5, 3.0]
for a in fspec:
    for b in fspec:
        for c in fspec:
            singles.append((a, b, c))
def rand_single(lo=-149, hi=127):
    return f32(math.ldexp(rnd.random() * 2 - 1, rnd.randint(lo, hi)))
for _ in range(60000):
    a, b = rand_single(-40, 40), rand_single(-40, 40)
    kind = rnd.randint(0, 3)
    p = f32(a * b)
    if kind == 0:
        c = f32(-p)
    elif kind == 1:
        c = f32(math.ldexp(rnd.choice([1, -1]), math.frexp(p)[1] - 25 - rnd.randint(0, 30))) if p else 0.0
    elif kind == 2:
        c = rand_single(-149, -100)
    else:
        c = rand_single(-40, 40)
    singles.append((a, b, c))
# The sum a double rounds onto a single's halfway point while the exact
# value is just off it: x*y = 2^s (1 - 2^-46), z an odd multiple of 2^(s+1).
for _ in range(20000):
    s = rnd.randint(-120, 100)
    m = rnd.randrange(2 ** 23 + 1, 2 ** 24, 2)
    a_exp = rnd.randint(-20, 20)
    x = f32(math.ldexp(1 + 2.0 ** -23, a_exp))
    y = f32(math.ldexp(1 - 2.0 ** -23, s - a_exp))
    z = f32(math.ldexp(m, s + 1))
    sx, sz = rnd.choice([1, -1]), rnd.choice([1, -1])
    singles.append((sx * x, y, sz * z))
for _ in range(30000):
    a, b = rand_single(-80, -60), rand_single(-80, -60)
    singles.append((a, b, rnd.choice([0.0, rand_single(-149, -126), f32(-a * b)])))
with open(sys.argv[2], "wb") as out:
    for a, b, c in singles:
        out.write(struct.pack("<ffff", a, b, c, exact_fma(a, b, c, single=True)))
