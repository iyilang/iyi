#!/usr/bin/env python3
"""Tool discovery for bench/build_tool_floor.sh.

This lives in its own file rather than a heredoc inside the shell script.
bash 3.2, which is what /bin/bash is on a macOS runner, parses backticks and
quotes inside $( ) before the heredoc ever reaches python, so a backtick in a
python comment made the whole gate a syntax error in CI while parsing fine
under bash 5 locally. A separate file has no such hazard.

    python3 bench/build_tool_scan.py build   <repo>
    python3 bench/build_tool_scan.py runtime <repo>

Each mode prints lines the shell reads:

    TOOL:<name>:<count>:<space separated locations>
    AUX:<name>:<count>:<space separated locations>
"""
import os
import re
import sys
import glob
import shlex


def scan_build(repo):

    found_build = {}

    # 1. Parse Makefile
    with open(f"{repo}/Makefile") as f:
        raw_lines = f.readlines()

    # Join continuation lines ending with backslash
    joined_lines = []
    current = ""
    start_idx = 1
    for idx, l in enumerate(raw_lines, 1):
        stripped = l.rstrip("\r\n")
        if stripped.endswith("\\"):
            if not current:
                start_idx = idx
                current = stripped[:-1] + " "
            else:
                current += stripped[:-1] + " "
        else:
            if current:
                joined_lines.append((start_idx, current + stripped))
                current = ""
            else:
                joined_lines.append((idx, stripped))

    for idx, line in joined_lines:
        if any(w in line for w in ["bin/crystal build", "$(CRYSTAL) env"]):
            found_build.setdefault("crystal", []).append(f"Makefile:{idx}")
        if any(w in line for w in ["find-llvm-config.sh", "$(LLVM_CONFIG)"]):
            found_build.setdefault("llvm-config", []).append(f"Makefile:{idx}")
        if "$(CXX)" in line:
            found_build.setdefault("c++", []).append(f"Makefile:{idx}")
        if any(w in line for w in ["EXPORT_CC", "CC ?="]):
            found_build.setdefault("cc", []).append(f"Makefile:{idx}")
        if any(w in line for w in ["git rev-parse", "git show", "git -c safe.directory"]):
            found_build.setdefault("git", []).append(f"Makefile:{idx}")

    # Scan compiler target recipes in Makefile for any unexpected tools
    COMPILER_TARGETS = {
        "$(O)/$(CRYSTAL_BIN)", "$(O)/iyi$(EXE)", "$(O)/$(IYI_DAEMON_BIN)",
        "$(O)/crystal-front$(EXE)", "$(O)/$(CRYSTAL_DAEMON_BIN)", "$(LLVM_EXT_OBJ)",
        "all:", "crystal:", "iyi:", "deps:", "llvm_ext:"
    }
    KNOWN_BUILTINS = {
        "echo", "printf", "test", "cat", "rm", "mkdir", "cp", "mv", "sed", "awk",
        "head", "tail", "tr", "sort", "uniq", "find", "cd", "pwd", "true", "false",
        "install", "touch", "stat", "chmod", "uname", "exit", "sh", "bash", "xargs",
    }
    MAKE_MACROS = {"$(call", "$(if", "$(error", "$(warning", "#"}

    # Every recipe, not a chosen few. Scoping discovery to a hardcoded target list
    # means a tool invoked from a target nobody listed is invisible, which is the
    # one thing this gate exists to catch: `smoke-probe:` calling `sha256sum` kept
    # the gate green until this scanned all of them. The allowlist does the
    # narrowing; discovery must not.
    SHELL_KEYWORDS = {
        "for", "if", "then", "else", "elif", "fi", "do", "done", "while", "case",
        "esac", "in", "return", "local", "read", "set", "unset", "shift", "eval",
        "source", ".", "[", "[[", "trap", "wait", "time",
    }

    # A tool needed to produce the compiler is a dependency of iyi. A tool needed
    # only by `docs`, `lint`, `spec` or `package` is a dependency of working on
    # iyi, which is a different claim and belongs in its own list. Both are
    # discovered; only the bucket differs.
    found_aux = {}

    in_target = False
    bucket = found_build
    for idx, line in joined_lines:
        if not line.startswith("\t") and not line.startswith(" "):
            stripped = line.strip()
            in_target = (
                ":" in stripped
                and not stripped.startswith("#")
                and not stripped.startswith(".PHONY")
                and "=" not in stripped.split(":", 1)[0]
            )
            if in_target:
                bucket = (
                    found_build
                    if any(stripped.startswith(t) for t in COMPILER_TARGETS)
                    else found_aux
                )
        elif in_target and line.startswith("\t"):
            cmd_str = line.strip().lstrip("@-").strip()
            if cmd_str.startswith("#"):
                continue
            try:
                tokens = shlex.split(cmd_str)
            except Exception:
                tokens = cmd_str.split()
            for tok in tokens:
                if tok.startswith("$(call"):
                    if "check_llvm_config" in tok:
                        found_build.setdefault("llvm-config", []).append(f"Makefile:{idx}")
                    break
                if tok.startswith("$(if"):
                    continue
                if "$(WINDOWS)," in tok:
                    sub_cmd = tok.split(",", 1)[1]
                    if sub_cmd in KNOWN_BUILTINS:
                        break
                if tok.startswith("$(") and tok.endswith(")"):
                    inner = tok[2:-1]
                    if inner in ["CXX"]:
                        found_build.setdefault("c++", []).append(f"Makefile:{idx}")
                        break
                    elif inner in ["CC", "EXPORT_CC"]:
                        found_build.setdefault("cc", []).append(f"Makefile:{idx}")
                        break
                    elif inner in ["CRYSTAL"]:
                        found_build.setdefault("crystal", []).append(f"Makefile:{idx}")
                        break
                    continue
                if "=" in tok:
                    continue
                # A flag is not a tool. `install -d`, `mkdir -m`, `make -B` were
                # being recorded as dependencies named `-d`, `-m` and `-B`.
                if tok.startswith("-"):
                    continue
                # Nor is a file mode (`install -m 0755`) or an included makefile.
                if tok.isdigit() or tok.endswith(".mk"):
                    continue
                # Nor an argument: a destination path, a completion file, an
                # automatic variable. `install -m 644 etc/completion.bash
                # $(DESTDIR)$(DATADIR)/...` was being read as three dependencies.
                if tok.startswith("$"):
                    continue
                if "/" in tok and not tok.startswith("./bin/"):
                    continue
                clean = tok.strip("\"'()")
                if clean.startswith("./bin/crystal") or clean == "crystal":
                    found_build.setdefault("crystal", []).append(f"Makefile:{idx}")
                    break
                elif clean in KNOWN_BUILTINS or clean in SHELL_KEYWORDS:
                    break
                elif clean:
                    bucket.setdefault(clean, []).append(f"Makefile:{idx}")
                    break

    # 2. Check src/llvm/
    with open(f"{repo}/src/llvm/ext/find-llvm-config.sh") as f:
        for idx, line in enumerate(f, 1):
            if "llvm-config" in line and not line.strip().startswith("#"):
                found_build.setdefault("llvm-config", []).append(f"src/llvm/ext/find-llvm-config.sh:{idx}")

    with open(f"{repo}/src/llvm/lib_llvm.cr") as f:
        for idx, line in enumerate(f, 1):
            if any(w in line for w in ["llvm-config", "find-llvm-config.sh"]):
                found_build.setdefault("llvm-config", []).append(f"src/llvm/lib_llvm.cr:{idx}")

    # 3. Check bin/crystal
    with open(f"{repo}/bin/crystal") as f:
        for idx, line in enumerate(f, 1):
            if "$PARENT_CRYSTAL" in line and "exec" in line:
                found_build.setdefault("crystal", []).append(f"bin/crystal:{idx}")

    for t in sorted(found_build):
        locs = " ".join(found_build[t][:3])
        count = len(found_build[t])
        print(f"TOOL:{t}:{count}:{locs}")

    for t in sorted(found_aux):
        if t in found_build:
            continue
        locs = " ".join(found_aux[t][:3])
        count = len(found_aux[t])
        print(f"AUX:{t}:{count}:{locs}")


def scan_runtime(repo):

    found_runtime = {}
    compiler_files = glob.glob(f"{repo}/src/compiler/**/*.cr", recursive=True)

    for cf in sorted(compiler_files):
        rel = os.path.relpath(cf, repo)
        with open(cf) as fh:
            for idx, line in enumerate(fh, 1):
                for m in re.finditer(r'Process\.find_executable\(\s*"([^"]+)"\s*\)', line):
                    t = m.group(1)
                    # Exclude dynamic subcommands and alternative modern linkers (probed under cc)
                    if not t.startswith("#{") and t not in ["ld.lld", "mold"]:
                        found_runtime.setdefault(t, []).append(f"{rel}:{idx}")
                for m in re.finditer(r'Process\.run\(\s*"([^"]+)"', line):
                    t = m.group(1)
                    if t not in ["true", "/bin/sh"]:
                        found_runtime.setdefault(t, []).append(f"{rel}:{idx}")
                if "DEFAULT_LINKER" in line and ("Process.run" in line or "probe =" in line or "`#{" in line):
                    found_runtime.setdefault("cc", []).append(f"{rel}:{idx}")

    for t in sorted(found_runtime):
        locs = " ".join(found_runtime[t][:3])
        count = len(found_runtime[t])
        print(f"TOOL:{t}:{count}:{locs}")


if __name__ == "__main__":
    mode = sys.argv[1]
    repo_arg = sys.argv[2]
    if mode == "build":
        scan_build(repo_arg)
    elif mode == "runtime":
        scan_runtime(repo_arg)
    else:
        sys.exit(f"unknown mode: {mode}")
