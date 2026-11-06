import { afterEach, describe, expect, it, vi } from "vitest";
import * as fs from "node:fs/promises";
import nativeFs from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";
import * as os from "node:os";
import * as path from "node:path";
import { readFile, writeFile, withFileMutation } from "./project-fs.js";
import { FileToolRegistry } from "./tool-registry.js";
import { registerSceneTools } from "../tools/scene-tools.js";

const temporary: string[] = [];
afterEach(async () => {
  await Promise.all(temporary.splice(0).map(p => fs.rm(p, { recursive: true, force: true })));
});
async function project() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "godot-file-mutation-"));
  temporary.push(root);
  return root;
}

describe("file mutations", () => {
  it("preserves every concurrent scene edit through the production registry", async () => {
    const root = await project();
    const scenePath = path.join(root, "main.tscn");
    await fs.writeFile(scenePath, '[gd_scene format=3]\n\n[node name="Main" type="Node2D"]\n');
    const registry = new FileToolRegistry();
    registerSceneTools(registry, { projectPath: root, editorConnected: false, editorPort: 6550 });
    const tool = registry.get("godot_modify_node")!;
    await Promise.all(Array.from({ length: 20 }, (_, i) => tool.handler(tool.inputSchema.parse({
      scenePath: "main.tscn", nodePath: "Main", updates: { properties: { [`metadata/value${i}`]: i } },
    }))));
    const text = await fs.readFile(scenePath, "utf8");
    for (let i = 0; i < 20; i++) expect(text).toContain(`metadata/value${i} = ${i}\n`);
  });

  it("rejects an observed external edit instead of overwriting it", async () => {
    const file = path.join(await project(), "file.txt");
    await fs.writeFile(file, "initial");
    await expect(withFileMutation(async () => {
      expect(await readFile(file, "utf8")).toBe("initial");
      await fs.writeFile(file, "external editor");
      await writeFile(file, "stale tool output");
    })).rejects.toThrow(/changed during tool operation/);
    expect(await fs.readFile(file, "utf8")).toBe("external editor");
    expect((await fs.readdir(path.dirname(file))).filter(p => p.endsWith(".tmp"))).toEqual([]);
  });

  it.each(["w", "wx"])("does not adopt an external edit immediately after %s publication", async (flag) => {
    const file = path.join(await project(), "file.txt");
    if (flag === "w") await fs.writeFile(file, "initial");
    const operation = flag === "wx" ? "link" : "rename";
    const publish = nativeFs[operation];
    const spy = vi.spyOn(nativeFs, operation).mockImplementationOnce(async (source, target) => {
      await publish(source, target);
      // Model an editor saving after atomic publication but before writeFile returns.
      await nativeFs.writeFile(file, "external edit after publication");
    });
    syncBuiltinESMExports();
    try {
      await expect(withFileMutation(async () => {
        await writeFile(file, "first tool output", { flag });
        expect(await fs.readFile(file, "utf8")).toBe("external edit after publication");
        await writeFile(file, "second stale output");
      })).rejects.toThrow(/changed during tool operation/);
      expect(await fs.readFile(file, "utf8")).toBe("external edit after publication");
      expect((await fs.readdir(path.dirname(file))).filter(p => p.endsWith(".tmp"))).toEqual([]);
    } finally {
      spy.mockRestore();
      syncBuiltinESMExports();
    }
  });

  it("keeps the queue usable after rejection and retains file permissions", async () => {
    const file = path.join(await project(), "file.txt");
    await fs.writeFile(file, "initial", { mode: 0o600 });
    const bad = withFileMutation(async () => { throw new Error("failed operation"); });
    const good = withFileMutation(async () => { await writeFile(file, "updated"); });
    await expect(bad).rejects.toThrow("failed operation");
    await good;
    expect(await fs.readFile(file, "utf8")).toBe("updated");
    if (process.platform !== "win32") expect((await fs.stat(file)).mode & 0o777).toBe(0o600);
  });

  it("exclusive creation never replaces an existing file", async () => {
    const file = path.join(await project(), "file.txt");
    await fs.writeFile(file, "keep me");
    await expect(writeFile(file, "replace me", { flag: "wx" })).rejects.toMatchObject({ code: "EEXIST" });
    expect(await fs.readFile(file, "utf8")).toBe("keep me");
  });
});
