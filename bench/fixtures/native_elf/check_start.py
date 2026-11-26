#!/usr/bin/env python3
"""Checks that a start-code module, as the LLVM bridge translates it, installs the environment block of the initial stack in
`environ`.

Usage: check_start.py START.ll [START.ll]...

The kernel enters a static program with the stack pointer at argc, then argv[0] ... argv[argc-1], a NULL, then envp[0] ...
and a NULL (System V ABI, process initialization). The start code's `__iyi_start_c(ptr %sp)` works envp out from that and
stores it in `environ`, which is what the program's ENV reads. This script takes the translated function, evaluates the
instructions that define the stored value for several argc against a fake stack pointer, and requires `environ` to be
sp + 8 * (argc + 2): the word after argv's terminator, where a libc-linked program finds it. Storing argv's own
terminator, sp + 8 * (argc + 1), hands the program an empty environment, and passes every check that does not read one.

It judges the translation, which is what llc compiles, and not the machine code: the corpus run on Linux compares what the
program reads. The evaluator reads the instructions the start code uses for this (the load of argc from sp, getelementptr
on bytes, the integer operators and the casts). Any other instruction in the chain is one it does not read, and it says
so, status 2.

Exit status: 0 when every START.ll holds, 1 on a difference (the first is printed as "decisive: ..."), 2 when it cannot
judge.
"""
import re
import sys

STACK = 0x7FFC00001000
ARGCS = (0, 1, 2, 3, 7)
MASK = (1 << 64) - 1
OPERATORS = {
    "add": lambda a, b: a + b,
    "sub": lambda a, b: a - b,
    "mul": lambda a, b: a * b,
    "shl": lambda a, b: a << b,
    "lshr": lambda a, b: a >> b,
    "and": lambda a, b: a & b,
    "or": lambda a, b: a | b,
    "xor": lambda a, b: a ^ b,
}


class Unjudged(Exception):
    """The start code uses something this check does not read."""


def function_lines(text, name):
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if line.startswith("define ") and f"@{name}(" in line:
            start = index
            break
    if start is None:
        raise Unjudged(f"there is no function @{name}")
    body = []
    for line in lines[start + 1:]:
        if line.strip() == "}":
            return body
        body.append(line.strip())
    raise Unjudged(f"@{name} is not closed")


def evaluate(defs, operand, argc):
    memo = {}

    def value(text):
        if text.startswith("%"):
            return named(text[1:])
        if text == "null":
            return 0
        try:
            return int(text, 0) & MASK
        except ValueError:
            raise Unjudged(f"the operand {text} is not one this check reads")

    def named(name):
        if name == "sp":
            return STACK
        if name not in memo:
            if name not in defs:
                raise Unjudged(f"%{name} is not defined in the function")
            memo[name] = run(defs[name]) & MASK
        return memo[name]

    def run(expr):
        match = re.match(r"load i64, ptr ([^\s,]+)(?:, align \d+)?$", expr)
        if match:
            if value(match.group(1)) != STACK:
                raise Unjudged(f"a load that is not argc from the stack pointer: {expr}")
            return argc
        match = re.match(r"getelementptr (?:inbounds )?i8, ptr ([^\s,]+), i64 ([^\s,]+)$", expr)
        if match:
            return value(match.group(1)) + value(match.group(2))
        match = re.match(r"(add|sub|mul|shl|lshr|and|or|xor) (?:nuw |nsw |exact )*i64 ([^\s,]+), ([^\s,]+)$", expr)
        if match:
            return OPERATORS[match.group(1)](value(match.group(2)), value(match.group(3)))
        match = re.match(r"(ptrtoint|inttoptr|bitcast|zext|trunc) (?:ptr|i\d+) ([^\s,]+) to (ptr|i(\d+))$", expr)
        if match:
            result = value(match.group(2))
            if match.group(1) == "trunc":
                result &= (1 << int(match.group(4))) - 1
            return result
        raise Unjudged(f"an instruction this check does not read: {expr}")

    return value(operand)


def check(path):
    """None when the start code installs the environment block, else the first difference."""
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    defs = {}
    stores = []
    for line in function_lines(text, "__iyi_start_c"):
        match = re.match(r"%([\w.$-]+) = (.+)$", line)
        if match:
            defs[match.group(1)] = match.group(2)
            continue
        match = re.match(r"store ptr ([^\s,]+), ptr @environ(?:, align \d+)?$", line)
        if match:
            stores.append(match.group(1))
    if len(stores) != 1:
        raise Unjudged(f"expected one store to @environ in @__iyi_start_c, found {len(stores)}")
    for argc in ARGCS:
        got = evaluate(defs, stores[0], argc)
        want = STACK + 8 * (argc + 2)
        if got != want:
            where = " (argv's terminator)" if got == STACK + 8 * (argc + 1) else ""
            return (f"{path}: with argc {argc} the start code stores environ = sp+{got - STACK}{where}, "
                    f"and the initial stack puts the environment at sp+{want - STACK}")
    return None


def main(argv):
    if len(argv) < 2:
        print("usage: check_start.py START.ll [START.ll]...")
        return 2
    for path in argv[1:]:
        try:
            difference = check(path)
        except (OSError, Unjudged) as error:
            print(f"cannot judge {path}: {error}")
            return 2
        if difference is not None:
            print(f"decisive: {difference}")
            return 1
        print(f"{path}: environ is sp + 8 * (argc + 2) for argc {', '.join(str(n) for n in ARGCS)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
