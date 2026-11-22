#!/usr/bin/env node
'use strict';

const { spawnSync } = require('node:child_process');
const path = require('node:path');
const os = process.env.IYI_NPM_TEST_OS || process.platform;
const cpu = process.env.IYI_NPM_TEST_CPU || process.arch;
const supported = new Set(['darwin-arm64', 'linux-x64', 'win32-x64']);
const target = `${os}-${cpu}`;
if (!supported.has(target)) {
  console.error(`hello: unsupported platform ${target}`);
  process.exit(1);
}
const name = `hello-${target}`;
let root;
try {
  root = path.dirname(require.resolve(`${name}/package.json`));
} catch (error) {
  if (error.code !== 'MODULE_NOT_FOUND') throw error;
  console.error(`hello: missing platform package ${name}; install ${name}`);
  process.exit(1);
}
const child = spawnSync(path.join(root, 'bin', os === 'win32' ? 'hello.exe' : 'hello'), process.argv.slice(2), { stdio: 'inherit' });
if (child.error) {
  console.error(`hello: ${child.error.message}`);
  process.exit(1);
}
if (child.signal) {
  process.kill(process.pid, child.signal);
} else {
  process.exit(child.status);
}
