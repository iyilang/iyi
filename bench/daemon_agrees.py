#!/usr/bin/env python3
"""A build served by the daemon answers what a plain build answers.

    make iyi iyi-daemon
    python3 bench/daemon_agrees.py

`bench/daemon_protocol.py` asks what the daemon does when a client is not a
client, and it compiles one single-file program to prove the daemon is still
alive. Nothing asked the question this exists for: **is the program the
daemon built the same program?**

It is a question with teeth because of how the daemon works. It analyses the
prelude once and forks a child per build, so the child starts from a program
that was *not* configured by this build's command line — every switch that
matters has to be re-applied to it (`Compiler::APPLIED_ON_ADOPT`). The
compiler refuses to build when a new switch is unclassified, which is a good
rail and a narrow one: it makes somebody *name* the list a switch belongs to
and cannot tell them they named the right one. Put one in the wrong list and
the daemon quietly builds something else — no error, no warning, a binary
that runs.

So: three programs, each built both ways and *run*, with the two outputs
compared byte for byte.

  * a sample with imports, which is the ordinary shape;
  * a workspace whose dependency is only a `.iyimod` and whose source is
    gone, which is what a library ships as (III.7);
  * the mixed shape a project has: its own module source, its dependency an
    artifact;
  * the same artifact-only workspace under `--crystal`, which is the arm
    with the teeth. The daemon analyses *Crystal's* prelude, so that is the
    mode where a build actually adopts one (IV.1d says as much: an iyi
    build misses and warms nothing, because the analysis happens in a
    forked child). Delete the line that re-applies `use_iyimod` to an
    adopted program and this arm is the one that notices: the plain build
    answers and both daemon builds fail.

Two builds per arm through the daemon, because the first request is what
warms a prelude and the second is what adopts one.

Exits non-zero if the two arms disagree, or if either cannot build.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.abspath(os.path.dirname(__file__)))
IYI = os.path.join(ROOT, "bin", "iyi")

BASE = """module app/base

pub def value : Int32
  42
end
"""

MID = """module app/mid

import app/base
using app/base::{value}

pub def doubled : Int32
  value * 2
end
"""

status = 0


def say(label, ok, detail=""):
    global status
    print(f"  {'ok  ' if ok else 'FAIL'} {label}" + (f" — {detail}" if detail else ""))
    if not ok:
        status = 1


def write(where, name, text):
    path = os.path.join(where, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    return path


def artifact_workspace(where, keep_mid_source, switches=()):
    """A built workspace whose `app/base` arrives as an artifact only. With
    *keep_mid_source* there is a source module in between, which is the
    shape a project has."""
    os.makedirs(where, exist_ok=True)
    write(where, os.path.join("app", "base.iyi"), BASE)
    if keep_mid_source:
        write(where, os.path.join("app", "mid.iyi"), MID)
        entry = write(where, "main.iyi",
                      "module main\n\nimport app/mid\nusing app/mid::{doubled}\n\n"
                      "puts doubled\n")
    else:
        entry = write(where, "main.iyi",
                      "module main\n\nimport app/base\nusing app/base::{value}\n\n"
                      "puts value\n")
    env = dict(os.environ, IYI_PATH=os.path.join(ROOT, "src") + os.pathsep + where)
    emit = subprocess.run([IYI, "build"] + list(switches) +
                          ["--emit-iyimod", "mods", "-o", "seed", entry],
                          cwd=where, env=env, capture_output=True, text=True)
    if emit.returncode != 0:
        return None, None, (emit.stdout + emit.stderr).splitlines()[:1]
    os.remove(os.path.join(where, "app", "base.iyi"))
    return entry, env, None


def answer(argv, cwd, env, out):
    """What the binary that build printed answers, or the failure."""
    built = subprocess.run(argv + ["-o", out], cwd=cwd, env=env,
                           capture_output=True, text=True, timeout=600)
    if built.returncode != 0:
        # The first line that says something: a build's output opens with
        # "Showing last frame", which names no failure at all.
        spoken = (built.stdout + built.stderr).splitlines()
        named = [line for line in spoken if "rror" in line or "cannot" in line]
        return None, (named or [line for line in spoken if line.strip()])[:2]
    ran = subprocess.run([out], cwd=cwd, env=env, capture_output=True, text=True,
                         timeout=600)
    return ran.stdout, None


def compare(label, entry, cwd, env, socket, work, switches=()):
    tag = label.replace(" ", "-")
    plain, failure = answer([IYI, "build"] + list(switches) + [entry], cwd, env,
                            os.path.join(work, "plain-" + tag))
    if plain is None:
        say(f"{label}: a plain build answers", False, failure)
        return
    # Twice: the first request warms the prelude, the second adopts it, and
    # an adopted program is the one a switch can go missing from.
    for round in (1, 2):
        served, failure = answer(
            [IYI, "daemon", "build", "--socket", socket] + list(switches) + [entry],
            cwd, env, os.path.join(work, f"served-{round}-{tag}"))
        if served is None:
            say(f"{label}: the daemon builds it (request {round})", False, failure)
            return
        say(f"{label}: the two arms answer the same (request {round})",
            plain == served, f"plain {plain.strip()!r}, served {served.strip()!r}")


def package_workspace(where):
    """A workspace whose dependency is a package: a bare mirror, a cache, a
    requirement in `iyi.mod` and a sum beside it.

    The daemon forks a child from a program this build did not configure, and
    where a package's module comes from is decided by `iyi.mod`, `iyi.sum`,
    the cache and the project root — `iyi_project_root` and `iyi_mod_table`
    are on `APPLIED_ON_ADOPT` for exactly that reason. This is the shape that
    reads them.

    Returns (entry, env) or (None, reason).
    """
    lib = os.path.join(where, "work", "liba")
    os.makedirs(lib, exist_ok=True)
    env = dict(os.environ,
               IYI_CACHE_DIR=os.path.join(where, "cache"),
               IYI_MOD_MIRROR=os.path.join(where, "mirror"))
    def git(*args):
        return subprocess.run(["git", *args], capture_output=True, text=True)
    if git("init", "-q", lib).returncode != 0:
        return None, ["git is not here to make a package with"]
    git("-C", lib, "config", "user.email", "t@t")
    git("-C", lib, "config", "user.name", "t")
    with open(os.path.join(lib, "iyi.mod"), "w") as f:
        f.write("module example.test/user/liba\n")
    with open(os.path.join(lib, "liba.iyi"), "w") as f:
        f.write('module liba\n\npub def greeting : String\n'
                '  "hello from liba"\nend\n')
    for args in (("-C", lib, "add", "-A"), ("-C", lib, "commit", "-qm", "one"),
                 ("-C", lib, "tag", "v1.0.0")):
        if git(*args).returncode != 0:
            return None, ["the package repository would not commit"]
    mirror = os.path.join(where, "mirror", "example.test", "user")
    os.makedirs(mirror, exist_ok=True)
    if git("clone", "-q", "--bare", lib, os.path.join(mirror, "liba")).returncode != 0:
        return None, ["the package would not clone into the mirror"]

    app = os.path.join(where, "app")
    os.makedirs(app, exist_ok=True)
    with open(os.path.join(app, "iyi.mod"), "w") as f:
        f.write("module example.test/user/app\n"
                "require example.test/user/liba v1.0.0\n")
    entry = os.path.join(app, "main.iyi")
    with open(entry, "w") as f:
        f.write("import example.test/user/liba\n"
                "using example.test/user/liba::{greeting}\n\nputs greeting\n")
    return entry, env


def main():
    work = tempfile.mkdtemp(prefix="iyi-daemon-agrees")
    socket = os.path.join(work, "daemon.sock")
    daemon = subprocess.Popen([IYI, "daemon", "start", "--socket", socket],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        # The daemon prints its readiness on stderr; waiting for the socket
        # is the same fact without parsing a sentence.
        deadline = time.monotonic() + 120
        while not os.path.exists(socket) and time.monotonic() < deadline:
            if daemon.poll() is not None:
                say("the daemon starts", False,
                    (daemon.stderr.read() or b"").decode().splitlines()[:2])
                return status
            time.sleep(0.05)
        if not os.path.exists(socket):
            say("the daemon starts", False, "no socket after 120s")
            return status

        # The ordinary shape, from the corpus every other gate uses.
        samples = os.path.join(ROOT, "samples", "iyi")
        compare("a sample with imports", os.path.join(samples, "modules.iyi"),
                samples, dict(os.environ, IYI_PATH=os.path.join(ROOT, "src")),
                socket, work)

        for label, mid, switches in (
                ("an artifact-only dependency", False, []),
                ("a source module over an artifact", True, []),
                # `--crystal` on both sides: an artifact carries which
                # prelude it was built against, and a program cannot hold
                # one module of each.
                ("an artifact-only dependency under --crystal", False, ["--crystal"])):
            where = os.path.join(work, label.replace(" ", "-"))
            entry, env, failure = artifact_workspace(where, mid, switches)
            if entry is None:
                say(f"{label}: the workspace builds from source", False, failure)
                continue
            compare(label, entry, where, env, socket, work, switches)

        # And a dependency that is a package rather than a file beside the
        # entry: where its module comes from is `iyi.mod`, `iyi.sum`, the
        # cache and the project root, and the child is forked from a program
        # that set none of them for itself.
        where = os.path.join(work, "a-package-dependency")
        entry, env = package_workspace(where)
        if entry is None:
            say("a package dependency: the workspace is made", False, env)
        else:
            compare("a package dependency", entry, os.path.join(where, "app"),
                    env, socket, work)

        # And the one thing a daemon cannot take from a request: the library.
        # The prelude it holds came from its own `IYI_PATH`, so a build that
        # asks for another one has to be refused rather than served from the
        # wrong library — the environment travels, and this is the variable
        # that cannot.
        elsewhere = os.path.join(work, "no-library")
        os.makedirs(elsewhere, exist_ok=True)
        entry = os.path.join(elsewhere, "x.iyi")
        with open(entry, "w") as f:
            f.write("puts 1\n")
        proc = subprocess.run(
            [IYI, "daemon", "build", "--socket", socket, "-o",
             os.path.join(work, "no-library-out"), entry],
            cwd=elsewhere, env=dict(os.environ, IYI_PATH=elsewhere),
            capture_output=True, text=True, timeout=600)
        spoken = proc.stdout + proc.stderr
        say("a build asking for another library is refused",
            proc.returncode != 0 and "analysed a different library" in spoken
            and "IYI_PATH" in spoken,
            spoken.strip().splitlines()[:1])
    finally:
        daemon.terminate()
        try:
            daemon.wait(timeout=30)
        except subprocess.TimeoutExpired:
            daemon.kill()
        shutil.rmtree(work, ignore_errors=True)

    print()
    if status == 0:
        print("the daemon's builds and a plain build's are the same builds.")
    else:
        print("the daemon builds something else.")
    return status


if __name__ == "__main__":
    sys.exit(main())
