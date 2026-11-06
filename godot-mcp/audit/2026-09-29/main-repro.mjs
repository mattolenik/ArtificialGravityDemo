// Run after npm ci && npm run build: node audit/2026-09-29/main-repro.mjs
// Uses only temporary project files and terminates its own HTTP subprocess.
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';
import http from 'node:http';
import net from 'node:net';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const { tools, state } = await import(path.join(repo, 'dist/index.js'));
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'godot-mcp-audit-main-'));
state.projectPath = root;
const call = async (name, args) => {
  const tool = tools.get(name);
  return tool.handler(tool.inputSchema.parse(args));
};
const entry = path.join(repo, 'dist/index.js');
const link = path.join(root, 'godot-mcp');
await fs.symlink(entry, link);
for (const launch of [entry, link]) {
  const result = spawnSync(process.execPath, [launch, '--project', root], {
    encoding: 'utf8', input: '', timeout: 3000,
  });
  console.log('CLI', JSON.stringify({ launch, status: result.status,
    error: result.error?.code, stderr: result.stderr }));
}

for (let iteration = 0; iteration < 3; iteration++) {
  await fs.writeFile(path.join(root, 'main.tscn'),
    '[gd_scene format=3]\n\n[node name="Main" type="Node2D"]\n');
  const results = await Promise.all(Array.from({ length: 10 }, (_, i) =>
    call('godot_modify_node', { scenePath: 'main.tscn', nodePath: 'Main',
      updates: { properties: { ['metadata/a' + i]: i } } })));
  const content = await fs.readFile(path.join(root, 'main.tscn'), 'utf8');
  console.log('CONCURRENT_EDITS', JSON.stringify({ iteration,
    successes: results.filter(r => r.success).length,
    persisted: (content.match(/metadata\/a/g) || []).length, content }));
}

const existing = path.join(root, 'existing-project');
await fs.mkdir(existing);
await fs.writeFile(path.join(existing, 'project.godot'),
  '[application]\nconfig/name="Existing"\n[autoload]\nSave="*res://save.gd"\n');
await fs.writeFile(path.join(existing, '.gitignore'), 'private-data/\n');
await call('godot_init_project', { projectPath: existing,
  projectName: 'New', includeAiBridge: false });
console.log('INIT_OVERWRITE', JSON.stringify({
  project: await fs.readFile(path.join(existing, 'project.godot'), 'utf8'),
  ignore: await fs.readFile(path.join(existing, '.gitignore'), 'utf8'),
}));

const reservation = net.createServer();
await new Promise(r => reservation.listen(0, '127.0.0.1', r));
const port = reservation.address().port;
await new Promise(r => reservation.close(r));
const child = spawn(process.execPath, [entry, '--transport', 'http',
  '--http-port', String(port), '--project', root], { stdio: ['ignore', 'pipe', 'pipe'] });
let log = '';
child.stderr.on('data', d => { log += d; });
try {
  for (let i = 0; i < 100 && !log.includes('stateless HTTP at'); i++) {
    await new Promise(r => setTimeout(r, 30));
  }
  for (const extra of [{}, { host: 'untrusted.example' },
    { origin: 'https://untrusted.example' }, { origin: 'null' }]) {
    await new Promise((resolve, reject) => {
      const request = http.request({ host: '127.0.0.1', port, path: '/mcp', method: 'POST',
        headers: { accept: 'application/json, text/event-stream',
          'content-type': 'application/json', 'mcp-protocol-version': '2025-11-25', ...extra },
      }, response => {
        let body = '';
        response.on('data', d => { body += d; });
        response.on('end', () => {
          console.log('HTTP_GUARD', JSON.stringify({ headers: extra, status: response.statusCode,
            toolsListed: body.includes('godot_read_scene') }));
          resolve();
        });
      });
      request.setTimeout(3000, () => request.destroy(new Error('HTTP probe timeout')));
      request.on('error', reject);
      request.end(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} }));
    });
  }
} finally {
  const exited = new Promise(r => child.once('exit', r));
  child.kill('SIGTERM');
  const force = setTimeout(() => child.kill('SIGKILL'), 1500);
  await exited;
  clearTimeout(force);
}
console.log('Temporary evidence:', root);
