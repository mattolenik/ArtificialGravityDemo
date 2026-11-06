import { describe, expect, it } from "vitest";
import { registerEditorTools } from "./editor-tools.js";

describe("editor tools", () => {
  it("accepts an empty runtime wait request so the runtime bridge can default to one frame", () => {
    const tools = new Map();
    registerEditorTools(tools as any, {
      projectPath: "/test/project",
      editorConnected: false,
      editorPort: 6550,
    });

    const runtimeWaitTool = tools.get("godot_runtime_wait");
    expect(runtimeWaitTool).toBeDefined();
    expect(runtimeWaitTool?.inputSchema.parse({})).toEqual({});
  });
});
