import type { ParsedScene, SceneNode } from "../parsers/tscn-parser.js";
export declare function getSceneNodePath(node: SceneNode): string;
export declare function buildSceneNodePath(parentPath: string | undefined, nodeName: string): string;
export declare function getSceneRootName(scene: ParsedScene): string | null;
export declare function normalizeSceneParentPath(scene: ParsedScene, inputPath: string | undefined): string | undefined;
export declare function normalizeSceneNodePath(scene: ParsedScene, inputPath: string): string;
export declare function sceneHasNodePath(scene: ParsedScene, inputPath: string): boolean;
export declare function assertSceneParentExists(scene: ParsedScene, inputPath: string | undefined): string | undefined;
//# sourceMappingURL=scene-path-utils.d.ts.map