#!/usr/bin/env python3
"""Measures the macro sites of the prelude (src/iyi) and the port's own source
(src/compiler), site by site, against the hosted compiler's expansion.

The gate (bench/selfhost_macros_exercise.sh) runs the oracle and the port with
--sites on every file listed here and keeps one dump per driver per file. This
script pairs the two dumps site by site and classifies each pair:

  identical      both expand to the same text, or both fail the same way
  refused        the port fails on a site the hosted compiler expands
  differing      both expand to different text; or one side fails and the other
                 expands (the port expanding where the hosted compiler fails is
                 the silent wrong expansion this slice removes)
  needs-context  reads @type, @top_level, @def or @caller on both sides; the
                 enclosing type is not passed in yet, so it is not compared
  macro-body     inside a macro definition: expanded when that macro is called
  unpaired       a site on one side only, or a file one driver could not read

    python3 bench/macro_sites.py --list                  # name<TAB>path per file
    python3 bench/macro_sites.py DUMPDIR                 # summary to stdout
    python3 bench/macro_sites.py DUMPDIR --table PATH    # also write the table
    python3 bench/macro_sites.py DUMPDIR --check         # exit 1 on a floor breach

bench/macro_sites.floor keeps the identical-site floor and unreadable-file
ceiling, followed by named exceptions. A new or stale exception fails --check.
"""
import collections
import os
import re
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
FLOOR = os.path.join(REPO, "bench/macro_sites.floor")
SITE_LINE = re.compile(r"^site (\d+) (\S+) (\d+:\d+) (\S+) (.*)$")
MESSAGE = re.compile(r" message=(.*)$")
ERROR_POSITION = re.compile(r"^error (\d+):(\d+) message=")
CATEGORIES = ["identical", "refused", "differing", "needs-context", "macro-body", "unpaired"]


def source_files():
    """The prelude's .iyi files, then the port's .iyi files, sorted, relative to REPO."""
    files = []
    iyi_dir = os.path.join(REPO, "src/iyi")
    for name in sorted(os.listdir(iyi_dir)):
        if name.endswith(".iyi"):
            files.append(os.path.join("src/iyi", name).replace(os.sep, "/"))
    for dirpath, dirnames, filenames in os.walk(os.path.join(REPO, "src/compiler")):
        dirnames.sort()
        for name in sorted(filenames):
            if name.endswith(".iyi"):
                files.append(os.path.relpath(os.path.join(dirpath, name), REPO).replace(os.sep, "/"))
    return files


def dump_name(rel):
    return rel.replace("/", "__")


def read_dump(path):
    """Returns (error, sites). `error` is set when the driver failed on the file."""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    sites = []
    for line in text.split("\n"):
        if line.startswith("file-error"):
            return line, []
        m = SITE_LINE.match(line)
        if m:
            sites.append({
                "index": int(m.group(1)),
                "kind": m.group(2),
                "where": m.group(3),
                "context": m.group(4),
                "status": m.group(5),
            })
    return None, sites


def outcome(status):
    if status.startswith("text="):
        return "text"
    if status.startswith("error "):
        return "error"
    return status


def message_of(status):
    m = MESSAGE.search(status)
    return m.group(1) if m else status


def classify(o, p):
    """(category, reason) for one site the two drivers both listed."""
    if o["status"] == "macro-body" and p["status"] == "macro-body":
        return "macro-body", ""
    if o["status"] == "needs-context" and p["status"] == "needs-context":
        return "needs-context", ""
    if o["status"] == p["status"]:
        return "identical", ""
    ot = outcome(o["status"])
    pt = outcome(p["status"])
    if ot == "text" and pt == "error":
        return "refused", message_of(p["status"])[:110]
    if ot == "error" and pt == "error" and message_of(o["status"]) == message_of(p["status"]):
        ol = ERROR_POSITION.match(o["status"])
        pl = ERROR_POSITION.match(p["status"])
        if ol and pl and ol.group(1) == pl.group(1) and int(pl.group(2)) == int(ol.group(2)) + 1:
            return "differing", "error location differs"
    if ot == "text" and pt == "text":
        return "differing", "text differs"
    if ot == "error":
        return "differing", f"oracle error {message_of(o['status'])[:90]}; port {pt}"
    return "differing", f"oracle {ot}, port {pt}"


def pair_file(rel, dump_dir):
    """Rows for one file, one dict per site, and the error when a driver could not run."""
    name = dump_name(rel)
    rows = []
    try:
        o_err, o_sites = read_dump(os.path.join(dump_dir, name + ".oracle"))
    except FileNotFoundError as e:
        return [{"file": rel, "where": "-", "kind": "-", "context": "-",
                 "category": "unpaired", "reason": f"oracle: no dump"}], "oracle: no dump"
    if o_err:
        with open(os.path.join(dump_dir, name + ".oracle.err"), encoding="utf-8",
                  errors="replace") as f:
            detail = f.readline().strip()[:110]
        reason = f"oracle: {o_err}: {detail}"
        return [{"file": rel, "where": "-", "kind": "-", "context": "-",
                 "category": "unpaired", "reason": reason}], reason
    try:
        p_err, p_sites = read_dump(os.path.join(dump_dir, name + ".port"))
    except FileNotFoundError:
        p_err, p_sites = "file-error port: no dump", []
    if p_err:
        for o in o_sites:
            rows.append({"file": rel, "where": o["where"], "kind": o["kind"], "context": o["context"],
                         "category": "unpaired", "reason": f"port: {p_err}"})
        if not o_sites:
            rows.append({"file": rel, "where": "-", "kind": "-", "context": "-",
                         "category": "unpaired", "reason": f"port: {p_err}"})
        return rows, f"port: {p_err}"
    for i, o in enumerate(o_sites):
        if i >= len(p_sites):
            rows.append({"file": rel, "where": o["where"], "kind": o["kind"], "context": o["context"],
                         "category": "unpaired", "reason": f"port lists {len(p_sites)} sites, oracle {len(o_sites)}"})
            continue
        p = p_sites[i]
        if (o["kind"], o["where"], o["context"]) != (p["kind"], p["where"], p["context"]) and \
                (o["status"], p["status"]) not in (("macro-body", "macro-body"), ("needs-context", "needs-context")):
            for side, site in (("oracle", o), ("port", p)):
                rows.append({"file": rel, "where": site["where"], "kind": site["kind"],
                             "context": site["context"], "category": "unpaired",
                             "reason": f"{side}: site identity differs"})
            continue
        category, reason = classify(o, p_sites[i])
        rows.append({"file": rel, "where": o["where"], "kind": o["kind"], "context": o["context"],
                     "category": category, "reason": reason})
    for p in p_sites[len(o_sites):]:
        rows.append({"file": rel, "where": p["where"], "kind": p["kind"], "context": p["context"],
                     "category": "unpaired", "reason": f"oracle lists {len(o_sites)} sites, port {len(p_sites)}"})
    return rows, None


def floors(path):
    """Read the floors and exact exception identities with their reasons."""
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    if len(lines) < 2:
        raise ValueError("expected an identical floor and unreadable ceiling")
    least_identical, most_unreadable = int(lines[0]), int(lines[1])
    if least_identical < 0 or most_unreadable < 0:
        raise ValueError("floors and ceilings must be non-negative")
    expected = collections.Counter()
    for number, line in enumerate(lines[2:], 3):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("|", 6)
        if len(fields) != 7 or any(not field for field in fields):
            raise ValueError(f"line {number}: expected category|file|site|kind|context|case|reason")
        category, rel, where, kind, context, case, reason = fields
        if category not in ("differing", "unpaired", "unreadable"):
            raise ValueError(f"line {number}: invalid category {category}")
        key = (category, rel, where, kind, context, case)
        expected[key] += 1
        if expected[key] != 1:
            raise ValueError(f"line {number}: duplicate exception {key}")
    return least_identical, most_unreadable, expected


def exception_reason(reason):
    # A parser syntax error is the named limitation. A missing dump or an
    # unrelated crash of that file is not the same tolerated case.
    if reason.startswith("oracle: file-error") and "Iyi::SyntaxException" in reason:
        return "hosted syntax error"
    return reason


def exception_key(row):
    return (row["category"], row["file"], row["site"], row["kind"], row["context"],
            exception_reason(row["reason"]))


def show_exception(key):
    category, rel, where, kind, context, reason = key
    return f"{category} {rel}:{where} {kind} {context}: {reason}"


def table_markdown(files, rows):
    counts = collections.Counter(r["category"] for r in rows)
    total = len(rows)
    compared = counts["identical"] + counts["refused"] + counts["differing"] + counts["unpaired"]
    unreadable = sum(1 for r in rows if r["where"] == "-")
    out = []
    out.append("# Macro sites: the prelude and the port's own source")
    out.append("")
    out.append("Generated by `bench/macro_sites.py` from the dumps of `bench/selfhost_macros_exercise.sh`.")
    out.append("To regenerate: `MACRO_GATE_KEEP=<dir> bash bench/selfhost_macros_exercise.sh`, then")
    out.append("`python3 bench/macro_sites.py <dir>/sites --table src/compiler/macros/SITES.md`. Do not edit by hand.")
    out.append("")
    out.append("Scope: every `.iyi` file in `src/iyi` and `src/compiler`. A site is one top-level `{% if %}`,")
    out.append("`{% for %}`, `{{ }}` or `verbatim` node: the unit the hosted compiler expands. Both sides use the")
    out.append("host target. A site is `identical` when the oracle and the port agree on its text, or on how it")
    out.append("fails. The oracle is the hosted compiler's expansion of the file parsed on its own, with no type")
    out.append("information, so a site that reads a type is `needs-context` or fails on the oracle side.")
    out.append("")
    out.append("The `identical` count is the scoreboard and may only rise. The count of files the hosted parser")
    out.append("cannot read may only fall (`bench/macro_sites.floor`).")
    out.append("")
    out.append("## Counts")
    out.append("")
    out.append("| measure | sites |")
    out.append("|---|---|")
    out.append(f"| files | {len(files)} |")
    out.append(f"| files the hosted parser cannot read (their sites are unpaired) | {unreadable} |")
    out.append(f"| sites, all | {total} |")
    out.append(f"| expanded identically | {counts['identical']} |")
    out.append(f"| differing | {counts['differing']} |")
    out.append(f"| refused by the port | {counts['refused']} |")
    out.append(f"| unpaired | {counts['unpaired']} |")
    out.append(f"| needs the enclosing type (`@type`, `@top_level`, `@def`, `@caller`) | {counts['needs-context']} |")
    out.append(f"| in a macro body (expanded when called) | {counts['macro-body']} |")
    out.append(f"| compared | {compared} |")
    out.append("")
    out.append("## Top reasons")
    out.append("")
    out.append("| sites | category | reason |")
    out.append("|---|---|---|")
    reasons = collections.Counter()
    for r in rows:
        if r["category"] in ("refused", "differing", "unpaired"):
            reasons[(r["category"], r["reason"])] += 1
    for (category, reason), n in reasons.most_common(25):
        out.append(f"| {n} | {category} | {reason.replace('|', chr(92) + '|')} |")
    out.append("")
    out.append("## Per file")
    out.append("")
    out.append("| file | sites | identical | differing | refused | unpaired | needs-context | macro-body |")
    out.append("|---|---|---|---|---|---|---|---|")
    for rel in files:
        fr = [r for r in rows if r["file"] == rel]
        c = collections.Counter(r["category"] for r in fr)
        out.append(f"| `{rel}` | {len(fr)} | {c['identical']} | {c['differing']} | {c['refused']} | "
                   f"{c['unpaired']} | {c['needs-context']} | {c['macro-body']} |")
    out.append("")
    out.append("## Sites not identical")
    out.append("")
    out.append("Every site that is differing, refused, unpaired or needs the enclosing type. Macro-body sites are")
    out.append("left out: each is checked when its macro is called.")
    out.append("")
    out.append("| where | kind | context | category | reason |")
    out.append("|---|---|---|---|---|")
    for r in rows:
        if r["category"] in ("identical", "macro-body"):
            continue
        reason = r["reason"].replace("|", chr(92) + "|")
        where = f"{r['file']}:{r['where']}" if r["where"] != "-" else r["file"]
        out.append(f"| `{where}` | {r['kind']} | {r['context']} | {r['category']} | {reason} |")
    out.append("")
    return "\n".join(out)


def main(argv):
    if "--list" in argv:
        for rel in source_files():
            sys.stdout.buffer.write(f"{dump_name(rel)}\t{rel}\n".encode("utf-8"))
        return 0
    table = None
    if "--table" in argv:
        table = argv[argv.index("--table") + 1]
    floor = FLOOR
    if "--floor" in argv:
        floor = argv[argv.index("--floor") + 1]
    args = [a for a in argv if not a.startswith("--") and a != table and a != floor]
    if not args:
        print(__doc__)
        return 2
    dump_dir = args[0]

    files = source_files()
    rows = []
    unreadable = []
    for rel in files:
        file_rows, err = pair_file(rel, dump_dir)
        # The ordinal among the same kind and enclosing context identifies a
        # site even when unrelated edits move its source line.
        ordinals = collections.Counter()
        for row in file_rows:
            if row["where"] == "-":
                row["site"] = "-"
            else:
                group = (row["kind"], row["context"])
                row["site"] = f"#{ordinals[group]}"
                ordinals[group] += 1
        rows.extend(file_rows)
        if err:
            unreadable.append((rel, err))

    counts = collections.Counter(r["category"] for r in rows)
    print(f"files {len(files)}, sites {len(rows)}")
    for c in CATEGORIES:
        print(f"  {c}: {counts[c]}")
    hosted_unreadable = [(rel, err) for rel, err in unreadable if err.startswith("oracle: ")]
    print(f"  files the hosted compiler could not read: {len(hosted_unreadable)}")
    print(f"  files the port could not read: {len(unreadable) - len(hosted_unreadable)}")

    if table:
        with open(table, "w", encoding="utf-8") as f:
            f.write(table_markdown(files, rows))
        print(f"wrote {os.path.relpath(table, REPO) if table.startswith(REPO) else table}")

    if "--check" in argv:
        try:
            least_identical, most_unreadable, expected = floors(floor)
        except (OSError, ValueError) as e:
            print(f"  invalid census floor: {e}")
            return 1
        status = 0
        if counts["identical"] < least_identical:
            print(f"  identical {counts['identical']} is below the floor {least_identical}")
            status = 1
        else:
            print(f"  identical {counts['identical']} meets the floor {least_identical}")
        if len(hosted_unreadable) > most_unreadable:
            print(f"  {len(hosted_unreadable)} files unreadable by the hosted compiler, above the allowed {most_unreadable}")
            status = 1
        else:
            print(f"  unreadable files {len(hosted_unreadable)} within the allowed {most_unreadable}")
        actual = collections.Counter(exception_key(r) for r in rows if r["category"] in ("differing", "unpaired"))
        for rel, reason in unreadable:
            actual[("unreadable", rel, "-", "-", "-", exception_reason(reason))] += 1
        for key, count in sorted((actual - expected).items()):
            print(f"  unexpected {show_exception(key)} (count {count})")
            status = 1
        for key, count in sorted((expected - actual).items()):
            print(f"  missing listed {show_exception(key)} (count {count})")
            status = 1
        if actual == expected:
            print(f"  named exceptions match: {sum(actual.values())}")
        return status
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
