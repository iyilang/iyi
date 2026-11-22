#!/usr/bin/env node
// Assemble one platform package and the portable launcher from local files.
import { readFile, writeFile, mkdir, copyFile, chmod } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const [out, os, cpu, binary] = process.argv.slice(2);
if (!out || !binary || !['darwin-arm64', 'linux-x64', 'win32-x64'].includes(`${os}-${cpu}`)) {
  console.error('usage: node assemble.mjs OUT OS CPU BINARY');
  process.exit(1);
}
const here = dirname(fileURLToPath(import.meta.url));
const main = JSON.parse(await readFile(join(here, 'package.json')));
const platform = JSON.parse(await readFile(join(here, 'platform.json')));
platform.name = `${main.name}-${os}-${cpu}`;
platform.version = main.version;
platform.os = [os];
platform.cpu = [cpu];
const mainDir = join(out, main.name);
const platformDir = join(out, platform.name);
await mkdir(join(mainDir, 'bin'), { recursive: true });
await mkdir(join(platformDir, 'bin'), { recursive: true });
await writeFile(join(mainDir, 'package.json'), JSON.stringify(main, null, 2) + '\n');
await writeFile(join(platformDir, 'package.json'), JSON.stringify(platform, null, 2) + '\n');
await copyFile(join(here, 'bin', 'hello.js'), join(mainDir, 'bin', 'hello.js'));
const dest = join(platformDir, 'bin', os === 'win32' ? 'hello.exe' : 'hello');
await copyFile(binary, dest);
await chmod(dest, 0o755);
