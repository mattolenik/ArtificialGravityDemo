import { describe, expect, it } from "vitest";
import * as path from "path";
import {
  getProjectRelativePath,
  resolveProjectDirectory,
  resolveProjectPath,
} from "./path-utils.js";

describe("path utils", () => {
  const projectRoot = path.resolve("/tmp/godot-project");

  it("resolves relative project paths", () => {
    const resolved = resolveProjectPath("scenes/main.tscn", projectRoot);
    expect(resolved).toBe(path.join(projectRoot, "scenes", "main.tscn"));
  });

  it("resolves res:// paths", () => {
    const resolved = resolveProjectPath("res://scripts/player.gd", projectRoot);
    expect(resolved).toBe(path.join(projectRoot, "scripts", "player.gd"));
  });

  it("allows absolute paths inside project root", () => {
    const inProject = path.join(projectRoot, "assets", "icon.png");
    expect(resolveProjectPath(inProject, projectRoot)).toBe(inProject);
  });

  it("rejects traversal outside project root", () => {
    expect(() => resolveProjectPath("../outside.txt", projectRoot)).toThrow(
      /escapes project root/
    );
  });

  it("rejects absolute paths outside project root", () => {
    expect(() => resolveProjectPath("/etc/passwd", projectRoot)).toThrow(
      /escapes project root/
    );
  });

  it("resolves optional directories", () => {
    expect(resolveProjectDirectory(undefined, projectRoot)).toBe(projectRoot);
    expect(resolveProjectDirectory("scenes/ui", projectRoot)).toBe(
      path.join(projectRoot, "scenes", "ui")
    );
  });

  it("computes project-relative paths", () => {
    const full = path.join(projectRoot, "resources", "data.tres");
    expect(getProjectRelativePath(full, projectRoot)).toBe(
      path.join("resources", "data.tres")
    );
  });

  it("rejects project-relative path lookup outside root", () => {
    expect(() => getProjectRelativePath("/var/tmp/file.txt", projectRoot)).toThrow(
      /escapes project root/
    );
  });
});

import * as fs from "node:fs";
import * as os from "node:os";

describe("real filesystem containment", () => {
  it("blocks existing and new outputs through escaping symlinks, including dangling links", () => {
    const temp = fs.mkdtempSync(path.join(os.tmpdir(), "path-regression-"));
    try {
      const root = path.join(temp, "project");
      const outside = path.join(temp, "outside");
      fs.mkdirSync(root); fs.mkdirSync(outside);
      fs.writeFileSync(path.join(outside, "secret"), "data");
      fs.symlinkSync(outside, path.join(root, "link"), process.platform === "win32" ? "junction" : "dir");
      fs.symlinkSync(path.join(outside, "absent"), path.join(root, "dangling"));
      expect(() => resolveProjectPath("link/secret", root)).toThrow(/escapes/);
      expect(() => resolveProjectPath("link/new/sub/file", root)).toThrow(/escapes/);
      expect(() => resolveProjectPath("dangling", root)).toThrow(/Dangling/);
      fs.mkdirSync(path.join(root, "assets"));
      fs.symlinkSync(path.join(root,"assets"),path.join(root,"internal"), process.platform === "win32" ? "junction" : "dir");
      expect(resolveProjectPath("internal/new",root)).toBe(path.join(root,"internal/new"));
      expect(resolveProjectPath("..valid/file",root)).toBe(path.join(root,"..valid/file"));
    } finally { fs.rmSync(temp,{recursive:true,force:true}); }
  });
});
