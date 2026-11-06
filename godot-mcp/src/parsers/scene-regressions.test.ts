import { describe, expect, it } from "vitest";
import { TscnParser } from "./tscn-parser.js";
import { splitGodotStatements } from "./godot-text.js";

const hierarchy = `[gd_scene format=3]
[node name="Root" type="Node2D"]
[node name="Player" type="Node2D" parent="."]
[node name="Sprite" type="Node2D" parent="Player"]
target = NodePath("../../Player2")
[node name="Player2" type="Node2D" parent="."]
target = NodePath("../Player/Sprite:position")
[node name="Sprite" type="Node2D" parent="Player2"]
[connection signal="ready" from="Player/Sprite" to="Player" method="hide"]`;

describe("scene preservation regressions", () => {
 it("preserves escaped resource attributes and rejects unsupported sections", () => {
  const input = '[gd_scene format=3]\n[ext_resource type="Texture2D" path="res://a\\\"b\\\\c.png" id="1"]\n[node name="Root" type="Node"]';
  const parsed = TscnParser.parse(input);
  const serialized = TscnParser.serialize(parsed);
  expect(TscnParser.parse(serialized).externalResources).toEqual(parsed.externalResources);
  expect(serialized).toContain(input.split("\n")[1]);
  expect(() => TscnParser.parse(input + '\n[unsupported]\ndata = 1')).toThrow(/Unsupported Godot section/);
 });

 it("preserves Godot multiline variants, literal strings, unknown attributes and sections", () => {
  const input = `[gd_scene format=3 custom="future"]
[sub_resource type="AnimationLibrary" id="Library"]
_data = {
&"idle": SubResource("Animation_1")
}
[node name="Root" type="Node2D" unique_id=123 node_paths=PackedStringArray("target")]
metadata/data = {
"_private": 4,
"res://icon.png": [Vector2i(1, 2), &"name"],
"x": 1,
"y": 2
}
metadata/literal = "Vector2(1, 2)"
metadata/escaped = "hello\\nworld"
polygon = PackedVector2Array(0, 0, 1, 0, 0, 1)
[editable path="Child"]`;
  const scene = TscnParser.parse(input);
  TscnParser.modifyNode(scene, "Root", { properties: { visible: false } });
  const result = TscnParser.serialize(scene);
  for (const statement of splitGodotStatements(input)) expect(result).toContain(statement);
  expect(result).toContain("visible = false");
 });
 it("rejects incomplete source before mutation", () => {
  expect(() => TscnParser.parse('[gd_scene format=3]\n[node name="Root"]\nmetadata/data = {\n"a": 1')).toThrow(/Incomplete/);
 });
 it("accepts Variant shorthand when replacing existing properties", () => {
  const scene = TscnParser.parse('[gd_scene format=3]\n[node name="Root" type="Node2D"]\nposition = Vector2(1, 2)\nscale = Vector2(1, 1)\nmetadata/literal = "Vector2(9, 9)"');
  TscnParser.modifyNode(scene, "Root", { properties: { position: "Vector2(3, 4)", scale: { x: 2, y: 3 } } });
  const result = TscnParser.serialize(scene);
  expect(result).toContain("position = Vector2(3, 4)");
  expect(result).toContain("scale = Vector2(2, 3)");
  expect(result).toContain('metadata/literal = "Vector2(9, 9)"');
 });
 it("preserves empty and subname-only NodePaths during renames", () => {
  const scene = TscnParser.parse(hierarchy.replace('[connection', 'empty = NodePath("")\nlocal = NodePath(":position")\n[connection'));
  TscnParser.modifyNode(scene, "Player2", { name: "Other" });
  const result = TscnParser.serialize(scene);
  expect(result).toContain('empty = NodePath("")');
  expect(result).toContain('local = NodePath(":position")');
 });
 it("removes only a complete path subtree, and root deletion removes everything", () => {
  const scene = TscnParser.parse(hierarchy);
  TscnParser.removeNode(scene, "Player");
  expect(scene.nodes.map(n => [n.name,n.parent])).toEqual([["Root",undefined],["Player2","."],["Sprite","Player2"]]);
  expect(scene.connections).toEqual([]);
  TscnParser.removeNode(scene, "Root");
  expect(scene.nodes).toEqual([]);
 });
 it("renames descendants, relative NodePaths, and signal endpoints atomically", () => {
  const scene = TscnParser.parse(hierarchy);
  TscnParser.modifyNode(scene, "Player", { name: "Hero" });
  expect(scene.nodes[2].parent).toBe("Hero");
  expect(scene.nodes[2].properties.target).toEqual({_type:"NodePath",path:"../../Player2"});
  expect(scene.nodes[3].properties.target).toEqual({_type:"NodePath",path:"../Hero/Sprite:position"});
  expect(scene.connections[0]).toMatchObject({from:"Hero/Sprite",to:"Hero"});
  expect(() => TscnParser.modifyNode(scene,"Hero",{name:"Player2"})).toThrow(/already exists/);
 });
 it("rejects ambiguous references before changing the tree", () => {
  const scene=TscnParser.parse(hierarchy+'\n');
  scene.subResources.push({type:"Animation",id:"a",properties:{target:{_type:"NodePath",path:"Player"}}});
  const before=JSON.stringify(scene);
  expect(()=>TscnParser.modifyNode(scene,"Player",{name:"Hero"})).toThrow(/safely rename/);
  expect(JSON.stringify(scene)).toBe(before);
 });
 it("returns descendants below the actual root", () => {
  const tree = TscnParser.getSceneTree(TscnParser.parse(hierarchy)) as any;
  expect(Object.keys(tree)).toEqual(["Root"]);
  expect(Object.keys(tree.Root._children)).toEqual(["Player","Player2"]);
  expect(tree.Root._children.Player._children.Sprite.type).toBe("Node2D");
 });
});
