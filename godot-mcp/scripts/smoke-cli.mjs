import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import * as fs from 'node:fs/promises';
import * as os from 'node:os';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
import net from 'node:net';
import { WebSocketServer } from 'ws';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'godot-cli-test-'));
const children = [];
const launch = (entry, args = []) => {
  const child = spawn(process.execPath, [entry, '--project', root, ...args], { stdio: ['pipe', 'pipe', 'pipe'] });
  child.errors = '';
  child.stderr.on('data', bytes => { child.errors += bytes; });
  children.push(child);
  return child;
};
const bounded = async (promise, label, ms = 8000) => {
  let timer;
  try { return await Promise.race([promise, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`Timed out: ${label}`)), ms);
  })]); } finally { clearTimeout(timer); }
};
let bridge;
try {
  await fs.writeFile(path.join(root, 'project.godot'), 'config_version=5\n');
  const target = path.join(repo, 'dist/index.js');
  const linked = path.join(root, 'godot-mcp');
  await fs.symlink(target, linked);
  for (const entry of [target, linked]) {
    const child = launch(entry);
    const response = bounded(new Promise((resolve, reject) => {
      let pending = '';
      child.stdout.on('data', bytes => {
        pending += bytes;
        for (;;) {
          const end = pending.indexOf('\n');
          if (end < 0) break;
          const line = pending.slice(0, end); pending = pending.slice(end + 1);
          try { const message = JSON.parse(line); if (message.id === 1) resolve(message); }
          catch { reject(new Error(`Non-JSON stdout: ${line}`)); }
        }
      });
      child.once('error', reject);
      child.once('exit', () => reject(new Error(`CLI exited before handshake: ${child.errors}`)));
    }), 'stdio handshake');
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {
      protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'smoke', version: '1' },
    } }) + '\n');
    assert.equal((await response).result.serverInfo.name, 'godot-mcp');
    const stopped = once(child, 'exit'); child.stdin.end();
    await bounded(stopped, 'stdio EOF cleanup');
    assert.equal(child.exitCode, 0);
  }

  // Windows forcibly terminates on child.kill('SIGTERM'); it cannot exercise
  // the POSIX graceful signal handler. EOF cleanup above runs on every OS.
  if (process.platform !== 'win32') {
  const token = 'a'.repeat(64);
  bridge = new WebSocketServer({ host: '127.0.0.1', port: 0,
    handleProtocols: protocols => protocols.has(`godot-ai-bridge.${token}`) ? `godot-ai-bridge.${token}` : false });
  await once(bridge, 'listening');
  bridge.on('connection', socket => socket.on('message', data => {
    const request = JSON.parse(data);
    socket.send(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: { authenticated: true } }));
  }));
  const bridgePort = bridge.address().port;
  await fs.mkdir(path.join(root, '.godot'));
  await fs.writeFile(path.join(root, '.godot/godot-ai-bridge.json'),
    JSON.stringify({ token, port: bridgePort, version: 1 }), { mode: 0o600 });
  const reserve = net.createServer(); await new Promise(r => reserve.listen(0, '127.0.0.1', r));
  const httpPort = reserve.address().port; await new Promise(r => reserve.close(r));
  const child = launch(target, ['--transport', 'http', '--http-port', String(httpPort), '--port', String(bridgePort)]);
  await bounded(new Promise((resolve, reject) => {
    const ready = () => { if (child.errors.includes('stateless HTTP at')) resolve(); };
    child.stderr.on('data', ready); ready();
    child.once('exit', () => reject(new Error(child.errors)));
  }), 'HTTP startup');
  const response = await fetch(`http://127.0.0.1:${httpPort}/mcp`, {
    method: 'POST', signal: AbortSignal.timeout(8000), headers: {
      accept: 'application/json, text/event-stream', 'content-type': 'application/json',
      'mcp-protocol-version': '2025-11-25',
    }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'godot_connect', arguments: {} } }),
  });
  const body = await response.text();
  assert.equal(response.status, 200);
  const rpc = JSON.parse(body.startsWith('event:') ? body.split('\n').find(line => line.startsWith('data: ')).slice(6) : body);
  assert.equal(rpc.result.structuredContent.success, true, body);
  const exited = once(child, 'exit'); child.kill('SIGTERM');
  await bounded(exited, 'HTTP shutdown with active editor connection', 4000);
  assert.equal(child.exitCode, 0);
  }
  console.log(`CLI smoke passed: direct/symlink handshake, EOF cleanup${process.platform !== 'win32' ? ', HTTP shutdown with active bridge' : ' (POSIX signal test skipped)'}.`);
} finally {
  for (const child of children) if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  if (bridge) { for (const client of bridge.clients) client.terminate(); await new Promise(r => bridge.close(r)); }
  await fs.rm(root, { recursive: true, force: true });
}
