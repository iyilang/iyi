#!/usr/bin/env python3
"""Normalized-IR tool (RG8 oracle).

Normalizes DUMP=1 stderr IR plus IYI_DUMP_TYPE_ID=1:
- strips debug metadata;
- turns type-id constants into names, and range checks into sorted name lists;
- turns symbol indices into strings, via the symbol table initializer;
- turns proc and temp names into first-occurrence ordinals;
- sorts union switch cases by type name;
- restricts module-level tables to entries the emitted functions reference;
- emits one canonical text per function, plus a whole-program digest.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path


class TypeIdRegistry:
    """Maintains mapping of type IDs and type ID ranges to type names."""

    def __init__(self) -> None:
        self.id_to_name: dict[int, str] = {}
        self.name_to_id: dict[str, int] = {}
        self.ranges: list[tuple[int, int, str]] = []
        self.concrete_types: dict[int, str] = {}

    def parse_dump_type_id_text(self, text: str) -> None:
        """Parses stdout from IYI_DUMP_TYPE_ID=1."""
        pattern = re.compile(r"^\s*\{(\d+)\s*-\s*(\d+)\}:\s*(.+)$")
        for line in text.splitlines():
            m = pattern.match(line)
            if not m:
                continue
            min_id = int(m.group(1))
            max_id = int(m.group(2))
            type_name = m.group(3).strip()
            self.ranges.append((min_id, max_id, type_name))
            if min_id == max_id:
                self.concrete_types[min_id] = type_name
                self.id_to_name[min_id] = type_name
                self.name_to_id[type_name] = min_id

    def record_type_id(self, type_name: str, type_id: int) -> None:
        self.id_to_name[type_id] = type_name
        self.name_to_id[type_name] = type_id
        self.concrete_types[type_id] = type_name

    def names_in_range(self, min_id: int, max_id: int) -> list[str]:
        """Returns sorted list of concrete type names with type_id in [min_id, max_id]."""
        names = [
            name
            for tid, name in self.concrete_types.items()
            if min_id <= tid <= max_id
        ]
        return sorted(set(names))

    def format_range_names(self, min_id: int, max_id: int) -> str:
        names = self.names_in_range(min_id, max_id)
        if not names:
            return f"[{min_id}..{max_id}]"
        return "{" + ", ".join(names) + "}"


class StringConstant:
    def __init__(self, raw_name: str, string_value: str, raw_line: str) -> None:
        self.raw_name = raw_name
        self.string_value = string_value
        self.raw_line = raw_line


class SymbolTableRegistry:
    """Extracts symbol table mapping from @":symbol_table"."""

    def __init__(self) -> None:
        self.index_to_symbol: dict[int, str] = {}
        self.symbol_to_index: dict[str, int] = {}

    def record_symbol(self, index: int, symbol: str) -> None:
        self.index_to_symbol[index] = symbol
        self.symbol_to_index[symbol] = index


def parse_string_constants_and_symbols(
    ir_text: str,
) -> tuple[dict[str, StringConstant], SymbolTableRegistry]:
    """Finds private string constants and extracts the symbol table."""
    string_constants: dict[str, StringConstant] = {}
    symbols = SymbolTableRegistry()

    str_const_re = re.compile(
        r'(@\"[^\"]+\"|@\'[^\']+\'|@[A-Za-z0-9_\.:]+)\s*=\s*(?:private\s+|internal\s+)?constant\s+.*c\"([^\"]*?)(?:\\00)?\"'
    )
    for line in ir_text.splitlines():
        m = str_const_re.search(line)
        if m:
            const_name = m.group(1)
            raw_str = m.group(2)
            string_constants[const_name] = StringConstant(const_name, raw_str, line)

    sym_table_match = re.search(
        r'@\":symbol_table\"\s*=\s*(?:private\s+|internal\s+)?constant\s*\[\s*\d+\s*x\s*ptr\s*\]\s*\[(.*?)\]',
        ir_text,
        re.DOTALL,
    )
    if sym_table_match:
        entries_blob = sym_table_match.group(1)
        ptr_refs = re.findall(
            r'ptr\s+(@\"[^\"]+\"|@\'[^\']+\'|@[A-Za-z0-9_\.:]+)', entries_blob
        )
        for idx, ref in enumerate(ptr_refs):
            if ref in string_constants:
                sym_val = string_constants[ref].string_value
                symbols.record_symbol(idx, sym_val)

    sym_global_re = re.compile(
        r'@\"~symbol:([^\"]+)\"\s*=\s*(?:private\s+|internal\s+)?constant\s+i32\s+(\d+)'
    )
    for line in ir_text.splitlines():
        m = sym_global_re.search(line)
        if m:
            sym_name = m.group(1)
            sym_idx = int(m.group(2))
            symbols.record_symbol(sym_idx, sym_name)

    return string_constants, symbols


def parse_type_id_globals(ir_text: str, type_reg: TypeIdRegistry) -> None:
    """Finds all @"TypeName:type_id" = constant i32 <ID> in the IR."""
    pattern = re.compile(
        r'@\"([^\"]+?)(?:\.class)?:type_id\"\s*=\s*(?:private\s+|internal\s+|external\s+)?constant\s+i32\s+(-?\d+)'
    )
    for line in ir_text.splitlines():
        m = pattern.search(line)
        if m:
            name = m.group(1)
            tid = int(m.group(2))
            if tid >= 0:
                type_reg.record_type_id(name, tid)


class FunctionDef:
    def __init__(
        self,
        raw_name: str,
        ret_type: str,
        params: str,
        attrs: str,
        body_lines: list[str],
    ) -> None:
        self.raw_name = raw_name
        self.ret_type = ret_type
        self.params = params
        self.attrs = attrs
        self.body_lines = body_lines
        self.canonical_name = raw_name


def split_modules_and_functions(ir_text: str) -> tuple[list[str], list[FunctionDef]]:
    """Splits raw IR text into top-level declarations/globals and function definitions."""
    top_level_lines: list[str] = []
    functions: list[FunctionDef] = []

    cleaned_lines: list[str] = []
    for line in ir_text.splitlines():
        if line.startswith("ld: warning:") or line.startswith("ld: "):
            continue
        cleaned_lines.append(line)

    in_func = False
    curr_raw_name = ""
    curr_ret = ""
    curr_params = ""
    curr_attrs = ""
    curr_body: list[str] = []

    func_header_re = re.compile(
        r"^define\s+([^{]+?)\s+(@\"[^\"]+\"|@[A-Za-z0-9_\.:]+)\s*\((.*?)\)\s*(.*?)\s*\{"
    )

    for line in cleaned_lines:
        if not in_func:
            m = func_header_re.match(line)
            if m:
                in_func = True
                curr_ret = m.group(1).strip()
                curr_raw_name = m.group(2).strip()
                curr_params = m.group(3).strip()
                curr_attrs = m.group(4).strip()
                curr_body = []
            else:
                top_level_lines.append(line)
        else:
            if line.strip() == "}":
                in_func = False
                functions.append(
                    FunctionDef(
                        raw_name=curr_raw_name,
                        ret_type=curr_ret,
                        params=curr_params,
                        attrs=curr_attrs,
                        body_lines=curr_body,
                    )
                )
            else:
                curr_body.append(line)

    return top_level_lines, functions


def strip_debug_and_comments(line: str) -> str:
    """Strips debug metadata and end-of-line comments from an IR line."""
    line = re.sub(r",\s*!dbg\s*!\d+", "", line)
    line = re.sub(r"!dbg\s*!\d+", "", line)
    in_quote = False
    res: list[str] = []
    for ch in line:
        if ch == '"':
            in_quote = not in_quote
        elif ch == ";" and not in_quote:
            break
        res.append(ch)
    return "".join(res).rstrip()


def normalize_switch_statement(
    switch_lines: list[str], type_reg: TypeIdRegistry
) -> list[str]:
    """Sorts union switch cases by type name."""
    if not switch_lines:
        return switch_lines

    header = switch_lines[0]
    case_entries: list[tuple[str, str]] = []
    footer = ""

    case_re = re.compile(
        r"^\s*([A-Za-z0-9_]+)\s+(-?\d+|[A-Za-z0-9_:\.]+),\s*(label\s+%[A-Za-z0-9_\.]+)"
    )

    for cl in switch_lines[1:]:
        stripped = cl.strip()
        if stripped == "]":
            footer = cl
            continue
        m = case_re.match(cl)
        if m:
            val_type = m.group(1)
            val_lit = m.group(2)
            dest_label = m.group(3)
            type_name = val_lit
            try:
                numeric_val = int(val_lit)
                if numeric_val in type_reg.id_to_name:
                    type_name = type_reg.id_to_name[numeric_val]
            except ValueError:
                pass
            norm_case_line = f"    {val_type} {type_name}, {dest_label}"
            case_entries.append((type_name, norm_case_line))
        else:
            case_entries.append((stripped, cl))

    case_entries.sort(key=lambda item: item[0])
    res = [header]
    for _, cline in case_entries:
        res.append(cline)
    if footer:
        res.append(footer)
    return res


def normalize_function_body(
    body_lines: list[str],
    type_reg: TypeIdRegistry,
    symbols: SymbolTableRegistry,
    proc_map: dict[str, str],
    temp_map: dict[str, str],
) -> list[str]:
    """Normalizes function body lines:
    - strips debug metadata and intrinsics
    - turns temp names into first-occurrence ordinals
    - turns type-id constants into names, and range checks into sorted name lists
    - turns symbol indices into strings
    - sorts union switch cases by type name
    - replaces proc references with canonical proc ordinals
    """
    cleaned_lines: list[str] = []
    for line in body_lines:
        s = strip_debug_and_comments(line)
        if "call void @llvm.dbg." in s or "tail call void @llvm.dbg." in s:
            continue
        if s.strip():
            cleaned_lines.append(s)

    # 1. Replace proc names using proc_map
    text = "\n".join(cleaned_lines)
    for raw_proc, ordinal_proc in proc_map.items():
        text = text.replace(raw_proc, ordinal_proc)
    cleaned_lines = text.splitlines()

    # 2. Temp variables: %__temp_[A-Za-z0-9_]+ to first-occurrence ordinals
    temp_counter = len(temp_map)

    def temp_repl(m: re.Match) -> str:
        nonlocal temp_counter
        var = m.group(0)
        if var not in temp_map:
            temp_counter += 1
            temp_map[var] = f"%__temp_{temp_counter}"
        return temp_map[var]

    temp_var_re = re.compile(r"%__temp_[A-Za-z0-9_]+")
    cleaned_lines = [temp_var_re.sub(temp_repl, line) for line in cleaned_lines]

    # 3. Symbol table references:
    def sym_gep_repl(m: re.Match) -> str:
        idx = int(m.group(1))
        sym_name = symbols.index_to_symbol.get(idx, str(idx))
        return f'getelementptr inbounds %":symbol_table", i32 0, symbol("{sym_name}")'

    gep_sym_re = re.compile(
        r'getelementptr(?:\s+inbounds)?\s+[^,]+,\s+ptr\s+@":symbol_table",\s+i32\s+0,\s+i32\s+(\d+)'
    )
    cleaned_lines = [gep_sym_re.sub(sym_gep_repl, line) for line in cleaned_lines]

    # 4. Range checks and type-id constants
    result_lines: list[str] = []
    i = 0
    n = len(cleaned_lines)

    sge_re = re.compile(r"^(%\w+)\s*=\s*icmp\s+sge\s+i32\s+(%\w+),\s*(\d+)")
    sle_re = re.compile(r"^(%\w+)\s*=\s*icmp\s+sle\s+i32\s+(%\w+),\s*(\d+)")

    while i < n:
        line = cleaned_lines[i]

        if re.search(r"^\s*switch\s+i32\s+", line) and "[" in line:
            switch_block = [line]
            i += 1
            while i < n and "]" not in cleaned_lines[i - 1]:
                switch_block.append(cleaned_lines[i])
                i += 1
            norm_switch = normalize_switch_statement(switch_block, type_reg)
            result_lines.extend(norm_switch)
            continue

        m_sge = sge_re.search(line)
        if m_sge and i + 1 < n:
            next_line = cleaned_lines[i + 1]
            m_sle = sle_re.search(next_line)
            if m_sle and m_sge.group(2) == m_sle.group(2):
                var_name = m_sge.group(2)
                min_id = int(m_sge.group(3))
                max_id = int(m_sle.group(3))
                names = type_reg.names_in_range(min_id, max_id)
                if names:
                    norm_list = type_reg.format_range_names(min_id, max_id)
                    res_a = f"  {m_sge.group(1)} = icmp in_range i32 {var_name}, {norm_list}"
                    res_b = f"  {m_sle.group(1)} = icmp in_range i32 {var_name}, {norm_list}"
                    result_lines.append(res_a)
                    result_lines.append(res_b)
                    i += 2
                    continue

        icmp_eq_re = re.search(r"icmp\s+eq\s+i32\s+(%\w+),\s*(\d+)", line)
        if icmp_eq_re:
            val_id = int(icmp_eq_re.group(2))
            if val_id in type_reg.id_to_name:
                tname = type_reg.id_to_name[val_id]
                line = line.replace(f"i32 {val_id}", f"type_id({tname})")

        result_lines.append(line)
        i += 1

    return result_lines


def build_proc_map(functions: list[FunctionDef]) -> dict[str, str]:
    """Discovers all ~proc names and maps each to first-occurrence ordinal ~proc_1, ~proc_2, ..."""
    proc_map: dict[str, str] = {}
    proc_pattern = re.compile(r'\"~proc[^\"]*?@[^\"]+?\"')

    non_proc_funcs = sorted(
        [f for f in functions if not proc_pattern.search(f.raw_name)],
        key=lambda f: f.raw_name,
    )

    def scan_text(text: str) -> None:
        for match in proc_pattern.finditer(text):
            raw = match.group(0)
            if raw not in proc_map:
                proc_map[raw] = f'"~proc_{len(proc_map) + 1}"'

    for f in non_proc_funcs:
        scan_text(f.raw_name)
        scan_text(f.params)
        for line in f.body_lines:
            scan_text(line)

    for f in sorted(functions, key=lambda f: f.raw_name):
        scan_text(f.raw_name)
        scan_text(f.params)
        for line in f.body_lines:
            scan_text(line)

    return proc_map


def extract_referenced_globals(
    functions: list[FunctionDef],
    top_level_lines: list[str],
    string_constants: dict[str, StringConstant],
) -> set[str]:
    """Finds all global symbols (@...) transitively referenced in function bodies."""
    referenced = set()
    global_ref_re = re.compile(r'(@\"[^\"]+\"|@[A-Za-z0-9_\.:]+)')

    for f in functions:
        for line in f.body_lines:
            for m in global_ref_re.finditer(line):
                referenced.add(m.group(1))

    # Build dependency graph between globals
    const_deps: dict[str, set[str]] = {}
    for line in top_level_lines:
        m = re.match(r'^(@\"[^\"]+\"|@[A-Za-z0-9_\.:]+)\s*=\s*(.*)$', line.strip())
        if m:
            gname = m.group(1)
            rhs = m.group(2)
            deps = set(global_ref_re.findall(rhs))
            deps.discard(gname)
            const_deps[gname] = deps

    for name, sc in string_constants.items():
        deps = set(global_ref_re.findall(sc.raw_line))
        deps.discard(name)
        if deps:
            const_deps[name] = deps

    # Compute transitive closure
    queue = list(referenced)
    while queue:
        curr = queue.pop()
        for dep in const_deps.get(curr, ()):
            if dep not in referenced:
                referenced.add(dep)
                queue.append(dep)

    return referenced


def parse_gc_layout_table(ir_text: str) -> list[tuple[int, int, int, int, list[int]]]:
    """Parses __iyi_gc_layouts:table into entries (type_id, alloc_size, scan_cap, scan_count, offsets)."""
    m = re.search(
        r'@\"__iyi_gc_layouts:table\"\s*=\s*(?:private\s+|internal\s+)?constant\s*\[\s*(\d+)\s*x\s*i64\s*\]\s*\[(.*?)\]',
        ir_text,
        re.DOTALL,
    )
    if not m:
        return []

    raw_array = m.group(2)
    words = [
        int(w.replace("i64", "").strip())
        for w in raw_array.split(",")
        if w.strip()
    ]
    if not words:
        return []

    entry_count = words[0]
    entries = []
    offsets_start = 1 + entry_count * 5
    for i in range(entry_count):
        base = 1 + i * 5
        if base + 4 >= len(words):
            break
        tid = words[base]
        alloc_size = words[base + 1]
        scan_cap = words[base + 2]
        scan_count = words[base + 3]
        scan_index = words[base + 4]
        offsets = words[
            offsets_start + scan_index : offsets_start + scan_index + scan_count
        ]
        entries.append((tid, alloc_size, scan_cap, scan_count, offsets))
    return entries


def normalize_module_level_tables(
    top_level_lines: list[str],
    referenced_globals: set[str],
    type_reg: TypeIdRegistry,
    symbols: SymbolTableRegistry,
    string_constants: dict[str, StringConstant],
    gc_entries: list[tuple[int, int, int, int, list[int]]],
) -> list[str]:
    """Restricts module-level tables to entries the emitted functions reference."""
    kept_tables: list[str] = []

    # 1. Type ID globals
    type_id_global_re = re.compile(
        r'^(@\"([^\"]+?)(?:\.class)?:type_id\")\s*=\s*(?:private\s+|internal\s+|external\s+)?constant\s+i32\s+(-?\d+)'
    )
    kept_type_ids: list[tuple[str, str]] = []

    for line in top_level_lines:
        m = type_id_global_re.match(line.strip())
        if m:
            full_name = m.group(1)
            type_name = m.group(2)
            if full_name in referenced_globals:
                norm_line = f"{full_name} = constant type_id({type_name})"
                kept_type_ids.append((type_name, norm_line))

    kept_type_ids.sort(key=lambda item: item[0])
    if kept_type_ids:
        kept_tables.append("# TYPE_ID_GLOBALS")
        for _, tline in kept_type_ids:
            kept_tables.append(tline)

    # 2. Simple constants
    kept_constants: list[tuple[str, str]] = []
    for name, sc in string_constants.items():
        if name in referenced_globals:
            norm_line = f'{name} = constant string("{sc.string_value}")'
            kept_constants.append((name, norm_line))

    kept_constants.sort(key=lambda item: item[0])
    if kept_constants:
        kept_tables.append("# SIMPLE_CONSTANTS")
        for _, cline in kept_constants:
            kept_tables.append(cline)

    # 3. Symbol table
    referenced_sym_indices = set()
    for idx, sym_name in symbols.index_to_symbol.items():
        sym_global = f'@"~symbol:{sym_name}"'
        if sym_global in referenced_globals:
            referenced_sym_indices.add(idx)

    if '@":symbol_table"' in referenced_globals or referenced_sym_indices:
        kept_tables.append("# SYMBOL_TABLE")
        sorted_syms = sorted(
            [
                (idx, symbols.index_to_symbol[idx])
                for idx in referenced_sym_indices
                if idx in symbols.index_to_symbol
            ],
            key=lambda item: item[1],
        )
        for idx, sym_name in sorted_syms:
            kept_tables.append(f'  symbol("{sym_name}") = index {idx}')

    # 4. GC layouts
    if "@__iyi_gc_layouts" in referenced_globals and gc_entries:
        kept_tables.append("# GC_LAYOUTS")
        kept_gc: list[tuple[str, str]] = []
        for tid, alloc_size, scan_cap, scan_count, offsets in gc_entries:
            tname = type_reg.id_to_name.get(tid)
            if not tname:
                continue
            # Check if this type is referenced by emitted functions
            type_global = f'@"<{tname}>:type_id"'
            type_global_alt = f'@"{tname}:type_id"'
            type_struct = f'%"<{tname}>"'
            type_struct_alt = f'%"{tname}"'
            is_ref = (
                type_global in referenced_globals
                or type_global_alt in referenced_globals
                or any(tname in g for g in referenced_globals)
            )
            if is_ref:
                entry_line = (
                    f"  layout({tname}): alloc_size={alloc_size}, scan_cap={scan_cap}, "
                    f"scan_count={scan_count}, offsets={offsets}"
                )
                kept_gc.append((tname, entry_line))

        kept_gc.sort(key=lambda item: item[0])
        for _, gcline in kept_gc:
            kept_tables.append(gcline)

    return kept_tables


def normalize_ir(ir_text: str, type_id_text: str = "") -> tuple[str, str]:
    """Runs full normalization over LLVM IR and type ID dump.
    Returns (whole_program_digest, full_canonical_text).
    """
    type_reg = TypeIdRegistry()
    if type_id_text:
        type_reg.parse_dump_type_id_text(type_id_text)

    parse_type_id_globals(ir_text, type_reg)
    string_constants, symbols = parse_string_constants_and_symbols(ir_text)
    gc_entries = parse_gc_layout_table(ir_text)

    top_level_lines, raw_functions = split_modules_and_functions(ir_text)

    proc_map = build_proc_map(raw_functions)

    for f in raw_functions:
        canon_name = f.raw_name
        for raw_p, ord_p in proc_map.items():
            canon_name = canon_name.replace(raw_p, ord_p)
        f.canonical_name = canon_name

    ref_globals = extract_referenced_globals(
        raw_functions, top_level_lines, string_constants
    )

    tables = normalize_module_level_tables(
        top_level_lines,
        ref_globals,
        type_reg,
        symbols,
        string_constants,
        gc_entries,
    )

    canonical_functions: list[tuple[str, str]] = []

    for f in raw_functions:
        temp_map: dict[str, str] = {}
        temp_counter = 0

        def temp_repl(m: re.Match) -> str:
            nonlocal temp_counter
            var = m.group(0)
            if var not in temp_map:
                temp_counter += 1
                temp_map[var] = f"%__temp_{temp_counter}"
            return temp_map[var]

        temp_var_re = re.compile(r"%__temp_[A-Za-z0-9_]+")
        header_params = temp_var_re.sub(temp_repl, f.params)
        for raw_p, ord_p in proc_map.items():
            header_params = header_params.replace(raw_p, ord_p)

        norm_body = normalize_function_body(
            f.body_lines, type_reg, symbols, proc_map, temp_map
        )

        func_lines = [f"define {f.ret_type} {f.canonical_name}({header_params}) {{"]
        for bl in norm_body:
            func_lines.append(bl)
        func_lines.append("}")
        canonical_functions.append((f.canonical_name, "\n".join(func_lines)))

    canonical_functions.sort(key=lambda item: item[0])

    output_parts: list[str] = []
    if tables:
        output_parts.append("\n".join(tables))
        output_parts.append("")

    for _, ftext in canonical_functions:
        output_parts.append(ftext)
        output_parts.append("")

    canonical_body = "\n".join(output_parts).strip() + "\n"

    digest = hashlib.sha256(canonical_body.encode("utf-8")).hexdigest()
    full_output = f"DIGEST: {digest}\n\n" + canonical_body

    return digest, full_output


def compile_and_extract(
    source_path: str,
    output_bin: str | None = None,
    compiler_path: str | None = None,
) -> tuple[str, str]:
    """Compiles source with DUMP=1 and IYI_DUMP_TYPE_ID=1, returning (ir_text, type_id_text)."""
    compiler = compiler_path or os.environ.get("IYI")
    if not compiler:
        candidates = [
            "/Users/jwaldrip/dev/worktrees/iyi-stale-plan-clean/bin/iyi",
            "./bin/iyi",
            "bin/iyi",
        ]
        for c in candidates:
            if Path(c).is_file() and os.access(c, os.X_OK):
                compiler = c
                break

    if not compiler:
        sys.exit("Error: no compiler executable found. Set $IYI or pass --compiler.")

    bin_path = output_bin or f"/tmp/norm_test_{os.getpid()}"

    env = os.environ.copy()
    env["DUMP"] = "1"
    env["IYI_DUMP_TYPE_ID"] = "1"
    env.setdefault("LIBRARY_PATH", "/opt/homebrew/opt/bdw-gc/lib")
    env.setdefault("IYI_CACHE_DIR", "/tmp/iyi-stale-s3n-cache")

    cmd = [compiler, "build", "-o", bin_path, source_path]
    proc = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        sys.exit(f"Compilation failed with exit code {proc.returncode}")

    return proc.stderr, proc.stdout


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Normalized-IR tool (RG8 oracle)"
    )
    parser.add_argument(
        "--compile",
        metavar="SOURCE.iyi",
        help="Compile source file with DUMP=1 and IYI_DUMP_TYPE_ID=1",
    )
    parser.add_argument(
        "--compiler",
        metavar="PATH",
        help="Path to compiler executable",
    )
    parser.add_argument(
        "-o",
        "--output-bin",
        metavar="PATH",
        help="Output binary path for --compile",
    )
    parser.add_argument(
        "--ir",
        metavar="FILE",
        help="Path to file containing DUMP=1 stderr IR",
    )
    parser.add_argument(
        "--types",
        "--type-ids",
        metavar="FILE",
        dest="types",
        help="Path to file containing IYI_DUMP_TYPE_ID=1 stdout",
    )
    parser.add_argument(
        "--digest-only",
        action="store_true",
        help="Print only the whole-program digest",
    )
    parser.add_argument(
        "inputs",
        nargs="*",
        help="Positional inputs: [IR_FILE [TYPES_FILE]] or combined stream via stdin",
    )

    args = parser.parse_args()

    ir_text = ""
    types_text = ""

    if args.compile:
        ir_text, types_text = compile_and_extract(
            args.compile,
            output_bin=args.output_bin,
            compiler_path=args.compiler,
        )
    elif args.ir:
        with open(args.ir, "r", encoding="utf-8", errors="replace") as f:
            ir_text = f.read()
        if args.types:
            with open(args.types, "r", encoding="utf-8", errors="replace") as f:
                types_text = f.read()
    elif len(args.inputs) == 2:
        with open(args.inputs[0], "r", encoding="utf-8", errors="replace") as f:
            ir_text = f.read()
        with open(args.inputs[1], "r", encoding="utf-8", errors="replace") as f:
            types_text = f.read()
    elif len(args.inputs) == 1 and args.inputs[0] != "-":
        with open(args.inputs[0], "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
        if "IYI_DUMP_TYPE_ID" in content:
            parts = content.split("IYI_DUMP_TYPE_ID", 1)
            ir_text = parts[0]
            types_text = "IYI_DUMP_TYPE_ID" + parts[1]
        else:
            ir_text = content
    else:
        content = sys.stdin.read()
        if "IYI_DUMP_TYPE_ID" in content:
            parts = content.split("IYI_DUMP_TYPE_ID", 1)
            ir_text = parts[0]
            types_text = "IYI_DUMP_TYPE_ID" + parts[1]
        else:
            ir_text = content

    digest, full_output = normalize_ir(ir_text, types_text)

    if args.digest_only:
        print(digest)
    else:
        sys.stdout.write(full_output)


if __name__ == "__main__":
    main()
