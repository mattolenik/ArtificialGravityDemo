import { describe, it, expect } from "vitest";
import {
  buildNavigationBakePlan,
  registerNavigationTools,
  validateNavigationPathSetup,
  toNavigationVector,
  toNavigationDescriptor,
} from "./navigation-tools.js";
import type { ToolHandler, ServerState } from "../index.js";

describe("Navigation Tools", () => {
  it("creates typed vectors for 2D and 3D navigation", () => {
    const vec2 = toNavigationVector([10, 20], "2d");
    const vec3 = toNavigationVector([1, 2, 3], "3d");

    expect(vec2).toEqual({ _type: "Vector2", x: 10, y: 20 });
    expect(vec3).toEqual({ _type: "Vector3", x: 1, y: 2, z: 3 });
  });

  it("classifies navigation node descriptors correctly", () => {
    const region = toNavigationDescriptor({
      name: "NavRegion",
      type: "NavigationRegion2D",
      parent: ".",
      properties: { navigation_layers: 1, enabled: true },
    });
    const agent = toNavigationDescriptor({
      name: "Agent",
      type: "NavigationAgent3D",
      parent: ".",
      properties: { max_speed: 8, radius: 0.5 },
    });

    expect(region?.kind).toBe("region");
    expect(region?.dimension).toBe("2d");
    expect(agent?.kind).toBe("agent");
    expect(agent?.dimension).toBe("3d");
  });

  it("returns null descriptor for non-navigation nodes", () => {
    const other = toNavigationDescriptor({
      name: "Player",
      type: "CharacterBody2D",
      parent: ".",
      properties: {},
    });

    expect(other).toBeNull();
  });

  it("builds bake plans from descriptors", () => {
    const descriptors = [
      toNavigationDescriptor({
        name: "Region",
        type: "NavigationRegion2D",
        parent: ".",
        properties: { navigation_layers: 1, navigation_polygon: "SubResource(\"1\")" },
      }),
      toNavigationDescriptor({
        name: "Agent",
        type: "NavigationAgent2D",
        parent: ".",
        properties: { navigation_layers: 1 },
      }),
    ].filter((entry): entry is NonNullable<typeof entry> => entry !== null);

    const plan = buildNavigationBakePlan(descriptors);
    expect(plan.readyForBake).toBe(true);
    expect(plan.regionCount).toBe(1);
  });

  it("validates layer compatibility for agents", () => {
    const descriptors = [
      toNavigationDescriptor({
        name: "Region",
        type: "NavigationRegion2D",
        parent: ".",
        properties: { navigation_layers: 1 },
      }),
      toNavigationDescriptor({
        name: "Agent",
        type: "NavigationAgent2D",
        parent: ".",
        properties: { navigation_layers: 2 },
      }),
    ].filter((entry): entry is NonNullable<typeof entry> => entry !== null);

    const report = validateNavigationPathSetup(descriptors);
    expect(report.valid).toBe(false);
    expect(report.errors[0]).toContain("no matching region");
  });

  it("registers all navigation tools", () => {
    const tools = new Map<string, ToolHandler>();
    const state: ServerState = {
      projectPath: process.cwd(),
      editorConnected: false,
      editorPort: 6550,
    };

    registerNavigationTools(tools, state);

    expect(tools.has("godot_navigation_list_nodes")).toBe(true);
    expect(tools.has("godot_navigation_add_region")).toBe(true);
    expect(tools.has("godot_navigation_add_agent")).toBe(true);
    expect(tools.has("godot_navigation_add_link")).toBe(true);
    expect(tools.has("godot_navigation_configure_region")).toBe(true);
    expect(tools.has("godot_navigation_configure_agent")).toBe(true);
    expect(tools.has("godot_navigation_build_bake_plan")).toBe(true);
    expect(tools.has("godot_navigation_validate_paths")).toBe(true);
  });
});
