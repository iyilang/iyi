#!/usr/bin/env python3
"""Mutation generator for stale callpath tests (RG8).

Generates single-site mutations over C2 (samples/iyi/*.iyi) and C3 (bench/std_*_exercise.iyi):
- Reached set:
    * body
    * callee
    * overload_capture
    * ivar_init
    * constant
    * class_var_init
    * annotation
    * macro_input
    * position_change
- Outside reached set:
    * unreached_def
    * unrelated_type
    * unused_const
    * comment_no_loc
- Special checks:
    * link_annotation
    * artifact_object_unit
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Mutation:
    kind: str
    description: str
    mutated_source: str
    in_reach: bool
    special: str | None = None


def generate_mutations_for_source(
    source_path: str,
    elements: list[dict] | None = None,
    seed: int = 42,
    kinds: set[str] | None = None,
) -> list[Mutation]:
    """Generates mutations for a given .iyi source file."""
    with open(source_path, "r", encoding="utf-8", errors="replace") as f:
        src = f.read()

    lines = src.splitlines(keepends=True)
    real_path = os.path.abspath(source_path)

    # Filter elements belonging to this source file
    src_elements = []
    if elements:
        for e in elements:
            efile = e.get("file")
            if efile and os.path.abspath(efile) == real_path:
                src_elements.append(e)

    mutations: list[Mutation] = []

    def should_generate(k: str) -> bool:
        return kinds is None or k in kinds

    # 1. unreached_def (outside reached)
    if should_generate("unreached_def"):
        mut_src = src + "\ndef __unreached_mut_probe_func\n  999999\nend\n"
        mutations.append(Mutation("unreached_def", "add unreached def body", mut_src, in_reach=False))

    # 2. unrelated_type (outside reached)
    if should_generate("unrelated_type"):
        mut_src = src + "\nclass __UnrelatedTypeMutProbe\n  def unreached_meth\n    888888\n  end\nend\n"
        mutations.append(Mutation("unrelated_type", "add unrelated type", mut_src, in_reach=False))

    # 3. unused_const (outside reached)
    if should_generate("unused_const"):
        mut_src = src + "\n__UNUSED_CONST_MUT_PROBE = 777777\n"
        mutations.append(Mutation("unused_const", "add unused constant", mut_src, in_reach=False))

    # 4. comment_no_loc (outside reached)
    if should_generate("comment_no_loc"):
        mut_src = "# Comment above code without location literal\n" + src
        mutations.append(Mutation("comment_no_loc", "comment above code with no location literal", mut_src, in_reach=False))

    # 5. body (in reach)
    if should_generate("body"):
        # Find reached def in source
        defs = [e for e in src_elements if e.get("kind") == "def" and e.get("line")]
        mutated = False
        if defs:
            d = defs[0]
            start_l = d["line"] - 1
            end_l = d.get("end_line", start_l + 1)
            # Find a line inside def body
            for idx in range(start_l, min(len(lines), end_l)):
                line = lines[idx]
                stripped = line.strip()
                if stripped.startswith("def ") or stripped == "end" or stripped.startswith("#") or not stripped:
                    continue
                # Try literal mutation
                m = re.search(r"\"([^\"]{2,})\"", line)
                if m:
                    new_line = line[:m.start(1)] + m.group(1) + "_mut" + line[m.end(1):]
                    new_lines = list(lines)
                    new_lines[idx] = new_line
                    mutations.append(Mutation("body", f"mutate string in {d.get('key', 'def')}", "".join(new_lines), in_reach=True))
                    mutated = True
                    break
                m = re.search(r"\b([0-9]+)\b", line)
                if m:
                    new_val = str(int(m.group(1)) + 1)
                    new_line = line[:m.start(1)] + new_val + line[m.end(1):]
                    new_lines = list(lines)
                    new_lines[idx] = new_line
                    mutations.append(Mutation("body", f"mutate number in {d.get('key', 'def')}", "".join(new_lines), in_reach=True))
                    mutated = True
                    break
        if not mutated:
            # Fallback: append statement to a top-level block or reached line
            # If there is a def, insert a dummy statement
            for idx, line in enumerate(lines):
                if re.match(r"^\s*def\s+", line):
                    new_lines = list(lines)
                    indent = re.match(r"^(\s*)", line).group(1) + "  "
                    new_lines.insert(idx + 1, indent + "__mut_body_var = 12345\n")
                    mutations.append(Mutation("body", "insert statement in def body", "".join(new_lines), in_reach=True))
                    mutated = True
                    break
            if not mutated:
                # Top-level body mutation
                mutations.append(Mutation("body", "mutate top-level body", src + "\n__mut_body_var = 12345\n", in_reach=True))

    # 6. callee (in reach)
    if should_generate("callee"):
        mutated = False
        for idx, line in enumerate(lines):
            # Look for a method call like .to_s, .each, .length, etc.
            if ".to_s" in line:
                new_lines = list(lines)
                new_lines[idx] = line.replace(".to_s", ".inspect", 1)
                mutations.append(Mutation("callee", "change .to_s to .inspect", "".join(new_lines), in_reach=True))
                mutated = True
                break
            m = re.search(r"\.([a-z_][a-z0-9_]*)\b", line)
            if m and not line.strip().startswith("#"):
                meth = m.group(1)
                if meth in ("to_s", "name", "area", "greet", "shout", "calc", "speak"):
                    new_lines = list(lines)
                    new_lines[idx] = line[:m.start(1)] + meth + "_alt" + line[m.end(1):]
                    # Also define the alt method on the receiver
                    helper = f"\ndef {meth}_alt; {meth}; end\n"
                    mutations.append(Mutation("callee", f"change call .{meth} to .{meth}_alt", helper + "".join(new_lines), in_reach=True))
                    mutated = True
                    break
        if not mutated:
            # Add a called helper
            new_lines = ["def __callee_mut_helper(x); x; end\n"] + list(lines)
            # Find a callsite to wrap
            for idx, line in enumerate(new_lines):
                if "puts " in line:
                    new_lines[idx] = line.replace("puts ", "puts __callee_mut_helper(", 1).rstrip() + ")\n"
                    mutations.append(Mutation("callee", "wrap callee with helper", "".join(new_lines), in_reach=True))
                    mutated = True
                    break
            if not mutated:
                mutations.append(Mutation("callee", "add called helper in main", "".join(new_lines) + "\nputs __callee_mut_helper(42)\n", in_reach=True))

    # 7. overload_capture (in reach)
    if should_generate("overload_capture"):
        # Add a specific overload capturing a callsite
        mut_src = src + "\ndef __iyi_overload_cap_test(x : Int32); x + 100; end\ndef __iyi_overload_cap_test(x : Number); x; end\nputs __iyi_overload_cap_test(1)\n"
        mutations.append(Mutation("overload_capture", "overload capturing call site", mut_src, in_reach=True))

    # 8. ivar_init (in reach)
    if should_generate("ivar_init"):
        mutated = False
        for idx, line in enumerate(lines):
            if re.search(r"@[a-z_][a-z0-9_]*\s*=\s*", line):
                # Mutate existing ivar initializer
                m = re.search(r"(@[a-z_][a-z0-9_]*\s*=\s*)([0-9]+)", line)
                if m:
                    new_lines = list(lines)
                    new_lines[idx] = line[:m.start(2)] + str(int(m.group(2)) + 1) + line[m.end(2):]
                    mutations.append(Mutation("ivar_init", "mutate existing ivar initializer", "".join(new_lines), in_reach=True))
                    mutated = True
                    break
            if re.search(r"^\s*(class|struct)\s+([A-Z][a-zA-Z0-9_]*)", line):
                # Add an ivar initializer to reached class
                m = re.search(r"^\s*(class|struct)\s+([A-Z][a-zA-Z0-9_]*)", line)
                cname = m.group(2)
                # Check if this type is in reached elements
                if not src_elements or any(cname in e.get("key", "") for e in src_elements):
                    new_lines = list(lines)
                    new_lines.insert(idx + 1, "  @__mut_ivar_init : Int32 = 42\n")
                    mutations.append(Mutation("ivar_init", f"add ivar initializer to {cname}", "".join(new_lines), in_reach=True))
                    mutated = True
                    break
        if not mutated:
            # Synthetic reached class with ivar
            mut_src = src + "\nclass __MutIvarType; @x : Int32 = 10; def x; @x; end; end\nputs __MutIvarType.new.x\n"
            mutations.append(Mutation("ivar_init", "add reached type with ivar init", mut_src, in_reach=True))

    # 9. constant (in reach)
    if should_generate("constant"):
        mutated = False
        for idx, line in enumerate(lines):
            m = re.match(r"^([A-Z][A-Z0-9_]*)\s*=\s*([0-9]+)", line.strip())
            if m:
                cname = m.group(1)
                new_val = str(int(m.group(2)) + 1)
                new_lines = list(lines)
                new_lines[idx] = line.replace(m.group(2), new_val, 1)
                mutations.append(Mutation("constant", f"mutate constant {cname}", "".join(new_lines), in_reach=True))
                mutated = True
                break
        if not mutated:
            mut_src = "MUT_TEST_CONST = 9999\n" + src + "\nputs MUT_TEST_CONST\n"
            mutations.append(Mutation("constant", "add and use reached constant", mut_src, in_reach=True))

    # 10. class_var_init (in reach)
    if should_generate("class_var_init"):
        mutated = False
        for idx, line in enumerate(lines):
            if "@@" in line and "=" in line:
                m = re.search(r"(@@[a-z_][a-z0-9_]*\s*=\s*)([0-9]+)", line)
                if m:
                    new_lines = list(lines)
                    new_lines[idx] = line[:m.start(2)] + str(int(m.group(2)) + 1) + line[m.end(2):]
                    mutations.append(Mutation("class_var_init", "mutate class var initializer", "".join(new_lines), in_reach=True))
                    mutated = True
                    break
            if re.search(r"^\s*(class|struct)\s+([A-Z][a-zA-Z0-9_]*)", line):
                m = re.search(r"^\s*(class|struct)\s+([A-Z][a-zA-Z0-9_]*)", line)
                cname = m.group(2)
                if not src_elements or any(cname in e.get("key", "") for e in src_elements):
                    new_lines = list(lines)
                    new_lines.insert(idx + 1, "  @@__mut_cvar : Int32 = 777\n  def self.cvar_val; @@__mut_cvar; end\n")
                    new_lines.append(f"\nputs {cname}.cvar_val\n")
                    mutations.append(Mutation("class_var_init", f"add class var initializer to {cname}", "".join(new_lines), in_reach=True))
                    mutated = True
                    break
        if not mutated:
            mut_src = src + "\nclass __MutCvarType; @@val : Int32 = 55; def self.val; @@val; end; end\nputs __MutCvarType.val\n"
            mutations.append(Mutation("class_var_init", "add reached class var", mut_src, in_reach=True))

    # 11. annotation (in reach)
    if should_generate("annotation"):
        mutated = False
        for idx, line in enumerate(lines):
            if re.match(r"^\s*def\s+[a-z_]", line):
                new_lines = list(lines)
                indent = re.match(r"^(\s*)", line).group(1)
                new_lines.insert(idx, f"{indent}@[NoInline]\n")
                mutations.append(Mutation("annotation", "add @[NoInline] annotation to reached def", "".join(new_lines), in_reach=True))
                mutated = True
                break
        if not mutated:
            mut_src = "@[NoInline]\ndef __mut_annotated_fn; 123; end\n" + src + "\nputs __mut_annotated_fn\n"
            mutations.append(Mutation("annotation", "add annotated reached def", mut_src, in_reach=True))

    # 12. macro_input (in reach)
    if should_generate("macro_input"):
        mut_src = "macro __mut_mac(x); {{x}} + 1; end\n" + src + "\nputs __mut_mac(10)\n"
        mutations.append(Mutation("macro_input", "reached macro input expansion", mut_src, in_reach=True))

    # 13. position_change (in reach: position change above reached call or failable cast)
    if should_generate("position_change"):
        # Add a def with line = __LINE__ and insert newlines above its callsite
        mut_src = (
            "def __here_loc(line = __LINE__); line; end\n"
            + src
            + "\n\n# Newline shift\n# Line shift comment\nputs __here_loc\n"
        )
        mutations.append(Mutation("position_change", "position change above reached call with __LINE__ default", mut_src, in_reach=True))

    # Special: link_annotation
    if should_generate("link_annotation"):
        mut_src = (
            "@[Link(\"m\")]\n"
            "lib LibMutMath; fun cos(x : Float64) : Float64; end\n"
            + src
            + "\nputs LibMutMath.cos(0.0)\n"
        )
        mutations.append(Mutation("link_annotation", "link annotation mutation changing LinkFp", mut_src, in_reach=True, special="link_annotation"))

    return mutations


def main() -> None:
    parser = argparse.ArgumentParser(description="Stale mutation generator (RG8)")
    parser.add_argument("source", help="Source .iyi file to mutate")
    parser.add_argument("--elements", help="Path to --stale-dump-elements JSONL file")
    parser.add_argument("--kind", help="Generate only this mutation kind")
    parser.add_argument("--seed", type=int, default=42, help="Deterministic random seed")
    parser.add_argument("--json", action="store_true", help="Output JSON list of mutations")

    args = parser.parse_args()

    elements = []
    if args.elements and os.path.exists(args.elements):
        with open(args.elements) as f:
            for line in f:
                line = line.strip()
                if line:
                    elements.append(json.loads(line))

    kinds = {args.kind} if args.kind else None
    muts = generate_mutations_for_source(args.source, elements, seed=args.seed, kinds=kinds)

    if args.json:
        data = [
            {"kind": m.kind, "description": m.description, "in_reach": m.in_reach, "special": m.special}
            for m in muts
        ]
        print(json.dumps(data, indent=2))
    else:
        print(f"Generated {len(muts)} mutations for {args.source}:")
        for m in muts:
            print(f"  [{m.kind}] ({'in-reach' if m.in_reach else 'out-of-reach'}) {m.description}")


if __name__ == "__main__":
    main()
