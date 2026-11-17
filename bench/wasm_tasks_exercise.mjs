import { instantiate, IyiExit } from "../src/iyi/wasm/iyi.mjs";

async function runFibers(bytes, { shared, scan }) {
  let iyi;
  const parked = Array(2);
  const saved = Array(2);
  const park = new WebAssembly.Suspending(id => {
    saved[id] = iyi.exports.__stack_pointer.value;
    return new Promise(resolve => { parked[id] = resolve; });
  });
  iyi = await instantiate(bytes, { start: false, imports: { jspi_probe: { park } } });
  iyi.exports.jspi_probe_gate();
  if (await iyi.start() !== 0) throw new Error("JSPI probe start failed");
  const stack = iyi.exports.__stack_pointer;
  if (!(stack instanceof WebAssembly.Global)) throw new Error("missing mutable __stack_pointer export");
  const main = stack.value;
  const size = 256 * 1024;
  const pointers = [iyi.alloc(size), iyi.alloc(size)];
  const tops = pointers.map(ptr => (ptr + size) & ~15);
  if (shared) tops[1] = tops[0];
  const entry = WebAssembly.promising(iyi.exports.jspi_probe_fiber);
  const tasks = [];
  for (let id = 0; id < 2; id++) {
    stack.value = tops[id];
    tasks.push(entry(id));
    if (typeof parked[id] !== "function") throw new Error(`fiber ${id} did not park`);
    stack.value = main;
  }
  iyi.exports.jspi_probe_collect(saved[0], tops[0], saved[1], tops[1], scan ? 1 : 0);
  const results = [];
  for (let id = 0; id < 2; id++) {
    stack.value = saved[id];
    parked[id]();
    results.push(await tasks[id]);
    stack.value = main;
  }
  for (const ptr of pointers) iyi.free(ptr);
  return results;
}

async function program(bytes, options = {}) {
  let stdout = "";
  let stderr = "";
  const decoder = new TextDecoder();
  const iyi = await instantiate(bytes, {
    start: false,
    jspi: options.jspi,
    imports: { jspi_probe: { park: () => { throw new Error("unexpected probe park"); } } },
    stdout: value => { stdout += decoder.decode(value); },
    stderr: value => { stderr += decoder.decode(value); },
  });
  if (options.gate) iyi.exports.jspi_probe_gate();
  const status = await iyi.start();
  return { iyi, status, stdout, get stderr() { return stderr; } };
}

async function canary(bytes) {
  const run = await program(bytes, { gate: true });
  if (run.status !== 0) throw new Error("canary fixture did not start");
  try {
    await run.iyi.call("task_damage_canary");
    return { failed: false, stderr: run.stderr };
  } catch (error) {
    if (!(error instanceof IyiExit) || error.code !== 1) throw error;
    return { failed: true, stderr: run.stderr };
  }
}

export default async function ({ load, log }) {
  if (typeof WebAssembly.Suspending !== "function" || typeof WebAssembly.promising !== "function") {
    throw new Error("JSPI is unavailable");
  }
  const bytes = await load("tasks.wasm");
  const correct = await runFibers(bytes, { shared: false, scan: true });
  if (correct.join(",") !== "1701,1702") throw new Error(`separate stacks: got ${correct}`);
  log(`separate shadow stacks across collection: ${correct}`);
  const unscanned = await runFibers(bytes, { shared: false, scan: false });
  if (unscanned.join(",") === "1701,1702") throw new Error("omitting parked-stack roots was not detected");
  log(`parked-stack scan omitted: ${unscanned}`);
  const shared = await runFibers(bytes, { shared: true, scan: true });
  if (shared.join(",") === "1701,1702") throw new Error("a shared shadow stack was not detected");
  log(`shared shadow stack: ${shared}`);

  const expected = new TextDecoder().decode(await load("native.stdout"));
  const actual = await program(bytes);
  const imports = WebAssembly.Module.imports(actual.iyi.module).map(item => `${item.module}.${item.name}`).sort();
  const taskImports = ["iyi.clock_ns", "iyi.exit", "iyi.fiber_exit", "iyi.idle", "iyi.swap", "iyi.write", "jspi_probe.park"];
  if (JSON.stringify(imports) !== JSON.stringify(taskImports)) throw new Error(`unexpected task imports: ${imports}`);
  if (actual.status !== 0 || actual.stdout !== expected) {
    throw new Error(`wasm/native task output differs: status=${actual.status}\n${actual.stdout}\n${actual.stderr}`);
  }
  if (!actual.stderr.includes("expected task panic")) throw new Error("task panic did not reach stderr");
  log("portable task output matches native");

  const began = performance.now();
  const rounds = await actual.iyi.call("task_round_trips", 100000);
  const elapsed = performance.now() - began;
  if (rounds !== 100000) throw new Error(`channel round trips returned ${rounds}`);
  log(`100000 channel round trips: ${elapsed.toFixed(1)} ms`);

  const disabled = await program(bytes, { jspi: false });
  if (disabled.status !== 1 || !disabled.stderr.includes("JSPI is required to park a task")) {
    throw new Error(`missing JSPI refusal was not observed: ${disabled.status} ${disabled.stderr}`);
  }
  let resumed = false;
  try { await disabled.iyi.call("task_round_trips", 1); resumed = true; }
  catch (error) { if (!String(error).includes("program has exited")) throw error; }
  if (resumed) throw new Error("a no-JSPI exit allowed another call");
  let helloOutput = "";
  const hello = await instantiate(await load("hello.wasm"), {
    jspi: false,
    start: false,
    stdout: value => { helloOutput += new TextDecoder().decode(value); },
  });
  const helloStatus = await hello.start();
  const helloExpected = new TextDecoder().decode(await load("hello.stdout"));
  if (helloStatus !== 0 || helloOutput !== helloExpected) throw new Error("no-JSPI hello differs from native");
  log("no JSPI: first park refused; no-park hello succeeded");
  const empty = await program(await load("empty-group.wasm"), { jspi: false });
  if (empty.status !== 0 || empty.stdout !== "empty\n") throw new Error("empty group without JSPI failed");
  const sleeper = await program(await load("sleep-only.wasm"));
  if (sleeper.status !== 0 || sleeper.stdout !== "slept\n") throw new Error("standalone sleep failed");
  const selected = await program(await load("select-only.wasm"));
  if (selected.status !== 0 || selected.stdout !== "timeout\n") throw new Error("standalone select failed");
  const deadlock = await program(await load("deadlock-only.wasm"));
  if (deadlock.status !== 1 || !deadlock.stderr.includes("deadlock: every fiber is blocked")) {
    throw new Error(`deadlock was not reported: ${deadlock.status} ${deadlock.stderr}`);
  }
  log("empty group, standalone sleep and select succeeded; deadlock was reported");

  const intact = await canary(bytes);
  if (!intact.failed || !intact.stderr.includes("fiber shadow stack overflow")) {
    throw new Error(`damaged canary was not reported: ${intact.stderr}`);
  }
  const broken = await canary(await load("bad-canary.wasm"));
  if (broken.failed || broken.stderr.includes("fiber shadow stack overflow")) {
    throw new Error(`canary mutation did not remove detection: ${broken.stderr}`);
  }
  log("damaged canary reported; removing its check was caught");

  const noRoots = await program(await load("bad-roots.wasm"));
  if (noRoots.status === 0 || !noRoots.stderr.includes("parked fiber lost its only box")) {
    throw new Error(`parked-root mutation was not caught: status=${noRoots.status} ${noRoots.stderr}`);
  }
  log("removing parked-fiber roots was caught");
  return { ok: true };
}
