/**
 * Live editor connection tools for Godot MCP
 * These tools require the godot-ai-bridge plugin running in Godot
 */

import { z } from "zod";
import WebSocket from "ws";
import * as path from "path";
import { readFile, lstat } from "node:fs/promises";
import type { ToolHandler, ServerState } from "../index.js";

// WebSocket connection state
let wsConnection: WebSocket | null = null;
let messageId = 0;
let connectionState: ServerState | null = null;
let connectingPromise: Promise<{ success: boolean; message: string; info?: unknown }> | null = null;
let connectionGeneration = 0;
const pendingRequests = new Map<
  number,
  { socket: WebSocket; resolve: (value: unknown) => void; reject: (error: Error) => void }
>();

export function registerEditorTools(
  tools: Map<string, ToolHandler>,
  state: ServerState
): void {
  // Connect to Godot editor
  tools.set("godot_connect", {
    description:
      "Connect to a running Godot editor instance with the godot-ai-bridge plugin enabled. This enables live scene manipulation and real-time feedback.",
    inputSchema: z.object({
      port: z
        .number()
        .optional()
        .describe("Port the Godot AI Bridge is running on (default: 6550)"),
      token: z.string().regex(/^[a-f0-9]{64}$/).optional().describe("Pairing token for explicit connections; normally read from the project .godot directory"),
      host: z
        .string()
        .optional()
        .describe("Host address (default: localhost)"),
    }),
    handler: async (args) => {
      const { port = state.editorPort, host = "127.0.0.1", token } = args as {
        token?: string;
        port?: number;
        host?: string;
      };

      if (wsConnection && wsConnection.readyState === WebSocket.OPEN && state.editorConnected) {
        return {
          success: true,
          message: "Already connected to Godot editor",
          connected: true,
        };
      }

      try {
        const result = await connectToGodot(host, port, state, token);
        return result;
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        return {
          success: false,
          error: message,
          hint: "Make sure Godot is running with the godot-ai-bridge plugin enabled",
        };
      }
    },
  });

  // Disconnect from Godot editor
  tools.set("godot_disconnect", {
    description: "Disconnect from the Godot editor.",
    inputSchema: z.object({}),
    handler: async () => {
      await disposeEditorConnection();
      state.editorConnected = false;

      return {
        success: true,
        message: "Disconnected from Godot editor",
      };
    },
  });

  // Get connection status
  tools.set("godot_connection_status", {
    description: "Check the current connection status to the Godot editor.",
    inputSchema: z.object({}),
    handler: async () => {
      const connected =
        wsConnection !== null && wsConnection.readyState === WebSocket.OPEN && state.editorConnected;

      return {
        connected,
        port: state.editorPort,
        projectPath: state.projectPath,
      };
    },
  });

  // Get scene tree from running editor
  tools.set("godot_editor_get_scene_tree", {
    description:
      "Get the current scene tree from the running Godot editor. Shows all nodes, their types, and hierarchy.",
    inputSchema: z.object({}),
    handler: async () => {
      ensureConnected();

      const result = await sendRequest("scene_tree.get", {});
      return result;
    },
  });

  // Select a node in the editor
  tools.set("godot_editor_select_node", {
    description: "Select a node in the Godot editor's scene tree.",
    inputSchema: z.object({
      nodePath: z
        .string()
        .describe(
          "Path to the node to select (e.g., 'Player' or 'Player/Sprite2D')"
        ),
    }),
    handler: async (args) => {
      ensureConnected();
      const { nodePath } = args as { nodePath: string };

      const result = await sendRequest("editor.select_node", { path: nodePath });
      return result;
    },
  });

  // Add a node in the running editor
  tools.set("godot_editor_add_node", {
    description:
      "Add a new node to the current scene in the running Godot editor.",
    inputSchema: z.object({
      parentPath: z
        .string()
        .describe("Path to the parent node (use '.' for scene root)"),
      name: z.string().describe("Name for the new node"),
      type: z.string().describe("Godot node type (e.g., 'Sprite2D', 'Node2D')"),
      properties: z
        .record(z.string(), z.unknown())
        .optional()
        .describe("Initial properties to set"),
    }),
    handler: async (args) => {
      ensureConnected();
      const { parentPath, name, type, properties } = args as {
        parentPath: string;
        name: string;
        type: string;
        properties?: Record<string, unknown>;
      };

      const result = await sendRequest("scene_tree.add_node", {
        parent: parentPath,
        name,
        type,
        properties,
      });
      return result;
    },
  });

  // Remove a node from the running editor
  tools.set("godot_editor_remove_node", {
    description: "Remove a node from the current scene in the running Godot editor.",
    inputSchema: z.object({
      nodePath: z.string().describe("Path to the node to remove"),
    }),
    handler: async (args) => {
      ensureConnected();
      const { nodePath } = args as { nodePath: string };

      const result = await sendRequest("scene_tree.remove_node", {
        path: nodePath,
      });
      return result;
    },
  });

  // Modify a node in the running editor
  tools.set("godot_editor_modify_node", {
    description:
      "Modify properties of a node in the current scene in the running Godot editor.",
    inputSchema: z.object({
      nodePath: z.string().describe("Path to the node to modify"),
      properties: z
        .record(z.string(), z.unknown())
        .describe("Properties to set on the node"),
    }),
    handler: async (args) => {
      ensureConnected();
      const { nodePath, properties } = args as {
        nodePath: string;
        properties: Record<string, unknown>;
      };

      const result = await sendRequest("scene_tree.modify_node", {
        path: nodePath,
        properties,
      });
      return result;
    },
  });

  // Open a scene in the editor
  tools.set("godot_editor_open_scene", {
    description: "Open a scene file in the Godot editor.",
    inputSchema: z.object({
      scenePath: z
        .string()
        .describe("Path to the scene file (e.g., 'res://scenes/main.tscn')"),
    }),
    handler: async (args) => {
      ensureConnected();
      const { scenePath } = args as { scenePath: string };

      const result = await sendRequest("editor.open_scene", { path: scenePath });
      return result;
    },
  });

  // Save the current scene
  tools.set("godot_editor_save_scene", {
    description: "Save the current scene in the Godot editor.",
    inputSchema: z.object({}),
    handler: async () => {
      ensureConnected();

      const result = await sendRequest("editor.save_scene", {});
      return result;
    },
  });

  // Run the current scene
  tools.set("godot_editor_run_scene", {
    description: "Run the current scene or a specific scene in the Godot editor.",
    inputSchema: z.object({
      scenePath: z
        .string()
        .optional()
        .describe("Optional path to a specific scene to run"),
    }),
    handler: async (args) => {
      ensureConnected();
      const { scenePath } = args as { scenePath?: string };

      const result = await sendRequest("editor.run_scene", {
        path: scenePath,
      });
      return result;
    },
  });

  // Stop the running scene
  tools.set("godot_editor_stop_scene", {
    description: "Stop the currently running scene in the Godot editor.",
    inputSchema: z.object({}),
    handler: async () => {
      ensureConnected();

      const result = await sendRequest("editor.stop_scene", {});
      return result;
    },
  });

  // Get editor errors
  tools.set("godot_editor_get_errors", {
    description:
      "Get structured editor/runtime errors with optional severity/query filtering and log-file inclusion.",
    inputSchema: z.object({
      includeRuntime: z
        .boolean()
        .optional()
        .describe("Include runtime errors captured from debugger sessions (default: true)"),
      includeScript: z
        .boolean()
        .optional()
        .describe("Include script compile checks from currently open scripts (default: true)"),
      includeLogFile: z
        .boolean()
        .optional()
        .describe("Include error/warning matches from the latest Godot log file (default: true)"),
      severity: z
        .enum(["all", "error", "warning", "info", "debug"])
        .optional()
        .describe("Filter by severity level (default: all)"),
      query: z
        .string()
        .optional()
        .describe("Case-insensitive substring filter across message/path/source fields"),
      logLines: z
        .number()
        .optional()
        .describe("How many recent log-file lines to scan when includeLogFile=true (default: 200)"),
      clear: z
        .boolean()
        .optional()
        .describe("Clear in-memory runtime error buffer after retrieval"),
    }),
    handler: async (args) => {
      ensureConnected();
      const {
        includeRuntime = true,
        includeScript = true,
        includeLogFile = true,
        severity = "all",
        query = "",
        logLines = 200,
        clear = false,
      } = args as {
        includeRuntime?: boolean;
        includeScript?: boolean;
        includeLogFile?: boolean;
        severity?: "all" | "error" | "warning" | "info" | "debug";
        query?: string;
        logLines?: number;
        clear?: boolean;
      };

      const result = await sendRequest("info.errors", {
        include_runtime: includeRuntime,
        include_script: includeScript,
        include_log_file: includeLogFile,
        severity,
        query,
        log_lines: logLines,
        clear,
      });
      return result;
    },
  });

  // Get editor output
  tools.set("godot_editor_get_output", {
    description:
      "Get captured output with severity/source/query filters and optional structured metadata.",
    inputSchema: z.object({
      lines: z
        .number()
        .optional()
        .describe("Number of recent lines to retrieve (default: 50)"),
      level: z
        .enum(["all", "error", "warning", "info", "debug"])
        .optional()
        .describe("Filter output by severity level (default: all)"),
      source: z
        .enum(["all", "runtime", "debugger", "bridge", "editor", "log_file"])
        .optional()
        .describe("Filter by output source (default: all)"),
      query: z
        .string()
        .optional()
        .describe("Case-insensitive substring filter on output text"),
      includeMetadata: z
        .boolean()
        .optional()
        .describe("Include structured output entries with level/source/timestamp"),
      clear: z
        .boolean()
        .optional()
        .describe("Clear in-memory output buffer after retrieval"),
    }),
    handler: async (args) => {
      ensureConnected();
      const {
        lines = 50,
        level = "all",
        source = "all",
        query = "",
        includeMetadata = true,
        clear = false,
      } = args as {
        lines?: number;
        level?: "all" | "error" | "warning" | "info" | "debug";
        source?: "all" | "runtime" | "debugger" | "bridge" | "editor" | "log_file";
        query?: string;
        includeMetadata?: boolean;
        clear?: boolean;
      };

      const result = await sendRequest("info.output", {
        lines,
        level,
        source,
        query,
        include_metadata: includeMetadata,
        clear,
      });
      return result;
    },
  });

  // Get log file content (captures all print output)
  tools.set("godot_editor_get_log_file", {
    description:
      "Read and filter the latest Godot log file with structured metadata and incremental tail support.",
    inputSchema: z.object({
      lines: z
        .number()
        .optional()
        .describe("Number of recent lines to retrieve (default: 100)"),
      filter: z
        .enum(["all", "error", "warning", "info", "debug"])
        .optional()
        .describe("Filter log entries by severity (default: all)"),
      query: z
        .string()
        .optional()
        .describe("Case-insensitive substring filter on log line content"),
      sinceLine: z
        .number()
        .optional()
        .describe("Only include lines with line_number > sinceLine for incremental polling"),
      includeMetadata: z
        .boolean()
        .optional()
        .describe("Include structured line entries with severity and line numbers"),
    }),
    handler: async (args) => {
      ensureConnected();
      const {
        lines = 100,
        filter = "all",
        query = "",
        sinceLine = 0,
        includeMetadata = true,
      } = args as {
        lines?: number;
        filter?: "all" | "error" | "warning" | "info" | "debug";
        query?: string;
        sinceLine?: number;
        includeMetadata?: boolean;
      };

      const result = await sendRequest("info.log_file", {
        lines,
        filter,
        query,
        since_line: sinceLine,
        include_metadata: includeMetadata,
      });
      return result;
    },
  });

  // Execute GDScript in the editor
  tools.set("godot_editor_execute_gdscript", {
    description:
      "Execute arbitrary GDScript code in the running Godot editor. Use with caution.",
    inputSchema: z.object({
      code: z.string().describe("GDScript code to execute"),
    }),
    handler: async (args) => {
      ensureConnected();
      const { code } = args as { code: string };

      const result = await sendRequest("execute.gdscript", { code });
      return result;
    },
  });

  // Get project info from editor
  tools.set("godot_editor_get_project_info", {
    description: "Get information about the currently open project in the Godot editor.",
    inputSchema: z.object({}),
    handler: async () => {
      ensureConnected();

      const result = await sendRequest("info.project", {});
      return result;
    },
  });

  // Refresh the filesystem in editor
  tools.set("godot_editor_refresh_filesystem", {
    description:
      "Trigger a filesystem refresh in the Godot editor. Useful after external file changes.",
    inputSchema: z.object({}),
    handler: async () => {
      ensureConnected();

      const result = await sendRequest("fs.refresh", {});
      return result;
    },
  });

  tools.set("godot_runtime_status", {
    description:
      "Get runtime automation harness status and viewport metadata from the currently running game.",
    inputSchema: z.object({}),
    handler: async () => {
      ensureConnected();
      const result = await sendRequest("runtime.status", {});
      return result;
    },
  });

  tools.set("godot_runtime_wait", {
    description:
      "Wait for a number of frames or seconds in the running game before continuing. If omitted, waits for one frame.",
    inputSchema: z.object({
      frames: z
        .number()
        .int()
        .nonnegative()
        .max(3600)
        .optional()
        .describe("Number of process frames to wait (maximum 3600)"),
      seconds: z
        .number()
        .nonnegative()
        .max(3600)
        .optional()
        .describe("Wall-clock seconds to wait in the running game (maximum 3600)"),
    }),
    handler: async (args) => {
      ensureConnected();
      const { frames, seconds } = args as { frames?: number; seconds?: number };

      const result = await sendRequest("runtime.wait", { frames, seconds }, runtimeTimeout({ frames, seconds }));
      return result;
    },
  });

  tools.set("godot_runtime_press_action", {
    description:
      "Press and hold an InputMap action in the running game until a matching release call.",
    inputSchema: z.object({
      action: z.string().describe("InputMap action name to press"),
      strength: z
        .number()
        .optional()
        .default(1.0)
        .describe("Optional action strength (default: 1.0)"),
    }),
    handler: async (args) => {
      ensureConnected();
      const { action, strength = 1.0 } = args as {
        action: string;
        strength?: number;
      };

      const result = await sendRequest("runtime.press_action", {
        action,
        strength,
      });
      return result;
    },
  });

  tools.set("godot_runtime_release_action", {
    description: "Release a previously pressed InputMap action in the running game.",
    inputSchema: z.object({
      action: z.string().describe("InputMap action name to release"),
    }),
    handler: async (args) => {
      ensureConnected();
      const { action } = args as { action: string };

      const result = await sendRequest("runtime.release_action", { action });
      return result;
    },
  });

  tools.set("godot_runtime_tap_action", {
    description:
      "Tap an InputMap action for a small number of frames in the running game.",
    inputSchema: z.object({
      action: z.string().describe("InputMap action name to tap"),
      frames: z
        .number()
        .int()
        .positive()
        .max(3600)
        .optional()
        .default(1)
        .describe("How many frames to hold the action before release (maximum 3600)"),
      strength: z
        .number()
        .optional()
        .default(1.0)
        .describe("Optional action strength (default: 1.0)"),
    }),
    handler: async (args) => {
      ensureConnected();
      const { action, frames = 1, strength = 1.0 } = args as {
        action: string;
        frames?: number;
        strength?: number;
      };

      const result = await sendRequest("runtime.tap_action", { action, frames, strength }, runtimeTimeout({ frames }));
      return result;
    },
  });

  tools.set("godot_runtime_mouse_move", {
    description:
      "Move the synthetic pointer inside the running game viewport using viewport-local coordinates.",
    inputSchema: z.object({
      x: z.number().describe("Viewport-local X coordinate"),
      y: z.number().describe("Viewport-local Y coordinate"),
    }),
    handler: async (args) => {
      ensureConnected();
      const { x, y } = args as { x: number; y: number };

      const result = await sendRequest("runtime.mouse_move", { x, y });
      return result;
    },
  });

  tools.set("godot_runtime_click", {
    description:
      "Send a mouse click into the running game viewport, optionally moving first.",
    inputSchema: z
      .object({
        x: z.number().optional().describe("Optional viewport-local X coordinate"),
        y: z.number().optional().describe("Optional viewport-local Y coordinate"),
        button: z
          .number()
          .int()
          .positive()
          .optional()
          .default(1)
          .describe("Mouse button index (default: 1 for left click)"),
        holdFrames: z
          .number()
          .int()
          .positive()
          .max(3600)
          .optional()
          .default(1)
          .describe("How many frames to hold the button before release (maximum 3600)"),
      })
      .refine(
        (value) =>
          (value.x === undefined && value.y === undefined) ||
          (value.x !== undefined && value.y !== undefined),
        { message: "Provide both x and y, or neither." }
      ),
    handler: async (args) => {
      ensureConnected();
      const { x, y, button = 1, holdFrames = 1 } = args as {
        x?: number;
        y?: number;
        button?: number;
        holdFrames?: number;
      };

      const result = await sendRequest("runtime.click", { x, y, button, holdFrames }, runtimeTimeout({ frames: holdFrames }));
      return result;
    },
  });

  tools.set("godot_runtime_type_text", {
    description:
      "Type text into the currently focused Control in the running game.",
    inputSchema: z.object({
      text: z.string().describe("Text to push into the focused control"),
    }),
    handler: async (args) => {
      ensureConnected();
      const { text } = args as { text: string };

      const result = await sendRequest("runtime.type_text", { text });
      return result;
    },
  });

  tools.set("godot_runtime_capture_screenshot", {
    description:
      "Capture the running game viewport to a PNG file and return the resolved path plus image size.",
    inputSchema: z.object({
      path: z
        .string()
        .describe(
          "Output path. Supports absolute paths plus res://, user://, or project-relative paths."
        ),
    }),
    handler: async (args) => {
      ensureConnected();
      const { path: screenshotPath } = args as { path: string };

      const result = await sendRequest("runtime.capture_screenshot", {
        path: normalizeRuntimeArtifactPath(screenshotPath, state.projectPath),
      });
      return result;
    },
  });
}

// Helper functions
function ensureConnected(): void {
  if (!wsConnection || wsConnection.readyState !== WebSocket.OPEN) {
    throw new Error(
      "Not connected to Godot editor. Use godot_connect first."
    );
  }
}

export async function disposeEditorConnection(): Promise<void> {
  ++connectionGeneration;
  connectingPromise = null;
  const socket = wsConnection;
  wsConnection = null;
  if (connectionState) connectionState.editorConnected = false;
  connectionState = null;
  if (!socket) return;
  rejectSocketRequests(socket, new Error("Connection closed"));
  if (socket.readyState === WebSocket.CLOSED) return;
  await new Promise<void>((resolve) => {
    const timer = setTimeout(() => { socket.terminate(); resolve(); }, 1000);
    socket.once("close", () => { clearTimeout(timer); resolve(); });
    // terminate also safely cancels an unfinished handshake.
    if (socket.readyState === WebSocket.CONNECTING) socket.terminate();
    else socket.close();
  });
}

function rejectSocketRequests(socket: WebSocket, error: Error): void {
  for (const [id, pending] of pendingRequests) {
    if (pending.socket !== socket) continue;
    pendingRequests.delete(id);
    pending.reject(error);
  }
}

function connectToGodot(host: string, port: number, state: ServerState, explicitToken?: string): Promise<{ success: boolean; message: string; info?: unknown }> {
  if (connectingPromise) return connectingPromise;
  const generation = ++connectionGeneration;
  const attempt = establishConnection(host, port, state, generation, explicitToken);
  connectingPromise = attempt;
  void attempt.then(() => { if (connectingPromise === attempt) connectingPromise = null; }, () => { if (connectingPromise === attempt) connectingPromise = null; });
  return attempt;
}

async function establishConnection(host: string, port: number, state: ServerState, generation: number, explicitToken?: string): Promise<{ success: boolean; message: string; info?: unknown }> {
  if (!["127.0.0.1", "localhost", "[::1]", "::1"].includes(host.toLowerCase())) {
    throw new Error("The Godot bridge only supports loopback connections. Use a local tunnel for remote editors.");
  }
  let token = explicitToken;
  if (!token) {
    if (!state.projectPath) throw new Error("Set the project path or provide a pairing token before connecting.");
    const pairingPath = path.join(state.projectPath, ".godot", "godot-ai-bridge.json");
    try {
      const metadata = await lstat(pairingPath);
      if (!metadata.isFile() || metadata.isSymbolicLink()) throw new Error("Invalid pairing file.");
      if (process.getuid && metadata.uid !== process.getuid()) throw new Error("Pairing file belongs to another user.");
      if (process.platform !== "win32" && (metadata.mode & 0o077) !== 0) throw new Error("Pairing credentials must be private (mode 0600).");
      const pairing = JSON.parse(await readFile(pairingPath, "utf8"));
      if (pairing.port !== port) throw new Error("Pairing port does not match the requested editor port.");
      token = pairing.token;
    } catch {
      throw new Error("Private bridge pairing credentials are unavailable. Enable the updated Godot AI Bridge in this project first.");
    }
  }
  if (typeof token !== "string" || !/^[a-f0-9]{64}$/.test(token)) throw new Error("Invalid bridge pairing token.");
  if (generation !== connectionGeneration) throw new Error("Connection cancelled");
  const url = `ws://${host === "::1" ? "[::1]" : host}:${port}`;
  const socket = new WebSocket(url, `godot-ai-bridge.${token}`, { handshakeTimeout: 5000 });
  wsConnection = socket;
  connectionState = state;
  socket.on("message", (data) => {
    try {
      const message = JSON.parse(data.toString());
      const pending = pendingRequests.get(message.id);
      if (!pending || pending.socket !== socket) return;
      pendingRequests.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message || "Unknown error"));
      else pending.resolve(message.result);
    } catch { console.error("Received invalid JSON from Godot bridge"); }
  });
  socket.on("close", () => {
    if (wsConnection === socket) {
      wsConnection = null;
      state.editorConnected = false;
      connectionState = null;
    }
    rejectSocketRequests(socket, new Error("Connection closed"));
  });
  // Retain an error handler after initialization; never expose handshake secrets.
  socket.on("error", () => { rejectSocketRequests(socket, new Error("Godot bridge connection failed")); });
  try {
    await new Promise<void>((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", () => reject(new Error("Godot bridge handshake failed; check pairing credentials.")));
      socket.once("close", () => reject(new Error("Godot bridge closed before initialization.")));
    });
    if (generation !== connectionGeneration || wsConnection !== socket) throw new Error("Connection cancelled");
    const info = await sendRequest("initialize", { client: "godot-mcp", version: "0.2.0", capabilities: ["scene_tree", "execute", "runtime"] }, 5000, socket);
    if (generation !== connectionGeneration || wsConnection !== socket) throw new Error("Connection cancelled");
    state.editorPort = port;
    state.editorConnected = true;
    return { success: true, message: `Connected to Godot editor at ${url}`, info };
  } catch (error) {
    socket.terminate();
    if (wsConnection === socket) { wsConnection = null; state.editorConnected = false; connectionState = null; }
    throw error;
  }
}

function runtimeTimeout({ frames = 0, seconds = 0 }: { frames?: number; seconds?: number }): number {
  // Match the bridge budget (one second per frame) plus network overhead.
  return Math.max(30000, (seconds + frames + 10) * 1000);
}

function normalizeRuntimeArtifactPath(
  inputPath: string,
  projectPath: string | null
): string {
  const trimmed = inputPath.trim();
  if (
    trimmed.startsWith("res://") ||
    trimmed.startsWith("user://") ||
    path.isAbsolute(trimmed) ||
    projectPath === null
  ) {
    return trimmed;
  }

  return path.resolve(projectPath, trimmed);
}

async function sendRequest(
  method: string,
  params: Record<string, unknown>,
  timeoutMs = 30000,
  socket = wsConnection
): Promise<unknown> {
  if (!socket || socket.readyState !== WebSocket.OPEN) {
    throw new Error("Not connected to Godot editor");
  }

  const id = ++messageId;

  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      pendingRequests.delete(id);
      reject(new Error(`Request timeout: ${method}`));
    }, timeoutMs);

    pendingRequests.set(id, {
      socket,
      resolve: (value) => {
        clearTimeout(timeout);
        resolve(value);
      },
      reject: (error) => {
        clearTimeout(timeout);
        reject(error);
      },
    });

    const message = JSON.stringify({
      jsonrpc: "2.0",
      id,
      method,
      params,
    });

    socket.send(message, (error) => {
      if (!error) return;
      const pending = pendingRequests.get(id);
      pendingRequests.delete(id);
      pending?.reject(error);
    });
  });
}
