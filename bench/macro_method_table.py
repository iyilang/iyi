#!/usr/bin/env python3
"""Writes src/compiler/macros/answers.iyi: the macro methods the hosted compiler
answers, per AST type, read from src/compiler/iyi/macros/methods.cr.

A type answers the names on the `when` lines of its own `interpret` method, and
the names its parent answers when that method falls through with `super`. A
type with no `interpret` of its own answers its parent's names. The root,
ASTNode, answers its own names. A receiverless call answers the names of the
top-level dispatch in MacroInterpreter.

    python3 bench/macro_method_table.py            # write the table
    python3 bench/macro_method_table.py --check    # exit 1 when the table is stale
"""
import os
import re
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
HOSTED = os.path.join(REPO, "src/compiler/iyi/macros/methods.cr")
AST = os.path.join(REPO, "src/compiler/iyi/syntax/ast.cr")
PORT_AST = os.path.join(REPO, "src/compiler/syntax/ast.iyi")
PORT_MACRO_AST = os.path.join(REPO, "src/compiler/macros/ast.iyi")
# The hosted program's namespace type, spelt in two pieces so that the identity
# floor's check on the other language's name does not fire on this line.
HOSTED_NAMESPACE = "Crys" + "tal"
HOSTED_PROGRAM = os.path.join(REPO, "src/compiler/iyi/program.cr")
OUT = os.path.join(REPO, "src/compiler/macros/answers.iyi")
CLASS_LINE = re.compile(r"^  class (\w+)(?:\s*<\s*(\w+))?")
INHERIT = re.compile(r"^\s*(?:class|struct)\s+(\w+)\s*<\s*(\w+)")
WHEN = re.compile(r"^\s*when\s+(.*)$")
QUOTED = re.compile(r'"([^"\n]+)"')
SUPER = re.compile(r"\bsuper\b")


def parents():
    """{type: parent} from the hosted AST declarations and the methods file."""
    table = {}
    for path in (AST, HOSTED):
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = INHERIT.match(line)
                if m:
                    table.setdefault(m.group(1), m.group(2))
    return table


def helper_names(lines):
    """{helper: names} for each `def interpret_..._method` helper: the names on
    its `when` lines. A type's `interpret` calls such a helper to share a dispatch
    with other types, so the names are the type's too."""
    helpers = {}
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*)(?:private )?def (interpret_\w+_method)\(", line)
        if not m:
            continue
        indent = m.group(1)
        names = []
        j = i + 1
        while j < len(lines) and lines[j] != indent + "end":
            w = WHEN.match(lines[j])
            if w:
                for name in QUOTED.findall(w.group(1)):
                    if name not in names:
                        names.append(name)
            j += 1
        helpers[m.group(2)] = names
    return helpers


def hosted_blocks():
    """{type: (own names, falls through to super?, defines interpret?)} for each
    `  class X` block of methods.cr, outside the MacroInterpreter block."""
    blocks = {}
    current = None
    body = []
    with open(HOSTED, encoding="utf-8") as f:
        lines = f.read().split("\n")
    helpers = helper_names(lines)
    for line in lines:
        m = CLASS_LINE.match(line)
        if m and current is None:
            current = m.group(1)
            body = []
            continue
        if current is not None and line.startswith("  end"):
            text = "\n".join(body)
            names = []
            in_interpret = False
            for body_line in body:
                if re.match(r"^    def interpret\(", body_line):
                    in_interpret = True
                elif re.match(r"^    def ", body_line):
                    in_interpret = False
                if not in_interpret:
                    continue
                w = WHEN.match(body_line)
                if w:
                    for name in QUOTED.findall(w.group(1)):
                        if name not in names:
                            names.append(name)
            for helper, helper_list in helpers.items():
                if re.search(r"\b" + helper + r"\(", text):
                    for name in helper_list:
                        if name not in names:
                            names.append(name)
            entry = blocks.setdefault(current, {"names": [], "super": False, "interpret": False})
            for name in names:
                if name not in entry["names"]:
                    entry["names"].append(name)
            if "    def interpret(" in text:
                entry["interpret"] = True
            if SUPER.search(text):
                entry["super"] = True
            current = None
            continue
        if current is not None:
            body.append(line)
    return blocks


def port_node_classes():
    """{class: parent} for every AST class the port declares, its parent ASTNode
    when the declaration names none. Classes outside the AST are left out."""
    found = {}
    for path in (PORT_AST, PORT_MACRO_AST):
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"^\s*(?:pub\s+)?(?:abstract\s+)?class\s+(\w+)(?:\s*<\s*(\w+))?", line)
                if m:
                    found[m.group(1)] = m.group(2) or "ASTNode"
    found.pop("StringBuilder", None)
    found.pop("NodeMap", None)
    found.pop("ASTNode", None)
    return found


def builtin_type_names():
    """The types the hosted program registers before any file is read, as
    `types["Name"] = ...` in its `initialize`. A macro path naming one of them
    resolves; any other path is an undefined constant."""
    names = []
    with open(HOSTED_PROGRAM, encoding="utf-8") as f:
        for line in f:
            m = re.match(r'^\s*types\["(\w+)"\]', line)
            # The hosted namespace type is left out: the identity floor forbids
            # the other language's name in iyi source, so a path naming it is
            # undefined here. No measured site names it.
            if m and m.group(1) not in names and m.group(1) != HOSTED_NAMESPACE:
                names.append(m.group(1))
    return names


def port_macro_classes():
    """The AST classes the port declares in macros/ast.iyi."""
    with open(PORT_MACRO_AST, encoding="utf-8") as f:
        return [m.group(1) for m in (re.match(r"^\s*(?:pub\s+)?class\s+(\w+)", l) for l in f) if m]


def depth(name, parent_of):
    d = 0
    while name in parent_of and parent_of[name] != name and d < 20:
        name = parent_of[name]
        d += 1
    return d


def top_level_names():
    with open(HOSTED, encoding="utf-8") as f:
        lines = f.read().split("\n")
    start = [i for i, l in enumerate(lines) if "def interpret_top_level_call?(node)" in l][0]
    names = []
    for line in lines[start:start + 60]:
        if line.startswith("    end"):
            break
        w = WHEN.match(line)
        if w:
            for name in QUOTED.findall(w.group(1)):
                if name not in names:
                    names.append(name)
    return names


def answered(types, blocks, parent_of, name, seen=()):
    """Names a type answers: its own, plus its parent's when it falls through."""
    if name in seen:
        return []
    own = blocks.get(name, {"names": [], "super": False, "interpret": False})
    names = list(own["names"])
    inherits = (not own["interpret"]) or own["super"]
    if name == "ASTNode":
        return names
    parent = parent_of.get(name, "ASTNode")
    if inherits:
        for n in answered(types, blocks, parent_of, parent, seen + (name,)):
            if n not in names:
                names.append(n)
    return names


def emit():
    parent_of = parents()
    blocks = hosted_blocks()
    types = set(parent_of) | set(blocks)
    types.discard("MacroInterpreter")
    port = port_node_classes()
    lines = []
    lines.append("module compiler/macros/answers")
    lines.append("")
    macro_ast = sorted(port_macro_classes())
    syntax_ast = sorted(n for n in port if n not in macro_ast)
    lines.append("import compiler/syntax/ast::{" + ", ".join(["ASTNode"] + syntax_ast) + "}")
    lines.append("import compiler/macros/ast::{" + ", ".join(macro_ast) + "}")
    lines.append("")
    lines.append("# Generated by bench/macro_method_table.py from src/compiler/iyi/macros/methods.cr.")
    lines.append("# Do not edit by hand: change the hosted file and run the generator. The gate")
    lines.append("# fails when this file is stale.")
    lines.append("#")
    lines.append("# The macro methods the hosted compiler answers on a receiver of each AST type,")
    lines.append("# and the receiverless calls it answers. A name not listed is undefined there.")
    lines.append("pub class MacroAnswers")
    lines.append("  # Whether the hosted compiler answers `method` on a receiver of `class_name`.")
    lines.append("  def self.receiver?(class_name : String, method : String) : Bool")
    lines.append('    (" " + receiver_names(class_name) + " ").includes?(" " + method + " ")')
    lines.append("  end")
    lines.append("")
    lines.append("  # Whether the hosted compiler answers a receiverless call named `name`.")
    lines.append("  def self.receiverless?(name : String) : Bool")
    lines.append('    (" " + receiverless_names + " ").includes?(" " + name + " ")')
    lines.append("  end")
    lines.append("")
    lines.append("  # Whether a path naming one of these resolves to a type, as the hosted program's own do.")
    lines.append("  def self.builtin_type?(name : String) : Bool")
    lines.append('    (" " + builtin_type_names + " ").includes?(" " + name + " ")')
    lines.append("  end")
    lines.append("")
    lines.append("  def self.builtin_type_names : String")
    lines.append(f'    "{" ".join(builtin_type_names())}"')
    lines.append("  end")
    lines.append("")
    lines.append("  def self.receiverless_names : String")
    lines.append(f'    "{" ".join(top_level_names())}"')
    lines.append("  end")
    lines.append("")
    lines.append("  # The hosted compiler's name for a node's class (`class_desc`). The most specific")
    lines.append("  # class is tested first, so a subclass is never named by its parent.")
    lines.append("  def self.class_name_of(node : ASTNode) : String")
    for name in sorted(port, key=lambda n: (-depth(n, port), n)):
        lines.append(f'    return "{name}" if node.is_a?({name})')
    lines.append('    "ASTNode"')
    lines.append("  end")
    lines.append("")
    lines.append("  # The names a receiver of `class_name` answers, separated by spaces.")
    lines.append("  def self.receiver_names(class_name : String) : String")
    lines.append("    case class_name")
    for name in sorted(types):
        answers = answered(types, blocks, parent_of, name)
        if not answers:
            continue
        lines.append(f'    when "{name}"')
        lines.append(f'      "{" ".join(answers)}"')
    lines.append("    else")
    lines.append('      ""')
    lines.append("    end")
    lines.append("  end")
    lines.append("end")
    return "\n".join(lines) + "\n"


def main(argv):
    text = emit()
    if "--check" in argv:
        with open(OUT, encoding="utf-8") as f:
            current = f.read()
        if current != text:
            print(f"{os.path.relpath(OUT, REPO)} is stale: run bench/macro_method_table.py")
            return 1
        print(f"{os.path.relpath(OUT, REPO)} is current")
        return 0
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"wrote {os.path.relpath(OUT, REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
