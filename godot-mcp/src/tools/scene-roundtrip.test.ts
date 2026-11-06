import { expect, it } from "vitest";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import * as os from "node:os";
import { registerSceneTools } from "./scene-tools.js";
import { FileToolRegistry } from "../utils/tool-registry.js";
import { TscnParser } from "../parsers/tscn-parser.js";

it("preserves parser metadata through the public read/write schemas", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "godot-scene-roundtrip-"));
  try {
    const content = `[gd_scene load_steps=2 format=3 uid="uid://audit" custom="future"]
[ext_resource type="PackedScene" path="res://child.tscn" id="1" custom="resource"]
[node name="Root" type="Node" unique_id=42]
metadata/literal = "Vector2(1, 2)"
metadata/inventory = {
"coins": 42,
"positions": PackedVector2Array(0, 0, 1, 1)
}
[node name="Child" parent="." owner="." index=0 instance=ExtResource("1")]
[connection signal="ready" from="." to="Child" method="show" binds=[&"test", 42] unbinds=1]
[editable path="Child"]
`;
    await fs.writeFile(path.join(root, "source.tscn"), content);
    const registry = new FileToolRegistry();
    registerSceneTools(registry, { projectPath: root, editorConnected: false, editorPort: 6550 });
    const read = registry.get("godot_read_scene")!;
    const result = await read.handler(read.inputSchema.parse({ path: "source.tscn" })) as { scene: object };
    const write = registry.get("godot_write_scene")!;
    await write.handler(write.inputSchema.parse({ path: "copy.tscn", scene: result.scene }));
    const copy = await fs.readFile(path.join(root, "copy.tscn"), "utf8");
    expect(TscnParser.parse(copy)).toEqual(TscnParser.parse(content));
    expect(copy).toContain('metadata/literal = "Vector2(1, 2)"');
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});
