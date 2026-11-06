import { describe, expect, it } from "vitest";
import type { ParsedScene } from "../parsers/tscn-parser.js";
import {
  assertSceneParentExists,
  buildSceneNodePath,
  getSceneNodePath,
  normalizeSceneNodePath,
  normalizeSceneParentPath,
  sceneHasNodePath,
} from "./scene-path-utils.js";

const scene: ParsedScene = {
  header: { type: "gd_scene", format: 3 },
  externalResources: [],
  subResources: [],
  nodes: [
    { name: "Main", type: "Node2D", properties: {} },
    { name: "Player", type: "CharacterBody2D", parent: ".", properties: {} },
    { name: "UI", type: "CanvasLayer", parent: ".", properties: {} },
    { name: "Label", type: "Label", parent: "UI", properties: {} },
  ],
  connections: [],
};

describe("scene path utils", () => {
  it("normalizes live-editor parent paths for file-based scene tools", () => {
    expect(normalizeSceneParentPath(scene, "Main")).toBe(".");
    expect(normalizeSceneParentPath(scene, "Main/UI")).toBe("UI");
    expect(normalizeSceneParentPath(scene, "UI")).toBe("UI");
  });

  it("normalizes live-editor node paths for file-based scene tools", () => {
    expect(normalizeSceneNodePath(scene, "Main")).toBe("Main");
    expect(normalizeSceneNodePath(scene, "Main/UI")).toBe("UI");
    expect(normalizeSceneNodePath(scene, "Main/UI/Label")).toBe("UI/Label");
    expect(normalizeSceneNodePath(scene, "UI/Label")).toBe("UI/Label");
  });

  it("builds and resolves internal scene node paths consistently", () => {
    expect(buildSceneNodePath(".", "Player")).toBe("Player");
    expect(buildSceneNodePath("UI", "Label")).toBe("UI/Label");
    expect(getSceneNodePath(scene.nodes[0])).toBe("Main");
    expect(getSceneNodePath(scene.nodes[3])).toBe("UI/Label");
  });

  it("accepts either root-prefixed or root-relative paths when checking existence", () => {
    expect(sceneHasNodePath(scene, "Main/UI")).toBe(true);
    expect(sceneHasNodePath(scene, "Main/UI/Label")).toBe(true);
    expect(sceneHasNodePath(scene, "UI/Label")).toBe(true);
    expect(sceneHasNodePath(scene, "Main/Missing")).toBe(false);
  });

  it("validates parent paths after normalization", () => {
    expect(assertSceneParentExists(scene, "Main/UI")).toBe("UI");
    expect(assertSceneParentExists(scene, ".")).toBe(".");
    expect(() => assertSceneParentExists(scene, "Main/Missing")).toThrow(
      "Parent path not found in scene: Main/Missing"
    );
  });
});
