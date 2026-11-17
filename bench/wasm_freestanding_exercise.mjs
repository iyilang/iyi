import { instantiate, IyiExit } from "../src/iyi/wasm/iyi.mjs";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const assert = (condition, message) => { if (!condition) throw new Error(message); };
const equal = (a, b) => a.length === b.length && a.every((value, index) => value === b[index]);
const joined = parts => {
  const bytes = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) { bytes.set(part, offset); offset += part.length; }
  return bytes;
};

export default async function run({ load, log }) {
  const hello = await WebAssembly.compile(await load("hello.wasm"));
  const imports = WebAssembly.Module.imports(hello).map(item => `${item.module}.${item.name}`).sort();
  assert(JSON.stringify(imports) === JSON.stringify(["iyi.exit", "iyi.write"]), `hello imports ${imports}`);
  const exported = WebAssembly.Module.exports(hello).map(item => item.name);
  for (const name of ["memory", "iyi_start", "iyi_alloc", "iyi_free"]) assert(exported.includes(name), `missing ${name}`);
  log(`hello imports: ${imports.join(", ")}; exports: memory, iyi_start, iyi_alloc, iyi_free`);

  for (const name of ["hello", "format", "io"]) {
    const output = [];
    let remaining = name === "io" ? encoder.encode("first line\nsecond line\nthird line\n") : null;
    const iyi = await instantiate(await load(`${name}.wasm`), {
      start: false,
      stdout: bytes => output.push(bytes),
      stderr: bytes => { throw new Error(decoder.decode(bytes)); },
      stdin: () => { const bytes = remaining; remaining = null; return bytes; },
    });
    assert(await iyi.start() === 0, `${name} exit status`);
    assert(equal(joined(output), await load(`${name}.expected`)), `${name} differs from native stdout`);
    log(`${name}: native and wasm stdout match`);
  }

  const output = [];
  const errors = [];
  const program = await instantiate(await load("contract.wasm"), {
    start: false,
    imports: { contract: { double: value => value * 2 } },
    stdout: bytes => output.push(bytes),
    stderr: bytes => errors.push(bytes),
  });
  let refused = false;
  try { program.alloc(1); } catch { refused = true; }
  assert(refused, "allocation before start was allowed");
  assert(await program.start() === 0 && await program.start() === -1, "start must run once");
  assert(decoder.decode(joined(output)) === "contract ready\n", "stdout bytes differ");

  const message = program.put("hello, wasm");
  assert(program.string(message.ptr, message.len) === "hello, wasm", "UTF-8 round trip");
  const mixed = await program.call("contract_mix", 7, 9007199254740993n, 3.75, message.ptr);
  assert(mixed === 9007199254740993n + 14n + 3n + 104n, "Int32, Int64, Float64, pointer or user import mismatch");
  assert(typeof mixed === "bigint", "Int64 result must be BigInt");
  await program.call("contract_collect");
  await program.call("contract_collect");
  assert(program.string(message.ptr, message.len) === "hello, wasm", "pinned memory did not survive collections");
  log("boundary: Int32, BigInt, Float64, pointer and user import; pinned bytes survived collections");

  const decoy = program.alloc(48);
  const keeper = program.alloc(48);
  await program.call("contract_remember", decoy);
  new DataView(program.memory.buffer).setUint32(keeper, decoy, true);
  program.free(decoy);
  program.free(decoy);
  program.free(123);
  assert(await program.call("contract_reclaimed") === 1, "freed atomic decoy was retained or not reclaimed");
  program.free(keeper);
  log("free: freed object reclaimed; unknown and repeated pointers ignored; atomic data not scanned");

  const length = 16 * 1024 * 1024;
  const large = program.alloc(length);
  const written = new Uint8Array(length);
  for (let i = 0; i < length; i++) written[i] = (i * 31 + 7) & 255;
  new Uint8Array(program.memory.buffer, large, length).set(written);
  await program.call("contract_collect");
  assert(equal(program.bytes(large, length), written), "16 MiB buffer changed across collection");
  const previousBuffer = program.memory.buffer;
  const grown = await program.call("contract_grow");
  assert(program.memory.buffer !== previousBuffer, "32 MiB export did not grow memory");
  assert(program.bytes(grown, 1)[0] === 173, "bytes() retained an obsolete view after growth");
  assert(program.string(message.ptr, message.len) === "hello, wasm", "existing bytes changed after growth");
  program.free(large);
  program.free(message.ptr);
  log("memory: 16 MiB round trip across collection; 32 MiB export grew memory and fresh views read it");

  const wall = await program.call("contract_wall_seconds");
  assert(typeof wall === "bigint" && Math.abs(Number(wall) * 1000 - Date.now()) < 5000, "wall clock differs from host");
  const first = await program.call("contract_monotonic_ns");
  const second = await program.call("contract_monotonic_ns");
  assert(second >= first, "monotonic clock decreased");
  const a = program.alloc(4096);
  const b = program.alloc(4096);
  await program.call("contract_random", a, 4096);
  await program.call("contract_random", b, 4096);
  const ra = program.bytes(a, 4096);
  const rb = program.bytes(b, 4096);
  assert(ra.some(value => value !== ra[0]) && rb.some(value => value !== rb[0]) && !equal(ra, rb), "random draws constant or equal");
  program.free(a);
  program.free(b);
  log("clocks: wall within 5 s, monotonic nondecreasing; random: two distinct nonconstant 4 KiB draws");

  let exit;
  try { await program.call("contract_exit", 17); } catch (error) { exit = error; }
  assert(exit instanceof IyiExit && exit.code === 17, "IyiExit.code mismatch");
  const exited = await instantiate(await load("exit.wasm"), { start: false, stdout: () => {}, stderr: () => {} });
  assert(await exited.start() === 3, "top-level exit(3) status mismatch");
  const panicOutput = [];
  const panic = await instantiate(await load("panic.wasm"), { start: false, stdout: () => {}, stderr: bytes => panicOutput.push(bytes) });
  assert((await panic.start()) !== 0, "panic returned success");
  assert(decoder.decode(joined(panicOutput)).includes("freestanding panic proof"), "panic sentence missing from stderr");
  log("exit: IyiExit.code 17, exit(3) status 3, panic nonzero with sentence on stderr");
  return { ok: true };
}
