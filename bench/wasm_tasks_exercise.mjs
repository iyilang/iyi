import { instantiate } from "../src/iyi/wasm/iyi.mjs";

async function runFibers(bytes, { shared, scan }) {
  let iyi;
  const parked = Array(2);
  const saved = Array(2);
  const park = new WebAssembly.Suspending(id => {
    saved[id] = iyi.exports.__stack_pointer.value;
    return new Promise(resolve => { parked[id] = resolve; });
  });
  iyi = await instantiate(bytes, { imports: { jspi_probe: { park } } });
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
  return { ok: true };
}
