import { afterEach, describe, expect, it } from "vitest";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { registerDocsTools } from "./docs-tools.js";
import { FileToolRegistry } from "../utils/tool-registry.js";

const temporary: string[] = [];
afterEach(async () => {
  await Promise.all(temporary.splice(0).map(p => fs.rm(p, { recursive: true, force: true })));
});
async function setup() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "godot-init-safe-"));
  temporary.push(root);
  const registry = new FileToolRegistry();
  registerDocsTools(registry, { projectPath: root, editorConnected: false, editorPort: 6550 });
  const tool = registry.get("godot_init_project")!;
  return { root, run: (args: object = {}) => tool.handler(tool.inputSchema.parse({
    projectPath: root, projectName: 'Quoted "Project"', includeAiBridge: false, ...args,
  })) };
}

describe("safe project initialization", () => {
  it("refuses an existing project without changing any files", async () => {
    const { root, run } = await setup();
    await fs.writeFile(path.join(root, "project.godot"), '[autoload]\nSave="*res://save.gd"\n');
    await fs.writeFile(path.join(root, ".gitignore"), "private-data/\n");
    await expect(run()).rejects.toThrow(/Refusing to overwrite/);
    expect(await fs.readFile(path.join(root, "project.godot"), "utf8")).toContain("Save=");
    expect(await fs.readFile(path.join(root, ".gitignore"), "utf8")).toBe("private-data/\n");
    expect(await fs.readdir(root)).toHaveLength(2);
  });

  it("preflights template collisions before writing project.godot", async () => {
    const { root, run } = await setup();
    await fs.mkdir(path.join(root, "scripts"));
    await fs.writeFile(path.join(root, "scripts/player.gd"), "existing script");
    await expect(run({ template: "2d_platformer" })).rejects.toThrow(/player.gd/);
    await expect(fs.access(path.join(root, "project.godot"))).rejects.toMatchObject({ code: "ENOENT" });
    expect(await fs.readFile(path.join(root, "scripts/player.gd"), "utf8")).toBe("existing script");
  });

  it("allows explicit overwrite and escapes project names", async () => {
    const { root, run } = await setup();
    await run({ template: "ui_app" });
    const config = await fs.readFile(path.join(root, "project.godot"), "utf8");
    expect(config).toContain('config/name="Quoted \\"Project\\""');
    await expect(run({ overwrite: true })).resolves.toMatchObject({ success: true });
  });

  it("refuses output directories symlinked outside the new project", async () => {
    const { root, run } = await setup();
    const outside = await fs.mkdtemp(path.join(os.tmpdir(), "godot-init-outside-"));
    temporary.push(outside);
    await fs.symlink(outside, path.join(root, "scripts"), process.platform === "win32" ? "junction" : "dir");
    await expect(run({ template: "2d_platformer" })).rejects.toThrow(/escapes project root/);
    expect(await fs.readdir(outside)).toEqual([]);
    await expect(fs.access(path.join(root, "project.godot"))).rejects.toMatchObject({ code: "ENOENT" });
  });
});
