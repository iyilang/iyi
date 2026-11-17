#!/usr/bin/env python3
"""Compares the own-source lowering blocks of the hosted oracle and the port, type by type.

  lower_types_compare.py <oracle output> <port output>

Each output holds one block per type a file declares, opened by a `== <name>` line (see
bench/selfhost_lower_types_oracle.cr, `own_text`). The script prints one line:

  declared identical oracle_failed missing differs

A type is identical when the port prints the same block. A type the oracle could not lower (its
block is an `ERROR:` line) is counted as oracle_failed, not as a difference: the hosted side has no
answer to compare with. A type the port did not print is missing. Anything else differs.

Then one `REASON <count> <reason>` line for each reason a type differs, ranked by count, and one
`EXAMPLE <reason>\t<type name>` line per reason, naming the first type that has it. A reason is the
root cause of the difference, not the first printed field that differs: an instance variable the
declaration pass recorded in another order moves every later offset, and that is one reason.
"""
import re
import sys
from collections import Counter


def blocks(path):
    order = []
    found = {}
    name = None
    buf = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if line.startswith("== "):
                if name is not None:
                    found[name] = buf
                name = line[3:].rstrip("\n")
                order.append(name)
                buf = [line]
            elif name is not None:
                buf.append(line.rstrip("\n"))
    if name is not None:
        found[name] = buf
    return order, found


def fields(block):
    out = {}
    for line in block[1:]:
        if ": " in line:
            key, value = line.split(": ", 1)
            out[key] = value
        elif line.endswith(":"):
            out[line[:-1]] = ""
    return out


def ivar_list(value):
    """The `@name:Type` entries of an ivars line, split at the spaces outside parentheses."""
    if value in ("-", ""):
        return []
    parts, depth, current = [], 0, ""
    for ch in value:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == " " and depth == 0:
            if current:
                parts.append(current)
            current = ""
        else:
            current += ch
    if current:
        parts.append(current)
    return parts


def shape(text):
    """A coarse LLVM type shape, for the reason text of a layout difference."""
    if text in ("-", ""):
        return "-"
    if text in ("void", "ptr", "float", "double") or re.fullmatch(r"i\d+", text):
        return text
    if text.startswith("%"):
        return "%named"
    if text.startswith("{") or text.startswith("<{"):
        return "literal struct"
    if text.startswith("["):
        return "array"
    return text[:20]


def generalise(message):
    """A hosted or port error with its names taken out, so one reason groups every instance."""
    message = re.sub(r"LibLLVM::\w+", "LibLLVM::*", message)
    message = re.sub(r"'[^']*'", "'*'", message)
    message = re.sub(r"for [^ ]+ is", "for * is", message)
    message = re.sub(r"for [^ ]+:", "for *:", message)
    message = re.sub(r"Compiler::\S+", "*", message)
    return message[:110]


def error_line(block):
    for line in block:
        if line.startswith("ERROR: "):
            return line[7:]
    return None


def classify(ob, pb):
    """The root-cause reason for a type whose blocks differ, from the oracle's and the port's block."""
    message = error_line(ob)
    if message is not None:
        return "hosted cannot lower: " + generalise(message)
    if pb is None:
        return "port: no block"
    message = error_line(pb)
    if message is not None:
        return "port cannot lower: " + generalise(message)
    o, p = fields(ob), fields(pb)
    if o.get("ivars") != p.get("ivars"):
        oi = ivar_list(o.get("ivars", "-"))
        pi = ivar_list(p.get("ivars", "-"))
        onames = [x.split(":", 1)[0] for x in oi]
        pnames = [x.split(":", 1)[0] for x in pi]
        if any(x.endswith(":untyped") for x in pi):
            return "ivars: untyped on port side (NEEDS row 15)"
        if sorted(onames) == sorted(pnames) and onames != pnames:
            return "ivars: declared in a different order (declarations)"
        if set(onames) - set(pnames):
            return "ivars: missing on port side (declarations)"
        if set(pnames) - set(onames):
            return "ivars: extra on port side (declarations)"
        if onames == pnames:
            for a, b in zip(oi, pi):
                if a == b:
                    continue
                oty, pty = a.split(":", 1)[1], b.split(":", 1)[1]
                if "(" in oty and "(" in pty and oty.split("(")[0] == pty.split("(")[0]:
                    return "ivars: generic instance lost its type arguments (declarations, NEEDS row 3)"
                return "ivars: type text differs"
        return "ivars: other"
    for key in ["llvm_type", "llvm_type(wants_size)", "llvm_struct_type", "offsets", "llvm_embedded_type",
                "size", "align", "passed_by_value", "layout", "c_type", "c_return_type", "embedded_c_type",
                "intrinsic_return_type", "passed_indirectly", "proc_function", "closure_function"]:
        if o.get(key) == p.get(key):
            continue
        ov, pv = o.get(key, "<none>"), p.get(key, "<none>")
        if key in ("llvm_type", "llvm_type(wants_size)", "llvm_embedded_type", "c_type"):
            return f"{key}: oracle {shape(ov)}, port {shape(pv)}"
        if key == "offsets":
            if o.get("llvm_struct_type") != p.get("llvm_struct_type"):
                return "llvm_struct_type differs (offsets follow)"
            return "offsets differ, same ivars and same struct type"
        if key == "size":
            return f"size differs: oracle {ov}, port {pv}"
        return f"{key} differs"
    return "block differs in no known field"


def main():
    oracle_order, oracle = blocks(sys.argv[1])
    _, port = blocks(sys.argv[2])
    declared = len(oracle_order)
    identical = failed = missing = differs = 0
    reasons = Counter()
    examples = {}
    for name in oracle_order:
        ob = oracle[name]
        if error_line(ob) is not None:
            failed += 1
            reason = classify(ob, None)
        elif name not in port:
            missing += 1
            reason = "port: no block"
        elif port[name] == ob:
            identical += 1
            continue
        else:
            differs += 1
            reason = classify(ob, port[name])
        reasons[reason] += 1
        examples.setdefault(reason, name)
    print(declared, identical, failed, missing, differs)
    for reason, count in sorted(reasons.items(), key=lambda kv: (-kv[1], kv[0])):
        print("REASON", count, reason)
        print("EXAMPLE", reason + "\t" + examples[reason])


if __name__ == "__main__":
    main()
