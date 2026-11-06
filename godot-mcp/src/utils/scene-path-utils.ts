import type { ParsedScene, SceneNode } from "../parsers/tscn-parser.js";

export function getSceneNodePath(node: SceneNode): string {
  if (!node.parent || node.parent === ".") {
    return node.name;
  }

  return `${node.parent}/${node.name}`;
}

export function buildSceneNodePath(
  parentPath: string | undefined,
  nodeName: string
): string {
  if (!parentPath || parentPath === ".") {
    return nodeName;
  }

  return `${parentPath}/${nodeName}`;
}

export function getSceneRootName(scene: ParsedScene): string | null {
  const rootNode = scene.nodes.find((node) => node.parent === undefined);
  return rootNode?.name ?? null;
}

export function normalizeSceneParentPath(
  scene: ParsedScene,
  inputPath: string | undefined
): string | undefined {
  if (inputPath === undefined) {
    return undefined;
  }

  const trimmed = inputPath.trim();
  if (!trimmed) {
    return undefined;
  }

  if (trimmed === ".") {
    return ".";
  }

  const rootName = getSceneRootName(scene);
  if (!rootName) {
    return trimmed;
  }

  if (trimmed === rootName) {
    return ".";
  }

  const rootPrefix = `${rootName}/`;
  if (trimmed.startsWith(rootPrefix)) {
    const relativePath = trimmed.slice(rootPrefix.length);
    return relativePath || ".";
  }

  return trimmed;
}

export function normalizeSceneNodePath(
  scene: ParsedScene,
  inputPath: string
): string {
  const trimmed = inputPath.trim();
  if (!trimmed) {
    return trimmed;
  }

  const rootName = getSceneRootName(scene);
  if (!rootName) {
    return trimmed;
  }

  if (trimmed === "." || trimmed === rootName) {
    return rootName;
  }

  const rootPrefix = `${rootName}/`;
  if (trimmed.startsWith(rootPrefix)) {
    const relativePath = trimmed.slice(rootPrefix.length);
    return relativePath || rootName;
  }

  return trimmed;
}

export function sceneHasNodePath(scene: ParsedScene, inputPath: string): boolean {
  const normalizedPath = normalizeSceneNodePath(scene, inputPath);
  return scene.nodes.some((node) => getSceneNodePath(node) === normalizedPath);
}

export function assertSceneParentExists(
  scene: ParsedScene,
  inputPath: string | undefined
): string | undefined {
  const normalizedPath = normalizeSceneParentPath(scene, inputPath);
  if (normalizedPath === undefined || normalizedPath === ".") {
    return normalizedPath;
  }

  if (!sceneHasNodePath(scene, normalizedPath)) {
    throw new Error(`Parent path not found in scene: ${inputPath}`);
  }

  return normalizedPath;
}
