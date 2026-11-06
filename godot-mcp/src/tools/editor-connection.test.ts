import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { WebSocketServer } from "ws";
import { disposeEditorConnection, registerEditorTools } from "./editor-tools.js";

let project: string;
let server: WebSocketServer;
let tools: Map<string, any>;
let state: any;
let connections: number;
let failInitialize: boolean;
const token = "a".repeat(64);
const call = (name: string, args = {}) => tools.get(name).handler(args);

beforeEach(async () => {
  project = await mkdtemp(join(tmpdir(), "godot-pairing-test-"));
  await mkdir(join(project, ".godot"));
  connections = 0;
  failInitialize = false;
  server = new WebSocketServer({ port: 0, host: "127.0.0.1", handleProtocols: (protocols) => protocols.has(`godot-ai-bridge.${token}`) ? `godot-ai-bridge.${token}` : false });
  await new Promise<void>((resolve) => server.once("listening", resolve));
  server.on("connection", (socket) => {
    connections++;
    socket.on("message", (raw) => {
      const message = JSON.parse(raw.toString());
      if (message.method !== "initialize") return;
      socket.send(JSON.stringify({ id: message.id, ...(failInitialize ? { error: { message: "Initialization refused" } } : { result: { server: "test-bridge" } }) }));
    });
  });
  state = { projectPath: project, editorConnected: false, editorPort: (server.address() as any).port };
  await writeFile(join(project, ".godot", "godot-ai-bridge.json"), JSON.stringify({ token, port: state.editorPort }), { mode: 0o600 });
  tools = new Map();
  registerEditorTools(tools, state);
});

afterEach(async () => {
  await disposeEditorConnection();
  for (const client of server.clients) client.terminate();
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await rm(project, { recursive: true, force: true });
});

describe("paired editor connection lifecycle", () => {
  it("requires private pairing credentials before opening a socket", async () => {
    await rm(join(project, ".godot", "godot-ai-bridge.json"));
    expect(await call("godot_connect")).toMatchObject({ success: false });
    expect(connections).toBe(0);
  });

  it("does not disclose implicit credentials to another endpoint", async () => {
    expect(await call("godot_connect", { host: "example.com" })).toMatchObject({ success: false });
    expect(await call("godot_connect", { port: state.editorPort + 1 })).toMatchObject({ success: false });
    expect(connections).toBe(0);
  });

  it("rejects incorrect pairing without leaking the token", async () => {
    const wrong = "b".repeat(64);
    const result = await call("godot_connect", { token: wrong });
    expect(result.success).toBe(false);
    expect(JSON.stringify(result)).not.toContain(wrong);
    expect(await call("godot_connection_status")).toMatchObject({ connected: false });
  });

  it("keeps the replacement connection after disconnect and immediate reconnect", async () => {
    expect(await call("godot_connect")).toMatchObject({ success: true });
    await call("godot_disconnect");
    expect(await call("godot_connect")).toMatchObject({ success: true, info: { server: "test-bridge" } });
    expect(await call("godot_connection_status")).toMatchObject({ connected: true });
  });

  it("shares simultaneous connection attempts", async () => {
    const results = await Promise.all([call("godot_connect"), call("godot_connect")]);
    expect(results.every((result) => result.success)).toBe(true);
    expect(connections).toBe(1);
  });

  it("reports initialization failure instead of a healthy connection", async () => {
    failInitialize = true;
    expect(await call("godot_connect")).toMatchObject({ success: false, error: "Initialization refused" });
    expect(await call("godot_connection_status")).toMatchObject({ connected: false });
  });

  it("allows runtime waits beyond the ordinary thirty-second transport timeout", async () => {
    await call("godot_connect");
    vi.useFakeTimers();
    try {
      let settled = false;
      const request = call("godot_runtime_wait", { seconds: 31 }).then(
        () => { settled = true; },
        () => { settled = true; }
      );
      await vi.advanceTimersByTimeAsync(30001);
      expect(settled).toBe(false);
      await disposeEditorConnection();
      await request;
    } finally {
      vi.useRealTimers();
    }
  });

  it("disposal rejects outstanding work and closes the connection", async () => {
    await call("godot_connect");
    const request = call("godot_editor_get_scene_tree");
    const rejected = expect(request).rejects.toThrow("Connection closed");
    await disposeEditorConnection();
    await rejected;
    expect(state.editorConnected).toBe(false);
  });
});
