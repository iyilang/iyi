import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

if (process.argv.length !== 3) {
  console.error("usage: node bench/wasm_node.mjs SCRIPT.mjs");
  process.exitCode = 1;
} else {
  try {
    const script = await import(pathToFileURL(resolve(process.argv[2])).href);
    const result = await script.default({
      load: path => readFile(resolve(path)),
      log: (...args) => console.log(...args),
    });
    console.log(JSON.stringify(result));
    if (result?.ok !== true) process.exitCode = 1;
  } catch (error) {
    console.error(error?.stack ?? String(error));
    process.exitCode = 1;
  }
}
