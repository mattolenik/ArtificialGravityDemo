import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const binary = process.env.GODOT_BIN || 'godot';
const version = spawnSync(binary, ['--version'], { encoding: 'utf8', timeout: 10000 });
if (version.error || version.status !== 0) {
  console.error('Godot is required for test:godot. Set GODOT_BIN to the executable.');
  process.exit(1);
}
console.log(`Engine: ${version.stdout.trim()}`);
const result = spawnSync(process.execPath, [join(dirname(require.resolve('vitest/package.json')), 'vitest.mjs'), 'run',
  'src/parsers/godot-engine.test.ts', 'src/tools/generation-regressions.test.ts'], {
  stdio: 'inherit', env: { ...process.env, GODOT_BIN: binary }, timeout: 120000,
});
if (result.error) console.error(result.error.message);
process.exitCode = result.status ?? 1;
