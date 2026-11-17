import { instantiate } from "./iyi.mjs";

const assert = (condition, message) => { if (!condition) throw new Error(message); };
const same = (a, b, label) => {
  assert(a.length === b.length, `${label}: lengths differ`);
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) throw new Error(`${label}: byte ${i} differs`);
  }
};
const rate = (bytes, ms) => bytes / (ms * 1000);
const summary = (bytes, times) => {
  const values = times.map(ms => rate(bytes, ms));
  return { best: Math.max(...values), min: Math.min(...values), max: Math.max(...values), samples: values };
};

async function timed(bytes, action, verify, collect) {
  const times = [];
  for (let i = 0; i < 5; i++) {
    collect?.();
    const start = performance.now();
    const result = await action();
    times.push(performance.now() - start);
    await verify(result);
  }
  return summary(bytes, times);
}

function setup(app, key, nonce, aad, plain, sealed) {
  const inputs = [key, nonce, aad, plain, sealed].map(bytes => app.put(bytes));
  try {
    const [k, n, a, p, s] = inputs;
    app.exports.aead_setup(k.ptr, n.ptr, a.ptr, a.len, p.ptr, p.len, s.ptr);
  } finally {
    for (const input of inputs) app.free(input.ptr);
  }
  return { ctr: app.alloc(plain.length), ghash: app.alloc(16) };
}

export default async function run({ load, log }) {
  const config = JSON.parse(new TextDecoder().decode(await load("aead-config.json")));
  const keyBytes = Uint8Array.from({ length: 32 }, (_, i) => (i * 23 + 7) & 255);
  const nonce = Uint8Array.from({ length: 12 }, (_, i) => (i * 11 + 3) & 255);
  const aad = new TextEncoder().encode("iyi AES-GCM browser proof");
  const key = await crypto.subtle.importKey("raw", keyBytes, "AES-GCM", false, ["encrypt", "decrypt"]);
  const algorithm = { name: "AES-GCM", iv: nonce, additionalData: aad, tagLength: 128 };
  const programs = {};
  for (const name of ["scalar", "simd"]) {
    programs[name] = await instantiate(await load(`${name}.wasm`), { stdout: () => {}, stderr: bytes => { throw new Error(new TextDecoder().decode(bytes)); } });
  }
  const rows = [];
  log("AES-256-GCM, decimal MB/s; best and range of five, setup and comparisons excluded");
  log("MiB | operation | scalar best [min,max] | SIMD best [min,max] | WebCrypto best [min,max]");
  for (const mib of config.sizes) {
    const size = mib * 1024 * 1024;
    const plain = new Uint8Array(size);
    for (let i = 0; i < size; i++) plain[i] = (i * 31 + (i >>> 8) + 17) & 255;
    const sealed = new Uint8Array(await crypto.subtle.encrypt(algorithm, key, plain));
    const bad = sealed.slice();
    bad[bad.length - 1] ^= 1;
    let webRefused = false;
    try { await crypto.subtle.decrypt(algorithm, key, bad); } catch (error) { webRefused = error.name === "OperationError"; }
    assert(webRefused, `${mib} MiB: WebCrypto accepted a flipped tag`);
    const buffers = {};
    for (const name of ["scalar", "simd"]) {
      buffers[name] = setup(programs[name], keyBytes, nonce, aad, plain, sealed);
      assert(programs[name].exports.aead_bad_tag_refused() === 1, `${name} accepted a flipped tag`);
      programs[name].exports.aead_collect();
    }
    const measurements = {};
    for (const name of ["scalar", "simd"]) {
      const app = programs[name];
      const view = (ptr, length) => new Uint8Array(app.memory.buffer, ptr >>> 0, length);
      // Warm the Wasm code before the five measured repetitions.
      same(view(app.exports.aead_seal(), size + 16), sealed, `${name} warm seal`);
      same(view(app.exports.aead_open(), size), plain, `${name} warm open`);
      measurements[name] = {};
      measurements[name].seal = await timed(size, () => app.exports.aead_seal(), p => same(view(p, size + 16), sealed, `${name} seal`), () => app.exports.aead_collect());
      measurements[name].open = await timed(size, () => app.exports.aead_open(), p => { assert(p !== 0, `${name} refused authentic data`); same(view(p, size), plain, `${name} open`); }, () => app.exports.aead_collect());
      measurements[name].ctr = await timed(size, () => { app.exports.aead_ctr(buffers[name].ctr); return buffers[name].ctr; }, p => same(view(p, size), sealed.subarray(0, size), `${name} CTR`));
      measurements[name].ghash = await timed(size, () => { app.exports.aead_ghash(buffers[name].ghash); return buffers[name].ghash; }, () => {});
    }
    same(new Uint8Array(programs.scalar.memory.buffer, buffers.scalar.ghash, 16), new Uint8Array(programs.simd.memory.buffer, buffers.simd.ghash, 16), `${mib} MiB GHASH`);
    const web = {};
    web.seal = await timed(size, () => crypto.subtle.encrypt(algorithm, key, plain), result => same(new Uint8Array(result), sealed, "WebCrypto seal"));
    web.open = await timed(size, () => crypto.subtle.decrypt(algorithm, key, sealed), result => same(new Uint8Array(result), plain, "WebCrypto open"));
    const text = item => item ? `${item.best.toFixed(1)} [${item.min.toFixed(1)},${item.max.toFixed(1)}]` : "n/a";
    for (const operation of ["open", "seal", "ctr", "ghash"]) {
      log(`${mib} | ${operation} | ${text(measurements.scalar[operation])} | ${text(measurements.simd[operation])} | ${text(web[operation])}`);
    }
    rows.push({ mib, scalar: measurements.scalar, simd: measurements.simd, webcrypto: web, flippedTagRefused: true });
    for (const name of ["scalar", "simd"]) {
      programs[name].free(buffers[name].ctr);
      programs[name].free(buffers[name].ghash);
      programs[name].exports.aead_collect();
    }
  }
  log("All timed outputs matched WebCrypto; both iyi builds and WebCrypto refused every flipped tag.");
  return { ok: true, userAgent: navigator.userAgent, samplesPerOperation: 5, unit: "decimal MB/s", rows };
}
