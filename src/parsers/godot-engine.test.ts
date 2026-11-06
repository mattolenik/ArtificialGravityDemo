import { describe, expect, it } from "vitest";
import { spawnSync } from "node:child_process";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import * as os from "node:os";
import { registerSceneTools } from "../tools/scene-tools.js";
import { registerAnimationTools } from "../tools/animation-tools.js";
import { registerResourceTools } from "../tools/resource-tools.js";
import type { ServerState, ToolHandler } from "../index.js";

const godot = process.env.GODOT_BIN || "godot";
const available = spawnSync(godot,["--version"],{encoding:"utf8",timeout:5000}).status === 0;
describe.skipIf(!available)("Godot semantic preservation",()=>{
 it("loads edited engine-authored scenes, animations, and structured resources without data loss",async()=>{
  const root=await fs.mkdtemp(path.join(os.tmpdir(),"godot-preservation-"));
  const run=(script:string)=>{
   const result=spawnSync(godot,["--headless","--path",root,"--script",script],{encoding:"utf8",timeout:15000});
   expect(result.error, result.stderr).toBeUndefined();
   expect(result.status, result.stderr).toBe(0);
   expect(result.stderr).not.toMatch(/(?:SCRIPT ERROR|Parse Error|ERROR:)/);
   return result.stdout;
  };
  try {
   await fs.writeFile(path.join(root,"project.godot"),'[application]\nconfig/name="regression"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n');
   await fs.writeFile(path.join(root,"generate.gd"),`extends SceneTree
func _init():
 var root = Node2D.new()
 root.name = "Root"
 root.set_meta("inventory", {"coins": 42, "items": ["sword", "shield"]})
 var poly = Polygon2D.new()
 poly.name = "Polygon"
 root.add_child(poly)
 poly.owner = root
 poly.polygon = PackedVector2Array([Vector2.ZERO, Vector2(10, 0), Vector2(0, 10)])
 var scene = PackedScene.new()
 scene.pack(root)
 ResourceSaver.save(scene, "res://scene.tscn")
 var anim = Animation.new()
 anim.length = 1
 anim.resource_name = "Original"
 var idx = anim.add_track(Animation.TYPE_VALUE)
 anim.track_set_path(idx, NodePath(".:position"))
 anim.track_insert_key(idx, 0, Vector2.ZERO)
 anim.track_insert_key(idx, 1, Vector2(10, 10))
 anim.track_set_enabled(idx, false)
 ResourceSaver.save(anim, "res://animation.tres")
 root.free()
 print("GENERATED")
 quit()
`);
   expect(run("generate.gd")).toContain("GENERATED");
   const tools=new Map<string,ToolHandler>();
   registerSceneTools(tools,{projectPath:root} as ServerState);
   const modify=tools.get("godot_modify_node")!;
   await modify.handler(modify.inputSchema.parse({scenePath:"scene.tscn",nodePath:"Root",updates:{properties:{visible:false}}}));
   registerAnimationTools(tools,{projectPath:root} as ServerState);
   registerResourceTools(tools,{projectPath:root} as ServerState);
   const add=tools.get("godot_animation_add_keyframe")!;
   await add.handler(add.inputSchema.parse({path:"animation.tres",trackIndex:0,time:0.5,value:{_type:"Vector2",x:5,y:5}}));
   const write=tools.get("godot_write_resource")!;
   await write.handler(write.inputSchema.parse({path:"resource.tres",resourceType:"Resource",properties:{resource_name:'Say "hello"',"metadata/inventory":{coins:42,_private:1},"metadata/literal":"Vector2(1, 2)"}}));
   await fs.writeFile(path.join(root,"verify.gd"),`extends SceneTree
func _init():
 var root = load("res://scene.tscn").instantiate()
 assert(root.get_meta("inventory")["coins"] == 42)
 assert(root.get_meta("inventory")["items"] == ["sword", "shield"])
 assert(root.get_node("Polygon").polygon.size() == 3)
 assert(root.visible == false)
 var anim = load("res://animation.tres")
 assert(anim.track_get_key_count(0) == 3)
 assert(anim.track_get_key_value(0, 1) == Vector2(5, 5))
 assert(anim.track_is_enabled(0) == false)
 assert(anim.resource_name == "Original")
 var resource = load("res://resource.tres")
 assert(resource.resource_name == 'Say "hello"')
 assert(resource.get_meta("inventory")["coins"] == 42)
 assert(resource.get_meta("inventory")["_private"] == 1)
 assert(resource.get_meta("literal") == "Vector2(1, 2)")
 root.free()
 print("PRESERVATION_PASSED")
 quit()
`);
   expect(run("verify.gd")).toContain("PRESERVATION_PASSED");
  } finally { await fs.rm(root,{recursive:true,force:true}); }
 },30000);
});
