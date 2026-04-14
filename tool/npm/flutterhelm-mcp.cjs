#!/usr/bin/env node

const {spawnSync, spawn} = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const packageRoot = path.resolve(__dirname, '..', '..');
const args = process.argv.slice(2);

function hasCommand(command) {
  const result = spawnSync(command, ['--version'], {
    stdio: 'ignore',
    shell: process.platform === 'win32',
  });
  return result.status === 0;
}

function selectRuntime() {
  if (hasCommand('dart')) {
    return {
      command: 'dart',
      pubGetArgs: ['pub', 'get'],
      runArgs: ['run', 'bin/flutterhelm.dart'],
    };
  }

  if (hasCommand('flutter')) {
    return {
      command: 'flutter',
      pubGetArgs: ['pub', 'get'],
      runArgs: ['pub', 'run', 'bin/flutterhelm.dart'],
    };
  }

  console.error(
    'flutterhelm-mcp requires Dart SDK or Flutter SDK on PATH. Install Dart or Flutter, then retry.',
  );
  process.exit(1);
}

function ensurePubGet(runtime) {
  if (process.env.FLUTTERHELM_WRAPPER_SKIP_PUB_GET === '1') {
    return;
  }

  const packageConfigPath = path.join(packageRoot, '.dart_tool', 'package_config.json');
  if (fs.existsSync(packageConfigPath)) {
    return;
  }

  const pubGet = spawnSync(runtime.command, runtime.pubGetArgs, {
    cwd: packageRoot,
    stdio: 'inherit',
    shell: process.platform === 'win32',
  });
  if (pubGet.status !== 0) {
    process.exit(pubGet.status ?? 1);
  }
}

const runtime = selectRuntime();
ensurePubGet(runtime);

const child = spawn(runtime.command, [...runtime.runArgs, ...args], {
  cwd: packageRoot,
  stdio: 'inherit',
  shell: process.platform === 'win32',
  env: {
    ...process.env,
    FLUTTERHELM_WRAPPER_ACTIVE: '1',
  },
});

child.on('exit', (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 0);
});
