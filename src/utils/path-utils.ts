import * as fs from "node:fs";
import * as path from "path";

function getProjectRoot(projectPath: string | null): string {
  return path.resolve(projectPath || process.cwd());
}

// Resolve symlinks in the deepest existing ancestor, including for new files.
function canonicalPath(target: string): string {
  try { return fs.realpathSync.native(target); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    // A dangling symlink must not be mistaken for an absent output component.
    try { if (fs.lstatSync(target).isSymbolicLink()) throw new Error(`Dangling symlink: ${target}`); }
    catch (inner) { if ((inner as NodeJS.ErrnoException).code !== "ENOENT") throw inner; }
    const parent = path.dirname(target);
    if (parent === target) throw error;
    return path.join(canonicalPath(parent), path.basename(target));
  }
}

function isWithinRoot(rootPath: string, targetPath: string): boolean {
  const relativePath = path.relative(rootPath, targetPath);
  return (
    relativePath === "" ||
    (relativePath !== ".." && !relativePath.startsWith(`..${path.sep}`) && !path.isAbsolute(relativePath))
  );
}

export function resolveProjectPath(
  inputPath: string,
  projectPath: string | null
): string {
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

export function resolveProjectDirectory(
  directory: string | undefined,
  projectPath: string | null
): string {
  if (!directory) {
    return getProjectRoot(projectPath);
  }

  return resolveProjectPath(directory, projectPath);
}

export function getProjectRelativePath(
  fullPath: string,
  projectPath: string | null
): string {
  const rootPath = getProjectRoot(projectPath);
  const resolvedPath = path.resolve(fullPath);

  if (!isWithinRoot(rootPath, resolvedPath)) {
    throw new Error(`Path escapes project root: ${fullPath}`);
  }

  return path.relative(rootPath, resolvedPath);
}
