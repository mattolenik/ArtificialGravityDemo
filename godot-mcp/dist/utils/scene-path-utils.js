export function getSceneNodePath(node) {
    if (!node.parent || node.parent === ".") {
        return node.name;
    }
    return `${node.parent}/${node.name}`;
}
export function buildSceneNodePath(parentPath, nodeName) {
    if (!parentPath || parentPath === ".") {
        return nodeName;
    }
    return `${parentPath}/${nodeName}`;
}
export function getSceneRootName(scene) {
    const rootNode = scene.nodes.find((node) => node.parent === undefined);
    return rootNode?.name ?? null;
}
export function normalizeSceneParentPath(scene, inputPath) {
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
export function normalizeSceneNodePath(scene, inputPath) {
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
export function sceneHasNodePath(scene, inputPath) {
    const normalizedPath = normalizeSceneNodePath(scene, inputPath);
    return scene.nodes.some((node) => getSceneNodePath(node) === normalizedPath);
}
export function assertSceneParentExists(scene, inputPath) {
    const normalizedPath = normalizeSceneParentPath(scene, inputPath);
    if (normalizedPath === undefined || normalizedPath === ".") {
        return normalizedPath;
    }
    if (!sceneHasNodePath(scene, normalizedPath)) {
        throw new Error(`Parent path not found in scene: ${inputPath}`);
    }
    return normalizedPath;
}
//# sourceMappingURL=scene-path-utils.js.map