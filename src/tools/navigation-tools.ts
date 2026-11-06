/**
 * Navigation tools for Godot MCP
 *
 * Supports file-based setup and configuration of navigation nodes in .tscn scenes.
 */

import { z } from "zod";
import * as fs from "../utils/project-fs.js";
import { TscnParser, SceneNode } from "../parsers/tscn-parser.js";
import type { ToolHandler, ServerState } from "../index.js";
import { resolveProjectPath } from "../utils/path-utils.js";
import {
  assertSceneParentExists,
  buildSceneNodePath,
  getSceneNodePath,
  normalizeSceneNodePath,
  sceneHasNodePath,
} from "../utils/scene-path-utils.js";

export type NavigationKind = "region" | "agent" | "link";
export type NavigationDimension = "2d" | "3d";

export interface NavigationNodeDescriptor {
  nodePath: string;
  type: string;
  kind: NavigationKind;
  dimension: NavigationDimension;
  properties: Record<string, unknown>;
}

export function registerNavigationTools(
  tools: Map<string, ToolHandler>,
  state: ServerState
): void {
  tools.set("godot_navigation_list_nodes", {
    description:
      "List navigation nodes (regions, agents, links) in a scene with optional key properties.",
    inputSchema: z.object({
      scenePath: z.string().describe("Path to scene file"),
      includeProperties: z
        .boolean()
        .optional()
        .default(true)
        .describe("Include key navigation properties"),
    }),
    handler: async (args) => {
      const { scenePath, includeProperties } = args as {
        scenePath: string;
        includeProperties: boolean;
      };

      const fullPath = resolveProjectPath(scenePath, state.projectPath);
      const content = await fs.readFile(fullPath, "utf-8");
      const scene = TscnParser.parse(content);

      const nodes = scene.nodes
        .map((node) => toNavigationDescriptor(node))
        .filter((entry): entry is NavigationNodeDescriptor => entry !== null)
        .map((entry) => {
          if (!includeProperties) {
            return {
              nodePath: entry.nodePath,
              type: entry.type,
              kind: entry.kind,
              dimension: entry.dimension,
            };
          }
          return entry;
        });

      return {
        scenePath,
        count: nodes.length,
        nodes,
      };
    },
  });

  tools.set("godot_navigation_add_region", {
    description:
      "Add a NavigationRegion2D/3D node to a scene with baseline navigation properties.",
    inputSchema: z.object({
      scenePath: z.string().describe("Path to scene file"),
      nodeName: z
        .string()
        .optional()
        .default("NavigationRegion")
        .describe("Node name"),
      parentPath: z
        .string()
        .optional()
        .default(".")
        .describe("Parent path ('.' for root child)"),
      dimension: z
        .enum(["2d", "3d"])
        .optional()
        .default("2d")
        .describe("Navigation dimension to create"),
      enabled: z
        .boolean()
        .optional()
        .default(true)
        .describe("Whether the region is enabled"),
      navigationLayers: z
        .number()
        .int()
        .min(1)
        .optional()
        .default(1)
        .describe("Navigation layer bitmask value"),
      enterCost: z.number().optional().default(0).describe("Region enter cost"),
      travelCost: z.number().optional().default(1).describe("Region travel cost"),
    }),
    handler: async (args) => {
      const {
        scenePath,
        nodeName,
        parentPath,
        dimension,
        enabled,
        navigationLayers,
        enterCost,
        travelCost,
      } = args as {
        scenePath: string;
        nodeName: string;
        parentPath: string;
        dimension: NavigationDimension;
        enabled: boolean;
        navigationLayers: number;
        enterCost: number;
        travelCost: number;
      };

      const fullPath = resolveProjectPath(scenePath, state.projectPath);
      const content = await fs.readFile(fullPath, "utf-8");
      const scene = TscnParser.parse(content);
      const normalizedParentPath = assertSceneParentExists(scene, parentPath) ?? ".";

      const nodePath = buildSceneNodePath(normalizedParentPath, nodeName);
      if (sceneHasNodePath(scene, nodePath)) {
        throw new Error(`Node already exists: ${nodePath}`);
      }

      const type = dimension === "2d" ? "NavigationRegion2D" : "NavigationRegion3D";
      const properties = {
        enabled,
        navigation_layers: navigationLayers,
        enter_cost: enterCost,
        travel_cost: travelCost,
      };

      TscnParser.addNode(scene, {
        name: nodeName,
        type,
        parent: normalizedParentPath,
        properties,
      });

      await fs.writeFile(fullPath, TscnParser.serialize(scene), "utf-8");

      return {
        success: true,
        scenePath,
        created: nodePath,
        type,
      };
    },
  });

  tools.set("godot_navigation_add_agent", {
    description:
      "Add a NavigationAgent2D/3D node to a scene with baseline movement/avoidance properties.",
    inputSchema: z.object({
      scenePath: z.string().describe("Path to scene file"),
      nodeName: z
        .string()
        .optional()
        .default("NavigationAgent")
        .describe("Node name"),
      parentPath: z
        .string()
        .optional()
        .default(".")
        .describe("Parent path ('.' for root child)"),
      dimension: z
        .enum(["2d", "3d"])
        .optional()
        .default("2d")
        .describe("Navigation dimension to create"),
      radius: z.number().optional().default(10).describe("Agent collision radius"),
      maxSpeed: z.number().optional().default(200).describe("Maximum movement speed"),
      neighborDistance: z
        .number()
        .optional()
        .default(50)
        .describe("Neighbor avoidance distance"),
      pathDesiredDistance: z
        .number()
        .optional()
        .default(10)
        .describe("Distance threshold for path point completion"),
      targetDesiredDistance: z
        .number()
        .optional()
        .default(10)
        .describe("Distance threshold for target reached"),
      avoidanceEnabled: z
        .boolean()
        .optional()
        .default(true)
        .describe("Enable RVO-style avoidance"),
      navigationLayers: z
        .number()
        .int()
        .min(1)
        .optional()
        .default(1)
        .describe("Navigation layer bitmask value"),
    }),
    handler: async (args) => {
      const {
        scenePath,
        nodeName,
        parentPath,
        dimension,
        radius,
        maxSpeed,
        neighborDistance,
        pathDesiredDistance,
        targetDesiredDistance,
        avoidanceEnabled,
        navigationLayers,
      } = args as {
        scenePath: string;
        nodeName: string;
        parentPath: string;
        dimension: NavigationDimension;
        radius: number;
        maxSpeed: number;
        neighborDistance: number;
        pathDesiredDistance: number;
        targetDesiredDistance: number;
        avoidanceEnabled: boolean;
        navigationLayers: number;
      };

      const fullPath = resolveProjectPath(scenePath, state.projectPath);
      const content = await fs.readFile(fullPath, "utf-8");
      const scene = TscnParser.parse(content);
      const normalizedParentPath = assertSceneParentExists(scene, parentPath) ?? ".";

      const nodePath = buildSceneNodePath(normalizedParentPath, nodeName);
      if (sceneHasNodePath(scene, nodePath)) {
        throw new Error(`Node already exists: ${nodePath}`);
      }

      const type = dimension === "2d" ? "NavigationAgent2D" : "NavigationAgent3D";
      const properties = {
        radius,
        max_speed: maxSpeed,
        neighbor_distance: neighborDistance,
        path_desired_distance: pathDesiredDistance,
        target_desired_distance: targetDesiredDistance,
        avoidance_enabled: avoidanceEnabled,
        navigation_layers: navigationLayers,
      };

      TscnParser.addNode(scene, {
        name: nodeName,
        type,
        parent: normalizedParentPath,
        properties,
      });

      await fs.writeFile(fullPath, TscnParser.serialize(scene), "utf-8");

      return {
        success: true,
        scenePath,
        created: nodePath,
        type,
      };
    },
  });

  tools.set("godot_navigation_add_link", {
    description:
      "Add a NavigationLink2D/3D node with start/end positions and layer settings.",
    inputSchema: z.object({
      scenePath: z.string().describe("Path to scene file"),
      nodeName: z
        .string()
        .optional()
        .default("NavigationLink")
        .describe("Node name"),
      parentPath: z
        .string()
        .optional()
        .default(".")
        .describe("Parent path ('.' for root child)"),
      dimension: z
        .enum(["2d", "3d"])
        .optional()
        .default("2d")
        .describe("Navigation dimension to create"),
      startPosition: z
        .array(z.number())
        .min(2)
        .max(3)
        .describe("Start position [x,y] or [x,y,z]"),
      endPosition: z
        .array(z.number())
        .min(2)
        .max(3)
        .describe("End position [x,y] or [x,y,z]"),
      bidirectional: z
        .boolean()
        .optional()
        .default(true)
        .describe("Whether travel is allowed in both directions"),
      navigationLayers: z
        .number()
        .int()
        .min(1)
        .optional()
        .default(1)
        .describe("Navigation layer bitmask value"),
      enabled: z.boolean().optional().default(true).describe("Whether the link is enabled"),
    }),
    handler: async (args) => {
      const {
        scenePath,
        nodeName,
        parentPath,
        dimension,
        startPosition,
        endPosition,
        bidirectional,
        navigationLayers,
        enabled,
      } = args as {
        scenePath: string;
        nodeName: string;
        parentPath: string;
        dimension: NavigationDimension;
        startPosition: number[];
        endPosition: number[];
        bidirectional: boolean;
        navigationLayers: number;
        enabled: boolean;
      };

      const start = toNavigationVector(startPosition, dimension);
      const end = toNavigationVector(endPosition, dimension);

      const fullPath = resolveProjectPath(scenePath, state.projectPath);
      const content = await fs.readFile(fullPath, "utf-8");
      const scene = TscnParser.parse(content);
      const normalizedParentPath = assertSceneParentExists(scene, parentPath) ?? ".";

      const nodePath = buildSceneNodePath(normalizedParentPath, nodeName);
      if (sceneHasNodePath(scene, nodePath)) {
        throw new Error(`Node already exists: ${nodePath}`);
      }

      const type = dimension === "2d" ? "NavigationLink2D" : "NavigationLink3D";
      const properties = {
        start_position: start,
        end_position: end,
        bidirectional,
        navigation_layers: navigationLayers,
        enabled,
      };

      TscnParser.addNode(scene, {
        name: nodeName,
        type,
        parent: normalizedParentPath,
        properties,
      });

      await fs.writeFile(fullPath, TscnParser.serialize(scene), "utf-8");

      return {
        success: true,
        scenePath,
        created: nodePath,
        type,
      };
    },
  });

  tools.set("godot_navigation_configure_region", {
    description:
      "Configure properties on an existing NavigationRegion2D/3D node.",
    inputSchema: z.object({
      scenePath: z.string().describe("Path to scene file"),
      nodePath: z.string().describe("Target region node path"),
      enabled: z.boolean().optional().describe("Enable or disable the region"),
      navigationLayers: z
        .number()
        .int()
        .min(1)
        .optional()
        .describe("Navigation layer bitmask value"),
      enterCost: z.number().optional().describe("Region enter cost"),
      travelCost: z.number().optional().describe("Region travel cost"),
    }),
    handler: async (args) => {
      const { scenePath, nodePath, enabled, navigationLayers, enterCost, travelCost } =
        args as {
          scenePath: string;
          nodePath: string;
          enabled?: boolean;
          navigationLayers?: number;
          enterCost?: number;
          travelCost?: number;
        };

      const updates = stripUndefined({
        enabled,
        navigation_layers: navigationLayers,
        enter_cost: enterCost,
        travel_cost: travelCost,
      });

      if (Object.keys(updates).length === 0) {
        throw new Error("Provide at least one property to update");
      }

      const fullPath = resolveProjectPath(scenePath, state.projectPath);
      const content = await fs.readFile(fullPath, "utf-8");
      const scene = TscnParser.parse(content);
      const normalizedNodePath = normalizeSceneNodePath(scene, nodePath);
      const node = scene.nodes.find(
        (entry) => getSceneNodePath(entry) === normalizedNodePath
      );

      if (!node) {
        throw new Error(`Node not found: ${nodePath}`);
      }
      if (!isRegionType(node.type)) {
        throw new Error(
          `Node '${normalizedNodePath}' is not a NavigationRegion node (found '${node.type || "unknown"}')`
        );
      }

      const success = TscnParser.modifyNode(scene, normalizedNodePath, {
        properties: updates,
      });
      if (!success) {
        throw new Error(`Failed to update node: ${normalizedNodePath}`);
      }

      await fs.writeFile(fullPath, TscnParser.serialize(scene), "utf-8");

      return {
        success: true,
        scenePath,
        nodePath: normalizedNodePath,
        updatedProperties: Object.keys(updates),
      };
    },
  });

  tools.set("godot_navigation_configure_agent", {
    description:
      "Configure properties on an existing NavigationAgent2D/3D node.",
    inputSchema: z.object({
      scenePath: z.string().describe("Path to scene file"),
      nodePath: z.string().describe("Target agent node path"),
      radius: z.number().optional().describe("Agent collision radius"),
      maxSpeed: z.number().optional().describe("Maximum movement speed"),
      neighborDistance: z.number().optional().describe("Neighbor avoidance distance"),
      pathDesiredDistance: z
        .number()
        .optional()
        .describe("Distance threshold for path point completion"),
      targetDesiredDistance: z
        .number()
        .optional()
        .describe("Distance threshold for target reached"),
      avoidanceEnabled: z.boolean().optional().describe("Enable RVO-style avoidance"),
      navigationLayers: z
        .number()
        .int()
        .min(1)
        .optional()
        .describe("Navigation layer bitmask value"),
    }),
    handler: async (args) => {
      const {
        scenePath,
        nodePath,
        radius,
        maxSpeed,
        neighborDistance,
        pathDesiredDistance,
        targetDesiredDistance,
        avoidanceEnabled,
        navigationLayers,
      } = args as {
        scenePath: string;
        nodePath: string;
        radius?: number;
        maxSpeed?: number;
        neighborDistance?: number;
        pathDesiredDistance?: number;
        targetDesiredDistance?: number;
        avoidanceEnabled?: boolean;
        navigationLayers?: number;
      };

      const updates = stripUndefined({
        radius,
        max_speed: maxSpeed,
        neighbor_distance: neighborDistance,
        path_desired_distance: pathDesiredDistance,
        target_desired_distance: targetDesiredDistance,
        avoidance_enabled: avoidanceEnabled,
        navigation_layers: navigationLayers,
      });

      if (Object.keys(updates).length === 0) {
        throw new Error("Provide at least one property to update");
      }

      const fullPath = resolveProjectPath(scenePath, state.projectPath);
      const content = await fs.readFile(fullPath, "utf-8");
      const scene = TscnParser.parse(content);
      const normalizedNodePath = normalizeSceneNodePath(scene, nodePath);
      const node = scene.nodes.find(
        (entry) => getSceneNodePath(entry) === normalizedNodePath
      );

      if (!node) {
        throw new Error(`Node not found: ${nodePath}`);
      }
      if (!isAgentType(node.type)) {
        throw new Error(
          `Node '${normalizedNodePath}' is not a NavigationAgent node (found '${node.type || "unknown"}')`
        );
      }

      const success = TscnParser.modifyNode(scene, normalizedNodePath, {
        properties: updates,
      });
      if (!success) {
        throw new Error(`Failed to update node: ${normalizedNodePath}`);
      }

      await fs.writeFile(fullPath, TscnParser.serialize(scene), "utf-8");

      return {
        success: true,
        scenePath,
        nodePath: normalizedNodePath,
        updatedProperties: Object.keys(updates),
      };
    },
  });

  tools.set("godot_navigation_build_bake_plan", {
    description:
      "Build a navigation bake checklist from scene regions/links/agents for editor execution.",
    inputSchema: z.object({
      scenePath: z.string().describe("Path to scene file"),
      includeChecklist: z
        .boolean()
        .optional()
        .default(true)
        .describe("Include step-by-step checklist"),
    }),
    handler: async (args) => {
      const { scenePath, includeChecklist } = args as {
        scenePath: string;
        includeChecklist: boolean;
      };

      const fullPath = resolveProjectPath(scenePath, state.projectPath);
      const content = await fs.readFile(fullPath, "utf-8");
      const scene = TscnParser.parse(content);
      const descriptors = scene.nodes
        .map((node) => toNavigationDescriptor(node))
        .filter((entry): entry is NavigationNodeDescriptor => entry !== null);

      const plan = buildNavigationBakePlan(descriptors, includeChecklist);
      return {
        scenePath,
        ...plan,
      };
    },
  });

  tools.set("godot_navigation_validate_paths", {
    description:
      "Validate navigation setup consistency (layers, region coverage, and link endpoints).",
    inputSchema: z.object({
      scenePath: z.string().describe("Path to scene file"),
      agentNodePaths: z
        .array(z.string())
        .optional()
        .describe("Optional subset of agent node paths to validate"),
      strict: z
        .boolean()
        .optional()
        .default(false)
        .describe("If true, validation errors throw"),
    }),
    handler: async (args) => {
      const { scenePath, agentNodePaths, strict } = args as {
        scenePath: string;
        agentNodePaths?: string[];
        strict: boolean;
      };

      const fullPath = resolveProjectPath(scenePath, state.projectPath);
      const content = await fs.readFile(fullPath, "utf-8");
      const scene = TscnParser.parse(content);
      const descriptors = scene.nodes
        .map((node) => toNavigationDescriptor(node))
        .filter((entry): entry is NavigationNodeDescriptor => entry !== null);
      const normalizedAgentNodePaths = agentNodePaths?.map((nodePath) =>
        normalizeSceneNodePath(scene, nodePath)
      );

      const report = validateNavigationPathSetup(
        descriptors,
        normalizedAgentNodePaths
      );
      if (strict && report.errors.length > 0) {
        throw new Error(`Navigation validation failed: ${report.errors.join("; ")}`);
      }

      return {
        scenePath,
        ...report,
      };
    },
  });
}

export function buildNavigationBakePlan(
  descriptors: NavigationNodeDescriptor[],
  includeChecklist = true
): Record<string, unknown> {
  const regions = descriptors.filter((node) => node.kind === "region");
  const agents = descriptors.filter((node) => node.kind === "agent");
  const links = descriptors.filter((node) => node.kind === "link");

  const missingRegionResources = regions
    .filter((region) => {
      const has2DPoly = region.properties.navigation_polygon != null;
      const has3DMesh = region.properties.navigation_mesh != null;
      return region.dimension === "2d" ? !has2DPoly : !has3DMesh;
    })
    .map((region) => region.nodePath);

  const steps = includeChecklist
    ? [
        "Open scene in Godot editor.",
        `Inspect ${regions.length} region node(s) and assign navigation polygons/meshes where missing.`,
        "Run region bake/update in editor for each navigation map.",
        "Play scene and verify agents can reach intended targets.",
      ]
    : [];

  return {
    regionCount: regions.length,
    agentCount: agents.length,
    linkCount: links.length,
    missingRegionResources,
    readyForBake: regions.length > 0 && missingRegionResources.length === 0,
    checklist: steps,
  };
}

export function validateNavigationPathSetup(
  descriptors: NavigationNodeDescriptor[],
  agentNodePaths?: string[]
): {
  valid: boolean;
  errors: string[];
  warnings: string[];
  checkedAgents: string[];
} {
  const errors: string[] = [];
  const warnings: string[] = [];

  const regions = descriptors.filter((node) => node.kind === "region");
  const agents = descriptors.filter((node) => node.kind === "agent");
  const links = descriptors.filter((node) => node.kind === "link");

  if (regions.length === 0) {
    errors.push("No navigation regions found.");
  }
  if (agents.length === 0) {
    warnings.push("No navigation agents found.");
  }

  const targetAgents = agentNodePaths
    ? agents.filter((agent) => agentNodePaths.includes(agent.nodePath))
    : agents;

  for (const agent of targetAgents) {
    const layerMask = Number(agent.properties.navigation_layers ?? 1);
    const hasRegionOnLayer = regions.some((region) => {
      const regionMask = Number(region.properties.navigation_layers ?? 1);
      return region.dimension === agent.dimension &&
        region.properties.enabled !== false &&
        (layerMask & regionMask) !== 0;
    });
    if (!hasRegionOnLayer) {
      errors.push(
        `Agent '${agent.nodePath}' has no matching region (enabled and same dimension) by navigation_layers (${layerMask}).`
      );
    }
  }

  for (const link of links) {
    const start = link.properties.start_position as Record<string, unknown> | undefined;
    const end = link.properties.end_position as Record<string, unknown> | undefined;
    if (!start || !end) {
      warnings.push(`Link '${link.nodePath}' is missing start/end positions.`);
      continue;
    }
    if (start._type !== end._type) {
      errors.push(`Link '${link.nodePath}' has mismatched start/end vector types.`);
    }
  }

  if (agentNodePaths && targetAgents.length !== agentNodePaths.length) {
    const found = new Set(targetAgents.map((agent) => agent.nodePath));
    const missing = agentNodePaths.filter((nodePath) => !found.has(nodePath));
    warnings.push(`Requested agents not found: ${missing.join(", ")}`);
  }

  return {
    valid: errors.length === 0,
    errors,
    warnings,
    checkedAgents: targetAgents.map((agent) => agent.nodePath),
  };
}

export function toNavigationVector(
  coordinates: number[],
  dimension: NavigationDimension
): Record<string, unknown> {
  if (dimension === "2d") {
    if (coordinates.length !== 2) {
      throw new Error("2D navigation vectors require [x, y]");
    }
    return { _type: "Vector2", x: coordinates[0], y: coordinates[1] };
  }

  if (coordinates.length !== 3) {
    throw new Error("3D navigation vectors require [x, y, z]");
  }
  return {
    _type: "Vector3",
    x: coordinates[0],
    y: coordinates[1],
    z: coordinates[2],
  };
}

export function toNavigationDescriptor(
  node: SceneNode
): NavigationNodeDescriptor | null {
  const typeInfo = classifyNavigationType(node.type);
  if (!typeInfo) return null;

  const base: NavigationNodeDescriptor = {
    nodePath: getSceneNodePath(node),
    type: node.type || "",
    kind: typeInfo.kind,
    dimension: typeInfo.dimension,
    properties: {},
  };

  if (typeInfo.kind === "region") {
    base.properties = stripUndefined({
      enabled: node.properties.enabled,
      navigation_layers: node.properties.navigation_layers,
      enter_cost: node.properties.enter_cost,
      travel_cost: node.properties.travel_cost,
      navigation_polygon: node.properties.navigation_polygon,
      navigation_mesh: node.properties.navigation_mesh,
    });
  } else if (typeInfo.kind === "agent") {
    base.properties = stripUndefined({
      radius: node.properties.radius,
      max_speed: node.properties.max_speed,
      neighbor_distance: node.properties.neighbor_distance,
      path_desired_distance: node.properties.path_desired_distance,
      target_desired_distance: node.properties.target_desired_distance,
      avoidance_enabled: node.properties.avoidance_enabled,
      navigation_layers: node.properties.navigation_layers,
    });
  } else {
    base.properties = stripUndefined({
      start_position: node.properties.start_position,
      end_position: node.properties.end_position,
      bidirectional: node.properties.bidirectional,
      navigation_layers: node.properties.navigation_layers,
      enabled: node.properties.enabled,
    });
  }

  return base;
}

function classifyNavigationType(
  type: string | undefined
): { kind: NavigationKind; dimension: NavigationDimension } | null {
  if (!type) return null;

  if (type === "NavigationRegion2D") return { kind: "region", dimension: "2d" };
  if (type === "NavigationRegion3D") return { kind: "region", dimension: "3d" };
  if (type === "NavigationAgent2D") return { kind: "agent", dimension: "2d" };
  if (type === "NavigationAgent3D") return { kind: "agent", dimension: "3d" };
  if (type === "NavigationLink2D") return { kind: "link", dimension: "2d" };
  if (type === "NavigationLink3D") return { kind: "link", dimension: "3d" };
  return null;
}

function isRegionType(type: string | undefined): boolean {
  return type === "NavigationRegion2D" || type === "NavigationRegion3D";
}

function isAgentType(type: string | undefined): boolean {
  return type === "NavigationAgent2D" || type === "NavigationAgent3D";
}

function stripUndefined(
  input: Record<string, unknown>
): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(input).filter(([, value]) => value !== undefined)
  );
}
