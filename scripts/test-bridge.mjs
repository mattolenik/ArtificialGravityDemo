// Real-engine regression checks. No user's project or editor is used.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { mkdtemp, cp, writeFile, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";
import { registerEditorTools, disposeEditorConnection } from "../dist/tools/editor-tools.js";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const project = await mkdtemp(join(tmpdir(), "godot-bridge-regression-"));
const children = [];
const sockets = [];
const godot = process.env.GODOT_BIN || "godot";
const delay = ms => new Promise(r => setTimeout(r, ms));
const freePort = async () => {
  const server = createServer();
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const port = server.address().port;
  await new Promise(r => server.close(r));
  return port;
};
function run(args) {
  const child = spawn(godot, args, { stdio: ["ignore", "pipe", "pipe"] });
  child.output = "";
  child.on("error", error => { child.output += String(error); });
  for (const stream of [child.stdout, child.stderr]) stream.on("data", chunk => { child.output += chunk; });
  children.push(child);
  return child;
}
async function until(predicate, description, timeout = 30000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await delay(100);
  }
  throw new Error(`Timed out: ${description}\n${children.map(c => c.output).join("\n")}`);
}
async function connect(port, token, origin) {
  const socket = new WebSocket(`ws://127.0.0.1:${port}`, token ? `godot-ai-bridge.${token}` : [], origin ? { origin } : {});
  sockets.push(socket);
  // A rejected handshake must not become an uncaught asynchronous error.
  socket.on("error", () => {});
  await new Promise((r, j) => { socket.once("open", r); socket.once("error", j); });
  return socket;
}
let id = 0;
function rpc(socket, method, params = {}, timeout = 15000) {
  return new Promise((resolve, reject) => {
    const requestId = ++id;
    const timer = setTimeout(() => { cleanup(); reject(new Error(`RPC timed out: ${method}`)); }, timeout);
    const cleanup = () => { clearTimeout(timer); socket.off("message", onMessage); socket.off("close", onClose); };
    const onClose = () => { cleanup(); reject(new Error("Connection closed")); };
    const onMessage = data => {
      const message = JSON.parse(data.toString());
      if (message.id !== requestId) return;
      cleanup();
      if (message.error) reject(new Error(message.error.message));
      else resolve(message.result);
    };
    socket.on("message", onMessage);
    socket.once("close", onClose);
    socket.send(JSON.stringify({ jsonrpc: "2.0", id: requestId, method, params }));
  });
}
try {
  const [port, debugPort, lspPort, dapPort] = await Promise.all(Array.from({ length: 4 }, freePort));
  await cp(join(root, "addons"), join(project, "addons"), { recursive: true });
  const pluginPath = join(project, "addons/godot_ai_bridge/godot_ai_bridge.gd");
  await writeFile(pluginPath, (await readFile(pluginPath, "utf8")).replace("var _port: int = 6550", `var _port: int = ${port}`));
  await writeFile(join(project, "project.godot"), `[application]\nconfig/name="BridgeRegression"\n[editor_plugins]\nenabled=PackedStringArray("res://addons/godot_ai_bridge/plugin.cfg")\n[debug]\nfile_logging/enable_logging=true\nfile_logging/log_path="res://runtime.log"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n`);
  await writeFile(join(project, "main.tscn"), '[gd_scene format=3]\n[node name="Main" type="Node"]\n[node name="Branch" type="Node" parent="."]\n[node name="Leaf" type="Node" parent="Branch"]\n[node name="Last" type="Node" parent="."]\n');
  await writeFile(join(project, "runtime_probe.gd"), 'extends Node\nfunc _ready():\n\tawait get_tree().create_timer(0.5).timeout\n\tprint("BRIDGE_OUTPUT_SENTINEL")\n\tpush_warning("BRIDGE_WARNING_SENTINEL")\n\tpush_error("BRIDGE_ERROR_SENTINEL")\n');
  await writeFile(join(project, "runtime_probe.tscn"), '[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://runtime_probe.gd" id="1"]\n[node name="RuntimeProbe" type="Node"]\nscript=ExtResource("1")\n');
  await writeFile(join(project, "cursor_handler.gd"), 'extends "res://addons/godot_ai_bridge/message_handler.gd"\nfunc _resolve_latest_log_file_path() -> Dictionary:\n\treturn {"path": "res://cursor.log"}\n');
  const editor = run(["--headless", "--editor", "--debug-server", `tcp://127.0.0.1:${debugPort}`, "--lsp-port", String(lspPort), "--dap-port", String(dapPort), "--path", project, "res://main.tscn"]);
  await until(() => editor.output.includes(`Server started on port ${port}`), "plugin startup");
  const pairingPath = join(project, ".godot", "godot-ai-bridge.json");
  const { token } = JSON.parse(await readFile(pairingPath, "utf8"));
  assert.match(token, /^[a-f0-9]{64}$/);
  if (process.platform !== "win32") assert.equal((await stat(pairingPath)).mode & 0o777, 0o600);
  // Origin headers never grant a capability. Missing and wrong pairings cannot dispatch.
  for (const candidate of [undefined, "0".repeat(64)]) {
    let rejected = false;
    try {
      const socket = await connect(port, candidate, "https://untrusted.example");
      await rpc(socket, "info.project", {}, 3000);
    } catch { rejected = true; }
    assert.equal(rejected, true, "unpaired request must be rejected");
  }
  const socket = await connect(port, token);
  await until(async () => (await rpc(socket, "scene_tree.get")).root === "Main", "scene load");
  const execute = async code => (await rpc(socket, "execute.gdscript", { code })).result;
  await rpc(socket, "scene_tree.remove_node", { path: "Branch" });
  const undo = await execute('var root = editor_interface.get_edited_scene_root()\nvar history = message_handler.undo_redo.get_object_history_id(root)\nmessage_handler.undo_redo.get_history_undo_redo(history).undo()\nreturn {"leaf_owned": root.get_node("Branch/Leaf").owner == root, "index": root.get_node("Branch").get_index()}');
  assert.deepEqual(undo, { leaf_owned: true, index: 0 });
  await rpc(socket, "editor.save_scene");
  assert.match(await readFile(join(project, "main.tscn"), "utf8"), /name="Leaf"/);
  await writeFile(join(project, "cursor.log"), "first\n");
  const cursor1 = await execute('var handler = load("res://cursor_handler.gd").new()\nreturn handler._scan_recent_log_entries(100, "all", "")');
  assert.equal(cursor1.next_since_line, 1);
  await writeFile(join(project, "cursor.log"), "first\nsecond\n");
  const cursor2 = await execute('var handler = load("res://cursor_handler.gd").new()\nreturn handler._scan_recent_log_entries(100, "all", "", 1)');
  assert.equal(cursor2.entries[0].text, "second");
  run(["--headless", "--remote-debug", `tcp://127.0.0.1:${debugPort}`, "--path", project, "res://runtime_probe.tscn"]);
  await until(async () => { try { return (await rpc(socket, "runtime.status")).available; } catch { return false; } }, "runtime harness");
  const tools = new Map();
  registerEditorTools(tools, { projectPath: project, editorConnected: false, editorPort: port });
  assert.equal((await tools.get("godot_connect").handler({})).success, true);
  const start = Date.now();
  await tools.get("godot_runtime_wait").handler({ seconds: 6 });
  assert.ok(Date.now() - start >= 5900, "six-second runtime wait must finish successfully");
  const output = await rpc(socket, "info.output", { include_metadata: true });
  assert.ok(output.entries.some(entry => entry.source === "log_file" && entry.message.includes("BRIDGE_OUTPUT_SENTINEL")));
  const errors = await rpc(socket, "info.errors", { include_script: false, include_log_file: false });
  assert.ok(errors.errors.some(entry => entry.source === "log_file" && entry.message.includes("BRIDGE_ERROR_SENTINEL")));
  assert.equal(output.capture.source, "log_file");
  assert.equal(output.capture.available, true);
  await execute('ProjectSettings.set_setting("debug/file_logging/enable_logging", false)\nProjectSettings.set_setting("debug/file_logging/enable_logging.pc", false)\nreturn true');
  assert.equal((await rpc(socket, "info.output")).capture.available, false);
  await tools.get("godot_disconnect").handler({});
  assert.equal((await tools.get("godot_connect").handler({})).success, true);
  assert.equal((await tools.get("godot_connection_status").handler({})).connected, true);
  assert.ok(!editor.output.includes(token), "pairing token must not appear in logs");
  console.log("Godot bridge integration passed: pairing, undo/save, log cursor, runtime output/errors, six-second wait, reconnect.");
} finally {
  await disposeEditorConnection();
  for (const socket of sockets) socket.terminate();
  for (const child of children.reverse()) {
    if (child.exitCode !== null || child.signalCode !== null) continue;
    child.kill("SIGTERM");
    await Promise.race([new Promise(r => child.once("exit", r)), delay(2000)]);
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
  }
  await rm(project, { recursive: true, force: true });
}
