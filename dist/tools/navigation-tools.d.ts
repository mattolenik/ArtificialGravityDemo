/**
 * Navigation tools for Godot MCP
 *
 * Supports file-based setup and configuration of navigation nodes in .tscn scenes.
 */
import { SceneNode } from "../parsers/tscn-parser.js";
import type { ToolHandler, ServerState } from "../index.js";
export type NavigationKind = "region" | "agent" | "link";
export type NavigationDimension = "2d" | "3d";
export interface NavigationNodeDescriptor {
    nodePath: string;
    type: string;
    kind: NavigationKind;
    dimension: NavigationDimension;
    properties: Record<string, unknown>;
}
export declare function registerNavigationTools(tools: Map<string, ToolHandler>, state: ServerState): void;
export declare function buildNavigationBakePlan(descriptors: NavigationNodeDescriptor[], includeChecklist?: boolean): Record<string, unknown>;
export declare function validateNavigationPathSetup(descriptors: NavigationNodeDescriptor[], agentNodePaths?: string[]): {
    valid: boolean;
    errors: string[];
    warnings: string[];
    checkedAgents: string[];
};
export declare function toNavigationVector(coordinates: number[], dimension: NavigationDimension): Record<string, unknown>;
export declare function toNavigationDescriptor(node: SceneNode): NavigationNodeDescriptor | null;
//# sourceMappingURL=navigation-tools.d.ts.map