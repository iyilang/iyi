#!/usr/bin/env python3
"""bench/web_cores.iyi's server under heap22's verifier, for
bench/heap_verify_matrix.sh: the server built `-Dheap_partitions
-Dheap_verify -Diyi_chaos` runs `parallel WORKERS PORTFILE [tls]` with the
environment it is given (IYI_CHAOS, IYI_HEAP_STRESS, IYI_HEAP_FALSE_WORDS),
and REQUESTS requests over THREADS client threads, the three endpoints in
turn, are each answered 200 with the bytes the same server answers with no
chaos and no stress (`--reference` writes those, `--expect` reads them).

  python3 bench/heap_verify_web.py --program P --work DIR --reference
  python3 bench/heap_verify_web.py --program P --work DIR --expect DIR/answers.json [--tls]

The server's stderr goes to DIR/server.err; the exit is 0 when every answer
held and the server was still running at the end (it is then killed), 86
when the server ended at a verifier report, 1 otherwise.
"""

import argparse
import json
import os
import pathlib
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import web_cores  # noqa: E402  (ENDPOINTS, ask)

# Requests per endpoint in one run: a login is a cost-10 bcrypt, slow
# under a collection at every chaos point, so it is asked least.
COUNTS = {"login": 4, "check_version": 60, "order": 60}


def start(program: str, work: pathlib.Path, workers: int, tls: bool, env: dict) -> tuple[subprocess.Popen, int]:
    portfile = work / "port"
    portfile.unlink(missing_ok=True)
    err = open(work / "server.err", "wb")
    command = [program, "parallel", str(workers), str(portfile)] + (["tls"] if tls else [])
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=err, env=env)
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        if portfile.exists() and portfile.read_text().endswith("\n"):
            return process, int(portfile.read_text())
        if process.poll() is not None:
            return process, 0
        time.sleep(0.05)
    process.kill()
    process.wait()
    return process, 0


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--program", required=True)
    p.add_argument("--work", required=True)
    p.add_argument("--workers", type=int, default=4)
    p.add_argument("--threads", type=int, default=8)
    p.add_argument("--tls", action="store_true")
    p.add_argument("--reference", action="store_true")
    p.add_argument("--expect")
    a = p.parse_args()
    work = pathlib.Path(a.work)
    work.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    if a.reference:
        for name in ("IYI_CHAOS", "IYI_HEAP_STRESS", "IYI_HEAP_FALSE_WORDS"):
            env.pop(name, None)
    process, port = start(a.program, work, a.workers, a.tls, env)
    if port == 0:
        code = process.returncode
        print(f"web: the server wrote no port (exit {code})")
        return 86 if code == 86 else 1
    expect = json.loads(pathlib.Path(a.expect).read_text()) if a.expect else {}
    answers: dict = {}
    wrong: list = []
    work_items = [name for name, count in COUNTS.items() for _ in range(count if not a.reference else 1)]
    lock = threading.Lock()

    def client(items: list) -> None:
        for name in items:
            method, path, body = web_cores.ENDPOINTS[name]
            try:
                status, text = web_cores.ask(port, a.tls, method, path, body)
            except Exception as error:  # a reset, a refusal, a timeout
                with lock:
                    wrong.append(f"{name}: {type(error).__name__}: {error}")
                return
            with lock:
                if status != 200:
                    wrong.append(f"{name}: status {status}")
                elif a.reference:
                    answers[name] = text
                elif text != expect.get(name):
                    wrong.append(f"{name}: answered {text[:80]!r}")

    threads = [threading.Thread(target=client, args=(work_items[i :: a.threads],)) for i in range(a.threads)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    ended = process.poll()
    if ended is None:
        process.kill()
        process.wait()
    if a.reference:
        (work / "answers.json").write_text(json.dumps(answers))
    if ended is not None:
        print(f"web: the server ended (exit {ended}) with {len(wrong)} requests unanswered or wrong")
        return 86 if ended == 86 else 1
    if wrong:
        print(f"web: {len(wrong)} of {len(work_items)} wrong: {wrong[0]}")
        return 1
    print(f"web: {len(work_items)} requests answered as the reference")
    return 0


if __name__ == "__main__":
    sys.exit(main())
