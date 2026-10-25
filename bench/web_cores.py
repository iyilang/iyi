#!/usr/bin/env python3
"""Issue #145's shape, measured: how many cores an iyi web server uses next to Go.

    ~/.cache/heavy.sh python3 bench/web_cores.py            # the whole table
    python3 bench/web_cores.py --runs 1 --seconds 2 --servers serve,go

The issue: the Açık Türkiye API's iyi build never passed 178% CPU on twelve
vCPUs, its Go port reached 1,117%, and the gap was widest where the work was
the server's own - a bcrypt login at 9.9 requests a second against Go's
108.2, `check_version` at 5,308 against 21,099. This builds
`bench/web_cores.iyi` (release) and its Go twin `bench/web_cores/main.go`
and asks each of three endpoints in turn over 32 kept-alive connections,
in the clear and over TLS:

  * `login`, a JSON body checked with bcrypt at cost 10 (std/password's
    `Bcrypt.verify`, Go's golang.org/x/crypto/bcrypt) - the issue does not
    say which cost its login used;
  * `check_version`, a query read and a few fields of JSON answered;
  * `order`, sixteen line items of JSON read, totalled and sorted, and
    answered in JSON.

There is no database. The issue's app read one through a tuned pool; that
pool is out of scope, and what is measured is what the server's own cores
do with a request.

The servers: iyi's `Server.serve` (one thread), `Server.serve_parallel` on
each of WORKERS, and Go's net/http at its default GOMAXPROCS. Before any is
timed, each endpoint is asked over the wire and the iyi and Go answers must
be the same bytes, or the run stops. Then wrk runs RUNS times per endpoint
(after a one-second warm-up, and each after the server has finished what
the run before left it) and the best run's requests a second is kept,
with that run's p50 and p99 latency and the CPU the server used in it, read
from /proc as a share of one core (1,200% is all twelve of a twelve-thread
machine). The load generator shares the machine, so its CPU is printed
too, and so is what the rest of the machine was doing: /proc/stat's busy
time over the run less the server's and wrk's, in cores.

Not a gate, and nothing runs it: the numbers are a machine's and a
moment's. On a shared twelve-thread machine the `serve_parallel` rows move
by tens of percent with whatever else is running, and wrk takes cores the
twelve-worker row wants. `bench/measured_numbers.py` names it among the
figures a shared runner cannot check, and holds the shape SPEC.md III.4.13
quotes (connections, workers, cost) to the constants here. Needs wrk, Go
1.25 through mise, and a compiler at bin/iyi; the program is built with
`--release` whatever the compiler was built with.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shutil
import ssl
import http.client
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
IYI = ROOT / "bin" / "iyi"
GO = ["mise", "exec", "go@1.25.14", "--", "go"]

CONNECTIONS = 32
WRK_THREADS = 4
# Seconds per run. A login is about 37 ms of one core in either server
# (cost 10, measured one request at a time), and under `serve_parallel`
# the 32 asked at once are preempted and interleaved, so they finish in
# batches of a second or more: a login run is long enough for many.
SECONDS = {"login": 15, "check_version": 5, "order": 5}
RUNS = 3
WORKERS = (1, 2, 4, 8, 12)
COST = 10
TICK = os.sysconf("SC_CLK_TCK")

USER = "ada@example.com"
PASSWORD = "correct horse battery staple"


def order_body() -> str:
    """bench/web_cores.iyi's `order_body`: sixteen line items."""
    items = [
        {"id": i, "price": (i * 37 % 101) + 0.25, "qty": i % 5 + 1}
        for i in range(1, 17)
    ]
    return json.dumps({"items": items}, separators=(",", ":"))


# Each endpoint: its method, its path with any query, and its body.
ENDPOINTS = {
    "login": ("POST", "/login", json.dumps({"email": USER, "password": PASSWORD}, separators=(",", ":"))),
    "check_version": ("GET", "/check_version?platform=android&version=2.3.9", ""),
    "order": ("POST", "/order", order_body()),
}


def build(work: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
    iyi_out = work / "web"
    go_out = work / "web-go"
    done = subprocess.run(
        [str(IYI), "build", "--release", "-o", str(iyi_out), str(ROOT / "bench/web_cores.iyi")],
        capture_output=True, text=True,
    )
    if done.returncode != 0:
        raise SystemExit(f"bench/web_cores.iyi did not build:\n{done.stdout}{done.stderr}")
    env = dict(os.environ, GOTOOLCHAIN="local")
    done = subprocess.run(
        GO + ["build", "-o", str(go_out), "."],
        cwd=ROOT / "bench/web_cores", capture_output=True, text=True, env=env,
    )
    if done.returncode != 0:
        raise SystemExit(f"bench/web_cores/main.go did not build:\n{done.stdout}{done.stderr}")
    return iyi_out, go_out


class Server:
    """One server process, started, its port read, killed at the end."""

    def __init__(self, command: list[str], portfile: pathlib.Path):
        portfile.unlink(missing_ok=True)
        self.process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if portfile.exists() and portfile.read_text().endswith("\n"):
                self.port = int(portfile.read_text())
                return
            if self.process.poll() is not None:
                raise SystemExit(f"{command} ended: {self.process.stderr.read().decode()}")
            time.sleep(0.05)
        self.stop()
        raise SystemExit(f"{command} wrote no port in 20 s")

    def ticks(self) -> int:
        fields = pathlib.Path(f"/proc/{self.process.pid}/stat").read_text().rsplit(")", 1)[1].split()
        return int(fields[11]) + int(fields[12])

    def stop(self) -> None:
        self.process.kill()
        self.process.wait()


def machine_ticks() -> int:
    fields = [int(x) for x in pathlib.Path("/proc/stat").read_text().split("\n", 1)[0].split()[1:]]
    user, nice, system, _idle, _iowait, irq, softirq, steal = fields[:8]
    return user + nice + system + irq + softirq + steal


def ask(port: int, tls: bool, method: str, path: str, body: str) -> tuple[int, str]:
    if tls:
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        conn = http.client.HTTPSConnection("127.0.0.1", port, timeout=10, context=context)
    else:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    headers = {"Content-Type": "application/json"} if body else {}
    conn.request(method, path, body=body or None, headers=headers)
    got = conn.getresponse()
    answer = (got.status, got.read().decode())
    conn.close()
    return answer


def lua(work: pathlib.Path, name: str, method: str, body: str) -> pathlib.Path:
    script = work / f"{name}.lua"
    lines = [f'wrk.method = "{method}"']
    if body:
        lines.append(f"wrk.body = {json.dumps(body)}")
        lines.append('wrk.headers["Content-Type"] = "application/json"')
    script.write_text("\n".join(lines) + "\n")
    return script


UNITS = {"us": 0.001, "ms": 1.0, "s": 1000.0, "m": 60000.0}


def latency(text: str, percent: str) -> float:
    found = re.search(rf"^\s+{percent}%\s+([\d.]+)(us|ms|s|m)\s*$", text, re.M)
    return float(found.group(1)) * UNITS[found.group(2)] if found else float("nan")


def settle(server: Server) -> None:
    """Wait for the server to stop computing what the last run left it.

    wrk stops counting when its time is up, not when the server stops
    working: 32 logins asked in the last instant are over a second of one
    core's work, still being done when the next run starts. In a smoke run
    with no wait `serve` answered 11 logins a second at 100% CPU, against
    27 a second measured on its own.
    """
    deadline = time.monotonic() + 60
    last = server.ticks()
    while time.monotonic() < deadline:
        time.sleep(0.2)
        now = server.ticks()
        if now - last <= 2:
            return
        last = now
    raise SystemExit("the server was still busy a minute after wrk stopped")


def wrk(server: Server, url: str, script: pathlib.Path, seconds: float) -> dict:
    command = [
        "wrk", f"-t{WRK_THREADS}", f"-c{CONNECTIONS}", f"-d{seconds:g}s",
        "--timeout", "20s", "--latency", "-s", str(script), url,
    ]
    settle(server)
    before_server = server.ticks()
    before_machine = machine_ticks()
    started = time.monotonic()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    output = process.stdout.read()
    _, status, usage = os.wait4(process.pid, 0)
    process.returncode = os.waitstatus_to_exitcode(status)
    wall = time.monotonic() - started
    server_cores = (server.ticks() - before_server) / TICK / wall
    machine_cores = (machine_ticks() - before_machine) / TICK / wall
    wrk_cores = (usage.ru_utime + usage.ru_stime) / wall
    rate = re.search(r"Requests/sec:\s+([\d.]+)", output)
    if process.returncode != 0 or rate is None:
        raise SystemExit(f"wrk failed on {url}:\n{output}")
    errors = 0
    non2xx = re.search(r"Non-2xx or 3xx responses: (\d+)", output)
    if non2xx:
        errors += int(non2xx.group(1))
    sockets = re.search(r"Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)", output)
    if sockets:
        errors += sum(int(x) for x in sockets.groups())
    return {
        "rate": float(rate.group(1)),
        "p50": latency(output, "50"),
        "p99": latency(output, "99"),
        "cpu": server_cores * 100,
        "wrk": wrk_cores * 100,
        "elsewhere": max(0.0, machine_cores - server_cores - wrk_cores),
        "errors": errors,
    }


def servers(iyi: pathlib.Path, go: pathlib.Path, portfile: pathlib.Path, chosen: set[str]) -> list[tuple[str, list[str]]]:
    every = [("iyi serve", [str(iyi), "serve", "1", str(portfile)], "serve")]
    every += [
        (f"iyi serve_parallel, {n}", [str(iyi), "parallel", str(n), str(portfile)], f"parallel{n}")
        for n in WORKERS
    ]
    every.append(("Go net/http", [str(go), str(portfile)], "go"))
    return [(label, command) for label, command, key in every if not chosen or key in chosen or (key.startswith("parallel") and "parallel" in chosen)]


def wire_check(iyi: pathlib.Path, go: pathlib.Path, portfile: pathlib.Path, tls: bool) -> None:
    """Both servers' answers to every endpoint, which must be the same bytes."""
    extra = ["tls"] if tls else []
    answers = {}
    for label, command in (("iyi", [str(iyi), "parallel", "2", str(portfile)] + extra), ("Go", [str(go), str(portfile)] + extra)):
        server = Server(command, portfile)
        try:
            answers[label] = {name: ask(server.port, tls, *how) for name, how in ENDPOINTS.items()}
        finally:
            server.stop()
    for name in ENDPOINTS:
        if answers["iyi"][name] != answers["Go"][name] or answers["iyi"][name][0] != 200:
            raise SystemExit(f"{name}: iyi answered {answers['iyi'][name]}, Go {answers['Go'][name]}")
        print(f"  {name}: {answers['iyi'][name][1]}")


def cell(best: dict) -> str:
    flag = f" ({best['errors']} errors)" if best["errors"] else ""
    return f"{best['rate']:,.0f} | {best['cpu']:,.0f}% | {best['p50']:.1f} / {best['p99']:.1f}{flag}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--runs", type=int, default=RUNS)
    parser.add_argument("--seconds", type=float, help="every endpoint's run, in place of SECONDS")
    parser.add_argument("--servers", default="", help="comma list of serve, parallel, parallelN, go")
    parser.add_argument("--protocols", default="http,https")
    parser.add_argument("--endpoints", default=",".join(ENDPOINTS))
    parser.add_argument("--work", help="build into this directory and keep it, for a profiler")
    parser.add_argument("--reuse", action="store_true", help="with --work, take the binaries already there")
    options = parser.parse_args()
    if shutil.which("wrk") is None:
        raise SystemExit("needs wrk")
    if not IYI.exists():
        raise SystemExit("needs a compiler at bin/iyi: make iyi")
    chosen = {s for s in options.servers.split(",") if s}
    endpoints = [e for e in options.endpoints.split(",") if e]

    work = pathlib.Path(options.work) if options.work else pathlib.Path(tempfile.mkdtemp(prefix="web_cores."))
    work.mkdir(parents=True, exist_ok=True)
    try:
        iyi, go = (work / "web", work / "web-go") if options.reuse else build(work)
        portfile = work / "port"
        scripts = {name: lua(work, name, method, body) for name, (method, _path, body) in ENDPOINTS.items()}
        seconds = {name: options.seconds or SECONDS[name] for name in ENDPOINTS}
        cpu = next((line.split(":", 1)[1].strip() for line in pathlib.Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")), "?")
        print(f"{os.cpu_count()} hardware threads ({cpu}), wrk -t{WRK_THREADS} -c{CONNECTIONS}, best of "
              f"{options.runs} runs of {', '.join(f'{s:g} s ({name})' for name, s in seconds.items() if name in endpoints)}, "
              f"bcrypt cost {COST}")
        for protocol in options.protocols.split(","):
            tls = protocol == "https"
            print(f"\n{protocol}: the same answers from both servers")
            wire_check(iyi, go, portfile, tls)
            print(f"\n{protocol}, load average before: {pathlib.Path('/proc/loadavg').read_text().split()[0]}")
            print("| server | " + " | ".join(f"{e} req/s | CPU | p50 / p99 ms" for e in endpoints) + " |")
            print("|---|" + "---:|---:|---:|" * len(endpoints))
            elsewhere = []
            wrk_cpu = []
            for label, command in servers(iyi, go, portfile, chosen):
                server = Server(command + (["tls"] if tls else []), portfile)
                cells = []
                try:
                    for name in endpoints:
                        path = ENDPOINTS[name][1]
                        url = f"{protocol}://127.0.0.1:{server.port}{path}"
                        wrk(server, url, scripts[name], 1)
                        runs = [wrk(server, url, scripts[name], seconds[name]) for _ in range(options.runs)]
                        best = max(runs, key=lambda run: run["rate"])
                        elsewhere += [run["elsewhere"] for run in runs]
                        wrk_cpu.append(best["wrk"])
                        cells.append(cell(best))
                finally:
                    server.stop()
                print(f"| {label} | " + " | ".join(cells) + " |", flush=True)
            print(f"\nbusy elsewhere during the runs: {min(elsewhere):.1f} to {max(elsewhere):.1f} cores "
                  f"(mean {sum(elsewhere) / len(elsewhere):.1f}); wrk itself {min(wrk_cpu):.0f}% to {max(wrk_cpu):.0f}% "
                  f"in the best runs")
    finally:
        if not options.work:
            shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
