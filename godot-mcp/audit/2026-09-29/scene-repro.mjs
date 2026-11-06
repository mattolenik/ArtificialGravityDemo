import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {spawnSync} from 'node:child_process';

const repo = path.resolve(process.argv[2] || process.cwd());
const importRepo = rel => import(pathToFileURL(path.join(repo, rel)).href);
const {TscnParser} = await importRepo('dist/parsers/tscn-parser.js');
const {registerAnimationTools, parseAnimationClipContent} = await importRepo('dist/tools/animation-tools.js');
const {registerResourceTools} = await importRepo('dist/tools/resource-tools.js');
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'godot-audit-repro-'));
console.log('FIXTURES', root);
const checks = [];
function record(name, reproduced, detail) {
  checks.push({name,reproduced,detail});
  console.log(JSON.stringify(checks.at(-1)));
}
await fs.writeFile(path.join(root,'project.godot'),'[application]\nconfig/name="Audit Repro"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n');
await fs.writeFile(path.join(root,'generate.gd'),`extends SceneTree
func _init():
 var root = Node2D.new()
 root.name = "Root"
 root.set_meta("inventory", {"coins": 42, "items": ["sword", "shield"]})
 var poly = Polygon2D.new()
 poly.name = "Polygon"
 root.add_child(poly)
 poly.owner = root
 poly.polygon = PackedVector2Array([Vector2(0,0),Vector2(10,0),Vector2(0,10)])
 var scene = PackedScene.new()
 scene.pack(root)
 ResourceSaver.save(scene, "res://original.tscn")
 var anim = Animation.new()
 anim.length = 1
 var idx = anim.add_track(Animation.TYPE_VALUE)
 anim.track_set_path(idx, NodePath(".:position"))
 anim.track_insert_key(idx, 0, Vector2.ZERO)
 anim.track_insert_key(idx, 1, Vector2(10, 10))
 ResourceSaver.save(anim, "res://original.tres")
 root.free()
 quit()
`);
const godot = process.env.GODOT_BIN || 'godot';
const generation = spawnSync(godot,['--headless','--path',root,'--script','generate.gd'],{encoding:'utf8',timeout:20000});
const engineAvailable = !generation.error && generation.status === 0;
if (!engineAvailable) {
 console.log('Godot unavailable or generation failed; using equivalent text fixtures', generation.error?.message || generation.stderr);
 await fs.writeFile(path.join(root,'original.tscn'),`[gd_scene format=3]
[node name="Root" type="Node2D"]
metadata/inventory = {
"coins": 42,
"items": ["sword", "shield"]
}
[node name="Polygon" type="Polygon2D" parent="."]
polygon = PackedVector2Array(0, 0, 10, 0, 0, 10)
`);
 await fs.writeFile(path.join(root,'original.tres'),`[gd_resource type="Animation" format=3]
[resource]
tracks/0/type = "value"
tracks/0/path = NodePath(".:position")
tracks/0/keys = {
"times": PackedFloat32Array(0, 1),
"transitions": PackedFloat32Array(1, 1),
"update": 0,
"values": [Vector2(0, 0), Vector2(10, 10)]
}
`);
}
const scene = TscnParser.parse(await fs.readFile(path.join(root,'original.tscn'),'utf8'));
const serialized = TscnParser.serialize(scene);
await fs.writeFile(path.join(root,'roundtrip.tscn'),serialized);
record('multiline_scene_dictionary_loss',Object.keys(scene.nodes[0].properties['metadata/inventory']).length === 0,scene.nodes[0].properties);
record('packed_array_quoted',serialized.includes('polygon = "PackedVector2Array('), serialized);
const animationSource = await fs.readFile(path.join(root,'original.tres'),'utf8');
const clip = parseAnimationClipContent(animationSource);
record('multiline_animation_keys_loss',clip.tracks[0].keyframes.length === 0,clip);
await fs.copyFile(path.join(root,'original.tres'),path.join(root,'edited.tres'));
const tools = new Map();
registerAnimationTools(tools,{projectPath:root});
const keyTool = tools.get('godot_animation_add_keyframe');
const keyResult = await keyTool.handler(keyTool.inputSchema.parse({path:'edited.tres',trackIndex:0,time:0.5,value:{_type:'Vector2',x:5,y:5}}));
record('animation_edit_deletes_existing_keys',keyResult.keyframeCount === 1,keyResult);
const hierarchy = `[gd_scene format=3]
[node name="Root" type="Node2D"]
[node name="Player" type="Node2D" parent="."]
[node name="Sprite" type="Sprite2D" parent="Player"]
[node name="Player2" type="Node2D" parent="."]
[node name="Sprite" type="Sprite2D" parent="Player2"]
[connection signal="ready" from="Player/Sprite" to="Player" method="hide"]
`;
const removed = TscnParser.parse(hierarchy);
TscnParser.removeNode(removed,'Player');
record('remove_deletes_sibling_descendant',!removed.nodes.some(n=>n.parent === 'Player2'),removed.nodes);
const renamed = TscnParser.parse(hierarchy);
TscnParser.modifyNode(renamed,'Player',{name:'Hero'});
await fs.writeFile(path.join(root,'renamed.tscn'),TscnParser.serialize(renamed));
record('rename_orphans_descendant',renamed.nodes.some(n=>n.parent === 'Player'),renamed);
const tree = TscnParser.getSceneTree(TscnParser.parse(hierarchy));
record('incorrect_scene_tree',!!tree['.'] && Object.keys(tree.Root._children).length === 0,tree);
await fs.mkdir(path.join(root,'project'));
await fs.mkdir(path.join(root,'outside'));
await fs.symlink(path.join(root,'outside'),path.join(root,'project','link'));
registerResourceTools(tools,{projectPath:path.join(root,'project')});
const writeResource = tools.get('godot_write_resource');
await writeResource.handler(writeResource.inputSchema.parse({path:'res://link/escape.tres',resourceType:'Resource',properties:{resource_name:'outside project'}}));
record('symlink_escape',await fs.access(path.join(root,'outside','escape.tres')).then(()=>true,()=>false),path.join(root,'outside','escape.tres'));
registerResourceTools(tools,{projectPath:root});
for (const [file,properties] of [['dictionary.tres',{'metadata/inventory':{coins:42}}],['quoted.tres',{resource_name:'Say "hello"'}]]) {
 const tool = tools.get('godot_write_resource');
 await tool.handler(tool.inputSchema.parse({path:file,resourceType:'Resource',properties}));
 const text = await fs.readFile(path.join(root,file),'utf8');
 record('resource_serialization_'+file,file === 'dictionary.tres' ? text.includes('[object Object]') : text.includes('"Say "hello""'),text);
}
const waveScript = `import {registerResourceTools} from ${JSON.stringify(pathToFileURL(path.join(repo,'dist/tools/resource-tools.js')).href)};
const tools=new Map();registerResourceTools(tools,{projectPath:${JSON.stringify(root)}});
const tool=tools.get('godot_generate_wave_config');
const args=tool.inputSchema.parse({waveCount:1,enemyTypes:[{name:'slime',baseCost:0}]});
console.log('SCHEMA_ACCEPTED',JSON.stringify(args));
await tool.handler(args);`;
const wave = spawnSync(process.execPath,['--input-type=module','-e',waveScript],{encoding:'utf8',timeout:2000});
record('zero_cost_wave_hang',wave.error?.code === 'ETIMEDOUT',{stdout:wave.stdout,error:wave.error?.code});
if (engineAvailable) {
 await fs.writeFile(path.join(root,'verify.gd'),`extends SceneTree
func _init():
 for file in ["original.tscn", "roundtrip.tscn"]:
  var root = load("res://" + file).instantiate()
  print(file, " INVENTORY=", root.get_meta("inventory"), " POLYGON=", root.get_node("Polygon").polygon)
  root.free()
 for file in ["original.tres", "edited.tres"]:
  var anim = load("res://" + file)
  print(file, " KEYS=", anim.track_get_key_count(0))
 var renamed = load("res://renamed.tscn").instantiate()
 print("HERO_CHILD_COUNT=", renamed.get_node("Hero").get_child_count())
 renamed.free()
 for file in ["dictionary.tres", "quoted.tres"]:
  print(file, " LOADED=", load("res://" + file))
 quit()
`);
 const result = spawnSync(godot,['--headless','--path',root,'--script','verify.gd'],{encoding:'utf8',timeout:20000});
 await fs.writeFile(path.join(root,'engine-output.txt'),result.stdout + result.stderr);
 console.log('ENGINE_VERIFICATION\n' + result.stdout + result.stderr);
}
await fs.writeFile(path.join(root,'checks.json'),JSON.stringify(checks,null,2));
console.log('SUMMARY',checks.filter(c=>c.reproduced).length + '/' + checks.length + ' audit bugs reproduced');
