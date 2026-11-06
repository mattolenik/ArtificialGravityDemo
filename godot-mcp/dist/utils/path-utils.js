import * as fs from "node:fs";
import * as path from "path";
function getProjectRoot(projectPath) {
    return path.resolve(projectPath || process.cwd());
}
// Resolve symlinks in the deepest existing ancestor, including for new files.
function canonicalPath(target) {
    try {
        return fs.realpathSync.native(target);
    }
    catch (error) {
        if (error.code !== "ENOENT")
            throw error;
        // A dangling symlink must not be mistaken for an absent output component.
        try {
            if (fs.lstatSync(target).isSymbolicLink())
                throw new Error(`Dangling symlink: ${target}`);
        }
        catch (inner) {
            if (inner.code !== "ENOENT")
                throw inner;
        }
        const parent = path.dirname(target);
        if (parent === target)
            throw error;
        return path.join(canonicalPath(parent), path.basename(target));
    }
}
function isWithinRoot(rootPath, targetPath) {
    const relativePath = path.relative(rootPath, targetPath);
    return (relativePath === "" ||
        (relativePath !== ".." && !relativePath.startsWith(`..${path.sep}`) && !path.isAbsolute(relativePath)));
}
export function resolveProjectPath(inputPath, projectPath) {
    let normalizedInput = inputPath.trim();
    if (!normalizedInput) {
        throw new Error("Path cannot be empty");
    }
    if (normalizedInput.startsWith("res://")) {
        normalizedInput = normalizedInput.slice(6);
    }
    const rootPath = getProjectRoot(projectPath);
    const resolvedPath = path.isAbsolute(normalizedInput)
        ? path.resolve(normalizedInput)
        : path.resolve(rootPath, normalizedInput);
    if (!isWithinRoot(rootPath, resolvedPath)) {
        throw new Error(`Path escapes project root: ${inputPath}`);
    }
    if (!isWithinRoot(canonicalPath(rootPath), canonicalPath(resolvedPath))) {
        throw new Error(`Path escapes project root through symlink: ${inputPath}`);
    }
    return resolvedPath;
}
export function resolveProjectDirectory(directory, projectPath) {
    if (!directory) {
        return getProjectRoot(projectPath);
    }
    return resolveProjectPath(directory, projectPath);
}
export function getProjectRelativePath(fullPath, projectPath) {
    const rootPath = getProjectRoot(projectPath);
    const resolvedPath = path.resolve(fullPath);
    if (!isWithinRoot(rootPath, resolvedPath)) {
        throw new Error(`Path escapes project root: ${fullPath}`);
    }
    return path.relative(rootPath, resolvedPath);
}
//# sourceMappingURL=path-utils.js.map